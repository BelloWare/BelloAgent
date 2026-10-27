# AGENTS-1 app — 0.1.135

Branch `dev/a135-agents-ui`, based on helper contract commit `114cd880`.
Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents-ui`;
all commands export `PI_BUILD_ROOT` to that directory. Generated journals,
loopback providers, and the isolated `com.belloware.PiAppTests.Host` only.
No helper source changes, real chats, credentials, installed app, or paid calls.

Implements §9 of `docs/design/subagents-codex-style.md`. The requested
`docs/Design.md` does not exist; the design guide is the root `Design.md`,
with PiKit component guidance in `docs/appkit-components.md`.
The three appendix decisions follow the lead's instructions: additive list
cursor, read-only message/turn detail modes, and locally derived descriptions.

## Changes

- Durable task names flow from headers and adopted helper summaries into cards,
  picker, tabs/windows, group/search rows and Inspector family. Missing names
  keep the numbered legacy fallback. Named sidebar rows retain their description
  and their existing cost/status figures.
- Six capability-gated Codex cards extend the existing native sub-agent card.
  They distinguish fresh/forked starts, send delivery, new turns, wait wake
  summaries, interrupt outcome and compact paged lists. Existing v3 cards remain.
- Typed v2 deliveries render sender, recipient and message type; initial hand-off
  and task are `main · New task`. Final answers retain the full Markdown source,
  bounded presentation, Copy and Find. v1 decoding remains.
- Journal coordination joins a sibling's source call with its recipient delivery.
  A live sibling sender is not mislabeled as copied history. Copied cards retain
  original ownership; navigation still validates the family and reader token.
- Queue-only mail to an idle child reads `Waiting for its next turn` and is not
  relabeled as parent Resume. V4 interrupts do not invent a final-answer message.
- A single inherited-context fold uses the existing disclosure and paging stores.
  The count comes from the body-free journal index/window positions. Closed folds
  suppress hidden-page opening fill and automatic reads; expanding uses normal
  bounded history paging. Loaded inherited rows remain read-only. Child input,
  Stop/hold, cost/footer and coalesced progress behavior stay in place.

## Failing-first evidence

Logs are under `$PI_BUILD_ROOT/logs`.

- `codex-red.log`: six new presentation tests, 30 failing assertions before the
  implementation (names, six card headings/states, v2 rows, gating, queue mail,
  inherited fold and v1/v3 compatibility expectations).
- `codex-green-4.log`: utility cards incorrectly borrowed the target's running
  state; an interrupt synthesized mail; named search lost description matching.
  Corrected those issues. Two page-count assertions initially used the wrong
  fixture API/default limits and were corrected to exercise bounded windows.
- `codex-paging-red-2.log`: seven storage tests, two assertions failed because a
  closed inherited fold started opening fill and read a hidden page. Both guards
  now prevent it (`codex-focused-green.log`: 14/14).
- `codex-visual-red.log`: 15 tests, seven assertions failed after gallery review:
  sibling card treated as copied history, later main task attribution, list soft
  line breaks, empty wait/interrupt bodies and named search title. The next run
  (`codex-visual-green.log`) passed 36/36 across presentation, storage, display
  and organization.
- The first serial run caught changed legacy turn-fold classification. Restored
  legacy `subagent_*` handling and classify only spawn/followup as delegations.

## Validation

Final distinct class results: **296 passed, 1 optional gallery skipped, 1 existing
failure**, 298 tests total. The 138-test parallel batch and all new tests pass.
Serial classes ran alone. Galleries and focus/timing-sensitive runs held
`/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`, released on exit.

| Class | Result | Log under `$PI_BUILD_ROOT/logs` |
|---|---|---|
| `ConversationFamilyTests` | 22 passed | `codex-final-parallel.log` |
| `MetadataDurabilityTests` | 10 passed | `codex-final-parallel.log` |
| `SubagentCodexPresentationTests` | 8 passed | `codex-final-parallel.log` |
| `SubagentCodexStorageTests` | 7 passed | `codex-final-parallel.log` |
| `SubagentDiscoveryTests` | 15 passed | `codex-final-parallel.log` |
| `SubagentDisplayTests` | 8 passed | `codex-final-parallel.log` |
| `SubagentInspectorTests` | 7 passed | `codex-final-parallel.log` |
| `SubagentMetadataTests` | 9 passed | `codex-final-parallel.log` |
| `SubagentOrganizationTests` | 13 passed | `codex-final-parallel.log` |
| `SubagentPanelTests` | 8 passed | `codex-final-parallel.log` |
| `SubagentSteeringInspectorTests` | 6 passed | `codex-final-parallel.log` |
| `SubagentSteeringPresentationTests` | 10 passed | `codex-final-parallel.log` |
| `SubagentSteeringWorkspaceTests` | 4 passed | `codex-final-parallel.log` |
| `SubagentTranscriptTests` | 11 passed | `codex-final-parallel.log` |
| `SubagentCodexGalleryTests` | 1 passed | `codex-final-gallery.log` |
| `SubagentMarkdownTests` | 20 passed | `codex-final-SubagentMarkdownTests.log` |
| `SubagentNavigationTests` | 7 passed | `codex-final-SubagentNavigationTests.log` |
| `TranscriptTurnFoldTests` | 26 passed | `codex-final-TranscriptTurnFoldTests.log` |
| `SubagentPerformanceTests` | 1 passed, 1 failed (baseline issue below) | `codex-final-SubagentPerformanceTests.log` |
| `InheritedSubagentReaderTests` | 8 passed | `codex-InheritedSubagentReaderTests.log` |
| `CostPauseFamilyTests` | 5 passed | `codex-CostPauseFamilyTests.log` |
| `SubagentOpeningTests` | 15 passed | `codex-SubagentOpeningTests.log` |
| `SubagentReaderTests` | 60 passed | `codex-SubagentReaderTests.log` |
| `TranscriptOpeningFillTests` | 11 passed, 1 skipped | `codex-TranscriptOpeningFillTests.log` |
| `TranscriptWirePageTests` | 4 passed | `codex-TranscriptWirePageTests.log` |

The skipped `TranscriptOpeningFillTests.testOpeningFillGallery` requires its
separate `PI_OPENING_GALLERY` opt-in; the new agent gallery ran explicitly.
`SubagentOpeningTests` uses the real bundled helper and generated loopback
provider. Its 15 tests cover discovery, attachment, window/tab selection,
Back to Parent and stale reader ownership. The v4 cases are contract fixtures
until runtime activation is available.

Commands (all from this worktree):

```bash
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents-ui
# Initial focused runs; each serial class is a separate invocation.
scripts/test-macos.sh -only-testing:PiAppTests/<Class>
# Final runs limited compiler concurrency after shared-machine pressure.
scripts/test-macos.sh -jobs 4 'OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 4' \
  -only-testing:PiAppTests/<Class>
