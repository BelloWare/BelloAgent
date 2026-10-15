# Sub-agent display — 0.1.128

Date: 2026-10-15. Stream: `sub-display`; branch: `dev/a128-sub-display`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-sub-display`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display` (all logs and generated images below this root).

## Scope and decisions

Implements owner requests 2 and 4. The other stream owns webhooks and cost accounting; this branch changes neither. No helper, provider request, tool schema/result, permission, capture, vault or journal format change.

The format is **Sub-agent N · description**. Parent-authored input reads **Parent → Sub-agent N · task · turn T**; the child's report reads **Sub-agent N · task · turn T**. The number is separate from the existing child turn number. Navigation buttons retain short visible actions with the full numbered identity in tooltips and accessibility labels. Cards, search results, child header, Back to Parent, main native window/tab title, Inspector window/group/filter/request headers and delivery menus use the same naming function. A group without a child file can still get its number from the parent journal.

Numbers are the 1-based position of each unique accepted child start in the owning journal. Both v2 `pi-app.subagent-call.v1` and v3 `pi-app.agent-operation.v1.plan` participate. Duplicate plans, follow-ups, activity order, renamed descriptions, capture arrival order and filesystem enumeration do not allocate a number. Missing child files reserve their positions; retained branches are counted too. Copied foreign-owner plans do not acquire ownership or allocate numbers in a fork. Journal slimming preserves these records in order.

`ChatRecord.subagentNumber` is an optional, rebuildable desktop cache, not a new journal field or execution identity. Old desktop records decode without it and discovery reconstructs it. Stale metadata copies cannot erase a known cache. If a damaged/orphaned family has neither its parent acceptance history nor a previous cache, the UI retains the unnumbered “Sub-agent” label rather than inventing a start order. Existing known numbers remain visible with Parent unavailable. Model-facing descriptions, IDs and text are deliberately unchanged for parity.

Number lookup uses small cached dictionaries in `SessionDisplay`; each delivery row receives only the children it names. Discovery and the existing actor-isolated coordination scan derive numbers outside layout. There are no journal scans or transcript-size scans in a view's layout. Every newly inserted display is seeded, including side and copied transcript views. Earlier-version projections are decorated too, without changing their saved content.

## Root causes and changes

- Turn folding treated every provider-role `user` row as independent human input. Typed agent deliveries use that provider role, so their contents stayed visible beside a collapsed result. The fold now uses typed attribution and the existing agent notice identities, puts these rows inside the disclosure and excludes them from answer selection. A late report cannot replace the main agent's final answer or prevent its turn from folding.
- The fold explicitly printed a sub-agent count. Child controls, reports and notices now contribute no visible count. A turn with only hidden child work uses the neutral “Work details” disclosure. Main-agent work counts retain their existing behavior. All original rows and disclosure keys remain available when opened; normal/live/incomplete turns preserve their existing behavior.
- Every naming surface previously used the description or generic “Sub-agent”, with no family ordinal. Persisted parent acceptance order already provides a stable identity order, so no helper/journal migration is required. UI projections add the derived number without altering raw tool input/output or native provenance.
- Gallery inspection found that the old horizontal card action row clipped Stop in a narrow pane. Custom `PiKit.FlowView` rows now wrap card and delivery actions. The child header leads with its numbered identity, and its Stop control includes the number. A failing-first test also caught the side/copied-view path bypassing normal selection; display insertion now seeds all paths.

## Validation

Only generated journals, memory vaults and isolated native test hosts were used. No installed app launch, real preferences, Keychain, paid-provider call or `xctrace --launch`. No named result bundles; the test script retains only its newest automatically named bundle in the assigned build root. No helper-package tests are needed because this stream does not edit `packages/swift-host`.

Native command prefix: `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Serial membership checked with `python3 scripts/test-lanes.py list`; serial classes run separately.

| Check | Result | Log under `logs/` |
| --- | --- | --- |
| Failing-first behavioral run | Both numbering tests fail on absent numbers; collapse regression exposes typed rows and the child count | `sub-display-red-behavior.log` |
| Initial implementation selection | 73 tests passed | `sub-display-green.log` |
| Broader affected classes | 142 tests passed | `sub-display-affected.log` |
| Gallery-found regressions, failing first | 2 tests fail 3 assertions: clipped Stop, unnumbered footer, child identity after parent title | `sub-display-gallery-red.log` |
| Side/copied display regression, failing first | 1 test fails 4 missing-number assertions | `sub-display-new-display-red.log` |
| Final affected selection | 145 tests passed, including all 7 `SubagentDisplayTests` | `sub-display-affected-complete.log` |
| Mutation: remove typed-agent independent-row guard | Collapse regression fails four hidden-row assertions | `sub-display-mutation.log` |
| Mutation: remove unique-start numbering guard in discovery | Child 2 becomes 3; both persistence/reload assertions fail | `sub-display-mutation.log` |
| Serial `ConversationPaneTests` | 81 tests passed | `sub-display-pane.log` |
| Serial `SubagentPerformanceTests` | 1 test passed; streamed progress does not rebuild parent transcript/sidebar | `sub-display-performance.log` |
| Serial `SubagentNavigationTests` | 7 tests passed; numbered native window/tab title and Back to Parent responder routing | `sub-display-navigation-final.log` |
| Serial `SubagentOpeningTests` | 9 tests passed | `sub-display-opening-final.log` |
| Standalone `SubagentDisplayGalleryTests` | 1 test passed; 40 PNG captures | `sub-display-gallery-final.log` |
| One full native parallel lane, four workers | 2,461 passed, 37 skipped, 1 failed fixture assertion; 2,499 total | `sub-display-full-parallel.log`, `sub-display-full-parallel-summary.json` |
| `MetadataDurabilityTests` after exhaustive-fixture correction | 10 tests passed | `sub-display-metadata-final.log` |

Both mutated production files were restored in a `finally` block. Initial fixture compilation (ambiguous `Data.split`) and one Inspector setter access compilation error were corrected; their logs remain `sub-display-red.log` and `sub-display-green-initial.log`. The first red fixture also compared the wrong journal after reloading sorted chat metadata; it now retains the parent path and verifies both journals byte-for-byte. These setup failures are separate from the behavioral failures above.

The affected selection covers `SubagentDisplayTests`, `TranscriptTurnFoldTests`, `SubagentDiscoveryTests`, `SubagentSteeringPresentationTests`, `SubagentTranscriptTests`, `SubagentMetadataTests`, `SubagentInspectorTests`, `SubagentSteeringInspectorTests`, `SubagentSteeringWorkspaceTests`, `ChatRecordMergeTests`, `SessionReferenceTests`, `SidebarFlatTopicsTests`, `SidebarSearchSidebarTests`, `SidebarAppearanceTests` and `InspectorWindowControlTests`.

Tests cover unique v2/v3 start order, duplicate starts, a missing first child, filtered lookup, metadata loss/rebuild, stale metadata merges, renaming, mixed-author/mixed-child delivery batches, report cards, earlier versions, side/copied display creation, exact raw tool/provenance preservation, unchanged journal bytes, folding/expansion, final-report ordering, tool controls and neutral child-only fold labels. Native labels/tooltips and narrow action geometry at 320, 376 and 656 points are asserted too.

## Gallery and final lane

Final gallery directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-final/`.
`manifest.txt` lists all 40 PNGs. Seven `*-contact.jpg` sheets cover every image and were visually inspected after the fixes. The first gallery remains in `gallery/` as the evidence that found the narrow clipping.

