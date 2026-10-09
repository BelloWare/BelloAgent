//! Disposable private acceleration. A cached row is never a source receipt.
//! Every lookup requires current loaded/observed evidence; App reconciliation and
//! fresh reveal still own admission. Connections remain on source/query workers.
#[cfg(any(test, target_os = "macos"))]
mod mac_acl;
#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod observer;
mod privacy;
mod query;
mod runtime;
#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests;
use super::{
    CancellationProbe, PreparedSearchCandidate, UnloadedObserved,
    projection::{self, SidebarProjection},
};
use crate::workspace_membership::{MembershipMember, MembershipStamp};
pub use privacy::platform_data_base;
pub use query::{CacheHint, CacheQueryHandle};
use rusqlite::{Connection, Transaction, TransactionBehavior, params};
use sha2::{Digest, Sha256};
use std::{
    fmt,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
};

type Result<T> = std::result::Result<T, CacheError>;
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CacheError {
    #[error("Content search privacy acceptance is pending")]
    PrivacyGatePending,
    #[error("Native content search privacy acceptance is pending")]
    PlatformPending,
    #[error("Private content cache location is unsafe or unavailable")]
    UnsafeLocation,
    #[error("Content cache is already owned or cleanup is busy")]
    Busy,
    #[error("SQLite source or no-spill capability does not match")]
    UnsupportedBuild,
    #[error("Content cache binding does not match")]
    BindingMismatch,
    #[error("Content cache work was cancelled or superseded")]
    Cancelled,
    #[error("Content cache resource budget was exceeded")]
    ResourceLimit,
    #[error("Content cache database is unavailable")]
    Database,
    #[error("Content cache cleanup is pending")]
    CleanupPending,
}
impl From<rusqlite::Error> for CacheError {
    fn from(_: rusqlite::Error) -> Self {
        Self::Database
    }
}
impl From<projection::Error> for CacheError {
    fn from(e: projection::Error) -> Self {
        if e == projection::Error::Cancelled {
            Self::Cancelled
        } else {
            Self::ResourceLimit
        }
    }
}

/// Compile-sealed acceptance, separate from runtime gates. Advance the platform's
/// reviewed record here only with the exact source/build/privacy test evidence in
/// docs/sidebar-private-cache.md. There is no environment or public API override.
/// Native acceptance is deliberately not inferred from Linux fixtures.
#[cfg(target_os = "linux")]
const LINUX_ACCEPTANCE_RECORD: Option<&str> = None;
#[cfg(target_os = "macos")]
const MACOS_ACCEPTANCE_RECORD: Option<&str> = None;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheReadiness {
    blocker: Option<CacheError>,
}
impl CacheReadiness {
    pub fn production() -> Self {
        #[cfg(target_os = "linux")]
        let blocker = LINUX_ACCEPTANCE_RECORD
            .is_none()
            .then_some(CacheError::PrivacyGatePending);
        #[cfg(target_os = "macos")]
        let blocker = MACOS_ACCEPTANCE_RECORD
            .is_none()
            .then_some(CacheError::PlatformPending);
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let blocker = Some(CacheError::PlatformPending);
        Self { blocker }
    }
    pub fn is_ready(self) -> bool {
        self.blocker.is_none()
    }
    pub fn reason(self) -> &'static str {
        match self.blocker {
            None => "Content search available after source reconciliation",
            Some(CacheError::CleanupPending) => "Content search unavailable: cache cleanup pending",
            Some(CacheError::PlatformPending) => {
                "Content search unavailable: native privacy checks pending"
            }
            _ => "Content search unavailable: privacy checks pending",
        }
    }
    pub fn error(self) -> Option<CacheError> {
        self.blocker
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct CacheBinding {
    encoded: Vec<u8>,
}
impl CacheBinding {
    pub fn from_membership(stamp: &MembershipStamp) -> Result<Self> {
        if !stamp.catalog_path().is_absolute() || !stamp.project_path().is_absolute() {
            return Err(CacheError::BindingMismatch);
        }
        Self::encode(&[
            stamp.catalog_path().as_os_str().as_encoded_bytes(),
            stamp.project_path().as_os_str().as_encoded_bytes(),
            &[u8::from(stamp.project_id().is_some())],
            stamp.project_id().unwrap_or("").as_bytes(),
        ])
    }
    fn encode(fields: &[&[u8]]) -> Result<Self> {
        let mut encoded = b"bello.private-search.binding.v1".to_vec();
        for field in fields {
            if field.len() > 16 * 1024 {
                return Err(CacheError::ResourceLimit);
            }
            encoded.extend_from_slice(&(field.len() as u64).to_le_bytes());
            encoded.extend_from_slice(field);
        }
        Ok(Self { encoded })
    }
    pub fn namespace(&self) -> String {
        Sha256::digest(&self.encoded)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
    fn matches(&self, stamp: &MembershipStamp) -> bool {
        Self::from_membership(stamp).is_ok_and(|v| v == *self)
    }
}
impl fmt::Debug for CacheBinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CacheBinding").finish_non_exhaustive()
    }
}

