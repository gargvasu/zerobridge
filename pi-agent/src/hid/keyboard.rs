use std::fs::OpenOptions;
use std::io::Write;
use tokio::time::{sleep, Duration};
use crate::hid::keycodes::{char_to_hid, name_to_hid, modifier_from_name, MOD_NONE};

const HID_DEVICE: &str = "/dev/hidg0";
const TAP_DELAY_MS: u64 = 30;

pub struct Keyboard {
    device: std::fs::File,
}

impl Keyboard {
    pub fn new() -> Result<Self, std::io::Error> {
        let device = OpenOptions::new()
            .write(true)
            .open(HID_DEVICE)?;
        Ok(Keyboard { device })
    }

    fn send(&mut self, modifier: u8, keycode: u8) -> std::io::Result<()> {
        let report = [modifier, 0u8, keycode, 0u8, 0u8, 0u8, 0u8, 0u8];
        self.device.write_all(&report)?;
        self.device.flush()
    }

    pub fn release_all(&mut self) -> std::io::Result<()> {
        self.send(0, 0)
    }

    pub async fn tap(&mut self, modifier: u8, keycode: u8) -> std::io::Result<()> {
        self.send(modifier, keycode)?;
        sleep(Duration::from_millis(TAP_DELAY_MS)).await;
        self.release_all()?;
        sleep(Duration::from_millis(TAP_DELAY_MS)).await;
        Ok(())
    }

    pub async fn key(&mut self, name: &str) -> std::io::Result<()> {
        if let Some((keycode, modifier)) = name_to_hid(name) {
            self.tap(modifier, keycode).await
        } else if name.len() == 1 {
            self.type_char(name.chars().next().unwrap()).await
        } else {
            eprintln!("[WARN] Unknown key: {}", name);
            Ok(())
        }
    }

    pub async fn combo(&mut self, keys: &[&str]) -> std::io::Result<()> {
        let mut modifier = MOD_NONE;
        let mut keycode: Option<u8> = None;

        for &k in keys {
            if let Some(m) = modifier_from_name(k) {
                modifier |= m;
            } else if let Some((kc, extra_mod)) = name_to_hid(k) {
                keycode = Some(kc);
                modifier |= extra_mod;
            } else if k.len() == 1 {
                if let Some((kc, extra_mod)) = char_to_hid(k.chars().next().unwrap()) {
                    keycode = Some(kc);
                    modifier |= extra_mod;
                }
            }
        }

        match keycode {
            Some(kc) => self.tap(modifier, kc).await,
            None => {
                eprintln!("[WARN] No keycode in combo: {:?}", keys);
                Ok(())
            }
        }
    }

    pub async fn type_char(&mut self, ch: char) -> std::io::Result<()> {
        match char_to_hid(ch) {
            Some((keycode, modifier)) => self.tap(modifier, keycode).await,
            None => {
                eprintln!("[WARN] Unsupported char: {}", ch);
                Ok(())
            }
        }
    }

    pub async fn type_text(&mut self, text: &str) -> std::io::Result<()> {
        for ch in text.chars() {
            self.type_char(ch).await?;
        }
        Ok(())
    }

    pub async fn type_smart(&mut self, text: &str) -> std::io::Result<()> {
        let mut chars = text.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '[' {
                let mut token = String::new();
                for inner in chars.by_ref() {
                    if inner == ']' { break; }
                    token.push(inner);
                }
                let parts: Vec<&str> = token.split('+').collect();
                self.combo(&parts).await?;
            } else {
                self.type_char(ch).await?;
            }
        }
        Ok(())
    }
}

impl Drop for Keyboard {
    fn drop(&mut self) {
        let _ = self.release_all();
    }
}