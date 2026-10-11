//! Isolated fake-platform view contracts. No vault, provider or native access.
use super::{
    ConnectionConfirmation, ConnectionFields, ConnectionForm, ConnectionSettingsAvailability,
    ConnectionSettingsEvent, ConnectionSettingsIntent, ConnectionSettingsNotice,
    ConnectionSettingsPresentation, ConnectionSettingsView, ConnectionTab, Control, Field,
};
use crate::theme::Palette;
use gpui::{
    Context, Entity, EntityInputHandler, FocusHandle, Focusable, IntoElement, KeyDownEvent,
    Keystroke, Modifiers, Render, Subscription, TestAppContext, VisualTestContext, Window,
    WindowAppearance, WindowHandle, div, prelude::*, px, size,
};
use std::{cell::RefCell, rc::Rc};

fn ready() -> ConnectionSettingsPresentation {
    ConnectionSettingsPresentation {
        revision: 1,
        mode: crate::launch_authority::AuthorityMode::Fixture,
        availability: ConnectionSettingsAvailability::Ready,
        saving: false,
        tabs: vec![ConnectionTab {
            id: "one".into(),
            label: "Fixture router".into(),
            saved: true,
            dirty: false,
        }],
        active: Some(ConnectionForm {
            id: "one".into(),
            saved: true,
            catalog: Default::default(),
            model_metadata: "Model output ceiling: unknown".into(),
            inherited_catalog_name: None,
            fields: ConnectionFields {
                name: "Fixture router".into(),
                api: "openai-responses".into(),
                base_url: "http://127.0.0.1:9".into(),
                model: "fixture-model".into(),
                catalog_url: String::new(),
                catalog_search: String::new(),
                context_window: "32000".into(),
                output_budget: "4096".into(),
                key: String::new(),
                headers: String::new(),
            },
        }),
        dirty: false,
        completion_sound_enabled: true,
        completion_sound_dirty: false,
        section: super::SettingsSection::Connections,
        transcript_display: crate::app_settings::TranscriptDisplayMode::Compact,
        transcript_display_dirty: false,
        confirmation: ConnectionConfirmation::None,
        notice: None,
    }
}

#[test]
fn unavailable_storage_never_enables_mutating_controls() {
    use ConnectionSettingsAvailability as Availability;
    for availability in [
        Availability::Loading,
        Availability::Busy("Working".into()),
        Availability::Unavailable("Unavailable".into()),
        Availability::Failed("Failed".into()),
        Availability::Unconfirmed("Reload to review".into()),
    ] {
        let mut p = ready();
        p.availability = availability;
        for intent in [
            ConnectionSettingsIntent::Edited,
            ConnectionSettingsIntent::New,
            ConnectionSettingsIntent::SaveAll,
            ConnectionSettingsIntent::RequestDelete,
        ] {
            assert!(!p.allows(&intent));
        }
        assert!(p.status().is_some());
    }
    let mut p = ready();
    p.mode = crate::launch_authority::AuthorityMode::Unavailable;
    assert!(!p.allows(&ConnectionSettingsIntent::Edited));
    assert!(!p.allows(&ConnectionSettingsIntent::SaveAll));
    assert!(!p.allows(&ConnectionSettingsIntent::RequestDelete));
    assert!(p.allows(&ConnectionSettingsIntent::RequestClose));
}

#[test]
fn native_mode_enables_only_ready_settings_and_retains_confirmation_guards() {
    let mut p = ready();
    p.mode = crate::launch_authority::AuthorityMode::Native;
    for intent in [
        ConnectionSettingsIntent::Edited,
        ConnectionSettingsIntent::New,
        ConnectionSettingsIntent::SaveAll,
        ConnectionSettingsIntent::RequestDelete,
    ] {
        assert!(p.allows(&intent));
    }
    p.confirmation = ConnectionConfirmation::Close;
    assert!(p.allows(&ConnectionSettingsIntent::SaveAndClose));
    assert!(!p.allows(&ConnectionSettingsIntent::New));
    p.confirmation = ConnectionConfirmation::Delete {
        summary: String::new(),
    };
    assert!(p.allows(&ConnectionSettingsIntent::ConfirmDelete));
    p.availability = ConnectionSettingsAvailability::Unconfirmed("Review required".into());
    assert!(!p.allows(&ConnectionSettingsIntent::ConfirmDelete));
    assert!(!super::NATIVE_NOTICE.contains("Fixture-only"));
    assert!(super::NATIVE_NOTICE.contains("in a trusted project they offer its tools"));
}

