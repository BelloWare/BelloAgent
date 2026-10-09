use super::{
    Barrier, CacheBinding, CacheError, CacheReadiness, Result, privacy::PrivateDirectory, runtime,
};
use crate::sidebar_search::{
    PreparedSearchCandidate, SearchOutcome, SearchRequest, UnloadedObserved,
};
use rusqlite::{Connection, params};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

/// Advisory candidate only. It is deliberately not an OwnedHit/SearchOutcome and
/// cannot enter reconciliation. Fresh projection remains the UI/reveal authority.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheHint {
    pub piece_index: usize,
    pub normalized_start: usize,
    pub message_position: usize,
    pub piece_ordinal: usize,
}
#[derive(Clone)]
pub struct CacheQueryHandle {
    directory: Arc<PrivateDirectory>,
    barrier: Arc<Barrier>,
    binding: CacheBinding,
    vfs: Option<Arc<str>>,
    #[cfg(test)]
    pub(super) instruction_budget: usize,
}
impl CacheQueryHandle {
    pub(super) fn new(
        directory: Arc<PrivateDirectory>,
        barrier: Arc<Barrier>,
        binding: CacheBinding,
        vfs: Option<Arc<str>>,
    ) -> Self {
        Self {
            directory,
            barrier,
            binding,
            vfs,
            #[cfg(test)]
            instruction_budget: 10_000_000,
        }
    }
    /// Point-in-time UI admission only; never touches SQLite or the filesystem.
    /// Recheck for display/hold/reveal, rather than retaining this copied value.
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
    /// Run on the single cancellable query worker. No connection is shared with
    /// the writer/UI, and a whole lookup uses one reader transaction.
    pub fn query_loaded(
        &self,
        evidence: &PreparedSearchCandidate,
        cancel: Arc<AtomicBool>,
    ) -> Result<Option<CacheHint>> {
        evidence.cache_check().map_err(|_| CacheError::Cancelled)?;
        if !self.binding.matches(evidence.membership_stamp()) {
            return Err(CacheError::BindingMismatch);
        }
        let value = self.lookup(
            evidence.member().chat_id(),
            evidence.content_digest(),
            evidence.cache_request(),
            cancel,
        )?;
        evidence.cache_check().map_err(|_| CacheError::Cancelled)?;
        Self::verify_hint(evidence.outcome(), &value)?;
        Ok(value)
    }
    pub fn query_observed(
        &self,
        evidence: &UnloadedObserved,
        cancel: Arc<AtomicBool>,
    ) -> Result<Option<CacheHint>> {
        evidence
            .work
            .require_unloaded()
            .map_err(|_| CacheError::Cancelled)?;
        if !self.binding.matches(evidence.membership_stamp()) {
            return Err(CacheError::BindingMismatch);
        }
        let value = self.lookup(
            evidence.member().chat_id(),
            evidence.content_digest(),
            &evidence.work.request,
            cancel,
        )?;
        evidence
            .work
            .require_unloaded()
            .map_err(|_| CacheError::Cancelled)?;
        Self::verify_hint(evidence.outcome(), &value)?;
        Ok(value)
    }
    fn verify_hint(outcome: &SearchOutcome, hint: &Option<CacheHint>) -> Result<()> {
        match (outcome, hint) {
            (SearchOutcome::NoMatch, None) => Ok(()),
            (SearchOutcome::Match(hit), Some(hint))
                if hit.key().message_position == hint.message_position
                    && hit.key().piece_ordinal == hint.piece_ordinal
                    && hit.occurrence().normalized.start == hint.normalized_start =>
            {
                Ok(())
            }
            _ => Err(CacheError::BindingMismatch),
        }
    }
    pub(super) fn lookup(
        &self,
        chat: &str,
        digest: [u8; 32],
        request: &SearchRequest,
        cancel: Arc<AtomicBool>,
    ) -> Result<Option<CacheHint>> {
        let epoch = self.barrier.epoch.load(Ordering::SeqCst);
        if self.barrier.cleanup.load(Ordering::SeqCst) || self.barrier.closed.load(Ordering::SeqCst)
        {
            return Err(CacheError::CleanupPending);
        }
        if self
            .barrier
            .readers
            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err(CacheError::Busy);
        }
        struct Reader<'a>(&'a Barrier);
        impl Drop for Reader<'_> {
            fn drop(&mut self) {
                self.0.readers.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let _reader = Reader(&self.barrier);
        #[cfg(test)]
        ENTRY_HOOK.with(|hook| {
            if let Some(hook) = hook.borrow_mut().take() {
                hook();
            }
        });
        if self.barrier.cleanup.load(Ordering::SeqCst)
            || self.barrier.closed.load(Ordering::SeqCst)
            || self.barrier.epoch.load(Ordering::SeqCst) != epoch
        {
            return Err(CacheError::CleanupPending);
        }
        self.directory.validate_siblings()?;
        runtime::probe()?;
        let flags =
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let path = self.directory.path.join("cache.sqlite3");
        let mut connection = match &self.vfs {
            Some(vfs) => Connection::open_with_flags_and_vfs(path, flags, vfs.as_ref())?,
            None => Connection::open_with_flags(path, flags)?,
        };
        runtime::configure(&connection, true)?;
        let barrier = self.barrier.clone();
        let request_cancel = request.clone();
        let signal = cancel.clone();
        let instructions = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let used = instructions.clone();
        #[cfg(test)]
        let budget = self.instruction_budget;
        #[cfg(not(test))]
        let budget = 10_000_000;
        connection.progress_handler(
            1000,
            Some(move || {
                signal.load(Ordering::Acquire)
                    || request_cancel.is_cancelled()
                    || barrier.closed.load(Ordering::SeqCst)
                    || barrier.epoch.load(Ordering::SeqCst) != epoch
                    || used.fetch_add(1000, Ordering::Relaxed) >= budget
            }),
        )?;
        let tx = connection.transaction()?;
        let literal = request.normalized_query();
        let phrase = format!("\"{}\"", literal.replace('"', "\"\""));
        let mut key = (-1i64, -1i64, -1i64);
        let mut scanned = 0usize;
        let result = loop {
            if cancel.load(Ordering::Acquire)
                || request.is_cancelled()
                || self.barrier.closed.load(Ordering::SeqCst)
                || self.barrier.epoch.load(Ordering::SeqCst) != epoch
            {
                return Err(CacheError::Cancelled);
            }
            // Bounded keyset page. Ordering is newest message, prose then call,
            // earliest chunk. No LIMIT-before-refinement false-empty shortcut.
            let mut statement = tx.prepare("SELECT p.piece_index,p.message_position,p.piece_ordinal,p.chunk_start,p.normalized_text FROM docs JOIN pieces p ON p.id=docs.rowid JOIN chats c ON c.chat_id=p.chat_id WHERE docs MATCH ?1 AND p.chat_id=?2 AND c.digest=?3 AND NOT EXISTS(SELECT 1 FROM tombstones t WHERE t.chat_id=p.chat_id) AND (?4=-1 OR p.message_position<?4 OR (p.message_position=?4 AND p.piece_ordinal>?5) OR (p.message_position=?4 AND p.piece_ordinal=?5 AND p.chunk_start>?6)) ORDER BY p.message_position DESC,p.piece_ordinal,p.chunk_start LIMIT 16")?;
            let rows = statement.query_map(
                params![phrase, chat, digest.as_slice(), key.0, key.1, key.2],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                },
            )?;
            let mut any = false;
            let mut winner = None;
            for row in rows {
                let (piece, position, ordinal, start, text) = row?;
                any = true;
                scanned += 1;
                if scanned > 131_072 {
                    return Err(CacheError::ResourceLimit);
                }
                let piece_index = usize::try_from(piece).map_err(|_| CacheError::Database)?;
                let message_position =
                    usize::try_from(position).map_err(|_| CacheError::Database)?;
                let piece_ordinal = usize::try_from(ordinal).map_err(|_| CacheError::Database)?;
                let chunk_start = usize::try_from(start).map_err(|_| CacheError::Database)?;
                if piece_index >= crate::sidebar_search::projection::MAX_PIECES
                    || message_position >= crate::sidebar_search::projection::MAX_PIECES
                    || piece_ordinal >= crate::sidebar_search::projection::MAX_PIECES
                    || chunk_start > 256 * 1024 * 1024
                    || text.len() > 32_768 * 4
                    || text.chars().count() > 32_768
                {
                    return Err(CacheError::Database);
                }
                key = (position, ordinal, start);
                if let Some(offset) = text.find(&literal) {
                    winner = Some(CacheHint {
                        piece_index,
                        normalized_start: chunk_start
                            .checked_add(offset)
                            .ok_or(CacheError::Database)?,
                        message_position,
                        piece_ordinal,
                    });
                    break;
                }
            }
            if winner.is_some() {
                break winner;
            }
            if !any {
                break None;
            }
        };
        tx.commit()?;
        if cancel.load(Ordering::Acquire)
            || request.is_cancelled()
            || self.barrier.closed.load(Ordering::SeqCst)
            || self.barrier.epoch.load(Ordering::SeqCst) != epoch
        {
            return Err(CacheError::Cancelled);
        }
        self.directory.validate_siblings()?;
        Ok(result)
    }
}

#[cfg(test)]
thread_local! {
    static ENTRY_HOOK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = std::cell::RefCell::new(None);
}
#[cfg(test)]
pub(super) fn on_reader_entry(hook: impl FnOnce() + 'static) {
    ENTRY_HOOK.with(|slot| *slot.borrow_mut() = Some(Box::new(hook)));
}
