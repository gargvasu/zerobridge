use std::collections::HashMap;
use std::os::unix::io::AsRawFd;
use std::sync::Arc;
use tokio::fs::OpenOptions;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};

use crate::serial::protocol::{Request, RequestEnvelope, Response, ResponseEnvelope};

use crate::config::SerialConfig;

type PendingMap = Arc<Mutex<HashMap<String, oneshot::Sender<Response>>>>;

fn set_raw_mode(file: &tokio::fs::File) {
    let fd = file.as_raw_fd();
    unsafe {
        let mut termios: libc::termios = std::mem::zeroed();
        libc::tcgetattr(fd, &mut termios);
        libc::cfmakeraw(&mut termios);
        libc::tcsetattr(fd, libc::TCSANOW, &termios);
    }
    eprintln!("[serial] Raw mode set on fd {}", fd);
}

pub struct SerialTransport {
    writer: Arc<Mutex<tokio::fs::File>>,
    pending: PendingMap,
    timeout_ms: u64,
    cursor_timeout_ms: u64,
    max_retries: u32,
}

impl SerialTransport {
    pub async fn new(config: &SerialConfig) -> Result<Self, std::io::Error> {
        let writer = OpenOptions::new().write(true).open(&config.device).await?;
        set_raw_mode(&writer);

        let reader = OpenOptions::new().read(true).open(&config.device).await?;
        set_raw_mode(&reader);

        eprintln!("[serial] Opened {}", &config.device);

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));

        let transport = SerialTransport {
            writer: Arc::new(Mutex::new(writer)),
            pending: pending.clone(),
            timeout_ms: config.timeout_ms,
            cursor_timeout_ms: config.cursor_timeout_ms,
            max_retries: config.max_retries,
        };

        tokio::spawn(Self::read_loop(reader, pending));

        Ok(transport)
    }

    fn timeout_for(&self, req: &Request) -> u64 {
        match req {
            Request::GetCursor => self.cursor_timeout_ms,
            _ => self.timeout_ms,
        }
    }

    async fn read_loop(file: tokio::fs::File, pending: PendingMap) {
        let mut reader = BufReader::new(file);
        let mut line = String::new();

        eprintln!("[serial] Reader loop started");

        loop {
            line.clear();
            match reader.read_line(&mut line).await {
                Ok(0) => {
                    eprintln!("[serial] EOF");
                    break;
                }
                Ok(n) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    eprintln!("[serial] ← ({} bytes) {}", n, trimmed);

                    match serde_json::from_str::<ResponseEnvelope>(trimmed) {
                        Ok(envelope) => {
                            let mut map = pending.lock().await;
                            if let Some(tx) = map.remove(&envelope.id) {
                                eprintln!("[serial] Matched id: {}", &envelope.id[..8]);
                                let _ = tx.send(envelope.response);
                            } else {
                                // Late response — already timed out, just log
                                eprintln!("[serial] Late/unknown id: {}", &envelope.id[..8]);
                            }
                        }
                        Err(e) => {
                            eprintln!(
                                "[serial] Parse error: {} — raw bytes: {:?}",
                                e,
                                line.as_bytes()
                            );
                        }
                    }
                }
                Err(e) => {
                    eprintln!("[serial] Read error: {}", e);
                    break;
                }
            }
        }
    }

    // Single request with configurable timeout
    async fn send_once(&self, req: &Request, timeout_ms: u64) -> Result<Response, String> {
        let id = uuid::Uuid::new_v4().to_string();

        let envelope = RequestEnvelope {
            id: id.clone(),
            request: req.clone(),
        };

        let json =
            serde_json::to_string(&envelope).map_err(|e| format!("Serialize error: {}", e))? + "\n";

        eprintln!("[serial] → ({} bytes) {}", json.len(), json.trim());

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), tx);

        self.writer
            .lock()
            .await
            .write_all(json.as_bytes())
            .await
            .map_err(|e| format!("Write error: {}", e))?;

        match timeout(Duration::from_millis(timeout_ms), rx).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(_)) => Err("Channel closed".into()),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(format!("Timeout after {}ms", timeout_ms))
            }
        }
    }

    // Public request with automatic retry
    pub async fn request(&self, req: Request) -> Result<Response, String> {
        let timeout_ms = self.timeout_for(&req);
        let mut last_err = String::new();

        for attempt in 0..=self.max_retries {
            if attempt > 0 {
                eprintln!(
                    "[serial] Retry {}/{} for {:?}",
                    attempt, self.max_retries, req
                );
                tokio::time::sleep(Duration::from_millis(50)).await;
            }

            match self.send_once(&req, timeout_ms).await {
                Ok(resp) => {
                    if attempt > 0 {
                        eprintln!("[serial] Succeeded on retry {}", attempt);
                    }
                    return Ok(resp);
                }
                Err(e) => {
                    eprintln!("[serial] Attempt {} failed: {}", attempt + 1, e);
                    last_err = e;
                }
            }
        }

        Err(format!(
            "Failed after {} attempts: {}",
            self.max_retries + 1,
            last_err
        ))
    }

    // Direct request with custom timeout — for callers that need control
    pub async fn request_timeout(&self, req: Request, timeout_ms: u64) -> Result<Response, String> {
        self.send_once(&req, timeout_ms).await
    }
}
