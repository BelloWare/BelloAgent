//! Sidebar chat state Swift keeps on WorkspaceModel: rows marked for a bulk
//! action (SidebarSelection.swift, SessionOrganizationBatch.swift), the
//! recency wash (WorkspaceRecency.swift), the draft marker
//! (WorkspaceDraftMarks.swift) and session references (WorkspaceContent.swift,
//! SessionReference.swift). The rename sheet and the delete question live in
//! sidebar_chat_rename.rs and sidebar_chat_delete.rs; this module routes the
//! keys and overlay of whichever is open.
use crate::{
    AgentView,
    sidebar_actions::{
        ChatMenuFacts, MarkedMenuFacts, SidebarAction, SidebarMenuEntry, chat_menu_entries,
        marked_menu_entries,
    },
};
use bello_agent_core::workspace::{ChatMaterialization, ChatRecord, DraftRecord};
use gpui::{prelude::*, *};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// SidebarSelection.markedSessionLimit (TopicSessionDrag.maximumSessions).
pub(crate) const MARKED_SESSION_LIMIT: usize = 500;
/// WorkspaceModel.recentlyOpenedLimit.
pub(crate) const RECENTLY_OPENED_LIMIT: usize = 16;
/// PiKit.SelectableRow.recencyLadder: how much of the open row's wash the
/// chat opened `rank` openings ago keeps.
pub(crate) const RECENCY_LADDER: [f32; 5] = [1., 0.75, 0.5, 0.3, 0.15];

pub(crate) fn recency_tint(rank: Option<usize>) -> f32 {
    rank.and_then(|rank| RECENCY_LADDER.get(rank).copied())
        .unwrap_or(0.)
}

#[derive(Default)]
pub(crate) struct SidebarChats {
    pub(crate) rename: Option<crate::sidebar_chat_rename::RenameSheet>,
    pub(crate) delete: Option<crate::sidebar_chat_delete::DeleteQuestion>,
    /// Chats with a rename or deletion in flight.
    pub(crate) busy: BTreeSet<String>,
    marks: BTreeSet<String>,
    mark_anchor: Option<String>,
    /// Chats by order of opening, the open one first.
    recent: Vec<String>,
    recent_store: Option<Arc<RecentStore>>,
    /// Chats whose saved draft holds something unsent.
    draft_marks: BTreeSet<String>,
    copy_revision: u64,
}
impl SidebarChats {
    /// At launch: the saved drafts' markers and the remembered order of
    /// opening, kept beside the window layout.
    /// `chats` is the catalog's managed chat directory, the same for every
    /// launch whichever chat it opens.
    pub(crate) fn restore(
        drafts: &BTreeMap<String, DraftRecord>,
        records: &[ChatRecord],
        launch: &ChatRecord,
        chats: Option<&Path>,
    ) -> Self {
        let store = chats
            .filter(|_| cfg!(not(test)))
            .map(|directory| Arc::new(RecentStore::new(directory.join("recent-chats.json"))));
        let mut recent = store
            .as_ref()
            .map(|store| adopt_recent(store.load(), records))
            .unwrap_or_default();
        note_opened(&mut recent, &launch.id);
        Self {
            draft_marks: drafts
                .iter()
                .filter(|(_, draft)| draft.holds_unsent())
                .map(|(id, _)| id.clone())
                .collect(),
            recent,
            recent_store: store,
            ..Default::default()
        }
    }
    pub(crate) fn modal_open(&self) -> bool {
        self.rename.is_some() || self.delete.is_some()
    }
    pub(crate) fn is_marked(&self, id: &str) -> bool {
        self.marks.contains(id)
    }
    /// What a bulk menu offers: marking one row is still an ordinary selection.
    pub(crate) fn has_marked_sessions(&self) -> bool {
        self.marks.len() > 1
    }
    pub(crate) fn recency_rank(&self, id: &str) -> Option<usize> {
        self.recent
            .iter()
            .position(|recent| recent == id)
            .filter(|rank| *rank < RECENCY_LADDER.len())
    }
    pub(crate) fn has_draft_mark(&self, id: &str) -> bool {
        self.draft_marks.contains(id)
    }
    /// A chat that is gone holds no mark, place or draft marker.
    pub(crate) fn forget(&mut self, id: &str) {
        self.marks.remove(id);
        if self.mark_anchor.as_deref() == Some(id) {
            self.mark_anchor = None;
        }
        self.recent.retain(|recent| recent != id);
        self.draft_marks.remove(id);
    }
}

