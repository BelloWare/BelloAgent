use super::{PickerOperation, input_label};
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Credential, Lane, Profile, SessionStore, Submission,
    attachments::AttachmentRecord,
    workspace::{ChatRecord, DraftRecord, SubmissionIntent, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::sync::{Arc, Mutex};

fn image(name: &str) -> AttachmentRecord {
    AttachmentRecord {
        id: uuid::Uuid::new_v4().to_string(),
        path: format!("/missing/{name}.gif"),
        sha256: "a".repeat(64),
        bytes: 6,
        mime_type: "image/gif".into(),
    }
}
fn controller(store: SessionStore, images: bool) -> Arc<Controller> {
    let profile: Profile = serde_json::from_value(serde_json::json!({
        "id":"attachment-ui", "api":"openai-responses", "providerId":"litellm",
        "modelId":"fixture-model", "baseUrl":"http://127.0.0.1:9",
        "contextWindow":32000, "maxOutputTokens":4096,
        "input": if images { vec!["text", "image"] } else { vec!["text"] }
    }))
    .unwrap();
    Controller::new(
        store,
        Some((
            profile,
            Credential::new("attachment-fixture-only".into()).unwrap(),
        )),
    )
    .unwrap()
}
fn fixture(
    cx: &mut TestAppContext,
    text: &str,
    images: bool,
    queued: Option<Submission>,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let mut store = SessionStore::open(project.join("session.json")).unwrap();
    if let Some(item) = queued {
        store
            .transact(|session| {
                session.pending.push(item);
                session.queue_paused = true;
                Ok(())
            })
            .unwrap();
    }
    let record = ChatRecord::new(
        store.snapshot().id,
        "Attachments".into(),
        project.join("session.json"),
    );
    let draft = DraftRecord {
        text: text.into(),
        revision: 1,
        ..Default::default()
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace.register(record.clone(), draft.clone()).unwrap();
    let launch = LaunchState {
        controller: controller(store, images),
        record,
        draft,
        workspace: Arc::new(Mutex::new(workspace)),
        project,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}

fn wait_idle(root: &Entity<AgentView>, cx: &mut TestAppContext) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(6);
    loop {
        cx.run_until_parked();
        if cx.read(|cx| !root.read(cx).busy) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "attachment operation did not settle"
        );
        std::thread::sleep(std::time::Duration::from_millis(3));
    }
}

#[test]
fn image_only_labels_are_presentation_without_invented_source_text() {
    assert_eq!(input_label("", 1), "Image");
    assert_eq!(input_label("", 4), "4 images");
    assert_eq!(input_label("caption 日本語", 4), "caption 日本語");
    assert_eq!(input_label("  ", 1), "  ");
    assert_eq!(input_label("", 0), "");
}

#[gpui::test]
fn chooser_cancel_rejection_and_over_limit_keep_text_chips_and_editor(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx, "caption 日本語", true, None);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        let original = image("original");
        view.receive_images(&id, &source, Ok(vec![original.clone()]), cx);
        let editor = view.composer.entity_id();
        let revision = view.draft_revision;
        view.receive_images(&id, &source, Ok(vec![]), cx);
        assert_eq!(view.draft_revision, revision);
        view.receive_images(&id, &source, Err("unsupported selected file".into()), cx);
        view.receive_images(
            &id,
            &source,
            Ok((0..4).map(|n| image(&format!("more-{n}"))).collect()),
            cx,
        );
        assert_eq!(view.attachments, vec![original]);
        assert_eq!(view.composer.read(cx).text(), "caption 日本語");
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.draft_revision, revision);
        assert!(view.error.is_some());
    });
}

