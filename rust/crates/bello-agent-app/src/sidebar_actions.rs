//! Source sidebar organization and reference actions; neither owns navigation.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::workspace::ChatRecord;
use gpui::{prelude::*, *};
use std::path::PathBuf;

pub(crate) enum SidebarEntry<'a> {
    Root,
    Topic(&'a bello_agent_core::workspace::TopicRecord),
    Chat(&'a ChatRecord),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SidebarAction {
    Rename,
    TogglePinned,
    ToggleArchived,
    Delete,
    CopySessionId,
    CopySessionReference,
    MarkRead,
    MarkUnread,
    CopyMarkedReferences,
    ArchiveMarked,
    RestoreMarked,
    PinMarked,
    UnpinMarked,
    MarkMarkedRead,
    MarkMarkedUnread,
    ClearMarks,
}

/// One command of a chat row's right-click menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SidebarMenuItem {
    pub action: SidebarAction,
    pub title: String,
    /// The SF Symbol the native menu shows, as SessionOrganizationActions names it.
    pub symbol: Option<&'static str>,
    /// The bundled icon the drawn (non-macOS) menu shows.
    pub icon: Option<&'static str>,
    pub enabled: bool,
}
/// PiMenuEntry: a command, an informative note or a divider.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SidebarMenuEntry {
    Item(SidebarMenuItem),
    Note(String),
    Separator,
}
fn item(
    action: SidebarAction,
    title: impl Into<String>,
    symbol: Option<&'static str>,
    icon: Option<&'static str>,
    enabled: bool,
) -> SidebarMenuEntry {
    SidebarMenuEntry::Item(SidebarMenuItem {
        action,
        title: title.into(),
        symbol,
        icon,
        enabled,
    })
}

/// What one chat's menu branches on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ChatMenuFacts {
    pub pinned: bool,
    pub archived: bool,
    /// Rename… applies: the chat has a saved checkpoint and is not loading.
    pub renamable: bool,
    /// SidebarChatRowState.offersMarkAsRead.
    pub offers_read: bool,
    /// WorkspaceModel.canMarkSessionUnread.
    pub can_unread: bool,
}

/// SidebarChatRowView.entries: SessionOrganizationActions, then
/// SessionReferenceActions, then Mark as Read or Mark as Unread. (Move to
/// Topic stays on the row's own Move button in this build.)
pub(crate) fn chat_menu_entries(facts: &ChatMenuFacts) -> Vec<SidebarMenuEntry> {
    let mut entries = vec![
        item(
            SidebarAction::Rename,
            "Rename…",
            None,
            Some("pencil"),
            facts.renamable,
        ),
        if facts.pinned {
            item(
                SidebarAction::TogglePinned,
                "Unpin Chat",
                Some("pin.slash"),
                Some("unpin"),
                true,
            )
        } else {
            item(
                SidebarAction::TogglePinned,
                "Pin Chat",
                Some("pin"),
                Some("pin"),
                true,
            )
        },
        if facts.archived {
            item(
                SidebarAction::ToggleArchived,
                "Restore Chat",
                Some("arrow.uturn.backward"),
                Some("restore"),
                true,
            )
        } else {
            item(
                SidebarAction::ToggleArchived,
                "Archive Chat",
                Some("archivebox"),
                Some("archive"),
                true,
            )
        },
    ];
    if facts.archived {
        entries.push(SidebarMenuEntry::Separator);
        entries.push(item(
            SidebarAction::Delete,
            "Delete Chat…",
            Some("trash"),
            Some("trash"),
            true,
        ));
    }
    entries.push(SidebarMenuEntry::Separator);
    entries.push(item(
        SidebarAction::CopySessionId,
        "Copy Session ID",
        Some("number"),
        Some("number"),
        true,
    ));
    entries.push(item(
        SidebarAction::CopySessionReference,
        "Copy Session Reference",
        Some("doc.on.doc"),
        Some("doc.on.doc"),
        true,
    ));
    if facts.offers_read {
        entries.push(SidebarMenuEntry::Separator);
        entries.push(item(
            SidebarAction::MarkRead,
            "Mark as Read",
            None,
            Some("checkmark"),
            true,
        ));
    } else if facts.can_unread {
        entries.push(SidebarMenuEntry::Separator);
        entries.push(item(
            SidebarAction::MarkUnread,
            "Mark as Unread",
            None,
            Some("circle"),
            true,
        ));
    }
    entries
}

