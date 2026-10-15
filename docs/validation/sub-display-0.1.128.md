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

## Lead review round 4: rendered Find and side menu routing

2026-10-15, `dev/a128-sub-display`, following `6f69c44a`. Both review findings
are fixed. Only affected classes ran in this round, as requested; no full lane
or gallery was run. There are no layout changes. The round 3 gallery paths and
its explicitly recorded validation ordering remain the visual evidence.

### Root causes and changes

- The renderer's `contains` check ran only after Find had obtained a hit. The
  initial `searchConversation` still searched source/JSON, so a visible phrase
  such as `Last unique result` in `Last **unique** result` never reached it.
  The transcript bridge now requests an app-only search projection. The history
  actor searches agent Task/Result, reports and typed deliveries using the same
  cached Markdown blocks as the native renderer, including unloaded history and
  legacy child task headers. Source search, Copy Conversation, journal records
  and the helper search API retain their previous contracts.
- Opening a matching card also checked only its raw arguments/output. The real
  Find tests exposed this second stage: card disclosure now recognizes the
  rendered phrase using the shared parse. The previous test that injected
  highlights directly now calls `TranscriptFindController.setQuery` through a
  real pane and workspace, and checks automatic opening, expansion and the
  highlighted phrase's visible rectangle.
- Searching the app's saved projection must retain current streaming and unsaved
  text. A bounded display snapshot supplies streaming revisions and unsaved rows
  to the history actor; memory-only delegated-task placeholders use the same
  projection. Saved records keep their own hit IDs, avoiding a second result
  hit through an issuer's resolved card. A retained but abandoned record is not
  an unsaved row: the journal's full reference index guards that boundary.
- The saved-side actions menu bypassed `showAgentFamily` and sent the side's
  family ID to its hidden header. It now uses the existing visible-picker route,
  which addresses the main column while retaining actual delegation ownership.

### Failing-first and mutation evidence

All logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`.

| Evidence | Result |
| --- | --- |
| `review4-red-SubagentMarkdownTests.log` | 12 tests; four failed assertions for rendered card task/result, report and typed-delivery queries through `setQuery` |
| `review4-red-ConversationFamilyTests.log` | 14 tests; the actual side menu action emitted `chat-side` instead of `chat-parent` |
| `review4-find-navigation-SubagentMarkdownTests.log` | Query hits worked, but the rendered task's card did not open; also corrected the test to invalidate the actual timeline row holding the result, rather than another row of the same reply |
| `review4-red-live-SubagentMarkdownTests.log` | Three failed assertions for current streaming text, an unsaved typed report and a memory-only delegated-task header |
| `review4-red-boundary-ContentSearchTests.log` | Abandoned saved text was incorrectly treated as an unsaved display row; full reference lookup fixed it |
| `review4-mutation-search.log` | Turning off the production bridge's rendered-search option failed the Find regressions (14 tests, 11 failures including expected reveal timeouts) |
| `review4-mutation-menu.log` | Restoring the old production side-ID send failed the real menu-action assertion (14 tests, one failure) |

Both mutations returned exit 65 and were restored in `finally` before final
validation. `review4-mutations-status.json` records their exit codes. The saved
Find fixture starts with its agent rows outside the loaded page; it checks hit
IDs, repeated occurrence counts, automatic reveal and actual rendered highlights.
The search boundary fixture crosses the 100-hit page, checks source Copy, rejects
abandoned rows and verifies the generated journal's bytes remain unchanged.

### Final affected validation

**113 passing executions across 99 distinct tests; zero failures or skips.**

| Classes / log | Passed |
| --- | ---: |
| `ContentSearchTests` | 3 |
| `ConversationFamilyTests` | 14 |
| `ConversationSearchPagingTests` | 1 |
| `TranscriptFindTests` | 11 |
| `TranscriptMarkdownTests` | 9 |
| `TranscriptTurnFoldTests` | 24 |
| Above six classes: `review4-affected-parallel.log` | **62** |
| `review4-final-SubagentMarkdownTests.log` (serial, alone) | 14 |
| `review4-final-SubagentReaderTests.log` (serial, alone) | 21 |
| `review4-final-SubagentPerformanceTests.log` (serial, alone) | 2 |
| `review4-final-ConversationFamilyTests.log` (restored menu after mutation) | 14 |

Commands used `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`
and `TEST_RUNNER_PI_APP_SCRATCH_ROOT` within that root, with
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Lane assignments were
checked with `python3 scripts/test-lanes.py list`. Results are summarized in
`review4-final-status.json` and `review4-final-summary.json`. Only the normal
automatic result bundle was retained; no named `.xcresult` was created.

The unchanged 55,812-byte/400-message Markdown performance fixture passed:
cold maximum draw **24.25 ms**, native Markdown batch **4.65 ms** and whole-window
heartbeat **51.85 ms**; expanded maximum draw **24.70 ms**, native batch
**15.16 ms**, heartbeat **89.19 ms**, within the existing 50/100 ms budgets.
These measure rendering/expansion, not a search throughput benchmark. Progress
updates still caused **zero sidebar recomputations**.

No helper package, model-facing content, journal format, cost/webhook accounting,
permission/capture/tool/vault boundary or side-draft persistence changed. All
fixtures and native test hosts were isolated; no installed app, real preferences,
Keychain, paid provider or `xctrace --launch` was used. Remaining work is the lead's
independent review and integration. This round does not claim to resolve the
earlier, non-reproduced full-lane retention flake.

## Lead review round 5: code copy and reader navigation

2026-10-15, `dev/a128-sub-display`, following `a5c02c7a`. All three review
findings are fixed. This round ran affected classes only, as requested. No layout
changed, so no new gallery or full native lane ran; the earlier gallery paths
remain the visual record.

### Root causes and changes

- The 1,200-character preview shortened the parsed code before the native builder
  created its copy mark. Both the hover toolbar and VoiceOver therefore copied
  that prefix. The cached agent reading now retains complete code targets in
  parsed block order, including nested quotes/lists. Each preview adoption binds
  those targets to its native marks and refreshes an existing hover toolbar.
  This also handles a changed hidden suffix when the visible prefix is identical.
  TextKit and syntax highlighting still receive only the bounded preview; full
  code targets are collected during reading preparation, never layout. Ordinary
  assistant rendering and source/selection Copy retain their existing contracts.
- Show in Chat ignored a nil `openSubagentTab` completion and checked only whether
  the child was visible. Back intentionally leaves an embedded reader visible,
  so an obsolete opening could still reveal its message. Reveal now requires a
  successful current opening before touching the child's transcript. The held-load
  regression verifies the return value, reveal state, reveal serial and parent
  focus, then verifies a fresh explicit Show in Chat still works.
- Exact shortcut comparisons retained Caps Lock. The hosted reader now removes
  that flag before matching, like the native transcript. Actual popped-out
  `TabHost.tabKey` tests cover uppercase Find, Next, Previous and Stop with Caps
  Lock, while retaining responder/window ownership and sheet exclusion.

### Failing-first and mutation evidence

All logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`.

| Evidence | Result |
| --- | --- |
| `review5-red-SubagentMarkdownTests.log` | 16 tests; copy regressions reproduced; the nested fixture initially also expected a copy action for an empty fence, which the existing parser omits |
| `review5-red-corrected-SubagentMarkdownTests.log` | Fixture corrected before production edits; 16 tests, eight failures in the two new copy tests |
| `review5-red-SubagentReaderTests.log` | 22 tests, 12 failed assertions in the superseded reveal and Caps Lock tests |
| `review5-green-SubagentMarkdownTests.log` | All 16 passed with the fixes |
| `review5-green-SubagentReaderTests.log` | All 22 passed with the fixes |
| `review5-mutation-SubagentMarkdownTests.log` | Removing the production full-code binding reproduced eight failures in both copy regressions |
| `review5-mutation-SubagentReaderTests.log` | Reverting the production opening-result guard and Caps Lock normalization reproduced the 12 navigation/shortcut failures |

The three production mutations were applied together, then the two serial classes
ran separately. Each targeted test failed as expected; both runs returned exit 65.
The harness verified the named regression failures and restored all three files
in `finally`. `review5-mutations-status.json` records that evidence. Final runs
below used the restored fixes. The copy regressions press the real hover Copy
button and invoke its VoiceOver action; they cover folding, expansion, retained
toolbar refresh, nested fence ordering and unchanged full Markdown Copy.

### Final affected validation

**84 passed, zero failed, three opt-in diagnostics skipped (87 tests).**

| Class | Passed | Skipped |
| --- | ---: | ---: |
| `SubagentMarkdownTests` | 16 | 0 |
| `SubagentReaderTests` | 22 | 0 |
| `SubagentNavigationTests` | 7 | 0 |
| `TranscriptNativeChromeBehaviourTests` | 8 | 0 |
| `SubagentPerformanceTests` | 2 | 0 |
| `MarkdownTextSurfaceTests` | 6 | 3 |
| `NativeCodeTextTests` | 11 | 0 |
| `NestedFenceIdentityTests` | 3 | 0 |
| `ReportMessageNavigationTests` | 9 | 0 |

The first five classes ran individually, matching their serial lane assignments,
with logs `review5-final-<Class>.log`. The remaining four ran in one affected
parallel invocation (four workers), `review5-affected-parallel.log`. The skipped
methods are the existing opt-in line-pitch, token-cost and snapshot diagnostics.
Commands used `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`
and `TEST_RUNNER_PI_APP_SCRATCH_ROOT` within that root, with
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Lane assignments were
checked with `python3 scripts/test-lanes.py list`. `review5-final-status.json`
records exit codes; `review5-affected-summary.json` preserves the final automatic
result bundle's 29-pass/3-skip summary. No named `.xcresult` was created.

The existing 55,812-byte result in a 400-message chat passed its performance
budgets: cold maximum draw **25.50 ms**, native Markdown batch **4.56 ms**, whole
window heartbeat **56.73 ms**; expanded maximum draw **22.77 ms**, native batch
**13.88 ms**, heartbeat **79.69 ms**. Progress updates caused zero sidebar
recomputations. These are the existing prose rendering/expansion measurements;
the code-copy tests separately assert that the folded code display remains bounded.

No helper package, model-facing text, journal, cost/webhook accounting, permissions,
capture, tool, vault or side-draft persistence changed. Tests used generated
fixtures, isolated native test hosts and the test clipboard. No installed app,
real preferences, Keychain, paid provider or `xctrace --launch` was used. Remaining
work is the lead's independent review and integration; this round makes no new
claim about earlier full-lane flakes.


## Lead review round 6: reader ownership and effort integration

2026-10-15, `dev/a128-sub-display`, following `f1cf06cc`. Merged
`origin/dev/next` at `e13e1462` in `114c1bf3`, retaining the policy/effort,
fork-history, new-chat project chip and side-keep recovery behavior. Release
notes retain every stream's items. The Xcode project was regenerated with
`xcodegen`; reciprocal origin validation and historical fork controls remain
alongside numbered readers and Markdown cards. No upstream commit was rewritten.

