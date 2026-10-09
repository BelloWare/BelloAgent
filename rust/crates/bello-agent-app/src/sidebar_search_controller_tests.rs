use super::*;

#[test]
fn production_readiness_is_closed_without_accepted_privacy_receipt() {
    let state = SidebarSearch::default();
    assert!(!state.readiness.is_ready());
    assert!(state.request.is_none());
    assert!(state.cache.cache.is_none());
    assert!(state.hit("missing").is_none());
}

#[test]
fn retirement_revokes_preparing_query_and_keeps_map_gap_tombstone() {
    let mut state = SidebarSearch::default();
    let request = SearchRequest::new("needle", 1).unwrap();
    state.request = Some(request.clone());
    state.preparing = true;
    let epoch = state.epoch;
    state.block("chat");
    assert!(request.is_cancelled());
    assert_ne!(epoch, state.epoch);
    assert!(!state.preparing);
    assert_eq!(state.test_route("chat"), Some(SourceRoute::Blocked));
    state.cancel();
    assert_eq!(state.routes.route("chat"), Some(SourceRoute::Blocked));
    state.installed("chat");
    assert_eq!(state.routes.route("chat"), Some(SourceRoute::Loaded));
}

#[test]
fn cancellation_does_not_release_shared_source_permit() {
    let mut lane = crate::sidebar_run_state::SidebarRunStates::default();
    let first = Uuid::new_v4();
    assert!(lane.reserve_reveal(first));
    lane.cancel_pending();
    assert!(!lane.reserve_reveal(Uuid::new_v4()));
    lane.finish_reveal(Uuid::new_v4());
    assert!(!lane.is_idle());
    lane.finish_reveal(first);
    assert!(lane.is_idle());
}

#[test]
fn changing_loaded_member_yields_to_unvisited_saved_members() {
    let mut state = SidebarSearch::default();
    state
        .pending
        .extend(["a-streaming".into(), "z-saved".into()]);
    state.served.insert("a-streaming".into());
    assert_eq!(state.next_id(), Some("z-saved"));
    state.served.insert("z-saved".into());
    assert_eq!(state.next_id(), Some("a-streaming"));
}

#[cfg(all(feature = "synthetic-authority", target_os = "linux"))]
mod workflow {
    use super::*;
    use crate::{AgentView, LaunchState};
    use bello_agent_core::{
        Controller, Lane, SessionStore, Submission,
        workspace::{ChatRecord, DraftRecord},
    };
    use gpui::{
        Entity, EntityInputHandler, TestAppContext, VisualTestContext, WindowHandle, px, size,
    };
    use std::sync::{Arc, Mutex};

