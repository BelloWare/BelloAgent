//! Real GPUI handlers over a disposable local catalog; no provider is configured.
use super::{
    RECENTLY_OPENED_LIMIT, RecentStore, adopt_recent, note_opened, recency_tint, session_reference,
};
use crate::{
    AgentView, LaunchState,
    sidebar_actions::{SidebarAction, SidebarMenuEntry},
};
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

pub(crate) fn app_fixture(
    cx: &mut TestAppContext,
    saved: &[(&str, &str)],
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    Vec<ChatRecord>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    let mut records = Vec::new();
    for (index, (title, draft)) in saved.iter().enumerate() {
        let id = uuid::Uuid::new_v4().to_string();
        let path = workspace.chat_path(&id).unwrap();
        let mut store = SessionStore::pending_with_id(&id).unwrap();
        store.persist_to(&path).unwrap();
        store
            .transact(|session| {
                session.title = (*title).into();
                Ok(())
            })
            .unwrap();
        drop(store);
        let mut record = ChatRecord::new(id, (*title).into(), path);
        // Newest first in the sidebar: the first listed is the most recent.
        record.sidebar_order = Some(1_000 - index as u64);
        workspace
            .register(
                record.clone(),
                DraftRecord {
                    text: (*draft).into(),
                    revision: 1,
                    ..Default::default()
                },
            )
            .unwrap();
        records.push(record);
    }
    let store = SessionStore::pending();
    let launch = LaunchState {
        record: ChatRecord::new(
            store.snapshot().id,
            "New chat".into(),
            workspace.chat_path(&store.snapshot().id).unwrap(),
        ),
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(workspace)),
        project,
        draft: DraftRecord::default(),
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root, records)
}

pub(crate) fn select(window: WindowHandle<AgentView>, id: &str, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| view.select_chat(id, window, cx))
        .unwrap();
    cx.run_until_parked();
}

fn titles(entries: &[SidebarMenuEntry]) -> Vec<String> {
    entries
        .iter()
        .map(|entry| match entry {
            SidebarMenuEntry::Item(item) => item.title.clone(),
            SidebarMenuEntry::Note(note) => format!("({note})"),
            SidebarMenuEntry::Separator => "-".into(),
        })
        .collect()
}

#[test]
fn recency_keeps_the_order_of_opening_and_swifts_ladder() {
    let mut recent = Vec::new();
    for id in ["a", "b", "c", "b"] {
        note_opened(&mut recent, id);
    }
    assert_eq!(recent, ["b", "c", "a"]);
    assert!(!note_opened(&mut recent, "b"));
    for index in 0..20 {
        note_opened(&mut recent, &format!("x{index}"));
    }
    assert_eq!(recent.len(), RECENTLY_OPENED_LIMIT);
    assert_eq!(recent[0], "x19");
    assert_eq!(
        (0..6)
            .map(|rank| recency_tint(Some(rank)))
            .collect::<Vec<_>>(),
        [1., 0.75, 0.5, 0.3, 0.15, 0.]
    );
    assert_eq!(recency_tint(None), 0.);
}

#[test]
fn remembered_order_round_trips_and_a_newer_write_wins() {
    let dir = tempfile::tempdir().unwrap();
    let store = RecentStore::new(dir.path().join("recent-chats.json"));
    let ids: Vec<String> = (0..3).map(|_| uuid::Uuid::new_v4().to_string()).collect();
    let stale = store.reserve();
    let current = store.reserve();
    assert!(!store.save(stale, &ids[..1]).unwrap());
    assert!(store.save(current, &ids).unwrap());
    assert_eq!(store.load(), ids);
    let records: Vec<ChatRecord> = ids[1..]
        .iter()
        .map(|id| ChatRecord::new(id.clone(), "Chat".into(), dir.path().join("x.json")))
        .collect();
    // Chats that no longer exist hold no place after a relaunch.
    assert_eq!(adopt_recent(store.load(), &records), ids[1..].to_vec());
    std::fs::write(dir.path().join("recent-chats.json"), b"[\"not-an-id\"]").unwrap();
    assert!(store.load().is_empty());
}

