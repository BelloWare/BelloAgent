//! Fake-platform tests of the isolated view, never a native authority backend.
use super::*;
use gpui::{
    Entity, Keystroke, Modifiers, Subscription, TestAppContext, VisualTestContext,
    WindowAppearance, WindowHandle, size,
};
use std::{cell::RefCell, rc::Rc};

fn ready() -> ProjectManagerPresentation {
    ProjectManagerPresentation {
        revision: 1,
        primary: PathBuf::from("/sample/primary"),
        project_id: Some("fixture-project".into()),
        trusted: true,
        extra_roots: vec![PathBuf::from("/sample/extra")],
        stage: ProjectManagerStage::Current,
        availability: ProjectManagerAvailability::Ready,
        notice: None,
        synthetic: true,
    }
}

#[test]
fn current_and_draft_actions_never_target_the_primary_or_each_other() {
    let mut presentation = ready();
    let remove = |target, path: &str| ProjectManagerIntent::RemoveAdditionalFolder {
        target,
        path: path.into(),
    };
    assert!(!presentation.allows(&remove(ProjectFolderTarget::Current, "/sample/primary")));
    assert!(!presentation.allows(&remove(ProjectFolderTarget::Current, "/sample/missing")));
    assert!(!presentation.allows(&remove(ProjectFolderTarget::Draft, "/sample/extra")));
    assert!(presentation.allows(&remove(ProjectFolderTarget::Current, "/sample/extra")));
    assert!(!presentation.allows(&ProjectManagerIntent::ConfirmTrust));
    presentation.stage = ProjectManagerStage::TrustDraft {
        kind: ProjectTrustKind::Retrust,
        extras: vec!["/sample/draft".into()],
    };
    assert_eq!(
        presentation.displayed_extras(),
        &[PathBuf::from("/sample/draft")]
    );
    assert!(!presentation.allows(&remove(ProjectFolderTarget::Current, "/sample/extra")));
    assert!(!presentation.allows(&remove(ProjectFolderTarget::Draft, "/sample/extra")));
    assert!(presentation.allows(&remove(ProjectFolderTarget::Draft, "/sample/draft")));
    assert!(presentation.allows(&ProjectManagerIntent::ConfirmTrust));
}

#[test]
fn folder_limit_and_confirmed_trust_control_current_mutations() {
    let mut presentation = ready();
    let add = ProjectManagerIntent::ChooseAdditionalFolders(ProjectFolderTarget::Current);
    assert!(presentation.allows(&add));
    presentation.extra_roots = (0..15)
        .map(|index| PathBuf::from(format!("/sample/extra-{index}")))
        .collect();
    assert!(!presentation.allows(&add));
    presentation.extra_roots.clear();
    presentation.trusted = false;
    assert!(!presentation.allows(&add));
    assert!(presentation.allows(&ProjectManagerIntent::BeginRetrust));
    presentation.project_id = None;
    presentation.trusted = true;
    assert!(
        !presentation.allows(&add),
        "a flag without a saved project is not trust"
    );
    assert!(presentation.allows(&ProjectManagerIntent::BeginCreate));
    assert!(!presentation.allows(&ProjectManagerIntent::BeginRetrust));
}

#[test]
fn unavailable_loading_busy_failed_and_unconfirmed_never_grant_mutations() {
    for availability in [
        ProjectManagerAvailability::Loading,
        ProjectManagerAvailability::Unavailable("Native project authority is unavailable.".into()),
        ProjectManagerAvailability::Busy(
            "Stop this project's work before changing folders.".into(),
        ),
        ProjectManagerAvailability::Failed("Load failed.".into()),
        ProjectManagerAvailability::Unconfirmed(
            "The write may have saved. Reload to review.".into(),
        ),
    ] {
        let mut presentation = ready();
        presentation.stage = ProjectManagerStage::TrustDraft {
            kind: ProjectTrustKind::Retrust,
            extras: vec!["/sample/draft".into()],
        };
        presentation.availability = availability;
        for intent in [
            ProjectManagerIntent::ConfirmTrust,
            ProjectManagerIntent::ChooseAdditionalFolders(ProjectFolderTarget::Draft),
            ProjectManagerIntent::RemoveAdditionalFolder {
                target: ProjectFolderTarget::Draft,
                path: "/sample/draft".into(),
            },
        ] {
            assert!(!presentation.allows(&intent));
        }
        assert_eq!(
            presentation.displayed_extras(),
            &[PathBuf::from("/sample/draft")]
        );
        assert!(presentation.status().is_some());
    }
}

