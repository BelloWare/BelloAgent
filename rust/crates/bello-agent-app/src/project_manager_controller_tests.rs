//! Real AgentView ownership/admission tests, using only synthetic authority.
//! The fake platform cannot open a native folder panel: picker completion is
//! delivered through the same guarded callback used by the real panel.
use super::{Availability, Intent, LaunchProjectAuthority, ProjectFolderTarget, Stage};
use crate::{
    AgentView, LaunchState,
    project_host::{ChangedProject, Replacement},
};
use bello_agent_core::{
    Controller, RunState, SessionStore,
    project_authority::{AuthorityError, ProjectAuthority, synthetic::SyntheticAuthorityControl},
    workspace::{ChatRecord, ChatToolMode, DraftRecord, WorkspaceStore},
};
use gpui::{Context, Entity, Focusable, TestAppContext, Window, WindowHandle};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use uuid::Uuid;

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    SyntheticAuthorityControl,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    cx.update(|cx| {
        cx.set_global(LaunchProjectAuthority {
            authority: Arc::new(authority),
            mode: crate::launch_authority::AuthorityMode::Fixture,
        })
    });
    let store = SessionStore::pending();
    let record = ChatRecord::new(
        store.snapshot().id,
        "Original".into(),
        project.join("chat.json"),
    );
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record,
        draft: DraftRecord {
            skills: Vec::new(),
            attachments: Vec::new(),
            text: "retained composer 日本語".into(),
            ..Default::default()
        },
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| view.open_projects(window, cx))
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| root.read(cx).projects.presentation.availability.clone()),
        Availability::Ready
    );
    (dir, window, root, control)
}

fn intent(view: &mut AgentView, action: Intent, window: &mut Window, cx: &mut Context<AgentView>) {
    view.project_intent(view.projects.presentation.revision, action, window, cx);
}

fn prepare_read_only_chat(window: WindowHandle<AgentView>, cx: &mut TestAppContext) -> String {
    window
        .update(cx, |view, window, cx| {
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx));
            view.projects_dismissed(window, cx);
            view.controller.materialize(&view.record.snapshot).unwrap();
            view.record.materialization =
                bello_agent_core::workspace::ChatMaterialization::CheckpointRequired;
            view.pending = false;
            view.record.tool_mode = ChatToolMode::ReadOnly;
            let record = view.record.clone();
            view.records
                .iter_mut()
                .find(|chat| chat.id == record.id)
                .unwrap()
                .tool_mode = ChatToolMode::ReadOnly;
            view.workspace
                .lock()
                .unwrap()
                .register(record.clone(), view.saved_draft(cx))
                .unwrap();
            assert_eq!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .chats
                    .iter()
                    .find(|chat| chat.id == record.id)
                    .unwrap()
                    .tool_mode,
                ChatToolMode::ReadOnly,
            );
            record.id
        })
        .unwrap()
}

#[gpui::test]
async fn confirmed_mode_change_only_fences_target_and_preserves_navigation_drafts_and_projects(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root, _) = fixture(cx);
    let id = prepare_read_only_chat(window, cx);
    let old = cx.read(|cx| root.read(cx).controller.clone());
    let old_source = Arc::downgrade(&old);
    let mut late_snapshot = old.snapshot();
    late_snapshot.title = "stale retired publication".into();
    late_snapshot.revision += 100;
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    let selected = window
        .update(cx, |view, window, cx| {
            view.projects.presentation.stage = Stage::TrustDraft {
                kind: crate::project_manager_view::ProjectTrustKind::Create,
                extras: vec![view.project.join("reviewed draft folder")],
            };
            let revision = view.projects.presentation.revision;
            view.enable_chat_editing_after_confirmation(&id, cx);
            assert!(view.chat_mode_operations.contains_key(&id));
            assert!(view.actor_mutation_blocked(&id));
            assert!(view.loading);
            assert!(!view.request_close(window, cx));
            assert!(view.project_idle_error().is_some());
            view.new_chat(window, cx);
            assert_ne!(view.record.id, id);
            assert!(!view.actor_mutation_blocked(&view.record.id));
            assert_eq!(view.projects.presentation.revision, revision);
            view.record.id.clone()
        })
        .unwrap();
    cx.condition(&root, |view, _| view.chat_mode_operations.is_empty())
        .await;
    window.update(cx, |view, _, cx| {
        assert_eq!(view.record.id, selected);
        let chat = view.chat_ref(&id).unwrap();
        assert_eq!(chat.record.tool_mode, ChatToolMode::Editing);
        assert_eq!(chat.composer.entity_id(), composer.entity_id());
        assert_eq!(chat.composer.read(cx).text(), "retained composer 日本語");
            assert!(!chat.loading);
            assert_ne!(chat.error.as_deref(), Some("Wait for the chat tool mode change to finish before closing."));
            assert!(!view.actor_mutation_blocked(&id));
        assert!(matches!(&view.projects.presentation.stage, Stage::TrustDraft { extras, .. } if extras == &[view.project.join("reviewed draft folder")]));
        let current = chat.controller.clone();
        view.receive_snapshot(&id, &old_source, Arc::new(late_snapshot), cx);
        assert!(Arc::ptr_eq(&view.chat_ref(&id).unwrap().controller, &current));
        assert_ne!(view.chat_ref(&id).unwrap().session.title, "stale retired publication");
    }).unwrap();
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
}