#[test]
fn session_reference_has_swifts_lines_for_a_saved_and_an_unsaved_chat() {
    let record = ChatRecord::new(
        "5c1b0c56-6a73-4a9d-9a7e-2a3a7c3a0c11".into(),
        "Ignored".into(),
        "/tmp/it's here.json".into(),
    );
    let text = session_reference(
        &record,
        "Plan",
        Some("PROJECT"),
        Path::new("/project"),
        true,
    );
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(
        &lines[..5],
        [
            "Bello Agent session",
            "App session ID: 5c1b0c56-6a73-4a9d-9a7e-2a3a7c3a0c11",
            "Title: Plan",
            "Project ID: PROJECT",
            "Gateway-reported usage (retained requests): 0 requests",
        ]
    );
    assert!(lines.contains(&"Reported cost: not reported"));
    assert!(lines.contains(&"cat -- '/tmp/it'\"'\"'s here.json'"));
    let unsaved = session_reference(&record, "Plan", None, Path::new("/project"), false);
    assert!(unsaved.contains("Project folder: /project"));
    assert!(unsaved.ends_with(
        "Conversation file: not created yet. This session has no saved journal to inspect."
    ));
}

#[gpui::test]
fn marks_follow_swift_clicks_and_bulk_menu_counts(cx: &mut TestAppContext) {
    let (_dir, window, _root, chats) =
        app_fixture(cx, &[("One", ""), ("Two", ""), ("Three", ""), ("Four", "")]);
    select(window, &chats[0].id, cx);
    window
        .update(cx, |view, _, cx| {
            // The first Command-click extends the open row.
            view.toggle_session_mark(&chats[1].id);
            assert!(view.sidebar_chats.has_marked_sessions());
            assert!(view.sidebar_chats.is_marked(&chats[0].id));
            // Shift extends from the anchor (the last Command-clicked row).
            view.extend_session_marks(&chats[3].id, cx);
            let marked: Vec<_> = view.marked_chats(cx).into_iter().map(|r| r.id).collect();
            assert_eq!(
                marked,
                [
                    chats[1].id.clone(),
                    chats[2].id.clone(),
                    chats[3].id.clone()
                ]
            );
            view.toggle_session_mark(&chats[0].id);
            assert_eq!(view.marked_chats(cx).len(), 4);
            assert_eq!(
                titles(&view.sidebar_menu_entries(&chats[2].id, cx)),
                [
                    "(4 chats selected)",
                    "-",
                    "Copy Session References",
                    "-",
                    "Archive 4 Chats",
                    "Pin All",
                    "Unpin All",
                    "-",
                    "Mark 4 as Unread",
                    "-",
                    "Clear Selection",
                ]
            );
            view.run_marked_action(SidebarAction::ClearMarks, cx);
            assert!(!view.sidebar_chats.has_marked_sessions());
            // One mark on the open chat is an ordinary selection.
            view.toggle_session_mark(&chats[1].id);
            view.toggle_session_mark(&chats[1].id);
            assert!(!view.sidebar_chats.is_marked(&chats[0].id));
        })
        .unwrap();
}

