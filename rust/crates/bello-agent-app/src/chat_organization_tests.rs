//! Controlled foreground/real local catalog checks. No provider or native IME
//! guarantee is implied by the GPUI fake platform.
use super::CatalogOutcome;
use crate::AgentView;
use crate::{ChatState, LaunchState};
use bello_agent_core::workspace::ChatRecord;
use bello_agent_core::{
    Controller, Lane, SessionStore,
    workspace::{DraftRecord, WorkspaceStore},
};
use gpui::{Context, Entity, Window, WindowHandle};
use gpui::{EntityInputHandler, TestAppContext, VisualTestContext};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

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
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record: ChatRecord::new(snapshot.id, "First".into(), project.join("first.json")),
        draft: DraftRecord {
            skills: Vec::new(),
            attachments: Vec::new(),
            text: "retained draft 日本語".into(),
            ..Default::default()
        },
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let view = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, view)
}
fn id(view: &Entity<AgentView>, cx: &TestAppContext) -> String {
    cx.read(|cx| view.read(cx).record.id.clone())
}
fn second(
    view: &mut AgentView,
    title: &str,
    window: &mut Window,
    cx: &mut Context<AgentView>,
) -> String {
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    let id = controller.snapshot_shared().id.clone();
    let mut record = ChatRecord::new(
        id.clone(),
        title.into(),
        view.chat_directory.join(format!("{id}.json")),
    );
    record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
    let chat = ChatState::new(
        controller,
        crate::chat::ChatSource {
            record: record.clone(),
            workspace: view.workspace.clone(),
        },
        crate::chat::RestoredDraft {
            draft: DraftRecord {
                skills: Vec::new(),
                attachments: Vec::new(),
                text: format!("{title} draft"),
                ..Default::default()
            },
            cancellation: None,
        },
        true,
        view.palette,
        window,
        cx,
    );
    view.records.push(record);
    view.inactive.insert(id.clone(), chat);
    id
}

#[gpui::test]
fn archive_fifo_waits_for_live_work_without_polling_and_preserves_every_intent(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| {
            view.busy = true;
            view.set_chat_pinned(&first, true, cx);
            view.set_chat_archived(&first, true, cx);
            view.set_chat_archived(&first, false, cx);
            view.set_chat_pinned(&first, false, cx);
            assert_eq!(view.organization_operations[&first].intents.len(), 4);
            assert!(view.actor_mutation_blocked(&first));
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.record.pinned_at.is_some());
        assert!(view.record.archived_at.is_none());
        assert_eq!(view.organization_operations[&first].intents.len(), 3);
        assert!(!view.organization_drain_scheduled);
    });
    window
        .update(cx, |view, _, cx| {
            view.busy = false;
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.organization_operations.is_empty());
        assert!(!view.actor_mutation_blocked(&first));
        let state = view.workspace.lock().unwrap().snapshot();
        assert!(state.chats[0].pinned_at.is_none());
        assert!(state.chats[0].archived_at.is_none());
        assert_eq!(state.version, 11);
        assert_eq!(view.composer.read(cx).text(), "retained draft 日本語");
        assert!(!view.controller.is_persistent());
    });
}

#[gpui::test]
fn archive_waiting_target_does_not_block_other_chat_and_close_waits(cx: &mut TestAppContext) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let mut other = String::new();
    window
        .update(cx, |view, window, cx| {
            other = second(view, "Other", window, cx);
            view.busy = true;
            view.set_chat_archived(&first, true, cx);
            view.set_chat_archived(&other, true, cx);
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(!view.chat_is_archived(&first));
        assert!(view.chat_is_archived(&other));
        assert_eq!(view.organization_operations.len(), 1);
    });
    window
        .update(cx, |view, _, cx| {
            view.busy = false;
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| view.read(cx).organization_operations.is_empty()));
}

