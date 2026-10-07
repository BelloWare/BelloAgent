//! Synthetic GPUI events and real local stores; native IME/focus is separate.
use super::*;
use crate::{LaunchState, queue_edit_controls::QueueEditRowState};
use bello_agent_core::{
    Lane, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, QueuedCancelState, WorkspaceStore},
};
use gpui::{Entity, EntityInputHandler, Focusable, TestAppContext};
use std::sync::Mutex;

fn fixture(
    cx: &mut TestAppContext,
    held: bool,
    original: String,
    revision: u64,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    String,
    String,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let turn = Submission::new(original, Lane::FollowUp);
    let turn_id = turn.id.clone();
    store
        .transact(|s| {
            s.pending.push(turn);
            s.queue_paused = true;
            if held {
                s.begin_edit(&turn_id, "recovered-hold")?;
            }
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Begin fixture".into(), path);
    let draft = DraftRecord {
        attachments: Vec::new(),
        revision,
        text: "ordinary é 日本語".into(),
        queued_edit: None,
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace.register(record.clone(), draft.clone()).unwrap();
    let id = record.id.clone();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root, id, turn_id)
}

#[gpui::test]
fn queue_begin_keeps_typing_and_captures_latest_draft_only_after_reply(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued full text".into(), 5);
    let mut expected = String::new();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            assert!(!v.busy);
            assert!(v.editing.is_none());
            assert!(v.draft_before_edit.is_empty());
            assert!(matches!(
                v.queue_edit_row_state(&turn),
                QueueEditRowState::Preparing
            ));
            v.composer.update(cx, |editor, cx| {
                editor.replace_text_in_range(None, "typed 🦀 ", window, cx)
            });
            expected = v.composer.read(cx).text().to_owned();
            assert!(expected.contains("typed 🦀"));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.draft_before_edit, expected);
        assert_eq!(v.composer.read(cx).text(), "queued full text");
        assert!(v.begin_operation.is_none());
        assert!(v.editing.is_some());
        assert!(matches!(
            v.queue_edit_row_state(&turn),
            QueueEditRowState::Owned { resolving: false }
        ));
        v.cancel_owned_edit(&id, cx);
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| assert_eq!(v.composer.read(cx).text(), expected));
}

#[gpui::test]
fn queue_begin_resumes_named_unowned_hold_without_allocating_another_identity(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, true, "held full text".into(), 5);
    window
        .update(cx, |v, window, cx| {
            assert!(matches!(
                v.queue_edit_row_state(&turn),
                QueueEditRowState::Held { .. }
            ));
            v.begin_queued_edit(&id, &turn, Some("recovered-hold".into()), window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.editing.as_deref(), Some("recovered-hold"));
        assert_eq!(v.composer.read(cx).text(), "held full text");
        assert!(v.session.outcomes.is_empty());
    });
}

#[gpui::test]
fn queue_begin_cancel_before_reply_durably_fences_adoption(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "never replace ordinary".into(), 5);
    let mut old = None;
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            let key = v.begin_operation.as_ref().unwrap().key.clone();
            old = Some(key.clone());
            v.cancel_held_edit(&id, &turn, &key.edit, cx);
            assert!(v.begin_operation.is_none());
            assert!(!v.busy);
            assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        let key = old.take().unwrap();
        let status = v.controller.edit_status(&key.edit).unwrap();
        assert_eq!(status.state, QueueEditState::Cancelled);
        v.finish_begin_read(key, Ok(status), cx);
        assert!(v.editing.is_none());
        assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
        assert!(matches!(
            v.workspace.lock().unwrap().snapshot().queued_cancellations[&id].state,
            QueuedCancelState::Settled
        ));
    });
}

