# Bello Agent 0.1.19 code review

Reviewed current `master`, including Claude's eight commits `33b8071` through
`c40f89d`. Claude's repository session had finished its turn and had no child
processes before editing. Three parallel reviews covered host execution,
native persistence and transcript delivery; the integration review covered
catalog authority, archived captures and usage reporting.

## Confirmed problems and fixes

- **Writes after a clock correction could silently disappear.** SQLite rejected
  older timestamp revisions without reporting it. Automatic writes now reserve
  monotonic revisions from saved state. Deliberately stale writes fail explicitly;
  delayed drafts cannot overwrite a later send or quit flush.
- **Failure paths could lose visible work or pretend it was saved.** Quit now
  blocks further input while flushing and stays open if persistence fails. Copies,
  side closure and editing-mode changes require durable storage. Portable handoff
  chat/draft/provenance writes are atomic. A failed side recovery no longer blocks
  other children or live snapshot updates, and failed history navigation restores
  the prior browsing state. Deleted chats remove their actual vault capture override.
- **Transcript fallback pages reported successful painting.** Render failures now
  remain failures and cannot acknowledge a reply as read. The next valid snapshot
  resets the boundary. Reload clears old delivery state and clock calibration;
  recovery attempts reset only after rendering, and post-navigation failures have
  a recovery path. Malformed tool durations are rejected before rendering.
- **An evicted command ID could repeat a mutation.** Recent exact fingerprints
  are supplemented with bounded tombstones for the host epoch. A rare collision
  refuses a command conservatively; it never repeats effects. There is no longer
  a 4,096-command lifetime stop or unsafe replay after eviction.
- **A queue checkpoint failure could corrupt the journal.** If the user message
  appended successfully but the next queue-state append failed, Claude's retry
  fix requeued that already committed message. Both steering and follow-up
  fixtures reproduced duplicated context, duplicate journal IDs and failure to
  reopen. Only uncommitted messages are now reinserted; explicit resume and reopen
  preserve each user message once.
- **Response captures could retain echoed authentication credentials.** A
  streaming masker now handles known literal/JSON-escaped credentials across
  callback boundaries. Only the capture copy changes. Same-length masks preserve
  SSE byte offsets; parsing receives original bytes. Body metadata, retained
  inspection and exports explicitly label the transformation. Error/cancel tails
  are flushed, and an unconsumed tail cannot become a complete capture merely
  because HTTP reached EOF. Existing historical captures are not rewritten.
- **Live exports represented unavailable bodies as empty captures.** Disabled,
  omitted, expired and missing body records now remain absent in exports. A
  genuinely captured empty body still has a file and verified hash.
- **Sidebar refresh repeatedly swept the whole archive.** Reads now reuse the
  next actual retention deadline. Completion, policy changes and export-lease
  release invalidate it. A regression performs 200 accounting/list reads without
  another global maintenance pass, then verifies expiry and changed policy.
- **Partial cache observations could not produce a useful uncached total.**
  Subtraction now occurs within each request before summation. Missing or
  impossible pairs are excluded with their own sample coverage in native and
  transcript details. Cached input and reasoning remain subsets, never extra
  usage added to totals.

## Catalog review and retained changes

The original fresh-save alias/catalog flow already records lineage through
`inheritCatalog`; older unbound chats receive the explicit repair added in
0.1.18. The issue note's original diagnosis omitted this inheritance. Current
tests exercise Settings save, original-chat refresh, retained request credentials,
mounted picker replacement rows, explicit source selection and restart. The
fix does not silently combine independently saved gateway connections.

Claude's draft, timeout, banner, Markdown export, title filtering, keyboard
navigation, image paste/drop and Dock unread changes are retained. His report's
claim that failed `revealConversationHit` already recovered was inaccurate; that
path is fixed here. Durable child sides follow current Features/Design; legacy
unkept-side behavior is not allowed to redefine the current child-session contract.

## Verification

- **394 unique native cases have a final pass; six optional visual/interactive
  captures were skipped.** The broad run executed 398 cases: 391 passed, six
  skipped, one accounting-scale case failed two assertions because its expected
  value omitted the new paired sample field. Its independent fixture expectation
  was updated; the focused 54-case run passed, including that case and an added
  incomplete-capture regression. The final nine-case export/configuration check
  passed, including the new absent-versus-empty export regression. No initial
  failure remains unresolved.
- **140 unique helper cases have a final pass.** The full 138-case suite passed;
  the queue change then passed 12 focused acceptance/recovery cases, two new.
  The new failure fixtures failed before the fix and passed afterwards. HTTP/SSE,
  tools, cancellation, compaction and capture use deterministic local fixtures;
  no deployed LiteLLM or production credential was used.
- **29 transcript tests, TypeScript checking and 10 dependency-cache tests pass.**
  Four native tests use the actual packaged React page in WKWebView, including
  injected DOM rendering failure, rejected input and a reload triggered through
  the content-process-termination callback. This does not claim an OS-induced crash.
- The 100,000-attempt / 300,100-link fixture preserved accounting: 615.668 ms for
  its 101-message page, 56.579 ms for session totals and 62.737 ms for one message
  on this Debug run. These are observations, not a claimed UI latency budget.

Scratch evidence is in session `tmp/deep-review-019`: `native.log`,
`native-final.log`, `native-export.log`, `native-results.json`, `swift-host-tests.log`,
`queue-regression-before.log`, `queue-regression-after.log`, `transcript-tests.log`,
`typecheck.log` and `dependencies-test.log`. Distribution evidence belongs in the
separate versioned acceptance record after publication.

## Explicit limits

This review is not a claim that every possible bug is eliminated. Scroll
anchoring when the bounded host page evicts the currently read row still needs
a broader history-window change. Archive metadata has the documented finite
100,000-record limit; storage saturation remains a visible failure. Trusted
editing tools run with the user's permissions and are not a filesystem sandbox.
Full-text captured-body search remains deferred. No installation or Sparkle
update rehearsal is run under the owner's current workflow.
