//! Synthetic Settings -> saved connection -> actual loopback dispatch. No native
//! authority, real credentials or paid provider is used.
use super::{ConnectionSettingsIntent as Intent, LaunchConnectionAuthority, new_form};
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Lane, SessionStore,
    project_authority::{
        AuthorityError, ProjectAuthority, connections::SYNTHETIC_KEY,
        synthetic::SyntheticAuthorityControl,
    },
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::{
    io::{Read, Write},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

fn fixture_with_trust(
    cx: &mut TestAppContext,
    trusted: bool,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    fixture_with_mode(cx, trusted, crate::launch_authority::AuthorityMode::Fixture)
}
fn fixture_with_mode(
    cx: &mut TestAppContext,
    trusted: bool,
    mode: crate::launch_authority::AuthorityMode,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    cx.update(|cx| cx.set_global(LaunchConnectionAuthority(control.clone())));
    cx.update(|cx| {
        cx.set_global(crate::project_manager_controller::LaunchProjectAuthority {
            authority: Arc::new(authority.clone()),
            mode,
        })
    });
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let record = ChatRecord::new(
        snapshot.id,
        "Connection fixture".into(),
        project.join("session.json"),
    );
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    if trusted {
        let baseline = authority.load().unwrap();
        let mut project_draft = baseline.edit();
        let trusted = project_draft
            .trust_project(&uuid::Uuid::new_v4().to_string(), &project, &[])
            .unwrap();
        let saved_project = authority.save(&mut project_draft).unwrap();
        workspace
            .bind_project_identity(
                authority
                    .confirm_project_binding(&saved_project, &trusted)
                    .unwrap(),
            )
            .unwrap();
    }
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(workspace)),
        project,
        record,
        draft: DraftRecord {
            skills: Vec::new(),
            attachments: Vec::new(),
            text: "keep composer 日本語".into(),
            ..Default::default()
        },
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.run_until_parked();
    (dir, control, window, root)
}
pub(super) fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    fixture_with_trust(cx, true)
}

pub(super) fn act(window: WindowHandle<AgentView>, intent: Intent, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            let revision = view.connections.presentation.revision;
            let id = view.connections.active.clone();
            let fields = id
                .as_ref()
                .and_then(|id| view.connections.forms.get(id))
                .map(|form| form.fields.clone());
            view.connection_intent(revision, id, fields, intent, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
}
pub(super) fn edit(
    root: &Entity<AgentView>,
    cx: &mut TestAppContext,
    f: impl FnOnce(&mut super::ConnectionFields),
) {
    root.update(cx, |view, cx| {
        let id = view.connections.active.clone().unwrap();
        f(&mut view.connections.forms.get_mut(&id).unwrap().fields);
        view.connections.publish(cx);
    });
}
pub(super) fn save_fixture(
    window: WindowHandle<AgentView>,
    root: &Entity<AgentView>,
    cx: &mut TestAppContext,
) -> String {
    edit(root, cx, |f| {
        f.name = "Fixture connection".into();
        f.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| {
        root.read(cx)
            .connections
            .loaded
            .as_ref()
            .unwrap()
            .profiles()[0]
            .profile
            .id
            .clone()
    })
}
pub(super) fn wait(cx: &mut TestAppContext, mut done: impl FnMut(&mut TestAppContext) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        cx.run_until_parked();
        if done(cx) {
            break;
        }
        assert!(Instant::now() < deadline, "bounded real-worker completion");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[gpui::test]
fn sidebar_routes_recover_after_certain_partial_save_and_retry(cx: &mut TestAppContext) {
    use bello_agent_core::sidebar_search::reconciliation::SourceRoute;
    let (_dir, _control, window, root) = fixture(cx);
    save_fixture(window, &root, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, _| {
        let id = view.record.id.clone();
        view.sidebar_search.installed(&id);
        view.sidebar_search.block("prior-retirement");
    });
    edit(&root, cx, |fields| {
        fields.name = "First saved tab".into();
        fields.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::New, cx);
    edit(&root, cx, |fields| {
        fields.name = "Second invalid tab".into();
        fields.key = SYNTHETIC_KEY.into();
        fields.context_window = "invalid-number".into();
    });
    act(window, Intent::SaveAll, cx);
    root.update(cx, |view, _| {
        assert_eq!(
            view.connections.loaded.as_ref().unwrap().profiles().len(),
            1
        );
        assert!(
            view.connections
                .presentation
                .notice
                .as_ref()
                .unwrap()
                .is_error
        );
        assert!(!view.connections.uncertain);
        assert_eq!(
            view.sidebar_search.test_route(&view.record.id),
            Some(SourceRoute::Loaded)
        );
        assert_eq!(
            view.sidebar_search.test_route("prior-retirement"),
            Some(SourceRoute::Blocked)
        );
    });
    edit(&root, cx, |fields| {
        fields.name = "Corrected second tab".into();
        fields.context_window = "128000".into();
    });
    act(window, Intent::SaveAll, cx);
    root.update(cx, |view, _| {
        assert_eq!(
            view.connections.loaded.as_ref().unwrap().profiles().len(),
            2
        );
        assert_eq!(
            view.sidebar_search.test_route(&view.record.id),
            Some(SourceRoute::Loaded)
        );
        assert_eq!(
            view.sidebar_search.test_route("prior-retirement"),
            Some(SourceRoute::Blocked)
        );
    });
}

#[test]
fn model_alias_change_clears_old_catalog_ceiling_and_invalid_numbers_retain_text() {
    let mut form = new_form(crate::launch_authority::AuthorityMode::Fixture);
    form.draft.profile.model_output_limit = Some(1000);
    form.fields.model = "another-alias".into();
    assert!(form.capture().unwrap().profile.model_output_limit.is_none());
    form.fields.context_window = "invalid partial number".into();
    assert!(form.capture().is_err());
    assert_eq!(form.fields.context_window, "invalid partial number");
}

fn native_mode_saved_fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    String,
) {
    let (dir, control, window, root) =
        fixture_with_mode(cx, true, crate::launch_authority::AuthorityMode::Native);
    edit(&root, cx, |fields| {
        fields.base_url = "http://127.0.0.1:9".into();
        fields.model = "native-mode-fixture".into();
    });
    let id = save_fixture(window, &root, cx);
    (dir, control, window, root, id)
}

#[gpui::test]
fn native_mode_form_does_not_relax_fixture_provenance_and_retains_failed_secrets(
    cx: &mut TestAppContext,
) {
    let (_dir, control, window, root) =
        fixture_with_mode(cx, true, crate::launch_authority::AuthorityMode::Native);
    cx.read(|cx| {
        let view = root.read(cx);
        let fields = &view
            .connections
            .presentation
            .active
            .as_ref()
            .unwrap()
            .fields;
        assert!(fields.base_url.is_empty() && fields.model.is_empty());
        assert!(fields.key.is_empty() && fields.headers.is_empty());
        assert_eq!(
            view.projects.presentation.mode,
            crate::launch_authority::AuthorityMode::Native
        );
    });
    let before = control.snapshot_bytes().unwrap();
    edit(&root, cx, |fields| {
        fields.base_url = "https://gateway.example.test".into();
        fields.model = "typed-model".into();
        fields.key = "not-a-real-key-and-not-the-fixture-key".into();
    });
    act(window, Intent::SaveAll, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.connections.presentation.dirty);
        let notice = view.connections.presentation.notice.as_ref().unwrap();
        assert!(notice.is_error);
        assert!(!notice.text.contains("not-a-real-key"));
        assert!(!view.controller.configured());
    });
    edit(&root, cx, |fields| {
        fields.base_url = "http://127.0.0.1:9".into();
        fields.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.connections.presentation.dirty);
        let form = view.connections.presentation.active.as_ref().unwrap();
        assert!(form.fields.key.is_empty() && form.fields.headers.is_empty());
        assert!(
            view.connections
                .presentation
                .notice
                .as_ref()
                .unwrap()
                .text
                .contains("separate Rust Keychain vault")
        );
    });
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |fields| {
        fields.name = "retained after conflict".into()
    });
    control.fail_next_write(AuthorityError::Conflict).unwrap();
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| assert!(root.read(cx).connections.presentation.dirty));
    control.fail_next_read(AuthorityError::Denied).unwrap();
    root.update(cx, |view, cx| view.reload_connections(false, cx));
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).connections.presentation.dirty));
    root.update(cx, |view, cx| view.reload_connections(false, cx));
    cx.run_until_parked();
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.connections.uncertain && view.connections.presentation.dirty);
        assert_eq!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .name,
            "retained after conflict"
        );
    });
    root.update(cx, |view, cx| view.reload_connections(false, cx));
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).connections.uncertain));
}

