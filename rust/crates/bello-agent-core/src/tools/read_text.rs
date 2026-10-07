//! Swift Tools.swift FileToolContext.read and ViewerLines.read, with the
//! TextPreviews.swift byte-prefix/lossy/edge-replacement-character behavior.
//! Kept separate from acquisition: source file and decoding errors must precede
//! offset/limit validation. This is not a complete read-tool implementation.
use super::{ToolError, ToolResult, bounded_int, result_text};
use serde_json::{Value, json};

pub(super) const PREVIEW_BYTES: usize = 32_768;

pub(super) fn render(text: &str, path: &str, arguments: &Value) -> ToolResult<Value> {
    let offset = bounded_int(&arguments["offset"], 1, 10_000_000)?;
    let count = bounded_int(&arguments["limit"], 2_000, 10_000)?;
    if offset == 0 || count == 0 {
        return Err(ToolError::failure(
            "tool_arguments",
            "Line offset and limit must be positive",
        ));
    }
    // split, unlike lines(), keeps final empty rows and literal CR bytes.
    // Track a borrowed contiguous slice instead of allocating one pointer per
    // source line (a 16 MiB all-newline file has over 16 million lines).
    let mut total_lines = 0;
    let mut position = 0;
    let mut start = None;
    let mut end = 0;
    for (index, line) in text.split('\n').enumerate() {
        if index == offset - 1 {
            start = Some(position);
        }
        if index >= offset - 1 && index < offset - 1 + count {
            end = position + line.len();
        }
        position += line.len() + 1;
        total_lines += 1;
    }
    let selected = start.map_or("", |start| &text[start..end]);
    let bounded = preview(selected, PREVIEW_BYTES);
    let truncated = offset - 1 + count < total_lines || bounded.len() < selected.len();
    let output = if truncated {
        format!(
            "{bounded}\n[Truncated. {} total lines; read another range.]",
            total_lines
        )
    } else {
        bounded
    };
    let mut result = result_text(output, false);
    result["stats"] = json!({"path": path});
    if let Some((first, last)) =
        start.and_then(|start| viewer_range(text, start, selected.len(), PREVIEW_BYTES))
    {
        result["stats"]["line"] = json!(first);
        result["stats"]["lastLine"] = json!(last);
    }
    Ok(result)
}

fn preview(text: &str, maximum: usize) -> String {
    String::from_utf8_lossy(&text.as_bytes()[..text.len().min(maximum)])
        .trim_matches('\u{fffd}')
        .to_owned()
}

fn viewer_range(text: &str, start: usize, length: usize, bound: usize) -> Option<(usize, usize)> {
    if length == 0 {
        return None;
    }
    let end = start + length.min(bound);
    let bytes = text.as_bytes();
    if end > bytes.len() {
        return None;
    }
    let whole = length <= bound && bytes[end - 1] == b'\n';
    let through = if whole { end } else { end - 1 };
    let mut line = 1;
    let mut first = 1;
    for index in 0..through {
        if index == start {
            first = line;
        }
        if bytes[index] == b'\n' || (bytes[index] == b'\r' && bytes.get(index + 1) != Some(&b'\n'))
        {
            line += 1;
        }
    }
    if start == through {
        first = line;
    }
    Some((first, line))
}