#[gpui::test]
fn picker_result_stays_with_origin_chat_after_navigation(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx, "", true, None);
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let source = Arc::downgrade(&view.controller);
            let binding = view.window_binding;
            let project = view.project.clone();
            let token = uuid::Uuid::new_v4();
            view.pending = true;
            view.attachment_picker = Some(PickerOperation {
                token,
                chat: id.clone(),
            });
            assert!(!view.can_attach_images());
            view.new_chat(window, cx);
            assert_ne!(view.record.id, id);
            assert!(
                view.inactive.contains_key(&id),
                "an empty origin stays alive while its chooser is open"
            );
            let selected = image("origin");
            view.finish_image_picker(
                token,
                binding,
                &project,
                &id,
                &source,
                Ok(vec![selected.clone()]),
                cx,
            );
            assert_eq!(view.chat_ref(&id).unwrap().attachments, vec![selected]);
            assert!(view.attachments.is_empty());
            assert!(view.attachment_picker.is_none());
        })
        .unwrap();
}

#[gpui::test]
fn stale_picker_cannot_cross_runtime_or_window_replacement(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, "keep", true, None);
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let old = Arc::downgrade(&view.controller);
            let binding = view.window_binding;
            let project = view.project.clone();
            let token = uuid::Uuid::new_v4();
            view.attachment_picker = Some(PickerOperation {
                token,
                chat: id.clone(),
            });
            let replacement = controller(SessionStore::pending_with_id(&id).unwrap(), true);
            view.chat.replace_controller(replacement, cx);
            view.finish_image_picker(
                token,
                binding,
                &project,
                &id,
                &old,
                Ok(vec![image("old-controller")]),
                cx,
            );
            assert!(view.attachments.is_empty());
            let current = Arc::downgrade(&view.controller);
            view.attachment_picker = Some(PickerOperation {
                token,
                chat: id.clone(),
            });
            view.bind_window(window, cx);
            view.finish_image_picker(
                token,
                binding,
                &project,
                &id,
                &current,
                Ok(vec![image("old-window")]),
                cx,
            );
            assert!(view.attachments.is_empty());
            assert_eq!(view.composer.read(cx).text(), "keep");
        })
        .unwrap();
    let _ = root;
}

#[gpui::test]
fn missing_declared_capability_cannot_adopt_or_enable_picker(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx, "keep", false, None);
    root.update(cx, |view, cx| {
        assert!(!view.can_attach_images());
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(vec![image("unsupported")]), cx);
        assert!(view.attachments.is_empty());
        assert_eq!(view.composer.read(cx).text(), "keep");
        assert!(view.error.as_deref().unwrap().contains("image support"));
    });
}

#[gpui::test]
fn held_image_only_save_keeps_queued_images_and_restores_new_ordinary_images(
    cx: &mut TestAppContext,
) {
    let queued_image = image("queued");
    let mut item = Submission::new("caption to remove".into(), Lane::FollowUp);
    item.attachments = vec![queued_image.clone()];
    let turn = item.id.clone();
    let (_dir, window, root) = fixture(cx, "ordinary", true, Some(item));
    let first = image("ordinary");
    let later = image("chosen-during-edit");
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let source = Arc::downgrade(&view.controller);
            view.receive_images(&id, &source, Ok(vec![first.clone()]), cx);
            view.begin_queued_edit(&id, &turn, None, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.editing.is_some());
        assert!(view.attachments.is_empty());
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(vec![later.clone()]), cx);
        assert_eq!(
            view.draft_before_edit_attachments,
            vec![first.clone(), later.clone()]
        );
        view.composer
            .update(cx, |editor, cx| editor.set_text(String::new(), cx));
        assert!(view.composer_has_input(cx));
        view.resolve_edit("saved", cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.editing.is_none());
        assert_eq!(view.composer.read(cx).text(), "ordinary");
        assert_eq!(view.attachments, vec![first, later]);
        let queued = view
            .session
            .pending
            .iter()
            .find(|item| item.id == turn)
            .unwrap();
        assert_eq!(queued.text, "");
        assert_eq!(queued.attachments, vec![queued_image]);
        assert_eq!(view.saved_draft(cx).attachments, view.attachments);
    });
}

