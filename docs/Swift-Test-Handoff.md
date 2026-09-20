# Native Swift — test and continuation handoff

## Current test selection policy

**Owner change, 2026-09-16, after 0.1.6:** shorten test/release cycles. Skip
fresh-install and actual Sparkle update/relaunch rehearsals unless the owner
explicitly asks for them again. Do not run the signed owner/update rehearsal
by default. Keep signing/notarization and public artifact verification. Earlier
installation results below remain historical evidence, not future release gates.

- Choose tests for the changed behavior and its integration boundaries. Reuse
  passing checks whose relevant source, dependencies and toolchain are unchanged;
  after a failure, rerun the focused check first and broaden only as warranted.
- Documentation-only changes need link/diff checks. Icon-only changes need asset
  generation/dimension checks and a build/visual check, not the entire UI gallery
  or gateway suite. UI logic needs the affected native/transcript tests; provider,
  capture and tool changes need their request-aware helper/gateway regressions.
- Run independent helper, Python and transcript checks concurrently, with
  separate logs and isolated fixture/build directories where required. Serialize
  tests that share native windows, dependency installation or a Swift build path.
- Reuse a stable `PI_BUILD_ROOT`, native DerivedData and Swift build caches.
  Give each run fresh fixture/log subdirectories; avoid cleaning or recreating
  caches without a specific reason. Rebuild changed outputs incrementally.
- The gallery and interactive gateway fixtures are opt-in for changed visual or
  interaction behavior. Do not set their opt-in variables on routine test runs.
  Preserve existing assertions and report skipped/reused checks accurately.

The matrices and commands below are available coverage, not a requirement to
execute every suite for every change. This policy supersedes older blanket gates.

Updated 2026-09-20. **Use `main` in `BelloWare/BelloAgent`.** See the
[implementation status](Implementation-Status.md) for the current public release,
and the [crash audit implementation](Crash-Audit-Implementation-2026-09-20.md)
for the latest crash/lifecycle fixes. The [0.1.61 validation record](validation/Bello-Agent-0.1.61-2026-09-20.md)
records optimized native/helper tests, explicit actor checks and publication.
Current release records take precedence over the historical matrices below.
Installation/update rehearsals remain skipped by owner instruction.

## 2026-09-20 performance acceptance (included in 0.1.61)

Read the [performance implementation record](Performance-Review-Implementation-2026-09-20.md)
for measurements, rejected prototypes and remaining stalls. The original work
was source-only; the subsequent crash-audit request authorizes its inclusion in
0.1.61/build 65.
Validation totals: **83 distinct focused passes**, plus 12 unchanged parser/copy/
cache-lifetime checks reused from the earlier successful Release selection. The
final scheduler/load selection passed 16/16 and the isolated scroll/stream repeat
passed 3/3. All exact geometry, source, capture, input and accounting assertions
remain. Timing results are mixed; do not claim universal scrolling improvement.

Use Release with `ENABLE_TESTABILITY=YES`, the existing native DerivedData and
staged helper. Run native-window tests serially. Once the changed binary is built,
use `xcodebuild test-without-building` for additional selections of that binary.
Relevant suites:

- Motion, resize and scheduling: `TranscriptDisclosureTests`,
  `TranscriptStreamingStressTests`, `TranscriptIdleSchedulerTests`,
  `TranscriptGeometryCacheTests`, `ReportNavigationTests`.
- Text and input: `NativeCodeTextTests`, `NativeMarkdownSizingTests`,
  `NativeMarkdownViewportTests`, `MarkdownStreamingTests`,
  `TranscriptMarkdownTests`, `ComposerAttachmentDestinationTests`, and the
  paste/marked-text/typing/two-chat cases in `ConversationPaneTests`.
- Measurements and retention: `NativeTranscriptScrollingPerformanceTests`,
  `FiveSessionWorkspacePerformanceTests`, and the streaming, disclosure-tick,
  scrolling and page-retention cases in `TranscriptFrameBudgetTests`.

The opt-in combined native/helper/gateway workload is:

```sh
PI_REVIEW_VISUAL_LOAD=1 TEST_RUNNER_PI_REVIEW_VISUAL_LOAD=1 \
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-release" \
  -only-testing:PiAppTests/CaptureMacIntegrationTests/testTwentyColdNativeSessionsStreamToolsAndPersistEveryExactBody \
  ENABLE_TESTABILITY=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```

Leave that opt-in unset for the isolated capture/concurrency comparison. It uses
20 real loopback sessions/tool round trips/exact captures; the two 300-row UI
history prefixes are synthetic and do not enter provider context. The inspector
contains 2 MiB of fixture JSON. IME is driven through native test APIs, not physical
keyboard input. This is correctness/load evidence, not proof of a frame-rate target.

For the scrolling-size variation, set both `PI_PERF_SCROLL_ROWS=2000` and
`TEST_RUNNER_PI_PERF_SCROLL_ROWS=2000`. The production page cap still applies:
**2,000 source messages produce 500 rendered rows**. The test now reports both.
Keep visual readiness separate from exact offscreen settlement in tab/resize
fixtures. Never compare a provisional row frame as if it were final, or weaken
the final exact-geometry assertions to make timing tests pass.

The work preserves helper/capture semantics, complete source and copy actions,
cache limits and native selection. It does not establish physical 60/120 Hz
cadence, VoiceOver, system-driven Reduce Motion, external-display moves or
slow-storage behavior. No install/update or publication checks were run during
that source-only task; the separate 0.1.61 record covers publication.

## Current 0.1.57 concurrent-session responsiveness acceptance

Version 0.1.57 isolates per-chat usage notifications, skips hidden helper transcript
projection, rejects stale refresh replies and reuses verified immutable native row
geometry. In the five-session fixture, background content/billing work fell from
12.51 ms to 7.24 ms mean, with zero whole-workspace notifications. A return to the
initially mounted chat took 629.11 ms to readiness plus 68.76 ms deferred settlement;
the original readiness-only baseline was 1,421.23 ms. Repeated helper status reads
fell 98.0%. Acceptance covers 118 distinct native passes, 41 helper passes and three
request-aware concurrent gateway scenarios (162 distinct passes), with two native
interactive checks skipped. The final shipping-source selection passed 23/23;
unchanged checks reuse the earlier successful selections, excluding four discarded
experimental tests. Twenty simultaneous requests completed tools and exact capture.
A shared Markdown-block cache was rejected after it slowed long-answer scrolling.
Rich foreground layout still has spikes (54.46 ms mean, 124.57 ms maximum), and cold
large-history loading remains expensive. Physical trackpad/VoiceOver smoothness is
unverified on this inactive desktop. Installation and actual update rehearsals stay
skipped under the owner’s policy.

