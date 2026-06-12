pub const KEY_A: u8 = 0x04;
pub const KEY_B: u8 = 0x05;
pub const KEY_C: u8 = 0x06;
pub const KEY_D: u8 = 0x07;
pub const KEY_E: u8 = 0x08;
pub const KEY_F: u8 = 0x09;
pub const KEY_G: u8 = 0x0A;
pub const KEY_H: u8 = 0x0B;
pub const KEY_I: u8 = 0x0C;
pub const KEY_J: u8 = 0x0D;
pub const KEY_K: u8 = 0x0E;
pub const KEY_L: u8 = 0x0F;
pub const KEY_M: u8 = 0x10;
pub const KEY_N: u8 = 0x11;
pub const KEY_O: u8 = 0x12;
pub const KEY_P: u8 = 0x13;
pub const KEY_Q: u8 = 0x14;
pub const KEY_R: u8 = 0x15;
pub const KEY_S: u8 = 0x16;
pub const KEY_T: u8 = 0x17;
pub const KEY_U: u8 = 0x18;
pub const KEY_V: u8 = 0x19;
pub const KEY_W: u8 = 0x1A;
pub const KEY_X: u8 = 0x1B;
pub const KEY_Y: u8 = 0x1C;
pub const KEY_Z: u8 = 0x1D;

pub const KEY_1: u8 = 0x1E;
pub const KEY_2: u8 = 0x1F;
pub const KEY_3: u8 = 0x20;
pub const KEY_4: u8 = 0x21;
pub const KEY_5: u8 = 0x22;
pub const KEY_6: u8 = 0x23;
pub const KEY_7: u8 = 0x24;
pub const KEY_8: u8 = 0x25;
pub const KEY_9: u8 = 0x26;
pub const KEY_0: u8 = 0x27;

pub const KEY_ENTER: u8 = 0x28;
pub const KEY_ESC: u8 = 0x29;
pub const KEY_BACKSPACE: u8 = 0x2A;
pub const KEY_TAB: u8 = 0x2B;
pub const KEY_SPACE: u8 = 0x2C;
pub const KEY_MINUS: u8 = 0x2D;
pub const KEY_EQUAL: u8 = 0x2E;
pub const KEY_LBRACKET: u8 = 0x2F;
pub const KEY_RBRACKET: u8 = 0x30;
pub const KEY_BACKSLASH: u8 = 0x31;
pub const KEY_SEMICOLON: u8 = 0x33;
pub const KEY_QUOTE: u8 = 0x34;
pub const KEY_GRAVE: u8 = 0x35;
pub const KEY_COMMA: u8 = 0x36;
pub const KEY_DOT: u8 = 0x37;
pub const KEY_SLASH: u8 = 0x38;

pub const KEY_F1: u8 = 0x3A;
pub const KEY_F2: u8 = 0x3B;
pub const KEY_F3: u8 = 0x3C;
pub const KEY_F4: u8 = 0x3D;
pub const KEY_F5: u8 = 0x3E;
pub const KEY_F6: u8 = 0x3F;
pub const KEY_F7: u8 = 0x40;
pub const KEY_F8: u8 = 0x41;
pub const KEY_F9: u8 = 0x42;
pub const KEY_F10: u8 = 0x43;
pub const KEY_F11: u8 = 0x44;
pub const KEY_F12: u8 = 0x45;

pub const KEY_DELETE: u8 = 0x4C;
pub const KEY_HOME: u8 = 0x4A;
pub const KEY_END: u8 = 0x4D;
pub const KEY_PAGEUP: u8 = 0x4B;
pub const KEY_PAGEDOWN: u8 = 0x4E;
pub const KEY_RIGHT: u8 = 0x4F;
pub const KEY_LEFT: u8 = 0x50;
pub const KEY_DOWN: u8 = 0x51;
pub const KEY_UP: u8 = 0x52;
pub const KEY_CAPSLOCK: u8 = 0x39;

pub const MOD_NONE: u8 = 0x00;
pub const MOD_CTRL: u8 = 0x01;
pub const MOD_SHIFT: u8 = 0x02;
pub const MOD_ALT: u8 = 0x04;
pub const MOD_CMD: u8 = 0x08;

