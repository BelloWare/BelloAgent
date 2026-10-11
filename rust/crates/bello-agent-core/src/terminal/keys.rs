//! The bytes a key sends, honouring the application cursor and keypad modes
//! (Swift 0.1.122 Terminal/TerminalKeyEncoder.swift), and the ones a typed
//! character sends with Control or Option held (TerminalView.keyDown).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalKey {
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    Tab,
    BackTab,
    Enter,
    Escape,
    Backspace,
    /// F1 to F12 (anything past 12 sends F12's sequence, as Swift's does).
    Function(u8),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct KeyModifiers {
    pub shift: bool,
    pub control: bool,
    pub option: bool,
}

/// The key a GPUI key name is, for the keys that send a sequence of their
/// own; None for a key that types a character.
pub fn key_for_name(name: &str, shift: bool) -> Option<TerminalKey> {
    Some(match name {
        "up" => TerminalKey::Up,
        "down" => TerminalKey::Down,
        "left" => TerminalKey::Left,
        "right" => TerminalKey::Right,
        "home" => TerminalKey::Home,
        "end" => TerminalKey::End,
        "pageup" => TerminalKey::PageUp,
        "pagedown" => TerminalKey::PageDown,
        "delete" => TerminalKey::Delete,
        "insert" => TerminalKey::Insert,
        "escape" => TerminalKey::Escape,
        "tab" if shift => TerminalKey::BackTab,
        "tab" => TerminalKey::Tab,
        "enter" => TerminalKey::Enter,
        "backspace" => TerminalKey::Backspace,
        _ => {
            let number: u8 = name.strip_prefix('f')?.parse().ok()?;
            if !(1..=12).contains(&number) {
                return None;
            }
            TerminalKey::Function(number)
        }
    })
}

pub fn encode(key: TerminalKey, application_cursor: bool, modifiers: KeyModifiers) -> Vec<u8> {
    let mut value = 1;
    if modifiers.shift {
        value += 1;
    }
    if modifiers.option {
        value += 2;
    }
    if modifiers.control {
        value += 4;
    }
    let modifier = if value == 1 {
        String::new()
    } else {
        format!(";{value}")
    };
    let csi = |final_byte: &str| {
        if modifier.is_empty() {
            format!("\u{1b}[{final_byte}")
        } else {
            format!("\u{1b}[1{modifier}{final_byte}")
        }
    };
    let ss3 = |final_byte: &str| {
        if !modifier.is_empty() {
            format!("\u{1b}[1{modifier}{final_byte}")
        } else if application_cursor {
            format!("\u{1b}O{final_byte}")
        } else {
            format!("\u{1b}[{final_byte}")
        }
    };
    let tilde = |number: u8| format!("\u{1b}[{number}{modifier}~");
    let text = match key {
        TerminalKey::Up => ss3("A"),
        TerminalKey::Down => ss3("B"),
        TerminalKey::Right => ss3("C"),
        TerminalKey::Left => ss3("D"),
        TerminalKey::Home => ss3("H"),
        TerminalKey::End => ss3("F"),
        TerminalKey::PageUp => tilde(5),
        TerminalKey::PageDown => tilde(6),
        TerminalKey::Insert => tilde(2),
        TerminalKey::Delete => tilde(3),
        TerminalKey::Tab => "\t".into(),
        TerminalKey::BackTab => "\u{1b}[Z".into(),
        TerminalKey::Enter => "\r".into(),
        TerminalKey::Escape => "\u{1b}".into(),
        TerminalKey::Backspace => {
            if modifiers.option {
                "\u{1b}\u{7f}".into()
            } else {
                "\u{7f}".into()
            }
        }
        TerminalKey::Function(number) => match number {
            1..=4 => {
                let final_byte = ["P", "Q", "R", "S"][usize::from(number - 1)];
                if modifier.is_empty() {
                    format!("\u{1b}O{final_byte}")
                } else {
                    csi(final_byte)
                }
            }
            5 => tilde(15),
            6 => tilde(17),
            7 => tilde(18),
            8 => tilde(19),
            9 => tilde(20),
            10 => tilde(21),
            11 => tilde(23),
            _ => tilde(24),
        },
    };
    text.into_bytes()
}

/// The control byte Control plus a character sends, as TerminalView.keyDown
/// works it out from the character without modifiers; Option adds ESC first.
pub fn control_bytes(character: char, option: bool) -> Option<Vec<u8>> {
    let value = u32::from(character);
    let byte = match character {
        'a'..='z' => (value - 0x60) as u8,
        'A'..='Z' => (value - 0x40) as u8,
        ' ' | '@' | '2' => 0,
        '[' | '3' => 0x1b,
        '\\' | '4' => 0x1c,
        ']' | '5' => 0x1d,
        '^' | '6' => 0x1e,
        '_' | '7' | '-' => 0x1f,
        '?' | '8' => 0x7f,
        _ => return None,
    };
    Some(if option { vec![0x1b, byte] } else { vec![byte] })
}

/// Pasted text as one paste: line ends become carriage returns, and when the
/// program asked for bracketed paste it is bracketed and carries no ESC or
/// C1 CSI of its own (as in iTerm2, kitty and VTE), so a pasted "ESC[201~"
/// cannot end the paste early (TerminalView.pasteText).
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    let normalized = text.replace("\r\n", "\r").replace('\n', "\r");
    if bracketed {
        let payload: String = normalized
            .chars()
            .filter(|c| *c != '\u{1b}' && *c != '\u{9b}')
            .collect();
        format!("\u{1b}[200~{payload}\u{1b}[201~").into_bytes()
    } else {
        normalized.into_bytes()
    }
}