struct TestHost {
    panel: Entity<ProjectManagerView>,
    outside: FocusHandle,
    newer: FocusHandle,
    events: Rc<RefCell<Vec<ProjectManagerEvent>>>,
    _subscription: Subscription,
}

impl Render for TestHost {
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

fn fixture(
    cx: &mut TestAppContext,
    presentation: ProjectManagerPresentation,
) -> (
    WindowHandle<TestHost>,
    Entity<TestHost>,
    Rc<RefCell<Vec<ProjectManagerEvent>>>,
) {
    let events = Rc::new(RefCell::new(Vec::new()));
    let observed = events.clone();
    let window = cx.add_window(|_, cx| {
        let panel = cx.new(|cx| {
            ProjectManagerView::new(
                presentation,
                Palette::for_appearance(WindowAppearance::Light),
                cx,
            )
        });
        let subscription = cx.subscribe(&panel, |host: &mut TestHost, _, event, cx| {
            host.events.borrow_mut().push(event.clone());
            cx.notify();
        });
        TestHost {
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
    visual.simulate_resize(size(px(720.), px(520.)));
    cx.run_until_parked();
    (window, root, events)
}

#[gpui::test]
fn repeated_clicks_and_stale_callbacks_emit_only_the_current_intent(cx: &mut TestAppContext) {
    let (window, root, events) = fixture(cx, ready());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let target = visual
        .debug_bounds("project-remove-extra-0")
        .unwrap()
        .center();
    visual.simulate_click(target, Modifiers::none());
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Intent {
            revision: 1,
            intent: ProjectManagerIntent::RemoveAdditionalFolder {
                target: ProjectFolderTarget::Current,
                path: "/sample/extra".into()
            }
        }]
    );
    root.update(cx, |host, cx| {
        host.panel.update(cx, |panel, cx| {
            let mut newer = ready();
            newer.revision = 2;
            panel.set_presentation(newer, cx);
            panel.dispatch(1, ProjectManagerIntent::BeginRetrust, cx);
            panel.dispatch(2, ProjectManagerIntent::BeginRetrust, cx);
            panel.dispatch(2, ProjectManagerIntent::BeginRetrust, cx);
        });
    });
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 2);
    assert_eq!(
        events.borrow()[1],
        ProjectManagerEvent::Intent {
            revision: 2,
            intent: ProjectManagerIntent::BeginRetrust
        }
    );
}

#[gpui::test]
fn closing_repeatedly_preserves_the_draft_and_rejects_delayed_clicks(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.stage = ProjectManagerStage::TrustDraft {
        kind: ProjectTrustKind::Retrust,
        extras: vec!["/sample/draft".into()],
    };
    let (window, _, events) = fixture(cx, presentation.clone());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                panel.show(window, cx);
                panel.close(true, window, cx);
                panel.close(true, window, cx);
                panel.dispatch(1, ProjectManagerIntent::ConfirmTrust, cx);
                assert_eq!(panel.presentation, presentation);
            });
            assert!(
                host.outside.is_focused(window),
                "repeated show must not overwrite the original focus"
            );
            host.panel.update(cx, |panel, cx| {
                panel.show(window, cx);
                assert_eq!(panel.presentation, presentation);
            });
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Dismissed { revision: 1 }]
    );
}