#[gpui::test]
fn archive_fallback_uses_source_active_order_outside_filter_and_restore_never_selects(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let mut candidate = String::new();
    window
        .update(cx, |view, window, cx| {
            candidate = second(view, "Hidden candidate", window, cx);
            view.filter.update(cx, |editor, cx| {
                editor.set_text("no matching rows".into(), cx)
            });
            view.set_chat_archived(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(id(&view, cx), candidate);
    window
        .update(cx, |view, _, cx| {
            assert!(view.chat_is_archived(&first));
            assert!(!view.effective_archive_visibility());
            view.set_chat_archived(&first, false, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(id(&view, cx), candidate);
    assert!(cx.read(|cx| !view.read(cx).chat_is_archived(&first)));
}

#[gpui::test]
fn archive_navigation_away_and_back_invalidates_original_capture(cx: &mut TestAppContext) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, window, cx| {
            let other = second(view, "Other", window, cx);
            view.busy = true;
            view.set_chat_archived(&first, true, cx);
            view.select_chat(&other, window, cx);
            view.select_chat(&first, window, cx);
            view.busy = false;
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(id(&view, cx), first);
    assert!(cx.read(|cx| view.read(cx).chat_is_archived(&first)));
}

#[gpui::test]
fn archive_generic_command_and_send_fenced_before_dispatch_without_freezing_typing(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let called = Arc::new(AtomicBool::new(false));
    window
        .update(cx, |view, _, cx| {
            view.loading = true;
            view.set_chat_archived(&first, true, cx);
            view.loading = false;
            let called = called.clone();
            view.command(
                cx,
                None,
                false,
                move |_| {
                    called.store(true, Ordering::SeqCst);
                    Ok(())
                },
                |_, (), _| {},
            );
            view.submit_chat(Lane::FollowUp, cx);
            assert!(!view.busy);
            assert!(view.inflight_submission.is_none());
            view.composer
                .update(cx, |editor, cx| editor.set_text("newer typing".into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    assert!(!called.load(Ordering::SeqCst));
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.chat_is_archived(&first));
        assert_eq!(view.composer.read(cx).text(), "newer typing");
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&first].text,
            "newer typing"
        );
    });
}

#[gpui::test]
fn archived_footer_retains_editor_and_marked_text_restore_returns_it_without_launch(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let editor = cx.read(|cx| view.read(cx).composer.clone());
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "marked 漢字", Some(2..2), window, cx)
            });
            view.set_chat_archived(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("archived-read-only-footer").is_some());
    // GPUI 0.2.2 retains debug_bounds from old frames. Measure the current
    // replacement footer, rather than treating that cache as a presence tree.
    let footer = visual.debug_bounds("archived-read-only-footer").unwrap();
    cx.read(|cx| {
        assert_eq!(
            view.read(cx).queue_geometry.unwrap().composer_height,
            f32::from(footer.size.height)
                + crate::queue_geometry::COMPOSER_TOP
                + crate::queue_geometry::COMPOSER_BOTTOM
        )
    });
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(view.composer, editor);
        assert!(view.composer.read(cx).has_marked_text());
        assert!(view.queue_geometry.unwrap().composer_height > 0.);
    });
    window
        .update(cx, |view, _, cx| view.set_chat_archived(&first, false, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(view.composer, editor);
        assert!(view.composer.read(cx).has_marked_text());
        assert!(!view.controller.is_persistent());
        assert!(view.session.messages.is_empty());
    });
}

#[gpui::test]
fn archive_failure_preserves_pending_draft_and_advances_later_valid_requests(
    cx: &mut TestAppContext,
) {
    let (dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    std::fs::create_dir(dir.path().join("catalog.json")).unwrap();
    window
        .update(cx, |view, _, cx| {
            view.set_chat_archived(&first, true, cx);
            view.set_chat_archived(&first, false, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.pending);
        assert!(!view.chat_is_archived(&first));
        assert!(view.organization_operations.is_empty());
        assert!(!view.known_catalog_uncertainty);
        assert_eq!(view.composer.read(cx).text(), "retained draft 日本語");
    });
    std::fs::remove_dir(dir.path().join("catalog.json")).unwrap();
    window
        .update(cx, |view, _, cx| view.set_chat_archived(&first, true, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| view.read(cx).chat_is_archived(&first)));
}

#[gpui::test]
fn archive_uncertainty_settles_successors_and_fences_actor_only_methods(cx: &mut TestAppContext) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| {
            view.loading = true;
            view.set_chat_archived(&first, true, cx);
            view.set_chat_archived(&first, false, cx);
            view.set_chat_pinned(&first, true, cx);
            let intent = view.organization_operations[&first]
                .intents
                .front()
                .unwrap()
                .clone();
            view.organization_operations
                .get_mut(&first)
                .unwrap()
                .intents
                .front_mut()
                .unwrap()
                .running = true;
            view.loading = false;
            // Same outcome shape also covers Invalid from an already-uncertain
            // catalog. Visibility stays active: no guessed durable archive state.
            view.finish_organization(
                &intent,
                CatalogOutcome {
                    result: Err(bello_agent_core::Error::Invalid("already uncertain".into())),
                    uncertain: true,
                },
                cx,
            );
            assert!(view.organization_operations.is_empty());
            assert_eq!(view.blocked_organization_count, 2);
            assert!(view.known_catalog_uncertainty);
            assert!(!view.chat_is_archived(&first));
            assert!(view.actor_mutation_blocked(&first));
            view.command(
                cx,
                None,
                false,
                |_| panic!("actor-only command escaped uncertainty"),
                |_, (): (), _| {},
            );
            view.submit_chat(Lane::FollowUp, cx);
            assert!(view.session.messages.is_empty());
            assert_eq!(view.composer.read(cx).text(), "retained draft 日本語");
        })
        .unwrap();
}

