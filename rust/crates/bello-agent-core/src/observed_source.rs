//! Opaque read-only source evidence. A receipt describes bytes observed during
//! its interval, never fsync acceptance or currency after the lease is released.
use crate::{Result, invalid};
use sha2::{Digest, Sha256};
use std::{
    fmt,
    fs::{self, File, Metadata},
    path::{Path, PathBuf},
    time::{Instant, SystemTime},
};
use uuid::Uuid;

#[derive(Clone, Eq, PartialEq)]
pub struct ObservedFile {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    digest: [u8; 32],
}
impl ObservedFile {
    pub fn length(&self) -> u64 {
        self.length
    }
    pub fn digest(&self) -> [u8; 32] {
        self.digest
    }
    pub(crate) fn new(metadata: &Metadata, digest: [u8; 32]) -> Result<Self> {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            length: metadata.len(),
            modified: metadata.modified()?,
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
            digest,
        })
    }
}
impl fmt::Debug for ObservedFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ObservedFile")
            .field("length", &self.length)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ObservedJournal {
    LegacyNotApplicable,
    Absent,
    Present {
        file: ObservedFile,
        bytes_consumed: u64,
        complete_records: usize,
        first_sequence: Option<u64>,
        last_sequence: Option<u64>,
        final_record_end: u64,
    },
}
#[derive(Clone, Eq, PartialEq)]
pub struct ObservedRevision {
    schema: u32,
    generation: String,
    sequence: u64,
    revision: u64,
}
impl ObservedRevision {
    pub fn schema(&self) -> u32 {
        self.schema
    }
    pub fn generation(&self) -> &str {
        &self.generation
    }
    pub fn sequence(&self) -> u64 {
        self.sequence
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub(crate) fn of(s: &crate::Session) -> Self {
        Self {
            schema: s.version,
            generation: s.stream_generation.clone(),
            sequence: s.stream_sequence,
            revision: s.revision,
        }
    }
}
impl fmt::Debug for ObservedRevision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ObservedRevision")
            .field("schema", &self.schema)
            .field("sequence", &self.sequence)
            .field("revision", &self.revision)
            .finish_non_exhaustive()
    }
}
#[derive(Clone)]
pub struct ObservedSource {
    pub(crate) id: Uuid,
    pub(crate) path: PathBuf,
    pub(crate) session_id: String,
    pub(crate) checkpoint: ObservedFile,
    pub(crate) journal: ObservedJournal,
    pub(crate) initial: ObservedRevision,
    pub(crate) final_revision: ObservedRevision,
    pub(crate) lock: ObservedFile,
    pub(crate) started: Instant,
    pub(crate) finished: Instant,
}
impl ObservedSource {
    pub fn observation_id(&self) -> Uuid {
        self.id
    }
    pub fn checkpoint(&self) -> &ObservedFile {
        &self.checkpoint
    }
    pub fn journal(&self) -> &ObservedJournal {
        &self.journal
    }
    pub fn initial_revision(&self) -> &ObservedRevision {
        &self.initial
    }
    pub fn final_revision(&self) -> &ObservedRevision {
        &self.final_revision
    }
    pub fn interval(&self) -> (Instant, Instant) {
        (self.started, self.finished)
    }
    pub fn lock_identity(&self) -> &ObservedFile {
        &self.lock
    }
}
impl fmt::Debug for ObservedSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ObservedSource")
            .field("observation_id", &self.id)
            .field("journal", &self.journal)
            .finish_non_exhaustive()
    }
}

pub(crate) struct OpenObservation {
    pub path: PathBuf,
    pub file: File,
    pub before: Metadata,
}
impl OpenObservation {
    pub fn verify(&self) -> Result<()> {
        crate::session::verify_inspection_file(&self.path, &self.file, &self.before)
    }
}
pub(crate) enum JournalClosure {
    Legacy,
    Absent(PathBuf),
    Present(OpenObservation),
}
impl JournalClosure {
    pub fn verify(&self) -> Result<()> {
        match self {
            Self::Legacy => Ok(()),
            Self::Present(file) => file.verify(),
            Self::Absent(path) => match fs::symlink_metadata(path) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.into()),
                Ok(_) => Err(invalid("Journal appeared during observation")),
            },
        }
    }
}
/// Reject symlink/parent aliases and retain every ancestor's identity. This is
/// conservative point-in-time path validation, not a sandbox against same-user
/// noncooperating mutation. Advisory locks only exclude cooperating writers.
pub(crate) struct Ancestors(Vec<(PathBuf, Metadata)>);
impl Ancestors {
    pub fn capture(path: &Path) -> Result<Self> {
        if !path.is_absolute()
            || path.as_os_str().as_encoded_bytes().len() > 16 * 1024
            || path.components().any(|c| {
                matches!(
                    c,
                    std::path::Component::ParentDir | std::path::Component::CurDir
                )
            })
        {
            return Err(invalid("Ambiguous observed source path"));
        }
        let mut ancestors = Vec::new();
        for p in path
            .parent()
            .ok_or_else(|| invalid("Missing observed source parent"))?
            .ancestors()
        {
            let m = fs::symlink_metadata(p)?;
            if !m.is_dir() || m.file_type().is_symlink() {
                return Err(invalid("Unsafe observed source ancestor"));
            }
            ancestors.push((p.to_owned(), m));
        }
        Ok(Self(ancestors))
    }
    pub fn verify(&self) -> Result<()> {
        for (p, before) in &self.0 {
            let after = fs::symlink_metadata(p)?;
            if !after.is_dir() || after.file_type().is_symlink() {
                return Err(invalid("Observed source ancestor changed"));
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                if before.dev() != after.dev() || before.ino() != after.ino() {
                    return Err(invalid("Observed source ancestor changed"));
                }
            }
            #[cfg(not(unix))]
            {
                let _ = before;
            }
        }
        Ok(())
    }
}
pub(crate) fn digest(
    bytes: &[u8],
    cancel: Option<&dyn crate::sidebar_search::CancellationProbe>,
) -> Result<[u8; 32]> {
    let mut hash = Sha256::new();
    for chunk in bytes.chunks(64 * 1024) {
        #[cfg(test)]
        crate::inspection::observation_hook("checkpoint_hash");
        crate::inspection::check(cancel)?;
        hash.update(chunk);
    }
    crate::inspection::check(cancel)?;
    Ok(hash.finalize().into())
}
