//! GPUI TestPlatform evidence only. Real platform focus/IME/AX remain separate.
use super::*;
use std::time::Duration;
fn search(window: WindowHandle<AgentView>, text: &str, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            view.show_transcript_find(window, cx);
            let query = view.transcript_find.as_ref().unwrap().query.clone();
            query.update(cx, |editor, cx| editor.set_text(text.into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
}
#[gpui::test]
fn find_pages_all_retained_rows_preserves_draft_checkpoint_clipboard_and_cache(
    cx: &mut TestAppContext,
) {
    let (dir, window, root) = fixture_with_visible(cx, messages(240), 0, Some(30));
    let session_path = cx.read(|cx| root.read(cx).record.snapshot.clone());
    let before = std::fs::read(&session_path).unwrap();
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("clipboard sentinel".into())));
    let child = transcript(&root, cx);
    let prior = renders(&child, cx);
    search(window, "Transcript", cx);
    cx.read(|cx| {
        let view = root.read(cx);
        let bar = view.transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.total(), 240);
        assert!(!bar.state.searching);
        assert!(!bar.state.failed);
        assert_eq!(view.composer.read(cx).text(), "draft");
        assert_eq!(
            cx.read_from_clipboard().unwrap().text().unwrap(),
            "clipboard sentinel"
        );
        assert_eq!(bar.state.groups().len(), 240);
    });
    assert!(
        renders(&child, cx) > prior,
        "cached child receives Find invalidation"
    );
    assert_eq!(std::fs::read(session_path).unwrap(), before);
    drop(dir);
}
#[gpui::test]
fn find_close_reopen_debounce_aba_starts_blank_and_stale_work_cannot_publish(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, messages(3), 0);
    window
        .update(cx, |view, w, cx| {
            view.show_transcript_find(w, cx);
            let editor = view.transcript_find.as_ref().unwrap().query.clone();
            editor.update(cx, |e, cx| e.set_text("Transcript".into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    let old = cx.read(|cx| root.read(cx).transcript_find.as_ref().unwrap().identity);
    window
        .update(cx, |v, w, cx| {
            v.close_transcript_find(w, cx);
            v.show_transcript_find(w, cx);
        })
        .unwrap();
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.run_until_parked();
    cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_ne!(bar.identity, old);
        assert!(bar.state.query.is_empty());
        assert_eq!(bar.state.total(), 0);
        assert!(bar.matcher.is_none());
    });
    search(window, "Transcript", cx);
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .total(),
            3
        )
    });
}
#[gpui::test]
fn find_next_previous_wrap_and_close_preserve_composer_focus_owner(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(
        cx,
        vec![message("one", "assistant", "needle needle needle")],
        0,
    );
    search(window, "needle", cx);
    window
        .update(cx, |v, _, cx| {
            assert_eq!(v.transcript_find.as_ref().unwrap().state.ordinal(), Some(0));
            v.step_transcript_find(true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .ordinal(),
            Some(2)
        )
    });
    window
        .update(cx, |v, _, cx| v.step_transcript_find(false, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .ordinal(),
            Some(0)
        )
    });
    window
        .update(cx, |v, w, cx| {
            v.composer.read(cx).focus(w);
            v.close_transcript_find(w, cx);
            assert!(v.composer.read(cx).focus_handle(cx).is_focused(w));
        })
        .unwrap();
}
#[gpui::test]
fn find_wrong_displayed_bytes_cannot_receive_old_highlights(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, vec![message("one", "assistant", "needle")], 0);
    search(window, "needle", cx);
    root.update(cx, |view, cx| {
        let mut changed = (*view.session).clone();
        changed.messages[0].text = "xxxxxx".into();
        view.session = Arc::new(changed);
        view.sync_transcript_inputs(cx);
        cx.notify();
    });
    cx.run_until_parked();
    let child = transcript(&root, cx);
    cx.read(|cx| assert!(!child.read(cx).find_has_current_binding()));
}
#[gpui::test]
fn find_tool_output_omission_is_truthful_and_input_does_not_match(cx: &mut TestAppContext) {
    let output = format!("{} needle", "x".repeat(9000));
    let (_dir, window, root) = fixture(cx, retained_tool_rows(1, &output), 0);
    search(window, "needle", cx);
    cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.total(), 1);
        assert!(
            bar.notice
                .as_deref()
                .is_some_and(|s| s.contains("outside") || s.contains("preview")),
            "{:?}",
            bar.notice
        );
    });
}

