use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::bridge::mac_bridge::MacBridge;
use crate::config::Config;
use crate::hid::keyboard::Keyboard;
use crate::hid::media::Media;
use crate::hid::mouse::Mouse;
use crate::ipc::{IpcRequest, IpcResponse};
use crate::serial::protocol::Request as BridgeRequest;

fn socket_path() -> String {
    std::env::var("ZB_SOCK").unwrap_or_else(|_| "/tmp/zerobridge.sock".to_string())
}

pub struct Daemon {
    bridge:   Arc<MacBridge>,
    keyboard: Arc<tokio::sync::Mutex<Keyboard>>,
    mouse:    Arc<tokio::sync::Mutex<Mouse>>,
    media:    Arc<tokio::sync::Mutex<Media>>,
}

impl Daemon {
    pub async fn new(config: Config) -> Result<Self, String> {
        let bridge = MacBridge::new(config.clone()).await
            .map_err(|e| format!("Bridge init failed: {e}"))?;

        let keyboard = Keyboard::new(&config.hid)
            .map_err(|e| format!("Keyboard init failed: {e}"))?;

        let mouse = Mouse::new(&config.hid)
            .map_err(|e| format!("Mouse init failed: {e}"))?;

        let media = Media::new(&config.hid)
            .map_err(|e| format!("Media init failed: {e}"))?;

        Ok(Daemon {
            bridge:   Arc::new(bridge),
            keyboard: Arc::new(tokio::sync::Mutex::new(keyboard)),
            mouse:    Arc::new(tokio::sync::Mutex::new(mouse)),
            media:    Arc::new(tokio::sync::Mutex::new(media)),
        })
    }

