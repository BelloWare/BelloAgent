# Private sidebar content cache implementation

This repository implements a private, disposable SQLite repository and the existing
loaded/observed source preparation seams. Production acceptance remains closed.
The cache is not a source, durability receipt, or authority grant. App reconciliation
must cover every current member, including negative/missing rows, before presenting
its as-of coverage. Cached hints cannot be installed as `SearchOutcome`.

## Dependency and invocation

Official rusqlite Git `91f876c80114122670f455190d03c81d1f78b0af`, defaults off,
`bundled`, `hooks`, `limits`; SQLite 3.53.4 source ID:
`2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
The existing workspace lock changes only these Git packages and their two missing
iterator dependencies. Every build must use checked-in `.cargo/config.toml`, either
from repository/rust cwd or explicitly with `cargo --config /absolute/repo/.cargo/config.toml`
when invoked elsewhere. Core's build script rejects missing/different no-spill flags
and known system/SQLCipher override variables. `check-sidebar-sqlite.py` verifies
resolved source identity and the full permitted feature union. Runtime probes repeat
the actual linked source, compile options, trigram/full-detail and FTS secure-delete
checks before opening user data. All connections verify WAL, secure_delete, MEMORY
TEMP, FULL synchronous and reader query_only. Extension loading is explicitly disabled
through official bindings and read back; the bundled source compiles that capability,
but the `load_extension` crate feature and enabled connections are not admitted.

## Location and threat boundary

Linux absolute XDG_DATA_HOME, otherwise absolute HOME/.local/share; macOS proposal
HOME/Library/Application Support. No cwd, relative XDG, or arbitrary session-parent
fallback. Missing data-base ancestors fail closed rather than creating/taking over
unrelated directories. Beneath the base: BelloAgent-rust/search-cache/v1/digest.
The digest covers length-delimited exact catalog path, canonical project binding
and project UUID; the full binding is stored and checked for collisions/mismatch.

Linux admission traverses from `/` with no-follow directory descriptors, accepts
only root/current-UID non-other-writable ancestors, and rejects extended POSIX ACLs
conservatively. Dedicated cache directories require exact 0700; files require exact 0600,
current UID, regular type, single link, and no ACL. Creation is exclusive and does not
chmod/chown existing paths. Only known DB/WAL/SHM/journal/lease siblings are admitted.
A stable exclusive owner.lock lease remains alive through all reader connections.
The default SQLite VFS still opens filenames: same-user malicious processes,
privileged access, backups/snapshots and swap are outside this isolation guarantee.
Native macOS ACL/path/VFS execution acceptance is pending, so production opening remains closed.

## Transaction and worker contract

The serialized App source worker owns/moves `PrivateCache`; no actor/catalog/witness
guard spans SQL or disk. `begin_replacement` marks durable cleanup pending first,
then starts one IMMEDIATE transaction. The existing prepare-with-cache variants
construct one SidebarProjection and stage streaming normalized chunks, while keeping
normal prepare APIs unchanged. Drop the inspection/session lease before committing.
Commit checks current member/binding/digest and receipt before and after SQL; a lost
race leaves inaccessible rows, never a valid new receipt. App must withhold the output
if commit or cleanup fails. Initial implementation rebuilds the full chat.

The external-content trigram index has exact insert/delete triggers. Chunks are
32,768 normalized scalars with 256 overlap; offsets are UTF-8 bytes. Projection's
existing NUL-source/query refusal is retained. Normalized staging is capped at 256 MiB
and 131,072 chunks per chat; one chunk is at most 128 KiB. Candidate pages contain at
most 16 chunks; query VM work is capped at 10 million progress instructions and 131,072
candidate rows. Exhaustion/interruption/error never becomes NoMatch. A 2 MiB page
cache is not a whole-process memory cap. Main DB page quota is 512 MiB at 4096-byte pages;
SQLite memory-only statement journals, parser/Session, canonical tool-input and
projection allocations remain separately bounded by their existing/source budgets.
No ATTACH/VACUUM/export/backup operation is exposed. One query worker owns its own
connection and reader transaction; hints require fresh matching evidence and bounded
keyset refinement continues after false candidates.

Lifecycle invalidation suppresses/deletes rows without a permanent tombstone, so a
fresh successful reinstall may rebuild the same member. Authoritative removal uses
`delete`, whose persistent tombstone rejects UUID reuse. A future import/reuse policy
must explicitly review revival, not clear tombstones opportunistically.

All mutations, rollback/error paths and startup require cleanup. A sticky checked
epoch cancels old readers and refuses new admission; overflow closes permanently.
Cleanup refuses active readers, checks the actual main TRUNCATE busy/frame tuple,
verifies zero WAL, clears its durable marker, then repeats TRUNCATE/zero-WAL check.
A busy/failing attempt stays unavailable; App owns bounded backoff and retries.
Startup conservatively removes all persisted rows and scrubs before rebuilding from
fresh sources, so restart correctness has no unvalidated warm-cache shortcut.
No application-level cleanup claims forensic erasure.

## Acceptance transition

`CacheReadiness` has no public boolean setter. `PrivateCache::open` combines the
compile-sealed platform acceptance record with actual source/build/private-path checks.
The Linux acceptance record may be advanced only in a reviewed source change after
all applicable observer/fault, lifecycle, GUI and exact-closure gates are accepted;
record the reviewed evidence and source closure here. Native acceptance is separate.
The explicit `synthetic-authority` fixture constructor supports Linux/macOS, requires a new
private 0700 fixture root, retains real runtime/path/SQL checks, and is never selected
by production composition. Its opaque `readiness()` cannot be forged from a boolean.

The unit observer is compiled only into Linux/macOS tests. It uses supported
`open_with_flags_and_vfs` and official `rusqlite::ffi` types/callback registration,
forwards every platform VFS/file callback with its original context and lifetime,
and runs in disposable subprocesses. xOpen classifies temp/null/DELETEONCLOSE paths;
xShmMap, xWrite faults and xDelete are observed separately. Deliberate synthetic temp
opens and disk-full controls prove it is live. No ptrace or alternative OS tracing
is used. This instrument targets SQLite operations, not all process file activity.
Exact no-spill source: pinned sqlite3.c `openSubJournal` passes nStmtSpill;
`sqlite3JournalOpen` with negative spill keeps memory; `sqlite3TempInMemory` with
TEMP_STORE=3 always chooses memory. Unix SHM derives mode from main DB and uses the
main filename plus `-shm` unless an alternate build macro overrides that behavior.
Final acceptance must include actual compiled-source/config closure and live private
sibling checks, not final directory scans alone.

## Native source and verification plan

Darwin admission now shares the descriptor-relative Unix traversal/lease protocol.
Its ACL read uses official libc `fgetattrlist(ATTR_CMN_EXTENDED_SECURITY)` and
`FSOPT_REPORT_FULLSIZE`, with a bounded aligned buffer and checked signed
attrreference offsets. Absent/deny-only ACLs cannot expand access and accommodate
normal macOS home-directory delete-denial entries. Grant, audit/alarm, unknown flags,
truncated buffers, overflow, and unexpected entry counts are rejected. Format source:
[Apple extended-security packing](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_attrlist.c),
[Apple ACL definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/kauth.h).
These are source-grounded implementation choices, not observed native acceptance.

Before advancing the macOS acceptance record, independently review offsets, native
endianness, denial/inheritance policy and malformed inputs; then use the existing free
native CI lane for the exact pinned build/link/runtime gate, live private HOME and ACL
fixtures, shared repository/observer fault/crash/SHM suite and App integration tests.
Record the requested runner label separately from the actual observed host version.
An arm64 macos-14 runner label is not proof that its actual OS is macOS 14. No TCC,
accessibility, Keychain, signing, owner-computer or production account action is implied.

Build admission also rejects external generic/host/target CFLAGS and CPPFLAGS,
SQLite compile-limit overrides and forced bundling/system-link switches. This closes
unreported preprocessor paths such as SQLITE_SHM_DIRECTORY; the reviewed build
script's compiler flags and plain compiler-path/SDKROOT selection remain supported.

Failed deletion/invalidation intent also remains in a bounded in-memory suppression
set. Cleanup first retries those SQL operations; checkpoint success alone cannot clear
a failed delete. A crash before writing that intent is covered by startup's mandatory
full purge and fresh authoritative reconciliation. Memory-only intent is not presented
as a durability receipt.

The independent build-control matrix omits each required flag and both together.
Every variant must be refused by the actual runtime gate before fixture text. Spill
behavior is characterized separately: the pinned `sqlite3PagerBegin` call passes
`sqlite3TempInMemory(db)`, so TEMP_STORE=3 independently fences the ordinary B-tree
statement-journal inventory even when STMTJRNL_SPILL=-1 is omitted. A redundant-only
negative build need not fabricate a spill to validate its refusal gate. Both production
flags remain mandatory; actual unsafe temporary opens are asserted only in variants
where the observer records them. These controls do not advance production acceptance.

Compiler admission accepts a single compiler executable name or existing path. It
rejects flags embedded in generic/HOST/TARGET/target-specific CC values and custom
cc wrapper declarations, as well as CFLAGS/CPPFLAGS overrides. A compiler path with
spaces is accepted only when it is an actual file, matching cc's executable-path
interpretation. The selected compiler, Cargo/Rust toolchain and operating system
remain trusted; these checks do not protect against a malicious compiler or prove
arbitrary build-tool behavior from SQLite's source ID alone. Final binary linkage
and compiled-source identity are separate recorded checks.

The current App integration runs the receipt-bound query serially after source
preparation on its background job, using a separate query-only connection. The cache
now enforces at most one active query connection even if handles are cloned. A
separate concurrently running query worker is still a scheduling/performance gate;
this implementation does not claim that concurrency milestone. Connection close is
handed to the App background executor, so UI owner replacement does not close SQLite
on the UI thread.

Selected reveal results retain a 32-byte SHA-256 identity of the exact full selected
projection piece, including role, ownership, ordering and tool-input split. The same
in-memory projection supplies it with bounded cancellation checks; there is no second
parser or projection. A later fresh receipt must match this identity as well as the
selected occurrence and target. A checkpoint rotation or unrelated later content
can preserve the selected piece; normalization-equivalent byte edits and edits outside
the bounded excerpt cannot. The digest alone is never a source-admission receipt.
