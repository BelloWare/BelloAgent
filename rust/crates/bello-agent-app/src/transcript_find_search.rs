//! Portable Find ranges use exactly Search and Copy's NFC/lowercase/NFC match
//! stream. Source spans track canonical decomposition, reordering, composition
//! and lowercase expansion. A span is the smallest contiguous UTF-8 envelope of
//! contributing source scalars; reordered marks can therefore overlap envelopes.
//! No Foundation locale/full-casefold equivalence is claimed.
use crate::conversation_content::{normalization_preflight, prepare_query, search_check_cancel};
use std::{
    collections::VecDeque,
    ops::Range,
    sync::atomic::{AtomicBool, Ordering},
};
use unicode_normalization::char::{canonical_combining_class as ccc, compose, decompose_canonical};

pub(crate) const MAX_RANGE_PAGE: usize = 4096;
#[derive(Clone, Debug)]
pub(crate) struct Query {
    chars: Vec<char>,
    prefix: Vec<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RangePage {
    pub total: usize,
    pub ranges: Vec<Range<usize>>,
    pub next: Option<usize>,
}
impl Query {
    pub(crate) fn new(text: &str, cancel: &AtomicBool) -> Result<Self, String> {
        let (chars, prefix) = prepare_query(text, cancel)?;
        Ok(Self { chars, prefix })
    }
    /// Count all non-overlapping normalized occurrences, retaining only the
    /// requested bounded range page. Cancellation never publishes a partial page.
    pub(crate) fn ranges(
        &self,
        text: &str,
        start: usize,
        limit: usize,
        cancel: &AtomicBool,
    ) -> Result<RangePage, String> {
        search_check_cancel(cancel)?;
        if limit == 0 || limit > MAX_RANGE_PAGE {
            return Err("Unsupported Find range page size.".into());
        }
        if self.chars.is_empty() {
            return Ok(RangePage {
                total: 0,
                ranges: vec![],
                next: None,
            });
        }
        normalization_preflight(text, cancel)?;
        let source = text
            .char_indices()
            .enumerate()
            .take_while(|(i, _)| i % 1024 != 0 || !cancel.load(Ordering::Acquire))
            .flat_map(|(_, (start, ch))| {
                let span = start..start + ch.len_utf8();
                let mut parts = Vec::with_capacity(4);
                decompose_canonical(ch, |ch| {
                    parts.push(Mapped {
                        ch,
                        span: span.clone(),
                    })
                });
                parts
            });
        let lowered = Nfc::new(source).flat_map(|part| {
            let mut parts = Vec::with_capacity(4);
            for lower in part.ch.to_lowercase() {
                decompose_canonical(lower, |ch| {
                    parts.push(Mapped {
                        ch,
                        span: part.span.clone(),
                    })
                });
            }
            parts
        });
        let mut tail = VecDeque::<Range<usize>>::with_capacity(self.chars.len());
        let mut matched = 0;
        let mut total: usize = 0;
        let mut ranges = Vec::new();
        for (index, part) in Nfc::new(lowered).enumerate() {
            if index % 1024 == 0 {
                search_check_cancel(cancel)?;
            }
            if tail.len() == self.chars.len() {
                tail.pop_front();
            }
            tail.push_back(part.span);
            while matched > 0 && part.ch != self.chars[matched] {
                matched = self.prefix[matched - 1];
            }
            if part.ch == self.chars[matched] {
                matched += 1;
            }
            if matched == self.chars.len() {
                if total >= start && ranges.len() < limit {
                    let low = tail.iter().map(|r| r.start).min().unwrap();
                    let high = tail.iter().map(|r| r.end).max().unwrap();
                    ranges.push(low..high);
                }
                total = total
                    .checked_add(1)
                    .ok_or("Find occurrence count overflow.")?;
                matched = 0;
            }
        }
        search_check_cancel(cancel)?;
        let consumed = start
            .checked_add(ranges.len())
            .ok_or("Find range position overflow.")?;
        Ok(RangePage {
            total,
            next: (consumed < total).then_some(consumed),
            ranges,
        })
    }
}
#[derive(Clone)]
struct Mapped {
    ch: char,
    span: Range<usize>,
}
impl Mapped {
    fn merge(&mut self, other: &Self, ch: char) {
        self.ch = ch;
        self.span = self.span.start.min(other.span.start)..self.span.end.max(other.span.end);
    }
}
/// One canonical segment at a time. Input has already been decomposed and
/// bounded by preflight. Lowercase expansion is bounded by Unicode's scalar
/// mapping, so neither stage allocates proportional to the whole message.
struct Nfc<I: Iterator<Item = Mapped>> {
    input: std::iter::Peekable<I>,
    output: std::vec::IntoIter<Mapped>,
}
impl<I: Iterator<Item = Mapped>> Nfc<I> {
    fn new(input: I) -> Self {
        Self {
            input: input.peekable(),
            output: vec![].into_iter(),
        }
    }
}
impl<I: Iterator<Item = Mapped>> Iterator for Nfc<I> {
    type Item = Mapped;
    fn next(&mut self) -> Option<Mapped> {
        if let Some(part) = self.output.next() {
            return Some(part);
        }
        let mut segment = vec![self.input.next()?];
        while let Some(next) = self.input.peek() {
            if ccc(next.ch) == 0 {
                // Adjacent starters compose for Hangul (and any future Unicode
                // canonical starter pair); intervening marks block this path.
                if segment.len() == 1
                    && let Some(ch) = compose(segment[0].ch, next.ch)
                {
                    let next = self.input.next().unwrap();
                    segment[0].merge(&next, ch);
                    continue;
                }
                break;
            }
            segment.push(self.input.next().unwrap());
        }
        let marks = usize::from(ccc(segment[0].ch) == 0);
        segment[marks..].sort_by_key(|part| ccc(part.ch));
        let mut output: Vec<Mapped> = Vec::with_capacity(segment.len());
        let mut starter: Option<usize> = None;
        let mut last_class = 0;
        for part in segment {
            let class = ccc(part.ch);
            if let Some(index) = starter
                && (last_class == 0 || last_class < class)
                && let Some(ch) = compose(output[index].ch, part.ch)
            {
                output[index].merge(&part, ch);
                continue;
            }
            if class == 0 {
                starter = Some(output.len());
            }
            last_class = class;
            output.push(part);
        }
        self.output = output.into_iter();
        self.output.next()
    }
}

#[cfg(test)]
#[path = "transcript_find_search_tests.rs"]
mod tests;
