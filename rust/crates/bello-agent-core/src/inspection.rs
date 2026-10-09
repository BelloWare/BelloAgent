//! Cooperative, read-only inspection cancellation and one shared parse lane.
//! Neither a permit nor a successful read proves source authority or durability.
use crate::{Error, Result, invalid};
use InspectionCancellation as CancellationToken;
use serde::de::DeserializeOwned;
use std::{
    collections::VecDeque,
    io::Read,
    sync::{Arc, Mutex},
};
use tokio::sync::Notify;
pub use tokio_util::sync::CancellationToken as InspectionCancellation;

pub(crate) fn check(cancel: Option<&dyn crate::sidebar_search::CancellationProbe>) -> Result<()> {
    if cancel.is_some_and(|cancel| cancel.is_cancelled()) {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
/// Read at most the caller's existing snapshot limit plus one sentinel byte.
/// Cancellation is checked before and after each bounded filesystem read.
pub(crate) fn read_checkpoint(
    reader: impl Read,
    limit: usize,
    cancel: Option<&dyn crate::sidebar_search::CancellationProbe>,
) -> Result<Vec<u8>> {
    let mut reader = reader.take(limit as u64 + 1);
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        #[cfg(test)]
        observation_hook("checkpoint");
        check(cancel)?;
        let outcome = reader.read(&mut buffer);
        check(cancel)?;
        let count = outcome?;
        if count == 0 {
            return Ok(bytes);
        }
        bytes.extend_from_slice(&buffer[..count]);
    }
}
/// Preserve the normal slice parser when cancellation was not requested. The
/// inspection parser checks within large strings/ignored fields, not only rows.
pub(crate) fn parse<T: DeserializeOwned>(
    bytes: &[u8],
    cancel: Option<&dyn crate::sidebar_search::CancellationProbe>,
) -> Result<T> {
    check(cancel)?;
    let parsed = if let Some(cancel) = cancel {
        struct Reader<'a> {
            bytes: &'a [u8],
            cancel: &'a dyn crate::sidebar_search::CancellationProbe,
            since: usize,
        }
        impl Read for Reader<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if self.since >= 4096 {
                    self.since = 0;
                    #[cfg(test)]
                    observation_hook("json");
                    #[cfg(test)]
                    PARSE_CHECK_HOOK.with(|hook| {
                        if let Some(hook) = hook.borrow_mut().as_mut() {
                            hook();
                        }
                    });
                    if self.cancel.is_cancelled() {
                        return Err(std::io::Error::other("Inspection cancelled"));
                    }
                }
                // Do not rely on serde's present one-byte read strategy.
                // Every Read call respects the remaining check budget.
                let take = buffer.len().min(4096 - self.since);
                let count = self.bytes.read(&mut buffer[..take])?;
                self.since += count;
                Ok(count)
            }
        }
        serde_json::from_reader(Reader {
            bytes,
            cancel,
            since: 4096,
        })
    } else {
        serde_json::from_slice(bytes)
    };
    // Cancellation is never reported as corruption, including cancellation
    // during the final buffer or a parser error. No recovery is attempted.
    check(cancel)?;
    Ok(parsed?)
}

