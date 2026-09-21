# Fresh session loading, history windows and native transitions

Implements the owner's `Fresh-Session-Loading-and-Transitions-Plan.md` dated
2026-09-21. This continues the current native Swift application and helper;
it does not restore the retired Node/WebView implementation. The prior
unreleased Live Monitor B is included in the same 0.1.71 release.

## Behavior and ownership

Ordinary selection creates a new presentation generation and immediately shows
loading. Every revisit starts with the latest **three display turns**, counting
delivered user/steering inputs, not three messages. Re-clicking the selected
chat and returning from Reports preserve the existing page. Explicit message
links open a bounded window around the target instead.

The agent, tools, model context, run receipts and draft outlive this short-lived
presentation. Draft metadata loads before body indexing; the composer enables
when that metadata is known. An existing or newly typed draft, attachments,
skills and edit are not overwritten by late storage. Stop remains available
during history loading. Loading a transcript does not start a helper or replay
a request. Main and side have independent generations and cursors; an ephemeral
side without its owner reports that fact rather than inventing a disk source.

Navigation, both page edges, native placement, deferred live-bar removal and
optional context/accounting are generation-scoped. A → B → C and A → B → A
cannot publish stale content or focus. Context/accounting are admitted after
useful destination geometry and the existing input-quiet deadline. Re-clicking
a ready chat can recover a missing context preview without reloading history.

## Source contract and budgets

`session.history` version 2 and the stored-history adapter expose the same
latest/older/newer/around contract. It returns messages, source incarnation,
branch lineage, exclusive older/newer edge cursors, and an optional original
user-input reference for a partial turn. Cursors carry stable entry IDs. Disk
cursors also identify the committed prefix; appends retain validity, while
rewrites, file replacement, incompatible branches and malformed pages reject
adoption. A file/helper handoff validates entry and lineage before changing
cursor ownership. The legacy numeric helper API remains a compatibility adapter.

Defaults from the plan are retained:

| Limit | Implementation |
| --- | --- |
| Initial/adjacent turn target | 3 display turns |
| Page row cap | 60 projections |
| Wire page cap | 256 KiB, including encoded escaping and envelope allowance |
| Metadata allowance | 8 KiB in projection budgeting |
| Resident window | 500 rows and approximately 4 MiB of projected content |
| Startup fills | At most 2; one in-flight request per edge |

Oversized turns continue across segments. A huge row receives a bounded preview
with full-source access; it cannot bypass the encoded-byte budget just because
it is the first row. Tool occurrence IDs remain distinct even when a provider
reuses its call ID. Full tool arguments, message inspection, source export and
model replay remain independent of the display window.

Earlier, Retry and Newer are explicit controls. A failed or non-progressing
request retains its cursor and reports a recoverable error. Pages adopt
atomically only after identity, coverage and resident-window checks. Loading
older content evicts the far newer edge, and vice versa, while protecting the
reading anchor and active selection. Latest actually fetches the source tail.
Nonoverlapping live snapshots preserve the reader's range and expose a newer
boundary rather than deleting history or pretending that a gap is adjacency.

The old 100,000-record index cutoff is removed. A cancellable worker scans the
supported journal and builds a private, disposable SQLite offset/branch index.
Offsets spill to disk; only the requested body window is decoded for display.
The derived index uses a 512 KiB SQLite cache and is removed on disposal. Eight
indexes/digests are retained. Index progress reports records/bytes at most once
per 150 ms. Cancellation and corrupt/incomplete tails never rewrite the journal.
Existing 128 MiB file and 32 MiB single-record support limits remain explicit.
Some branch/checkpoint validation maps are still proportional to source record
count within that supported file bound; this is not constant-memory parsing.

## Native rendering and transition review

Rich pages use viewport-first layout even below the old 32-row threshold. A
small plaintext fast path remains. Provisional offscreen geometry is kept out
of the exact shared-size cache and out of the mounted row tree. Selected native
text owners survive eviction. The fresh generation drops the old render tree;
the loading surface lifts only after visible rows and their Markdown sections
are prepared and the initial placement has settled. One destination draw is
requested after lifting the cover. There is no minimum spinner duration.

A giant Markdown answer initially measures six blocks and then up to four
visible blocks per resolution step. Unvisited blocks keep lightweight
descriptors. Corrections preserve a logical block identity and intra-block
offset across both block measurement and the hosting ancestor's later height
adoption. Frame observers are limited to that ancestor chain and removed with
the surface. A newer scroll position invalidates the old correction. Settled
code fences over 32 KiB expose UTF-8-safe sections of approximately 8 KiB, with
the complete original source available to Copy. Live fences retain their
existing renderer to avoid remounting during streaming.

The transition pass preserves the existing PiMotion tokens, app-owned motion
policy, native composer/IME, disclosure retargeting, queue/error slots, project
and topic disclosure, terminal process lifetime and popup sampling. It adds no
global animation and does not animate metric updates. Sidebar organization
continues its single publication/selection policy. Report return keeps the
mounted chat and its page intent. Optional/hidden presentation work remains
separate from essential model execution.

