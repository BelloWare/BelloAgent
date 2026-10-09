use super::Control;
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Lane, Message, RunState, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    ClipboardItem, Entity, Modifiers, TestAppContext, VisualTestContext, WindowHandle, px, size,
};
use std::sync::{Arc, Mutex};

fn fixture(
    cx: &mut TestAppContext,
    count: usize,
    archived: bool,
    huge: bool,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(directory.path()).unwrap();
    let path = project.join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.messages = (0..count)
                .map(|i| Message {
                    task_root_id: None,
                    user_content: None,
                    id: format!("row-{i}"),
                    role: "assistant".into(),
                    text: if huge {
                        "x".repeat(8 * 1024 * 1024 + 1)
                    } else {
                        format!("match {i}\n")
                    },
                    reasoning: "hidden-reasoning".into(),
                    replay_eligible: true,
                    state: "complete".into(),
                    usage: serde_json::Value::Null,
                    model: None,
                    tool_record: None,
                    compaction: None,
                })
                .collect();
            session.state = RunState::Paused;
            session.queue_paused = true;
            session
                .pending
                .push(Submission::new("queued untouched".into(), Lane::FollowUp));
            Ok(())
        })
        .unwrap();
    let mut record = ChatRecord::new(store.snapshot().id, "Content fixture".into(), path);
    record.archived_at = archived.then_some(1);
    let draft = DraftRecord {
        text: "Draft 日本語".into(),
        ..Default::default()
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace.register(record.clone(), draft.clone()).unwrap();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(workspace)),
        project,
        record,
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(812.)));
    cx.run_until_parked();
    (directory, window, root)
}
fn open(window: WindowHandle<AgentView>, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            view.open_conversation_content(window, cx)
        })
        .unwrap();
    cx.run_until_parked();
}
fn action(window: WindowHandle<AgentView>, control: Control, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            let token = view.conversation_content.as_ref().unwrap().token;
            view.content_control(token, control, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
}
fn clipboard(cx: &TestAppContext) -> String {
    cx.read(|cx| cx.read_from_clipboard().unwrap().text().unwrap())
}

#[gpui::test]
fn archived_search_covers_retained_history_without_mutating_store_or_composer(
    cx: &mut TestAppContext,
) {
    let (directory, window, root) = fixture(cx, 240, true, false);
    let files: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            let bytes = std::fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect();
    let before = cx.read(|cx| {
        let view = root.read(cx);
        (
            view.composer.entity_id(),
            view.composer.read(cx).text().to_owned(),
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            view.visible_messages,
        )
    });
    open(window, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        let sheet = view.conversation_content.as_ref().unwrap();
        let page = sheet.result.as_ref().unwrap();
        assert_eq!(page.total, 240);
        assert_eq!(page.hits.len(), 100);
        assert_eq!(page.hits[0].id, "row-0");
        assert_eq!(view.composer.entity_id(), before.0);
        assert_eq!(view.composer.read(cx).text(), before.1);
        assert_eq!(
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            before.2
        );
        assert_eq!(view.visible_messages, before.3);
    });
    for (path, bytes) in files {
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}
#[gpui::test]
fn next_keeps_searched_query_after_editor_changes(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 205, false, false);
    open(window, cx);
    window
        .update(cx, |view, _, cx| {
            view.conversation_content
                .as_ref()
                .unwrap()
                .query
                .update(cx, |editor, cx| editor.set_text("no match".into(), cx));
        })
        .unwrap();
    action(window, Control::Next, cx);
    cx.read(|cx| {
        let sheet = root.read(cx).conversation_content.as_ref().unwrap();
        assert_eq!(sheet.searched, "");
        assert_eq!(sheet.result.as_ref().unwrap().hits[0].position, 101);
        assert_eq!(sheet.query.read(cx).text(), "no match");
    });
}
#[gpui::test]
fn inclusive_range_and_whole_copy_are_exact_plain_retained_text(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 3, false, false);
    open(window, cx);
    action(window, Control::Select(2), cx);
    action(window, Control::Start, cx);
    action(window, Control::Select(3), cx);
    action(window, Control::End, cx);
    action(window, Control::CopyRange, cx);
    assert_eq!(clipboard(cx), "match 1\nmatch 2\n");
    action(window, Control::CopyAll, cx);
    assert_eq!(clipboard(cx), "match 0\nmatch 1\nmatch 2\n");
    cx.read(|cx| assert_eq!(root.read(cx).composer.read(cx).text(), "Draft 日本語"));
}
#[gpui::test]
fn cancelled_copy_cannot_replace_clipboard(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx, 3, false, false);
    open(window, cx);
    window
        .update(cx, |view, window, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into()));
            let token = view.conversation_content.as_ref().unwrap().token;
            view.content_control(token, Control::CopyAll, window, cx);
            view.content_control(token, Control::Close, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(clipboard(cx), "sentinel");
}
#[gpui::test]
fn oversize_and_invalid_range_leave_clipboard_unchanged(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 1, false, true);
    open(window, cx);
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    action(window, Control::CopyAll, cx);
    assert_eq!(clipboard(cx), "sentinel");
    window
        .update(cx, |view, _, cx| {
            view.conversation_content
                .as_ref()
                .unwrap()
                .first
                .update(cx, |editor, cx| editor.set_text("0".into(), cx));
        })
        .unwrap();
    action(window, Control::CopyRange, cx);
    assert_eq!(clipboard(cx), "sentinel");
    cx.read(|cx| assert!(!root.read(cx).conversation_content.as_ref().unwrap().busy));
}
#[gpui::test]
fn navigation_and_window_rebind_fence_pending_copy(cx: &mut TestAppContext) {
    for rebind in [false, true] {
        let (_dir, window, _root) = fixture(cx, 3, false, false);
        open(window, cx);
        window
            .update(cx, |view, window, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into()));
                let token = view.conversation_content.as_ref().unwrap().token;
                view.content_control(token, Control::CopyAll, window, cx);
                if rebind {
                    view.window_binding = None;
                } else {
                    view.navigation_generation += 1;
                }
            })
            .unwrap();
        cx.run_until_parked();
        assert_eq!(clipboard(cx), "sentinel");
    }
}
#[gpui::test]
fn older_result_reveal_targets_exact_id_and_keeps_transcript_virtualized(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 240, false, false);
    open(window, cx);
    action(window, Control::Select(2), cx);
    action(window, Control::Reveal, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.conversation_content.is_none());
        assert_eq!(view.visible_messages, 239);
        let transcript = view.transcript.as_ref().unwrap().read(cx);
        assert!(transcript.materialized_indexes().len() < 100);
        assert!(
            transcript
                .materialized_texts()
                .iter()
                .any(|(_, text)| text.contains("match 1\n"))
        );
    });
}
#[gpui::test]
fn real_buttons_search_copy_and_escape_preserve_draft(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 3, false, false);
    open(window, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let copy = visual
        .debug_bounds("content-copy-all")
        .expect("copy button");
    visual.simulate_click(copy.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(clipboard(cx), "match 0\nmatch 1\nmatch 2\n");
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.conversation_content.is_none());
        assert_eq!(view.composer.read(cx).text(), "Draft 日本語");
    });
}
#[gpui::test]
fn modal_keys_cannot_submit_background_composer_and_tab_stays_in_sheet(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 3, false, false);
    open(window, cx);
    let before = cx.read(|cx| serde_json::to_value(root.read(cx).controller.snapshot()).unwrap());
    window
        .update(cx, |view, window, cx| view.composer.read(cx).focus(window))
        .unwrap();
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    for _ in 0..20 {
        cx.simulate_keystrokes(window.into(), "tab");
    }
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            before
        );
        assert_eq!(view.composer.read(cx).text(), "Draft 日本語");
    });
}
#[gpui::test]
fn replaced_controller_and_old_sheet_callbacks_cannot_copy(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx, 3, false, false);
    open(window, cx);
    window
        .update(cx, |view, window, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into()));
            let token = view.conversation_content.as_ref().unwrap().token;
            view.content_control(token, Control::CopyAll, window, cx);
            view.controller = Controller::new(SessionStore::pending(), None).unwrap();
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(clipboard(cx), "sentinel");
}
#[gpui::test]
fn marked_composer_is_preserved_and_query_ime_escape_does_not_close(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler;
    let (_dir, window, root) = fixture(cx, 3, false, false);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "未確定", Some(1..2), window, cx)
            });
            let before = view.composer.read(cx).text().to_owned();
            view.open_conversation_content(window, cx);
            assert!(view.conversation_content.is_none());
            assert_eq!(view.composer.read(cx).text(), before);
            assert!(view.composer.read(cx).has_marked_text());
            view.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
            view.open_conversation_content(window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            view.conversation_content
                .as_ref()
                .unwrap()
                .query
                .update(cx, |editor, cx| {
                    editor.replace_and_mark_text_in_range(None, "未確定", Some(1..2), window, cx)
                });
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).conversation_content.is_some()));
}
#[gpui::test]
fn archived_footer_opens_loaded_sheet_without_connection(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 3, true, false);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let entry = visual.debug_bounds("archived-search-copy").unwrap();
    visual.simulate_click(entry.center(), Modifiers::none());
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .conversation_content
                .as_ref()
                .unwrap()
                .result
                .as_ref()
                .unwrap()
                .total,
            3
        )
    });
}
#[gpui::test]
fn equal_length_stale_copy_finishes_with_notice_without_touching_clipboard(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, 3, false, false);
    open(window, cx);
    window
        .update(cx, |view, _, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into()));
            let mut stale = view.controller.snapshot();
            stale.messages[0].text.replace_range(..1, "M");
            view.conversation_content.as_mut().unwrap().snapshot =
                Some(crate::conversation_content::Snapshot::new(Arc::new(stale)));
        })
        .unwrap();
    action(window, Control::CopyAll, cx);
    assert_eq!(clipboard(cx), "sentinel");
    cx.read(|cx| {
        let sheet = root.read(cx).conversation_content.as_ref().unwrap();
        assert!(!sheet.busy);
        assert!(
            sheet
                .notice
                .as_ref()
                .unwrap()
                .contains("conversation changed")
        );
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("content-search").is_some());
}