The first broad affected run also caught a fixture integration mismatch: the
policy stream emits an object envelope plus model-specific `oneOf` effort
branches, while the strict loopback oracle accepted only a bare `oneOf`. The
packaged helper therefore received HTTP 400 before a turn could stream. The
fixture now validates both the object envelope and exactly one branch; unsupported
effort/model pairs and malformed unions still fail. No production tool schema
was changed to accommodate the fixture. The imported historical-card test now
asserts disabled Open/Inspect/Stop specifically and separately asserts that local
Task/Result Markdown Copy remains enabled across appearance changes; treating
every button as a child control conflicted with the rich-text reading contract.

### Causes and lifecycle changes

The review found three inconsistent owners for asynchronous reader work: external
Show in Chat only checked a child-open generation, history Find/Home/position
reads checked the main-window revision, and menu validation accepted only the
workspace window. That let older child reveals survive a newer parent reveal,
canceled valid popped-out reads after main navigation, and disabled the menu
commands that their keyboard equivalents could already run.

A hosted child now owns one `HostedReaderToken`, with the reader identity and a
single generation. Every awaited opening, reveal and history operation captures
and validates that token. Presentation generations still identify retained page
content; they no longer substitute for the reader's navigation intent. The audit
covered the following paths, including their paging state:

- Opening from a card, search or Show in Chat shares the same token through
  header validation, registration/attachment, initial history and message reveal.
  A newer external destination retires the previous pending opening even when
  that destination is an already-loaded ordinary chat.
- Reopening revalidates saved history. Real hide, Back, close, reload and newer
  reader navigation retire previous reads and clear their loading/read handles
  while preserving page cursors. A canceled initial presentation becomes dormant
  so a current presentation can reload it.
- Moving between pane and popped-out window retains the reader and its token;
  a transient detached container does not become a hide or force a second load.
  Unrelated main selections and Reports leave a popped-out reader's token intact.
- Find/search, Home, position jumps and retries, older/newer paging, history
  progress/viewport work, position recovery and version reads all check that
  reader token before applying their awaited results. Completion cannot restore
  focus after a newer focus choice. Existing display eviction and side-availability
  visibility rules are preserved.
- Conversation command availability and dispatch resolve the key child window's
  active reader, or the responder inside an embedded reader. Find, Next/Previous,
  Stop, Latest Messages, Search and Copy, folding and Inspector follow that reader
  even when the main window is on Reports. Native sheets still suppress commands;
  human composer commands and managed-child Delete/Rename remain unavailable.

The native menu fixture nominates its real popped-out `NSWindow` through the
window resolver used by command routing. Production resolves `NSApp.keyWindow`.
This avoids competing with other test hosts on this shared machine for process
activation; the fixture still validates and invokes the actual menu items,
checks the child's native Find bar and native sheet exclusion, and checks that
Stop does not affect the selected parent. The workspace-only guard mutation below
reproduces the menu failure without relying on OS focus acquisition.

### Effort display and integration decisions

The picker metadata line, transcript card header/details, child header and family
Inspector use the accepted current turn's effort. Explicit and inherited values
both read as the actual level (for example, `high`); `default` reads as
`model default` when the model has effort controls. A model with an explicitly
empty capability list shows no effort. Missing legacy capability information is
filled only from the accepted grant or the connection's existing catalog;
unknown model-default capability is omitted rather than invented.

Cold discovery retains the latest accepted turn's effort across terminal/state
mirrors which omit it. Older journals fall back to the accepted model grant.
Follow-ups update current cards and headers; historical send receipts keep the
effort accepted for their own turn. The display context is a small in-memory
cache, published with metadata instead of parsed during layout. Long child titles
truncate before the separate trailing effort label, keeping the level readable
in a narrow pane. Tooltips and VoiceOver include the level.

The display changes add no persisted field, journal write, tool schema, provider
call or model-facing text. The merged policy stream intentionally owns the
optional effort contract and its saved fields; this stream reads those fields.
Its [policy validation](subagent-policy-0.1.128.md) remains the record of those
behavioral changes. Cost totals, webhook policy, permissions, capture, vault,
tools and ephemeral side persistence were not altered by these fixes.

### Failing-first and production mutations

Logs and artifacts are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`.

| Evidence | Result |
| --- | --- |
| `review6-red-corrected-SubagentReaderTests.log` | 26 tests, 24 failed assertions before reader fixes |
| `review6-red-corrected-SubagentEffortTests.log` | 3 tests, 26 failed assertions before effort display changes |
| `review6-green4-SubagentReaderTests.log` | 26 passed |
| `review6-green1-SubagentEffortTests.log` | 3 passed |
| `review6-mutation-SubagentReaderTests.log` | 26 tests, 23 failed assertions; all three named review regressions failed |
| `review6-mutation-SubagentEffortTests.log` | 3 tests, five failed assertions in the changed follow-up effort regression |

The initial red invocations each exposed a fixture compile issue, corrected
before production changes (a run-state case and an async XCTest autoclosure).
The corrected red reader run also included the original menu activation setup;
that fixture was later made deterministic as described above. Intermediate green
runs exposed a move/reload race, now covered by the same reader token and explicit
revalidation flag, before the final 26-test pass.

The mutation harness removed pending-opening retirement before a parent reveal,
restored global main-window revision checks for child Find/Home/position reads,
restored workspace-only menu availability, and made the initial grant override a
new follow-up's accepted effort. The two affected classes ran alone, returned
exit 65, and failed the four expected named regressions. The harness restored all
four production files in `finally`; `review6-mutation-status.json` records the
verified failures and restoration. Final validation uses the restored fixes.

The interrupted `ConversationPaneTests` run is retained in
`review6-integration-ConversationPaneTests.log`: the first helper-crash test failed
after the oracle rejected the schema, and the run was stopped before further
timeouts. Two new gateway regressions then failed first (three assertions, both
API formats and common-constraint enforcement), in `review6-red-gateway.log`.
The corrected oracle passed all **20 Python gateway tests** in
`review6-green-gateway.log`. Reverting the production oracle guards reproduced
all three assertions in `review6-mutation-gateway.log`; the harness restored the
file (`review6-mutation-gateway-status.json`). The final native ConversationPane
rerun then passed **81/81** against the packaged helper and loopback gateway.

The first affected parallel batch (`review6-integration-affected-parallel.log`)
passed 218 tests with two failures: the historical-card test assumption described
above and a one-row difference (601 versus 602) in
`HistoryExtentTests.testAReaderInRoomBelowKeepsTheirPlaceWhenTheRoomIsMeasuredAgain`.
The same history assertion failed in the isolated pre-final class (23 passed,
one failed; `review6-history-isolated-before.log`). An exact comparison against
merge commit `114c1bf3` passed 24/24 (`review6-history-baseline.log`); the harness
backed up and restored every working file, verified in
`review6-history-baseline-status.json`. Reader checks were then kept directly
after awaits in the existing history function, eliminating an extra async
wrapper and capturing progress ownership before any source handoff. The history
assertion and scroll-position implementation were not changed. The resulting
isolated class passed 24/24; final parallel results below remain separate evidence
for this scheduling-sensitive mismatch.

### Final validation

Final affected native validation: **377 passed, zero failures, zero skips**
(30 classes). The eight serial classes ran alone; the 22 parallel classes ran
together with four workers. The two extra isolated integration checks are not
counted twice in the 377 total. `review6-final-status.json`, the per-run
`review6-final-<Class>-summary.json` files and
`review6-final-affected-parallel-tests.json` retain the results.

| Serial class | Passed |
| --- | ---: |
| `SubagentReaderTests` | 26 |
| `SubagentOpeningTests` | 12 |
| `SubagentNavigationTests` | 7 |
| `NativeApplicationTests` | 11 |
| `ConversationPaneTests` | 81 |
| `SidebarSearchTypingTests` | 2 |
| `SubagentMarkdownTests` | 16 |
| `SubagentPerformanceTests` | 2 |

| Affected parallel class | Passed |
| --- | ---: |
| `HistoryEdgeTests` | 16 |
| `HistoryExtentTests` | 24 |
| `MessageVersionTranscriptTests` | 8 |
| `ReportMessageNavigationTests` | 9 |
| `SideKeepOrderingTests` | 12 |
| `SideKeepRecoveryTests` | 15 |
| `SidebarSearchSidebarTests` | 9 |
| `SubagentDeletionTests` | 10 |
| `SubagentDiscoveryTests` | 13 |
| `SubagentDisplayTests` | 7 |
| `SubagentEffortTests` | 3 |
| `SubagentInspectorTests` | 6 |
| `SubagentModelGrantTests` | 2 |
| `SubagentOrganizationTests` | 13 |
| `SubagentPanelTests` | 8 |
| `SubagentSteeringInspectorTests` | 5 |
| `SubagentSteeringPresentationTests` | 9 |
| `SubagentSteeringWorkspaceTests` | 4 |
| `SubagentTranscriptTests` | 10 |
| `TabHostTests` | 16 |
| `TranscriptFindTests` | 11 |
| `TranscriptRevealTests` | 10 |

Commands used `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`
and `TEST_RUNNER_PI_APP_SCRATCH_ROOT` within that root, with
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Lane assignments were
checked with `python3 scripts/test-lanes.py list`; `review6-lanes.txt` preserves
them. No named `.xcresult` bundle was created.

The 55,812-byte result in a 400-message chat retained the existing performance
budgets: cold maximum draw **25.64 ms**, Markdown batch **4.63 ms**, heartbeat
**55.21 ms**; expanded maximum draw **28.24 ms**, batch **15.16 ms**, heartbeat
**82.77 ms**. Progress updates caused zero sidebar recomputations.

The final restored loopback suite passed **20/20** in
`review6-final-gateway.log`. Helper integration validation passed **46/46** in
`review6-helper.log`: `SubagentPolicyEffortTests` (25), `SubagentForkTests` and
`JournalCloneTests` (21 combined). The command was `swift test --package-path
packages/swift-host --scratch-path <build-root>/swift-host --configuration release
--arch arm64 --jobs 4 -Xswiftc -Osize --filter
'SubagentPolicyEffortTests|SubagentForkTests|JournalCloneTests'`, with temporary
fixtures inside this stream's scratch root. No helper source was authored by this
round beyond the upstream merge.

The **one full native parallel lane** completed in 652.5 seconds: **2,533
passed, three failed, 37 skipped (2,573 tests)**. It used the arguments from
`python3 scripts/test-lanes.py parallel`, passed to `scripts/test-macos.sh` with
`-parallel-testing-enabled YES -parallel-testing-worker-count 4`. The exact skip
arguments, output, summary and test tree are retained in
`review6-full-parallel-args.txt`, `review6-full-parallel.log`,
`review6-full-parallel-summary.json` and `review6-full-parallel-tests.json`.
`HistoryExtentTests`, including the earlier one-row mismatch, passed in this lane.

The three failures exposed one further guard regression: folding had been coupled
to the existence of a chat record when menu routing was made reader-aware. Local
folding has always worked from a retained transcript display. Reader availability
is now separate from record availability: folding needs the display; lifecycle
and helper commands still need their chat record. Key child-window routing,
sheet/Quick Open exclusion and the managed-child Delete guard remain intact.
The existing behavioral tests failed before this correction:

- `TranscriptTurnFoldTests.testEvaluatingTheFoldMenuDoesNotPlanThePage`
- `TranscriptTurnFoldTests.testTheFoldCommandsOpenAndCloseTheEndOfTurnFold`
- `ResponseChronologyTests.testTheFoldCommandsDriveTheSameParts`

After the fix, **75 affected checks passed, zero failures or skips**:
`SubagentReaderTests` 26 and `NativeApplicationTests` 11 each ran alone, followed
by `TranscriptTurnFoldTests` and `ResponseChronologyTests` (38 combined) in a
four-worker affected invocation. These reran the real folding behavior, menu
availability/dispatch, native sheet guards and child Delete protection. Results
are in `review6-final-SubagentReaderTests.log`,
`review6-final-NativeApplicationTests.log`,
`review6-final-post-full-folding.log` and their saved summaries/test tree.
There are **415 distinct passing affected native tests** across the two final
phases; repeated reader/menu checks are not counted twice. The full lane was not
repeated, honoring the requested one-run limit. Its three failures remain in the
record and are not relabelled as a passing full run. The final small folding
correction has affected-class coverage rather than another complete lane.

### Gallery

`SubagentEffortGalleryTests` ran standalone: **one passed, zero failures**, log
`review6-gallery-SubagentEffortGalleryTests.log`. All **12 captures** were inspected
at `gallery-review6-effort/` (manifest in that directory):

- Light and dark at 1240×800 and 920×600, each with the card, open picker and child
  side-pane header.
- Picker rows show `high`, `low`, `model default` and a model with no effort label;
  the native fixture also checks all four accessibility labels and popup bounds.
- Card header/details and child header show `high`. The narrow child header keeps
  effort visible while its title truncates. The picker stays within the window,
  with compact rows, uppercase sections and the accent + New Side action.

No installed app was launched and no real preferences, Keychain, paid provider
or `xctrace --launch` was used. Remaining handoff after validation and push is the
lead's independent review; no merge or push to `dev/next` is part of this stream.
## Lead review round 7: Find, Source, receipts and card details

2026-10-15, `dev/a128-sub-display`, following `f53f7625`. This round fixes all
three review findings and the lead's details-grid design note. It runs affected
classes only, as requested; no new full native lane or helper-package run.

### Causes and decisions

- Find's automatic first-match reveal and Next-match reads renewed the hosted
  reader token while the same query was awaiting its next 100-hit search page.
  Find reveals now share that reader intent. The Find controller retains its
  own query/task and newest-match cancellation; Back, hide and close still retire
  the reader token. The regression uses `TranscriptFindController.setQuery`
  through the ordinary pane bridge and `WorkspaceModel.searchConversation`,
  holding a generated-history search page while both automatic and Next reveals
  read other pages. All 251 matches must arrive, with the second match current.
- A typed delivery's Source lookup used only main selection revision. Embedded
  Back changes focus and the reader token without changing that revision.
  Coordination lookup completion and error publication now check the originating
  hosted reader's token; ordinary main readers retain their selection guard.
  The regression holds that lookup, presses embedded Back, and verifies the
  parent's message, pixel offset and reveal state remain intact. Its control case
  verifies that a current Source link still reveals the issuing call.
- Saved `agentToolWire` send receipts need not contain a summary. The presentation
  had ignored their accepted effort and fallen back to the initial grant.
  Receipt effort now resolves `nativeSubagent.effort`, then the output envelope,
  before legacy summary/grant fallback. The current-turn overlay remains scoped
  by origin and turn. A Codable round-trip fixture starts at low, has an older
  turn-2 send receipt and a current turn-3 summary; it checks native metadata
  precedence, output-only high/default, legacy fallback, and unchanged source
  output/native metadata. Model capabilities still determine whether effort is
  displayed. Nothing changes in model-facing text or journals.
- Expanded cards use seven compact Pi label/value rows: Model, Effort, Tools,
  Requests, Time, Cost and Tokens. Values use the normal UI font, retain complete
  VoiceOver labels, and wrap within narrow cards. Cost uses the shared money
  formatter and adds only an unknown-cost note when needed (singular/plural).
  There is no reported-request count. Copy buttons remain on Task and Result.
  Metadata views rebuild only when the small field list changes; transcript
  Markdown parsing/layout is unchanged. Gallery inspection caught a nested-stack
  baseline error; a failing geometry regression now verifies that wrapped values
  and cost notes keep each label on the value's first baseline at 272, 500 and
  850 points.

Two optional read-only lookup seams hold precisely the awaited search/coordination
boundary in generated fixtures. Production still reads the same history actor or
helper, with the same source validation and search semantics.

### Failing-first and mutation evidence

All artifacts below are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/`.