#[gpui::test]
fn find_noncontent_publications_do_not_starve_search_or_rollback_queued_rewrite(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, messages(240), 2);
    let controller = cx.read(|cx| root.read(cx).controller.clone());
    let old = controller.snapshot_shared();
    let original_token = controller.find_snapshot().unwrap();
    window
        .update(cx, |view, w, cx| {
            view.show_transcript_find(w, cx);
            view.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| e.set_text("Transcript".into(), cx));
            view.composer
                .update(cx, |e, cx| e.set_text("newer 日本語 draft".into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    for _ in 0..32 {
        let mut ids: Vec<_> = controller
            .snapshot_shared()
            .pending
            .iter()
            .map(|q| q.id.clone())
            .collect();
        ids.reverse();
        controller.reorder(&ids).unwrap();
    }
    let mut ids: Vec<_> = controller
        .snapshot_shared()
        .pending
        .iter()
        .map(|q| q.id.clone())
        .collect();
    ids.reverse();
    controller.reorder(&ids).unwrap();
    let latest = controller.find_snapshot().unwrap();
    assert!(original_token.same_content(&latest));
    assert!(!Arc::ptr_eq(&old, &latest.session_shared()));
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        view.receive_snapshot(&id, &Arc::downgrade(&controller), old, cx);
    });
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.session
                .pending
                .iter()
                .map(|q| q.id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_eq!(view.composer.read(cx).text(), "newer 日本語 draft");
        let bar = view.transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.total(), 240);
        assert!(!bar.state.searching);
        assert!(bar.binding.same_content(&latest));
        assert!(Arc::ptr_eq(
            &bar.binding.session_shared(),
            &latest.session_shared()
        ));
        assert!(
            view.display_find_binding
                .as_ref()
                .unwrap()
                .same_content(&latest)
        );
    });
}

#[gpui::test]
fn find_long_prose_lands_on_selected_occurrence_without_revealing_row_top(cx: &mut TestAppContext) {
    let text = (0..300)
        .map(|i| {
            if i == 260 {
                "needle".into()
            } else {
                format!("wrapped line {i} 日本語")
            }
        })
        .collect::<Vec<String>>()
        .join("\n");
    let (_dir, window, root) = fixture(cx, vec![message("long", "assistant", &text)], 0);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    cx.read(|cx| {
        let view = child.read(cx);
        assert!(view.find_landed());
        assert!(
            view.list_state().logical_scroll_top().offset_in_item > px(3000.),
            "Find must use exact text geometry inside the row"
        );
    });
}

#[gpui::test]
fn find_manual_scroll_cancels_delayed_landing_and_timeout_notice(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, messages(240), 0);
    search(window, "Transcript", cx);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let target = scroll(&child, cx).viewport_bounds().center();
    visual.simulate_event(ScrollWheelEvent {
        position: target,
        delta: ScrollDelta::Pixels(point(px(0.), px(-123.))),
        ..Default::default()
    });
    cx.run_until_parked();
    let after = anchor(&child, cx);
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), after);
    cx.read(|cx| {
        assert!(
            !root
                .read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .as_deref()
                .is_some_and(|n| n.contains("geometry") || n.contains("retry"))
        )
    });
}

