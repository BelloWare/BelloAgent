use super::{progress_label, row_label};
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, SessionStore,
    compaction::{Operation, Phase},
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    Entity, EntityInputHandler, Modifiers, TestAppContext, VisualTestContext, WindowHandle, point,
    px,
};
use std::sync::{Arc, Mutex};
fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record: ChatRecord::new(
            snapshot.id,
            "Compaction fixture".into(),
            project.join("session.json"),
        ),
        draft: DraftRecord {
            attachments: Vec::new(),
            text: "Keep this unsent draft 日本語".into(),
            ..Default::default()
        },
        project,
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}
#[gpui::test]
fn actions_menu_open_dismiss_and_rejection_preserve_draft_and_never_materialize(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let before = root.read_with(cx, |view, cx| {
        (
            view.composer.read(cx).text().to_owned(),
            view.controller.snapshot().revision,
        )
    });
    let position = visual
        .debug_bounds("conversation-actions-open")
        .unwrap()
        .center();
    visual.simulate_click(position, Modifiers::none());
    cx.run_until_parked();
    assert!(root.read_with(cx, |view, _| view.compaction_menu.is_some()));
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    assert!(root.read_with(cx, |view, _| view.compaction_menu.is_none()));
    let position = visual
        .debug_bounds("conversation-actions-open")
        .unwrap()
        .center();
    visual.simulate_click(position, Modifiers::none());
    cx.run_until_parked();
    let position = visual.debug_bounds("compact-now").unwrap().center();
    visual.simulate_click(position, Modifiers::none());
    cx.run_until_parked();
    root.read_with(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), before.0);
        assert_eq!(view.controller.snapshot().revision, before.1);
        assert!(!view.controller.is_persistent());
        assert!(view.compaction_menu.is_none());
    });
}
#[gpui::test]
fn delayed_menu_choice_cannot_retarget_after_navigation_identity_changes(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx);
    root.update(cx, |view, cx| {
        view.open_compaction_menu(point(px(400.), px(400.)), cx);
        let old_id = view.record.id.clone();
        view.record.id = "replacement-chat".into();
        view.compact_from_menu(cx);
        assert!(view.queue_operation.is_none());
        assert_eq!(view.controller.snapshot().revision, 0);
        view.record.id = old_id;
    });
}
#[gpui::test]
fn menu_dismiss_keeps_marked_text_and_undo_editor_entity(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let editor = root.read_with(cx, |view, _| view.composer.clone());
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            view.open_compaction_menu(point(px(400.), px(400.)), cx);
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    root.read_with(cx, |view, cx| {
        assert_eq!(view.composer.entity_id(), editor.entity_id());
        assert!(view.composer.read(cx).has_marked_text());
        assert!(view.composer.read(cx).text().contains("漢字"));
        assert!(view.compaction_menu.is_none());
        assert_eq!(view.controller.snapshot().revision, 0);
    });
}
#[gpui::test]
fn archive_and_shutdown_fences_reject_compaction_action(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx);
    root.update(cx, |view, cx| {
        view.shutting_down = true;
        view.compact_current(cx);
        assert!(view.queue_operation.is_none());
        view.shutting_down = false;
        view.record.archived_at = Some(1);
        let id = view.record.id.clone();
        if let Some(record) = view.records.iter_mut().find(|record| record.id == id) {
            record.archived_at = Some(1);
        } else {
            view.records.push(view.record.clone());
        }
        assert!(view.chat_is_archived(&view.record.id));
        view.compact_current(cx);
        assert!(view.queue_operation.is_none());
    });
}
#[::core::prelude::v1::test]
fn labels_distinguish_compaction_from_normal_generation() {
    let mut session = bello_agent_core::Session::new();
    assert_eq!(progress_label(&session), "Working · Generating response…");
    session.compaction = Some(Operation {
        id: "op".into(),
        phase: Phase::Planning,
        progress_id: "progress".into(),
        summary_id: None,
        error: None,
        summary_output_allowance: 0,
        http_attempts: 0,
    });
    assert!(progress_label(&session).contains("Preparing"));
    session.compaction.as_mut().unwrap().phase = Phase::Summarizing;
    assert!(progress_label(&session).contains("Summarizing"));
    let row = bello_agent_core::Message {
        user_content: None,
        id: "progress".into(),
        role: "assistant".into(),
        text: "Partial summary".into(),
        reasoning: String::new(),
        replay_eligible: false,
        state: "compaction-cancelled".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    };
    session.compaction = None;
    assert!(
        row_label(&row, &session)
            .unwrap()
            .contains("original context retained")
    );
}

#[::core::prelude::v1::test]
fn older_compaction_receipt_displays_its_exact_retained_failure() {
    let mut session = bello_agent_core::Session::new();
    session.compaction_history.push(Operation {
        id: "old-attempt".into(),
        phase: Phase::Failed,
        progress_id: "old-progress".into(),
        summary_id: None,
        error: Some(
            "Compaction failed: exact retained gateway failure. Original context is retained."
                .into(),
        ),
        summary_output_allowance: 16384,
        http_attempts: 1,
    });
    let row = bello_agent_core::Message {
        user_content: None,
        id: "old-progress".into(),
        role: "assistant".into(),
        text: String::new(),
        reasoning: String::new(),
        replay_eligible: false,
        state: "compaction-failed".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    };
    assert_eq!(
        row_label(&row, &session),
        session.compaction_history[0].error.as_deref()
    );
}