/// What the marked rows' menu counts (MarkedSessionActions).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct MarkedMenuFacts {
    pub count: usize,
    pub archived: usize,
    pub unread: usize,
    pub read: usize,
}

/// MarkedSessionActions.entries, without its Move to Topic submenu.
pub(crate) fn marked_menu_entries(facts: &MarkedMenuFacts) -> Vec<SidebarMenuEntry> {
    let mut entries = vec![
        SidebarMenuEntry::Note(format!("{} chats selected", facts.count)),
        SidebarMenuEntry::Separator,
        item(
            SidebarAction::CopyMarkedReferences,
            "Copy Session References",
            Some("doc.on.doc"),
            Some("doc.on.doc"),
            true,
        ),
        SidebarMenuEntry::Separator,
    ];
    if facts.archived < facts.count {
        entries.push(item(
            SidebarAction::ArchiveMarked,
            format!("Archive {} Chats", facts.count - facts.archived),
            Some("archivebox"),
            Some("archive"),
            true,
        ));
    }
    if facts.archived > 0 {
        entries.push(item(
            SidebarAction::RestoreMarked,
            format!("Restore {} Chats", facts.archived),
            Some("arrow.uturn.backward"),
            Some("restore"),
            true,
        ));
    }
    entries.push(item(
        SidebarAction::PinMarked,
        "Pin All",
        Some("pin"),
        Some("pin"),
        true,
    ));
    entries.push(item(
        SidebarAction::UnpinMarked,
        "Unpin All",
        Some("pin.slash"),
        Some("unpin"),
        true,
    ));
    if facts.unread > 0 || facts.read > 0 {
        entries.push(SidebarMenuEntry::Separator);
    }
    if facts.unread > 0 {
        entries.push(item(
            SidebarAction::MarkMarkedRead,
            format!("Mark {} as Read", facts.unread),
            None,
            Some("checkmark"),
            true,
        ));
    }
    if facts.read > 0 {
        entries.push(item(
            SidebarAction::MarkMarkedUnread,
            format!("Mark {} as Unread", facts.read),
            None,
            Some("circle"),
            true,
        ));
    }
    entries.push(SidebarMenuEntry::Separator);
    entries.push(item(
        SidebarAction::ClearMarks,
        "Clear Selection",
        Some("xmark.circle"),
        Some("close"),
        true,
    ));
    entries
}

/// The commands keyboard selection moves between, in menu order.
pub(crate) fn menu_actions(entries: &[SidebarMenuEntry]) -> Vec<SidebarAction> {
    entries
        .iter()
        .filter_map(|entry| match entry {
            SidebarMenuEntry::Item(item) => Some(item.action),
            _ => None,
        })
        .collect()
}

#[derive(Clone)]
pub(crate) struct SidebarMenu {
    pub(super) token: uuid::Uuid,
    chat_id: String,
    snapshot: PathBuf,
    project: PathBuf,
    binding: Option<WindowBinding>,
    entries: Vec<SidebarMenuEntry>,
    selected: SidebarAction,
    #[cfg(not(target_os = "macos"))]
    position: Point<Pixels>,
    #[cfg(not(target_os = "macos"))]
    previous_focus: Option<FocusHandle>,
    #[cfg(not(target_os = "macos"))]
    focus_record_id: String,
    #[cfg(not(target_os = "macos"))]
    popup_window: Option<AnyWindowHandle>,
    #[cfg(not(target_os = "macos"))]
    focus_route: (u64, bool, Option<u64>, bool),
}
impl AgentView {
    pub(super) fn sidebar_title<'a>(&'a self, record: &'a ChatRecord) -> &'a str {
        self.chat_ref(&record.id)
            .map(|chat| {
                if chat.loading || chat.load_failed {
                    chat.record.title.as_str()
                } else {
                    chat.session.title.as_str()
                }
            })
            .unwrap_or(record.title.as_str())
    }