#[gpui::test]
fn queue_begin_marked_adoption_waits_for_unmark_and_blocks_conflicting_routes(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued text".into(), 5);
    let mut marked = String::new();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
            marked = v.composer.read(cx).text().to_owned();
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(v.begin_operation.as_ref().unwrap().deferred.is_some());
            assert_eq!(v.composer.read(cx).text(), marked);
            assert!(v.composer.read(cx).has_marked_text());
            let before = serde_json::to_value(v.controller.snapshot()).unwrap();
            v.resolve_edit("saved", cx);
            v.remove_queue(turn.clone(), cx);
            v.submit_chat(Lane::FollowUp, cx);
            v.begin_shutdown(window, cx);
            assert!(!v.busy);
            assert!(!v.shutting_down);
            assert_eq!(
                serde_json::to_value(v.controller.snapshot()).unwrap(),
                before
            );
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "queued text");
        assert_eq!(v.draft_before_edit, marked);
        assert!(v.begin_operation.is_none());
    });
}

#[gpui::test]
fn queue_begin_cancel_invalidates_marked_deferred_reply_without_replacing_text(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, true, "held text".into(), 5);
    let mut marked = String::new();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, Some("recovered-hold".into()), window, cx);
            v.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
            marked = v.composer.read(cx).text().to_owned();
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(v.begin_operation.as_ref().unwrap().deferred.is_some());
            v.cancel_held_edit(&id, &turn, "recovered-hold", cx);
            assert!(v.begin_operation.is_none());
            assert!(v.composer.read(cx).has_marked_text());
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert_eq!(v.composer.read(cx).text(), marked);
        assert_eq!(
            v.controller.edit_status("recovered-hold").unwrap().state,
            QueueEditState::Cancelled
        );
    });
}

#[gpui::test]
fn queue_begin_navigation_and_changed_focus_do_not_steal_current_composer(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "old chat queue".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.new_chat(window, cx);
            v.composer
                .update(cx, |editor, cx| editor.set_text("new chat text".into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert_ne!(v.record.id, id);
            assert_eq!(v.composer.read(cx).text(), "new chat text");
            assert!(v.composer.read(cx).focus_handle(cx).is_focused(window));
            let previous = v.chat_ref(&id).unwrap();
            assert_eq!(previous.composer.read(cx).text(), "old chat queue");
            assert_eq!(previous.draft_before_edit, "ordinary é 日本語");
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).begin_operation.is_none()));
}

#[gpui::test]
fn queue_begin_rebound_window_rejects_old_adoption_and_retains_resumable_hold(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "held not yet adopted".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.bind_window(window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert!(v.begin_operation.is_none());
        assert!(v.queue_operation.is_none());
        assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
        assert!(matches!(
            v.queue_edit_row_state(&turn),
            QueueEditRowState::Held { .. }
        ));
    });
}

#[gpui::test]
fn queue_begin_oversized_live_draft_is_preserved_and_hold_can_be_cancelled_after_repair(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "valid queued text".into(), 5);
    let oversized = "x".repeat(262_145);
    window
        .update(cx, |v, window, cx| {
            v.composer
                .update(cx, |editor, cx| editor.set_text(oversized.clone(), cx));
            v.begin_queued_edit(&id, &turn, None, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), oversized);
        assert!(v.editing.is_none());
        assert!(
            v.error
                .as_deref()
                .unwrap()
                .contains("draft was not replaced"),
            "actual error: {:?}",
            v.error
        );
        assert!(v.session.edit.is_some());
        v.composer.update(cx, |editor, cx| {
            editor.set_text("repaired ordinary".into(), cx)
        });
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        let edit = v.session.edit.as_ref().unwrap().edit_id.clone();
        v.cancel_held_edit(&id, &turn, &edit, cx);
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.session.edit.is_none());
        assert_eq!(v.composer.read(cx).text(), "repaired ordinary");
    });
}

