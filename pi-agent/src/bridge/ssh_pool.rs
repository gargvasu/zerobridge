use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use russh::client;
use russh_keys::load_secret_key;
use tokio::sync::Mutex;

use crate::config::SshConfig;
use crate::serial::protocol::{Request, Response};

// ── russh client handler ───────────────────────────

struct ClientHandler;

#[async_trait::async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh_keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true) // Trust USB tether — private network
    }
}

// ── SSH Connection ─────────────────────────────────

pub struct SshConnection {
    handle:     client::Handle<ClientHandler>,
    host:       String,
    shell:      Option<russh::Channel<russh::client::Msg>>,
    seq:        u64,
    timeout_ms: u64,
}

impl SshConnection {
    pub async fn connect(host: &str, config: &SshConfig) -> Result<Self, String> {
        let client_config = Arc::new(client::Config {
            inactivity_timeout: Some(std::time::Duration::from_millis(config.timeout_ms)),
            ..<_>::default()
        });

        let mut handle = client::connect(client_config, (host, config.port), ClientHandler)
            .await
            .map_err(|e| format!("SSH connect to {host} failed: {e}"))?;

        let key = load_secret_key(&config.key, None)
            .map_err(|e| format!("Load key {} failed: {e}", config.key))?;

        let auth_res = handle
            .authenticate_publickey(&config.user, Arc::new(key))
            .await
            .map_err(|e| format!("Auth failed: {e}"))?;

        if !auth_res {
            return Err(format!("SSH auth rejected for {host}"));
        }

        eprintln!("[ssh] ✅ Connected to {host}");

        Ok(SshConnection {
            handle,
            host: host.to_string(),
            shell: None,
            seq: 0,
            timeout_ms: config.timeout_ms,
        })
    }

    // Open a persistent shell channel (no PTY — clean stdout, no prompts/echo).
    async fn ensure_shell(&mut self) -> Result<(), String> {
        if self.shell.is_some() {
            return Ok(());
        }
        let ch = self.handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Shell channel open failed: {e}"))?;
        ch.request_shell(true)
            .await
            .map_err(|e| format!("Shell request failed: {e}"))?;
        self.shell = Some(ch);
        eprintln!("[ssh] {} persistent shell ready", self.host);
        Ok(())
    }

    pub async fn exec(&mut self, cmd: &str) -> Result<String, String> {
        self.ensure_shell().await?;

        let marker = format!("__ZB{}__", self.seq);
        self.seq += 1;

        // Wrap command: run it, then echo the unique marker so we know where output ends.
        // 2>&1 merges stderr into stdout so we capture error messages too.
        let wrapped = format!("{{ {cmd}; }} 2>&1; echo '{marker}'\n");

        let ch = self.shell.as_mut().expect("ensure_shell guarantees Some");
        ch.data(wrapped.as_bytes())
            .await
            .map_err(|e| {
                self.shell = None; // channel dead, will reopen next call
                format!("Shell write failed: {e}")
            })?;

        // Read stdout until marker appears, with a hard timeout.
        let timeout = std::time::Duration::from_millis(self.timeout_ms);
        match tokio::time::timeout(timeout, Self::read_until_marker(
            self.shell.as_mut().expect("still open"),
            &marker,
        ))
        .await
        {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(e)) => {
                self.shell = None;
                Err(e)
            }
            Err(_) => {
                eprintln!("[ssh] {} command timed out — resetting shell", self.host);
                self.shell = None;
                Err("SSH command timed out".to_string())
            }
        }
    }

    async fn read_until_marker(
        ch: &mut russh::Channel<russh::client::Msg>,
        marker: &str,
    ) -> Result<String, String> {
        let mut output = String::new();
        loop {
            match ch.wait().await {
                Some(russh::ChannelMsg::Data { data }) => {
                    output.push_str(&String::from_utf8_lossy(&data));
                    if let Some(pos) = output.find(marker) {
                        output.truncate(pos);
                        return Ok(output.trim().to_string());
                    }
                }
                Some(russh::ChannelMsg::ExtendedData { data, .. }) => {
                    // stderr on extended channel — include in output
                    output.push_str(&String::from_utf8_lossy(&data));
                }
                None
                | Some(russh::ChannelMsg::Eof)
                | Some(russh::ChannelMsg::Close) => {
                    return Err("Shell channel closed unexpectedly".to_string());
                }
                _ => {}
            }
        }
    }
}