## Acceptance disposition

“Passed” below means the named deterministic source/native regression passed;
it is not a physical trackpad or live-provider claim. Logs and `.xcresult`
bundles are in this session's `tmp/fresh-transcript` directory. The release
record identifies the final reruns. Exact native geometry tests visit deferred
offscreen rows before asserting their sizes; they no longer assume optional
idle work runs while a test window is occluded.

| ID | Result | Evidence / scope |
| --- | --- | --- |
| SS01 | Passed | FreshPresentation barrier: immediate loading, no previous messages, metadata-ready composer. |
| SS02 | Passed | Known-empty versus malformed-header fixture; only authoritative emptiness gets the starter. |
| SS03 | Passed | Fresh revisit after earlier paging returns to six rows/three turns; draft/runtime retained. |
| SS04 | Passed | Idempotent selection retains generation/page; AutomaticContext tests recover optional preview separately. |
| SS05 | Passed | Explicit delayed A → B → C fixture; late A/B cannot publish or take focus. |
| SS06 | Passed | Delayed first A in A → B → A cannot replace the second A or acknowledge its geometry. |
| SS07 | Passed | Hydration typing and saved main/side draft fixtures; metadata and late-source guards. |
| SS08 | Passed | Open-helper hydration fixture dispatches Stop once, with no submit/open/execution replay. |
| SS09 | Passed | Independent main/ephemeral-side barrier fixture, separate ready callbacks/drafts; SideTests retain read-only/persistence rules. |
| SS10 | Passed | ReportMessageNavigation and around-window source tests retain explicit older-message intent. |
| PG01 | Passed | Stored 2,402 rows/1,201 turns and helper 2,202 rows traverse in canonical order. |
| PG02 | Passed | 401-row oversized turn and helper tool-round fixtures: segments retain original input reference/full source. |
| PG03 | Passed | Earlier failure preserves boundary; retry without switching adopts the expected prior page. |
| PG04 | Passed | Barrier fixture admits one edge request; repeated demand does not duplicate it. |
| PG05 | Passed | Real native tall-window fixture caps startup fills at two and retains working manual Earlier. |
| PG06 | Passed | Overlap/no-progress and malformed cursor fixtures retain content/cursor and surface failure. |
| PG07 | Passed | Mounted 1,100-row traversal crosses resident row cap: native document shows m0 and evicts far-tail content. |
| PG08 | Passed | Same large-body fixture crosses the projected-byte cap; selected requested coverage remains resident. |
| PG09 | Passed | Exhaustive 1,201-turn source traversal up/down; moving-window traversal and native Latest fetch actual tail. |
| PG10 | Passed | Escaped huge first-row wire fixture and native full-body access prevent oversized/zero-row loops. |
| PG11 | Passed | Helper reused-call-ID fixture preserves occurrence-specific results and full arguments across segments. |
| PG12 | Passed | Committed append keeps an existing disk cursor valid; snapshot merge preserves historical reading. |
| PG13 | Passed | Nonoverlapping live-tail regression retains old content and exposes the gap. |
| PG14 | Passed | Prefix rewrite/stale incarnation/branch reader tests and stale-generation adoption guards. |
| PG15 | Passed | Native file → mocked open helper handoff uses stable entry/lineage, never raw file offsets. |
| PG16 | Passed | Same fixture returns to committed disk after helper removal; ephemeral missing-owner test is explicit. |
| PG17 | Passed | Exhaustive traversal with index work segment reduced to 19; no semantic history cutoff. |
| PG18 | Passed | StorageTruth plus malformed header, incomplete tail, file bounds and page-shape regressions preserve source bytes. |
| PG19 | Passed | Old canceled page cleanup cannot clear a replacement generation's loading state; retry remains usable. |
| PG20 | Passed | 60 generated turn-boundary histories exhaustively match canonical forward/backward ranges; append/rewrite/branch interleavings have separate deterministic fixtures. |
| UX01 | Passed | Six-row coding-shaped fresh native fixture prepares only required visible rows. |
| UX02 | Passed | Actual native 3/8/16/32/33 rich-row measurements; no old all-rows threshold cliff. |
| UX03 | Passed | 640-block native answer, giant fence/full copy, and logical block anchor regression. |
| UX04 | Passed | Native document row/offset and provisional Markdown anchor tests. |
| UX05 | Passed | Two rapid scrolls before queued Markdown correction; the latest target wins. |
| UX06 | Passed | Native selected field/code retention, exact Copy, disclosure and protected-row paging fixtures. |
| UX07 | Passed | ConversationPane dual-stream switching plus generation-owned live-bar removal. |
| UX08 | Passed | All 14 TranscriptDisclosure tests, including reversal and tool updates while collapsed. |
| UX09 | Passed | Native viewport width/height/anchor tests and ConversationPane dual-pane focus/layout tests. |
| UX10 | Not run | Full physical matrix across report/inspectors/popup/terminal/settings not performed. Automated report, popup and lifecycle evidence is recorded separately below. |
| UX11 | Passed | OrganizationBatch tests retain atomic selection/publication while newer navigation wins. |
| UX12 | Passed | CompletionSound and SessionReadState regressions; native historical pages cannot emit completion/read receipts merely on adoption. |
| UX13 | Not run | Full physical CJK/RTL/larger-text/high-contrast/VoiceOver matrix unavailable; native marked-text, keyboard, selection and appearance tests provide partial evidence. |
| UX14 | Passed | Fifty fresh mounted generations release departed displays; row/byte/index bounds and canceled-index disposal asserted. |
| UX15 | Passed | ConversationPane two simulated streams and WorkspaceConcurrency twenty-session bursts; packaged helper completion/tool-loop capture regression. |

