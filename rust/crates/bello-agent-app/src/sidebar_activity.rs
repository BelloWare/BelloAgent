//! Presentation holds and bounded, max-only activity write admission.
//!
//! Neither structure owns transcript state or a catalog row. Explicit pin,
//! archive, topic and creation changes therefore remain visible during a hold.
use bello_agent_core::workspace::ChatRecord;
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Default)]
pub(crate) struct SidebarActivityHold {
    pointer: bool,
    pointer_unknown: bool,
    menu: Option<uuid::Uuid>,
    // Snapshot is part of identity: a reused ID cannot inherit an old hold.
    held: BTreeMap<String, (PathBuf, u64)>,
    bounds: std::rc::Rc<std::cell::Cell<Option<gpui::Bounds<gpui::Pixels>>>>,
    events: Vec<gpui::Subscription>,
}
impl SidebarActivityHold {
    pub(crate) fn active(&self) -> bool {
        self.pointer || self.pointer_unknown || self.menu.is_some()
    }
    pub(crate) fn set_pointer(&mut self, inside: bool) -> bool {
        let was_active = self.active();
        self.pointer = inside;
        self.pointer_unknown = false;
        self.release_if_idle(was_active)
    }
    pub(crate) fn begin_menu(&mut self, token: uuid::Uuid) {
        self.menu = Some(token);
    }
    pub(crate) fn end_menu(&mut self, token: uuid::Uuid) -> bool {
        if self.menu != Some(token) {
            return false;
        }
        let was_active = self.active();
        self.menu = None;
        self.release_if_idle(was_active)
    }
    pub(crate) fn release_all(&mut self) -> bool {
        let was_active = self.active();
        self.pointer = false;
        self.pointer_unknown = false;
        self.menu = None;
        self.release_if_idle(was_active)
    }
    fn release_if_idle(&mut self, was_active: bool) -> bool {
        if self.active() || (!was_active && self.held.is_empty()) {
            return false;
        }
        self.held.clear();
        true
    }
    /// Call before merging a strictly newer activity stamp. New rows have no
    /// previous presentation key and are intentionally never hidden by a hold.
    pub(crate) fn before_activity_change(&mut self, record: &ChatRecord) {
        if self.active() {
            let entry = self
                .held
                .entry(record.id.clone())
                .or_insert_with(|| (record.snapshot.clone(), record.activity_stamp()));
            if entry.0 != record.snapshot {
                *entry = (record.snapshot.clone(), record.activity_stamp());
            }
        }
    }
    pub(crate) fn key(&self, record: &ChatRecord) -> Option<u64> {
        self.held
            .get(&record.id)
            .filter(|(snapshot, _)| snapshot == &record.snapshot)
            .map(|(_, stamp)| *stamp)
    }
    pub(crate) fn prune(&mut self, records: &[ChatRecord]) {
        self.held.retain(|id, (snapshot, _)| {
            records
                .iter()
                .any(|record| &record.id == id && &record.snapshot == snapshot)
        });
    }
}