The scenes are finished collapsed/expanded, numbered live card, two child reports in one typed message, parent steering in the child, the child's report card, and the family Inspector. Transcript scenes cover light/dark at 1240×800, 920×600 and 640×600 (376-point transcript pane); Inspector scenes cover both themes at wide and 920×600. The collapsed scenes show only the main agent's answer below the neutral/main-work disclosure. Expanded scenes restore child cards and reports. The narrow action rows wrap without clipping; child headers, Stop, source links and Inspector groups retain their numbers. Some narrow captures are scrolled to the lower part of a long card; the full-width captures show its heading. The gallery uses a generic fixture window title; the numbered native window title is covered separately by `SubagentNavigationTests`.

Reproduction:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display \
PI_APP_SUB_DISPLAY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-final \
TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-final \
scripts/test-macos.sh -only-testing:PiAppTests/SubagentDisplayGalleryTests
```

One full native parallel lane ran with four workers and the skip arguments from `python3 scripts/test-lanes.py parallel`. Its log is `logs/sub-display-full-parallel.log`; the exact class exclusions are `logs/sub-display-parallel-arguments.txt`. `xcresulttool get test-results summary` recorded **2,461 passed, 37 skipped, 1 failed**, 2,499 total, in 588.4 seconds. The JSON summary is retained in `logs/sub-display-full-parallel-summary.json` before the script's automatic result-bundle pruning.

The only failure was `MetadataDurabilityTests.testChatRecordRoundTripsEveryFieldUnchanged`: its reflection guard reported **“fixture leaves subagentNumber nil”** because the exhaustive fixture had not supplied the new optional field. The fixture now supplies `2`, and the sparse legacy decode explicitly asserts nil. This is a test-fixture correction; production code did not change after the full lane. The complete class then passed **10/10** alone (`logs/sub-display-metadata-final.log`). The full lane is not repeated, per the one-run instruction, and its failed status is retained here rather than represented as a green gate.

## Handoff

The lead performs the separate branch review, integrates the two streams and owns release validation/publication. This worktree does not merge or push `dev/next`. No interactive VoiceOver session is claimed; native accessibility labels and keyboard routing are checked programmatically. Corrupt families without any persisted ordering evidence cannot be given a truthful start-order number; the explicit fallback above remains.

Shared-file edits are small and additive: `ConversationPaneParts.swift` changes only the child Stop label/cache; `WorkspaceModel.swift` seeds numbers when display identities are inserted; `SessionDisplay.swift` adds the presentation map; `MetadataStore.swift` adds its optional cache; `InspectorFamily.swift` adds its numbered title. No cost totals, usage math, notification eligibility or webhook tracking changed. The lead should retain both streams' changes in these areas and regenerate the Xcode project after integration.


## Owner display follow-up

The subsequent 2026-10-15 owner request is part of this same branch. It keeps the
numbering and compact-turn changes above and replaces child sidebar groups with
the main-column Agents picker and read-only side tabs. This section records the
follow-up separately from the earlier committed validation/full lane.

### Changes and decisions

- Topics/Flat, pinned and archived presentation and topic counts omit children;
  existing child unread/draft exclusions remain. Search alone lists matching children
  as **#N · description — in parent title**, including number queries and a matching
  topic title. The parent's small Pi badge counts queued/running/stopping children
  and disappears at zero.
- The main chat reserves a row above its transcript for **Agents N** and the active
  count/spinner. It stays at that column's trailing edge when a child/file/Git pane
  is open. Embedded child tabs suppress a duplicate pill. Full child windows show
  the family and mark the current child.
- A cached family projection orders members by the existing durable number. The
  Pi popover shows lifecycle status, model and **reported** spend from the existing
  per-child progress summary when available. This is not new accounting or a cost
  total; no cost/usage/webhook implementation is changed. Full labels still use
  **Sub-agent N · description**; compact picker/search labels use **#N · description**.
  Model-facing names, results and journal bytes remain unchanged.
- Open uses the existing tab host's global kind/key identity, persistence and
  pop-out/move-back behavior. Direct selection, cards, search, Inspector and source
  links now open a child tab beside its parent. Back in the embedded reader only
  focuses the parent; explicit source links retain message/version navigation.
  Stop All uses a custom Pi confirmation and revalidates the original children
  before issuing the existing authorized Stop requests. No child composer is added.

### Root causes found

The former sidebar family expansion and normal selection route made children ordinary
sidebar rows/main-pane destinations. Tab restoration happens before chat metadata,
so a child reader must defer loading until its record arrives. Two history/snapshot
visibility guards only recognized main/ordinary-side panes; without extending them,
a hosted child would remain preparing or receive status instead of streamed rows.
Topic headers also counted hidden children even after row filtering. These are now
covered by behavioral, generated-loopback and gallery checks.

A full test-module rebuild exposed an existing Swift 6 Sendable capture in
`SidebarInteractionTests`: the event-tracking fixture captured a native surface
outside its existing `Unchecked` holder. The fixture now carries that surface in
the same holder as its document and row; no production drag behavior changed.

### Follow-up validation

All commands use the assigned build root, generated fixtures/memory vaults and
synthetic loopback only. Logs named `panel-*.log` are directly under the build root;
the earlier validation's `sub-display-*.log` files remain under `logs/`. No helper
package source changed, so helper-package tests are not required.

- Failing first: `panel-red.log`, 1 test/6 assertions fail on child rows, old group
  disclosure and keyboard row order in Topics and Flat.
- Real guard mutation: `panel-mutation.log`, removing the production empty-query
  child exclusion causes 1 test/4 assertions to fail. The source was restored in
  `finally`; the final affected run verifies the real guard.
- Initial affected run: `panel-affected.log`, 48 tests pass.
- Initial gallery: `panel-gallery-final2.log`, 1 test passes and 28 captures. Native
  image inspection confirmed main-column anchoring and pop-out highlighting and
  prompted the topic-count fix. A prior opt-in invocation skipped, and the first
  image collector used the wrong CoreGraphics array representation; the collector
  now combines only separately captured fixture-owned windows. Neither was a
  product failure.
- The initial loopback selection run found an obsolete Back assertion expecting an
  issuing-version jump. Embedded Back now explicitly preserves the main page per
  the owner's instruction; Inspector/source-link assertions retain their old behavior.

| Final check | Result | Log |
| --- | --- | --- |
| Affected classes, including launch restore | 177 passed | `panel-affected-verified.log` |
| `SubagentNavigationTests` alone | 7 passed | `panel-navigation.log` |
| `SubagentOpeningTests` alone, loopback | 9 passed | `panel-opening-final.log` |
| `SidebarInteractionTests` alone | 9 passed | `panel-sidebar-interaction.log` |
| `SubagentPerformanceTests` alone | 1 passed | `panel-performance.log` |
| `ConversationPaneTests` alone | 81 passed | `panel-conversation.log` |
| `SubagentPanelGalleryTests` alone | 1 passed, 28 captures | `panel-gallery-verified.log` |
| `SubagentDisplayGalleryTests` alone | 1 passed, 40 captures | `panel-collapse-gallery.log` |
| One full native parallel lane, four workers | 2,468 passed, 2 failed, 37 skipped | `panel-full-parallel.log` |
| Badge fix: lazy-list, panel, appearance, row states | 18 passed | `panel-badge-final.log` |
| Refreshed panel gallery after badge fix, alone | 1 passed, 28 captures | `panel-gallery-post-gate.log` |

The 177-test final selection is `LaunchSelectionTests` (20), `SidebarAppearanceTests`
(6), `SidebarFlatTopicsTests` (30), `SidebarSearchSidebarTests` (9), `SubagentDisplayTests`
(7), `SubagentOrganizationTests` (13), `SubagentPanelTests` (8),
`SubagentSteeringWorkspaceTests` (4), `TabHostTests` (16), `TranscriptTurnFoldTests`
(24), `WorkspaceDisplayMemoryTests` (2), `WorkspaceLoadingTests` (12), and
`WorkspaceRefreshLifecycleTests` (26). Serial behavioral classes add 107 passing
tests; the two gallery tests are separate.

Additional failing-first checks (`panel-scope-restore-red.log`): 2 tests/3 assertions
caught a cross-project family borrowed through corrupt link metadata and a legacy
child selection that lost its restored Usage Report page. The family cache now
retains the old workspace boundary; legacy selections recognize the child side tab
when restoring the report. Both pass in the final affected selection. The earlier
155-test selection (`panel-affected-final.log`) also exposed two fixture mismatches:
a stale sidebar title expectation and missing required history-page boundary fields.
Both fixtures are corrected, without relaxing their behavioral assertions.

Full-lane arguments are saved in `panel-parallel-arguments.txt`; its JSON result
summary is `panel-full-parallel-summary.json`. This is the one full lane for the
owner's follow-up, separate from the earlier committed numbering/collapse lane.
It ran for 667.9 seconds. Failure details were exported before the next test run
pruned the automatic result bundle (`panel-full-sidebar-failure.json` and
`panel-full-wire-failure.json`). The sidebar test found ten unnecessary inactive
badge spinner views in addition to the one active chat spinner. The wire test's
accounting assertions passed, but OCR did not find the expected throughput label.
Targeted follow-up results are recorded below; the full lane is not repeated.

The unchanged `WireContractTests` class passed 10 tests with one opt-in benchmark
skipped in `panel-full-failures-isolated.log` (a sequential two-class selection with
`LazyListAppKitControlTests`). The OCR failure's cause remains unconfirmed; no
accounting, timing, footer or wire-test code changed. The sidebar failure reproduced
in that selection. `AgentRunningBadge` now creates a spinner only above zero and
removes it when the active count reaches zero, preserving the sidebar's existing
no-idle-spinner contract. After that fix, all 18 checks passed:
`LazyListAppKitControlTests` (3), `SubagentPanelTests` (8), `SidebarAppearanceTests`
(6) and `SidebarRowStatesTogetherTests` (1). The standalone panel gallery passed
again and its 28 captures were refreshed. The badge lifetime fix is the only
production change after the full lane; the full lane's failed status remains above.

Gallery directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-panel-final/`.
The 28-image manifest names closed/open running/done headers, main + child side tabs, and
popped-out child windows with sibling highlighting. Main-window scenes cover
light/dark at 920×600 and 1240×800; pop-outs use the tab host’s default 820×640
content size. Captures contain only fixture-owned native windows. Native accessibility
labels, Tab focus, read-only controls, tab reuse, geometry, and the custom Stop All
confirmation are asserted. An interactive VoiceOver session is not claimed.