## Performance evidence and limits

Reference machine: **Apple M3 Max (Virtual), 16 GiB, arm64, macOS 14.8
(23J21), Xcode 16.1 (16B40)**. Native windows run serially. Optimized measurement
runs do not overlap compilation. These measurements end at native draw
opportunities, not physical display scanout.

The baseline regressions reproduced nonoverlapping-tail history loss and the
permanent earlier-page request latch before the fixes. Structural rendering
evidence changes the 640-block answer's initial native hosts from 640 to six.
The earlier Plan A 88 KiB cold-answer result (988.86 ms) uses a different fixture
and is not presented as a matched numerical speedup.

The final optimized pass measured 50 fresh six-row UI generations at
**50.88 ms p50 / 55.89 ms p95 / 66.07 ms maximum**. Rich pages with
3/8/16/32/33 rows took **17.46 / 66.06 / 86.30 / 93.71 / 80.13 ms**.
These are source-already-provided UI measurements.

The complete stored-file fixture uses **1,259,707 bytes / 2,001 records** of
coding-shaped history. A cold visit took **103.90 ms** through source adoption
and **179.79 ms** through useful native draw. Twenty index-hit fresh UI visits
took **66.09 ms p50 / 66.23 ms p95 / 66.25 ms maximum** from selection invocation
to useful draw; source adoption p95 was **9.34 ms**, and selection/loading
feedback p95 **1.00 ms**. No helper was launched to display these histories.

Aggregate layout/draw work in that run was **43.23 ms p95 / 50.69 ms p99 /
77.03 ms maximum**. It is aggregate synchronous host work, not an individual
display frame or indivisible sizing call. The proposed <5 ms main-thread-unit
goal is **not established**; viewport bounding removes unneeded work but native
text/hosting layout can still be expensive. Twenty mocked native cold opens
took 59.04 ms, refresh settlement 20.78 ms, and the MainActor heartbeat's
maximum gap was 6.44 ms in the independent concurrency fixture.

The separate combined workload completed **20 real local HTTP streams, 20 tool
round trips, 660 text events and 80 byte-exact durable bodies** in 2.732 seconds,
with two native 300-row panes, a 2 MiB inspector and marked-text composition.
It preserved selection/composition/capture integrity, but its UI steps were
**20.74 ms p50 / 104.39 ms p95 / 176.35 ms p99**, and the maximum MainActor
heartbeat gap was **194.78 ms**. Resize/release steps took 15.55 and 59.79 ms.
Those are remaining heavy-view stalls, not a pass of the proposed typing/frame
latency targets. Functional concurrency and latency budgets are separate claims.

Remaining evidence limits: no physical 60/120 Hz or trackpad judgement, no
hardware input-to-physical-draw latency, no authenticated live gateway request,
no full accessibility matrix, and no install/Sparkle update rehearsal (the last
two installation workflows are excluded by standing owner policy). The 2,001-
record cold selection fixture is not a worst-case 128 MiB archive claim. Some
very long single Markdown blocks still have indivisible native text layout;
code is sectioned, but large paragraph/table tokenization is not a background
native layout implementation. Normal app telemetry remains unchanged: the
opt-in performance probe records only counters/durations, never content.

## Changed areas and validation

- Shared `HistoryWindowPolicy`, helper `SessionReads`, `SessionDisplay` and
  `HostService`: bounded turn-aware source contract; optimized helper regressions.
- Native `HistoryReader` / `HistoryOffsetIndex`: complete cancellable indexing,
  prefix validation and bidirectional windows; stored-source regressions.
- `ConversationPresentation`, `WorkspaceHistory`, selection/refresh/side/run/
  shutdown/content flows and composer: presentation ownership, paging and draft
  safety; native generation, race and integration regressions.
- Native transcript page/document, Markdown surface, geometry cache, idle
  scheduler and code rows: viewport preparation, logical anchoring, disclosure
  preservation and full-source access; mounted AppKit fixtures.
- Features, Design, test handoff, version and release notes document the new
  behavior. Source commits stay local under the current release policy; the
  website publication commit is pushed to deploy the release.

See the [release validation record](validation/Bello-Agent-0.1.71-2026-09-21.md)
for final suite results, publication provenance and verified artifact checks.