/// One catalog write per chat. Event timestamps are captured by the Controller,
/// never by the save callback; older receipts cannot acknowledge newer activity.
#[derive(Debug, Default)]
pub(crate) struct ActivityWriteState {
    identity: Option<(String, PathBuf)>,
    pub(crate) dirty: Option<u64>,
    pub(crate) confirmed: u64,
    inflight: Option<(uuid::Uuid, u64)>,
    failures: u8,
    fenced: bool,
    pub(crate) error: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ActivityWrite {
    pub(crate) token: uuid::Uuid,
    pub(crate) stamp: u64,
}
impl ActivityWriteState {
    // Two automatic retries after the original attempt. A close/explicit flush
    // can reset this budget; render notifications cannot cause a retry loop.
    pub(crate) const MAX_FAILURES: u8 = 3;
    pub(crate) fn for_record(record: &ChatRecord) -> Self {
        Self {
            identity: Some((record.id.clone(), record.snapshot.clone())),
            confirmed: record.last_activity_at.unwrap_or(0),
            ..Self::default()
        }
    }
    /// Return whether the previous actor's final watermark still belongs to
    /// this row. A path replacement gets an independent admission generation.
    pub(crate) fn adopt_record(&mut self, record: &ChatRecord) -> bool {
        if self
            .identity
            .as_ref()
            .is_some_and(|(id, snapshot)| id == &record.id && snapshot == &record.snapshot)
        {
            return true;
        }
        *self = Self::for_record(record);
        false
    }
    pub(crate) fn observe(&mut self, stamp: u64) -> bool {
        if stamp <= self.confirmed || self.dirty.is_some_and(|dirty| stamp <= dirty) {
            return false;
        }
        self.dirty = Some(stamp);
        true
    }
    pub(crate) fn begin(&mut self, materialized: bool) -> Option<ActivityWrite> {
        if !materialized
            || self.fenced
            || self.inflight.is_some()
            || self.failures >= Self::MAX_FAILURES
        {
            return None;
        }
        let stamp = self.dirty?;
        let token = uuid::Uuid::new_v4();
        self.inflight = Some((token, stamp));
        Some(ActivityWrite { token, stamp })
    }
    pub(crate) fn confirm(&mut self, write: ActivityWrite, saved: u64) -> bool {
        if self.inflight != Some((write.token, write.stamp)) {
            return false;
        }
        self.inflight = None;
        self.acknowledge(saved);
        self.failures = 0;
        true
    }
    /// Registration captures its own stamp. It can acknowledge that stamp only,
    /// including when a newer event arrived before registration completed.
    pub(crate) fn acknowledge(&mut self, saved: u64) {
        self.confirmed = self.confirmed.max(saved);
        if self.dirty.is_some_and(|dirty| dirty <= self.confirmed) {
            self.dirty = None;
        }
    }
    pub(crate) fn fail(&mut self, write: ActivityWrite, uncertain: bool) -> bool {
        // Uncertainty belongs to the workspace even for a stale operation.
        self.fenced |= uncertain;
        if self.inflight != Some((write.token, write.stamp)) {
            return false;
        }
        self.inflight = None;
        self.failures = self.failures.saturating_add(1);
        true
    }
    pub(crate) fn flush(&mut self) {
        self.failures = 0;
    }
    pub(crate) fn is_pending(&self) -> bool {
        self.dirty.is_some() || self.inflight.is_some()
    }
}

#[cfg(test)]
#[path = "sidebar_activity_tests.rs"]
mod tests;

use crate::{AgentView, chat_organization::catalog_operation};
use bello_agent_core::{Controller, runtime::SemanticActivity, workspace::WorkspaceStore};
use gpui::{Context, Div, IntoElement, Task, Window, canvas};
use gpui::{Pixels, Point};
use std::sync::{Arc, Mutex, Weak};

/// Capture a known matching actor at construction/retirement boundaries before
/// baselining its watch receiver. Empty recovered watermarks remain neutral.
pub(crate) fn capture_current(
    record: &mut ChatRecord,
    state: &mut ActivityWriteState,
    controller: &Controller,
) {
    if let Some(stamp) = controller.activity().timestamp_micros {
        state.observe(stamp);
        if stamp > record.last_activity_at.unwrap_or(0) {
            record.last_activity_at = Some(stamp);
        }
    }
}

/// Subscribe independently from Session snapshots: watch coalescing may hide an
/// entire start/finish transition from the presentation stream.
pub(crate) fn subscribe(
    controller: &Arc<Controller>,
    record: &ChatRecord,
    workspace: Arc<Mutex<WorkspaceStore>>,
    cx: &mut Context<AgentView>,
) -> Task<()> {
    let mut updates = controller.subscribe_activity();
    // Actor construction/recovery starts at an empty watermark. Baseline a
    // replacement explicitly rather than promoting historical session data.
    let initial = *updates.borrow_and_update();
    let source = Arc::downgrade(controller);
    let id = record.id.clone();
    let snapshot = record.snapshot.clone();
    cx.spawn(async move |owner, cx| {
        // Deliver the exact subscribed baseline too. An event can occur between
        // constructor capture_current and receiver creation; discarding this
        // value would lose that event if no later publication occurs.
        if owner
            .update(cx, |view, cx| {
                view.receive_activity(&workspace, &id, &snapshot, &source, initial, cx);
            })
            .is_err()
        {
            return;
        }
        while updates.changed().await.is_ok() {
            let activity = *updates.borrow_and_update();
            if owner
                .update(cx, |view, cx| {
                    view.receive_activity(&workspace, &id, &snapshot, &source, activity, cx);
                })
                .is_err()
            {
                break;
            }
        }
    })
}

impl AgentView {
    fn receive_activity(
        &mut self,
        workspace: &Arc<Mutex<WorkspaceStore>>,
        id: &str,
        snapshot: &std::path::Path,
        source: &Weak<Controller>,
        activity: SemanticActivity,
        cx: &mut Context<Self>,
    ) {
        if !Arc::ptr_eq(workspace, &self.workspace)
            || self.chat_ref(id).is_none_or(|chat| {
                chat.record.snapshot != snapshot
                    || !source.ptr_eq(&Arc::downgrade(&chat.controller))
            })
        {
            return;
        }
        let Some(stamp) = activity.timestamp_micros else {
            return;
        };
        let changed = self
            .chat_mut(id)
            .is_some_and(|chat| chat.activity_write.observe(stamp));
        if !changed {
            return;
        }
        self.merge_activity(id, snapshot, stamp);
        self.request_activity_drain(cx);
        cx.notify();
    }

