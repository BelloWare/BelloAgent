//! Markdown for the transcript, as Swift 0.1.122 reads it
//! (`TranscriptMarkdown.swift`): blocks (paragraphs, headings, code, lists,
//! quotes, tables) of dressed inline spans. No HTML is interpreted (it stays
//! literal text), images become a note, and links are kept only when they are
//! plain http(s) URLs without credentials. Foundation's CommonMark/GFM reading
//! is reproduced on pulldown-cmark, including bare-URL autolinks; an oracle
//! built from the Swift source pins the result (`markdown_tests.rs`).
use pulldown_cmark::{
    Alignment as CmarkAlignment, CodeBlockKind, Event, Options, Parser, Tag, TagEnd,
};

/// One block of a rendered message, in reading order.
#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    Paragraph(Vec<Span>),
    Heading {
        level: u8,
        spans: Vec<Span>,
        plain: String,
    },
    Code {
        language: Option<String>,
        code: String,
    },
    List {
        ordered: bool,
        start: u64,
        items: Vec<Vec<Block>>,
    },
    Quote(Vec<Block>),
    Table {
        alignments: Vec<Alignment>,
        header: Vec<Vec<Span>>,
        rows: Vec<Vec<Vec<Span>>>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    Left,
    Center,
    Right,
}

/// A run of text and how it is dressed (Swift's `MarkdownFontSpec` plus the
/// inline-code, strikethrough and link attributes).
#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    pub text: String,
    pub size: f32,
    pub bold: bool,
    pub italic: bool,
    pub mono: bool,
    pub serif: bool,
    /// An inline code span (drawn on the code background).
    pub code: bool,
    pub strike: bool,
    pub link: Option<String>,
}

impl Span {
    fn same_dress(&self, other: &Span) -> bool {
        self.size == other.size
            && self.bold == other.bold
            && self.italic == other.italic
            && self.mono == other.mono
            && self.serif == other.serif
            && self.code == other.code
            && self.strike == other.strike
            && self.link == other.link
    }
}

/// Swift's `MarkdownStyle`: the base size and whether soft line breaks stay
/// as typed (user messages) or become spaces (prose).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Style {
    pub base_size: f32,
    pub keeps_soft_breaks: bool,
}

impl Style {
    pub const PROSE: Style = Style {
        base_size: 14.5,
        keeps_soft_breaks: false,
    };
    pub const USER: Style = Style {
        base_size: 14.5,
        keeps_soft_breaks: true,
    };
    pub const REASONING: Style = Style {
        base_size: 13.,
        keeps_soft_breaks: false,
    };
}

/// Only plain web links survive: no scripts, files, data URLs,
/// protocol-relative hosts or embedded credentials (Swift's `safeURL`).
pub fn safe_url(value: &str) -> Option<String> {
    let url = url::Url::parse(value).ok()?;
    let scheme = url.scheme();
    (matches!(scheme, "http" | "https")
        && url.host_str().is_some_and(|host| !host.is_empty())
        && url.username().is_empty()
        && url.password().is_none())
    .then(|| value.to_owned())
}

/// The document as blocks.
pub fn parse(source: &str, style: Style) -> Vec<Block> {
    let mut builder = Builder::new(style);
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH;
    for event in Parser::new_ext(source, options) {
        builder.event(event);
    }
    builder.finish()
}

enum Container {
    Root(Vec<Block>),
    /// The flag: something was parsed inside, even if it shows nothing (a rule).
    Quote(Vec<Block>, bool),
    List {
        ordered: bool,
        start: u64,
        items: Vec<Vec<Block>>,
    },
    Item(Vec<Block>, bool),
    /// A paragraph, a heading or literal HTML collecting spans. `implicit`
    /// marks the paragraph a tight list item's text opens.
    Text {
        heading: Option<u8>,
        spans: Vec<Span>,
        /// The text as parsed, before dressing: an image is its alt text.
        plain: String,
        implicit: bool,
    },
    Code {
        language: Option<String>,
        code: String,
        /// Any line at all, even a blank one: Foundation drops only a fence
        /// with no lines.
        lines: bool,
    },
    Table {
        alignments: Vec<Alignment>,
        header: Vec<Vec<Span>>,
        rows: Vec<Vec<Vec<Span>>>,
        row: Vec<Vec<Span>>,
        in_head: bool,
    },
    Cell(Vec<Span>),
    /// Raw HTML inside a quote or list item, which shows nothing.
    Html,
}

