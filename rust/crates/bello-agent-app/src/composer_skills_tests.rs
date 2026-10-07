use super::{input_label, restore_chips, validate_fresh};
use bello_agent_core::skills::{SkillChip, SkillIntent, SkillPolicy, SkillSelection};

fn chip(index: usize, arguments: &str) -> SkillChip {
    const IDS: [&str; 18] = [
        "e343e4ede09af4ba6e17b429924170c07d43f9b78ae2d564559c5733627bed24",
        "3f2143c83f2f5fd07ec70f0703befa29bdbe5417ff432a45e9a254d6b33eaaae",
        "e30748df78c807c274304ea5a0fafa9b2ef3fb0c73739e39e0ab4b5a74f26c57",
        "2e819ef79a6e98b599ea396b817693e172fd74c8aaa0a8a3f672cbe81168e3fe",
        "15c6b933fa1568ea8b160d726793e51abe899560ac54abb9e2533dcb59ea8670",
        "bc0b96c904b8a1103687e43f6b66063a8187289255086cb3e898089cacb1574f",
        "60d1d4eeb17506ffa331117e00a5c2918a00559935bb1ecfce008099b76507fb",
        "98c4836c72e90dc9ef91d2987994067f9f71b6adbc0354f51e4a13f0318b63e8",
        "e2e62bf360d749ccb39e815dd5ebe8dd07e44be1e3e0c3763fa736d85e1cd4a0",
        "7249c4e7dd6601ed32de38d180a378d9f47e55d2048922265eb3fe44bfba359b",
        "8b4aa106187c305e3dcd4655e9fa80c0a0267d77f8b4bab6324b46ba2ae34366",
        "71960cc43fcdbfb8da8390aa87468630e5412a3bba5191704e39eb8c0eeb5cc7",
        "e3f572579adb806dbdbc82482a706e8573b63165cabc06df6f3045f4037ccead",
        "c4e8efa7cfa0e01c597747bee3bee65659074514a418d215263beaba63aae274",
        "be9e14be6a7ec2618fb46efe966c773c7d504d0dae8869bfe15fb3dda3df97e5",
        "95bf1fa9d58cd9a90faaf4f36e5ea8d9de3f4ddda2fae634b1df9b75a43e3432",
        "bfce5ab29141cb8b1781579e55667aafe532cac5b620bca5ae5f362cc252ef8d",
        "904593b33df2ea2f5c12a68dc2cedaf61fc59293f65124341421054f1874004f",
    ];
    SkillChip {
        selection: SkillSelection {
            id: IDS[index].into(),
            content_hash: "a".repeat(64),
            metadata_hash: "b".repeat(64),
            arguments: arguments.into(),
            intent: SkillIntent::Picker,
        },
        name: format!("skill-{index}"),
        path: format!("/project/.agents/skills/{index}/SKILL.md"),
        description: "A captured display fact".into(),
        scope: "project".into(),
        policy: SkillPolicy::ExplicitOnly,
        source_root: "/project/.agents/skills".into(),
    }
}
#[test]
fn recovery_is_captured_first_exact_variant_and_storage_is_not_send_authority() {
    let captured = vec![chip(1, "captured"), chip(2, "literal /not-a-command")];
    let newer = vec![chip(1, "newer"), captured[1].clone(), chip(3, "")];
    let recovered = restore_chips(&captured, &newer).unwrap();
    assert_eq!(
        recovered,
        vec![
            captured[0].clone(),
            captured[1].clone(),
            newer[0].clone(),
            newer[2].clone()
        ]
    );
    assert!(validate_fresh(&recovered).is_err());
    let sixteen = (0..16).map(|i| chip(i, "")).collect::<Vec<_>>();
    assert_eq!(
        restore_chips(&sixteen[..8], &sixteen[8..]).unwrap(),
        sixteen
    );
    assert!(validate_fresh(&sixteen).is_err());
    assert!(restore_chips(&sixteen, &[chip(17, "")]).is_err());
    let mut metadata_only = captured[0].clone();
    metadata_only.description = "newer description".into();
    assert_eq!(
        restore_chips(&captured, &[metadata_only]).unwrap(),
        captured
    );
}
#[test]
fn arguments_are_literal_and_input_labels_never_rewrite_display_text() {
    let mut value = chip(1, &"a".repeat(16 * 1024));
    validate_fresh(&[value.clone()]).unwrap();
    value.selection.arguments.push('b');
    assert!(validate_fresh(&[value]).is_err());
    assert_eq!(
        input_label("", 1, ["first", "second"]),
        "/first · /second · Image"
    );
    assert_eq!(input_label("/first", 0, std::iter::empty()), "/first");
    assert_eq!(input_label("typed", 1, ["first"]), "typed");
}