pub(crate) struct Barrier {
    epoch: AtomicU64,
    cleanup: AtomicBool,
    readers: AtomicUsize,
    closed: AtomicBool,
}
impl Barrier {
    fn new() -> Self {
        Self {
            epoch: AtomicU64::new(1),
            cleanup: AtomicBool::new(true),
            readers: AtomicUsize::new(0),
            closed: AtomicBool::new(false),
        }
    }
    fn suppress(&self) {
        self.cleanup.store(true, Ordering::SeqCst);
        let mut current = self.epoch.load(Ordering::SeqCst);
        loop {
            let Some(next) = current.checked_add(1) else {
                self.closed.store(true, Ordering::SeqCst);
                break;
            };
            match self
                .epoch
                .compare_exchange(current, next, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => break,
                Err(changed) => current = changed,
            }
        }
    }
}

pub struct PrivateCache {
    connection: Connection,
    directory: Arc<privacy::PrivateDirectory>,
    binding: CacheBinding,
    barrier: Arc<Barrier>,
    pending_suppression: std::collections::BTreeMap<String, bool>,
    vfs: Option<Arc<str>>,
}
impl fmt::Debug for PrivateCache {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PrivateCache").finish_non_exhaustive()
    }
}
impl PrivateCache {
    /// Explicit synthetic fixture route, never selected by production open().
    /// The caller owns a disposable 0700 test root and synthetic-only content.
    #[cfg(all(
        feature = "synthetic-authority",
        any(target_os = "linux", target_os = "macos")
    ))]
    pub fn open_synthetic_fixture(binding: CacheBinding, root: &std::path::Path) -> Result<Self> {
        runtime::probe()?;
        let directory = privacy::PrivateDirectory::fixture(root, &binding)?;
        Self::open_admitted(binding, directory, None)
    }

    pub fn open(binding: CacheBinding) -> Result<Self> {
        if let Some(error) = CacheReadiness::production().error() {
            return Err(error);
        }
        // Before opening any content-bearing file or binding any user data.
        runtime::probe()?;
        let directory = privacy::PrivateDirectory::open(&binding)?;
        Self::open_admitted(binding, directory, None)
    }
    fn open_admitted(
        binding: CacheBinding,
        directory: privacy::PrivateDirectory,
        vfs: Option<&str>,
    ) -> Result<Self> {
        runtime::probe()?;
        let path = directory.path.join("cache.sqlite3");
        let flags =
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let connection = match vfs {
            Some(vfs) => Connection::open_with_flags_and_vfs(path, flags, vfs)?,
            None => Connection::open_with_flags(path, flags)?,
        };
        runtime::configure(&connection, false)?;
        connection.execute_batch(SCHEMA)?;
        let stored: Option<Vec<u8>> = connection
            .query_row("SELECT binding FROM meta WHERE id=1", [], |r| r.get(0))
            .optional()?;
        if stored.as_ref().is_some_and(|v| v != &binding.encoded) {
            return Err(CacheError::BindingMismatch);
        }
        connection.execute(
            "INSERT OR IGNORE INTO meta(id,binding,cleanup_pending) VALUES(1,?1,1)",
            [&binding.encoded],
        )?;
        let versions: (u32,u32,u32,u32) = connection.query_row("SELECT schema_version,projection_version,normalization_version,mapping_version FROM meta WHERE id=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
        if versions
            != (
                1,
                projection::PROJECTION_VERSION,
                projection::NORMALIZATION_VERSION,
                projection::CANONICAL_MAPPING_VERSION,
            )
        {
            return Err(CacheError::BindingMismatch);
        }
        connection.execute_batch("INSERT INTO docs(docs,rank) VALUES('secure-delete',1)")?;
        let secure: i64 = connection.query_row(
            "SELECT v FROM docs_config WHERE k='secure-delete'",
            [],
            |r| r.get(0),
        )?;
        if secure != 1 {
            return Err(CacheError::UnsupportedBuild);
        }
        let mut out = Self {
            connection,
            directory: Arc::new(directory),
            binding,
            barrier: Arc::new(Barrier::new()),
            pending_suppression: std::collections::BTreeMap::new(),
            vfs: vfs.map(Arc::from),
        };
        // Conservative startup rebuild. Old persisted rows never authorize hits,
        // including after a crash before the cleanup marker was cleared.
        out.mark_pending()?;
        out.connection
            .execute_batch("BEGIN IMMEDIATE; DELETE FROM pieces; DELETE FROM chats; COMMIT;")?;
        out.cleanup()?;
        Ok(out)
    }
    fn mark_pending(&self) -> Result<()> {
        self.barrier.suppress();
        if self.barrier.closed.load(Ordering::SeqCst) {
            return Err(CacheError::ResourceLimit);
        }
        self.connection
            .execute("UPDATE meta SET cleanup_pending=1 WHERE id=1", [])?;
        Ok(())
    }
    pub fn begin_replacement_for_work(
        &mut self,
        work: &super::reconciliation::SearchWork,
    ) -> Result<Replacement<'_>> {
        work.check().map_err(|_| CacheError::Cancelled)?;
        self.begin_replacement_inner(work.member(), Some(work.clone()))
    }
    pub fn begin_replacement(&mut self, member: &MembershipMember) -> Result<Replacement<'_>> {
        self.begin_replacement_inner(member, None)
    }
    fn begin_replacement_inner(
        &mut self,
        member: &MembershipMember,
        work: Option<super::reconciliation::SearchWork>,
    ) -> Result<Replacement<'_>> {
        self.connection.progress_handler(0, None::<fn() -> bool>)?;
        let chat = member.chat_id();
        if chat.len() > 256 {
            return Err(CacheError::ResourceLimit);
        }
        self.mark_pending()?;
        self.apply_suppression()?;
        self.directory.validate_siblings()?;
        let operations = std::sync::atomic::AtomicUsize::new(0);
        let callback_work = work.clone();
        self.connection.progress_handler(
            1000,
            Some(move || {
                callback_work.as_ref().is_some_and(|work| {
                    work.request.is_cancelled() || work.cancellation().load(Ordering::Acquire)
                }) || operations.fetch_add(1000, Ordering::Relaxed) >= 50_000_000
            }),
        )?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let tombstone: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM tombstones WHERE chat_id=?1)",
            [chat],
            |r| r.get(0),
        )?;
        if tombstone {
            return Err(CacheError::BindingMismatch);
        }
        transaction.execute("DELETE FROM pieces WHERE chat_id=?1", [chat])?;
        transaction.execute("DELETE FROM chats WHERE chat_id=?1", [chat])?;
        Ok(Replacement {
            transaction: Some(transaction),
            chat: chat.to_owned(),
            checkpoint: member.checkpoint_path().to_owned(),
            binding: &self.binding,
            staged: None,
            bytes: 0,
            chunks: 0,
            work,
        })
    }
    /// Call after logical suppression in the coordinator. Failure keeps the
    /// admission barrier closed even when the durable tombstone write failed.
    pub fn invalidate(&mut self, chat_id: &str) -> Result<()> {
        self.suppress_chat(chat_id, false)
    }
    pub fn delete(&mut self, chat_id: &str) -> Result<()> {
        self.suppress_chat(chat_id, true)
    }
    fn suppress_chat(&mut self, chat_id: &str, permanent: bool) -> Result<()> {
        self.barrier.suppress();
        if chat_id.len() > 256
            || (self.pending_suppression.len() >= 512
                && !self.pending_suppression.contains_key(chat_id))
        {
            self.barrier.closed.store(true, Ordering::SeqCst);
            return Err(CacheError::ResourceLimit);
        }
        self.pending_suppression
            .entry(chat_id.to_owned())
            .and_modify(|value| *value |= permanent)
            .or_insert(permanent);
        self.connection.progress_handler(0, None::<fn() -> bool>)?;
        self.mark_pending()?;
        self.apply_suppression()?;
        self.cleanup()
    }
    fn apply_suppression(&mut self) -> Result<()> {
        if self.pending_suppression.is_empty() {
            return Ok(());
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        for (chat_id, permanent) in &self.pending_suppression {
            if *permanent {
                tx.execute(
                    "INSERT OR IGNORE INTO tombstones(chat_id) VALUES(?1)",
                    [chat_id],
                )?;
            }
            tx.execute("DELETE FROM pieces WHERE chat_id=?1", [chat_id])?;
            tx.execute("DELETE FROM chats WHERE chat_id=?1", [chat_id])?;
        }
        tx.commit()?;
        self.pending_suppression.clear();
        Ok(())
    }
    /// No new readers enter after suppression. Old readers observe the epoch in
    /// their progress callback and exit. Caller retries Busy with bounded backoff;
    /// neither a busy row nor a failed cleanup ever becomes availability.
    pub fn cleanup(&mut self) -> Result<()> {
        self.connection.progress_handler(0, None::<fn() -> bool>)?;
        self.barrier.suppress();
        if self.barrier.closed.load(Ordering::SeqCst) {
            return Err(CacheError::ResourceLimit);
        }
        if self.barrier.readers.load(Ordering::SeqCst) != 0 {
            return Err(CacheError::Busy);
        }
        // Failed deletion/invalidation intent survives in memory. A checkpoint
        // alone must never turn that failed write into successful cleanup.
        self.apply_suppression()?;
        self.directory.validate_siblings()?;
        checkpoint(&self.connection, &self.directory.path)?;
        self.connection
            .execute("UPDATE meta SET cleanup_pending=0 WHERE id=1", [])?;
        // Clearing the marker also writes WAL. Verify the *final* named WAL.
        checkpoint(&self.connection, &self.directory.path)?;
        self.directory.validate_siblings()?;
        self.barrier.cleanup.store(false, Ordering::SeqCst);
        Ok(())
    }
    pub fn readiness(&self) -> CacheReadiness {
        CacheReadiness {
            blocker: if self.barrier.closed.load(Ordering::SeqCst) {
                Some(CacheError::ResourceLimit)
            } else {
                self.barrier
                    .cleanup
                    .load(Ordering::SeqCst)
                    .then_some(CacheError::CleanupPending)
            },
        }
    }
    pub fn query_handle(&self) -> CacheQueryHandle {
        CacheQueryHandle::new(
            self.directory.clone(),
            self.barrier.clone(),
            self.binding.clone(),
            self.vfs.clone(),
        )
    }
}
impl Drop for PrivateCache {
    fn drop(&mut self) {
        self.barrier.closed.store(true, Ordering::SeqCst);
        self.barrier.suppress();
    }
}
use rusqlite::OptionalExtension;
fn checkpoint(connection: &Connection, directory: &std::path::Path) -> Result<()> {
    let result: (i64, i64, i64) =
        connection.query_row("PRAGMA main.wal_checkpoint(TRUNCATE)", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?;
    if result != (0, 0, 0) {
        return Err(CacheError::CleanupPending);
    }
    match std::fs::symlink_metadata(directory.join("cache.sqlite3-wal")) {
        Ok(m) if m.is_file() && m.len() == 0 => Ok(()),
        _ => Err(CacheError::CleanupPending),
    }
}

/// Transaction-local staging. Not Send across an await. Dropping a failed or
/// cancelled replacement rolls back; the durable cleanup marker remains set.
pub struct Replacement<'a> {
    transaction: Option<Transaction<'a>>,
    chat: String,
    checkpoint: PathBuf,
    binding: &'a CacheBinding,
    staged: Option<[u8; 32]>,
    bytes: usize,
    chunks: usize,
    work: Option<super::reconciliation::SearchWork>,
}
impl Replacement<'_> {
    fn clear_progress(&self) {
        if let Some(tx) = &self.transaction {
            // SAFETY: this worker exclusively owns the live transaction. The
            // official API only removes its callback; rusqlite retains/drops the
            // closure allocation on its next handler replacement or close.
            unsafe {
                rusqlite::ffi::sqlite3_progress_handler(tx.handle(), 0, None, std::ptr::null_mut());
            }
        }
    }
    pub(crate) fn stage(
        &mut self,
        projection: &SidebarProjection<'_>,
        digest: [u8; 32],
        cancel: &dyn CancellationProbe,
    ) -> Result<()> {
        if projection.chat_id != self.chat
            || projection.deferred_from.is_some()
            || self.staged.is_some()
        {
            return Err(CacheError::BindingMismatch);
        }
        let tx = self.transaction.as_ref().ok_or(CacheError::Database)?;
        tx.execute(
            "INSERT INTO chats(chat_id,digest) VALUES(?1,?2)",
            params![self.chat, digest.as_slice()],
        )?;
        for (piece_index, piece) in projection.pieces.iter().enumerate() {
            projection::normalized_chunks(&piece.source, cancel, |start, text| {
                self.bytes = self
                    .bytes
                    .checked_add(text.len())
                    .ok_or(CacheError::ResourceLimit)?;
                self.chunks += 1;
                // Explicit additional normalized-text/statement-journal budget.
                // Rebuild fails visibly instead of truncating searchable coverage.
                if self.bytes > 256 * 1024 * 1024 || self.chunks > 131_072 {
                    return Err(CacheError::ResourceLimit);
                }
                if cancel.is_cancelled() {
                    return Err(CacheError::Cancelled);
                }
                tx.execute("INSERT INTO pieces(chat_id,piece_index,message_position,piece_ordinal,chunk_start,normalized_text) VALUES(?1,?2,?3,?4,?5,?6)", params![self.chat,piece_index as i64,piece.key.message_position as i64,piece.key.piece_ordinal as i64,start as i64,text])?;
                Ok(())
            })?;
        }
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        self.staged = Some(digest);
        Ok(())
    }
    fn check_work(&self) -> Result<()> {
        if let Some(work) = &self.work {
            work.check().map_err(|_| CacheError::Cancelled)?;
        }
        Ok(())
    }
    fn verify(
        &self,
        member: &MembershipMember,
        stamp: &MembershipStamp,
        digest: [u8; 32],
    ) -> Result<()> {
        self.check_work()?;
        if self.chat != member.chat_id()
            || self.checkpoint != member.checkpoint_path()
            || !self.binding.matches(stamp)
            || self.staged != Some(digest)
        {
            return Err(CacheError::BindingMismatch);
        }
        Ok(())
    }
    pub fn commit_loaded(mut self, candidate: &PreparedSearchCandidate) -> Result<()> {
        candidate.cache_check().map_err(|_| CacheError::Cancelled)?;
        self.verify(
            candidate.member(),
            candidate.membership_stamp(),
            candidate.content_digest(),
        )?;
        self.clear_progress();
        self.transaction
            .take()
            .ok_or(CacheError::Database)?
            .commit()?;
        // No witness guard spans SQL. A lost race leaves inaccessible durable rows.
        candidate.cache_check().map_err(|_| CacheError::Cancelled)?;
        self.check_work()
    }
    pub fn commit_observed(mut self, candidate: &UnloadedObserved) -> Result<()> {
        candidate
            .work
            .require_unloaded()
            .map_err(|_| CacheError::Cancelled)?;
        self.verify(
            candidate.member(),
            candidate.membership_stamp(),
            candidate.content_digest(),
        )?;
        self.clear_progress();
        self.transaction
            .take()
            .ok_or(CacheError::Database)?
            .commit()?;
        candidate
            .work
            .require_unloaded()
            .map_err(|_| CacheError::Cancelled)?;
        self.check_work()
    }
}