#[gpui::test]
fn find_synthetic_ime_unmark_commits_query_without_enter_navigation_or_draft_mutation(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, vec![message("one", "assistant", "日本語 needle")], 0);
    window
        .update(cx, |v, w, cx| {
            v.show_transcript_find(w, cx);
            let query = v.transcript_find.as_ref().unwrap().query.clone();
            query.update(cx, |e, cx| {
                e.replace_and_mark_text_in_range(None, "日本語", Some(3..3), w, cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .query
                .is_empty()
        )
    });
    window
        .update(cx, |v, w, cx| {
            v.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| e.unmark_text(w, cx));
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
    cx.read(|cx| {
        let v = root.read(cx);
        let bar = v.transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.query, "日本語");
        assert_eq!(bar.state.total(), 1);
        assert_eq!(v.composer.read(cx).text(), "draft");
    });
}

#[gpui::test]
fn find_tool_read_middle_expands_and_inner_scroll_keeps_find_focus_and_caret(
    cx: &mut TestAppContext,
) {
    use bello_agent_core::tool_history::ToolRecord;
    let text = (0..100)
        .map(|i| format!("line-{i} {}", if i == 75 { "needle" } else { "body" }))
        .collect::<Vec<_>>()
        .join("\n");
    let mut rows = retained_tool_rows(1, &text);
    if let Some(ToolRecord::Assistant(record)) = &mut rows[0].tool_record {
        record.calls[0].name = "read".into();
        record.calls[0].arguments = serde_json::json!({"path":"fixture.txt","offset":10});
    }
    let (_dir, window, root) = fixture(cx, rows, 0);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    window
        .update(cx, |view, window, cx| {
            assert!(
                view.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .read(cx)
                    .focus_handle(cx)
                    .is_focused(window)
            );
            let outputs: Vec<_> = child
                .read(cx)
                .tool_section_editors()
                .into_iter()
                .filter(|(label, _)| *label == "OUT")
                .collect();
            assert_eq!(outputs.len(), 1);
            let editor = outputs[0].1.read(cx);
            assert!(editor.text().contains("85  line-75 needle"));
            assert_eq!(editor.engine.cursor, 0);
            assert!(!editor.focus_handle(cx).is_focused(window));
            assert!(
                child.read(cx).find_landed(),
                "fresh inner geometry must settle navigation"
            );
        })
        .unwrap();
}

#[gpui::test]
fn find_blank_reopen_clears_old_prose_and_tool_decoration_owner(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx, retained_tool_rows(1, "needle needle"), 0);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    assert!(cx.read(|cx| child.read(cx).find_decoration_state().0));
    window
        .update(cx, |v, w, cx| {
            v.close_transcript_find(w, cx);
            v.show_transcript_find(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .query
                .is_empty()
        );
        assert_eq!(child.read(cx).find_decoration_state(), (false, 0));
    });
}

#[gpui::test]
fn find_shortcuts_route_query_steps_close_and_do_not_steal_editable_file_focus(
    cx: &mut TestAppContext,
) {
    let (dir, window, root) = fixture(cx, vec![message("one", "assistant", "needle needle")], 0);
    let command = if cfg!(target_os = "macos") {
        "cmd"
    } else {
        "ctrl"
    };
    cx.simulate_keystrokes(window.into(), &format!("{command}-f"));
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).transcript_find.is_some()));
    window
        .update(cx, |v, _, cx| {
            v.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| e.set_text("needle".into(), cx))
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .ordinal(),
            Some(1)
        )
    });
    cx.simulate_keystrokes(window.into(), "shift-enter");
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .state
                .ordinal(),
            Some(0)
        )
    });
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).transcript_find.is_none()));
    let path = dir.path().join("editable.txt");
    std::fs::write(&path, "editable needle").unwrap();
    window
        .update(cx, |v, w, cx| v.open_file(path, None, w, cx))
        .unwrap();
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), &format!("{command}-f"));
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).transcript_find.is_none()));
}

#[gpui::test]
fn find_active_read_path_click_defers_cleanup_until_child_borrow_ends(cx: &mut TestAppContext) {
    use bello_agent_core::tool_history::ToolRecord;
    let mut rows = retained_tool_rows(1, "needle source");
    if let Some(ToolRecord::Assistant(record)) = &mut rows[0].tool_record {
        record.calls[0].name = "read".into();
        record.calls[0].arguments = serde_json::json!({"path":"fixture.txt"});
    }
    let (dir, window, root) = fixture(cx, rows, 0);
    std::fs::write(dir.path().join("fixture.txt"), "needle source").unwrap();
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    let selector = Box::leak(
        format!(
            "{}-read-path",
            cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone())
        )
        .into_boxed_str(),
    );
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let bounds = visual.debug_bounds(selector).unwrap();
    visual.simulate_click(bounds.center(), Modifiers::none());
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.files.len(), 1);
        assert!(view.transcript_find.is_none());
        assert_eq!(view.composer.read(cx).text(), "draft");
    });
}

