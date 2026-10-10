//! What a tool call's work row says, as Swift 0.1.122 works it out
//! (`TranscriptToolRow.model` in TranscriptRowParts.swift, over
//! `TranscriptActivity.actionParts`/`describe`/`outcome`/`firstLine`/
//! `shortPath`/`fileLink`, `actionSymbol` and `ToolCallSummary`). Pure values:
//! `transcript_tool_row_oracle_tests` holds every rule to Swift's own code.
use bello_agent_core::tool_timing::DurationUs;
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

/// The call as Swift's `ToolView` carries it, borrowed from Rust's history.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ToolFacts<'a> {
    pub name: &'a str,
    pub arguments: &'a Value,
    /// Swift's helper state: "completed", "failed", "cancelled", "unknown",
    /// "running", "prepared", "preparing" or "recorded".
    pub state: &'a str,
    pub output: &'a str,
    pub duration_us: Option<u64>,
    /// The path the host resolved, once the call ran.
    pub path: Option<&'a str>,
    pub added: Option<u32>,
    pub removed: Option<u32>,
    pub line: Option<u32>,
    pub last_line: Option<u32>,
    pub input_truncated: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionKind {
    Command,
    Read,
    Write,
    Search,
    List,
    Mcp,
    Other,
}

impl ActionKind {
    #[cfg(test)]
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Command => "command",
            Self::Read => "read",
            Self::Write => "write",
            Self::Search => "search",
            Self::List => "list",
            Self::Mcp => "mcp",
            Self::Other => "other",
        }
    }
    /// `actionSymbol`: the SF Symbol each kind reads as (an SVG of that name
    /// in assets.rs).
    pub(crate) fn icon(self) -> &'static str {
        match self {
            Self::Command => "terminal",
            Self::Write => "pencil",
            Self::Read => "doc.text",
            Self::List => "folder",
            Self::Search => "magnifyingglass",
            Self::Mcp => "point.3.connected.trianglepath.dotted",
            Self::Other => "circle",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    Running,
    Done,
    Failed,
    Cancelled,
    Unknown,
}

impl Outcome {
    pub(crate) fn of(state: &str) -> Self {
        match state {
            "running" | "preparing" | "prepared" => Self::Running,
            "cancelled" => Self::Cancelled,
            "failed" => Self::Failed,
            "unknown" => Self::Unknown,
            _ => Self::Done,
        }
    }
    #[cfg(test)]
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Done => "done",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
        }
    }
}

/// `TranscriptRowState`: a stopped call is amber, a failed one red.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RowState {
    Ok,
    Running,
    Stopped,
    Failed,
}

impl RowState {
    #[cfg(test)]
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Running => "running",
            Self::Stopped => "stopped",
            Self::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Parts {
    pub kind: ActionKind,
    pub done: &'static str,
    pub doing: &'static str,
    pub object: String,
    pub path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileLink {
    pub path: String,
    pub lines: Option<std::ops::RangeInclusive<usize>>,
}

/// `TranscriptToolRow.Model`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Model {
    pub icon: &'static str,
    pub title: String,
    pub summary: String,
    pub suffix: Option<String>,
    pub state: RowState,
    pub trailing: Option<String>,
    pub help: String,
    pub links_summary: bool,
    pub kind: ActionKind,
    pub verb: String,
    pub object: String,
    pub path: Option<String>,
    pub outcome: Outcome,
    pub file: Option<FileLink>,
}

/// A non-empty top-level string member, as `text(argumentString(...))` reads it.
fn member<'a>(arguments: &'a Value, key: &str) -> Option<&'a str> {
    arguments
        .as_object()?
        .get(key)?
        .as_str()
        .filter(|text| !text.is_empty())
}

fn nonempty(text: Option<&str>) -> Option<&str> {
    text.filter(|text| !text.is_empty())
}

/// The document the call's arguments were, as Swift's `tool.input` holds it.
fn raw_input(arguments: &Value) -> std::borrow::Cow<'_, str> {
    match arguments {
        Value::String(text) => text.into(),
        other => other.to_string().into(),
    }
}

/// `shortPath`: the last two components of a longer path.
pub(crate) fn short_path(path: &str) -> String {
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    if parts.len() > 2 {
        parts[parts.len() - 2..].join("/")
    } else {
        path.to_owned()
    }
}

