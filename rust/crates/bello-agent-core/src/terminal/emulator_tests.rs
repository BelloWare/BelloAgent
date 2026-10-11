//! The emulator held to Swift 0.1.122's: every case of the corpus (escape
//! sequences for each feature, and output recorded from vim, less, ls, tput
//! and zsh under script(1)) is fed to both, and everything the grid holds
//! afterwards must match. `fixtures/expected.json` is the unchanged Swift
//! TerminalEmulator's answer (claude-2026-10-10/terminal-oracle/emu-oracle).
use super::emulator::{TerminalEmulator, TerminalEvent};
use super::keys::{self, KeyModifiers, TerminalKey};
use super::screen::{CellStyle, TerminalCell, TerminalColor, TerminalCursorShape};
use super::width::width;
use serde_json::{Value, json};

fn colour(c: TerminalColor) -> String {
    match c {
        TerminalColor::Standard => "s".into(),
        TerminalColor::Indexed(i) => format!("i{i}"),
        TerminalColor::Rgb(r, g, b) => format!("r{r:02x}{g:02x}{b:02x}"),
    }
}
fn style(s: CellStyle) -> String {
    let mut out = format!("{}/{}", colour(s.foreground), colour(s.background));
    for (on, mark) in [
        (s.bold, 'B'),
        (s.dim, 'D'),
        (s.italic, 'I'),
        (s.underline, 'U'),
        (s.inverse, 'R'),
        (s.strikethrough, 'S'),
        (s.hidden, 'H'),
    ] {
        if on {
            out.push(mark);
        }
    }
    out
}
fn cells(line: &[TerminalCell]) -> Value {
    let mut runs: Vec<(String, u8, String, bool, usize)> = Vec::new();
    for cell in line {
        let key = (
            cell.text.as_string(),
            cell.width,
            style(cell.style),
            cell.combining_truncated,
        );
        match runs.last_mut() {
            Some(last) if (&last.0, last.1, &last.2, last.3) == (&key.0, key.1, &key.2, key.3) => {
                last.4 += 1
            }
            _ => runs.push((key.0, key.1, key.2, key.3, 1)),
        }
    }
    Value::Array(
        runs.into_iter()
            .map(|(text, width, style, truncated, count)| {
                json!([text, width, style, truncated, count])
            })
            .collect(),
    )
}
fn hex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

fn run(case: &Value) -> Value {
    let mut e = TerminalEmulator::new(
        case["columns"].as_u64().unwrap_or(20) as usize,
        case["rows"].as_u64().unwrap_or(6) as usize,
        case["scrollback"].as_u64().unwrap_or(10_000) as usize,
    );
    if let Some(cell) = case["cellPixelSize"].as_array() {
        e.cell_pixel_size = (cell[0].as_f64().unwrap(), cell[1].as_f64().unwrap());
    }
    let mut replies = Vec::new();
    let (mut bells, mut titles, mut dirs) = (0, Vec::<String>::new(), Vec::<String>::new());
    let mut dirty = Vec::new();
    let mut drain = |e: &mut TerminalEmulator| {
        replies.extend(e.take_output());
        for event in e.take_events() {
            match event {
                TerminalEvent::Bell => bells += 1,
                TerminalEvent::TitleChanged(t) => titles.push(t),
                TerminalEvent::DirectoryChanged(d) => {
                    dirs.push(d.unwrap_or_else(|| "<nil>".into()))
                }
                TerminalEvent::TextLimit => {}
            }
        }
    };
    for step in case["steps"].as_array().unwrap() {
        if let Some(text) = step["hex"].as_str() {
            let bytes = hex(text);
            if step["split"].as_bool() == Some(true) {
                for byte in bytes {
                    e.feed(&[byte]);
                }
            } else {
                e.feed(&bytes);
            }
        }
        if let Some(size) = step["resize"].as_array() {
            e.resize(
                size[0].as_u64().unwrap() as usize,
                size[1].as_u64().unwrap() as usize,
            );
        }
        if step["clearDirty"].as_bool() == Some(true) {
            e.clear_dirty();
        }
        if step["dirty"].as_bool() == Some(true) {
            dirty.push(match e.dirty_rows() {
                Some(rows) => json!(rows.iter().collect::<Vec<_>>()),
                None => json!("all"),
            });
        }
        if step["reset"].as_bool() == Some(true) {
            e.reset();
        }
        drain(&mut e);
    }
    let shape = match e.cursor_shape() {
        TerminalCursorShape::Block => "block",
        TerminalCursorShape::Underline => "underline",
        TerminalCursorShape::Bar => "bar",
    };
    let lines: Vec<Value> = (0..e.line_count()).map(|i| cells(&e.line(i))).collect();
    let texts: Vec<String> = (0..e.line_count()).map(|i| e.text_at_line(i)).collect();
    json!({
        "columns": e.columns(), "rows": e.rows(),
        "screenText": e.screen_text(),
        "texts": texts,
        "lines": lines,
        "scrollback": e.scrollback_len(), "trimmed": e.trimmed_lines(),
        "cursor": [e.cursor().x, e.cursor().y], "cursorVisible": e.cursor_visible(), "cursorShape": shape,
        "title": e.title(), "directory": e.current_directory(),
        "modes": {
            "applicationCursorKeys": e.application_cursor_keys(), "applicationKeypad": e.application_keypad(),
            "bracketedPaste": e.bracketed_paste(), "focusReporting": e.focus_reporting(), "alternateScreen": e.alternate_screen(),
            "mouseReporting": e.mouse_reporting(), "originMode": e.origin_mode(), "autowrap": e.autowrap(),
            "insertMode": e.insert_mode(), "newlineMode": e.newline_mode(),
        },
        "scrollRegion": [e.scroll_region().0, e.scroll_region().1],
        "style": style(e.style()),
        "replies": String::from_utf8_lossy(&replies),
        "bells": bells, "titles": titles, "directories": dirs,
        "dirty": dirty,
    })
}