The 40 refreshed collapse, numbered-card, typed-message and Inspector captures are
in `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-display-followup/`.
All 68 images were visually inspected, using the 11 `*-contact.jpg` sheets plus full
narrow/popup captures. Normal topic counts now show only main chats, narrow Stop
controls remain visible, and collapsed finished turns retain only the main answer.

To reproduce either gallery, pass its environment knob through xcodebuild:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display \
TEST_RUNNER_PI_APP_SUB_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-panel-final \
scripts/test-macos.sh -only-testing:PiAppTests/SubagentPanelGalleryTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display \
TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-display-followup \
scripts/test-macos.sh -only-testing:PiAppTests/SubagentDisplayGalleryTests
```

The lead still owns independent review and integration with sub-cost. Shared edits
are limited to tab configuration/cache fields in `WorkspaceModel`, visible-reader
guards in `WorkspaceHistory`/`WorkspaceRefresh`, navigation and conversation layout;
retain the other stream's independent cost fields. No merge or push of `dev/next`.


## Lead review round 1 and shared Sides picker

Date: 2026-10-15. This section supersedes the Agents-only navigation described
above. The original numbering and collapsed-turn work remains in place. This
round implements every A/B review finding and the owner's later Sides addition.

### Root causes and fixes

- A ready child display was treated as current even after hidden status-only
  updates and helper expiry. Every reopen now uses the existing saved-history
  revision/reload path; no provider run is started to read a completed child.
- Async child load completion made a second focus decision. Opening now records
  the focus intent immediately; completion never refocuses. Back to Parent wins,
  and hiding a child clears its stale focused-session identity. Deferred attachment
  focus checks that the same child is still visible and intended.
- Visibility tested the raw `sideShown` bit, unlike the host. It now uses
  `shownTab(sideAvailable:)`, including the no-side fallback and page visibility.
- Popped-out readers bypassed the main-window conversation command validator.
  The hosted tab routes Find, Next/Previous, Inspector Find and Stop to its child,
  with window, responder, sheet and popup guards. Back retains its existing guard.
- Child open/close bypassed normal selection's eight-display eviction. Reader
  lifecycle now applies that same policy after closing; running sessions, open
  tabs, sides and pending drafts keep their existing protections.
- Every child observer could overwrite its pop-out window title. Only the active
  tab sets it. Compact tab labels use `#N · description` and truncate at the tail;
  native titles, tooltips and VoiceOver keep `Sub-agent N · description`.