#[gpui::test]
fn queue_begin_checked_revision_rejects_start_and_exhaustion_during_deferred_adoption(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), u64::MAX);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            assert!(v.begin_operation.is_none());
            assert!(v.controller.snapshot().edit.is_none());
        })
        .unwrap();
    root.update(cx, |v, _| v.draft_revision = u64::MAX - 1);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "字", Some(1..1), window, cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    let before = root.update(cx, |v, cx| {
        assert_eq!(v.draft_revision, u64::MAX);
        assert!(v.begin_operation.as_ref().unwrap().deferred.is_some());
        v.composer.read(cx).text().to_owned()
    });
    window
        .update(cx, |v, window, cx| {
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx))
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert_eq!(v.composer.read(cx).text(), before);
        assert!(v.session.edit.is_some());
        assert!(v.error.as_deref().unwrap().contains("revision limit"));
    });
}

#[gpui::test]
fn queue_begin_same_chat_changed_control_focus_is_not_stolen(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(window.is_window_active());
            v.composer.read(cx).focus(window);
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.filter.read(cx).focus(window);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(v.filter.read(cx).focus_handle(cx).is_focused(window));
            assert_eq!(v.composer.read(cx).text(), "queued");
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).editing.is_some()));
}

#[gpui::test]
fn queue_begin_unchanged_control_focus_can_follow_requested_editor(cx: &mut TestAppContext) {
    let (_dir, window, _root, id, turn) = fixture(cx, false, "queued".into(), 5);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(window.is_window_active());
            v.filter.read(cx).focus(window);
            v.begin_queued_edit(&id, &turn, None, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert!(v.composer.read(cx).focus_handle(cx).is_focused(window))
        })
        .unwrap();
}

#[gpui::test]
fn queue_begin_replaced_controller_rejects_old_reply(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            let replacement =
                Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
            v.chat.replace_controller(replacement, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert!(v.begin_operation.is_none());
        assert!(v.queue_operation.is_none());
        assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
        assert!(v.controller.snapshot().edit.is_none());
    });
}

#[gpui::test]
fn queue_begin_later_failure_invalidates_deferred_status_before_unmark(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            v.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "字", Some(1..1), window, cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            let old = v.begin_operation.as_ref().unwrap().key.clone();
            let status = v
                .begin_operation
                .as_ref()
                .unwrap()
                .deferred
                .clone()
                .unwrap();
            let text = v.composer.read(cx).text().to_owned();
            v.result(
                Err(bello_agent_core::Error::PersistenceUncertain(
                    "synthetic later actor error".into(),
                )),
                cx,
            );
            assert_ne!(v.queue_operation, Some(old.token));
            assert!(v.begin_operation.as_ref().unwrap().deferred.is_none());
            v.finish_begin_read(old, Ok(status), cx);
            assert_eq!(v.composer.read(cx).text(), text);
            assert!(v.editing.is_none());
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_some());
        assert_eq!(v.composer.read(cx).text(), "queued");
    });
}

#[gpui::test]
fn queue_begin_rejected_checkpoint_preserves_draft_and_retry_opens_once(cx: &mut TestAppContext) {
    let (dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    let path = dir.path().join("session.json");
    let backup = dir.path().join("saved-session.json");
    std::fs::rename(&path, &backup).unwrap();
    std::fs::create_dir(&path).unwrap();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert!(v.controller.snapshot().edit.is_none());
        assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
        assert!(!v.busy);
        assert!(v.begin_error.is_some());
    });
    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(&backup, &path).unwrap();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.editing.is_some());
        assert_eq!(v.composer.read(cx).text(), "queued");
        assert_eq!(v.session.pending.len(), 1);
        assert!(
            v.error.is_none(),
            "confirmed retry must clear its own Begin error"
        );
        assert!(v.begin_error.is_none());
    });
}