#[gpui::test]
fn native_mode_preflight_blocks_submission_but_denial_preserves_current_actor(
    cx: &mut TestAppContext,
) {
    let (_dir, control, _window, root, id) = native_mode_saved_fixture(cx);
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    let actor = cx.read(|cx| root.read(cx).controller.clone());
    let gate = control.pause_next_read().unwrap();
    control.fail_next_read(AuthorityError::Denied).unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        gate.release();
    });
    root.update(cx, |view, cx| {
        view.select_connection(&id, cx);
        assert!(view.connections.switches.contains_key(&view.record.id));
        assert!(view.actor_mutation_blocked(&view.record.id));
        assert!(!actor.is_retired());
        view.submit(Lane::FollowUp, cx);
        view.resume_queued(&view.record.id.clone(), cx);
        assert!(view.inflight_submission.is_none());
        assert!(view.composer.read(cx).text().contains("keep composer"));
    });
    cx.run_until_parked();
    observer.join().unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(Arc::ptr_eq(&view.controller, &actor));
        assert!(!actor.is_retired());
        assert!(!view.actor_mutation_blocked(&view.record.id));
        assert!(!view.record.snapshot.exists());
        assert!(view.session.messages.is_empty());
    });
}

/// The composer's picker is how a reader chooses a connection, by pointer or
/// keyboard. Native mode once refused every choice made in it because the
/// open picker itself counted as a blocking project action, leaving the
/// picker up and the chat unbound (seen in the signed app). The change is
/// told as Swift tells it: a footer notice naming the connection, no error.
#[gpui::test]
fn native_mode_choosing_in_the_picker_binds_the_connection(cx: &mut TestAppContext) {
    for keyboard in [false, true] {
        let (_dir, _control, window, root, id) = native_mode_saved_fixture(cx);
        window
            .update(cx, |view, window, cx| {
                view.open_connection_picker(window, cx);
                assert!(view.connections.picker);
                if keyboard {
                    let enter = gpui::KeyDownEvent {
                        keystroke: gpui::Keystroke::parse("enter").unwrap(),
                        is_held: false,
                    };
                    view.connection_picker_key(&enter, window, cx);
                } else {
                    view.select_connection(&id, cx);
                }
            })
            .unwrap();
        cx.run_until_parked();
        cx.read(|cx| {
            let view = root.read(cx);
            assert!(!view.connections.picker, "keyboard: {keyboard}");
            assert_eq!(
                view.record.connection_id.as_deref(),
                Some(id.as_str()),
                "keyboard: {keyboard}"
            );
            let name = view.connections.name_of(&id).unwrap();
            assert!(!name.is_empty() && name != id, "{name}");
            assert_eq!(view.notice, Some(format!("Next turn uses {name}.")));
            assert_eq!(view.error, None);
            assert_eq!(view.connection_label(), name);
        });
        let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
        visual.run_until_parked();
        assert!(visual.debug_bounds("footer-notice").is_some());
        // However long, the notice is cut to the room the footer row leaves
        // rather than wrapping it: the composer above never moves.
        visual.simulate_resize(gpui::size(gpui::px(1000.), gpui::px(800.)));
        visual.run_until_parked();
        let footer = visual.debug_bounds("queue-measured-footer").unwrap();
        root.update(cx, |view, cx| {
            view.notice = Some("A notice far too long for the footer's room. ".repeat(20));
            cx.notify();
        });
        visual.run_until_parked();
        assert_eq!(
            visual.debug_bounds("queue-measured-footer").unwrap(),
            footer
        );
        root.update(cx, |view, cx| {
            view.notice = None;
            cx.notify();
        });
        visual.run_until_parked();
        assert_eq!(
            visual.debug_bounds("queue-measured-footer").unwrap(),
            footer
        );
    }
}

#[gpui::test]
fn native_mode_later_route_selection_discards_pending_new_chat(cx: &mut TestAppContext) {
    let (_dir, _control, window, root, id) = native_mode_saved_fixture(cx);
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    let original = cx.read(|cx| root.read(cx).record.id.clone());
    let count = cx.read(|cx| root.read(cx).records.len());
    window
        .update(cx, |view, window, cx| {
            view.new_chat(window, cx);
            view.select_connection(&id, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, original);
        assert_eq!(view.records.len(), count);
        assert!(view.controller.configured());
        assert!(view.controller.has_available_tool_definitions());
    });
}

/// A native saved chat offers its trusted project's tools, MCP and skills as
/// Swift's does, through New Chat and after the startup loader restores it.
#[gpui::test]
fn native_mode_new_chat_and_startup_loader_keep_saved_connection_with_its_tools(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root, id) = native_mode_saved_fixture(cx);
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    let original = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    let launch = root.update(cx, |view, _| {
        assert_ne!(view.record.id, original);
        assert!(view.controller.configured());
        assert!(view.controller.has_available_tool_definitions());
        view.workspace
            .lock()
            .unwrap()
            .register(view.record.clone(), DraftRecord::default())
            .unwrap();
        LaunchState {
            controller: crate::saved_runtime_adapter::AppRuntime::placeholder(&view.record)
                .unwrap(),
            project: view.project.clone(),
            workspace: view.workspace.clone(),
            record: view.record.clone(),
            draft: DraftRecord::default(),
            pending: false,
        }
    });
    let restored = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    cx.run_until_parked();
    restored
        .update(cx, |view, window, cx| {
            assert!(view.controller.configured());
            assert!(!view.loading && !view.load_failed);
            assert_eq!(view.record.connection_id.as_deref(), Some(id.as_str()));
            assert!(view.controller.has_available_tool_definitions());
            assert!(view.runtime.mcp_manager().is_ok());
            assert!(!view.record.snapshot.exists());
            assert!(view.can_choose_skills());
            view.open_skill_picker(window, cx);
            assert!(view.skill_picker.is_some());
        })
        .unwrap();
}

#[gpui::test]
fn settings_save_select_and_real_composer_send_use_selected_fixture(cx: &mut TestAppContext) {
    exercise_settings_send(cx, crate::launch_authority::AuthorityMode::Fixture);
}

#[gpui::test]
fn native_mode_settings_send_uses_same_factory_with_tools_and_project_resources(
    cx: &mut TestAppContext,
) {
    // Storage is still the synthetic fake. Only the app composition/presentation
    // is native; production credential acceptance is tested in core fake-native tests.
    exercise_settings_send(cx, crate::launch_authority::AuthorityMode::Native);
}