#[test]
fn loading_can_close_but_saving_cannot_close_reload_or_discard() {
    let mut p = ready();
    p.availability = ConnectionSettingsAvailability::Loading;
    assert!(p.allows(&ConnectionSettingsIntent::RequestClose));
    assert!(p.allows(&ConnectionSettingsIntent::Cancel));
    assert!(!p.allows(&ConnectionSettingsIntent::Reload));
    p.saving = true;
    for intent in [
        ConnectionSettingsIntent::RequestClose,
        ConnectionSettingsIntent::Cancel,
        ConnectionSettingsIntent::Reload,
        ConnectionSettingsIntent::DiscardAndClose,
        ConnectionSettingsIntent::KeepEditing,
    ] {
        assert!(!p.allows(&intent));
    }
}

#[test]
fn confirmation_choices_are_scoped_to_the_question_and_saved_identity() {
    let mut p = ready();
    p.confirmation = ConnectionConfirmation::Delete {
        summary: "Earlier chats remain.".into(),
    };
    assert!(p.allows(&ConnectionSettingsIntent::ConfirmDelete));
    assert!(p.allows(&ConnectionSettingsIntent::Keep));
    assert!(!p.allows(&ConnectionSettingsIntent::SaveAll));
    assert!(!p.allows(&ConnectionSettingsIntent::DiscardAndClose));
    p.active.as_mut().unwrap().saved = false;
    assert!(!p.allows(&ConnectionSettingsIntent::ConfirmDelete));
    p.confirmation = ConnectionConfirmation::Close;
    assert!(p.allows(&ConnectionSettingsIntent::SaveAndClose));
    assert!(p.allows(&ConnectionSettingsIntent::DiscardAndClose));
    assert!(p.allows(&ConnectionSettingsIntent::KeepEditing));
    assert!(!p.allows(&ConnectionSettingsIntent::DiscardAndReload));
    p.availability = ConnectionSettingsAvailability::Unconfirmed("Unknown outcome".into());
    assert!(!p.allows(&ConnectionSettingsIntent::SaveAndClose));
    assert!(p.allows(&ConnectionSettingsIntent::KeepEditing));
    p.confirmation = ConnectionConfirmation::Reload;
    assert!(p.allows(&ConnectionSettingsIntent::DiscardAndReload));
    assert!(!p.allows(&ConnectionSettingsIntent::DiscardAndClose));
}

#[test]
fn tabs_require_a_real_target_even_with_a_history_only_active_connection() {
    let mut p = ready();
    assert!(!p.allows(&ConnectionSettingsIntent::Select("one".into())));
    assert!(!p.allows(&ConnectionSettingsIntent::Select("unknown".into())));
    p.active.as_mut().unwrap().fields.api = "anthropic-messages".into();
    p.tabs.push(ConnectionTab {
        id: "two".into(),
        label: "Other".into(),
        saved: true,
        dirty: false,
    });
    assert!(p.allows(&ConnectionSettingsIntent::Select("two".into())));
}

#[test]
fn debug_output_redacts_typed_replacements_in_forms_and_events() {
    let mut fields = ready().active.unwrap().fields;
    fields.base_url = "http://user:fixture-secret@127.0.0.1:9?key=fixture-query".into();
    fields.key = "synthetic-project-fixture-only".into();
    fields.headers = "{\"X-Fixture\":\"synthetic-header-fixture-only\"}".into();
    let event = ConnectionSettingsEvent::Intent {
        revision: 1,
        active_id: Some("one".into()),
        fields: Some(Box::new(fields)),
        intent: ConnectionSettingsIntent::SaveAll,
    };
    let debug = format!("{event:?}");
    assert!(!debug.contains("fixture-secret"));
    assert!(!debug.contains("fixture-query"));
    assert!(!debug.contains("synthetic-project-fixture-only"));
    assert!(!debug.contains("synthetic-header-fixture-only"));
    assert!(debug.contains("redacted"));
}

struct Host {
    panel: Entity<ConnectionSettingsView>,
    outside: FocusHandle,
    newer: FocusHandle,
    events: Rc<RefCell<Vec<ConnectionSettingsEvent>>>,
    _subscription: Subscription,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .track_focus(&self.outside)
            .on_any_mouse_down(|_, window, _| window.prevent_default())
            .child(div().id("newer-focus").track_focus(&self.newer))
            .when(self.panel.read(cx).is_open(), |root| {
                root.child(self.panel.clone())
            })
    }
}