#[gpui::test]
fn find_composition_cancels_queued_search_and_unmark_restarts_unchanged_query(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, vec![message("one", "assistant", "needle")], 0);
    window
        .update(cx, |v, w, cx| {
            v.show_transcript_find(w, cx);
            v.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| e.set_text("needle".into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, w, cx| {
            v.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| {
                    e.replace_and_mark_text_in_range(Some(0..6), "needle", Some(6..6), w, cx);
                });
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(500));
    cx.run_until_parked();
    cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.total(), 0);
        assert!(bar.destination.is_none());
        assert!(bar.query.read(cx).has_marked_text());
    });
    window
        .update(cx, |v, w, cx| {
            v.transcript_find
                .as_ref()
                .unwrap()
                .query
                .clone()
                .update(cx, |e, cx| e.unmark_text(w, cx));
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(151));
    cx.run_until_parked();
    cx.read(|cx| {
        let v = root.read(cx);
        let bar = v.transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.total(), 1);
        assert!(!bar.state.searching);
        assert_eq!(v.composer.read(cx).text(), "draft");
    });
}

#[gpui::test]
fn find_real_tool_callback_rejects_outer_scroll_then_retries_fresh_geometry(
    cx: &mut TestAppContext,
) {
    let mut rows = messages(20);
    rows.extend(retained_tool_rows(1, "needle needle"));
    let (_dir, window, root) = fixture(cx, rows, 0);
    crate::transcript_view::pause_find_geometry(true);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    let before = cx.read(|cx| child.read(cx).find_geometry_state().unwrap());
    assert!(
        before.1 && !before.2,
        "actual fresh geometry receipt is held: {before:?}"
    );
    let list = scroll(&child, cx);
    let origin = list.logical_scroll_top();
    list.scroll_to(ListOffset {
        item_ix: origin.item_ix,
        offset_in_item: origin.offset_in_item + px(17.),
    });
    let changed = list.logical_scroll_top();
    assert_ne!(changed.offset_in_item, origin.offset_in_item);
    window
        .update(cx, |_, w, cx| {
            assert!(crate::transcript_view::resume_find_geometry(w, cx) > 0);
            let state = child.read(cx).find_geometry_state().unwrap();
            assert!(
                !state.1 && !state.2,
                "stale point rejected and reservation released: {state:?}"
            );
        })
        .unwrap();
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let state = child.read(cx).find_geometry_state().unwrap();
        assert!(state.0 > before.0 && state.0 <= 3);
        assert!(!state.1 && state.2, "fresh retry settles: {state:?}");
    });
}

#[gpui::test]
fn find_real_tool_callback_resize_and_same_content_replacement_release_reservation(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, retained_tool_rows(1, "needle"), 2);
    crate::transcript_view::pause_find_geometry(true);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    let controller = cx.read(|cx| root.read(cx).controller.clone());
    let token = controller.find_snapshot().unwrap();
    let mut ids: Vec<_> = controller
        .snapshot_shared()
        .pending
        .iter()
        .map(|q| q.id.clone())
        .collect();
    ids.reverse();
    controller.reorder(&ids).unwrap();
    root.update(cx, |v, cx| {
        let id = v.record.id.clone();
        v.receive_snapshot(
            &id,
            &Arc::downgrade(&controller),
            controller.snapshot_shared(),
            cx,
        );
    });
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(980.), px(710.)));
    cx.run_until_parked();
    assert!(token.same_content(&controller.find_snapshot().unwrap()));
    window
        .update(cx, |_, w, cx| {
            assert!(crate::transcript_view::resume_find_geometry(w, cx) > 0);
            let state = child.read(cx).find_geometry_state().unwrap();
            assert!(!state.1 && !state.2);
        })
        .unwrap();
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let state = child.read(cx).find_geometry_state().unwrap();
        assert!(state.0 <= 3 && !state.1 && state.2, "{state:?}");
    });
}

#[gpui::test]
fn find_prepared_scope_rejects_owner_or_role_change_with_identical_id_and_text(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx, retained_tool_rows(1, "needle"), 0);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    cx.read(|cx| {
        let original = root
            .read(cx)
            .session
            .messages
            .iter()
            .find(|m| m.text == "needle")
            .unwrap()
            .clone();
        assert!(child.read(cx).find_scope_matches(&original));
        let mut changed = original.clone();
        changed.role = "assistant".into();
        assert!(!child.read(cx).find_scope_matches(&changed));
        let mut changed = original.clone();
        if let Some(bello_agent_core::tool_history::ToolRecord::Result(result)) =
            &mut changed.tool_record
        {
            result.call_id.push_str("-other");
        }
        assert!(!child.read(cx).find_scope_matches(&changed));
        assert!(child.read(cx).find_scope_matches(&original));
    });
}

