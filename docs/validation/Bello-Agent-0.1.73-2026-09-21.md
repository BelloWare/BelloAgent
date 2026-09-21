# Bello Agent 0.1.73 / build 77

Release candidate; publication verification is recorded below after deployment.

## Changes and scope

- Compact Now, the application menu and a directly typed `/compact` freeze the
  originating chat's model, thinking level, context capacity, output budget and
  supported output ceiling before opening/awaiting the helper. The host passes
  these choices to compaction and validates them before mutating command state.
  Explicit connection defaults do not borrow settings from the previous turn.
  Automatic compaction keeps its existing active-submission path. The existing
  headroom policy can still clip the model ceiling to fit the summary request.
- Live turn accounting joins the active root **and execution** to its request
  rows. Retry generations and other turns cannot supply unrelated usage. Header
  reports attached to a user row move to its assistant source without being
  counted twice. No token or cost estimate is made from visible output.
- The progress dock has fixed slots for phase, elapsed time, total tokens, cost,
  input/output counters, Info and Stop. Reported zero and micro-costs remain
  visible. Missing reports say Pending while running and Unreported after.
- Terminal summaries show timing, request/tool/file counts, token breakdowns,
  cost and model directly. Fields wrap between values in a narrow pane. Tool
  details stay collapsed, and the summary remains independent of prose hosts.
- Info opens a metric/value/coverage table with timestamps, model/tool duration,
  input/output/cache/uncached/reasoning tokens, total/reasoning cost, response-cache
  observations and per-request inspection. Copy Turn Info remains available.
  Reasoning and cache figures are subsets, not extra additions to totals.

Usage is gateway-reported, with sample coverage. A bounded history window can
contain only part of an execution's requests; this is labelled in the inline
summary and details, and the live dock exposes the same scope in its help.
The current request may not report final usage until it completes. This change
does not invent complete totals from absent or unloaded observations.

## Focused validation

- **55 helper tests pass**, covering manual override selection/rejection,
  compaction safety/budgets/receipts/gateway/recovery and task/configuration state.
- **39 distinct native Debug cases pass with actor checks**, across
  `TurnInfoTests`, `ManualCompactionTests`, `StableToolPresentationTests`,
  `TranscriptActivityTests`, `TranscriptUpdateIsolationTests`,
  `NativeTranscriptDocumentTests` and `ComposerSubmissionTests`.
- **13 optimized native cases pass**: turn info, manual compaction and stable
  tool presentation. The final table-header wording is checked again in Debug.
- **12 website staging tests pass**.
- The new native compaction fixture drives the bundled helper to an independent
  loopback Responses gateway. It checks the actual model, effort, output ceiling,
  final summary instruction and capture bytes for menu, slash and explicit-default
  cases: six requests and six responses. Each selected model differs from the
  earlier turn and connection defaults; a picker change after dispatch cannot
  change the accepted command.
- Native tests cover user-to-assistant accounting ownership, tool-round sums,
  retry exclusion, zero/micro-costs, missing reports, reporting coverage and
  cache/reasoning arithmetic. Mounted 280pt/640pt views preserve live dock height
  as values arrive and wrap completed figures. The info table is visually checked.
- Existing task/prose/selection tests and the separate three-request tool gateway
  remain passing. No test install or actual updater rehearsal is performed.

The initial native test-only compile annotation and mounted test window ownership
were corrected, then the affected checks rerun. The slash fixture now marks
directly typed input, preserving the app's deliberate distinction from pasted
slash text. No request/capture or layout assertion was removed.

Packaging and publication details follow after their checks complete.
Logs are in session scratch `bello-agent-0.1.73` and
`fresh-transcript`; fixtures use synthetic credentials only. No deployed LiteLLM
call or physical display frame-rate claim is part of this release check.