#[gpui::test]
fn failed_send_prepends_captured_images_to_newer_draft_without_losing_text(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root) = fixture(cx, "", true, None);
    let first = image("captured-missing");
    let newer = image("newer");
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(vec![first.clone()]), cx);
        assert!(view.composer_has_input(cx));
        view.submit_chat(Lane::FollowUp, cx);
        assert!(view.attachments.is_empty());
        view.receive_images(&id, &source, Ok(vec![newer.clone()]), cx);
        view.composer
            .update(cx, |editor, cx| editor.set_text("newer text".into(), cx));
    });
    wait_idle(&root, cx);
    root.update(cx, |view, cx| {
        assert!(!view.busy);
        assert_eq!(view.attachments, vec![first, newer]);
        assert_eq!(view.composer.read(cx).text(), "newer text");
        assert!(view.session.pending.is_empty());
        assert!(view.session.messages.is_empty());
        assert!(view.recoveries.is_empty());
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&view.record.id].attachments,
            view.attachments
        );
    });
}

#[gpui::test]
fn accepted_intent_insert_acknowledges_exact_metadata_without_duplicate_draft(
    cx: &mut TestAppContext,
) {
    let selected = image("accepted");
    let mut item = Submission::new("".into(), Lane::FollowUp);
    item.attachments = vec![selected.clone()];
    let (_dir, _window, root) = fixture(cx, "newer draft", true, Some(item.clone()));
    root.update(cx, |view, cx| {
        let receipt = SubmissionIntent {
            skills: Vec::new(),
            id: item.id.clone(),
            chat_id: view.record.id.clone(),
            text: item.text.clone(),
            attachments: item.attachments.clone(),
            lane: item.lane.clone(),
            draft_revision: 0,
        };
        view.workspace
            .lock()
            .unwrap()
            .begin_submission(receipt.clone())
            .unwrap();
        view.recoveries.insert(receipt.id.clone(), receipt);
        view.load_failed = true;
        view.resolve_intent(&item.id, true, cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), "newer draft");
        assert!(view.attachments.is_empty());
        assert!(view.recoveries.is_empty());
        assert_eq!(view.session.pending.len(), 1);
        assert!(view.workspace.lock().unwrap().snapshot().intents.is_empty());
    });
}

#[gpui::test]
fn matching_id_with_different_metadata_retains_recovery_and_never_inserts(cx: &mut TestAppContext) {
    let mut item = Submission::new("".into(), Lane::FollowUp);
    item.attachments = vec![image("accepted")];
    let (_dir, _window, root) = fixture(cx, "newer", true, Some(item.clone()));
    root.update(cx, |view, cx| {
        let receipt = SubmissionIntent {
            skills: Vec::new(),
            id: item.id.clone(),
            chat_id: view.record.id.clone(),
            text: item.text.clone(),
            attachments: vec![image("different")],
            lane: item.lane.clone(),
            draft_revision: 0,
        };
        view.workspace
            .lock()
            .unwrap()
            .begin_submission(receipt.clone())
            .unwrap();
        view.recoveries.insert(receipt.id.clone(), receipt);
        view.resolve_intent(&item.id, true, cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), "newer");
        assert!(view.attachments.is_empty());
        assert!(view.recoveries.contains_key(&item.id));
        assert!(
            view.workspace
                .lock()
                .unwrap()
                .snapshot()
                .intents
                .contains_key(&item.id)
        );
        assert!(!view.busy);
    });
}

#[gpui::test]
fn removing_one_chip_uses_uuid_and_preserves_composer_and_other_same_path_chip(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root) = fixture(cx, "untouched", true, None);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        let first = image("same-path");
        let mut second = first.clone();
        second.id = uuid::Uuid::new_v4().to_string();
        let editor = view.composer.entity_id();
        view.receive_images(&id, &source, Ok(vec![first.clone(), second.clone()]), cx);
        view.remove_attachment(&id, &source, &first.id, cx);
        assert_eq!(view.attachments, vec![second]);
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.composer.read(cx).text(), "untouched");
        let revision = view.draft_revision;
        view.remove_attachment(&id, &source, &first.id, cx);
        assert_eq!(
            view.draft_revision, revision,
            "an old repeated remove is inert"
        );
    });
}