/// WorkspaceModel.noteOpened.
pub(crate) fn note_opened(recent: &mut Vec<String>, id: &str) -> bool {
    if recent.first().is_some_and(|first| first == id) {
        return false;
    }
    recent.retain(|recent| recent != id);
    recent.insert(0, id.to_owned());
    recent.truncate(RECENTLY_OPENED_LIMIT);
    true
}
/// WorkspaceModel.adoptRecentChats: chats that still exist, once each.
pub(crate) fn adopt_recent(ids: Vec<String>, records: &[ChatRecord]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    ids.into_iter()
        .filter(|id| records.iter().any(|record| &record.id == id) && seen.insert(id.clone()))
        .take(RECENTLY_OPENED_LIMIT)
        .collect()
}

/// The remembered order of opening (Swift keeps it with the selection,
/// `RememberedSelection.recentChats`). Newer writes supersede older ones.
pub(crate) struct RecentStore {
    path: PathBuf,
    latest: AtomicU64,
    write: Mutex<()>,
}
impl RecentStore {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            latest: AtomicU64::new(0),
            write: Mutex::new(()),
        }
    }
    pub(crate) fn load(&self) -> Vec<String> {
        std::fs::metadata(&self.path)
            .ok()
            .filter(|meta| meta.is_file() && meta.len() <= 64 * 1024)
            .and_then(|_| std::fs::read(&self.path).ok())
            .and_then(|bytes| serde_json::from_slice::<Vec<String>>(&bytes).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|id| uuid::Uuid::parse_str(id).is_ok())
            .collect()
    }
    pub(crate) fn reserve(&self) -> u64 {
        self.latest.fetch_add(1, Ordering::AcqRel) + 1
    }
    pub(crate) fn save(&self, revision: u64, ids: &[String]) -> std::io::Result<bool> {
        use std::io::Write;
        let _guard = self
            .write
            .lock()
            .map_err(|_| std::io::Error::other("Recent chats storage lock failed"))?;
        if self.latest.load(Ordering::Acquire) != revision {
            return Ok(false);
        }
        let parent = self
            .path
            .parent()
            .ok_or_else(|| std::io::Error::other("Recent chats storage has no parent"))?;
        let tmp = parent.join(format!(".recent-chats-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&tmp)?;
            file.write_all(&serde_json::to_vec(ids)?)?;
            file.sync_all()?;
            std::fs::rename(&tmp, &self.path)?;
            Ok(true)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(tmp);
        }
        result
    }
}