- NSPopover constrained to the display rather than its owning window. The new
  picker opts into a trailing-aligned, window-constrained frame and height, with
  scrolling for longer lists. The main column reserves its own header row.
- The previous generic pill face and row badge each added another activity
  indicator, while the active count called queued work running. The pill swaps
  its quiet symbol for one spinner; the sidebar uses its existing leading spinner
  plus a passive count. Running, queued and stopping agent counts stay separate.
  The incidental canonical/arrival-order caption is removed; actual missing-event
  coverage warnings remain.
- The owner's Sides addition replaces both navigation lists with one cached
  conversation-family projection. Normal Topics/Flat, pinned, archived and keyboard
  row lists omit sides and managed children. Search still finds saved family
  members, labelled with their parent, and opens the existing side/tab path.
  Orphaned or cross-project sides remain findable as main chats.
- An activity-only update could unhide an embedded child header despite the
  main-column-only rule. The header now retains its placement permission across
  its own activity observer. A new draft's fixed header minimum also overflowed
  a 310-point side pane in the gallery; narrow draft headers now put actions below
  the labels, with a compact Draft badge and full accessibility text.

The pill reads `2 sides · 3 agents`, with absent parts omitted. Its Sides section
shows title, working/new reply/failed/saved/draft status, existing reported spend,
Open and New Side; the ordered Sub-agents section retains model/status/spend,
Open, running-only Stop, confirmed Stop All and Inspect Family. Side and agent
activity is spelled out in tooltips and VoiceOver. The passive parent badge shows
working work, or queued work when none is working. Tab/arrow navigation is retained.

The former hover/edge SidesPanel, pinned column, pin preference, panel menus,
tests, gallery helper and design document are removed. Old saved selections with
the obsolete JSON pin key remain readable. New Side reuses the unsent draft;
existing unkept-side ephemerality and kept-side restore paths are unchanged.
Per-side and per-child spend comes only from existing reported usage. Model-facing
text, tool behavior, permission/capture/vault boundaries, journal format and cost
accounting are unchanged; accounting remains the sub-cost stream's responsibility.

### Behavioral evidence

All paths below are relative to the assigned build root. Generated fixtures,
memory vaults and the isolated native host/loopback helper only; no installed app,
real preferences, Keychain, paid-provider requests or named result bundles.
No Swift helper source changed, so package tests were not required.

| Failing-first check | Evidence |
| --- | --- |
| Six reader review findings | `review-reader-red2.log`: 7 tests, 13 failing assertions |
| Switching tabs during load, without a fixture-injected parent focus | `review-reader-focus-red2.log`: 1 failing assertion |
| Shared Sides/Agents projection and sidebar omission | `review-family-red.log`: 4 tests, 16 failing assertions |
| Native popup owning-window bounds | `review-popover-red.log`: 1 gallery test, 8 failing assertions |
| Embedded reader's second pill after activity | `review-family-visibility-red2.log`: 1 failing assertion |
| Pending side header at 310/186 points | `review-side-width-red.log`: 3 failing assertions |
| Mutation of the real empty-query side exclusion in `SidebarGroups.swift` | `review-mutation-sidebar.log`: 4 failing Topics/Flat row/keyboard-order assertions; production guard restored |

Earlier affected runs also exposed obsolete tests that expected ordinary sides in
sidebar/adjacent navigation. Those expectations now exercise the requested picker
or search path. The search-click fixture waits for navigation before clearing the
filter: retiring the binding first correctly rejects its queued click. No production
binding guard was weakened. An early reader command fixture required key-window
state despite using the tab host's event/responder routing; the final code and test
use the same guarded host path as other hosted tabs.

