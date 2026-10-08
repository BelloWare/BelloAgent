//! Real GPUI handlers with a disposable local catalog. No provider is configured.
use super::{TopicAction, TopicWrite};
use crate::{AgentView, chat_organization::CatalogOutcome};
use crate::{LaunchState, topics_view::TopicControl};
use bello_agent_core::workspace::WorkspaceSnapshot;
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    Entity, EntityInputHandler, Focusable, KeyDownEvent, Keystroke, Modifiers, TestAppContext,
    VisualTestContext, WindowHandle,
};
use std::sync::{Arc, Mutex};
fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    fixture_configured(cx, None)
}
fn fixture_configured(
    cx: &mut TestAppContext,
    configuration: Option<(bello_agent_core::Profile, bello_agent_core::Credential)>,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let store = SessionStore::pending();
    let id = store.snapshot().id;
    let launch = LaunchState {
        controller: Controller::new(store, configuration).unwrap(),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record: ChatRecord::new(
            id,
            "Original chat".into(),
            project.join("conversation.json"),
        ),
        draft: DraftRecord::default(),
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}
fn open(window: WindowHandle<AgentView>, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            view.open_topics(&id, window, cx);
        })
        .unwrap();
}
fn control(window: WindowHandle<AgentView>, action: TopicControl, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            let token = view.topic_panel.as_ref().unwrap().token;
            view.activate_topic_control(token, action, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
}
fn title(window: WindowHandle<AgentView>, text: &str, cx: &mut TestAppContext) {
    window
        .update(cx, |view, _, cx| {
            view.topic_panel
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text(text.into(), cx));
        })
        .unwrap();
}
#[gpui::test]
fn create_move_rename_delete_reopen_is_metadata_only(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "  Work\n plans  ", cx);
    control(window, TopicControl::Save, cx);
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    assert_eq!(topic.title, "Work plans");
    control(window, TopicControl::Move(Some(topic.id.clone()), 0), cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.pending);
        assert_eq!(view.record.topic_id.as_deref(), Some(topic.id.as_str()));
        assert!(!view.controller.is_persistent());
        assert!(view.session.messages.is_empty());
        assert_eq!(view.composer.read(cx).text(), "");
    });
    assert!(!dir.path().join("conversation.json").exists());
    control(window, TopicControl::Rename(topic.id.clone()), cx);
    title(window, "Renamed", cx);
    control(window, TopicControl::Save, cx);
    let renamed = cx.read(|cx| root.read(cx).topics[0].clone());
    assert_eq!(renamed.title, "Renamed");
    control(window, TopicControl::Delete(topic.id.clone()), cx);
    assert_eq!(cx.read(|cx| root.read(cx).topics.len()), 1);
    control(
        window,
        TopicControl::ConfirmDelete(topic.id, renamed.revision),
        cx,
    );
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.topics.is_empty());
        assert!(view.record.topic_id.is_none());
        assert_eq!(view.record.topic_revision, 2);
        assert!(!view.controller.is_persistent());
    });
    let bytes = std::fs::read(dir.path().join("catalog.json")).unwrap();
    let snapshot: WorkspaceSnapshot = serde_json::from_slice(&bytes).unwrap();
    assert!(snapshot.topics.is_empty());
    assert!(snapshot.chats[0].topic_id.is_none());
    // A fresh application window over the same owning catalog restores metadata.
    let launch = cx.read(|cx| {
        let view = root.read(cx);
        LaunchState {
            controller: view.controller.clone(),
            project: view.project.clone(),
            workspace: view.workspace.clone(),
            record: view.record.clone(),
            draft: DraftRecord::default(),
            pending: false,
        }
    });
    let reopened = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    cx.run_until_parked();
    reopened
        .update(cx, |view, _, _| {
            assert!(view.topics.is_empty());
            assert!(view.record.topic_id.is_none());
        })
        .unwrap();
    assert_eq!(
        bytes,
        std::fs::read(dir.path().join("catalog.json")).unwrap()
    );
}
#[gpui::test]
fn failed_create_preserves_editor_and_catalog_state(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    std::fs::create_dir(dir.path().join("catalog.json")).unwrap();
    open(window, cx);
    title(window, "Keep this title", cx);
    control(window, TopicControl::Save, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.topics.is_empty());
        assert!(view.pending);
        assert!(view.topic_write.is_none());
        assert!(!view.known_catalog_uncertainty);
        assert_eq!(
            view.topic_panel.as_ref().unwrap().editor.read(cx).text(),
            "Keep this title"
        );
        assert!(
            view.topic_panel
                .as_ref()
                .unwrap()
                .notice
                .as_ref()
                .unwrap()
                .contains("could not be saved")
        );
    });
    std::fs::remove_dir(dir.path().join("catalog.json")).unwrap();
    control(window, TopicControl::Save, cx);
    assert_eq!(cx.read(|cx| root.read(cx).topics.len()), 1);
}
#[gpui::test]
fn stale_panel_controls_and_membership_cannot_overwrite_current_state(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    let old = cx.read(|cx| root.read(cx).topic_panel.as_ref().unwrap().token);
    open(window, cx);
    title(window, "Current", cx);
    window
        .update(cx, |view, window, cx| {
            view.activate_topic_control(old, TopicControl::Save, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).topics.is_empty()));
    control(window, TopicControl::Save, cx);
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    control(window, TopicControl::Move(Some(topic.id), 0), cx);
    window
        .update(cx, |view, _, cx| {
            view.apply_topic_action(TopicAction::Move(view.record.id.clone(), None, 0), cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.record.topic_id.is_some());
        assert_eq!(view.record.topic_revision, 1);
    });
}
#[gpui::test]
fn close_reopen_during_save_preserves_new_panel_and_blocks_shutdown(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "First", cx);
    window
        .update(cx, |view, window, cx| {
            let token = view.topic_panel.as_ref().unwrap().token;
            view.activate_topic_control(token, TopicControl::Save, window, cx);
            assert!(view.topic_write.is_some());
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
            view.activate_topic_control(token, TopicControl::Close, window, cx);
            let id = view.record.id.clone();
            view.open_topics(&id, window, cx);
            view.topic_panel
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| {
                    editor.set_text("New panel draft".into(), cx)
                });
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.topics.len(), 1);
        assert_eq!(
            view.topic_panel.as_ref().unwrap().editor.read(cx).text(),
            "New panel draft"
        );
        assert!(view.topic_write.is_none());
    });
}
#[gpui::test]
fn collapse_filter_archive_and_pin_keep_one_visible_order(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "Topic", cx);
    control(window, TopicControl::Save, cx);
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    control(window, TopicControl::Move(Some(topic.id.clone()), 0), cx);
    control(window, TopicControl::Close, cx);
    window
        .update(cx, |view, _, cx| {
            view.apply_topic_action(TopicAction::Expand(topic.id, false, 0), cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).visible_sidebar_records(cx).is_empty()));
    window
        .update(cx, |view, _, cx| {
            view.filter
                .update(cx, |filter, cx| filter.set_text("chat".into(), cx))
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert_eq!(root.read(cx).visible_sidebar_records(cx).len(), 1));
    window
        .update(cx, |view, _, cx| {
            let id = view.record.id.clone();
            view.set_chat_pinned(&id, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.record.pinned_at.is_some());
        assert!(view.record.topic_id.is_some());
    });
    window
        .update(cx, |view, _, cx| {
            let id = view.record.id.clone();
            view.set_chat_archived(&id, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).visible_sidebar_records(cx).is_empty()));
    window
        .update(cx, |view, _, cx| view.set_archive_visibility(true, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        let visible = view.visible_sidebar_records(cx);
        assert_eq!(visible.len(), 1);
        assert!(visible[0].archived_at.is_some());
        assert!(visible[0].pinned_at.is_some());
        assert!(visible[0].topic_id.is_some());
    });
}
#[gpui::test]
fn rendered_sheet_mouse_create_move_and_keyboard_close(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "Mouse topic", cx);
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("topics-panel").is_some());
    assert!(visual.debug_bounds("topics-title").is_some());
    let save = visual.debug_bounds("topics-save").unwrap();
    visual.simulate_click(save.center(), Modifiers::none());
    cx.run_until_parked();
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let move_here = visual
        .debug_bounds(Box::leak(
            format!("topic-move-{}", topic.id).into_boxed_str(),
        ))
        .unwrap();
    visual.simulate_click(move_here.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| root.read(cx).record.topic_id.clone()),
        Some(topic.id)
    );
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_keystrokes("escape");
    assert!(cx.read(|cx| root.read(cx).topic_panel.is_none()));
    assert!(cx.read(|cx| root.read(cx).session.messages.is_empty()));
}

