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

    // Handle SIGTERM and SIGINT gracefully
    let config = Config::load().unwrap_or_else(|e| {
        eprintln!("[zerobridge] Config failed: {} — using defaults", e);
        Config::default()
    });

    eprintln!("[zerobridge] SSH user:   {}", config.ssh.user);
    eprintln!("[zerobridge] hosts.usb:  {}", config.hosts.usb);
    eprintln!("[zerobridge] hosts.wifi: {}", config.hosts.wifi);
    eprintln!("[zerobridge] serial:     {}", config.serial.device);

    let daemon = Daemon::new(config).await
        .unwrap_or_else(|e| {
            eprintln!("[zerobridge] Fatal: {}", e);
            std::process::exit(1);
        });

    eprintln!("[zerobridge] All subsystems ready");

    // Handle shutdown signals
    tokio::select! {
        result = daemon.run() => {
            if let Err(e) = result {
                eprintln!("[zerobridge] Daemon error: {}", e);
                std::process::exit(1);
            }
        }
        _ = tokio::signal::ctrl_c() => {
            eprintln!("[zerobridge] Received SIGINT — shutting down");
        }
    }

    // Cleanup
    let sock = std::env::var("ZB_SOCK").unwrap_or_else(|_| "/tmp/zerobridge.sock".to_string());
    let _ = std::fs::remove_file(&sock);
    eprintln!("[zerobridge] Shutdown complete");
}