#[gpui::test]
fn stale_mode_completion_cannot_publish_over_newer_operation_or_runtime(cx: &mut TestAppContext) {
    let (_directory, window, _, _) = fixture(cx);
    let id = prepare_read_only_chat(window, cx);
    window
        .update(cx, |view, _, cx| {
            let old = view.controller.clone();
            let operation = Uuid::new_v4();
            let newer = Uuid::new_v4();
            view.chat_mode_operations.insert(id.clone(), newer);
            view.chat_mode_blocked.insert(id.clone());
            let mut record = view.record.clone();
            record.tool_mode = ChatToolMode::Editing;
            let result = crate::chat_tool_mode::ChangedChatMode {
                record: record.clone(),
                replacement: None,
            };
            view.finish_chat_mode_change(
                operation,
                (&view.project.clone(), &view.workspace.clone()),
                &id,
                Some(old.clone()),
                Ok(result),
                cx,
            );
            assert_eq!(view.chat_mode_operations.get(&id), Some(&newer));
            assert_eq!(view.record.tool_mode, ChatToolMode::ReadOnly);
            let other = Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
            view.finish_chat_mode_change(
                newer,
                (&view.project.clone(), &view.workspace.clone()),
                &id,
                Some(other),
                Ok(crate::chat_tool_mode::ChangedChatMode {
                    record,
                    replacement: None,
                }),
                cx,
            );
            assert_eq!(view.record.tool_mode, ChatToolMode::ReadOnly);
            assert!(Arc::ptr_eq(&view.controller, &old));
            assert!(view.chat_mode_blocked.contains(&id));
        })
        .unwrap();
}

#[gpui::test]
async fn unloaded_mode_target_cannot_acquire_a_placeholder_or_archive_during_save(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root, _) = fixture(cx);
    let id = prepare_read_only_chat(window, cx);
    window
        .update(cx, |view, window, cx| {
            view.new_chat(window, cx);
            let selected = view.record.id.clone();
            assert_ne!(selected, id);
            drop(view.inactive.remove(&id).unwrap());
            view.enable_chat_editing_after_confirmation(&id, cx);
            assert!(view.chat_mode_operations.contains_key(&id));
            view.select_chat(&id, window, cx);
            assert_eq!(view.record.id, selected);
            assert!(view.chat_ref(&id).is_none());
            view.set_chat_pinned(&id, true, cx);
            view.set_chat_archived(&id, true, cx);
            assert!(!view.organization_operations.contains_key(&id));
            assert!(!view.actor_mutation_blocked(&selected));
        })
        .unwrap();
    cx.condition(&root, |view, _| view.chat_mode_operations.is_empty())
        .await;
    window
        .update(cx, |view, window, cx| {
            assert!(!view.chat_mode_blocked.contains(&id));
            let record = view.records.iter().find(|record| record.id == id).unwrap();
            assert_eq!(record.tool_mode, ChatToolMode::Editing);
            assert!(record.archived_at.is_none() && record.pinned_at.is_none());
            view.select_chat(&id, window, cx);
            assert_eq!(view.record.id, id);
        })
        .unwrap();
    cx.condition(&root, |view, _| !view.loading).await;
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.chat_mode_blocked.contains(&id));
        assert_eq!(view.record.tool_mode, ChatToolMode::Editing);
        assert!(!view.load_failed);
    });
}

