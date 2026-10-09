use super::{
    SearchError, SearchOutcome, cancellation::CombinedCancellation, projection::ActivePolicy,
    reconciliation::SearchWork,
};
use crate::{
    inspection::CoordinatedInspection,
    observed_source::ObservedSource,
    workspace_membership::{MembershipMember, MembershipStamp},
};
use std::fmt;

/// Bounded as-of output. No raw session, borrowed projection, lease, Controller,
/// catalog owner, or claim of ongoing disk currency survives here.
pub struct UnloadedObserved {
    pub(crate) work: SearchWork,
    source: ObservedSource,
    content_digest: [u8; 32],
    outcome: SearchOutcome,
}
impl UnloadedObserved {
    pub fn source(&self) -> &ObservedSource {
        &self.source
    }
    pub fn member(&self) -> &MembershipMember {
        self.work.member()
    }
    pub fn membership_stamp(&self) -> &MembershipStamp {
        &self.work.membership
    }
    pub fn content_digest(&self) -> [u8; 32] {
        self.content_digest
    }
    pub fn outcome(&self) -> &SearchOutcome {
        &self.outcome
    }
    pub fn versions(&self) -> (u32, u32, u32) {
        (
            super::projection::PROJECTION_VERSION,
            super::projection::CANONICAL_MAPPING_VERSION,
            super::projection::NORMALIZATION_VERSION,
        )
    }
}
impl fmt::Debug for UnloadedObserved {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UnloadedObserved")
            .field("source", &self.source)
            .field("outcome", &self.outcome)
            .finish_non_exhaustive()
    }
}
impl CoordinatedInspection<'_> {
    /// Worker-only. The request must be issued before parsing; callers acquire
    /// inspect_observed on the exact work member. Final closure follows CPU work
    /// while the cooperating writer lock and exclusive parse permit remain held.
    pub fn prepare_search(&self, work: &SearchWork) -> Result<UnloadedObserved, SearchError> {
        self.prepare_search_impl(work, None)
    }
    pub fn prepare_search_with_cache(
        &self,
        work: &SearchWork,
        cache: &mut super::cache::Replacement<'_>,
    ) -> Result<UnloadedObserved, SearchError> {
        self.prepare_search_impl(work, Some(cache))
    }
    fn prepare_search_impl(
        &self,
        work: &SearchWork,
        cache: Option<&mut super::cache::Replacement<'_>>,
    ) -> Result<UnloadedObserved, SearchError> {
        work.require_unloaded()?;
        if !self.matches_search_work(work) {
            return Err(SearchError::WrongRequest);
        }
        let source = self.observed_source().map_err(observation_error)?;
        if source.path != work.member().checkpoint_path()
            || source.session_id != work.member().chat_id()
        {
            return Err(SearchError::BindingMismatch);
        }
        let cancel = CombinedCancellation(
            work.request.cancellation(),
            self.cancellation(),
            work.cancellation(),
        );
        let (content_digest, outcome) = work.request.project_with_cache(
            self.snapshot(),
            ActivePolicy::ObservedRetained,
            &cancel,
            cache,
        )?;
        #[cfg(test)]
        crate::inspection::observation_hook("projection");
        let source = self.observed_source().map_err(observation_error)?;
        work.check()?;
        Ok(UnloadedObserved {
            work: work.clone(),
            source,
            content_digest,
            outcome,
        })
    }
}
fn observation_error(error: crate::Error) -> SearchError {
    match error {
        crate::Error::Cancelled => SearchError::Cancelled,
        _ => SearchError::Unavailable,
    }
}

impl crate::inspection::InspectionPermit {
    /// Validates route/membership/request before any disk access. Never use a
    /// readable checkpoint as a fallback for Loaded or Blocked work.
    pub fn inspect_search(
        &mut self,
        work: &SearchWork,
    ) -> crate::Result<CoordinatedInspection<'_>> {
        work.require_unloaded()
            .map_err(|_| crate::invalid("Search source is not eligible for unloaded inspection"))?;
        self.inspect_bound_search(work)
    }
}
