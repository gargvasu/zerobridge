use ssh2::Session;
use std::io::Read;
use std::net::TcpStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::serial::protocol::{Request, Response};

use crate::config::SshConfig;

pub struct SshPool {
    host: String,
    config: SshConfig,
    conn: Arc<Mutex<Option<SshConnection>>>,
    healthy: Arc<AtomicBool>,
}

pub struct SshConnection {
    session: Session,
    host: String,
}

impl SshConnection {
    pub fn connect(host: &str, config: &SshConfig) -> Result<Self, String> {
        let tcp = TcpStream::connect(format!("{}:{}", host, config.port))
            .map_err(|e| format!("TCP connect failed: {}", e))?;

        let timeout = std::time::Duration::from_millis(config.timeout_ms);
        tcp.set_read_timeout(Some(timeout))
            .map_err(|e| format!("Set timeout failed: {}", e))?;
        tcp.set_write_timeout(Some(timeout))
            .map_err(|e| format!("Set timeout failed: {}", e))?;

        let mut session = Session::new().map_err(|e| format!("Session create failed: {}", e))?;

        session.set_tcp_stream(tcp);
        session
            .handshake()
            .map_err(|e| format!("Handshake failed: {}", e))?;

        session
            .userauth_pubkey_file(&config.user, None, Path::new(&config.key), None)
            .map_err(|e| format!("Auth failed: {}", e))?;

        if !session.authenticated() {
            return Err("SSH authentication failed".into());
        }

        eprintln!("[ssh] Connected to {}", host);

        Ok(SshConnection {
            session,
            host: host.to_string(),
        })
    }

    pub fn exec(&mut self, cmd: &str) -> Result<String, String> {
        let mut channel = self
            .session
            .channel_session()
            .map_err(|e| format!("Channel open failed: {}", e))?;

        channel
            .exec(cmd)
            .map_err(|e| format!("Exec failed: {}", e))?;

        let mut output = String::new();
        channel
            .read_to_string(&mut output)
            .map_err(|e| format!("Read failed: {}", e))?;

        channel
            .wait_close()
            .map_err(|e| format!("Wait close failed: {}", e))?;

        Ok(output.trim().to_string())
    }

    pub fn is_healthy(&mut self) -> bool {
        self.exec("echo ok")
            .map(|o| o.trim() == "ok")
            .unwrap_or(false)
    }
}

impl SshPool {
    pub fn new(host: String, config: SshConfig) -> Self {
        SshPool {
            host,
            config,
            conn: Arc::new(Mutex::new(None)),
            healthy: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Relaxed)
    }

    // Get or create connection
    async fn get_conn(&self) -> Result<(), String> {
        let mut guard = self.conn.lock().await;
        if guard.is_none() {
            match SshConnection::connect(&self.host, &self.config) {
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
        self.get_conn().await?;

        let mut guard = self.conn.lock().await;
        let conn = guard.as_mut().unwrap();

        match conn.exec(cmd) {
            Ok(output) => Ok(output),
            Err(e) => {
                // Connection broken — reset for next attempt
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
        match self.exec("echo ok").await {
            Ok(o) if o.trim() == "ok" => {
                self.healthy.store(true, Ordering::Relaxed);
                eprintln!("[ssh] {} healthy", self.host);
            }
            _ => {
                self.healthy.store(false, Ordering::Relaxed);
                eprintln!("[ssh] {} unhealthy", self.host);
                // Reset connection
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

            Request::GetClipboard =>
                "pbpaste".into(),

            Request::GetActiveApp =>
                "osascript -e 'tell application \"System Events\" to get name of first process where it is frontmost'".into(),

            Request::RunCommand { cmd } =>
                cmd.clone(),
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