#[gpui::test]
fn uncertain_topic_completion_keeps_catalog_admission_fenced(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    window
        .update(cx, |view, _, cx| {
            let write = TopicWrite {
                token: uuid::Uuid::new_v4(),
                panel_token: view.topic_panel.as_ref().map(|panel| panel.token),
                project: view.project.clone(),
                chat_id: None,
            };
            view.topic_write = Some(write.clone());
            view.finish_topic_write(
                write,
                CatalogOutcome {
                    result: Err(bello_agent_core::Error::Invalid(
                        "injected uncertain catalog result".into(),
                    )),
                    uncertain: true,
                },
                cx,
            );
            assert!(view.known_catalog_uncertainty);
            assert!(view.topic_write.is_none());
            view.apply_topic_action(TopicAction::Create("must not write".into()), cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.topics.is_empty());
        assert!(view.pending);
        assert!(!view.controller.is_persistent());
    });
}

#[gpui::test]
fn delayed_topic_completion_merges_only_membership_and_rejects_old_tokens(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "Topic", cx);
    control(window, TopicControl::Save, cx);
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    control(window, TopicControl::Move(Some(topic.id), 0), cx);
    window
        .update(cx, |view, _, cx| {
            let snapshot = view.workspace.lock().unwrap().snapshot();
            let write = TopicWrite {
                token: uuid::Uuid::new_v4(),
                panel_token: None,
                project: view.project.clone(),
                chat_id: None,
            };
            view.topic_write = Some(write.clone());
            view.records[0].pinned_at = Some(42);
            view.record.pinned_at = Some(42);
            view.records[0].topic_revision = 9;
            view.records[0].topic_id = None;
            view.record.topic_revision = 9;
            view.record.topic_id = None;
            let mut stale = write.clone();
            stale.token = uuid::Uuid::new_v4();
            view.finish_topic_write(
                stale,
                CatalogOutcome {
                    result: Ok(snapshot.clone()),
                    uncertain: false,
                },
                cx,
            );
            assert!(view.topic_write.is_some());
            view.finish_topic_write(
                write,
                CatalogOutcome {
                    result: Ok(snapshot),
                    uncertain: false,
                },
                cx,
            );
            assert_eq!(view.record.pinned_at, Some(42));
            assert_eq!(view.record.topic_revision, 9);
            assert!(view.record.topic_id.is_none());
        })
        .unwrap();
}