/// `firstLine`: up to the first newline, trimmed, at most `max` characters
/// (grapheme clusters, as Swift counts them) with an ellipsis.
pub(crate) fn first_line(text: &str, max: usize) -> String {
    let line = text[..text.find('\n').unwrap_or(text.len())].trim();
    if line.graphemes(true).count() > max {
        let mut cut: String = line.graphemes(true).take(max - 1).collect();
        cut.push('…');
        cut
    } else {
        line.to_owned()
    }
}

pub(crate) fn parts(tool: &ToolFacts) -> Parts {
    let make = |kind, done, doing, object: String, path| Parts {
        kind,
        done,
        doing,
        object,
        path,
    };
    match tool.name {
        "read" | "write" | "edit" | "ls" => {
            let path = if tool.name == "read" {
                member(tool.arguments, "path").or(nonempty(tool.path))
            } else {
                nonempty(tool.path).or(member(tool.arguments, "path"))
            };
            let object = |fallback: &str| path.map_or_else(|| fallback.to_owned(), short_path);
            let path = path.map(str::to_owned);
            match tool.name {
                "read" => make(ActionKind::Read, "Read", "reading", object("file"), path),
                "write" => {
                    let created = tool.added.is_some() && tool.removed.unwrap_or(0) == 0;
                    let done = if created { "Created" } else { "Wrote" };
                    make(ActionKind::Write, done, "writing", object("file"), path)
                }
                "edit" => make(ActionKind::Write, "Edited", "editing", object("file"), path),
                _ => make(
                    ActionKind::List,
                    "Listed",
                    "listing",
                    object("directory"),
                    path,
                ),
            }
        }
        "bash" => {
            // The whole document is serialized only when it has no command:
            // a heredoc's body is never copied to draw its first line.
            let command = match member(tool.arguments, "command") {
                Some(command) => first_line(command, 96),
                None => first_line(&raw_input(tool.arguments), 96),
            };
            let object = if command.is_empty() {
                "command".into()
            } else {
                command
            };
            make(ActionKind::Command, "Ran", "running", object, None)
        }
        "find" | "grep" => {
            let object = member(tool.arguments, "pattern")
                .unwrap_or("files")
                .to_owned();
            make(ActionKind::Search, "Searched", "searching", object, None)
        }
        "mcp" => {
            let action = member(tool.arguments, "action").unwrap_or("invoke");
            let server = member(tool.arguments, "server");
            if action == "list" {
                let object =
                    server.map_or_else(|| "MCP servers".into(), |s| format!("tools on {s}"));
                return make(ActionKind::Mcp, "Listed", "listing", object, None);
            }
            if action == "describe" {
                let count = tool
                    .arguments
                    .get("targets")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len);
                let object = match count {
                    0 => "tool schemas".into(),
                    1 => "1 tool schema".into(),
                    n => format!("{n} tool schemas"),
                };
                return make(ActionKind::Mcp, "Loaded", "loading", object, None);
            }
            let object = format!(
                "{} · {}",
                server.unwrap_or("server"),
                member(tool.arguments, "tool").unwrap_or("call")
            );
            make(ActionKind::Mcp, "Called", "calling", object, None)
        }
        name => make(ActionKind::Other, "Used", "using", name.to_owned(), None),
    }
}

/// `conjugate`: the verb never claims work that did not happen.
pub(crate) fn verb(parts: &Parts, outcome: Outcome) -> String {
    let doing = parts.doing;
    match outcome {
        Outcome::Running => {
            let mut chars = doing.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(chars).collect()
            })
        }
        Outcome::Failed => format!("Failed {doing}"),
        Outcome::Cancelled => format!("Skipped {doing}"),
        Outcome::Unknown => format!("Stopped {doing}"),
        Outcome::Done => parts.done.to_owned(),
    }
}

pub(crate) fn row_state(outcome: Outcome) -> RowState {
    match outcome {
        Outcome::Running => RowState::Running,
        Outcome::Cancelled | Outcome::Unknown => RowState::Stopped,
        Outcome::Failed => RowState::Failed,
        Outcome::Done => RowState::Ok,
    }
}