#[derive(Clone, Copy)]
enum Format {
    Italic,
    Bold,
    Strike,
}

struct Builder {
    style: Style,
    stack: Vec<Container>,
    italic: usize,
    bold: usize,
    strike: usize,
    /// Emphasis, strong and strikethrough as opened, each with whether it
    /// counts: Foundation drops any formatting opened inside a link's text.
    formats: Vec<(Format, bool)>,
    links: Vec<Option<String>>,
    /// Alt text of the image being read, if any, and how many images deep.
    image: Option<String>,
    image_depth: usize,
    /// The last top-level block was raw HTML, which the next one joins.
    html_last: bool,
    /// Literal `[` not yet closed in the current text: no autolink inside.
    open_brackets: usize,
}

impl Builder {
    fn new(style: Style) -> Self {
        Self {
            style,
            stack: vec![Container::Root(Vec::new())],
            italic: 0,
            bold: 0,
            strike: 0,
            formats: Vec::new(),
            links: Vec::new(),
            image: None,
            image_depth: 0,
            html_last: false,
            open_brackets: 0,
        }
    }

    fn event(&mut self, event: Event<'_>) {
        if let Some(alt) = &mut self.image {
            match event {
                // An image in alt text gives its own alt text.
                Event::Start(Tag::Image { .. }) => self.image_depth += 1,
                Event::End(TagEnd::Image) if self.image_depth > 0 => self.image_depth -= 1,
                Event::End(TagEnd::Image) => {
                    // An image without alt text reads as Foundation's object
                    // replacement character, as the Swift note shows it.
                    if alt.is_empty() {
                        alt.push('\u{fffc}');
                    }
                    let note = format!("[Image not loaded: {alt}]");
                    let alt = std::mem::take(alt);
                    self.image = None;
                    self.push_dressed(&note, &alt, false, None);
                }
                Event::Text(text)
                | Event::Code(text)
                | Event::InlineHtml(text)
                | Event::Html(text) => alt.push_str(&text),
                Event::SoftBreak | Event::HardBreak => alt.push(' '),
                _ => {}
            }
            return;
        }
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text(&text),
            // Inside a link's text a code span is plain text, as in Swift.
            Event::Code(text) => self.push_text(&text, self.links.is_empty(), None),
            Event::Html(text) | Event::InlineHtml(text) => self.push_text(&text, false, None),
            Event::SoftBreak => {
                let text = if self.style.keeps_soft_breaks {
                    "\n"
                } else {
                    " "
                };
                self.push_text(text, false, None);
            }
            Event::HardBreak => self.push_text("\n", false, None),
            // A rule shows nothing, but its quote or item still exists, and
            // at the top level it ends a run of HTML blocks.
            Event::Rule => {
                self.mark_content();
                if matches!(self.stack.last(), Some(Container::Root(_))) {
                    self.html_last = false;
                }
            }
            // Task markers, footnotes and math are not read.
            _ => {}
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.open_text(None, false),
            Tag::HtmlBlock => self.open_html(),
            Tag::Heading { level, .. } => self.open_text(Some(level as u8), false),
            Tag::BlockQuote(_) => {
                self.close_implicit();
                self.stack.push(Container::Quote(Vec::new(), false));
            }
            Tag::CodeBlock(kind) => {
                self.close_implicit();
                let language = match kind {
                    CodeBlockKind::Fenced(info) => {
                        let hint = info.trim().to_lowercase();
                        (!hint.is_empty()).then_some(hint)
                    }
                    CodeBlockKind::Indented => None,
                };
                self.stack.push(Container::Code {
                    language,
                    code: String::new(),
                    lines: false,
                });
            }
            Tag::List(start) => {
                self.close_implicit();
                self.stack.push(Container::List {
                    ordered: start.is_some(),
                    start: start.unwrap_or(1),
                    items: Vec::new(),
                });
            }
            Tag::Item => self.stack.push(Container::Item(Vec::new(), false)),
            Tag::Table(alignments) => {
                self.close_implicit();
                self.stack.push(Container::Table {
                    alignments: alignments
                        .iter()
                        .map(|alignment| match alignment {
                            CmarkAlignment::Center => Alignment::Center,
                            CmarkAlignment::Right => Alignment::Right,
                            _ => Alignment::Left,
                        })
                        .collect(),
                    header: Vec::new(),
                    rows: Vec::new(),
                    row: Vec::new(),
                    in_head: false,
                });
            }
            Tag::TableHead => {
                if let Some(Container::Table { in_head, .. }) = self.stack.last_mut() {
                    *in_head = true;
                }
            }
            Tag::TableRow => {}
            Tag::TableCell => self.stack.push(Container::Cell(Vec::new())),
            Tag::Emphasis => self.open_format(Format::Italic),
            Tag::Strong => self.open_format(Format::Bold),
            Tag::Strikethrough => self.open_format(Format::Strike),
            Tag::Link { dest_url, .. } => self.links.push(safe_url(&dest_url)),
            Tag::Image { .. } => self.image = Some(String::new()),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::HtmlBlock => self.close_html(),
            TagEnd::Paragraph | TagEnd::Heading(_) => self.close_text(),
            TagEnd::BlockQuote(_) => {
                self.close_implicit();
                if let Some(Container::Quote(blocks, true)) = self.stack.pop() {
                    self.push_block(Block::Quote(blocks));
                }
            }
            TagEnd::CodeBlock => {
                if let Some(Container::Code {
                    language,
                    mut code,
                    lines,
                }) = self.stack.pop()
                {
                    if code.ends_with('\n') {
                        code.pop();
                    }
                    // Foundation drops only a fence with no lines at all.
                    if lines {
                        self.push_block(Block::Code { language, code });
                    }
                }
            }
            TagEnd::List(_) => {
                if let Some(Container::List {
                    ordered,
                    start,
                    items,
                }) = self.stack.pop()
                    && !items.is_empty()
                {
                    self.push_block(Block::List {
                        ordered,
                        start,
                        items,
                    });
                }
            }
            TagEnd::Item => {
                self.close_implicit();
                if let Some(Container::Item(blocks, true)) = self.stack.pop()
                    && let Some(Container::List { items, .. }) = self.stack.last_mut()
                {
                    items.push(blocks);
                }
            }
            TagEnd::TableHead | TagEnd::TableRow => {
                if let Some(Container::Table {
                    header,
                    rows,
                    row,
                    in_head,
                    ..
                }) = self.stack.last_mut()
                {
                    let cells = std::mem::take(row);
                    if *in_head {
                        *header = cells;
                        *in_head = false;
                    } else {
                        rows.push(cells);
                    }
                }
            }
            TagEnd::TableCell => {
                if let Some(Container::Cell(spans)) = self.stack.pop()
                    && let Some(Container::Table { row, .. }) = self.stack.last_mut()
                {
                    row.push(spans);
                }
            }
            TagEnd::Table => {
                if let Some(Container::Table {
                    alignments,
                    header,
                    rows,
                    ..
                }) = self.stack.pop()
                {
                    self.push_block(Block::Table {
                        alignments,
                        header,
                        rows,
                    });
                }
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => self.close_format(),
            TagEnd::Link => {
                self.links.pop();
            }
            _ => {}
        }
    }

