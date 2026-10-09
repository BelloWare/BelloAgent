use super::{
    identity::ContentIdentity,
    projection::{
        self, ActivePolicy, Occurrence, Piece, PieceKind, Query, SidebarProjection, SourceTarget,
    },
};
use crate::{
    Controller, Session,
    source_admission::{LoadedSourceStamp, SourceWitness},
    workspace::{ChatMaterialization, WorkspaceStore},
    workspace_membership::{MembershipMember, MembershipStamp, MembershipWitness},
};
use sha2::{Digest, Sha256};
use std::{
    fmt,
    ops::Range,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicBool, Ordering},
    },
};
use uuid::Uuid;

pub const MAX_EXCERPT_BYTES: usize = 4096;
const MAX_BINDING_BYTES: usize = 16 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum SearchError {
    #[error("Search was cancelled")]
    Cancelled,
    #[error("Search evidence changed")]
    Stale,
    #[error("Search source or membership unavailable")]
    Unavailable,
    #[error("Loaded source does not match materialized membership")]
    BindingMismatch,
    #[error("Search candidate belongs to a different request")]
    WrongRequest,
    #[error("Search resource limit")]
    Limit,
    #[error("Search projection unavailable: {0:?}")]
    Projection(projection::Error),
}
impl From<projection::Error> for SearchError {
    fn from(error: projection::Error) -> Self {
        if error == projection::Error::Cancelled {
            Self::Cancelled
        } else {
            Self::Projection(error)
        }
    }
}

/// A unique query lifetime, even if the caller reuses its numeric generation.
/// Use one slot per request. Cancel on every app generation/lifecycle change.
#[derive(Clone)]
pub struct SearchRequest(Arc<Request>);
struct Request {
    id: Uuid,
    generation: u64,
    query: Query,
    query_digest: [u8; 32],
    cancelled: AtomicBool,
}
impl SearchRequest {
    pub fn new(query: &str, generation: u64) -> Result<Self, SearchError> {
        let cancelled = AtomicBool::new(false);
        let query = Query::new(query, &cancelled)?;
        let query_digest = Sha256::digest(query.normalized().as_bytes()).into();
        Ok(Self(Arc::new(Request {
            id: Uuid::new_v4(),
            generation,
            query,
            query_digest,
            cancelled,
        })))
    }
    pub(crate) fn same_request(&self, other: &Self) -> bool {
        self.0.id == other.0.id
    }
    pub(crate) fn cancellation(&self) -> &AtomicBool {
        &self.0.cancelled
    }
    pub(crate) fn project(
        &self,
        session: &Session,
        policy: ActivePolicy,
        cancel: &dyn super::CancellationProbe,
    ) -> Result<([u8; 32], SearchOutcome), SearchError> {
        self.check()?;
        let projection = SidebarProjection::new(session, policy, cancel)?;
        let identity = ContentIdentity::of(&projection, cancel)?;
        let outcome = match projection.newest_match(&self.0.query, cancel)? {
            Some((index, occurrence)) => SearchOutcome::Match(Box::new(OwnedHit::new(
                &projection.pieces[index],
                occurrence,
            ))),
            None => SearchOutcome::NoMatch,
        };
        self.check()?;
        Ok((identity.digest, outcome))
    }
    pub fn generation(&self) -> u64 {
        self.0.generation
    }
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }
    pub(crate) fn check(&self) -> Result<(), SearchError> {
        if self.is_cancelled() {
            Err(SearchError::Cancelled)
        } else {
            Ok(())
        }
    }
}
impl fmt::Debug for SearchRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SearchRequest")
            .field("generation", &self.generation())
            .field("cancelled", &self.is_cancelled())
            .finish_non_exhaustive()
    }
}