#[gpui::test]
fn actions_menu_opens_loaded_sheet_without_connection(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 3, false, false);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let actions = visual.debug_bounds("conversation-actions-open").unwrap();
    visual.simulate_click(actions.center(), Modifiers::none());
    cx.run_until_parked();
    let entry = visual.debug_bounds("search-copy-conversation").unwrap();
    visual.simulate_click(entry.center(), Modifiers::none());
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).conversation_content.is_some()));
}

#[gpui::test]
fn latest_loaded_count_contract_survives_search_and_next_query_edits(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, 205, false, false);
    open(window, cx);
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .conversation_content
                .as_ref()
                .unwrap()
                .result
                .as_ref()
                .unwrap()
                .hits
                .iter()
                .all(|hit| hit.count == Some(0))
        )
    });
    window
        .update(cx, |view, _, cx| {
            view.conversation_content
                .as_ref()
                .unwrap()
                .query
                .update(cx, |editor, cx| editor.set_text("MATCH".into(), cx))
        })
        .unwrap();
    action(window, Control::Search, cx);
    window
        .update(cx, |view, _, cx| {
            view.conversation_content
                .as_ref()
                .unwrap()
                .query
                .update(cx, |editor, cx| editor.set_text("absent".into(), cx))
        })
        .unwrap();
    action(window, Control::Next, cx);
    cx.read(|cx| {
        let sheet = root.read(cx).conversation_content.as_ref().unwrap();
        assert_eq!(sheet.searched, "MATCH");
        assert_eq!(sheet.result.as_ref().unwrap().hits[0].position, 101);
        assert!(
            sheet
                .result
                .as_ref()
                .unwrap()
                .hits
                .iter()
                .all(|hit| hit.count == Some(1))
        );
    });
}