fn exercise_settings_send(cx: &mut TestAppContext, mode: crate::launch_authority::AuthorityMode) {
    let (dir, _control, window, root) = fixture_with_mode(cx, true, mode);
    std::fs::write(dir.path().join("AGENTS.md"), "PROJECT_INSTRUCTIONS_MARKER").unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let request = || {
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline);
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("{e}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            let body = loop {
                let n = stream.read(&mut buffer).unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(at) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..at]);
                    let size: usize = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|v| v.trim().parse().unwrap())
                        })
                        .unwrap();
                    if bytes.len() >= at + 4 + size {
                        break serde_json::from_slice::<serde_json::Value>(
                            &bytes[at + 4..at + 4 + size],
                        )
                        .unwrap();
                    }
                }
            };
            (stream, body)
        };
        let respond = |mut stream: std::net::TcpStream, output: &str| {
            let event = format!(
                "data: {{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\",\"output\":[{output}]}}}}\n\n"
            );
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",event.len(),event).unwrap();
        };
        // The model lists the project; the listing goes back to it.
        let (stream, body) = request();
        tx.send(body).unwrap();
        respond(
            stream,
            r#"{"type":"function_call","call_id":"list-project","name":"ls","arguments":"{\"path\":\".\"}"}"#,
        );
        let (stream, body) = request();
        tx.send(body).unwrap();
        respond(
            stream,
            r#"{"type":"message","content":[{"type":"output_text","text":"fixture reply"}]}"#,
        );
    });
    edit(&root, cx, |f| {
        f.base_url = url;
        f.model = "selected-fixture-alias".into();
    });
    let id = save_fixture(window, &root, cx);
    assert!(rx.try_recv().is_err());
    let editor = cx.read(|cx| root.read(cx).composer.entity_id());
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.connection_id.as_deref(), Some(id.as_str()));
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.composer.read(cx).text(), "keep composer 日本語");
        assert!(!view.controller.is_persistent());
    });
    assert!(!dir.path().join("session.json").exists());
    assert!(rx.try_recv().is_err());
    root.update(cx, |view, cx| view.submit(Lane::FollowUp, cx));
    let mut body = None;
    wait(cx, |_| {
        body = rx.try_recv().ok();
        body.is_some()
    });
    let body = body.unwrap();
    assert_eq!(body["model"], "selected-fixture-alias");
    assert!(body.to_string().contains("keep composer 日本語"));
    // Both compositions offer the trusted project's tools and send its
    // instructions; a native chat reads as Swift's starter card does.
    let names: Vec<&str> = body["tools"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|tool| tool["name"].as_str())
        .collect();
    assert!(names.contains(&"ls"), "{names:?}");
    assert!(
        body.to_string().contains("PROJECT_INSTRUCTIONS_MARKER"),
        "{body}"
    );
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.controller.has_available_tool_definitions());
        assert!(view.runtime.mcp_manager().is_ok());
        let label = crate::saved_runtime_adapter::tool_runtime_label(
            &view.controller,
            mode,
            view.record.tool_mode,
        );
        if mode.is_fixture() {
            assert_eq!(label, "Fixture tool runtime");
        } else {
            assert_eq!(
                label,
                match view.record.tool_mode {
                    bello_agent_core::workspace::ChatToolMode::Editing => "Editing tools",
                    bello_agent_core::workspace::ChatToolMode::ReadOnly => "Read-only tools",
                }
            );
        }
    });
    // The tool ran in the project and its listing went back to the model.
    let mut body = None;
    wait(cx, |_| {
        body = rx.try_recv().ok();
        body.is_some()
    });
    let listed = body
        .unwrap()
        .to_string()
        .split("\"function_call_output\"")
        .nth(1)
        .unwrap_or_default()
        .to_owned();
    assert!(listed.contains("AGENTS.md"), "{listed}");
    worker.join().unwrap();
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.state != bello_agent_core::RunState::Running)
    });
    assert!(cx.read(|cx| root.read(cx).record.snapshot.exists()));
}

#[gpui::test]
fn tab_drafts_route_fork_and_cancel_preserve_original_chat(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx);
    let original = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&original, cx));
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |f| f.name = "unsaved rename".into());
    act(window, Intent::New, cx);
    let new = cx.read(|cx| root.read(cx).connections.active.clone().unwrap());
    edit(&root, cx, |f| f.name = "second unsaved".into());
    act(window, Intent::Select(original.clone()), cx);
    assert_eq!(
        cx.read(|cx| root
            .read(cx)
            .connections
            .presentation
            .active
            .as_ref()
            .unwrap()
            .fields
            .name
            .clone()),
        "unsaved rename"
    );
    act(window, Intent::Select(new), cx);
    act(window, Intent::Cancel, cx);
    assert_eq!(
        control
            .authority()
            .load_connections()
            .unwrap()
            .profiles()
            .len(),
        1
    );
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |f| {
        f.model = "forked-alias".into();
        f.name = "Fork".into();
    });
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.record.connection_id.as_deref(),
            Some(original.as_str())
        );
        assert_eq!(
            view.connections.loaded.as_ref().unwrap().profiles().len(),
            2
        );
        assert!(view.connections.view.read(cx).is_open());
        assert!(
            view.connections
                .presentation
                .notice
                .as_ref()
                .unwrap()
                .text
                .contains("new connections")
        );
    });
}

#[gpui::test]
fn uncertain_save_retains_form_and_reload_does_not_reopen_admission(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx);
    root.update(cx, |view, _| {
        let id = view.record.id.clone();
        view.sidebar_search.installed(&id);
    });
    edit(&root, cx, |f| {
        f.name = "Retain me".into();
        f.key = SYNTHETIC_KEY.into();
    });
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    act(window, Intent::SaveAll, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.connections.uncertain);
        assert_eq!(
            view.sidebar_search.test_route(&view.record.id),
            Some(bello_agent_core::sidebar_search::reconciliation::SourceRoute::Blocked)
        );
        assert_eq!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .name,
            "Retain me"
        );
        assert!(!view.controller.configured());
    });
    root.update(cx, |view, cx| view.reload_connections(false, cx));
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).connections.uncertain));
}

fn stage_catalog_selection_notice(
    root: &Entity<AgentView>,
    window: WindowHandle<AgentView>,
    cx: &mut TestAppContext,
) {
    act(window, Intent::BrowseCatalog, cx);
    wait(cx, |cx| {
        cx.read(|cx| {
            !root
                .read(cx)
                .connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .catalog
                .loading
        })
    });
    let generation = cx.read(|cx| {
        root.read(cx)
            .connections
            .presentation
            .active
            .as_ref()
            .unwrap()
            .catalog
            .generation
    });
    act(
        window,
        Intent::ChooseCatalog {
            id: "deepseek-v4.1-flash".into(),
            generation,
        },
        cx,
    );
    cx.read(|cx| {
        let state = &root.read(cx).connections;
        assert!(
            state
                .presentation
                .notice
                .as_ref()
                .unwrap()
                .text
                .contains("Model metadata applied")
        );
        assert_eq!(
            state.forms[state.active.as_ref().unwrap()]
                .capture()
                .unwrap()
                .profile
                .model_output_limit,
            Some(393216)
        );
    });
}

#[gpui::test]
fn save_errors_survive_discard_reopen_and_uncertainty_still_blocks_admission(
    cx: &mut TestAppContext,
) {
    for error in [AuthorityError::Conflict, AuthorityError::Unconfirmed] {
        for confirm_close in [false, true] {
            let (_dir, control, window, root) = fixture(cx);
            let before = control.snapshot_bytes().unwrap();
            edit(&root, cx, |f| {
                f.name = "Failed save draft".into();
                f.key = SYNTHETIC_KEY.into();
            });
            stage_catalog_selection_notice(&root, window, cx);
            control.fail_next_write(error.clone()).unwrap();
            act(window, Intent::SaveAll, cx);
            // Unconfirmed writes may commit. Discard must not mutate the
            // post-failure bytes or turn uncertainty into confirmed admission.
            let failed_bytes = control.snapshot_bytes().unwrap();
            if error == AuthorityError::Conflict {
                assert_eq!(failed_bytes, before);
            }
            let warning = cx.read(|cx| {
                let state = &root.read(cx).connections;
                let warning = state.presentation.notice.clone().unwrap();
                assert!(warning.is_error);
                assert_eq!(state.uncertain, error == AuthorityError::Unconfirmed);
                warning
            });
            if confirm_close {
                act(window, Intent::RequestClose, cx);
                act(window, Intent::DiscardAndClose, cx);
            } else {
                act(window, Intent::Cancel, cx);
            }
            window
                .update(cx, |view, window, cx| view.open_connections(window, cx))
                .unwrap();
            cx.read(|cx| {
                let view = root.read(cx);
                assert_eq!(
                    view.connections.presentation.notice.as_ref(),
                    Some(&warning)
                );
                assert!(!view.connections.presentation.dirty);
                assert!(!view.controller.configured());
                if error == AuthorityError::Unconfirmed {
                    assert!(view.connections.uncertain);
                    assert!(matches!(
                        view.connections.presentation.availability,
                        super::ConnectionSettingsAvailability::Unconfirmed(_)
                    ));
                    assert!(!view.connections.presentation.allows(&Intent::SaveAll));
                    assert!(view.connection_switch_blocker().is_some());
                }
            });
            assert_eq!(control.snapshot_bytes().unwrap(), failed_bytes);
        }
    }
}