The latest affected-class selections total **343 passing tests across 29 classes**,
without counting repeat runs. `review-affected-class-results.json` records each
class's final selected result and exact log. This includes 204 tests in parallel-lane
classes and the following standalone serial checks:

| Standalone class | Passed | Log |
| --- | ---: | --- |
| SubagentReaderTests | 7 | `review-serial-SubagentReaderTests.log` |
| SubagentNavigationTests | 7 | `review-serial-SubagentNavigationTests.log` |
| SubagentOpeningTests | 9 | `review-serial-SubagentOpeningTests.log` |
| SidebarNativeBindingTests | 4 | `review-serial-SidebarNativeBindingTests.log` |
| WorkspaceRootTests | 7 | `review-serial-WorkspaceRootTests.log` |
| ShellParityTests | 15 | `review-serial-ShellParityTests.log` |
| ConversationPaneTests | 81 | `review-final-ConversationPaneTests.log` |
| GitPanelNarrowParityTests | 8 | `review-final-GitPanelNarrowParityTests.log` |
| SubagentPerformanceTests | 1 | `review-performance.log` |

The performance fixture used 400 settled transcript rows and 20 progress updates:
p50 63.878 ms, maximum 109.502 ms, 52 measured rows, 16 Markdown updates and **zero
sidebar-index recomputations**; the switch round trip was 1284.05 ms. These are
one Debug sample on a shared machine, not a release latency claim. Membership and
activity projections do not scan transcripts. Focus/defaults/timing classes were
run separately for their final checks; an earlier sequential 95-test selection
included ConversationPaneTests, then its final 81-test run was repeated alone.

### Final gallery

Both standalone gallery tests pass, producing **100 captures**, all visually
inspected via nine contact sheets plus full-size narrow/popup/draft images:

- `gallery-review-verified/`: 60 picker scenes, with running/queued/done states,
  closed/open/scrolled footer, child tab, saved side, pop-out siblings, long tab
  labels, agents-only, new draft and sides-only. Light/dark at 920×600 and 1240×800;
  pop-outs use the host's default 820×640 content size. Log:
  `review-final-SubagentPanelGalleryTests.log`.
- `gallery-display-review/`: 40 collapsed/expanded turns, numbered cards, typed
  parent/child messages, reports and family Inspector scenes, light/dark at
  920×600, 1240×800 and narrow 640×600. Log: `review-gallery-display.log`.

Each folder contains `manifest.txt` and `review-contact-*.png`. Capture is limited
to fixture-owned windows. Assertions cover popup bounds on all four sides, the
main-column/divider boundary, one spinner per location, compact tail truncation,
keyboard first focus, numbered accessibility labels, read-only child composer,
tab reuse, embedded Back, side/draft placement and custom Stop All confirmation.
Interactive VoiceOver operation is not claimed; native labels/actions are tested.

Reproduce the picker gallery with:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display \
TEST_RUNNER_PI_APP_SUB_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-review-verified \
scripts/test-macos.sh -only-testing:PiAppTests/SubagentPanelGalleryTests
```

Use `TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY` and `SubagentDisplayGalleryTests` for
the transcript/Inspector captures. The old `gallery-review-final` is an intermediate
capture; `gallery-review-verified` includes the fixed narrow draft header.

### One full native parallel lane

The final lane uses four workers and `scripts/test-lanes.py parallel` exclusions;
arguments are saved in `review-parallel-arguments.json`, console output in
`review-full-parallel.log`. **Passed: 2,468 tests, zero failures, 37 skips**, in
587.1 seconds. `review-full-parallel-summary.json` is the exported native result;
`review-full-parallel-status.txt` records exit status 0. This was the one full lane
for review round 1, after the final source and gallery changes; no source changes
or test reruns followed it.

The lead still owns independent branch review and integration with sub-cost.
Shared edits are small/additive in WorkspaceModel (family caches/invalidation),
conversation layout and tab navigation; keep the other stream's independent cost
fields. No merge or push of `dev/next`; only `dev/a128-sub-display` is published.


## Lead review round 2: reader lifecycle and compact picker

Branch `dev/a128-sub-display`, based on `6593ba9451d30bf86bfb1a4619a432b535b0fbb2`.
All artifacts below are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`.
Only generated journals, in-memory vaults, the loopback gateway and the isolated
native test host were used. No installed-app launch, real preferences, Keychain,
paid provider, helper/tool semantics or journal format changes.

### Findings, ownership and lifecycle audit

- A saved side's ordinary parent relationship had replaced its delegation owner.
  `conversationFamily(side)` now retains that side's agents. The main picker adds
  labelled side-owned delegation groups, each with its own Inspector target and
  Stop authority. Opening their readers keeps the main column; Back shows the
  actual owning side. Sidebar activity includes these groups without reassigning
  the agent numbers or changing accounting ownership.
- Child attachment checked the main selection revision after its header read.
  Loads now validate the exact tab, display and presentation generation, alongside
  the existing origin/path/workspace/helper-connection checks. Main selection,
  visibility and pane/window placement are separate from the load's lifetime.
- Presentation restart canceled page tasks without clearing their loading flags.
  Main, side and child readers share a cursor-preserving boundary reset and owned
  task cleanup. Unchanged journals remain reusable; canceled side reads reopen.
  Closed readers cannot revive themselves or adopt a page into a new reader.
- Side-opening completions selected the pane too late, and hide callbacks observed
  the previous host state. Pane choices now occur at the request; later choices
  invalidate pending openings. Host callbacks use actual side availability and
  run after the state transition, retaining the no-side fallback.
- Native focus could return to a visible child's reply without updating command
  focus. Both workspace and tab windows reconcile responder changes through the
  containing conversation pane. This walks ancestors only, never transcript rows.
  Deferred attachment checks current focus intent before restoring a responder.
- The audit additionally reproduced a deferred New Side selection overriding a
  newer file tab, a canceled side remaining dormant on reopen, and delayed card
  header validation reopening a child over a newer tab choice. Their regressions
  fail before the fixes. Popped-out reader command availability is also independent
  of the main window's Reports page; sheets and native responder checks still apply.