#[gpui::test]
fn queue_begin_cancel_prepare_failure_never_adopts_and_retry_preserves_latest_ordinary(
    cx: &mut TestAppContext,
) {
    let (dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    let path = dir.path().join("workspace.json");
    let backup = dir.path().join("saved-workspace.json");
    std::fs::rename(&path, &backup).unwrap();
    std::fs::create_dir(&path).unwrap();
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            let edit = v.begin_operation.as_ref().unwrap().key.edit.clone();
            v.cancel_held_edit(&id, &turn, &edit, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.begin_operation.is_none());
        assert!(v.editing.is_none());
        assert!(v.has_pending_cancel(&id));
        assert_eq!(v.composer.read(cx).text(), "ordinary é 日本語");
    });
    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(&backup, &path).unwrap();
    window
        .update(cx, |v, window, cx| {
            v.composer.update(cx, |editor, cx| {
                editor.replace_text_in_range(None, "new ", window, cx)
            });
            let edit = v.session.edit.as_ref().unwrap().edit_id.clone();
            v.cancel_held_edit(&id, &turn, &edit, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.session.edit.is_none());
        assert!(!v.has_pending_cancel(&id));
        assert!(v.composer.read(cx).text().contains("new "));
        assert!(!v.composer.read(cx).text().contains("queued"));
    });
}

#[gpui::test]
fn queue_begin_earlier_retained_rewrite_is_reconciled_before_another_resume(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, true, "held text".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.retained_edit = Some(QueuedDraft {
                edit_id: "earlier-edit".into(),
                turn_id: "earlier-turn".into(),
                rewrite: "earlier unsaved rewrite".into(),
                original_text: Some("old original".into()),
            });
            v.begin_queued_edit(&id, &turn, Some("recovered-hold".into()), window, cx);
            assert!(v.begin_operation.is_none());
            assert!(v.retained_edit.is_some());
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(
            v.composer.read(cx).text(),
            "earlier unsaved rewrite\n\nordinary é 日本語"
        );
        assert!(v.retained_edit.is_none());
        assert!(v.editing.is_none());
        assert_eq!(v.session.edit.as_ref().unwrap().edit_id, "recovered-hold");
    });
}