#[derive(Clone, Default)]
pub struct InspectionCoordinator {
    shared: Arc<Shared>,
}
#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Notify,
}
#[derive(Default)]
struct State {
    next: u64,
    active: Option<Active>,
    selected: VecDeque<u64>,
}
struct Active {
    id: u64,
    background: bool,
    cancel: CancellationToken,
}
/// A permit spans the complete lease/parse/summary lifetime. Drop the inspection
/// lease before dropping this permit; do not hold store/catalog locks while waiting.
#[must_use]
pub struct InspectionPermit {
    shared: Arc<Shared>,
    id: u64,
    cancel: CancellationToken,
}
impl InspectionPermit {
    pub fn cancellation(&self) -> &CancellationToken {
        &self.cancel
    }
    pub(crate) fn inspect_bound_search(
        &mut self,
        work: &crate::sidebar_search::reconciliation::SearchWork,
    ) -> Result<CoordinatedInspection<'_>> {
        let cancel = crate::sidebar_search::cancellation::CombinedCancellation(
            work.request.cancellation(),
            &self.cancel,
            work.cancellation(),
        );
        let lease = crate::session::SessionInspectionLease::acquire_observed(
            work.member().checkpoint_path(),
            work.member().chat_id(),
            &cancel,
        )?;
        Ok(CoordinatedInspection {
            lease,
            search_work: Some(work.clone()),
            _permit: self,
        })
    }
    pub fn inspect_observed<'a>(
        &'a mut self,
        path: impl AsRef<std::path::Path>,
        expected_id: &str,
    ) -> Result<CoordinatedInspection<'a>> {
        let lease = crate::session::SessionInspectionLease::acquire_observed(
            path.as_ref(),
            expected_id,
            &self.cancel,
        )?;
        Ok(CoordinatedInspection {
            lease,
            _permit: self,
            search_work: None,
        })
    }
    /// The exclusive borrow prevents concurrent parses through one permit and
    /// dropping the parse permit before its writer lease.
    ///
    /// ```compile_fail,E0499
    /// use bello_agent_core::inspection::InspectionCoordinator;
    /// let lane = InspectionCoordinator::default();
    /// let mut permit = lane.try_background().unwrap().unwrap();
    /// let first = permit.inspect("first.json", "fixture").unwrap();
    /// let second = permit.inspect("second.json", "fixture").unwrap();
    /// drop(first);
    /// drop(second);
    /// ```
    pub fn inspect<'a>(
        &'a mut self,
        path: impl AsRef<std::path::Path>,
        expected_id: &str,
    ) -> Result<CoordinatedInspection<'a>> {
        let lease = crate::session::SessionInspectionLease::acquire_cancelled(
            path,
            expected_id,
            &self.cancel,
        )?;
        Ok(CoordinatedInspection {
            lease,
            _permit: self,
            search_work: None,
        })
    }
}
#[must_use]
pub struct CoordinatedInspection<'a> {
    lease: crate::session::SessionInspectionLease,
    _permit: &'a mut InspectionPermit,
    search_work: Option<crate::sidebar_search::reconciliation::SearchWork>,
}
impl CoordinatedInspection<'_> {
    pub fn observed_source(&self) -> Result<crate::observed_source::ObservedSource> {
        self.lease.observed_source(Some(&self._permit.cancel))
    }
    pub(crate) fn cancellation(&self) -> &CancellationToken {
        &self._permit.cancel
    }
    pub(crate) fn matches_search_work(
        &self,
        work: &crate::sidebar_search::reconciliation::SearchWork,
    ) -> bool {
        self.search_work
            .as_ref()
            .is_some_and(|bound| bound.same_attempt(work))
    }

    /// Read-only presentation evidence only, not a durability/loaded-source receipt.
    pub fn snapshot(&self) -> &crate::Session {
        self.lease.snapshot()
    }
}
#[cfg(test)]
thread_local! { static PARSE_CHECK_HOOK: std::cell::RefCell<Option<Box<dyn FnMut()>>> = std::cell::RefCell::new(None); }