#[gpui::test]
fn find_composition_rejects_delayed_real_page_and_preparation_completions(cx: &mut TestAppContext) {
    for (page, preparation) in [(500, 0), (0, 500)] {
        let (_dir, window, root) = fixture(cx, messages(120), 0);
        crate::transcript_find_controller::set_find_completion_delays(page, preparation);
        search(window, "Transcript", cx);
        let child = transcript(&root, cx);
        let before = scroll(&child, cx).logical_scroll_top();
        window
            .update(cx, |v, w, cx| {
                v.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .clone()
                    .update(cx, |e, cx| {
                        e.replace_and_mark_text_in_range(
                            Some(0..10),
                            "Transcript",
                            Some(10..10),
                            w,
                            cx,
                        );
                    });
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(600));
        cx.run_until_parked();
        window
            .update(cx, |v, w, cx| {
                let bar = v.transcript_find.as_ref().unwrap();
                assert!(bar.destination.is_none());
                assert!(bar.query.read(cx).focus_handle(cx).is_focused(w));
                let after = child.read(cx).list_state().logical_scroll_top();
                assert_eq!(before.item_ix, after.item_ix);
                assert_eq!(before.offset_in_item, after.offset_in_item);
                assert_eq!(v.composer.read(cx).text(), "draft");
            })
            .unwrap();
        crate::transcript_find_controller::set_find_completion_delays(0, 0);
        window
            .update(cx, |v, w, cx| {
                v.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .clone()
                    .update(cx, |e, cx| e.unmark_text(w, cx));
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(151));
        cx.run_until_parked();
        cx.read(|cx| {
            assert_eq!(
                root.read(cx)
                    .transcript_find
                    .as_ref()
                    .unwrap()
                    .state
                    .total(),
                120
            )
        });
    }
}

#[gpui::test]
fn find_real_tool_geometry_retries_are_bounded_after_repeated_outer_changes(
    cx: &mut TestAppContext,
) {
    let mut rows = messages(20);
    rows.extend(retained_tool_rows(1, "needle"));
    let (_dir, window, root) = fixture(cx, rows, 0);
    crate::transcript_view::pause_find_geometry(true);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    for _ in 0..3 {
        let list = scroll(&child, cx);
        let origin = list.logical_scroll_top();
        list.scroll_to(ListOffset {
            item_ix: origin.item_ix,
            offset_in_item: origin.offset_in_item + px(5.),
        });
        window
            .update(cx, |_, w, cx| {
                assert!(crate::transcript_view::resume_find_geometry(w, cx) > 0);
            })
            .unwrap();
        cx.run_until_parked();
    }
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(child.read(cx).find_geometry_state(), Some((3, false, true)));
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .as_deref()
                .is_some_and(|n| n.contains("kept changing"))
        );
    });
}

fn assert_find_outside_measured_bar(
    window: WindowHandle<AgentView>,
    _root: &Entity<AgentView>,
    child: &Entity<TranscriptView>,
    cx: &mut TestAppContext,
) {
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let bar = visual.debug_bounds("conversation-find-bar").unwrap();
    cx.read(|cx| {
        let viewport = child.read(cx).list_state().viewport_bounds();
        let selected = child
            .read(cx)
            .find_confirmed_geometry()
            .expect("fresh visibility confirmation");
        assert!(
            viewport.top() >= bar.bottom(),
            "viewport {viewport:?}, bar {bar:?}"
        );
        assert!(
            selected.top() >= viewport.top() && selected.bottom() <= viewport.bottom(),
            "selected {selected:?}, viewport {viewport:?}"
        );
    });
}

#[gpui::test]
fn find_landmark_first_and_early_later_row_clear_actual_bar_and_wrapped_notice(
    cx: &mut TestAppContext,
) {
    let mut rows = messages(240);
    rows[0].text = "landmark first".into();
    rows[119].text = "landmark early in row\nsecond landmark on next line".into();
    rows[239].text = "landmark last".into();
    let (_dir, window, root) = fixture(cx, rows, 0);
    search(window, "landmark", cx);
    let child = transcript(&root, cx);
    assert_find_outside_measured_bar(window, &root, &child, cx);
    for _ in 0..2 {
        window
            .update(cx, |v, _, cx| v.step_transcript_find(false, cx))
            .unwrap();
        cx.run_until_parked();
        assert_find_outside_measured_bar(window, &root, &child, cx);
    }
    root.update(cx, |v,cx| { v.transcript_find.as_mut().unwrap().notice=Some("A deliberately tall wrapped notice tests the measured exclusion band across narrow windows and multiple lines. ".repeat(3)); cx.notify(); });
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(760.), px(840.)));
    cx.run_until_parked();
    window
        .update(cx, |v, _, cx| v.step_transcript_find(true, cx))
        .unwrap();
    cx.run_until_parked();
    assert_find_outside_measured_bar(window, &root, &child, cx);
    window
        .update(cx, |v, w, cx| v.close_transcript_find(w, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).transcript_find.is_none()));
}