type Fixture = (
    WindowHandle<Host>,
    Entity<Host>,
    Rc<RefCell<Vec<ConnectionSettingsEvent>>>,
);
fn fixture(cx: &mut TestAppContext, presentation: ConnectionSettingsPresentation) -> Fixture {
    let events = Rc::new(RefCell::new(Vec::new()));
    let observed = events.clone();
    let window = cx.add_window(|_, cx| {
        let panel = cx.new(|cx| {
            ConnectionSettingsView::new(
                presentation,
                Palette::for_appearance(WindowAppearance::Light),
                cx,
            )
        });
        let subscription = cx.subscribe(&panel, |host: &mut Host, _, event, cx| {
            host.events.borrow_mut().push(event.clone());
            cx.notify();
        });
        Host {
            panel,
            outside: cx.focus_handle(),
            newer: cx.focus_handle(),
            events: observed,
            _subscription: subscription,
        }
    });
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    window
        .update(cx, |host, window, cx| {
            host.outside.focus(window);
            host.panel.update(cx, |panel, cx| panel.show(window, cx));
            cx.notify();
        })
        .unwrap();
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(900.), px(730.)));
    cx.run_until_parked();
    (window, root, events)
}

fn key(value: &str, modifiers: Modifiers) -> KeyDownEvent {
    KeyDownEvent {
        keystroke: Keystroke {
            modifiers,
            key: value.into(),
            key_char: None,
        },
        is_held: false,
    }
}

#[gpui::test]
fn every_action_captures_final_editor_text_before_changed_notification(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |editor, cx| editor.set_text("Final typing".into(), cx));
                panel.dispatch(panel.token(), ConnectionSettingsIntent::SaveAll, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 1);
    let ConnectionSettingsEvent::Intent {
        revision,
        active_id,
        fields,
        intent,
    } = &events.borrow()[0]
    else {
        panic!("expected Save All")
    };
    assert_eq!(*revision, 1);
    assert_eq!(active_id.as_deref(), Some("one"));
    assert_eq!(fields.as_ref().unwrap().name, "Final typing");
    assert_eq!(*intent, ConnectionSettingsIntent::SaveAll);
}

#[gpui::test]
fn render_does_not_overwrite_unacknowledged_typing_and_echo_retains_editor(
    cx: &mut TestAppContext,
) {
    let (window, root, events) = fixture(cx, ready());
    let editor_id =
        cx.read(|cx| root.read(cx).panel.read(cx).editors["one"].fields[&Field::Name].entity_id());
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                panel.editors["one"].fields[&Field::Name]
                    .update(cx, |editor, cx| editor.set_text("日本語 draft".into(), cx));
                cx.notify();
            });
        })
        .unwrap();
    cx.run_until_parked();
    assert!(events.borrow().iter().any(|event| matches!(event, ConnectionSettingsEvent::Intent { intent: ConnectionSettingsIntent::Edited, fields: Some(fields), .. } if fields.name == "日本語 draft")));
    root.update(cx, |host, cx| {
        host.panel.update(cx, |panel, cx| {
            assert_eq!(
                panel.editors["one"].fields[&Field::Name].read(cx).text(),
                "日本語 draft"
            );
            let mut p = ready();
            p.revision = 2;
            p.active.as_mut().unwrap().fields.name = "日本語 draft".into();
            p.dirty = true;
            panel.set_presentation(p, cx);
            assert_eq!(
                panel.editors["one"].fields[&Field::Name].entity_id(),
                editor_id
            );
            assert_eq!(
                panel.editors["one"].fields[&Field::Name].read(cx).text(),
                "日本語 draft"
            );
        })
    });
}

#[gpui::test]
fn per_tab_editors_survive_switches_without_revealing_saved_keys(cx: &mut TestAppContext) {
    let mut p = ready();
    p.tabs.push(ConnectionTab {
        id: "two".into(),
        label: "Second".into(),
        saved: true,
        dirty: false,
    });
    let (window, root, _) = fixture(cx, p.clone());
    let original =
        cx.read(|cx| root.read(cx).panel.read(cx).editors["one"].secrets[&Field::Key].entity_id());
    p.revision = 2;
    p.active.as_mut().unwrap().id = "two".into();
    p.active.as_mut().unwrap().fields.name = "Second".into();
    root.update(cx, |host, cx| {
        host.panel
            .update(cx, |panel, cx| panel.set_presentation(p.clone(), cx))
    });
    cx.run_until_parked();
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                panel.ensure_editors(window, cx);
                assert_eq!(
                    panel.editors["two"].secrets[&Field::Key].read(cx).text(),
                    ""
                );
                p.revision = 3;
                p.active.as_mut().unwrap().id = "one".into();
                p.active.as_mut().unwrap().fields.name = "Restored coordinator draft".into();
                panel.set_presentation(p.clone(), cx);
                assert_eq!(
                    panel.editors["one"].secrets[&Field::Key].entity_id(),
                    original
                );
                assert_eq!(
                    panel.editors["one"].secrets[&Field::Key].read(cx).text(),
                    ""
                );
                assert_eq!(
                    panel.editors["one"].fields[&Field::Name].read(cx).text(),
                    "Restored coordinator draft"
                );
            })
        })
        .unwrap();
}

