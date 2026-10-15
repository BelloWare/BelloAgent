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
