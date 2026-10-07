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

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let (_, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    cx.update(|cx| cx.set_global(LaunchConnectionAuthority(control.clone())));
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let record = ChatRecord::new(
        snapshot.id,
        "Connection fixture".into(),
        project.join("session.json"),
    );
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("workspace.json"), &project).unwrap(),
        )),
        project,
        record,
        draft: DraftRecord {
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
fn act(window: WindowHandle<AgentView>, intent: Intent, cx: &mut TestAppContext) {
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
fn edit(
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
fn save_fixture(
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
fn wait(cx: &mut TestAppContext, mut done: impl FnMut(&mut TestAppContext) -> bool) {
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

#[test]
fn model_alias_change_clears_old_catalog_ceiling_and_invalid_numbers_retain_text() {
    let mut form = new_form();
    form.draft.profile.model_output_limit = Some(1000);
    form.fields.model = "another-alias".into();
    assert!(form.capture().unwrap().profile.model_output_limit.is_none());
    form.fields.context_window = "invalid partial number".into();
    assert!(form.capture().is_err());
    assert_eq!(form.fields.context_window, "invalid partial number");
}

#[gpui::test]
fn settings_save_select_and_real_composer_send_use_selected_fixture(cx: &mut TestAppContext) {
    let (dir, _control, window, root) = fixture(cx);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
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
        tx.send(body).unwrap();
        let event = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"fixture reply\"}]}]}}\n\n";
        write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",event.len(),event).unwrap();
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
    assert!(
        body.get("tools")
            .is_none_or(|v| v.as_array().is_some_and(Vec::is_empty))
    );
    worker.join().unwrap();
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.state != bello_agent_core::RunState::Running)
    });
    assert!(dir.path().join("session.json").exists());
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
            let record = ChatRecord::new(
                legacy_id.clone(),
                "Unloaded legacy chat".into(),
                view.chat_directory.join(format!("{legacy_id}.json")),
            );
            let draft = DraftRecord {
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
    std::fs::create_dir(&path).unwrap();
    root.update(cx, |view, cx| view.select_connection(&second, cx));
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
        assert!(view.connections.blocked.contains(&view.record.id));
    });
    assert!(
        old.submit("must never send on old route".into(), Lane::FollowUp)
            .is_err()
    );
    std::fs::remove_dir(&path).unwrap();
    root.update(cx, |view, cx| view.select_connection(&second, cx));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.connections.blocked.contains(&view.record.id));
        assert_eq!(view.controller.profile().unwrap().model_id, "second-alias");
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