#[gpui::test]
fn archive_visibility_grouping_and_latest_revision_are_independent_of_navigation(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let mut other = String::new();
    window
        .update(cx, |view, window, cx| {
            other = second(view, "Other", window, cx);
            view.set_chat_archived(&other, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, _, cx| {
            assert_eq!(view.visible_sidebar_records(cx).len(), 1);
            view.launch_archive_reveal = true;
            assert_eq!(
                view.visible_sidebar_records(cx)
                    .iter()
                    .map(|r| r.id.clone())
                    .collect::<Vec<_>>(),
                vec![first.clone(), other.clone()]
            );
            view.set_archive_visibility(true, cx);
            view.set_archive_visibility(false, cx);
            view.set_archive_visibility(true, cx);
            assert!(!view.launch_archive_reveal);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(view.record.id, first);
        assert!(view.show_archived);
        assert_eq!(view.archive_visibility_writes, 0);
        let state = view.workspace.lock().unwrap().snapshot();
        assert!(state.show_archived);
        assert_eq!(state.archive_visibility_revision, 3);
    });
}

#[test]
fn archive_startup_remembers_archived_or_creates_distinct_pending_identity() {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let anchor = project.join("anchor.json");
    let mut workspace = WorkspaceStore::open(project.join("catalog.json"), &project).unwrap();
    let original = ChatRecord::new(
        uuid::Uuid::new_v4().to_string(),
        "Archived".into(),
        anchor.clone(),
    );
    workspace
        .set_archived(original.clone(), DraftRecord::default(), true, 1)
        .unwrap();
    let (_, fresh, pending) = crate::open_startup_chat(&mut workspace, &anchor).unwrap();
    assert!(pending);
    assert_ne!(fresh.id, original.id);
    assert_ne!(fresh.snapshot, original.snapshot);
    assert_eq!(workspace.snapshot().chats.len(), 1);
    workspace.select(&original.id, 1).unwrap();
    let (_, remembered, pending) = crate::open_startup_chat(&mut workspace, &anchor).unwrap();
    assert!(!pending);
    assert_eq!(remembered.id, original.id);
    assert!(remembered.archived_at.is_some());
    assert!(!workspace.snapshot().show_archived);
}

#[gpui::test]
fn archive_stable_load_failure_does_not_block_and_unloaded_fallback_keeps_draft(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    let bad = "not-a-uuid".to_owned();
    window
        .update(cx, |view, _, cx| {
            let record = ChatRecord::new(
                bad.clone(),
                "Invalid candidate".into(),
                view.chat_directory.join("invalid.json"),
            );
            view.records.push(record);
            view.unloaded_drafts.insert(
                bad.clone(),
                DraftRecord {
                    skills: Vec::new(),
                    attachments: Vec::new(),
                    text: "unloaded draft survives failed construction".into(),
                    ..Default::default()
                },
            );
            view.load_failed = true;
            view.set_chat_archived(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.chat_is_archived(&first));
        assert!(view.organization_operations.is_empty());
        assert_eq!(view.record.id, first);
        assert_eq!(
            view.unloaded_drafts[&bad].text,
            "unloaded draft survives failed construction"
        );
    });
}

#[gpui::test]
fn archive_commits_across_window_replacement_without_old_navigation_effect(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, window, cx| {
            second(view, "Other", window, cx);
            view.busy = true;
            view.set_chat_archived(&first, true, cx);
            view.window_binding = None;
            view.busy = false;
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.chat_is_archived(&first));
        assert_eq!(view.record.id, first);
        assert!(view.organization_operations.is_empty());
    });
}