#[gpui::test]
fn bulk_archive_and_restore_run_each_chats_own_path(cx: &mut TestAppContext) {
    let (dir, window, root, chats) =
        app_fixture(cx, &[("One", ""), ("Two", ""), ("Three", ""), ("Four", "")]);
    select(window, &chats[0].id, cx);
    window
        .update(cx, |view, _, cx| {
            view.toggle_session_mark(&chats[1].id);
            view.toggle_session_mark(&chats[2].id);
            view.run_marked_action(SidebarAction::ArchiveMarked, cx);
            assert!(!view.sidebar_chats.has_marked_sessions());
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        for chat in &chats[..3] {
            assert!(view.chat_is_archived(&chat.id), "{}", chat.title);
        }
        assert!(!view.chat_is_archived(&chats[3].id));
        // The open chat was archived: the reader lands on one still active,
        // never on another chat of the same batch.
        assert_eq!(view.record.id, chats[3].id);
    });
    window
        .update(cx, |view, _, cx| {
            view.toggle_session_mark(&chats[0].id);
            view.toggle_session_mark(&chats[1].id);
            assert_eq!(
                titles(&view.sidebar_menu_entries(&chats[1].id, cx))[4..6],
                ["Archive 1 Chats", "Restore 2 Chats"]
            );
            view.run_marked_action(SidebarAction::RestoreMarked, cx);
        })
        .unwrap();
    cx.run_until_parked();
    let saved: bello_agent_core::workspace::WorkspaceSnapshot =
        serde_json::from_slice(&std::fs::read(dir.path().join("workspace.json")).unwrap()).unwrap();
    let archived = |id: &str| {
        saved
            .chats
            .iter()
            .find(|chat| chat.id == id)
            .unwrap()
            .archived_at
            .is_some()
    };
    assert!(!archived(&chats[0].id) && !archived(&chats[1].id));
    assert!(archived(&chats[2].id) && !archived(&chats[3].id));
}

#[gpui::test]
fn chat_menu_matches_swifts_order_for_active_and_archived_chats(cx: &mut TestAppContext) {
    let (_dir, window, _root, chats) = app_fixture(cx, &[("One", ""), ("Two", "")]);
    window
        .update(cx, |view, _, cx| {
            assert_eq!(
                titles(&view.sidebar_menu_entries(&chats[1].id, cx)),
                [
                    "Rename…",
                    "Pin Chat",
                    "Archive Chat",
                    "-",
                    "Copy Session ID",
                    "Copy Session Reference",
                    "-",
                    "Mark as Unread",
                ]
            );
            let record = view
                .records
                .iter_mut()
                .find(|r| r.id == chats[0].id)
                .unwrap();
            record.archived_at = Some(1);
            record.pinned_at = Some(1);
            assert_eq!(
                titles(&view.sidebar_menu_entries(&chats[0].id, cx)),
                [
                    "Rename…",
                    "Unpin Chat",
                    "Restore Chat",
                    "-",
                    "Delete Chat…",
                    "-",
                    "Copy Session ID",
                    "Copy Session Reference",
                ]
            );
            // The new chat that exists only on screen has no title to rename.
            let pending = view.record.id.clone();
            let entries = view.sidebar_menu_entries(&pending, cx);
            assert!(matches!(&entries[0], SidebarMenuEntry::Item(item)
                if item.action == SidebarAction::Rename && !item.enabled));
        })
        .unwrap();
}

#[gpui::test]
fn recency_wash_follows_openings_and_forgets_dropped_chats(cx: &mut TestAppContext) {
    let (_dir, window, root, chats) = app_fixture(cx, &[("One", ""), ("Two", ""), ("Three", "")]);
    let launch = cx.read(|cx| root.read(cx).record.id.clone());
    for chat in chats.iter().rev() {
        select(window, &chat.id, cx);
    }
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.sidebar_recency_rank(&chats[0].id), Some(0));
        assert_eq!(view.sidebar_recency_rank(&chats[1].id), Some(1));
        assert_eq!(view.sidebar_recency_rank(&chats[2].id), Some(2));
        // The empty new chat left the sidebar when the reader moved on.
        assert_eq!(view.sidebar_recency_rank(&launch), None);
    });
}