#[gpui::test]
fn stale_duplicate_and_prior_opening_callbacks_are_fenced(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let old = panel.token();
                panel.dispatch(old, ConnectionSettingsIntent::New, cx);
                panel.dispatch(old, ConnectionSettingsIntent::New, cx);
                let mut p = ready();
                p.revision = 2;
                panel.set_presentation(p, cx);
                panel.dispatch(old, ConnectionSettingsIntent::SaveAll, cx);
                let before_close = panel.token();
                panel.close(true, window, cx);
                panel.show(window, cx);
                panel.dispatch(before_close, ConnectionSettingsIntent::SaveAll, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        events
            .borrow()
            .iter()
            .filter(|event| matches!(event, ConnectionSettingsEvent::Intent { .. }))
            .count(),
        1
    );
    assert_eq!(
        events
            .borrow()
            .iter()
            .filter(|event| matches!(event, ConnectionSettingsEvent::Dismissed { .. }))
            .count(),
        1
    );
}

#[gpui::test]
fn escape_requests_close_once_and_owner_controls_actual_dismissal(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                assert!(panel.key(&key("escape", Modifiers::none()), window, cx));
                assert!(panel.is_open());
                assert!(panel.key(&key("escape", Modifiers::none()), window, cx));
                let mut p = ready();
                p.revision = 2;
                p.dirty = true;
                p.confirmation = ConnectionConfirmation::Close;
                panel.set_presentation(p, cx);
                panel.key(&key("escape", Modifiers::none()), window, cx);
                assert!(panel.is_open());
            })
        })
        .unwrap();
    cx.run_until_parked();
    let intents: Vec<_> = events
        .borrow()
        .iter()
        .filter_map(|event| match event {
            ConnectionSettingsEvent::Intent { intent, .. } => Some(intent.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        intents,
        vec![
            ConnectionSettingsIntent::RequestClose,
            ConnectionSettingsIntent::KeepEditing
        ]
    );
}

#[gpui::test]
fn close_preserves_draft_and_does_not_steal_newer_focus(cx: &mut TestAppContext) {
    let mut p = ready();
    p.dirty = true;
    p.active.as_mut().unwrap().fields.name = "Unsaved".into();
    let (window, _, events) = fixture(cx, p.clone());
    window
        .update(cx, |host, window, cx| {
            host.newer.focus(window);
            host.panel.update(cx, |panel, cx| {
                panel.show(window, cx);
                panel.close(true, window, cx);
                panel.close(true, window, cx);
                assert_eq!(panel.presentation, p);
            });
            assert!(host.newer.is_focused(window));
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ConnectionSettingsEvent::Dismissed { revision: 1 }]
    );
}

#[gpui::test]
fn composing_field_fences_keyboard_click_and_save_intents(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |editor, cx| {
                    editor.focus(window);
                    editor.replace_and_mark_text_in_range(None, "未確定", None, window, cx);
                });
                assert!(panel.composing(cx));
                panel.request_close(cx);
                assert!(!panel.key(&key("escape", Modifiers::none()), window, cx));
                assert!(!panel.key(&key("tab", Modifiers::none()), window, cx));
                panel.dispatch(panel.token(), ConnectionSettingsIntent::SaveAll, cx);
                panel.dispatch(panel.token(), ConnectionSettingsIntent::New, cx);
                assert!(panel.is_open());
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert!(events.borrow().is_empty());
}

#[gpui::test]
fn keyboard_tab_moves_between_controls_without_inserting_editor_spaces(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.read(cx).focus(window);
                assert!(panel.key(&key("tab", Modifiers::none()), window, cx));
                let url = &panel.editors["one"].fields[&Field::BaseUrl];
                assert!(url.read(cx).focus_handle(cx).is_focused(window));
                assert_eq!(editor.read(cx).text(), "Fixture router");
                panel.key(
                    &key(
                        "tab",
                        Modifiers {
                            shift: true,
                            ..Modifiers::none()
                        },
                    ),
                    window,
                    cx,
                );
                assert!(editor.read(cx).focus_handle(cx).is_focused(window));
                let field = panel
                    .controls
                    .iter()
                    .find(|control| control.control == Control::Field(Field::Name))
                    .unwrap();
                assert!(field.focus.is_focused(window));
            })
        })
        .unwrap();
}

