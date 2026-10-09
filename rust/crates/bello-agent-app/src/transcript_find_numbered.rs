//! Background-prepared mapping of retained source spans into ReadWindow previews.
//! Metadata is O(requested spans), not O(source lines). Generated prefixes, empty
//! line placeholders, fold labels and separated truncation notes have no mapping.
use std::{
    ops::Range,
    sync::atomic::{AtomicBool, Ordering},
};

#[derive(Clone, Debug)]
struct Span {
    source: Range<usize>,
    line: usize,
    raw: usize,
}
#[derive(Clone, Debug)]
pub(crate) struct NumberedPreviewMap {
    spans: Vec<Span>,
    lines: usize,
    raw_len: usize,
    head_end: usize,
    tail_start: usize,
}
impl NumberedPreviewMap {
    /// Call only on the background preparation path, with bounded requested spans.
    pub fn new(
        source: &str,
        ranges: &[Range<usize>],
        selected: Option<&Range<usize>>,
        cancel: &AtomicBool,
    ) -> Result<Self, &'static str> {
        let mut requested: Vec<_> = ranges
            .iter()
            .chain(selected)
            .filter(|r| r.start < r.end && source.get((*r).clone()).is_some())
            .cloned()
            .collect();
        requested.sort_unstable_by_key(|r| (r.start, r.end));
        requested.dedup();
        let mut spans = Vec::with_capacity(requested.len());
        let last = source.rsplit('\n').next().unwrap_or("");
        let has_note = last.starts_with("[Truncated.") && last.ends_with(']');
        let body = if has_note {
            &source[..source.len().saturating_sub(last.len() + 1)]
        } else {
            source
        };
        let no_lines = source.is_empty() || (has_note && source.len() == last.len());
        let mut source_start = 0usize;
        let mut raw_cursor = 0usize;
        let mut lines = 0usize;
        let mut head_end = 0usize;
        let mut tail = [0usize; 6];
        let mut next = 0usize;
        if !no_lines {
            for line in body.split('\n') {
                if cancel.load(Ordering::Acquire) {
                    return Err("Find cancelled.");
                }
                let end = source_start + line.len();
                while next < requested.len() && requested[next].start <= end {
                    let range = &requested[next];
                    if range.start >= source_start && range.end <= end {
                        spans.push(Span {
                            source: range.clone(),
                            line: lines,
                            raw: raw_cursor + range.start - source_start,
                        });
                    }
                    next += 1;
                }
                tail[lines % 6] = raw_cursor;
                lines += 1;
                raw_cursor += line.len().max(1) + 1;
                if lines == 6 {
                    head_end = raw_cursor;
                }
                source_start = end + 1;
            }
        }
        if cancel.load(Ordering::Acquire) {
            return Err("Find cancelled.");
        }
        Ok(Self {
            spans,
            lines,
            raw_len: raw_cursor.saturating_sub(1),
            head_end,
            tail_start: if lines >= 6 { tail[lines % 6] } else { 0 },
        })
    }
    pub fn map_range(
        &self,
        range: &Range<usize>,
        first_line: usize,
        expanded: bool,
    ) -> Option<Range<usize>> {
        let index = self
            .spans
            .binary_search_by_key(&(range.start, range.end), |s| {
                (s.source.start, s.source.end)
            })
            .ok()?;
        let span = &self.spans[index];
        let folded = self.lines > 13 && !expanded;
        let (raw, digits, prefix_count) = if folded && span.line >= 6 {
            if span.line < self.lines - 6 {
                return None;
            }
            let tail_index = span.line - (self.lines - 6);
            (
                self.head_end
                    .checked_add(self.fold_label_len() + 1)?
                    .checked_add(span.raw.checked_sub(self.tail_start)?)?,
                digit_sum(first_line, 6)?.checked_add(digit_sum(
                    first_line.checked_add(self.lines - 6)?,
                    tail_index + 1,
                )?)?,
                7 + tail_index,
            )
        } else {
            (
                span.raw,
                digit_sum(first_line, span.line + 1)?,
                span.line + 1,
            )
        };
        let start = raw
            .checked_add(digits)?
            .checked_add(prefix_count.checked_mul(2)?)?;
        Some(start..start.checked_add(range.end.checked_sub(range.start)?)?)
    }
    /// A cheap render-time stale-layout guard; exact source identity remains the
    /// caller's responsibility. Equal length alone does not establish identity.
    pub fn expected_len(&self, first_line: usize, expanded: bool) -> Option<usize> {
        if self.lines > 13 && !expanded {
            self.head_end
                .checked_add(self.fold_label_len() + 1)?
                .checked_add(self.raw_len.checked_sub(self.tail_start)?)?
                .checked_add(digit_sum(first_line, 6)?)?
                .checked_add(digit_sum(first_line.checked_add(self.lines - 6)?, 6)?)?
                .checked_add(24)
        } else {
            self.raw_len
                .checked_add(digit_sum(first_line, self.lines)?)?
                .checked_add(self.lines.checked_mul(2)?)
        }
    }
    fn fold_label_len(&self) -> usize {
        "…  more lines".len() + decimal_digits(self.lines - 12)
    }
}
fn decimal_digits(mut n: usize) -> usize {
    let mut digits = 1;
    while n >= 10 {
        n /= 10;
        digits += 1;
    }
    digits
}
/// Sum decimal widths over consecutive line numbers in <= usize decimal buckets.
fn digit_sum(first: usize, count: usize) -> Option<usize> {
    if count == 0 {
        return Some(0);
    }
    let last = first.checked_add(count - 1)?;
    let mut cursor = first;
    let mut sum = 0usize;
    loop {
        let digits = decimal_digits(cursor);
        let upper = 10usize
            .checked_pow(digits as u32)
            .map(|n| n - 1)
            .unwrap_or(usize::MAX)
            .min(last);
        sum = sum.checked_add((upper - cursor + 1).checked_mul(digits)?)?;
        if upper == last {
            return Some(sum);
        }
        cursor = upper + 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn render(source: &str, first: usize, expanded: bool) -> String {
        let mut lines: Vec<_> = if source.is_empty() {
            vec![]
        } else {
            source.split('\n').collect()
        };
        if lines
            .last()
            .is_some_and(|l| l.starts_with("[Truncated.") && l.ends_with(']'))
        {
            lines.pop();
        }
        let mut out = vec![];
        for (i, line) in lines.iter().enumerate() {
            if lines.len() > 13 && !expanded && (6..lines.len() - 6).contains(&i) {
                if i == 6 {
                    out.push(format!("… {} more lines", lines.len() - 12));
                }
                continue;
            }
            out.push(format!(
                "{}  {}",
                first + i,
                if line.is_empty() { " " } else { line }
            ));
        }
        out.join("\n")
    }
    fn build(source: &str, ranges: &[Range<usize>]) -> NumberedPreviewMap {
        NumberedPreviewMap::new(source, ranges, None, &AtomicBool::new(false)).unwrap()
    }
    #[test]
    fn exhaustive_ranges_match_reference_for_folds_widths_empty_crlf_and_unicode() {
        for count in 0..40 {
            let source = (0..count)
                .map(|i| match i % 4 {
                    0 => format!("tag{i}汉🙂"),
                    1 => String::new(),
                    2 => format!("tag{i}\r"),
                    _ => format!("tag{i}x"),
                })
                .collect::<Vec<_>>()
                .join("\n");
            let ranges: Vec<_> = source
                .char_indices()
                .map(|(i, c)| i..i + c.len_utf8())
                .collect();
            let map = build(&source, &ranges);
            for first in [1, 7, 98, 998, 9_999_998] {
                for expanded in [false, true] {
                    let shown = render(&source, first, expanded);
                    assert_eq!(map.expected_len(first, expanded), Some(shown.len()));
                    for range in &ranges {
                        let line = source[..range.start]
                            .bytes()
                            .filter(|b| *b == b'\n')
                            .count();
                        let omitted = count > 13 && !expanded && (6..count - 6).contains(&line);
                        let mapped = map.map_range(range, first, expanded);
                        if &source[range.clone()] == "\n" || omitted {
                            assert!(mapped.is_none());
                        } else {
                            let mapped = mapped.unwrap();
                            assert_eq!(&shown[mapped], &source[range.clone()]);
                        }
                    }
                }
            }
        }
    }
    #[test]
    fn selected_tail_maps_after_fold_but_middle_only_when_expanded() {
        let source = (0..20)
            .map(|i| format!("line{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let middle = source.find("line8").unwrap()..source.find("line8").unwrap() + 5;
        let tail = source.find("line19").unwrap()..source.len();
        let map = NumberedPreviewMap::new(
            &source,
            std::slice::from_ref(&middle),
            Some(&tail),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(map.map_range(&middle, 90, false).is_none());
        assert_eq!(
            &render(&source, 90, true)[map.map_range(&middle, 90, true).unwrap()],
            "line8"
        );
        assert_eq!(
            &render(&source, 90, false)[map.map_range(&tail, 90, false).unwrap()],
            "line19"
        );
    }
    #[test]
    fn no_generated_text_or_crossline_envelopes_or_invalid_utf8() {
        let source = "汉\n\nend\n[Truncated. generated note]";
        let ranges = vec![
            0..3,
            1..2,
            3..4,
            4..5,
            2..6,
            5..8,
            9..source.len(),
            0..0,
            Range { start: 8, end: 7 },
            0..usize::MAX,
        ];
        let map = build(source, &ranges);
        assert_eq!(map.spans.len(), 2);
        for expanded in [true, false] {
            let shown = render(source, 9, expanded);
            assert_eq!(map.expected_len(9, expanded), Some(shown.len()));
            assert_eq!(&shown[map.map_range(&(0..3), 9, expanded).unwrap()], "汉");
            assert_eq!(&shown[map.map_range(&(5..8), 9, expanded).unwrap()], "end");
            for r in &ranges[1..5] {
                assert!(map.map_range(r, 9, expanded).is_none());
            }
            assert!(map.map_range(&(9..source.len()), 9, expanded).is_none());
        }
    }
    #[test]
    fn note_only_trailing_newline_and_literal_not_note() {
        for source in [
            "",
            "[Truncated. note]",
            "\n[Truncated. note]",
            "a\n",
            "a\n\n",
            "[Truncated. note]\n",
            "a\n[Truncated. note]\r",
        ] {
            let map = build(source, &[]);
            assert_eq!(
                map.expected_len(1, false),
                Some(render(source, 1, false).len())
            );
        }
    }
    #[test]
    fn bounded_metadata_on_newline_heavy_and_long_line_inputs() {
        let source = "\n".repeat(200_000) + "汉needle";
        let range = source.len() - 6..source.len();
        let map = build(&source, &[range.clone(), range.clone()]);
        assert_eq!(map.spans.len(), 1);
        let shown = render(&source, 1, false);
        assert_eq!(&shown[map.map_range(&range, 1, false).unwrap()], "needle");
        let long = "x".repeat(1_000_000) + "🙂";
        let range = 1_000_000..long.len();
        let map = build(&long, std::slice::from_ref(&range));
        assert_eq!(map.map_range(&range, 1, false), Some(1_000_003..1_000_007));
    }
    #[test]
    fn cancellation_is_failure_not_partial_map() {
        assert!(
            NumberedPreviewMap::new(
                "abc",
                std::slice::from_ref(&(0..1)),
                None,
                &AtomicBool::new(true)
            )
            .is_err()
        );
        assert!(NumberedPreviewMap::new("", &[], None, &AtomicBool::new(true)).is_err());
    }
    #[test]
    fn decimal_bucket_boundaries_and_overflow_fail_closed() {
        for first in [0, 1, 8, 9, 10, 98, 99, 100, 999, 1000] {
            for count in 0..200 {
                assert_eq!(
                    digit_sum(first, count),
                    Some((first..first + count).map(decimal_digits).sum())
                );
            }
        }
        let map = build("a\nb", &[0..1, 2..3]);
        assert!(map.expected_len(usize::MAX, true).is_none());
        assert!(map.map_range(&(2..3), usize::MAX, true).is_none());
        assert_eq!(digit_sum(usize::MAX, 1), Some(decimal_digits(usize::MAX)));
    }
}