#[gpui::test]
fn queue_begin_held_controls_fit_normal_half_split_and_growing_rows_remain_scrollable(
    cx: &mut TestAppContext,
) {
    use gpui::{VisualTestContext, point, px, size};
    let (_dir, window, root, id, turn) = fixture(cx, true, "held text".into(), 5);
    let mut last = String::new();
    root.update(cx, |v, cx| {
        for i in 0..6 {
            let item = Submission::new(format!("later row {i}"), Lane::FollowUp);
            last = item.id.clone();
            Arc::make_mut(&mut v.session).pending.push(item);
        }
        cx.notify();
    });
    // GPUI's test selector API requires static strings; these five bounded
    // fixture-only labels live for this test process, never in production.
    let row_selector: &'static str = Box::leak(format!("queue-row-{turn}").into_boxed_str());
    let resume_selector: &'static str =
        Box::leak(format!("queue-resume-edit-{turn}").into_boxed_str());
    let cancel_selector: &'static str =
        Box::leak(format!("queue-cancel-edit-{turn}").into_boxed_str());
    let last_selector: &'static str = Box::leak(format!("queue-row-{last}").into_boxed_str());
    let owned_selector: &'static str = Box::leak(format!("queue-editing-{turn}").into_boxed_str());
    let primary_selector: &'static str =
        Box::leak(format!("queue-primary-{turn}").into_boxed_str());
    let preview_selector: &'static str =
        Box::leak(format!("queue-preview-{turn}").into_boxed_str());
    let actions_selector: &'static str =
        Box::leak(format!("queue-actions-{turn}").into_boxed_str());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for (width, height, split) in [
        (1180., 812., false),
        (920., 600., false),
        (1180., 812., true),
        (920., 600., true),
        (1180., 812., false),
    ] {
        root.update(cx, |v, cx| {
            v.show_files = split;
            v.layout.fraction = 0.5;
            v.queue_scroll.set_offset(point(px(0.), px(0.)));
            cx.notify();
        });
        visual.simulate_resize(size(px(width), px(height)));
        cx.run_until_parked();
        let list = root.update(cx, |v, _| v.queue_scroll.bounds());
        let row = visual.debug_bounds(row_selector).unwrap();
        let primary = visual.debug_bounds(primary_selector).unwrap();
        let preview = visual.debug_bounds(preview_selector).unwrap();
        let actions = visual.debug_bounds(actions_selector).unwrap();
        let (minimum_controls, preview_minimum) = window
            .update(cx, |v, window, _| {
                let state = v.queue_edit_row_state(&turn);
                let font = gpui::font(if cfg!(target_os = "macos") {
                    ".SystemUIFont"
                } else {
                    "DejaVu Sans"
                });
                let measure = |text: &str| {
                    f32::from(
                        window
                            .text_system()
                            .shape_line(
                                text.to_owned().into(),
                                px(13.),
                                &[gpui::TextRun {
                                    len: text.len(),
                                    font: font.clone(),
                                    color: gpui::black(),
                                    background_color: None,
                                    underline: None,
                                    strikethrough: None,
                                }],
                                None,
                            )
                            .width,
                    )
                    .ceil()
                };
                (
                    state.minimum_word_width(window),
                    measure("held") + measure("…"),
                )
            })
            .unwrap();
        assert!(
            f32::from(actions.size.width) - 30. + 0.5 >= minimum_controls,
            "whole labels must retain measured word minima"
        );
        assert!(
            f32::from(preview.size.width) + 0.5 >= preview_minimum,
            "preview cannot collapse to zero or a glyph column"
        );
        if split && width == 920. {
            assert!(
                actions.top() >= primary.bottom() + px(7.5),
                "only the constrained Held row flows controls below its readable preview"
            );
            assert!(row.size.height >= primary.size.height + actions.size.height + px(11.5));
        } else {
            assert!(
                (f32::from(actions.center().y - primary.center().y)).abs() <= 0.5,
                "wider rows retain the original single-line sequence"
            );
        }

        let resume = visual.debug_bounds(resume_selector).unwrap();
        let cancel = visual.debug_bounds(cancel_selector).unwrap();
        assert!(row.size.height >= px(30.));
        assert!(
            resume.left() >= list.left() && cancel.right() <= list.right() + px(0.5),
            "controls must fit normal supported split: list {list:?}, resume {resume:?}, cancel {cancel:?}"
        );
        assert!(resume.top() >= row.top() && resume.bottom() <= row.bottom() + px(0.5));
        assert!(cancel.top() >= row.top() && cancel.bottom() <= row.bottom() + px(0.5));
        root.update(cx, |v, cx| {
            v.queue_scroll.set_offset(point(px(0.), px(-10000.)));
            cx.notify();
        });
        cx.run_until_parked();
        let last_row = visual.debug_bounds(last_selector).unwrap();
        assert!(last_row.bottom() <= list.bottom() + px(0.5));
        assert!(last_row.top() < list.bottom());
    }
    // Same source body becomes owned; the status remains whole and the row
    // cannot shrink below its original30pt outer minimum.
    root.update(cx, |v, cx| {
        v.queue_scroll.set_offset(point(px(0.), px(0.)));
        cx.notify();
    });
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, Some("recovered-hold".into()), window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    let owned = visual.debug_bounds(owned_selector).unwrap();
    let row = visual.debug_bounds(row_selector).unwrap();
    assert!(owned.bottom() <= row.bottom() + px(0.5));
}

#[gpui::test]
fn queue_begin_success_preserves_newer_unrelated_and_other_turn_errors(cx: &mut TestAppContext) {
    for unrelated in [false, true] {
        let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
        window
            .update(cx, |v, window, cx| {
                v.chat.note_begin_failure(
                    if unrelated { &turn } else { "another-turn" },
                    "an earlier Begin error".into(),
                );
                v.begin_queued_edit(&id, &turn, None, window, cx);
                if unrelated {
                    v.error = Some("newer unrelated warning".into());
                }
            })
            .unwrap();
        cx.run_until_parked();
        root.update(cx, |v, cx| {
            assert!(v.editing.is_some());
            assert_eq!(v.composer.read(cx).text(), "queued");
            assert_eq!(
                v.error.as_deref(),
                Some(if unrelated {
                    "newer unrelated warning"
                } else {
                    "an earlier Begin error"
                })
            );
        });
    }
}

