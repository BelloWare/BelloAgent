//! Source requested edit/content cards. Preview is a projection of retained
//! arguments, never a claim that an interrupted edit was applied or rolled back.
use super::{
    read_presentation::ReadFileLink,
    tool_presentation::{self, ProjectedRow, Status},
};
use bello_agent_core::{
    Session, provider::ToolCall, tool_content::ReadStats, tool_history::ToolRecord,
};
use unicode_normalization::UnicodeNormalization;

pub(super) fn edit_call(session: &Session, row: ProjectedRow) -> Option<&ToolCall> {
    let call = match row {
        ProjectedRow::Call {
            assistant, call, ..
        } => tool_presentation::call_at(session, assistant, call),
        ProjectedRow::Result(index) => {
            let Some(ToolRecord::Result(result)) = &session.messages[index].tool_record else {
                return None;
            };
            let mut owners = session
                .messages
                .iter()
                .enumerate()
                .filter(|(_, m)| m.id == result.assistant_id);
            let (owner_index, owner) = owners.next()?;
            if owners.next().is_some() || owner.role != "assistant" || owner_index >= index {
                return None;
            }
            let Some(ToolRecord::Assistant(record)) = &owner.tool_record else {
                return None;
            };
            let mut calls = record.calls.iter().filter(|call| call.id == result.call_id);
            let call = calls.next()?;
            if calls.next().is_some() {
                return None;
            }
            call
        }
        _ => return None,
    };
    matches!(call.name.as_str(), "write" | "edit").then_some(call)
}
pub(super) fn stats(session: &Session, row: ProjectedRow) -> Option<&ReadStats> {
    let Some(ToolRecord::Result(record)) = &session.messages.get(row.result()?)?.tool_record else {
        return None;
    };
    record.content.as_ref()?.stats.as_ref()
}
pub(super) fn file_link(session: &Session, row: ProjectedRow) -> Option<ReadFileLink> {
    let call = edit_call(session, row)?;
    let status = tool_presentation::status(session, row);
    let stats = stats(session, row);
    let path = stats
        .map(|stats| stats.path.as_str())
        .filter(|p| !p.is_empty())
        .or_else(|| {
            (status != Status::Awaiting)
                .then(|| call.arguments["path"].as_str())
                .flatten()
        })?;
    if path.is_empty() {
        return None;
    }
    let lines = if status == Status::Completed {
        stats.and_then(|s| {
            s.line
                .map(|first| first as usize..=s.last_line.unwrap_or(first).max(first) as usize)
        })
    } else {
        None
    };
    Some(ReadFileLink {
        path: path.into(),
        lines,
    })
}
pub(super) fn has_request(session: &Session, row: ProjectedRow) -> bool {
    edit_call(session, row).is_some_and(|call| {
        call.arguments["oldText"].is_string()
            || call
                .arguments
                .get("newText")
                .or_else(|| call.arguments.get("content"))
                .is_some_and(|value| value.is_string())
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Context,
    Removed,
    Added,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct DiffRow<'a> {
    pub kind: Kind,
    pub text: &'a str,
}
pub(super) struct EditRequest<'a> {
    pub editing: bool,
    pub before: &'a str,
    pub after: &'a str,
    pub rows: Vec<DiffRow<'a>>,
    pub too_large: bool,
    pub lines: usize,
    pub status: Status,
    pub added: Option<u32>,
    pub removed: Option<u32>,
}
impl<'a> EditRequest<'a> {
    pub fn new(call: &'a ToolCall, status: Status, stats: Option<&ReadStats>) -> Option<Self> {
        let old = call.arguments["oldText"].as_str();
        let new = call
            .arguments
            .get("newText")
            .or_else(|| call.arguments.get("content"))
            .and_then(|v| v.as_str());
        if old.is_none() && new.is_none() {
            return None;
        }
        let before = old.unwrap_or("");
        let after = new.or(old).unwrap_or("");
        let line_count = |text: &str| {
            if text.is_empty() {
                0
            } else {
                text.bytes().filter(|b| *b == b'\n').count() + 1
            }
        };
        let lines = line_count(before).max(line_count(after));
        let too_large = before.len().saturating_add(after.len()) > 256 * 1024 || lines > 4000;
        let editing = call.name == "edit";
        let created = stats.is_some_and(|s| s.added.is_some() && s.removed.unwrap_or(0) == 0);
        let rows = if too_large {
            vec![]
        } else if editing || (created && status == Status::Completed) {
            line_diff(before, after)
        } else {
            after
                .split('\n')
                .map(|text| DiffRow {
                    kind: Kind::Context,
                    text,
                })
                .collect()
        };
        Some(Self {
            editing,
            before,
            after,
            rows,
            too_large,
            lines,
            status,
            added: stats.and_then(|s| s.added),
            removed: stats.and_then(|s| s.removed),
        })
    }
    pub fn label(&self) -> String {
        let base = if self.editing {
            "Requested edit"
        } else {
            "Requested content"
        };
        let suffix = match self.status {
            Status::Completed => "",
            Status::Awaiting | Status::Running => " · in progress",
            Status::Unknown | Status::Missing | Status::Cancelled => " · outcome unknown",
            _ if self.editing => " · not applied",
            _ => " · not written",
        };
        format!("{base}{suffix}")
    }
    pub fn collapsible(&self) -> bool {
        self.too_large
            || super::card_lines::collapses(self.rows.len() as isize - MAX_LINES as isize)
    }
    pub fn footer(&self) -> String {
        let plus = self
            .added
            .map(|n| n as usize)
            .unwrap_or_else(|| self.rows.iter().filter(|r| r.kind == Kind::Added).count());
        let minus = self
            .removed
            .map(|n| n as usize)
            .unwrap_or_else(|| self.rows.iter().filter(|r| r.kind == Kind::Removed).count());
        format!(
            "+{} −{}",
            super::card_lines::number(plus),
            super::card_lines::number(minus)
        )
    }
    /// The diff's rows' texts, one line each; their marks stand apart.
    pub fn rows_text(&self) -> String {
        let mut text = String::new();
        for (i, row) in self.rows.iter().enumerate() {
            if i > 0 {
                text.push('\n');
            }
            text.push_str(row.text);
        }
        text
    }
    /// A change too large to diff: what the card says of it, and once the
    /// reader asks, its whole content.
    pub fn large_preview(&self, expanded: bool) -> String {
        if !expanded {
            return format!(
                "Diff preview unavailable — {} lines. Full content is available below.",
                super::card_lines::number(self.lines)
            );
        }
        if self.editing {
            format!("Before\n{}\n\nAfter\n{}", self.before, self.after)
        } else {
            self.after.into()
        }
    }
}
/// `TranscriptCardMetrics.diffLines`.
const MAX_LINES: usize = super::card_lines::MAX_LINES;
fn line_diff<'a>(before: &'a str, after: &'a str) -> Vec<DiffRow<'a>> {
    let a: Vec<_> = before.split('\n').collect();
    let b: Vec<_> = after.split('\n').collect();
    if a.len() > 300 || b.len() > 300 {
        return a
            .into_iter()
            .map(|text| DiffRow {
                kind: Kind::Removed,
                text,
            })
            .chain(b.into_iter().map(|text| DiffRow {
                kind: Kind::Added,
                text,
            }))
            .collect();
    }
    let normalized_a: Vec<String> = a.iter().map(|s| s.nfc().collect()).collect();
    let normalized_b: Vec<String> = b.iter().map(|s| s.nfc().collect()).collect();
    let mut lengths = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            lengths[i][j] = if normalized_a[i] == normalized_b[j] {
                lengths[i + 1][j + 1] + 1
            } else {
                lengths[i + 1][j].max(lengths[i][j + 1])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut rows = vec![];
    while i < a.len() && j < b.len() {
        if normalized_a[i] == normalized_b[j] {
            rows.push(DiffRow {
                kind: Kind::Context,
                text: a[i],
            });
            i += 1;
            j += 1;
        } else if lengths[i + 1][j] >= lengths[i][j + 1] {
            rows.push(DiffRow {
                kind: Kind::Removed,
                text: a[i],
            });
            i += 1;
        } else {
            rows.push(DiffRow {
                kind: Kind::Added,
                text: b[j],
            });
            j += 1;
        }
    }
    rows.extend(a[i..].iter().map(|text| DiffRow {
        kind: Kind::Removed,
        text,
    }));
    rows.extend(b[j..].iter().map(|text| DiffRow {
        kind: Kind::Added,
        text,
    }));
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn call(name: &str, args: serde_json::Value) -> ToolCall {
        ToolCall {
            id: "fixture".into(),
            name: name.into(),
            arguments: args,
        }
    }
    #[test]
    fn source_lcs_unicode_and_noncompleted_labels() {
        let input = call(
            "edit",
            json!({"oldText":"é\nold\nsame","newText":"e\u{301}\nnew\nsame"}),
        );
        let request = EditRequest::new(&input, Status::Unknown, None).unwrap();
        assert_eq!(request.label(), "Requested edit · outcome unknown");
        assert_eq!(request.rows_text(), "é\nold\nnew\nsame");
        assert_eq!(
            request.rows.iter().map(|row| row.kind).collect::<Vec<_>>(),
            [Kind::Context, Kind::Removed, Kind::Added, Kind::Context]
        );
        assert_eq!(request.footer(), "+1 −1");
        for status in [Status::Unknown, Status::Missing, Status::Cancelled] {
            assert!(
                !EditRequest::new(&input, status, None)
                    .unwrap()
                    .label()
                    .contains("not applied")
            );
        }
        assert!(
            EditRequest::new(&input, Status::NotExecuted, None)
                .unwrap()
                .label()
                .ends_with("not applied")
        );
    }
    #[test]
    fn writes_show_requested_content_without_inventing_previous_contents() {
        let input = call("write", json!({"content":"new\n"}));
        let request = EditRequest::new(&input, Status::Completed, None).unwrap();
        assert_eq!(request.rows_text(), "new\n");
        assert!(request.rows.iter().all(|row| row.kind == Kind::Context));
        assert_eq!(request.label(), "Requested content");
    }
    #[test]
    fn source_head_tail_and_large_content_are_explicit_and_exact() {
        let text = (0..20)
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        let input = call("write", json!({"content":text}));
        let request = EditRequest::new(&input, Status::Awaiting, None).unwrap();
        assert!(request.collapsible());
        assert_eq!(
            super::super::card_lines::head_tail(request.rows.len(), MAX_LINES, false).hidden,
            8
        );
        let text = "x".repeat(256 * 1024 + 1);
        let input = call("write", json!({"content":text}));
        let request = EditRequest::new(&input, Status::Unknown, None).unwrap();
        assert!(request.too_large);
        assert_eq!(
            request.large_preview(false),
            "Diff preview unavailable — 1 lines. Full content is available below."
        );
        assert_eq!(request.large_preview(true), text);
        let text = "x\n".repeat(9000);
        let input = call("write", json!({"content":text}));
        let request = EditRequest::new(&input, Status::Unknown, None).unwrap();
        assert!(request.large_preview(false).contains("— 9,001 lines."));
    }
}

/// Source-bounded diff cache: no more than 512 entries or 32 MiB of retained
/// text. Exact text/status/count equality guards reuse; hashes alone never
/// decide that two requests are the same. Large content is copied only after
/// its explicit disclosure, and entries larger than the budget are not kept.
#[derive(Default)]
pub(super) struct EditCache {
    entries: std::collections::HashMap<super::RowKey, CachedEdit>,
    bytes: usize,
    tick: u64,
    #[cfg(test)]
    pub computations: usize,
}
struct CachedEdit {
    old: Option<String>,
    new: Option<String>,
    editing: bool,
    status: Status,
    added: Option<u32>,
    removed: Option<u32>,
    cost: usize,
    used: u64,
    preview: std::sync::Arc<EditPreview>,
}
pub(super) struct EditPreview {
    pub label: String,
    /// The diff's rows' texts, one line each; empty when too large to diff.
    pub rows: String,
    pub kinds: Vec<Kind>,
    /// A change too large to diff: its note, and once asked for, its content.
    pub collapsed: String,
    pub full: Option<String>,
    pub footer: Option<String>,
    pub collapsible: bool,
    pub too_large: bool,
}
impl EditPreview {
    /// What a change too large to diff shows in its section.
    pub fn text(&self, expanded: bool) -> &str {
        if expanded {
            self.full.as_deref().unwrap_or(&self.collapsed)
        } else {
            &self.collapsed
        }
    }
}
impl EditCache {
    pub fn get(
        &mut self,
        key: &super::RowKey,
        session: &Session,
        row: ProjectedRow,
        expanded: bool,
    ) -> Option<std::sync::Arc<EditPreview>> {
        let call = edit_call(session, row)?;
        let status = tool_presentation::status(session, row);
        let stats = stats(session, row);
        let old = call.arguments["oldText"].as_str();
        let new = call
            .arguments
            .get("newText")
            .or_else(|| call.arguments.get("content"))
            .and_then(|v| v.as_str());
        let editing = call.name == "edit";
        let added = stats.and_then(|s| s.added);
        let removed = stats.and_then(|s| s.removed);
        self.tick = self.tick.wrapping_add(1);
        if let Some(entry) = self.entries.get_mut(key)
            && entry.old.as_deref() == old
            && entry.new.as_deref() == new
            && entry.editing == editing
            && entry.status == status
            && entry.added == added
            && entry.removed == removed
            && (!expanded || !entry.preview.too_large || entry.preview.full.is_some())
        {
            entry.used = self.tick;
            return Some(entry.preview.clone());
        }
        let request = EditRequest::new(call, status, stats)?;
        #[cfg(test)]
        {
            self.computations += 1;
        }
        let preview = std::sync::Arc::new(EditPreview {
            label: request.label(),
            rows: request.rows_text(),
            kinds: request.rows.iter().map(|row| row.kind).collect(),
            collapsed: if request.too_large {
                request.large_preview(false)
            } else {
                String::new()
            },
            full: (request.too_large && expanded).then(|| request.large_preview(true)),
            footer: (!request.too_large || added.is_some() || removed.is_some())
                .then(|| request.footer()),
            collapsible: request.collapsible(),
            too_large: request.too_large,
        });
        if let Some(previous) = self.entries.remove(key) {
            self.bytes -= previous.cost;
        }
        let cost = old.map_or(0, str::len)
            + new.map_or(0, str::len)
            + preview.rows.len()
            + preview.kinds.len()
            + preview.collapsed.len()
            + preview.full.as_ref().map_or(0, String::len)
            + 256;
        const BUDGET: usize = 32 * 1024 * 1024;
        if cost <= BUDGET {
            while self.bytes + cost > BUDGET || self.entries.len() >= 512 {
                let oldest = self
                    .entries
                    .iter()
                    .min_by_key(|(_, entry)| entry.used)
                    .map(|(key, _)| key.clone())?;
                self.bytes -= self.entries.remove(&oldest).unwrap().cost;
            }
            self.entries.insert(
                key.clone(),
                CachedEdit {
                    old: old.map(str::to_owned),
                    new: new.map(str::to_owned),
                    editing,
                    status,
                    added,
                    removed,
                    cost,
                    used: self.tick,
                    preview: preview.clone(),
                },
            );
            self.bytes += cost;
        }
        Some(preview)
    }
}