The signed/notarized release and public feeds/archive are verified. Read the
[five-session performance review](Five-Session-Performance-Review-2026-09-19.md) and
[0.1.57 acceptance record](validation/Bello-Agent-0.1.57-2026-09-19.md). Installation/update rehearsals
remain skipped under the standing owner policy.

## Historical 0.1.56 topics acceptance

Version 0.1.56 adds project topics: collapsible, named groups for related
sessions, with New Chat, rename, removal that keeps chats, and drag-and-drop
between topics or back to the project header. Move to Topic is also available
in session menus. New chats inherit the focused topic, sides/forks inherit
the source group, and moving a parent includes its saved side descendants.
Atomic metadata updates preserve active work, drafts, history and session IDs;
regressions cover side publication, late writes and concurrent deletion.
Topics and their disclosure state persist across restart.

The native Release selection passed 90 tests with no failures or skips; a
final seven-test subset also passed after checking the packaged drag-type
declaration. Unchanged helper/gateway/scrolling evidence was reused. Physical
pointer drag/drop, context-menu interaction and VoiceOver remain unverified
on the inactive remote desktop; real item-provider dispatch and hosted native
sidebar layout passed. Installation/update rehearsals remain skipped.

The signed/notarized release and public feeds/archive are verified. Read the
[topics review](Topics-Review-2026-09-19.md) and
[0.1.56 acceptance record](validation/Bello-Agent-0.1.56-2026-09-19.md). Installation/update rehearsals
remain skipped under the standing owner policy.

## Historical 0.1.55 scrolling acceptance

Version 0.1.55 keeps only nearby native transcript rows and Markdown blocks
attached while retaining complete content, exact geometry and selected text.
The 300-message fixture drops from 85.7 to 9.6 ms per native scroll step on
average; the 88 KiB answer drops from 44.6 to 13.0 ms. These are comparable
layout/display stress measurements, not physical display FPS. Initial loading
of every retained row still requires an up-front geometry pass.
The affected Release XCTest run executed 78 cases: 76 passed and two interactive
pointer checks were explicitly skipped on the inactive remote desktop. A final
four-case Markdown/scroll rerun passed after fixing Copy/Copied layout feedback.
Unchanged provider/helper/gateway/worker and website-staging acceptance is
reused; physical trackpad and VoiceOver checks are not claimed. Single enormous
Markdown blocks and selection at the streaming renderer threshold remain
qualified in the scrolling review. Installation/update rehearsals are skipped
under the owner’s standing instruction.

The signed/notarized release and public feeds/archive are verified. Read the
[scrolling review](Scrolling-Review-2026-09-19.md) and
[0.1.55 acceptance record](validation/Bello-Agent-0.1.55-2026-09-19.md). Installation/update rehearsals
remain skipped under the standing owner policy.

## Historical 0.1.54 session-reference acceptance

Version 0.1.54 adds Copy Session ID and Copy Session Reference to session right-click and conversation “…” menus. References include the authoritative local JSONL path and a shell-quoted read command, without switching chats, loading history or starting helpers. Empty chats and imported identities are explicit. All 27 focused native tests and 12 site-staging tests pass, including executable Bash quoting and complete retained-history reads. The release-page template now preserves native-transcript and reported-throughput wording. Existing helper, gateway, concurrency and rendering evidence is reused. Physical menu/VoiceOver and install/update rehearsals were not repeated.

The signed/notarized release and public feeds/archive are verified. Read the
[session-reference review](Session-Reference-Review-2026-09-19.md) and
[0.1.54 acceptance record](validation/Bello-Agent-0.1.54-2026-09-19.md). Installation/update rehearsals
remain skipped under the standing owner policy.

## Historical 0.1.53 responsiveness acceptance

Version 0.1.53 uses Bello-styled selection panels and disables the system window tab strip. Exact row-layout caches isolate retained transcript text from streaming updates; ownership-scoped accounting avoids repeated history reads. Comparable native rendering fixtures open about 37% faster and reduce per-update layout/display work by 85.4% (61 rows) and 91.7% (300 rows); these are stress measurements, not a 60 fps guarantee. Final focused evidence contains 191 distinct native passes and four explicit interactive-desktop skips. The native/helper/gateway fixture completed 20 concurrent sessions and tool round trips with 80 exact retained bodies. Unchanged helper/provider/worker evidence is reused from 0.1.52. Pointer/popover and VoiceOver behavior are not claimed as verified on this remote desktop. Installation/update rehearsals remain skipped under the standing owner policy.

The signed/notarized release and public feeds/archive are verified. Read the
[responsiveness review](Responsiveness-Review-2026-09-19.md) and
[0.1.53 acceptance record](validation/Bello-Agent-0.1.53-2026-09-19.md). Installation/update rehearsals
remain skipped under the standing owner policy.

## Historical 0.1.52 throughput and worker acceptance

Final evidence: **140 native passes, 2 optional skips, 188 helper passes and 29 packaged gateway/process passes**.
The signed/notarized release and public feeds/archive are verified.
Read the [throughput/worker review](TPS-Workers-Review-2026-09-19.md) and
[0.1.52 acceptance record](validation/Bello-Agent-0.1.52-2026-09-19.md).
Rate migration/expiry, hidden reasoning, stable and narrow native metric layouts,
bounded OS-thread execution and the full twenty-session path are covered.

## Historical 0.1.51 concurrency acceptance

Final evidence: **137 native, 176 helper, 29 packaged gateway/process cases pass**.
The signed/notarized release and public feeds/archive are verified.

The twenty-session target covers overlapping model streams within one project
and across projects, exact durable capture, tool round trips, isolated Stop/error
handling, cold project/session initialization and accounting bursts. Read the
[concurrency review](Concurrency-Review-2026-09-19.md) and
[0.1.51 acceptance record](validation/Bello-Agent-0.1.51-2026-09-19.md) for the
current results and concurrency boundaries.

After staging the changed helper, run the deterministic wire pressure scenarios:

```sh
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

Relevant native suites are `WorkspaceConcurrencyTests`, `HostSupervisorTests`,
`HostTransportTests`, `HostInboxTests`, `PayloadArchiveTests`,
`CaptureMacIntegrationTests`, `LiveAccountingTests` and the affected workspace
lifecycle/context/connection suites. Run Xcode writers serially against the
shared DerivedData. The helper's `CaptureConcurrencyTests` and
`ConcurrentSessionsTests` exercise capture pressure and session/editing-gate
isolation. Do not mistake a twenty-request network barrier for twenty dedicated
threads or unrestricted parallel file mutations.

## Historical 0.1.50 acceptance

Version 0.1.50 improves warm chat loading, trims unnecessary initial history,
keeps native text geometry stable during transitions, speeds up code coloring,
and preserves scrolling while new output arrives. Focused Release checks cover
195 passing native cases and one opt-in skip, with no failures. Unchanged helper,
gateway and release-tool evidence is reused from 0.1.49. Large rich histories
still have expensive native layout; this release does not establish a universal
frame-rate target. See the [performance review](Performance-Review-2026-09-19.md)
and [0.1.50 acceptance record](validation/Bello-Agent-0.1.50-2026-09-19.md).

## Historical 0.1.49 acceptance

Version 0.1.49 reviews Claude's completed 0.1.48 work and fixes confirmed
queue, crash-recovery, transcript, inspector, transport and storage defects.
It also coordinates context previews and connection removal across suspended
operations, preserving drafts and readable context snapshots. All 498 native
cases completed: 491 passed and 7 opt-in cases skipped. The helper's 170 tests,
52 Python checks and 24 local gateway checks passed. See the
[deep review](Deep-Review-2026-09-19.md) and
[0.1.49 acceptance record](validation/Bello-Agent-0.1.49-2026-09-19.md).

## Historical 0.1.19 acceptance

Version 0.1.19 completes a deeper review of Claude's recent changes and the
Settings-to-existing-chat catalog flow. It fixes clock-correction write loss,
quit and side recovery failures, non-atomic handoffs, false transcript paint/read
acknowledgements, command replay after ledger eviction and duplicated queued
messages after a partial journal commit. Response capture masks known credential
echoes across streaming boundaries and labels that transformation. Archive
maintenance avoids repeated whole-store sweeps; partial cache observations keep
paired sample coverage. Existing catalog lineage and explicit repair remain.
Unavailable live-export bodies cannot be misrepresented as empty captured files.
See the [review and remaining limits](Deep-Review-2026-09-17.md).

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
**29 transcript tests, TypeScript checking and 10 dependency-cache tests pass.**
Four native tests exercise the packaged React page in WKWebView, including
render rejection and recovery. Local HTTP/SSE fixtures validate requests, tools,
cancellation, compaction and capture; no deployed LiteLLM was used. No full
screenshot gallery or Release performance matrix was run. Installation/update
rehearsals were skipped by owner instruction.

## Historical 0.1.18 acceptance

Version 0.1.18 makes stale catalog sources visible in older unbound chats.
The model picker offers a direct Use this catalog action for one later saved
custom list on the same gateway, or a chooser for multiple alternatives. The
selected source loads immediately and persists across restart. Repair preserves
the request connection, credentials, selected model, reasoning effort, output
budget and history. Explicit source bindings remain authoritative.

**67 focused native tests passed**, with 0 skips and
zero unresolved failures. Counts come from the actual test log, with repeated
cases counted once. Coverage includes the original save/inherit flow, legacy
repair and restart, distinct/multiple sources, explicit-binding preservation,
refresh source routing and the mounted picker's visible banner/replacement rows.
The mounted-view check invokes the action shared by the button; it does not
claim a physical mouse click. Unchanged helper/context/capture and transcript/
TypeScript evidence is reused from 0.1.17 and its referenced earlier records.
No live deployed gateway or full screenshot gallery was run. Installation/update
rehearsals were skipped by owner instruction.

The originally reported fresh-save alias/catalog flow was already handled
by inheritCatalog and covered by an integration test. The remaining gap was
older records without catalog lineage: Refresh correctly reloaded their old
source but gave no prominent repair path. Suggestions now use later saved
same-base/API records with a different custom URL, independently of profileChoice.
No independent connections are silently merged. See the
[issue resolution](Issue-Stale-Chat-Model-Catalog.md).

## Historical 0.1.17 acceptance

Version 0.1.17 uses one request-aware context count for the ring, inspector,
preflight and compaction. It counts the actual provider-built instructions,
tools and replayed input. Gateway-reported input is reused only for a matching
prefix and an explicitly pinned, reported model; previous output is not added
wholesale. Counts carry method, request fingerprint, model and uncertainty.
Safe idle tabs and draft edits refresh through a shared debounce/cache; pending
counts do not display stale conversation totals. Output budgets are a local
reserve, separate from catalog model ceilings (which are what requests carry as
their output limit), with a distinct safety margin. Reported usage,
request context and estimated live output activity remain separate measurements.

**129 unique native tests and 132 unique helper tests have a final
observed pass.** Initial broad runs did not pass: one native case and three
helper cases failed. The corrected focused reruns passed (36 native, seven
capacity and 11 request-context cases), followed by 21 passing final helper
context/gateway/capacity cases. Every initial failing case has a later pass;
repeated executions are counted once. Coverage includes debounced/stale context,
output-budget migration, replay/baseline invalidation, image uncertainty and a
request-validating loopback gateway with exact request/response capture.
The unchanged transcript/WebKit/TypeScript evidence is reused from 0.1.16.
No live deployed gateway, remote token counter, screenshot gallery or physical
UI interaction is claimed. Installation/update rehearsals were skipped by owner
instruction.

These remain estimates, not exact tokenizer results or independently
verified billing usage. No remote counting endpoint is enabled: the reviewed
LiteLLM interfaces do not establish complete Responses request compatibility
and a route-bound counted model. Automatic routing and opaque/image costs retain
explicit uncertainty. See [Context-Accounting.md](Context-Accounting.md).

## Historical 0.1.16 acceptance

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

**74 unique focused native tests passed**, with
1 optional capture skip and zero failures. The initial native run executed
75 cases (74 passed, one skipped); the final Stop run rebuilt the app and repeated
five follow-up cases. Repeated cases are counted once. **115 unique helper tests,
27 transcript tests and 9 WebKit disclosure checks passed**; TypeScript passed.
Loopback HTTP 429/SSE failure fixtures verify useful errors, credential masking,
no automatic retry and exact captured bytes. Native coverage includes retained
errors, weighted timing and actual wide/narrow footer rendering with OCR.
No manual Stop click, screenshot gallery or full interactive gateway run is claimed.
Installation/update rehearsals were skipped by owner instruction.

## Historical 0.1.15 acceptance

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

**27 focused native tests passed with zero failures in 0.714 seconds**:
Workspace 17, ProjectSidebar 6 and ReleaseConfiguration 4. Three new regressions
cover live folder-selection state, cancellation/reopening and second-project
persistence with a fresh vault readback. These are state/integration checks;
physical NSOpenPanel interaction was not exercised. Unchanged context/catalog,
provider/transcript/capture evidence is reused from 0.1.14 and earlier records.
Installation/update rehearsals were skipped by owner instruction.

## Historical 0.1.14 acceptance

Version 0.1.14 calculates prepared context automatically when a safe idle
chat opens, using the local helper without sending a model request or executing
tools. Matching estimates are reused; cancelled or changed inputs cannot publish
stale results. Unsent chats retain their allocated journal across helper eviction.

Catalog lists now resolve independently of preserved request connections.
New same-authority default-model forks keep catalog linkage; older chats can
choose a saved custom catalog through **Catalog source…** in the model picker.
Refresh reloads saved bindings, requests HTTP revalidation and displays its
successful update time. Changing the list preserves the chat's request route,
credentials, selected model and effort. Legacy lookalike connections are not
automatically merged because their records contain no reliable lineage.

**98 unique focused native tests passed with zero failures.** The catalog/
configuration run passed 71 cases in 9.523 seconds; the final context/workspace
run passed 34 cases in 2.144 seconds, including seven repeated catalog-source
cases with strengthened credential assertions. Counts are not added twice.
The packaged-helper fixture verifies automatic calculation, no model request,
no message/queue changes, durable unsent journal paths and unchanged bytes after
helper reopening. Local catalogs verify refresh, metadata and credential scope.
Unchanged provider/transcript/capture evidence is reused from 0.1.13 and earlier
records. Installation/update rehearsals were skipped; the owner will test on
their own MacBook.

## Historical 0.1.13 acceptance

Version 0.1.13 fixes chat catalog Refresh by reloading the saved connection
before fetching, using the same path as Settings. Chat TTFT and TPS show the
same latest completed request and retain it while a new request runs. Hover
shows native history charts; clicking keeps them open. Charts cover up to 128
recent completed requests in that session/project, with gaps for missing
measurements. Usage-window/menu-bar historical averages remain independent.

**108 focused native tests passed with zero failures in 13.773 seconds**:
GatewayAccounting 19, LiveAccounting 5, MenuBarMetrics 21, ModelCatalogEndpoint
19, ModelSwitch 15, ReleaseConfiguration 4, SessionTiming 9, SessionUsage 10,
SettingsSave 6.
Synthetic native fixtures cover picker rendering and timing charts. The release
record preserves the corrected Swift test-helper isolation error and explains
why an inactive-window mouse harness does not establish a physical click or
end-to-end hover test. Unchanged helper/provider, transcript and capture evidence
is reused from 0.1.12. No installation/update rehearsal was run.

## Historical 0.1.12 acceptance

Version 0.1.12 adds Combined JSON for Responses streams, retaining the terminal
response object or an explicitly partial reconstruction. Events, UTF-8/hex,
original-byte exports and capture-state labels remain. Session usage opens in
reusable resizable native windows with tokens, response/prompt caching, reported
and reasoning cost, historical TPS and model/cost distributions. Windows retain
their session scope across chat changes and stop reads when closed.

**89 focused native tests passed with zero failures in 4.716 seconds**:
CapturedBody 14, CombinedResponse 21, MenuBarMetrics 21, MessageDetail 9,
SessionUsage 10 and Workspace 14. Five synthetic own-window views were inspected.
Helper/provider, transcript, catalog and storage evidence is reused from 0.1.11
and earlier records because those sources are unchanged. No deployed gateway,
full gallery, installation/update or signed owner/update rehearsal was run.

## Historical 0.1.11 acceptance

Version 0.1.11 simplifies reply footers to one response-body model, with
header/body evidence on click. Captured SSE responses now open as expandable
JSON event trees with original framing and bytes preserved. Calculated context
previews update the footer, with stale-input/activity/reopen guards; unloaded
context offers “Inspect context” without an automatic model request.

**103 unique focused native cases pass** after correcting two optional
screenshot readiness checks. The final 21-case viewer/context rerun passed in
1.248 seconds; helper ContextPreview 4 passed in 0.085 seconds, transcript 25
passed and TypeScript passed. Two synthetic own-window JPEGs were inspected.
The 100k-attempt Debug accounting fixture preserved attribution and coverage
(101-message page 605.350 ms; session-only 68.847 ms; one message 65.396 ms).
See the release record for individual suites and the original failures.
Unchanged catalog/onboarding/title and broader evidence is reused from 0.1.10
and earlier records; it was not rerun. No full gallery, deployed LiteLLM,
install/update/relaunch or signed owner/update rehearsal was performed.

## Historical 0.1.10 acceptance

Version 0.1.9 honored a model catalog only when a custom URL was saved; the
repository's catalog file was not packaged in the app. Version 0.1.10 fixes that
missed default path: nil, empty and whitespace catalog settings now load the
bundled six-model Bello catalog without requesting gateway models or reading an
API key. Existing selected aliases, reasoning efforts and per-connection defaults
are preserved. Explicit custom catalogs remain authoritative, with no fallback
to either the bundle or gateway after a custom-source failure.

**60 focused native tests passed, zero failures, in 6.899 seconds.**

| Native suite | Passed | Seconds |
| --- | ---: | ---: |
| ModelCatalogEndpoint | 18 | 5.365 |
| ModelSwitch | 11 | 0.243 |
| Onboarding | 18 | 0.684 |
| SettingsSave | 6 | 0.169 |
| TitleGeneration | 7 | 0.439 |

Checks read the actual application-bundle catalog and assert all six aliases,
context/output limits and reasoning choices. Legacy/blank defaults require no
gateway traffic or credential lookup; explicit catalogs retain source isolation,
credential-origin checks, caching and cancellation guards. Remembered choices,
Settings saves, onboarding probes and title-session isolation remain covered.

Three synthetic own-window picker JPEGs were visually inspected, with OCR
assertions for the default, custom-catalog and error views. No unrelated
application content is captured.
The unchanged helper, transcript, capture/accounting, chrome, broader native and
Keychain evidence is reused explicitly from the [0.1.9 record](validation/Bello-Agent-0.1.9-2026-09-16.md)
and its linked historical records. Those are not additional tests run for 0.1.10.
No full gallery, deployed LiteLLM, fresh-install, Sparkle update/relaunch or signed
owner/update rehearsal was run. Log: `catalog-default-fix/native.log` in session scratch.

## Historical 0.1.9 acceptance

| Focused native suite | Final passing cases |
| --- | --- |
| AccountingScale | 1 |
| CapturedBody / MessageDetail / PayloadArchive | 9 / 7 / 13 |
| GatewayAccounting / LiveAccounting | 16 / 5 |
| MenuBarMetrics / MenuBarPresentation / SessionUsage | 21 / 3 / 6 |
| ModelCatalogEndpoint / ModelSwitch | 14 / 11 |
| ProjectSidebar / SessionOrganization | 6 / 8 |
| SettingsSave / TitleGeneration | 6 / 7 |
| WindowPresentation / ReportNavigation | 5 / 3 |
| Workspace | 14 |

**155 unique focused native tests pass after corrections and focused reruns.**
The first broad selected run executed 155 tests in 19.717 seconds with four
failed assertions across two cases: catalog-render inspection and a 28-point
native safe-area inset. The layout fix applies top safe-area handling to the
split child; the final WindowPresentation/ReportNavigation rerun passes.
The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.
ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.

Helper title/session/context checks: **17 passed in 0.494 seconds**. Transcript:
**24 passed in 0.811 seconds**; TypeScript passes. Capture coverage includes
CapturedBody 9, MessageDetail 7 and PayloadArchive 13. TitleGeneration 7 includes
an actual packaged-helper loopback request checking the chosen mini model,
512-token output cap, disabled tools, isolated instructions, one dispatch,
durable title session and separate capture/cost accounting.

The 100,000-attempt/300,100-link Debug fixture preserves attribution and
coverage: a 101-message page took **555.924 ms**, session-only **56.682 ms**, and
a single-message query **59.201 ms**. These are local database timings, not
input-to-paint measurements or the full Release performance budget.

Eleven synthetic JPEGs were inspected: five session/menu usage views, three window-chrome views, expandable JSON, and two model-picker views. They show only isolated fixture windows, not unrelated applications.
Unchanged broader provider/wire/process, Python, native/gallery and ordinary
Keychain evidence is reused from versioned records. No full gallery, deployed
LiteLLM test, production gateway credentials, install/update or signed owner/update
rehearsal was used.

## Historical 0.1.8 acceptance

| Focused native suite | Result |
| --- | --- |
| WindowPresentation | 5 passed, 1.091 seconds in the combined run |
| ReportNavigation | 3 passed, 4.318 seconds |
| WindowPresentation, optional capture readiness rerun | Same 5 passed, 2.756 seconds |

**Eight unique focused native tests pass**: WindowPresentation 5 and
ReportNavigation 3 (5.409 seconds combined). The five window tests passed again
(2.756 seconds) after optional capture-readiness changes. Three synthetic JPEGs
were inspected: light chat, compact dark chat and light report. Checks cover the
real SwiftUI WindowGroup after layout/resize, native-control exclusions,
zoom/restore, focus/drafts and retained report/chat surfaces. A test-only SDK
compile issue was corrected; no test assertion failed. See the
[0.1.8 record](validation/Bello-Agent-0.1.8-2026-09-16.md) for scope and logs.

Unchanged 0.1.7 (81 tests) and broader 0.1.6 evidence is reused. No full native
suite/gallery, provider/performance acceptance, install/update or signed
owner/update rehearsal was run.

For chrome-only changes, select `WindowPresentationTests` and
`ReportNavigationTests` with the existing native DerivedData. Optional
`PI_APP_CHROME_CAPTURE_ROOT` (and `TEST_RUNNER_PI_APP_CHROME_CAPTURE_ROOT`) writes
three own-window JPEGs from isolated synthetic state; `PI_APP_SCRATCH_ROOT`
controls its fixture directory. The capture waits for actual transcript paint
and completed transitions only when enabled. This is a focused visual check,
not the full screenshot gallery or provider acceptance.

## Historical 0.1.7 acceptance

| Focused native suite | Result |
| --- | --- |
| GatewayModelDiscovery | 9 passed, 1.051 seconds |
| ModelCatalogEndpoint | 12 passed, 1.112 seconds |
| ProjectSidebar | 6 passed, 0.179 seconds |
| Workspace | 14 passed, 0.341 seconds |
| ModelSwitch | 11 passed, 0.468 seconds |
| Dashboard | 14 passed, 1.088 seconds |
| MenuBarMetrics | 15 passed, 0.524 seconds |

These are **81 unique passing tests**, not a full native suite. The first four
passed in the initial focused run; the last three passed in the final run after
a simulated restart fixture closed the previous instance's request archive.
The original five failed assertions and logs remain documented, and all original
assertions now pass. Coverage includes visible-picker loading without hover,
saved catalog changes, per-connection choices across projects/restarts, pending
picker saves, atomic failure rollback and conflicting model-name reporting.

Unchanged helper/wire/process/transcript and broader native/gallery acceptance
is reused from 0.1.6 below. No full suite, gallery, full interactive gateway or
new reveal-gesture check was run. Signed/notarized artifact and public
page/icon/feed/archive checks pass. See the release record for commands and logs.

## Historical 0.1.6 acceptance

These results cover the reviewed catalog, fallback, Settings, scratch chat,
compaction, report/sidebar and selected-icon changes. The gallery is included
in the native total. Distribution evidence is recorded separately.

| Check | Result |
| --- | --- |
| Helper core | 105 passed, 5.179 seconds |
| Optimized wire / process-MCP | 24 passed, 5.339 seconds / 2 passed, 2.599 seconds |
| Python release/gateway | 52 passed, 17.046 seconds |
| Transcript | 21 passed, 0.933 seconds; TypeScript passed |
| Full native app, gallery enabled | 247 executed: 246 passed, one interactive opt-in skip, zero failures; 91.525 seconds |
| Gallery and packaged onboarding probe, included above | One passed, 75.464 seconds; 30 light/dark captures |
| Isolated signed Keychain owner/update acceptance | 51 checks/observations passed |

The four Settings regressions preserve untouched legacy credentials and active
connections, reject edited blank URLs without partial saves and distinguish an
untouched new form from incomplete connection edits. Five native follow-up tests
cover the scratch composer and tool-free context preview, selection-independent
connection-test submission, side restrictions, open-child deletion guards and
compaction notices. The scratch composer test sends no HTTP request and verifies
that switching away and back preserves its composer and draft. Helper regressions
cover successful, failed, cancelled and abandoned-branch compaction summaries.

The initial hidden-window scratch test failure was reproduced in isolation and
fixed with its fixture window shown and laid out while retaining all original
assertions and adding a return-to-scratch check. The focused five-test rerun
passed in 0.496 seconds before the final full suite above. The strict gateway
fixture also gained malformed-request probes for default `disable_fallbacks`.
Original failures and logs remain in the 0.1.6 record. No full interactive
gateway run was repeated; the eight-request CUA evidence below is historical.

## Historical verified 0.1.5 acceptance

Bello Agent 0.1.5/build 9 was released from source `3460390`, website `51d81cf`.
Signing/notarization, public bytes and the actual 0.1.4→0.1.5 update passed.
All 75 installed files/links matched; history and unchanged Keychain revision 0
remained available. See the [0.1.5 record](validation/Bello-Agent-0.1.5-2026-09-16.md).

These results include the final updater/composer corrections. Signed/public
and actual-update evidence is recorded separately in the release record.

| Check | Result |
| --- | --- |
| Helper core | 101 passed, 4.905 seconds |
| Optimized wire / process-MCP | 24 passed, 5.160 seconds / 2 passed, 2.576 seconds |
| Python release/gateway | 52 passed, 16.967 seconds |
| Transcript | 21 passed; TypeScript passed |
| Full native app, gallery enabled | 236 executed: 235 passed, one opt-in skip, zero failures; 91.136 seconds |
| Gallery and packaged onboarding probe, included above | One passed, 75.587 seconds; 30 light/dark captures |
| Separate CUA fixture | One passed, 670.249 seconds; eight requests/16 exact bodies, 1,290 tokens and $0.0101375 |

The historical 0.1.5 CUA run covers two menu opens, day/retained usage scopes, Report and
main-window close/recovery, background cost and unread updates, session
title/pin/archive/restore, exact code-block and Markdown-section copying,
context preview, captured requests/direct header display, a Bello-only skill
toggle, empty `/side` with draft close/reopen, `/fork`, and actual native
title-bar double-click zoom/restore. The helper/native suites additionally
cover complete-context fork persistence, policy migration and stale async work.
No deployed LiteLLM or production credentials are used. Physical status clicks,
successful foreground unread clearing, real-language IME and full Release
performance acceptance are not claimed by this run.

The app captures request/response bodies and headers by default, with
30-day plaintext body retention subject to quota and no reveal gate. Ordinary
headers remain readable; longer request auth tokens retain only a masked final
four-character suffix, while short tokens, cookies, response authentication and
credential echoes are fully masked. Body credential literals remain explicitly
hashed capture transformations with wire bytes unchanged. Legacy encrypted
history remains readable. Policy migration preserves session overrides and
distinguishable custom/off settings; legacy seven-day retention always becomes
30 days because the old format cannot identify an explicitly selected seven
days. Other custom retention and all new-policy deliberate settings remain.

All projects now have persistent sidebar groups. Rename/pin/archive/restore,
background cost refresh and running estimated TPS apply without a focus change.
New sides are durable children immediately; closing only hides their pane and
preserves work/drafts. Forks are independent and inherit complete context rather
than queued work. Context inspection uses a read-only provider-built preview,
and individual skill disabling is saved only in Bello Agent configuration;
Codex/shared sources remain untouched.

## Historical verified 0.1.4 release

See the [0.1.4 acceptance record](validation/Bello-Agent-0.1.4-2026-09-16.md) for
commands, logs, source scope and exact limitations. Current active requests are
Responses-only; preserve historical Messages records/keys and explicit conversion.
The selected architecture is native SwiftUI/AppKit throughout (composers, the
conversation page and, since 0.1.38, the terminal) with the self-contained Swift helper; there is no Node, React or WebKit.

| Check | Result |
| --- | --- |
| Native app | 195 executed: 193 passed, two opt-in skips, zero failures; 12.980 seconds |
| Python release/gateway | 52 passed, 17.159 seconds |
| Helper core | 92 passed, 4.862 seconds; final focused activity 3 passed, 0.091 seconds |
| Optimized wire / process-MCP | 23 passed, 3.110 seconds / 2 passed, 2.586 seconds |
| Transcript | 13 passed; TypeScript passed |
| Final report-page regression | 15 passed, 1.330 seconds; compact grouping/pagination controls corrected |
| Gallery and packaged onboarding probe | One passed, 76.585 seconds; 30 light/dark captures |
| Final fresh CUA | One passed, 284.612 seconds; four requests/eight exact bodies, 677 tokens and $0.0051375 |

The gallery verifies the actual onboarding helper/vault/capture boundary before
any chat exists, checks cleanup and then renders the app. CUA exercises the owner
billing sample, tool continuation, slow output, request Details, report links,
status Activity/Usage, usage scopes and recovery after closing the main window.
Unread remains while Report is visible. During final foreground-clear acceptance,
SecurityAgent held focus and CUA refused access to it; the inactive chat correctly
kept unread state. Do not claim successful foreground clearing from that run.
Native tests separately cover painted frames, visibility, stale receipts and restart.

The fixture invokes the actual status-button action; physical left/right menu
clicks remain outside CUA, while native tests cover both event masks. Chart
dragging, real-language IME and the complete Release performance budget remain
unverified. Earlier Debug burst-input/helper-to-paint targets were missed. Local
request-aware mocks use no production vault or real gateway; they do not establish
deployed LiteLLM compatibility.

The [0.1.3 record](validation/Bello-Agent-0.1.3-2026-09-16.md) preserves earlier
source/UI counts and its verified signing, public-byte and actual 0.1.2→0.1.3
Sparkle installation. The 0.1.4 record confirms the repeated release checks and all 51 isolated signed
Keychain checks/observations.
Clipboard's ordinary Keychain/profile-free Developer ID flow remains selected:
one versioned vault item, scoped helper IPC, no plaintext/per-profile fallback,
no signing-key ACL or persistent-policy change. The historical 0.1.6 signed synthetic
owner/update suite repeated all 51 checks/observations without failures;
ordinary Keychain does not promise raw same-user write/delete isolation.
Preserve the bundle ID, Keychain item, history paths and Sparkle signing key.
The selected exact flat icon and deterministic resamples are recorded in
[icon provenance](../assets/branding/icon-0.1.6-prompt.md); its opaque exterior
margin is intentional, and the discarded transparency derivative was not used.

## Start with deterministic checks

```sh
: "${PI_SESSION_TMP:?Set this to the current session temporary folder}"
export PI_BUILD_ROOT="${PI_BUILD_ROOT:-$PI_SESSION_TMP/pi-app-build-cache}"
mkdir -p "$PI_BUILD_ROOT"
git switch master
git log -1 --oneline
swift --version
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests"
swift build --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-host" \
  -c release --arch arm64 -Xswiftc -Osize
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
```

On ARM64 macOS with the intended Xcode 16.1 toolchain, start with:

```sh
: "${PI_BUILD_ROOT:?Reuse the build root from above}"
python3 scripts/build-bundle.py
xcodegen generate
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGNING_ALLOWED=NO
python3 scripts/smoke-native-bundle.py \
  "$PI_BUILD_ROOT/native-tests/Build/Products/Debug/Bello Agent.app"