pub fn char_to_hid(ch: char) -> Option<(u8, u8)> {
    match ch {
        'a'..='z' => Some((KEY_A + (ch as u8 - b'a'), MOD_NONE)),
        'A'..='Z' => Some((KEY_A + (ch as u8 - b'A'), MOD_SHIFT)),
        '1' => Some((KEY_1, MOD_NONE)),
        '2' => Some((KEY_2, MOD_NONE)),
        '3' => Some((KEY_3, MOD_NONE)),
        '4' => Some((KEY_4, MOD_NONE)),
        '5' => Some((KEY_5, MOD_NONE)),
        '6' => Some((KEY_6, MOD_NONE)),
        '7' => Some((KEY_7, MOD_NONE)),
        '8' => Some((KEY_8, MOD_NONE)),
        '9' => Some((KEY_9, MOD_NONE)),
        '0' => Some((KEY_0, MOD_NONE)),
        '!' => Some((KEY_1, MOD_SHIFT)),
        '@' => Some((KEY_2, MOD_SHIFT)),
        '#' => Some((KEY_3, MOD_SHIFT)),
        '$' => Some((KEY_4, MOD_SHIFT)),
        '%' => Some((KEY_5, MOD_SHIFT)),
        '^' => Some((KEY_6, MOD_SHIFT)),
        '&' => Some((KEY_7, MOD_SHIFT)),
        '*' => Some((KEY_8, MOD_SHIFT)),
        '(' => Some((KEY_9, MOD_SHIFT)),
        ')' => Some((KEY_0, MOD_SHIFT)),
        '-' => Some((KEY_MINUS, MOD_NONE)),
        '_' => Some((KEY_MINUS, MOD_SHIFT)),
        '=' => Some((KEY_EQUAL, MOD_NONE)),
        '+' => Some((KEY_EQUAL, MOD_SHIFT)),
        '[' => Some((KEY_LBRACKET, MOD_NONE)),
        '{' => Some((KEY_LBRACKET, MOD_SHIFT)),
        ']' => Some((KEY_RBRACKET, MOD_NONE)),
        '}' => Some((KEY_RBRACKET, MOD_SHIFT)),
        '\\' => Some((KEY_BACKSLASH, MOD_NONE)),
        '|' => Some((KEY_BACKSLASH, MOD_SHIFT)),
        ';' => Some((KEY_SEMICOLON, MOD_NONE)),
        ':' => Some((KEY_SEMICOLON, MOD_SHIFT)),
        '\'' => Some((KEY_QUOTE, MOD_NONE)),
        '"' => Some((KEY_QUOTE, MOD_SHIFT)),
        '`' => Some((KEY_GRAVE, MOD_NONE)),
        '~' => Some((KEY_GRAVE, MOD_SHIFT)),
        ',' => Some((KEY_COMMA, MOD_NONE)),
        '<' => Some((KEY_COMMA, MOD_SHIFT)),
        '.' => Some((KEY_DOT, MOD_NONE)),
        '>' => Some((KEY_DOT, MOD_SHIFT)),
        '/' => Some((KEY_SLASH, MOD_NONE)),
        '?' => Some((KEY_SLASH, MOD_SHIFT)),
        ' ' => Some((KEY_SPACE, MOD_NONE)),
        '\n' => Some((KEY_ENTER, MOD_NONE)),
        '\t' => Some((KEY_TAB, MOD_NONE)),
        _ => None,
    }
}

pub fn name_to_hid(name: &str) -> Option<(u8, u8)> {
    match name.to_uppercase().as_str() {
        "ENTER" => Some((KEY_ENTER, MOD_NONE)),
        "ESC" => Some((KEY_ESC, MOD_NONE)),
        "BACKSPACE" => Some((KEY_BACKSPACE, MOD_NONE)),
        "TAB" => Some((KEY_TAB, MOD_NONE)),
        "SPACE" => Some((KEY_SPACE, MOD_NONE)),
        "LEFT" => Some((KEY_LEFT, MOD_NONE)),
        "RIGHT" => Some((KEY_RIGHT, MOD_NONE)),
        "UP" => Some((KEY_UP, MOD_NONE)),
        "DOWN" => Some((KEY_DOWN, MOD_NONE)),
        "DELETE" => Some((KEY_DELETE, MOD_NONE)),
        "HOME" => Some((KEY_HOME, MOD_NONE)),
        "END" => Some((KEY_END, MOD_NONE)),
        "PAGEUP" => Some((KEY_PAGEUP, MOD_NONE)),
        "PAGEDOWN" => Some((KEY_PAGEDOWN, MOD_NONE)),
        "CAPSLOCK" => Some((KEY_CAPSLOCK, MOD_NONE)),
        "F1" => Some((KEY_F1, MOD_NONE)),
        "F2" => Some((KEY_F2, MOD_NONE)),
        "F3" => Some((KEY_F3, MOD_NONE)),
        "F4" => Some((KEY_F4, MOD_NONE)),
        "F5" => Some((KEY_F5, MOD_NONE)),
        "F6" => Some((KEY_F6, MOD_NONE)),
        "F7" => Some((KEY_F7, MOD_NONE)),
        "F8" => Some((KEY_F8, MOD_NONE)),
        "F9" => Some((KEY_F9, MOD_NONE)),
        "F10" => Some((KEY_F10, MOD_NONE)),
        "F11" => Some((KEY_F11, MOD_NONE)),
        "F12" => Some((KEY_F12, MOD_NONE)),
        _ => None,
    }
}

pub fn modifier_from_name(name: &str) -> Option<u8> {
    match name.to_uppercase().as_str() {
        "CTRL" => Some(MOD_CTRL),
        "SHIFT" => Some(MOD_SHIFT),
        "ALT" => Some(MOD_ALT),
        "CMD" => Some(MOD_CMD),
        _ => None,
    }
}
