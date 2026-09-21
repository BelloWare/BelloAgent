# Bello Agent 0.1.76 / build 80

## Scope and source

Implements the uploaded **Stable Reading During Streaming and a Faithful Execution Timeline** plan, reviewed against `72b67c67dbed8190d1c54755f3708ef6f4c6dd6b` (0.1.75). Implementation started from the current `main`, without subagents.

- `530ddc9`: separate Copy/caret updates from Markdown geometry; retain exact block measurements.
- `9b23fd3`: one pane reading coordinator, real reader-intent invalidation, source/character anchors and mounted streaming regressions.
- `6d660ad`: bounded typed provider parts, request and execution journals, compaction stages, revision-aware native history and durable capture links.
- `4220d55`: incremental code highlighting from safe lexical checkpoints; preserve prefix attributes when crossing the highlight cap.
- `bb3b9d3`: chronological local transcript entries, native history/capture presentation, selection reconciliation, terminal tool-result receipt and legacy live-status fixes.
- `16e3e82`: restored reading destinations take priority during first mount; expandable timeline rows cannot share local heights, timeline metadata is counted in cache budgets; local fragment planning avoids full regrouping; footer owners release correctly.

Returned text, reasoning, preparation, actual tool starts/results, retries and compaction retain their supported order. A/B/A delivery remains three segments. A terminal replacement that differs from earlier output is explicit correction evidence. Legacy flattened content is labeled as lacking exact part order. Opaque reasoning/signatures do not become invented reasoning text.

Presentation records are display-only and never enter model replay context. They preserve original record positions across semantic revisions, branch edits, forks and saved side sessions. Journaling occurs at semantic boundaries, not every token. Preview bounds remain explicit; full retained content and request/response captures stay available. Tool dispatch, retry policy, compaction adoption, permission checks and usage arithmetic are unchanged.

## Evidence and limits

Environment: Apple M3 Max **Virtual**, 16 GiB RAM; macOS 14.8 (23J21); Xcode 16.1 (16B40); arm64, Swift 6. Native runs use actor data-race checks. Debug is used for correctness and optimized Release for throughput/layout measurements.

The baseline reproduced four regressions (six failed assertions): completion changed exact blocks back to provisional, the highlighting threshold removed existing colors, reasoning was relocated before earlier prose, and a 25-point upward gesture still followed output. The production same-response fixture also reproduced source-anchor movement when a streaming append arrived between inner measurement and parent height adoption. After the fix, mounted selected **and unselected** middle-of-response checks maintain the source anchor within one physical pixel at draw opportunities. Long Unicode prose/code reflow and inline Markdown finalization are covered separately.

Verification categories:

1. **State/protocol:** ordered-part, canonical correction, opaque data, bounded projection, patch identity and usage/replay invariance tests.
2. **Helper integration/durability:** all **296 helper tests passed**. Includes restart/fork/edit/saved-side equivalence, interrupted semantic journals, retry/queue/compaction behavior and request-aware local gateways. The compaction golden fixture writes `once\n` to a counter, compares exact captured HTTP bytes, reopens with zero model dispatches, and confirms no repeated mutation. The two-pane gateway fixture compares live and reopened part IDs/order/scope and six exact request/response bodies.
3. **Mounted macOS:** correctness tests exercise the actual SessionDisplay → TranscriptPage → native document path, real field editors, selection owners, width reflow, scrolling, older-page adoption, tab rebinding and local disclosure. Selection remains attached to the same native editor through literal-to-canonical Markdown reconciliation, including UTF-16 offsets.
4. **Physical UI:** no human trackpad observation, physical 60/120 Hz display certification or screen-recording-based frame analysis was performed. Automated virtual-window draw opportunities and CPU/layout timings are not a substitute for those checks.
5. **Live LiteLLM route:** not tested against the user's production endpoint. Gateway tests use deterministic loopback Responses fixtures; provider event semantics also have protocol fixtures.

Across the focused runs, **181 distinct native tests pass** after rerunning affected failures; the final Debug saved-position/cache run passes all 34 tests. The optimized measurements are below. The broad exploratory native suite was interrupted after exposing older fixture assumptions (task-wide work grouping, default-open tools, and bypassing fresh history loading), plus failures outside this change. Affected fixtures were updated and focused suites rerun. This is **not** a claim that the complete native suite passed.

## Acceptance map

“Covered” means the named automated fixture checks that invariant, not physical hardware certification. “Partial” identifies a dimension not exhaustively tested in this run.