```

Resolve compiler/integration failures with focused regressions; these commands are reproducible procedures, not a claim they all passed on an arbitrary checkout. No Node is involved in the build; shipped Node/node_modules/Pi SDK is not expected either. Keep fixture testing separate from the authorized release workflow. Publish after affected checks and signing/notarization pass, then verify public artifacts. Skip installation/update rehearsals under the owner policy above. Fixtures and unsigned engineering artifacts are not distributable releases.

## Mac regression matrix for subsequent changes

Use the 0.1.8 record for current focused acceptance and distribution status;
0.1.6 and earlier records retain the unchanged broader and historical evidence. Repeat affected checks for
source changes or concrete concerns.
Keep foreground-unread, physical-menu, chart-drag, IME, performance and
deployed-gateway limits explicit.

1. Typecheck all native app/helper sources, validate manifest/handshake, helpers, IPC size limits and old frontend command contracts. Exercise Darwin shell/MCP process groups and cleanup without signalling the app.
2. Through LiteLLM, test active Responses and explicit rejection of new Messages requests: custom endpoint prefix/full-leaf normalization, API key/custom headers, default effort omission, explicit effort, tools, usage, malformed SSE/JSON, cancellation and max_output_tokens handling. Historical Messages captures remain readable; new max_tokens/Messages dispatch is not an active capability. Never silently substitute another API.
3. During a slow request and tool execution, submit follow-ups and steering, remove queued entries, cancel, restart and explicitly resume. Check ordering, paused state and no duplicate mutation on acknowledgement timeout.
4. Stream large Markdown/tool output while using IME, selection, search, history, copy and native scroll anchors. Verify bounded rendering and honest context/rate/TTFT displays.
5. Enter exactly `/side` and press Enter: open an empty durable child immediately without an HTTP request. Repeat during model and tool phases; check complete-boundary context, independent sending/cancellation, inherited model/effort/capacity, saved child relationship, draft/history close-reopen and restart. Closing the pane must preserve running work, not discard it. Keep legacy keep recovery idempotent. `/fork` must create an independent journal with the same complete context, tool/reasoning/provider state and no copied pending commands or new HTTP request; verify full context after reload and unchanged parent bytes. Bring-back edits the parent draft without automatically submitting. Discussion-only must not disable its composer.
6. Test Codex explicit-only policy in `agents/openai.yaml`, slash chips, canonical-name collisions, policy revocation while queued, dependencies, unsupported metadata, source changes, symlinks and Unicode instruction byte limits. Pasted/model text never grants authorization. Disable/re-enable a skill through Bello Agent, verify changes reach loaded/future project hosts, and prove Codex/shared files remain byte-identical. Local re-enabling cannot override original skill policy or project restrictions.
7. Compare debugger body bytes/hashes to actual fixture input/output for Responses and compaction; preserve historical Messages capture reads. Verify default persistence/30-day retention, direct body display and versioned legacy-policy migration, including deliberate custom/off/session overrides and the documented indistinguishable old seven-day case. Preserve ordinary request/response headers. Longer request auth tokens may expose only a masked final-four-character suffix; fully mask short tokens, cookies, response auth and credential echoes, including configured custom auth headers. Credentials stay untouched on the wire and use labeled SHA-256 transformations if found in captured request bytes. Credential omission cannot become an empty original/export. Test new plaintext storage, legacy encrypted reads, partial/error/truncated/off states, quota, exports, shared chunks, reconstruction, GC, crash/disk-full, expiry and restart. No body-reveal gate or HTTP body full-text search.
8. Exercise MCP list, batched describe, singular invoke, serialized concurrency, read-only denial, HTTP/stdio, schema/result limits and durable unknown-outcome acknowledgement. Listing cannot invoke; human acknowledgement cannot retry or be called by the model.
9. After F14 changes, test one ordinary Keychain item, revisioned configuration writes, no plaintext/per-profile fallback, no helpers/children/logs receiving the whole vault, and locked/denied/corrupt behavior with affected focused tests. Reuse the historical signed-owner evidence; the signed owner/update rehearsal requires an explicit owner request. Record raw other-app read/write/delete behavior separately; ordinary Keychain does not establish the previous restricted access-group guarantee.
10. After F15, validate counts/percentiles on known samples, nulls, outliers, errors/cancelled/in-flight, time windows and filters. Do not average p99 across buckets. Confirm metrics remain after body retention expires and route aliases/effective-model groups are separate.
11. After F17, simulate route changes across requests, an alias echoed in model, explicit actual-model evidence, late/missing/conflicting metadata and both streaming/nonstreaming bodies. Unknown must stay unknown. Verify opaque replay across route changes is not assumed safe.
12. After F18, validate final streamed and JSON cost, null body cost with final JSON headers, provisional SSE headers, reported zero versus missing/invalid/conflicting data, request-keyed cache hit/miss and separate provider cache tokens/cache writes. Verify reasoning tokens and reported reasoning cost stay subsets of output; do not add classifier/other components to totals. Check one inline accounting owner as user input becomes an assistant response, persistent user Details links, compaction attribution, session/report deduplication, filtering, retained metrics after body purge and crash-resumable projection. Use the strict local request oracle; do not infer real gateway compatibility from it.
13. After F19, open the persistent native status panel with either mouse button, including with no main window. Usage opens first; Activity lists running model/tool/compaction work and omits unread/waiting/paused rows. Check completed reported output rates; reasoning is already included in output, and no streamed-byte estimate is displayed. A silent tool must still update its phase. In Usage, switch between last 24 hours, seven days and retained history. Check all-workspace token consumption, input/output and cost coverage, cache states and activity. Alias/model groups must include auto-router, reported models and unreported/conflict/incomplete states. Total tokens include provider cache once and require both input and output; requests, tools and compaction must not be counted again through message links. Check half-open date boundaries, pagination, schema/backfill/restart, metric expiry and cancellation of polling when the panel hides. Open Report from the menu.
14. After F20, first launch must retain setup until a chat is saved, require project trust, preserve profile identity across retries and reject duplicate completion. Test & Start must call the selected Responses model once with its fixed short prompt, no tools/history/skills/project instructions, output ≤256 and scoped credentials/capture. Discovery alone cannot verify a connection. Verify timeout/cancellation, empty/error/truncated responses, post-cleanup settings races, default capture with its privacy/retention explanation and no probe chat/journal. No extra capture-consent gate is required. Compare both bodies against independent gateway observations. Test bounded model discovery with endpoint prefixes, manual alias entry, cancellation, timeout and redirect refusal. Check the native icon and Bello Agent name while retaining bundle ID, Keychain item, history paths and update signing continuity.
15. Old journals remain intact/read-only; portable handoff is deliberate. For future releases, use the sibling apps' Developer ID flow, measure the complete signed/notarized DMG, retain `/bello-agent.html` and matching canonical/legacy appcasts, and verify public bytes/signatures. Do not perform installation or Sparkle update rehearsals unless explicitly requested again. The released `BelloAgent-0.1.6.dmg` and actual 0.1.5-to-0.1.6 update remain historical baseline evidence: all 75 installed files/links match, history and drafts are retained, and Keychain revision 0 is unchanged. One empty draft was re-encoded with JSON key order only; do not claim all state bytes were identical.
16. For the reviewed model/catalog/edit batch, validate active Responses against requested aliases, explicit effort omission and selected context/output limits through tool rounds and compaction; retain historical Messages readability and explicit dispatch rejection. Check override persistence, side inheritance, catalog revision/cancellation races, anonymous external catalogs and redirect refusal. Exercise actual model/effort menu actions, edit/cancel/restart drafts, atomic branch recovery and offline visible history. Add/remove workspace roots only when affected sessions permit it. Chart-filter tests do not establish an actual chart-drag interaction.

17. After F21, verify old-history baselines, offline journal reconciliation, durable counts across restart, foreground latest-reply visibility and explicit Mark as Read. Report/background/scrollback/hidden windows must not clear unread state; stale or pre-paint receipts must not clear newer replies. Check sidebar and Activity badges, abandoned branches, bounded quit/install flush and no probe-related unread entry.

18. For the 0.1.5 project/sidebar follow-up, show every project in a persistent expandable group, with saved archive filters and stable internal workspace IDs/paths. Rename/pin/archive/restore must preserve history, active work and focus/navigation; delayed unrelated model/path saves cannot revert these fields. Check saved children and independent forks, pinned/archived child-parent mismatches, and restored groups after restart. Session costs must update after background capture commits without focus changes, including evicted/unloaded session caches; stale queries cannot overwrite newer totals. Running rows keep the latest completed reported TPS stable; a newer completion without usage displays unavailable, and a new chat waits for usage. Remove gateway/API/model-ID/editing title badges. Copy original code and Markdown-section source through the native bridge, with stale/oversize/forged copy requests rejected. Open the context ring and verify a bounded, paged provider-built preview of authoritative instructions/messages/tools, stale-snapshot rejection and clear separation from historical captures. Actual custom-header double-click must zoom to the available screen and restore its previous frame without content overlap, preserving native traffic-light behavior. Use focused unit tests for changed updater handoff logic to preserve main/saved-child drafts, edit targets and displaced original drafts; do not perform an installation or actual update/relaunch rehearsal.

19. For the 0.1.6 follow-up, require a configured catalog to be the sole source, cache it for one hour and retain the last list plus error after failure. Verify no gateway fallback and no credentials sent to external catalogs. Requests must send `disable_fallbacks: true` unless explicitly allowed. Settings preferences-only saves must preserve untouched active and retained Messages connections; changed invalid fields stay open without partial saves. Test Connection must save first, retain a native composer in No project and submit only to its own saved chat despite selection changes; its tools stay disabled and sides/edit promotion remain unavailable. Verify fast/background and historical compaction summaries from authoritative active context without reusing old results after failure/cancellation. Confirm requested/final model columns, pointer/hover affordances, explicit idle archive deletion and open-child guards. Keep the exact selected flat icon and provenance.

## Report page

`ReportPageTests` cover filter chips/reset/custom bounds, real archive
queries, debounce and return freshness, saved-default retries and early edits,
canceled/obsolete query results, applied labels while filters are pending, and
brush/paging races. `ReportMessageNavigationTests` cover stale linked-message
loads and history navigation; `ReportNavigationTests` cover native responder, undo,
selection, drafts, hidden sends and retained native transcript identity. The report
refreshes on re-entry while preserving choices and cancels pending work when
hidden. Actual chart dragging remains outside passed CUA scope.

The gallery captures `03-report-*`, `03b-report-expanded-*`, plus compact reports
with collapsed and expanded custom-date filters, in light and dark appearance.

## Screenshot gallery

`UIScreenshotTests` renders the redesigned shell against the same synthetic
loopback gateway, verifies the selected-model onboarding ping before creating
chats, sends Responses fixture turns, opens a side and native sheets, and captures
this process's own windows in light and dark appearance.
It is opt-in and skips without its root variable.

```sh
export PI_APP_UI_SCREENSHOT_ROOT="$(mktemp -d "$PI_BUILD_ROOT/gallery.XXXXXX")"
export TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_APP_UI_SCREENSHOT_ROOT"
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  -only-testing:PiAppTests/UIScreenshotTests CODE_SIGNING_ALLOWED=NO
open "$PI_APP_UI_SCREENSHOT_ROOT/screenshots"
```

## Performance baseline

`PerformanceBaselineTests` prints `PERF …` timings for the paths that run
most (Markdown parse, the streaming parse per delta, the highlighter, turn
grouping, the terminal parser, opening a 300-row chat and a streaming
delta's layout and display). It asserts nothing about time. Debug builds
run these paths ten to twenty times slower than the shipped app, so the
release record quotes a Release build:

```sh
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/perf" \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/perf" \
  -only-testing:PiAppTests/PerformanceBaselineTests CODE_SIGNING_ALLOWED=NO