#[gpui::test]
fn non_error_recovery_notice_survives_discard_reopen(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    edit(&root, cx, |f| f.name = "Discard this draft".into());
    stage_catalog_selection_notice(&root, window, cx);
    root.update(cx, |view, cx| {
        view.connections.notice(
            "Settings were saved, but a chat could not apply them. Explicit recovery is required.",
            false,
        );
        view.connections.publish(cx);
    });
    let notice = cx.read(|cx| root.read(cx).connections.presentation.notice.clone());
    act(window, Intent::Cancel, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.read(|cx| assert_eq!(root.read(cx).connections.presentation.notice, notice));
}

#[gpui::test]
fn delete_replaces_pending_chat_with_disconnected_controller_and_preserves_composer(
    cx: &mut TestAppContext,
) {
    let (_dir, control, window, root) = fixture(cx);
    let id = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    let old = cx.read(|cx| root.read(cx).controller.clone());
    let editor = cx.read(|cx| root.read(cx).composer.entity_id());
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::RequestDelete, cx);
    act(window, Intent::ConfirmDelete, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(old.is_retired());
        assert!(!view.controller.configured());
        assert_eq!(
            crate::saved_runtime_adapter::tool_runtime_label(
                &view.controller,
                view.connections.presentation.mode,
                view.record.tool_mode,
            ),
            "Tools unavailable"
        );
        assert_ne!(Arc::as_ptr(&old), Arc::as_ptr(&view.controller));
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.composer.read(cx).text(), "keep composer 日本語");
        assert!(
            view.connections
                .loaded
                .as_ref()
                .unwrap()
                .profiles()
                .is_empty()
        );
    });
    assert!(
        control
            .authority()
            .load_connections()
            .unwrap()
            .profiles()
            .is_empty()
    );
}

#[gpui::test]
fn settings_editor_receives_text_selection_undo_and_navigation_without_touching_composer(
    cx: &mut TestAppContext,
) {
    use gpui::{Modifiers, VisualTestContext, px, size};
    let (_directory, _control, window, root) = fixture(cx);
    let (composer, original_draft, controller_revision) = cx.read(|cx| {
        let view = root.read(cx);
        (
            view.composer.entity_id(),
            view.composer.read(cx).text().to_owned(),
            view.controller.revision(),
        )
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(812.)));
    cx.run_until_parked();
    let name = visual
        .debug_bounds("settings-connection-name")
        .expect("visible Name editor");
    visual.simulate_click(name.center(), Modifiers::none());
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "linux") {
            "ctrl-a"
        } else {
            "cmd-a"
        },
    );
    cx.simulate_input(window.into(), "Keyboard connection 日本語");
    cx.run_until_parked();
    let active_name = |cx: &mut TestAppContext| {
        cx.read(|cx| {
            let view = root.read(cx);
            view.connections.forms[view.connections.active.as_ref().unwrap()]
                .fields
                .name
                .clone()
        })
    };
    assert_eq!(active_name(cx), "Keyboard connection 日本語");
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "linux") {
            "ctrl-z"
        } else {
            "cmd-z"
        },
    );
    cx.run_until_parked();
    assert_eq!(
        active_name(cx),
        "New connection",
        "owner edit echoes retain the editor's Undo history"
    );
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "linux") {
            "ctrl-a"
        } else {
            "cmd-a"
        },
    );
    cx.simulate_input(window.into(), "Alpha");
    cx.simulate_keystrokes(window.into(), "left backspace");
    cx.run_until_parked();
    assert_eq!(
        active_name(cx),
        "Alpa",
        "ancestor capture must allow editor navigation and deletion"
    );
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.composer.entity_id(), composer);
        assert_eq!(view.composer.read(cx).text(), original_draft);
        assert_eq!(view.controller.revision(), controller_revision);
        assert!(!view.controller.is_persistent());
    });
    let cancel = visual.debug_bounds("settings-cancel").unwrap();
    visual.simulate_click(cancel.center(), Modifiers::none());
    cx.run_until_parked();
    cx.read(|cx| assert!(!root.read(cx).connections.view.read(cx).is_open()));
}

#[gpui::test]
fn unloaded_legacy_chat_stays_disconnected_after_another_chat_selects_a_saved_connection(
    cx: &mut TestAppContext,
) {
    let (_directory, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    let selected_chat = cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.connection_id.as_deref(), Some(saved.as_str()));
        assert!(view.controller.configuration().is_some());
        assert!(view.legacy_configuration.is_none());
        view.record.id.clone()
    });
    let legacy_id = uuid::Uuid::new_v4().to_string();
    window
        .update(cx, |view, window, cx| {
            let mut record = ChatRecord::new(
                legacy_id.clone(),
                "Unloaded legacy chat".into(),
                view.chat_directory.join(format!("{legacy_id}.json")),
            );
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
            let draft = DraftRecord {
                skills: Vec::new(),
                attachments: Vec::new(),
                text: "Legacy draft stays disconnected 日本語".into(),
                ..Default::default()
            };
            view.workspace
                .lock()
                .unwrap()
                .register(record.clone(), draft.clone())
                .unwrap();
            view.records.push(record);
            view.unloaded_drafts.insert(legacy_id.clone(), draft);
            view.select_chat(&legacy_id, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, legacy_id);
        assert!(view.record.connection_id.is_none());
        assert!(view.legacy_configuration.is_none());
        assert!(
            view.controller.configuration().is_none(),
            "a null-ID legacy chat must never borrow the previously selected saved runtime"
        );
        assert_eq!(
            view.composer.read(cx).text(),
            "Legacy draft stays disconnected 日本語"
        );
        assert!(!view.record.snapshot.exists());
        assert_eq!(
            view.inactive[&selected_chat]
                .record
                .connection_id
                .as_deref(),
            Some(saved.as_str())
        );
    });
}

#[gpui::test]
fn new_chat_without_a_configured_choice_infers_neither_saved_identity_nor_runtime(
    cx: &mut TestAppContext,
) {
    let (_directory, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    let before = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| {
            assert!(view.controller.configuration().is_some());
            assert!(view.legacy_configuration.is_none());
            assert!(!view.connections.choices().is_empty());
            // Existence of saved connections is not an explicit configured choice.
            view.connections.choice = None;
            view.new_chat(window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_ne!(view.record.id, before);
        assert!(view.record.connection_id.is_none());
        assert!(view.controller.configuration().is_none());
        assert!(view.legacy_configuration.is_none());
        assert!(!view.controller.is_persistent());
        assert_eq!(
            view.inactive[&before].record.connection_id.as_deref(),
            Some(saved.as_str())
        );
        assert_eq!(
            view.inactive[&before].composer.read(cx).text(),
            "keep composer 日本語"
        );
    });
}

#[gpui::test]
fn first_saved_choice_makes_new_chat_use_it_instead_of_reusing_disconnected_placeholder(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root) = fixture(cx);
    root.update(cx, |view, cx| {
        view.composer
            .update(cx, |editor, cx| editor.set_text(String::new(), cx))
    });
    let before = cx.read(|cx| root.read(cx).record.id.clone());
    let saved = save_fixture(window, &root, cx);
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_ne!(view.record.id, before);
        assert_eq!(view.record.connection_id.as_deref(), Some(saved.as_str()));
        assert!(view.controller.configured());
        assert!(!view.controller.is_persistent());
    });
}

#[gpui::test]
fn post_catalog_switch_open_failure_adopts_new_binding_and_never_revives_old_route(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root) = fixture(cx);
    let first = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&first, cx));
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::New, cx);
    edit(&root, cx, |f| {
        f.name = "Second route".into();
        f.model = "second-alias".into();
        f.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::SaveAll, cx);
    let second = cx.read(|cx| root.read(cx).connections.choice.clone().unwrap());
    assert_ne!(first, second);
    let (old, path) = root.update(cx, |view, cx| {
        let draft = view.saved_draft(cx);
        view.workspace
            .lock()
            .unwrap()
            .register(view.record.clone(), draft)
            .unwrap();
        view.pending = false;
        (view.controller.clone(), view.record.snapshot.clone())
    });
    // A registered, never-sent chat has no journal. A directory in its place
    // causes a real reopen failure after the catalog selection was committed.
    std::fs::create_dir_all(&path).unwrap();
    let late_activity = bello_agent_core::workspace::organization_timestamp();
    root.update(cx, |view, cx| {
        view.select_connection(&second, cx);
        let id = view.record.id.clone();
        // A genuine event accepted before retirement may arrive through its
        // watch callback while retirement/reopen is still outstanding.
        view.test_activity_event(&id, late_activity, cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.connection_id.as_deref(), Some(second.as_str()));
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().chats[0]
                .connection_id
                .as_deref(),
            Some(second.as_str())
        );
        assert!(old.is_retired());
        assert_eq!(view.record.last_activity_at, Some(late_activity));
        assert_eq!(
            view.records
                .iter()
                .find(|row| row.id == view.record.id)
                .unwrap()
                .last_activity_at,
            Some(late_activity)
        );
        assert!(view.connections.blocked.contains(&view.record.id));
    });
    assert!(
        old.submit("must never send on old route".into(), Lane::FollowUp)
            .is_err()
    );
    std::fs::remove_dir(&path).unwrap();
    let retry_activity = late_activity.saturating_add(1);
    root.update(cx, |view, cx| {
        view.select_connection(&second, cx);
        let id = view.record.id.clone();
        view.test_activity_event(&id, retry_activity, cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.connections.blocked.contains(&view.record.id));
        assert_eq!(view.controller.profile().unwrap().model_id, "second-alias");
        assert_eq!(view.record.last_activity_at, Some(retry_activity));
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().chats[0].last_activity_at,
            Some(retry_activity)
        );
        assert!(old.is_retired());
    });
}