#[gpui::test]
fn queue_begin_old_failure_callback_and_wrong_controller_cannot_own_current_error(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.begin_queued_edit(&id, &turn, None, window, cx);
            let old = v.begin_operation.as_ref().unwrap().key.clone();
            v.cancel_held_edit(&id, &turn, &old.edit, cx);
            v.error = Some("newer unrelated warning".into());
            v.finish_begin_read(old, Err("delayed old Begin error".into()), cx);
            assert_eq!(v.error.as_deref(), Some("newer unrelated warning"));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, _| {
        assert_eq!(v.error.as_deref(), Some("newer unrelated warning"));
        v.chat
            .note_begin_failure(&turn, "old controller failure".into());
        let original = v.controller.clone();
        v.chat.controller =
            Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
        v.chat.clear_confirmed_begin_failure(&turn);
        assert_eq!(v.error.as_deref(), Some("old controller failure"));
        v.chat.controller = original;
    });
}

#[gpui::test]
fn queue_begin_single_flowed_hold_uses_measured_content_and_keeps_constrained_floor(
    cx: &mut TestAppContext,
) {
    use bello_agent_core::workspace::SubmissionIntent;
    use gpui::{VisualTestContext, point, px, size};
    let (_dir, window, root, id, turn) = fixture(cx, true, "held text".into(), 5);
    let row_selector: &'static str = Box::leak(format!("queue-row-{turn}").into_boxed_str());
    let actions_selector: &'static str =
        Box::leak(format!("queue-actions-{turn}").into_boxed_str());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    root.update(cx, |v, cx| {
        v.show_files = true;
        v.layout.fraction = 0.5;
        cx.notify();
    });
    visual.simulate_resize(size(px(920.), px(600.)));
    cx.run_until_parked();
    let row = visual.debug_bounds(row_selector).unwrap();
    let actions = visual.debug_bounds(actions_selector).unwrap();
    let list = root.update(cx, |v, _| v.queue_scroll.bounds());
    assert!(
        list.size.height > px(52.),
        "available room must show one grown row, not truncate it at the old 30pt estimate"
    );
    assert!((f32::from(list.size.height - row.size.height) - 22.).abs() <= 0.5);
    assert!(row.bottom() <= list.bottom() + px(0.5));
    assert!(actions.top() >= list.top() && actions.bottom() <= list.bottom() + px(0.5));
    root.update(cx, |v, cx| {
        v.composer.update(cx, |editor, cx| {
            editor.set_text("tall draft line 日本語\n".repeat(30), cx)
        });
        v.recoveries.insert(
            "fixture-intent".into(),
            SubmissionIntent {
                attachments: Vec::new(),
                id: "fixture-intent".into(),
                chat_id: id.clone(),
                text: "unconfirmed input ".repeat(20),
                lane: Lane::FollowUp,
                draft_revision: 1,
            },
        );
        cx.notify();
    });
    cx.run_until_parked();
    let floor = root.update(cx, |v, _| {
        assert!(v.queue_geometry.unwrap().room() <= 52.);
        v.queue_scroll.bounds()
    });
    assert_eq!(floor.size.height, px(52.));
    root.update(cx, |v, cx| {
        v.queue_scroll.set_offset(point(px(0.), px(-10000.)));
        cx.notify();
    });
    cx.run_until_parked();
    let actions = visual.debug_bounds(actions_selector).unwrap();
    assert!(
        actions.top() >= floor.top() - px(0.5) && actions.bottom() <= floor.bottom() + px(0.5),
        "the whole actionable line remains reachable by scrolling at the unchanged floor"
    );
}