#[gpui::test]
fn busy_presentation_freezes_editor_and_old_snapshot_cannot_unlock_it(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let mut p = ready();
                p.revision = 2;
                p.saving = true;
                p.availability = ConnectionSettingsAvailability::Busy("Saving all tabs…".into());
                panel.set_presentation(p.clone(), cx);
                panel.set_presentation(ready(), cx);
                assert_eq!(panel.presentation, p);
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |editor, cx| {
                    editor.replace_text_in_range(None, "lost typing", window, cx)
                });
                assert_eq!(editor.read(cx).text(), "Fixture router");
                panel.key(&key("escape", Modifiers::none()), window, cx);
                panel.dispatch(panel.token(), ConnectionSettingsIntent::Reload, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert!(events.borrow().is_empty());
}

#[gpui::test]
fn click_save_is_deduplicated_and_confirmation_choices_remain_visible(cx: &mut TestAppContext) {
    let (window, root, events) = fixture(cx, ready());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let target = visual
        .debug_bounds("settings-save")
        .expect("Save All")
        .center();
    visual.simulate_click(target, Modifiers::none());
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        events
            .borrow()
            .iter()
            .filter(|event| matches!(
                event,
                ConnectionSettingsEvent::Intent {
                    intent: ConnectionSettingsIntent::SaveAll,
                    ..
                }
            ))
            .count(),
        1
    );
    for (index, confirmation) in [
        ConnectionConfirmation::Close,
        ConnectionConfirmation::Reload,
        ConnectionConfirmation::Delete {
            summary: "Its fake key is removed. Earlier chats keep their history.".into(),
        },
    ]
    .into_iter()
    .enumerate()
    {
        root.update(cx, |host, cx| {
            host.panel.update(cx, |panel, cx| {
                let mut p = ready();
                p.revision = index as u64 + 2;
                p.dirty = true;
                p.confirmation = confirmation;
                p.notice = Some(ConnectionSettingsNotice {
                    text: "Drafts remain available.".into(),
                    is_error: false,
                });
                panel.set_presentation(p, cx);
                panel.set_palette(Palette::for_appearance(WindowAppearance::Dark), cx);
            })
        });
        cx.run_until_parked();
        assert!(visual.debug_bounds("settings-status").is_some());
        assert!(visual.debug_bounds("settings-unsaved").is_some());
        match index {
            0 => assert!(visual.debug_bounds("settings-save-close").is_some()),
            1 => assert!(visual.debug_bounds("settings-discard-reload").is_some()),
            _ => assert!(
                visual
                    .debug_bounds("settings-confirm-delete-connection")
                    .is_some()
            ),
        }
    }
}

#[gpui::test]
fn status_revision_preserves_unacknowledged_composition_and_tab_switch_rehomes_focus(
    cx: &mut TestAppContext,
) {
    let mut p = ready();
    p.tabs.push(ConnectionTab {
        id: "two".into(),
        label: "Second".into(),
        saved: true,
        dirty: false,
    });
    let (window, _, _) = fixture(cx, p.clone());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |editor, cx| {
                    editor.focus(window);
                    editor.replace_and_mark_text_in_range(None, "未確定", None, window, cx);
                });
                let composed = editor.read(cx).text().to_owned();
                p.revision = 2;
                p.notice = Some(ConnectionSettingsNotice {
                    text: "Status only".into(),
                    is_error: false,
                });
                panel.set_presentation(p.clone(), cx);
                assert_eq!(editor.read(cx).text(), composed);
                assert!(editor.read(cx).has_marked_text());
                editor.update(cx, |editor, cx| editor.unmark_text(window, cx));
                p.revision = 3;
                p.active.as_mut().unwrap().id = "two".into();
                p.active.as_mut().unwrap().fields.name = "Second".into();
                panel.set_presentation(p.clone(), cx);
                panel.ensure_editors(window, cx);
                panel.sync_controls(window, cx);
                assert!(panel.focus.is_focused(window));
                assert!(!editor.read(cx).focus_handle(cx).is_focused(window));
            })
        })
        .unwrap();
}