#[gpui::test]
fn pending_pin_fences_connection_switch_until_fresh_catalog_registration(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    let first = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&first, cx));
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::New, cx);
    edit(&root, cx, |f| {
        f.name = "Second".into();
        f.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::SaveAll, cx);
    let second = cx.read(|cx| root.read(cx).connections.choice.clone().unwrap());
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        view.set_chat_pinned(&id, true, cx);
        assert!(view.organization_operations.contains_key(&id));
        view.select_connection(&second, cx);
        assert_eq!(view.record.connection_id.as_deref(), Some(first.as_str()));
        assert!(!view.controller.is_retired());
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| view.select_connection(&second, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        let state = view.workspace.lock().unwrap().snapshot();
        assert_eq!(view.record.connection_id.as_deref(), Some(second.as_str()));
        assert_eq!(
            state.chats[0].connection_id.as_deref(),
            Some(second.as_str())
        );
        assert!(view.record.pinned_at.is_some());
        assert_eq!(view.record.pinned_at, state.chats[0].pinned_at);
    });
}

#[gpui::test]
fn loading_chat_blocks_settings_save_and_delete_without_losing_edits(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx);
    let id = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&id, cx));
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |f| f.name = "retained rename".into());
    let before = control.snapshot_bytes().unwrap();
    root.update(cx, |view, _| view.loading = true);
    act(window, Intent::SaveAll, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.controller.is_retired());
        assert!(
            view.connections
                .presentation
                .notice
                .as_ref()
                .unwrap()
                .text
                .contains("finish opening")
        );
        assert_eq!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .name,
            "retained rename"
        );
    });
    act(window, Intent::RequestDelete, cx);
    act(window, Intent::ConfirmDelete, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    assert!(!cx.read(|cx| root.read(cx).controller.is_retired()));
    root.update(cx, |view, _| view.loading = false);
    act(window, Intent::SaveAll, cx);
    assert_eq!(
        control.authority().load_connections().unwrap().profiles()[0].name,
        "retained rename"
    );
}

/// One completed response followed by an actual streaming request held open
/// until its client cancels. Counts every accepted HTTP request, including any
/// unintended queued continuation. No configured provider outside loopback.
struct DeletionGateway {
    url: String,
    requests: Arc<std::sync::atomic::AtomicUsize>,
    stalled_closed: Arc<std::sync::atomic::AtomicBool>,
    stop: Arc<std::sync::atomic::AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl DeletionGateway {
    fn new() -> Self {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let stalled_closed = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let seen = requests.clone();
        let closed = stalled_closed.clone();
        let stopping = stop.clone();
        let worker = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            while !stopping.load(Ordering::SeqCst) {
                assert!(
                    Instant::now() < deadline,
                    "bounded deletion loopback fixture"
                );
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(3));
                        continue;
                    }
                    Err(error) => panic!("loopback accept: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0_u8; 4096];
                loop {
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0, "request terminated before body");
                    bytes.extend_from_slice(&buffer[..count]);
                    assert!(bytes.len() <= 256 * 1024, "bounded synthetic request");
                    if let Some(at) = bytes.windows(4).position(|value| value == b"\r\n\r\n") {
                        let length: usize = String::from_utf8_lossy(&bytes[..at])
                            .lines()
                            .find_map(|line| {
                                line.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|value| value.trim().parse().unwrap())
                            })
                            .unwrap();
                        if bytes.len() >= at + 4 + length {
                            break;
                        }
                    }
                }
                let index = seen.fetch_add(1, Ordering::SeqCst);
                if index == 0 {
                    let event = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"completed fixture history\"}]}]}}\n\n";
                    write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}", event.len(), event).unwrap();
                } else {
                    stream.write_all(concat!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"retained active partial\"}\n\n"
                    ).as_bytes()).unwrap();
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_millis(80)))
                        .unwrap();
                    while !stopping.load(Ordering::SeqCst) {
                        match stream.read(&mut buffer) {
                            Ok(0) => {
                                closed.store(true, Ordering::SeqCst);
                                break;
                            }
                            Ok(_) => {}
                            Err(error)
                                if matches!(
                                    error.kind(),
                                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                                ) => {}
                            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => {
                                closed.store(true, Ordering::SeqCst);
                                break;
                            }
                            Err(error) => panic!("stalled loopback read: {error}"),
                        }
                    }
                }
            }
        });
        Self {
            url,
            requests,
            stalled_closed,
            stop,
            worker: Some(worker),
        }
    }
    fn count(&self) -> usize {
        self.requests.load(std::sync::atomic::Ordering::SeqCst)
    }
}
impl Drop for DeletionGateway {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !std::thread::panicking() {
                result.expect("loopback fixture worker");
            }
        }
    }
}

