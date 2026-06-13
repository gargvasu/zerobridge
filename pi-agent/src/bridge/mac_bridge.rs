use std::sync::Arc;
use tokio::time::{sleep, Duration};

use crate::bridge::serial_queue::SerialQueue;
use crate::bridge::ssh_pool::SshPool;
use crate::bridge::ws_pool::WsPool;
use crate::config::Config;
use crate::serial::protocol::{Request, Response};

const HEALTH_INTERVAL_SECS: u64 = 30;

pub struct MacBridge {
    pub serial:   Arc<SerialQueue>,
    pub ssh_usb:  Arc<SshPool>,
    pub ssh_wifi: Arc<SshPool>,
    pub ws:       Option<Arc<WsPool>>,
    mode:         String,
}

impl MacBridge {
    pub async fn new(config: Config) -> Result<Self, String> {
        let serial = SerialQueue::new(&config.serial)
            .await
            .map_err(|e| format!("Serial init failed: {e}"))?;

        let ws = match config.bridge.mode.as_str() {
            "websocket" | "hybrid" => {
                eprintln!("[bridge] Initializing WebSocket pool → {}", config.websocket.url);
                Some(Arc::new(WsPool::new(config.websocket.clone())))
            }
            _ => {
                eprintln!("[bridge] WebSocket disabled (mode={})", config.bridge.mode);
                None
            }
        };

        let bridge = MacBridge {
            serial: Arc::new(serial),
            ssh_usb: Arc::new(SshPool::new(config.hosts.usb.clone(), config.ssh.clone())),
            ssh_wifi: Arc::new(SshPool::new(config.hosts.wifi.clone(), config.ssh.clone())),
            ws,
            mode: config.bridge.mode.clone(),
        };

        eprintln!("[bridge] Mode: {}", bridge.mode);

        Ok(bridge)
    }

    pub fn spawn_health_monitor_with_shutdown(&self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let ssh_usb  = self.ssh_usb.clone();
        let ssh_wifi = self.ssh_wifi.clone();
        let ws       = self.ws.clone();

        tokio::spawn(async move {
            // Initial probe shortly after startup so status reflects reality fast
            tokio::select! {
                _ = sleep(Duration::from_secs(3)) => {}
                _ = shutdown.changed() => { return; }
            }
            eprintln!("[health] Initial channel probe...");
            if let Some(ws) = &ws { ws.check_health().await; }
            ssh_usb.check_health().await;
            ssh_wifi.check_health().await;

            loop {
                tokio::select! {
                    _ = sleep(Duration::from_secs(HEALTH_INTERVAL_SECS)) => {}
                    _ = shutdown.changed() => {
                        eprintln!("[health] Shutdown — stopping health monitor");
                        return;
                    }
                }
                eprintln!("[health] Checking channels...");
                if let Some(ws) = &ws { ws.check_health().await; }
                ssh_usb.check_health().await;
                ssh_wifi.check_health().await;
            }
        });
    }

    // ── Public API ─────────────────────────────────

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        match self.mode.as_str() {
            "serial" => match &req {
                Request::GetCursor | Request::GetScreens | Request::GetActiveApp => {
                    self.serial_with_fallback(req).await
                }
                _ => self.ssh_with_fallback(req).await,
            },
            "ssh" => self.ssh_with_fallback(req).await,
            _ => self.ws_with_fallback(req).await, // "websocket", "hybrid", default
        }
    }

    // ── Routing ────────────────────────────────────

    async fn ws_with_fallback(&self, req: Request) -> Result<Response, String> {
        if let Some(ws) = &self.ws {
            if ws.should_try() {
                match ws.request(req.clone()).await {
                    Ok(resp) => {
                        eprintln!("[bridge] ✅ websocket");
                        return Ok(resp);
                    }
                    Err(e) => {
                        eprintln!("[bridge] ⚠ websocket failed: {e} — trying SSH");
                    }
                }
            }
        }
        self.ssh_with_fallback(req).await
    }

    async fn serial_with_fallback(&self, req: Request) -> Result<Response, String> {
        match self.serial.request(req.clone()).await {
            Ok(resp) => {
                eprintln!("[bridge] ✅ serial");
                Ok(resp)
            }
            Err(e) => {
                eprintln!("[bridge] ⚠ serial failed: {e} — trying SSH");
                self.ssh_with_fallback(req).await
            }
        }
    }

    async fn ssh_with_fallback(&self, req: Request) -> Result<Response, String> {
        if self.ssh_usb.should_try() {
            match self.ssh_usb.request(req.clone()).await {
                Ok(resp) => {
                    eprintln!("[bridge] ✅ ssh_usb");
                    return Ok(resp);
                }
                Err(e) => {
                    eprintln!("[bridge] ⚠ ssh_usb failed: {e}");
                }
            }
        }

        eprintln!("[bridge] trying ssh_wifi...");
        match self.ssh_wifi.request(req).await {
            Ok(resp) => {
                eprintln!("[bridge] ✅ ssh_wifi");
                Ok(resp)
            }
            Err(e) => {
                eprintln!("[bridge] ❌ all channels failed: {e}");
                Err(format!("All channels failed: {e}"))
            }
        }
    }

    // ── Status ─────────────────────────────────────

    pub fn status(&self) -> BridgeStatus {
        BridgeStatus {
            ws_healthy:       self.ws.as_ref().is_some_and(|w| w.is_healthy()),
            ssh_usb_healthy:  self.ssh_usb.is_healthy(),
            ssh_wifi_healthy: self.ssh_wifi.is_healthy(),
        }
    }
}

pub struct BridgeStatus {
    pub ws_healthy:       bool,
    pub ssh_usb_healthy:  bool,
    pub ssh_wifi_healthy: bool,
}
