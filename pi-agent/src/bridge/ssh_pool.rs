use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use russh::client;
use russh_keys::load_secret_key;
use tokio::sync::Mutex;

use crate::config::SshConfig;
use crate::serial::protocol::{Request, Response};

struct ClientHandler;

#[async_trait::async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh_keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

pub struct SshConnection {
    handle: client::Handle<ClientHandler>,
    host: String,
}

impl SshConnection {
    pub async fn connect(host: &str, config: &SshConfig) -> Result<Self, String> {
        let client_config = Arc::new(client::Config {
            inactivity_timeout: Some(std::time::Duration::from_millis(config.timeout_ms)),
            ..<_>::default()
        });

        let mut handle = client::connect(client_config, (host, config.port), ClientHandler)
            .await
            .map_err(|e| format!("SSH connect to {} failed: {}", host, e))?;

        let key = load_secret_key(&config.key, None)
            .map_err(|e| format!("Load key {} failed: {}", config.key, e))?;

        let auth_res = handle
            .authenticate_publickey(&config.user, Arc::new(key))
            .await
            .map_err(|e| format!("Auth failed: {}", e))?;

        if !auth_res {
            return Err(format!("SSH auth rejected for {}", host));
        }

        eprintln!("[ssh] Connected to {}", host);

        Ok(SshConnection {
            handle,
            host: host.to_string(),
        })
    }

    pub async fn exec(&mut self, cmd: &str) -> Result<String, String> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Channel open failed: {}", e))?;

        channel
            .exec(true, cmd)
            .await
            .map_err(|e| format!("Exec '{}' failed: {}", cmd, e))?;

        let mut output = Vec::new();

        loop {
            match channel.wait().await {
                Some(russh::ChannelMsg::Data { data }) => {
                    output.extend_from_slice(&data);
                }
                Some(russh::ChannelMsg::ExitStatus { exit_status }) => {
                    if exit_status != 0 {
                        eprintln!("[ssh] command exited with status {}", exit_status);
                    }
                    break;
                }
                None => break,
                _ => {}
            }
        }

        Ok(String::from_utf8_lossy(&output).trim().to_string())
    }

    pub async fn is_healthy(&mut self) -> bool {
        self.exec("echo ok")
            .await
            .map(|o| o.trim() == "ok")
            .unwrap_or(false)
    }
}

pub struct SshPool {
    host: String,
    config: SshConfig,
    conn: Arc<Mutex<Option<SshConnection>>>,
    healthy: Arc<AtomicBool>,
    checked: Arc<AtomicBool>,
}

impl SshPool {
    pub fn new(host: String, config: SshConfig) -> Self {
        SshPool {
            host,
            config,
            conn: Arc::new(Mutex::new(None)),
            healthy: Arc::new(AtomicBool::new(false)),
            checked: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Relaxed)
    }

    pub fn should_try(&self) -> bool {
        self.is_healthy() || !self.checked.load(Ordering::Relaxed)
    }

    async fn ensure_connected(&self) -> Result<(), String> {
        let mut guard = self.conn.lock().await;
        if guard.is_none() {
            self.checked.store(true, Ordering::Relaxed);
            match SshConnection::connect(&self.host, &self.config).await {
                Ok(conn) => {
                    self.healthy.store(true, Ordering::Relaxed);
                    *guard = Some(conn);
                }
                Err(e) => {
                    self.healthy.store(false, Ordering::Relaxed);
                    return Err(e);
                }
            }
        }
        Ok(())
    }

    pub async fn exec(&self, cmd: &str) -> Result<String, String> {
        self.ensure_connected().await?;

        let mut guard = self.conn.lock().await;
        let conn = guard.as_mut().unwrap();

        match conn.exec(cmd).await {
            Ok(output) => Ok(output),
            Err(e) => {
                eprintln!("[ssh] {} exec failed: {} — resetting", self.host, e);
                self.healthy.store(false, Ordering::Relaxed);
                *guard = None;
                Err(e)
            }
        }
    }

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        let cmd = self.req_to_cmd(&req);
        let output = self.exec(&cmd).await?;
        self.parse_output(req, output)
    }

    pub async fn check_health(&self) {
        self.checked.store(true, Ordering::Relaxed);
        match self.exec("echo ok").await {
            Ok(o) if o.trim() == "ok" => {
                self.healthy.store(true, Ordering::Relaxed);
                eprintln!("[ssh] {} healthy", self.host);
            }
            _ => {
                self.healthy.store(false, Ordering::Relaxed);
                eprintln!("[ssh] {} unhealthy — resetting", self.host);
                *self.conn.lock().await = None;
            }
        }
    }

    fn req_to_cmd(&self, req: &Request) -> String {
        match req {
            Request::GetCursor =>
                "python3 -c 'from Quartz import NSEvent; import json; p=NSEvent.mouseLocation(); print(json.dumps({\"type\":\"cursor_pos\",\"x\":round(p.x,1),\"y\":round(p.y,1)}))'".into(),

            Request::GetScreens =>
                "python3 -c 'from AppKit import NSScreen; import json; screens=[{\"id\":i,\"x\":int(s.frame().origin.x),\"y\":int(s.frame().origin.y),\"w\":int(s.frame().size.width),\"h\":int(s.frame().size.height)} for i,s in enumerate(NSScreen.screens())]; screens.sort(key=lambda s:s[\"x\"]); print(json.dumps({\"type\":\"screens\",\"layout\":screens}))'".into(),

            Request::GetClipboard => "pbpaste".into(),

            Request::GetActiveApp =>
                "osascript -e 'tell application \"System Events\" to get name of first process where it is frontmost'".into(),

            Request::RunCommand { cmd } => cmd.clone(),
        }
    }

    fn parse_output(&self, req: Request, output: String) -> Result<Response, String> {
        match req {
            Request::GetCursor => {
                let v: serde_json::Value =
                    serde_json::from_str(&output).map_err(|e| format!("Parse cursor: {}", e))?;
                Ok(Response::CursorPos {
                    x: v["x"].as_f64().unwrap_or(0.0),
                    y: v["y"].as_f64().unwrap_or(0.0),
                })
            }

            Request::GetScreens => {
                let v: serde_json::Value =
                    serde_json::from_str(&output).map_err(|e| format!("Parse screens: {}", e))?;
                let layout = v["layout"]
                    .as_array()
                    .ok_or("No layout field")?
                    .iter()
                    .map(|s| crate::serial::protocol::Screen {
                        id: s["id"].as_u64().unwrap_or(0) as u32,
                        x: s["x"].as_i64().unwrap_or(0) as i32,
                        y: s["y"].as_i64().unwrap_or(0) as i32,
                        w: s["w"].as_u64().unwrap_or(0) as u32,
                        h: s["h"].as_u64().unwrap_or(0) as u32,
                    })
                    .collect();
                Ok(Response::Screens { layout })
            }

            Request::GetClipboard => Ok(Response::Clipboard { text: output }),

            Request::GetActiveApp => Ok(Response::ActiveApp {
                name: output,
                window: String::new(),
            }),

            Request::RunCommand { .. } => Ok(Response::CommandResult {
                output,
                error: String::new(),
            }),
        }
    }
}