    // Rendering and keyboard traversal must share the currently visible order.
    pub(super) fn visible_sidebar_records(&self, cx: &App) -> Vec<&ChatRecord> {
        let filter = self.filter.read(cx).text().trim().to_lowercase();
        let mut records: Vec<_> = self
            .records
            .iter()
            .filter(|record| {
                (!filter.is_empty()
                    || self.effective_topic_id(record).is_none_or(|id| {
                        self.topics.iter().any(|topic| {
                            topic.id == id
                                && (topic.expanded
                                    || self.launch_topic_reveal.as_deref() == Some(id))
                        })
                    }))
                    && (record.archived_at.is_none() || self.effective_archive_visibility())
                    && (filter.is_empty()
                        || self.sidebar_title(record).to_lowercase().contains(&filter)
                        || self.sidebar_search_matches(&record.id, cx)
                        || self.effective_topic_id(record).is_some_and(|id| {
                            self.topics.iter().any(|topic| {
                                topic.id == id && topic.title.to_lowercase().contains(&filter)
                            })
                        }))
            })
            .collect();
        records.sort_by(|a, b| {
            self.topic_sort_index(a)
                .cmp(&self.topic_sort_index(b))
                .then_with(|| {
                    a.archived_at
                        .is_some()
                        .cmp(&b.archived_at.is_some())
                        .then_with(|| {
                            a.sidebar_cmp_with_activity(
                                b,
                                self.sidebar_activity_hold.key(a),
                                self.sidebar_activity_hold.key(b),
                            )
                        })
                })
        });
        records
    }

