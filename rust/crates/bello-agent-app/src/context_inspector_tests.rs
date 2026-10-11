// Do not glob-import the parent's GPUI `test` macro: `gpui::test` emits a
// built-in `#[test]`, which would resolve back to GPUI and recurse.
use super::{
    COUNT_UNAVAILABLE, ContextInspector, Control, MINIMUM_SIZE, PAGE_BYTES, PreparedDocument,
    page_ranges, summary,
};
use crate::{AgentView, LaunchState, shutdown_barrier::ShutdownOutcome};
use bello_agent_core::{
    Controller, Credential, Profile, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    ClipboardItem, Entity, EntityInputHandler, Focusable, Modifiers, TestAppContext,
    VisualTestContext, WindowHandle, px, size,
};
use std::sync::{Arc, Mutex};

fn configured(store: SessionStore) -> Arc<Controller> {
    let profile: Profile = serde_json::from_value(serde_json::json!({
        "id": "inspector-test", "api": "openai-responses", "providerId": "litellm",
        "modelId": "fixture-model", "baseUrl": "http://127.0.0.1:9",
        "contextWindow": 32000, "maxOutputTokens": 4096
    }))
    .unwrap();
    Controller::new(
        store,
        Some((
            profile,
            Credential::new("inspector-fixture-only".into()).unwrap(),
        )),
    )
    .unwrap()
}

fn fixture(
    cx: &mut TestAppContext,
    draft: &str,
    connected: bool,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(directory.path()).unwrap();
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let record = ChatRecord::new(
        snapshot.id,
        "Inspector fixture".into(),
        project.join("session.json"),
    );
    let draft = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        text: draft.into(),
        ..Default::default()
    };
    let launch = LaunchState {
        controller: if connected {
            configured(store)
        } else {
            Controller::new(store, None).unwrap()
        },
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("workspace.json"), &project).unwrap(),
        )),
        project,
        record,
        draft,
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (directory, window, root)
}

fn open(
    window: WindowHandle<AgentView>,
    cx: &mut TestAppContext,
) -> (WindowHandle<ContextInspector>, Entity<ContextInspector>) {
    let handle = window
        .update(cx, |view, window, cx| {
            let target = view.context_inspector_target();
            view.open_context_inspector(&target, window, cx);
            view.inspector_windows.last().unwrap().handle
        })
        .unwrap();
    let inspector = handle.root(cx).unwrap();
    cx.run_until_parked();
    (handle, inspector)
}

#[test]
fn pages_preserve_every_unicode_byte_and_never_exceed_editor_bound() {
    for text in [
        String::new(),
        "a".repeat(PAGE_BYTES),
        format!(
            "{}{}",
            "a".repeat(PAGE_BYTES - 1),
            "世界 👩🏽‍💻 e\u{301}\n".repeat(12_000)
        ),
    ] {
        let pages = page_ranges(&text);
        assert!(!pages.is_empty());
        assert!(pages.iter().all(|range| range.len() <= PAGE_BYTES));
        assert_eq!(
            pages
                .iter()
                .map(|range| &text[range.clone()])
                .collect::<String>(),
            text
        );
        for (left, right) in pages.iter().zip(pages.iter().skip(1)) {
            assert_eq!(left.end, right.start);
        }
    }
}