impl Drop for InspectionPermit {
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.state.lock()
            && state
                .active
                .as_ref()
                .is_some_and(|active| active.id == self.id)
        {
            state.active = None;
        }
        self.shared.changed.notify_waiters();
    }
}
/// Registration is synchronous and nonblocking except for a short state mutex;
/// waiting is async. Dropping the request/future always removes queued priority.
#[must_use]
pub struct SelectedOpenRequest {
    shared: Arc<Shared>,
    id: u64,
    registered: bool,
}
impl Drop for SelectedOpenRequest {
    fn drop(&mut self) {
        if self.registered {
            if let Ok(mut state) = self.shared.state.lock() {
                state.selected.retain(|id| *id != self.id);
            }
            self.shared.changed.notify_waiters();
        }
    }
}
impl InspectionCoordinator {
    /// Background callers coalesce/retry in their existing scheduler; no waiting
    /// parse or queued Session is retained here. Selected-open always has priority.
    pub fn try_background(&self) -> Result<Option<InspectionPermit>> {
        self.try_background_with_parent(None)
    }
    fn try_background_with_parent(
        &self,
        parent: Option<&CancellationToken>,
    ) -> Result<Option<InspectionPermit>> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| invalid("Inspection coordinator unavailable"))?;
        if state.active.is_some() || !state.selected.is_empty() {
            return Ok(None);
        }
        let id = next(&mut state)?;
        let cancel = parent.map_or_else(CancellationToken::new, CancellationToken::child_token);
        state.active = Some(Active {
            id,
            background: true,
            cancel: cancel.clone(),
        });
        Ok(Some(InspectionPermit {
            shared: self.shared.clone(),
            id,
            cancel,
        }))
    }
    /// Notification-driven wait; cancellation of the scope also reaches an
    /// admitted background parse. Selected-open cancellation affects only the
    /// child token, never unrelated later work in the same parent scope.
    pub async fn background(&self, cancel: &CancellationToken) -> Result<InspectionPermit> {
        loop {
            let notified = self.shared.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            check(Some(cancel))?;
            if let Some(permit) = self.try_background_with_parent(Some(cancel))? {
                check(Some(cancel))?;
                return Ok(permit);
            }
            tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(Error::Cancelled),
                _ = notified => {}
            }
        }
    }
    pub fn selected_open(&self) -> Result<SelectedOpenRequest> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| invalid("Inspection coordinator unavailable"))?;
        if state.selected.len() >= 1024 {
            return Err(invalid("Too many queued selected opens"));
        }
        let id = next(&mut state)?;
        state.selected.push_back(id);
        if let Some(active) = &state.active
            && active.background
        {
            active.cancel.cancel();
        }
        Ok(SelectedOpenRequest {
            shared: self.shared.clone(),
            id,
            registered: true,
        })
    }
    /// Scope invalidation asks an active background parse to stop, but cannot
    /// release its lane or writer lock before the worker actually drops them.
    pub fn cancel_background(&self) -> Result<()> {
        let state = self
            .shared
            .state
            .lock()
            .map_err(|_| invalid("Inspection coordinator unavailable"))?;
        if let Some(active) = &state.active
            && active.background
        {
            active.cancel.cancel();
        }
        Ok(())
    }
}
fn next(state: &mut State) -> Result<u64> {
    state.next = state
        .next
        .checked_add(1)
        .ok_or_else(|| invalid("Inspection generation exhausted"))?;
    Ok(state.next)
}
impl SelectedOpenRequest {
    /// Dropping the cancelled acquisition removes its queued priority entry.
    pub async fn acquire_cancelled(self, cancel: &CancellationToken) -> Result<InspectionPermit> {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(Error::Cancelled),
            result = self.acquire() => { check(Some(cancel))?; result }
        }
    }

    pub async fn acquire(mut self) -> Result<InspectionPermit> {
        loop {
            // Register the waiter before testing the condition: permit release
            // between the mutex check and await must not become a lost wake.
            let shared = self.shared.clone();
            let notified = shared.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut state = self
                    .shared
                    .state
                    .lock()
                    .map_err(|_| invalid("Inspection coordinator unavailable"))?;
                if state.active.is_none() && state.selected.front() == Some(&self.id) {
                    state.selected.pop_front();
                    let cancel = CancellationToken::new();
                    state.active = Some(Active {
                        id: self.id,
                        background: false,
                        cancel: cancel.clone(),
                    });
                    self.registered = false;
                    return Ok(InspectionPermit {
                        shared: self.shared.clone(),
                        id: self.id,
                        cancel,
                    });
                }
            }
            #[cfg(test)]
            WAIT_CHECK_HOOK.with(|hook| {
                if let Some(hook) = hook.borrow_mut().take() {
                    hook();
                }
            });
            notified.await;
        }
    }
}
#[cfg(test)]
thread_local! { static WAIT_CHECK_HOOK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = std::cell::RefCell::new(None); }
#[cfg(test)]
#[path = "inspection_tests.rs"]
mod tests;

#[cfg(test)]
type ObservationHook = Option<Box<dyn FnMut(&str)>>;
#[cfg(test)]
thread_local! { pub(crate) static OBSERVATION_HOOK: std::cell::RefCell<ObservationHook> = std::cell::RefCell::new(None); }
#[cfg(test)]
pub(crate) fn observation_hook(stage: &str) {
    OBSERVATION_HOOK.with(|hook| {
        if let Some(hook) = hook.borrow_mut().as_mut() {
            hook(stage);
        }
    });
}