#[gpui::test]
fn stale_mode_uncertainty_blocks_only_the_originating_workspace(cx: &mut TestAppContext) {
    for stale_token in [true, false] {
        let (_directory, window, _, _) = fixture(cx);
        let id = prepare_read_only_chat(window, cx);
        window
            .update(cx, |view, _, cx| {
                let operation = Uuid::new_v4();
                let newer = if stale_token {
                    Uuid::new_v4()
                } else {
                    operation
                };
                view.chat_mode_operations.insert(id.clone(), newer);
                view.chat_mode_blocked.insert(id.clone());
                let previous =
                    Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
                let failure = || crate::chat_tool_mode::ChatModeFailure {
                    message: "unconfirmed catalog write".into(),
                    keep_blocked: true,
                    uncertain: true,
                    recovery: None,
                };
                let foreign = Arc::new(Mutex::new(
                    WorkspaceStore::open(view.project.join("other-catalog.json"), &view.project)
                        .unwrap(),
                ));
                view.finish_chat_mode_change(
                    operation,
                    (&view.project.clone(), &foreign),
                    &id,
                    Some(previous.clone()),
                    Err(failure()),
                    cx,
                );
                assert!(!view.known_catalog_uncertainty);
                view.finish_chat_mode_change(
                    operation,
                    (
                        &view.project.join("different-root"),
                        &view.workspace.clone(),
                    ),
                    &id,
                    Some(previous.clone()),
                    Err(failure()),
                    cx,
                );
                assert!(!view.known_catalog_uncertainty);
                view.finish_chat_mode_change(
                    operation,
                    (&view.project.clone(), &view.workspace.clone()),
                    &id,
                    Some(previous),
                    Err(failure()),
                    cx,
                );
                assert!(view.known_catalog_uncertainty);
                assert_eq!(view.record.tool_mode, ChatToolMode::ReadOnly);
                assert!(view.chat_mode_blocked.contains(&id));
                if stale_token {
                    assert_eq!(view.chat_mode_operations.get(&id), Some(&newer));
                }
            })
            .unwrap();
    }
}

#[gpui::test]
fn rejected_intents_cancel_and_picker_cancellation_consume_revision_without_authority(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, control) = fixture(cx);
    window.update(cx, |view, window, cx| {
        let old = view.projects.presentation.revision;
        view.project_intent(old - 1, Intent::BeginCreate, window, cx);
        assert!(view.projects.presentation.revision > old);
        assert_eq!(view.projects.presentation.stage, Stage::Current);
        intent(view, Intent::BeginCreate, window, cx);
        let extra = view.project.join("extra");
        std::fs::create_dir(&extra).unwrap();
        let token = Uuid::new_v4();
        view.projects.picker = Some(token);
        view.finish_project_picker(token, view.window_binding, view.project.clone(), ProjectFolderTarget::Draft, Ok(Some(vec![extra.clone()])), cx);
        assert!(matches!(&view.projects.presentation.stage, Stage::TrustDraft { extras, .. } if extras == &[extra]));
        let token = Uuid::new_v4();
        let revision = view.projects.presentation.revision;
        view.projects.picker = Some(token);
        view.projects.presentation.availability = Availability::Busy("picker".into());
        view.finish_project_picker(token, view.window_binding, view.project.clone(), ProjectFolderTarget::Draft, Ok(None), cx);
        assert!(view.projects.presentation.revision > revision);
        assert_eq!(view.projects.presentation.availability, Availability::Ready);
        intent(view, Intent::CancelDraft, window, cx);
        assert_eq!(view.projects.presentation.stage, Stage::Current);
    }).unwrap();
    cx.run_until_parked();
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        "retained composer 日本語"
    );
}

#[gpui::test]
fn failed_save_preserves_draft_and_current_controller_for_explicit_retry(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    let old = cx.read(|cx| root.read(cx).controller.clone());
    control.fail_next_write(AuthorityError::Denied).unwrap();
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_some());
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.projects.operation.is_none());
        assert!(!view.projects.admission_blocked);
        assert!(matches!(
            view.projects.presentation.stage,
            Stage::TrustDraft { .. }
        ));
        assert!(view.projects.presentation.notice.as_ref().unwrap().is_error);
        assert!(Arc::ptr_eq(&old, &view.controller));
        assert_eq!(view.composer.read(cx).text(), "retained composer 日本語");
    });
    drop(old.suspend_idle_admission().unwrap());
    assert!(control.snapshot_bytes().unwrap().is_none());
}

#[gpui::test]
async fn saving_blocks_all_admission_and_close_before_the_worker_runs(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    let old = cx.read(|cx| root.read(cx).controller.clone());
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    let gate = control.pause_next_write().unwrap();
    let check = old.clone();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        assert!(check.suspend_idle_admission().is_err());
        gate.release();
    });
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
            let operation = view.projects.operation;
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx));
            view.projects_dismissed(window, cx);
            assert!(!view.projects.open);
            let id = view.record.id.clone();
            let generation = view.navigation_generation;
            view.new_chat(window, cx);
            view.submit_chat(crate::Lane::FollowUp, cx);
            view.set_chat_pinned(&id, true, cx);
            view.load_chat(&id, cx);
            view.begin_shutdown(window, cx);
            assert!(!view.request_close(window, cx));
            assert!(!view.shutting_down && !view.close_ready && !view.loading && !view.busy);
            assert_eq!(view.record.id, id);
            assert_eq!(view.navigation_generation, generation);
            assert!(view.organization_operations.is_empty());
            assert_eq!(view.projects.operation, operation);
        })
        .unwrap();
    cx.condition(&root, |view, _| view.projects.operation.is_none())
        .await;
    observer.join().unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.projects.admission_blocked);
        assert!(!Arc::ptr_eq(&old, &view.controller));
        assert_eq!(view.composer.entity_id(), composer.entity_id());
        assert_eq!(view.composer.read(cx).text(), "retained composer 日本語");
        assert!(view.projects.presentation.trusted);
        assert_eq!(view.session.state, RunState::Idle);
    });
    assert!(old.is_retired());
    assert!(control.snapshot_bytes().unwrap().is_some());
}