The audit covers initial open, ready/hidden reopen, unchanged-journal paging,
active-Side selection, no-side fallback, main selection during attachment, newer
file/child choices during awaits, close/reopen during a read, eviction, pop-out and
move back during a read, native responder transitions, Back, saved-side restoration
and child-tab restoration. Pending side drafts retain their existing memory-only
path and persistence tests.

### Picker design and decisions

Rows are custom Pi buttons with a title and one secondary line, opened by click
or Return, with arrow navigation and separate accessible trailing Stop buttons.
New Side uses the same title inset. Keyboard selection survives status updates by
identity. Six side/agent rows plus New Side and the footer fit at 1240×800.

Spend uses existing `CostLimit.dollars` / `MetricFormat.centsUSD`: two decimal
places at a cent or above, meaningful sub-cent digits (up to six) and a less-than
label below that precision. The usage caveat is in the tooltip rather than a
repeated “Reported” prefix. Only existing per-session usage is read. Cost/footer/
Inspector accounting code remains owned by sub-cost.

Numbering stays `Sub-agent N · description` for full identities and `#N · description`
for compact rows/tabs. Side-owned groups name their own parent so identical numbers
in different delegation families remain distinguishable. No model-facing text,
permission, tool, capture, vault or data boundary changed.

### Failing-first and mutation evidence

- `review2-red-reader-corrected.log`: four reported reader regressions fail (paging
  flags, stale side completion, hidden-child focus and responder focus). The first
  draft of the journal fixture needed its generated directory created; the corrected
  run has no unexpected failures.
- `review2-red-family.log`: side-owned membership and compact/money assertions fail.
- `review2-red-opening-corrected.log`: a real loopback child fails attachment after
  an unrelated main selection. The fixture holds the history actor only after its
  parent is selected. The final assertion distinguishes an unfinished `.loading`
  read from `.preparing`, which already has its page and awaits the viewport.
- `review2-audit-red-reader.log`: the deferred New Side and canceled-side reopen
  regressions fail; the other lifecycle checks pass.
- `review2-audit-red-opening.log`: delayed card validation overrides the newer tab.
- `review2-mutation-opening.log`: weakening the real pane-intent equality guard to
  `>=` makes the card-opening regression fail all three stale-navigation assertions.
  The original guard was restored; the full opening class then passes.
- The additional report-page command check is isolated from global app activation:
  an earlier native-key precondition did not become true in this shared test host.
  The final check tests reader command scope, while existing responder/sheet and
  native keyboard tests verify delivery. Those exploratory key-window failures are
  retained separately and are not counted as product-regression evidence.

### Validation and galleries

The final affected selections pass **358 tests across 26 classes**, with no skips
or failures, excluding repeat runs. `review2-affected-class-results.json` records
each class's count and final log. The 17-class parallel selection passes 202 tests;
standalone serial classes pass 156:

| Standalone serial class | Passed |
| --- | ---: |
| SubagentOpeningTests | 11 |
| SubagentReaderTests | 19 |
| SubagentNavigationTests | 7 |
| ConversationPaneTests | 81 |
| WindowPresentationTests | 9 |
| WindowLifecycleTests | 3 |
| WorkspaceRootTests | 7 |
| ShellParityTests | 15 |
| SidebarNativeBindingTests | 4 |

Reader and navigation final logs are `review2-final-<Class>.log`; other serial logs
are `review2-serial-<Class>.log`. The affected parallel log and exact arguments are
`review2-affected-parallel.log` and `review2-affected-arguments.json`.
ConversationFamilyTests was rerun alone after extending sub-cent/side-owner checks;
its 13 passing tests are counted once. A legacy WorkspaceRootTests selector for the
removed Open button was updated to the clickable Pi row; its final class passes.

`review2-audit-red-reader-command-scope.log` records the report-page scope regression;
`review2-final-SubagentReaderTests.log` verifies the fix, including actual popped-out
Find/Next/Previous/Stop commands on Reports, sheet rejection and embedded-reader
rejection. No product code changed after the final reader/navigation selections.

The standalone galleries produce **108 captures**, inspected in ten contact sheets
and full-size picker images:

- `gallery-review2-final/`: 68 captures in light/dark at 920×600 and 1240×800,
  including compact rows, keyboard focus, closed/open/running/done pickers,
  embedded/pop-out children, ordinary sides, new drafts, long titles and side-owned
  delegation groups/readers. Native assertions check six visible rows at 1240×800,
  all popup bounds, main-column placement and keyboard/accessibility actions.
- `gallery-display-review2/`: 40 captures of collapsed/expanded turns, numbered
  cards, typed parent/child messages, reports and family Inspector, including narrow
  640×600 panes. Existing collapsed-turn and numbering behavior remains intact.

Each folder has `manifest.txt` and `review2-contact-*.jpg`. Logs are
`review2-serial-SubagentPanelGalleryTests.log` and
`review2-serial-SubagentDisplayGalleryTests.log`. Galleries use the same conversation
window subclass as production. The subsequent command-availability change affects
Reports-page keyboard routing only, with no gallery appearance change.
Interactive VoiceOver operation is not claimed; native labels, roles/actions and
keyboard routing are covered. Swift helper packages were not changed.

### One full native parallel lane and isolated follow-up

The one full native parallel lane for review round 2 used four workers and
`scripts/test-lanes.py parallel` exclusions. It finished with **2,469 passed,
one failed, 37 skipped**, exit status 65, in 553.1 seconds including setup.
Exact arguments, console output, native summary and status are saved as
`review2-parallel-arguments.json`, `review2-full-parallel.log`,
`review2-full-parallel-summary.json` and `review2-full-parallel-status.txt`.

`AppShellPerformanceTests.testMemoryAfterVisitingFiftyChatsAndAnHourOfStreaming`
failed because `chat-12` was still retained after the fifty-chat visit. The total
retained-page limit passed; the stricter intermediate-chat release assertion did
not. Its native detail and activity exports are
`review2-full-memory-test-details.json` and `review2-full-memory-activities.json`.
The cause remains unconfirmed; this run is not reported as a passing full lane.