| Stage | Result | Evidence |
| --- | --- | --- |
| Reader regressions before fixes | 26 passed, 2 failed | `review7-red-reader.log`, matching summary JSON |
| Effort and details regressions before fixes | 12 passed, 3 failed | `review7-red-display.log`, matching summary JSON |
| Baseline regression before layout correction | 10 passed, 1 failed | `review7-red-grid-baselines.log`, matching summary JSON |
| Restore unconditional reader renewal and selection-only Source guard | 26 passed, the same 2 reader regressions failed | `review7-mutation-reader.log`, matching summary JSON |
| Ignore receipt effort again | 3 passed, the saved-receipt regression failed | `review7-mutation-effort.log`, matching summary JSON |

All three mutations were restored before final validation;
`review7-mutation-status.json` records their exit status and test counts.

### Final affected validation

Every class ran through `PI_BUILD_ROOT=… scripts/test-macos.sh
-only-testing:PiAppTests/<Class>`, using this stream's build root and generated
scratch fixtures. `scripts/test-lanes.py list` was checked; serial classes ran
alone. The six eligible parallel classes ran together with four workers.

| Class | Passed |
| --- | ---: |
| SubagentReaderTests | 28 |
| SubagentEffortTests | 4 |
| SubagentTranscriptTests | 11 |
| SubagentSteeringPresentationTests | 9 |
| SubagentSteeringWorkspaceTests | 4 |
| TranscriptFindTests | 11 |
| TranscriptRevealTests | 10 |
| SubagentNavigationTests | 7 |
| SubagentMarkdownTests | 16 |
| SubagentPerformanceTests | 2 |
| SubagentEffortGalleryTests | 1 |
| **Total** | **103** |

Zero failures and zero skips. Logs, summaries and case lists are
`review7-final-{reader,parallel,navigation,markdown,performance,gallery}.*`;
`review7-final-status.json` records the six runs. No named result bundle was
created; the native script pruned older automatically named bundles.

The 55,812-byte Markdown result in a 400-message history had a 15.45 ms worst cold
draw, 3.05 ms worst Markdown batch and 52.83 ms heartbeat gap. Expansion measured
25.03 ms worst draw, 15.01 ms Markdown batch and 77.17 ms heartbeat gap. All existing
budgets passed; 20 progress updates caused zero sidebar recomputations. These are
test-host observations, not signed-release performance claims.

### Gallery and boundaries

Final gallery: `gallery-review7-details/manifest.txt`, **12 PNGs**, all inspected:
light/dark × 1240×800/920×600 × card/picker/child. Card captures expose the full
grid; the narrow capture scrolls just enough to keep Tokens and the Cost note
inside the transcript viewport. Picker rows retain effective effort, numbered
children, complete footer and window containment. Side-pane scenes retain the
main-column pill and the child's readable effort/header. The initial gallery
under `gallery-review7-details-initial/` is retained only as evidence of the
baseline issue and is superseded by the final gallery.

No cost accounting, webhook, helper-package, permission, capture, tool, vault,
side-draft persistence or journal changes. Generated fixtures and isolated native
test hosts only; no installed app, real preferences, Keychain or paid-provider calls.
Release/design notes were updated. Remaining work is the lead's independent
review and integration; this round makes no new claim about earlier full-lane
flakes.

## Lead review round 8: nested families and navigation ownership

Work remains on `dev/a128-sub-display`; the build root for all evidence below is
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`. This round uses only
affected native classes, serial-lane classes alone, and the standalone picker
gallery. No full lane or helper-package run is claimed for this round.

### Root causes and decisions

- The replacement picker grouped only direct `parentSessionID` children. Both a
  saved side and its reply fork disappeared from normal sidebar lists, but the
  picker could reach only the first. Its cached projection now traverses all
  descendants, with a visited set, retaining real delegation scopes. Rows form a
  depth-first tree with 14-point indentation per parent, two lines at most, and
  complete parent-labelled accessibility/tooltip text. Root agents retain number
  order; each side's agents keep their own numbers and Stop authority. Archived
  branches remain in the picker, labelled Archived. Metadata invalidation reaches
  all ancestors; no transcript is scanned or parsed for the tree.
- Nested sides still open beside their immediate parent using the existing side
  path. The main-column header resolves the original root's complete picker, so
  drilling into a branch never loses access to other saved descendants. Ancestry,
  stored links, helper ownership and draft persistence are unchanged. Search
  retains each saved descendant under its existing archive/project filters and
  labels its immediate parent. Imported/orphan/cross-project side behavior stays
  unchanged. Root-picker ancestry validates the project at every edge, including
  delegated children; a malformed link cannot expose another project's family.
- Source checked its originating reader only during coordination lookup, then
  silently changed to main-window ownership. The entire parent operation now
  carries the origin token *and* the destination intent through helper opening,
  versions metadata, anchor history, earlier-version pages and the final reveal.
  Inspector source entry points and popped-out Back share that ownership. Opening
  the owning ordinary Side deliberately replaces an embedded child and transfers
  ownership to the main pane before its load; an external origin keeps its token.
- Sidebar hits incorrectly required Chats even for an external child. Hosted hits
  now require that exact reader's current token and host visibility, plus the
  unchanged query/open identity. Reports and Background remain in the main window.
- The audit also found main reload/edge/search-hit reads with no workspace-token
  check, a canceled first version page that left a loading cover, and a coalesced
  position destination that could restart from a retired operation's cleanup.
  Main navigation now retires reads on every page transition, including Background
  and a leave/return round trip. Version cleanup uses its own in-memory read ID;
  it cannot clear a newer same-index retry. Presentation cleanup remains cursor
  preserving. No new navigation generation is stored in journals.

The short normative rule is in
[Reader navigation ownership](../design/subagents.md#reader-navigation-ownership).
A hosted reader uses one local navigation UUID; main/ordinary-side readers use the
workspace revision. Presentation, query and read IDs protect the specific resource
being published or cleaned up; they do not replace reader navigation ownership.

### Failing first and real-guard mutations

Saved console logs and xcresult summary/test JSON use the `review8-` prefix. Each
native run used `PI_BUILD_ROOT` above and
`TEST_RUNNER_PI_APP_SCRATCH_ROOT=<build root>/scratch-review8`, with
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>` (multiple filters only for
parallel-lane classes). No named result bundle was created; the script pruned its
older automatic bundles after summary/test JSON extraction.

- `red-family`: 14 passed / 1 failed. The nested tree, nested agents and row order
  were absent before the traversal fix.