#[gpui::test]
fn find_long_prose_scroll_request_requires_next_actual_paint_confirmation(cx: &mut TestAppContext) {
    let text = (0..300)
        .map(|i| {
            if i == 260 {
                "needle".to_string()
            } else {
                format!("line {i}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let (_dir, window, root) = fixture(cx, vec![message("long", "assistant", &text)], 0);
    crate::transcript_view::pause_find_geometry(true);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    assert!(!cx.read(|cx| child.read(cx).find_landed()));
    window
        .update(cx, |_, w, cx| {
            assert!(crate::transcript_view::resume_find_geometry(w, cx) > 0);
            assert!(
                !child.read(cx).find_landed(),
                "requesting scroll is not confirmation"
            );
        })
        .unwrap();
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_find_outside_measured_bar(window, &root, &child, cx);
}

#[gpui::test]
fn find_flow_resize_notice_close_reopen_rejects_old_prose_geometry(cx: &mut TestAppContext) {
    let text = (0..150)
        .map(|i| {
            if i == 100 {
                "needle needle".to_string()
            } else {
                format!("line {i}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let (_dir, window, root) = fixture(cx, vec![message("long", "assistant", &text)], 0);
    crate::transcript_view::pause_find_geometry(true);
    search(window, "needle", cx);
    let child = transcript(&root, cx);
    root.update(cx, |v, cx| {
        v.transcript_find.as_mut().unwrap().notice = Some("a tall wrapping notice ".repeat(18));
        cx.notify();
    });
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(760.), px(840.)));
    cx.run_until_parked();
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    assert!(!cx.read(|cx| child.read(cx).find_landed()));
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |_, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert_find_outside_measured_bar(window, &root, &child, cx);
    crate::transcript_view::pause_find_geometry(true);
    window
        .update(cx, |v, _, cx| v.step_transcript_find(false, cx))
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, w, cx| {
            v.close_transcript_find(w, cx);
            v.show_transcript_find(w, cx);
        })
        .unwrap();
    cx.run_until_parked();
    crate::transcript_view::pause_find_geometry(false);
    window
        .update(cx, |v, w, cx| {
            crate::transcript_view::resume_find_geometry(w, cx);
            assert!(v.transcript_find.as_ref().unwrap().state.query.is_empty());
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| child.read(cx).find_decoration_state()),
        (false, 0)
    );
    let with_bar = scroll(&child, cx).viewport_bounds();
    window
        .update(cx, |v, w, cx| v.close_transcript_find(w, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(
        scroll(&child, cx).viewport_bounds().size.height > with_bar.size.height,
        "closing removes all reserved bar space"
    );
}

#[gpui::test]
fn find_multiline_span_fits_adaptive_padding_and_oversized_notice_keeps_first_line_visible(
    cx: &mut TestAppContext,
) {
    let text = format!(
        "{}{}END\n{}",
        "prefix\n".repeat(80),
        "z\n".repeat(100),
        "tail\n".repeat(100)
    );
    let (_dir, window, root) = fixture(cx, vec![message("long", "assistant", &text)], 0);
    window
        .update(cx, |v, w, cx| v.show_transcript_find(w, cx))
        .unwrap();
    cx.run_until_parked();
    let child = transcript(&root, cx);
    let height = f32::from(scroll(&child, cx).viewport_bounds().size.height);
    let fitting_lines = (height * 0.8 / 21.).floor() as usize;
    let query = format!("{}END", "z\n".repeat(fitting_lines));
    search(window, &query, cx);
    assert_find_outside_measured_bar(window, &root, &child, cx);
    cx.read(|cx| {
        let measured = child.read(cx).find_confirmed_geometry().unwrap();
        let viewport = child.read(cx).list_state().viewport_bounds();
        assert!(measured.size.height > viewport.size.height * (2. / 3.));
        assert!(measured.size.height <= viewport.size.height);
    });
    let query = format!("{}END", "z\n".repeat((height / 21.).ceil() as usize + 12));
    search(window, &query, cx);
    assert_find_outside_measured_bar(window, &root, &child, cx);
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .as_deref()
                .is_some_and(|n| n.contains("only its first line"))
        );
        assert!(
            child
                .read(cx)
                .find_confirmed_geometry()
                .unwrap()
                .size
                .height
                < px(30.)
        );
    });
    let before = scroll(&child, cx).logical_scroll_top();
    for _ in 0..12 {
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
    }
    let after = scroll(&child, cx).logical_scroll_top();
    assert_eq!(before.item_ix, after.item_ix);
    assert_eq!(before.offset_in_item, after.offset_in_item);
    assert_find_outside_measured_bar(window, &root, &child, cx);
}

#[gpui::test]
fn find_notice_belongs_to_current_destination_and_stale_receipts_cannot_restore_it(
    cx: &mut TestAppContext,
) {
    let mut rows = vec![message("exact", "assistant", "needle")];
    rows.extend(retained_tool_rows(
        1,
        &format!("{} needle", "x".repeat(9000)),
    ));
    let (_dir, window, root) = fixture(cx, rows, 0);
    search(window, "needle", cx);
    root.update(cx, |v, cx| v.step_transcript_find(false, cx));
    cx.run_until_parked();
    let old = cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.ordinal(), Some(1));
        assert!(bar.notice.as_deref().is_some_and(|n| n.contains("preview")));
        bar.destination.clone().unwrap()
    });
    root.update(cx, |v, cx| {
        v.step_transcript_find(true, cx);
        assert!(v.transcript_find.as_ref().unwrap().notice.is_none());
        v.find_landing_notice(&old, "stale unavailable preview".into(), cx);
        assert!(v.transcript_find.as_ref().unwrap().notice.is_none());
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.ordinal(), Some(0));
        assert!(bar.notice.is_none(), "{:?}", bar.notice);
    });
    root.update(cx, |v, cx| v.step_transcript_find(false, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .as_deref()
                .is_some_and(|n| n.contains("preview"))
        )
    });
}

