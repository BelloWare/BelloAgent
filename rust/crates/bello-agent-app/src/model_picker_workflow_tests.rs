//! The composer's model and effort pills against a saved fixture connection
//! whose catalog and route are a loopback gateway: list, Refresh, choose,
//! remember, and send the chosen model. Nothing leaves the loopback host.
use super::*;
use crate::model_picker::PickerKind;
use bello_agent_core::model_choice::{ModelChoice, ModelChoiceStore, ThinkingLevel};

fn saved_on_gateway(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    Gateway,
    String,
) {
    let (dir, _control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    edit(&root, cx, |f| {
        f.base_url = gateway.url.clone();
        f.catalog_url = format!("{}/catalog?token=fixture-only", gateway.url);
        f.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::SaveAll, cx);
    let id = cx.read(|cx| root.read(cx).connections.choice.clone().unwrap());
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    assert_eq!(gateway.count("get"), 0, "saving and choosing list nothing");
    (dir, window, root, gateway, id)
}
fn open(window: WindowHandle<AgentView>, kind: PickerKind, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            view.toggle_model_picker(kind, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
}
fn token(root: &Entity<AgentView>, cx: &TestAppContext) -> uuid::Uuid {
    cx.read(|cx| root.read(cx).model_pickers.open.as_ref().unwrap().token)
}
fn listed(root: &Entity<AgentView>, cx: &mut TestAppContext) {
    wait(cx, |cx| {
        cx.read(|cx| {
            let view = root.read(cx);
            view.chat_catalog().is_some_and(|c| !c.loading)
                && view
                    .model_pickers
                    .open
                    .as_ref()
                    .is_none_or(|o| !o.refreshing)
        })
    });
}

#[gpui::test]
fn pills_list_refresh_choose_remember_and_send_the_chosen_model(cx: &mut TestAppContext) {
    let (dir, window, root, gateway, connection) = saved_on_gateway(cx);
    cx.read(|cx| {
        let reading = root.read(cx).model_pill_reading();
        assert_eq!(reading.model, "local-test-fixture");
        assert!(!reading.model_active);
        assert_eq!(reading.effort, "Effort · connection default");
        assert!(!reading.effort_active);
        assert!(!reading.disabled);
    });
    open(window, PickerKind::Model, cx);
    listed(&root, cx);
    assert_eq!(gateway.count("get"), 1, "opening lists once");
    cx.read(|cx| {
        let view = root.read(cx);
        let catalog = view.chat_catalog().unwrap();
        assert_eq!(catalog.models.len(), 170);
        assert_eq!(
            catalog.offered(None).len(),
            169,
            "deprecated rows are hidden"
        );
        assert!(catalog.configured);
        assert!(catalog.error.is_none());
        assert!(
            !catalog.source_label.contains("token"),
            "the catalog URL's query is never shown: {}",
            catalog.source_label
        );
        assert!(catalog.source_label.ends_with("/catalog"));
    });
    // Closing and opening again within the TTL reads nothing.
    open(window, PickerKind::Model, cx);
    assert!(cx.read(|cx| root.read(cx).model_pickers.open.is_none()));
    open(window, PickerKind::Model, cx);
    listed(&root, cx);
    assert_eq!(gateway.count("get"), 1);
    // Refresh always fetches, after reloading the saved connection.
    let picker = token(&root, cx);
    root.update(cx, |view, cx| view.refresh_chat_catalog(picker, cx));
    listed(&root, cx);
    assert_eq!(gateway.count("get"), 2);
    // A failed Refresh keeps the last list beside its error.
    gateway.fail.store(true, Ordering::SeqCst);
    root.update(cx, |view, cx| view.refresh_chat_catalog(picker, cx));
    listed(&root, cx);
    assert_eq!(gateway.count("get"), 3);
    cx.read(|cx| {
        let catalog = root.read(cx).chat_catalog().unwrap();
        assert_eq!(catalog.models.len(), 170);
        assert!(catalog.error.is_some());
    });
    gateway.fail.store(false, Ordering::SeqCst);
    window
        .update(cx, |view, window, cx| {
            view.choose_chat_model(picker, Some("fixture-model-169".into()), window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    let chat = cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            view.model_pickers.open.is_none(),
            "choosing closes the list"
        );
        let reading = view.model_pill_reading();
        assert_eq!(reading.model, "fixture-model-169");
        assert!(reading.model_active);
        assert!(
            reading
                .model_help
                .contains("Profile default: local-test-fixture")
        );
        view.record.id.clone()
    });
    // The catalog lists only "low": the effort list offers it and the
    // model's own default, and the connection's default ("default") too.
    open(window, PickerKind::Effort, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.offered_effort_levels(),
            [
                ThinkingLevel::ProfileDefault,
                ThinkingLevel::Default,
                ThinkingLevel::Low
            ]
        );
        assert_eq!(view.effort_note(), Some("Levels from the model catalog"));
    });
    let picker = token(&root, cx);
    window
        .update(cx, |view, window, cx| {
            view.choose_chat_effort(picker, ThinkingLevel::Low, window, cx)
        })
        .unwrap();
    let chosen = ModelChoice {
        model: Some("fixture-model-169".into()),
        thinking_level: Some("low".into()),
    };
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.model_pill_reading().effort, "Effort · low");
        assert_eq!(view.chat_model_choice(), chosen);
    });
    // Saved for the chat and as the connection's next-chat default, on disk.
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let reopened = ModelChoiceStore::open(project.join("chat-models.json"));
    assert_eq!(reopened.chat(&chat), chosen);
    assert_eq!(reopened.default_for(&connection), Some(chosen.clone()));
    assert_eq!(gateway.count("post"), 0, "choosing sends nothing");
    // The next turn carries the choice to the gateway.
    root.update(cx, |view, cx| {
        view.composer
            .update(cx, |editor, cx| editor.set_text("hello".into(), cx));
        view.submit(Lane::FollowUp, cx)
    });
    wait(cx, |_| gateway.count("post") == 1);
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.state != bello_agent_core::RunState::Running)
    });
    {
        let receipts = gateway.receipts.lock().unwrap();
        let post = receipts.iter().find(|r| r.method == "post").unwrap();
        assert_eq!(post.body["model"], "fixture-model-169");
    }
    // A new chat on the same connection starts from the remembered choice.
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_ne!(view.record.id, chat);
        assert_eq!(view.chat_model_choice(), chosen);
        assert_eq!(view.model_pill_reading().model, "fixture-model-169");
    });
    // Use connection default restores the connection's model for this chat
    // and becomes the next-chat default, leaving the first chat alone.
    open(window, PickerKind::Model, cx);
    let picker = token(&root, cx);
    window
        .update(cx, |view, window, cx| {
            view.choose_chat_model(picker, None, window, cx)
        })
        .unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.model_pill_reading().model, "local-test-fixture");
        assert_eq!(
            view.chat_model_choice().thinking_level.as_deref(),
            Some("low")
        );
        assert_eq!(view.model_pickers.choices.chat(&chat), chosen);
    });
}

