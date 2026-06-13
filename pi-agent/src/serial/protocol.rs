use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Screen {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    GetCursor,
    GetScreens,
    GetClipboard,
    GetActiveApp,
    GetWindows,                      // ← new
    GetWindowForApp { app: String }, // ← new
    FocusApp { app: String },        // ← new
    RunCommand { cmd: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    CursorPos { x: f64, y: f64 },
    Screens { layout: Vec<Screen> },
    Clipboard { text: String },
    ActiveApp { name: String, window: String },
    CommandResult { output: String, error: String },
    Windows { list: Vec<crate::ipc::WindowInfo> },  // ← new
    Window { info: crate::ipc::WindowInfo },          // ← new
    FocusResult { app: String, success: bool },       // ← new
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestEnvelope {
    pub id: String,
    #[serde(flatten)]
    pub request: Request,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseEnvelope {
    pub id: String,
    #[serde(flatten)]
    pub response: Response,
}
