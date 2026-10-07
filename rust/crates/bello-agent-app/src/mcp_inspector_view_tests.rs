use super::{
    HEADER_BYTES, McpEvent, McpInput, McpInspectorView, McpIntent, McpPresentation, McpToken,
    PAGE_BYTES, Palette,
};
use gpui::{
    AppContext, Context, Entity, IntoElement, KeyDownEvent, Keystroke, Modifiers, Render,
    Subscription, TestAppContext, VisualTestContext, Window, WindowAppearance, WindowHandle, div,
    prelude::*, px, size,
};
use std::collections::BTreeMap;
use std::{cell::RefCell, rc::Rc};
fn ready() -> McpPresentation {
    let mut p = McpPresentation::new(true);
    p.ready = true;
    p.configuration_applied = true;
    p.project_id = Some("project-a".into());
    p.project_path = "/fixture/a".into();
    p.servers = vec!["fixture".into()];
    p.editing = true;
    p
}
#[::core::prelude::v1::test]
fn production_busy_unconfirmed_and_read_only_fail_closed() {
    let mut p = ready();
    p.synthetic = false;
    assert!(!p.allows(&McpIntent::Save));
    assert!(!p.allows(&McpIntent::Invoke));
    assert!(p.allows(&McpIntent::Close));
    p = ready();
    p.editing = false;
    assert!(!p.allows(&McpIntent::Invoke));
    assert!(p.allows(&McpIntent::Describe));
    p.busy = true;
    p.cancellable = true;
    assert!(!p.allows(&McpIntent::Save));
    assert!(!p.allows(&McpIntent::Acknowledge));
    assert!(p.allows(&McpIntent::CancelOperation));
    p.saving = true;
    assert!(!p.allows(&McpIntent::Close));
    assert!(!p.allows(&McpIntent::CancelOperation));
    p = ready();
    p.blocked = true;
    assert!(!p.allows(&McpIntent::Reload));
    assert!(!p.allows(&McpIntent::Save));
    assert!(p.allows(&McpIntent::Close));
}
#[::core::prelude::v1::test]
fn unknown_and_pending_receipt_fence_one_shot_and_acknowledgment() {
    let mut p = ready();
    p.unknown_id = Some("exact-marker-set".into());
    assert!(!p.allows(&McpIntent::Invoke));
    assert!(p.allows(&McpIntent::Acknowledge));
    assert!(p.allows(&McpIntent::Save));
    p.pending_results = 1;
    assert!(!p.allows(&McpIntent::Acknowledge));
    p.unknown_id = None;
    assert!(!p.allows(&McpIntent::Invoke));
}
#[::core::prelude::v1::test]
fn debug_does_not_contain_any_typed_configuration_credentials_or_arguments() {
    let input = McpInput {
        configuration: "invalid-secret-config".into(),
        headers: BTreeMap::from([("fixture".into(), "fixture-secret-header".into())]),
        arguments: "argument-secret".into(),
        server: "typed-secret-name".into(),
        tool: "typed-secret-tool".into(),
    };
    let rendered = format!(
        "{:?}",
        McpEvent {
            token: McpToken {
                revision: 1,
                opening: 1
            },
            intent: McpIntent::Save,
            input: Some(input)
        }
    );
    for forbidden in [
        "invalid-secret-config",
        "fixture-secret-header",
        "argument-secret",
        "typed-secret-name",
        "typed-secret-tool",
    ] {
        assert!(!rendered.contains(forbidden));
    }
    assert!(rendered.contains("REDACTED"));
}
struct Host {
    panel: Entity<McpInspectorView>,
    events: Rc<RefCell<Vec<McpEvent>>>,
    _subscription: Subscription,
}
impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.panel.clone())
    }
}
fn fixture(
    cx: &mut TestAppContext,
) -> (WindowHandle<Host>, Entity<Host>, Rc<RefCell<Vec<McpEvent>>>) {
    let events = Rc::new(RefCell::new(Vec::new()));
    let observed = events.clone();
    let window = cx.add_window(|_, cx| {
        let panel = cx.new(|cx| {
            McpInspectorView::new(
                ready(),
                Palette::for_appearance(WindowAppearance::Light),
                cx,
            )
        });
        let subscription = cx.subscribe(&panel, |host: &mut Host, _, event, _| {
            host.events.borrow_mut().push(event.clone())
        });
        Host {
            panel,
            events: observed,
            _subscription: subscription,
        }
    });
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |v, cx| v.show(window, cx))
        })
        .unwrap();
    VisualTestContext::from_window(window.into(), cx).simulate_resize(size(px(1000.), px(800.)));
    cx.run_until_parked();
    let root = window.root(cx).unwrap();
    (window, root, events)
}
#[gpui::test]
fn close_reopen_preserves_general_editor_identity_and_masked_replacement(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx);
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |v, cx| {
                let draft =
                    r#"{"servers":{"fixture":{"transport":"http","url":"http://127.0.0.1:9"}}}"#;
                v.config
                    .as_ref()
                    .unwrap()
                    .update(cx, |e, cx| e.set_text(draft.into(), cx));
                v.ensure_headers(cx);
                v.headers["fixture"].update(cx, |e, cx| {
                    assert!(e.set_text(r#"{"X-Test":"synthetic-header-fixture-only"}"#.into(), cx));
                });
                let editor = v.config.as_ref().unwrap().entity_id();
                let secure = v.headers["fixture"].entity_id();
                let input = v.input(cx).unwrap();
                assert!(v.dirty(cx));
                v.close(false, window, cx);
                v.show(window, cx);
                assert_eq!(v.config.as_ref().unwrap().entity_id(), editor);
                assert_eq!(v.headers["fixture"].entity_id(), secure);
                assert_eq!(v.input(cx).unwrap().headers, input.headers);
                assert_eq!(v.input(cx).unwrap().configuration, draft);
                assert!(
                    !v.config
                        .as_ref()
                        .unwrap()
                        .read(cx)
                        .text()
                        .contains("synthetic-header-fixture-only")
                );
            })
        })
        .unwrap();
}
#[gpui::test]
fn repeated_stale_and_prior_opening_callbacks_emit_only_once(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx);
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |v, cx| {
                let old = v.token();
                v.dispatch(old, McpIntent::Save, cx);
                v.dispatch(old, McpIntent::Save, cx);
                let mut p = ready();
                p.revision = 2;
                v.present(p, cx);
                v.dispatch(old, McpIntent::Save, cx);
                let prior = v.token();
                v.close(false, window, cx);
                v.show(window, cx);
                v.dispatch(prior, McpIntent::Save, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 1);
}
#[gpui::test]
fn event_captures_latest_input_without_waiting_for_edit_notification(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |v, cx| {
                v.config.as_ref().unwrap().update(cx, |e, cx| {
                    e.set_text(r#"{"servers":{"last-keystroke":{}}}"#.into(), cx)
                });
                v.dispatch(v.token(), McpIntent::Save, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert!(
        events.borrow()[0]
            .input
            .as_ref()
            .unwrap()
            .configuration
            .contains("last-keystroke")
    );
}
#[gpui::test]
fn rejected_secret_replacement_cannot_be_captured_as_empty_clear(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |v, cx| {
                v.config.as_ref().unwrap().update(cx, |e, cx| {
                    e.set_text(r#"{"servers":{"fixture":{}}}"#.into(), cx)
                });
                v.ensure_headers(cx);
                v.headers["fixture"].update(cx, |e, cx| {
                    e.set_text("{}".into(), cx);
                    assert!(!e.set_text("x".repeat(HEADER_BYTES + 1), cx));
                });
                assert!(v.input(cx).is_none());
            })
        })
        .unwrap();
}
#[gpui::test]
fn published_busy_result_does_not_overwrite_unacknowledged_configuration(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |v, cx| {
                v.config
                    .as_ref()
                    .unwrap()
                    .update(cx, |e, cx| e.set_text("last draft 日本語".into(), cx));
                let mut p = ready();
                p.revision = 2;
                p.busy = true;
                v.present(p, cx);
                v.set_output("Discovery result".into(), cx);
                assert_eq!(v.input(cx).unwrap().configuration, "last draft 日本語");
            })
        })
        .unwrap();
}
#[gpui::test]
fn output_paging_keeps_unicode_boundaries_and_exact_reconstruction(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |v, cx| {
                let text = "日本語🦀".repeat(20000);
                v.set_output(text.clone(), cx);
                assert!(v.pages.len() > 1);
                let restored = v
                    .pages
                    .iter()
                    .map(|r| &v.output[r.clone()])
                    .collect::<String>();
                assert_eq!(restored, text);
                assert!(v.pages.iter().all(|r| r.len() <= PAGE_BYTES));
            })
        })
        .unwrap();
}
#[gpui::test]
fn confirmation_locks_editors_and_escape_cancels_only_the_question(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx);
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |v, cx| {
                let mut p = ready();
                p.revision = 2;
                p.confirmation = Some(("Trust?".into(), "Review first".into(), "Save".into()));
                v.present(p, cx);
                let event = KeyDownEvent {
                    keystroke: Keystroke {
                        modifiers: Modifiers::none(),
                        key: "escape".into(),
                        key_char: None,
                    },
                    is_held: false,
                };
                assert!(v.key(&event, window, cx));
                assert!(v.open);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(events.borrow()[0].intent, McpIntent::CancelConfirmation);
}

