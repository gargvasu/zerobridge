use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::Message;

use crate::config::WebSocketConfig;
use crate::serial::protocol::{Request, RequestEnvelope, Response, ResponseEnvelope};

type PendingMap = Arc<Mutex<HashMap<String, oneshot::Sender<Response>>>>;
type WsSink = Arc<Mutex<futures_util::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    Message,
>>>;

pub struct WsPool {
    url:        String,
    timeout_ms: u64,
    sink:       Arc<Mutex<Option<WsSink>>>,
    pending:    PendingMap,
    healthy:    Arc<AtomicBool>,
    checked:    Arc<AtomicBool>,
}

impl WsPool {
    pub fn new(config: WebSocketConfig) -> Self {
        WsPool {
            url:        config.url,
            timeout_ms: config.timeout_ms,
            sink:       Arc::new(Mutex::new(None)),
            pending:    Arc::new(Mutex::new(HashMap::new())),
            healthy:    Arc::new(AtomicBool::new(false)),
            checked:    Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Relaxed)
    }

    pub fn should_try(&self) -> bool {
        self.is_healthy() || !self.checked.load(Ordering::Relaxed)
    }

    async fn connect(&self) -> Result<(), String> {
        self.checked.store(true, Ordering::Relaxed);

        eprintln!("[ws] Connecting to {}...", self.url);

        let (ws_stream, _) = tokio_tungstenite::connect_async(&self.url)
            .await
            .map_err(|e| format!("WebSocket connect failed: {e}"))?;

        let (write, read) = ws_stream.split();
        let ws_sink: WsSink = Arc::new(Mutex::new(write));

        {
            let mut guard = self.sink.lock().await;
            *guard = Some(ws_sink.clone());
        }

        self.healthy.store(true, Ordering::Relaxed);
        eprintln!("[ws] ✅ Connected to {}", self.url);

        let pending  = self.pending.clone();
        let healthy  = self.healthy.clone();
        let sink_ref = self.sink.clone();

        tokio::spawn(async move {
            Self::read_loop(read, pending, healthy, sink_ref).await;
        });

        Ok(())
    }

    async fn read_loop(
        mut read: futures_util::stream::SplitStream<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
        >,
        pending: PendingMap,
        healthy: Arc<AtomicBool>,
        sink: Arc<Mutex<Option<WsSink>>>,
    ) {
        eprintln!("[ws] Read loop started");

        while let Some(msg) = read.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    eprintln!("[ws] ← ({} bytes) {}", text.len(), &text[..text.len().min(120)]);

                    match serde_json::from_str::<ResponseEnvelope>(&text) {
                        Ok(envelope) => {
                            let mut map = pending.lock().await;
                            if let Some(tx) = map.remove(&envelope.id) {
                                eprintln!("[ws] Matched id: {}", &envelope.id[..envelope.id.len().min(8)]);
                                let _ = tx.send(envelope.response);
                            } else {
                                eprintln!("[ws] Late/unknown id: {}", &envelope.id[..envelope.id.len().min(8)]);
                            }
                        }
                        Err(e) => {
                            eprintln!("[ws] Parse error: {e} — raw: {}", &text[..text.len().min(100)]);
                        }
                    }
                }
                Ok(Message::Close(_)) => {
                    eprintln!("[ws] Connection closed by server");
                    break;
                }
                Ok(Message::Ping(data)) => {
                    if let Some(ws_sink) = &*sink.lock().await {
                        let _ = ws_sink.lock().await.send(Message::Pong(data)).await;
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    eprintln!("[ws] Read error: {e}");
                    break;
                }
            }
        }

        eprintln!("[ws] Read loop ended — marking unhealthy");
        healthy.store(false, Ordering::Relaxed);
        *sink.lock().await = None;
    }

    async fn ensure_connected(&self) -> Result<(), String> {
        let guard = self.sink.lock().await;
        if guard.is_some() {
            return Ok(());
        }
        drop(guard);
        self.connect().await
    }

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        self.ensure_connected().await?;

        let id = uuid::Uuid::new_v4().to_string();

        let envelope = RequestEnvelope { id: id.clone(), request: req };

        let json = serde_json::to_string(&envelope)
            .map_err(|e| format!("Serialize error: {e}"))?;

        eprintln!("[ws] → ({} bytes) {}", json.len(), &json[..json.len().min(120)]);

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), tx);

        {
            let guard = self.sink.lock().await;
            if let Some(ws_sink) = &*guard {
                if let Err(e) = ws_sink.lock().await.send(Message::Text(json)).await {
                    self.healthy.store(false, Ordering::Relaxed);
                    self.pending.lock().await.remove(&id);
                    return Err(format!("WebSocket send failed: {e}"));
                }
            } else {
                self.pending.lock().await.remove(&id);
                return Err("WebSocket not connected".into());
            }
        }

        match timeout(Duration::from_millis(self.timeout_ms), rx).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(_)) => {
                self.pending.lock().await.remove(&id);
                Err("Response channel closed".into())
            }
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(format!("WebSocket timeout after {}ms", self.timeout_ms))
            }
        }
    }

    pub async fn check_health(&self) {
        self.checked.store(true, Ordering::Relaxed);

        // If already healthy, probe without dropping the connection
        if self.is_healthy() {
            match self.request(Request::GetCursor).await {
                Ok(_) => {
                    eprintln!("[ws] {} ✅ healthy (probe)", self.url);
                    return;
                }
                Err(e) => {
                    eprintln!("[ws] {} probe failed: {e} — reconnecting", self.url);
                }
            }
        }

        // Drop and reconnect
        {
            let mut guard = self.sink.lock().await;
            *guard = None;
            self.healthy.store(false, Ordering::Relaxed);
        }

        match self.connect().await {
            Ok(()) => match self.request(Request::GetCursor).await {
                Ok(_) => {
                    self.healthy.store(true, Ordering::Relaxed);
                    eprintln!("[ws] {} ✅ healthy", self.url);
                }
                Err(e) => {
                    self.healthy.store(false, Ordering::Relaxed);
                    eprintln!("[ws] {} ❌ unhealthy: {e}", self.url);
                    *self.sink.lock().await = None;
                }
            },
            Err(e) => {
                eprintln!("[ws] {} ❌ connect failed: {e}", self.url);
            }
        }
    }
}
