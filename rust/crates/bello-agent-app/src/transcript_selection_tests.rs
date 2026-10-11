use super::{ReplyText, quoted_draft};
use bello_agent_core::markdown::{Style, parse};

fn text(source: &str) -> ReplyText {
    ReplyText::new(&parse(source, Style::PROSE), "r")
}

/// Swift's own builder, assembler and `copyText`, run over the Markdown
/// corpus and ranges of each text
/// (`docs/validation/reply-actions-2026-10-11/copy-oracle`): Rust's text is
/// Swift's storage, character for character, and every copy is Swift's.
#[test]
fn copies_are_swifts_copies() {
    let oracle: serde_json::Value = serde_json::from_str(include_str!(
        "../../../docs/validation/reply-actions-2026-10-11/copy-oracle/copies.json"
    ))
    .unwrap();
    let mut compared = 0;
    let mut skipped = Vec::new();
    for case in oracle.as_array().unwrap() {
        let source = case["source"].as_str().unwrap();
        let units: Vec<u16> = case["text"]
            .as_array()
            .unwrap()
            .iter()
            .map(|unit| unit.as_u64().unwrap() as u16)
            .collect();
        let reply = text(source);
        let storage = reply.storage();
        if storage.encode_utf16().collect::<Vec<_>>() != units {
            // Swift drops an empty table cell and shifts the row's later
            // cells left; Rust keeps each cell in its column (see the
            // Markdown oracle's notes). Nothing else may differ.
            assert!(
                source.contains('|'),
                "{source:?}: {storage:?} vs {:?}",
                String::from_utf16_lossy(&units)
            );
            skipped.push(source.to_owned());
            continue;
        }
        // UTF-16 offsets to bytes.
        let mut bytes = vec![0usize; units.len() + 1];
        let mut at = 0;
        let mut unit = 0;
        for ch in storage.chars() {
            for _ in 0..ch.len_utf16() {
                bytes[unit] = at;
                unit += 1;
            }
            at += ch.len_utf8();
        }
        bytes[unit] = at;
        for copy in case["copies"].as_array().unwrap() {
            let (start, end) = (
                copy[0].as_u64().unwrap() as usize,
                copy[1].as_u64().unwrap() as usize,
            );
            let expected = copy[2].as_str().unwrap();
            assert_eq!(
                reply.copy(bytes[start]..bytes[end]),
                expected,
                "{source:?} {start}..{end}"
            );
            compared += 1;
        }
    }
    assert!(compared > 7_000, "{compared}");
    assert!(skipped.len() <= 2, "{skipped:?}");
}

#[test]
fn owners_name_the_elements_markdown_draws() {
    let reply =
        text("Intro\n\n- one\n- ```\n  code\n  ```\n\n> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |");
    let owners: Vec<&str> = reply
        .pieces
        .iter()
        .map(|piece| piece.owner.as_ref())
        .collect();
    assert_eq!(
        owners,
        [
            "r.0", "r.1.0m", "r.1.0.0", "r.1.1m", "r.1.1.0", "r.2.0", "r.3.0.0", "r.3.0.1",
            "r.3.1.0", "r.3.1.1"
        ]
    );
    assert_eq!(reply.piece("r.1.1.0"), Some(4));
    assert_eq!(
        reply.copy(0..reply.len),
        "Intro\n\n- one\n- \ncode\n\nquote\n\na\tb\n1\t2"
    );
}

#[test]
fn a_marker_copies_once_and_whole() {
    let reply = text("1. first\n2. second");
    let second = reply.piece("r.0.1m").unwrap();
    let marker = reply.pieces[second].range();
    // A selection that cuts the marker still copies it whole.
    assert_eq!(reply.copy(marker.start + 1..reply.len), "2. second");
    assert_eq!(reply.copy(0..marker.start + 1), "1. first\n2. ");
}

#[test]
fn a_preview_note_is_never_copied() {
    let rows: String = (0..45).map(|row| format!("| {row} | x |\n")).collect();
    let reply = text(&format!("| a | b |\n|---|---|\n{rows}"));
    assert_eq!(
        reply.pieces[0].text,
        "Preview · first 20 of 45 rows · up to 8 columns"
    );
    let copy = reply.copy(0..reply.len);
    assert!(copy.starts_with("a\tb\n0\tx\n"), "{copy:?}");
    assert!(copy.ends_with("19\tx"), "{copy:?}");
}

#[test]
fn double_and_triple_clicks_take_a_word_and_a_paragraph() {
    let reply = text("Hello wide world.\n\n- item text");
    assert_eq!(reply.word(7), 6..10);
    assert_eq!(&reply.pieces[0].text[reply.word(0)], "Hello");
    assert_eq!(reply.paragraph(3), 0..17);
    let item = reply.piece("r.1.0.0").unwrap();
    let at = reply.pieces[item].start + 1;
    // The paragraph of a list item's text starts at its marker.
    assert_eq!(reply.copy(reply.paragraph(at)), "- item text");
}

#[test]
fn quotes_each_line_below_the_draft() {
    assert_eq!(
        quoted_draft("", "one\r\ntwo\rthree"),
        "> one\n> two\n> three\n\n"
    );
    assert_eq!(quoted_draft("Draft", "x"), "Draft\n\n> x\n\n");
}