#[gpui::test]
fn removing_server_does_not_transmit_its_retained_masked_draft(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |v, cx| {
                v.config.as_ref().unwrap().update(cx, |e, cx| {
                    e.set_text(r#"{"servers":{"fixture":{}}}"#.into(), cx)
                });
                v.ensure_headers(cx);
                v.headers["fixture"].update(cx, |e, cx| {
                    e.set_text(r#"{"X-Test":"synthetic-header-fixture-only"}"#.into(), cx);
                });
                v.config
                    .as_ref()
                    .unwrap()
                    .update(cx, |e, cx| e.set_text(r#"{"servers":{}}"#.into(), cx));
                assert!(v.input(cx).unwrap().headers.is_empty());
                v.config.as_ref().unwrap().update(cx, |e, cx| {
                    e.set_text(r#"{"servers":{"fixture":{}}}"#.into(), cx)
                });
                assert!(
                    v.input(cx).unwrap().headers["fixture"]
                        .contains("synthetic-header-fixture-only")
                );
            })
        })
        .unwrap();
}
#[::core::prelude::v1::test]
fn confirmation_cancel_remains_available_when_project_manager_becomes_busy() {
    let mut p = ready();
    p.confirmation = Some(("Question".into(), "Detail".into(), "Confirm".into()));
    p.busy = true;
    assert!(p.allows(&McpIntent::CancelConfirmation));
    assert!(!p.allows(&McpIntent::Confirm));
}

#[::core::prelude::v1::test]
fn newer_saved_configuration_requires_explicit_review_save_apply_before_requests() {
    let mut p = ready();
    p.configuration_applied = false;
    assert!(p.allows(&McpIntent::Save));
    assert!(p.allows(&McpIntent::SelectHeader("fixture".into())));
    for intent in [
        McpIntent::Refresh,
        McpIntent::ListTools,
        McpIntent::Describe,
        McpIntent::Invoke,
        McpIntent::Acknowledge,
    ] {
        assert!(!p.allows(&intent));
    }
    p.configuration_applied = true;
    p.receipt_read_failed = true;
    assert!(!p.allows(&McpIntent::Invoke));
    assert!(p.allows(&McpIntent::Reload));
}

#[::core::prelude::v1::test]
fn shared_project_work_without_inspector_token_does_not_offer_cancellation() {
    let mut p = ready();
    p.busy = true;
    assert!(!p.allows(&McpIntent::CancelOperation));
    assert!(p.allows(&McpIntent::Close));
    p.cancellable = true;
    assert!(p.allows(&McpIntent::CancelOperation));
    p.saving = true;
    assert!(!p.allows(&McpIntent::CancelOperation));
}