/// `TranscriptReadCardText.firstLine(of:)`: the host's 1-based `offset`.
pub(crate) fn read_first_line(arguments: &Value) -> usize {
    let Some(offset) = arguments.get("offset").filter(|value| value.is_number()) else {
        return 1;
    };
    let value = offset.as_f64().unwrap_or(0.);
    if value.is_finite() && value >= 1. && value.round() == value && value <= 10_000_000. {
        value as usize
    } else {
        1
    }
}

/// `TranscriptReadCardText.window(of:)`'s line count: the host's closing
/// "[Truncated. …]" note is not a line of the file.
fn read_lines_shown(text: &str) -> usize {
    if text.is_empty() {
        return 0;
    }
    let lines = text.split('\n').count();
    let last = &text[text.rfind('\n').map_or(0, |at| at + 1)..];
    lines - usize::from(last.starts_with("[Truncated.") && last.ends_with(']'))
}

/// `fileLink`: where a read, a write or an edit opens its file.
pub(crate) fn file_link(tool: &ToolFacts, outcome: Outcome) -> Option<FileLink> {
    if !matches!(tool.name, "read" | "write" | "edit") {
        return None;
    }
    let path = match nonempty(tool.path) {
        Some(resolved) => resolved,
        None => {
            if outcome == Outcome::Running || tool.input_truncated {
                return None;
            }
            member(tool.arguments, "path")?
        }
    }
    .to_owned();
    if outcome != Outcome::Done {
        return Some(FileLink { path, lines: None });
    }
    if tool.name == "read" {
        let object = tool.arguments.as_object();
        let named = object.is_some_and(|o| o.contains_key("offset") || o.contains_key("limit"));
        if !named || tool.output.starts_with("Read image file [") {
            return Some(FileLink { path, lines: None });
        }
    }
    if let Some(first) = tool.line.filter(|&line| line > 0) {
        let last = tool.last_line.unwrap_or(first).max(first);
        return Some(FileLink {
            path,
            lines: Some(first as usize..=last as usize),
        });
    }
    if tool.name != "read" {
        return Some(FileLink { path, lines: None });
    }
    let (first, shown) = (
        read_first_line(tool.arguments),
        read_lines_shown(tool.output),
    );
    Some(FileLink {
        path,
        lines: (shown > 0).then(|| first..=first + shown - 1),
    })
}

/// `TranscriptToolRow.model(of:)`.
pub(crate) fn model(tool: &ToolFacts) -> Model {
    let parts = parts(tool);
    let outcome = Outcome::of(tool.state);
    let state = row_state(outcome);
    let verb = verb(&parts, outcome);
    let title = if matches!(outcome, Outcome::Unknown | Outcome::Cancelled) {
        verb.clone()
    } else {
        parts.done.to_owned()
    };
    // A failure's first line replaces the argument summary outright.
    let summary = if state == RowState::Failed && !tool.output.is_empty() {
        first_line(tool.output, 96)
    } else {
        parts.object.clone()
    };
    let change = (tool.added.is_some() || tool.removed.is_some()).then(|| {
        format!(
            "+{} −{}",
            tool.added.unwrap_or(0),
            tool.removed.unwrap_or(0)
        )
    });
    let suffix = if outcome == Outcome::Unknown {
        Some(match change {
            Some(change) => format!("{change} · outcome unknown"),
            None => "· outcome unknown".into(),
        })
    } else {
        change
    };
    let trailing = (outcome != Outcome::Running)
        .then_some(tool.duration_us)
        .flatten()
        .and_then(|us| crate::tool_timing_presentation::elapsed(Some(DurationUs::new(us))));
    Model {
        icon: parts.kind.icon(),
        title,
        links_summary: summary == parts.object,
        summary,
        suffix,
        state,
        trailing,
        help: parts.path.clone().unwrap_or_else(|| parts.object.clone()),
        kind: parts.kind,
        verb,
        file: file_link(tool, outcome),
        object: parts.object,
        path: parts.path,
        outcome,
    }
}

/// `ToolCallSummary`, over one reply's calls or several replies' calls:
/// issued calls with what failed, was skipped or ended unknown.
// The response line and turn folds read it next; the oracle holds it now.
#[cfg_attr(not(test), allow(dead_code))]
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct CallSummary {
    pub total: usize,
    pub failed: usize,
    pub skipped: usize,
    pub uncertain: usize,
    pub preparing: bool,
    pub partial: bool,
}