    fn open_format(&mut self, format: Format) {
        let counts = self.links.is_empty();
        if counts {
            *self.format_count(format) += 1;
        }
        self.formats.push((format, counts));
    }

    fn close_format(&mut self) {
        if let Some((format, true)) = self.formats.pop() {
            let count = self.format_count(format);
            *count = count.saturating_sub(1);
        }
    }

    fn format_count(&mut self, format: Format) -> &mut usize {
        match format {
            Format::Italic => &mut self.italic,
            Format::Bold => &mut self.bold,
            Format::Strike => &mut self.strike,
        }
    }

    /// Foundation gives raw HTML no block of its own: at the top level it
    /// reads as a paragraph that runs on through adjacent HTML blocks, and
    /// inside a quote or list item it shows nothing (the container stays).
    fn open_html(&mut self) {
        self.close_implicit();
        self.mark_content();
        if matches!(self.stack.last(), Some(Container::Root(_))) {
            let merged = match self.stack.last_mut() {
                Some(Container::Root(blocks)) if self.html_last => match blocks.pop() {
                    Some(Block::Paragraph(spans)) => spans,
                    Some(other) => {
                        blocks.push(other);
                        Vec::new()
                    }
                    None => Vec::new(),
                },
                _ => Vec::new(),
            };
            let plain = merged.iter().map(|span| span.text.as_str()).collect();
            self.stack.push(Container::Text {
                heading: None,
                spans: merged,
                plain,
                implicit: false,
            });
        } else {
            self.stack.push(Container::Html);
        }
    }

