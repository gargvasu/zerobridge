#![allow(dead_code)]
#![allow(unused_variables)]

mod bridge;
mod config;
mod hid;
mod screen;
mod serial;

use bridge::mac_bridge::MacBridge;
use config::Config;
use screen::ScreenLayout;
use serial::protocol::Request;
use tokio::time::{sleep, Duration};

#[tokio::main]
async fn main() {
    println!("ZeroBridge — MacBridge Test");
    println!("══════════════════════════════════════");

    let config = Config::load().expect("Failed to load config");

    println!("Initialising bridge...");
    let bridge = MacBridge::new(config)
        .await
        .expect("Failed to init MacBridge");

    sleep(Duration::from_millis(200)).await;

    let mut passed = 0u32;
    let mut failed = 0u32;

    // ── Serial Tests ───────────────────────────────

    println!("\n📡 Serial Channel Tests");
    println!("──────────────────────────────────────");

    // Screens
    print!("  get_screens ... ");
    match bridge.request(Request::GetScreens).await {
        Ok(serial::protocol::Response::Screens { layout }) => {
            let screen_layout = ScreenLayout::from_raw(layout);
            println!("✅");
            screen_layout.print_layout();
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Cursor
    print!("  get_cursor ... ");
    match bridge.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) => {
            println!("✅ ({}, {})", x, y);
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Active app
    print!("  get_active_app ... ");
    match bridge.request(Request::GetActiveApp).await {
        Ok(serial::protocol::Response::ActiveApp { name, .. }) => {
            println!("✅ {}", name);
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // ── SSH USB Tests ──────────────────────────────

    println!("\n🔌 SSH USB Tests (hid.macmini)");
    println!("──────────────────────────────────────");

    // Clipboard via SSH USB
    print!("  get_clipboard ... ");
    match bridge.request(Request::GetClipboard).await {
        Ok(serial::protocol::Response::Clipboard { text }) => {
            println!("✅ {} chars", text.len());
            if !text.is_empty() {
                let preview: String = text.chars().take(60).collect();
                println!("    preview: {}{}",
                    preview,
                    if text.len() > 60 { "..." } else { "" }
                );
            }
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Cursor via SSH USB (force SSH)
    print!("  get_cursor (SSH) ... ");
    match bridge.ssh_usb.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) => {
            println!("✅ ({}, {})", x, y);
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Screens via SSH USB
    print!("  get_screens (SSH) ... ");
    match bridge.ssh_usb.request(Request::GetScreens).await {
        Ok(serial::protocol::Response::Screens { layout }) => {
            println!("✅ {} screens", layout.len());
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Run command via SSH USB
    print!("  run_command (SSH) ... ");
    match bridge.ssh_usb.request(Request::RunCommand {
        cmd: "hostname".to_string()
    }).await {
        Ok(serial::protocol::Response::CommandResult { output, .. }) => {
            println!("✅ hostname: {}", output.trim());
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // ── SSH WiFi Tests ─────────────────────────────

    println!("\n📶 SSH WiFi Tests (Vasus-Mac-Mini.local)");
    println!("──────────────────────────────────────");

    // Health check WiFi
    print!("  health check ... ");
    bridge.ssh_wifi.check_health().await;
    if bridge.ssh_wifi.is_healthy() {
        println!("✅ connected");
        passed += 1;
    } else {
        println!("❌ unhealthy");
        failed += 1;
    }

    // Clipboard via SSH WiFi
    print!("  get_clipboard (WiFi) ... ");
    match bridge.ssh_wifi.request(Request::GetClipboard).await {
        Ok(serial::protocol::Response::Clipboard { text }) => {
            println!("✅ {} chars", text.len());
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // Cursor via SSH WiFi
    print!("  get_cursor (WiFi) ... ");
    match bridge.ssh_wifi.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) => {
            println!("✅ ({}, {})", x, y);
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // ── Fallback Test ──────────────────────────────

    println!("\n🔄 Fallback Chain Test");
    println!("──────────────────────────────────────");

    // Serial → SSH fallback (cursor goes serial first)
    print!("  serial→ssh fallback (cursor) ... ");
    match bridge.request(Request::GetCursor).await {
        Ok(serial::protocol::Response::CursorPos { x, y }) => {
            println!("✅ ({}, {})", x, y);
            passed += 1;
        }
        Ok(r)  => { println!("❌ unexpected: {:?}", r); failed += 1; }
        Err(e) => { println!("❌ {}", e); failed += 1; }
    }

    // ── Summary ────────────────────────────────────

    println!("\n══════════════════════════════════════");
    println!("Bridge Status:");
    let status = bridge.status();
    println!("  SSH USB:  {}", if status.ssh_usb_healthy  { "✅" } else { "❌" });
    println!("  SSH WiFi: {}", if status.ssh_wifi_healthy { "✅" } else { "❌" });

    println!("\nTest Results:");
    println!("  ✅ Passed: {}", passed);
    println!("  ❌ Failed: {}", failed);
    println!("  📊 Total:  {}", passed + failed);

    if failed == 0 {
        println!("\n🎉 All tests passed!");
    } else {
        println!("\n⚠️  {} test(s) failed", failed);
    }
}