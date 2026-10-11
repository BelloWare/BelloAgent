//! TerminalView.swift's measures, colours, selection and reading position.
use super::*;
use bello_agent_core::terminal::TerminalEmulator;

#[::core::prelude::v1::test]
fn the_cell_is_one_advance_of_m_and_ceil_of_the_line() {
    // SF Mono at 12 points, as Swift measured it on macOS 14:
    // advance 7.41796875, ascent 11.6015625, descent 2.53125, no leading.
    let m = CellMetrics::from_font(7.417_968_8, 11.601_562_5, 2.531_25);
    assert_eq!(m.width, 7.417_968_8);
    assert_eq!(m.height, 17.);
    assert_eq!(m.baseline, 12.601_562_5);
    // Swift's fitGrid: the inset on each side, whole cells, at least 2 x 1.
    assert_eq!(m.grid(800., 240.), Some((105, 13)));
    assert_eq!(m.grid(16. + 2. * m.width, 16. + 17.), Some((2, 1)));
    assert_eq!(m.grid(30., 240.), None, "too narrow: the grid stays");
    assert_eq!(m.grid(800., 32.), None, "too short: the grid stays");
}

#[::core::prelude::v1::test]
fn colours_are_swifts() {
    let light = TerminalColors { dark: false };
    let dark = TerminalColors { dark: true };
    assert_eq!(
        (light.foreground(), light.background(), light.accent()),
        (0x1f1b17, 0xede4d8, 0xd67520)
    );
    assert_eq!(
        (dark.foreground(), dark.background(), dark.accent()),
        (0xf1ece5, 0x15120f, 0xf0a052)
    );
    assert_eq!(light.rgb(TerminalColor::Indexed(1), true), 0xb3312c);
    assert_eq!(dark.rgb(TerminalColor::Indexed(15), true), 0xf5f1ea);
    assert_eq!(light.rgb(TerminalColor::Indexed(16), true), 0x000000);
    assert_eq!(light.rgb(TerminalColor::Indexed(196), true), 0xff0000);
    assert_eq!(light.rgb(TerminalColor::Indexed(110), true), 0x87afd7);
    assert_eq!(light.rgb(TerminalColor::Indexed(232), true), 0x080808);
    assert_eq!(light.rgb(TerminalColor::Indexed(255), true), 0xeeeeee);
    assert_eq!(light.rgb(TerminalColor::Rgb(1, 2, 3), false), 0x010203);
    let mut style = CellStyle::PLAIN;
    assert_eq!(light.fill(&style), None);
    style.background = TerminalColor::Indexed(4);
    assert_eq!(light.fill(&style), Some(0x2a5aa6));
    style.inverse = true;
    style.foreground = TerminalColor::Standard;
    // Inverse paints the foreground behind and draws in the background.
    assert_eq!(light.fill(&style), Some(0x1f1b17));
    assert_eq!(light.glyph(&style), rgb(0x2a5aa6).into());
    style.dim = true;
    assert_eq!(light.glyph(&style).a, 0.6);
    let mut emulator = TerminalEmulator::new(10, 3, 100);
    dark.publish(&mut emulator);
    assert_eq!(emulator.default_background_rgb, (0x15, 0x12, 0x0f));
}

fn emulator_with(lines: &[&str], columns: usize, rows: usize) -> TerminalEmulator {
    let mut e = TerminalEmulator::new(columns, rows, 100);
    e.feed_str(&lines.join("\r\n"));
    e
}

#[::core::prelude::v1::test]
fn selection_reads_as_swifts_selected_text() {
    let e = emulator_with(&["one two  ", "three", "four"], 10, 3);
    let mut grid = GridState::default();
    let at = |line, column| Position { line, column };
    grid.anchor = Some(at(0, 4));
    grid.drag_to(at(1, 3));
    assert_eq!(grid.selected_text(&e).as_deref(), Some("two\nthr"));
    grid.drag_to(at(0, 2));
    assert_eq!(grid.selection, Some((at(0, 2), at(0, 4))));
    grid.mouse_up();
    assert!(grid.anchor.is_none());
    grid.anchor = Some(at(2, 1));
    grid.drag_to(at(2, 1));
    grid.mouse_up();
    assert_eq!(grid.selection, None, "a click selects nothing");
    grid.select_word(&e, at(0, 5));
    assert_eq!(grid.selected_text(&e).as_deref(), Some("two"));
    grid.select_word(&e, at(0, 8));
    assert_eq!(
        grid.selected_text(&e).as_deref(),
        Some("two"),
        "a blank selects no word"
    );
    grid.select_line(&e, at(1, 2));
    assert_eq!(grid.selected_text(&e).as_deref(), Some("three"));
    grid.select_all(&e);
    assert_eq!(
        grid.selected_text(&e).as_deref(),
        Some("one two\nthree\nfour")
    );
    let words = emulator_with(&["cd ~/a_b-c.d/e x"], 20, 1);
    grid.select_word(&words, at(0, 5));
    assert_eq!(grid.selected_text(&words).as_deref(), Some("~/a_b-c.d/e"));
}

#[::core::prelude::v1::test]
fn a_reader_scrolled_back_keeps_their_lines_as_output_arrives() {
    let mut e = emulator_with(&["a", "b", "c", "d", "e"], 10, 2);
    let mut grid = GridState::default();
    grid.output_arrived(&e);
    assert_eq!(grid.first_visible(&e), 3);
    grid.scroll_offset = 2;
    let first = grid.first_visible(&e);
    assert_eq!(first, 1);
    e.feed_str("\r\nf\r\ng");
    grid.output_arrived(&e);
    assert_eq!(grid.scroll_offset, 4);
    assert_eq!(grid.first_visible(&e), first);
    // Points map to cells inside the inset, clamped to the grid.
    let m = CellMetrics::from_font(7.5, 12., 3.);
    let p = grid.position(&e, m, INSET + 7.6, INSET + 18.);
    assert_eq!(
        p,
        Position {
            line: first + 1,
            column: 1
        }
    );
    let p = grid.position(&e, m, -40., 900.);
    assert_eq!(
        p,
        Position {
            line: first + 1,
            column: 0
        }
    );
}