#[gpui::test]
fn failed_four_image_send_keeps_all_four_newer_images_recoverable(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx, "first", true, None);
    let captured: Vec<_> = (0..4).map(|n| image(&format!("captured-{n}"))).collect();
    let newer: Vec<_> = (0..4).map(|n| image(&format!("newer-{n}"))).collect();
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(captured.clone()), cx);
        view.submit_chat(Lane::Steering, cx);
        view.receive_images(&id, &source, Ok(newer.clone()), cx);
        view.composer
            .update(cx, |editor, cx| editor.set_text("second".into(), cx));
    });
    wait_idle(&root, cx);
    root.update(cx, |view, cx| {
        let expected: Vec<_> = captured.into_iter().chain(newer).collect();
        assert_eq!(view.attachments, expected);
        assert_eq!(view.composer.read(cx).text(), "first\n\nsecond");
        assert_eq!(view.saved_draft(cx).attachments.len(), 8);
        let before = view.workspace.lock().unwrap().snapshot();
        let before_revision = view.draft_revision;
        view.submit_chat(Lane::FollowUp, cx);
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().intents,
            before.intents
        );
        assert_eq!(view.draft_revision, before_revision);
        assert!(view.inflight_submission.is_none());
        assert!(view.session.messages.is_empty() && view.session.pending.is_empty());
        assert!(
            !view.busy,
            "over-limit recovered drafts fail before clearing anything"
        );
        assert_eq!(view.attachments.len(), 8);
        assert_eq!(view.composer.read(cx).text(), "first\n\nsecond");
    });
}

#[gpui::test]
fn held_draft_reopen_retains_ordinary_images_and_cancel_restores_them(cx: &mut TestAppContext) {
    let mut item = Submission::new("queued".into(), Lane::FollowUp);
    item.attachments = vec![image("queued")];
    let turn = item.id.clone();
    let (_dir, window, root) = fixture(cx, "ordinary", true, Some(item));
    let selected = image("parked");
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let source = Arc::downgrade(&view.controller);
            view.receive_images(&id, &source, Ok(vec![selected.clone()]), cx);
            view.begin_queued_edit(&id, &turn, None, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            let saved = view.saved_draft(cx);
            assert_eq!(saved.attachments, vec![selected.clone()]);
            let reloaded = crate::chat::ChatState::new(
                view.controller.clone(),
                view.record.clone(),
                crate::chat::RestoredDraft {
                    draft: saved,
                    cancellation: None,
                },
                false,
                view.palette,
                window,
                cx,
            );
            view.chat = reloaded;
            assert!(view.attachments.is_empty());
            assert_eq!(view.draft_before_edit_attachments, vec![selected.clone()]);
            let id = view.record.id.clone();
            view.reconcile_edit(&id, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        view.cancel_owned_edit(&id, cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.editing.is_none());
        assert_eq!(view.attachments, vec![selected]);
        assert_eq!(view.composer.read(cx).text(), "ordinary");
        assert_eq!(view.session.pending[0].attachments.len(), 1);
    });
}

#[test]
fn chip_file_urls_encode_reserved_unicode_and_shell_bytes_without_retargeting() {
    for path in [
        "/tmp/a b#c?d%2F日本語'\";$(id).gif",
        "/tmp/line\nbreak.gif",
        "/tmp/--flag.gif",
        "//not-an-authority/a.png",
        "/tmp/https://example.invalid/?q#fragment.gif",
    ] {
        let url = super::attachment_file_url(path).expect("safe absolute file path");
        assert_eq!(url.scheme(), "file");
        assert!(url.host_str().is_none());
        assert!(url.query().is_none() && url.fragment().is_none());
        assert_eq!(url.to_file_path().unwrap(), std::path::Path::new(path));
    }
    let url = super::attachment_file_url("/tmp/a b#c?d%2F.gif").unwrap();
    assert_eq!(url.as_str(), "file:///tmp/a%20b%23c%3Fd%252F.gif");
    for path in [
        "relative.gif",
        "https://example.invalid/image",
        "file:///tmp/a.gif",
        "/tmp/zero\0byte.gif",
    ] {
        assert!(super::attachment_file_url(path).is_none());
    }
}