The entire unchanged `AppShellPerformanceTests` class then passed **11/11** alone,
with no skips, in 14.7 test seconds (19.9 seconds including setup). Its memory
check retained exactly eight pages for eight displays, with no retained accounting
rows and zero settlement milliseconds. The log, status and native summary are
`review2-isolated-AppShellPerformanceTests.log`,
`review2-isolated-AppShellPerformanceTests-status.txt` and
`review2-isolated-AppShellPerformanceTests-summary.json`. No assertion or timing
limit was changed, and the full lane was not repeated. These eleven follow-up
tests are separate from the 358 affected tests above. No product code changed
after either final affected validation or the full lane.

The lead retains independent review and integration with sub-cost, plus follow-up
on the unconfirmed parallel retention failure. Only `dev/a128-sub-display` is
published; `dev/next` is not merged or pushed. No cost accounting, webhook, helper,
tool-result text, journal format or side-draft persistence contract changed.

## Lead review round 3: focused commands and Markdown

Baseline: `6b52565564adc6fec1827604f90aab14eb6e4756` on
`dev/a128-sub-display`. This round addresses all three independent review findings,
the owner's rich-text addition, and the two picker gallery notes. All artifacts
below are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/`.

### Root causes and changes

- Delete Chat still used the main selection after child navigation moved to hosted
  readers. The command now resolves the focused conversation, and both menu
  validation and invocation reject a managed child. Explicit parent focus retains
  its ordinary confirmation. The regression cancels confirmations in its generated
  fixture and asserts that child focus never even prepares the parent's deletion.
- Picker refresh replaced its stack without notifying the enclosing native document.
  It now propagates `PiKit.sizeChanged`, so added/removed family rows change document
  height and the popover's preferred size without reopening it.
- Embedded children have no header anchor of their own. Their family menu now
  addresses the visible main-column picker; it is disabled when that main chat has
  no family. Popped-out children continue to address their actual delegation family.
- Task/Result cards and typed deliveries previously used plain monospaced text.
  `TranscriptAgentMarkdown` now uses the same `TranscriptMarkdown` cache,
  `NativeMarkdownContainer`, native text builder, syntax highlighter and link policy
  as assistant replies. This includes parent-authored delegated tasks, child results,
  and note/blocker/question reports. No model-facing text or journal bytes change.
- Long prose uses a 168-point preview, Show more/less, and original-source Copy.
  Full selection copies the original Markdown; selected runs map back to their
  source spelling, including inline emphasis/code/links and repeated words.
  Truncation/error notices are separate from copied content. Native selection,
  rendered Find and existing reply file-link actions are retained. Images remain
  inert notes, unsafe links remain non-actions, and HTML is not interpreted.
- A source of at least 16 KiB parses off the main thread into immutable cached
  blocks. Initial native text is bounded to 1,200 characters; expansion adds bounded
  batches with a main-loop yield between them. Source/environment generations and
  cancellation reject superseded preparation and expansion. Settled measurements
  are reused; no transcript-wide work is introduced in layout.
- Two implementation checks exposed additional issues before completion: downward
  stack invalidation recursively invalidated Markdown, and Find could finish between
  text adoption and the row's height validation. The first now invalidates upward
  only; the second waits for native height validation before choosing/scrolling to
  its target. The final tests verify both the on-screen match and this real guard.
- Picker section labels use the small uppercase Pi style. New Side has an accent
  plus icon and ordinary Pi hover/pressed feedback. A common title inset aligns it
  with side/agent rows; current entries use the same leading gutter for a checkmark.

### Failing-first and mutation evidence

| Check | Observed result | Artifact |
| --- | --- | --- |
| Focused Delete and available family anchor, before fixes | 21 reader tests; four assertion failures in the two new regressions | `review3-red-SubagentReaderTests.log` |
| Open picker document resizing, before fix | 14 family tests; five failed assertions | `review3-red-ConversationFamilyTests.log` |
| Markdown renderer, preview, Copy and untrusted parity, before implementation | Four tests; 13 failed assertions | `review3-red-SubagentMarkdownTests.log` |
| Unbounded native Markdown adoption | 95.65 ms main-loop gap; 55.69 ms native update plus 31.50 ms layout | `review3-second-SubagentPerformanceTests.log` |
| Mutation: resolve Delete through selected main chat | Two assertions fail: menu incorrectly enabled and parent confirmation prepared | `review3-mutation-delete.log`, `.status` |
| Mutation: remove pending-height guard from Markdown Find | Both visible-match and pending-target assertions fail | `review3-mutation-find.log`, `.status` |
| Restored Markdown class, five iterations | 50 passed, zero failures | `review3-final-SubagentMarkdownTests.log` |

Both real production mutations were restored in `finally` blocks. The first
performance iteration also exposed an invalidation recursion in a typed message;
its stack evidence is `review3-perf-crash.ips`. The upward-only notification fix
passed the existing 400-message/progress-card test. The Find race was caught again
by the affected-suite run before adding its deterministic pending-height assertion;
removing the final guard reproduces both failures above.

The original 50 ms whole-window heartbeat threshold also counted the fixture's
AppKit/window work: even bounded Markdown recorded 54–64 ms gaps while its native
update/layout took only 7–10 ms. The final check separately enforces a 50 ms native
Markdown batch/draw budget and a 100 ms whole-window responsiveness budget. These
are generated Debug-fixture measurements, not a claim about every machine or
arbitrary result size. The 50 KB case expands the complete result, compares it to
an assistant's rendering, verifies 30 unchanged layouts reuse geometry, and checks
that the 400 settled messages and sidebar are not rebuilt.

### Gallery

The standalone fixture classes use only generated conversations, memory credentials
and their own native windows; no helper/provider calls or desktop-wide captures.
The refreshed sets are:

- `gallery-review3-markdown/`: 28 PNGs, card Task/Result, report, delegated-task header,
  folded/expanded and code/table detail views, light/dark at 1240×800 and 920×600.
- `gallery-review3-panel/`: 68 PNGs, running/done, main pill closed/open, six compact
  rows, side/child tabs, side-owned families, popped-out readers, narrow panes and
  New Side. Popup bounds, six-row visibility, numbering and keyboard access are
  asserted in the gallery class.
- `gallery-review3-display/`: 40 PNGs, finished collapsed/expanded turns, numbered
  cards, typed parent/child messages, reports and family Inspector, including a
  376-point transcript pane.

Each directory has `manifest.txt`; `review3-contact-*.jpg` sheets cover every PNG.
The fixture captures rich folded results after scrolling their controls into view,
so 920×600 shows the preview and Show more. Additional detail captures show the full
code/table section. Native labels/actions and keyboard routing are checked; an
interactive VoiceOver session is not claimed.

Reproduce a gallery with its class alone (substitute the corresponding environment
variable and class for the other sets):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display \
TEST_RUNNER_PI_APP_SUB_MARKDOWN_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-review3-markdown \
scripts/test-macos.sh -only-testing:PiAppTests/SubagentMarkdownGalleryTests
```