#[gpui::test]
fn draft_marker_follows_saved_drafts_not_keystrokes(cx: &mut TestAppContext) {
    let (_dir, window, root, chats) =
        app_fixture(cx, &[("Drafted", "half a thought"), ("Empty", "")]);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.shows_draft_mark(&chats[0].id));
        assert!(!view.shows_draft_mark(&chats[1].id));
    });
    select(window, &chats[1].id, cx);
    window
        .update(cx, |view, _, cx| {
            view.composer
                .update(cx, |editor, cx| editor.set_text("new words".into(), cx));
            let id = view.record.id.clone();
            view.draft_changed(&id, cx);
            // Typing alone does not mark the row; the saved write does.
            assert!(!view.shows_draft_mark(&id));
        })
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).shows_draft_mark(&chats[1].id)));
    window
        .update(cx, |view, _, cx| {
            view.composer
                .update(cx, |editor, cx| editor.set_text("  ".into(), cx));
            let id = view.record.id.clone();
            view.draft_changed(&id, cx);
        })
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    cx.run_until_parked();
    assert!(!cx.read(|cx| root.read(cx).shows_draft_mark(&chats[1].id)));
}

#[gpui::test]
fn copy_session_references_write_one_or_a_headed_list(cx: &mut TestAppContext) {
    let (_dir, window, _root, chats) = app_fixture(cx, &[("One", ""), ("Two", "")]);
    window
        .update(cx, |view, _, cx| {
            view.copy_session_references(vec![chats[0].id.clone()], cx)
        })
        .unwrap();
    cx.run_until_parked();
    let text = cx.read(|cx| cx.read_from_clipboard().unwrap().text().unwrap());
    assert!(text.starts_with(&format!(
        "Bello Agent session\nApp session ID: {}\nTitle: One\n",
        chats[0].id
    )));
    assert!(text.contains(&format!(
        "Conversation file (JSON): {}",
        chats[0].snapshot.display()
    )));
    window
        .update(cx, |view, _, cx| {
            view.copy_session_references(
                vec![
                    chats[1].id.clone(),
                    chats[0].id.clone(),
                    chats[1].id.clone(),
                ],
                cx,
            )
        })
        .unwrap();
    cx.run_until_parked();
    let text = cx.read(|cx| cx.read_from_clipboard().unwrap().text().unwrap());
    assert!(text.starts_with("Bello Agent session references (2)\n\nBello Agent session\n"));
    assert_eq!(text.matches("\n\n---\n\n").count(), 1);
    assert!(text.find("Title: Two").unwrap() < text.find("Title: One").unwrap());
}

#[gpui::test]
fn rename_unloaded_and_loaded_chats_through_their_own_checkpoints(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Old one", ""), ("Old two", "")]);
    // Unloaded: the checkpoint, then the catalog row.
    window
        .update(cx, |view, window, cx| {
            view.open_rename_sheet(&chats[0].id, window, cx);
            let sheet = view.sidebar_chats.rename.as_ref().unwrap();
            assert_eq!(sheet.editor.read(cx).text(), "Old one");
            sheet.editor.clone().update(cx, |editor, cx| {
                editor.set_text("  Release\n notes ".into(), cx)
            });
            view.save_rename(cx);
            assert!(view.sidebar_chats.rename.as_ref().unwrap().saving);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.sidebar_chats.rename.is_none());
        let record = view.records.iter().find(|r| r.id == chats[0].id).unwrap();
        assert_eq!(record.title, "Release notes");
    });
    let checkpoint = SessionStore::open_existing_with_id(&chats[0].snapshot, &chats[0].id).unwrap();
    assert_eq!(checkpoint.snapshot().title, "Release notes");
    drop(checkpoint);
    // Loaded: the controller's snapshot carries it to the row and catalog.
    select(window, &chats[1].id, cx);
    window
        .update(cx, |view, window, cx| {
            view.open_rename_sheet(&chats[1].id, window, cx);
            let editor = view.sidebar_chats.rename.as_ref().unwrap().editor.clone();
            editor.update(cx, |editor, cx| editor.set_text("Loaded name".into(), cx));
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.sidebar_chats.rename.is_none());
        assert_eq!(view.session.title, "Loaded name");
        let record = view.records.iter().find(|r| r.id == chats[1].id).unwrap();
        assert_eq!(view.sidebar_title(record), "Loaded name");
    });
    let saved: bello_agent_core::workspace::WorkspaceSnapshot =
        serde_json::from_slice(&std::fs::read(dir.path().join("workspace.json")).unwrap()).unwrap();
    let title = |id: &str| {
        saved
            .chats
            .iter()
            .find(|c| c.id == id)
            .unwrap()
            .title
            .clone()
    };
    assert_eq!(title(&chats[0].id), "Release notes");
    assert_eq!(title(&chats[1].id), "Loaded name");
}

