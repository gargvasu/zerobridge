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
    println!("ZeroBridge daemon starting...");

    let config = Config::load().unwrap_or_else(|e| {
        eprintln!("[config] Failed: {} — using defaults", e);
        Config::default()
    });

    eprintln!("[config] SSH user:   {}", config.ssh.user);
    eprintln!("[config] hosts.usb:  {}", config.hosts.usb);
    eprintln!("[config] hosts.wifi: {}", config.hosts.wifi);
    eprintln!("[config] serial:     {}", config.serial.device);

    let daemon = Daemon::new(config).await
        .expect("Failed to init daemon");

    eprintln!("[daemon] All subsystems ready");

    // Run forever
    if let Err(e) = daemon.run().await {
        eprintln!("[daemon] Fatal error: {}", e);
        std::process::exit(1);
    }
}