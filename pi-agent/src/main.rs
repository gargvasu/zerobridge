#![allow(dead_code)]
#![allow(unused_variables)]

mod bridge;
mod config;
mod daemon;
mod hid;
mod ipc;
mod screen;
mod serial;

use config::Config;
use daemon::Daemon;

#[tokio::main]
async fn main() {
    eprintln!("[zerobridge] Starting pi-agent v{}", env!("CARGO_PKG_VERSION"));

    let config = Config::load().unwrap_or_else(|e| {
        eprintln!("[zerobridge] Config failed: {e} — using defaults");
        Config::default()
    });

    eprintln!("[zerobridge] SSH user:   {}", config.ssh.user);
    eprintln!("[zerobridge] hosts.usb:  {}", config.hosts.usb);
    eprintln!("[zerobridge] hosts.wifi: {}", config.hosts.wifi);
    eprintln!("[zerobridge] serial:     {}", config.serial.device);

    let daemon = Daemon::new(config).await.unwrap_or_else(|e| {
        eprintln!("[zerobridge] Fatal: {e}");
        std::process::exit(1);
    });

    eprintln!("[zerobridge] All subsystems ready");

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    tokio::select! {
        result = daemon.run(shutdown_rx) => {
            if let Err(e) = result {
                eprintln!("[zerobridge] Daemon error: {e}");
                std::process::exit(1);
            }
        }
        sig = wait_for_signal() => {
            eprintln!("[zerobridge] Received {sig} — shutting down");
            let _ = shutdown_tx.send(true);
            // Give in-flight handlers up to 3 s to finish
            tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
        }
    }

    let sock = std::env::var("ZB_SOCK").unwrap_or_else(|_| "/tmp/zerobridge.sock".to_string());
    let _ = std::fs::remove_file(&sock);
    eprintln!("[zerobridge] Shutdown complete");
    std::process::exit(0);
}

async fn wait_for_signal() -> &'static str {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = signal(SignalKind::terminate()).expect("SIGTERM handler");
    let mut sighup  = signal(SignalKind::hangup()).expect("SIGHUP handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => "SIGINT",
        _ = sigterm.recv()          => "SIGTERM",
        _ = sighup.recv()           => "SIGHUP",
    }
}