// ── SSH Pool ───────────────────────────────────────

pub struct SshPool {
    host:    String,
    config:  SshConfig,
    conn:    Arc<Mutex<Option<SshConnection>>>,
    healthy: Arc<AtomicBool>,
    checked: Arc<AtomicBool>,
}

impl SshPool {
    pub fn new(host: String, config: SshConfig) -> Self {
        SshPool {
            host,
            config,
            conn:    Arc::new(Mutex::new(None)),
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
        let conn = guard.as_mut().expect("ensure_connected guarantees Some");

        match conn.exec(cmd).await {
            Ok(output) => Ok(output),
            Err(e) if e.contains("Channel") => {
                // Channel error — session likely stale, reconnect and retry
                eprintln!("[ssh] {} channel error — reconnecting: {e}", self.host);
                self.healthy.store(false, Ordering::Relaxed);
                *guard = None;
                drop(guard);

                self.ensure_connected().await?;
                let mut guard = self.conn.lock().await;
                let conn = guard.as_mut().expect("just reconnected");
                conn.exec(cmd).await
            }
            Err(e) => {
                eprintln!("[ssh] {} exec failed: {e} — resetting", self.host);
                self.healthy.store(false, Ordering::Relaxed);
                *guard = None;
                Err(e)
            }
        }
    }

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        let cmd = self.req_to_cmd(&req);
        eprintln!("[ssh] → {} : {cmd}", self.host);
        let output = self.exec(&cmd).await?;
        eprintln!("[ssh] ← {} bytes", output.len());
        self.parse_output(req, output)
    }

    pub async fn check_health(&self) {
        self.checked.store(true, Ordering::Relaxed);

        // If already healthy, probe before dropping
        if self.is_healthy() {
            match self.exec("echo ok").await {
                Ok(o) if o.trim() == "ok" => {
                    eprintln!("[ssh] {} ✅ healthy (probe)", self.host);
                    return;
                }
                _ => {
                    eprintln!("[ssh] {} probe failed — reconnecting", self.host);
                }
            }
        }

        // Drop and reconnect
        {
            let mut guard = self.conn.lock().await;
            *guard = None;
            self.healthy.store(false, Ordering::Relaxed);
        }

        match self.ensure_connected().await {
            Ok(()) => match self.exec("echo ok").await {
                Ok(o) if o.trim() == "ok" => {
                    self.healthy.store(true, Ordering::Relaxed);
                    eprintln!("[ssh] {} ✅ healthy", self.host);
                }
                _ => {
                    self.healthy.store(false, Ordering::Relaxed);
                    eprintln!("[ssh] {} ❌ unhealthy", self.host);
                    *self.conn.lock().await = None;
                }
            },
            Err(e) => {
                eprintln!("[ssh] {} ❌ connect failed: {e}", self.host);
            }
        }
    }

    // ── Command mapping ────────────────────────────

    fn req_to_cmd(&self, req: &Request) -> String {
        match req {
            Request::GetCursor       => "~/bin/zb-agent cursor".into(),
            Request::GetScreens      => "~/bin/zb-agent screens".into(),
            Request::GetClipboard    => "~/bin/zb-agent clipboard".into(),
            Request::GetActiveApp    => "~/bin/zb-agent app".into(),
            Request::GetWindows      => "~/bin/zb-agent windows".into(),

            Request::RunCommand { cmd } => {
                let escaped = cmd.replace('\'', "'\\''");
                format!("~/bin/zb-agent run '{escaped}'")
            }
            Request::GetWindowForApp { app } => {
                format!("~/bin/zb-agent window '{}'", app.replace('\'', "'\\''"))
            }
            Request::FocusApp { app } => {
                format!("~/bin/zb-agent focus '{}'", app.replace('\'', "'\\''"))
            }
        }
    }

    // ── Response parsing ───────────────────────────

