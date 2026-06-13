use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcRequest {
    // Mac queries
    GetCursor,
    GetScreens,
    GetClipboard,
    GetActiveApp,
    RunCommand { cmd: String },

    // HID keyboard
    Key {
        code:      String,
        modifiers: Vec<String>,
    },
    TypeText { text: String },
    TypeSmart { text: String },
    Release,

    // HID mouse
    MouseMove  { dx: i32, dy: i32 },
    MouseClick { button: String },
    MouseScroll { delta: i32 },

    // HID media
    MediaKey { key: String },

    // System
    Reset,
    Status,
    Ping,
    GetWindows,
    GetWindowForApp { app: String },
    FocusApp { app: String },    
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcResponse {
    // Mac data
    CursorPos  { id: String, x: f64, y: f64 },
    Screens    { id: String, layout: Vec<crate::serial::protocol::Screen> },
    Clipboard  { id: String, text: String },
    ActiveApp  { id: String, name: String, window: String },
    CommandResult { id: String, output: String, error: String },

    // Generic success
    Ok    { id: String },

    // Status
    StatusInfo {
        id:               String,
        ssh_usb_healthy:  bool,
        ssh_wifi_healthy: bool,
    },

    // Errors
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