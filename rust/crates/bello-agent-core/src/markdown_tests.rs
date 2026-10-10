use super::{Alignment, Block, Span, Style, parse, safe_url};
use serde_json::{Value, json};

/// `TranscriptMarkdown.parse` from Swift 0.1.122 (6319e368) on a fixed corpus,
/// prose and user styles. Harness: rust/docs/validation/markdown-swift-oracle-2026-10-10.
const CORPUS: &str = include_str!("../tests/data/markdown/corpus.json");
const SWIFT_PROSE: &str = include_str!("../tests/data/markdown/swift-prose.json");
const SWIFT_USER: &str = include_str!("../tests/data/markdown/swift-user.json");

fn span(span: &Span) -> Value {
    let mut value = json!({"text": span.text, "size": span.size});
    let object = value.as_object_mut().unwrap();
    for (key, on) in [
        ("bold", span.bold),
        ("italic", span.italic),
        ("mono", span.mono),
        ("serif", span.serif),
        ("code", span.code),
        ("strike", span.strike),
    ] {
        if on {
            object.insert(key.into(), json!(true));
        }
    }
    if let Some(link) = &span.link {
        object.insert("link".into(), json!(link));
    }
    value
}

fn spans(spans: &[Span]) -> Value {
    Value::Array(spans.iter().map(span).collect())
}

fn block(value: &Block) -> Value {
    match value {
        Block::Paragraph(text) => json!({"paragraph": spans(text)}),
        Block::Heading {
            level,
            spans: text,
            plain,
        } => json!({"heading": level, "spans": spans(text), "plain": plain}),
        Block::Code { language, code } => json!({"code": code, "language": language}),
        Block::List {
            ordered,
            start,
            items,
        } => json!({
            "list": items.iter().map(|item| item.iter().map(block).collect::<Vec<_>>()).collect::<Vec<_>>(),
            "ordered": ordered,
            "start": start,
        }),
        Block::Quote(blocks) => json!({"quote": blocks.iter().map(block).collect::<Vec<_>>()}),
        Block::Table {
            alignments,
            header,
            rows,
        } => json!({
            "alignments": alignments.iter().map(|alignment| match alignment {
                Alignment::Left => "left",
                Alignment::Center => "center",
                Alignment::Right => "right",
            }).collect::<Vec<_>>(),
            "header": header.iter().map(|cell| spans(cell)).collect::<Vec<_>>(),
            "table": rows.iter().map(|row| row.iter().map(|cell| spans(cell)).collect::<Vec<_>>()).collect::<Vec<_>>(),
        }),
    }
}

/// Equal JSON, with sizes compared as the floats Swift computed in CGFloat.
fn same(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => {
            (a.as_f64().unwrap() - b.as_f64().unwrap()).abs() < 1e-3
        }
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, value)| b.get(key).is_some_and(|other| same(value, other)))
        }
        _ => left == right,
    }
}

fn check(style: Style, oracle: &str) {
    let corpus: Vec<String> = serde_json::from_str(CORPUS).unwrap();
    let expected: Vec<Value> = serde_json::from_str(oracle).unwrap();
    assert_eq!(corpus.len(), expected.len());
    let mut different = Vec::new();
    for (index, (source, expected)) in corpus.iter().zip(&expected).enumerate() {
        let actual = Value::Array(parse(source, style).iter().map(block).collect());
        if !same(&actual, expected) {
            different.push(format!(
                "case {index} {source:?}\n  swift: {expected}\n  rust:  {actual}"
            ));
        }
    }
    assert!(
        different.is_empty(),
        "{} of {} cases differ from Swift:\n{}",
        different.len(),
        corpus.len(),
        different.join("\n")
    );
}

#[test]
fn prose_reads_as_swift_reads_it() {
    check(Style::PROSE, SWIFT_PROSE);
}

#[test]
fn user_messages_keep_their_line_breaks_as_swift_does() {
    check(Style::USER, SWIFT_USER);
}

/// Deliberate difference: Foundation gives an empty cell no run, so Swift
/// drops it and the row's later cells shift into the wrong columns. Rust
/// keeps every cell in its column.
#[test]
fn empty_table_cells_keep_their_column() {
    let blocks = parse("| a | b | c |\n|---|---|---|\n| 1 |  | 3 |", Style::PROSE);
    let [Block::Table { header, rows, .. }] = blocks.as_slice() else {
        panic!("one table: {blocks:?}");
    };
    assert_eq!(header.len(), 3);
    assert_eq!(rows[0].len(), 3);
    assert!(rows[0][1].is_empty());
    assert_eq!(rows[0][2][0].text, "3");
}

#[test]
fn only_plain_web_links_survive() {
    assert_eq!(
        safe_url("https://example.com/a?b=1").as_deref(),
        Some("https://example.com/a?b=1")
    );
    assert!(safe_url("http://example.com").is_some());
    for unsafe_link in [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "mailto:a@b.c",
        "https://user:pass@example.com",
        "https://user@example.com",
        "/relative/path",
        "//protocol.relative",
        "data:text/html,hi",
    ] {
        assert_eq!(safe_url(unsafe_link), None, "{unsafe_link}");
    }
}

/// Differential run against a larger Swift oracle outside the repository:
/// BELLO_MARKDOWN_ORACLE_DIR holds generated.json and its
/// generated-swift-{prose,user}.json (harness in the validation record).
#[test]
fn generated_documents_read_as_swift_reads_them() {
    let Ok(directory) = std::env::var("BELLO_MARKDOWN_ORACLE_DIR") else {
        return;
    };
    let read = |name: &str| std::fs::read_to_string(format!("{directory}/{name}")).unwrap();
    let corpus: Vec<String> = serde_json::from_str(&read("generated.json")).unwrap();
    for (style, oracle) in [
        (Style::PROSE, "generated-swift-prose.json"),
        (Style::USER, "generated-swift-user.json"),
    ] {
        let expected: Vec<Value> = serde_json::from_str(&read(oracle)).unwrap();
        let actual: Vec<Value> = corpus
            .iter()
            .map(|source| Value::Array(parse(source, style).iter().map(block).collect()))
            .collect();
        std::fs::write(
            format!("{directory}/rust-{oracle}"),
            serde_json::to_string(&actual).unwrap(),
        )
        .unwrap();
        let mut different = Vec::new();
        for (index, (source, expected)) in corpus.iter().zip(&expected).enumerate() {
            let actual = Value::Array(parse(source, style).iter().map(block).collect());
            if !same(&actual, expected) {
                different.push(format!(
                    "case {index} {source:?}\n  swift: {expected}\n  rust:  {actual}"
                ));
            }
        }
        assert!(
            different.is_empty(),
            "{oracle}: {} of {} documents differ:\n{}",
            different.len(),
            corpus.len(),
            different
                .iter()
                .take(6)
                .cloned()
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
}