struct Evidence {
    membership: MembershipStamp,
    member: MembershipMember,
    membership_witness: MembershipWitness,
    source: LoadedSourceStamp,
    source_witness: SourceWitness,
}
struct AdmissionOwners {
    membership: crate::workspace_membership::MembershipOwnerLease,
    source: crate::source_admission::SourceOwnerLease,
    membership_poison: std::cell::Cell<bool>,
    source_poison: std::cell::Cell<bool>,
}
impl AdmissionOwners {
    fn pin(evidence: &Evidence) -> Result<Self, SearchError> {
        Ok(Self {
            membership_poison: std::cell::Cell::new(false),
            source_poison: std::cell::Cell::new(false),
            membership: evidence
                .membership_witness
                .pin_owner()
                .map_err(|_| SearchError::Stale)?,
            source: evidence
                .source_witness
                .pin_owner()
                .map_err(|_| SearchError::Stale)?,
        })
    }
    fn check(&self) -> Result<(), SearchError> {
        let membership = self.membership.healthy();
        let source = self.source.healthy();
        self.membership_poison
            .set(self.membership_poison.get() || !membership);
        self.source_poison.set(self.source_poison.get() || !source);
        if membership && source {
            Ok(())
        } else {
            Err(SearchError::Stale)
        }
    }
    // Called only after every admission guard has released; never re-lock a held witness.
    fn revoke_observed_poison(&self, evidence: &Evidence) {
        if self.membership_poison.get() || !self.membership.healthy() {
            evidence.membership_witness.unavailable();
        }
        if self.source_poison.get() || !self.source.healthy() {
            evidence.source_witness.unavailable();
        }
    }
}
impl Evidence {
    fn check(&self) -> Result<(), SearchError> {
        let owners = AdmissionOwners::pin(self)?;
        let result = (|| {
            let _membership = self
                .membership_witness
                .lock_current(&self.membership)
                .map_err(|_| SearchError::Stale)?;
            let _source = self
                .source_witness
                .lock_current(&self.source)
                .map_err(|_| SearchError::Stale)?;
            owners.check()
        })();
        owners.revoke_observed_poison(self);
        result
    }
}
/// Temporary worker-only acquisition. Consuming prepare releases all raw Session
/// and membership-list storage. It never holds the Controller during CPU work.
pub struct LoadedSearchEvidence {
    evidence: Evidence,
    session: Arc<Session>,
    request: SearchRequest,
}
impl LoadedSearchEvidence {
    /// Worker-only: catalog and actor capture can wait for existing persistence.
    /// Never holds both owner locks; never opens an unloaded checkpoint as fallback.
    pub fn capture(
        workspace: &Arc<Mutex<WorkspaceStore>>,
        controller: &Weak<Controller>,
        chat_id: &str,
        request: &SearchRequest,
    ) -> Result<Self, SearchError> {
        request.check()?;
        let membership = WorkspaceStore::search_membership_snapshot(workspace)
            .map_err(|_| SearchError::Unavailable)?;
        request.check()?;
        #[cfg(test)]
        test_hook(TestStage::CapturedMembership);
        let source = {
            let controller = controller.upgrade().ok_or(SearchError::Unavailable)?;
            controller
                .loaded_search_source()
                .map_err(|_| SearchError::Unavailable)?
        }; // Release the strong Controller before matching, hashing or projection.
        request.check()?;
        let member = membership
            .members()
            .iter()
            .find(|member| member.chat_id() == chat_id)
            .ok_or(SearchError::BindingMismatch)?;
        if member.materialization() != ChatMaterialization::CheckpointRequired
            || member.chat_id() != source.stamp().session_id()
            || member.checkpoint_path() != source.stamp().checkpoint_path()
        {
            return Err(SearchError::BindingMismatch);
        }
        // Bound retained private binding metadata before any clone into a result.
        for bytes in [
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
            member.checkpoint_path().as_os_str().as_encoded_bytes(),
            member.chat_id().as_bytes(),
            source.stamp().stream_generation().as_bytes(),
            membership.stamp().project_id().unwrap_or("").as_bytes(),
        ] {
            if bytes.len() > MAX_BINDING_BYTES {
                return Err(SearchError::Limit);
            }
        }
        let evidence = Evidence {
            membership: membership.stamp().clone(),
            member: member.clone(),
            membership_witness: membership.witness(),
            source: source.stamp().clone(),
            source_witness: source.witness(),
        };
        evidence.check()?;
        request.check()?;
        // Transfer the existing captured Arc, never clone a second full Session.
        Ok(Self {
            evidence,
            session: source.into_session(),
            request: request.clone(),
        })
    }
    pub fn prepare(self) -> Result<Arc<PreparedSearchCandidate>, SearchError> {
        self.request.check()?;
        self.evidence.check()?;
        let cancel = &self.request.0.cancelled;
        let (content_digest, outcome) =
            self.request
                .project(&self.session, ActivePolicy::AcceptedRetained, cancel)?;
        self.request.check()?;
        self.evidence.check()?;
        Ok(Arc::new(PreparedSearchCandidate {
            evidence: self.evidence,
            request: self.request,
            content_digest,
            outcome,
        }))
    }
}
impl fmt::Debug for LoadedSearchEvidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoadedSearchEvidence")
            .finish_non_exhaustive()
    }
}