#[gpui::test]
fn footer_opens_once_and_reading_never_materializes_or_changes_chat(cx: &mut TestAppContext) {
    let (directory, window, root) = fixture(cx, "Draft 日本語\n", true);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(812.)));
    cx.run_until_parked();
    let (before, revision, editor, draft_revision) = cx.read(|cx| {
        let view = root.read(cx);
        (
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            view.controller.revision(),
            view.composer.entity_id(),
            view.draft_revision,
        )
    });
    let footer = visual
        .debug_bounds("session-stats-context")
        .expect("visible Context footer entry");
    visual.simulate_click(footer.center(), Modifiers::none());
    cx.run_until_parked();
    let handle = cx.read(|cx| root.read(cx).inspector_windows[0].handle);
    let inspector = handle.root(cx).unwrap();
    visual.simulate_click(footer.center(), Modifiers::none());
    cx.run_until_parked();
    let same = cx.read(|cx| root.read(cx).inspector_windows[0].handle);
    let same_inspector = same.root(cx).unwrap();
    assert_eq!(same.window_id(), handle.window_id());
    assert_eq!(same_inspector.entity_id(), inspector.entity_id());
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.inspector_windows.len(), 1);
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.draft_revision, draft_revision);
        assert_eq!(view.controller.revision(), revision);
        assert_eq!(
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            before
        );
        assert!(!view.controller.is_persistent());
        let inspector = inspector.read(cx);
        let document = inspector
            .document
            .as_ref()
            .expect("prepared read-only request");
        assert!(document.preview.request_json().contains("Draft 日本語"));
        assert!(document.preview.metadata().tokens.is_none());
        assert!(summary(document.preview.metadata()).contains(&COUNT_UNAVAILABLE.into()));
        assert!(inspector.reader.read(cx).engine.read_only);
    });
    assert!(!directory.path().join("session.json").exists());
}

#[gpui::test]
fn disconnected_preview_is_honest_and_preserves_draft(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "not sent", false);
    let (_, inspector) = open(window, cx);
    cx.read(|cx| {
        assert_eq!(root.read(cx).composer.read(cx).text(), "not sent");
        let inspector = inspector.read(cx);
        assert!(inspector.document.is_none());
        assert!(
            inspector
                .notice
                .as_deref()
                .unwrap()
                .contains("No connection configured")
        );
        assert!(!inspector.enabled(Control::Copy));
    });
}

#[gpui::test]
fn open_close_preserves_composer_entity_undo_selection_and_marked_text(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "saved ", true);
    cx.simulate_input(window.into(), "typed ");
    let editor = cx.read(|cx| root.read(cx).composer.clone());
    let before = window
        .update(cx, |_, window, cx| {
            editor.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "未確定", Some(1..2), window, cx);
                (
                    editor.text().to_owned(),
                    editor.selected_text_range(false, window, cx).unwrap().range,
                    editor.marked_text_range(window, cx).unwrap(),
                )
            })
        })
        .unwrap();
    let (handle, inspector) = open(window, cx);
    // A newer workspace focus choice must survive an inspector close.
    window
        .update(cx, |view, window, cx| view.filter.read(cx).focus(window))
        .unwrap();
    handle
        .update(cx, |view, window, cx| view.close(window, cx))
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.composer.entity_id(), editor.entity_id());
            assert!(view.filter.read(cx).focus_handle(cx).is_focused(window));
            editor.update(cx, |editor, cx| {
                assert_eq!(editor.text(), before.0);
                assert_eq!(
                    editor.selected_text_range(false, window, cx).unwrap().range,
                    before.1
                );
                assert_eq!(editor.marked_text_range(window, cx).unwrap(), before.2);
                editor.unmark_text(window, cx);
                editor.focus(window);
            });
        })
        .unwrap();
    assert!(cx.read(|cx| inspector.read(cx).closed));
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "macos") {
            "cmd-z"
        } else {
            "ctrl-z"
        },
    );
    assert_ne!(cx.read(|cx| editor.read(cx).text().to_owned()), before.0);
}