    fn topic_sort_index(&self, record: &ChatRecord) -> usize {
        self.effective_topic_id(record)
            .and_then(|id| self.topics.iter().position(|topic| topic.id == id))
            .unwrap_or(usize::MAX)
    }
    pub(super) fn sidebar_entries(&self, cx: &App) -> Vec<SidebarEntry<'_>> {
        let records = self.visible_sidebar_records(cx);
        let mut entries = Vec::new();
        let query = self.filter.read(cx).text().trim().to_lowercase();
        for topic in &self.topics {
            if !query.is_empty()
                && !topic.title.to_lowercase().contains(&query)
                && !records
                    .iter()
                    .any(|record| self.effective_topic_id(record) == Some(topic.id.as_str()))
            {
                continue;
            }
            entries.push(SidebarEntry::Topic(topic));
            entries.extend(
                records
                    .iter()
                    .filter(|record| self.effective_topic_id(record) == Some(topic.id.as_str()))
                    .map(|record| SidebarEntry::Chat(record)),
            );
        }
        let roots = records
            .iter()
            .filter(|record| self.effective_topic_id(record).is_none())
            .collect::<Vec<_>>();
        if !roots.is_empty() && !self.topics.is_empty() {
            entries.push(SidebarEntry::Root);
        }
        entries.extend(roots.into_iter().map(|record| SidebarEntry::Chat(record)));
        entries
    }

    pub(super) fn open_sidebar_menu(
        &mut self,
        id: &str,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down {
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id) else {
            return;
        };
        let entries = self.sidebar_menu_entries(id, cx);
        // A single chat's menu starts on Pin, as it always has; the marked
        // rows' menu on its first command.
        let selected = if menu_actions(&entries).contains(&SidebarAction::TogglePinned) {
            SidebarAction::TogglePinned
        } else {
            menu_actions(&entries)
                .first()
                .copied()
                .unwrap_or(SidebarAction::ClearMarks)
        };
        let menu = SidebarMenu {
            token: uuid::Uuid::new_v4(),
            chat_id: id.into(),
            snapshot: record.snapshot.clone(),
            project: self.project.clone(),
            binding: self.window_binding,
            entries,
            selected,
            #[cfg(not(target_os = "macos"))]
            position,
            #[cfg(not(target_os = "macos"))]
            previous_focus: self
                .sidebar_menu
                .as_ref()
                .and_then(|menu| menu.previous_focus.clone())
                .or_else(|| {
                    window
                        .focused(cx)
                        .filter(|focus| !focus.eq(&self.sidebar_popup_focus))
                }),
            #[cfg(not(target_os = "macos"))]
            focus_record_id: self.record.id.clone(),
            #[cfg(not(target_os = "macos"))]
            popup_window: Some(window.window_handle()),
            #[cfg(not(target_os = "macos"))]
            focus_route: (
                self.navigation_generation,
                self.show_files,
                self.selected_file,
                self.changes_open,
            ),
        };
        self.recheck_sidebar_pointer(Some(position));
        self.sidebar_activity_hold.begin_menu(menu.token);
        self.sidebar_menu = Some(menu.clone());
        #[cfg(target_os = "macos")]
        {
            let owner = cx.weak_entity();
            crate::native_menu::show_sidebar_menu(
                cx,
                window.window_handle(),
                position,
                menu.entries.clone(),
                move |choice, pointer, cx| {
                    let _ = owner.update(cx, |view, cx| {
                        if view
                            .sidebar_menu
                            .as_ref()
                            .is_some_and(|current| current.token == menu.token)
                        {
                            view.recheck_sidebar_pointer(pointer);
                            view.finish_sidebar_menu(menu.token, choice, cx);
                        }
                    });
                },
            );
        }
        #[cfg(not(target_os = "macos"))]
        self.sidebar_popup_focus.focus(window);
        cx.notify();
    }
    fn finish_sidebar_menu(
        &mut self,
        token: uuid::Uuid,
        choice: Option<SidebarAction>,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self
            .sidebar_menu
            .as_ref()
            .filter(|menu| menu.token == token)
            .cloned()
        else {
            return;
        };
        self.sidebar_activity_hold.end_menu(token);
        self.sidebar_menu = None;
        #[cfg(not(target_os = "macos"))]
        self.restore_sidebar_popup_focus(&menu, cx);
        if menu.project == self.project
            && menu.binding == self.window_binding
            && !self.shutting_down
            && let Some(action) = choice
        {
            // A missing Copy target retains its existing explanatory notice;
            // a reused ID at another path must never act on the replacement.
            if self
                .records
                .iter()
                .find(|record| record.id == menu.chat_id)
                .is_some_and(|record| record.snapshot != menu.snapshot)
            {
                cx.notify();
                return;
            }
            match action {
                SidebarAction::TogglePinned => {
                    if let Some(record) =
                        self.records.iter().find(|record| record.id == menu.chat_id)
                    {
                        self.set_chat_pinned(&menu.chat_id, record.pinned_at.is_none(), cx);
                    }
                }
                SidebarAction::ToggleArchived => {
                    if let Some(record) =
                        self.records.iter().find(|record| record.id == menu.chat_id)
                    {
                        self.set_chat_archived(&menu.chat_id, record.archived_at.is_none(), cx);
                    }
                }
                SidebarAction::CopySessionId => self.copy_sidebar_session_id(&menu.chat_id, cx),
                SidebarAction::MarkRead => self.mark_chat_read_state(&menu.chat_id, false, cx),
                SidebarAction::MarkUnread => self.mark_chat_read_state(&menu.chat_id, true, cx),
                SidebarAction::Rename => self.present_rename(&menu.chat_id, cx),
                SidebarAction::Delete => self.ask_delete_chat(&menu.chat_id, cx),
                SidebarAction::CopySessionReference => {
                    self.copy_session_references(vec![menu.chat_id.clone()], cx)
                }
                marked => self.run_marked_action(marked, cx),
            }
        }
        cx.notify();
    }
    #[cfg(not(target_os = "macos"))]
    fn restore_sidebar_popup_focus(&self, menu: &SidebarMenu, cx: &mut Context<Self>) {
        let Some(handle) = menu.popup_window else {
            return;
        };
        let menu = menu.clone();
        let owner = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = handle.update(cx, |_, window, cx| {
                let _ = owner.update(cx, |view, cx| {
                    if view.window_binding != menu.binding
                        || view.project != menu.project
                        || view.sidebar_menu.is_some()
                        || view.shutting_down
                        || view.close_dialog
                        || view.quick_open.read(cx).is_open()
                        || !view.sidebar_popup_focus.is_focused(window)
                    {
                        return;
                    }
                    // contains() sees the last rendered dispatch tree. Fresh
                    // navigation/pane state must also match, since dismissal
                    // can precede the frame that removes a now-hidden editor.
                    let route = (
                        view.navigation_generation,
                        view.show_files,
                        view.selected_file,
                        view.changes_open,
                    );
                    if view.record.id == menu.focus_record_id
                        && route == menu.focus_route
                        && let Some(previous) = &menu.previous_focus
                        && view.root_focus.contains(previous, window)
                        && !(view.chat_is_archived(&view.record.id)
                            && previous == &view.composer.read(cx).focus_handle(cx))
                    {
                        previous.focus(window);
                    } else {
                        view.root_focus.focus(window);
                    }
                });
            });
        });
    }
    pub(super) fn sidebar_menu_key(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(menu) = self.sidebar_menu.clone() else {
            return false;
        };
        match event.keystroke.key.as_str() {
            "escape" => self.finish_sidebar_menu(menu.token, None, cx),
            "enter" => {
                let enabled = menu.entries.iter().any(|entry| {
                    matches!(entry, SidebarMenuEntry::Item(item)
                        if item.action == menu.selected && item.enabled)
                });
                self.finish_sidebar_menu(menu.token, enabled.then_some(menu.selected), cx)
            }
            "up" | "down" => {
                if let Some(menu) = self.sidebar_menu.as_mut() {
                    let actions = menu_actions(&menu.entries);
                    if actions.is_empty() {
                        return true;
                    }
                    let index = actions
                        .iter()
                        .position(|action| *action == menu.selected)
                        .unwrap_or(0);
                    let next = if event.keystroke.key == "down" {
                        (index + 1).min(actions.len() - 1)
                    } else {
                        index.saturating_sub(1)
                    };
                    menu.selected = actions[next];
                }
                cx.notify();
            }
            // A context menu owns keyboard input until dismissal; do not type
            // into the still-focused composer or trigger a hidden chat action.
            _ => {}
        }
        true
    }
    fn copy_sidebar_session_id(&mut self, id: &str, cx: &mut Context<Self>) {
        // WorkspaceContent.copySessionID resolves the requested record again at
        // action time. Copying a nonselected/pending chat never selects or saves it.
        if self.records.iter().any(|record| record.id == id) {
            cx.write_to_clipboard(ClipboardItem::new_string(id.to_owned()));
        } else {
            self.error = Some("That chat is no longer available to copy.".into());
        }
    }
    pub(super) fn sidebar_menu_element(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        #[cfg(target_os = "macos")]
        {
            let _ = cx;
            None
        }
        #[cfg(not(target_os = "macos"))]
        {
            let menu = self.sidebar_menu.clone()?;
            let token = menu.token;
            let p = self.palette;
            let mut body = div()
                .id("sidebar-organization-menu")
                .track_focus(&self.sidebar_popup_focus)
                .occlude()
                .min_w(px(180.))
                .p(px(4.))
                .rounded(px(7.))
                .border_1()
                .border_color(p.hairline())
                .bg(rgb(p.surface))
                .shadow_lg()
                .on_mouse_down_out(
                    cx.listener(move |view, _, _, cx| view.finish_sidebar_menu(token, None, cx)),
                );
            for entry in &menu.entries {
                let entry = match entry {
                    SidebarMenuEntry::Separator => {
                        body = body.child(div().h(px(1.)).my(px(4.)).bg(p.hairline()));
                        continue;
                    }
                    SidebarMenuEntry::Note(note) => {
                        body = body.child(
                            div()
                                .px(px(8.))
                                .py(px(4.))
                                .text_size(px(12.))
                                .text_color(rgb(p.tertiary))
                                .child(note.clone()),
                        );
                        continue;
                    }
                    SidebarMenuEntry::Item(entry) => entry,
                };
                let action = entry.action;
                let id = menu_item_selector(action);
                let enabled = entry.enabled;
                body = body.child(
                    div()
                        .id(id)
                        .debug_selector(move || id.into())
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .px(px(8.))
                        .py(px(5.))
                        .rounded(px(4.))
                        .text_size(px(13.))
                        .text_color(rgb(p.ink))
                        .cursor_pointer()
                        .opacity(if enabled { 1. } else { 0.45 })
                        .when(menu.selected == action, |style| style.bg(p.accent_soft()))
                        .on_hover(cx.listener(move |view, hover, _, cx| {
                            if *hover
                                && let Some(menu) = view
                                    .sidebar_menu
                                    .as_mut()
                                    .filter(|menu| menu.token == token)
                            {
                                menu.selected = action;
                                cx.notify();
                            }
                        }))
                        .on_click(cx.listener(move |view, _, _, cx| {
                            if enabled {
                                view.finish_sidebar_menu(token, Some(action), cx)
                            }
                        }))
                        .when_some(entry.icon, |row, icon| row.child(self.icon(icon, 13.)))
                        .child(entry.title.clone()),
                );
            }
            Some(
                deferred(
                    anchored()
                        .position(menu.position)
                        .anchor(Corner::TopLeft)
                        .snap_to_window_with_margin(px(4.))
                        .child(body),
                )
                .with_priority(20)
                .into_any_element(),
            )
        }
    }
}

