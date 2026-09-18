# Native release acceptance — 2026-09-15

This supplements the earlier [initial-version UI evidence](Native-UI-Acceptance-2026-09-15.md).
It records a native XCTest harness, not a release-signed application. The
synthetic vault implementation exists only in the XCTest bundle. Production
Keychain requirements and entry points were not weakened.

## Environment and reproducibility

- macOS 14.8 arm64, Xcode 16.1; virtual Apple M3 Max, 16 GiB RAM.
- SwiftUI/AppKit application and composers, React in WKWebView, optimized Swift
  helper. The application itself was a Debug build containing XCTest.
- Scratch root: `tmp/native-final` in the remote session folder. Primary logs:
  `ui-build-3.log`, `ui-run-final.log`, `ui-run-relaunch.log`,
  `process-stress-final.json`, `timings-*-two-stream.json`,
  `timings-*-discrete-keys.json`, `ui-run-final-checkpoint.log`, and
  `measured-final-paired.json`.
- `NativeUIAcceptanceTests.testInteractiveSyntheticWorkspace` is opt-in through
  `TEST_RUNNER_PI_APP_UI_ACCEPTANCE_ROOT`. Set
  `TEST_RUNNER_PI_APP_UI_ACCEPTANCE_HISTORY=1` to seed 100 archives of 10,000
  messages each, and `TEST_RUNNER_PI_APP_BENCHMARK_OUTPUT` to a scratch JSON file.
  Run `xcodebuild test-without-building` with
  `-only-testing:PiAppTests/NativeUIAcceptanceTests`. The operator uses CUA and
  writes the test-only `finish` marker after observations. A later launch uses
  the same synthetic state and gateway port; this preserves native journal
  endpoint bindings without altering production compatibility checks.
- UI commands were executed through CUA, not by directly calling view-model
  methods. Byte verification at the end independently compares retained request
  and response bytes with those seen by the loopback server.

The local gateway imports `fixtures/native/litellm_contract.py`. Every model
request must satisfy its endpoint, authentication, model, token-limit,
provider-specific body, tool schema, history and paired tool-result contract.
Malformed requests receive an error. Responses are chosen from validated user
content and actual tool results. No paid or external model calls are made.

## Functional observations

The first completed interactive run passed in **719.590 seconds**: **11 model
HTTP requests and 18 retained request/response bodies** verified against actual
loopback bytes. The two side requests used session-memory capture and were not
counted as durable bodies. The run exercised:

- Native Skills, Instruction Chain, Discovery Settings and MCP Servers panels.
  The explicit-only skill source, hash and policy were visible. Selecting its
  chip and sending through the global Conversation menu reached a valid
  Responses request and completed a read-tool round trip. Synthetic discovery
  settings saved successfully. Native MCP list and describe returned the echo
  schema; one confirmed invocation returned the supplied Unicode string.
- Separate Messages and Responses tool cycles. Per-message originating-request
  accounting and per-session totals agreed without adding overlapping rows.
  At the four-request checkpoint, Dashboard displayed **$0.00375 USD**, four of
  four costs reported, **one cache hit / three misses**, and 40 provider
  prompt-cache-read tokens. The Messages filter displayed two requests,
  **$0.00125**, one hit / one miss and 20 prompt-cache-read tokens. The cost and
  cache-hit charts reflected the same scope.
- An explicit synthetic header contract supplied cache status. Final
  `usage.cost` supplied cost; the pre-stream zero cost header remained a
  separate observation and did not overwrite final cost. The first fixture
  version treated a Messages tool-result user block as the newest prompt;
  therefore its second tool-loop request was a miss. The final fixture uses the
  validator's latest textual user prompt consistently for both APIs.
- Both APIs completed a 1 MiB Markdown response. A main editing conversation
  and its read-only side then streamed independent 1 MiB responses concurrently.
  Two editing conversations in the same workspace were observed to serialize,
  as required by the workspace editing gate.
- A real local bash tool produced **52,428,800 bytes (50 MiB)** while the side
  streamed a model response. Its visible tool card completed in **8.87 seconds**.
  Output previews and transcript pages stayed bounded with explicit truncation
  labels. The original tool spool size was checked independently.
