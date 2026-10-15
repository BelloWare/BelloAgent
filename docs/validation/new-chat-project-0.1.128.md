# 0.1.128: choose the project of an unsaved new chat

Date: 2026-10-15. Stream/branch: `new-chat-project` / `dev/a128-new-chat-project`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-new-chat-project`.
Build and evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-new-chat-project`.

## Behavior and implementation

- Flat and Topics show a compact Pi `in <Project> ▾` chip above the composer
  while the chat remains in `pendingChatIDs`. New Chat's initial project guess
  is unchanged. Saved chats cannot move projects, even if they have no messages.
- The Pi popover uses `PiMenuEntry` commands, marks the current project, and
  searches names and paths at eight or more choices. Only trusted projects
  whose complete folder set exists and is readable are offered. Scratch / No
  project is omitted because ordinary New Chat does not allow it today.
- The chip is keyboard reachable and has the VoiceOver label
  `Project: <name>, change`. Up/Down navigate the picker, Return chooses,
  Escape dismisses; search has its own accessible label. Long names and paths
  truncate, with the complete identity available to accessibility and tooltips.
- `newChatRecord` is the shared New Chat seed. Switching uses the same saved
  connection/model defaults and fresh tool settings, clears the topic, and
  keeps only the chat identity, sidebar position, typed draft and explicit
  image attachments. Target folders, instructions and skills are resolved by
  the destination helper through the existing project configuration path.
- Replacing `SessionDisplay` retires the old editor/undo, selected skills,
  catalog, prepared context, metrics and capture presentation. Skill discovery
  and automatic context reads are cancelled; cached context and resource
  selection are cleared. The old connection lease is invalidated, and an old
  `ChatRecord` cannot subsequently open the previous project's helper session.
- An image import in progress blocks switching. Completed explicit image
  selections remain subject to the existing delivery hash checks and grant no
  access to their source folders. An image-incompatible target model produces
  a notice; images remain in the draft. Selected skills are cleared with an
  explanation; retained slash text does not carry its old direct-command grant.
- A first send hides the chip synchronously. Other actions that materialize a
  pending chat also fix its project. A counted reservation covers every first
  metadata save before the store actor returns, including overlapping callers.
  Navigation, trust loss, target folder changes, a send or a save during the
  asynchronous reads causes a project choice to be refused.
  A pending side must be closed before its parent can switch projects.

Project availability is read off the UI actor only when opening the picker or
choosing a project. Layout and refresh use record lookups, cached state and
constant-time emptiness checks; neither scans transcript messages. Picker
filtering runs only on explicit interaction. A cancelled availability task
cannot clear ownership of a newer picker read.

No helper/package code, agent tool semantics, vault format, permission rules,
capture protocol, data retention or journal format changed. Existing journals
continue down their original read path. Shared-file edits are limited to the
composer mount, the New Chat factory/save reservation, a model counter and the
stale-open guard, plus Inspector window rebinding from review round 1;
sub-agent display/cost/webhook files are untouched.

## Root causes and regression evidence

1. Flat New Chat had only its implicit focused/selected/fallback project guess;
   the composer offered no way to correct it. Before implementation,
   `testPendingProjectChipInFlatAndTopics` failed with four assertions for the
   missing chip/label in the two modes (`validation/failing-first.log`).
2. A pending chat's project had never changed under an existing identity.
   Reusing its display would retain project resource selections, and the old
   `open` guard compared only the connection. Replacement state plus a project
   comparison prevents stale records and context from crossing the switch.
3. `materializeChat` left `pendingChatIDs` set while awaiting its first store
   write. The regression holds the real store actor with a generated encodable
   fixture and observes the chip while the save waits. Before the reservation,
   it failed both the disabled-chip and blocker assertions
   (`validation/save-race-failing-first.log`). It now also verifies the chip
   updates through its normal observation path, without a manual refresh.
4. Mutation: removing only `pendingChatIDs.contains(id)` from the real switch
   guard made `testSavedEmptyChatCannotChangeProjectAndChipDisappears` move a
   materialized chat to Harbor. It failed two assertions
   (`validation/mutation-pending-guard.log`). The guard was restored; no
   mutation remains in the branch.

The behavioral tests compare the switched `ChatRecord` with a fresh target
New Chat, check draft bytes/images and removed context/skills, reject untrusted,
missing, scratch and changing projects, cover save/trust races, and inspect a
real helper-prepared request for target-only roots and AGENTS instructions.
One test sends through the synthetic loopback gateway and checks that the
project is fixed and the chip stays gone after the reply.

## Native validation

Every invocation used `PI_BUILD_ROOT` above and `scripts/test-macos.sh`.
`python3 scripts/test-lanes.py list` classified the two composer layout classes
as serial; each ran alone. Logs below are relative to the evidence root.