#[gpui::test]
fn clicking_chip_opens_exact_captured_file_without_changing_draft(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, "caption", true, None);
    let record = image("a b#c?d%2F日本語");
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(vec![record.clone()]), cx);
    });
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(gpui::px(1180.), gpui::px(812.)));
    cx.run_until_parked();
    let revision = cx.read(|cx| root.read(cx).draft_revision);
    let body = visual
        .debug_bounds(Box::leak(
            format!("image-chip-{}", record.id).into_boxed_str(),
        ))
        .unwrap();
    visual.simulate_click(body.center(), gpui::Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        cx.opened_url().as_deref(),
        Some(super::attachment_file_url(&record.path).unwrap().as_str())
    );
    root.update(cx, |view, cx| {
        assert_eq!(view.attachments, vec![record]);
        assert_eq!(view.composer.read(cx).text(), "caption");
        assert_eq!(view.draft_revision, revision);
    });
}

#[gpui::test]
fn chip_remove_is_uuid_scoped_and_never_bubbles_into_open(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, "caption", true, None);
    let first = image("same");
    let mut second = first.clone();
    second.id = uuid::Uuid::new_v4().to_string();
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let source = Arc::downgrade(&view.controller);
        view.receive_images(&id, &source, Ok(vec![first.clone(), second.clone()]), cx);
    });
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(gpui::px(1180.), gpui::px(812.)));
    cx.run_until_parked();
    let remove = visual
        .debug_bounds(Box::leak(
            format!("remove-image-{}", first.id).into_boxed_str(),
        ))
        .unwrap();
    visual.simulate_click(remove.center(), gpui::Modifiers::none());
    cx.run_until_parked();
    assert!(cx.opened_url().is_none());
    root.update(cx, |view, cx| {
        assert_eq!(view.attachments, vec![second.clone()]);
        assert_eq!(view.composer.read(cx).text(), "caption");
        // A blocked removal leaves the record present. Without stopped event
        // propagation its enclosing chip would still open the source file.
        view.draft_revision = u64::MAX;
        cx.notify();
    });
    cx.run_until_parked();
    let remove = visual
        .debug_bounds(Box::leak(
            format!("remove-image-{}", second.id).into_boxed_str(),
        ))
        .unwrap();
    visual.simulate_click(remove.center(), gpui::Modifiers::none());
    cx.run_until_parked();
    assert!(cx.opened_url().is_none());
    root.update(cx, |view, _| assert_eq!(view.attachments, vec![second]));
}

#[gpui::test]
fn chip_callbacks_reject_navigation_window_and_controller_replacements(cx: &mut TestAppContext) {
    for change in ["chat", "window", "controller", "metadata", "project"] {
        let (_dir, window, root) = fixture(cx, "caption", true, None);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let source = Arc::downgrade(&view.controller);
                let record = image("original");
                view.receive_images(&id, &source, Ok(vec![record.clone()]), cx);
                let target = view.attachment_target(&record);
                match change {
                    "chat" => view.new_chat(window, cx),
                    "window" => view.bind_window(window, cx),
                    "controller" => view.chat.replace_controller(
                        controller(SessionStore::pending_with_id(&id).unwrap(), true),
                        cx,
                    ),
                    "metadata" => view.attachments[0].path = "/missing/replaced.gif".into(),
                    "project" => view.project = view.project.join("different"),
                    _ => unreachable!(),
                }
                let before = view.chat_ref(&id).unwrap().attachments.clone();
                assert!(
                    !view.open_attachment(&target, cx),
                    "stale {change} callback"
                );
                view.remove_presented_attachment(&target, cx);
                assert_eq!(view.chat_ref(&id).unwrap().attachments, before);
            })
            .unwrap();
        assert!(cx.opened_url().is_none());
        let _ = root;
    }
}