#[gpui::test]
fn alias_entry_and_effort_keys_choose_without_listing_again(cx: &mut TestAppContext) {
    let (_dir, window, root, gateway, _) = saved_on_gateway(cx);
    open(window, PickerKind::Model, cx);
    listed(&root, cx);
    let picker = token(&root, cx);
    window
        .update(cx, |view, window, cx| {
            view.toggle_alias_entry(picker, window, cx);
            let alias = view
                .model_pickers
                .open
                .as_ref()
                .unwrap()
                .alias
                .clone()
                .unwrap();
            alias.update(cx, |editor, cx| {
                editor.set_text("  router-alias  ".into(), cx)
            });
            view.submit_model_alias(picker, window, cx);
        })
        .unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.chat_model_choice().model.as_deref(),
            Some("router-alias")
        );
        assert_eq!(view.model_pill_reading().model, "router-alias");
    });
    // An unlisted alias offers every level; nothing is fetched to decide.
    open(window, PickerKind::Effort, cx);
    cx.read(|cx| {
        assert_eq!(root.read(cx).offered_effort_levels().len(), 9);
        assert_eq!(root.read(cx).effort_note(), None);
    });
    // A second press on the same pill closes its list.
    open(window, PickerKind::Effort, cx);
    assert!(cx.read(|cx| root.read(cx).model_pickers.open.is_none()));
    // Another chat's list never chooses for this one.
    open(window, PickerKind::Effort, cx);
    let stale = token(&root, cx);
    root.update(cx, |view, _| {
        view.model_pickers.open.as_mut().unwrap().chat = "another-chat".into()
    });
    window
        .update(cx, |view, window, cx| {
            view.choose_chat_effort(stale, ThinkingLevel::Max, window, cx)
        })
        .unwrap();
    cx.read(|cx| {
        assert_eq!(root.read(cx).chat_model_choice().thinking_level, None);
    });
    assert_eq!(gateway.count("get"), 1);
    assert_eq!(gateway.count("post"), 0);
}

#[gpui::test]
fn pills_and_lists_draw_and_answer_the_pointer_and_escape(cx: &mut TestAppContext) {
    use gpui::{Modifiers, VisualTestContext, px, size};
    let (_dir, window, root, gateway, _) = saved_on_gateway(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1280.), px(840.)));
    cx.run_until_parked();
    let pill = visual
        .debug_bounds("session-model-picker")
        .expect("model pill");
    visual.simulate_click(pill.center(), Modifiers::none());
    listed(&root, cx);
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let panel = visual
        .debug_bounds("model-catalog-picker")
        .expect("model list drawn");
    assert!(
        panel.bottom() <= pill.top() + px(1.),
        "the list opens above its pill"
    );
    assert!(visual.debug_bounds("refresh-model-catalog").is_some());
    assert!(visual.debug_bounds("model-catalog-search").is_some());
    let first = visual
        .debug_bounds("catalog-choice-fixture-model-000")
        .expect("first row drawn");
    visual.simulate_click(first.center(), Modifiers::none());
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.model_pickers.open.is_none());
        assert_eq!(
            view.chat_model_choice().model.as_deref(),
            Some("fixture-model-000")
        );
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let effort = visual
        .debug_bounds("session-reasoning-picker")
        .expect("effort pill");
    visual.simulate_click(effort.center(), Modifiers::none());
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("reasoning-effort-list").is_some());
    // A press on the pill while its list is open lands on the backdrop,
    // which closes the list without opening it again.
    visual.simulate_click(effort.center(), Modifiers::none());
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).model_pickers.open.is_none()));
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_click(effort.center(), Modifiers::none());
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).model_pickers.open.is_some()));
    cx.simulate_keystrokes(window.into(), "down enter");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.model_pickers.open.is_none());
        assert!(view.chat_model_choice().thinking_level.is_some());
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_click(pill.center(), Modifiers::none());
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).model_pickers.open.is_none()));
    assert_eq!(gateway.count("post"), 0);
}