| ID | Evidence / scope |
| --- | --- |
| A01 | NativeMarkdownViewportTests: older selected owners and exact settled layout retained. |
| A02 | StableReadingTests: same response retains prior blocks while tail appends. |
| A03 | Covered by the unselected, nonzero middle-position production fixture. |
| A04 | Deterministic append during parent adoption; draw-time source displacement checked. |
| A05 | Provisional-correction and newer-reader-input ordering tests. |
| A06 | Completion metadata test has 80+ blocks and retains prepared geometry/owners. |
| A07 | Copy targets/caret are paint/action changes; exact-height and copy-source checks. |
| A08 | NativeCodeTextTests: lexical checkpoint suffix updates and UTF-16 selection retention. |
| A09 | Highlight-cap crossing keeps earlier colors and complete source. |
| A10 | Long open Unicode paragraph holds its actual middle character through reflow. |
| A11 | Inline closing markup and Unicode selection/source anchors covered; exhaustive cross-block late-reference dependencies remain partial. |
| A12 | Provider terminal correction is explicit and preserves earlier segment identities. |
| A13 | Upward gesture 25 points from the end disables following. |
| A14 | Latest/page keys/wheel intent covered; physical momentum and scrollbar drag under load remain partial. |
| A15 | FreshPresentationTests: older coverage reaches the native document while resident limits are applied. |
| A16 | 1,100-row retained history traversal, older/newer cursors and native coverage tests. |
| A17 | Bounded timeline projection, full retained history revision retrieval and exact capture tests. |
| A18 | Two mounted panes with packaged helper/gateway and independent reading coordinators. |
| A19 | Rapid ABC source/focus rejection and coordinator generation invalidation. |
| A20 | Width, Unicode and selection reflow covered; physical monitor/backing-scale changes remain partial. |
| A21 | Local disclosure motion/geometry fixture; settled prose not invalidated by hidden argument updates. |
| A22 | Terminal states flush promptly; stop/error/retry and detached-reader paths tested separately. |
| A23 | Composer marked-text, typing, focus and two-chat tests pass; dedicated IME + 30 Hz combined latency matrix remains partial. |
| A24 | Native viewport host bounds/selected-owner retention and pane-release checks; long soak remains partial. |
| B01 | ResponseTimelineTests: text → reasoning → text → tool preparation. |
| B02 | Reasoning-first fixture retains that different order. |
| B03 | Responses item/content/summary indices, IDs and canonical correction fixtures. |
| B04 | Anthropic mixed blocks and opaque signature/redaction fixture; app remains Responses-only. |
| B05 | A/B/A interleaving survives finalization and restart. |
| B06 | Incomplete arguments are preparation evidence without invented tool execution. |
| B07 | Actual invocation records are emitted after execution admission; helper concurrency/ordering tests. |
| B08 | Reused raw call IDs retain independent attempt/response scopes. |
| B09 | Partial failed attempts remain before the next attempt; retry durability tests. |
| B10 | Existing TaskPresentation/QueueHandoff tests preserve queued vs delivered positions. |
| B11 | Golden automatic-compaction operation precedes its durable checkpoint. |
| B12 | Compaction gateway: physical summary attempts, streamed text and validated/adopted stages. |
| B13 | Existing candidate/adoption failure tests plus terminal-evidence-only presentation. |
| B14 | Cancellation/crash fixtures leave interruption evidence and do not dispatch on reopen. |
| B15 | Opaque provider data and waiting metrics never synthesize reasoning text/duration. |
| B16 | Late accounting/cost/model metadata cannot reorder or remeasure prose parts. |
| C01 | Native two-pane live/reopened equality plus indexed/unindexed latest revision retrieval. |
| C02 | Helper restart/fork/edit/grandchild/saved-side order and no discarded-future leakage. |
| C03 | Canonical/partial/unknown-version fallback, bounded evidence and capture-disabled paths; exhaustive expiry combinations remain partial. |
| C04 | Snapshot of an interrupted semantic journal; no terminal success or automatic dispatch invented. |
| C05 | Two-pane gateway, long reading, paging and compaction/retry golden tests pass separately; one exhaustive all-features physical stress run remains partial. |

## Measurements and final checks

The final optimized, actor-checked run passed **50 tests** (`native-optimized-verified.log`). It includes the production same-response selected/unselected reading cases, Unicode/reflow, chronological projection and patches, retry/compaction/capture integration, Markdown finalization, retention, opaque-ID crash regressions and actual AppKit scrolling. The footer retention test now releases all four tested pane configurations.

| Optimized mounted fixture | p50 | p95 | p99 | Longest synchronous work |
| --- | ---: | ---: | ---: | ---: |
| 300 rich transcript rows, 120 scroll steps | 3.526 ms | 27.255 ms | 85.956 ms | 68.057 ms |
| One 88 KiB Markdown answer, 120 scroll steps | 5.846 ms | 8.572 ms | 14.447 ms | 12.283 ms |

These are wall-clock CPU/layout/draw-opportunity timings in the named virtual machine, including a main-run-loop opportunity per step. They do **not** establish physical gesture-to-photon latency. Refresh rate and physical 60/120 Hz behavior were not measured. The engineering target of <5 ms is **not achieved universally**, especially when mounting rich rows; these tails remain a performance limitation.

Both prepared-content traversals have zero exact-width row cache misses, zero row intrinsic validations, unchanged row frames and clip positions within 0.5 points. Native view counts remain bounded. The 88 KiB fixture initially misclassified provisional inner Markdown as settled because only the outer row had an exact height. Instrumentation linked every remaining correction to newly prepared blocks. The benchmark now requires an observed preparation-free traversal (three passes in the long-answer run) before measuring unchanged geometry; it still asserts raw position at every measured step. Cold measurement/source-anchor correctness is asserted independently at draw opportunities by `StableReadingTests`, without unconditional settling before each append assertion.

The 300-row incremental update fixture uses a **190-byte** frame. Mean stage costs: frame encode 0.018 ms, decode 0.096 ms, update 0.100 ms, merge/compare 0.082 ms, local planning 0.785 ms. Update + merge + planning is **0.967 ms**, below its existing 1 ms assertion (the first optimized run before local planning measured 1.051 ms and failed). The test asserts local patch equivalence with the complete chronology and forces late-accounting changes through full planning. Real helper-reply-to-published latency over 40 deltas: median **1.02 ms**, maximum **1.33 ms**. This is publication latency, not visible frame latency.

The final saved-position/cache-isolation suite passes (`native-cache-restoration.log`), including all six cache tests, explicit prepended-history destinations, same-response character anchors, native page changes and nine chronological presentation tests. The saved-position regression now reuses 49 unchanged row measurements and measures the answer changed while hidden; it retains the exact restored anchor. Cache tests reject local reasoning/tool/operation heights and oversized evidence metadata while still sharing immutable prose.

## Publication

Pending signing, notarization and public verification. Installation/update rehearsals are omitted under the owner's standing instruction.
