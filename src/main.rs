#![allow(dead_code)]
#![allow(unused_variables)]

mod hid;
mod serial;
mod screen;

use serial::protocol::Request;
use serial::transport::SerialTransport;
use screen::ScreenLayout;
use tokio::time::{sleep, Duration};

#[tokio::main]
async fn main() {
    println!("Pi Mac Bridge — Serial Test");

    let transport = SerialTransport::new().await
        .expect("Failed to open /dev/ttyGS0");

    sleep(Duration::from_millis(100)).await;

    // Get and classify screens
    println!("Requesting screens...");
    match transport.request(Request::GetScreens).await {
        Ok(serial::protocol::Response::Screens { layout }) => {
            let screen_layout = ScreenLayout::from_raw(layout);
            screen_layout.print_layout();
        }
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    // Cursor
    println!("Requesting cursor...");
    match transport.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) => {
            println!("✅ Cursor: ({}, {})", x, y);
        }
        Ok(r)  => eprintln!("Unexpected: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    // Active app
    println!("Requesting active app...");
    match transport.request(Request::GetActiveApp).await {
        Ok(r)  => println!("✅ App: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    // Clipboard
    println!("Requesting clipboard...");
    match transport.request(Request::GetClipboard).await {
        Ok(r)  => println!("✅ Clipboard: {:?}", r),
        Err(e) => eprintln!("❌ {}", e),
    }

    println!("Done!");
}