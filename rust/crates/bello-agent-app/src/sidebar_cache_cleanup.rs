//! Owned cleanup intents outlive query/window generations. Errors never consume
//! later IDs, and authoritative removal dominates transient invalidation.
use std::collections::BTreeMap;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CleanupKind {
    Invalidate,
    Delete,
}
#[derive(Default)]
pub(crate) struct CleanupIntents(BTreeMap<String, CleanupKind>);
impl CleanupIntents {
    pub(crate) fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub(crate) fn insert(&mut self, id: String, kind: CleanupKind) {
        self.0
            .entry(id)
            .and_modify(|old| {
                if kind == CleanupKind::Delete {
                    *old = kind;
                }
            })
            .or_insert(kind);
    }
    pub(crate) fn merge(&mut self, other: Self) {
        for (id, kind) in other.0 {
            self.insert(id, kind);
        }
    }
    pub(crate) fn drain_with<E>(
        &mut self,
        mut action: impl FnMut(&str, CleanupKind) -> Result<(), E>,
    ) -> bool {
        let ids: Vec<_> = self.0.keys().cloned().collect();
        for id in ids {
            let kind = self.0[&id];
            if action(&id, kind).is_ok() {
                self.0.remove(&id);
            }
        }
        self.is_empty()
    }
    pub(crate) fn drain(
        &mut self,
        cache: &mut bello_agent_core::sidebar_search::cache::PrivateCache,
    ) -> bool {
        self.drain_with(|id, kind| match kind {
            CleanupKind::Invalidate => cache.invalidate(id),
            CleanupKind::Delete => cache.delete(id),
        })
    }
}
#[derive(Default)]
pub(crate) struct CleanupRetry {
    attempts: u8,
    pub(crate) waiting: bool,
}
impl CleanupRetry {
    pub(crate) fn reset(&mut self) {
        *self = Self::default();
    }
    pub(crate) fn failed(&mut self) -> Option<u64> {
        self.attempts = self.attempts.saturating_add(1);
        self.waiting = true;
        (self.attempts < 3).then_some(50u64 << self.attempts.min(3))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn three() -> CleanupIntents {
        let mut queue = CleanupIntents::default();
        for id in ["a", "b", "c"] {
            queue.insert(id.into(), CleanupKind::Invalidate);
        }
        queue
    }
    #[test]
    fn first_and_middle_failure_keep_exact_failed_intents_and_visit_later_ids() {
        for failed in ["a", "b"] {
            let mut queue = three();
            let mut visited = Vec::new();
            assert!(!queue.drain_with(|id, _| {
                visited.push(id.to_owned());
                if id == failed { Err(()) } else { Ok(()) }
            }));
            assert_eq!(visited, ["a", "b", "c"]);
            assert_eq!(
                queue.0.keys().map(String::as_str).collect::<Vec<_>>(),
                [failed]
            );
            assert!(queue.drain_with::<()>(|_, _| Ok(())));
        }
    }
    #[test]
    fn cancellation_or_window_change_does_not_discard_worker_or_new_intents() {
        let mut live = three();
        let mut worker = std::mem::take(&mut live);
        live.insert("d".into(), CleanupKind::Invalidate);
        live.insert("b".into(), CleanupKind::Delete);
        assert!(!worker.drain_with::<()>(|_, _| Err(())));
        live.merge(worker);
        assert_eq!(live.0.len(), 4);
        assert_eq!(live.0["b"], CleanupKind::Delete);
    }
    #[test]
    fn busy_cleanup_has_bounded_automatic_retries_and_explicit_reset() {
        let mut retry = CleanupRetry::default();
        assert_eq!(retry.failed(), Some(100));
        assert_eq!(retry.failed(), Some(200));
        assert_eq!(retry.failed(), None);
        assert!(retry.waiting);
        assert_eq!(retry.failed(), None);
        retry.reset();
        assert_eq!(retry.failed(), Some(100));
    }
}
