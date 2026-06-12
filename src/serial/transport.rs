use std::collections::HashMap;
use std::sync::Arc;
use std::os::unix::io::AsRawFd;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tokio::fs::OpenOptions;

use crate::serial::protocol::{
    Request, Response, RequestEnvelope, ResponseEnvelope
};

const SERIAL_DEVICE: &str = "/dev/ttyGS0";
const TIMEOUT_MS: u64 = 3000;
const CURSOR_TIMEOUT_MS: u64 = 1000;  // cursor is fast, fail quickly
const MAX_RETRIES: u32 = 2;

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

fn timeout_for(req: &Request) -> u64 {
    match req {
        Request::GetCursor => CURSOR_TIMEOUT_MS,
        _                  => TIMEOUT_MS,
    }
}

pub struct SerialTransport {
    writer:  Arc<Mutex<tokio::fs::File>>,
    pending: PendingMap,
}

impl SerialTransport {
    pub async fn new() -> Result<Self, std::io::Error> {
        let writer = OpenOptions::new()
            .write(true)
            .open(SERIAL_DEVICE)
            .await?;
        set_raw_mode(&writer);

        let reader = OpenOptions::new()
            .read(true)
            .open(SERIAL_DEVICE)
            .await?;
        set_raw_mode(&reader);

        eprintln!("[serial] Opened {}", SERIAL_DEVICE);

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));

        let transport = SerialTransport {
            writer:  Arc::new(Mutex::new(writer)),
            pending: pending.clone(),
        };

        tokio::spawn(Self::read_loop(reader, pending));

        Ok(transport)
    }

    async fn read_loop(
        file: tokio::fs::File,
        pending: PendingMap,
    ) {
        let mut reader = BufReader::new(file);
        let mut line   = String::new();

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
                    if trimmed.is_empty() { continue; }

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
                            eprintln!("[serial] Parse error: {} — raw bytes: {:?}",
                                e, line.as_bytes());
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
    async fn send_once(
        &self,
        req: &Request,
        timeout_ms: u64,
    ) -> Result<Response, String> {
        let id = uuid::Uuid::new_v4().to_string();

        let envelope = RequestEnvelope {
            id:      id.clone(),
            request: req.clone(),
        };

        let json = serde_json::to_string(&envelope)
            .map_err(|e| format!("Serialize error: {}", e))?
            + "\n";

        eprintln!("[serial] → ({} bytes) {}", json.len(), json.trim());

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), tx);

        self.writer.lock().await
            .write_all(json.as_bytes()).await
            .map_err(|e| {
                format!("Write error: {}", e)
            })?;

        match timeout(Duration::from_millis(timeout_ms), rx).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(_))       => Err("Channel closed".into()),
            Err(_)           => {
                self.pending.lock().await.remove(&id);
                Err(format!("Timeout after {}ms", timeout_ms))
            }
        }
    }

    // Public request with automatic retry
    pub async fn request(&self, req: Request) -> Result<Response, String> {
        let timeout_ms = timeout_for(&req);
        let mut last_err = String::new();

        for attempt in 0..=MAX_RETRIES {
            if attempt > 0 {
                eprintln!("[serial] Retry {}/{} for {:?}", attempt, MAX_RETRIES, req);
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

        Err(format!("Failed after {} attempts: {}", MAX_RETRIES + 1, last_err))
    }

    // Direct request with custom timeout — for callers that need control
    pub async fn request_timeout(
        &self,
        req: Request,
        timeout_ms: u64,
    ) -> Result<Response, String> {
        self.send_once(&req, timeout_ms).await
    }
}