#[gpui::test]
fn archive_repeat_does_not_move_selection_and_restore_failure_keeps_read_only(
    cx: &mut TestAppContext,
) {
    let (dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| view.set_chat_archived(&first, true, cx))
        .unwrap();
    cx.run_until_parked();
    let archived_at = cx.read(|cx| view.read(cx).record.archived_at);
    window
        .update(cx, |view, window, cx| {
            second(view, "Active candidate", window, cx);
            view.set_chat_archived(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(id(&view, cx), first);
    assert_eq!(cx.read(|cx| view.read(cx).record.archived_at), archived_at);
    // Replace only the test-owned catalog path with a directory to force a
    // certain pre-rename failure. No production recovery is simulated.
    std::fs::remove_file(dir.path().join("catalog.json")).unwrap();
    std::fs::create_dir(dir.path().join("catalog.json")).unwrap();
    window
        .update(cx, |view, _, cx| view.set_chat_archived(&first, false, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.actor_mutation_blocked(&first));
        assert!(view.record.archived_at.is_some());
        assert!(!view.known_catalog_uncertainty);
    });
}

#[gpui::test]
fn archive_saved_visibility_failure_is_reported_and_close_cannot_overtake_write(
    cx: &mut TestAppContext,
) {
    let (dir, window, view) = fixture(cx);
    std::fs::create_dir(dir.path().join("catalog.json")).unwrap();
    window
        .update(cx, |view, window, cx| {
            view.set_archive_visibility(true, cx);
            assert_eq!(view.archive_visibility_writes, 1);
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.show_archived);
        assert_eq!(view.archive_visibility_writes, 0);
        assert!(
            view.error
                .as_ref()
                .unwrap()
                .contains("Archive visibility could not be saved")
        );
        assert!(!view.workspace.lock().unwrap().snapshot().show_archived);
    });
}

#[test]
fn archive_uncertainty_notice_never_advises_reopen_or_restart() {
    for error in [
        bello_agent_core::Error::Invalid(
            "Workspace persistence is uncertain. Reopen before continuing.".into(),
        ),
        bello_agent_core::Error::PersistenceUncertain("directory sync".into()),
    ] {
        let message = super::catalog_error(&error, true);
        assert!(message.contains("unconfirmed"));
        assert!(message.contains("Live drafts"));
        assert!(!message.to_lowercase().contains("reopen"));
        assert!(!message.to_lowercase().contains("restart"));
    }
}

#[gpui::test]
fn archive_launch_reveal_is_transient_until_explicit_history_selection(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let mut store = WorkspaceStore::open(project.join("catalog.json"), &project).unwrap();
    let record = ChatRecord::new(
        uuid::Uuid::new_v4().to_string(),
        "Archived".into(),
        project.join("archived.json"),
    );
    let saved = store
        .set_archived(record, DraftRecord::default(), true, 1)
        .unwrap()
        .record;
    store.select(&saved.id, 1).unwrap();
    let controller =
        Controller::new(SessionStore::pending_with_id(&saved.id).unwrap(), None).unwrap();
    let launch = LaunchState {
        controller,
        project,
        workspace: Arc::new(Mutex::new(store)),
        record: saved.clone(),
        draft: DraftRecord::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.launch_archive_reveal);
        assert!(view.effective_archive_visibility());
        assert!(!view.show_archived);
        assert!(!view.workspace.lock().unwrap().snapshot().show_archived);
    });
    window
        .update(cx, |view, window, cx| {
            view.select_chat(&saved.id, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.launch_archive_reveal);
        assert!(view.show_archived);
        assert!(view.workspace.lock().unwrap().snapshot().show_archived);
        assert!(view.chat_is_archived(&saved.id));
    });
}

#[gpui::test]
fn archive_controller_load_never_replaces_current_organization_patch_in_either_order(
    cx: &mut TestAppContext,
) {
    for commit_first in [false, true] {
        let (_dir, window, view) = fixture(cx);
        let target = uuid::Uuid::new_v4().to_string();
        window
            .update(cx, |view, window, cx| {
                let path = view.chat_directory.join(format!("{target}.json"));
                let record = ChatRecord::new(target.clone(), "Unloaded target".into(), path);
                let draft = DraftRecord {
                    skills: Vec::new(),
                    attachments: Vec::new(),
                    text: "unloaded preserved".into(),
                    ..Default::default()
                };
                view.workspace
                    .lock()
                    .unwrap()
                    .register(record.clone(), draft.clone())
                    .unwrap();
                view.records.push(record.clone());
                view.unloaded_drafts.insert(target.clone(), draft.clone());
                view.set_chat_archived(&target, true, cx);
                if commit_first {
                    // Resolve a confirmed metadata write while a selected placeholder
                    // is still awaiting its generation-checked controller load.
                    view.organization_operations
                        .get_mut(&target)
                        .unwrap()
                        .intents
                        .front_mut()
                        .unwrap()
                        .running = true;
                    let intent = view.organization_operations[&target]
                        .intents
                        .front()
                        .unwrap()
                        .clone();
                    let change = view
                        .workspace
                        .lock()
                        .unwrap()
                        .set_archived(record, draft, true, 1)
                        .unwrap();
                    view.select_chat(&target, window, cx);
                    assert!(view.loading);
                    view.finish_organization(
                        &intent,
                        CatalogOutcome {
                            result: Ok((change.record, change.changed)),
                            uncertain: false,
                        },
                        cx,
                    );
                } else {
                    view.select_chat(&target, window, cx);
                }
            })
            .unwrap();
        cx.run_until_parked();
        cx.read(|cx| {
            let view = view.read(cx);
            assert!(view.chat_is_archived(&target));
            let chat = view.chat_ref(&target).unwrap();
            assert!(chat.record.archived_at.is_some());
            assert!(!chat.loading);
            assert_eq!(chat.composer.read(cx).text(), "unloaded preserved");
            assert!(view.organization_operations.is_empty());
        });
    }
}

