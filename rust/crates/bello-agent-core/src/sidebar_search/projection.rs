//! Pure sidebar search groundwork. No disk access, Controller admission, or index.
//! Callers must separately prove source membership and persistence certainty.
//! Only retained Message.text and typed call name/pretty arguments are read.
//! Reasoning, usage/ledger, provider items, compaction, drafts, image containers,
//! hidden skill bodies and live preview payloads are deliberately not traversed.
use super::CancellationProbe;
use crate::{Message, Session, tool_history::ToolRecord};
use std::{
    borrow::Cow,
    collections::{BTreeSet, VecDeque},
    io::{self, Write},
    ops::Range,
};
use unicode_normalization::char::{canonical_combining_class as ccc, compose, decompose_canonical};

pub const PROJECTION_VERSION: u32 = 1;
/// Shared canonical decomposition/composition and scalar-lowercase mapping.
pub const CANONICAL_MAPPING_VERSION: u32 = 1;
/// Sidebar-only whitespace trim/collapse, NUL rejection and query eligibility.
pub const NORMALIZATION_VERSION: u32 = 1;
pub const MAX_SOURCE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_TOTAL_BYTES: usize = 256 * 1024 * 1024;
pub const MAX_PIECES: usize = 100_000;
pub const MAX_QUERY_BYTES: usize = 16 * 1024;
pub const MAX_NONSTARTERS: usize = 16 * 1024;
pub const MAX_RANGE_PAGE: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Cancelled,
    SourceLimit,
    QueryLimit,
    CombiningLimit,
    UnsupportedNul,
    InvalidIdentity,
    InvalidOwnership,
    Serialization,
    PageLimit,
}
pub type Result<T> = std::result::Result<T, Error>;
pub fn check_cancel(cancel: &dyn CancellationProbe) -> Result<()> {
    if cancel.is_cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PieceKind {
    User,
    Assistant,
    ToolInput,
    ToolOutput,
}
/// Fixture policy only: neither variant is an authority/durability receipt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivePolicy {
    AcceptedRetained,
    /// Complete validated bytes observed read-only, without durability acceptance.
    ObservedRetained,
    DeferActive,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PieceKey<'a> {
    pub message_id: &'a str,
    pub message_position: usize,
    pub kind: PieceKind,
    pub piece_ordinal: usize,
    pub assistant_id: Option<&'a str>,
    pub call_id: Option<&'a str>,
}
#[derive(Clone)]
pub struct Piece<'a> {
    pub key: PieceKey<'a>,
    pub source: Cow<'a, str>,
    /// Some only for input: name, synthetic single-space separator, pretty JSON.
    pub input_start: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SourceTarget {
    Message(Range<usize>),
    ToolName(Range<usize>),
    ToolInput(Range<usize>),
    CardFallback,
}
impl Piece<'_> {
    /// Never pretend a synthetic name/input boundary is one exact editor span.
    pub fn target(&self, range: Range<usize>) -> SourceTarget {
        if range.start >= range.end
            || range.end > self.source.len()
            || !self.source.is_char_boundary(range.start)
            || !self.source.is_char_boundary(range.end)
        {
            return SourceTarget::CardFallback;
        }
        match self.input_start {
            Some(start) if start == 0 || start > self.source.len() => SourceTarget::CardFallback,
            None => SourceTarget::Message(range),
            Some(start) if range.end < start => SourceTarget::ToolName(range),
            Some(start) if range.start >= start => {
                SourceTarget::ToolInput(range.start - start..range.end - start)
            }
            Some(_) => SourceTarget::CardFallback,
        }
    }
}
pub struct SidebarProjection<'a> {
    pub chat_id: &'a str,
    pub pieces: Vec<Piece<'a>>,
    /// Deferred prefix is intentionally incomplete; never publish it as coverage.
    pub deferred_from: Option<usize>,
}
fn identity(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        Err(Error::InvalidIdentity)
    } else {
        Ok(())
    }
}
fn argument_preflight(
    value: &serde_json::Value,
    depth: usize,
    nodes: &mut usize,
    cancel: &dyn CancellationProbe,
) -> Result<()> {
    check_cancel(cancel)?;
    if depth > 128 || *nodes >= MAX_PIECES {
        return Err(Error::SourceLimit);
    }
    *nodes += 1;
    match value {
        serde_json::Value::Array(values) => {
            for value in values {
                argument_preflight(value, depth + 1, nodes, cancel)?;
            }
        }
        serde_json::Value::Object(values) => {
            for value in values.values() {
                argument_preflight(value, depth + 1, nodes, cancel)?;
            }
        }
        _ => {}
    }
    Ok(())
}
/// Same serde pretty serializer as transcript_tool_presentation::arguments_preview.
/// Full retained input is searchable; beyond the renderer's 8 KiB preview remains
/// an explicit presentation fallback until the full-input adapter is integrated.
/// Arbitrary argument strings are not guessed/redacted as images or secrets.
/// Limits: 128 nested levels, 100,000 JSON nodes, 16 MiB serialized bytes.
pub fn canonical_tool_input(
    value: &serde_json::Value,
    cancel: &dyn CancellationProbe,
) -> Result<String> {
    struct Bounded<'a> {
        bytes: Vec<u8>,
        cancel: &'a dyn CancellationProbe,
        limit: bool,
    }
    impl Write for Bounded<'_> {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if self.cancel.is_cancelled() {
                return Err(io::ErrorKind::Other.into());
            }
            if bytes.len() > MAX_SOURCE_BYTES.saturating_sub(self.bytes.len()) {
                self.limit = true;
                return Err(io::ErrorKind::WriteZero.into());
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    check_cancel(cancel)?;
    argument_preflight(value, 0, &mut 0, cancel)?;
    let mut writer = Bounded {
        bytes: vec![],
        cancel,
        limit: false,
    };
    let outcome = serde_json::to_writer_pretty(&mut writer, value);
    check_cancel(cancel)?;
    if writer.limit {
        return Err(Error::SourceLimit);
    }
    outcome.map_err(|_| Error::Serialization)?;
    String::from_utf8(writer.bytes).map_err(|_| Error::Serialization)
}
impl<'a> SidebarProjection<'a> {
    /// Worker-only, bounded, pure projection. This does not call Session validation
    /// or read opaque payloads; production admission must validate the source first.
    pub fn new(
        session: &'a Session,
        policy: ActivePolicy,
        cancel: &dyn CancellationProbe,
    ) -> Result<Self> {
        check_cancel(cancel)?;
        identity(&session.id)?;
        if session.messages.len() > MAX_PIECES {
            return Err(Error::SourceLimit);
        }
        let mut ids = BTreeSet::new();
        for message in &session.messages {
            check_cancel(cancel)?;
            identity(&message.id)?;
            if !ids.insert(message.id.as_str()) {
                return Err(Error::InvalidIdentity);
            }
        }
        let deferred_from = if policy == ActivePolicy::DeferActive {
            session
                .active_reply
                .as_ref()
                .and_then(|id| session.messages.iter().position(|m| &m.id == id))
        } else {
            None
        };
        if session.active_reply.is_some()
            && policy == ActivePolicy::DeferActive
            && deferred_from.is_none()
        {
            return Err(Error::InvalidIdentity);
        }
        let mut result = Self {
            chat_id: &session.id,
            pieces: vec![],
            deferred_from,
        };
        let mut total = 0usize;
        let mut owner: Option<(&str, Vec<&str>)> = None;
        let mut last_result = None;
        for (position, message) in session
            .messages
            .iter()
            .enumerate()
            .take(deferred_from.unwrap_or(session.messages.len()))
        {
            check_cancel(cancel)?;
            if message.compaction.is_some() {
                owner = None;
                last_result = None;
                continue;
            }
            match (&*message.role, &message.tool_record) {
                ("user", None) => {
                    owner = None;
                    last_result = None;
                    result.push(
                        message,
                        position,
                        PieceKind::User,
                        0,
                        None,
                        None,
                        Cow::Borrowed(&message.text),
                        None,
                        &mut total,
                        cancel,
                    )?;
                }
                ("assistant", record) => {
                    result.push(
                        message,
                        position,
                        PieceKind::Assistant,
                        0,
                        None,
                        None,
                        Cow::Borrowed(&message.text),
                        None,
                        &mut total,
                        cancel,
                    )?;
                    owner = None;
                    last_result = None;
                    if let Some(record) = record {
                        let ToolRecord::Assistant(record) = record else {
                            return Err(Error::InvalidOwnership);
                        };
                        if record.calls.is_empty() {
                            return Err(Error::InvalidOwnership);
                        }
                        let mut calls = BTreeSet::new();
                        for (index, call) in record.calls.iter().enumerate() {
                            identity(&call.id)?;
                            identity(&call.name)?;
                            if !calls.insert(call.id.as_str()) {
                                return Err(Error::InvalidOwnership);
                            }
                            let input = canonical_tool_input(&call.arguments, cancel)?;
                            let start = call.name.len() + 1;
                            let source = format!("{} {}", call.name, input);
                            result.push(
                                message,
                                position,
                                PieceKind::ToolInput,
                                index + 1,
                                Some(&message.id),
                                Some(&call.id),
                                Cow::Owned(source),
                                Some(start),
                                &mut total,
                                cancel,
                            )?;
                        }
                        owner = Some((
                            &message.id,
                            record.calls.iter().map(|c| c.id.as_str()).collect(),
                        ));
                    }
                }
                ("toolResult", Some(ToolRecord::Result(record))) => {
                    let (assistant, calls) = owner.as_ref().ok_or(Error::InvalidOwnership)?;
                    let index = calls
                        .iter()
                        .position(|id| *id == record.call_id)
                        .ok_or(Error::InvalidOwnership)?;
                    if *assistant != record.assistant_id
                        || last_result.is_some_and(|last| index <= last)
                    {
                        return Err(Error::InvalidOwnership);
                    }
                    last_result = Some(index);
                    result.push(
                        message,
                        position,
                        PieceKind::ToolOutput,
                        0,
                        Some(&record.assistant_id),
                        Some(&record.call_id),
                        Cow::Borrowed(&message.text),
                        None,
                        &mut total,
                        cancel,
                    )?;
                }
                (_, Some(_)) | ("toolResult", None) => return Err(Error::InvalidOwnership),
                _ => {
                    owner = None;
                    last_result = None;
                }
            }
        }
        check_cancel(cancel)?;
        Ok(result)
    }
    #[allow(clippy::too_many_arguments)]
    fn push(
        &mut self,
        message: &'a Message,
        position: usize,
        kind: PieceKind,
        ordinal: usize,
        assistant_id: Option<&'a str>,
        call_id: Option<&'a str>,
        source: Cow<'a, str>,
        input_start: Option<usize>,
        total: &mut usize,
        cancel: &dyn CancellationProbe,
    ) -> Result<()> {
        preflight(&source, cancel)?;
        *total = total.checked_add(source.len()).ok_or(Error::SourceLimit)?;
        if *total > MAX_TOTAL_BYTES || self.pieces.len() >= MAX_PIECES {
            return Err(Error::SourceLimit);
        }
        self.pieces.push(Piece {
            key: PieceKey {
                message_id: &message.id,
                message_position: position,
                kind,
                piece_ordinal: ordinal,
                assistant_id,
                call_id,
            },
            source,
            input_start,
        });
        Ok(())
    }
    /// Newest row; prose before ordered calls; first non-overlapping occurrence.
    pub fn newest_match(
        &self,
        query: &Query,
        cancel: &dyn CancellationProbe,
    ) -> Result<Option<(usize, Occurrence)>> {
        let mut end = self.pieces.len();
        while end > 0 {
            let position = self.pieces[end - 1].key.message_position;
            let mut start = end - 1;
            while start > 0 && self.pieces[start - 1].key.message_position == position {
                start -= 1;
            }
            for index in start..end {
                let page = query.ranges(&self.pieces[index].source, 0, 1, cancel)?;
                if let Some(found) = page.occurrences.into_iter().next() {
                    return Ok(Some((index, found)));
                }
            }
            end = start;
        }
        check_cancel(cancel)?;
        Ok(None)
    }
}