#[gpui::test]
fn preview_completion_and_refresh_follow_original_chat_after_selection_changes(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root) = fixture(cx, "first draft", true);
    let (_handle, inspector) = open(window, cx);
    let original = cx.read(|cx| root.read(cx).record.id.clone());
    let (generation, prepared) = cx.read(|cx| {
        let view = inspector.read(cx);
        (
            view.generation,
            Arc::new(PreparedDocument::new(
                root.read(cx)
                    .controller
                    .prepare_context("first draft")
                    .unwrap(),
            )),
        )
    });
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    inspector.update(cx, |view, cx| view.install(generation, Ok(prepared), cx));
    cx.read(|cx| {
        assert_ne!(root.read(cx).record.id, original);
        let view = inspector.read(cx);
        assert_eq!(view.target.chat, original);
        assert_eq!(
            view.document
                .as_ref()
                .unwrap()
                .preview
                .metadata()
                .session_id,
            original
        );
        assert_eq!(root.read(cx).composer.read(cx).text(), "");
    });
    inspector.update(cx, |view, cx| view.refresh(cx));
    cx.run_until_parked();
    assert!(cx.read(|cx| {
        inspector
            .read(cx)
            .document
            .as_ref()
            .unwrap()
            .preview
            .request_json()
            .contains("first draft")
    }));
}

#[gpui::test]
fn idle_draft_change_and_newer_refresh_reject_stale_completion(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "old draft", true);
    let (_, inspector) = open(window, cx);
    let generation = inspector.update(cx, |view, cx| {
        view.refresh(cx);
        view.generation
    });
    let prepared = cx.read(|cx| {
        Arc::new(PreparedDocument::new(
            root.read(cx)
                .controller
                .prepare_context("old draft")
                .unwrap(),
        ))
    });
    window
        .update(cx, |view, _, cx| {
            view.composer
                .update(cx, |editor, cx| editor.set_text("new draft".into(), cx))
        })
        .unwrap();
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        view.install(generation, Ok(prepared), cx);
        assert!(view.document.is_none());
        view.refresh(cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let document = inspector.read(cx).document.as_ref().unwrap();
        assert!(document.preview.request_json().contains("new draft"));
        assert!(!document.preview.request_json().contains("old draft"));
    });
}

#[gpui::test]
fn older_prepare_completion_cannot_replace_newer_refresh_or_copied_document(
    cx: &mut TestAppContext,
) {
    let (_directory, window, _root) = fixture(cx, "older prepared draft", true);
    let (_, inspector) = open(window, cx);
    let (older_generation, older_document) = cx.read(|cx| {
        let view = inspector.read(cx);
        (view.generation, view.document.as_ref().unwrap().clone())
    });
    window
        .update(cx, |view, _, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.set_text("newer prepared draft".into(), cx)
            });
        })
        .unwrap();
    inspector.update(cx, |view, cx| view.refresh(cx));
    cx.run_until_parked();
    let (newer_generation, newer_document) = inspector.update(cx, |view, cx| {
        let document = view.document.as_ref().unwrap().clone();
        view.copy_request(cx);
        (view.generation, document)
    });
    cx.run_until_parked();
    assert_ne!(older_generation, newer_generation);
    assert!(
        newer_document
            .preview
            .request_json()
            .contains("newer prepared draft")
    );
    inspector.update(cx, |view, cx| {
        view.install(older_generation, Ok(older_document), cx);
        view.install(older_generation, Err("late preparation failed".into()), cx);
        assert_eq!(view.generation, newer_generation);
        assert!(Arc::ptr_eq(
            view.document.as_ref().unwrap(),
            &newer_document
        ));
        assert!(view.notice.is_none());
        view.copy_request(cx);
    });
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(newer_document.preview.request_json())
    );
}

#[gpui::test]
fn installed_snapshot_keeps_page_and_copy_when_later_draft_changes(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "captured draft", true);
    let (_, inspector) = open(window, cx);
    let (generation, full, reader) = cx.read(|cx| {
        let view = inspector.read(cx);
        (
            view.generation,
            view.document
                .as_ref()
                .unwrap()
                .preview
                .request_json()
                .to_owned(),
            view.reader.entity_id(),
        )
    });
    window
        .update(cx, |view, _, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.set_text("new unsent draft".into(), cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        assert_eq!(view.generation, generation);
        assert_eq!(view.reader.entity_id(), reader);
        assert_eq!(view.document.as_ref().unwrap().preview.request_json(), full);
        assert!(
            view.notice
                .as_deref()
                .unwrap()
                .contains("captured snapshot")
        );
        view.copy_request(cx);
    });
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        Some(full)
    );
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        "new unsent draft"
    );
}

