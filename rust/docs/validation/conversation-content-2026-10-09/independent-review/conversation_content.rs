//! Loaded-chat Search and Copy Conversation, based on Swift SessionReads.
//!
//! This projects only the app's retained display text (Message.text), never
//! serialized messages, provider items, exposed reasoning, image bytes, tool
//! arguments or expanded skill bodies. The unopened Swift HistoryReader has a
//! different Markdown projection and is deliberately outside this module.
//!
//! Portable search uses canonical normalization plus Unicode lowercase. It is
//! not Foundation's locale-sensitive case-insensitive matching (for example,
//! full case folding and locale-specific I are not implemented). Query limits
//! count extended grapheme clusters, as Swift String.count does.
use bello_agent_core::Session;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

const COPY_LIMIT: usize = 8 * 1024 * 1024;
const PAGE_BYTES: usize = 64 * 1024;
const SEARCH_LIMIT: usize = 100;
const MAX_START: usize = 100_000;
pub(crate) const QUERY_BYTE_LIMIT: usize = 16 * 1024;
const MAX_NONSTARTERS: usize = 16 * 1024;
const CANCEL_INTERVAL: usize = 1024;

#[derive(Clone)]
pub(crate) struct Snapshot {
    session: Arc<Session>,
    rows: Arc<Vec<usize>>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Hit {
    pub id: String,
    pub position: usize,
    pub preview: String,
    /// Latest loaded SessionReads always supplies a count, including zero for
    /// an empty query. Older/unopened sources may omit it (consumer fallback: one).
    pub count: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SearchPage {
    pub total: usize,
    pub next: Option<usize>,
    pub hits: Vec<Hit>,
}
impl Snapshot {
    pub(crate) fn new(session: Arc<Session>) -> Self {
        let rows = Arc::new(
            session
                .messages
                .iter()
                .enumerate()
                .filter(|(_, row)| retained(&session, row))
                .map(|(index, _)| index)
                .collect(),
        );
        Self { session, rows }
    }

    /// Equal counts/byte lengths are insufficient: every identity, order and
    /// projected byte must match. Queue, usage and other non-content updates do
    /// not invalidate a selection. Controller/window fences belong to the UI.
    pub(crate) fn matches(&self, current: &Arc<Session>) -> bool {
        Arc::ptr_eq(&self.session, current)
            || (self.session.id == current.id
                && self
                    .rows
                    .iter()
                    .map(|&index| {
                        let row = &self.session.messages[index];
                        (&row.id, &row.text)
                    })
                    .eq(current
                        .messages
                        .iter()
                        .filter(|row| retained(current, row))
                        .map(|row| (&row.id, &row.text))))
    }

    #[cfg(test)]
    pub(crate) fn search(&self, query: &str, start: usize) -> Result<SearchPage, String> {
        self.search_cancelled(query, start, &AtomicBool::new(false))
    }

    pub(crate) fn search_cancelled(
        &self,
        query: &str,
        start: usize,
        cancel: &AtomicBool,
    ) -> Result<SearchPage, String> {
        search_check_cancel(cancel)?;
        // Byte admission precedes grapheme scanning: one grapheme may contain
        // arbitrarily many combining marks. This is an explicit Rust bound.
        if query.len() > QUERY_BYTE_LIMIT {
            return Err("Search query exceeds the 16 KiB text limit.".into());
        }
        if query.graphemes(true).take(257).count() > 256 {
            return Err("Search query exceeds 256 characters.".into());
        }
        if start > MAX_START {
            return Err("Search position exceeds the supported range.".into());
        }
        normalization_preflight(query, cancel)?;
        let query: Vec<char> = normalized_chars(query, cancel).collect();
        search_check_cancel(cancel)?;
        let prefix = prefix_table(&query);
        let total = self.rows.len();
        let mut cursor = start.min(total);
        let mut hits = Vec::new();
        while cursor < total && hits.len() < SEARCH_LIMIT {
            search_check_cancel(cancel)?;
            let row = &self.session.messages[self.rows[cursor]];
            let count = occurrences_normalized(&row.text, &query, &prefix, cancel)?;
            if query.is_empty() || count > 0 {
                hits.push(Hit {
                    id: row.id.clone(),
                    position: cursor + 1,
                    preview: preview(&row.text),
                    count: Some(count),
                });
            }
            cursor += 1;
        }
        search_check_cancel(cancel)?;
        Ok(SearchPage {
            total,
            next: (cursor < total).then_some(cursor),
            hits,
        })
    }

    /// Inclusive one-based range, with the live host's exact concatenation:
    /// no invented headings or separators. All bytes are collected before the
    /// caller may replace the clipboard. Cancellation/error returns no prefix.
    pub(crate) fn collect(
        &self,
        first: usize,
        last: usize,
        cancel: &AtomicBool,
    ) -> Result<String, String> {
        check_cancel(cancel)?;
        if first == 0 || last < first || last > self.rows.len() {
            return Err("Invalid retained message range.".into());
        }
        let mut output = String::new();
        for &index in &self.rows[first - 1..last] {
            let row = &self.session.messages[index];
            check_cancel(cancel)?;
            if row.text.len() > COPY_LIMIT - output.len() {
                return Err("This copy exceeds 8 MiB. Choose a smaller message range. The clipboard was not changed.".into());
            }
            let mut offset = 0;
            while offset < row.text.len() {
                check_cancel(cancel)?;
                let mut end = (offset + PAGE_BYTES).min(row.text.len());
                while !row.text.is_char_boundary(end) {
                    end -= 1;
                }
                output.push_str(&row.text[offset..end]);
                offset = end;
            }
        }
        check_cancel(cancel)?;
        Ok(output)
    }
}
// Swift keeps partialID/partialText separate from shown rows until append.
// Rust publishes that transient reply among messages. Exclude precisely that
// active streaming row, while retaining interrupted/cancelled terminal text.
fn retained(session: &Session, row: &bello_agent_core::Message) -> bool {
    !(session.active_reply.as_deref() == Some(row.id.as_str()) && row.state == "streaming")
}
fn check_cancel(cancel: &AtomicBool) -> Result<(), String> {
    if cancel.load(Ordering::Acquire) {
        Err("Conversation copy was cancelled. The clipboard was not changed.".into())
    } else {
        Ok(())
    }
}
fn search_check_cancel(cancel: &AtomicBool) -> Result<(), String> {
    if cancel.load(Ordering::Acquire) {
        Err("Conversation search was cancelled.".into())
    } else {
        Ok(())
    }
}
// NFC's iterator internally buffers a nonstarter segment. Preflight canonical
// decomposition without materializing text, so hostile combining runs cannot
// turn streaming normalization into an unbounded allocation. This conservative
// Rust-only limit is a visible error rather than a silently incomplete search.
fn normalization_preflight(text: &str, cancel: &AtomicBool) -> Result<(), String> {
    let mut nonstarters = 0usize;
    for (index, character) in text.chars().enumerate() {
        if index % CANCEL_INTERVAL == 0 {
            search_check_cancel(cancel)?;
        }
        unicode_normalization::char::decompose_canonical(character, |part| {
            if unicode_normalization::char::canonical_combining_class(part) == 0 {
                nonstarters = 0;
            } else {
                nonstarters = nonstarters.saturating_add(1);
            }
        });
        if nonstarters > MAX_NONSTARTERS {
            return Err("A message contains an unsupported combining-character sequence. Search could not be completed.".into());
        }
    }
    search_check_cancel(cancel)
}
// Input cancellation also runs while normalization is buffering a segment.
// Every caller checks cancellation after consuming this iterator and before
// publishing a match, so stopping early can never become a false success.
fn normalized_chars<'a>(text: &'a str, cancel: &'a AtomicBool) -> impl Iterator<Item = char> + 'a {
    text.chars()
        .enumerate()
        .take_while(move |(index, _)| {
            index % CANCEL_INTERVAL != 0 || !cancel.load(Ordering::Acquire)
        })
        .map(|(_, character)| character)
        .nfc()
        .flat_map(char::to_lowercase)
        .nfc()
}
fn prefix_table(query: &[char]) -> Vec<usize> {
    let mut prefix = vec![0; query.len()];
    let mut matched = 0;
    for index in 1..query.len() {
        while matched > 0 && query[index] != query[matched] {
            matched = prefix[matched - 1];
        }
        if query[index] == query[matched] {
            matched += 1;
        }
        prefix[index] = matched;
    }
    prefix
}
fn occurrences_normalized(
    text: &str,
    query: &[char],
    prefix: &[usize],
    cancel: &AtomicBool,
) -> Result<usize, String> {
    search_check_cancel(cancel)?;
    if query.is_empty() {
        return Ok(0);
    }
    normalization_preflight(text, cancel)?;
    let mut matched = 0;
    let mut count = 0;
    for (index, character) in normalized_chars(text, cancel).enumerate() {
        if index % CANCEL_INTERVAL == 0 {
            search_check_cancel(cancel)?;
        }
        while matched > 0 && character != query[matched] {
            matched = prefix[matched - 1];
        }
        if character == query[matched] {
            matched += 1;
        }
        if matched == query.len() {
            search_check_cancel(cancel)?;
            count += 1;
            // Swift advances to found.upperBound: overlapping starts cannot
            // reuse the suffix of the previous occurrence.
            matched = 0;
        }
    }
    search_check_cancel(cancel)?;
    Ok(count)
}
/// Swift TextPreviews.preview: prefix in bytes, decode lossily, then trim only
/// replacement characters at either edge. Interior original U+FFFD remains.
fn preview(text: &str) -> String {
    String::from_utf8_lossy(&text.as_bytes()[..text.len().min(240)])
        .trim_matches('\u{fffd}')
        .to_owned()
}

#[cfg(test)]
#[path = "conversation_content_tests.rs"]
mod tests;