/// SessionReference.text, for a chat this build keeps no request
/// accounting for: its usage reads as Swift's does with none retained.
pub(crate) fn session_reference(
    record: &ChatRecord,
    title: &str,
    project_id: Option<&str>,
    project: &Path,
    saved: bool,
) -> String {
    let mut lines = vec![
        "Bello Agent session".to_owned(),
        format!("App session ID: {}", record.id),
        format!("Title: {title}"),
        match project_id {
            Some(id) => format!("Project ID: {id}"),
            None => format!("Project folder: {}", project.display()),
        },
        "Gateway-reported usage (retained requests): 0 requests".to_owned(),
    ];
    for label in [
        "Total tokens (input + output)",
        "Input tokens (includes cache)",
        "Output tokens (includes reasoning)",
        "Cached input tokens",
        "Cache-write input tokens",
        "Reasoning tokens (part of output)",
        "Reported cost",
        "Reasoning cost (part of reported cost)",
    ] {
        lines.push(format!("{label}: not reported"));
    }
    lines.push("Usage is a snapshot of this session's own retained requests; inherited conversation history and unreported in-flight usage are not added.".into());
    lines.push(String::new());
    if saved {
        let path = record.snapshot.display().to_string();
        lines.extend([
            format!("Conversation file (JSON): {path}"),
            String::new(),
            "Read with Bash:".into(),
            format!("cat -- '{}'", path.replace('\'', "'\"'\"'")),
            String::new(),
            "The saved JSON checkpoint includes messages, tool results and compaction metadata, not just the current model context. Live streaming output appears after it is saved; unsaved drafts are not included. Read the file without modifying it.".into(),
        ]);
    } else {
        lines.push(
            "Conversation file: not created yet. This session has no saved journal to inspect."
                .into(),
        );
    }
    lines.join("\n")
}

impl AgentView {
    // MARK: Menu

    /// The right-click menu for `id`: the marked rows' menu when it is one of
    /// several marked rows, else the chat's own.
    pub(crate) fn sidebar_menu_entries(&self, id: &str, cx: &App) -> Vec<SidebarMenuEntry> {
        if self.sidebar_chats.has_marked_sessions() && self.sidebar_chats.is_marked(id) {
            let marked = self.marked_chats(cx);
            return marked_menu_entries(&MarkedMenuFacts {
                count: marked.len(),
                archived: marked
                    .iter()
                    .filter(|record| record.archived_at.is_some())
                    .count(),
                unread: marked
                    .iter()
                    .filter(|record| self.can_read_action(&record.id, false))
                    .count(),
                read: marked
                    .iter()
                    .filter(|record| self.can_read_action(&record.id, true))
                    .count(),
            });
        }
        let record = self.records.iter().find(|record| record.id == id);
        let offers_read = self.can_read_action(id, false);
        chat_menu_entries(&ChatMenuFacts {
            pinned: record.is_some_and(|record| record.pinned_at.is_some()),
            archived: record.is_some_and(|record| record.archived_at.is_some()),
            renamable: self.rename_refusal(id).is_none(),
            offers_read,
            can_unread: !offers_read && self.can_read_action(id, true),
        })
    }
    /// The marked rows' commands, each through its single-chat path.
    pub(crate) fn run_marked_action(&mut self, action: SidebarAction, cx: &mut Context<Self>) {
        let ids: Vec<String> = self
            .marked_chats(cx)
            .into_iter()
            .map(|record| record.id)
            .collect();
        match action {
            // Copying keeps the marks.
            SidebarAction::CopyMarkedReferences => self.copy_session_references(ids, cx),
            SidebarAction::ArchiveMarked | SidebarAction::RestoreMarked => {
                self.clear_session_marks();
                let archived = action == SidebarAction::ArchiveMarked;
                for id in ids {
                    if self.chat_is_archived(&id) != archived {
                        self.set_chat_archived(&id, archived, cx);
                    }
                }
            }
            SidebarAction::PinMarked | SidebarAction::UnpinMarked => {
                self.clear_session_marks();
                let pinned = action == SidebarAction::PinMarked;
                for id in ids {
                    let current = self
                        .records
                        .iter()
                        .find(|record| record.id == id)
                        .map(|record| record.pinned_at.is_some());
                    if current.is_some_and(|current| current != pinned) {
                        self.set_chat_pinned(&id, pinned, cx);
                    }
                }
            }
            SidebarAction::MarkMarkedRead | SidebarAction::MarkMarkedUnread => {
                self.clear_session_marks();
                let unread = action == SidebarAction::MarkMarkedUnread;
                // Decide every chat first, and hold the shared flush until the
                // whole batch is applied: a flush holding the catalog would
                // make later eligibility checks read as refusals.
                let eligible: Vec<String> = ids
                    .into_iter()
                    .filter(|id| self.can_read_action(id, unread))
                    .collect();
                let hold_flush = !self.read_write_inflight;
                if hold_flush {
                    self.read_write_inflight = true;
                }
                for id in eligible {
                    self.mark_chat_read_state(&id, unread, cx);
                }
                if hold_flush {
                    self.read_write_inflight = false;
                    self.flush_read_states(cx);
                }
            }
            SidebarAction::ClearMarks => self.clear_session_marks(),
            _ => {}
        }
        cx.notify();
    }

