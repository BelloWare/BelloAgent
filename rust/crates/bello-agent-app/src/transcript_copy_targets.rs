//! Swift 0.1.122's copy targets for a reply (`Transcript/TranscriptCopy.swift`):
//! the introduction (or the whole reply when it has no headings), each
//! heading's section through its subsections, and each code block, found by
//! a line scanner in the reply's own Markdown, so a copy is the author's
//! bytes, never a re-rendering.
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TargetKind {
    Introduction,
    Whole,
    Section(usize),
    Code,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CopyTarget {
    pub kind: TargetKind,
    pub label: String,
    pub text: String,
}

pub(crate) const MAXIMUM_BYTES: usize = 65_536;

struct Line<'a> {
    start: usize,
    end: usize,
    next: usize,
    text: &'a str,
}

fn lines(source: &str) -> Vec<Line<'_>> {
    let bytes = source.as_bytes();
    let mut lines = Vec::new();
    let mut cursor = 0;
    while cursor < source.len() {
        let mut end = cursor;
        while end < bytes.len() && bytes[end] != b'\n' && bytes[end] != b'\r' {
            end += 1;
        }
        // A CRLF pair is one line ending.
        let next = if end + 1 < bytes.len() && bytes[end] == b'\r' && bytes[end + 1] == b'\n' {
            end + 2
        } else if end < bytes.len() {
            end + 1
        } else {
            end
        };
        lines.push(Line {
            start: cursor,
            end,
            next,
            text: &source[cursor..end],
        });
        cursor = next;
    }
    lines
}

fn indentation(text: &str) -> usize {
    text.chars().take_while(|c| *c == ' ').count()
}

/// Foundation's `.whitespaces`: tabs and the Unicode space separators.
fn space(c: char) -> bool {
    c == '\t'
        || (c.is_whitespace()
            && !matches!(
                c,
                '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

fn trim_spaces(text: &str) -> &str {
    text.trim_matches(space)
}

fn drop_chars(text: &str, count: usize) -> &str {
    let at = text.char_indices().nth(count).map_or(text.len(), |(at, _)| at);
    &text[at..]
}

struct Fence<'a> {
    prefix: String,
    character: char,
    length: usize,
    #[allow(dead_code)]
    rest: &'a str,
}

/// A fence opener at up to three spaces of indentation, inside any quote
/// and list markers.
fn fence(text: &str) -> Option<Fence<'_>> {
    let mut body = text;
    let mut prefix = 0;
    loop {
        let trimmed = body.trim_start_matches([' ', '\t']);
        if let Some(after) = trimmed.strip_prefix('>') {
            body = after.strip_prefix(' ').unwrap_or(after);
            prefix = text.len() - body.len();
            continue;
        }
        let mut chars = trimmed.chars();
        if let (Some(first), Some(' ')) = (chars.next(), chars.next())
            && matches!(first, '-' | '*' | '+')
        {
            body = &trimmed[2..];
            prefix = text.len() - body.len();
            continue;
        }
        break;
    }
    let indent = indentation(body);
    if indent > 3 {
        return None;
    }
    let candidate = &body[indent..];
    let character = candidate.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let length = candidate.chars().take_while(|c| *c == character).count();
    if length < 3 {
        return None;
    }
    let rest = &candidate[length..];
    if character == '`' && rest.contains('`') {
        return None;
    }
    Some(Fence {
        prefix: text[..prefix].to_owned() + &" ".repeat(indent),
        character,
        length,
        rest,
    })
}

fn stripping_prefix<'a>(text: &'a str, prefix: &str) -> &'a str {
    let mut remaining = text;
    let mut expected = prefix.chars();
    loop {
        let (Some(p), Some(t)) = (expected.clone().next(), remaining.chars().next()) else {
            break;
        };
        if p == t || (p == ' ' && t == '\t') {
            expected.next();
            remaining = &remaining[t.len_utf8()..];
        } else {
            break;
        }
    }
    remaining
}

fn atx_heading(text: &str) -> Option<(usize, String)> {
    let body = drop_chars(text, indentation(text).min(3));
    let level = body.chars().take_while(|c| *c == '#').count();
    if !(1..=6).contains(&level) {
        return None;
    }
    let after = &body[level..];
    if !(after.is_empty() || after.starts_with(' ') || after.starts_with('\t')) {
        return None;
    }
    let mut title = trim_spaces(after).to_owned();
    while title.ends_with('#') {
        title.pop();
    }
    Some((level, trim_spaces(&title).to_owned()))
}

fn setext_underline(text: &str) -> Option<usize> {
    let body = trim_spaces(drop_chars(text, indentation(text).min(3)));
    let first = body.chars().next().filter(|c| *c == '=' || *c == '-')?;
    body.chars()
        .all(|c| c == first)
        .then_some(if first == '=' { 1 } else { 2 })
}

fn is_container_line(text: &str) -> bool {
    let trimmed = text.trim_start_matches(' ');
    if trimmed.starts_with('>') {
        return true;
    }
    let mut chars = trimmed.chars();
    if let (Some(first), Some(' ')) = (chars.next(), chars.next())
        && matches!(first, '-' | '*' | '+')
    {
        return true;
    }
    if let Some((at, c)) = trimmed.char_indices().find(|(_, c)| !c.is_numeric())
        && at > 0
        && (c == '.' || c == ')')
        && trimmed[at + 1..].starts_with(' ')
    {
        return true;
    }
    false
}

fn blank(text: &str) -> bool {
    text.chars().all(|c| c == ' ' || c == '\t')
}

