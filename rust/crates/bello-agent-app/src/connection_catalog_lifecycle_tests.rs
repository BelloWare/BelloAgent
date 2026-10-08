//! Deterministic queued-success races complement actual HTTP cancellation tests.
use super::super::tests::{act, edit, fixture, save_fixture, wait};
use super::*;
use gpui::{Entity, TestAppContext};

struct Pending {
    id: String,
    generation: uuid::Uuid,
    identity: SourceIdentity,
    binding: Option<crate::workspace_lifetime::WindowBinding>,
    cancel: CancellationToken,
}
fn pending(root: &Entity<AgentView>, cx: &mut TestAppContext) -> Pending {
    root.update(cx, |view, cx| {
        let id = view.connections.active.clone().unwrap();
        let identity = SourceIdentity::of(
            &view.connections.forms[&id],
            view.connections.loaded.as_ref(),
        );
        let mut state = CatalogState::new(identity.clone());
        state.opened = true;
        let cancel = CancellationToken::new();
        state.cancel = Some(cancel.clone());
        let generation = state.generation;
        view.connections.catalogs.insert(id.clone(), state);
        view.connections.publish(cx);
        Pending {
            id,
            generation,
            identity,
            binding: view.window_binding,
            cancel,
        }
    })
}
fn stale_success(root: &Entity<AgentView>, old: &Pending, cx: &mut TestAppContext) {
    root.update(cx, |view, cx| {
        view.finish_connection_catalog(
            &old.id,
            old.generation,
            &old.identity,
            old.binding,
            Ok(bello_agent_core::model_catalog::bundled().unwrap()),
            cx,
        );
    });
}
#[gpui::test]
fn failed_save_and_delete_cancel_and_reject_already_queued_catalog_success(
    cx: &mut TestAppContext,
) {
    for deleting in [false, true] {
        for error in [AuthorityError::Conflict, AuthorityError::Unconfirmed] {
            let (_dir, control, window, root) = fixture(cx);
            save_fixture(window, &root, cx);
            window
                .update(cx, |view, window, cx| view.open_connections(window, cx))
                .unwrap();
            if !deleting {
                edit(&root, cx, |f| f.name = "retained edited name".into());
            }
            let old = pending(&root, cx);
            control.fail_next_write(error.clone()).unwrap();
            if deleting {
                act(window, ConnectionSettingsIntent::RequestDelete, cx);
                act(window, ConnectionSettingsIntent::ConfirmDelete, cx);
            } else {
                act(window, ConnectionSettingsIntent::SaveAll, cx);
            }
            wait(cx, |cx| {
                cx.read(|cx| root.read(cx).connections.operation.is_none())
            });
            assert!(
                old.cancel.is_cancelled(),
                "mutation admission must cancel catalog work"
            );
            stale_success(&root, &old, cx);
            cx.read(|cx| {
                let view = root.read(cx);
                let state = &view.connections.catalogs[&old.id];
                assert!(state.models.is_empty());
                assert!(state.cancel.is_none());
            });
            if error == AuthorityError::Conflict {
                let next = pending(&root, cx);
                stale_success(&root, &old, cx);
                cx.read(|cx| {
                    let state = &root.read(cx).connections.catalogs[&next.id];
                    assert_eq!(state.generation, next.generation);
                    assert!(state.cancel.is_some());
                    assert!(!next.cancel.is_cancelled());
                    assert!(state.models.is_empty());
                });
                root.update(cx, |view, _| view.connections.cancel_catalog_loads());
            }
        }
    }
}
#[gpui::test]
fn window_rebind_fences_old_catalog_success_and_keeps_new_request_owned(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    let old = pending(&root, cx);
    window
        .update(cx, |view, window, cx| {
            view.window_binding = Some(crate::workspace_lifetime::WindowBinding::new(
                window.window_handle().window_id(),
            ));
            view.bind_connections(window, cx);
        })
        .unwrap();
    assert!(old.cancel.is_cancelled());
    let next = pending(&root, cx);
    stale_success(&root, &old, cx);
    cx.read(|cx| {
        let state = &root.read(cx).connections.catalogs[&next.id];
        assert_eq!(state.generation, next.generation);
        assert!(state.cancel.is_some());
        assert!(!next.cancel.is_cancelled());
        assert!(state.models.is_empty());
    });
    root.update(cx, |view, _| view.connections.cancel_catalog_loads());
}

#[gpui::test]
fn reload_source_key_close_and_shutdown_discard_queued_success(cx: &mut TestAppContext) {
    for action in ["reload", "source", "key", "close", "shutdown"] {
        let (_dir, _control, window, root) = fixture(cx);
        save_fixture(window, &root, cx);
        window
            .update(cx, |view, window, cx| view.open_connections(window, cx))
            .unwrap();
        let old = pending(&root, cx);
        match action {
            "reload" => act(window, ConnectionSettingsIntent::Reload, cx),
            "source" => edit(&root, cx, |f| {
                f.catalog_url = "http://127.0.0.1:9/catalog".into()
            }),
            "key" => edit(&root, cx, |f| {
                f.key = bello_agent_core::project_authority::connections::SYNTHETIC_KEY.into()
            }),
            "close" => act(window, ConnectionSettingsIntent::Cancel, cx),
            "shutdown" => window
                .update(cx, |view, window, cx| view.begin_shutdown(window, cx))
                .unwrap(),
            _ => unreachable!(),
        }
        assert!(
            old.cancel.is_cancelled(),
            "{action} must cancel in-flight work"
        );
        stale_success(&root, &old, cx);
        cx.read(|cx| {
            assert!(
                root.read(cx)
                    .connections
                    .catalogs
                    .values()
                    .all(|state| state.models.is_empty()),
                "{action} must ignore an already queued successful response"
            )
        });
        if action == "shutdown" {
            cx.run_until_parked();
            continue;
        }
        if action == "close" {
            window
                .update(cx, |view, window, cx| view.open_connections(window, cx))
                .unwrap();
        }
        let next = pending(&root, cx);
        stale_success(&root, &old, cx);
        cx.read(|cx| {
            let state = &root.read(cx).connections.catalogs[&next.id];
            assert_eq!(state.generation, next.generation);
            assert!(state.cancel.is_some());
            assert!(!next.cancel.is_cancelled());
            assert!(state.models.is_empty());
        });
        root.update(cx, |view, _| view.connections.cancel_catalog_loads());
    }
}
