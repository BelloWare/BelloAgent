//! Explicit all-member query reconciliation. This is not an index/cache and
//! does not infer absence from missing rows or disk currency from old receipts.
use super::{PreparedSearchCandidate, SearchError, SearchOutcome, SearchRequest, UnloadedObserved};
use crate::workspace::ChatMaterialization;
use crate::workspace_membership::{
    MembershipMember, MembershipSnapshot, MembershipStamp, MembershipWitness,
};
use std::{
    collections::BTreeMap,
    fmt,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};
use uuid::Uuid;

#[derive(Clone)]
pub struct SearchWork {
    pub(crate) request: SearchRequest,
    pub(crate) membership: MembershipStamp,
    witness: MembershipWitness,
    member: MembershipMember,
    pass: Uuid,
    lifecycle: u64,
    route: SourceRoute,
    cancelled: Arc<AtomicBool>,
}
impl SearchWork {
    pub(crate) fn same_attempt(&self, other: &Self) -> bool {
        self.pass == other.pass
            && self.lifecycle == other.lifecycle
            && Arc::ptr_eq(&self.cancelled, &other.cancelled)
            && self.request.same_request(&other.request)
    }
    pub fn member(&self) -> &MembershipMember {
        &self.member
    }
    pub fn generation(&self) -> u64 {
        self.request.generation()
    }
    pub fn lifecycle_generation(&self) -> u64 {
        self.lifecycle
    }
    pub(crate) fn cancellation(&self) -> &AtomicBool {
        &self.cancelled
    }
    pub fn require_unloaded(&self) -> Result<(), SearchError> {
        self.check()?;
        if self.route != SourceRoute::Unloaded {
            Err(SearchError::Unavailable)
        } else {
            Ok(())
        }
    }
    pub(crate) fn check(&self) -> Result<(), SearchError> {
        self.request.check()?;
        if self.cancelled.load(Ordering::Acquire) {
            return Err(SearchError::Cancelled);
        }
        if !self.witness.is_current(&self.membership) {
            return Err(SearchError::Stale);
        }
        Ok(())
    }
}
impl fmt::Debug for SearchWork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SearchWork")
            .field("pass", &self.pass)
            .field("lifecycle", &self.lifecycle)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObservationFailure {
    Busy,
    Changed,
    Missing,
    Unsafe,
    Torn,
    Invalid,
    Cancelled,
    ResourceLimit,
    LoadedBlocked,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceRoute {
    Unloaded,
    Loaded,
    Blocked,
}
enum Outcome {
    Pending,
    Failed(ObservationFailure),
    Observed(Box<UnloadedObserved>),
    Loaded(Arc<PreparedSearchCandidate>),
}
struct Row {
    member: MembershipMember,
    lifecycle: u64,
    route: SourceRoute,
    outcome: Outcome,
    cancelled: Arc<AtomicBool>,
}
impl Row {
    fn advance(&mut self) -> Result<(), SearchError> {
        // Revoke first. Exhaustion must never preserve a previous hit or issue
        // an uncancelled replacement token with the old generation.
        self.cancelled.store(true, Ordering::Release);
        self.outcome = Outcome::Failed(ObservationFailure::ResourceLimit);
        let Some(next) = self.lifecycle.checked_add(1) else {
            self.route = SourceRoute::Blocked;
            return Err(SearchError::Limit);
        };
        self.lifecycle = next;
        self.cancelled = Arc::new(AtomicBool::new(false));
        self.outcome = Outcome::Pending;
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CoverageState {
    CompleteAsOf,
    Pending,
    Unavailable,
}
#[derive(Clone, Debug)]
pub struct QueryCoverage {
    pub pass_id: Uuid,
    pub expected_members: usize,
    pub observed_members: usize,
    pub loaded_members: usize,
    pub pending: usize,
    pub unavailable: usize,
    pub removed: usize,
    pub interval: (Instant, Instant),
    pub state: CoverageState,
}
/// One pass starts every eligible member Pending, including prior cache misses.
/// App owns dispatch and must mark all loaded/blocked lifetimes before requesting
/// work. Scope/lifecycle state must survive map gaps; no map-absence inference here.
pub struct ReconciliationPass {
    id: Uuid,
    request: SearchRequest,
    membership: MembershipStamp,
    witness: MembershipWitness,
    rows: BTreeMap<String, Row>,
    started: Instant,
    removed: usize,
}
impl ReconciliationPass {
    #[cfg(test)]
    pub(crate) fn exhaust_for_test(&mut self, id: &str) {
        self.rows.get_mut(id).unwrap().lifecycle = u64::MAX;
    }
    pub fn begin(
        request: &SearchRequest,
        membership: &MembershipSnapshot,
    ) -> Result<Self, SearchError> {
        request.check()?;
        if !membership.is_current() {
            return Err(SearchError::Stale);
        }
        if membership.members().len() > 512 {
            return Err(SearchError::Limit);
        }
        let mut rows = BTreeMap::new();
        for member in membership.members() {
            if member.materialization() != ChatMaterialization::CheckpointRequired {
                continue;
            }
            for bytes in [
                member.chat_id().as_bytes(),
                member.checkpoint_path().as_os_str().as_encoded_bytes(),
                membership
                    .stamp()
                    .catalog_path()
                    .as_os_str()
                    .as_encoded_bytes(),
                membership
                    .stamp()
                    .project_path()
                    .as_os_str()
                    .as_encoded_bytes(),
            ] {
                if bytes.len() > 16 * 1024 {
                    return Err(SearchError::Limit);
                }
            }
            rows.insert(
                member.chat_id().to_owned(),
                Row {
                    member: member.clone(),
                    lifecycle: 0,
                    route: SourceRoute::Unloaded,
                    outcome: Outcome::Pending,
                    cancelled: Arc::new(AtomicBool::new(false)),
                },
            );
        }
        Ok(Self {
            id: Uuid::new_v4(),
            request: request.clone(),
            membership: membership.stamp().clone(),
            witness: membership.witness(),
            rows,
            started: Instant::now(),
            removed: 0,
        })
    }
    fn check(&self) -> Result<(), SearchError> {
        self.request.check()?;
        if !self.witness.is_current(&self.membership) {
            Err(SearchError::Stale)
        } else {
            Ok(())
        }
    }
    /// Every transition invalidates the old outcome, even if the numeric route
    /// is unchanged. Only the App's explicit successful transition may unblock.
    pub fn transition(&mut self, id: &str, route: SourceRoute) -> Result<(), SearchError> {
        self.check()?;
        let row = self.rows.get_mut(id).ok_or(SearchError::BindingMismatch)?;
        row.advance()?;
        row.route = route;
        row.outcome = if route == SourceRoute::Blocked {
            Outcome::Failed(ObservationFailure::LoadedBlocked)
        } else {
            Outcome::Pending
        };
        Ok(())
    }
    pub fn work(&mut self, id: &str) -> Result<SearchWork, SearchError> {
        self.check()?;
        let row = self.rows.get_mut(id).ok_or(SearchError::BindingMismatch)?;
        if row.route == SourceRoute::Blocked {
            return Err(SearchError::Unavailable);
        }
        row.advance()?;
        row.outcome = Outcome::Pending;
        Ok(SearchWork {
            route: row.route,
            cancelled: row.cancelled.clone(),
            request: self.request.clone(),
            membership: self.membership.clone(),
            witness: self.witness.clone(),
            member: row.member.clone(),
            pass: self.id,
            lifecycle: row.lifecycle,
        })
    }
    fn row_for(&mut self, work: &SearchWork) -> Result<&mut Row, SearchError> {
        self.check()?;
        work.check()?;
        if work.pass != self.id || !work.request.same_request(&self.request) {
            return Err(SearchError::WrongRequest);
        }
        let row = self
            .rows
            .get_mut(work.member.chat_id())
            .ok_or(SearchError::Stale)?;
        if row.member != work.member
            || row.lifecycle != work.lifecycle
            || row.route == SourceRoute::Blocked
            || !matches!(row.outcome, Outcome::Pending)
        {
            return Err(SearchError::Stale);
        }
        Ok(row)
    }
    pub fn record_observed(&mut self, value: UnloadedObserved) -> Result<(), SearchError> {
        let row = self.row_for(&value.work)?;
        if row.route != SourceRoute::Unloaded {
            return Err(SearchError::Unavailable);
        }
        row.outcome = Outcome::Observed(Box::new(value));
        Ok(())
    }
    pub fn record_loaded(
        &mut self,
        work: &SearchWork,
        value: Arc<PreparedSearchCandidate>,
    ) -> Result<(), SearchError> {
        value.check_for(&self.request)?;
        let row = self.row_for(work)?;
        if row.route != SourceRoute::Loaded
            || value.member() != &row.member
            || value.membership_stamp() != &work.membership
        {
            return Err(SearchError::BindingMismatch);
        }
        row.outcome = Outcome::Loaded(value);
        Ok(())
    }
    pub fn record_failure(
        &mut self,
        work: &SearchWork,
        failure: ObservationFailure,
    ) -> Result<(), SearchError> {
        self.row_for(work)?.outcome = Outcome::Failed(failure);
        Ok(())
    }
    /// Removal suppresses immediately even when the membership witness has
    /// already changed. A new authoritative pass is required to admit new rows.
    pub fn remove(&mut self, id: &str) {
        if let Some(row) = self.rows.remove(id) {
            row.cancelled.store(true, Ordering::Release);
            self.removed += 1;
        }
    }
    pub fn outcome(&self, id: &str) -> Result<Option<&SearchOutcome>, SearchError> {
        self.check()?;
        let row = self.rows.get(id).ok_or(SearchError::BindingMismatch)?;
        match &row.outcome {
            Outcome::Observed(v) => Ok(Some(v.outcome())),
            Outcome::Loaded(v) => {
                v.check_for(&self.request)?;
                Ok(Some(v.outcome()))
            }
            Outcome::Pending => Ok(None),
            Outcome::Failed(_) => Err(SearchError::Unavailable),
        }
    }
    pub fn failure(&self, id: &str) -> Option<ObservationFailure> {
        match &self.rows.get(id)?.outcome {
            Outcome::Failed(f) => Some(*f),
            _ => None,
        }
    }
    /// Exact membership epoch AND complete eligible set are checked again.
    /// Changed/uncertain membership invalidates the pass; begin a new one so new
    /// members and previous negatives are reobserved. No old result is freshened.
    pub fn finish(&self, current: &MembershipSnapshot) -> Result<QueryCoverage, SearchError> {
        self.check()?;
        if !current.is_current() || current.stamp() != &self.membership {
            return Err(SearchError::Stale);
        }
        let members: Vec<_> = current
            .members()
            .iter()
            .filter(|m| m.materialization() == ChatMaterialization::CheckpointRequired)
            .collect();
        if members.len() != self.rows.len()
            || members
                .iter()
                .any(|m| self.rows.get(m.chat_id()).is_none_or(|r| &r.member != *m))
        {
            return Err(SearchError::Stale);
        }
        let mut out = QueryCoverage {
            pass_id: self.id,
            expected_members: self.rows.len(),
            observed_members: 0,
            loaded_members: 0,
            pending: 0,
            unavailable: 0,
            removed: self.removed,
            interval: (self.started, Instant::now()),
            state: CoverageState::CompleteAsOf,
        };
        for row in self.rows.values() {
            match &row.outcome {
                Outcome::Pending => out.pending += 1,
                Outcome::Failed(_) => out.unavailable += 1,
                Outcome::Observed(_) => out.observed_members += 1,
                Outcome::Loaded(v) => {
                    if v.check_for(&self.request).is_ok() {
                        out.loaded_members += 1
                    } else {
                        out.unavailable += 1
                    }
                }
            }
        }
        if out.unavailable > 0 {
            out.state = CoverageState::Unavailable;
        } else if out.pending > 0 {
            out.state = CoverageState::Pending;
        }
        self.check()?;
        Ok(out)
    }
}

impl Drop for ReconciliationPass {
    fn drop(&mut self) {
        for row in self.rows.values() {
            row.cancelled.store(true, Ordering::Release);
        }
    }
}