#[gpui::test]
fn find_oversized_notice_clears_for_short_query_and_old_result_cannot_restore_it(
    cx: &mut TestAppContext,
) {
    let text = format!("{}END\nshortneedle", "z\n".repeat(100));
    let (_dir, window, root) = fixture(cx, vec![message("long", "assistant", &text)], 0);
    search(window, &format!("{}END", "z\n".repeat(80)), cx);
    let old = cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert!(
            bar.notice
                .as_deref()
                .is_some_and(|n| n.contains("only its first line"))
        );
        bar.destination.clone().unwrap()
    });
    search(window, "shortneedle", cx);
    root.update(cx, |v, cx| {
        v.find_landing_notice(&old, "stale oversized notice".into(), cx)
    });
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .is_none()
        )
    });
    let child = transcript(&root, cx);
    assert_find_outside_measured_bar(window, &root, &child, cx);
}

#[gpui::test]
fn find_same_tool_output_omitted_to_prefix_replaces_only_old_result_notice(
    cx: &mut TestAppContext,
) {
    let output = format!("needle {} needle", "x".repeat(9000));
    let (_dir, window, root) = fixture(cx, retained_tool_rows(1, &output), 0);
    search(window, "needle", cx);
    root.update(cx, |v, cx| v.step_transcript_find(false, cx));
    cx.run_until_parked();
    let old = cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert!(bar.notice.as_deref().is_some_and(|n| n.contains("outside")));
        bar.destination.clone().unwrap()
    });
    root.update(cx, |v, cx| {
        v.step_transcript_find(true, cx);
        assert!(v.transcript_find.as_ref().unwrap().notice.is_none());
        v.find_landing_notice(&old, "old unavailable geometry".into(), cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let bar = root.read(cx).transcript_find.as_ref().unwrap();
        assert_eq!(bar.state.ordinal(), Some(0));
        assert!(
            !bar.notice
                .as_deref()
                .is_some_and(|n| n.contains("outside") || n.contains("old unavailable")),
            "{:?}",
            bar.notice
        );
    });
    root.update(cx, |v, cx| v.step_transcript_find(false, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .transcript_find
                .as_ref()
                .unwrap()
                .notice
                .as_deref()
                .is_some_and(|n| n.contains("outside"))
        )
    });
}