#[cfg_attr(not(test), allow(dead_code))]
impl CallSummary {
    /// One reply's calls, by their helper states.
    pub(crate) fn add_reply<'a>(
        &mut self,
        states: impl IntoIterator<Item = &'a str>,
        count: Option<i64>,
        truncated: bool,
    ) {
        let mut confirmed = 0;
        for state in states {
            if state == "preparing" {
                self.preparing = true;
                continue;
            }
            confirmed += 1;
            match state {
                "failed" => self.failed += 1,
                "cancelled" | "skipped" => self.skipped += 1,
                "recorded" | "unknown" | "interrupted" => self.uncertain += 1,
                _ => {}
            }
        }
        match count.filter(|&count| count >= 0) {
            Some(count) => self.total += count as usize,
            None => {
                self.total += confirmed;
                self.partial |= truncated;
            }
        }
    }

    pub(crate) fn label(&self, reasoned: bool) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        if reasoned {
            parts.push("Reasoned".into());
        }
        if self.total > 0 {
            parts.push(format!(
                "{}{} tool {}",
                if self.partial { "at least " } else { "" },
                self.total,
                if self.total == 1 { "call" } else { "calls" }
            ));
        }
        if self.failed > 0 {
            parts.push(format!("{} failed", self.failed));
        }
        if self.skipped > 0 {
            parts.push(format!("{} skipped", self.skipped));
        }
        if self.uncertain > 0 {
            parts.push(format!("{} outcome unknown", self.uncertain));
        }
        if self.preparing {
            parts.push("Preparing tool call…".into());
        }
        (!parts.is_empty()).then(|| parts.join(" · "))
    }
}

#[cfg(test)]
#[path = "transcript_tool_row_oracle_tests.rs"]
mod oracle_tests;

/// Swift's helper state for a call in Rust's history.
pub(super) fn helper_state(status: super::tool_presentation::Status) -> &'static str {
    use super::tool_presentation::Status;
    match status {
        Status::Completed => "completed",
        Status::Failed => "failed",
        // Never ran: Swift's "Skipped".
        Status::NotExecuted => "cancelled",
        // Rust's legacy cancellation, stopped with no result: amber, as
        // Swift's unknown outcome reads.
        Status::Cancelled | Status::Unknown => "unknown",
        // Swift's journal card that holds only the request.
        Status::Missing => "recorded",
        Status::Awaiting => "prepared",
        Status::Running => "running",
    }
}

/// The row model of a call on the page: its arguments, its result or live
/// preview, the host's file facts and its clock.
pub(super) fn row_model(
    session: &bello_agent_core::Session,
    row: super::tool_presentation::ProjectedRow,
) -> Option<Model> {
    use super::tool_presentation as tools;
    let tools::ProjectedRow::Call {
        assistant, call, ..
    } = row
    else {
        return None;
    };
    let call = tools::call_at(session, assistant, call);
    let output = row
        .result()
        .map(|index| tools::display_text(&session.messages[index]))
        .or_else(|| tools::live(session, row).map(|view| view.preview.as_ref().into()));
    let stats = super::edit_presentation::stats(session, row);
    Some(model(&ToolFacts {
        name: &call.name,
        arguments: &call.arguments,
        state: helper_state(tools::status(session, row)),
        output: output.as_deref().unwrap_or(""),
        duration_us: tools::duration(session, row).map(DurationUs::get),
        path: stats.map(|stats| stats.path.as_str()),
        added: stats.and_then(|stats| stats.added),
        removed: stats.and_then(|stats| stats.removed),
        line: stats.and_then(|stats| stats.line),
        last_line: stats.and_then(|stats| stats.last_line),
        input_truncated: false,
    }))
}

pub(super) fn work_state(state: RowState) -> super::work_line::WorkState {
    use super::work_line::WorkState;
    match state {
        RowState::Ok => WorkState::Ok,
        RowState::Running => WorkState::Running,
        RowState::Stopped => WorkState::Stopped,
        RowState::Failed => WorkState::Failed,
    }
}