/// Reject NUL in source as well as query: the entire affected projection is
/// unavailable, never a successful partial index or an empty search answer.
pub(crate) fn preflight(text: &str, cancel: &dyn CancellationProbe) -> Result<()> {
    check_cancel(cancel)?;
    if text.len() > MAX_SOURCE_BYTES {
        return Err(Error::SourceLimit);
    }
    let mut nonstarters = 0usize;
    for (index, ch) in text.chars().enumerate() {
        if index % 1024 == 0 {
            check_cancel(cancel)?;
        }
        if ch == '\0' {
            return Err(Error::UnsupportedNul);
        }
        decompose_canonical(ch, |part| {
            if ccc(part) == 0 {
                nonstarters = 0;
            } else {
                nonstarters = nonstarters.saturating_add(1);
            }
        });
        if nonstarters > MAX_NONSTARTERS {
            return Err(Error::CombiningLimit);
        }
    }
    check_cancel(cancel)
}
/// Reusable mapped NFC/lowercase/NFC policy shared in behavior with Find v1.
/// Whitespace and NUL handling are sidebar-specific wrappers, not Find changes.
/// Low-level iterator: call preflight first and check cancellation after consuming;
/// cancellation stops the stream, never authorizes publishing a partial result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mapped {
    pub ch: char,
    pub span: Range<usize>,
}
impl Mapped {
    fn merge(&mut self, other: &Self, ch: char) {
        self.ch = ch;
        self.span = self.span.start.min(other.span.start)..self.span.end.max(other.span.end);
    }
}
pub(crate) fn canonical_mapped<'a>(
    text: &'a str,
    cancel: &'a dyn CancellationProbe,
) -> impl Iterator<Item = Mapped> + 'a {
    let source = text
        .char_indices()
        .enumerate()
        .take_while(|(index, _)| index % 1024 != 0 || !cancel.is_cancelled())
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
    Nfc::new(lowered)
}
fn sidebar_mapped<'a>(
    text: &'a str,
    cancel: &'a dyn CancellationProbe,
) -> impl Iterator<Item = Mapped> + 'a {
    let mut source = canonical_mapped(text, cancel);
    let mut pending = None::<Mapped>;
    let mut held = None;
    let mut started = false;
    std::iter::from_fn(move || {
        if let Some(next) = held.take() {
            return Some(next);
        }
        for part in source.by_ref() {
            if part.ch.is_whitespace() {
                if started {
                    match pending.as_mut() {
                        Some(space) => space.merge(&part, ' '),
                        None => {
                            pending = Some(Mapped {
                                ch: ' ',
                                span: part.span,
                            })
                        }
                    }
                }
            } else {
                started = true;
                if let Some(space) = pending.take() {
                    held = Some(part);
                    return Some(space);
                }
                return Some(part);
            }
        }
        None // Drop trailing whitespace.
    })
}
#[derive(Clone)]
pub struct Query {
    chars: Vec<char>,
    prefix: Vec<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Occurrence {
    pub ordinal: usize,
    pub normalized: Range<usize>,
    pub source: Range<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RangePage {
    pub total: usize,
    pub occurrences: Vec<Occurrence>,
    pub next: Option<usize>,
}
impl Query {
    pub fn new(text: &str, cancel: &dyn CancellationProbe) -> Result<Self> {
        check_cancel(cancel)?;
        if text.len() > MAX_QUERY_BYTES {
            return Err(Error::QueryLimit);
        }
        preflight(text, cancel)?;
        let chars: Vec<_> = sidebar_mapped(text, cancel).map(|p| p.ch).collect();
        check_cancel(cancel)?;
        if !(3..=256).contains(&chars.len()) {
            return Err(Error::QueryLimit);
        }
        let mut prefix = vec![0; chars.len()];
        let mut matched = 0;
        for i in 1..chars.len() {
            while matched > 0 && chars[i] != chars[matched] {
                matched = prefix[matched - 1];
            }
            if chars[i] == chars[matched] {
                matched += 1;
            }
            prefix[i] = matched;
        }
        Ok(Self { chars, prefix })
    }
    pub fn normalized(&self) -> String {
        self.chars.iter().collect()
    }
    pub fn ranges(
        &self,
        text: &str,
        start: usize,
        limit: usize,
        cancel: &dyn CancellationProbe,
    ) -> Result<RangePage> {
        if limit == 0 || limit > MAX_RANGE_PAGE {
            return Err(Error::PageLimit);
        }
        preflight(text, cancel)?;
        let mut tail = VecDeque::<(Range<usize>, Range<usize>)>::with_capacity(self.chars.len());
        let (mut matched, mut total, mut offset) = (0usize, 0usize, 0usize);
        let mut occurrences = vec![];
        for (index, part) in sidebar_mapped(text, cancel).enumerate() {
            if index % 1024 == 0 {
                check_cancel(cancel)?;
            }
            let normalized = offset..offset + part.ch.len_utf8();
            offset = normalized.end;
            if tail.len() == self.chars.len() {
                tail.pop_front();
            }
            tail.push_back((part.span, normalized));
            while matched > 0 && part.ch != self.chars[matched] {
                matched = self.prefix[matched - 1];
            }
            if part.ch == self.chars[matched] {
                matched += 1;
            }
            if matched == self.chars.len() {
                if total >= start && occurrences.len() < limit {
                    occurrences.push(Occurrence {
                        ordinal: total,
                        normalized: tail.front().unwrap().1.start..tail.back().unwrap().1.end,
                        source: tail.iter().map(|p| p.0.start).min().unwrap()
                            ..tail.iter().map(|p| p.0.end).max().unwrap(),
                    });
                }
                total = total.checked_add(1).ok_or(Error::SourceLimit)?;
                matched = 0;
            }
        }
        check_cancel(cancel)?;
        let consumed = start
            .checked_add(occurrences.len())
            .ok_or(Error::PageLimit)?;
        Ok(RangePage {
            total,
            occurrences,
            next: (consumed < total).then_some(consumed),
        })
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

// Do not make generic diagnostics a transcript/query logging channel.
impl std::fmt::Debug for Piece<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Piece")
            .field("kind", &self.key.kind)
            .field("source_bytes", &self.source.len())
            .finish_non_exhaustive()
    }
}
impl std::fmt::Debug for SidebarProjection<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SidebarProjection")
            .field("piece_count", &self.pieces.len())
            .field("deferred_from", &self.deferred_from)
            .finish_non_exhaustive()
    }
}
impl std::fmt::Debug for Query {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Query")
            .field("normalized_scalars", &self.chars.len())
            .finish_non_exhaustive()
    }
}

