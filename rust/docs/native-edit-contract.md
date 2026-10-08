# Write/edit vertical contract

Source specification: `packages/swift-host/Sources/PiAgentCore/Tools.swift`
(`NativeTools.invoke`, `lineDiffStats`, `ViewerLines.changed`), `Support.swift`
(`required`, `canonical`, `readBounded`), `SessionTools.swift` (`runToolBatch`,
`rejectionCodes`, invocation/outcome persistence), and native transcript diff/file
links in `apps/macos/PiApp/Transcript/{TranscriptActivity,TranscriptCards}.swift`.

## Exact behavior to preserve

- Definitions are `write(path,content)` and `edit(path,oldText,newText)` with no
  extra properties. Provider preparation coerces each required string using the
  source schema rules; direct native invocation does not coerce arguments.
- Path validation/resolution comes first. Paths are required, nonempty, at most
  4096 UTF-8 bytes. Foundation expands/canonicalizes paths. Only edit searches a
  unique existing secondary-root candidate when the primary candidate is absent;
  write always resolves a relative name in the primary root. Roots are resolution
  context, not a sandbox. Absolute, parent, tilde and symlink paths can leave them.
- Write accepts an empty string and at most 16 MiB UTF-8. Prior bounded-read or
  decoding failures are ignored for its diff baseline. Edit requires nonempty
  oldText of at most 4 MiB, then validates newText (empty allowed, at most 4 MiB),
  then bounded-reads at most 16 MiB, then decodes UTF-8 using Foundation. Native
  acquisition errors take precedence over the non-text error. Exactly one
  non-overlapping Foundation substring occurrence is required. No fuzzy matching.
  The final edited file may exceed 16 MiB; there is no extra source output cap.
- Cancellation is checked before mutation. Parent creation, best-effort attribute
  capture, Foundation atomic data write and restoration of captured POSIX mode
  follow without an intervening cancellation point. Other file attributes are
  not promised. Replacement can change inode identity. Hard-link aliases can
  diverge. External filesystem writers can race any of these steps: no CAS,
  filesystem sandbox, rollback or editor conflict protection is claimed here.
- Successful output is `Wrote/Edited <resolved path> (+N -M)`, with durable path,
  added/removed and optional changed viewer lines. Diff counts compare LF-delimited
  lines using Swift canonical Unicode equality and common prefix/suffix, not LCS.
  Viewer changed ranges compare bytes and recognize LF, CRLF and lone CR. New
  files and exact no-ops omit the range. A no-op still performs the atomic write.
- Main 0.1.121 runs all calls concurrently, including same-file edits across
  chats. Cancellation before invocation entry is NotExecuted. Once entered,
  interruption is Unknown. Known argument/match/read/capacity (`tool_busy`)
  rejections are Failed; other errors may leave effects and are Unknown,
  including permission restoration after a write. Stored calls never
  automatically reexecute. Retry requests a new model response using history.

## Availability and acceptance

`SyntheticProjectRuntime::open_editing_chat` is an explicit nondefault validation
entry point. It requires current synthetic saved-project trust and an already
saved Editing chat. It does not change mode or bypass the existing one-way
confirmation boundary. The original read-only entry and public read-only runtime
constructors reject mutation capabilities. Production/default tools remain off.
Linux executes only a cfg(test)-compiled ASCII temporary-file adapter; ordinary
Linux constructors refuse write/edit. Native execution is macOS Foundation.

The Controller starts every batch call independently and retains durable rows
in original reply order. Per-call authority checks remain before native entry;
there is no workspace-wide or per-path editing lock. Physical work uses the
bounded shared four-worker/64-waiting executor. Dropped awaiters cannot release
entered worker slots or Bash process ownership. Stop joins entered work and
reopening neither reconstructs tool authority nor reruns old calls.

Typed mutation stats require snapshot v5; older v1–4 remain readable without an
opening rewrite. Wrong-version new stats are rejected before recovery writes.
Before-/after-rename result failures recover either a truthful Unknown row or
the exact durable completed output, with no automatic filesystem replay.

Deliberate bounded differences: the Controller retains its existing 2 MiB JSON
argument limit, so the connected model workflow rejects larger calls before
invocation even though direct native write/edit implement the source's 16/4 MiB
limits. The existing 32 MiB request and batch-retention and snapshot limits also
remain. Mutation execution uses the bounded file-worker executor instead of
blocking the async actor. Capacity failures are known pre-effect rejections and are Failed. External writers can still race; this is no CAS or
filesystem sandbox. Foundation-internal allocations are not a new memory bound.

The visible requested-change card uses the source's canonical-Unicode LCS with
300-line fallback, 256 KiB/4,000-line diff eligibility and six-head/six-tail
collapse. Exact-text/status/count cache reuse is bounded to 512 entries/32 MiB.
Large content requires explicit disclosure. Unknown output never says not applied;
source rejected/not-executed labels remain distinct. Persisted resolved paths and
changed viewer ranges open through the existing owner-fenced file editor (first
line reveal, not full-range selection). Raw Copy remains the stored result, not
the marked diff. The selectable marked-text body uses the existing 150 px editor
cap; source color/background styling and native visual/input acceptance are not
claimed.

Validation to date: Linux tests cover real loopback/synthetic trust→temporary-file
mutation→durable v5→reopen replay, same-file ordering, shared gates, post-write
cancellation and store faults; GPUI fixtures cover cache/disclosure/selection/file
links/paging. An isolated exact-source tools harness type-checks Apple signatures.
The checked-in native 21-case Swift-source oracle and native GPUI workflow need
exact macOS CI; cross-target metadata is not execution or SDK/native acceptance.


Frozen local check evidence (2026-10-07): 59 affected core edit/mode/recovery tests,
89 transcript tests (three existing/native ignores), all six compaction action
UI tests, strict synthetic workspace/all-target Clippy, formatting and whitespace
checks passed after both review fixes. The combined synthetic core aggregate
passed 376 unit plus 107 integration tests. Reintroducing early gate release and
off-page-owner indexing each failed its new regression before exact restoration.
The refreshed Apple-target signature harness also checks the new oracle's Rust
integration-test code; it does not execute Swift or native APIs.

The final default workspace aggregate also passed 782 tests (372 app, 303 core,
107 integration; one existing benchmark ignored), with strict default all-target
Clippy. These are local checks of the joint edit/compaction source, not a native
execution result. The preceding published read baseline `49b5e933` independently
passed Linux run37583323641 and macOS run37583323651, including native read through
the fake-platform transcript and own-window lifecycle; those runs do not validate
these later write/edit changes.

## Main 0.1.121 reconciliation

The concurrency contract above supersedes the old serialization assertions in
historical validation records below/linked here. See
[the scoped concurrency record](tool-concurrency-0.1.121.md) for reconstruction
status and fresh validation. Historical test counts are not new acceptance.
