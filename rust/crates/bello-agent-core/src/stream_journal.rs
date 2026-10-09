//! Private, generation-scoped append journal for streamed output. Each complete
//! record is synced before it is published. Checkpoints rotate generations only
//! after their atomic snapshot is durable, so deleting an older journal is safe.
use crate::{Delta, Result, Session, invalid};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;
pub(crate) const MAX_JOURNAL_BYTES: u64 = 512 * 1024 * 1024;
const MAX_RECORD_BYTES: usize = 16 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
struct Record {
    version: u32,
    session: String,
    generation: String,
    sequence: u64,
    reply: String,
    delta: Delta,
}
#[derive(Default)]
pub(crate) struct Replay {
    pub exists: bool,
    pub records: usize,
    pub incomplete_tail: bool,
}
pub(crate) fn path(snapshot: &Path, generation: &str) -> Result<PathBuf> {
    Uuid::parse_str(generation).map_err(|_| invalid("Invalid stream journal generation"))?;
    let name = snapshot
        .file_name()
        .ok_or_else(|| invalid("Snapshot has no filename"))?
        .to_string_lossy();
    Ok(snapshot.with_file_name(format!("{name}.{generation}.stream.jsonl")))
}
pub(crate) fn encode(session: &Session, reply: &str, delta: &Delta) -> Result<Vec<u8>> {
    let record = Record {
        version: 1,
        session: session.id.clone(),
        generation: session.stream_generation.clone(),
        sequence: session
            .stream_sequence
            .checked_add(1)
            .ok_or_else(|| invalid("Stream journal sequence overflow"))?,
        reply: reply.into(),
        delta: delta.clone(),
    };
    let mut bytes = serde_json::to_vec(&record)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(invalid("A stream journal record exceeds 16 MiB"));
    }
    Ok(bytes)
}
pub(crate) fn create(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.create_new(true).append(true).read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}
pub(crate) fn append(file: &mut File, bytes: &[u8]) -> std::io::Result<()> {
    file.write_all(bytes)?;
    file.sync_all()
}
/// An incomplete final line was never acknowledged by append+fsync. Keep the
/// old generation for inspection and checkpoint only its complete valid prefix.
/// Malformed complete records, gaps and foreign identities are refused.
pub(crate) fn replay(snapshot: &Path, session: &mut Session) -> Result<Replay> {
    replay_with_confirmation(snapshot, session, true)
}

/// Inspection uses the same format/identity validation without opening the
/// journal for writing or synchronizing it. Readable bytes do not prove a prior
/// uncertain append durable, and this path cannot authorize recovery writes.
pub(crate) fn replay_read_only(snapshot: &Path, session: &mut Session) -> Result<Replay> {
    replay_with_confirmation(snapshot, session, false)
}

fn open_after_metadata(
    path: &Path,
    metadata: &fs::Metadata,
    confirm_durability: bool,
) -> Result<File> {
    if confirm_durability {
        // Preserve the writer's existing recovery/durability path.
        Ok(OpenOptions::new().read(true).write(true).open(path)?)
    } else {
        // Reuse the same nonblocking, regular-file and identity checks as the
        // inspection checkpoint/lock. A FIFO swap after stat must not hang.
        crate::session::open_inspection_file_with_metadata(path, false, metadata)
    }
}

fn replay_with_confirmation(
    snapshot: &Path,
    session: &mut Session,
    confirm_durability: bool,
) -> Result<Replay> {
    let path = path(snapshot, &session.stream_generation)?;
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Replay::default()),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(invalid("Stream journal is not a regular private file"));
    }
    if metadata.len() > MAX_JOURNAL_BYTES {
        return Err(invalid("Stream journal exceeds its 512 MiB recovery limit"));
    }
    let file = open_after_metadata(&path, &metadata, confirm_durability)?;
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut outcome = Replay {
        exists: true,
        ..Default::default()
    };
    let mut consumed = 0u64;
    loop {
        let mut line = Vec::new();
        loop {
            let buffer = reader.fill_buf()?;
            if buffer.is_empty() {
                break;
            }
            let count = buffer
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(buffer.len(), |i| i + 1);
            if line.len() + count > MAX_RECORD_BYTES {
                return Err(invalid("Stream journal record exceeds its recovery limit"));
            }
            consumed += count as u64;
            if consumed > MAX_JOURNAL_BYTES {
                return Err(invalid("Stream journal exceeds its 512 MiB recovery limit"));
            }
            line.extend_from_slice(&buffer[..count]);
            reader.consume(count);
            if line.last() == Some(&b'\n') {
                break;
            }
        }
        if line.is_empty() {
            break;
        }
        if line.last() != Some(&b'\n') {
            outcome.incomplete_tail = true;
            break;
        }
        let record: Record = serde_json::from_slice(&line).map_err(|_| {
            invalid("Malformed complete stream journal record; original data is preserved")
        })?;
        if record.version != 1
            || record.session != session.id
            || record.generation != session.stream_generation
            || Some(record.sequence) != session.stream_sequence.checked_add(1)
        {
            return Err(invalid(
                "Stream journal identity or sequence does not match its checkpoint",
            ));
        }
        let revision = session
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("Stream journal session revision overflow"))?;
        session.delta(&record.reply, record.delta)?;
        session.stream_sequence = record.sequence;
        session.revision = revision;
        outcome.records += 1;
    }
    // Confirm bytes readable after an earlier uncertain synchronization before
    // allowing a new durable checkpoint to depend on them.
    if confirm_durability {
        reader.get_ref().sync_all()?;
    } else {
        crate::session::verify_inspection_file(&path, reader.get_ref(), &metadata)?;
    }
    Ok(outcome)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Lane, Submission};
    fn active() -> Session {
        let mut session = Session::new();
        session
            .submit(Submission::new("input".into(), Lane::FollowUp))
            .unwrap();
        session.start_next().unwrap();
        session
    }
    #[test]
    fn valid_prefix_replays_and_torn_tail_is_identified() {
        let dir = tempfile::tempdir().unwrap();
        let snapshot = dir.path().join("s.json");
        let mut session = active();
        let reply = session.active_reply.clone().unwrap();
        let mut file = create(&path(&snapshot, &session.stream_generation).unwrap()).unwrap();
        append(
            &mut file,
            &encode(&session, &reply, &Delta::Text("héllo".into())).unwrap(),
        )
        .unwrap();
        file.write_all(b"{partial").unwrap();
        let result = replay(&snapshot, &mut session).unwrap();
        assert!(result.incomplete_tail);
        assert_eq!(result.records, 1);
        assert_eq!(session.messages.last().unwrap().text, "héllo");
    }
    #[test]
    fn foreign_and_stale_records_never_apply() {
        let dir = tempfile::tempdir().unwrap();
        let snapshot = dir.path().join("s.json");
        let mut session = active();
        let reply = session.active_reply.clone().unwrap();
        let mut foreign = session.clone();
        foreign.id = "other".into();
        let mut file = create(&path(&snapshot, &session.stream_generation).unwrap()).unwrap();
        append(
            &mut file,
            &encode(&foreign, &reply, &Delta::Text("bad".into())).unwrap(),
        )
        .unwrap();
        assert!(replay(&snapshot, &mut session).is_err());
        assert!(session.messages.last().unwrap().text.is_empty());
    }
    #[test]
    fn traversal_generation_is_rejected() {
        assert!(path(Path::new("session.json"), "../../outside").is_err());
    }
}

#[cfg(test)]
#[path = "stream_journal_inspection_tests.rs"]
mod inspection_tests;