    fn merge_activity(&mut self, id: &str, snapshot: &std::path::Path, stamp: u64) {
        if let Some(record) = self
            .records
            .iter_mut()
            .find(|record| record.id == id && record.snapshot == snapshot)
            && stamp > record.last_activity_at.unwrap_or(0)
        {
            if stamp > record.activity_stamp() {
                self.sidebar_activity_hold.before_activity_change(record);
            }
            record.last_activity_at = Some(stamp);
        }
        if let Some(chat) = self.chat_mut(id)
            && chat.record.snapshot == snapshot
            && stamp > chat.record.last_activity_at.unwrap_or(0)
        {
            chat.record.last_activity_at = Some(stamp);
        }
    }

    pub(crate) fn request_activity_drain(&mut self, cx: &mut Context<Self>) {
        if self.shutting_down || self.known_catalog_uncertainty {
            return;
        }
        self.sidebar_activity_hold.prune(&self.records);
        // Controller replacement may capture the outgoing actor's final event
        // before its watch callback runs. Publish that max-only column here.
        let captured: Vec<_> = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .filter_map(|chat| {
                chat.record
                    .last_activity_at
                    .map(|stamp| (chat.record.id.clone(), chat.record.snapshot.clone(), stamp))
            })
            .collect();
        for (id, snapshot, stamp) in captured {
            self.merge_activity(&id, &snapshot, stamp);
        }
        let mut work = Vec::new();
        for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
            if let Some(write) = chat.activity_write.begin(!chat.pending) {
                work.push((
                    chat.record.id.clone(),
                    chat.record.snapshot.clone(),
                    Arc::downgrade(&chat.controller),
                    write,
                ));
            }
        }
        for (id, snapshot, source, write) in work {
            let workspace = self.workspace.clone();
            let saved_workspace = workspace.clone();
            let saved_id = id.clone();
            let saved_snapshot = snapshot.clone();
            let task = cx.background_executor().spawn(async move {
                catalog_operation(&workspace, |store| {
                    store.record_activity(&saved_id, &saved_snapshot, write.stamp)
                })
            });
            cx.spawn(async move |owner, cx| {
                let outcome = task.await;
                let _ = owner.update(cx, |view, cx| {
                    // Observe uncertainty before checking actor or row liveness.
                    // The admission fence belongs to this exact workspace.
                    if !Arc::ptr_eq(&saved_workspace, &view.workspace) {
                        return;
                    }
                    view.observe_catalog_uncertainty(outcome.uncertain, cx);
                    let Some(chat) = view
                        .chat_mut(&id)
                        .filter(|chat| chat.record.snapshot == snapshot)
                    else {
                        return;
                    };
                    let current = source.ptr_eq(&Arc::downgrade(&chat.controller));
                    match outcome.result {
                        Ok(receipt) => {
                            let stamp = receipt.last_activity_at.unwrap_or(0);
                            if chat.activity_write.confirm(write, stamp) && current {
                                if let Some(error) = chat.activity_write.error.take()
                                    && chat.error.as_ref() == Some(&error)
                                {
                                    chat.error = None;
                                }
                                view.merge_activity(&id, &snapshot, stamp);
                            }
                        }
                        Err(error) => {
                            if chat.activity_write.fail(write, outcome.uncertain) && current {
                                let message = format!(
                                    "Chat activity could not be saved: {}",
                                    crate::chat_organization::catalog_error(
                                        &error,
                                        outcome.uncertain
                                    )
                                );
                                chat.activity_write.error = Some(message.clone());
                                chat.error = Some(message);
                            }
                        }
                    }
                    view.request_activity_drain(cx);
                    cx.notify();
                });
            })
            .detach();
        }
    }
}