/// Stable test selectors for the drawn (non-macOS) menu's rows.
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn menu_item_selector(action: SidebarAction) -> &'static str {
    match action {
        SidebarAction::Rename => "sidebar-rename-choice",
        SidebarAction::TogglePinned => "sidebar-pin-choice",
        SidebarAction::ToggleArchived => "sidebar-archive-choice",
        SidebarAction::Delete => "sidebar-delete-choice",
        SidebarAction::CopySessionId => "sidebar-copy-id-choice",
        SidebarAction::CopySessionReference => "sidebar-copy-reference-choice",
        SidebarAction::MarkRead => "sidebar-mark-read",
        SidebarAction::MarkUnread => "sidebar-mark-unread",
        SidebarAction::CopyMarkedReferences => "sidebar-marked-copy-references",
        SidebarAction::ArchiveMarked => "sidebar-marked-archive",
        SidebarAction::RestoreMarked => "sidebar-marked-restore",
        SidebarAction::PinMarked => "sidebar-marked-pin",
        SidebarAction::UnpinMarked => "sidebar-marked-unpin",
        SidebarAction::MarkMarkedRead => "sidebar-marked-read",
        SidebarAction::MarkMarkedUnread => "sidebar-marked-unread",
        SidebarAction::ClearMarks => "sidebar-marked-clear",
    }
}

#[cfg(test)]
#[path = "sidebar_actions_tests.rs"]
mod tests;

pub(crate) struct ArchiveVisibilityHint(pub &'static str);
impl Render for ArchiveVisibilityHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .bg(rgb(0x333333))
            .text_color(rgb(0xffffff))
            .text_size(px(12.))
            .child(self.0)
    }
}
