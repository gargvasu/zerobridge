use std::sync::Arc;
use tokio::time::{sleep, Duration};

use crate::bridge::serial_queue::SerialQueue;
use crate::bridge::ssh_pool::SshPool;
use crate::config::Config;
use crate::serial::protocol::{Request, Response};

const HEALTH_INTERVAL_SECS: u64 = 30;

pub struct MacBridge {
    pub serial: Arc<SerialQueue>,
    pub ssh_usb: Arc<SshPool>,
    pub ssh_wifi: Arc<SshPool>,
}

impl MacBridge {
    pub async fn new(config: Config) -> Result<Self, String> {
        let serial = SerialQueue::new(&config.serial)
            .await
            .map_err(|e| format!("Serial init failed: {}", e))?;

        let bridge = MacBridge {
            serial: Arc::new(serial),
            ssh_usb: Arc::new(SshPool::new(config.hosts.usb.clone(), config.ssh.clone())),
            ssh_wifi: Arc::new(SshPool::new(config.hosts.wifi.clone(), config.ssh.clone())),
        };

        // Spawn background health monitor
        bridge.spawn_health_monitor();

        Ok(bridge)
    }

    // ── Public API ─────────────────────────────────

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        match &req {
            // Real-time queries → serial first
            Request::GetCursor | Request::GetScreens | Request::GetActiveApp => {
                self.serial_with_fallback(req).await
            }

            // Large data → SSH directly
            Request::GetClipboard => self.ssh_with_fallback(req).await,

            // Commands → SSH only
            Request::RunCommand { .. } => self.ssh_with_fallback(req).await,
        }
    }

    // ── Routing ────────────────────────────────────

    async fn serial_with_fallback(&self, req: Request) -> Result<Response, String> {
        match self.serial.request(req.clone()).await {
            Ok(resp) => {
                eprintln!("[bridge] ✅ serial");
                Ok(resp)
            }
            Err(e) => {
                eprintln!("[bridge] ⚠ serial failed: {} — trying SSH", e);
                self.ssh_with_fallback(req).await
            }
        }
    }

    async fn ssh_with_fallback(&self, req: Request) -> Result<Response, String> {
        // Try USB tether first
        if self.ssh_usb.should_try() {
            match self.ssh_usb.request(req.clone()).await {
                Ok(resp) => {
                    eprintln!("[bridge] ✅ ssh_usb");
                    return Ok(resp);
                }
                Err(e) => {
                    eprintln!("[bridge] ⚠ ssh_usb failed: {}", e);
                }
            }
        }

        // Fallback to WiFi
        eprintln!("[bridge] trying ssh_wifi...");
        match self.ssh_wifi.request(req).await {
            Ok(resp) => {
                eprintln!("[bridge] ✅ ssh_wifi");
                Ok(resp)
            }
            Err(e) => {
                eprintln!("[bridge] ❌ all channels failed: {}", e);
                Err(format!("All channels failed: {}", e))
            }
        }
    }

    // ── Health Monitor ─────────────────────────────

    fn spawn_health_monitor(&self) {
        let ssh_usb = self.ssh_usb.clone();
        let ssh_wifi = self.ssh_wifi.clone();

        tokio::spawn(async move {
            loop {
                sleep(Duration::from_secs(HEALTH_INTERVAL_SECS)).await;

                eprintln!("[health] Checking channels...");
                ssh_usb.check_health().await;
                ssh_wifi.check_health().await;
            }
        });
    }

    // ── Status ─────────────────────────────────────

    pub fn status(&self) -> BridgeStatus {
        BridgeStatus {
            ssh_usb_healthy: self.ssh_usb.is_healthy(),
            ssh_wifi_healthy: self.ssh_wifi.is_healthy(),
        }
    }
}

pub struct BridgeStatus {
    pub ssh_usb_healthy: bool,
    pub ssh_wifi_healthy: bool,
}