#[gpui::test]
fn refresh_invalidates_old_copy_and_edit_hold_blocks_new_preparation(cx: &mut TestAppContext) {
    let (_directory, window, _) = fixture(cx, "captured", true);
    let (_, inspector) = open(window, cx);
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("clipboard sentinel".into())));
    inspector.update(cx, |view, cx| {
        view.copy_request(cx);
        view.refresh(cx);
    });
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some("clipboard sentinel")
    );
    window
        .update(cx, |view, _, cx| {
            view.editing = Some("held-edit".into());
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        // A previously prepared document remains readable, but Refresh must
        // obey the source app's unconditional queued/message editing guard.
        assert!(view.document.is_some());
        view.refresh(cx);
        assert!(view.document.is_none());
        assert!(!view.loading);
        assert!(view.notice.as_deref().unwrap().contains("Save or cancel"));
    });
}

#[gpui::test]
fn replaced_controller_and_owner_rebind_close_old_inspectors(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "draft", true);
    let (_, old) = open(window, cx);
    let stale_target = cx.read(|cx| root.read(cx).context_inspector_target());
    let id = stale_target.chat.clone();
    root.update(cx, |view, cx| {
        let replacement = configured(SessionStore::pending_with_id(&id).unwrap());
        view.chat.replace_controller(replacement, cx);
        cx.notify();
    });
    cx.run_until_parked();
    assert!(cx.read(|cx| old.read(cx).closed));
    window
        .update(cx, |view, window, cx| {
            view.open_context_inspector(&stale_target, window, cx);
            assert!(
                view.inspector_windows
                    .iter()
                    .all(|entry| !entry.target.same_scope(&view.context_inspector_target()))
            );
        })
        .unwrap();
    let (_, rebound) = open(window, cx);
    window
        .update(cx, |view, window, cx| view.bind_window(window, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| rebound.read(cx).closed));
    assert!(cx.read(|cx| root.read(cx).inspector_windows.is_empty()));
}

#[gpui::test]
fn closed_and_reopened_window_rejects_late_result_and_releases_body(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "private snapshot", true);
    let (handle, old) = open(window, cx);
    let generation = cx.read(|cx| old.read(cx).generation);
    let prepared = cx.read(|cx| {
        Arc::new(PreparedDocument::new(
            root.read(cx)
                .controller
                .prepare_context("private snapshot")
                .unwrap(),
        ))
    });
    handle
        .update(cx, |view, window, cx| view.close(window, cx))
        .unwrap();
    cx.run_until_parked();
    let (new_handle, new) = open(window, cx);
    assert_ne!(new_handle.window_id(), handle.window_id());
    old.update(cx, |view, cx| {
        view.install(generation, Ok(prepared), cx);
        view.refresh(cx);
        assert!(view.closed && view.document.is_none() && !view.loading);
        assert!(view.reader.read(cx).text().is_empty());
    });
    assert!(cx.read(|cx| new.read(cx).document.is_some()));
}

#[gpui::test]
fn workspace_shutdown_closes_secondary_windows_without_owner_reentry(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, "draft", true);
    let (handle, inspector) = open(window, cx);
    root.update(cx, |view, cx| {
        let operation = uuid::Uuid::new_v4();
        view.shutdown_operation = Some(operation);
        view.shutting_down = true;
        assert!(view.finish_shutdown(
            operation,
            ShutdownOutcome {
                registered: Vec::new(),
                catalog_uncertain: false,
                result: Ok(())
            },
            cx
        ));
        assert!(view.inspector_windows.is_empty());
    });
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(inspector.read(cx).closed);
        assert!(
            !cx.windows()
                .iter()
                .any(|window| window.window_id() == handle.window_id())
        );
        assert!(
            cx.windows()
                .iter()
                .any(|open| open.window_id() == window.window_id())
        );
    });
}