#[cfg(test)]
fn viewer_read(
    text: &str,
    split: &[&str],
    offset: usize,
    count: usize,
    bound: usize,
) -> Option<(usize, usize)> {
    if offset == 0 || count == 0 || offset > split.len() {
        return None;
    }
    let taken = &split[offset - 1..split.len().min(offset - 1 + count)];
    let length = taken.iter().map(|line| line.len()).sum::<usize>() + taken.len() - 1;
    let start = split[..offset - 1]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>();
    viewer_range(text, start, length, bound)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn read(text: &str, args: Value) -> Value {
        render(text, "/fixture", &args).unwrap()
    }
    #[test]
    fn lf_paging_preserves_cr_and_final_empty_line() {
        let value = read("a\r\nb\rc\n", json!({}));
        assert_eq!(value["content"][0]["text"], "a\r\nb\rc\n");
        assert_eq!(
            value["stats"],
            json!({"path":"/fixture", "line":1,"lastLine":4})
        );
        let page = read("a\r\nb\rc\n", json!({"offset":2,"limit":1}));
        assert_eq!(
            page["content"][0]["text"],
            "b\rc\n[Truncated. 3 total lines; read another range.]"
        );
        assert_eq!(page["stats"]["line"], 2);
        assert_eq!(page["stats"]["lastLine"], 3);
        assert_eq!(
            read("a\n", json!({"offset":2}))["stats"],
            json!({"path":"/fixture"})
        );
    }
    #[test]
    fn empty_and_outside_selection_return_no_viewer_range() {
        for (text, offset) in [("", 1), ("a", 2), ("a\n", 3)] {
            let value = read(text, json!({"offset":offset}));
            assert_eq!(value["content"][0]["text"], "");
            assert_eq!(value["stats"], json!({"path":"/fixture"}));
        }
    }
    #[test]
    fn byte_preview_lossily_trims_both_real_and_cut_replacements() {
        assert_eq!(preview("\u{fffd}a\u{fffd}", 100), "a");
        assert_eq!(preview("aé", 2), "a");
        assert_eq!(preview("a\u{fffd}b", 100), "a\u{fffd}b");
        let text = format!("{}é\nnext", "a".repeat(PREVIEW_BYTES - 1));
        let value = read(&text, json!({}));
        assert!(
            value["content"][0]["text"]
                .as_str()
                .unwrap()
                .ends_with("\n[Truncated. 2 total lines; read another range.]")
        );
        assert_eq!(value["stats"]["lastLine"], 1);
    }
    #[test]
    fn range_errors_and_source_caps_are_exact() {
        for args in [json!({"offset":0}), json!({"limit":0})] {
            assert_eq!(
                render("a", "/fixture", &args).unwrap_err().code(),
                Some("tool_arguments")
            );
        }
        for args in [
            json!({"offset":10_000_001}),
            json!({"limit":10_001}),
            json!({"offset":-1}),
            json!({"limit":"1"}),
            json!({"offset":1.5}),
        ] {
            assert_eq!(
                render("a", "/fixture", &args).unwrap_err().code(),
                Some("invalid_range")
            );
        }
        assert!(
            render(
                "a",
                "/fixture",
                &json!({"offset":10_000_000,"limit":10_000})
            )
            .is_ok()
        );
        assert_eq!(
            read("a", json!({"offset":null,"limit":null}))["content"][0]["text"],
            "a"
        );
    }
    #[test]
    fn viewer_range_counts_crlf_as_one_even_at_cut() {
        let text = "x\r\ny\rz";
        let split = text.split('\n').collect::<Vec<_>>();
        assert_eq!(viewer_read(text, &split, 1, 2, 2), Some((1, 1)));
        assert_eq!(viewer_read(text, &split, 1, 2, 3), Some((1, 1)));
        assert_eq!(viewer_read(text, &split, 1, 2, 4), Some((1, 2)));
        assert_eq!(viewer_read(text, &split, 2, 1, 100), Some((2, 3)));
    }
    #[test]
    fn real_edge_replacement_characters_trigger_source_truncation_notice() {
        assert_eq!(
            read("\u{fffd}a\u{fffd}", json!({}))["content"][0]["text"],
            "a\n[Truncated. 1 total lines; read another range.]"
        );
    }

    #[test]
    fn source_viewer_corpus_covers_empty_lines_bare_cr_and_byte_cuts() {
        for (text, offset, count, bound, expected) in [
            ("a\nb\nc\nd", 2, 2, 32768, Some((2, 3))),
            ("a\nb\nc\nd", 1, 2000, 32768, Some((1, 4))),
            ("a\n", 1, 2, 32768, Some((1, 2))),
            ("a\n", 1, 1, 32768, Some((1, 1))),
            ("a\n", 2, 1, 32768, None),
            ("\n\n", 2, 2, 32768, Some((2, 3))),
            ("a\nb", 3, 2000, 32768, None),
            ("abc\ndef\nghi", 1, 2000, 5, Some((1, 2))),
            ("abc\ndef\nghi", 1, 2000, 4, Some((1, 1))),
            ("a\rb\rc", 1, 1, 32768, Some((1, 3))),
            ("a\rb\nc\rd", 2, 1, 32768, Some((3, 4))),
            ("a\r\nb\r\nc", 2, 1, 32768, Some((2, 2))),
            ("a\r\nb\r\n", 1, 3, 32768, Some((1, 3))),
            ("é\nü\nx", 2, 2, 32768, Some((2, 3))),
        ] {
            assert_eq!(
                viewer_read(
                    text,
                    &text.split('\n').collect::<Vec<_>>(),
                    offset,
                    count,
                    bound
                ),
                expected,
                "{text:?}"
            );
        }
    }
}