#[gpui::test]
fn save_events_without_opening_tokens_cannot_act_after_reopen(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |_, cx| {
                    cx.emit(bello_workbench_ui::EditorEvent::SaveRequested)
                });
                panel.close(true, window, cx);
                panel.show(window, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert!(
        !events
            .borrow()
            .iter()
            .any(|event| matches!(event, ConnectionSettingsEvent::Intent { .. }))
    );
}

#[gpui::test]
fn delayed_edit_acknowledgment_does_not_replace_newer_local_typing(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                let editor = panel.editors["one"].fields[&Field::Name].clone();
                editor.update(cx, |editor, cx| editor.set_text("First edit".into(), cx));
                panel.edited(cx);
                editor.update(cx, |editor, cx| editor.set_text("Newer edit".into(), cx));
                let mut acknowledgment = ready();
                acknowledgment.revision = 2;
                acknowledgment.active.as_mut().unwrap().fields.name = "First edit".into();
                panel.set_presentation(acknowledgment, cx);
                assert_eq!(editor.read(cx).text(), "Newer edit");
                assert_eq!(panel.captured_fields(cx).unwrap().name, "Newer edit");
            })
        })
        .unwrap();
}

#[gpui::test]
fn history_only_api_shows_conversion_unavailable_without_an_action(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.active.as_mut().unwrap().fields.api = "anthropic-messages".into();
    let (window, _, events) = fixture(cx, presentation);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-history-only-api").is_some());
    assert!(visual.debug_bounds("settings-use-responses").is_none());
    assert!(events.borrow().is_empty());
}

#[gpui::test]
fn key_and_header_inputs_are_secure_and_final_action_captures_exact_replacements(
    cx: &mut TestAppContext,
) {
    let (window, _, events) = fixture(cx, ready());
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                let editors = &panel.editors["one"];
                assert!(!editors.fields.contains_key(&Field::Key));
                assert!(!editors.fields.contains_key(&Field::Headers));
                let key = editors.secrets[&Field::Key].clone();
                let headers = editors.secrets[&Field::Headers].clone();
                key.update(cx, |input, cx| {
                    input.set_text("synthetic-project-fixture-only".into(), cx);
                });
                headers.update(cx, |input, cx| {
                    input.set_text("{\"X-Fake\":\"synthetic-header-fixture-only\"}".into(), cx);
                });
                panel.dispatch(panel.token(), ConnectionSettingsIntent::SaveAll, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    let collected = events.borrow();
    let fields = collected
        .iter()
        .find_map(|event| match event {
            ConnectionSettingsEvent::Intent {
                fields,
                intent: ConnectionSettingsIntent::SaveAll,
                ..
            } => fields.as_deref(),
            _ => None,
        })
        .unwrap();
    assert_eq!(fields.key, "synthetic-project-fixture-only");
    assert_eq!(
        fields.headers,
        "{\"X-Fake\":\"synthetic-header-fixture-only\"}"
    );
    assert!(!format!("{collected:?}").contains("synthetic-project-fixture-only"));
    assert!(!format!("{collected:?}").contains("synthetic-header-fixture-only"));
}

#[gpui::test]
fn secure_composition_blocks_save_close_and_tab_until_platform_commit(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    for field in [Field::Key, Field::Headers] {
        window
            .update(cx, |host, window, cx| {
                host.panel.update(cx, |panel, cx| {
                    let input = panel.editors["one"].secrets[&field].clone();
                    input.update(cx, |input, cx| {
                        input.replace_and_mark_text_in_range(
                            None,
                            "fake-日",
                            Some(5..6),
                            window,
                            cx,
                        )
                    });
                    assert!(panel.composing(cx));
                    panel.dispatch(panel.token(), ConnectionSettingsIntent::SaveAll, cx);
                    panel.request_close(cx);
                    panel.dispatch(panel.token(), ConnectionSettingsIntent::New, cx);
                    assert!(panel.pending_revision.is_none());
                    input.update(cx, |input, cx| {
                        input.replace_text_in_range(None, "fake-確定", window, cx)
                    });
                    assert!(!panel.composing(cx));
                    assert_eq!(
                        field.value(&panel.captured_fields(cx).unwrap()),
                        "fake-確定"
                    );
                });
            })
            .unwrap();
    }
    cx.run_until_parked();
    assert!(events.borrow().iter().all(|event| matches!(
        event,
        ConnectionSettingsEvent::Intent {
            intent: ConnectionSettingsIntent::Edited,
            ..
        }
    )));
}

#[gpui::test]
fn secure_delayed_ack_and_busy_state_preserve_newer_input(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let input = panel.editors["one"].secrets[&Field::Key].clone();
                input.update(cx, |input, cx| {
                    input.set_text("fake-first".into(), cx);
                });
                panel.edited(cx);
                input.update(cx, |input, cx| {
                    input.set_text("fake-newer".into(), cx);
                });
                let mut acknowledgment = ready();
                acknowledgment.revision = 2;
                acknowledgment.active.as_mut().unwrap().fields.key = "fake-first".into();
                panel.set_presentation(acknowledgment.clone(), cx);
                assert_eq!(input.read(cx).text(), "fake-newer");
                acknowledgment.revision = 3;
                acknowledgment.saving = true;
                acknowledgment.availability = ConnectionSettingsAvailability::Busy("Saving".into());
                panel.set_presentation(acknowledgment, cx);
                input.update(cx, |input, cx| {
                    input.replace_text_in_range(None, "should-not-insert", window, cx)
                });
                assert_eq!(panel.captured_fields(cx).unwrap().key, "fake-newer");
            });
        })
        .unwrap();
}

