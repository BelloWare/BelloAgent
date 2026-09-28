# Journal metadata file

Since 0.1.109 every chat journal (`<id>.jsonl` in a project's `Sessions`
folder) can have a plain JSON file beside it, `<id>.jsonl.meta`. It says where
the chat's model context starts after its latest compaction (or edit, or fork
boundary) and what the records before that point add up to, so a chat opens
from there instead of replaying its whole journal. The model (`JournalCheckpoint`,
`packages/swift-host/Sources/PiAgentCore/JournalCheckpoint.swift`) is shared by
the helper and the app.

## What it holds

| Field | Meaning |
| --- | --- |
| `header`, `marker`, `last` | The session header, the native marker and the record the checkpoint follows: offset, length and the SHA-256 of their bytes. |
| `lastID` | The id of that last record; replay resumes just after it. |
| `rows`, `rowsBefore` | The rows shown from the model context's first row on, in order, each with where its current content is (its message record, the presentation update that last replaced it, a compaction record, or an edit's record for its marker); and how many shown rows come before them. |
| `context` | The model context at the checkpoint, as ids of `rows`. |
| `lineage` | The newest edit marker among all shown rows (the timeline page cursors name). |
| `state`, `stateKey` | The newest run-state record before the checkpoint and the key holding it (`data`, or an edit's `nativeState`). |
| `assistantMessageCount`, `latestAssistantMessageID`, `versions`, `tasks` | What the records before the checkpoint add up to, as a full replay counts them. |
| `helper` | JSON text only the helper reads: spend, recovery and compaction state, fork or side origin, the presentation ordinal. |

## Who writes it

The helper, which owns the journal: after every compaction and every edit it
writes, and after opening a chat whose file was missing or unusable. It writes
a new file whole and renames it over the old one, so a reader sees one or the
other. The app only reads it.

## Opening from it

The helper (`AgentSession.init`) and the app's history reader
(`HistoryReader.read`) both:

1. check the header, the marker, the record the checkpoint follows and the
   newest state against their recorded hashes;
2. check the chain after the checkpoint: the first record's parent is
   `lastID`, and no edit or fork boundary follows (only a full replay applies
   those);
3. read the named rows from their places, and replay only the records after
   the checkpoint.

A 226 MB, 3,000-turn synthetic chat with a compaction every 100 turns opens in
the helper in 5 ms (Release) instead of 1.46 s, and the app indexes it in about
25 ms (Debug) instead of 3.6 s. The first open of a chat without a file replays
the whole journal once and writes the file.

## Older rows

Rows before the checkpoint load from the journal the first time something
reaches for them: a page past the loaded rows, a message read, search, a
message's versions, an edit or a fork. The helper replays the whole journal and
keeps the live rows, context, queue and run as they are; the app indexes the
whole journal. Page cursors name rows by id, so a cursor from before stays
valid.

## When it is not used

The journal is the only record; the file is only ever a shortcut. A file that
is missing, unreadable or of another version, whose checked records differ,
whose rows are not where it says, or that is followed by an edit or a fork
boundary, is ignored: the journal is replayed in full and the file written
again from it.