    fn close_html(&mut self) {
        match self.stack.pop() {
            Some(Container::Text { spans, .. }) => {
                let mut spans = spans;
                // Its text keeps its line ending.
                if let Some(last) = spans.last_mut()
                    && !last.text.ends_with('\n')
                {
                    last.text.push('\n');
                }
                if let Some(Container::Root(blocks)) = self.stack.last_mut() {
                    blocks.push(Block::Paragraph(spans));
                }
                self.html_last = true;
            }
            Some(Container::Html) | None => {}
            Some(other) => self.stack.push(other),
        }
    }

    fn open_text(&mut self, heading: Option<u8>, implicit: bool) {
        self.close_implicit();
        self.open_brackets = 0;
        self.stack.push(Container::Text {
            heading,
            spans: Vec::new(),
            plain: String::new(),
            implicit,
        });
    }

    fn close_text(&mut self) {
        if let Some(Container::Text {
            heading,
            spans,
            plain,
            ..
        }) = self.stack.pop()
        {
            let spans = trimmed(spans);
            // Foundation has no runs, and so no block, for empty content.
            if spans.is_empty() {
                return;
            }
            match heading {
                Some(level) => {
                    let plain = plain.trim_end_matches([' ', '\t']).to_owned();
                    self.push_block(Block::Heading {
                        level,
                        spans,
                        plain,
                    });
                }
                None => self.push_block(Block::Paragraph(spans)),
            }
        }
    }

    /// A tight list item's text has no paragraph of its own: it ends where
    /// the next block in the item begins, or with the item.
    fn close_implicit(&mut self) {
        if matches!(
            self.stack.last(),
            Some(Container::Text { implicit: true, .. })
        ) {
            self.close_text();
        }
    }

    fn push_block(&mut self, block: Block) {
        self.mark_content();
        if matches!(self.stack.last(), Some(Container::Root(_))) {
            self.html_last = false;
        }
        if let Some(
            Container::Root(blocks) | Container::Quote(blocks, _) | Container::Item(blocks, _),
        ) = self.stack.last_mut()
        {
            blocks.push(block);
        }
    }

    /// Every quote and item around the current position now has content.
    fn mark_content(&mut self) {
        for container in self.stack.iter_mut() {
            if let Container::Quote(_, content) | Container::Item(_, content) = container {
                *content = true;
            }
        }
    }

    /// Plain text: bare http(s) and www. addresses become links (GFM's
    /// extended autolinks) unless already inside a link.
    fn text(&mut self, text: &str) {
        if self.links.last().is_some() {
            self.push_text(text, false, None);
            return;
        }
        let mut rest = text;
        while let Some((start, end, href)) = autolink(rest) {
            // cmark-gfm does not link an address inside a `[` still open.
            let before = &rest[..start];
            let brackets = self.brackets_after(before);
            if brackets > 0 {
                self.open_brackets = self.brackets_after(&rest[..end]);
                self.push_text(&rest[..end], false, None);
                rest = &rest[end..];
                continue;
            }
            self.open_brackets = brackets;
            if start > 0 {
                self.push_text(before, false, None);
            }
            self.push_text(&rest[start..end], false, Some(href));
            rest = &rest[end..];
        }
        self.open_brackets = self.brackets_after(rest);
        if !rest.is_empty() {
            self.push_text(rest, false, None);
        }
    }

    fn push_text(&mut self, text: &str, code: bool, autolink: Option<String>) {
        self.push_dressed(text, text, code, autolink);
    }

    /// Open literal brackets after `text`, from the count before it.
    fn brackets_after(&self, text: &str) -> usize {
        text.chars().fold(self.open_brackets, |open, c| match c {
            '[' => open + 1,
            ']' => open.saturating_sub(1),
            _ => open,
        })
    }