    // MARK: Marks

    /// The sidebar's listed order, the order a Shift-click range follows.
    fn sidebar_chat_order(&self, cx: &App) -> Vec<String> {
        self.visible_sidebar_records(cx)
            .into_iter()
            .map(|record| record.id.clone())
            .collect()
    }
    /// Marked chats in sidebar order; rows not listed sort after, by ID.
    pub(crate) fn marked_chats(&self, cx: &App) -> Vec<ChatRecord> {
        if self.sidebar_chats.marks.is_empty() {
            return Vec::new();
        }
        let rank: BTreeMap<String, usize> = self
            .sidebar_chat_order(cx)
            .into_iter()
            .enumerate()
            .map(|(index, id)| (id, index))
            .collect();
        let mut marked: Vec<ChatRecord> = self
            .records
            .iter()
            .filter(|record| self.sidebar_chats.marks.contains(&record.id))
            .cloned()
            .collect();
        marked.sort_by(|a, b| {
            (rank.get(&a.id).unwrap_or(&usize::MAX), &a.id)
                .cmp(&(rank.get(&b.id).unwrap_or(&usize::MAX), &b.id))
        });
        marked
    }
    /// Command-click. The first one extends the row that is already open.
    pub(crate) fn toggle_session_mark(&mut self, id: &str) {
        if !self.records.iter().any(|record| record.id == id) {
            return;
        }
        let mut marks = if self.sidebar_chats.marks.is_empty() {
            BTreeSet::from([self.record.id.clone()])
        } else {
            self.sidebar_chats.marks.clone()
        };
        let mut anchor = self.sidebar_chats.mark_anchor.clone();
        if !marks.remove(id) && marks.len() < MARKED_SESSION_LIMIT {
            marks.insert(id.to_owned());
            anchor = Some(id.to_owned());
        }
        self.apply_marks(marks, anchor);
    }
    /// Shift-click: every row between the anchor and this one, as listed.
    pub(crate) fn extend_session_marks(&mut self, id: &str, cx: &App) {
        if !self.records.iter().any(|record| record.id == id) {
            return;
        }
        let order = self.sidebar_chat_order(cx);
        let anchor = self
            .sidebar_chats
            .mark_anchor
            .clone()
            .unwrap_or_else(|| self.record.id.clone());
        let range = (anchor != id)
            .then(|| {
                let from = order.iter().position(|row| *row == anchor)?;
                let to = order.iter().position(|row| row == id)?;
                Some(order[from.min(to)..=from.max(to)].to_vec())
            })
            .flatten();
        match range {
            Some(range) => {
                // The anchor stays put, so the next Shift-click re-measures
                // from the same row instead of growing the last range.
                let marks = range.into_iter().take(MARKED_SESSION_LIMIT).collect();
                self.apply_marks(marks, Some(anchor));
            }
            None => {
                // No anchor in the listed order: mark this row beside the open chat.
                let mut marks = self.sidebar_chats.marks.clone();
                marks.insert(id.to_owned());
                marks.insert(self.record.id.clone());
                self.apply_marks(marks, Some(id.to_owned()));
            }
        }
    }
    pub(crate) fn clear_session_marks(&mut self) {
        self.sidebar_chats.marks.clear();
        self.sidebar_chats.mark_anchor = None;
    }
    fn apply_marks(&mut self, marks: BTreeSet<String>, anchor: Option<String>) {
        let valid: BTreeSet<String> = marks
            .into_iter()
            .filter(|id| self.records.iter().any(|record| &record.id == id))
            .collect();
        let chats = &mut self.sidebar_chats;
        if let Some(anchor) = anchor.filter(|anchor| valid.is_empty() || valid.contains(anchor)) {
            chats.mark_anchor = Some(anchor);
        } else if chats
            .mark_anchor
            .as_ref()
            .is_none_or(|anchor| !valid.contains(anchor))
        {
            chats.mark_anchor = valid.iter().next().cloned();
        }
        // One mark on the chat that is already open is an ordinary selection.
        chats.marks = if valid.len() == 1 && valid.contains(&self.chat.record.id) {
            BTreeSet::new()
        } else {
            valid
        };
    }