#[gpui::test]
fn large_request_uses_bounded_pages_and_copies_exact_full_immutable_body(cx: &mut TestAppContext) {
    let draft = "日本語 👩🏽‍💻 e\u{301}\n".repeat(6_000);
    let (_directory, window, _) = fixture(cx, &draft, true);
    let (handle, inspector) = open(window, cx);
    let full = cx.read(|cx| {
        inspector
            .read(cx)
            .document
            .as_ref()
            .unwrap()
            .preview
            .request_json()
            .to_owned()
    });
    assert!(full.len() > PAGE_BYTES);
    inspector.update(cx, |view, cx| {
        let document = view.document.as_ref().unwrap();
        assert!(document.pages.len() > 1);
        assert!(view.reader.read(cx).text().len() <= PAGE_BYTES);
        view.show_page(document.pages.len() - 1, cx);
        assert!(view.reader.read(cx).text().len() <= PAGE_BYTES);
        view.copy_request(cx);
    });
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        Some(full)
    );
    let mut visual = VisualTestContext::from_window(handle.into(), cx);
    visual.simulate_resize(size(px(MINIMUM_SIZE.0), px(MINIMUM_SIZE.1)));
    cx.run_until_parked();
    let reader = visual.debug_bounds("context-inspector-reader").unwrap();
    let copy = visual.debug_bounds("context-inspector-copy").unwrap();
    assert!(reader.size.height > px(100.));
    assert!(reader.bottom() <= px(MINIMUM_SIZE.1));
    assert!(copy.right() <= px(MINIMUM_SIZE.0));
    let page = cx.read(|cx| inspector.read(cx).reader.read(cx).text().to_owned());
    cx.simulate_input(handle.into(), "cannot edit");
    assert_eq!(
        cx.read(|cx| inspector.read(cx).reader.read(cx).text().to_owned()),
        page
    );
    cx.simulate_keystrokes(
        handle.into(),
        if cfg!(target_os = "macos") {
            "cmd-w"
        } else {
            "ctrl-w"
        },
    );
    cx.run_until_parked();
    assert!(cx.read(|cx| inspector.read(cx).closed));
}

#[gpui::test]
fn attachment_only_change_marks_captured_preview_stale_and_refresh_is_honest(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root) = fixture(cx, "same text", true);
    let (_, inspector) = open(window, cx);
    let captured = cx.read(|cx| {
        inspector
            .read(cx)
            .document
            .as_ref()
            .unwrap()
            .preview
            .request_json()
            .to_owned()
    });
    root.update(cx, |view, cx| {
        view.attachments
            .push(bello_agent_core::attachments::AttachmentRecord {
                id: uuid::Uuid::new_v4().to_string(),
                path: "/missing/preview.gif".into(),
                sha256: "a".repeat(64),
                bytes: 6,
                mime_type: "image/gif".into(),
            });
        // Isolate metadata equality: revision and text deliberately stay equal.
        cx.notify();
    });
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        assert_eq!(
            view.document.as_ref().unwrap().preview.request_json(),
            captured
        );
        assert!(!view.current(view.document.as_ref().unwrap(), cx).unwrap());
        assert!(
            view.notice
                .as_deref()
                .unwrap()
                .contains("captured snapshot")
        );
        view.refresh(cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let reader = inspector.read(cx);
        assert!(reader.document.is_none());
        assert!(reader.notice.is_some());
        let owner = root.read(cx);
        assert_eq!(owner.composer.read(cx).text(), "same text");
        assert_eq!(owner.attachments.len(), 1);
        assert!(owner.controller.snapshot().messages.is_empty());
        assert!(!owner.controller.is_persistent());
    });
}

#[gpui::test]
fn attachment_capture_compares_full_metadata_and_revision_even_after_equal_text(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root) = fixture(cx, "unchanged", true);
    let (_, inspector) = open(window, cx);
    let revision = cx.read(|cx| root.read(cx).draft_revision);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        view.draft_changed(&id, cx);
        cx.notify();
    });
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        assert_eq!(view.draft_revision, revision);
        assert!(!view.current(view.document.as_ref().unwrap(), cx).unwrap());
    });
}