/// Bounded occurrence identity. Strings have passed projection's 256-byte ID limit.
#[derive(Clone, Eq, PartialEq)]
pub struct OwnedPieceKey {
    pub message_id: String,
    pub message_position: usize,
    pub kind: PieceKind,
    pub piece_ordinal: usize,
    pub assistant_id: Option<String>,
    pub call_id: Option<String>,
}
impl fmt::Debug for OwnedPieceKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OwnedPieceKey")
            .field("kind", &self.kind)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExcerptCoverage {
    ExactHighlight,
    MatchEnvelopeExceedsBudget,
}
/// Exact source range is independent from the bounded preview. A large collapsed
/// whitespace envelope cannot be painted as an exact bounded excerpt highlight.
#[derive(Clone)]
pub struct OwnedHit {
    key: OwnedPieceKey,
    occurrence: Occurrence,
    target: SourceTarget,
    excerpt: String,
    excerpt_source: Range<usize>,
    highlight: Option<Range<usize>>,
    coverage: ExcerptCoverage,
}
impl OwnedHit {
    fn new(piece: &Piece<'_>, occurrence: Occurrence) -> Self {
        let source = &*piece.source;
        let envelope = occurrence.source.clone();
        let (mut start, mut end) = (envelope.start, envelope.end);
        let (coverage, highlight) = if envelope.len() > MAX_EXCERPT_BYTES {
            end = start + MAX_EXCERPT_BYTES;
            while !source.is_char_boundary(end) {
                end -= 1;
            }
            (ExcerptCoverage::MatchEnvelopeExceedsBudget, None)
        } else {
            // Source-side context only; word-aware UI layout remains a separate gate.
            for (offset, _) in source[..start].char_indices().rev().take(40) {
                if envelope.end - offset > MAX_EXCERPT_BYTES {
                    break;
                }
                start = offset;
            }
            for ch in source[end..].chars().take(160) {
                if end + ch.len_utf8() - start > MAX_EXCERPT_BYTES {
                    break;
                }
                end += ch.len_utf8();
            }
            (
                ExcerptCoverage::ExactHighlight,
                Some(envelope.start - start..envelope.end - start),
            )
        };
        Self {
            key: OwnedPieceKey {
                message_id: piece.key.message_id.into(),
                message_position: piece.key.message_position,
                kind: piece.key.kind,
                piece_ordinal: piece.key.piece_ordinal,
                assistant_id: piece.key.assistant_id.map(str::to_owned),
                call_id: piece.key.call_id.map(str::to_owned),
            },
            target: piece.target(envelope),
            occurrence,
            excerpt: source[start..end].into(),
            excerpt_source: start..end,
            highlight,
            coverage,
        }
    }
    pub fn key(&self) -> &OwnedPieceKey {
        &self.key
    }
    pub fn occurrence(&self) -> &Occurrence {
        &self.occurrence
    }
    pub fn target(&self) -> &SourceTarget {
        &self.target
    }
    pub fn excerpt(&self) -> &str {
        &self.excerpt
    }
    pub fn excerpt_source(&self) -> Range<usize> {
        self.excerpt_source.clone()
    }
    pub fn highlight(&self) -> Option<Range<usize>> {
        self.highlight.clone()
    }
    pub fn coverage(&self) -> ExcerptCoverage {
        self.coverage
    }
}
impl fmt::Debug for OwnedHit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OwnedHit")
            .field("kind", &self.key.kind)
            .field("coverage", &self.coverage)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Debug)]
pub enum SearchOutcome {
    Match(Box<OwnedHit>),
    NoMatch,
}
/// Immutable and bounded; contains no Session, projection, prefix chain or Controller.
/// Read only after slot admission; retained output is not a perpetual capability.
pub struct PreparedSearchCandidate {
    evidence: Evidence,
    request: SearchRequest,
    content_digest: [u8; 32],
    outcome: SearchOutcome,
}
impl PreparedSearchCandidate {
    pub(crate) fn check_for(&self, request: &SearchRequest) -> Result<(), SearchError> {
        if !self.request.same_request(request) {
            return Err(SearchError::WrongRequest);
        }
        self.request.check()?;
        self.evidence.check()
    }

    pub fn generation(&self) -> u64 {
        self.request.generation()
    }
    pub fn content_digest(&self) -> [u8; 32] {
        self.content_digest
    }
    pub fn query_digest(&self) -> [u8; 32] {
        self.request.0.query_digest
    }
    pub fn versions(&self) -> (u32, u32, u32) {
        (
            projection::PROJECTION_VERSION,
            projection::CANONICAL_MAPPING_VERSION,
            projection::NORMALIZATION_VERSION,
        )
    }
    pub fn member(&self) -> &MembershipMember {
        &self.evidence.member
    }
    pub fn membership_stamp(&self) -> &MembershipStamp {
        &self.evidence.membership
    }
    pub fn source_stamp(&self) -> &LoadedSourceStamp {
        &self.evidence.source
    }
    pub fn outcome(&self) -> &SearchOutcome {
        &self.outcome
    }
}
impl fmt::Debug for PreparedSearchCandidate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PreparedSearchCandidate")
            .field("generation", &self.generation())
            .field("outcome", &self.outcome)
            .finish_non_exhaustive()
    }
}

