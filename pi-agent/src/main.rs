#![allow(dead_code)]
#![allow(unused_variables)]

mod hid;
mod serial;
mod bridge;
mod screen;

use bridge::mac_bridge::MacBridge;
use serial::protocol::Request;
use screen::ScreenLayout;
use tokio::time::{sleep, Duration};

#[tokio::main]
async fn main() {
    println!("ZeroBridge — MacBridge Test");

    println!("Initialising bridge...");
    let bridge = MacBridge::new().await
        .expect("Failed to init MacBridge");

    sleep(Duration::from_millis(200)).await;

    println!("Requesting screens...");
    match bridge.request(Request::GetScreens).await {
        Ok(serial::protocol::Response::Screens { layout }) => {
            let screen_layout = ScreenLayout::from_raw(layout);
            screen_layout.print_layout();
        }
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    println!("Requesting cursor...");
    match bridge.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) =>
            println!("✅ Cursor: ({}, {})", x, y),
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    println!("Requesting clipboard via SSH...");
    match bridge.request(Request::GetClipboard).await {
        Ok(serial::protocol::Response::Clipboard { text }) =>
            println!("✅ Clipboard: {} chars", text.len()),
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    println!("Requesting active app...");
    match bridge.request(Request::GetActiveApp).await {
        Ok(serial::protocol::Response::ActiveApp { name, .. }) =>
            println!("✅ App: {}", name),
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    let status = bridge.status();
    println!("\nBridge Status:");
    println!("  SSH USB:  {}", if status.ssh_usb_healthy  { "✅" } else { "❌" });
    println!("  SSH WiFi: {}", if status.ssh_wifi_healthy { "✅" } else { "❌" });

    println!("\nDone!");
}