- `red-reader`: 28 passed / 2 failed. Source was suspended at versions metadata,
  anchor history, version-page history and final message history, with paired
  non-canceled controls. Back lost its position at all four stages. A real indexed
  content-search hit failed in the external child on Reports and Background.
- `red-audit`: main reload, older edge, version cover and search-hit regressions
  failed on a Background→Chats round trip. Its extra side-handoff control initially
  used an invalid fixture link (owner changed without the call's parent); the
  fixture was corrected to the real reciprocal ownership contract. That setup
  failure is not counted as a production defect.
- `red-inspector`: 32 passed / 1 failed; Inspector's parent Source changed the
  parent after embedded Back while versions metadata was suspended.
- `red-back`: 33 passed / 1 failed; a newer reveal in the popped-out child did not
  retire the older Back operation's pending parent version read.
- `red-position`: 34 passed / 1 failed; cleanup started a second, obsolete position
  read after the main page had left and returned.
- `red-project-boundary`: 7 passed / 1 failed; the new root routing bypassed the
  existing family projection's cross-project check. Per-edge root validation now
  preserves that check for both the header and popover.
- `red-source-destination`: 35 passed / 1 failed; starting a parent Source lookup
  did not retire an older parent reveal until after versions metadata returned.
  Starting the destination intent now retires the old read before the first await.
- `mutation-tree`: removing recursive traversal from the real picker projection
  failed 3 family tests (13 passed).
- `mutation-origin`: removing the real `TranscriptNavigationToken.origin` guard
  failed typed Source, Inspector Source and popped-out Back (31 passed / 3 failed).
- `mutation-visibility`: restoring the Chats requirement in the real hosted search
  guard failed the external search-hit test (33 passed / 1 failed).
- `mutation-main`: ignoring the real workspace revision failed the page-round-trip
  read test (33 passed / 1 failed).

All mutations were restored in `finally` blocks. The restored reader and family
classes passed before continuing. The mutation runner and exact failure records
are `review8-mutations.py` and `review8-mutation-status.json` in the build root.

### Awaited-path audit and regression map

The final grep inventory is `review8-navigation-await-audit.txt` in the build root
(228 await sites, including the non-navigation reads classified below).
Paths below are under `apps/macos/PiApp`; tests are under `PiAppTests`. This table
covers navigation entry points and every underlying conversation read/reveal
stage, including deferred retries and source lookups. Pure storage methods return
data and never navigate; their publication owner is identified here.

| Path / awaited operation | Ownership and visibility | Regression coverage |
| --- | --- | --- |
| `Tabs/SubagentTab.swift`: `openSubagentTab`, `ensureLoaded`, `loadSubagentTab` (parent selection, load, managed attachment) | Exact reader token before/after await; actual host visibility, identity-key reuse; completion never focuses | `SubagentReaderTests`: initial-load Back, another-tab choice, close/reopen, pane/window move, hidden reload, side fallback; `SubagentPanelTests`: restored tab; `SubagentOpeningTests`: live attachment after main selection |
| `Workspaces/WorkspaceSubagents.swift`: `openSubagent` (header, discovery, tab load, turn-message lookup, final reveal) | One opening token throughout; validated project/link, shown reader and current focus; newer external destinations retire unfinished opens | `SubagentOpeningTests.testCardHeaderValidationDoesNotOverrideANewerTabChoice`; `SubagentReaderTests`: new parent reveal, Back superseding Show in Chat |
| `WorkspaceSubagents.attachManagedSubagent` (header and helper open) | Caller presentation predicate or exact reader token; helper connection/link remains the same | `SubagentOpeningTests.testVisibleChildAttachmentSurvivesAnUnrelatedMainSelection`, selection/Inspector attach and unload-during-opening tests |
| `WorkspaceAgentNavigation.openAgentSource` (coordination history → Source, delivery, fallback parent/child) | Captures originating reader/main intent before lookup; checks before dispatch/error; parent branches carry origin onward | `SubagentReaderTests.testEmbeddedBackRetiresAnAwaitingAgentSourceLookup`; four-stage Source regression with uncanceled controls |
| `WorkspaceAgentNavigation.showAgentSource` | Parent path retains origin; child Source is revealed inside the same validated opening rather than starting a second navigation afterward | Inspector Source regression; `SubagentNavigationTests.testFollowUpReturnAndTypedSourceKeepTheIssuingSendInAnEarlierVersion` |
| `WorkspaceSubagents.backToSubagentParent`, `openSubagentParent` | Back renews origin; embedded same-parent Back only focuses; external Back carries its new token; parent selection/side opening checks expected selection, pane and workspace revisions | `SubagentReaderTests.testNewRevealInPoppedChildRetiresItsAwaitingBackToParent`, owning-side handoff, saved-side-owned agent and embedded Back tests |
| `WorkspaceSubagents.revealSubagentCall` (helper open → `session.versions` → anchor → version load → exact tool reveal) | One destination intent starts before the first await, retiring older destination reads; it carries origin through every stage; `transcriptShows` before publication; errors guarded too | `SubagentReaderTests.testEmbeddedBackRetiresEveryStageOfAParentSourceReveal` (four gates × Back/control); Inspector and external Back gates; `testParentSourceRetiresAnOlderParentReadBeforeAwaitingItsVersionLookup`; `SubagentOpeningTests` edited-ancestor source routes |
| `WorkspaceVersions.showVersion`, `latestVersion`, `readVersionPage` | Explicit version choice starts an intent; internal Source version work shares it. Helper/decode/accounting return into the same version read ID and visible transcript; old cleanup cannot leave a spinner or clear a newer read | `MessageVersionTranscriptTests`; Source version-page gate; main round-trip version case |
| `WorkspaceSelection.select`, `loadSelectedChat`, `restoreShownSide` | Main selection/workspace plus display/presentation identity; hosted load uses its own token. Metadata/draft/coordination/plan reads, unchanged-file reuse, initial history and accounting recheck before adoption | `WorkspaceLoadingTests` (12), `WorkspaceConcurrencyTests` (8), reader hidden reload/canceled flags, `SubagentOpeningTests` |
| `WorkspaceSelection.readInitialWindow`; `WorkspaceHistory.readConversationWindow` | Data reads for latest/held anchor, helper/file handoff, cursor validation and progress. Low-level window read checks reader/main token; caller also checks presentation/visibility before adoption | `WorkspaceLoadingTests`; `HistoryEdgeTests`; `TranscriptRevealTests` replaced-source/helper-boundary tests |
| `WorkspaceSelection.selectSide`; `WorkspaceSides.showSide`, `loadSideDisplay` | Main workspace revision plus selected parent, pane intent and presentation; expected own selection/page transition is accounted for; stale completion never selects the Side tab | `SubagentReaderTests`: saved-side/file race, another-parent opening, side reopen and boundary reset; `SideTests`, `SideRelaunchTests`, `WorkspaceLoadingTests` draft/close races |
| `SubagentFamily.openFamilySide`, `openNewFamilySide` | Uses existing side opening; deferred New Side checks pane/main selection/revision before and after await | `ConversationFamilyTests`: nested opening, root picker/menu, existing-side reuse, ephemeral draft; reader deferred New Side race |
| `WorkspaceHistory.reloadHistory`, `loadHistoryPage` | Reader/main token, presentation and read identity; recheck source and accounting results; only owning boundary task clears flags; retired reload becomes dormant | Reader main round-trip cases, unchanged-child paging cancellation; `HistoryEdgeTests`, `WorkspaceLoadingTests` |
| `WorkspaceHistory.fillLiveGap`, `reacquireHistoryPositions`, `historyViewportReady` | Captured intent across waits/retries and publication; viewport callback uses actual visibility; metadata-only position reads also retain presentation/lineage | `HistoryExtentTests` bounded retries/recovery/coalescing; reader page-round-trip and popped history tests; `HistoryEdgeTests` |
| `TranscriptReveal.revealInTranscript`, `revealStartOfChat`, `readWindow` | Shared `TranscriptNavigationToken`, presentation, reveal serial and `transcriptShows`; explicit reveal renews intent, Find's own reveals do not | `TranscriptRevealTests` (10); reader Back/read, popped Find/Home on Reports, full 251-match `setQuery` test |
| `TranscriptReveal.jumpToHistoryPosition`, `drawablePage` and delayed/coalesced retries | Reader/main token through every page/accounting await; retries and queued destinations cannot outlive the intent; actual transcript visibility | `HistoryExtentTests` (24); reader popped position read and `testRetiredPositionReadDoesNotRestartItsQueuedDestination` |
| `WorkspaceContent.searchConversation`, `searchConversationSource`; `ConversationPaneBridges` / `TranscriptFindController` | Source pages capture reader/main token; query and match tasks additionally cancel their own old work; Find reveals share rather than renew the reader intent | `TranscriptFindTests` (11); reader actual `setQuery`/251 matches with pending second page and off-page Next |
| `WorkspaceContent.revealConversationHit`, `revealMessage` | Hit publication checks token, actual visibility and presentation. Show in Chat checks current successful child opening; ordinary targets account for their own selection/page transition and retain optional origin through history/accounting | Reader main search-hit round trip, new parent superseding child, Back superseding visible-child reveal; `ReportMessageNavigationTests` (9) |
| `SidebarSearch.revealSidebarSearchHit` / `SidebarSearchReveal`; `WorkspaceSelection.openFromSidebar` | Query/open identity and Task cancellation plus exact hosted token/visibility; ordinary path requires Chats. Delegated-task history lookup rechecks all of these before revealing | Reader real indexed child hit on Reports/Background/Chats; `SidebarSearchSidebarTests` (9), including superseded opens/query change/shutdown |
| `Inspector/Session/SessionInspectorModel`: `showInChat` linked-message lookup, `reveal`, `showOriginatingTool` family lookup, `showSubagentParent`; `InspectorAgentCoordination` Source/delivery actions | Destination intent before lookup/queued dispatch, current Inspector request where applicable; origin token passed to parent chain; child open and final message use one opening | Reader Inspector version-read regression; `SubagentOpeningTests` standalone/family Inspector source and Parent-request routes; `SubagentInspectorTests`, `SubagentSteeringInspectorTests` |
| `WorkspaceLaunchSelection.reopenRememberedSelection` | Existing launch selection generation; child restore goes through the same reader opening and visible-host predicate | `SubagentPanelTests` saved-tab and legacy child/Reports restore; `SideRelaunchTests` |
| `WorkspaceContent.conversationPage`; `Inspector/ConversationContentView` search/copy/export | Read-only retained-source paging; the sheet's `PayloadTaskScope` owns result/copy/export publication. It does not focus or scroll. Show in Transcript uses the guarded reveal path above | Existing `ConversationSearchPagingTests` / payload scope tests; unchanged data-only path, not rerun in this round |

The broad grep also includes background discovery/status/accounting, draft recovery,
transactional fork/create/delete reads, Inspector archive refresh, resource/file/Git
readers and message-detail/copy reads. Those are not conversation navigation:
they retain their existing helper connection, transaction, Inspector/task-scope or
file-tab ownership and do not adopt a transcript position. Their *navigation*
entry points are the shared open/reveal paths listed above. No tool execution,
provider call, permission, capture, vault, accounting or journal contract changed.

### Final validation and gallery

Final result: **229 distinct affected tests passed, zero failures, one intentional
skip**, across 20 classes. Repeated green checks are not added to that count.
The skip is the older 68-image panel gallery, whose opt-in environment variable
was deliberately absent; the requested nested gallery passed and produced all
four images. `review8-final-status.json` contains the per-test, per-class result
and the exact supplying run.

| Class | Passed |
| --- | ---: |
| ConversationFamilyTests | 16 |
| HistoryEdgeTests | 16 |
| HistoryExtentTests | 24 |
| MessageVersionTranscriptTests | 8 |
| ReportMessageNavigationTests | 9 |
| SideRelaunchTests | 3 |
| SideTests | 15 |
| SidebarSearchSidebarTests | 9 |
| SubagentInspectorTests | 6 |
| SubagentOrganizationTests | 13 |
| SubagentPanelTests | 8 |
| SubagentSteeringInspectorTests | 5 |
| TranscriptFindTests | 11 |
| TranscriptRevealTests | 10 |
| WorkspaceConcurrencyTests | 8 |
| WorkspaceLoadingTests | 12 |
| SubagentReaderTests (serial) | 36 |
| SubagentOpeningTests (serial, generated loopback helper) | 12 |
| SubagentNavigationTests (serial) | 7 |
| SubagentPanelGalleryTests (serial) | 1 |

Evidence: `review8-prefinal-parallel-{summary,tests}.json` and
`review8-final-{reader,family,reveal,opening,navigation,gallery}-{summary,tests}.json`,
with their `.log` files. The family and reader results are the final reruns after
all boundary and destination-ownership changes. No new layout change followed the
gallery run.

Gallery directory: `gallery-review8-nested/`, manifest `manifest.txt`:

- `nested-light-1240x800.png`
- `nested-dark-1240x800.png`
- `nested-light-920x600.png`
- `nested-dark-920x600.png`

All four were opened and visually inspected. They show three saved side/fork
levels, agents under their actual owners, root agents, one running indicator per
place, aligned accent New Side, all six rows and the complete footer without
scrolling or window-edge clipping. Native assertions also check indentation,
visibility and window containment. Navigation/key/VoiceOver regressions cover the
same row implementation.

Only generated fixtures, isolated preferences/vaults and the synthetic/loopback
helper were used. No installed app, real preferences, Keychain or paid-provider
calls. No helper-package, model-facing, journal, accounting, webhook or permission
changes. The commit/push target is `dev/a128-sub-display` only.
Remaining work is the lead's independent review and integration; no known requested
fix remains open in this stream.


## Lead review round 9: reader recovery and original references

Branch `dev/a128-sub-display`; build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`. This round uses
scratch-review9, generated journals, and the existing loopback gateway. No installed
app, paid provider, real preferences/Keychain, named result bundle, helper package
change, model-visible text change or journal format change. The separate cost and
webhook stream remains untouched; the one footer change only guards a retained
Stop callback against an original-reference reader.

### Root causes and decisions

- Rejecting an obsolete initial page left the owning display dormant. Page return
  and canceled-load cleanup now reconcile visible readers, with fresh presentation
  identity and the same desired chat. Leaving Chats retires an initial read at once;
  an uncooperative old read cannot delay the new read or clear its flags. Main,
  saved-side, child-tab and popped-child cases are covered, including returning
  before and after the old completion. Recovery never changes keyboard focus.
  Eligibility requires a presentation that actually began; populated in-memory
  displays are left alone. Recovery defers to a newer reveal/jump/version read,
  then completes any still-pending initial draft setup.
- The host revision counted Side re-clicks and external-window activity. It now
  describes actual pane choices only. Pane show/close/move transitions reconcile
  side hydration; unrelated window selections and inactive-tab closes do not
  invalidate it. The audit also moved the idempotent version guard before token
  renewal and removed main-revision changes from external-child Show in Chat.
  Parent Source's expected pane revision now accounts for an already-shown Side;
  a popped-out child can reveal its issuing message there without a fake selection.
- A retained Find query was a second still-wanted read: cancellation could stop
  search with “Search failed”. Reader retirement now suspends the query, and visible
  readers restart it under the new token. Recovery rebuilds matches without
  automatically navigating to an obsolete first match. Query edits/close still own
  their cancellation, and Find's own reveals still share the query intent.
- The new owner decision replaces disabled History controls with Open and Inspect
  Requests. A derived index reads copied acceptance plans off the main actor. Its
  cache contains original identities, labels and numbers, never delegation or cost
  authority. The fork's own numbers count copied starts first, including missing
  originals. The picker puts inherited entries after owned agents in a separate
  “From the original chat” group. A fork with inherited references uses its own
  picker scope and retains New Side; the ancestor's complete descendant tree
  remains reachable.
- An original-reference tab keeps `originalForkID` in existing tab restoration
  state, not a chat/journal field. One child identity still means one tab. Reusing
  this tab never upgrades it: it stays read-only until closed. Headers and native
  titles include “From the original chat · <title>”; compact tabs put that label
  immediately after #N so tail truncation preserves the provenance. Back returns
  to the fork. Source/Inspector parent navigation targets copied fork history;
  Inspector child navigation retains read-only provenance even after tab closure.
  A delayed Back rechecks its originating reader and the selected fork before
  focusing, so a newer main selection cannot be overwritten.
- Original reads validate the project’s trust/availability, reciprocal header and
  saved paths, then use saved history without attaching/opening a writable helper.
  Stop, send/steer, generic run actions, managed-child human commands and helper
  opens are blocked; retained footer callbacks check the same reader mode. Inspector
  capture reading remains available, with its fork/run actions unavailable. Missing
  parent/child/file/project, missing project folders and revoked trust leave labelled,
  disabled entries.
  The new tool availability cache is explicitly excluded from ToolView coding.
- Tree rows draw a faint guide at each depth. Non-main owners appear at the start
  of agent secondary text; complete owner/status/model/effort/cost remains in the
  tooltip and VoiceOver label. No transcript scan or Markdown parse occurs in layout.

### Failing first and mutation evidence

Logs and extracted result JSON are `<build root>/review9-<run>.*`. Runs use
`PI_BUILD_ROOT` and `TEST_RUNNER_PI_APP_SCRATCH_ROOT` with the required
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>` form. Serial classes run
alone. The initial fork UI regression lived in SubagentTranscriptTests, then moved
into the new serial InheritedSubagentReaderTests when Inspector/window coverage
was added. A fixture correction persisted parent metadata before discovery, as a
real saved family does; otherwise the fixture correctly appeared orphaned.

- `navigation-red`: 37 pass / 2 fail. Main/side return left content blank; a Side
  re-click discarded its still-owned load. Hosted hide/show recovery was a passing
  control. The strengthened test returns before the obsolete read completes too.
- `fork-red`: 24 pass / 2 fail. Open remained disabled and a fork's owned start
  incorrectly numbered itself 1 after a copied start.
- `query-red`: 41 pass / 1 fail. Actual `setQuery` could not finish after a reader
  hid and reappeared. The green test checks both main and hosted readers and that
  recovery does not reveal an old match.
- `recovery-reveal-red`: 42 pass / 1 fail. Automatic hydration displaced a newer
  explicit reveal. Recovery now waits for reveal/jump/version reads to finish,
  and tracks incomplete initial draft setup separately from already-readable rows.
- `affected-initial`: 295 pass / 7 fail. Six failures exposed recovery of displays
  that had never started an initial presentation (version rows and visible cost
  attribution). Recovery must own an abandoned initialization, not merely a
  dormant display. One older Source test simulated selection by changing a private
  counter; it now exercises an actual `select` while the coordination read waits.
- `audit-red3`: 44 pass / 2 fail. A Side already on screen incorrectly rejected
  Source from a popped-out child, and an in-memory presentation was reinitialized
  just by returning to Chats. `original-back-red`: 0 pass / 1 fail, with delayed
  Back stealing focus after another selection. The final reader class passes all
  46 tests, including an old initial read suspended across a newer explicit reveal.
  Original-reader Back is covered in the read-only fixture matrix. Reloading that
  fixture restores saved disclosure state; the unavailable-card checks explicitly
  expand the card again before asserting its disabled Open action.
- `reveal-read-red`: 45 pass / 1 fail. Extending the same recovery race to the
  report and conversation-search paths reproduced it in both. These paths now
  reserve and retire their existing reveal-read identity as the Find/Home path
  does. Recovery waits for all three destinations. `fork-side-action-red` failed
  the read-only matrix because the fork-scoped picker had lost New Side; its
  availability now follows the actual picker owner.
- `root`: 6 pass / 1 fail. The old VoiceOver expectation omitted the parent name;
  it now checks the required owner context ("in Parent").
- `project-availability-red`: 0 pass / 1 fail. A still-configured project with a
  missing folder incorrectly kept the original available. Reads now validate all
  original project roots as well as trust, configuration and saved journal paths;
  the complete original-reader matrix passes with that case included.
- Real-guard mutations: disabling visible recovery failed three reader tests;
  advancing the pane revision on a Side re-click failed two; removing the original
  reader Stop guard failed the live fixture's byte-identical source-journal check.
  All three mutations were restored before the final runs. Logs are
  `review9-mutation-{recovery,pane-intent,original-stop}.log`; exit codes are saved
  in `review9-mutation-status.json`.
- A fourth mutation removed the pending-destination exclusion from real recovery
  eligibility: 45 pass / 1 fail (`mutation-destination`). All 46 reader tests passed
  again after restoration (`reader-restored-final`).

### Renewed awaited-path audit (both ownership rules)

The grep inventory is `review9-navigation-await-audit.txt` (279 awaited sites). This table replaces the
round-8 interpretation of retirement; all its paths were rechecked. “Hydrate” below
means restart only the still-wanted initial presentation, never replay a retired
Source, reveal, version choice or coalesced jump. Existing readable rows remain
available when those one-off destinations retire. Every completion still checks
its token plus its own presentation/read identity before publication.

| Awaited path (under PiApp) | Retirement, recovery and visibility | Tests |
| --- | --- | --- |
| `Tabs/SubagentTab`: open, ensureLoaded, loadSubagentTab, attachment | Reader-local token; real hide/Back/close/new intent retire; visible dormant readers hydrate without focus; pane/window moves retain identity | SubagentReaderTests initial-load recovery (tab/pop-out), Back, move, close/reopen, hidden revalidation; SubagentPanelTests restore; SubagentOpeningTests attachment |
| `WorkspaceSelection`: select, loadSelectedChat, restoreShownSide, readInitialWindow | Main revision + selected slot + presentation; page return and canceled cleanup hydrate only a started presentation under fresh identity; no-op reselect keeps its load | Reader main/side return before/after completion, in-memory preservation and newer-reveal recovery; WorkspaceLoadingTests; WorkspaceConcurrencyTests; SideRelaunchTests |
| `WorkspaceSides`: selectSide/showSide, pending-side discard, loadSideDisplay | Workspace intent plus actual pane revision and mounted side; re-click/independent window does not retire; shown dormant side hydrates | Reader Side no-op/window, file-tab race, canceled side/reopen; SideTests |
| `SubagentFamily`: openFamilySide/openNewFamilySide | Delegates to guarded side opening; deferred new-side intent rechecks before/after parent selection; no old completion can reselect Side | Reader deferred-new-side and side/file tests; ConversationFamilyTests nested opening |
| `WorkspaceSubagents.openSubagent` | Local opening through header/discovery/tab/turn-message/reveal; superseded destination is not replayed; visible reader still hydrates | Reader newer-parent/Back; Opening header-tab race |
| `attachManagedSubagent` | Caller/local token and connection through header/open; original-reference mode never attaches | Opening live attachment/expiry; InheritedSubagentReaderTests helper-open guard |
| `WorkspaceAgentNavigation`: coordination lookup/Source/delivery/fallback | Origin token from first await through destination; retirement suppresses only the old navigation, retains displayed content | Reader lookup/four-stage Source/Back tests; SubagentNavigationTests |
| `WorkspaceSubagents`: Back/openSubagentParent/revealSubagentCall | Origin plus destination through helper, versions, anchor, version page, exact call; embedded side handoff explicitly transfers ownership; already-shown Side does not advance the expected pane revision; original Back rechecks selected fork before focus | Reader Source stages, side handoff, already-shown Side, Inspector origin and popped Back; InheritedSubagentReaderTests delayed Back; Opening standalone/family Inspector |
| `WorkspaceHistory.reloadHistory` | Token and presentation; canceled initial reload hydrates when visible, retaining requested reading anchor | Reader main history round trip; WorkspaceLoadingTests |
| `WorkspaceHistory`: loadHistoryPage/fillLiveGap/reacquireHistoryPositions/historyViewportReady | Local/main token and boundary/lineage; canceled boundaries clear only their flags; current viewport may request a fresh page; old queued position is never replayed | HistoryEdgeTests; HistoryExtentTests; Reader paging reset/retired coalesced destination |
| `TranscriptReveal`: revealInTranscript/readWindow/Home/drawablePage/jumpToHistoryPosition | Actual transcriptShows, token, presentation and request serial; a deliberate destination replaces the old destination; Find-owned reveals share its intent | TranscriptRevealTests; HistoryExtentTests; Reader popped reads, Back and 251-hit Find |
| `WorkspaceVersions`: showVersion/readVersionPage/latestVersion | Idempotent selection preserves pending load; new choice retires; first-page cleanup clears its cover using loadID; saved current page remains readable | Reader no-op version test and page round trips; MessageVersionTranscriptTests |
| `WorkspaceContent`: searchConversation/source and Find controller | Query task plus reader token; retirement suspends wanted queries, visible reader restarts without automatic reveal; changed query/close stays canceled | Reader actual setQuery retirement/recovery and 251-hit paging; TranscriptFindTests |
| `WorkspaceContent`: revealConversationHit/revealMessage | Token before await, pending reveal-read identity, unchanged source/presentation, actual visibility; recovery waits for the destination; external child only changes its local token; no stale reveal restart | Reader recovery race through transcript/report/conversation search, external reveal during main hydration, newer parent/Back; ReportMessageNavigationTests |
| `SidebarSearch` and `openFromSidebar` | Search/open identity plus reader token; popped window visibility independent of main page; retired hit selection is not replayed | Reader actual indexed popped hits on Chats/Reports/Background; SidebarSearchSidebarTests |
| `SessionInspectorModel` and `InspectorAgentCoordination`: linked requests/origins/Source/delivery | Inspector page + reader intent through lookup; original provenance persists across window/tab close and redirects parent navigation to fork | Reader Inspector-origin race; InheritedSubagentReaderTests; SubagentInspectorTests; SubagentSteeringInspectorTests |
| `WorkspaceLaunchSelection` / TabHost restoration | Existing launch selection owns ordinary loads; restored children use local tokens; no-op activation does not retire; original mode restored before load | SubagentPanelTests; SideRelaunchTests; InheritedSubagentReaderTests; TabHostTests/TabPaneTests |
| `InheritedSubagents`: copied plans, original header/history/accounting, optional message reveal | Caller/main or local reader token at every await; original availability rechecked before publication; visible retired load hydrates; no helper writer | InheritedSubagentReaderTests card/picker/restore/unavailable/bytes; Opening live original Stop/bytes; Discovery numbering |
| `conversationPage`, copy/export sheets, storage primitives | Data-only readers retain caller task/Inspector scopes; never focus or scroll; navigation uses the paths above | Existing conversation paging and Inspector suites in the full parallel lane |

Background discovery, metadata/accounting, draft/transaction recovery, file/Git
readers and request-detail reads retain their own transaction/connection/task
ownership. They do not publish a conversation location. Sub-agent tool, permission,
capture, vault and model-facing contracts stay unchanged.

### Gallery

Standalone SubagentPanelGalleryTests produced 12 images: eight in
`gallery-review9-original` (fork card plus original child tab, picker closed/open,
light/dark at 1240×800 and 920×600), and four in `gallery-review9-nested` (light/dark
at both sizes). Every image was opened and visually inspected. The main pill stays
left of the divider; popovers fit within the window. Narrow prose scrolls normally;
source provenance remains visible, and the child has no composer or Stop. The
nested picker keeps all six rows and footer visible with faint guides and explicit
side-owner labels. Each directory contains a manifest. The final original captures
also show New Side in the fork's own picker. Standalone SubagentForkGalleryTests
added 12 legacy missing-reference captures in `gallery-review9-unavailable`, with
pending/result cards in light/dark at widths 1240, 920 and 684 (height 600). All 24
final images were opened and inspected; disabled Open/Inspect remain inert across
appearance changes. The older 68-scene gallery
was intentionally skipped because its opt-in variable was not set.

### Final validation

Affected validation: **460 unique behavioral tests passed across 38 classes**,
zero failures. `review9-final-affected-counts.json` records the union by test
identifier, so repeated classes are not counted twice. Final run evidence:

| Run (`review9-<name>`) | Pass | Fail | Scope |
| --- | ---: | ---: | --- |
| `affected` | 302 | 0 | 30 affected parallel-lane classes |
| `reveal-family-final` | 82 | 0 | Latest reveal/picker changes, plus ContentSearch and ConversationSearchPaging |
| `reader-restored-final` | 46 | 0 | Serial SubagentReaderTests after the destination mutation was restored |
| `originals-availability-final` | 1 | 0 | Serial read-only original matrix, including missing project folder |
| `opening-restored` | 12 | 0 | Serial live loopback ownership, Stop, source bytes and fork budget |
| `navigation-restored` | 7 | 0 | Serial SubagentNavigationTests |
| `root-final` | 7 | 0 | Serial WorkspaceRootTests |
| `pane-final` | 81 | 0 | Serial ConversationPaneTests |

Standalone gallery classes: **3 passed, 1 intentionally skipped**, producing 24
inspected PNGs. Four real-guard mutations failed and were restored. No helper
package source changed, so no additional helper-package test run was needed.
XcodeGen regenerated the project; `git diff --check` passes. All data is generated,
and all gateway traffic uses loopback fixtures. No installed app, real preferences,
Keychain, paid provider, source-journal migration or cost accounting change.

The **one full native parallel lane passed: 2,541 passed, 37 skipped, zero failures**
(2,578 total). Its exact arguments are saved in
`review9-full-native-parallel-arguments.txt` (the lane script's serial exclusions,
four workers); its log and extracted summary/tests JSON use that same run prefix.
No second full lane was run. Round 9 has no known remaining implementation or
validation failures; lead review and integration remain with the lead.


## Lead review round 10: numbering, picker availability and plain labels

### Causes and changes

- Coordination filtered accepted starts by budget owner before assigning numbers.
  A fork's first owned child therefore became #1 after discovery had correctly
  assigned #2. Coordination now counts every unique accepted start, including
  copied starts (replayed records reserve no additional number), while separately
  filtering owned event/hold membership. The projection, display overlay and
  Inspector use the same ordinal;
  no original child is adopted and no source journal changes.
- Family availability checked membership without checking whether its main-column
  picker could open. Both menu validation and dispatch now resolve an available
  Chats picker or the active independent child window. A remembered child focus
  alone does not substitute for a visible picker.
- Older work headers and expanded response parts exposed reconstruction metadata
  that gave readers no action. The Work header now uses the ordinary activity/tool
  summary; old-response order disclaimers and part-order captions are removed.
  Missing completion says “Completion not recorded”; missing response detail says
  “Some response details are unavailable”. The human copy fallback heading is
  “Full saved response”, preserving the complete Markdown and diagnostic evidence.
  Opaque response sections say “Additional response data”; wait receipts translate
  settled/empty/timeout states and omit unknown internal reason codes.
- Original-reference Back labels name the destination fork and refresh when it is
  renamed. The compact label is bounded; tooltip and VoiceOver retain the complete
  destination and numbered child identity. The adjacent original-reader identity
  uses `#N · description`, keeping its number visible at narrow widths. Navigation
  behavior stays unchanged.

### Transcript wording audit

Searched all transcript source and its presentation/copy adapters for legacy,
canonical, part/arrival/delivery order, timing, evidence, terminal/receipt,
projection, hydration, replay, checkpoint, pending/unknown and raw state labels.
The saved pre-change grep is `review10-jargon-before.txt` in the stream build root.

| Surface | Disposition |
| --- | --- |
| Older Work header | Ordinary activity/tool summary instead of legacy/order caption |
| Older request-info detail | Removed order disclaimer |
| Missing timeline updates | Plain missing-details notice |
| Expanded response-part evidence | Removed delivery-order/arrival-timing captions |
| Execution without completion | “Completion not recorded” |
| Opaque response section | “Additional response data” |
| Wait receipt reasons | Plain finished/no-agents/wait-time wording; unknown codes omitted |
| Human copy fallback heading | “Full saved response”; saved source preserved |
| Original-reference header | “Back to <fork title>”; full destination in tooltip/VoiceOver |
| Missing text, partial history, unknown cost/tool outcome, pending delivery | Kept: these explain missing content, uncertainty or an available Resume action |
| Raw journal keys, model/tool text, request evidence, identifiers, comments, user prose | Unchanged: not app-authored transcript chrome |

### Failing-first and final evidence

The initial failing runs reproduced the production behavior before each fix:

| Run (`review10-<name>`) | Pass | Fail | Reproduction |
| --- | ---: | ---: | --- |
| `red-projection` | 25 | 2 | Fork child renumbered #1; legacy request-info disclaimer |
| `red-menu` | 46 | 1 | View/Conversation family commands enabled on Reports and Background |
| `red-original` | 0 | 1 | Generic Back to Parent instead of the destination fork |
| `red-native-words` | 27 | 2 | Legacy Work caption and terminal-receipt wording |
| `red-copy` | 3 | 1 | Canonical/order heading in copied saved response |
| `red-menu-key-reader` | 46 | 1 | Stale external-child focus enabled the covered main picker |
| `red-expanded-labels` | 29 | 1 | Opaque/order captions in expanded response parts |
| `red-compact-and-wait` | 16 | 2 | Long fork title exceeded a 320-point header; internal wait reasons |
| `red-header-number` | 7 | 1 | Named Back squeezed out the original child's number in a narrow header |

Real production mutations, each rejected and restored:

- `mutation-ordinal`: count only owned starts again. SubagentDiscoveryTests failed
  the fork projection/display/Inspector regression (13 passed, 1 failed).
- `mutation-ownership`: admit every numbered child to the owned coordination set.
  The same class failed its foreign-event/hold exclusion (13 passed, 1 failed).
- `mutation-picker`: remove the Chats-page guard. SubagentReaderTests failed actual
  View/Conversation menu validation and dispatch checks (46 passed, 1 failed).

Every run uses `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`
and `scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Serial-lane classes
run alone. Logs, exact arguments and extracted summary/tests JSON use the run
prefixes above in that build root; no named result bundles are retained.

Final affected validation: **320 unique tests passed across 18 classes, five
existing skips, zero failures**. `review10-final-affected-counts.json` records the
union by test identifier, avoiding double-counting repeated classes. Final evidence:

| Run (`review10-<name>`) | Pass | Skip | Scope |
| --- | ---: | ---: | --- |
| `green-projection` | 150 | 5 | Thirteen affected projection, display, Inspector, family, fold and native parity classes |
| `final-reader` | 47 | 0 | SubagentReaderTests alone; actual View/Conversation menu validation and dispatch |
| `final-timeline` | 30 | 0 | TranscriptNativeTimelineBehaviourTests alone; expanded parts, warnings and Work summary |
| `final-pane` | 81 | 0 | ConversationPaneTests alone |
| `final-projection` | 77 | 0 | Eight affected classes after the wording/compact-button refinements |
| `final-row-parity` | 24 | 2 | Native/reference rows after removing order captions |
| `final-header` | 8 | 0 | SubagentDisplayTests after preserving the narrow original identity |
| `final-original-header` | 1 | 0 | InheritedSubagentReaderTests alone; original read-only matrix and named/renamed Back |

The five skips are existing opt-in calibration sweeps and probes. No full native
lane was run this round, per the affected-classes-only instruction. No helper
package source changed, so no helper-package run was needed. The three mutation
checks above were all restored before final validation.

### Gallery and boundaries

Standalone gallery validation passed **three tests, zero failures, two intentional
opt-in skips**. All **20 final PNGs were opened and visually inspected**:

- `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-review10-original`:
  eight original-reference card/reader captures, picker closed/open, light/dark,
  1240×800 and 920×600. Back names the fork; the compact child number remains
  readable; provenance remains visible and popovers stay within the window.
  Final run: `review10-gallery-original-final` (one pass, two unrelated opt-ins skipped).
- `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display/gallery-review10-rows/screenshots`:
  twelve native transcript captures covering Work, expanded response parts,
  compact/expanded turns, stopped replies and saved-response warnings in light/dark.
  The added `23-saved-response-details-*` scenes show the plain labels and retained
  Request details action. Run: `review10-gallery-rows` (two passes).

XcodeGen regenerated the project; `git diff --check` passes. All fixture and gallery
data stayed in this stream's build root or isolated test scratch directories.
Journal bytes, model/tool text, ownership, Stop authority, permission, capture,
vault and accounting boundaries are unchanged. Raw request diagnostics remain raw;
only app-authored transcript labels and the human copy fallback heading changed.
No installed app, real preferences, Keychain or paid-provider calls were used.
Round 10 has no known remaining implementation or validation failures; independent
lead review and integration remain with the lead.

## Lead review round 11: live Find and integration

### Cause and change

Rendered Find uses the app's Markdown projection of saved history, so it reads the
journal directly even while its helper is running. Both the full index build and
the final search stamp guard required an unchanged file. A normal message,
tool-result or run-state append therefore became `unreadableRecord` and the actual
`TranscriptFindController.setQuery` pipeline displayed “Search failed”.

Each rendered search page now captures the descriptor's size before indexing. The
index stops at that byte boundary and uses only complete records; a pending last
line remains untouched. Before publishing, any stamp change requires a full-prefix
SHA-256 match, plus descriptor/path identity and non-truncation. Growth does not
retry or chase the writer. Exact-stamp prefix hashes share the existing eight-index
LRU; no transcript bodies or duplicate journals are retained. Parsing and bounded
64 KiB hash reads stay on the history actor, with cancellation checks. A malformed
newest completed run-state record takes precedence over a later incomplete tail.

Rendered tasks/results/reports, streaming replacements, unsaved rows, abandoned
branch exclusion and paged source Copy retain their existing rules. Source/copy
searches and copy pages retain strict revisions. Navigation tokens, journals,
model-facing text, permissions, capture, vault and cost accounting are unchanged.

### Failing-first evidence

All run prefixes below are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-sub-display`; each has a log, exact
arguments and extracted result JSON. Native runs use the required
`PI_BUILD_ROOT=… scripts/test-macos.sh -only-testing:PiAppTests/<Class>` invocation.

| Run (`review11-<name>`) | Pass | Fail | Reproduction |
| --- | ---: | ---: | --- |
| `red-append` | 4 | 1 | Normal append rejected by storage search |
| `red-live-find` | 16 | 1 | Actual `setQuery` reports Search failed during a running chat |
| `red-boundaries` | 5 | 2 | Appends rejected; an in-flight trailing record rejects all Find results |
| `red-tail-damage` | 6 | 1 | An incomplete tail masks a damaged newest completed state |

The live test searches 121 rendered deliveries across two result pages, with
deterministic writes after capture, after indexing and before publication. Its final
matrix uses an assistant message, tool result and actual sorted native state record.
Storage tests additionally assert the captured total, a subsequent search seeing
new records, original bytes unchanged, incomplete-tail completion, damaged complete
records, an in-place rewrite outside both 64 KiB edge windows plus growth, truncation
and atomic path replacement.

Real production mutations were rejected and restored before continuing:

- `mutation-append`: restoring strict file-stamp equality fails the actual
  controller's live Find regression (16 passed, one failed).
- `mutation-prefix`: omitting the full-prefix check admits a middle-of-file
  rewrite plus growth (six passed, one failed).
- `mutation-path`: omitting current-path identity admits atomic replacement
  (six passed, one failed).

Pre-merge affected search/history checks passed 57 tests with one existing skip;
the native Markdown/Find class passed all 17. After the tail-validation refinement
and restored mutations, `premerge-search` passed all 11 ContentSearch/StateTail
tests and standalone `premerge-live-find` passed all 17 again. The integration
and final native lane are recorded below after merging `origin/dev/next`.

### Integration

Merged fetched `origin/dev/next` at
`bd9a1a94769897ebfc7e1263ba5f38039baf7f95`, retaining the queue-edit work
(`152725f0`) and sub-agent prompt-cache fix (`bd9a1a94`). Existing release commit
identities are preserved. Conflicts and resolutions:

- `NEXT-RELEASE.md`: retained every item from both branches.
- `fixtures/native/litellm_contract.py`: retained shared object constraints for
  effort unions and incoming support for one valid `oneOf` branch. Both schema
  validation and argument validation still require the intended object shape and
  exactly one matching branch. Removed a duplicate test import from the automatic
  merge and updated the older test's now-obsolete two-branch minimum assertion.
- The project file merged automatically and was regenerated with XcodeGen.
  SessionDisplay, WorkspaceRefresh and WorkspaceRun merged without conflicts;
  hosted-reader behavior and the new queue notice/acknowledgement logic are retained.

The first merged gateway run caught the outdated single-branch rejection (23
passed, one failed). After updating that assertion while retaining its shared-field
checks, `review11-gateway-final.log` records **24 passed, zero failures**.

`review11-helper-affected.log` records **291 affected helper tests passed, zero
failures**, including all four SubagentCacheTests, steering/family, ordinary pi
parity, routing, request context, provider streaming, capacity and compaction.
`review11-helper-affected-arguments.txt` records the exact `swift test` command,
using this stream's existing release scratch directory with three jobs.

The actual rebuilt helper's generated loopback workflow also passed: **26 requests,
22 prefix comparisons, zero breaks**. Existing prompt prefixes with unchanged
request settings are fully retained. These are fixture measurements, not claims
about upstream provider cache hits. Evidence:
`review11-cache-loopback.log` and `cache-review11-integrated/{summary.json,measurements.json,measurements.md}`.
No new helper behavior or model-facing text change was introduced by this merge
resolution; the incoming, authorized prompt-cache implementation is preserved.

### Final affected native validation

**314 unique tests passed across 21 affected classes, one existing opt-in skip,
zero failures.** `review11-final-affected-counts.json` records the union by test
identifier. Serial classes ran alone; the refreshed lane inventory is saved as
`review11-lanes.txt`.

| Run (`review11-<name>`) | Pass | Skip | Scope |
| --- | ---: | ---: | --- |
| `affected-parallel` | 139 | 1 | Fifteen search, history, queue presentation/refresh, discovery, model-grant and effort classes |
| `affected-markdown` | 17 | 0 | SubagentMarkdownTests, including actual live `setQuery` pagination |
| `affected-reader` | 47 | 0 | SubagentReaderTests |
| `affected-original` | 1 | 0 | InheritedSubagentReaderTests matrix |
| `affected-opening` | 12 | 0 | SubagentOpeningTests with the rebuilt helper |
| `affected-queue` | 17 | 0 | QueueEditInteractionTests |
| `affected-pane` | 81 | 0 | ConversationPaneTests |

The skipped HistoryIndexFiles test is its opt-in large-journal measurement. This
round adds no UI text/layout change and no gallery scene; round 10's inspected
gallery remains the display baseline. The queue-edit branch's existing gallery
and validation record are retained by the merge.

### One full native parallel lane and handoff

The **one full native parallel lane passed: 2,561 passed, 38 skipped, zero
failures (2,599 total)**. It ran after all affected classes, with four workers
and the current lane script's serial exclusions. Exact arguments are in
`review11-full-native-parallel-arguments.txt`; the log and extracted summary/tests
JSON use the same prefix. No second full lane was run.

`git diff --check` passes. XcodeGen regeneration retained both branches' source
and test membership. All tests used generated fixtures, MemoryVault/isolated test
storage and loopback gateways; no installed app, real preferences, Keychain,
paid-provider calls or `xctrace --launch` were used. Builds, logs, retained fixture
evidence and the automatically named latest result bundle stayed in this stream's
own build root; disposable test data used isolated fixture scratch directories.
No named result bundles or source-journal migrations were introduced.

The Find fix was committed separately before the merge. The merge preserves
existing upstream commit identities and incorporates its queue-edit and prompt-cache
behavior without additional helper changes. Round 11 has no known remaining
implementation or validation failures. Lead review and integration into `dev/next`
remain with the lead; only `dev/a128-sub-display` is pushed.

## Lead review round 12: focus-independent reader publication

Scope: the two round-12 findings and an app-wide audit of global focus/main-page
checks reachable from hosted-reader async navigation. Same stream branch and
build root, generated journals and isolated native tests. No helper, tool,
model-facing text, cost accounting, journal format or UI layout change.

### Causes and changes

- `openSubagent` checked `focusedSessionID` after tab loading and after the saved
  turn lookup. Focusing an already-visible main pane changed that global value
  without retiring the independent child. Both checkpoints now require the
  opening's reader token and actual tab visibility; the second also checks tab
  identity. Earlier-turn opening, lookup and reveal complete without changing
  subsequent focus or the key window. A narrow optional lookup seam delays the
  real read-only `HistoryReader.subagentTurnMessage` in tests; production still
  calls that reader directly.
- Original-reference Back skipped selection when its fork was already selected,
  leaving Reports/Background over the destination. That branch now restores Chats
  explicitly, then validates the origin token, selected fork and `transcriptShows`
  before focusing. It preserves the fork's reading position and ready presentation.
- The audit found the same publication mistake in `openSubagentParent` and the
  main/side branch of `revealMessage`, both reachable through a child's Source or
  delivery link. They now retain a `TranscriptNavigationToken` with the originating
  child token and the destination's expected main revision, plus actual destination
  visibility. Genuine destination changes and Back still retire the chain.
- A further delayed-initial-parent test exposed a focus assignment after selection
  completed. Focus transfer now occurs only when selection's focus is still held;
  this condition never rejects history or a reveal. A newer focus choice survives
  while the still-owned content publishes.
- The design's Reader navigation ownership section explicitly distinguishes
  focus-only callbacks from content publication, and documents Back from an
  original-reference window to a fork behind Reports/Background.

### Failing-first and mutation evidence

All logs/arguments/result JSON are under the stream build root with the
`review12-` prefix. The runner uses `PI_BUILD_ROOT`, isolated
`TEST_RUNNER_PI_APP_SCRATCH_ROOT`, and the required
`scripts/test-macos.sh -only-testing:PiAppTests/<Class>` form. Serial classes run
alone. Result bundles are automatically named; summaries are extracted before
the next run. The first compile caught a Swift sendable loop capture in the new
test; an explicit immutable capture fixed the fixture before behavioral runs.

| Run | Passed | Failed | Evidence |
| --- | ---: | ---: | --- |
| `red-readers` | 47 | 2 | Earlier-child opening drops both presentation/turn-lookup completions; issuing-call and delivery parent destinations drop valid reads after focus moves |
| `red-original` | 1 | 1 | Back leaves the already-selected fork behind both Reports and Background |
| `green-readers` | 49 | 0 | Initial fixes pass the complete reader lifecycle class |
| `green-original` | 2 | 0 | Original-reference lifecycle and new page-return matrix pass |
| `mutation-focus` | 47 | 2 | Restoring all four real global-focus publication checks reproduces both reader regressions |
| `mutation-back` | 1 | 1 | Removing the real Chats restoration reproduces the Back failure |
| `red-initial-source` | 47 | 2 | The added initial-parent case proves the late focus overwrite; the other failure was a new test assuming its window became key in the test host |

The native-window check now captures the actual key window before completing the
read and verifies it remains unchanged; it does not assume the test host grants
activation. The focused conversation assertion separately verifies the user's
main-pane decision. Both mutations were restored before final validation.

### Global focus/page audit and navigation paths

The app-wide search is recorded in `review12-global-guards.txt`; the async
open/reveal/history/source/search inventory is `review12-async-paths.txt`. The
post-fix search is `review12-global-guards-final.txt`. Search expressions:
`focusedSessionID|page\s*(==|!=)` and `async|Task |await`, across `PiApp` and the
navigation/Inspector files respectively. The first inventory also includes
unrelated synchronous UI, composer, organization and report state, so the
dispositions below distinguish those from hosted content publication.

| Path / matching guard | Ownership and disposition | Behavioral coverage |
| --- | --- | --- |
| `WorkspaceSubagents.openSubagent`: header, discovery, open/load, turn lookup, reveal | Reader token before any await; identity + `subagentTabIsShown` once mounted. Removed both global focus guards. | `SubagentReaderTests.testEarlierChildTurnOpeningSurvivesMainFocusDuringEveryRead` gates presentation, saved turn lookup and off-page reveal; `SubagentOpeningTests.testCardHeaderValidationDoesNotOverrideANewerTabChoice` |
| `backToSubagentParent`: original-reference branch | Restore Chats for an already-selected fork; origin token + selected destination + `transcriptShows` after an awaited selection. This page assignment intentionally navigates the main window. | `InheritedSubagentReaderTests.testOriginalWindowBackRestoresChatsForTheAlreadySelectedFork`; existing full original-reader matrix rejects a delayed Back after newer selection |
| `openSubagentParent` / `revealSubagentCall` | Main destination token carries child origin through selection, helper/versions, anchor and history reads. Removed focus predicate; main page arithmetic only accounts for the intentional Chats transition. | New `testChildSourceDestinationIgnoresFocusChangesDuringParentReads`; existing `testEmbeddedBackRetiresEveryStageOfAParentSourceReveal`, `testNewRevealInPoppedChildRetiresItsAwaitingBackToParent` |
| `WorkspaceAgentNavigation.openAgentSource` / `showAgentSource` | Coordination lookup captures reader/main intent, then passes originating child through the destination chain. No global focus/page publication guard. | `testEmbeddedBackRetiresAnAwaitingAgentSourceLookup`, `testParentSourceRetiresAnOlderParentReadBeforeAwaitingItsVersionLookup`, side-transfer tests |
| `WorkspaceContent.revealMessage` | Hosted branch returns before main selection logic; reader token + visibility govern the child. Main destination now uses its token + origin + `transcriptShows`, including source delivery. The remaining focus comparison only controls a focus assignment, never whether content publishes. | New Source test includes an initially unloaded parent selected from another main chat; `testBackSupersedesShowInChatWithoutMovingTheStillVisibleReader`, `testNewParentMessageNavigationRetiresAnAwaitingChildReveal`, `ReportMessageNavigationTests` |
| `revealConversationHit`, `TranscriptReveal` reveal/readWindow/Home/position/drawable-page paths | Reader/main token and `transcriptShows`, with presentation/read identities. The `.chats` check lives only in the main/side branch of the shared visibility predicate; external readers bypass it. | `testPoppedOutHistoryReadsSurviveUnrelatedMainNavigation`, `testBackRetiresAnAwaitingRevealInTheVisibleChild`, `testMainHistoryOperationsRetireAcrossPageRoundTrips`, `testRetiredPositionReadDoesNotRestartItsQueuedDestination` |
| `WorkspaceHistory` reload, initial/source-handoff, viewport-ready, earlier/newer pages, live gap and position reacquisition | Reader token and presentation identity; viewport/reveal work uses actual visibility. Initial content can fill its still-owned mounted slot before viewport readiness. No global focus/page guard. | Reader hide/show recovery, hidden-history reopen, paging reset, move/close/reopen and main page round-trip tests |
| `WorkspaceVersions` show/read/latest | Async publication uses intent + actual transcript visibility. `stepVersion`'s optional focused-session fallback selects a command target synchronously, not after an await. | `testNoOpVersionSelectionKeepsItsPendingPage`, Source version-stage tests, `SubagentNavigationTests` |
| `WorkspaceContent.searchConversation` / Find | Search pages retain reader/main token; query/reveal tasks own cancellation. No global focus/page guard; Find's own reveals do not renew its query token. | `testFindKeepsPagingWhileItsAutomaticAndNextMatchesReadOtherPages`, `testVisibleReadersRestartTheirRetiredFindQueryWithoutRevealingAnOldMatch` |
| `SidebarSearch.revealSidebarSearchHit` / `openFromSidebar` | Hosted branch checks reader identity/token/visibility and returns before the fallback's main Chats/focus guard. Retained fallback applies only to an ordinary main/side opening. Search/open identity also remains current. | `testSidebarContentHitRevealsInPoppedOutChildOnEveryMainPage`, opening tests |
| `SubagentTab` open/ensureLoaded/load/attachment | Reader-local intent, actual host visibility and presentation identity. `.chats` gates embedded visibility only. `canRestoreFocus`, `focusIfAttached`, hide and close retain focus-only checks; they cannot reject a history result. | Initial-load Back, newer-tab choice, native responder transition, independent-window menu, attachment and moved-reader tests |
| `WorkspaceSelection.resumeVisibleReaders`, main/side initial loading, `WorkspaceSides`, `SubagentFamily` | Recovery visits independent child windows before its main-only Chats guard. Ordinary sides retain main/pane intent; the side's focus comparison only requests composer focus. The family command's Chats gate runs after its independent-window branch. | Retired main/side/child recovery, Side no-op/independent-window, side-open handoff and family-command availability tests |
| `InheritedSubagents` open/load | Trust/header/history/accounting reads retain the original reader token and presentation, with no global focus/page guard. No helper attachment or source writes. | Original-reader matrix, including read-only menus, restore, missing originals and byte-identical source journals |
| Inspector linked-message/origin/source/delivery routes | Navigation tokens survive lookup and transfer into shared open/reveal functions. `SessionInspectorModel.page == .request` checks the Inspector's own page, not the main window. Metadata-only coordination uses its Inspector task scope. | `testInspectorParentSourceRetainsTheOriginatingReaderThroughItsVersionRead`, `SubagentOpeningTests.testBackAndStandaloneInspectorFindTheIssuingCallAfterAnAncestorEdit`, original-reader Inspector matrix |
| Launch restoration, chrome, menus and other grep matches | `reopenReport` restores the main page only; remembered-side focus checks restore its composer. Menu/UI availability uses key-reader ownership. Run/edit/delete/composer, unread, project choice, automatic-context, organization and report-rendering checks are not hosted history publication. Pure copy/export/storage readers keep caller-owned task/clipboard scope. | Existing restore, key-reader menus, no-human-composer, read-only and original-reader matrix coverage; these guards are unchanged |

### Final affected validation and handoff

The restored final implementation passes **79 unique native tests in five affected
classes, zero failures and zero skips**. Counts are recorded in
`review12-final-counts.json`; each run also retains its arguments, log and extracted
summary/tests JSON under the stream build root.

| Final run | Class | Passed |
| --- | --- | ---: |
| `final-readers` | SubagentReaderTests | 49 |
| `final-original` | InheritedSubagentReaderTests | 2 |
| `final-opening` | SubagentOpeningTests | 12 |
| `final-navigation` | SubagentNavigationTests | 7 |
| `final-reports` | ReportMessageNavigationTests | 9 |

The four serial classes ran separately; the report class ran on its own as well.
No full native lane or gallery was run for round 12, as requested: there are no
visible text/layout changes. No helper package changed, so no helper suite was
needed; the opening class exercised its generated loopback helper fixture.

`git diff --check` passes. Tests used this stream's build root and isolated test
storage, generated journals, MemoryVault and synthetic/loopback services only.
No installed app, paid-provider calls, real preferences, Keychain, named result
bundles or `xctrace --launch` were used. Source journals and model/tool contracts
are unchanged. No implementation or validation failure remains in this round;
the independent lead review and integration remain with the lead. Commit/push
scope is only `dev/a128-sub-display`.