#[gpui::test]
fn active_inactive_and_recovery_state_refuse_before_save(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            view.busy = true;
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_none());
            view.busy = false;
            let controller = Controller::new(SessionStore::pending(), None).unwrap();
            let record = ChatRecord::new(
                controller.snapshot_shared().id.clone(),
                "Inactive".into(),
                view.project.join("inactive.json"),
            );
            let mut chat = crate::ChatState::new(
                controller,
                crate::chat::ChatSource {
                    record: record.clone(),
                    workspace: view.workspace.clone(),
                },
                crate::chat::RestoredDraft {
                    draft: DraftRecord::default(),
                    cancellation: None,
                },
                true,
                view.palette,
                window,
                cx,
            );
            chat.edit_recovery.blocked = true;
            view.records.push(record.clone());
            view.inactive.insert(record.id, chat);
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_none());
            assert!(
                view.projects
                    .presentation
                    .notice
                    .as_ref()
                    .unwrap()
                    .text
                    .contains("Inactive")
            );
        })
        .unwrap();
    cx.run_until_parked();
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(!cx.read(|cx| root.read(cx).projects.admission_blocked));
}

#[gpui::test]
fn unconfirmed_save_retains_fence_across_reload_and_dismissal(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    let old = cx.read(|cx| root.read(cx).controller.clone());
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(matches!(
                view.projects.presentation.availability,
                Availability::Unconfirmed(_)
            ));
            assert!(view.projects.admission_blocked);
            intent(view, Intent::Reload, window, cx);
            assert!(view.projects.load.is_some());
        })
        .unwrap();
    let bytes = control.snapshot_bytes().unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.projects.load.is_none());
            assert!(view.projects.admission_blocked);
            assert!(matches!(
                view.projects.presentation.availability,
                Availability::Unconfirmed(_)
            ));
            assert!(!view.projects.presentation.trusted);
            assert!(matches!(
                view.projects.presentation.stage,
                Stage::TrustDraft { .. }
            ));
            assert_eq!(view.projects.baseline.as_ref().unwrap().revision(), 1);
            assert!(Arc::ptr_eq(&old, &view.controller));
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_none());
            intent(view, Intent::CancelDraft, window, cx);
            assert_eq!(view.projects.presentation.stage, Stage::Current);
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx));
            view.controller.stop().unwrap();
        })
        .unwrap();
    assert_eq!(control.snapshot_bytes().unwrap(), bytes);
    cx.run_until_parked();
    assert!(cx.read(|cx| {
        root.read(cx)
            .actor_mutation_blocked(&root.read(cx).record.id)
    }));
}

#[gpui::test]
fn stale_picker_window_and_replaced_runtime_cannot_redirect_results(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    window.update(cx, |view, window, cx| {
        intent(view, Intent::BeginCreate, window, cx);
        let binding = view.window_binding;
        let token = Uuid::new_v4();
        view.projects.picker = Some(token);
        view.bind_window(window, cx);
        let revision = view.projects.presentation.revision;
        view.finish_project_picker(token, binding, view.project.clone(), ProjectFolderTarget::Draft, Ok(Some(vec![view.project.join("stale")])), cx);
        assert_eq!(view.projects.presentation.revision, revision);
        assert!(matches!(&view.projects.presentation.stage, Stage::TrustDraft { extras, .. } if extras.is_empty()));
        let operation = Uuid::new_v4();
        view.projects.operation = Some(operation);
        view.projects.admission_blocked = true;
        let baseline = view.projects.baseline.clone().unwrap();
        let mut draft = baseline.edit();
        let project = draft.trust_project(&Uuid::new_v4().to_string(), &view.project, &[]).unwrap();
        let expected = Controller::new(SessionStore::pending_with_id(&view.record.id).unwrap(), None).unwrap();
        let candidate = Controller::new(SessionStore::pending_with_id(&view.record.id).unwrap(), None).unwrap();
        let before = view.controller.clone();
        let result = ChangedProject { loaded: baseline, project, replacements: vec![Replacement { id: view.record.id.clone(), previous: expected, controller: candidate }] };
        view.finish_project_change(operation, &view.project.clone(), Ok(result), cx);
        assert!(Arc::ptr_eq(&before, &view.controller));
        assert!(view.projects.admission_blocked);
    }).unwrap();
    cx.run_until_parked();
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(!cx.read(|cx| root.read(cx).projects.presentation.trusted));
}

