use std::fs::OpenOptions;
use std::io::Write;
use tokio::time::{sleep, Duration};

use crate::config::HidConfig;
const CLICK_DELAY_MS: u64 = 50;
const SMOOTH_DELAY_MS: u64 = 10;

pub struct Mouse {
    device: std::fs::File,
    pub estimated_x: i32,
    pub estimated_y: i32,
}

impl Mouse {
    pub fn new(config: &HidConfig) -> Result<Self, std::io::Error> {
        let device = OpenOptions::new().write(true).open(&config.mouse)?;
        Ok(Mouse {
            device,
            estimated_x: 0,
            estimated_y: 0,
        })
    }

    fn send(&mut self, buttons: u8, x: i8, y: i8, wheel: i8) -> std::io::Result<()> {
        let report = [buttons, x as u8, y as u8, wheel as u8];
        self.device.write_all(&report)?;
        self.device.flush()
    }

    pub fn release_all(&mut self) -> std::io::Result<()> {
        self.send(0, 0, 0, 0)
    }

    // ── movement ───────────────────────────────────

    pub fn move_rel(&mut self, dx: i8, dy: i8) -> std::io::Result<()> {
        self.estimated_x += dx as i32;
        self.estimated_y += dy as i32;
        self.send(0, dx, dy, 0)
    }

    pub async fn move_smooth(&mut self, dx: i32, dy: i32, steps: u32) -> std::io::Result<()> {
        let step_x = (dx / steps as i32) as i8;
        let step_y = (dy / steps as i32) as i8;
        for _ in 0..steps {
            self.move_rel(step_x, step_y)?;
            sleep(Duration::from_millis(SMOOTH_DELAY_MS)).await;
        }
        Ok(())
    }

    // Break large movements into 127-unit chunks
    pub async fn move_large(&mut self, dx: i32, dy: i32) -> std::io::Result<()> {
        let mut rx = dx;
        let mut ry = dy;
        while rx != 0 || ry != 0 {
            let step_x = rx.clamp(-127, 127) as i8;
            let step_y = ry.clamp(-127, 127) as i8;
            self.move_rel(step_x, step_y)?;
            sleep(Duration::from_millis(5)).await;
            rx -= step_x as i32;
            ry -= step_y as i32;
        }
        Ok(())
    }

    pub fn nudge(&mut self) -> std::io::Result<()> {
        self.send(0, 2, 0, 0)?;
        self.send(0, -2, 0, 0)
    }

    // ── clicks ─────────────────────────────────────

    pub async fn click(&mut self) -> std::io::Result<()> {
        self.send(0x01, 0, 0, 0)?;
        sleep(Duration::from_millis(CLICK_DELAY_MS)).await;
        self.send(0, 0, 0, 0)
    }

    pub async fn right_click(&mut self) -> std::io::Result<()> {
        self.send(0x02, 0, 0, 0)?;
        sleep(Duration::from_millis(CLICK_DELAY_MS)).await;
        self.send(0, 0, 0, 0)
    }

    pub async fn middle_click(&mut self) -> std::io::Result<()> {
        self.send(0x04, 0, 0, 0)?;
        sleep(Duration::from_millis(CLICK_DELAY_MS)).await;
        self.send(0, 0, 0, 0)
    }

    pub async fn double_click(&mut self) -> std::io::Result<()> {
        self.click().await?;
        sleep(Duration::from_millis(100)).await;
        self.click().await
    }

    // ── scroll ─────────────────────────────────────

    pub fn scroll(&mut self, amount: i8) -> std::io::Result<()> {
        self.send(0, 0, 0, amount)
    }

    pub async fn scroll_smooth(&mut self, amount: i32, steps: u32) -> std::io::Result<()> {
        let step = if amount > 0 { 1i8 } else { -1i8 };
        for _ in 0..amount.unsigned_abs() {
            self.scroll(step)?;
            sleep(Duration::from_millis(SMOOTH_DELAY_MS)).await;
        }
        Ok(())
    }

    // ── drag ───────────────────────────────────────

    pub fn drag(&mut self, dx: i8, dy: i8) -> std::io::Result<()> {
        self.estimated_x += dx as i32;
        self.estimated_y += dy as i32;
        self.send(0x01, dx, dy, 0)
    }

    pub async fn drag_smooth(&mut self, dx: i32, dy: i32, steps: u32) -> std::io::Result<()> {
        let step_x = (dx / steps as i32) as i8;
        let step_y = (dy / steps as i32) as i8;
        for _ in 0..steps {
            self.drag(step_x, step_y)?;
            sleep(Duration::from_millis(SMOOTH_DELAY_MS)).await;
        }
        self.release_all()
    }
}

impl Drop for Mouse {
    fn drop(&mut self) {
        let _ = self.release_all();
    }
}
