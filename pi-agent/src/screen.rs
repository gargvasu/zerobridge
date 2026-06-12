// src/screen.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Screen {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
    pub role: ScreenRole,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ScreenRole {
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone)]
pub struct ScreenLayout {
    pub screens: Vec<Screen>,
}

impl ScreenLayout {
    pub fn from_raw(raw: Vec<crate::serial::protocol::Screen>) -> Self {
        // Sort by x position left to right
        let mut screens: Vec<Screen> = raw
            .into_iter()
            .map(|s| Screen {
                id: s.id,
                x: s.x,
                y: s.y,
                w: s.w,
                h: s.h,
                role: ScreenRole::Center, // temp
            })
            .collect();

        screens.sort_by_key(|s| s.x);

        // Assign roles based on sorted position
        let len = screens.len();
        for (i, screen) in screens.iter_mut().enumerate() {
            screen.role = if i == 0 {
                ScreenRole::Left
            } else if i == len - 1 {
                ScreenRole::Right
            } else {
                ScreenRole::Center
            };
        }

        ScreenLayout { screens }
    }

    pub fn left(&self) -> Option<&Screen> {
        self.screens.iter().find(|s| s.role == ScreenRole::Left)
    }

    pub fn center(&self) -> Option<&Screen> {
        self.screens.iter().find(|s| s.role == ScreenRole::Center)
    }

    pub fn right(&self) -> Option<&Screen> {
        self.screens.iter().find(|s| s.role == ScreenRole::Right)
    }

    pub fn which_screen(&self, x: i32, y: i32) -> Option<&Screen> {
        self.screens
            .iter()
            .find(|s| x >= s.x && x < s.x + s.w as i32 && y >= s.y && y < s.y + s.h as i32)
    }

    pub fn total_bounds(&self) -> (i32, i32, i32, i32) {
        let min_x = self.screens.iter().map(|s| s.x).min().unwrap_or(0);
        let min_y = self.screens.iter().map(|s| s.y).min().unwrap_or(0);
        let max_x = self
            .screens
            .iter()
            .map(|s| s.x + s.w as i32)
            .max()
            .unwrap_or(0);
        let max_y = self
            .screens
            .iter()
            .map(|s| s.y + s.h as i32)
            .max()
            .unwrap_or(0);
        (min_x, min_y, max_x, max_y)
    }

    pub fn clamp(&self, x: i32, y: i32) -> (i32, i32) {
        let (min_x, min_y, max_x, max_y) = self.total_bounds();
        (x.clamp(min_x, max_x), y.clamp(min_y, max_y))
    }

    pub fn print_layout(&self) {
        println!("Screen Layout:");
        for s in &self.screens {
            println!(
                "  {:?} — id:{} x:{} y:{} {}x{}",
                s.role, s.id, s.x, s.y, s.w, s.h
            );
        }
        let (min_x, _, max_x, max_y) = self.total_bounds();
        println!(
            "  Total: {}x{} (x: {} to {})",
            max_x - min_x,
            max_y,
            min_x,
            max_x
        );
    }
}