#[gpui::test]
fn modal_keys_and_newer_focus_never_reach_or_reclaim_composer(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    cx.simulate_keystrokes(window.into(), "cmd-n cmd-p enter");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, id);
        assert!(!view.quick_open.read(cx).is_open());
        assert!(view.controller.snapshot_shared().pending.is_empty());
        assert!(!view.busy);
    });
    window
        .update(cx, |view, window, cx| {
            view.filter.read(cx).focus(window);
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.filter.read(cx).focus_handle(cx).is_focused(window));
            assert!(!view.projects.open);
        })
        .unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}

#[gpui::test]
fn production_authority_surface_is_unavailable_even_with_synthetic_feature(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, control) = fixture(cx);
    root.update(cx, |view, cx| {
        view.projects.authority = Arc::new(ProjectAuthority::new());
        view.reload_projects(cx);
    });
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(matches!(
                view.projects.presentation.availability,
                Availability::Unavailable(_)
            ));
            intent(view, Intent::BeginCreate, window, cx);
            assert_eq!(view.projects.presentation.stage, Stage::Current);
            assert!(view.projects.operation.is_none());
        })
        .unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}

#[gpui::test]
fn late_authority_read_from_old_window_cannot_publish(cx: &mut TestAppContext) {
    let (_dir, window, root, control) = fixture(cx);
    control
        .replace_bytes(Some(br#"{"revision":7,"workspaces":[]}"#.to_vec()))
        .unwrap();
    let revision = window
        .update(cx, |view, window, cx| {
            view.reload_projects(cx);
            assert!(view.projects.load.is_some());
            view.bind_window(window, cx);
            assert!(view.projects.load.is_none());
            view.projects.presentation.revision
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.projects.presentation.revision, revision);
        assert_eq!(view.projects.baseline.as_ref().unwrap().revision(), 0);
    });
}

async fn retiring_tool_focus_case(cx: &mut TestAppContext, dismiss_early: bool, newer_file: bool) {
    use bello_agent_core::{
        Message,
        provider::ToolCall,
        tool_history::{
            AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
        },
    };
    let (dir, window, root, control) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx))
        })
        .unwrap();
    cx.run_until_parked();
    let assistant = Message {
        task_root_id: None,
        user_content: None,
        id: "assistant-tool".into(),
        role: "assistant".into(),
        text: String::new(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: serde_json::Value::Null,
        model: None,
        compaction: None,
        tool_record: Some(ToolRecord::Assistant(AssistantRecord {
            tool_batch_timing: None,
            completion: Completion::Complete,
            calls: vec![ToolCall {
                id: "tool-call".into(),
                name: "ls".into(),
                arguments: serde_json::json!({"path":"."}),
            }],
            binding: ReplayBinding {
                profile_id: "fixture".into(),
                api: "openai-responses".into(),
                provider: "litellm".into(),
                model: "fixture".into(),
                endpoint_sha256: "0".repeat(64),
            },
            provider_items: Vec::new(),
        })),
    };
    let result = Message {
        task_root_id: None,
        user_content: None,
        id: "result-tool".into(),
        role: "toolResult".into(),
        text: "selectable output".into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: serde_json::Value::Null,
        model: None,
        compaction: None,
        tool_record: Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: assistant.id.clone(),
            call_id: "tool-call".into(),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: None,
        })),
    };
    root.update(cx, |view, cx| {
        Arc::make_mut(&mut view.session).messages = vec![assistant, result];
        cx.notify();
    });
    cx.run_until_parked();
    if newer_file {
        let path = dir.path().join("focus.txt");
        std::fs::write(&path, "newer file editor").unwrap();
        window
            .update(cx, |view, window, cx| {
                view.open_file(path, None, window, cx)
            })
            .unwrap();
        cx.run_until_parked();
    }
    let old_editor = cx.read(|cx| {
        root.read(cx)
            .transcript
            .as_ref()
            .unwrap()
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(section, _)| *section == "OUT")
            .unwrap()
            .1
    });
    window
        .update(cx, |view, window, cx| {
            old_editor.read(cx).focus(window);
            view.open_projects(window, cx);
            assert!(view.projects.focus.as_ref().unwrap().tool.is_some());
        })
        .unwrap();
    cx.run_until_parked();
    let gate = control.pause_next_write().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        gate.release();
    });
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_some());
            if dismiss_early {
                view.projects
                    .view
                    .update(cx, |view, cx| view.close(true, window, cx));
                view.projects_dismissed(window, cx);
                assert!(view.projects.focus.is_none());
                assert!(old_editor.read(cx).focus_handle(cx).is_focused(window));
                if newer_file {
                    view.files[0].view.read(cx).focus(window, cx);
                }
            }
        })
        .unwrap();
    cx.condition(&root, |view, _| view.projects.operation.is_none())
        .await;
    observer.join().unwrap();
    cx.run_until_parked();
    if !dismiss_early {
        window
            .update(cx, |view, window, cx| {
                view.projects
                    .view
                    .update(cx, |view, cx| view.close(true, window, cx))
            })
            .unwrap();
    }
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            if newer_file {
                assert!(
                    view.files[0]
                        .view
                        .read(cx)
                        .has_focused_editable_text(window, cx)
                );
            } else {
                assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            }
            assert!(!old_editor.read(cx).focus_handle(cx).is_focused(window));
        })
        .unwrap();
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(cx.read(|cx| root.read(cx).changes_open));
}