#[gpui::test]
fn oversized_paste_retains_input_and_presents_content_free_error(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let input = panel.editors["one"].secrets[&Field::Key].clone();
                input.update(cx, |input, cx| {
                    input.set_text("fake-retained".into(), cx);
                    input.replace_text_in_range(
                        None,
                        &"x".repeat(super::secure_input::KEY_BYTES),
                        window,
                        cx,
                    );
                });
                assert_eq!(panel.captured_fields(cx).unwrap().key, "fake-retained");
            });
        })
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-api-key-rejection").is_some());
}

#[gpui::test]
fn out_of_contract_presentation_is_not_silently_captured_as_deletion(cx: &mut TestAppContext) {
    let mut p = ready();
    p.active.as_mut().unwrap().fields.key = "x".repeat(super::secure_input::KEY_BYTES + 1);
    let (window, _, events) = fixture(cx, p);
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                assert_eq!(
                    panel.captured_fields(cx).unwrap().key.len(),
                    super::secure_input::KEY_BYTES + 1
                );
                panel.edited(cx);
                let input = panel.editors["one"].secrets[&Field::Key].clone();
                input.update(cx, |input, cx| {
                    input.replace_text_in_range(None, "fake-correction", window, cx)
                });
                assert_eq!(panel.captured_fields(cx).unwrap().key, "fake-correction");
            });
        })
        .unwrap();
    cx.run_until_parked();
    assert!(events.borrow().iter().all(|event| match event {
        ConnectionSettingsEvent::Intent {
            fields: Some(fields),
            ..
        } => fields.key == "fake-correction",
        _ => false,
    }));
}

#[gpui::test]
fn delayed_secure_ack_does_not_replace_composition_that_matches_old_baseline(
    cx: &mut TestAppContext,
) {
    let mut p = ready();
    p.active.as_mut().unwrap().fields.key = "fake-base".into();
    let (window, _, _) = fixture(cx, p.clone());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let input = panel.editors["one"].secrets[&Field::Key].clone();
                input.update(cx, |input, cx| {
                    input.set_text("fake-first".into(), cx);
                });
                panel.edited(cx);
                input.update(cx, |input, cx| {
                    input.replace_and_mark_text_in_range(Some(0..10), "fake-base", None, window, cx)
                });
                p.revision = 2;
                p.active.as_mut().unwrap().fields.key = "fake-first".into();
                panel.set_presentation(p.clone(), cx);
                assert_eq!(input.read(cx).text(), "fake-base");
                assert!(input.read(cx).has_marked_text());
            });
        })
        .unwrap();
}

#[gpui::test]
fn tab_traversal_uses_secure_entity_focus_without_changing_replacements(cx: &mut TestAppContext) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let key_input = panel.editors["one"].secrets[&Field::Key].clone();
                let headers = panel.editors["one"].secrets[&Field::Headers].clone();
                key_input.update(cx, |input, cx| {
                    input.set_text("fake-key".into(), cx);
                });
                key_input.read(cx).focus_handle(cx).focus(window);
                assert!(panel.key(&key("tab", Modifiers::none()), window, cx));
                assert!(headers.read(cx).focus_handle(cx).is_focused(window));
                assert!(panel.key(
                    &key(
                        "tab",
                        Modifiers {
                            shift: true,
                            ..Modifiers::none()
                        }
                    ),
                    window,
                    cx
                ));
                assert!(key_input.read(cx).focus_handle(cx).is_focused(window));
                assert_eq!(panel.captured_fields(cx).unwrap().key, "fake-key");
                assert!(panel.captured_fields(cx).unwrap().headers.is_empty());
            });
        })
        .unwrap();
}