    // MARK: Rows

    /// SidebarRowClick: Shift extends the marks, Command adds or removes one
    /// row, a double click renames, and an ordinary click drops the marks and
    /// opens. Returns true when the click was taken here.
    pub(crate) fn sidebar_row_clicked(
        &mut self,
        id: &str,
        event: &ClickEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let modifiers = event.modifiers();
        if modifiers.shift {
            self.extend_session_marks(id, cx);
            cx.notify();
            return true;
        }
        // Command on macOS, Control elsewhere.
        if modifiers.secondary() {
            self.toggle_session_mark(id);
            cx.notify();
            return true;
        }
        self.clear_session_marks();
        if event.click_count() == 2 {
            self.open_rename_sheet(id, window, cx);
            return true;
        }
        false
    }
    /// The row's fill and outline: the open row's wash is drawn by the
    /// caller; a marked row gets the quiet fill and an accent outline; a row
    /// opened recently keeps a fainter wash (PiKit.SelectableRow.styleFace).
    pub(crate) fn decorate_sidebar_row(
        &self,
        id: &str,
        selected: bool,
        row: Stateful<Div>,
    ) -> Stateful<Div> {
        let p = self.palette;
        if selected {
            return row;
        }
        if self.sidebar_chats.is_marked(id) {
            let mut outline: Hsla = rgb(p.accent).into();
            outline.a *= 0.55;
            return row.bg(p.fill()).border_1().border_color(outline);
        }
        let tint = recency_tint(self.sidebar_recency_rank(id));
        if tint > 0. {
            let mut wash = p.accent_soft();
            wash.a *= tint.min(1.);
            return row.bg(wash);
        }
        row
    }
    /// The chat's place by order of opening among the chats still listed.
    pub(crate) fn sidebar_recency_rank(&self, id: &str) -> Option<usize> {
        self.sidebar_chats.recency_rank(id)
    }
    /// WorkspaceModel.showsDraftMark: a saved draft holds unsent work, and the
    /// chat is not one that exists only on screen.
    pub(crate) fn shows_draft_mark(&self, id: &str) -> bool {
        self.sidebar_chats.has_draft_mark(id)
            && self.records.iter().any(|record| record.id == id)
            && self.chat_ref(id).is_none_or(|chat| !chat.pending)
    }
    /// One confirmed draft write (WorkspaceDraftMarks.applyDraftMark).
    pub(crate) fn note_draft_mark(&mut self, id: &str, holds: bool) {
        if holds {
            self.sidebar_chats.draft_marks.insert(id.to_owned());
        } else {
            self.sidebar_chats.draft_marks.remove(id);
        }
    }
    /// The reader came to the selected chat (or navigation brought it).
    pub(crate) fn note_chat_opened(&mut self, cx: &mut Context<Self>) {
        let id = self.chat.record.id.clone();
        let before = self.sidebar_chats.recent.clone();
        note_opened(&mut self.sidebar_chats.recent, &id);
        // A chat that existed only on screen and is gone holds no place.
        let records = &self.records;
        self.sidebar_chats
            .recent
            .retain(|recent| records.iter().any(|record| &record.id == recent));
        if self.sidebar_chats.recent == before {
            return;
        }
        let Some(store) = self.sidebar_chats.recent_store.clone() else {
            return;
        };
        // Only chats a relaunch can list are remembered.
        let durable: Vec<String> = self
            .sidebar_chats
            .recent
            .iter()
            .filter(|id| {
                self.records.iter().any(|record| &record.id == *id)
                    && self.chat_ref(id).is_none_or(|chat| !chat.pending)
            })
            .cloned()
            .collect();
        let revision = store.reserve();
        cx.background_executor()
            .spawn(async move {
                // Best effort: losing the order costs only the wash.
                let _ = store.save(revision, &durable);
            })
            .detach();
    }