#[gpui::test]
async fn dismiss_after_retirement_routes_old_tool_editor_focus_to_current_composer(
    cx: &mut TestAppContext,
) {
    retiring_tool_focus_case(cx, false, false).await;
}

#[gpui::test]
async fn dismiss_before_delayed_retirement_repairs_old_tool_editor_focus(cx: &mut TestAppContext) {
    retiring_tool_focus_case(cx, true, false).await;
}

#[gpui::test]
async fn dismiss_before_delayed_retirement_preserves_newer_file_focus(cx: &mut TestAppContext) {
    retiring_tool_focus_case(cx, true, true).await;
}

#[gpui::test]
async fn completed_save_preserves_both_chat_drafts_after_newer_selection(cx: &mut TestAppContext) {
    let (_dir, window, root, _control) = fixture(cx);
    let (first_id, first, first_composer, second_id, second, second_composer) = window
        .update(cx, |view, window, cx| {
            let first_id = view.record.id.clone();
            let first = view.controller.clone();
            let first_composer = view.composer.clone();
            let second = Controller::new(SessionStore::pending(), None).unwrap();
            let second_id = second.snapshot_shared().id.clone();
            let mut record = ChatRecord::new(
                second_id.clone(),
                "Second".into(),
                view.project.join("second.json"),
            );
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
            let chat = crate::ChatState::new(
                second.clone(),
                crate::chat::ChatSource {
                    record: record.clone(),
                    workspace: view.workspace.clone(),
                },
                crate::chat::RestoredDraft {
                    draft: DraftRecord {
                        skills: Vec::new(),
                        attachments: Vec::new(),
                        text: "second composer".into(),
                        ..Default::default()
                    },
                    cancellation: None,
                },
                true,
                view.palette,
                window,
                cx,
            );
            let second_composer = chat.composer.clone();
            view.records.push(record);
            view.inactive.insert(second_id.clone(), chat);
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
            assert!(view.projects.operation.is_some());
            // A newer owning callback can change selection after the worker has
            // captured its targets. Completion still belongs to both original IDs.
            let newer = view.inactive.remove(&second_id).unwrap();
            view.install_chat(newer, window, cx);
            (
                first_id,
                first,
                first_composer,
                second_id,
                second,
                second_composer,
            )
        })
        .unwrap();
    cx.condition(&root, |view, _| view.projects.operation.is_none())
        .await;
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.projects.admission_blocked);
        assert_eq!(view.record.id, second_id);
        assert!(!Arc::ptr_eq(&view.controller, &second));
        assert!(!Arc::ptr_eq(&view.inactive[&first_id].controller, &first));
        assert_eq!(view.composer.entity_id(), second_composer.entity_id());
        assert_eq!(
            view.inactive[&first_id].composer.entity_id(),
            first_composer.entity_id()
        );
        assert_eq!(view.composer.read(cx).text(), "second composer");
        assert_eq!(
            view.inactive[&first_id].composer.read(cx).text(),
            "retained composer 日本語"
        );
        assert!(view.session.pending.is_empty());
        assert!(view.inactive[&first_id].session.pending.is_empty());
    });
    assert!(first.is_retired() && second.is_retired());
}