#[gpui::test]
fn topic_title_filter_reveals_children_and_hides_unrelated_headers(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "Alpha category", cx);
    control(window, TopicControl::Save, cx);
    let first = cx.read(|cx| root.read(cx).topics[0].clone());
    control(window, TopicControl::Move(Some(first.id.clone()), 0), cx);
    title(window, "Unrelated category", cx);
    control(window, TopicControl::Save, cx);
    control(window, TopicControl::Close, cx);
    window
        .update(cx, |view, _, cx| {
            view.apply_topic_action(TopicAction::Expand(first.id.clone(), false, 0), cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, _, cx| {
            view.filter
                .update(cx, |filter, cx| filter.set_text("alpha".into(), cx))
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx|{let view=root.read(cx);assert_eq!(view.visible_sidebar_records(cx).len(),1);let entries=view.sidebar_entries(cx);assert_eq!(entries.len(),2);assert!(matches!(&entries[0],crate::sidebar_actions::SidebarEntry::Topic(topic) if topic.id==first.id));});
}

#[gpui::test]
fn topic_and_connection_switch_admission_are_symmetric(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            view.connections
                .switches
                .insert(view.record.id.clone(), uuid::Uuid::new_v4());
            view.apply_topic_action(TopicAction::Create("Blocked".into()), cx);
            assert!(view.topic_write.is_none());
            view.connections.switches.clear();
            view.apply_topic_action(TopicAction::Create("Accepted".into()), cx);
            assert!(view.topic_write.is_some());
            assert!(view.connection_switch_blocker().is_some());
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert_eq!(root.read(cx).topics.len(), 1));
}

#[gpui::test]
fn cancelled_or_replaced_delete_confirmation_cannot_delete_old_target(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "A", cx);
    control(window, TopicControl::Save, cx);
    title(window, "B", cx);
    control(window, TopicControl::Save, cx);
    let topics = cx.read(|cx| root.read(cx).topics.clone());
    control(window, TopicControl::Delete(topics[0].id.clone()), cx);
    let old = cx.read(|cx| root.read(cx).topic_panel.as_ref().unwrap().token);
    control(window, TopicControl::New, cx);
    window
        .update(cx, |view, window, cx| {
            view.activate_topic_control(
                old,
                TopicControl::ConfirmDelete(topics[0].id.clone(), 0),
                window,
                cx,
            )
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).topics.len()), 2);
    control(window, TopicControl::Delete(topics[1].id.clone()), cx);
    control(
        window,
        TopicControl::ConfirmDelete(topics[0].id.clone(), 0),
        cx,
    );
    assert_eq!(cx.read(|cx| root.read(cx).topics.len()), 2);
    control(
        window,
        TopicControl::ConfirmDelete(topics[1].id.clone(), 0),
        cx,
    );
    assert_eq!(cx.read(|cx| root.read(cx).topics.len()), 1);
}

