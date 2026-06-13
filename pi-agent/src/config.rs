use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub ssh: SshConfig,
    pub hosts: HostsConfig,
    pub serial: SerialConfig,
    pub hid: HidConfig,
    #[serde(default)]
    pub bridge: BridgeConfig,
    #[serde(default)]
    pub websocket: WebSocketConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct SshConfig {
    pub user: String,
    pub key: String,
    pub port: u16,
    pub timeout_ms: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct HostsConfig {
    pub usb: String,
    pub wifi: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct SerialConfig {
    pub device: String,
    pub timeout_ms: u64,
    pub cursor_timeout_ms: u64,
    pub max_retries: u32,
}

#[derive(Debug, Deserialize, Clone)]
pub struct HidConfig {
    pub keyboard: String,
    pub mouse: String,
    pub media: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct BridgeConfig {
    pub mode: String,
}

impl Default for BridgeConfig {
    fn default() -> Self {
        BridgeConfig {
            mode: "hybrid".to_string(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct WebSocketConfig {
    pub url: String,
    pub timeout_ms: u64,
}

impl Default for WebSocketConfig {
    fn default() -> Self {
        WebSocketConfig {
            url: "ws://mac.hid:8082".to_string(),
            timeout_ms: 2000,
        }
    }
}

fn config_paths() -> Vec<PathBuf> {
    let mut paths = vec![
        PathBuf::from("zerobridge.toml"),
        PathBuf::from("/etc/zerobridge/config.toml"),
    ];

    if let Ok(home) = std::env::var("HOME") {
        paths.insert(1, PathBuf::from(format!("{home}/.config/zerobridge/config.toml")));
    }

    if let Some(home) = dirs::home_dir() {
        let p = home.join(".config/zerobridge/config.toml");
        if !paths.contains(&p) {
            paths.insert(2, p);
        }
    }
    eprintln!("[config] Searching paths: {:?}", paths);
    paths
}

impl Config {
    pub fn load() -> Result<Self, String> {
        for path in config_paths() {
            if path.exists() {
                eprintln!("[config] Loading from {}", path.display());
                let content =
                    std::fs::read_to_string(&path).map_err(|e| format!("Read failed: {e}"))?;
                return toml::from_str(&content).map_err(|e| format!("Parse failed: {e}"));
            }
        }
        eprintln!("[config] No config file found — using defaults");
        Ok(Config::default())
    }
}

impl Default for Config {
    fn default() -> Self {
        toml::from_str(DEFAULT_CONFIG).expect("Default config valid")
    }
}

pub const DEFAULT_CONFIG: &str = r#"
[ssh]
user       = "pi"
key        = "/home/pi/.ssh/id_ed25519"
port       = 22
timeout_ms = 5000

[hosts]
usb  = "169.254.206.1"
wifi = "192.168.0.167"

[serial]
device            = "/dev/ttyGS0"
timeout_ms        = 3000
cursor_timeout_ms = 1000
max_retries       = 2

[hid]
keyboard = "/dev/hidg0"
mouse    = "/dev/hidg1"
media    = "/dev/hidg2"

[bridge]
mode = "hybrid"

[websocket]
url        = "ws://mac.hid:8082"
timeout_ms = 2000
"#;
