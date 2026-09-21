# Bello Agent 0.1.74 / build 78

Implementation validated; signed publication is pending.

## Changes and root causes

- The helper's task timestamps are system-uptime milliseconds. The live dock
  subtracted them from a Unix calendar timestamp, producing roughly 497,000
  hours. Elapsed time now consistently uses uptime; separate optional Unix
  timestamps supply Started/Finished in the info table and completion notices.
  Existing receipts retain their elapsed durations without invented calendar
  dates. Interrupted work has no observed finish, including across a reboot.
  Streaming message dates also use calendar time. The duration precedes the
  Generating response label without changing the dock's reserved height.
- Manual compaction bypasses the ordinary follow-up loop. A message accepted
  while compaction or final cleanup was active could remain queued when that
  run settled. The helper now rechecks pending work atomically after its final
  suspension and starts it when idle. Failure, cancellation and persistence
  uncertainty keep the queue paused. An idle retained queue also exposes a
  Send queued action; deliberately paused queues retain Resume.
- Selecting native assistant prose or code opens an Ask in side chat popover.
  It quotes the exact selected Unicode text into an unsent child draft, inherits
  the parent's existing side-session context/settings path and focuses the
  composer. It appends to an unfinished draft and preserves an existing saved
  side. User text, tool/reasoning details, nested sides and unsupported origins
  do not offer the action. Quotes exceeding the existing 256 KiB draft limit
  fail without losing a draft. Selection, ordinary copy and streaming code
  remain owned by their existing AppKit text surfaces.
- The menu-bar activity label now keeps Error visible when a failed run also
  carries uncertainty about tool effects.

The quote affordance adds one local input observer per eligible mounted pane,
not per message or delta. A geometry-only marker identifies assistant prose.
It introduces no replacement renderer, global selection polling or transcript
remeasure on selection. The popover is dismissed on scroll/session changes and
revalidates its retained native selection before creating the draft.

## Focused validation

Platform: macOS 14.8 (23J21), arm64, Xcode 16.1 (16B40), Swift 6 mode.

- **17 helper tests pass**: `TaskPresentationTests`, `QueueHandoffTests`,
  `QueueEditingTests`, `QueueDeliveryRecoveryTests` and
  `CompactionTaskRegressionTests`. New held-compaction cases prove ordered,
  exactly-once follow-up delivery and explicit Resume after failure/Stop.
- **43 distinct native Debug tests pass with actor data-race checks**:
  `TranscriptQuoteSelectionTests`, `TurnInfoTests`, `WorkspaceFailureTests`,
  `SideTests`, `StableToolPresentationTests`, `NativeCodeTextTests`,
  `NativeMarkdownViewportTests`, `TranscriptUpdateIsolationTests` and
  `MenuBarPresentationTests`. One optional popup screenshot case is skipped.
- The mounted quote test drives a real native selection event and popover
  button into the workspace's child draft. Chinese/emoji selection, code-copy,
  streaming append, stale selection, session switching, existing drafts and
  saved sides are covered. It does not dispatch a gateway request by itself.
- The fixed clock regression compares an uptime of 432,100,000 ms to a Unix
  timestamp of 1,789,992,600,000 ms. It observes 12.5 seconds, unchanged by a
  one-day calendar-clock shift. Legacy receipts and interrupted work cannot
  fabricate Started/Finished dates or a duration after a missing receipt.
- A freshly staged optimized helper runs through the existing request-aware
  loopback Responses gateway and two mounted panes. Three request and response
  captures match exactly; active and terminal clock observations are checked.
- **12 website staging tests pass** (`test_stage_release_site.py`).
- **21 optimized native tests pass**, including the quoted side flow, elapsed
  clocks, idle queue controls, side persistence, native continuous code, menu-bar
  timing, completion notices and the packaged-helper/local-gateway integration.

Initial test-only compile labels and the native pasteboard-type fixture were
corrected. The large continuous-code height test now explicitly uses streaming
mode, matching its full-height contract; completed fences already use sections.
Its full-height and renderer-parity assertions remain. A pre-existing failure
label regression exposed by the focused suite was fixed in production code.

Logs and result bundles are under session scratch `fresh-transcript`:
`quote-clock-queue-{1,2,3}`, `quote-clock-menu-5`, and
`quote-clock-queue-helper-final.log` and `quote-clock-queue-release-1`.
The failed stale nonstreaming height case
is superseded by its passing streaming fixture. No deployed LiteLLM call,
physical frame-rate measurement, installation or updater rehearsal is claimed.

Helper command:

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'TaskPresentationTests|QueueHandoffTests|QueueEditingTests|QueueDeliveryRecoveryTests|CompactionTaskRegressionTests'
```

Native checks use the standard test selection policy, Debug actor checks and
the staged helper. Publication evidence will be added when complete.
Source commits stay local under the current release workflow;
the website commit is pushed to its configured upstream when published.