    pub async fn run(self, mut shutdown: tokio::sync::watch::Receiver<bool>) -> Result<(), String> {
        // Start health monitor with shutdown awareness
        self.bridge.spawn_health_monitor_with_shutdown(shutdown.clone());

        let sock = socket_path();
        let _ = std::fs::remove_file(&sock);

        let listener = UnixListener::bind(&sock)
            .map_err(|e| format!("Bind {sock} failed: {e}"))?;

        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o666))
                .map_err(|e| format!("Set permissions failed: {e}"))?;
        }

        eprintln!("[daemon] Listening on {sock}");

        let daemon = Arc::new(self);

        loop {
            tokio::select! {
                result = listener.accept() => {
                    match result {
                        Ok((stream, _)) => {
                            eprintln!("[daemon] New connection");
                            let d = daemon.clone();
                            let mut sd = shutdown.clone();
                            tokio::spawn(async move {
                                if let Err(e) = d.handle_connection(stream, &mut sd).await {
                                    eprintln!("[daemon] Connection error: {e}");
                                }
                            });
                        }
                        Err(e) => {
                            eprintln!("[daemon] Accept error: {e}");
                        }
                    }
                }
                _ = shutdown.changed() => {
                    eprintln!("[daemon] Shutdown signal — stopping accept loop");
                    break;
                }
            }
        }

        Ok(())
    }

    async fn handle_connection(
        &self,
        stream: UnixStream,
        shutdown: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<(), String> {
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        let mut line = String::new();

        loop {
            line.clear();
            tokio::select! {
                result = reader.read_line(&mut line) => {
                    match result {
                        Ok(0) => {
                            eprintln!("[daemon] Client disconnected");
                            break;
                        }
                        Ok(_) => {
                            let trimmed = line.trim();
                            if trimmed.is_empty() { continue; }

                            eprintln!("[daemon] ← {trimmed}");

                            let response = self.handle_request(trimmed).await;
                            let json = serde_json::to_string(&response)
                                .unwrap_or_else(|_| r#"{"type":"error","id":"?","message":"serialize failed"}"#.into())
                                + "\n";

                            eprintln!("[daemon] → {}", json.trim());

                            writer.write_all(json.as_bytes()).await
                                .map_err(|e| format!("Write failed: {e}"))?;
                        }
                        Err(e) => {
                            return Err(format!("Read error: {e}"));
                        }
                    }
                }
                _ = shutdown.changed() => {
                    eprintln!("[daemon] Shutdown — closing connection");
                    break;
                }
            }
        }

        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    async fn handle_request(&self, raw: &str) -> IpcResponse {
        let id = serde_json::from_str::<serde_json::Value>(raw)
            .ok()
            .and_then(|v| v["id"].as_str().map(ToString::to_string))
            .unwrap_or_else(|| "?".to_string());

        let req = match serde_json::from_str::<IpcRequest>(raw) {
            Ok(r) => r,
            Err(e) => return IpcResponse::error(&id, &format!("Parse error: {e}")),
        };

        match req {
            // ── Mac queries ────────────────────────

            IpcRequest::GetCursor => {
                match self.bridge.request(BridgeRequest::GetCursor).await {
                    Ok(crate::serial::protocol::Response::CursorPos { x, y }) =>
                        IpcResponse::CursorPos { id, x, y },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetScreens => {
                match self.bridge.request(BridgeRequest::GetScreens).await {
                    Ok(crate::serial::protocol::Response::Screens { layout }) =>
                        IpcResponse::Screens { id, layout },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetClipboard => {
                match self.bridge.request(BridgeRequest::GetClipboard).await {
                    Ok(crate::serial::protocol::Response::Clipboard { text }) =>
                        IpcResponse::Clipboard { id, text },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetActiveApp => {
                match self.bridge.request(BridgeRequest::GetActiveApp).await {
                    Ok(crate::serial::protocol::Response::ActiveApp { name, window }) =>
                        IpcResponse::ActiveApp { id, name, window },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::RunCommand { cmd } => {
                match self.bridge.request(BridgeRequest::RunCommand { cmd }).await {
                    Ok(crate::serial::protocol::Response::CommandResult { output, error }) =>
                        IpcResponse::CommandResult { id, output, error },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetWindows => {
                match self.bridge.request(BridgeRequest::GetWindows).await {
                    Ok(crate::serial::protocol::Response::Windows { list }) =>
                        IpcResponse::Windows { id, list },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetWindowForApp { app } => {
                match self.bridge.request(BridgeRequest::GetWindowForApp { app }).await {
                    Ok(crate::serial::protocol::Response::Window { info }) =>
                        IpcResponse::Window { id, info },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::FocusApp { app } => {
                match self.bridge.request(BridgeRequest::FocusApp { app }).await {
                    Ok(crate::serial::protocol::Response::FocusResult { app, success }) =>
                        IpcResponse::FocusResult { id, app, success },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            IpcRequest::GetMacState => {
                match self.bridge.request(BridgeRequest::GetMacState).await {
                    Ok(crate::serial::protocol::Response::MacState { state, locked, display_sleep }) =>
                        IpcResponse::MacState { id, state, locked, display_sleep },
                    Ok(_) => IpcResponse::error(&id, "Unexpected response"),
                    Err(e) => IpcResponse::error(&id, &e),
                }
            }

            // ── HID Keyboard ───────────────────────

            IpcRequest::Key { code, modifiers } => {
                let mut kb = self.keyboard.lock().await;
                let parts: Vec<&str> = modifiers.iter()
                    .map(String::as_str)
                    .chain(std::iter::once(code.as_str()))
                    .collect();
                match kb.combo(&parts).await {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            IpcRequest::TypeText { text } => {
                let mut kb = self.keyboard.lock().await;
                match kb.type_text(&text).await {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            IpcRequest::TypeSmart { text } => {
                let mut kb = self.keyboard.lock().await;
                match kb.type_smart(&text).await {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            IpcRequest::Release => {
                let mut kb = self.keyboard.lock().await;
                let mut m  = self.mouse.lock().await;
                let _ = kb.release_all();
                let _ = m.release_all();
                IpcResponse::ok(&id)
            }

            // ── HID Mouse ──────────────────────────

            IpcRequest::MouseMove { dx, dy } => {
                let mut m = self.mouse.lock().await;
                match m.move_large(dx, dy).await {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            IpcRequest::MouseClick { button } => {
                let mut m = self.mouse.lock().await;
                let result = match button.as_str() {
                    "right"  => m.right_click().await,
                    "middle" => m.middle_click().await,
                    _        => m.click().await,
                };
                match result {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            IpcRequest::MouseScroll { delta } => {
                let mut m = self.mouse.lock().await;
                match m.scroll_smooth(delta, 5).await {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            // ── HID Media ──────────────────────────

            IpcRequest::MediaKey { key } => {
                let mut media = self.media.lock().await;
                let result = match key.as_str() {
                    "play_pause"      => media.play_pause().await,
                    "next"            => media.next().await,
                    "prev"            => media.prev().await,
                    "volume_up"       => media.volume_up().await,
                    "volume_down"     => media.volume_down().await,
                    "mute"            => media.mute().await,
                    "brightness_up"   => media.brightness_up().await,
                    "brightness_down" => media.brightness_down().await,
                    unknown => {
                        return IpcResponse::error(&id, &format!("Unknown media key: {unknown}"));
                    }
                };
                match result {
                    Ok(())  => IpcResponse::ok(&id),
                    Err(e) => IpcResponse::error(&id, &format!("{e:?}")),
                }
            }

            // ── System ─────────────────────────────

            IpcRequest::Reset => {
                let mut kb = self.keyboard.lock().await;
                let mut m  = self.mouse.lock().await;
                let _ = kb.release_all();
                let _ = m.release_all();
                eprintln!("[daemon] Reset — all HID released");
                IpcResponse::ok(&id)
            }

            IpcRequest::Status => {
                let status = self.bridge.status();
                IpcResponse::StatusInfo {
                    id,
                    ws_healthy:       status.ws_healthy,
                    ssh_usb_healthy:  status.ssh_usb_healthy,
                    ssh_wifi_healthy: status.ssh_wifi_healthy,
                }
            }

            IpcRequest::Ping => IpcResponse::Pong { id },
        }
    }
}
