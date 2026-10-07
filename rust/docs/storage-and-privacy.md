# Storage, privacy, and recovery boundaries

This migration is an independent development slice, **not storage parity**. The
source comparison below is against Swift commit
`435c4c8a37072a3ce10229195d4dc39a2a43d976`. It describes application-level formats;
filesystem encryption and operating-system account protection are separate.

## What the original application actually stores

- **Session history is plaintext JSONL.**
  [`SessionJournal.swift`](../../packages/swift-host/Sources/PiAgentCore/SessionJournal.swift)
  creates a version-3 JSON header and appends JSON records directly to a file.
  It uses private directory/file modes, a writer lock, unique record IDs and a
  checked parent chain. `append(..., flush:)` and `synchronize()` define its
  durability boundary; streaming records can be batched. It does not encrypt
  each session journal.
- **Desktop metadata is JSON in SQLite.**
  [`MetadataStore.swift`](../../apps/macos/PiApp/Storage/MetadataStore.swift)
  encodes records with `JSONEncoder` and binds those bytes as SQLite blobs
  (`put`, lines 116–128 at this baseline). Its `CryptoKit` use implements a
  SHA-256 digest, not database encryption. The store applies private file modes.
- **Credentials and native configuration use Keychain.**
  [`ConfigurationVault.swift`](../../apps/macos/PiApp/Storage/ConfigurationVault.swift)
  constructs `KeychainVaultStorage`; its storage contract explicitly has no
  disk/per-profile fallback. This is distinct from plaintext transcript storage.
- **New captured HTTP bodies are plaintext; old encrypted captures are readable.**
  [`PayloadArchive.swift`](../../apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive.swift)
  writes new bodies/chunks with `storage='plaintext-v2'`.
  [`CaptureChunks.swift`](../../apps/macos/PiApp/Storage/CaptureArchive/CaptureChunks.swift)
  defines a read-only `aes-gcm-v1` compatibility path. The native vault retains
  the legacy capture key for that reader; new captures do not use it. This does
  not imply that sessions or all historical captures were encrypted.

## Rust slice: privacy and isolation

- The default storage root is a separate `BelloAgent-rust/sessions` directory
  under Linux XDG data storage or macOS Application Support. The application
  does not discover, import, or rewrite Swift sessions, native metadata, or
  Keychain contents. `--session FILE` must refer to a Rust snapshot; do not
  point it at a Swift journal or production source-app storage.
- Rust snapshots and stream journals are **plaintext**. They contain accepted
  user text, partial/complete assistant text, reasoning, pending input, and
  session state. They must be treated as private conversation data. There is no
  application-layer encryption in this slice.
- On Unix, newly created storage directories use mode `0700`; snapshots,
  journal files and writer locks use `0600`. Existing parent directories are
  not automatically chmodded. These modes protect against ordinary other-user
  reads, not administrators, the same account, malware, or an unsafe backup.
  Use a private, trusted directory. The original journal's full `O_NOFOLLOW`
  path-hardening contract is not claimed for every Rust filesystem operation.
- The explicit `--credential-stdin` entry point retains a supplied credential
  only in memory. Credentials are zeroized on drop and redacted from provider
  error messages; they are not part of the session record. Profiles must not
  contain keys. Native secure vault/settings entry, platform secret storage,
  and the original HTTP capture/legacy-decryption system are unported.
- Redaction of configured credential/header values in errors is not a promise
  to redact arbitrary sensitive text typed by the user or returned by a model.
  Optional performance telemetry records timing/counter data, not transcripts.

## Rust durability contract and differences

[`session.rs`](../crates/bello-agent-core/src/session.rs) and
[`stream_journal.rs`](../crates/bello-agent-core/src/stream_journal.rs) implement:

1. Accepted user/queue/edit commands: serialize a complete bounded snapshot;
   write a private temporary file; synchronize it; atomically rename it; then
   synchronize the parent directory. Publish the mutation only after success.
2. Streaming output: append a generation-scoped JSONL record, synchronize that
   file (and the parent directory on creation), then apply/publish the delta.
   Each record binds session, generation, sequence, and active reply identity.
3. A later successful checkpoint includes the accepted deltas and names a new
   generation. Old complete journals may be removed only after that checkpoint
   is durable. Cleanup failure cannot invalidate the new checkpoint.