#[test]
fn catalog_controls_reject_old_generation_and_refresh_while_loading() {
    let mut p = ready();
    let rows = bello_agent_core::model_catalog::bundled().unwrap();
    let id = rows[0].id.clone();
    let generation = uuid::Uuid::new_v4();
    let catalog = &mut p.active.as_mut().unwrap().catalog;
    catalog.opened = true;
    catalog.generation = generation;
    catalog.models = rows;
    catalog.pages = 1;
    assert!(p.allows(&ConnectionSettingsIntent::ChooseCatalog {
        id: id.clone(),
        generation
    }));
    assert!(!p.allows(&ConnectionSettingsIntent::ChooseCatalog {
        id: id.clone(),
        generation: uuid::Uuid::new_v4()
    }));
    p.active.as_mut().unwrap().catalog.loading = true;
    assert!(!p.allows(&ConnectionSettingsIntent::RefreshCatalog));
    assert!(p.allows(&ConnectionSettingsIntent::CloseCatalog));
    // Previous same-source rows remain explicitly selectable during refresh.
    assert!(p.allows(&ConnectionSettingsIntent::ChooseCatalog { id, generation }));
    p.mode = crate::launch_authority::AuthorityMode::Unavailable;
    for intent in [
        ConnectionSettingsIntent::BrowseCatalog,
        ConnectionSettingsIntent::RefreshCatalog,
        ConnectionSettingsIntent::CloseCatalog,
    ] {
        assert!(!p.allows(&intent));
    }
}

#[test]
fn catalog_query_values_are_redacted_in_form_event_and_presentation_debug() {
    let mut p = ready();
    p.active.as_mut().unwrap().fields.catalog_url =
        "http://127.0.0.1:8/catalog?token=private-query-fixture".into();
    let text = format!("{p:?}");
    assert!(!text.contains("private-query-fixture"));
    assert!(!text.contains("127.0.0.1"));
    let event = ConnectionSettingsEvent::Intent {
        revision: p.revision,
        active_id: Some("one".into()),
        fields: p.active.map(|f| Box::new(f.fields)),
        intent: ConnectionSettingsIntent::RefreshCatalog,
    };
    assert!(!format!("{event:?}").contains("private-query-fixture"));
}

#[gpui::test]
fn native_form_exposes_catalog_fields_and_actions_without_losing_manual_alias(
    cx: &mut TestAppContext,
) {
    let mut p = ready();
    p.mode = crate::launch_authority::AuthorityMode::Native;
    let model = bello_agent_core::model_catalog::bundled()
        .unwrap()
        .remove(0);
    let catalog = &mut p.active.as_mut().unwrap().catalog;
    catalog.opened = true;
    catalog.pages = 1;
    catalog.models = vec![model.clone()];
    let generation = catalog.generation;
    let (window, root, events) = fixture(cx, p);
    root.update(cx, |host, cx| {
        host.panel.update(cx, |panel, cx| {
            let controls = panel.current_controls();
            for field in [Field::CatalogUrl, Field::CatalogSearch, Field::Model] {
                assert!(controls.contains(&Control::Field(field)));
                assert!(panel.control_enabled(&Control::Field(field)));
            }
            for intent in [
                ConnectionSettingsIntent::BrowseCatalog,
                ConnectionSettingsIntent::RefreshCatalog,
                ConnectionSettingsIntent::CloseCatalog,
                ConnectionSettingsIntent::ChooseCatalog {
                    id: model.id.clone(),
                    generation,
                },
            ] {
                assert!(panel.presentation.allows(&intent));
                assert!(controls.contains(&Control::Intent(intent)));
            }
            assert!(
                panel
                    .presentation
                    .allows(&ConnectionSettingsIntent::SaveAll)
            );
            panel.dispatch(panel.token(), ConnectionSettingsIntent::BrowseCatalog, cx);
        })
    });
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 1);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-catalog-url").is_some());
    cx.read(|cx| {
        let panel = root.read(cx).panel.read(cx);
        let browse = panel
            .controls
            .iter()
            .find(|control| {
                control.control == Control::Intent(ConnectionSettingsIntent::BrowseCatalog)
            })
            .unwrap();
        assert!(
            browse.bounds.get().is_some(),
            "the native catalog button was laid out"
        );
    });
}