/// Streams the exact sidebar representation into bounded 32,768-scalar chunks
/// with 256-scalar overlap. Offsets are normalized UTF-8 bytes, matching Occurrence.
/// It never retains the whole normalized piece or maps it a second time.
pub fn normalized_chunks<E: From<Error>>(
    text: &str,
    cancel: &dyn CancellationProbe,
    mut sink: impl FnMut(usize, &str) -> std::result::Result<(), E>,
) -> std::result::Result<(), E> {
    preflight(text, cancel)?;
    let mut chunk = String::with_capacity(32_768 * 4);
    let (mut scalars, mut offset, mut added) = (0usize, 0usize, 0usize);
    for part in sidebar_mapped(text, cancel) {
        if scalars % 1024 == 0 {
            check_cancel(cancel)?;
        }
        chunk.push(part.ch);
        scalars += 1;
        added += 1;
        if scalars == 32_768 {
            sink(offset, &chunk)?;
            let retain = chunk
                .char_indices()
                .rev()
                .nth(255)
                .map(|(i, _)| i)
                .unwrap_or(0);
            offset += retain;
            chunk.drain(..retain);
            scalars = 256;
            added = 0;
        }
    }
    check_cancel(cancel)?;
    if added > 0 {
        sink(offset, &chunk)?;
    }
    Ok(())
}
