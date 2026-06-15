use serde::{Deserialize, Serialize};

// ── Window Info ────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowInfo {
    pub id:    u32,
    pub pid:   u32,
    pub app:   String,
    pub title: String,
    pub x:     i32,
    pub y:     i32,
    pub w:     u32,
    pub h:     u32,
}

impl WindowInfo {
    pub fn center(&self) -> (i32, i32) {
        (
            self.x + self.w as i32 / 2,
            self.y + self.h as i32 / 2,
        )
    }
}

// ── IPC Request ────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcRequest {
    // Mac queries
    GetCursor,
    GetScreens,
    GetClipboard,
    GetActiveApp,
    GetWindows,
    GetWindowForApp { app: String },
    FocusApp        { app: String },
    RunCommand      { cmd: String },
    GetMacState,

    // HID keyboard
    Key {
        code:      String,
        modifiers: Vec<String>,
    },
    TypeText  { text: String },
    TypeSmart { text: String },
    Release,

    // HID mouse
    MouseMove   { dx: i32, dy: i32 },
    MouseClick  { button: String },
    MouseScroll { delta: i32 },

    // HID media
    MediaKey { key: String },

    // System
    Reset,
    Status,
    Ping,
}

// ── IPC Response ───────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcResponse {
    // Mac data
    CursorPos     { id: String, x: f64, y: f64 },
    Screens       { id: String, layout: Vec<crate::serial::protocol::Screen> },
    Clipboard     { id: String, text: String },
    ActiveApp     { id: String, name: String, window: String },
    CommandResult { id: String, output: String, error: String },
    Windows       { id: String, list: Vec<WindowInfo> },
    Window        { id: String, info: WindowInfo },
    FocusResult   { id: String, app: String, success: bool },
    MacState      { id: String, state: String, locked: bool, display_sleep: bool },

    // Generic success
    Ok { id: String },

    // Status
    StatusInfo {
        id:               String,
        ws_healthy:       bool,
        ssh_usb_healthy:  bool,
        ssh_wifi_healthy: bool,
    },

    // Error
    Error { id: String, message: String },

    // Ping
    Pong { id: String },
}

impl IpcResponse {
    pub fn ok(id: &str) -> Self {
        IpcResponse::Ok { id: id.to_string() }
    }

    pub fn error(id: &str, msg: &str) -> Self {
        IpcResponse::Error {
            id:      id.to_string(),
            message: msg.to_string(),
        }
    }
}