#[gpui::test]
fn close_does_not_steal_newer_focus_and_old_snapshots_do_not_replace_drafts(
    cx: &mut TestAppContext,
) {
    let (window, _, _) = fixture(cx, ready());
    window
        .update(cx, |host, window, cx| {
            host.newer.focus(window);
            host.panel.update(cx, |panel, cx| {
                let mut draft = ready();
                draft.revision = 2;
                draft.stage = ProjectManagerStage::TrustDraft {
                    kind: ProjectTrustKind::Create,
                    extras: vec!["/sample/draft".into()],
                };
                panel.set_presentation(draft.clone(), cx);
                panel.set_presentation(ready(), cx);
                assert_eq!(panel.presentation, draft);
                panel.close(true, window, cx);
            });
            assert!(host.newer.is_focused(window));
        })
        .unwrap();
}

#[gpui::test]
fn unconfirmed_sheet_keeps_close_reload_and_visible_draft(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.stage = ProjectManagerStage::TrustDraft {
        kind: ProjectTrustKind::Retrust,
        extras: vec!["/sample/draft".into()],
    };
    presentation.availability = ProjectManagerAvailability::Unconfirmed("The native write was not confirmed. Your draft remains available; do not assume it was saved.".into());
    let (window, root, events) = fixture(cx, presentation.clone());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for appearance in [WindowAppearance::Light, WindowAppearance::Dark] {
        root.update(cx, |host, cx| {
            host.panel.update(cx, |panel, cx| {
                panel.set_palette(Palette::for_appearance(appearance), cx)
            })
        });
        for (width, height) in [(720., 520.), (560., 440.)] {
            visual.simulate_resize(size(px(width), px(height)));
            cx.run_until_parked();
            let panel = visual.debug_bounds("project-manager-panel").unwrap();
            let done = visual.debug_bounds("project-manager-done").unwrap();
            let status = visual.debug_bounds("project-manager-status").unwrap();
            let body = visual.debug_bounds("project-manager-body").unwrap();
            assert!(panel.contains(&done.center()));
            assert!(status.bottom() <= panel.bottom());
            assert!(body.bottom() <= done.bottom());
        }
    }
    root.update(cx, |host, cx| {
        host.panel.update(cx, |panel, cx| {
            panel.dispatch(1, ProjectManagerIntent::ConfirmTrust, cx);
            panel.dispatch(
                1,
                ProjectManagerIntent::ChooseAdditionalFolders(ProjectFolderTarget::Draft),
                cx,
            );
            assert_eq!(panel.presentation, presentation);
        })
    });
    cx.run_until_parked();
    assert!(events.borrow().is_empty());
    let reload = visual.debug_bounds("project-reload").unwrap().center();
    visual.simulate_click(reload, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Intent {
            revision: 1,
            intent: ProjectManagerIntent::Reload
        }]
    );
}

#[gpui::test]
fn escape_and_close_shortcut_dismiss_without_enter_confirming_trust(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.stage = ProjectManagerStage::TrustDraft {
        kind: ProjectTrustKind::Retrust,
        extras: vec!["/sample/draft".into()],
    };
    let (window, root, events) = fixture(cx, presentation.clone());
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    assert!(
        events.borrow().is_empty(),
        "trust requires its explicit action"
    );
    assert!(cx.read(|cx| root.read(cx).panel.read(cx).is_open()));
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Dismissed { revision: 1 }]
    );
    window
        .update(cx, |host, window, cx| {
            assert!(host.outside.is_focused(window));
            host.panel.update(cx, |panel, cx| {
                assert_eq!(panel.presentation, presentation);
                panel.show(window, cx);
            });
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "linux") {
            "ctrl-w"
        } else {
            "cmd-w"
        },
    );
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![
            ProjectManagerEvent::Dismissed { revision: 1 },
            ProjectManagerEvent::Dismissed { revision: 1 }
        ]
    );
}