### Final native validation

Serial classes run alone. The affected parallel selection covers
`ConversationFamilyTests`, `SubagentDeletionTests`, `SubagentDisplayTests`,
`SubagentPanelTests`, `SubagentSteeringPresentationTests`, `SubagentTranscriptTests`,
`MarkdownTextSurfaceTests`, `NativeMarkdownSizingTests`, `TranscriptFindTests`,
`TranscriptTurnFoldTests` and `CompactTurnReportTests`.

One existing geometry assertion needed a fixture correction: it checked a Copy
button inside an entirely hidden, empty Result container. It now checks
`isHiddenOrHasHiddenAncestor`, retaining all geometry assertions for visible
controls at 320, 376 and 656 points. The preceding failed selection is retained as
`review3-restored-affected-parallel.log` (one test, three assertions).

| Final affected run | Passed | Skipped | Log |
| --- | ---: | ---: | --- |
| `SubagentReaderTests`, restored deletion guard | 21 | 0 | `review3-final-SubagentReaderTests.log` |
| `NativeApplicationTests`, alone | 11 | 0 | `review3-final-NativeApplicationTests.log` |
| `SubagentMarkdownTests`, final 11 methods × three iterations | 33 | 0 | `review3-final-copy-SubagentMarkdownTests.log` |
| `SubagentPerformanceTests`, alone | 2 | 0 | `review3-restored-SubagentPerformanceTests.log` |
| Eleven affected parallel-lane classes listed above | 112 | 4 | `review3-complete-affected-parallel.log` |
| Standalone picker gallery | 1 | 0 | `review3-gallery-panel.log` |
| Standalone Markdown gallery | 1 | 0 | `review3-complete-gallery-markdown.log` |
| Standalone numbered/collapsed display gallery | 1 | 0 | `review3-complete-gallery-display.log` |
| **Affected total, including repeated executions** | **182** | **4** | **160 distinct passing tests; 136 gallery PNGs** |

The earlier five-iteration Markdown run (50 passed) is separate from this table.
The final 55,812-byte/400-history-message performance fixture measured a 24.00 ms
maximum draw, 48.81 ms whole-window heartbeat gap and 4.15 ms maximum native Markdown
batch for cold preview preparation. Full expansion measured 23.17 ms maximum draw,
78.77 ms whole-window gap and 13.10 ms maximum native Markdown batch. The 30 settled
layouts reused the native geometry, and sidebar computations did not advance.
The existing 20-progress-update case also passed, with zero sidebar recomputations.

The **one full native parallel lane**, four workers with `test-lanes.py parallel`
exclusions, passed **2,471 tests, zero failures, 37 skips** (2,508 total), exit 0,
in 561.5 seconds including setup. Exact arguments, console output, status and native
result summary are `review3-full-parallel-arguments.json`,
`review3-full-parallel.log`, `review3-full-parallel-status.json` and
`review3-full-parallel-summary.json`. The earlier round-2 retention failure did not
recur; its historical cause is still unconfirmed. Automatic result bundles remain
under this build root and are pruned by the normal script; no named bundle was used.

**Validation ordering:** while that full lane was already running against its
built binary, an additional source-copy audit found that partial selections near
entities/escapes could include the whole parser run, image labels lost their `!`,
and escaped parentheses or quoted titles could end copied links too early. The
production copy function was extracted unchanged into a Foundation-only check:
four cases failed in `review3-red-copy-provenance.log`, then two link cases failed
in `review3-red-copy-link-spelling.log`. The final mapping preserves those authored
tokens and uses the parser's image identity; all six checks pass in
`review3-green-copy-provenance.log`. The native class then passed **33/33** after the
full lane, covering eight corresponding cases (including UTF-16 entities) plus all
rendering, Find, folding, generation and Copy regressions. Its native summary is
`review3-final-copy-summary.json`. This final isolated copy change is covered by the
post-lane class, not by the earlier full-lane binary. The full lane was not repeated.
It changes no layout, drawing, session/tool behavior or model input, so the inspected
gallery and rendering performance measurements remain applicable.

All 136 captures and their contact sheets were inspected; representative full-size
checks include `gallery-review3-panel/running-light-1240x800-open.png`,
`gallery-review3-markdown/light-920x600-card-folded.png`,
`gallery-review3-markdown/dark-920x600-card-details.png` and the child's delegated
task. The palette, uppercase section hierarchy, action tint/alignment, code/table
rendering, bounded previews and narrow controls remain legible. Finished compact
turns still show only the main response; the separate family header remains available.

No helper package, cost accounting, webhook, model-facing text, journal format,
permission/capture/tool/vault boundary or ephemeral side-draft persistence changed.
No installed app, real preferences, Keychain, paid provider or `xctrace --launch`
was used. The lead owns independent review, integration with sub-cost and any
follow-up on the old intermittent retention failure. This stream publishes only
`dev/a128-sub-display`; it does not merge or push `dev/next`.