#[cfg(feature = "synthetic-authority")]
fn wait_skill_preview(inspector: &Entity<ContextInspector>, cx: &mut TestAppContext) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
    loop {
        cx.run_until_parked();
        if cx.read(|cx| !inspector.read(cx).loading && !inspector.read(cx).copying) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "skill preview did not settle"
        );
        std::thread::sleep(std::time::Duration::from_millis(3));
    }
}

#[cfg(feature = "synthetic-authority")]
#[gpui::test]
fn saved_skill_context_captures_ordered_arguments_and_keeps_immutable_copy(
    cx: &mut TestAppContext,
) {
    use crate::composer_skills::tests::saved_ui;
    let (_directory, window, root) = saved_ui::fixture(cx, "raw draft");
    let selected = saved_ui::select(&root, 1, cx);
    saved_ui::close(window, cx);
    let before = cx.read(|cx| serde_json::to_value(root.read(cx).controller.snapshot()).unwrap());
    let (_handle, inspector) = open(window, cx);
    wait_skill_preview(&inspector, cx);
    let original = inspector.update(cx, |view, _| {
        let document = view
            .document
            .as_ref()
            .unwrap_or_else(|| panic!("{:?}", view.notice));
        assert_eq!(view.skills, vec![selected.selection.clone()]);
        let json = document.preview.request_json().to_owned();
        assert!(json.contains("BODY-MARKER-a"));
        assert!(json.contains("Current explicit selection IDs:"));
        assert!(json.contains("raw draft"));
        json
    });
    root.update(cx, |view, cx| {
        view.skills[0].selection.arguments = "later literal /review arguments".into();
        let id = view.record.id.clone();
        view.draft_changed(&id, cx);
        cx.notify();
    });
    cx.run_until_parked();
    inspector.update(cx, |view, cx| {
        assert!(!view.current(view.document.as_ref().unwrap(), cx).unwrap());
        assert!(
            view.notice
                .as_deref()
                .unwrap()
                .contains("captured snapshot")
        );
        view.copy_request(cx);
    });
    wait_skill_preview(&inspector, cx);
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text().unwrap()),
        original
    );
    inspector.update(cx, |view, cx| view.refresh(cx));
    wait_skill_preview(&inspector, cx);
    inspector.update(cx, |view, _| {
        let json = view
            .document
            .as_ref()
            .unwrap_or_else(|| panic!("{:?}", view.notice))
            .preview
            .request_json();
        assert!(json.contains("later literal /review arguments"));
    });
    assert_eq!(
        cx.read(|cx| serde_json::to_value(root.read(cx).controller.snapshot()).unwrap()),
        before
    );
}

#[cfg(feature = "synthetic-authority")]
#[gpui::test]
fn changed_skill_source_blocks_idle_context_without_losing_draft_selection(
    cx: &mut TestAppContext,
) {
    use crate::composer_skills::tests::saved_ui;
    let (_directory, window, root) = saved_ui::fixture(cx, "raw draft");
    let selected = saved_ui::select(&root, 1, cx);
    saved_ui::close(window, cx);
    std::fs::write(&selected.path, "---\nname: review\ndescription: changed\ndisable-model-invocation: true\n---\nchanged source\n").unwrap();
    let (_handle, inspector) = open(window, cx);
    wait_skill_preview(&inspector, cx);
    inspector.update(cx, |view, _| {
        assert!(view.document.is_none());
        assert!(view.notice.is_some());
    });
    root.update(cx, |view, cx| {
        assert_eq!(view.skills, vec![selected]);
        assert_eq!(view.composer.read(cx).text(), "raw draft");
        assert!(view.session.pending.is_empty());
        assert!(view.session.messages.is_empty());
    });
}