fn focused_control(
    window: WindowHandle<TestHost>,
    cx: &mut TestAppContext,
) -> Option<ProjectControl> {
    window
        .update(cx, |host, window, cx| {
            host.panel
                .read(cx)
                .controls
                .iter()
                .find(|control| control.focus.is_focused(window))
                .map(|control| control.control.clone())
        })
        .unwrap()
}

#[gpui::test]
fn keyboard_traversal_requires_focused_trust_and_restores_descendant_focus(
    cx: &mut TestAppContext,
) {
    let mut presentation = ready();
    presentation.stage = ProjectManagerStage::TrustDraft {
        kind: ProjectTrustKind::Retrust,
        extras: vec!["/sample/draft".into()],
    };
    let (window, _, events) = fixture(cx, presentation.clone());
    cx.simulate_keystrokes(window.into(), "tab");
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(
            ProjectManagerIntent::RemoveAdditionalFolder {
                target: ProjectFolderTarget::Draft,
                path: "/sample/draft".into(),
            }
        ))
    );
    cx.simulate_keystrokes(window.into(), "tab");
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(
            ProjectManagerIntent::ChooseAdditionalFolders(ProjectFolderTarget::Draft)
        ))
    );
    cx.simulate_keystrokes(window.into(), "space");
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Intent {
            revision: 1,
            intent: ProjectManagerIntent::ChooseAdditionalFolders(ProjectFolderTarget::Draft)
        }]
    );
    assert_eq!(
        focused_control(window, cx),
        None,
        "consumed action returns focus to the sheet"
    );
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                presentation.revision = 2;
                panel.set_presentation(presentation.clone(), cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), "shift-tab");
    assert_eq!(focused_control(window, cx), Some(ProjectControl::Done));
    cx.simulate_keystrokes(window.into(), "shift-tab");
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(ProjectManagerIntent::Reload))
    );
    cx.simulate_keystrokes(window.into(), "shift-tab");
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(ProjectManagerIntent::ConfirmTrust))
    );
    window
        .update(cx, |host, window, cx| {
            assert!(host.panel.read(cx).owns_focus(window, cx))
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    assert_eq!(
        events.borrow()[1],
        ProjectManagerEvent::Intent {
            revision: 2,
            intent: ProjectManagerIntent::ConfirmTrust
        }
    );
    cx.simulate_keystrokes(window.into(), "tab");
    assert_eq!(focused_control(window, cx), Some(ProjectControl::Done));
    cx.simulate_keystrokes(window.into(), "space");
    cx.run_until_parked();
    assert_eq!(
        events.borrow()[2],
        ProjectManagerEvent::Dismissed { revision: 2 }
    );
    window
        .update(cx, |host, window, _| {
            assert!(host.outside.is_focused(window))
        })
        .unwrap();
}

#[gpui::test]
fn keyboard_skips_disabled_actions_and_keeps_navigation_inside_sheet(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.availability =
        ProjectManagerAvailability::Unavailable("Native project authority is unavailable.".into());
    let (window, _, events) = fixture(cx, presentation);
    for expected in [
        ProjectControl::Intent(ProjectManagerIntent::Reload),
        ProjectControl::Done,
        ProjectControl::Intent(ProjectManagerIntent::Reload),
    ] {
        cx.simulate_keystrokes(window.into(), "tab");
        assert_eq!(focused_control(window, cx), Some(expected));
    }
    cx.simulate_keystrokes(window.into(), "shift-tab");
    assert_eq!(focused_control(window, cx), Some(ProjectControl::Done));
    assert!(events.borrow().is_empty());
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    assert_eq!(
        *events.borrow(),
        vec![ProjectManagerEvent::Dismissed { revision: 1 }]
    );
}

#[gpui::test]
fn held_repeat_and_stale_focused_activation_cannot_repeat_or_bypass_disable(
    cx: &mut TestAppContext,
) {
    let (window, _, events) = fixture(cx, ready());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    cx.simulate_keystrokes(window.into(), "tab");
    visual.simulate_event(KeyDownEvent {
        keystroke: Keystroke::parse("enter").unwrap(),
        is_held: true,
    });
    cx.run_until_parked();
    assert!(events.borrow().is_empty());
    cx.simulate_keystrokes(window.into(), "enter");
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 1);
    window
        .update(cx, |host, _, cx| {
            host.panel.update(cx, |panel, cx| {
                let mut ready = ready();
                ready.revision = 2;
                panel.set_presentation(ready, cx);
            })
        })
        .unwrap();
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), "tab");
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let mut busy = ready();
                busy.revision = 3;
                busy.availability =
                    ProjectManagerAvailability::Busy("Project work started.".into());
                panel.set_presentation(busy, cx);
                // The last rendered focused button belongs to revision 2. The event
                // arrives before a redraw and must not operate on the newer snapshot.
                assert!(panel.key(
                    &KeyDownEvent {
                        keystroke: Keystroke::parse("enter").unwrap(),
                        is_held: false
                    },
                    window,
                    cx
                ));
            })
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(events.borrow().len(), 1);
    assert_eq!(focused_control(window, cx), None);
    cx.simulate_keystrokes(window.into(), "tab");
    assert_eq!(focused_control(window, cx), Some(ProjectControl::Done));
}