impl AgentView {
    pub(crate) fn bind_activity_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_activity_hold.release_all();
        self.sidebar_activity_hold.bounds.set(None);
        // Until initial layout gives a list hitbox, conservatively retain an
        // active window's pointer reason. Activity may arrive before first paint.
        self.sidebar_activity_hold.pointer_unknown = window.is_window_active();
        let binding = self.window_binding;
        let handle = window.window_handle();
        let activation = cx.observe_window_activation(window, move |view, window, cx| {
            if view.window_binding != binding {
                return;
            }
            if !window.is_window_active() {
                view.sidebar_activity_hold.release_all();
                view.sidebar_menu = None;
                cx.notify();
            } else {
                // External source writers may have changed old negative results
                // while this window was inactive. Start a full fresh query pass.
                view.sidebar_search.cancel();
                // GPUI does not refresh its cached pointer on activation.
                // Unknown is conservative, not a claim of list hover. Native
                // queries or the next actual mouse event resolve it.
                view.sidebar_activity_hold.pointer_unknown = true;
                // Activation observers run before GPUI refreshes window bounds.
                // Resolve against the next measured layout, not stale geometry.
                view.sidebar_activity_hold.bounds.set(None);
            }
        });
        let resized = cx.observe_window_bounds(window, move |view, window, _| {
            if view.window_binding == binding {
                view.sidebar_activity_hold.bounds.set(None);
                if window.is_window_active() {
                    view.sidebar_activity_hold.pointer_unknown = true;
                }
            }
        });
        let owner = cx.weak_entity();
        let closed = cx.on_window_closed(move |cx| {
            if cx
                .windows()
                .iter()
                .any(|open| open.window_id() == handle.window_id())
            {
                return;
            }
            let _ = owner.update(cx, |view, cx| {
                if view.window_binding == binding {
                    view.window_binding = None;
                    view.sidebar_search.cancel();
                    view.cancel_sidebar_reveal(cx);
                    // Cancellation does not release the in-flight owner; the
                    // detached worker still owns its permit until it exits.
                    view.sidebar_run_states.cancel_pending();
                    view.sidebar_activity_hold.release_all();
                    view.sidebar_activity_hold.bounds.set(None);
                    view.sidebar_menu = None;
                    cx.notify();
                }
            });
        });
        self.sidebar_activity_hold.events = vec![activation, resized, closed];
    }

    /// The native helper supplies a newly queried AppKit pointer. None is
    /// unknown, never proof that the pointer left the list during menu tracking.
    pub(crate) fn recheck_sidebar_pointer(&mut self, fresh: Option<Point<Pixels>>) {
        if let (Some(position), Some(bounds)) = (fresh, self.sidebar_activity_hold.bounds.get()) {
            self.sidebar_activity_hold
                .set_pointer(bounds.contains(&position));
        }
    }

    fn sidebar_pointer_moved(
        &mut self,
        binding: Option<crate::workspace_lifetime::WindowBinding>,
        measured: gpui::Bounds<Pixels>,
        position: Point<Pixels>,
        active: bool,
    ) -> bool {
        if self.window_binding != binding
            || self.sidebar_activity_hold.bounds.get() != Some(measured)
        {
            return false;
        }
        self.sidebar_activity_hold
            .set_pointer(active && measured.contains(&position))
    }

    pub(crate) fn activity_held_sidebar_list(
        &self,
        list: Div,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        use gpui::prelude::*;
        let bounds = self.sidebar_activity_hold.bounds.clone();
        let initial_owner = cx.weak_entity();
        let move_owner = cx.weak_entity();
        let binding = self.window_binding;
        list.id("sidebar-activity-list")
            .debug_selector(|| "sidebar-activity-list".into())
            .relative()
            .on_hover(cx.listener(|view, inside, window, _| {
                if *inside && window.is_window_active() {
                    view.sidebar_activity_hold.set_pointer(true);
                }
            }))
            .child(
                canvas(
                    move |measured, window, cx| {
                        let first_layout = bounds.replace(Some(measured)).is_none();
                        if first_layout {
                            let owner = initial_owner.clone();
                            window.defer(cx, move |window, cx| {
                                let _ = owner.update(cx, |view, cx| {
                                    if view.window_binding == binding && view.sidebar_menu.is_none()
                                    {
                                        // A rebind can reuse a Window whose cached position
                                        // is stale. Never resolve Unknown from that cache.
                                        #[cfg(target_os = "macos")]
                                        {
                                            let pointer =
                                                crate::native_menu::current_sidebar_pointer(
                                                    window.window_handle(),
                                                    cx,
                                                );
                                            view.recheck_sidebar_pointer(pointer);
                                            cx.notify();
                                        }
                                        #[cfg(not(target_os = "macos"))]
                                        let _ = (window, cx);
                                    }
                                });
                            });
                        }
                    },
                    move |measured, _, window, _| {
                        let owner = move_owner.clone();
                        // Use every fresh mouse move, not only GPUI hover transitions:
                        // after background/reset its previous hover boolean can remain
                        // true and a move within the list would emit no on_hover callback.
                        window.on_mouse_event(
                            move |event: &gpui::MouseMoveEvent, phase, window, cx| {
                                if phase != gpui::DispatchPhase::Capture {
                                    return;
                                }
                                let _ = owner.update(cx, |view, cx| {
                                    if view.sidebar_pointer_moved(
                                        binding,
                                        measured,
                                        event.position,
                                        window.is_window_active(),
                                    ) {
                                        cx.notify();
                                    }
                                });
                            },
                        );
                    },
                )
                .absolute()
                .inset_0(),
            )
    }
}

impl AgentView {
    /// Connection retirement can finish after an activity event. Preserve just
    /// that newer column on matching identity; do not alter the switch gates or
    /// borrow activity from a replacement snapshot.
    pub(crate) fn preserve_connection_activity(&self, saved: &mut ChatRecord) {
        let latest = self
            .records
            .iter()
            .chain(self.chat_ref(&saved.id).map(|chat| &chat.record))
            .filter(|record| record.id == saved.id && record.snapshot == saved.snapshot)
            .filter_map(|record| record.last_activity_at)
            .max();
        saved.last_activity_at = saved.last_activity_at.max(latest);
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
impl AgentView {
    pub(crate) fn test_activity_event(&mut self, id: &str, stamp: u64, cx: &mut Context<Self>) {
        let chat = self.chat_ref(id).unwrap();
        let snapshot = chat.record.snapshot.clone();
        let source = Arc::downgrade(&chat.controller);
        let workspace = self.workspace.clone();
        self.receive_activity(
            &workspace,
            id,
            &snapshot,
            &source,
            SemanticActivity {
                sequence: 1,
                timestamp_micros: Some(stamp),
            },
            cx,
        );
    }
}