#[test]
fn every_corpus_case_matches_swift() {
    let cases: Value = serde_json::from_str(include_str!("fixtures/cases.json")).unwrap();
    let expected: Value = serde_json::from_str(include_str!("fixtures/expected.json")).unwrap();
    let mut failures = Vec::new();
    let mut compared = 0;
    for case in cases.as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let ours = run(case);
        let theirs = &expected[name];
        for (key, value) in theirs.as_object().unwrap() {
            compared += 1;
            if &ours[key] != value {
                failures.push(format!(
                    "{name}.{key}:\n  swift {value}\n  rust  {}",
                    ours[key]
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} differences:\n{}",
        failures.len(),
        failures.join("\n")
    );
    assert!(cases.as_array().unwrap().len() >= 100);
    assert_eq!(compared, cases.as_array().unwrap().len() * 20);
}

#[test]
fn key_encoder_matches_swift() {
    let names = [
        ("up", TerminalKey::Up),
        ("down", TerminalKey::Down),
        ("left", TerminalKey::Left),
        ("right", TerminalKey::Right),
        ("home", TerminalKey::Home),
        ("end", TerminalKey::End),
        ("pageUp", TerminalKey::PageUp),
        ("pageDown", TerminalKey::PageDown),
        ("insert", TerminalKey::Insert),
        ("delete", TerminalKey::Delete),
        ("tab", TerminalKey::Tab),
        ("backTab", TerminalKey::BackTab),
        ("enter", TerminalKey::Enter),
        ("escape", TerminalKey::Escape),
        ("backspace", TerminalKey::Backspace),
    ];
    let mut checked = 0;
    for line in include_str!("fixtures/keys.txt").lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        if parts[0] == "code" {
            continue;
        }
        let key = names
            .iter()
            .find(|(name, _)| *name == parts[0])
            .map(|(_, key)| *key)
            .unwrap_or_else(|| TerminalKey::Function(parts[0][1..].parse().unwrap()));
        let flag = |i: usize| parts[i] == "1";
        let modifiers = KeyModifiers {
            shift: flag(2),
            control: flag(3),
            option: flag(4),
        };
        let bytes: String = keys::encode(key, flag(1), modifiers)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(bytes, parts.get(5).copied().unwrap_or(""), "{line}");
        checked += 1;
    }
    assert_eq!(checked, 27 * 16);
    // The keys Swift reads from key codes, by GPUI's names for them.
    assert_eq!(keys::key_for_name("tab", true), Some(TerminalKey::BackTab));
    assert_eq!(
        keys::key_for_name("f12", false),
        Some(TerminalKey::Function(12))
    );
    assert_eq!(keys::key_for_name("f13", false), None);
    assert_eq!(keys::key_for_name("a", false), None);
}

#[test]
fn control_and_paste_bytes() {
    assert_eq!(keys::control_bytes('c', false), Some(vec![3]));
    assert_eq!(keys::control_bytes('C', true), Some(vec![0x1b, 3]));
    assert_eq!(keys::control_bytes(' ', false), Some(vec![0]));
    assert_eq!(keys::control_bytes('-', false), Some(vec![0x1f]));
    assert_eq!(keys::control_bytes('?', false), Some(vec![0x7f]));
    assert_eq!(keys::control_bytes('1', false), None);
    assert_eq!(keys::paste_bytes("a\r\nb\nc", false), b"a\rb\rc");
    assert_eq!(
        keys::paste_bytes("x\u{1b}[201~y\u{9b}z", true),
        "\u{1b}[200~x[201~yz\u{1b}[201~".as_bytes()
    );
}

#[test]
fn widths_follow_swift() {
    for (scalar, cells) in [
        ('a', 1),
        ('\u{7}', 0),
        ('\u{301}', 0),
        ('漢', 2),
        ('😀', 2),
        ('\u{1f5a5}', 2),
        ('\u{1f321}', 2),
        ('é', 1),
        ('\u{200d}', 0),
        ('\u{fe0f}', 0),
        ('\u{1f3fd}', 2),
    ] {
        assert_eq!(width(scalar), cells, "{scalar:?}");
    }
}