#[gpui::test]
fn keyboard_reveals_scrolled_controls_and_skips_add_at_the_root_limit(cx: &mut TestAppContext) {
    let mut presentation = ready();
    presentation.extra_roots = (0..15)
        .map(|index| PathBuf::from(format!("/sample/extra-{index}")))
        .collect();
    let (window, _, _) = fixture(cx, presentation);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(560.), px(440.)));
    for _ in 0..15 {
        cx.simulate_keystrokes(window.into(), "tab");
    }
    cx.run_until_parked();
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(
            ProjectManagerIntent::RemoveAdditionalFolder {
                target: ProjectFolderTarget::Current,
                path: "/sample/extra-14".into(),
            }
        ))
    );
    let body = visual.debug_bounds("project-manager-body").unwrap();
    let remove = visual.debug_bounds("project-remove-extra-14").unwrap();
    assert!(
        body.contains(&remove.center()),
        "keyboard focus must reveal the extra-folder control: body={body:?}, remove={remove:?}, scroll={:?}",
        window
            .update(cx, |host, _, cx| host.panel.read(cx).body_scroll.offset())
            .unwrap()
    );
    cx.simulate_keystrokes(window.into(), "tab");
    cx.run_until_parked();
    assert_eq!(
        focused_control(window, cx),
        Some(ProjectControl::Intent(ProjectManagerIntent::BeginRetrust))
    );
    let review = visual.debug_bounds("project-review-trust").unwrap();
    assert!(
        body.contains(&review.center()),
        "keyboard focus must reveal trust review"
    );
}

#[gpui::test]
fn ready_revision_change_rejects_focused_activation_before_redraw(cx: &mut TestAppContext) {
    let (window, _, events) = fixture(cx, ready());
    cx.simulate_keystrokes(window.into(), "tab");
    assert!(focused_control(window, cx).is_some());
    window
        .update(cx, |host, window, cx| {
            host.panel.update(cx, |panel, cx| {
                let mut newer = ready();
                newer.revision = 2;
                panel.set_presentation(newer, cx);
                assert!(panel.key(
                    &KeyDownEvent {
                        keystroke: Keystroke::parse("enter").unwrap(),
                        is_held: false
                    },
                    window,
                    cx
                ));
            });
        })
        .unwrap();
    cx.run_until_parked();
    assert!(
        events.borrow().is_empty(),
        "availability stayed Ready; rendered revision must fence the stale key"
    );
}
