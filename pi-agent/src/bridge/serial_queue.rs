use tokio::sync::{mpsc, oneshot};
use crate::serial::protocol::{Request, Response};
use crate::serial::transport::SerialTransport;

use crate::config::SerialConfig;

struct QueuedRequest {
    req:   Request,
    reply: oneshot::Sender<Result<Response, String>>,
}

pub struct SerialQueue {
    tx: mpsc::Sender<QueuedRequest>,
}

impl SerialQueue {
    pub async fn new(config: &SerialConfig) -> Result<Self, std::io::Error> {
        let transport = SerialTransport::new(config).await?;
        let (tx, rx) = mpsc::channel::<QueuedRequest>(32);

        tokio::spawn(Self::worker(rx, transport));

        Ok(SerialQueue { tx })
    }

    async fn worker(
        mut rx: mpsc::Receiver<QueuedRequest>,
        transport: SerialTransport,
    ) {
        eprintln!("[serial_queue] Worker started");
        while let Some(item) = rx.recv().await {
            let result = transport.request(item.req).await;
            let _ = item.reply.send(result);
        }
        eprintln!("[serial_queue] Worker stopped");
    }

    pub async fn request(&self, req: Request) -> Result<Response, String> {
        let (tx, rx) = oneshot::channel();

        self.tx.send(QueuedRequest { req, reply: tx }).await
            .map_err(|_| "Serial queue closed".to_string())?;

        rx.await.map_err(|_| "Reply channel closed".to_string())?
    }
}