- All **100 archives** (`History 000` through `History 099`) were selected using
  native sidebar navigation; each contained 10,000 messages. Every selection
  was observed in CUA. Native asynchronous list updates occasionally retained
  the current selection for a Down key; subsequent keys advanced. This is
  functional load evidence, not a clean timing benchmark: other agents resumed
  builds after the separate numeric window ended.

The second OS process (PID **68762**, after PID **64735** exited) restored the
saved Unicode draft, chat history, kept side and request accounting. Native
Inspector displayed the original **696-byte Messages SSE** after deliberate
reveal. Its request headers showed `Bearer [sha256:…]` and `x-api-key:
[sha256:…]`, never the fixture auth key. This run passed in **287.947 seconds**
and reverified the 18 durable bodies. Its attempted new request was correctly
blocked because the fixture had initially changed its ephemeral port; the
fixture now persists the original port. No production endpoint-binding rule
was relaxed to make the harness pass.

The first fixed-port retry (PID **71502**) failed after **72.498 seconds** when
the shared disk filled and the harness could not write `ui-state.json`. This
was a failed run, not acceptance evidence. Its log is retained as
`ui-run-relaunch-port.log`; obsolete build scratch was reclaimed before retrying.
Two completed native captures from that failed run survived, but their separate
gateway log did not. Those historical attempts cannot now be independently
byte-verified. The harness reports their IDs separately and requires every
current-run durable capture to match independently observed server bytes.
Gateway records are now atomically checkpointed at HTTP completion/cancellation.

With the final optimized helper, a later process (PID **79856**) completed a
fresh Messages request, then cancelled a second request through native Stop.
Partial text remained visible; final cost correctly remained unavailable, with
six of seven session requests reported. The attempted paired stress run exposed
a fixture defect: its validator rejected a read-only side's completed historical
`bash` call because `bash` was no longer advertised. This workload is not claimed
as a successful two-stream measurement. The test ended after **298.644 seconds**
with the expected missing-historical-wire-record assertion, recorded in
`ui-run-final-helper.log`.

Commit `6657168` fixes that fixture contract with explicit known historical
schemas. Current tool availability stays separate: a read-only side never
receives a new `bash` call. Four loopback HTTP regressions pass, covering both
APIs, completed and cancelled byte checkpoints, unknown/malformed/unpaired
history rejection, and unavailable-tool behavior.

The final process (PID **82514**, fixed port **52234**) passed in **447.418
seconds**. It verified **30 retained bodies**, including **all six current-run
durable bodies**, against **19 cumulative independently checkpointed gateway
records**. The two current-run side requests used session-memory capture. Both
APIs sent fresh requests in this process; a Messages cache hit displayed an
explicit reported zero cost, and both main and side streams were subsequently
cancelled using native Stop. Both panes preserved partial output and showed
missing final cost without converting it into zero. The verification JSON
separately identifies the two unverified disk-full historical attempts; they
are not counted among the 30 verified bodies.

## Numeric observations and limits

`scripts/measure-app.py` sampled native app, helper, tool/MCP descendants and new
WebKit processes for **217.742 seconds**. The synthetic gateway PID and its
descendants were explicitly excluded. No browser activity or compiler/test
load occurred during this window. Aggregate RSS was **570.31 MiB mean / 755.75
MiB peak**; aggregate CPU was **33.17% of one core** over this mixed active
workload. RSS may count shared pages more than once; one-second sampling misses
shorter peaks. These are Debug/XCTest measurements, not a signed Release memory
or battery claim.

The previous instrumentation attributed a non-editing key to a much later
redraw. Commit `784a68e` measures only events that actually alter text or marked
text. Its regression retains a genuinely slow 20-second edit rather than
discarding outliers. Six Workspace tests and the separate credential-omitted
capture regression passed in the targeted seven-test native run.