4. Reopen: validate and replay the matching journal, retain partial text, and
   pause interrupted work/queues. A torn final record is not replayed; its old
   journal is retained for inspection. Malformed complete records, foreign
   identities, sequence gaps, or incompatible formats fail without replacing
   the existing snapshot/journal. An uncertain commit blocks further writes
   until reopen instead of silently acknowledging a possibly lost mutation.

The Rust format is version 2. It upgrades only its own earlier version-1
snapshot. It is not compatible with the source's version-3 journal, parent
chains, native checkpoints, branches, message versions, or portable import.
Every accepted Rust stream record is synchronized; this is not the source's
stream batching contract, nor a measured Swift performance comparison.

Snapshots are capped at 256 MiB, journals at 512 MiB, and individual journal
records at 16 MiB. Running/held-edit commands and deltas reserve 128 KiB for
interruption recovery rather than accepting output that cannot be checkpointed.
These are explicit safety bounds, not a full source context/retention policy.

## Testing and backup guidance

Use the loopback fixture and a new temporary session directory documented in
[`README.md`](../README.md) for this checkpoint. Automated tests use synthetic
text and fake credentials; they do not need an external model, billing, or
source-app data. macOS vault/build/runtime validation remains pending.

A live snapshot alone may not include the latest accepted stream fragments.
For a consistent manual backup, stop the response and close the Rust app first,
then copy the **entire Rust session directory**, including any `.stream.jsonl`
files. Preserve a damaged or uncertain snapshot and its journals together for
inspection rather than deleting a journal to force an open. There is no automatic
Swift migration or source-app backup/restore integration.

## Read results and snapshot v4

The opt-in macOS read capability retains text/image blocks and resolved viewer
path/line stats in the result checkpoint. Source image base64 is strictly below
4,718,592 bytes per image; content JSON is bounded at 16 MiB. Snapshot v4 marks
this payload, and older v1–3 snapshots remain readable. Idle v2–3 reads remain
byte-preserving; the existing v1-to-v2 migration and journal/interruption recovery
still checkpoint when required. Absent content is omitted from legacy result serialization. Results with payload
require v4, matching visible text and a completed outcome; malformed records are
refused without silently stripping media. Image data is shared immutably across
in-memory snapshot clones and still serialized into private durable storage.

Replay reads retained bytes, never the original file and never a historical tool
invocation. A model must explicitly declare image input. Otherwise the source
placeholder replaces images in the provider projection while durable data remains
unchanged. An unknown manual model-ID override loses inferred image support.
The existing 32 MiB request, 256 MiB snapshot, 16 MiB journal-record and 512 MiB
journal-recovery bounds remain; a capacity or uncertain-write failure does not
publish a success or drop the original recovery evidence. ImageIO's opaque native
allocations are additional to the documented read/decode bounds.

Successful read content is also charged against a 32 MiB per-batch budget before
its original file worker returns: serialized content/stats plus duplicated visible
text bytes. Charges remain until the batch settles; exhausted results explicitly
fail retention with no content and no automatic replay. Earlier accepted content
is unchanged. Native per-read/transient decode allocations are additional. The
snapshot encoder uses a bounded writer and includes the final newline in its
256 MiB limit; it never builds an oversized candidate buffer before rejecting it.

## Mutation results and snapshot v5

The explicit synthetic Editing runtime retains write/edit output with resolved
path, added/removed counts and optional changed viewer lines. These new stats
require v5; declaring them in an older snapshot fails before recovery writes.
Original call arguments/results stay durable; reopen and Retry never directly
repeat a historical mutation. Before-rename result failure leaves an Unknown
outcome on recovery; after-rename uncertainty can recover the committed completed
result. Both preserve the fact that the target file may already have changed.
Filesystem mutation and session persistence are separate transactions, with no
rollback or CAS guarantee. See [write/edit contracts](native-edit-contract.md).

V5 also stores optional ordered compaction checkpoint references and current plus
terminal operation receipts while retaining the full chronological transcript
and partial attempts; replay reconstructs summary, retained and newer messages.
V1–4 read behavior is unchanged. See [manual compaction](manual-compaction.md).