    fn parse_output(&self, req: Request, output: String) -> Result<Response, String> {
        match req {
            Request::GetCursor => {
                let v: serde_json::Value = serde_json::from_str(&output)
                    .map_err(|e| format!("Parse cursor failed: {e} — raw: {}", &output[..output.len().min(100)]))?;
                Ok(Response::CursorPos {
                    x: v["x"].as_f64().unwrap_or(0.0),
                    y: v["y"].as_f64().unwrap_or(0.0),
                })
            }

            Request::GetScreens => {
                let v: serde_json::Value = serde_json::from_str(&output)
                    .map_err(|e| format!("Parse screens failed: {e} — raw: {}", &output[..output.len().min(100)]))?;
                let layout = v["layout"].as_array()
                    .ok_or("Missing layout field")?
                    .iter()
                    .map(|s| crate::serial::protocol::Screen {
                        id: s["id"].as_u64().unwrap_or(0) as u32,
                        x:  s["x"].as_i64().unwrap_or(0) as i32,
                        y:  s["y"].as_i64().unwrap_or(0) as i32,
                        w:  s["w"].as_u64().unwrap_or(0) as u32,
                        h:  s["h"].as_u64().unwrap_or(0) as u32,
                    })
                    .collect();
                Ok(Response::Screens { layout })
            }

            Request::GetClipboard => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&output) {
                    Ok(Response::Clipboard {
                        text: v["text"].as_str().unwrap_or(&output).to_string(),
                    })
                } else {
                    Ok(Response::Clipboard { text: output })
                }
            }

            Request::GetActiveApp => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&output) {
                    Ok(Response::ActiveApp {
                        name:   v["name"].as_str().unwrap_or("").to_string(),
                        window: v["bundle"].as_str().unwrap_or("").to_string(),
                    })
                } else {
                    Ok(Response::ActiveApp { name: output, window: String::new() })
                }
            }

            Request::RunCommand { .. } => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&output) {
                    Ok(Response::CommandResult {
                        output: v["output"].as_str().unwrap_or("").to_string(),
                        error:  v["error"].as_str().unwrap_or("").to_string(),
                    })
                } else {
                    Ok(Response::CommandResult { output, error: String::new() })
                }
            }

            Request::GetWindows => {
                let v: serde_json::Value = serde_json::from_str(&output)
                    .map_err(|e| format!("Parse windows failed: {e}"))?;
                Ok(Response::Windows {
                    list: v["list"].as_array()
                        .ok_or("Missing list field")?
                        .iter()
                        .map(|w| crate::ipc::WindowInfo {
                            id:    w["id"].as_u64().unwrap_or(0) as u32,
                            pid:   w["pid"].as_u64().unwrap_or(0) as u32,
                            app:   w["app"].as_str().unwrap_or("").to_string(),
                            title: w["title"].as_str().unwrap_or("").to_string(),
                            x:     w["x"].as_i64().unwrap_or(0) as i32,
                            y:     w["y"].as_i64().unwrap_or(0) as i32,
                            w:     w["w"].as_u64().unwrap_or(0) as u32,
                            h:     w["h"].as_u64().unwrap_or(0) as u32,
                        })
                        .collect()
                })
            }

            Request::GetWindowForApp { .. } => {
                let v: serde_json::Value = serde_json::from_str(&output)
                    .map_err(|e| format!("Parse window failed: {e}"))?;
                Ok(Response::Window {
                    info: crate::ipc::WindowInfo {
                        id:    v["id"].as_u64().unwrap_or(0) as u32,
                        pid:   0,
                        app:   v["app"].as_str().unwrap_or("").to_string(),
                        title: v["title"].as_str().unwrap_or("").to_string(),
                        x:     v["x"].as_i64().unwrap_or(0) as i32,
                        y:     v["y"].as_i64().unwrap_or(0) as i32,
                        w:     v["w"].as_u64().unwrap_or(0) as u32,
                        h:     v["h"].as_u64().unwrap_or(0) as u32,
                    }
                })
            }

            Request::FocusApp { app } => {
                let v: serde_json::Value = serde_json::from_str(&output)
                    .map_err(|e| format!("Parse focus failed: {e}"))?;
                Ok(Response::FocusResult {
                    app,
                    success: v["success"].as_bool().unwrap_or(false),
                })
            }
        }
    }
}
