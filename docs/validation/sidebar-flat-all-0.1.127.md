# 0.1.127: one global Topics / Flat sidebar

Workstream `dev/a127-flat-all`, based on `2472ace641986627db43386a155bb3a5a414899d`
(after 0.1.126). This branch is committed and pushed separately; no merge or push
to `dev/next`, release packaging, or publication.

Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-flat-all` (called
`$BUILD` below). Native tests use the separate `com.belloware.PiAppTests.Host`
identity, scratch data and MemoryVault/loopback fixtures. The isolation guard and
`TestHostIsolationTests` pass. No installed app, real preferences, Keychain,
paid provider, or `xctrace --launch` is used. Text logs under `$BUILD/logs` are
the evidence; no named result bundles are created, and automatic `.xcresult`
bundles are removed after extracting the text summaries.

## Behavior and implementation

- The sidebar header's existing Projects title opens a Pi menu with one global
  Topics / Flat choice, Show Archived Chats and Projects. View > Show Chats
  shares the same checked choices. Project menus no longer contain view choices.
- Flat has one cached tree across every listed project, including No project and
  retained unavailable projects. It uses the existing family activity ordering,
  pins, archive section, paging, search/snippets, selection, row states, side
  folds and managed-child groups. Rows retain their actual project ownership;
  unavailable chats keep their existing read-only opening behavior. Flat has
  neither drag sources nor drop zones.
- Every Flat chat row carries its project and, when present, its own topic tag.
  Transient sides inherit their topic as before. Pi badges occupy a compact
  metadata line so both fit at minimum sidebar width without displacing titles
  or Archive controls. VoiceOver row labels include the tags; menu identifiers
  include `sidebarView-topics`, `sidebarView-flat` and
  `sidebarProjects-<id>-<action>`.
- New Chat resolves the focused/selected chat's trusted configured project,
  selected workspace, remembered workspace, then the first trusted project.
  A transient focused side falls back to its selected parent. Trust and
  availability are rechecked after the asynchronous defaults read. The header
  and File menu use the same enabled state. Projects retains New Chat, New
  Topic, Changes and History, and Manage/Configure actions with existing
  availability rules.
- The desktop store keeps global mode and combined page counts in
  `sidebar-view/main`; explicit Topics overrides legacy Flat. Any valid legacy
  project record with `flatTopics == true`, including an unlisted project,
  seeds Flat only before a global choice exists. Legacy records still decode.
  Writes coalesce and join the existing quit/update flush. Field-level intent
  merging protects early choices, late restores, concurrent page changes and
  stored revision floors. Failed writes report an error and retry on flush.
- Topics keeps its project/topic row structure and geometry. Combined trees
  reuse the sidebar index; project/topic name lookups are built once per pass.
  The empty-project cache invalidation from `03d94103` remains intact, and an
  entirely empty sidebar retains the existing Add Project screen.

Implementation choices beyond the owner decisions: keep pins ahead of the
activity-sorted families and archived chats in their existing separate section;
start top-level Flat New Chat at the chosen project's root topic; use the
existing Projects title as the menu face to preserve Topics pixels; keep the
footer archive control; show the existing explanatory note for No project's
submenu because scratch chats have no project actions.

## Failing-first and mutation evidence

| Log in `$BUILD/logs` | Result before the corresponding repair |
| --- | --- |
| `flat-red.log` | Original per-project implementation: 19 selected tests, 14 failed methods / 41 assertions. Covers global mode/migration, combination, tags, menus, New Chat, search/archive and row behavior. |
| `races-red-2.log` | Three regressions fail with seven assertions: a late restore loses pages, a pre-restore choice overwrites stored pages/revision, and New Chat creates after its project disappears. |
| `view-menu-red.log` | The new native menu test fails against the original application menu because Show Chats is missing. |
| `empty-flat-red.log` | No-project Flat fails at the duplicate empty list; configured empty projects pass and retain No chats yet. |
| `mutation-order-new-chat.log` | Reversing activity order and preferring the first project over the selected chat's project are both rejected: two failed methods / three assertions. Both mutations were restored before green validation. |

The initial race-test attempts `races-red.log` and `early-choice-red.log` stopped
at a Swift concurrency error in the new gallery timer closure; they are not
behavioral failure evidence. The capture helper was corrected before the
recorded failing run above.

## Native validation

Each command uses `PI_BUILD_ROOT=$BUILD scripts/test-macos.sh` with the requested
`-only-testing:PiAppTests/<Class>` arguments. Lane classification was checked
with `python3 scripts/test-lanes.py list` and saved to `logs/test-lanes.txt`.

| Run | Passed | Failures |
| --- | ---: | ---: |
| `affected-parallel.log`: PiMenu, SidebarAppearance, SidebarDocumentRegression, SidebarFlatTopics (then 23), SidebarMultiSelection, SidebarScalePerformance, SidebarSearchSidebar, SubagentOrganization, TopicSidebarPresentation | 75 | 0 |
| `final-flat-launch-scale.log`: SidebarFlatTopics (then 28), LaunchSelection (20), SidebarScalePerformance (4) | 52 | 0 |
| `empty-flat-green.log`: final SidebarFlatTopics class | 29 | 0 |
| `serial-TestHostIsolationTests.log` | 3 | 0 |
| `serial-NativeApplicationTests.log` | 11 | 0 |
| `serial-ProjectSidebarTests.log` | 8 | 0 |
| `serial-SidebarNativeBindingTests.log` | 5 | 0 |
| `serial-SidebarRowDragTests.log` | 4 | 0 |
| `serial-SidebarDropZoneTests.log` | 6 | 0 |
| `serial-SidebarInteractionTests.log` | 9 | 0 |
| `serial-SidebarSearchTypingTests.log` | 2 | 0 |
| `serial-TopicOrganizationTests.log` | 14 | 0 |

All nine serial classes ran alone: **62 passing tests**. The final Flat class
has 29 tests (previously 14), including actual menu actions, persisted migration,
late restore/write overlap, async project removal, retained-history opening,
minimum-width tags, archive confirmation, message search and exact Topics
round-trip pixel checks in both appearances.

The first complete parallel lane, eight workers (`full-parallel.log`), ran
2,380 tests: **2,344 passed, one failed, 35 skipped**. The single failure was
unchanged `PastedAttachmentTests.testCleanupDoesNotHoldRestorationOrMetadataReads`:
its ten-second `cleanup started` predicate expired before the utility scan
entered. The failure messages and counts were exported to
`full-parallel-summary.json`. The entire unchanged six-test class then passed
three repetitions (**18/18**) alone in `pasted-cleanup-recheck.log`. The next
utility-scan test on that original clone passed but took 60.195 seconds. A
read-only review found no new semantic path skipping the scan: the reference
inventory check affected by concurrent store writes occurs only after the scan
returns. This suggests load sensitivity; the exact cause is not established.

The complete four-worker repeat (`full-parallel-four-workers.log`) also ran
2,380 tests: **2,344 passed, one failed, 35 skipped**. The cleanup regression
passed. This run found a fixture assumption in
`SessionMarkUnreadTests.testTheMenusOfferMarkAsUnreadForAReadChatAndMarkAsReadOtherwise`:
it marked the selected chat failed, but `markRunFailed` correctly suppresses
that mark when the host is active. The expected two unread rows therefore
became one. The unchanged class passed **33/33** alone
(`mark-unread-recheck.log`). The fixture now selects the other chat before
marking it unread, then marks the intended out-of-view failure and asserts
that setup explicitly; production behavior and the existing assertions are
unchanged. Fixed class: **33/33**, zero failures
(`mark-unread-fixed-2.log`). The first repair attempt moved focus after the
manual mark and cleared it; `mark-unread-fixed.log` records that rejected
fixture ordering.

Final complete four-worker lane (`full-parallel-final.log` and
`full-parallel-final-summary.json`): **2,344 passed, one failed, 35 skipped**.
Both earlier failing classes passed. The unchanged
`TranscriptRevealTests.testRevealingAMessageInTheWindowLandsOnIt` expired its
ten-second `The message never landed` predicate (19.909 seconds including
setup). Its fixture mounts a conversation pane without the sidebar and had
passed in both earlier full runs. The entire unchanged ten-test class then
passed three isolated repetitions: **30/30**, zero failures
(`transcript-reveal-recheck.log`). The precise cause is unconfirmed.

All three full-lane commands selected every parallel test using
`python3 scripts/test-lanes.py parallel`; no classes were omitted or moved
between lanes. **No clean full-native gate is claimed.** The requested sidebar
checks and complete gallery are green; the cleanup-start and transcript-reveal
failures remain evidence for the broader native-test follow-up.

## Performance

`SidebarScalePerformanceTests.testCombinedFlatBuildCostAndIndexReuse` uses 540
chats across three projects and nine topics, 30 invalidated list builds per
mode. In the targeted Debug run (`final-flat-launch-scale.log`):

| Mode | Median cold list build | Maximum |
| --- | ---: | ---: |
| Topics | 9.258 ms | 10.075 ms |
| Flat | 8.337 ms | 8.982 ms |

Twenty unchanged builds/order reads reuse the cached tree; one streamed delta
rebuilds at most one row. Empty-to-populated and retained-group changes invalidate
correctly. These measure list construction and update work, not the full launch
path; they are not directly comparable to the historical approximately 255 ms
soak sidebar-listing metric. No hour-long soak or new whole-launch benchmark is
claimed for this workstream.

## Gallery and review

Full gallery: **3/3 tests passed**, zero skips/failures, 582.074 seconds. It ran
alone with both `PI_APP_UI_SCREENSHOT_ROOT` and
`TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT` set to `$BUILD/gallery-final`, selecting
the complete `UIScreenshotTests` class. It produced **408 captures**: 224 in
`$BUILD/gallery-final/screenshots`, 92 in `gallery-final/subagents`, and 92 in
`gallery-final/steering`. The separate root PNG is fixture input, not a capture.
Logs: `gallery-final.log` and `gallery-final-summary.json`.

New scenes cover combined Flat and the actual open header menu, both appearances
at normal 1440 x 900 and narrow 920 x 600 windows:

- `14f-sidebar-flat-all-{normal,narrow}-{light,dark}.png`
- `14g-sidebar-header-menu-{normal,narrow}-{light,dark}.png`

Baseline `$BUILD/gallery-before/screenshots` contains 24 captures from the old
implementation, including both `01-main` appearances. That baseline gallery was
interrupted after those captures; it is not a complete successful gallery run.
An earlier attempt without the XCTest environment prefix skipped the gallery.

Visual review completed for all eight new captures: both project/topic badges
remain visible at the 200-point minimum sidebar width, with normal truncation;
parent/side indentation, paused/unread states, recency tint, No project and
retained-project tags are clear. All four actual header-menu images show the
checked global choice, archive action and Projects submenu without clipping.

Also viewed both appearances of unchanged `14-sidebar-topic-marks`,
`14b-sidebar-narrow` and `14c-sidebar-archive`, and compared old/current
`01-main` sidebar crops side by side. The static header rectangle
`(24, 80, 576, 210)` in the 2x captures has **zero differing pixels** in both
themes. The broader main-scene differences are the synthetic folder name and
generated throughput value; row layout, colors and footer are unchanged in
the reviewed images. This is not a whole-gallery byte-equality claim.
Comparison notes: `logs/topics-image-comparison.txt`; reviewed crops/pairs:
`$BUILD/gallery-review`. The initial review missed the checked-icon alignment
and retained-tag abbreviation corrected in the follow-up below.

Read-only Codex gpt-6.1-sol xhigh planning and reviews covered the whole diff.
Two persistence races and the duplicate empty state were repaired with failing
tests. Final whole-change review: **no findings**; advice was to finish the full
parallel lane, verify all eight new captures, and compare Topics with the old
captures. VoiceOver labels/roles are checked by native tests; no manual
VoiceOver session is claimed.

## Owner gallery polish follow-up

Follow-up to `0080a567`, scoped to the two owner findings in 14f/14g. Lead
inspection confirmed the missing checked icon and the misleading retained
caption. The shared menu builder was discarding a checked item's symbol; the
old per-project menu used the same builder and had the same suppression. It now
keeps the original symbol and `NSMenuItem.state`, so AppKit draws the checkmark
in its separate leading column without shifting the icon or title. This also
keeps the archive symbol when Show Archived Chats is checked.

Unavailable project tags now read **Retained chats**. Their tooltip and row
accessibility label retain `Retained chats · <entire project ID>`, including
on transient sides. This uses project availability rather than matching a name
prefix, so a configured folder called “Retained chats · local” is unchanged.
The per-pass project lookup builds the short and full strings together; no
per-row scan was added. Topics group names and layout stay unchanged. The
shared Pi badge already draws overflowing text with an end ellipsis; no badge
renderer change was needed.

Affected native commands use the same `$BUILD` and isolated test host, with
`-parallel-testing-enabled NO`. The serial application-menu class runs in its
own invocation. No full lane, unrelated classes or full gallery were rerun.

| Log in `$BUILD/logs` | Follow-up result |
| --- | --- |
| `polish-red.log` | Before the fix, all three selected regressions fail: 17 assertions across checked icons, the header choices and retained parent/side captions, tooltips and VoiceOver labels. |
| `polish-affected.log` | **39 passed**, zero failures/skips: PiMenuTests 3, SidebarAppearanceTests 6, SidebarFlatTopicsTests 30. Includes both menu checked states, configured name-prefix collision, minimum widths and Topics round-trip pixels. |
| `polish-mutation.log` | Reintroducing checked-icon suppression and the old retained caption fails both selected tests with seven assertions. Both production sources were restored byte for byte. |
| `polish-native-menu.log` | **11 passed**, zero failures/skips: NativeApplicationTests alone, including the shared View-menu switch. |

Read-only planning and whole-diff review by Codex gpt-6.1-sol xhigh found no
issues. Its final advice was to finish native validation and inspect menu
alignment and narrow retained tags in the affected gallery.

Affected gallery: **1/1 passed**, zero failures/skips, 14.460 seconds, with
`PI_APP_UI_GALLERY_FLAT_TOPICS_ONLY=1` and its `TEST_RUNNER_` counterpart; the
screenshot-root variables point to `$BUILD/gallery-polish`. Only
`UIScreenshotTests/testRenderRedesignGallery` was selected. Text evidence is
`logs/polish-gallery.log`; eight captures are in
`$BUILD/gallery-polish/screenshots`.

The lead viewed every fresh image below, not just the test result:

- `14f-sidebar-flat-all-normal-light.png`
- `14f-sidebar-flat-all-normal-dark.png`
- `14f-sidebar-flat-all-narrow-light.png`
- `14f-sidebar-flat-all-narrow-dark.png`
- `14g-sidebar-header-menu-normal-light.png`
- `14g-sidebar-header-menu-normal-dark.png`
- `14g-sidebar-header-menu-narrow-light.png`
- `14g-sidebar-header-menu-narrow-dark.png`

In all four menu captures, Topics keeps its folder icon and Flat keeps its list
icon; their icon/title columns align, with the checked Flat mark in a separate
leading column. The retained tag reads “Retained chats” in full at both sidebar
widths in both themes. The narrow project and topic tags visibly end with
ellipses. No remaining finding in these two corrected areas. Tooltip and
VoiceOver strings are asserted by native tests; no manual VoiceOver session
is claimed. Automatic result bundles were removed; text logs remain.