/// One query lifetime and at most one bounded retained candidate. No external
/// callback/guard can delay invalidation. Membership → source → slot is the only
/// nested order; invalidation writers never take the slot mutex.
pub struct SearchAdmissionSlot {
    request: SearchRequest,
    installed: Mutex<Option<Arc<PreparedSearchCandidate>>>,
}
impl SearchAdmissionSlot {
    pub fn new(request: &SearchRequest) -> Self {
        Self {
            request: request.clone(),
            installed: Mutex::new(None),
        }
    }
    pub fn try_install(&self, candidate: Arc<PreparedSearchCandidate>) -> Result<(), SearchError> {
        self.request.check()?;
        if candidate.request.0.id != self.request.0.id {
            return Err(SearchError::WrongRequest);
        }
        let evidence = &candidate.evidence;
        let owners = AdmissionOwners::pin(evidence)?;
        let result: Result<Option<Arc<PreparedSearchCandidate>>, SearchError> = (|| {
            let _membership = evidence
                .membership_witness
                .lock_current(&evidence.membership)
                .map_err(|_| SearchError::Stale)?;
            let _source = evidence
                .source_witness
                .lock_current(&evidence.source)
                .map_err(|_| SearchError::Stale)?;
            let mut slot = self
                .installed
                .lock()
                .map_err(|_| SearchError::Unavailable)?;
            #[cfg(test)]
            test_hook(TestStage::InstallFinal);
            self.request.check()?;
            owners.check()?;
            Ok(slot.replace(candidate.clone()))
        })();
        owners.revoke_observed_poison(evidence);
        let previous = result?;
        drop(previous); // Destruction is always outside witness and slot guards.
        Ok(())
    }
    /// Point-in-time admission only. Recheck for every held-result release/reveal.
    /// An empty slot is None; a stale slot is an error, never a fresh NoMatch.
    pub fn current(&self) -> Result<Option<Arc<PreparedSearchCandidate>>, SearchError> {
        self.request.check()?;
        let candidate = self
            .installed
            .lock()
            .map_err(|_| SearchError::Unavailable)?
            .clone();
        let Some(candidate) = candidate else {
            return Ok(None);
        };
        #[cfg(test)]
        test_hook(TestStage::CurrentCloned);
        let evidence = &candidate.evidence;
        let owners = AdmissionOwners::pin(evidence)?;
        let result = (|| {
            let _membership = evidence
                .membership_witness
                .lock_current(&evidence.membership)
                .map_err(|_| SearchError::Stale)?;
            let _source = evidence
                .source_witness
                .lock_current(&evidence.source)
                .map_err(|_| SearchError::Stale)?;
            let slot = self
                .installed
                .lock()
                .map_err(|_| SearchError::Unavailable)?;
            #[cfg(test)]
            test_hook(TestStage::CurrentFinal);
            self.request.check()?;
            owners.check()?;
            if !slot
                .as_ref()
                .is_some_and(|installed| Arc::ptr_eq(installed, &candidate))
            {
                return Err(SearchError::Stale);
            }
            Ok(())
        })();
        owners.revoke_observed_poison(evidence);
        result?;
        Ok(Some(candidate))
    }
    pub fn clear(&self) -> Result<(), SearchError> {
        let previous = self
            .installed
            .lock()
            .map_err(|_| SearchError::Unavailable)?
            .take();
        drop(previous);
        Ok(())
    }
}
#[cfg(test)]
#[path = "admission_tests.rs"]
mod tests;

#[cfg(test)]
#[derive(Clone, Copy, Eq, PartialEq)]
enum TestStage {
    InstallFinal,
    CurrentFinal,
    CurrentCloned,
    CapturedMembership,
}
#[cfg(test)]
type AdmissionTestHook = Option<Box<dyn FnMut(TestStage)>>;
#[cfg(test)]
thread_local! {
    static ADMISSION_TEST_HOOK: std::cell::RefCell<AdmissionTestHook> = std::cell::RefCell::new(None);
}
#[cfg(test)]
fn test_hook(stage: TestStage) {
    ADMISSION_TEST_HOOK.with(|hook| {
        if let Some(hook) = hook.borrow_mut().as_mut() {
            hook(stage);
        }
    });
}
