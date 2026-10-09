//! Explicit-open reveal tickets. Never use excerpts as source locators and never
//! open/recover a Controller while merely typing a sidebar query.
use crate::{AgentView, conversation_content_controller::Target};
use bello_agent_core::sidebar_search::{
    LoadedSearchEvidence, OwnedHit, SearchAdmissionSlot, SearchOutcome, SearchRequest,
};
use gpui::{Context, Window};
use std::sync::Arc;
use uuid::Uuid;

#[cfg(test)]
thread_local! {
    static REVEAL_DELAY_MS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}
#[cfg(all(test, target_os = "linux", feature = "synthetic-authority"))]
pub(crate) fn set_reveal_delay(milliseconds: u64) {
    REVEAL_DELAY_MS.with(|delay| delay.set(milliseconds));
}

#[derive(Clone)]
pub(crate) struct SearchTicket {
    chat: String,
    epoch: Uuid,
    query: String,
    hit: OwnedHit,
}
pub(crate) struct PendingReveal {
    ticket: SearchTicket,
    operation: Uuid,
    dispatched: bool,
    request: SearchRequest,
    preparation_cancel: Arc<std::sync::atomic::AtomicBool>,
    retries: u8,
    navigation_completed: std::rc::Rc<std::cell::Cell<bool>>,
}
impl Drop for PendingReveal {
    fn drop(&mut self) {
        self.preparation_cancel
            .store(true, std::sync::atomic::Ordering::Release);
        self.request.cancel();
    }
}
impl AgentView {
    pub(crate) fn cancel_sidebar_reveal(&mut self, cx: &mut Context<Self>) {
        self.sidebar_search_reveal = None;
        if let Some(transcript) = self.transcript.clone() {
            transcript.update(cx, |view, cx| view.clear_sidebar_search(cx));
        }
    }
    pub(crate) fn suspend_sidebar_cache_reveal(&mut self, cx: &mut Context<Self>) {
        // A normal selected-open may wait for its own load/cleanup. Already
        // dispatched work and painted ranges lose admission immediately.
        if let Some(pending) = &mut self.sidebar_search_reveal
            && pending.dispatched
        {
            pending
                .preparation_cancel
                .store(true, std::sync::atomic::Ordering::Release);
            pending.preparation_cancel = Arc::new(std::sync::atomic::AtomicBool::new(false));
            pending.operation = Uuid::new_v4();
            pending.dispatched = false;
        }
        if let Some(transcript) = self.transcript.clone() {
            transcript.update(cx, |view, cx| view.clear_sidebar_search(cx));
        }
    }
    pub(crate) fn sidebar_search_ticket(&self, id: &str) -> Option<SearchTicket> {
        Some(SearchTicket {
            chat: id.into(),
            epoch: self.sidebar_search.epoch,
            query: self.sidebar_search.query.clone(),
            hit: self.sidebar_content_hit(id)?.clone(),
        })
    }
    pub(crate) fn open_sidebar_result(
        &mut self,
        id: &str,
        ticket: Option<SearchTicket>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.filter.read(cx).has_marked_text() {
            return;
        }
        if let Some(ticket) = &ticket
            && (ticket.chat != id
                || self.filter.read(cx).text() != ticket.query
                || ticket.epoch != self.sidebar_search.epoch
                || self.sidebar_content_hit(id).is_none())
        {
            return;
        }
        self.sidebar_search_reveal = None;
        if ticket.is_some() {
            self.prepare_sidebar_navigation(cx);
        }
        if ticket.is_some() && self.record.id == id && !self.loading && !self.load_failed {
            if self.project_actions_blocked_without_load() || self.load_retirement.failed() {
                return;
            }
            // Re-revealing within the current chat does not change navigation or
            // erase the independent Find bar. Keep normal explicit-open read and
            // durable-cancellation consequences, without a source load.
            self.reader_opened(id, false, cx);
            self.resume_durable_cancel_explicit(id, cx);
        } else {
            self.select_chat(id, window, cx);
        }
        if let Some(ticket) = ticket {
            let Ok(request) = SearchRequest::new(&ticket.query, 0) else {
                return;
            };
            self.sidebar_search_reveal = Some(PendingReveal {
                request,
                preparation_cancel: Arc::new(std::sync::atomic::AtomicBool::new(false)),
                retries: 0,
                navigation_completed: std::rc::Rc::new(std::cell::Cell::new(false)),
                ticket,
                operation: Uuid::new_v4(),
                dispatched: false,
            });
            self.resume_sidebar_reveal(cx);
        }
    }
    pub(crate) fn resume_sidebar_reveal(&mut self, cx: &mut Context<Self>) {
        let Some(reveal) = &self.sidebar_search_reveal else {
            return;
        };
        if reveal.ticket.chat != self.record.id
            || self.shutting_down
            || self.close_ready
            || self.known_catalog_uncertainty
            || self.sidebar_search_scope_blocked()
            || self.filter.read(cx).has_marked_text()
            || self.filter.read(cx).text() != reveal.ticket.query
        {
            self.sidebar_search_reveal = None;
            return;
        }
        if self.loading {
            return;
        }
        if self.load_failed || self.pending {
            self.sidebar_search_reveal = None;
            return;
        }
        if reveal.dispatched
            || self.sidebar_selection_pending.is_some()
            || self.sidebar_read_writes_pending()
            || !self.sidebar_search.reveal_settled()
        {
            return;
        }
        if self.transcript.as_ref().is_some_and(|transcript| {
            transcript
                .read(cx)
                .sidebar_decoration_owned(reveal.operation)
        }) {
            return;
        }
        let ticket = reveal.ticket.clone();
        let request = reveal.request.clone();
        let preparation_cancel = reveal.preparation_cancel.clone();
        let operation = Uuid::new_v4();
        let target = Target::capture(self);
        if !target.matches(self) {
            return;
        }
        if !self.sidebar_run_states.reserve_reveal(operation) {
            return;
        }
        self.sidebar_search_reveal.as_mut().unwrap().operation = operation;
        self.sidebar_search_reveal.as_mut().unwrap().dispatched = true;
        let workspace = self.workspace.clone();
        let controller = Arc::downgrade(&self.controller);
        #[cfg(test)]
        let delay = cx
            .background_executor()
            .timer(std::time::Duration::from_millis(
                REVEAL_DELAY_MS.with(|delay| delay.get()),
            ));
        let task = cx.background_executor().spawn(async move {
            #[cfg(test)]
            delay.await;
            let candidate =
                LoadedSearchEvidence::capture(&workspace, &controller, &ticket.chat, &request)?
                    .prepare()?;
            let slot = SearchAdmissionSlot::new(&request);
            slot.try_install(candidate.clone())?;
            let binding = controller
                .upgrade()
                .and_then(|controller| controller.find_snapshot())
                .ok_or(bello_agent_core::sidebar_search::SearchError::Unavailable)?;
            let fresh = match candidate.outcome() {
                SearchOutcome::Match(hit) => hit,
                _ => return Err(bello_agent_core::sidebar_search::SearchError::Stale),
            };
            let prepared = crate::transcript_find_presentation::prepare_sidebar(
                binding,
                fresh,
                &slot,
                &preparation_cancel,
            )
            .map_err(|_| bello_agent_core::sidebar_search::SearchError::Stale)?;
            Ok::<_, bello_agent_core::sidebar_search::SearchError>((
                ticket,
                Arc::new(slot),
                prepared,
            ))
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.sidebar_run_states.finish_reveal(operation);
                // Releasing the lane wakes current demand even when this old
                // publication is rejected after query/cache-owner replacement.
                cx.notify();
                if !view
                    .sidebar_search_reveal
                    .as_ref()
                    .is_some_and(|r| r.operation == operation)
                {
                    return;
                }
                if !target.matches(view)
                    || view.sidebar_search_scope_blocked()
                    || !view.sidebar_search.cache_ready()
                    || view.filter.read(cx).has_marked_text()
                    || view
                        .sidebar_search_reveal
                        .as_ref()
                        .is_some_and(|r| view.filter.read(cx).text() != r.ticket.query)
                {
                    view.cancel_sidebar_reveal(cx);
                    return;
                }
                let mut pending = view
                    .sidebar_search_reveal
                    .take()
                    .expect("matched reveal owner");
                let Ok((ticket, slot, prepared)) = result else {
                    if result.as_ref().err()
                        == Some(&bello_agent_core::sidebar_search::SearchError::Stale)
                        && pending.retries < 2
                    {
                        pending.retries += 1;
                        pending.dispatched = false;
                        view.sidebar_search_reveal = Some(pending);
                        view.resume_sidebar_reveal(cx);
                        return;
                    }
                    view.error = Some(
                        "The selected search result changed. Search again to refresh it.".into(),
                    );
                    cx.notify();
                    return;
                };
                let Ok(Some(candidate)) = slot.current() else {
                    if pending.retries < 2 && !pending.request.is_cancelled() {
                        pending.retries += 1;
                        pending.dispatched = false;
                        view.sidebar_search_reveal = Some(pending);
                        view.resume_sidebar_reveal(cx);
                        return;
                    }
                    view.error = Some(
                        "The search result changed while opening. Search again to refresh it."
                            .into(),
                    );
                    cx.notify();
                    return;
                };
                let fresh = match candidate.outcome() {
                    SearchOutcome::Match(hit) => hit,
                    _ => {
                        view.error =
                            Some("The selected phrase is no longer retained in this chat.".into());
                        cx.notify();
                        return;
                    }
                };
                if !fresh.same_semantic_piece(&ticket.hit)
                    || fresh.key() != ticket.hit.key()
                    || fresh.occurrence() != ticket.hit.occurrence()
                    || fresh.target() != ticket.hit.target()
                {
                    view.error =
                        Some("The selected occurrence changed. Search again to refresh it.".into());
                    cx.notify();
                    return;
                }
                // A separate sidebar owner reuses only exact presentation/geometry;
                // the independent Find field, matcher and navigation stay intact.
                let id = fresh.key().message_id.clone();
                if let Some(index) = view.session.messages.iter().position(|m| m.id == id) {
                    view.visible_messages = view
                        .visible_messages
                        .max(view.session.messages.len() - index);
                }
                view.sync_transcript_inputs(cx);
                if let Some(transcript) = view.transcript.clone() {
                    let input = view.transcript_input();
                    let Some(admission) = view.sidebar_search.reveal_admission() else {
                        return;
                    };
                    let paint = crate::transcript_find_presentation::FindPaint::new_sidebar(
                        prepared,
                        slot,
                        fresh,
                        operation,
                        admission,
                        pending.navigation_completed.clone(),
                    );
                    let navigate = !pending.navigation_completed.get();
                    let revealed = transcript.update(cx, |t, cx| {
                        if navigate {
                            t.reveal_sidebar(input, paint, cx)
                        } else {
                            t.decorate_sidebar(input, paint, cx)
                        }
                    });
                    if !revealed {
                        view.error = Some(
                            "The matching row could not be displayed. Search again to refresh it."
                                .into(),
                        );
                    } else {
                        if navigate {
                            view.bound_sidebar_search_reveal(operation, cx);
                        }
                        pending.dispatched = false;
                        pending.retries = 0;
                        view.sidebar_search_reveal = Some(pending);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn bound_sidebar_search_reveal(&mut self, owner: Uuid, cx: &mut Context<Self>) {
        let timer = cx
            .background_executor()
            .timer(std::time::Duration::from_millis(500));
        cx.spawn(async move |view, cx| {
            timer.await;
            let _ = view.update(cx, |view, cx| {
                if let Some(transcript) = view.transcript.clone()
                    && transcript.update(cx, |transcript,cx| transcript.finish_sidebar_wait(owner,cx)) {
                    view.error = Some("Exact phrase geometry was unavailable; showing the matching row. Choose the result again to retry.".into());
                    cx.notify();
                }
            });
        }).detach();
    }
}