    fn saved(owner: &mut WorkspaceStore, text: &str) -> (ChatRecord, SessionStore) {
        let id = Uuid::new_v4().to_string();
        let path = owner.chat_path(&id).unwrap();
        let mut store = SessionStore::pending_with_id(&id).unwrap();
        store.persist_to(&path).unwrap();
        store
            .transact(|session| {
                session.submit(Submission::new(text.into(), Lane::FollowUp))?;
                session.start_next()?;
                Ok(())
            })
            .unwrap();
        let record = ChatRecord::new(id, "Unrelated title".into(), path);
        owner
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        (record, store)
    }
    fn fixture(
        cx: &mut TestAppContext,
    ) -> (
        tempfile::TempDir,
        WindowHandle<AgentView>,
        Entity<AgentView>,
        ChatRecord,
    ) {
        fixture_kind(cx, false)
    }
    fn fixture_kind(
        cx: &mut TestAppContext,
        tool: bool,
    ) -> (
        tempfile::TempDir,
        WindowHandle<AgentView>,
        Entity<AgentView>,
        ChatRecord,
    ) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::Builder::new()
            .permissions(std::fs::Permissions::from_mode(0o700))
            .tempdir()
            .unwrap();
        let root = dir.path().canonicalize().unwrap();
        let mut owner = WorkspaceStore::open(root.join("catalog.json"), &root).unwrap();
        let (loaded, mut store) = saved(&mut owner, if tool { "context" } else { "loaded needle" });
        if tool {
            store
                .transact(|session| {
                    session
                        .messages
                        .extend(crate::transcript_view_tests::retained_tool_rows(
                            1,
                            "tool needle output",
                        ));
                    Ok(())
                })
                .unwrap();
        }
        let (unloaded, unloaded_store) = saved(&mut owner, "unopened needle");
        drop(unloaded_store);
        let owner = Arc::new(Mutex::new(owner));
        let membership = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
        let binding = bello_agent_core::sidebar_search::cache::CacheBinding::from_membership(
            membership.stamp(),
        )
        .unwrap();
        let cache = bello_agent_core::sidebar_search::cache::PrivateCache::open_synthetic_fixture(
            binding.clone(),
            &root,
        )
        .unwrap();
        let readiness = cache.readiness();
        let live_cache = cache.query_handle();
        let launch = LaunchState {
            controller: Controller::new(store, None).unwrap(),
            project: root,
            workspace: owner,
            record: loaded,
            draft: DraftRecord::default(),
            pending: false,
        };
        let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
        let view = window.root(cx).unwrap();
        let visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(1180.), px(812.)));
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            view.sidebar_search.readiness = readiness;
            view.sidebar_search.live_cache = Some(live_cache);
            view.sidebar_search.cache = WorkerCache {
                cache: Some(cache),
                binding: Some(binding),
                disposal: Some(cx.background_executor().clone()),
                registered: BTreeSet::new(),
            };
            view.filter
                .update(cx, |editor, cx| editor.set_text("needle".into(), cx));
            view.refresh_sidebar_search(cx);
            assert!(view.sidebar_search.debounce.is_some());
            assert!(view.sidebar_search.request.is_none());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(119));
        cx.run_until_parked();
        view.update(cx, |view, _| assert!(view.sidebar_search.request.is_none()));
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(1));
        cx.run_until_parked();
        // The source dispatcher drains its serial queue. Drive the same Render
        // hook once to request coverage, then once to publish its checked set.
        view.update(cx, |view, cx| view.refresh_sidebar_search(cx));
        cx.run_until_parked();
        view.update(cx, |view, cx| view.refresh_sidebar_search(cx));
        cx.run_until_parked();
        (dir, window, view, unloaded)
    }
    #[gpui::test]
    async fn actual_dispatch_finds_loaded_and_unopened_without_opening_unloaded(
        cx: &mut TestAppContext,
    ) {
        let (_dir, _window, view, unloaded) = fixture(cx);
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            view.refresh_sidebar_search(cx);

            assert!(view.chat_ref(&unloaded.id).is_none());
            assert!(view.sidebar_content_hit(&unloaded.id).is_some());
            assert!(view.sidebar_content_hit(&view.record.id).is_some());
            assert!(
                view.visible_sidebar_records(cx)
                    .iter()
                    .any(|r| r.id == unloaded.id)
            );
            view.sidebar_search.block(&unloaded.id);
            assert!(view.sidebar_content_hit(&unloaded.id).is_none());
        });
    }
    #[gpui::test]
    async fn same_chat_reveal_preserves_find_query_and_uses_separate_owner(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                view.refresh_sidebar_search(cx);
                view.show_transcript_find(window, cx);
                let field = view.transcript_find.as_ref().unwrap().query.clone();
                field.update(cx, |editor, cx| editor.set_text("independent".into(), cx));
                let id = view.record.id.clone();
                let ticket = view
                    .sidebar_search_ticket(&id)
                    .expect("fresh displayed content ticket");
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                assert_eq!(field.read(cx).text(), "independent");
                assert!(view.transcript_find.is_some());
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert_eq!(
                view.transcript_find.as_ref().unwrap().query.read(cx).text(),
                "independent"
            );
            assert!(view.sidebar_run_states.is_idle());
            let transcript = view.transcript.as_ref().expect("retained transcript");
            assert!(
                transcript.read(cx).sidebar_paint().is_some(),
                "fresh sidebar paint installed"
            );
        });
    }

    #[gpui::test]
    async fn oversized_query_and_scope_change_revoke_inflight_reveal(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                assert!(view.sidebar_search_reveal.is_some());
                view.filter.update(cx, |editor, cx| {
                    editor.set_text(
                        "x".repeat(
                            bello_agent_core::sidebar_search::projection::MAX_QUERY_BYTES + 1,
                        ),
                        cx,
                    )
                });
                view.refresh_sidebar_search(cx);
                assert!(view.sidebar_search_reveal.is_none());
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_none()
            );
            view.filter
                .update(cx, |editor, cx| editor.set_text("needle".into(), cx));
            view.refresh_sidebar_search(cx);
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(120));
        finish_pass(&view, cx);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                view.known_catalog_uncertainty = true;
                view.refresh_sidebar_search(cx);
                assert!(view.sidebar_search_reveal.is_none());
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_none()
            );
        });
    }

    #[gpui::test]
    async fn committed_identical_ime_text_gets_its_own_full_debounce(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                view.filter.update(cx, |editor, cx| {
                    editor.replace_and_mark_text_in_range(Some(0..6), "needle", None, window, cx)
                });
                view.refresh_sidebar_search(cx);
                assert!(view.sidebar_search.request.is_none());
                assert!(view.sidebar_search.composing);
                view.filter
                    .update(cx, |editor, cx| editor.unmark_text(window, cx));
            })
            .unwrap();
        // Notification-only unmark must reach the real filter observer.
        cx.run_until_parked();
        view.update(cx, |view, _| {
            assert!(view.sidebar_search.debounce.is_some());
            assert!(view.sidebar_search.request.is_none());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(119));
        cx.run_until_parked();
        view.update(cx, |view, _| assert!(view.sidebar_search.request.is_none()));
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(1));
        finish_pass(&view, cx);
        view.update(cx, |view, _| assert!(view.sidebar_search.request.is_some()));
    }

    #[gpui::test]
    async fn manual_navigation_revokes_sidebar_ticket_across_resize_rearm(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            view.abandon_find_navigation();
            let transcript = view.transcript.clone().unwrap();
            transcript.update(cx, |transcript, cx| {
                let paint = transcript.sidebar_paint().unwrap();
                transcript.cancel_find_navigation(cx);
                assert!(
                    paint
                        .destination
                        .as_ref()
                        .unwrap()
                        .navigation
                        .cancellation()
                        .load(std::sync::atomic::Ordering::Acquire)
                );
                // Even a resize/layout rearm cannot revive the revoked ticket.
                paint.landed.set(false);
                assert!(!paint.navigating());
            });
        });
    }

    #[gpui::test]
    async fn closing_window_revokes_pending_reveal_without_releasing_worker(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                assert!(!view.sidebar_run_states.is_idle());
                window.remove_window();
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(view.window_binding.is_none());
            assert!(view.sidebar_search_reveal.is_none());
            assert!(view.sidebar_search.request.is_none());
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_none()
            );
            assert!(
                view.sidebar_run_states.is_idle(),
                "worker exited before releasing its marker"
            );
        });
    }

    #[gpui::test]
    async fn unrelated_loaded_changes_keep_saved_hit_and_same_pass(cx: &mut TestAppContext) {
        let (_dir, _window, view, unloaded) = fixture(cx);
        view.update(cx, |view, _| {
            let epoch = view.sidebar_search.epoch;
            let request = view.sidebar_search.request.clone().unwrap();
            let loaded = view.record.id.clone();
            for _ in 0..100 {
                view.sidebar_search.source_changed(&loaded);
                assert!(view.sidebar_content_hit(&loaded).is_none());
                assert!(view.sidebar_content_hit(&unloaded.id).is_some());
                assert_eq!(view.sidebar_search.epoch, epoch);
                assert!(!request.is_cancelled());
            }
        });
    }

    #[gpui::test]
    async fn delayed_find_first_page_cannot_overtake_newer_sidebar_action(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture_kind(cx, true);
        crate::transcript_find_controller::set_find_completion_delays(200, 0);
        window
            .update(cx, |view, window, cx| {
                view.show_transcript_find(window, cx);
                view.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .update(cx, |editor, cx| editor.set_text("needle".into(), cx));
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(150));
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let owner = view.update(cx, |view, cx| {
            view.transcript
                .as_ref()
                .unwrap()
                .read(cx)
                .sidebar_paint()
                .unwrap()
                .owner
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(200));
        cx.run_until_parked();
        crate::transcript_find_controller::set_find_completion_delays(0, 0);
        view.update(cx, |view, cx| {
            assert_eq!(
                view.transcript_find.as_ref().unwrap().query.read(cx).text(),
                "needle"
            );
            assert_eq!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .unwrap()
                    .owner,
                owner
            );
            assert!(
                view.transcript_find.as_ref().unwrap().destination.is_none(),
                "old first-page completion updates counts but cannot navigate"
            );
        });
    }

    #[gpui::test]
    async fn newer_find_action_revokes_pending_sidebar_completion(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                view.show_transcript_find(window, cx);
                view.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .update(cx, |editor, cx| editor.set_text("needle".into(), cx));
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(150));
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                assert!(view.sidebar_search_reveal.is_some());
                view.step_transcript_find(false, cx);
                assert!(view.sidebar_search_reveal.is_none());
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_none()
            );
            assert!(view.transcript_find.as_ref().unwrap().destination.is_some());
        });
    }

    #[gpui::test]
    async fn delayed_tool_geometry_rechecks_source_receipt_before_scroll(cx: &mut TestAppContext) {
        let (_dir, window, view, _unloaded) = fixture_kind(cx, true);
        crate::transcript_view::pause_find_geometry(true);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let transcript = view.update(cx, |view, _| view.transcript.clone().unwrap());
        let paint = transcript.update(cx, |transcript, _| transcript.sidebar_paint().unwrap());
        let origin = transcript.update(cx, |transcript, _| {
            transcript.list_state().logical_scroll_top()
        });
        window
            .update(cx, |view, window, cx| {
                // Revoke the Core witness before its asynchronous UI watch is delivered.
                view.controller.retire().unwrap();
                assert!(!paint.matches_binding(view.display_find_binding.as_ref()));
                assert!(
                    crate::transcript_view::resume_find_geometry(window, cx) > 0,
                    "the real tool-editor geometry callback was held"
                );
                assert!(!paint.confirmed.get());
                let after = transcript.read(cx).list_state().logical_scroll_top();
                assert_eq!(after.item_ix, origin.item_ix);
                assert_eq!(after.offset_in_item, origin.offset_in_item);
            })
            .unwrap();
        crate::transcript_view::pause_find_geometry(false);
        cx.run_until_parked();
    }

    #[gpui::test]
    async fn old_find_timeout_cannot_cancel_newer_sidebar_tool_measurement(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, _unloaded) = fixture_kind(cx, true);
        crate::transcript_view::pause_find_geometry(true);
        window
            .update(cx, |view, window, cx| {
                view.show_transcript_find(window, cx);
                view.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .update(cx, |editor, cx| editor.set_text("needle".into(), cx));
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(150));
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(10));
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let paint = view.update(cx, |view, cx| {
            let transcript = view.transcript.as_ref().unwrap().read(cx);
            assert!(
                transcript
                    .tool_section_editors()
                    .iter()
                    .any(|(label, _)| *label == "OUT")
            );
            let paint = transcript.sidebar_paint().unwrap();
            assert!(
                paint.measuring.get(),
                "actual sidebar editor measurement is pending"
            );
            paint
        });
        // Only the older Find timeout is due. Sidebar's own bounded wait is10ms later.
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(490));
        cx.run_until_parked();
        assert!(paint.measuring.get());
        assert!(paint.navigating());
        window
            .update(cx, |_, window, cx| {
                assert!(crate::transcript_view::resume_find_geometry(window, cx) > 0);
            })
            .unwrap();
        crate::transcript_view::pause_find_geometry(false);
        cx.run_until_parked();
    }

    #[gpui::test]
    async fn changed_piece_with_same_owner_and_offsets_is_not_revealed(cx: &mut TestAppContext) {
        let (_dir, window, view, unloaded) = fixture(cx);
        let ticket = view.update(cx, |view, _| {
            view.sidebar_search_ticket(&unloaded.id).unwrap()
        });
        let mut writer = SessionStore::open(&unloaded.snapshot).unwrap();
        writer
            .transact(|session| {
                session.messages[0].text = "Unopened needle".into();
                Ok(())
            })
            .unwrap();
        drop(writer);
        window
            .update(cx, |view, window, cx| {
                view.open_sidebar_result(&unloaded.id, Some(ticket), window, cx)
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(250));
        cx.run_until_parked();
        finish_pass(&view, cx);
        view.update(cx, |view, cx| view.resume_sidebar_reveal(cx));
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert_eq!(view.record.id, unloaded.id);
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_none()
            );
            assert!(
                view.error
                    .as_deref()
                    .is_some_and(|error| error.contains("occurrence changed")),
                "{:?}",
                view.error
            );
        });
    }

    #[gpui::test]
    async fn same_query_explicit_click_after_wheel_gets_new_navigation(cx: &mut TestAppContext) {
        let (_dir, window, view, _unopened) = fixture_kind(cx, true);
        crate::transcript_view::pause_find_geometry(true);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let old = view.update(cx, |view, cx| {
            let transcript = view.transcript.clone().unwrap();
            let old = transcript.read(cx).sidebar_paint().unwrap();
            view.abandon_find_navigation();
            transcript.update(cx, |t, cx| t.cancel_find_navigation(cx));
            old
        });
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let fresh = view.update(cx, |view, cx| {
            let fresh = view
                .transcript
                .as_ref()
                .unwrap()
                .read(cx)
                .sidebar_paint()
                .unwrap();
            assert_ne!(fresh.owner, old.owner);
            assert!(fresh.navigating());
            fresh
        });
        window
            .update(cx, |_, window, cx| {
                assert!(crate::transcript_view::resume_find_geometry(window, cx) > 0);
            })
            .unwrap();
        crate::transcript_view::pause_find_geometry(false);
        cx.run_until_parked();
        assert!(!old.confirmed.get());
        assert!(fresh.confirmed.get());
    }

    #[gpui::test]
    async fn metadata_before_geometry_preserves_original_navigation_until_landing(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, _unopened) = fixture_kind(cx, true);
        crate::transcript_view::pause_find_geometry(true);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(400));
        cx.run_until_parked();
        let old = view.update(cx, |view, cx| {
            let paint = view
                .transcript
                .as_ref()
                .unwrap()
                .read(cx)
                .sidebar_paint()
                .unwrap();
            assert!(paint.measuring.get());
            assert!(!paint.confirmed.get());
            let id = view.record.id.clone();
            view.mark_chat_read_state(&id, true, cx);
            assert!(view.read_write_inflight);
            paint
        });
        cx.run_until_parked();
        for _ in 0..4 {
            finish_pass(&view, cx);
            view.update(cx, |view, cx| view.resume_sidebar_reveal(cx));
            cx.run_until_parked();
        }
        let fresh = view.update(cx, |view, cx| {
            let paint = view
                .transcript
                .as_ref()
                .unwrap()
                .read(cx)
                .sidebar_paint()
                .unwrap();
            assert!(!std::rc::Rc::ptr_eq(&old, &paint));
            assert!(
                paint.navigating(),
                "uncompleted original action remains eligible"
            );
            assert!(paint.matches_binding(view.display_find_binding.as_ref()));
            paint
        });
        // Only the previous paint's deadline expires here. A fresh attempt
        // still owns its full bounded wait and original navigation receipt.
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(100));
        cx.run_until_parked();
        assert!(fresh.measuring.get());
        assert!(fresh.navigating());
        assert_ne!(old.owner, fresh.owner);
        window
            .update(cx, |_, window, cx| {
                assert!(crate::transcript_view::resume_find_geometry(window, cx) > 0);
            })
            .unwrap();
        crate::transcript_view::pause_find_geometry(false);
        cx.run_until_parked();
        assert!(!old.confirmed.get());
        assert!(
            fresh.confirmed.get(),
            "fresh real geometry lands original action"
        );
        assert!(!fresh.navigating());
    }

    #[gpui::test]
    async fn stale_reveal_completion_wakes_newer_expired_query(cx: &mut TestAppContext) {
        let (_dir, window, view, _unopened) = fixture(cx);
        crate::sidebar_search_reveal::set_reveal_delay(300);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
                assert!(!view.sidebar_run_states.is_idle());
                view.filter
                    .update(cx, |editor, cx| editor.set_text("unopened".into(), cx));
                view.refresh_sidebar_search(cx);
            })
            .unwrap();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(120));
        cx.run_until_parked();
        view.update(cx, |view, _| {
            assert!(view.sidebar_search.debounce.is_none());
            assert!(!view.sidebar_run_states.is_idle());
            assert!(view.sidebar_search.request.is_none());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(180));
        cx.run_until_parked();
        crate::sidebar_search_reveal::set_reveal_delay(0);
        view.update(cx, |view, _| {
            assert_eq!(view.sidebar_search.query, "unopened");
            assert!(
                view.sidebar_search.request.is_some(),
                "lane release must wake current demand without another user event"
            );
        });
    }

    #[gpui::test]
    async fn first_unopened_reveal_survives_selection_write_and_held_reconciliation(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, unopened) = fixture(cx);
        let loaded = view.update(cx, |view, _| view.record.id.clone());
        window
            .update(cx, |view, window, cx| {
                view.sidebar_activity_hold.set_pointer(true);
                view.show_transcript_find(window, cx);
                view.transcript_find
                    .as_ref()
                    .unwrap()
                    .query
                    .update(cx, |editor, cx| {
                        editor.set_text("loaded".into(), cx);
                    });
            })
            .unwrap();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(150));
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                let ticket = view.sidebar_search_ticket(&unopened.id).unwrap();
                view.open_sidebar_result(&unopened.id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(view.sidebar_selection_pending.is_some());
            view.resume_sidebar_reveal(cx);
            assert!(
                !view
                    .transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_decoration_current()
            );
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(250));
        cx.run_until_parked();
        for _ in 0..4 {
            finish_pass(&view, cx);
            view.update(cx, |view, cx| view.resume_sidebar_reveal(cx));
            cx.run_until_parked();
        }
        view.update(cx, |view, cx| {
            assert_eq!(view.record.id, unopened.id);
            assert!(view.sidebar_activity_hold.active());
            assert!(view.sidebar_content_hit(&loaded).is_some());
            assert!(view.sidebar_content_hit(&unopened.id).is_some());
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_decoration_current(),
                "{:?}",
                view.error
            );
        });
        // Reach the documented terminal geometry/fallback boundary before
        // testing a later write. Installation alone is not a landing receipt.
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(500));
        cx.run_until_parked();
        // A later metadata transaction must reacquire decoration only. It must
        // never re-arm the already consumed explicit navigation.
        view.update(cx, |view, cx| {
            view.mark_chat_read_state(&unopened.id, true, cx);
            assert!(
                view.read_write_inflight,
                "actual catalog read-state write dispatched"
            );
            view.resume_sidebar_reveal(cx);
        });
        cx.run_until_parked();
        for _ in 0..4 {
            finish_pass(&view, cx);
            view.update(cx, |view, cx| view.resume_sidebar_reveal(cx));
            cx.run_until_parked();
        }
        view.update(cx, |view, cx| {
            let transcript = view.transcript.as_ref().unwrap().read(cx);
            assert!(transcript.sidebar_decoration_current());
            assert!(!transcript.sidebar_paint().unwrap().active_navigation());
            assert!(
                transcript
                    .sidebar_paint()
                    .unwrap()
                    .destination
                    .as_ref()
                    .unwrap()
                    .navigation
                    .cancellation()
                    .load(std::sync::atomic::Ordering::Acquire),
                "decoration refresh permanently cancels navigation, even after paint"
            );
            view.cancel_sidebar_reveal(cx);
            assert!(view.sidebar_search_reveal.is_none());
        });
    }

    #[gpui::test]
    async fn live_cache_barrier_suppresses_existing_hits_until_cleanup(cx: &mut TestAppContext) {
        let (_dir, _window, view, unloaded) = fixture(cx);
        let workspace = view.update(cx, |view, _| view.workspace.clone());
        let membership = WorkspaceStore::search_membership_snapshot(&workspace).unwrap();
        view.update(cx, |view, cx| {
            assert!(view.sidebar_content_hit(&unloaded.id).is_some());
            let member = membership
                .members()
                .iter()
                .find(|member| member.chat_id() == view.record.id)
                .unwrap();
            let mut owner = std::mem::take(&mut view.sidebar_search.cache);
            let cache = owner.cache.as_mut().unwrap();
            let replacement = cache.begin_replacement(member).unwrap();
            assert!(
                view.sidebar_content_hit(&unloaded.id).is_none(),
                "live barrier must override copied readiness"
            );
            drop(replacement);
            assert!(
                view.sidebar_content_hit(&unloaded.id).is_none(),
                "rollback still requires cleanup"
            );
            cache.cleanup().unwrap();
            assert!(view.sidebar_content_hit(&unloaded.id).is_some());
            view.sidebar_search.restore_cache(owner);
            cx.notify();
        });
    }

    fn finish_pass(view: &Entity<AgentView>, cx: &mut TestAppContext) {
        cx.run_until_parked();
        view.update(cx, |view, cx| view.refresh_sidebar_search(cx));
        cx.run_until_parked();
        view.update(cx, |view, cx| view.refresh_sidebar_search(cx));
        cx.run_until_parked();
    }

    #[gpui::test]
    async fn new_member_negative_then_journal_match_and_missing_source_reconcile(
        cx: &mut TestAppContext,
    ) {
        let (_dir, _window, view, _unloaded) = fixture(cx);
        let record = view.update(cx, |view, cx| {
            let (record, store) = saved(
                &mut view.workspace.lock().unwrap(),
                "previously absent phrase",
            );
            drop(store);
            view.records.push(record.clone());
            view.refresh_saved_content(cx);
            record
        });
        finish_pass(&view, cx);
        view.update(cx, |view, _| {
            assert!(matches!(
                view.sidebar_search
                    .pass
                    .as_ref()
                    .unwrap()
                    .outcome(&record.id),
                Ok(Some(SearchOutcome::NoMatch))
            ));
            assert!(view.sidebar_content_hit(&record.id).is_none());
        });
        let mut writer = SessionStore::open(&record.snapshot).unwrap();
        writer
            .transact(|session| {
                session.messages[0].text = "new journal needle".into();
                Ok(())
            })
            .unwrap();
        drop(writer);
        view.update(cx, |view, cx| view.refresh_saved_content(cx));
        finish_pass(&view, cx);
        view.update(cx, |view, _| {
            assert!(
                view.sidebar_content_hit(&record.id).is_some(),
                "old negative cannot hide later journal match"
            );
            assert!(view.chat_ref(&record.id).is_none());
        });
        // Preserve the synthetic checkpoint as evidence; make its exact source
        // unavailable without deleting data or turning failure into NoMatch.
        std::fs::rename(
            &record.snapshot,
            record.snapshot.with_extension("fixture-held"),
        )
        .unwrap();
        view.update(cx, |view, cx| view.refresh_saved_content(cx));
        finish_pass(&view, cx);
        view.update(cx, |view, _| {
            assert!(view.sidebar_content_hit(&record.id).is_none());
            assert!(!matches!(
                view.sidebar_search
                    .pass
                    .as_ref()
                    .unwrap()
                    .outcome(&record.id),
                Ok(Some(SearchOutcome::NoMatch))
            ));
            assert_eq!(
                view.sidebar_search.status,
                "Some saved content is unavailable"
            );
        });
    }

    #[gpui::test]
    async fn unopened_result_uses_normal_open_then_fresh_loaded_reveal(cx: &mut TestAppContext) {
        let (_dir, window, view, unloaded) = fixture(cx);
        window
            .update(cx, |view, window, cx| {
                assert!(view.chat_ref(&unloaded.id).is_none());
                let ticket = view.sidebar_search_ticket(&unloaded.id).unwrap();
                view.open_sidebar_result(&unloaded.id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert_eq!(view.record.id, unloaded.id);
            assert!(
                !view.loading && !view.load_failed,
                "normal open completed: {:?}",
                view.error
            );
            view.resume_sidebar_reveal(cx);
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(250));
        cx.run_until_parked();
        finish_pass(&view, cx);
        view.update(cx, |view, cx| view.resume_sidebar_reveal(cx));
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(view.sidebar_search_reveal.is_some());
            assert!(view.sidebar_run_states.is_idle());
            assert!(
                view.transcript
                    .as_ref()
                    .unwrap()
                    .read(cx)
                    .sidebar_paint()
                    .is_some(),
                "fresh loaded reveal after observed result open: {:?}",
                view.error
            );
        });
    }

    #[gpui::test]
    async fn fold_change_invalidates_sidebar_geometry_without_source_revision_change(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, view, _unloaded) = fixture_kind(cx, true);
        window
            .update(cx, |view, window, cx| {
                let id = view.record.id.clone();
                let ticket = view.sidebar_search_ticket(&id).unwrap();
                view.open_sidebar_result(&id, Some(ticket), window, cx);
            })
            .unwrap();
        cx.run_until_parked();
        let (transcript, binding) = view.update(cx, |view, _| {
            (
                view.transcript.clone().unwrap(),
                view.controller.find_snapshot().unwrap(),
            )
        });
        let paint = transcript.update(cx, |transcript, _| transcript.sidebar_paint().unwrap());
        paint.confirmed.set(true);
        paint.landed.set(true);
        let before = transcript.update(cx, |transcript, _| transcript.presentation_identity());
        // The real disclosure callback changes presentation while the loaded
        // source receipt and Find snapshot remain current.
        window
            .update(cx, |_, window, cx| {
                transcript.update(cx, |transcript, cx| {
                    transcript.toggle_first_tool_for_test(window, cx)
                });
            })
            .unwrap();
        transcript.update(cx, |transcript, _| {
            assert_ne!(before, transcript.presentation_identity());
            assert!(!paint.confirmed.get());
            assert!(!paint.landed.get());
            assert!(paint.host_geometry.borrow().is_none());
            assert!(paint.layouts.borrow().is_empty());
            assert!(paint.matches_binding(Some(&binding)));
        });
        cx.run_until_parked();
    }

    #[gpui::test]
    async fn failed_binding_switch_retries_original_and_disposes_on_background(
        cx: &mut TestAppContext,
    ) {
        let (dir, _window, view, _unloaded) = fixture(cx);
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            view.sidebar_search.live_cache = None;
            let mut owner = std::mem::take(&mut view.sidebar_search.cache);
            let original = owner.binding.clone().unwrap();
            owner.registered.insert("old-binding-only".into());
            let other_root = dir.path().join("other");
            std::fs::create_dir(&other_root).unwrap();
            let other = Arc::new(Mutex::new(
                WorkspaceStore::open(other_root.join("catalog.json"), &other_root).unwrap(),
            ));
            let other_membership = WorkspaceStore::search_membership_snapshot(&other).unwrap();
            let other_binding =
                bello_agent_core::sidebar_search::cache::CacheBinding::from_membership(
                    other_membership.stamp(),
                )
                .unwrap();
            assert!(
                owner
                    .ensure_with(other_binding, |_| Err(
                        bello_agent_core::sidebar_search::cache::CacheError::UnsafeLocation
                    ))
                    .is_err()
            );
            assert!(owner.cache.is_none());
            assert!(owner.binding.is_none());
            assert!(owner.registered.is_empty());
            owner
                .ensure_with(original, |binding| {
                    bello_agent_core::sidebar_search::cache::PrivateCache::open_synthetic_fixture(
                        binding,
                        dir.path(),
                    )
                })
                .unwrap();
            assert!(owner.cache.is_some());
            assert!(owner.disposal.is_some());
            drop(owner);
            assert!(view.sidebar_run_states.is_idle());
            cx.notify();
        });
        cx.run_until_parked();
    }
    #[gpui::test]
    async fn cancel_at_119ms_allows_unchanged_query_and_old_timer_cannot_reopen_new_query(
        cx: &mut TestAppContext,
    ) {
        let (_dir, _window, view, _unloaded) = fixture(cx);
        view.update(cx, |view, cx| {
            view.filter.update(cx, |editor, cx| {
                editor.set_text("changed phrase".into(), cx)
            });
            view.refresh_sidebar_search(cx);
            assert!(view.sidebar_search.debounce.is_some());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(119));
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            assert!(view.sidebar_search.request.is_none());
            view.sidebar_search.cancel();
            assert!(view.sidebar_search.debounce.is_none());
            view.refresh_sidebar_search(cx);
            assert!(view.sidebar_search.request.is_some());
        });
        cx.run_until_parked();
        view.update(cx, |view, cx| {
            view.filter
                .update(cx, |editor, cx| editor.set_text("newest phrase".into(), cx));
            view.refresh_sidebar_search(cx);
            assert!(view.sidebar_search.debounce.is_some());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(1));
        cx.run_until_parked();
        view.update(cx, |view, _| {
            assert!(view.sidebar_search.debounce.is_some());
            assert!(view.sidebar_search.request.is_none());
        });
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(119));
        cx.run_until_parked();
        view.update(cx, |view, _| {
            assert!(view.sidebar_search.debounce.is_none());
            assert!(view.sidebar_search.request.is_some());
        });
    }
    #[gpui::test]
    async fn actual_cache_completion_rejects_an_old_workspace_owner(cx: &mut TestAppContext) {
        let (dir, _window, view, _unloaded) = fixture(cx);
        cx.run_until_parked();
        view.update(cx, |view, _| {
            let owner = Arc::downgrade(&view.workspace);
            let cache = std::mem::take(&mut view.sidebar_search.cache);
            assert!(cache.cache.is_some());
            let other = dir.path().join("replacement-workspace");
            std::fs::create_dir(&other).unwrap();
            view.workspace = Arc::new(Mutex::new(
                WorkspaceStore::open(other.join("catalog.json"), &other).unwrap(),
            ));
            view.sidebar_search = SidebarSearch::default();
            assert!(!view.finish_sidebar_cache_owner(&owner, cache));
            assert!(view.sidebar_search.cache.cache.is_none());
            assert!(view.sidebar_search.cleanup.is_empty());
            assert!(!view.sidebar_search.readiness.is_ready());
        });
        cx.run_until_parked();
    }
}

#[test]
fn hold_release_notifies_even_without_activity_stamps() {
    let mut hold = crate::sidebar_activity::SidebarActivityHold::default();
    assert!(!hold.set_pointer(true));
    assert!(hold.set_pointer(false));
    assert!(!hold.set_pointer(false));
}

#[test]
fn operation_restore_is_exact_and_cannot_erase_later_retirement() {
    let mut routes = crate::sidebar_search_state::SearchLifecycles::default();
    routes.unloaded("unloaded");
    routes.loaded("loaded");
    let first = routes.block_all();
    routes.block("loaded");
    routes.restore(first, false);
    assert_eq!(routes.route("unloaded"), Some(SourceRoute::Unloaded));
    assert_eq!(routes.route("loaded"), Some(SourceRoute::Blocked));
    routes.loaded("loaded");
    let removed_connection = routes.block_all();
    routes.restore(removed_connection, true);
    assert_eq!(routes.route("unloaded"), Some(SourceRoute::Unloaded));
    assert_eq!(routes.route("loaded"), Some(SourceRoute::Blocked));
}