#[gpui::test]
fn fresh_picker_is_disabled_through_begin_held_save_and_cancel(cx: &mut TestAppContext) {
    for cancel in [false, true] {
        let item = Submission::new("queued".into(), Lane::FollowUp);
        let turn = item.id.clone();
        let (_dir, window, root) = fixture(cx, "ordinary", true, Some(item));
        window
            .update(cx, |view, window, cx| {
                assert!(view.can_attach_images());
                let id = view.record.id.clone();
                view.begin_queued_edit(&id, &turn, None, window, cx);
                assert!(!view.can_attach_images());
                view.choose_images(window, cx);
                assert!(view.attachment_picker.is_none());
            })
            .unwrap();
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                assert!(view.editing.is_some());
                assert!(!view.can_attach_images());
                view.choose_images(window, cx);
                assert!(view.attachment_picker.is_none());
                if cancel {
                    let id = view.record.id.clone();
                    view.cancel_owned_edit(&id, cx);
                } else {
                    view.resolve_edit("saved", cx);
                }
                assert!(!view.can_attach_images());
                view.choose_images(window, cx);
                assert!(view.attachment_picker.is_none());
            })
            .unwrap();
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(view.editing.is_none());
            assert!(view.can_attach_images());
            assert_eq!(view.composer.read(cx).text(), "ordinary");
        });
    }
}

#[gpui::test]
fn late_started_picker_parks_images_while_new_picker_stays_disabled(cx: &mut TestAppContext) {
    let item = Submission::new("queued".into(), Lane::FollowUp);
    let turn = item.id.clone();
    let (_dir, window, root) = fixture(cx, "ordinary", true, Some(item));
    let record = image("late-origin");
    let mut origin = None;
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let token = uuid::Uuid::new_v4();
            origin = Some((
                token,
                view.window_binding,
                view.project.clone(),
                id.clone(),
                Arc::downgrade(&view.controller),
            ));
            view.attachment_picker = Some(PickerOperation {
                token,
                chat: id.clone(),
            });
            view.begin_queued_edit(&id, &turn, None, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    let (token, binding, project, id, source) = origin.unwrap();
    window
        .update(cx, |view, window, cx| {
            assert!(view.editing.is_some());
            view.finish_image_picker(
                token,
                binding,
                &project,
                &id,
                &source,
                Ok(vec![record.clone()]),
                cx,
            );
            assert!(view.attachment_picker.is_none());
            assert!(view.attachments.is_empty());
            assert_eq!(view.draft_before_edit_attachments, vec![record.clone()]);
            assert!(!view.can_attach_images());
            view.choose_images(window, cx);
            assert!(view.attachment_picker.is_none());
            view.cancel_owned_edit(&id, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.attachments, vec![record]);
        assert_eq!(view.composer.read(cx).text(), "ordinary");
        assert!(view.can_attach_images());
    });
}

#[gpui::test]
fn fresh_picker_rejects_unowned_hold_and_recovery_but_allows_streaming(cx: &mut TestAppContext) {
    let item = Submission::new("queued".into(), Lane::FollowUp);
    let turn = item.id.clone();
    let (_dir, window, _root) = fixture(cx, "ordinary", true, Some(item));
    window
        .update(cx, |view, window, cx| {
            std::sync::Arc::make_mut(&mut view.chat.session).state =
                bello_agent_core::RunState::Running;
            assert!(
                view.can_attach_images(),
                "streaming alone does not block selection"
            );
            view.controller
                .begin_edit(&turn, "unowned-image-hold")
                .unwrap();
            view.session = view.controller.snapshot_shared();
            assert!(view.editing.is_none() && view.session.edit.is_some());
            assert!(!view.can_attach_images());
            view.choose_images(window, cx);
            assert!(view.attachment_picker.is_none());
            view.controller
                .resolve_edit("unowned-image-hold", "cancelled", None)
                .unwrap();
            view.session = view.controller.snapshot_shared();
            view.edit_recovery = crate::queue_edit::EditRecovery::new(true);
            assert!(!view.can_attach_images());
            view.choose_images(window, cx);
            assert!(view.attachment_picker.is_none());
        })
        .unwrap();
}
