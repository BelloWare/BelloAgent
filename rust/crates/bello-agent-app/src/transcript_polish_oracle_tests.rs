//! The transcript polish's pure rules held to what Swift 0.1.122's own code
//! says (docs/validation/transcript-polish-2026-10-11): a capped card list's
//! split and its middle line, a read card's window label, the cards' grouped
//! numbers, the end-of-turn fold's line, the display modes, and a response
//! header's work words.
use super::{TranscriptDisplayMode, card_lines, read_presentation, response, turn_fold};
use serde_json::Value;

const SWIFT: &str =
    include_str!("../../../docs/validation/transcript-polish-2026-10-11/swift-polish.json");

fn swift() -> Value {
    serde_json::from_str(SWIFT).unwrap()
}
fn int(value: &Value, key: &str) -> i64 {
    value[key].as_i64().unwrap()
}
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap()
}

#[test]
fn a_capped_lists_split_and_middle_line_are_swifts() {
    let swift = swift();
    let cases = swift["splits"].as_array().unwrap();
    assert!(cases.len() > 150);
    for case in cases {
        let cap = card_lines::head_tail(
            int(case, "total") as usize,
            int(case, "maxLines") as usize,
            case["expanded"].as_bool().unwrap(),
        );
        assert_eq!(cap.hidden as i64, int(case, "hidden"), "{case}");
        assert_eq!(cap.capped, case["capped"].as_bool().unwrap(), "{case}");
        assert_eq!(cap.head as i64, int(case, "head"), "{case}");
        assert_eq!(cap.tail as i64, int(case, "tail"), "{case}");
        assert_eq!(
            card_lines::collapses(cap.hidden),
            case["collapses"].as_bool().unwrap()
        );
        assert_eq!(card_lines::more_lines(cap.hidden), text(case, "moreLines"));
    }
    let caps = &swift["caps"];
    assert_eq!(card_lines::MAX_LINES as i64, int(caps, "diffLines"));
    assert_eq!(read_presentation::READ_LINES as i64, int(caps, "readLines"));
    assert_eq!(super::TERMINAL_CAP as f64, caps["terminalCap"].as_f64().unwrap());
    assert_eq!(
        super::tool_presentation::SECTION_CAP as f64,
        caps["sectionCap"].as_f64().unwrap()
    );
}

#[test]
fn a_read_cards_window_and_the_cards_numbers_read_as_swifts() {
    let swift = swift();
    for case in swift["windows"].as_array().unwrap() {
        assert_eq!(
            read_presentation::window(int(case, "shown") as usize, int(case, "total") as usize),
            text(case, "label"),
            "{case}"
        );
    }
    for case in swift["numbers"].as_array().unwrap() {
        assert_eq!(
            card_lines::number(int(case, "value") as usize),
            text(case, "text")
        );
    }
}

#[test]
fn the_fold_line_and_the_display_modes_read_as_swifts() {
    let swift = swift();
    let folds = swift["folds"].as_array().unwrap();
    assert_eq!(folds.len(), 64);
    for case in folds {
        assert_eq!(
            turn_fold::label(
                int(case, "toolCalls") as usize,
                int(case, "messages") as usize,
                int(case, "subagents") as usize
            ),
            text(case, "label"),
            "{case}"
        );
    }
    for case in swift["subagents"].as_array().unwrap() {
        assert_eq!(
            turn_fold::subagent(text(case, "name")),
            case["subagent"].as_bool().unwrap()
        );
    }
    let modes = swift["modes"].as_array().unwrap();
    assert_eq!(modes.len(), 2);
    for (mode, case) in [TranscriptDisplayMode::Normal, TranscriptDisplayMode::Compact]
        .into_iter()
        .zip(modes)
    {
        assert_eq!(mode.label(), text(case, "label"));
        assert_eq!(mode.detail(), text(case, "detail"));
    }
    assert_eq!(text(&swift, "fallback"), "compact");
    assert_eq!(TranscriptDisplayMode::default(), TranscriptDisplayMode::Compact);
}

#[test]
fn a_response_headers_work_words_are_swifts() {
    let swift = swift();
    let cases = swift["works"].as_array().unwrap();
    assert_eq!(cases.len(), 45);
    for case in cases {
        let states: Vec<&str> = case["states"]
            .as_array()
            .unwrap()
            .iter()
            .map(|state| state.as_str().unwrap())
            .collect();
        let line = response::Line::of(text(case, "thinking"), text(case, "text"), states);
        assert_eq!(line.work, text(case, "work"), "{case}");
    }
}
