# Per-request accounting, session pills, usage baseline, sidebar figures — 2026-10-11

Branch `work/accounting`. Specification: Swift 0.1.122 (`6319e368`).

## What matches Swift

**Per-request accounting** (`bello-agent-core/src/accounting.rs`)
- Usage normalization is `UsageObservation.normalized` (PiAgentCore
  TelemetryValues.swift) read through `GatewayObservation`
  (Dashboard/GatewayAccounting.swift): input including cache, output, cache
  read/write, reasoning; invalid parts (a cache larger than its input, caches
  summing past it, reasoning past output, negative/fractional/non-numeric
  counts, more than 10^12) stay unreported, never zero.
- Cost is gateway-reported only (`GatewayTelemetry`): `usage.cost` /
  `usage.response_cost` on a terminal event or JSON body, plus the
  `x-litellm-response-cost` header for non-streaming responses only;
  reported / unreported / invalid / conflict. No catalog prices: Swift never
  estimates a price either.
- Timing is `TraceStore.metrics`: TTFT = dispatch to first output (an output
  item opened or a non-empty delta); the decode span = first output to last
  output, or to the model terminal; the settled rate = (N − 1) / span over
  completed requests with N ≥ 2 and a span ≥ 250 ms.
- Totals are `gatewayAggregateSQL` + `PayloadArchive.gatewayTotals`: requests,
  distinct turns, cost/cache/token sums with their sample counts, the
  input/output splits from the same requests, the settled throughput, TTFT,
  latest wall time.
- Persistence: every dispatched request (turn and compaction, failed and
  stopped ones included) is a `RequestRecord` in the session snapshot
  (`Session.requests`, snapshot version 11), written with the next change of
  the session (no extra write). Nothing is trimmed; only validity bounds apply
  (the capture "no caps" rule). Core's `serde_json` now has `float_roundtrip`,
  so a reopened snapshot's figures are bit-identical to the saved ones.

**Footer pills and usage button** (`bello-agent-app/src/metrics_footer.rs`)
- `SessionStatsPills`: the gauge pill (`2 turns 3 steps · 34 tok/s`, hidden
  with no request), the usage pill (full face with the token split, compact
  face when the row is too narrow; hidden with no usage), and the context
  pill (ring with accent/warning/danger at 80/95%, `NN%`, `Context pending`
  after a compaction, `Inspect context` without a window). Strings, help and
  identifiers (`session-stats-time|usage|context`, `sessionStatsPills`) are
  Swift's; `StatPill` geometry 7 + 16 + 5 + text + 7 by 22, capsule, hover fill.
- The composer's usage button (`chart.pie`, `sessionUsageButton`) is enabled and
  opens the inspector, with Swift's help text.

**Usage baseline for compaction** (`compaction.rs`)
- `request_tokens` is `RequestContextCounter.count(...).requestTokens`: the last
  reply with valid usage (`PiContext.contextUsage`/`assistantUsage`, after the
  latest compaction only) anchors the request when its recorded usage binding
  (`usageBinding`: profile without budgets, instructions, tools, reasoning,
  include, text) matches; its reported tokens plus the provider items after it;
  otherwise the projection estimate. The threshold check and its `fits` use it.
- `context_usage` is the meter's reading (`contextInfo`).

**Sidebar and references** (`sidebar_metrics.rs`, `sidebar_chats.rs`)
- A row shows `ChatRowStats`' cost (`$0.0050`, `$0.00`, `cost n/a`), the
  108-point rate slot (`Latest 34 tok/s`, `compactRate`) for an open chat, and
  `· 12.3K tok` (hidden while running), with Swift's help texts. An unloaded
  chat's totals are read in the same parse as its saved run state.
- A copied session reference has `SessionReference.usageLines`; a saved chat's
  usage is read from its file in the background without opening it.

## How it was checked

Oracles compiled from the unchanged Swift sources (`run-oracle.sh`):
- `helper-src/main.swift` + every PiAgentCore source: 27 usage/cost cases
  (`usage-cases.json` → `swift-usage.json`).
- `app-src/main.swift` + MetricFormats, GatewayAccounting, SessionStatsPills,
  SessionReference, MetricsFooter, CostLimit (unchanged) and verbatim excerpts
  of MenuBarMetrics, TranscriptActivity and SessionTimingHistory (their other
  types need the database/transcript): `GatewayObservation` over the helper's
  output; 34 token, 17 money, 11 cache-hit and 8 occupancy format cases; 13
  sessions summed by the archive's own SQL (`gateway-aggregate.sql`, verbatim)
  in SQLite, read into gauge, usage faces, cost figure, reference lines and the
  latest rate (`swift-app.json`).
- The compaction-threshold oracle gained 10 usage-baseline cases (anchor last
  or earlier, unanswered, cached without total, stale/missing binding, zero
  usage falling back, unicode, empty instructions) and outputs
  `baselineRequestTokens`, `baselineMethod`, `contextTokens`, `meterTokens`;
  the 15 original outputs are unchanged.
- Rust tests: `accounting::tests` (oracle + the same SQL run in rusqlite
  column by column), `metric_format::tests`, `accounting_presentation::tests`,
  `compaction::tests::usage_baseline_matches_the_swift_oracle`, runtime tests
  over the loopback fixture provider (records for failed/compaction/retry
  requests survive reopen; a reported 60K context triggers the threshold
  compaction that ~23K characters do not; another prefix's usage is ignored),
  `metrics_footer::tests`, `sidebar_metrics::tests`, `sidebar_inspection` and
  session-reference tests.

## What still differs

- Swift's request log is a separate SQLite archive filled while a request
  runs; Rust keeps the records in the snapshot and adds a request when it ends,
  so an in-flight request is not counted ("running" missing-usage counts).
- No cache-hit header contract (`routing.cacheHeader`) and no cost breakdown
  components or reasoning cost exist in the Rust profile: they read unreported.
- No cost limit in this build: the usage pill never shows a limit or warning tail.
- Title requests use their own session (as Swift's title task does) and are
  not recorded; they belong to Background Requests.
- The usage face is chosen from an estimated text width (6.6 pt per character),
  not a measured `ViewThatFits`; digits are not tabular; no numeric roll.
- The gauge pill's tooltip carries the tool-time line where Swift has the time
  dialog; the context pill reads the stored context (Swift's `contextInfo`),
  not a prepared next request including the draft.
- The sidebar line keeps Rust's state words and attention text and does not
  switch between Swift's width forms; recency is not shown.
- `queue_geometry` test: with Swift's shorter footer the split 920×600 case no
  longer wraps, so its floor branch runs only when the footer wraps. Forcing a
  wrapped pill row there left the transcript 8 pt under the 150 pt reserve at
  room 147 — worth a look by the queue-geometry owner.
- Snapshot version 11 is claimed for request records; merge with any other
  branch that bumps the snapshot version.

## Follow-ups

Session Inspector Overview and request pages (gauge/usage dialogs, per-request
ledger), the Usage Report (sidebar `report` button), Background Requests and
the Live Monitor / menu-bar metrics, the per-message accounting rows in the
transcript, and the context inspector's "Token count unavailable" line can now
read these records.