fn exercise_persisted_active_delete(cx: &mut TestAppContext, conflict: bool) {
    use bello_agent_core::{RunState, Submission};
    let gateway = DeletionGateway::new();
    let (_directory, control, window, root) = fixture(cx);
    edit(&root, cx, |fields| fields.base_url = gateway.url.clone());
    let saved = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    root.update(cx, |view, cx| view.submit(Lane::FollowUp, cx));
    wait(cx, |cx| {
        cx.read(|cx| {
            let view = root.read(cx);
            view.session.state == RunState::Idle
                && view
                    .session
                    .messages
                    .iter()
                    .any(|message| message.text == "completed fixture history")
        })
    });
    assert_eq!(gateway.count(), 1);
    let original = cx.read(|cx| root.read(cx).controller.clone());
    root.update(cx, |view, cx| {
        view.composer.update(cx, |editor, cx| {
            editor.set_text("active request before deletion".into(), cx)
        });
        view.submit(Lane::FollowUp, cx);
    });
    wait(cx, |cx| {
        gateway.count() == 2
            && cx.read(|cx| {
                let view = root.read(cx);
                view.session.state == RunState::Running
                    && view
                        .session
                        .messages
                        .iter()
                        .any(|message| message.text == "retained active partial")
            })
    });
    let queued = Submission::new(
        "accepted queue must never dispatch during deletion".into(),
        Lane::FollowUp,
    );
    original.submit_identified(queued.clone()).unwrap();
    root.update(cx, |view, cx| {
        view.composer.update(cx, |editor, cx| {
            editor.set_text("retained unsent composer 日本語".into(), cx)
        })
    });
    wait(cx, |cx| {
        cx.read(|cx| {
            root.read(cx)
                .session
                .pending
                .iter()
                .any(|item| item.id == queued.id)
        })
    });
    let (editor, chat_id, snapshot) = cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.controller.is_persistent());
        assert!(view.record.snapshot.exists());
        assert!(view.session.state == RunState::Running);
        (
            view.composer.entity_id(),
            view.record.id.clone(),
            view.record.snapshot.clone(),
        )
    });
    if conflict {
        control.fail_next_write(AuthorityError::Conflict).unwrap();
    }
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::RequestDelete, cx);
    act(window, Intent::ConfirmDelete, cx);
    wait(cx, |cx| {
        cx.read(|cx| {
            let view = root.read(cx);
            view.connections.operation.is_none() && !Arc::ptr_eq(&view.controller, &original)
        })
    });
    wait(cx, |_| {
        gateway
            .stalled_closed
            .load(std::sync::atomic::Ordering::SeqCst)
    });
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(original.is_retired());
        assert!(!view.controller.is_retired());
        assert!(!view.controller.configured());
        assert_eq!(view.record.snapshot, snapshot);
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(
            view.composer.read(cx).text(),
            "retained unsent composer 日本語"
        );
        assert!(view.session.queue_paused);
        assert_ne!(view.session.state, RunState::Running);
        assert!(
            view.session
                .messages
                .iter()
                .any(|message| message.text == "completed fixture history")
        );
        assert!(
            view.session
                .messages
                .iter()
                .any(|message| message.text == "retained active partial")
        );
        assert_eq!(view.session.pending.len(), 1);
        assert_eq!(view.session.pending[0].id, queued.id);
        assert_eq!(view.session.pending[0].text, queued.text);
        assert!(
            !view.connections.blocked.contains(&chat_id),
            "disconnected reviewer must allow queue inspection/removal"
        );
        assert_eq!(
            view.connections.loaded.as_ref().unwrap().profiles().len(),
            usize::from(conflict)
        );
        if conflict {
            assert!(
                view.connections
                    .presentation
                    .notice
                    .as_ref()
                    .unwrap()
                    .text
                    .contains("not deleted")
            );
        }
    });
    assert!(
        original
            .submit("retired owner must reject".into(), Lane::FollowUp)
            .is_err()
    );
    assert_eq!(gateway.count(), 2);
    act(window, Intent::Cancel, cx);
    window
        .update(cx, |view, window, cx| {
            let before = view.controller.revision();
            view.open_queue_detail(
                queued.id.clone(),
                gpui::point(gpui::px(400.), gpui::px(200.)),
                window,
                cx,
            );
            assert!(view.queue_detail.is_some());
            assert_eq!(
                view.controller.revision(),
                before,
                "inspection does not acquire a queue edit"
            );
            assert!(view.session.edit.is_none());
            view.close_queue_detail(true, window, cx);
            view.remove_queued_from_chat(&chat_id, &queued.id, cx);
        })
        .unwrap();
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.pending.is_empty())
    });
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(
            view.composer.read(cx).text(),
            "retained unsent composer 日本語"
        );
        assert!(view.controller.is_persistent());
        assert!(!view.controller.configured());
    });
    if conflict {
        root.update(cx, |view, cx| view.select_connection(&saved, cx));
        wait(cx, |cx| cx.read(|cx| root.read(cx).controller.configured()));
        cx.read(|cx| {
            let view = root.read(cx);
            assert_eq!(view.record.connection_id.as_deref(), Some(saved.as_str()));
            assert!(view.session.pending.is_empty());
            assert_eq!(view.composer.entity_id(), editor);
            assert_eq!(
                view.composer.read(cx).text(),
                "retained unsent composer 日本語"
            );
        });
    }
    assert_eq!(
        gateway.count(),
        2,
        "delete, inspection, removal and optional explicit reselect send nothing"
    );
}

#[gpui::test]
fn delete_joins_actual_stalled_request_and_preserves_persisted_history_queue_and_composer(
    cx: &mut TestAppContext,
) {
    exercise_persisted_active_delete(cx, false);
}

#[gpui::test]
fn definite_delete_conflict_reopens_disconnected_queue_reviewer_and_permits_explicit_reselect(
    cx: &mut TestAppContext,
) {
    exercise_persisted_active_delete(cx, true);
}

#[gpui::test]
fn window_close_captures_local_typing_before_owner_acknowledgment_and_keep_retains_it(
    cx: &mut TestAppContext,
) {
    use gpui::{Modifiers, VisualTestContext, px, size};
    let (_directory, _control, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(812.)));
    cx.run_until_parked();
    // Delay the editor -> owner delivery deliberately. This represents a native
    // close arriving while the owner still holds an acknowledged clean snapshot.
    root.update(cx, |view, _| view.connections.events = None);
    let name = visual
        .debug_bounds("settings-connection-name")
        .unwrap()
        .center();
    visual.simulate_click(name, Modifiers::none());
    cx.simulate_keystrokes(
        window.into(),
        if cfg!(target_os = "linux") {
            "ctrl-a"
        } else {
            "cmd-a"
        },
    );
    cx.simulate_input(window.into(), "Local edit before native close 日本語");
    cx.run_until_parked();
    cx.read(|cx| assert!(!root.read(cx).connections.presentation.dirty));
    window
        .update(cx, |view, window, cx| {
            view.bind_connections(window, cx);
            assert!(
                !view.request_close(window, cx),
                "native window stays open while Settings decides"
            );
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.connections.presentation.dirty);
        assert_eq!(
            view.connections.presentation.confirmation,
            super::ConnectionConfirmation::Close
        );
        assert_eq!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .name,
            "Local edit before native close 日本語"
        );
        assert!(!view.shutting_down);
    });
    act(window, Intent::KeepEditing, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.connections.view.read(cx).is_open());
        assert_eq!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .name,
            "Local edit before native close 日本語"
        );
        assert_eq!(view.composer.read(cx).text(), "keep composer 日本語");
        assert!(!view.controller.is_persistent());
    });
}

#[::core::prelude::v1::test]
fn manual_model_change_clears_inherited_image_capability_but_name_edit_keeps_it() {
    let mut form = new_form(crate::launch_authority::AuthorityMode::Fixture);
    form.draft.profile.input = vec!["text".into(), "image".into()];
    form.fields.name = "Renamed fixture".into();
    assert!(form.capture().unwrap().profile.supports_images());
    form.fields.model = "unknown-other-model".into();
    assert!(!form.capture().unwrap().profile.supports_images());
    assert!(form.draft.profile.supports_images());
}

#[gpui::test]
fn saved_settings_require_trust_then_open_the_same_pending_chat_without_sending(
    cx: &mut TestAppContext,
) {
    use crate::project_manager_view::ProjectManagerIntent;
    let (_directory, _control, window, root) = fixture_with_trust(cx, false);
    let saved = save_fixture(window, &root, cx);
    let (original, id, editor) = cx.read(|cx| {
        let view = root.read(cx);
        (
            view.controller.clone(),
            view.record.id.clone(),
            view.composer.entity_id(),
        )
    });
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            !original.is_retired(),
            "untrusted preflight cannot strand the original actor"
        );
        assert!(view.record.connection_id.is_none());
        assert!(view.error.as_ref().unwrap().contains("Trust"));
        assert!(!view.record.snapshot.exists());
    });
    window
        .update(cx, |view, window, cx| view.open_projects(window, cx))
        .unwrap();
    cx.run_until_parked();
    for intent in [
        ProjectManagerIntent::BeginCreate,
        ProjectManagerIntent::ConfirmTrust,
    ] {
        window
            .update(cx, |view, window, cx| {
                view.project_intent(view.projects.presentation.revision, intent, window, cx);
            })
            .unwrap();
        cx.run_until_parked();
    }
    window
        .update(cx, |view, window, cx| {
            assert!(view.projects.presentation.trusted);
            let notice = &view.projects.presentation.notice.as_ref().unwrap().text;
            assert!(notice.contains("Fixture-only tools require a saved loopback connection"));
            assert!(notice.contains("Nothing was sent"));
            view.projects
                .view
                .update(cx, |view, cx| view.close(true, window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, id);
        assert_eq!(view.composer.entity_id(), editor);
        assert_eq!(view.composer.read(cx).text(), "keep composer 日本語");
        assert!(view.controller.configured());
        assert_eq!(view.record.connection_id.as_deref(), Some(saved.as_str()));
        assert_eq!(
            crate::saved_runtime_adapter::tool_runtime_label(
                &view.controller,
                view.connections.presentation.mode,
                view.record.tool_mode,
            ),
            "Fixture tool runtime"
        );
        assert!(view.controller.is_never_materialized());
        assert!(!view.record.snapshot.exists());
        assert!(view.session.messages.is_empty());
        assert!(view.workspace.lock().unwrap().snapshot().chats.is_empty());
    });
}

#[gpui::test]
fn checkpoint_required_missing_on_navigation_keeps_draft_and_inert_placeholder(
    cx: &mut TestAppContext,
) {
    exercise_missing_checkpoint(cx, crate::launch_authority::AuthorityMode::Fixture);
}

#[gpui::test]
fn native_mode_required_missing_checkpoint_keeps_draft_and_inert_placeholder(
    cx: &mut TestAppContext,
) {
    exercise_missing_checkpoint(cx, crate::launch_authority::AuthorityMode::Native);
}