#[gpui::test]
fn archive_waits_for_actual_rejected_send_and_second_draft_recovery_callback(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| {
            // No configured provider: this uses the real rejected-Send path and its
            // second catalog settlement callback, with no network request.
            view.submit_chat(Lane::FollowUp, cx);
            assert!(view.busy && view.inflight_submission.is_some());
            view.set_chat_archived(&first, true, cx);
            view.composer.update(cx, |editor, cx| {
                editor.set_text("newer while rejected Send settles".into(), cx)
            });
            assert!(view.archive_chat_work_live(&first));
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.chat_is_archived(&first));
        assert!(!view.busy);
        assert!(view.organization_operations.is_empty());
        assert!(view.recoveries.is_empty());
        assert_eq!(
            view.composer.read(cx).text(),
            "retained draft 日本語\n\nnewer while rejected Send settles"
        );
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&first].text,
            view.composer.read(cx).text()
        );
    });
}

#[gpui::test]
fn archive_waits_for_real_generic_retry_failure_without_erasing_that_error(
    cx: &mut TestAppContext,
) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| {
            view.command(
                cx,
                None,
                false,
                |controller| controller.retry(),
                |_, (), _| {},
            );
            assert!(view.busy);
            view.set_chat_archived(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.chat_is_archived(&first));
        assert!(view.error.as_ref().unwrap().contains("No connection"));
        assert!(!view.busy);
        assert!(view.organization_operations.is_empty());
    });
}

#[gpui::test]
fn successful_pin_cannot_clear_failed_archive_for_same_target(cx: &mut TestAppContext) {
    let (_dir, window, view) = fixture(cx);
    let first = id(&view, cx);
    window
        .update(cx, |view, _, cx| {
            view.set_chat_archived(&first, true, cx);
            let intent = view.organization_operations[&first]
                .intents
                .front()
                .unwrap()
                .clone();
            view.finish_organization(
                &intent,
                CatalogOutcome {
                    result: Err(bello_agent_core::Error::Invalid("archive failed".into())),
                    uncertain: false,
                },
                cx,
            );
            assert!(view.error.as_ref().unwrap().contains("archive failed"));
            view.set_chat_pinned(&first, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| {
        view.read(cx)
            .error
            .as_ref()
            .unwrap()
            .contains("archive failed")
    }));
    window
        .update(cx, |view, _, cx| view.set_chat_archived(&first, true, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| view.read(cx).error.is_none()));
}

#[gpui::test]
fn archive_visibility_retry_clears_only_its_owned_warning(cx: &mut TestAppContext) {
    for unrelated in [false, true] {
        let (dir, window, view) = fixture(cx);
        let collision = dir.path().join("catalog.json");
        std::fs::create_dir(&collision).unwrap();
        window
            .update(cx, |view, _, cx| view.set_archive_visibility(true, cx))
            .unwrap();
        cx.run_until_parked();
        assert!(cx.read(|cx| {
            view.read(cx)
                .error
                .as_ref()
                .unwrap()
                .contains("Archive visibility could not be saved")
        }));
        std::fs::remove_dir(&collision).unwrap();
        window
            .update(cx, |view, _, cx| {
                if unrelated {
                    view.error = Some("unrelated newer error".into());
                }
                view.set_archive_visibility(true, cx);
            })
            .unwrap();
        cx.run_until_parked();
        cx.read(|cx| {
            let view = view.read(cx);
            assert!(view.workspace.lock().unwrap().snapshot().show_archived);
            assert_eq!(
                view.error.as_deref(),
                unrelated.then_some("unrelated newer error")
            );
        });
    }
}