/// Every target in reading order: the introduction (or the whole reply),
/// then sections, then code blocks. A reply over 64 KiB has none.
pub(crate) fn targets(source: &str) -> Vec<CopyTarget> {
    if source.len() > MAXIMUM_BYTES {
        return Vec::new();
    }
    let lines = lines(source);
    let mut headings: Vec<(usize, String, usize)> = Vec::new();
    let mut codes: Vec<String> = Vec::new();
    let mut index = 0;
    let mut previous_blank = true;
    while index < lines.len() {
        let line = &lines[index];
        if let Some(fence) = fence(line.text) {
            // Collect until a matching closer; an unterminated fence runs to the end.
            let mut body_end = source.len();
            let mut close = index + 1;
            while close < lines.len() {
                let stripped = stripping_prefix(lines[close].text, &fence.prefix);
                let trimmed = stripped.trim_start_matches(' ');
                let run = trimmed.chars().take_while(|c| *c == fence.character).count();
                if indentation(stripped) <= 3
                    && run >= fence.length
                    && trimmed
                        .trim_start_matches(fence.character)
                        .chars()
                        .all(|c| c == ' ' || c == '\t')
                {
                    body_end = lines[close].start;
                    break;
                }
                close += 1;
            }
            if close >= lines.len() {
                close = lines.len() - 1;
            }
            let mut code = String::new();
            let mut cursor = index + 1;
            while cursor < lines.len() && lines[cursor].start < body_end {
                let content = &lines[cursor];
                code.push_str(stripping_prefix(content.text, &fence.prefix));
                code.push_str(&source[content.end..content.next.min(body_end).max(content.end)]);
                cursor += 1;
            }
            if !code.trim().is_empty() {
                codes.push(code);
            }
            index = close + 1;
            previous_blank = false;
            continue;
        }
        let is_blank = blank(line.text);
        if indentation(line.text) >= 4 && previous_blank && !is_blank {
            // An indented code block: every following indented line, less four spaces.
            let mut code = String::new();
            let mut cursor = index;
            while cursor < lines.len()
                && !blank(lines[cursor].text)
                && indentation(lines[cursor].text) >= 4
            {
                let content = &lines[cursor];
                code.push_str(&content.text[4..]);
                if cursor + 1 < lines.len() {
                    code.push_str(&source[content.end..content.next]);
                }
                cursor += 1;
            }
            codes.push(code);
            index = cursor;
            previous_blank = false;
            continue;
        }
        if !is_container_line(line.text) {
            if let Some((level, title)) = atx_heading(line.text).filter(|_| !is_blank) {
                headings.push((level, title, line.start));
            } else if !is_blank
                && index + 1 < lines.len()
                && let Some(level) = setext_underline(lines[index + 1].text)
                && !lines[index + 1].text.is_empty()
                && !is_container_line(lines[index + 1].text)
            {
                headings.push((level, trim_spaces(line.text).to_owned(), line.start));
                index += 2;
                previous_blank = false;
                continue;
            }
        }
        previous_blank = is_blank;
        index += 1;
    }
    let mut targets = Vec::new();
    let introduction = &source[..headings.first().map_or(source.len(), |heading| heading.2)];
    if !introduction.trim().is_empty() {
        targets.push(if headings.is_empty() {
            CopyTarget {
                kind: TargetKind::Whole,
                label: "Copy as Markdown".into(),
                text: introduction.to_owned(),
            }
        } else {
            CopyTarget {
                kind: TargetKind::Introduction,
                label: "Copy introduction as Markdown".into(),
                text: introduction.to_owned(),
            }
        });
    }
    for (position, (level, title, start)) in headings.iter().enumerate() {
        let end = headings[position + 1..]
            .iter()
            .find(|next| next.0 <= *level)
            .map_or(source.len(), |next| next.2);
        let title: String = title.graphemes(true).take(100).collect();
        targets.push(CopyTarget {
            kind: TargetKind::Section(*level),
            label: format!(
                "Copy {} as Markdown",
                if title.is_empty() { "section" } else { &title }
            ),
            text: source[*start..end].to_owned(),
        });
    }
    for code in codes {
        targets.push(CopyTarget {
            kind: TargetKind::Code,
            label: "Copy code".into(),
            text: code,
        });
    }
    targets
}

#[cfg(test)]
mod tests {
    use super::{TargetKind, targets};

    /// Swift's `TranscriptCopy.targets` over the Markdown corpus
    /// (`docs/validation/reply-actions-2026-10-11/copy-oracle/targets.json`).
    #[test]
    fn targets_are_swifts_targets() {
        let oracle: serde_json::Value = serde_json::from_str(include_str!(
            "../../../docs/validation/reply-actions-2026-10-11/copy-oracle/targets.json"
        ))
        .unwrap();
        let cases = oracle.as_array().unwrap();
        for case in cases {
            let source = case["source"].as_str().unwrap();
            let expected: Vec<(String, String, String)> = case["targets"]
                .as_array()
                .unwrap()
                .iter()
                .map(|target| {
                    (
                        target[0].as_str().unwrap().to_owned(),
                        target[1].as_str().unwrap().to_owned(),
                        target[2].as_str().unwrap().to_owned(),
                    )
                })
                .collect();
            let actual: Vec<(String, String, String)> = targets(source)
                .into_iter()
                .map(|target| {
                    let kind = match target.kind {
                        TargetKind::Introduction => "introduction".to_owned(),
                        TargetKind::Whole => "whole".to_owned(),
                        TargetKind::Section(level) => format!("section{level}"),
                        TargetKind::Code => "code".to_owned(),
                    };
                    (kind, target.label, target.text)
                })
                .collect();
            assert_eq!(actual, expected, "{source:?}");
        }
        assert!(cases.len() > 120);
    }
}