#[cfg(feature = "synthetic-authority")]
pub(crate) mod saved_ui {
    use super::*;
    use crate::AgentView;
    use crate::{
        LaunchState,
        connection_settings_controller::LaunchConnectionAuthority,
        project_skills_controller::{CatalogState, SkillTarget},
    };
    use bello_agent_core::{
        Controller, Lane, Profile, SessionStore,
        project_authority::{
            ProjectAuthority,
            connections::{ConnectionDraft, SYNTHETIC_KEY},
        },
        workspace::{ChatRecord, ChatToolMode, DraftRecord, WorkspaceStore},
    };
    use gpui::{Entity, Focusable, TestAppContext, VisualTestContext, WindowHandle, px, size};
    use std::sync::{Arc, Mutex};

    fn wait_for(
        root: &Entity<AgentView>,
        cx: &mut TestAppContext,
        predicate: impl Fn(&AgentView) -> bool,
    ) {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(8);
        loop {
            cx.run_until_parked();
            if cx.read(|cx| predicate(root.read(cx))) {
                return;
            }
            assert!(
                std::time::Instant::now() < end,
                "skill operation did not settle"
            );
            std::thread::sleep(std::time::Duration::from_millis(3));
        }
    }
    pub(crate) fn fixture(
        cx: &mut TestAppContext,
        text: &str,
    ) -> (
        tempfile::TempDir,
        WindowHandle<AgentView>,
        Entity<AgentView>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let project = std::fs::canonicalize(dir.path()).unwrap();
        for (folder, name) in [("a", "review"), ("b", "review"), ("c", "other")] {
            let path = project.join(".agents/skills").join(folder);
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(path.join("SKILL.md"), format!("---\nname: {name}\ndescription: Fixture {folder}\ndisable-model-invocation: true\n---\nBODY-MARKER-{folder}\n")).unwrap();
        }
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        cx.update(|cx| cx.set_global(LaunchConnectionAuthority(control)));
        let profile: Profile = serde_json::from_value(serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":"http://127.0.0.1:9","modelId":"local-test-fixture","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
        let mut connection = ConnectionDraft::new(profile, "Skill fixture".into());
        connection.key_input = SYNTHETIC_KEY.into();
        let saved = authority
            .save_connection(&authority.load_connections().unwrap(), &connection)
            .unwrap();
        let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
        let mut draft = authority.load().unwrap().edit();
        let saved_project = draft
            .trust_project(&uuid::Uuid::new_v4().to_string(), &project, &[])
            .unwrap();
        let loaded = authority.save(&mut draft).unwrap();
        workspace
            .bind_project_identity(
                authority
                    .confirm_project_binding(&loaded, &saved_project)
                    .unwrap(),
            )
            .unwrap();
        let mut store = SessionStore::open(project.join("session.json")).unwrap();
        store
            .transact(|session| {
                session.queue_paused = true;
                Ok(())
            })
            .unwrap();
        let mut record = ChatRecord::new(
            store.snapshot().id,
            "Skills".into(),
            project.join("session.json"),
        );
        record.connection_id = Some(saved.profile.profile.id);
        record.tool_mode = ChatToolMode::ReadOnly;
        let draft = DraftRecord {
            text: text.into(),
            ..Default::default()
        };
        workspace.register(record.clone(), draft.clone()).unwrap();
        drop(store);
        let workspace = Arc::new(Mutex::new(workspace));
        let runtime = crate::saved_runtime_adapter::AppRuntime::new(
            authority,
            workspace.clone(),
            crate::saved_runtime_adapter::AppRuntime::options(project.clone(), true),
            None,
        );
        let controller = runtime.open_registered(&record).unwrap();
        let launch = LaunchState {
            controller,
            workspace,
            project,
            record,
            draft,
            pending: false,
        };
        let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
        let root = window.root(cx).unwrap();
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| view.open_skill_picker(window, cx))
            .unwrap();
        wait_for(&root, cx, |view| !view.skill_catalog.loading());
        root.update(cx, |view, _| {
            assert_eq!(
                view.skill_catalog.snapshot.as_ref().unwrap().skills.len(),
                3
            );
            assert!(view.skill_catalog.authorizes());
        });
        (dir, window, root)
    }
    pub(crate) fn select(
        root: &Entity<AgentView>,
        index: usize,
        cx: &mut TestAppContext,
    ) -> SkillChip {
        root.update(cx, |view, cx| {
            let snapshot = view.skill_catalog.snapshot.clone().unwrap();
            let chip = snapshot.skills[index].chip(String::new());
            let token = view.skill_picker.as_ref().unwrap().token;
            view.add_presented_skill(token, &snapshot, &chip, cx);
            assert!(view.skills.contains(&chip));
            chip
        })
    }
    pub(crate) fn close(window: WindowHandle<AgentView>, cx: &mut TestAppContext) {
        window
            .update(cx, |view, window, cx| {
                let token = view.skill_picker.as_ref().unwrap().token;
                view.close_skill_picker(token, window, cx);
            })
            .unwrap();
    }
    fn click(visual: &mut VisualTestContext, selector: &'static str, cx: &mut TestAppContext) {
        cx.run_until_parked();
        let bounds = visual
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"));
        visual.simulate_click(bounds.center(), gpui::Modifiers::none());
        cx.run_until_parked();
    }
    #[gpui::test]
    fn mounted_controls_select_same_names_edit_arguments_cancel_remove_and_do_not_send(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "/review stays plain");
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(1180.), px(812.)));
        click(&mut visual, "skill-add-1", cx);
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .scroll
                .scroll_to_bottom();
            cx.notify();
        });
        click(&mut visual, "skill-add-2", cx);
        root.update(cx, |view, _| {
            assert_eq!(view.skills.len(), 2);
            assert_eq!(view.skills[0].name, view.skills[1].name);
            assert_ne!(view.skills[0].path, view.skills[1].path);
            assert!(view.session.pending.is_empty());
            assert!(view.session.messages.is_empty());
        });
        click(&mut visual, "skill-picker-close", cx);
        click(&mut visual, "skill-arguments-0", cx);
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| {
                    editor.set_text("literal /review\n日本語".into(), cx)
                });
        });
        click(&mut visual, "skill-picker-close", cx);
        root.update(cx, |view, _| {
            assert!(view.skills[0].selection.arguments.is_empty())
        });
        click(&mut visual, "skill-arguments-0", cx);
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| {
                    editor.set_text("literal /review\n日本語".into(), cx)
                });
        });
        click(&mut visual, "skill-arguments-save", cx);
        root.update(cx, |view, cx| {
            assert_eq!(
                view.skills[0].selection.arguments,
                "literal /review\n日本語"
            );
            assert_eq!(view.composer.read(cx).text(), "/review stays plain");
            assert!(
                !serde_json::to_string(&view.saved_draft(cx))
                    .unwrap()
                    .contains("BODY-MARKER")
            );
        });
        click(&mut visual, "skill-remove-0", cx);
        root.update(cx, |view, _| {
            assert_eq!(view.skills.len(), 1);
            assert!(view.session.pending.is_empty());
        });
    }
    #[gpui::test]
    fn discovery_refresh_loading_partial_failure_and_stale_callbacks_are_distinct(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "");
        root.update(cx, |view, cx| {
            let snapshot = view.skill_catalog.snapshot.clone().unwrap();
            let chip = snapshot.skills[0].chip(String::new());
            let token = view.skill_picker.as_ref().unwrap().token;
            for state in [CatalogState::Loading, CatalogState::Failed] {
                view.skill_catalog.state = state;
                view.add_presented_skill(token, &snapshot, &chip, cx);
                assert!(view.skills.is_empty());
            }
            view.skill_catalog.state = CatalogState::Partial;
            view.add_presented_skill(token, &snapshot, &chip, cx);
            assert_eq!(view.skills, vec![chip.clone()]);
            view.skills.clear();
            view.skill_catalog.state = CatalogState::Ready;
            let target = SkillTarget::capture(view);
            view.refresh_project_skills(&target, cx);
            assert_ne!(view.skill_picker.as_ref().unwrap().token, token);
            view.add_presented_skill(token, &snapshot, &chip, cx);
            assert!(view.skills.is_empty());
        });
        wait_for(&root, cx, |view| !view.skill_catalog.loading());
        close(window, cx);
        root.update(cx, |view, cx| {
            let target = SkillTarget::capture(view);
            view.finish_project_skills(&target, uuid::Uuid::new_v4(), Err("stale".into()), cx);
            assert!(view.skill_catalog.authorizes());
        });
    }
    #[gpui::test]
    fn late_discovery_only_updates_origin_and_never_selects_or_steals_focus(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "origin");
        window
            .update(cx, |view, window, cx| {
                let target = SkillTarget::capture(view);
                let snapshot = view.skill_catalog.snapshot.clone().unwrap();
                let token = uuid::Uuid::new_v4();
                view.skill_catalog.state = CatalogState::Loading;
                view.skill_catalog.request = Some(token);
                view.new_chat(window, cx);
                let current = view.record.id.clone();
                assert_ne!(current, target.chat);
                view.filter.read(cx).focus(window);
                view.finish_project_skills(&target, token, Ok(snapshot), cx);
                assert!(
                    view.chat_ref(&target.chat)
                        .unwrap()
                        .skill_catalog
                        .authorizes()
                );
                assert!(view.skills.is_empty());
                assert_eq!(view.record.id, current);
                assert!(view.filter.read(cx).focus_handle(cx).is_focused(window));
            })
            .unwrap();
        let _ = root;
    }
    #[gpui::test]
    fn arguments_remove_and_catalog_completions_reject_window_runtime_and_metadata_replacement(
        cx: &mut TestAppContext,
    ) {
        for change in ["window", "controller", "metadata", "navigation"] {
            let (_dir, window, root) = fixture(cx, "keep");
            let selected = select(&root, 0, cx);
            close(window, cx);
            window
                .update(cx, |view, window, cx| {
                    let target = SkillTarget::capture(view);
                    let original = view.record.id.clone();
                    match change {
                        "window" => view.bind_window(window, cx),
                        "controller" => view.chat.replace_controller(
                            Controller::new(
                                SessionStore::pending_with_id(&original).unwrap(),
                                None,
                            )
                            .unwrap(),
                            cx,
                        ),
                        "metadata" => view.skills[0].selection.arguments = "newer".into(),
                        "navigation" => view.new_chat(window, cx),
                        _ => unreachable!(),
                    }
                    let before = view.chat_ref(&original).unwrap().skills.clone();
                    view.remove_presented_skill(&target, &selected, cx);
                    view.edit_skill_arguments(&target, &selected, window, cx);
                    assert_eq!(view.chat_ref(&original).unwrap().skills, before);
                    assert!(view.skill_picker.is_none());
                })
                .unwrap();
        }
    }
    #[gpui::test]
    fn skill_only_submission_queue_edit_save_and_cancel_preserve_frozen_and_parked_chips(
        cx: &mut TestAppContext,
    ) {
        for save in [false, true] {
            let (_dir, window, root) = fixture(cx, "");
            let queued = select(&root, 1, cx);
            close(window, cx);
            root.update(cx, |view, cx| {
                assert!(view.composer_has_input(cx));
                view.submit_chat(Lane::FollowUp, cx);
            });
            wait_for(&root, cx, |view| {
                !view.busy && view.inflight_submission.is_none()
            });
            let (turn, frozen) = root.update(cx, |view, _| {
                assert_eq!(view.session.pending.len(), 1, "{:?}", view.error);
                assert!(view.skills.is_empty());
                let item = &view.session.pending[0];
                assert!(item.text.is_empty());
                assert_eq!(item.frozen_skills[0].selection(), queued.selection);
                (item.id.clone(), item.frozen_skills.clone())
            });
            window
                .update(cx, |view, window, cx| view.open_skill_picker(window, cx))
                .unwrap();
            let ordinary = select(&root, 0, cx);
            close(window, cx);
            window
                .update(cx, |view, window, cx| {
                    let id = view.record.id.clone();
                    view.begin_queued_edit(&id, &turn, None, window, cx);
                })
                .unwrap();
            wait_for(&root, cx, |view| {
                view.editing.is_some() && view.begin_operation.is_none()
            });
            root.update(cx, |view, cx| {
                assert!(!view.can_choose_skills());
                assert!(view.skills.is_empty());
                assert_eq!(view.saved_draft(cx).skills, vec![ordinary.clone()]);
                assert!(view.composer_has_input(cx));
                if save {
                    view.resolve_edit("saved", cx);
                } else {
                    let id = view.record.id.clone();
                    view.cancel_owned_edit(&id, cx);
                }
            });
            wait_for(&root, cx, |view| {
                view.editing.is_none() && !view.busy && view.cancel_operation.is_none()
            });
            root.update(cx, |view, _| {
                assert_eq!(view.skills, vec![ordinary]);
                assert_eq!(view.session.pending[0].frozen_skills, frozen);
            });
        }
    }
    #[gpui::test]
    fn picker_tab_enter_and_escape_do_not_send_or_parse_search(cx: &mut TestAppContext) {
        let (_dir, window, root) = fixture(cx, "");
        let visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(1180.), px(812.)));
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("/review".into(), cx));
        });
        cx.simulate_keystrokes(window.into(), "enter");
        cx.run_until_parked();
        root.update(cx, |view, _| assert!(view.skills.is_empty()));
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("".into(), cx));
        });
        cx.run_until_parked();
        cx.simulate_keystrokes(window.into(), "tab");
        cx.simulate_keystrokes(window.into(), "enter");
        cx.run_until_parked();
        root.update(cx, |view, _| {
            assert_eq!(view.skills.len(), 1);
            assert!(view.session.pending.is_empty());
        });
        cx.simulate_keystrokes(window.into(), "escape");
        cx.run_until_parked();
        root.update(cx, |view, _| assert!(view.skill_picker.is_none()));
    }
    #[gpui::test]
    fn rejected_freeze_restores_captured_variant_ahead_of_newer_draft(cx: &mut TestAppContext) {
        let (_dir, window, root) = fixture(cx, "captured text");
        let captured = select(&root, 1, cx);
        close(window, cx);
        std::fs::write(&captured.path, "---\nname: review\ndescription: Changed\ndisable-model-invocation: true\n---\nChanged body\n").unwrap();
        let mut newer = captured.clone();
        newer.selection.arguments = "newer literal arguments".into();
        root.update(cx, |view, cx| {
            view.submit_chat(Lane::FollowUp, cx);
            assert!(view.inflight_submission.is_some());
            view.skills.push(newer.clone());
            view.composer
                .update(cx, |editor, cx| editor.set_text("later text".into(), cx));
        });
        wait_for(&root, cx, |view| {
            !view.busy && view.inflight_submission.is_none()
        });
        root.update(cx, |view, cx| {
            assert!(view.session.pending.is_empty());
            assert!(view.session.messages.is_empty());
            assert_eq!(view.skills, vec![captured, newer]);
            assert_eq!(view.composer.read(cx).text(), "captured text\n\nlater text");
            assert!(validate_fresh(&view.skills).is_err());
            assert!(view.recoveries.is_empty());
            let saved = view.workspace.lock().unwrap().snapshot();
            assert_eq!(saved.drafts[&view.record.id].skills, view.skills);
        });
    }
    #[gpui::test]
    fn sent_skill_pills_keep_order_and_copy_only_raw_display_text(cx: &mut TestAppContext) {
        let (_dir, window, root) = fixture(cx, "");
        close(window, cx);
        let turn = uuid::Uuid::new_v4().to_string();
        root.update(cx, |view, cx| {
            let snapshot = view.skill_catalog.snapshot.clone().unwrap();
            let selections = vec![
                snapshot.skills[2].selection("second path first".into()),
                snapshot.skills[1].selection("first path second".into()),
            ];
            let frozen = snapshot.freeze(&selections).unwrap();
            let raw = "  typed /review stays plain\n日本語  ";
            let content = bello_agent_core::user_content::UserContent {
                attachments: vec![],
                skills: frozen.iter().map(|skill| skill.recorded()).collect(),
                blocks: vec![bello_agent_core::tool_content::ContentBlock::Text {
                    text: bello_agent_core::skills::user_message_text(raw, &frozen, &turn).unwrap(),
                }],
            };
            let message = bello_agent_core::Message {
                task_root_id: Some(turn.clone()),
                user_content: Some(Arc::new(content)),
                id: turn.clone(),
                role: "user".into(),
                text: raw.into(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "complete".into(),
                usage: serde_json::Value::Null,
                model: None,
                tool_record: None,
                compaction: None,
            };
            let mut store = SessionStore::pending_with_id(&view.record.id).unwrap();
            store
                .persist_to(view.project.join("sent-pill-fixture.json"))
                .unwrap();
            store
                .transact(|session| {
                    session.version = 8;
                    session.messages.push(message);
                    Ok(())
                })
                .unwrap();
            view.chat
                .replace_controller(Controller::new(store, None).unwrap(), cx);
            let key =
                crate::transcript_actions::MessageKey::new(view.record.id.clone(), turn.clone());
            view.copy_transcript_message(&key, &Arc::downgrade(&view.controller), cx);
            assert_eq!(cx.read_from_clipboard().unwrap().text().unwrap(), raw);
            assert_eq!(
                view.session.messages[0]
                    .user_content
                    .as_ref()
                    .unwrap()
                    .skills
                    .iter()
                    .map(|skill| skill.selection.clone())
                    .collect::<Vec<_>>(),
                selections
            );
            cx.notify();
        });
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(1180.), px(812.)));
        cx.run_until_parked();
        let first = visual
            .debug_bounds(Box::leak(format!("sent-skill-{turn}-0").into_boxed_str()))
            .unwrap();
        let second = visual
            .debug_bounds(Box::leak(format!("sent-skill-{turn}-1").into_boxed_str()))
            .unwrap();
        assert!(
            first.origin.y < second.origin.y
                || (first.origin.y == second.origin.y && first.origin.x < second.origin.x)
        );
    }
    #[gpui::test]
    fn same_turn_receipt_with_different_selection_stays_unresolved(cx: &mut TestAppContext) {
        let (_dir, window, root) = fixture(cx, "");
        let selected = select(&root, 1, cx);
        close(window, cx);
        root.update(cx, |view, cx| view.submit_chat(Lane::FollowUp, cx));
        wait_for(&root, cx, |view| {
            !view.busy && view.inflight_submission.is_none()
        });
        let receipt_id = root.update(cx, |view, cx| {
            assert_eq!(view.session.pending.len(), 1, "{:?}", view.error);
            let turn = view.session.pending[0].id.clone();
            let mut conflict = selected;
            conflict.selection.arguments = "different from accepted".into();
            view.skills = vec![conflict.clone()];
            view.draft_revision += 2;
            let receipt = bello_agent_core::workspace::SubmissionIntent {
                id: turn.clone(),
                chat_id: view.record.id.clone(),
                text: String::new(),
                lane: Lane::FollowUp,
                draft_revision: view.draft_revision,
                attachments: vec![],
                skills: vec![conflict],
            };
            let draft = view.saved_draft(cx);
            {
                let mut store = view.workspace.lock().unwrap();
                store.save_draft(&view.record.id, draft).unwrap();
                store.begin_submission(receipt.clone()).unwrap();
            }
            view.recoveries.insert(turn.clone(), receipt);
            view.resolve_intent(&turn, true, cx);
            turn
        });
        wait_for(&root, cx, |view| !view.busy);
        root.update(cx, |view, _| {
            assert!(view.recoveries.contains_key(&receipt_id));
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .intents
                    .contains_key(&receipt_id)
            );
            assert_eq!(
                view.skills[0].selection.arguments,
                "different from accepted"
            );
            assert_eq!(view.session.pending.len(), 1);
            assert!(
                view.session.pending[0].frozen_skills[0]
                    .arguments
                    .is_empty()
            );
            assert!(view.error.is_some());
        });
    }
    #[gpui::test]
    fn new_chat_keeps_selection_without_materializing_then_retains_failed_admission(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "");
        close(window, cx);
        window
            .update(cx, |view, window, cx| {
                view.connections.choice = view.record.connection_id.clone();
                view.new_chat(window, cx);
                assert!(view.pending);
                view.open_skill_picker(window, cx);
            })
            .unwrap();
        wait_for(&root, cx, |view| !view.skill_catalog.loading());
        let selected = select(&root, 0, cx);
        close(window, cx);
        root.update(cx, |view, cx| {
            assert!(view.pending);
            assert!(!view.record.snapshot.exists());
            assert_eq!(view.saved_draft(cx).skills, vec![selected.clone()]);
        });
        std::fs::write(&selected.path, "---\nname: other\ndescription: Changed source\ndisable-model-invocation: true\n---\nChanged before admission\n").unwrap();
        root.update(cx, |view, cx| view.submit_chat(Lane::FollowUp, cx));
        wait_for(&root, cx, |view| {
            !view.busy && view.inflight_submission.is_none()
        });
        root.update(cx, |view, _| {
            assert!(view.record.snapshot.exists());
            assert!(!view.pending);
            assert_eq!(view.skills, vec![selected]);
            assert!(view.session.messages.is_empty());
            assert!(view.session.pending.is_empty());
            assert!(view.workspace.lock().unwrap().snapshot().intents.is_empty());
        });
    }
    #[gpui::test]
    fn oversized_or_duplicate_argument_save_keeps_captured_chips_and_editor_open(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "draft");
        let first = select(&root, 0, cx);
        close(window, cx);
        window
            .update(cx, |view, window, cx| {
                let target = SkillTarget::capture(view);
                view.edit_skill_arguments(&target, &first, window, cx);
            })
            .unwrap();
        root.update(cx, |view, cx| {
            let token = view.skill_picker.as_ref().unwrap().token;
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("é".repeat(8193), cx));
            view.save_skill_arguments(token, cx);
            assert_eq!(view.skills, vec![first.clone()]);
            assert!(view.skill_picker.as_ref().unwrap().notice.is_some());
            let mut recovered = first.clone();
            recovered.selection.arguments = "duplicate".into();
            view.skills.push(recovered.clone());
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("duplicate".into(), cx));
            view.save_skill_arguments(token, cx);
            assert_eq!(view.skills, vec![first, recovered]);
            assert!(view.skill_picker.as_ref().unwrap().notice.is_some());
            assert_eq!(view.composer.read(cx).text(), "draft");
        });
    }
    #[gpui::test]
    fn partial_catalog_and_no_match_keep_controls_inside_minimum_window(cx: &mut TestAppContext) {
        let (_dir, window, root) = fixture(cx, "");
        root.update(cx, |view, cx| { view.skill_catalog.state = CatalogState::Partial; view.skill_catalog.notice = Some("A source could not be inspected. Successfully discovered entries remain available.".repeat(3)); cx.notify(); });
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(920.), px(600.)));
        cx.run_until_parked();
        for selector in [
            "project-skills-picker",
            "skill-refresh",
            "skill-picker-close",
            "skill-picker-editor",
        ] {
            let bounds = visual.debug_bounds(selector).unwrap();
            assert!(
                bounds.origin.y >= px(0.) && bounds.bottom() <= px(600.),
                "{selector}: {bounds:?}"
            );
        }
        root.update(cx, |view, cx| {
            view.skill_picker
                .as_ref()
                .unwrap()
                .editor
                .update(cx, |editor, cx| editor.set_text("never-a-match".into(), cx));
        });
        cx.run_until_parked();
        assert!(visual.debug_bounds("skill-catalog-empty").is_some());
        root.update(cx, |view, cx| {
            view.skill_catalog.state = CatalogState::Failed;
            view.skill_catalog.notice = Some("Discovery failed".into());
            cx.notify();
        });
        cx.run_until_parked();
        assert!(
            visual.debug_bounds("skill-catalog-empty").is_none(),
            "failed discovery cannot prove an empty catalog"
        );
        assert!(visual.debug_bounds("skill-refresh").is_some());
    }
    #[gpui::test]
    fn same_controller_configuration_change_invalidates_old_chip_and_picker_actions(
        cx: &mut TestAppContext,
    ) {
        let (_dir, window, root) = fixture(cx, "draft");
        let selected = select(&root, 0, cx);
        window
            .update(cx, |view, window, cx| {
                let target = SkillTarget::capture(view);
                let token = view.skill_picker.as_ref().unwrap().token;
                let snapshot = view.skill_catalog.snapshot.clone().unwrap();
                let other = snapshot.skills[1].chip(String::new());
                let current = view.controller.configuration().unwrap();
                let generation = view.controller.project_skills_ui_generation();
                view.controller.configure(current).unwrap();
                assert_ne!(view.controller.project_skills_ui_generation(), generation);
                view.remove_presented_skill(&target, &selected, cx);
                view.edit_skill_arguments(&target, &selected, window, cx);
                view.add_presented_skill(token, &snapshot, &other, cx);
                assert_eq!(view.skills, vec![selected.clone()]);
                let fresh = SkillTarget::capture(view);
                view.remove_presented_skill(&fresh, &selected, cx);
                assert!(view.skills.is_empty());
            })
            .unwrap();
    }
}
