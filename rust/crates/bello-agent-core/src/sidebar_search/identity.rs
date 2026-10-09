//! Semantic content identity only. Never a source-admission/durability receipt.
//! A production caller must separately bind catalog/project/source incarnation,
//! checkpoint+journal evidence and atomic Controller certainty. Inodes, mtimes,
//! stream generations and equal digests alone do not prove lineage or admission.
use super::CancellationProbe;
use super::projection::{
    CANONICAL_MAPPING_VERSION, NORMALIZATION_VERSION, PROJECTION_VERSION, PieceKind, Result,
    SidebarProjection, check_cancel,
};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContentIdentity {
    pub digest: [u8; 32],
    /// Ordered prefix chain for later append proof; not append permission.
    pub prefixes: Vec<[u8; 32]>,
    pub piece_count: usize,
}
fn number(hash: &mut Sha256, value: usize) {
    hash.update((value as u64).to_le_bytes());
}
fn field(hash: &mut Sha256, bytes: &[u8], cancel: &dyn CancellationProbe) -> Result<()> {
    number(hash, bytes.len());
    for chunk in bytes.chunks(4096) {
        check_cancel(cancel)?;
        hash.update(chunk);
    }
    Ok(())
}
fn optional(hash: &mut Sha256, text: Option<&str>, cancel: &dyn CancellationProbe) -> Result<()> {
    hash.update([u8::from(text.is_some())]);
    if let Some(text) = text {
        field(hash, text.as_bytes(), cancel)?;
    }
    Ok(())
}
impl ContentIdentity {
    /// Worker-only. Includes exact pre-normalized source, identities, role/kind,
    /// order, ownership, segment boundaries, versions and incomplete-prefix state.
    /// Excluded hidden containers intentionally never enter this digest.
    pub fn of(projection: &SidebarProjection<'_>, cancel: &dyn CancellationProbe) -> Result<Self> {
        check_cancel(cancel)?;
        let mut seed = Sha256::new();
        field(&mut seed, b"bello.sidebar.content.v1", cancel)?;
        seed.update(PROJECTION_VERSION.to_le_bytes());
        seed.update(NORMALIZATION_VERSION.to_le_bytes());
        seed.update(CANONICAL_MAPPING_VERSION.to_le_bytes());
        field(&mut seed, projection.chat_id.as_bytes(), cancel)?;
        let mut previous: [u8; 32] = seed.finalize().into();
        let mut prefixes = Vec::with_capacity(projection.pieces.len());
        for piece in &projection.pieces {
            check_cancel(cancel)?;
            let mut hash = Sha256::new();
            hash.update(previous);
            field(&mut hash, piece.key.message_id.as_bytes(), cancel)?;
            number(&mut hash, piece.key.message_position);
            number(&mut hash, piece.key.piece_ordinal);
            hash.update([match piece.key.kind {
                PieceKind::User => 0,
                PieceKind::Assistant => 1,
                PieceKind::ToolInput => 2,
                PieceKind::ToolOutput => 3,
            }]);
            optional(&mut hash, piece.key.assistant_id, cancel)?;
            optional(&mut hash, piece.key.call_id, cancel)?;
            hash.update([u8::from(piece.input_start.is_some())]);
            if let Some(start) = piece.input_start {
                number(&mut hash, start);
            }
            field(&mut hash, piece.source.as_bytes(), cancel)?;
            previous = hash.finalize().into();
            prefixes.push(previous);
        }
        let mut final_hash = Sha256::new();
        final_hash.update(previous);
        number(&mut final_hash, projection.pieces.len());
        final_hash.update([u8::from(projection.deferred_from.is_some())]);
        if let Some(position) = projection.deferred_from {
            number(&mut final_hash, position);
        }
        check_cancel(cancel)?;
        Ok(Self {
            digest: final_hash.finalize().into(),
            prefixes,
            piece_count: projection.pieces.len(),
        })
    }
}
