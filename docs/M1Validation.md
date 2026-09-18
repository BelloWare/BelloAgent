# M1 validation

M1 provides the native workspace/session path on top of the completed M0 proof.
The full v1 feature checklist remains open through M2–M5.

## Implemented and checked

- Versioned commands use a bounded per-epoch receipt ledger. Duplicate acceptance
  cannot submit twice, and receipt exhaustion refuses new mutations.
- Each Pi session has one command lane. Sessions of a workspace run
  concurrently; only editing tool invocations take turns on the workspace's
  gate (changed 2026-09-17, 0.1.28). Follow-ups and steering have independent bounds.
  Stop bypasses profile/Keychain resolution, signals Pi promptly, and pauses
  follow-ups until explicit Resume. Compaction shares the lane.
- Native SQLite stores workspace/session indexes, per-chat drafts, explicit
  command intent/acknowledgment and terminal receipts. It does not store raw
  bodies or an alternative model transcript. Native OS-held workspace locks
  prevent a second app writer. There is no atomicity claim across SQLite/Pi files.
- Node starts lazily for actual workspace operations. Native archive browsing
  needs no host. At most three Pi runtimes are retained per host, with idle
  eviction; idle hosts have a default 120-second grace. Workspace concurrency
  defaults to two. Queued work prevents idle shutdown.
- Native NSTextView supports Enter, Shift+Enter, marked IME text, undo and text
  selection. Drafts and scroll anchors are persisted. The webview receives
  bounded presentation pages and no raw HTTP bodies, keys or opaque reasoning.
- Markdown uses pinned react-markdown 10.1.0 / remark-gfm 4.0.1. Raw HTML,
  executable/credential links, automatic remote images and non-bundle navigation
  are disabled. Native link policy uses WebKit's actual async delegate callback.
- Imported originals remain read-only. Continue creates an independently
  identified Pi-format copy with immutable source provenance. Explicit tail
  recovery preserves all original bytes and drops only an unterminated final
  record in a new validated copy. Earlier corruption is rejected. Native retained
  message viewing is paged separately from the future M2 HTTP inspector.
- Deletion unloads the idle writer, clears its memory bodies, moves an owned Pi
  file to Trash and removes desktop drafts/index data. Imported originals remain.

## Evidence

The host suite has 68 passing tests, including real Pi Responses/Messages,
byte-exact fixtures, duplicate commands, stopped queues, writer/read-only
scheduling, bounded backpressure, stable history identities, safe Markdown,
changed-source import, strict tail validation, and preserved recovery provenance
without fabricated assistant output.

The native suite has 11 passing tests. Added cases cover independent durable
queued intents, stale draft revisions, lock descriptor ownership, branch-aware
archive browsing, incomplete-tail preservation, Enter/Shift+Enter/IME handling,
and a stalled credential worker that times out without accumulating workers.

An actual app UI run on the M0 machine opened a fixture workspace, saved a
synthetic local profile in Keychain, created a chat, rendered streaming Markdown
and exposed reasoning, reopened its Pi history and retained its draft. Typing
continued during a second stream. Send displayed a queued follow-up; Stop
produced an aborted assistant and left the follow-up paused with Resume visible.
No real provider credentials or live billable requests were used.

UI testing caught and fixed two integration defects: a stale sequence baseline
after host restart, and a macOS Security lookup blocking the main thread after
an ad hoc test signature changed. The latter now uses one background worker,
a bounded UI wait and explicit error reporting; Developer ID releases retain
their signing identity. These are functional checks, not M5 latency benchmarks.

## Required next milestones

M2 adds full profile discovery/compatibility and credential references,
model-supported attachments, context/rate metrics, native HTTP inspection,
persistence and export. M3 adds structured slash skill selection and instruction
provenance; M4 adds the independent side panel. M5 completes the remaining
copy/search/accessibility/performance acceptance matrix and ships the signed
application. The public feed still serves the verified 0.0.2 dummy release;
M0's notarized 0.0.3 candidate and this development build are not published.