#[gpui::test]
fn rename_refuses_unsaved_chats_and_escape_dismisses(cx: &mut TestAppContext) {
    let (_dir, window, root, chats) = app_fixture(cx, &[("Saved", "")]);
    window
        .update(cx, |view, window, cx| {
            let pending = view.record.id.clone();
            view.open_rename_sheet(&pending, window, cx);
            assert!(view.sidebar_chats.rename.is_none());
            assert_eq!(
                view.error.as_deref(),
                Some("Send a first message before renaming this chat.")
            );
            view.open_rename_sheet(&chats[0].id, window, cx);
            let editor = view.sidebar_chats.rename.as_ref().unwrap().editor.clone();
            editor.update(cx, |editor, cx| editor.set_text("   ".into(), cx));
            // A blank title is never saved.
            view.save_rename(cx);
            assert!(!view.sidebar_chats.rename.as_ref().unwrap().saving);
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.sidebar_chats.rename.is_none());
        assert_eq!(
            view.records
                .iter()
                .find(|r| r.id == chats[0].id)
                .unwrap()
                .title,
            "Saved"
        );
    });
}

#[gpui::test]
fn row_clicks_mark_with_modifiers_and_a_double_click_renames(cx: &mut TestAppContext) {
    use gpui::{Modifiers, MouseButton, MouseDownEvent, MouseUpEvent, VisualTestContext};
    let (_dir, window, root, chats) = app_fixture(cx, &[("One", ""), ("Two", ""), ("Three", "")]);
    select(window, &chats[0].id, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.run_until_parked();
    let row = |visual: &mut VisualTestContext, id: &str| {
        visual
            .debug_bounds(Box::leak(format!("chat-row-{id}").into_boxed_str()))
            .unwrap()
            .center()
    };
    let third = row(&mut visual, &chats[2].id);
    visual.simulate_click(third, Modifiers::secondary_key());
    let second = row(&mut visual, &chats[1].id);
    visual.simulate_click(
        second,
        Modifiers {
            shift: true,
            ..Default::default()
        },
    );
    visual.read(|cx| {
        let view = root.read(cx);
        // Command-click marked the open row and the third; Shift extended
        // from the third (the anchor) to the second.
        assert_eq!(view.record.id, chats[0].id);
        assert!(view.sidebar_chats.is_marked(&chats[1].id));
        assert!(view.sidebar_chats.is_marked(&chats[2].id));
        assert!(!view.sidebar_chats.is_marked(&chats[0].id));
    });
    // An ordinary click drops the marks and opens; a second press renames.
    for click_count in [1, 2] {
        visual.simulate_event(MouseDownEvent {
            position: second,
            button: MouseButton::Left,
            modifiers: Modifiers::default(),
            click_count,
            first_mouse: false,
        });
        visual.simulate_event(MouseUpEvent {
            position: second,
            button: MouseButton::Left,
            modifiers: Modifiers::default(),
            click_count,
        });
        visual.run_until_parked();
    }
    visual.read(|cx| {
        let view = root.read(cx);
        assert!(!view.sidebar_chats.has_marked_sessions());
        assert_eq!(view.record.id, chats[1].id);
        assert_eq!(
            view.sidebar_chats
                .rename
                .as_ref()
                .map(|sheet| sheet.chat_id.as_str()),
            Some(chats[1].id.as_str())
        );
    });
}