#[gpui::test]
fn archived_begin_and_remove_callbacks_preserve_queue_and_composer(cx: &mut TestAppContext) {
    let (_dir, window, _root, id, turn) = fixture(cx, false, "queued full text".into(), 5);
    window
        .update(cx, |view, window, cx| {
            let draft = view.saved_draft(cx);
            let revision = view.controller.snapshot().revision;
            view.records
                .iter_mut()
                .find(|record| record.id == id)
                .unwrap()
                .archived_at = Some(1);
            assert!(matches!(
                view.queue_edit_row_state(&turn),
                QueueEditRowState::Available { enabled: false }
            ));
            view.begin_queued_edit(&id, &turn, None, window, cx);
            view.remove_queued_from_chat(&id, &turn, cx);
            assert!(view.begin_operation.is_none());
            assert!(view.queue_operation.is_none());
            assert_eq!(view.controller.snapshot().revision, revision);
            assert_eq!(view.saved_draft(cx), draft);
        })
        .unwrap();
}

#[gpui::test]
fn begin_deferred_token_allows_archive_without_consuming_marked_text(cx: &mut TestAppContext) {
    let (_dir, window, root, id, turn) = fixture(cx, false, "queued full text".into(), 5);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
            view.begin_queued_edit(&id, &turn, None, window, cx);
            assert!(view.archive_chat_work_live(&id));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let operation = view.begin_operation.as_ref().unwrap();
        assert!(operation.is_deferred());
        assert!(operation.owns_queue_token(view.queue_operation.unwrap()));
        assert!(!view.archive_chat_work_live(&id));
        assert!(view.composer.read(cx).has_marked_text());
        assert!(view.editing.is_none());
        let before = view.saved_draft(cx);
        let token = view.queue_operation;
        view.records
            .iter_mut()
            .find(|record| record.id == id)
            .unwrap()
            .archived_at = Some(1);
        view.resume_deferred_begin(&id, cx);
        assert_eq!(view.queue_operation, token);
        assert_eq!(view.saved_draft(cx), before);
    });
}

#[gpui::test]
fn archive_waits_for_controlled_begin_callback_and_drains_on_success_or_failure(
    cx: &mut TestAppContext,
) {
    for fails in [false, true] {
        let (_dir, window, root, id, turn) = fixture(cx, false, "queued full text".into(), 5);
        let mut key = None;
        let mut status = None;
        window
            .update(cx, |view, window, cx| {
                // The actor result is ready, but its exact foreground operation
                // remains admitted until the controlled completion is delivered.
                let edit = Uuid::new_v4().to_string();
                if !fails {
                    view.controller.begin_edit(&turn, &edit).unwrap();
                    status = Some(view.controller.edit_status(&edit).unwrap());
                }
                let operation_key = Key {
                    token: Uuid::new_v4(),
                    chat: id.clone(),
                    turn: turn.clone(),
                    edit,
                    project: view.project.clone(),
                    controller: view.controller.clone(),
                    binding: view.window_binding,
                    window: window.window_handle().downcast::<AgentView>().unwrap(),
                    focus: window.focused(cx),
                };
                view.queue_operation = Some(operation_key.token);
                view.edit_recovery = EditRecovery::new(true);
                view.begin_operation = Some(BeginOperation {
                    key: operation_key.clone(),
                    deferred: None,
                    recheck: false,
                });
                key = Some(operation_key);
                view.set_chat_archived(&id, true, cx);
                assert!(view.archive_chat_work_live(&id));
            })
            .unwrap();
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(!view.chat_is_archived(&id));
            assert!(view.has_pending_archive(&id));
            assert!(!view.organization_drain_scheduled);
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .chats
                    .iter()
                    .all(|record| record.archived_at.is_none())
            );
            let result = if fails {
                Err("controlled Begin callback failure".into())
            } else {
                Ok(status.take().unwrap())
            };
            view.finish_begin_read(key.take().unwrap(), result, cx);
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(view.chat_is_archived(&id));
            assert!(view.organization_operations.is_empty());
            assert!(!view.archive_chat_work_live(&id));
            assert!(view.begin_operation.is_none());
            assert_eq!(
                view.composer.read(cx).text(),
                if fails {
                    "ordinary é 日本語"
                } else {
                    "queued full text"
                }
            );
            assert_eq!(view.editing.is_some(), !fails);
        });
    }
}