| Invocation / log | Executed | Result |
| --- | ---: | --- |
| `validation/affected-parallel.log`: ComposerAttachmentDestination (2), ConnectionSwitchJournal (6), ContextAndSkillPolicy (12), DeferredCreation (4), PendingChatProject (then 10), SidebarFlatTopics (30) | 64 | Passed |
| `validation/shell-composer.log`: ShellComposer alone | 5 | Passed |
| `validation/composer-bar-layout.log`: ComposerBarLayout alone | 7 | Passed |
| `validation/save-race-affected.log`: DeferredCreation (4), ModelSwitch (22), OrganizationBatch (9), PendingChatProject (11) | 46 | Passed |
| `validation/pending-final.log`: final PendingChatProject class, including observed save reservation | 11 | Passed |
| `validation/gallery-final.log`: standalone PendingChatProjectGallery | 1 | Passed, 22 captures |
| `validation/full-parallel.log`: one complete native parallel lane, four workers | 2,503 | 2,465 passed; 1 failed; 37 skipped |
| `validation/context-reading-isolated.log`: unchanged ContextReading class alone after the full lane | 3 | Passed (9.405 seconds) |

There are 108 distinct affected behavioral/layout tests across the selected
runs (overlapping classes are counted once), plus the standalone gallery test.
The helper package was not edited, so no helper-only `swift test` run was needed.
The two initial synthetic-send fixture failures were test setup errors: the
gateway key and then the synthetic model's declared output ceiling. Both were
corrected before the passing affected runs; their earlier logs remain
`validation/project-behavior.log` and `validation/project-behavior-fixed.log`.

The single full-lane failure was
`ContextReadingTests.testAChangedModelOrJournalCountsAgain`, after 67.975 seconds:
“The chat was never counted again for its new window” (`ContextReadingTests.swift:156`).
This is the same test already listed as an intermittent timeout in
`NEXT-RELEASE.md` and `docs/validation/Bello-Agent-0.1.126-2026-10-14.md`.
Its fixture uses a saved chat, not a pending chat or a project switch. The cause
of this occurrence remains unconfirmed. All 11 new behavioral tests and the
new gallery test passed in the full lane. The unchanged ContextReading class
then passed 3/3 alone in 9.405 seconds, including the failing case in 2.485
seconds. The failed full lane and passing isolated run remain separate
evidence. There was no second full-lane run for the initial implementation.
The machine-readable totals and failure are retained in
`validation/full-parallel-summary.json` and `validation/full-parallel-issues.json`;
the exact lane arguments are in `validation/full-parallel-arguments.txt`.

## Gallery

`PendingChatProjectGalleryTests.testProjectChipScenes` builds the actual native
workspace and conversation views with generated projects and an in-memory
vault. It captures only its own fixture window and Pi popover, excluding other
test processes on the shared Mac. It also chooses Harbor through the live menu
and checks the replacement composer binding and retained draft.

Final export: `gallery-final/` under the evidence root, 22 PNGs:

- `topics-*` / `flat-*`: 1240×800 and 920×600; light/dark; chip closed/open (16).
- `narrow-420-*`: 420×600 conversation pane, long project name, light/dark,
  closed/open (4).
- `search-light.png` and `search-dark.png`: many projects filtered to one (2).

All 22 final captures were opened and inspected. Chip placement, popover
anchoring, current checks, draft wrapping, long-name truncation, chevrons and
search are legible in both themes and all widths. The original 22 captures in
`gallery/` were also inspected. The capture settle helper was strengthened
before the final export to allow inactive-window sidebar layers to finish
drawing; the final captures include their complete sidebar labels.

Reproduction uses both `PI_APP_PROJECT_GALLERY=<evidence-root>/gallery-final`
and `TEST_RUNNER_PI_APP_PROJECT_GALLERY=<evidence-root>/gallery-final`, with
`-only-testing:PiAppTests/PendingChatProjectGalleryTests`. The final full lane
uses every skip argument from `python3 scripts/test-lanes.py parallel` with
`-parallel-testing-enabled YES -parallel-testing-worker-count 4`.

## Boundaries and handoff

Only generated fixtures, the isolated test host, an in-memory vault and the
synthetic loopback gateway were used. The installed app was not launched;
there were no `xctrace --launch`, paid-provider, real preference or Keychain
operations. Build products and exported evidence stay in this stream's build
root. The script's automatically named result bundles were used with its
normal newest-result cleanup; no named result bundle was requested.

Decisions: retain explicit images, clear topics and selected skills, use the
existing global connection/model-default policy, omit Scratch, add search at
eight choices, and retire the chip on any materialization (the existing pending
chat contract), not only a successful first send. A pending side is not moved
with its parent; close it first. Accessibility labels and
keyboard behavior are tested; a spoken VoiceOver walkthrough was not performed.