#[gpui::test]
fn topic_keyboard_preserves_marked_text_and_held_enter_never_sends(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    window
        .update(cx, |view, window, cx| {
            view.topic_panel
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| {
                    editor.replace_and_mark_text_in_range(None, "漢字", Some(0..2), window, cx)
                });
            view.topics_key(
                &KeyDownEvent {
                    keystroke: Keystroke::parse("enter").unwrap(),
                    is_held: false,
                },
                window,
                cx,
            );
            assert!(view.topic_write.is_none());
            assert!(
                view.topic_panel
                    .as_ref()
                    .unwrap()
                    .editor
                    .read(cx)
                    .has_marked_text()
            );
            view.topic_panel
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("Keep held".into(), cx));
            view.topics_key(
                &KeyDownEvent {
                    keystroke: Keystroke::parse("enter").unwrap(),
                    is_held: true,
                },
                window,
                cx,
            );
            assert!(view.topic_write.is_none());
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.topics.is_empty());
        assert!(view.session.messages.is_empty());
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_keystrokes("tab");
    visual.simulate_keystrokes("shift-tab");
    window
        .update(cx, |view, window, cx| {
            assert!(
                view.topic_panel
                    .as_ref()
                    .unwrap()
                    .editor
                    .read(cx)
                    .focus_handle(cx)
                    .is_focused(window)
            )
        })
        .unwrap();
}

#[gpui::test]
fn configured_loopback_provider_observes_zero_requests_for_topics(cx: &mut TestAppContext) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let profile=serde_json::from_value(serde_json::json!({"id":"topics-fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":format!("http://{}",listener.local_addr().unwrap()),"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let (dir, window, root) = fixture_configured(
        cx,
        Some((
            profile,
            bello_agent_core::Credential::new("loopback-only-topic-fixture".into()).unwrap(),
        )),
    );
    open(window, cx);
    title(window, "No network", cx);
    control(window, TopicControl::Save, cx);
    let topic = cx.read(|cx| root.read(cx).topics[0].clone());
    control(window, TopicControl::Move(Some(topic.id.clone()), 0), cx);
    control(window, TopicControl::Rename(topic.id.clone()), cx);
    title(window, "Still local", cx);
    control(window, TopicControl::Save, cx);
    control(window, TopicControl::Delete(topic.id.clone()), cx);
    control(window, TopicControl::ConfirmDelete(topic.id, 1), cx);
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.session.messages.is_empty());
        assert!(view.session.pending.is_empty());
        assert!(!view.controller.is_persistent());
    });
    assert!(!dir.path().join("conversation.json").exists());
}

#[gpui::test]
fn rebind_invalidates_old_topic_panel_callbacks(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    open(window, cx);
    title(window, "Old draft", cx);
    let old = cx.read(|cx| root.read(cx).topic_panel.as_ref().unwrap().token);
    window
        .update(cx, |view, window, cx| {
            view.bind_window(window, cx);
            let id = view.record.id.clone();
            view.open_topics(&id, window, cx);
            view.activate_topic_control(old, TopicControl::Save, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.topics.is_empty());
        assert!(view.topic_write.is_none());
        assert_eq!(
            view.topic_panel.as_ref().unwrap().editor.read(cx).text(),
            ""
        );
    });
}