```

`PI_PERF_REPEAT=40` (also as `TEST_RUNNER_PI_PERF_REPEAT`) streams the
benchmark reply that many times, long enough to `sample` the test host.

## MCP fixture

Edit this configuration in the native MCP inspector, which saves it into the single vault. The helper accepts it over private IPC; external paths/hash approvals and inherited credential references are retired. The fixture below contains no credentials.

```json
{"servers":{"local":{"transport":"stdio","command":"/absolute/path/to/python3","args":["/absolute/path/to/pi-app/fixtures/native/mcp-server.py"],"timeoutSeconds":30}}}
```

The model-facing interface is:

```json
{"action":"list"}
{"action":"list","server":"local"}
{"action":"describe","targets":[{"server":"local","tool":"echo"}]}
{"action":"invoke","server":"local","tool":"echo","arguments":{"text":"hello"}}
```

Describe can contain multiple pairs. Invoke cannot contain a batch. HTTP/stdio fixture coverage is in `scripts/test-native-host.py`. Human-only `mcp.acknowledgeUnknown` requires deliberate confirmation and does not rerun the old operation. MCP server annotations do not override read-only tool policy.

## Report format

Historical/explicitly requested signed vault rehearsal (not part of the default
workflow; no notarization or production-vault access):

```sh
python3 scripts/test-keychain-identity.py "$PI_BUILD_ROOT"
```

Use the installed Developer ID identity, without a provisioning profile. The
script uses random synthetic items, checks owner access and authorized changed
binary continuity, records raw access behavior from other identities, and removes
only its synthetic items. Direct raw modification behavior is a documented
ordinary-Keychain limitation, not a passed app-isolation guarantee.

For every result, record commit, platform/toolchain, commands, actual pass/fail counts, reproducible steps and logs. Separate core, executable, Mac typecheck, UI, signed-Keychain, real-LiteLLM and release/size validation. Add focused regressions for fixes and update the status/parity documents. Keep source/UI acceptance distinct from signed/public artifact verification and historical installation/update evidence. Record skipped or reused checks; do not imply a rehearsal was performed. Do not mark a missing feature complete by weakening its requirement.