fn exercise_missing_checkpoint(
    cx: &mut TestAppContext,
    mode: crate::launch_authority::AuthorityMode,
) {
    let (_directory, _control, window, root, saved) = if mode.is_fixture() {
        let (directory, control, window, root) = fixture(cx);
        let saved = save_fixture(window, &root, cx);
        (directory, control, window, root, saved)
    } else {
        native_mode_saved_fixture(cx)
    };
    let id = uuid::Uuid::new_v4().to_string();
    window
        .update(cx, |view, window, cx| {
            let mut record = ChatRecord::new(
                id.clone(),
                "Missing checkpoint".into(),
                view.chat_directory.join(format!("{id}.json")),
            );
            record.connection_id = Some(saved.clone());
            let draft = DraftRecord {
                skills: Vec::new(),
                attachments: Vec::new(),
                text: "never replace lost checkpoint".into(),
                ..Default::default()
            };
            view.workspace
                .lock()
                .unwrap()
                .register(record.clone(), draft.clone())
                .unwrap();
            view.records.push(record);
            view.unloaded_drafts.insert(id.clone(), draft);
            view.select_chat(&id, window, cx);
            assert!(
                !view.controller.configured(),
                "loader must be inert before background validation"
            );
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.load_failed);
        assert!(!view.controller.configured());
        assert_eq!(
            view.composer.read(cx).text(),
            "never replace lost checkpoint"
        );
        view.submit(Lane::FollowUp, cx);
        assert!(!view.record.snapshot.exists());
        assert!(!view.record.snapshot.with_extension("lock").exists());
        assert_eq!(
            view.composer.read(cx).text(),
            "never replace lost checkpoint"
        );
        assert!(view.session.messages.is_empty());
    });
}

#[gpui::test]
fn first_send_crash_before_checkpoint_can_recover_complete_receipt_without_opening_empty_history(
    cx: &mut TestAppContext,
) {
    use bello_agent_core::workspace::SubmissionIntent;
    let (_directory, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    let id = uuid::Uuid::new_v4().to_string();
    let full = format!("{}日本語 last retained words", "retained input ".repeat(80));
    let intent = SubmissionIntent {
        skills: Vec::new(),
        attachments: Vec::new(),
        id: uuid::Uuid::new_v4().to_string(),
        chat_id: id.clone(),
        text: full.clone(),
        lane: Lane::FollowUp,
        draft_revision: 0,
    };
    window
        .update(cx, |view, window, cx| {
            let mut record = ChatRecord::new(
                id.clone(),
                "Interrupted first send".into(),
                view.chat_directory.join(format!("{id}.json")),
            );
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
            record.connection_id = Some(saved);
            {
                let mut workspace = view.workspace.lock().unwrap();
                workspace
                    .register(record.clone(), DraftRecord::default())
                    .unwrap();
                workspace.begin_submission(intent.clone()).unwrap();
                record = workspace
                    .snapshot()
                    .chats
                    .into_iter()
                    .find(|row| row.id == id)
                    .unwrap();
            }
            view.records.push(record);
            view.recoveries.insert(intent.id.clone(), intent.clone());
            view.select_chat(&id, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.load_failed);
        view.resolve_intent(&intent.id, true, cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), full);
        assert!(!view.recoveries.contains_key(&intent.id));
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&id].text,
            full
        );
        assert!(view.load_failed);
        assert!(!view.record.snapshot.exists());
        assert!(!view.record.snapshot.with_extension("lock").exists());
        assert!(!view.controller.configured());
        view.submit(Lane::FollowUp, cx);
        assert_eq!(view.composer.read(cx).text(), full);
        assert!(!view.record.snapshot.exists());
    });
}

#[gpui::test]
async fn retired_materialized_actor_cannot_authorize_forged_pending_recreation(
    cx: &mut TestAppContext,
) {
    let (_directory, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    let (runtime, previous, mut forged) = root.update(cx, |view, _| {
        // Explicit disposable legacy fixture history, before selecting a route.
        view.controller.materialize(&view.record.snapshot).unwrap();
        (
            view.runtime.clone(),
            view.controller.clone(),
            view.record.clone(),
        )
    });
    previous.retire_and_wait().await.unwrap();
    assert!(!previous.is_persistent(), "the writer lock was released");
    assert!(
        !previous.is_never_materialized(),
        "immutable checkpoint provenance survived"
    );
    std::fs::remove_file(&forged.snapshot).unwrap();
    forged.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
    assert!(runtime.disconnected(&forged, Some(&previous)).is_err());
    forged.connection_id = Some(saved);
    assert!(runtime.reopen(&forged, &previous).is_err());
    assert!(!forged.snapshot.exists());
}

#[gpui::test]
fn composer_saved_factory_executes_actual_ls_and_replays_durable_result(cx: &mut TestAppContext) {
    let (directory, _control, window, root) = fixture(cx);
    std::fs::write(
        directory.path().join("factory-tool-proof.txt"),
        "fixture file",
    )
    .unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        for index in 0..2 {
            let deadline = Instant::now() + Duration::from_secs(6);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "bounded ls continuation");
                        std::thread::sleep(Duration::from_millis(3));
                    }
                    Err(error) => panic!("{error}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0_u8; 4096];
            let body = loop {
                let n = stream.read(&mut buffer).unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(at) = bytes.windows(4).position(|value| value == b"\r\n\r\n") {
                    let size: usize = String::from_utf8_lossy(&bytes[..at])
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|v| v.trim().parse().unwrap())
                        })
                        .unwrap();
                    if bytes.len() >= at + 4 + size {
                        break serde_json::from_slice::<serde_json::Value>(
                            &bytes[at + 4..at + 4 + size],
                        )
                        .unwrap();
                    }
                }
            };
            tx.send(body).unwrap();
            let output = if index == 0 {
                serde_json::json!([{"type":"function_call","id":"fixture-call","call_id":"fixture-ls","name":"ls","arguments":"{\"path\":\".\"}"}])
            } else {
                serde_json::json!([{"type":"message","content":[{"type":"output_text","text":"actual ls continuation complete"}]}])
            };
            let event = format!(
                "data: {}\n\n",
                serde_json::json!({"type":"response.completed","response":{"status":"completed","output":output}})
            );
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",event.len(),event).unwrap();
        }
    });
    edit(&root, cx, |fields| fields.base_url = endpoint);
    let saved = save_fixture(window, &root, cx);
    root.update(cx, |view, cx| view.select_connection(&saved, cx));
    cx.run_until_parked();
    assert!(rx.try_recv().is_err(), "saving/selecting does not send");
    root.update(cx, |view, cx| view.submit(Lane::FollowUp, cx));
    wait(cx, |cx| {
        cx.read(|cx| {
            root.read(cx)
                .session
                .messages
                .iter()
                .any(|message| message.text == "actual ls continuation complete")
        })
    });
    worker.join().unwrap();
    let first = rx.recv().unwrap();
    let second = rx.recv().unwrap();
    assert!(
        first["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|tool| tool["name"] == "ls")
    );
    assert!(
        second["input"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["type"] == "function_call_output"
                && item.to_string().contains("factory-tool-proof.txt"))
    );
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.controller.is_persistent());
        assert!(view.session.messages.iter().any(|message| matches!(&message.tool_record, Some(bello_agent_core::tool_history::ToolRecord::Result(result)) if result.outcome == bello_agent_core::tool_history::ToolOutcome::Completed)));
        assert_eq!(view.workspace.lock().unwrap().snapshot().chats[0].materialization, bello_agent_core::workspace::ChatMaterialization::CheckpointRequired);
    });
}

use bello_agent_core::workspace::SubmissionIntent;
use gpui::Focusable;