    /// `text` as shown, `raw` as parsed (they differ only for an image).
    fn push_dressed(&mut self, text: &str, raw: &str, code: bool, autolink: Option<String>) {
        if matches!(self.stack.last(), Some(Container::Item(..))) {
            self.stack.push(Container::Text {
                heading: None,
                spans: Vec::new(),
                plain: String::new(),
                implicit: true,
            });
        }
        let heading = self
            .stack
            .iter()
            .rev()
            .find_map(|container| match container {
                Container::Text { heading, .. } => Some(*heading),
                _ => None,
            });
        let heading = heading.flatten();
        let in_cell = matches!(self.stack.last(), Some(Container::Cell(_)));
        let mut size = self.style.base_size;
        if let Some(level) = heading {
            size *= match level {
                1 => 1.5,
                2 => 1.3,
                3 => 1.12,
                _ => 1.,
            };
        }
        if in_cell {
            size *= 0.9;
        }
        let strong = heading.is_some() || self.bold > 0;
        let link = autolink.or_else(|| self.links.last().cloned().flatten());
        let span = Span {
            text: text.to_owned(),
            size: if code { size * 0.9 } else { size },
            bold: strong,
            italic: self.italic > 0 && (code || heading.is_none()),
            mono: code,
            serif: heading.is_some() && !code,
            code,
            strike: self.strike > 0,
            link,
        };
        let spans = match self.stack.last_mut() {
            Some(Container::Text { spans, plain, .. }) => {
                plain.push_str(raw);
                spans
            }
            Some(Container::Cell(spans)) => spans,
            Some(Container::Code { code, lines, .. }) => {
                code.push_str(text);
                *lines = true;
                return;
            }
            Some(Container::Html) => return,
            _ => {
                // Text outside any block (stray inline content) gets a paragraph.
                self.open_text(None, false);
                let Some(Container::Text { spans, .. }) = self.stack.last_mut() else {
                    return;
                };
                spans.push(span);
                self.close_text();
                return;
            }
        };
        match spans.last_mut() {
            Some(last) if last.same_dress(&span) => last.text.push_str(&span.text),
            _ => spans.push(span),
        }
    }

    fn finish(mut self) -> Vec<Block> {
        while self.stack.len() > 1 {
            match self.stack.last() {
                Some(Container::Text { .. }) => self.close_text(),
                Some(Container::Item(..)) => self.end(TagEnd::Item),
                Some(Container::Quote(..)) => self.end(TagEnd::BlockQuote(None)),
                Some(Container::Code { .. }) => self.end(TagEnd::CodeBlock),
                Some(Container::List { .. }) => self.end(TagEnd::List(false)),
                Some(Container::Cell(_)) => self.end(TagEnd::TableCell),
                Some(Container::Table { .. }) => self.end(TagEnd::Table),
                _ => {
                    self.stack.pop();
                }
            }
        }
        match self.stack.pop() {
            Some(Container::Root(blocks)) => blocks,
            _ => Vec::new(),
        }
    }
}

/// A paragraph's trailing whitespace is not part of it.
fn trimmed(mut spans: Vec<Span>) -> Vec<Span> {
    while let Some(last) = spans.last_mut() {
        let kept = last.text.trim_end_matches([' ', '\t']).len();
        last.text.truncate(kept);
        if last.text.is_empty() {
            spans.pop();
        } else {
            break;
        }
    }
    spans
}

/// The first GFM extended autolink in `text`: its byte range and href.
fn autolink(text: &str) -> Option<(usize, usize, String)> {
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let rest = &text[index..];
        let boundary = index == 0
            || matches!(
                bytes[index - 1],
                b' ' | b'\t' | b'\n' | b'*' | b'_' | b'~' | b'('
            );
        let scheme = ["https://", "http://", "www."].into_iter().find(|prefix| {
            rest.len() > prefix.len()
                && rest.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
        });
        if boundary && let Some(prefix) = scheme {
            let mut end = index
                + rest
                    .find(|c: char| c.is_whitespace() || c == '<')
                    .unwrap_or(rest.len());
            // Trailing punctuation is not part of the address, nor is a
            // closing parenthesis the address did not open.
            loop {
                let candidate = &text[index..end];
                let Some(last) = candidate.chars().last() else {
                    break;
                };
                if matches!(
                    last,
                    '?' | '!' | '.' | ',' | ':' | '*' | '_' | '~' | '\'' | '"'
                ) {
                    end -= last.len_utf8();
                } else if last == ')'
                    && candidate.matches(')').count() > candidate.matches('(').count()
                {
                    end -= 1;
                } else {
                    break;
                }
            }
            let link = &text[index..end];
            let domain = link[prefix.len()..]
                .split(['/', '?', '#'])
                .next()
                .unwrap_or("");
            if domain.contains('.') && domain.len() > 2 {
                let href = if prefix == "www." {
                    format!("http://{link}")
                } else {
                    link.to_owned()
                };
                return Some((index, end, href));
            }
        }
        index += rest.chars().next().map_or(1, char::len_utf8);
    }
    None
}

#[cfg(test)]
#[path = "markdown_tests.rs"]
mod tests;
