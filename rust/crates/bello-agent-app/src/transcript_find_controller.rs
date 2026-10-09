//! Selected loaded-conversation Find. No actor mutation, storage or provider work.
use crate::{
    AgentView,
    conversation_content::Snapshot,
    conversation_content_controller::Target,
    transcript_find_search::Query,
    transcript_find_state::{Destination, FindState, Ticket},
};
use bello_agent_core::retained_find::FindSnapshot;
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

#[cfg(test)]
thread_local! {
    static FIND_COMPLETION_DELAYS: std::cell::Cell<(u64, u64)> = const { std::cell::Cell::new((0, 0)) };
}
#[cfg(test)]
pub(crate) fn set_find_completion_delays(page_ms: u64, preparation_ms: u64) {
    FIND_COMPLETION_DELAYS.with(|v| v.set((page_ms, preparation_ms)));
}

pub(crate) struct FindBar {
    pub target: Target,
    pub identity: uuid::Uuid,
    pub binding: FindSnapshot,
    pub state: FindState,
    pub query: Entity<EditorView>,
    pub snapshot: Option<Snapshot>,
    pub matcher: Option<Arc<Query>>,
    pub serial: u64,
    pub notice: Option<String>,
    pub checked_session: Arc<bello_agent_core::Session>,
    pub destination: Option<Destination>,
    pending_navigation: bool,
    composing: bool,
    awaiting_display: bool,
    paint_operation: uuid::Uuid,
    paint_cancel: Arc<AtomicBool>,
    lifetime_cancel: Arc<AtomicBool>,
    _events: Subscription,
    _query_observer: Subscription,
}
impl Drop for FindBar {
    fn drop(&mut self) {
        self.paint_cancel.store(true, Ordering::Release);
        self.lifetime_cancel.store(true, Ordering::Release);
    }
}
impl AgentView {
    pub(crate) fn show_transcript_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let target = Target::capture(self);
        let Some(binding) = self.controller.find_snapshot() else {
            self.error = Some(
                "Find is unavailable because the conversation snapshot could not be verified."
                    .into(),
            );
            cx.notify();
            return;
        };
        if !target.matches(self) || self.composer.read(cx).has_marked_text() {
            return;
        }
        if self
            .transcript_find
            .as_ref()
            .is_some_and(|bar| !bar.target.matches(self))
        {
            self.clear_transcript_find(cx);
        }
        if self.transcript_find.is_none() {
            let palette = self.palette;
            let query = cx.new(|cx| {
                let mut editor = EditorView::new(String::new(), window, cx);
                editor.set_composer_mode(cx);
                editor.set_appearance(Self::composer_style(palette), cx);
                editor
            });
            let events = cx.subscribe(&query, |view, _, event, cx| {
                if matches!(event, EditorEvent::Changed) {
                    view.transcript_find_query_changed(cx);
                }
            });
            let query_observer =
                cx.observe(&query, |view, _, cx| view.transcript_find_query_changed(cx));
            let mut state = FindState::default();
            state.show();
            self.transcript_find = Some(FindBar {
                target,
                identity: uuid::Uuid::new_v4(),
                binding: binding.clone(),
                state,
                query,
                snapshot: None,
                matcher: None,
                serial: 0,
                notice: None,
                checked_session: binding.session_shared(),
                destination: None,
                pending_navigation: false,
                composing: false,
                awaiting_display: false,
                paint_operation: uuid::Uuid::new_v4(),
                paint_cancel: Arc::new(AtomicBool::new(false)),
                lifetime_cancel: Arc::new(AtomicBool::new(false)),
                _events: events,
                _query_observer: query_observer,
            });
        }
        if let Some(bar) = &self.transcript_find {
            bar.query.read(cx).focus(window);
            bar.query.update(cx, |e, cx| {
                let _ = e.select_all(cx);
            });
        }
        cx.notify();
    }
    pub(crate) fn clear_transcript_find(&mut self, cx: &mut Context<Self>) {
        let Some(mut bar) = self.transcript_find.take() else {
            return;
        };
        bar.state.close();
        let old_identity = bar.identity;
        if let Some(transcript) = self.transcript.clone() {
            // Tool callbacks can already hold the transcript entity. Clear after
            // that borrow ends, and never erase a newly reopened Find session.
            let owner = cx.weak_entity();
            cx.defer(move |cx| {
                let _ = owner.update(cx, |view, cx| {
                    if view
                        .transcript
                        .as_ref()
                        .is_some_and(|current| current.entity_id() == transcript.entity_id())
                    {
                        transcript.update(cx, |view, cx| view.clear_find_owner(old_identity, cx));
                    }
                });
            });
        }
        cx.notify();
    }
    pub(crate) fn close_transcript_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let focused = self
            .transcript_find
            .as_ref()
            .is_some_and(|bar| bar.query.read(cx).focus_handle(cx).is_focused(window));
        self.clear_transcript_find(cx);
        if focused && let Some(transcript) = &self.transcript {
            transcript.read(cx).focus_fallback(window);
        }
    }
    pub(crate) fn refresh_find_content(&mut self, cx: &mut Context<Self>) {
        let Some(bar) = self.transcript_find.as_ref() else {
            return;
        };
        if !bar.target.matches(self) {
            self.clear_transcript_find(cx);
            return;
        }
        let Some(current) = self.controller.find_snapshot() else {
            self.error = Some(
                "Find is unavailable because the conversation snapshot could not be verified."
                    .into(),
            );
            self.clear_transcript_find(cx);
            return;
        };
        let changed = !bar.binding.same_content(&current);
        let bar = self.transcript_find.as_mut().unwrap();
        bar.checked_session = current.session_shared();
        let repaint = bar.awaiting_display;
        bar.binding = current.clone();
        if changed {
            bar.binding = current;
            bar.notice = None;
            bar.matcher = None;
            bar.destination = None;
            bar.paint_cancel.store(true, Ordering::Release);
            bar.paint_operation = uuid::Uuid::new_v4();
            let ticket = bar.state.restart();
            if let Some(transcript) = self.transcript.clone() {
                transcript.update(cx, |v, cx| v.set_find(None, cx));
            }
            if let Some(ticket) = ticket {
                self.begin_find_search(ticket, cx);
            }
            cx.notify();
        } else if repaint
            && self
                .display_find_binding
                .as_ref()
                .is_some_and(|b| current.same_content(b))
        {
            self.publish_find(None, cx);
        }
    }
    fn transcript_find_query_changed(&mut self, cx: &mut Context<Self>) {
        let Some(bar) = &mut self.transcript_find else {
            return;
        };
        if bar.query.read(cx).has_marked_text() {
            if !bar.composing {
                let _ = bar.state.restart();
            }
            bar.composing = true;
            bar.pending_navigation = false;
            bar.state.abandon_navigation();
            bar.destination = None;
            bar.paint_cancel.store(true, Ordering::Release);
            bar.paint_operation = uuid::Uuid::new_v4();
            return;
        }
        let query = bar.query.read(cx).text().to_owned();
        let was_composing = std::mem::take(&mut bar.composing);
        if bar.state.query == query && !was_composing {
            return;
        }
        let ticket = if bar.state.query == query {
            bar.state.restart()
        } else {
            bar.state.set_query(query)
        };
        bar.paint_cancel.store(true, Ordering::Release);
        bar.paint_operation = uuid::Uuid::new_v4();
        bar.notice = None;
        bar.destination = None;
        bar.matcher = None;
        bar.snapshot = None;
        if let Some(transcript) = self.transcript.clone() {
            transcript.update(cx, |v, cx| v.set_find(None, cx));
        }
        if let Some(ticket) = ticket {
            self.begin_find_search(ticket, cx);
        }
        cx.notify();
    }
    fn begin_find_search(&mut self, ticket: Ticket, cx: &mut Context<Self>) {
        let Some(binding) = self.controller.find_snapshot() else {
            self.error = Some(
                "Find is unavailable because the conversation snapshot could not be verified."
                    .into(),
            );
            cx.notify();
            return;
        };
        let current = binding.session_shared();
        let Some(bar) = &mut self.transcript_find else {
            return;
        };
        if bar.composing {
            return;
        }
        bar.binding = binding.clone();
        let snapshot = Snapshot::new(current.clone());
        bar.snapshot = Some(snapshot.clone());
        bar.checked_session = current;
        let query = bar.state.query.clone();
        let check = ticket.clone();
        let timer = cx.background_executor().timer(Duration::from_millis(150));
        cx.spawn(async move |view, cx| {
            timer.await;
            let _ = view.update(cx, |view, cx| {
                if view.find_completion_current(&check, &binding, cx).is_none() {
                    view.refresh_find_content(cx);
                    return;
                }
                view.search_find_page(check, snapshot, binding, query, 0, cx);
            });
        })
        .detach();
    }
    fn find_completion_current(
        &mut self,
        ticket: &Ticket,
        binding: &FindSnapshot,
        cx: &App,
    ) -> Option<FindSnapshot> {
        let bar = self.transcript_find.as_ref()?;
        if bar.composing
            || bar.query.read(cx).has_marked_text()
            || !bar.state.accepts(ticket)
            || !bar.target.matches(self)
        {
            return None;
        }
        self.controller
            .find_snapshot()
            .filter(|current| binding.same_content(current))
    }
    fn search_find_page(
        &mut self,
        ticket: Ticket,
        snapshot: Snapshot,
        binding: FindSnapshot,
        query: String,
        start: usize,
        cx: &mut Context<Self>,
    ) {
        let worker = snapshot.clone();
        let check = ticket.clone();
        let needle = query.clone();
        let task = cx.background_executor().spawn(async move {
            let matcher = Query::new(&needle, check.cancellation())?;
            worker
                .search_cancelled(&needle, start, check.cancellation())
                .map(|page| (page, matcher))
        });
        #[cfg(test)]
        let delay = cx.background_executor().timer(Duration::from_millis(
            FIND_COMPLETION_DELAYS.with(|v| v.get().0),
        ));
        cx.spawn(async move |view, cx| {
            let result = task.await;
            #[cfg(test)]
            delay.await;
            let _ = view.update(cx, |view, cx| {
                let Some(current) = view.find_completion_current(&ticket, &binding, cx) else {
                    view.refresh_find_content(cx);
                    cx.notify();
                    return;
                };
                let bar = view.transcript_find.as_mut().unwrap();
                bar.checked_session = current.session_shared();
                let visible = view
                    .transcript
                    .as_ref()
                    .map(|v| v.read(cx).find_visible_ids())
                    .unwrap_or_default();
                let bar = view.transcript_find.as_mut().unwrap();
                let first = bar.state.current().is_none();
                match result {
                    Ok((page, matcher)) => {
                        bar.matcher = Some(Arc::new(matcher));
                        if let Err(error) = bar.state.append(&ticket, start, page, &visible) {
                            bar.notice = Some(error);
                        }
                    }
                    Err(error) => {
                        bar.state.fail(&ticket);
                        bar.notice = Some(error);
                    }
                }
                let destination = first.then(|| bar.state.destination()).flatten();
                let next = bar.state.next_page();
                view.publish_find(destination, cx);
                if let Some(next) = next {
                    view.search_find_page(ticket, snapshot, binding, query, next, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(crate) fn step_transcript_find(&mut self, previous: bool, cx: &mut Context<Self>) {
        let Some(bar) = self.transcript_find.as_ref() else {
            return;
        };
        if !bar.target.matches(self) || bar.query.read(cx).has_marked_text() {
            return;
        }
        if !self
            .controller
            .find_snapshot()
            .is_some_and(|current| bar.binding.same_content(&current))
        {
            self.refresh_find_content(cx);
            return;
        }
        let destination = self.transcript_find.as_mut().unwrap().state.step(previous);
        self.publish_find(destination, cx);
        cx.notify();
    }
    fn publish_find(&mut self, destination: Option<Destination>, cx: &mut Context<Self>) {
        let visible = self
            .transcript
            .as_ref()
            .map(|t| t.read(cx).find_visible_ids())
            .unwrap_or_default();
        let Some(bar) = self.transcript_find.as_mut() else {
            return;
        };
        if bar.composing {
            return;
        }
        let Some(matcher) = bar.matcher.clone() else {
            return;
        };
        let navigate = destination.is_some() || bar.pending_navigation;
        bar.pending_navigation = navigate;
        if let Some(destination) = destination {
            bar.serial = bar.serial.saturating_add(1);
            bar.destination = Some(destination);
        }
        let destination = bar
            .destination
            .clone()
            .filter(|d| bar.state.accepts_destination(d));
        let current = bar.state.current();
        let mut wanted = Vec::new();
        if let Some(found) = &current {
            wanted.push(found.id.clone());
        }
        wanted.extend(
            bar.state
                .groups()
                .iter()
                .filter(|g| {
                    visible.contains(&g.id) && !current.as_ref().is_some_and(|m| m.id == g.id)
                })
                .take(63)
                .map(|g| g.id.clone()),
        );
        bar.paint_cancel.store(true, Ordering::Release);
        bar.paint_cancel = Arc::new(AtomicBool::new(false));
        let cancel = bar.paint_cancel.clone();
        let operation = uuid::Uuid::new_v4();
        bar.paint_operation = operation;
        let identity = bar.identity;
        let lifetime_cancel = bar.lifetime_cancel.clone();
        let target = bar.target.clone();
        let serial = bar.serial;
        let source = bar.binding.clone();
        let selected = current.clone();
        let task = cx.background_executor().spawn(async move {
            crate::transcript_find_presentation::prepare(
                &matcher,
                source,
                wanted,
                selected.as_ref(),
                &cancel,
            )
        });
        #[cfg(test)]
        let delay = cx.background_executor().timer(Duration::from_millis(
            FIND_COMPLETION_DELAYS.with(|v| v.get().1),
        ));
        cx.spawn(async move |view, cx| {
            let result = task.await;
            #[cfg(test)]
            delay.await;
            let _ = view.update(cx, |view, cx| {
                let Some(bar) = view.transcript_find.as_ref() else {
                    return;
                };
                if bar.composing
                    || bar.query.read(cx).has_marked_text()
                    || bar.identity != identity
                    || bar.paint_operation != operation
                    || !target.matches(view)
                {
                    return;
                }
                let prepared = match result {
                    Ok(p) => p,
                    Err(error) => {
                        view.transcript_find.as_mut().unwrap().notice = Some(error);
                        cx.notify();
                        return;
                    }
                };
                let paint = crate::transcript_find_presentation::FindPaint::new(
                    prepared,
                    current,
                    destination.clone(),
                    serial,
                    identity,
                    lifetime_cancel,
                );
                if !view
                    .controller
                    .find_snapshot()
                    .is_some_and(|b| paint.matches_binding(Some(&b)))
                {
                    view.refresh_find_content(cx);
                    return;
                }
                if !paint.matches_binding(view.transcript_input().find_binding.as_ref()) {
                    view.transcript_find.as_mut().unwrap().awaiting_display = true;
                    return;
                }
                if let Some(destination) = &destination
                    && navigate
                {
                    if !bar.state.accepts_destination(destination) {
                        return;
                    }
                    if let Some(index) = view
                        .session
                        .messages
                        .iter()
                        .position(|m| m.id == destination.found.id)
                    {
                        view.visible_messages = view
                            .visible_messages
                            .max(view.session.messages.len() - index);
                    }
                }
                view.transcript_find.as_mut().unwrap().awaiting_display = false;
                view.transcript_find.as_mut().unwrap().pending_navigation = false;
                view.refresh_find_content(cx);
                view.sync_transcript_inputs(cx);
                if let Some(transcript) = view.transcript.clone() {
                    let input = view.transcript_input();
                    let ok =
                        transcript.update(cx, |t, cx| t.reveal_find(input, paint, navigate, cx));
                    if !ok && let Some(destination) = destination {
                        view.transcript_find
                            .as_mut()
                            .unwrap()
                            .state
                            .landing_failed(&destination);
                    }
                }
                if navigate {
                    view.bound_find_wait(identity, serial, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn bound_find_wait(&mut self, identity: uuid::Uuid, serial: u64, cx: &mut Context<Self>) {
        let timer = cx.background_executor().timer(Duration::from_millis(500));
        cx.spawn(async move |view,cx| {
            timer.await;
            let _ = view.update(cx,|view,cx| {
                if !view.transcript_find.as_ref().is_some_and(|b| b.identity == identity && b.serial == serial) { return; }
                if let Some(transcript) = view.transcript.clone()
                    && let Some(destination) = transcript.update(cx,|t,cx| t.finish_find_wait(serial,cx)) {
                    view.find_landing_notice(&destination,"Exact preview geometry was unavailable; showing the matching row. Choose the match again to retry.".into(),cx);
                }
            });
        }).detach();
    }
    pub(crate) fn refresh_find_viewport(&mut self, cx: &mut Context<Self>) {
        self.publish_find(None, cx);
    }
    pub(crate) fn abandon_find_navigation(&mut self) {
        if let Some(bar) = &mut self.transcript_find {
            bar.state.abandon_navigation();
            bar.destination = None;
            bar.pending_navigation = false;
        }
    }
    pub(crate) fn find_render_count(
        &mut self,
        destination: &Destination,
        count: usize,
        cx: &mut Context<Self>,
    ) {
        let Some(bar) = &mut self.transcript_find else {
            return;
        };
        if bar.state.accepts_destination(destination)
            && let Ok(true) = bar
                .state
                .reconcile(&destination.search, &destination.found.id, count)
        {
            let next = bar.state.destination();
            self.publish_find(next, cx);
            cx.notify();
        }
    }
    pub(crate) fn find_landing_notice(
        &mut self,
        destination: &Destination,
        notice: String,
        cx: &mut Context<Self>,
    ) {
        if let Some(bar) = &mut self.transcript_find
            && bar.state.accepts_destination(destination)
            && bar.notice.as_ref() != Some(&notice)
        {
            bar.notice = Some(notice);
            cx.notify();
        }
    }
    pub(crate) fn transcript_find_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let mods = event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        let editable_file = self
            .files
            .iter()
            .any(|f| f.view.read(cx).has_focused_editable_text(window, cx));
        if editable_file {
            return false;
        }
        if command && mods.alt && !mods.shift && !mods.function && event.keystroke.key == "f" {
            self.open_conversation_content(window, cx);
            cx.stop_propagation();
            return true;
        }
        if command && !mods.alt && !mods.function && event.keystroke.key == "f" {
            self.show_transcript_find(window, cx);
            cx.stop_propagation();
            return true;
        }
        if command && !mods.alt && !mods.function && event.keystroke.key == "g" {
            if self.transcript_find.is_some() {
                self.step_transcript_find(mods.shift, cx);
                cx.stop_propagation();
                return true;
            }
            if !mods.shift {
                self.show_transcript_find(window, cx);
                cx.stop_propagation();
                return true;
            }
        }
        let focused = self
            .transcript_find
            .as_ref()
            .is_some_and(|bar| bar.query.read(cx).focus_handle(cx).is_focused(window));
        if !focused {
            if matches!(
                event.keystroke.key.as_str(),
                "home" | "end" | "pageup" | "pagedown" | "up" | "down" | "space"
            ) && self.transcript.as_ref().is_some_and(|t| {
                t.read(cx)
                    .owned_focus_handles(cx)
                    .iter()
                    .any(|f| f.is_focused(window))
            }) {
                self.abandon_find_navigation();
                if let Some(transcript) = self.transcript.clone() {
                    transcript.update(cx, |t, cx| t.cancel_find_navigation(cx));
                }
            }
            return false;
        }
        if self
            .transcript_find
            .as_ref()
            .unwrap()
            .query
            .read(cx)
            .has_marked_text()
        {
            return false;
        }
        match event.keystroke.key.as_str() {
            "escape" => self.close_transcript_find(window, cx),
            "enter" => self.step_transcript_find(mods.shift, cx),
            _ => return false,
        }
        cx.stop_propagation();
        true
    }
    pub(crate) fn find_bar_element(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let bar = self.transcript_find.as_ref()?;
        let query = bar.query.clone();
        let label = bar.state.label();
        let notice = bar.notice.clone();
        let p = self.palette;
        Some(
            div()
                .w_full()
                .flex_shrink_0()
                .flex()
                .justify_end()
                .pt(px(6.))
                .pr(px(14.))
                .child(
                    div()
                        .id("conversation-find-bar")
                        .debug_selector(|| "conversation-find-bar".into())
                        .w(px(420.))
                        .max_w_full()
                        .p(px(6.))
                        .rounded(px(10.))
                        .bg(rgb(p.surface))
                        .border_1()
                        .border_color(p.hairline())
                        .flex()
                        .flex_col()
                        .gap(px(3.))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .child(div().h(px(32.)).flex_1().min_w_0().child(query))
                                .child(div().text_size(px(11.)).child(label))
                                .child(self.button("find-previous", "↑").on_click(
                                    cx.listener(|v, _, _, cx| v.step_transcript_find(true, cx)),
                                ))
                                .child(self.button("find-next", "↓").on_click(
                                    cx.listener(|v, _, _, cx| v.step_transcript_find(false, cx)),
                                ))
                                .child(self.button("find-close", "×").on_click(
                                    cx.listener(|v, _, w, cx| v.close_transcript_find(w, cx)),
                                )),
                        )
                        .when_some(notice, |d, text| {
                            d.child(div().text_size(px(11.)).child(text))
                        }),
                )
                .into_any_element(),
        )
    }
}