    // MARK: Session references

    /// WorkspaceContent.copySessionReferences: one reference, or several under
    /// a heading, written once the catalog's project identity is read.
    pub(crate) fn copy_session_references(&mut self, ids: Vec<String>, cx: &mut Context<Self>) {
        self.sidebar_chats.copy_revision = self.sidebar_chats.copy_revision.wrapping_add(1);
        let revision = self.sidebar_chats.copy_revision;
        let mut seen = BTreeSet::new();
        let ids: Vec<String> = ids
            .into_iter()
            .filter(|id| seen.insert(id.clone()))
            .collect();
        if ids.is_empty() || ids.len() > MARKED_SESSION_LIMIT {
            self.error = Some("Select chats to copy their references.".into());
            cx.notify();
            return;
        }
        if !ids
            .iter()
            .all(|id| self.records.iter().any(|record| &record.id == id))
        {
            self.error = Some("A selected chat is no longer available to copy.".into());
            cx.notify();
            return;
        }
        let workspace = self.workspace.clone();
        let task = cx.background_executor().spawn(async move {
            crate::chat_organization::catalog_operation(&workspace, |store| {
                Ok(store.project_id().map(str::to_owned))
            })
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.sidebar_chats.copy_revision != revision || view.shutting_down {
                    return;
                }
                let project_id = match outcome.display_result() {
                    Ok(project_id) => project_id,
                    Err(error) => {
                        view.error = Some(format!(
                            "Session usage could not be read for copying. {error}"
                        ));
                        cx.notify();
                        return;
                    }
                };
                let mut references = Vec::new();
                for id in &ids {
                    let Some(record) = view.records.iter().find(|record| &record.id == id) else {
                        view.error = Some("A selected chat is no longer available to copy.".into());
                        cx.notify();
                        return;
                    };
                    let saved = record.materialization != ChatMaterialization::Pending
                        && view.chat_ref(id).is_none_or(|chat| !chat.pending);
                    references.push(session_reference(
                        record,
                        view.sidebar_title(record),
                        project_id.as_deref(),
                        &view.project,
                        saved,
                    ));
                }
                let heading = if references.len() > 1 {
                    format!("Bello Agent session references ({})\n\n", references.len())
                } else {
                    String::new()
                };
                cx.write_to_clipboard(ClipboardItem::new_string(
                    heading + &references.join("\n\n---\n\n"),
                ));
            });
        })
        .detach();
    }

    // MARK: Sheets

    pub(crate) fn sidebar_chats_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.sidebar_chats.delete.is_some() {
            self.delete_question_key(event, window, cx);
        } else if self.sidebar_chats.rename.is_some() {
            self.rename_sheet_key(event, window, cx);
        }
    }
    pub(crate) fn sidebar_chats_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if let Some(element) = self.delete_question_element(window, cx) {
            return Some(element);
        }
        self.rename_sheet_element(window, cx)
    }
}

#[cfg(test)]
#[path = "sidebar_chats_tests.rs"]
pub(crate) mod tests;