fn interrupted_reload_case(cx: &mut TestAppContext, blocked: bool, rebind: bool) {
    let (_dir, window, root, control) = fixture(cx);
    if blocked {
        control
            .fail_next_write(AuthorityError::Unconfirmed)
            .unwrap();
        window
            .update(cx, |view, window, cx| {
                intent(view, Intent::BeginCreate, window, cx);
                intent(view, Intent::ConfirmTrust, window, cx);
            })
            .unwrap();
        cx.run_until_parked();
    }
    let previous = cx.read(|cx| root.read(cx).projects.presentation.availability.clone());
    let stage = cx.read(|cx| root.read(cx).projects.presentation.stage.clone());
    let baseline_revision =
        cx.read(|cx| root.read(cx).projects.baseline.as_ref().unwrap().revision());
    let gate = control.pause_next_read().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        gate.release();
    });
    let cancelled_revision = window
        .update(cx, |view, window, cx| {
            intent(view, Intent::Reload, window, cx);
            assert_eq!(
                view.projects.presentation.availability,
                Availability::Loading
            );
            assert!(view.projects.load.is_some());
            if rebind {
                view.bind_window(window, cx);
            } else {
                view.projects
                    .view
                    .update(cx, |view, cx| view.close(true, window, cx));
                view.projects_dismissed(window, cx);
            }
            assert!(view.projects.load.is_none());
            assert_eq!(view.projects.presentation.availability, previous);
            assert_eq!(view.projects.presentation.stage, stage);
            view.projects.presentation.revision
        })
        .unwrap();
    cx.run_until_parked();
    observer.join().unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.projects.presentation.revision, cancelled_revision);
        assert_eq!(view.projects.presentation.availability, previous);
        assert_eq!(
            view.projects.baseline.as_ref().unwrap().revision(),
            baseline_revision
        );
    });
    window
        .update(cx, |view, window, cx| view.open_projects(window, cx))
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.projects.presentation.availability, previous);
            assert_eq!(view.projects.presentation.stage, stage);
            assert!(view.projects.presentation.allows(&Intent::Reload));
            assert_eq!(view.projects.admission_blocked, blocked);
            if blocked {
                assert!(view.projects.presentation.allows(&Intent::CancelDraft));
                intent(view, Intent::Reload, window, cx);
            }
        })
        .unwrap();
    cx.run_until_parked();
    if blocked {
        cx.read(|cx| {
            let view = root.read(cx);
            assert!(matches!(
                view.projects.presentation.availability,
                Availability::Unconfirmed(_)
            ));
            assert!(view.projects.admission_blocked && view.projects.load.is_none());
            assert_eq!(view.projects.presentation.stage, stage);
        });
    }
}

#[gpui::test]
fn cancelled_reload_from_unconfirmed_can_reopen_and_reload(cx: &mut TestAppContext) {
    interrupted_reload_case(cx, true, false);
}

#[gpui::test]
fn cancelled_reload_from_unconfirmed_rebind_ignores_old_window_result(cx: &mut TestAppContext) {
    interrupted_reload_case(cx, true, true);
}

#[gpui::test]
fn cancelled_reload_with_existing_baseline_restores_ready(cx: &mut TestAppContext) {
    interrupted_reload_case(cx, false, false);
}

#[gpui::test]
fn projects_close_shortcut_held_repeat_cannot_close_workspace(cx: &mut TestAppContext) {
    use gpui::{KeyDownEvent, KeyUpEvent, Keystroke, VisualTestContext};
    let (_dir, window, root, _control) = fixture(cx);
    let key = Keystroke::parse(if cfg!(target_os = "macos") {
        "cmd-w"
    } else {
        "ctrl-w"
    })
    .unwrap();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_event(KeyDownEvent {
        keystroke: key.clone(),
        is_held: false,
    });
    cx.run_until_parked();
    assert!(!cx.read(|cx| root.read(cx).projects.open));
    assert!(!cx.read(|cx| root.read(cx).shutting_down));
    visual.simulate_event(KeyDownEvent {
        keystroke: Keystroke::parse("left").unwrap(),
        is_held: false,
    });
    for _ in 0..3 {
        visual.simulate_event(KeyUpEvent {
            keystroke: key.clone(),
        });
        visual.simulate_event(KeyDownEvent {
            keystroke: key.clone(),
            is_held: true,
        });
        cx.run_until_parked();
        assert!(cx.read(|cx| {
            cx.windows()
                .iter()
                .any(|current| current.window_id() == window.window_id())
        }));
        cx.read(|cx| {
            let view = root.read(cx);
            assert!(!view.shutting_down && !view.close_ready && !view.close_dialog);
            assert_eq!(view.cancelled_prompt_key.as_deref(), Some("w"));
        });
    }
    // Release is not an action. A fresh press is an intentional new Close.
    visual.simulate_event(KeyUpEvent {
        keystroke: key.clone(),
    });
    visual.simulate_event(KeyDownEvent {
        keystroke: key,
        is_held: false,
    });
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).shutting_down));
    assert!(cx.read(|cx| root.read(cx).cancelled_prompt_key.is_none()));
}

