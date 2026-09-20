# Review after Claude's 0.1.48 release

The review started only after Claude posted its final report, all of its child
processes exited, its website deployment succeeded, and the working tree was
clean. Baseline: `ef49e00a130665df2b6e4ffc686b4209ad8e6217` in the current
`BelloWare/BelloAgent` repository on `main`. The implementation underlying that
release was `c52a3d197553c32c7ef0e8dfa2230f16cff68066`.

Three parallel audits covered native view lifecycles, helper/session state,
and storage/transport. Integration review also examined connection deletion
and host reconnection. This was a review of current native Swift code, including
the earlier crash fixes; the retired React/Node implementation was not restored.

## Confirmed findings and fixes

| Area | Failure | Correction and regression |
| --- | --- | --- |
| Queue delivery | Removing another queued message while an all-mode batch awaited delivery could make `removeFirst()` trap on an empty array. | Batches select identities, respect removals/reordering, and leave new work to the next batch. Both steering and follow-up regressions exercise the suspended boundary; the baseline reproduced fatal signal 5. |
| Explicit Retry | Paused steering could change the request before Retry repeated it. | Complete the failed request's model/tool boundary before draining steering. A gated model fixture checks exact request history and turn IDs. |
| Crash recovery | An old tool result could satisfy a later interrupted call with the same call ID. | Pair results with their originating assistant message; preserve unknown outcome, turn and request attribution without replaying tools. |
| Live configuration | An incompatible connection binding could be accepted in memory even though the saved journal would reject it on reopen. | Reject incompatible API/endpoint/model bindings before changing helper state; preserve the UI's existing connection-fork behavior. |
| Prepared context | The inspector could show an output limit different from dispatch after context clipping. | Use the same dispatch profile; a fixture reproduced a preview of 5,000 versus an actual limit of 1,658. |
| Context snapshot lifecycle | An automatic calculation starting during inspector startup could replace its just-returned snapshot. | Coordinate preparation per session, share matching requests, and serialize changed inputs; deterministic concurrent previews must return a readable shared revision. |
| Transcript positioning | Geometry callbacks could still scroll synchronously; an anchor could be lost before AppKit attached or override a later reader scroll. | Defer geometry-driven scrolling, retain the current anchor until attachment, and let user scrolling supersede restoration. Native scroll-view regressions check actual offsets and update timing. |
| Inspector selection | Deferred writes could publish superseded selections or restore details after leaving the JSON view. | Coalesce to the current selection and invalidate pending writes when the body/view changes. |
| Numeric formatting | Finite but unrepresentable retained durations/token values could trap during integer conversion. | Checked conversions and a safe missing-value display. A retained duration of `1e100` reproduced SIGTRAP before the fix. |
| Host transport | A full stdin pipe could block its own stop and kill deadlines. Late events from a retired connection could corrupt its replacement's state. | Ordered nonblocking writes plus connection-generation checks; tests use real local processes and injected delayed events. |
| Terminal lifecycle | A large paste could block exit handling; dropping the UI owner could lose forced termination, reaping or the final callback. Background callbacks inherited main-actor isolation, and extreme control-sequence counts could hang rendering. | Separate cancellable writes with owned descriptors, explicit callback isolation, main-actor delivery assertions, retained lifecycle through final delivery, and control-sequence work bounded by screen dimensions. |
| Captures and exports | Damaged event BLOBs or lengths could trap. Invalid completion could consume an active writer before validation. Cancelled exports could continue after a suspended page read. | Validate metadata before mutation, check stored lengths/chunk ranges, and honor export cancellation before publishing. |
| Desktop metadata storage | A failed initialization or a released store could leave its SQLite connection open. Calls after explicit close reached SQLite with a null handle. | Own and close the handle on every lifecycle path, and reject closed-store operations before calling SQLite. Fixture-scoped descriptor checks verify cleanup. |
| Deleted connections | Cached or already-opening helpers and stale display state could bypass connection removal. | Guard connection lifecycle and model dispatch, stop affected sessions independently of UI snapshots, and preserve side drafts/history. Rejected sends and edits save their drafts before surfacing the connection error. |

## Verification boundaries

The [0.1.49 acceptance record](validation/Bello-Agent-0.1.49-2026-09-19.md)
records final test counts, corrections during verification, signed artifacts and
public deployment evidence. Regression tests use synthetic data and local
fixtures; they do not establish compatibility with an unspecified production
LiteLLM deployment. The broad native suite includes mounted native views, but
no manual installation or Sparkle update rehearsal is claimed or required under
the standing owner policy. No full gallery or performance matrix is repeated.

These changes address the confirmed findings in this review. Passing them does
not establish that every possible defect is eliminated. Keep the crash
reproductions and lifecycle regressions when changing queues, view callbacks,
transport shutdown, or capture storage again.