# Gallery, while holding the full-lane lock:
TEST_RUNNER_PI_APP_CODEX_AGENTS_GALLERY="$PI_BUILD_ROOT/galleries/codex-v4" \
  scripts/test-macos.sh -jobs 4 'OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 4' \
  -only-testing:PiAppTests/SubagentCodexGalleryTests
```

The final parallel invocation supplies `-only-testing:PiAppTests/<Class>` for
the first fourteen table rows together. Exact batch scripts are retained at
`$PI_BUILD_ROOT/run-serial.sh` and `$PI_BUILD_ROOT/run-final.sh`. The baseline
check uses `$PI_BUILD_ROOT/check-baseline.py`, rebuilding `114cd880` in this same
root with two compiler workers before restoring the implementation. No named
result bundles or extra DerivedData directories were created.

## Mutation checks

Every temporary mutation was restored, followed by the final green functional
runs above. Scripts are retained at `$PI_BUILD_ROOT/check-mutations.py` and
`$PI_BUILD_ROOT/check-open-mutation.py`.

| Log | Deliberate break | Observed failures |
|---|---|---|
| `codex-mutation-behavior.log` | Ignore task titles; change all six headings and fork/fresh labels; drop wait summaries; damage compact list/interrupt text; call a sibling historical; relabel idle mail as parent Resume; remove the inherited fold and its paging guards; drop v1 deliveries and v3 cards; truncate final text | 27 presentation + 8 storage assertions across 15 tests |
| `codex-mutation-final-copy-find.log` | Truncate v2 FINAL_ANSWER to 100 characters | 5 assertions in 1 test, including full source, Copy, Find and its reveal timeout |
| `codex-mutation-capability.log` | Accept new cards/rows without capability and force capability on at handshake | 2 presentation + 1 storage assertions across 15 tests |
| `codex-open-red.log` | Original pending-message Open route; separately hide named sidebar descriptions when metrics exist | 1 pending-navigation failure before its fix, plus 1 independent subtitle mutation caught |
| `codex-open-mutation.log` | Restore the old pending Open route and mislabel starting, unknown and rejected outcomes | 6 assertions across 8 presentation tests |

Pending sibling mail now opens the recipient's transcript. Delivered mail opens
its exact delivery row. This uses the existing actions, family validation and
reader ownership. The initial failing-first run showed both states incorrectly
calling the delivery action; the mutation reproduced that failure after the fix.

## Gallery review

Folder: `/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents-ui/galleries/codex-v4`.
All **62 PNGs** listed in `manifest.txt` were regenerated and visually inspected,
including the 16 final contact sheets in `review-final/` and full-size checks of
the narrow pending, sibling, fold and picker scenes. The initial review caught
the sibling provenance bug, collapsed Markdown list lines, empty utility bodies
and stale picker capture; those are fixed in the final images.

Four variants (light/dark × 920-wide/640-wide) cover forked start, fresh start,
sibling send, sibling receipt, final answer, follow-up, interrupt, idle queue
mail, wait, list, inherited fold closed/open, v3 history and named search.
There are four named-picker variants and two named-family Inspector captures.
Narrow fixtures use 820-point height so the child footer and body can be reviewed.
The named sidebar shows description and cost; the child has no composer.

No intentional design deviations. No owner decision is pending on the three
settled appendix items. No confirmed helper bug or appendix mismatch was found
at the contract checkpoint; v4 real-helper integration remains outstanding.


## Integration status

Repeated `git fetch origin dev/a135-agents` checks still resolve to `114cd880`.
That commit publishes the contract and additive readers, not runtime activation.
The capability list in `packages/swift-host/Sources/PiAgentCore/SubagentTypes.swift:12`
still advertises v3. The existing real-helper/loopback opening tests pass; v4 end-to-end execution
must be rerun after the helper runtime advances. No helper mismatch is claimed
from an unimplemented path, and no helper code was changed.

## Existing failure isolated from this change

`SubagentPerformanceTests.testFiftyKilobyteMarkdownResultInALongChatKeepsTheMainThreadResponsive`
reports 405 message-row visits during expansion (expected zero). The same test
on **unmodified contract commit `114cd880`**, with all app changes and new tests
removed for the build, reproduces **405**. Evidence:
`codex-SubagentPerformanceTests.log` and `codex-baseline-performance.log`.
All implementation files were restored afterward.

The existing full reconciliation in `NativeTranscriptScrollView.swift:604`
clears the lookup and line 635 rebuilds it. The unchanged fresh-highlight expiry
in `TranscriptPage.swift` republishes a cosmetic revision with the same change
stamp, which can take that path while Markdown expansion is in progress.
This is reported, not repaired outside AGENTS-1. The baseline also hit two
wall-clock thresholds under machine load. These Debug checks are functional
regression evidence, not Release performance measurements; no speed claim is
made. A resource-thrashing baseline build was stopped and retried with limited
compiler concurrency in the same build root.