| Workload | Samples | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| CUA burst `typeText`, two simultaneous streams: input event → native draw | 818 | 34.59 ms | 216.61 ms | 259.74 ms |
| Same burst: native handler → draw | 818 | 1.34 ms | 2.46 ms | 5.93 ms |
| Same burst: event timestamp → handler dispatch | 818 | 35.72 ms | 214.90 ms | 258.17 ms |
| Discrete awaited CUA key events during side stream/tool workload: input → draw | 80 | 2.10 ms | 6.63 ms | 7.88 ms |
| Two-stream WKWebView snapshot receipt → paint opportunity | 28 | 28 ms | 43 ms | 62 ms |

All observations in these windows were retained; the burst result is not
trimmed or replaced by the discrete-key result. **Burst input did not meet the
historical 50/100 ms p95/p99 target.** The large difference occurs before the
native key handler; it is visible under CUA's bulk text injection. The discrete
key result demonstrates responsive paced input but does not erase that limit.
WKWebView receipt-to-paint is not helper-delta-to-visible latency. The first
run exposed a missing Swift helper `displayObservedAt` field. The final run
below uses the corrected helper contract.

The final optimized helper was verified before launch with SHA-256
`e240c2ad3b73da7cdd95f9042c63881561a4a45cba6819c4d36c90dafd7553e2`
(commit `471336e`; the XCTest host uses the unstripped optimized executable).
The complete **139.08-second** focused window included a completed pair of
small paced SSE streams, then longer main/side streams cancelled after the
typing probe. Both conversations were independently confirmed running before
and after the **80 individually awaited key events**. No compiler, other test
suite or browser activity ran during this window. The application remained a
Debug/XCTest build.

| Final workload / timing boundary | Samples | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| Both streams active: native input event → draw | 80 | 2.17 ms | 6.23 ms | 48.94 ms |
| Same keys: native handler → draw | 80 | 1.18 ms | 2.40 ms | 10.04 ms |
| Whole window: helper display delta → native snapshot received | 172 | 42.40 ms | 51.55 ms | 138.11 ms |
| Whole window: helper delta → `callAsyncJavaScript` submission | 177 | 48.94 ms | 67.78 ms | 141.85 ms |
| Whole window: WebKit snapshot receipt → paint opportunity | 182 | 43 ms | 63 ms | 76 ms |
| Whole window: helper delta → calibrated paint upper bound | 177 | 92.74 ms | 175.96 ms | 308.63 ms |
| Active key phase only: helper delta → calibrated paint upper bound | 54 | 90.79 ms | 181.93 ms | 485.90 ms |

The end-to-end maximum was **485.90 ms**. No observations were trimmed. The
helper clock uncertainty was at most **0.330 ms** and the two WebKit clock
calibrations at most **0.133 ms**. This measures a calibrated post-paint task
opportunity, not physical screen scanout. **The corrected end-to-end p95 exceeds
the historical 75 ms target.** Paced-key success does not replace the earlier
failed burst-input result. No visible bridge failure, refresh prompt, response
loss or growing transcript backlog was observed; the stage histograms are not
joined by snapshot ID and cannot identify the exact cause of an individual
tail-latency sample. Their percentiles must not be subtracted or added.

The artifacts `timings-before-final-paired.json`,
`timings-after-final-paired.json`, `timings-before-final-live-keys.json`,
`timings-after-final-live-keys.json`, `final-paired-window.json`, and
`final-paired-*-state.json` preserve these boundaries. A separate **62.16-second**
RSS/CPU sample (`process-final-paired.json`) ended before the active paired-key
phase, so it is not evidence of resource usage during that typing probe. No
final-run screenshot was saved; GUI observations were made through CUA
accessibility state and the earlier native screenshot inspection.

## Still separate

Real language IME candidate composition was not certified. The attempted Apple
Pinyin CUA workflow inserted Latin characters without a candidate/marked-text
phase. Original input sources, shortcut and dictation language settings were
restored. Existing native marked-text Enter tests and Unicode paste checks do
not replace a real language IME observation.

Release-signed Keychain identity/isolation, production gateway acceptance,
notarization, complete signed DMG size and Sparkle update/publication proof are
separate gates. This evidence does not claim they passed.

After the final run, Safari's existing Apple Developer tab still showed the
sign-in page with an empty account field and disabled Continue button. No
sign-in interaction, reload, navigation or credential entry was performed.