impl Drop for Replacement<'_> {
    fn drop(&mut self) {
        self.clear_progress();
    }
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),binding BLOB NOT NULL,cleanup_pending INTEGER NOT NULL,schema_version INTEGER NOT NULL DEFAULT 1,projection_version INTEGER NOT NULL DEFAULT 1,normalization_version INTEGER NOT NULL DEFAULT 1,mapping_version INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS chats(chat_id TEXT PRIMARY KEY,digest BLOB NOT NULL CHECK(length(digest)=32));
CREATE TABLE IF NOT EXISTS tombstones(chat_id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS pieces(id INTEGER PRIMARY KEY AUTOINCREMENT,chat_id TEXT NOT NULL,piece_index INTEGER NOT NULL,message_position INTEGER NOT NULL,piece_ordinal INTEGER NOT NULL,chunk_start INTEGER NOT NULL,normalized_text TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS piece_order ON pieces(chat_id,message_position DESC,piece_ordinal,chunk_start);
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(normalized_text,content='pieces',content_rowid='id',tokenize='trigram case_sensitive 1',detail=full);
CREATE TRIGGER IF NOT EXISTS piece_insert AFTER INSERT ON pieces BEGIN INSERT INTO docs(rowid,normalized_text) VALUES(new.id,new.normalized_text); END;
CREATE TRIGGER IF NOT EXISTS piece_delete AFTER DELETE ON pieces BEGIN INSERT INTO docs(docs,rowid,normalized_text) VALUES('delete',old.id,old.normalized_text); END;
";