fn missing_image_receipt(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    SubmissionIntent,
) {
    let (directory, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    let id = uuid::Uuid::new_v4().to_string();
    let intent = SubmissionIntent {
        skills: Vec::new(),
        id: uuid::Uuid::new_v4().to_string(),
        chat_id: id.clone(),
        text: "unverified image caption".into(),
        lane: Lane::FollowUp,
        draft_revision: 0,
        attachments: vec![bello_agent_core::attachments::AttachmentRecord {
            id: uuid::Uuid::new_v4().to_string(),
            path: "/missing/original.gif".into(),
            sha256: "a".repeat(64),
            bytes: 6,
            mime_type: "image/gif".into(),
        }],
    };
    window
        .update(cx, |view, window, cx| {
            let mut record = ChatRecord::new(
                id.clone(),
                "Unverified image receipt".into(),
                view.chat_directory.join(format!("{id}.json")),
            );
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
            record.connection_id = Some(saved);
            {
                let mut catalog = view.workspace.lock().unwrap();
                catalog
                    .register(record.clone(), DraftRecord::default())
                    .unwrap();
                catalog.begin_submission(intent.clone()).unwrap();
                record = catalog
                    .snapshot()
                    .chats
                    .into_iter()
                    .find(|record| record.id == id)
                    .unwrap();
            }
            view.records.push(record);
            view.recoveries.insert(intent.id.clone(), intent.clone());
            view.select_chat(&id, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, _| {
        assert!(view.load_failed && view.controller.is_retired());
        assert!(!view.controller.configured());
        assert!(view.controller.is_never_materialized());
        assert_eq!(
            view.record.materialization,
            bello_agent_core::workspace::ChatMaterialization::CheckpointRequired
        );
    });
    (directory, window, root, intent)
}

#[gpui::test]
fn unavailable_image_receipt_extracts_only_to_draft_across_window_rebind(cx: &mut TestAppContext) {
    let (_directory, window, _root, intent) = missing_image_receipt(cx);
    window
        .update(cx, |view, window, cx| {
            view.resolve_intent(&intent.id, true, cx);
            view.bind_window(window, cx);
            view.filter.read(cx).focus(window);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.composer.read(cx).text(), intent.text);
            assert_eq!(view.attachments, intent.attachments);
            assert!(view.filter.read(cx).focus_handle(cx).is_focused(window));
            assert!(view.load_failed && view.controller.is_retired());
            assert!(!view.controller.configured());
            assert!(view.session.messages.is_empty() && view.session.pending.is_empty());
            assert_eq!(
                view.record.materialization,
                bello_agent_core::workspace::ChatMaterialization::CheckpointRequired
            );
            assert!(!view.record.snapshot.exists());
            assert!(!view.record.snapshot.with_extension("lock").exists());
            let saved = view.workspace.lock().unwrap().snapshot();
            assert_eq!(
                saved.drafts[&intent.chat_id].attachments,
                intent.attachments
            );
            assert!(!saved.intents.contains_key(&intent.id));
            assert!(
                view.error
                    .as_deref()
                    .unwrap()
                    .contains("may already have executed")
            );
            view.resolve_intent(&intent.id, true, cx);
            view.submit(Lane::FollowUp, cx);
            assert_eq!(view.composer.read(cx).text(), intent.text);
            assert_eq!(view.attachments, intent.attachments);
            assert!(view.session.messages.is_empty() && view.session.pending.is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn unavailable_receipt_preserves_existing_file_directory_symlink_and_fifo(cx: &mut TestAppContext) {
    for kind in ["file", "directory", "symlink", "fifo"] {
        let (_directory, _window, root, intent) = missing_image_receipt(cx);
        let path = cx.read(|cx| root.read(cx).record.snapshot.clone());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        match kind {
            "file" => std::fs::write(&path, b"existing unknown checkpoint").unwrap(),
            "directory" => std::fs::create_dir(&path).unwrap(),
            #[cfg(unix)]
            "symlink" => std::os::unix::fs::symlink("missing-target", &path).unwrap(),
            #[cfg(unix)]
            "fifo" => {
                use std::os::unix::ffi::OsStrExt;
                let cpath = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
            }
            _ => continue,
        }
        root.update(cx, |view, cx| view.resolve_intent(&intent.id, true, cx));
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert_eq!(view.composer.read(cx).text(), "");
            assert!(view.attachments.is_empty());
            assert!(view.load_failed);
            assert!(view.recoveries.contains_key(&intent.id));
            assert_eq!(
                view.workspace.lock().unwrap().snapshot().intents[&intent.id],
                intent
            );
            assert!(!view.busy);
            assert!(view.session.messages.is_empty());
            assert!(!path.with_extension("lock").exists());
        });
        assert!(std::fs::symlink_metadata(path).is_ok());
    }
}

#[gpui::test]
fn unavailable_receipt_rejects_changed_saved_receipt_and_catalog_chat_identity(
    cx: &mut TestAppContext,
) {
    for changed_chat in [false, true] {
        let (_directory, _window, root, intent) = missing_image_receipt(cx);
        root.update(cx, |view, cx| {
            if changed_chat {
                view.record.snapshot = view.record.snapshot.with_extension("different-missing");
            } else {
                view.recoveries.get_mut(&intent.id).unwrap().attachments[0].sha256 = "b".repeat(64);
            }
            view.resolve_intent(&intent.id, true, cx);
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert_eq!(view.composer.read(cx).text(), "");
            assert!(view.attachments.is_empty() && view.load_failed);
            assert!(view.recoveries.contains_key(&intent.id));
            assert_eq!(
                view.workspace.lock().unwrap().snapshot().intents[&intent.id],
                intent
            );
        });
    }
}

#[gpui::test]
fn unavailable_receipt_never_erases_newer_saved_draft_or_its_receipt(cx: &mut TestAppContext) {
    let (_directory, _window, root, intent) = missing_image_receipt(cx);
    root.update(cx, |view, cx| {
        view.resolve_intent(&intent.id, true, cx);
        let newer = DraftRecord {
            skills: Vec::new(),
            revision: view.draft_revision + 1,
            text: "newer catalog draft".into(),
            attachments: intent.attachments.clone(),
            queued_edit: None,
        };
        view.workspace
            .lock()
            .unwrap()
            .save_draft(&intent.chat_id, newer)
            .unwrap();
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), "");
        assert!(view.attachments.is_empty());
        assert!(view.recoveries.contains_key(&intent.id));
        let saved = view.workspace.lock().unwrap().snapshot();
        assert_eq!(saved.intents[&intent.id], intent);
        assert_eq!(saved.drafts[&intent.chat_id].text, "newer catalog draft");
        assert_eq!(
            saved.drafts[&intent.chat_id].attachments,
            intent.attachments
        );
        assert!(view.load_failed && !view.busy);
    });
}

#[gpui::test]
fn unavailable_receipt_non_not_found_metadata_error_is_not_absence(cx: &mut TestAppContext) {
    let (_directory, _window, root, intent) = missing_image_receipt(cx);
    root.update(cx, |view, cx| {
        let file = view.record.snapshot.clone();
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, b"parent is an ordinary file").unwrap();
        view.record.snapshot = file.join("child");
        let error = std::fs::symlink_metadata(&view.record.snapshot).unwrap_err();
        assert_ne!(error.kind(), std::io::ErrorKind::NotFound);
        view.resolve_intent(&intent.id, true, cx);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.composer.read(cx).text(), "");
        assert!(view.attachments.is_empty());
        assert!(
            view.error
                .as_deref()
                .unwrap()
                .contains("could not be confirmed missing")
        );
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().intents[&intent.id],
            intent
        );
        assert!(view.load_failed && !view.busy);
    });
}

#[path = "connection_catalog_workflow_tests.rs"]
mod catalog_workflow;

#[gpui::test]
fn native_catalog_intents_never_read_vault_or_create_catalog_work(cx: &mut TestAppContext) {
    let (_dir, control, window, root, _id) = native_mode_saved_fixture(cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    control.fail_next_read(AuthorityError::Denied).unwrap();
    root.update(cx, |view, cx| {
        assert!(view.connections.presentation.mode.editable());
        assert!(!view.connections.presentation.mode.is_fixture());
        view.load_connection_catalog(false, cx);
        view.load_connection_catalog(true, cx);
        view.choose_connection_model("must-not-apply", uuid::Uuid::new_v4());
        assert!(view.connections.catalogs.is_empty());
        assert!(!view.connections.presentation.dirty);
        assert!(view.connections.operation.is_none());
    });
    cx.run_until_parked();
    assert!(
        matches!(
            control.authority().load_connections(),
            Err(AuthorityError::Denied)
        ),
        "catalog actions must leave the pending read failure untouched"
    );
}

#[test]
fn untouched_native_new_form_is_clean_with_blank_manual_fields() {
    let form = new_form(crate::launch_authority::AuthorityMode::Native);
    assert!(form.fields.base_url.is_empty() && form.fields.model.is_empty());
    assert!(!form.dirty());
    assert!(!form.draft.has_changes());
}