At the initial handoff, the lead's separate Codex review and integration of
this branch remained, along with the context-reading parallel-lane timeout
follow-up. This
stream does not merge or push `dev/next`, publish a release or modify the other
streams' sub-agent work.

## Lead review round 1

Date: 2026-10-15. Both the independent review's P2 Inspector finding and the
lead's project-picker alignment finding are addressed.

The Inspector followed a replacement `SessionDisplay` but retained its original,
immutable `SessionUsageScope`. Its archive index and usage queries therefore
stayed in the old project. The window registry also stored that old scope, so
opening Inspector again created another window. A successful pending-project
swap now explicitly rebinds only the matching owner/session/old-project entry.
It stops and disconnects the old Inspector model, replaces the model and view
inside the existing window, and derives the registry scope from the current
model. Archive queries, usage and display observation all start in the target
project. Window identity, frame and hidden state are preserved; a switch does
not present or deminiaturize the window. The new model starts on Overview so
previous project previews and navigation state are retired together. Normal
report entry points retain their exact owner/project/session matching.

The picker used each SF Symbol's natural width. The gallery regression measured
checked names/paths at 39.5 pt and unchecked names/paths at 42.5 pt. Both symbols
now occupy a fixed 16 pt leading column, with unchanged Pi commands, accessible
labels and keyboard behavior. The gallery checks the actual title and path
coordinates in both sidebar modes, themes and window sizes.

Failing-first and mutation evidence (paths relative to the evidence root):

- `validation/review1-inspector-red.log`: both new behavioral tests failed,
  with 10 assertions. They reproduce the stale scope, duplicate window,
  missing destination archive requests/usage and old read surviving the swap.
- `validation/review1-picker-red.log`: the standalone gallery failed with 16
  assertions for the 3 pt title/path offset across eight open-picker scenes.
- `validation/review1-owner-guard-mutation.log`: removing `entry.owner === model`
  from the real rebind guard caused the isolation regression to fail with two
  assertions: another owner's Inspector was replaced and changed project.
  The guard was restored before final validation.

The destination-archive regression uses the synthetic loopback gateway and
verifies an actual first send appears as an archived request and in usage in
the already-open Inspector. It also holds an old-scope read across the switch,
checks that it cannot publish after cancellation, verifies the replacement
footer subscription and proves that reopening reuses the same window. The
second regression covers a hidden window and a different owner's matching
session ID. No installed app, real credentials, real preferences, provider
calls, helper changes or journal changes are involved.

Review validation, with `PI_BUILD_ROOT` set to this stream's build root:

| Evidence | Tests | Result |
| --- | ---: | --- |
| `validation/review1-affected.log`: PendingChatProject (13), InspectorEntryPoint (7), InspectorFollow (2), InspectorWindowControl (1), SessionUsage (14), SubagentInspector (6), SubagentSteeringInspector (5) | 48 | Passed |
| `validation/review1-frame.log`: SessionUsageWindowFrame, serial class alone | 1 | Passed |
| `validation/review1-restored.log`: PendingChatProject after restoring the mutated owner guard | 13 | Passed |
| `validation/review1-gallery.log`: standalone PendingChatProjectGallery | 1 | Passed; 22 captures |
| `validation/review1-full-parallel.log`: one complete native parallel lane, four workers | 2,505 | 2,468 passed; 37 skipped; zero failures |

The selected runs cover 49 distinct behavioral/window tests plus the gallery.
The initial compile required an explicit `@MainActor` annotation for the
registry entry's computed scope; `validation/review1-build-diagnostic.log`
records that compile diagnostic separately from the passing runs.

Refreshed gallery: `gallery-review1/` under the evidence root. All 22 PNGs were
opened and inspected: Topics and Flat at 1240×800 and 920×600, light/dark,
closed/open; narrow 420×600 long names, light/dark, closed/open; and searchable
picker light/dark. Names and paths align for checked and unchecked rows;
long-name truncation, chevrons, draft wrapping and search remain legible.

The one full parallel lane for this review round passed, including all 13
PendingChatProject tests, the gallery test and all three unchanged
ContextReading tests. The prior intermittent test,
`testAChangedModelOrJournalCountsAgain`, passed in 2.419 seconds. This successful
run does not establish the cause of the initial handoff's timeout; that earlier
failed run remains recorded separately above. No second full lane was run for
this review round. Exact arguments and fixture environment are preserved in
`validation/review1-full-parallel-command.json`, authoritative totals in
`validation/review1-full-parallel-summary.json`, and selected-run counts in
`validation/review1-selected-summary.json`.

Both review findings are resolved. Remaining handoff: lead re-review and branch
integration; the historical ContextReading timeout remains a test follow-up.
