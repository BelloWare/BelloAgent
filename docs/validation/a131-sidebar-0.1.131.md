# SIDEBAR-1: a project filter for Flat — 0.1.131

Owner, 2026-10-22: "I think I prefer the like flat view of chats. However, when
I was actually using it, sometimes it's just hard to find some chat because
sometimes I like directory view does make sense and does help." From three
mockups the owner chose **Flat + project filter**: Flat stays as it is, newest
first; a row of project chips above the list, or a row's project tag, narrows it
to one project; All goes back.

Workstream `dev/a131-sidebar`, worktree `wt-a131-sidebar`, from `dev/next`
`6b716d89`. Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-sidebar`
(`$BUILD` below); text logs in `$BUILD/logs`, images in `$BUILD/evidence` and
`$BUILD/g1`, `$BUILD/g2`. Generated fixtures and the isolated test host only: no installed
app, real preferences, real chats, Keychain, paid provider or `xctrace`.

## What it does

- **Chips.** In Flat, a row of chips sits under the search field: **All**, then
  each project with chats, newest activity first. They take the slot the
  search scope pill already reserves, so no row moves and the list starts where
  it did. The chosen chip is a white capsule in a hairline, as a pill's face;
  the others are plain labels the pointer shades. 12-point medium type, the
  scope pill's, so the two read as one family in the same place.
- **Order: newest activity first** (measured by the same activity the rows are
  sorted by, so a project's chip moves up when one of its chats does). Why:
  Flat is newest first, and the projects the reader is working in are the ones
  most likely wanted, so they stay in view while the long tail goes into "+N".
  Alphabetical or configured order would put a quiet project ahead of the
  active one and push the active one into the menu. It matches the mockup
  (pi-app, whose chat answered 2 minutes ago, before BelloBox at 3 hours). A
  chip does not move under the pointer: while the pointer is over the bar, the
  order it had holds until the pointer leaves (as rows hold their place).
- **Which projects.** Configured projects, No project and retained groups that
  have listed chats (archived chats count while the archive is shown). The
  chosen project keeps its chip even with none, so the reader can see what is
  chosen. With only one project with chats, there is nothing to choose and no
  bar. Labels are the rows' project tags ("Retained chats" for one retained
  group; several keep their id suffixes apart).
- **Overflow.** Chips are whole: when they do not all fit, they fill the row
  in order beside "+N ▾" for the rest; only a first chip with no room to be
  whole is cut short (long names at the minimum width). "+N ▾" opens a Pi menu of the hidden projects, newest
  first. The chosen chip is always shown: it takes the last place that fits.
- **Tags.** A Flat row's project tag is a button while Flat lists every project
  and no search is on: hover shades it, the pointer is a hand, and a press
  narrows the list to that project without opening the row. At rest it is
  drawn exactly as the badge it replaces. In a narrowed list, or during a
  search, tags are labels and their clicks open the row as before.
- **The narrowed list** is the Flat list of that project's chats: the same
  order (pins first, then family activity), archive section, paging, selection,
  unread/paused/draft/recency states and keyboard order (⌘⌥↓/↑ and Shift
  ranges follow it). Every chip change shows the new list from its top, All
  included, and rows glide. Paging shares
  Flat's page count; a narrowed list offers "Show less" only when that would
  hide some of its chats (a raised count otherwise showed "Show less" under two
  rows).
- **New Chat** in Flat starts in the chosen project when it is a trusted one,
  so the new chat is listed where the reader is looking. When the chosen
  project takes no new chats (No project, a retained group, an untrusted
  project), New Chat falls back as before, and the chat it opens, a new one
  or the empty one it reuses, is listed: every project again.
- **Opening a chat of another project from elsewhere** (menu bar, report,
  notifications, a new chat in another project) lists every project again, as
  Topics expands a collapsed project to show the open chat. Clicks in the
  sidebar and keyboard steps never change the choice.

## Owner decisions

**Owner, 2026-10-23, after reviewing the screenshots: all three defaults
kept.** A search covers every project; the chosen chip is kept until the app
quits; chips only in Flat. The options as they were put:

1. **Search with a chosen project.** Shipped: **a search looks across every
   project**; while it is on, the chips give their place to the search scope
   pill (Titles & details / Full chats) and every row keeps its project tag; the
   chosen chip comes back when the search ends. Conservative: search finds
   what it found before the filter existed, and nothing is hidden by a choice
   the reader cannot see. Options:
   - A (shipped): across every project, chips give way to the scope pill.
   - B: within the chosen project; the chips stay visible during a search (one
     more header row while searching).
   - C: within the chosen project, shown as a removable "BelloBox ×" token in
     the search field.
   - D: typing a search sets the chips back to All.
2. **Remembering the choice.** Shipped: **kept while the app runs** (the app
   has one main window), never saved; a relaunch starts at All. Conservative: a
   narrowed list never greets the reader after a restart with chats missing.
   Options: A (shipped) session only; B remembered across launches with the
   Topics/Flat choice; C back to All whenever the reader leaves Flat.
3. **Topics.** Shipped: **chips only in Flat**; Topics is unchanged. Options:
   A (shipped) Flat only; B chips in Topics too, showing one project's header
   and topics; C chips in Topics jump to the project's header instead of
   filtering.

## Implementation

- `Workspaces/SidebarProjectFilter.swift` (new): the chip model
  (`sidebarProjectChips`, cached in `SidebarIndex` per invalidation), the
  choice (`sidebarFlatProject`, `sidebarFlatScope(query:)`,
  `setSidebarProjectFilter`), the pure fit (`SidebarChipFit`), the bar
  (`SidebarProjectFilterBar`, PiKit `ButtonBase` chips and "+N" menu button)
  and the row tag button (`SidebarProjectTag`).
- `WorkspaceModel.sidebarProjectFilter` (in memory, invalidates the index).
- `sidebarFlatEntries(…, project:)` narrows the cached Flat tree; Flat rows
  (`sidebarGroupContents`) and keyboard order (`sidebarChatOrder`) use it.
- Rows carry `choosesProject`; `ChatRowBodyView.projectTag` is the button.
- `WorkspaceSidebarView` lays the bar in the scope's slot, swaps them with a
  short fade in Flat only (Topics keeps the instant pill), and shows the new
  list from its top with gliding rows (the scroll follows the list's update,
  whose reading anchor would otherwise keep the old first row in place).
- `revealProjectChat` drops a choice of another project; `flatNewChatProjectID`
  puts the chosen project first.
- No helper, wire, store schema, permission, capture or vault change.

## Validation

All commands use `PI_BUILD_ROOT=$BUILD scripts/test-macos.sh` with the listed
`-only-testing:PiAppTests/…` arguments, from the worktree.

### Failing first and mutations

| Log | Result |
| --- | --- |
| `baseline-flat.log` | Unchanged `dev/next`: SidebarFlatTopicsTests **30/30**. |
| `filter-red-feature-off.log` | New `SidebarProjectFilterTests` against the feature switched off (nothing narrows, no chips, reveal and New Chat ignore the choice; the new API kept so the tests compile): **12 of 15 tests fail, 58 assertions**. The 3 that pass test the pure fit, the row states (which the switch leaves alone) and the tag's look. |
| `mutation-A.log` | The narrowed list ignores the chosen project: **7 tests fail, 22 assertions**. |
| `mutation-B.log` | No promotion of the chosen chip, reveal keeps the choice, New Chat ignores it, no order hold under the pointer, "Show less" always: **7 tests fail, 15 assertions**, each piece caught. |
| `mutation-C.log` | Tags never narrow; chips stay during a search: **2 tests fail, 6 assertions**. |
| `mutation-D.log` | A chip change keeps the old scroll position: **1 test fails** (the list stayed 828 points down). |
| `mutation-E.log` | The tag never takes its own click: **1 test fails** (the row would have taken it and opened the chat). |
| `scroll-red.log` | The defect the gallery review found (below), reproduced against the earlier order (scroll, then update): back to All from a narrowed list, the list kept the narrowed list's first chat in place, **72 points down** with a pinned chat hidden above it. 1 of 16 tests fails. |

Each mutation was applied by script and the sources restored and compared byte
for byte (`cmp`) afterwards. The red run predates two later tests (the list's
top after a chip change, the tag's own click); mutations D and E and
`scroll-red.log` are their failing-first evidence.

Shared machine: the focused builds and runs from 21:28 to 21:59 (the
`filter-*`, `mutation-*` and `affected-parallel` logs) overlapped
a131-layout's `ab-soak base` run, which held the full-lane lock from 21:26,
before the quiet-window rule was announced at about 22:01. Every heavy run
since waited while a perf or soak run held the lock; the serial classes and
galleries ran under the lock itself.

### Results

| Run | Passed | Failed |
| --- | ---: | ---: |
| `scroll-green.log`: final SidebarProjectFilterTests, with the scroll fix (`b062ddc9`) | **16** | 0 |
| `affected-parallel.log`, one process, parallel testing off: SidebarProjectFilterTests 15 (its first 15), SidebarFlatTopicsTests 30, SidebarSearchScopeTests 12, SidebarSearchSidebarTests 10, SidebarDocumentRegressionTests 10, SidebarMetricsLayoutTests 10, SubagentDiscoveryTests 15, SubagentOrganizationTests 13, SessionMarkUnreadTests 11, SessionOrderingTests 5, SidebarMultiSelectionTests 4, SidebarRecencyTests 4, TopicSidebarPresentationTests 4, SidebarBindingActionTests 3, SidebarFigureGoldenTests 2, SideRowPresentationTests 1, SidebarRowStatesTogetherTests 1 | **150** | 0 |
| `serial-affected.log`, under the lock, one process, parallel testing off: LaunchSelectionTests 21, SidebarInteractionTests 9, ProjectSidebarTests 8, SidebarAppearanceTests 6, SidebarListedOrderTests 5, SidebarSideClickTests 5, SidebarNativeBindingTests 4, SidebarScalePerformanceTests 4, SidebarSearchTypingTests 2, SidebarSearchKeyboardTests 1 | **65** | 0 |
| `gallery-flat.log`: `UIScreenshotTests/testRenderRedesignGallery`, Flat scenes only, 16 captures (`$BUILD/g1`) | **1** | 0 |
| `gallery-offscreen.log`: SidebarProjectFilterGalleryTests, 14 images | **1** | 0 |
| `gallery-flat-2.log`, after the scroll fix, 16 captures (`$BUILD/g2`) | **1** | 0 |
| `gallery-offscreen-2.log`, after the scroll fix, 14 images (`$BUILD/evidence/gallery2`) | **1** | 0 |

The serial and first gallery runs were at `76838a76` with the later test
assertions; the scroll fix after them changes only what a chip press does,
which no serial class makes.

Debug figures printed by SidebarScalePerformanceTests (540 chats, shared
machine, not evidence of speed): a cold Flat list build, which now also works
out the chips once per change, median 9.6 ms (Topics 10.5 ms in the same run;
0.1.127 recorded 8.3 / 9.3 ms on a quieter machine). The chips are one pass
over the chats per sidebar change, cached with the rest of the index; the
class's reuse assertions (twenty unchanged frames compute nothing) pass.

### Gallery

Both galleries ran under the full-lane lock. `UIScreenshotTests` (Flat scenes
only, `PI_APP_UI_GALLERY_FLAT_TOPICS_ONLY=1`) draws the real window at the
normal 1440 × 900 and the minimum 920 × 600 size, light and dark; the gallery
root is named `pi-app`, so its main project reads as the owner's. Its four
projects (pi-app, Design Reference, No project, one retained group) overflow
the chips at both widths:

- `14f-sidebar-flat-all-{normal,narrow}-{light,dark}.png`: All, `[All] pi-app
  Design Reference +2 ▾` (narrow: `[All] pi-app +3 ▾`).
- `14g-sidebar-header-menu-*`: the header menu, unchanged, over the chips.
- `14h-sidebar-flat-project-*`: Design Reference chosen by its chip (narrow:
  from the menu, its chip taking the last place, cut short), three chats.
- `14i-sidebar-flat-overflow-*`: the open "+N" menu (normal: No project,
  Retained chats; narrow: Design Reference too).

`SidebarProjectFilterGalleryTests` draws the sidebar alone with the mockup's
projects (pi-app, BelloBox, belloware-site, bello-views, No project):
`project-filter-{all,project,search}-{300,200}-{light,dark}.png` and
`project-filter-from-menu-200-{light,dark}.png`.

All 30 images of the second pass were looked at (contact sheets in
`$BUILD/evidence/review`), and every first-pass image before them. The first
pass (`$BUILD/g1`) showed one defect: after choosing All again, the list
started 72 points down, "Ledger rounding rules" above the view (`14i` and the
second-appearance `14g`), because the scroll to the top ran before the list's
update. Fixed in `b062ddc9` with a failing-first test (`scroll-red.log`); the
second pass starts every list at its top. Otherwise: the chosen chip reads at
both widths in both themes; the chips sit in the scope pill's slot (the list
starts where it did); no chip or "+N" crosses the bar's edge; tags look as
before; the search scene shows the scope pill in the chips' place and matches
from every project.

## Not done, and known limits

- Chips and tags are drawn and checked by tests; hover and press shading are
  checked as layer state, not by posting pointer events (that needs
  Accessibility permission for the runner). VoiceOver names, roles and
  selected states are asserted; no manual VoiceOver session.
- Rows marked for a bulk action stay marked while a chip hides them, as they do
  in a collapsed Topics project; the bar still counts them.
- Two configured projects with the same folder name share a chip label, as
  they share a Topics header; help shows the full name.
- A choice whose project stops being listed reads as All; it would apply again
  only if a project with that id came back.
- Release performance was not measured: the chips are one pass over the chats
  per sidebar change, cached with the index (see the Debug note above).

## Round 2: review findings (Codex Astra on `63a29d33`)

- **[P2] New Chat reusing an empty chat left it hidden.** With Flat narrowed to
  No project, a retained group or an untrusted project, New Chat falls back to
  the open chat's trusted project; when that open chat is an empty pending
  chat, `createNewChat(topicID:)` reuses it and returns without `select`, so
  `revealProjectChat` never ran and the chat New Chat opened stayed out of the
  list. The reuse branch now lists it the same way
  (`listSidebarProject(of:)`, shared with `revealProjectChat`). It only
  changes the project filter; Topics' reuse behaves as before.
- **[P3] Room kept for "+N" pushed out a chip that fit.** The fit reserved the
  menu button's width before each chip, so a last chip narrower than "+N"
  could be pushed into the menu with room to spare: widths [100, 25] in 176
  points (All 40, gaps 4, "+N" 40) need 169, yet the first was cut to 92 and
  the second hidden. The fit now shows every chip whenever the whole row fits,
  and keeps room for "+N" only when some chip does not.

| Log | Result |
| --- | --- |
| `r2-red.log`, before the fixes | SidebarProjectFilterTests 17: **2 tests fail, 8 assertions**: the fit gives `shown [0] widths [92] hidden [1]` for [100, 25] in 176 (and, with the second chosen, reorders a row that fits); New Chat's reuse keeps the choice and its chat out of the list for No project, a retained group and an untrusted project alike. |
| `r2-green-parallel.log`, one process: SidebarProjectFilterTests 17, SidebarFlatTopicsTests 30, DeferredCreationTests 4 | **51** passed, 0 failed |
| `r2-serial.log`, under the lock: PendingChatProjectTests 24, TopicOrganizationTests 14, ProjectSidebarTests 8 | **46** passed, 0 failed |

The red run is the fixes taken out, which is also their mutation check: each
fix is the only difference between `r2-red.log` and the green runs. The
galleries were not rerun: in both, every chip row is wider than the bar, where
the fit is unchanged.