fn history_fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let (authority, _) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    cx.update(|cx| {
        cx.set_global(LaunchProjectAuthority {
            authority: Arc::new(authority),
            mode: crate::launch_authority::AuthorityMode::Fixture,
        })
    });
    let path = project.join("history.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.title = "Saved conversation".into();
            session.messages.push(bello_agent_core::Message {
                task_root_id: None,
                user_content: None,
                id: Uuid::new_v4().to_string(),
                role: "assistant".into(),
                text: "Durable conversation history".into(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "complete".into(),
                usage: serde_json::Value::Null,
                model: None,
                tool_record: None,
                compaction: None,
            });
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Saved conversation".into(), path);
    let mut workspace = WorkspaceStore::open(project.join("catalog.json"), &project).unwrap();
    workspace
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft: DraftRecord::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).transcript.is_some()));
    (dir, window, root)
}

async fn create_history_project(
    window: WindowHandle<AgentView>,
    root: &Entity<AgentView>,
    cx: &mut TestAppContext,
) {
    window
        .update(cx, |view, window, cx| view.open_projects(window, cx))
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            intent(view, Intent::BeginCreate, window, cx);
            intent(view, Intent::ConfirmTrust, window, cx);
        })
        .unwrap();
    cx.condition(root, |view, _| view.projects.operation.is_none())
        .await;
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.projects.presentation.trusted);
        assert!(!view.projects.admission_blocked);
        assert_eq!(view.session.messages.len(), 1);
        assert!(view.transcript.is_some());
    });
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
}

fn copy_all(window: WindowHandle<AgentView>, cx: &mut TestAppContext) -> Option<String> {
    cx.update(|cx| cx.write_to_clipboard(gpui::ClipboardItem::new_string("sentinel".into())));
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "macos") {
            "cmd-a cmd-c"
        } else {
            "ctrl-a ctrl-c"
        },
    );
    cx.read(|cx| cx.read_from_clipboard().and_then(|item| item.text()))
}

#[gpui::test]
async fn project_saved_history_restores_composer_select_all_and_undo_after_escape(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = history_fixture(cx);
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    cx.simulate_input(window.into(), "typed draft 日本語");
    let text = cx.read(|cx| composer.read(cx).text().to_owned());
    assert_eq!(text, "typed draft 日本語");
    create_history_project(window, &root, cx).await;
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.entity_id()),
        composer.entity_id()
    );
    assert_eq!(copy_all(window, cx), Some(text));
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "macos") {
            "cmd-z"
        } else {
            "ctrl-z"
        },
    );
    assert_eq!(cx.read(|cx| composer.read(cx).text().to_owned()), "");
}

#[gpui::test]
async fn project_saved_history_keeps_composer_marked_text_and_focus(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler;
    let (_dir, window, root) = history_fixture(cx);
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    window
        .update(cx, |_, window, cx| {
            composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            })
        })
        .unwrap();
    create_history_project(window, &root, cx).await;
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.composer.entity_id(), composer.entity_id());
            assert_eq!(composer.read(cx).text(), "漢字");
            assert!(composer.read(cx).has_marked_text());
            assert!(composer.read(cx).focus_handle(cx).is_focused(window));
        })
        .unwrap();
}

#[gpui::test]
async fn project_saved_history_restores_file_editor_select_all_and_undo(cx: &mut TestAppContext) {
    let (dir, window, root) = history_fixture(cx);
    let path = dir.path().join("retained.txt");
    std::fs::write(&path, "original").unwrap();
    window
        .update(cx, |view, window, cx| {
            view.open_file(path, None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    let file = cx.read(|cx| root.read(cx).files[0].view.clone());
    let editor = cx.read(|cx| file.read(cx).editor_for_test());
    cx.simulate_input(window.into(), "typed ");
    let text = cx.read(|cx| editor.read(cx).text().to_owned());
    create_history_project(window, &root, cx).await;
    assert_eq!(
        cx.read(|cx| root.read(cx).files[0].view.entity_id()),
        file.entity_id()
    );
    assert_eq!(copy_all(window, cx), Some(text));
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "macos") {
            "cmd-z"
        } else {
            "ctrl-z"
        },
    );
    assert_eq!(cx.read(|cx| editor.read(cx).text().to_owned()), "original");
}

#[gpui::test]
async fn project_saved_history_does_not_restore_retired_noneditable_transcript_root(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = history_fixture(cx);
    let old = cx.read(|cx| root.read(cx).transcript.as_ref().unwrap().clone());
    let previous = window
        .update(cx, |_, window, cx| {
            assert!(old.read(cx).focus_fallback(window));
            window.focused(cx).unwrap()
        })
        .unwrap();
    create_history_project(window, &root, cx).await;
    window
        .update(cx, |view, window, cx| {
            let current = view.transcript.as_ref().unwrap();
            assert_ne!(old.entity_id(), current.entity_id());
            assert!(!previous.is_focused(window));
            assert!(
                current
                    .read(cx)
                    .owned_focus_handles(cx)
                    .iter()
                    .any(|handle| handle.is_focused(window))
            );
        })
        .unwrap();
}
