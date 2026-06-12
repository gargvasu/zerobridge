use std::fs::OpenOptions;
use std::io::Write;
use tokio::time::{sleep, Duration};

use crate::config::HidConfig;
const TAP_DELAY_MS: u64 = 50;

// Consumer key codes
pub const MEDIA_PLAY_PAUSE:    u16 = 0x00CD;
pub const MEDIA_NEXT:          u16 = 0x00B5;
pub const MEDIA_PREV:          u16 = 0x00B6;
pub const MEDIA_STOP:          u16 = 0x00B7;
pub const MEDIA_VOLUME_UP:     u16 = 0x00E9;
pub const MEDIA_VOLUME_DOWN:   u16 = 0x00EA;
pub const MEDIA_MUTE:          u16 = 0x00E2;
pub const MEDIA_BRIGHTNESS_UP: u16 = 0x006F;
pub const MEDIA_BRIGHTNESS_DN: u16 = 0x0070;
pub const MEDIA_SCREENSHOT:    u16 = 0x0065;

pub struct Media {
    device: std::fs::File,
}

impl Media {
    pub fn new(config: &HidConfig) -> Result<Self, std::io::Error> {
        let device = OpenOptions::new()
            .write(true)
            .open(&config.media)?;
        Ok(Media { device })
    }

    fn send(&mut self, key: u16) -> std::io::Result<()> {
        // 2 byte report — little endian
        let report = [
            (key & 0xFF) as u8,
            ((key >> 8) & 0xFF) as u8,
        ];
        self.device.write_all(&report)?;
        self.device.flush()
    }

    fn release(&mut self) -> std::io::Result<()> {
        self.send(0x0000)
    }

    pub async fn tap(&mut self, key: u16) -> std::io::Result<()> {
        self.send(key)?;
        sleep(Duration::from_millis(TAP_DELAY_MS)).await;
        self.release()?;
        sleep(Duration::from_millis(TAP_DELAY_MS)).await;
        Ok(())
    }

    // ── convenience methods ────────────────────────

    pub async fn play_pause(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_PLAY_PAUSE).await
    }

    pub async fn next(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_NEXT).await
    }

    pub async fn prev(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_PREV).await
    }

    pub async fn stop(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_STOP).await
    }

    pub async fn volume_up(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_VOLUME_UP).await
    }

    pub async fn volume_down(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_VOLUME_DOWN).await
    }

    pub async fn mute(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_MUTE).await
    }

    pub async fn brightness_up(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_BRIGHTNESS_UP).await
    }

    pub async fn brightness_down(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_BRIGHTNESS_DN).await
    }

    pub async fn screenshot(&mut self) -> std::io::Result<()> {
        self.tap(MEDIA_SCREENSHOT).await
    }

    // Volume by steps
    pub async fn volume_up_steps(&mut self, steps: u8) -> std::io::Result<()> {
        for _ in 0..steps {
            self.volume_up().await?;
        }
        Ok(())
    }

    pub async fn volume_down_steps(&mut self, steps: u8) -> std::io::Result<()> {
        for _ in 0..steps {
            self.volume_down().await?;
        }
        Ok(())
    }
}

impl Drop for Media {
    fn drop(&mut self) {
        let _ = self.release();
    }
}