# Bello Agent 0.1.137 — compaction by task, and a faster model list

Status: **released and verified 2026-11-11.** Marketing version 0.1.137, build 141. Previous public release: 0.1.136/build 140.

## Owner request

- 2026-11-11, on compaction: "for bello agent, I think the context compaction quite often break the flow… fix and release a new version". Then: "when it's working, it got compaction, either right after I send the message, or after few runs, and then it stopped, I am pretty sure the compaction method or prompt is bad". Then: "remove the cap directly, and you and astra figure what else to do, and then release a new version for both bello agent and bello hub". And: "It has to be backward compatible".
- 2026-11-11, on reasoning: "encrypted reasoning should be not ignored… unless it got rejected by litellm due to model switch, which then we need user confirmation to proceed with previous encrypted reasoning removed or something like that, while keep new encrypted reasoning". Only its counting is in this release (see Known).
- 0.1.136 carried the two compaction fixes that were already tested and said the task-based redesign would follow. This is it.

## Change

Branch `dev/a137-hotfix`: `main` at `4882d24d` (the 0.1.136 record), plus two branches, the version and three commits.

- **Compaction by task, `dev/a136-compaction-task`** (`8eac6d67`), merged as `6fa4c34e`. Design decided with Astra (eight questions, then a review, then two rulings). Contract: `Design.md`, "What a compaction keeps", and `docs/Context-Accounting.md`, "When and what a chat compacts, 0.1.137".
  - `7c04a451`: pi's 20,000-token recent tail is gone. The task in hand stays whole (its request, the owner's steering, every tool round); only earlier tasks are summarized. At send, the exchange before the message stays. A task too large for that keeps what must stay and its newest rounds. Triggers: 70% of the usable input before a task's first request, usable less a growth reserve while it works. A compaction that fails leaves the turn to go on.
  - `1642dda0`: replayed encrypted reasoning counts at characters over four where no reply has measured it; pinned through compaction.
  - `32b31a80`: four defects from Astra's review, each failing first.
  - `8eac6d67`: the last resort for a 32,768-token window, pinned end to end.
  - The merge's conflicts with `8a6f4453` (0.1.136's review fix, in the planner and in `CompactionFlowTests.swift`) were resolved to the redesign's versions; `645cf7d7` restates that fix's test for the task-based planner.
- **Model catalog, `dev/a136-catalog`** (`d02d1f6e`), merged as `28556bad`: a catalog is no longer read, measured and resolved again for nothing. The model list and the picker open faster, and editing a connection does not reload its catalog on every keystroke.
- `645cf7d7`: a tool call id over 64 bytes (a Gemini thought signature kept in it by LiteLLM) counts at characters over four with the call and with its output.
- `670c0036`: version 0.1.137 (141), `releases/0.1.137.html`, project regenerated with XcodeGen 2.44.1.
- `ecbc500e`: **Astra's ruling on what a failed automatic compaction ends**, each point failing first.
  - **The case.** In a 128,000-token window, 60,000 tokens of results were in flight when the working trigger was crossed. No plan can be made around them. That refusal wrote the task off, so one round later, when a plan fitted easily, none was made and the chat stopped at an overflow it could have compacted away.
  - A refusal before the summary request is sent costs nothing and ends nothing: no failure record, no suppression. It is planned again when the chat changes; the same inputs are not planned twice.
  - Only a summary request that was sent and not adopted ends automatic compaction for its task, durably. The session records the sending itself; an error's code cannot tell the two apart.
  - After a context rejection the ordinary plan comes first. Where it cannot be made, only what must stay is kept with the checkpoint, though that passes half the usable input, when the replacement fits a normal request in tokens and bytes at the whole summary allowance.
  - At most one automatic summary request between two replies of the model. Steering does not reset that; a new task does. The last is the lead's addition to the ruling, accepted: read literally, a summary followed by an overflow, and so by no reply, would leave the chat with no automatic recovery again.
- `7a9c293a`: the gallery's compaction scene restated (see the gate).

## Validation

Toolchain: macOS 14.8 arm64, Xcode 16.1, Swift 6.0.2, XcodeGen 2.44.1. Fixtures and loopback gateways only. Logs are in `~/Library/Caches/BelloSwiftWork`, named `hotfix137-*.log`.

- **The ruling, failing first** (`hotfix137-failing-first-refusal-final.log`): the final tests against `670c0036`'s sources, 8 of 10 failed (32 assertions).
  - Of the two that passed there, `CompactionRefusalTests.testANewTaskMayPayForASummaryThoughNoReplyFollowedTheLast` guards the new-task reset alone and fails with that line removed (`hotfix137-failing-first-newtask.log`).
  - `testAnOverflowRightAfterACompactionIsNotSummarizedAgain` is a pin: it passed before as well, through the "already compacted" refusal.
- **Headless gates on `ecbc500e`**, before the full gate: the helper suite twice (below), `StreamingCostTests` 5, the bundle, wire / concurrent / acceptance, script tests 150, the fixture end-to-end 3 of 3 scenarios (`hotfix137-e2e-fixture.log`), the app's test build.
  - The first helper run had 1 failure in 1,309: `AgentCodexRuntimeTests.testMultiMiBForkAcceptanceJournalAndCheckpointCarryOnlyReferences`, "The source journal changed while it was being read". Seen once. It passed alone 3 of 3 (`hotfix137-helper-rerun.log`), in the second full run (`hotfix137-helper-2.log`) and in the gate's run. The test reads the parent's journal right after a turn ends and touches no compaction code.
- **Full gate on `ecbc500e`** (`scripts/verify-release.sh`, 94 min, alone on the machine; logs `hotfix137-build/verify-logs`, copied as `hotfix137-gate-*.log`; stamps in `hotfix137-verify.log`).

  | Check | Result |
  |---|---|
  | Helper bundle, Debug app and tests, helper and views test builds | built |
  | Native suite, serial lane | 2,611 tests, 111 skipped, 1 test failed (2 assertions) |
  | Native suite, parallel lane, 8 clones | 2,043 passed, 0 failed, 25 skipped |
  | StreamingCostTests, alone | 5 tests, 0 failures |
  | Gallery | 3 tests, 1 failed (2 assertions), 156 screenshots; after `7a9c293a`: 3 tests, 0 failures, 238 screenshots |
  | Helper suite | 1,309 tests, 8 skipped, 0 failures |
  | Views package | 489 tests, 4 skipped, 0 failures |
  | Wire / concurrent / acceptance | 41 / 4 / 3, OK |
  | Script tests | 150, OK |

  The classes this release is about ran and passed:
  - Compaction: `HistoryReaderCheckpointTests` 8, `CompactionResponsivenessTests` 1, `ManualCompactionTests` 1, `InspectorSummaryRequestTests` 5, `SubagentTranscriptTests` 12.
  - Catalog: `CatalogLoadCostTests` 4, `CatalogModelPickerTests` 5, `ModelCatalogEndpointTests` 23 (its window-driven methods among them), `ModelCatalogTimeoutTests` 1, `MiniModelSettingsTests` 1, `SettingsParityTests` 5, `SettingsUnsavedTests` 25, `TitleGenerationTests` 12, `SidebarAskPublishingTests` 8, `SidebarAskTextTests` 2.
  - `SendLatencyTests` skips in the gate by design (it is an opt-in measurement). Run alone with `PI_PERF_SEND_LATENCY=1` it passed (`hotfix137-SendLatencyTests.log`): the composer clears in a median 24.9 ms for a small warm chat, 81.2 ms for a large one, 85.3 ms from a cold helper.
- **The serial lane's failure, pre-existing:** `SubagentCodexIntegrationTests.testNamedForkSiblingQueueReceivingTurnAndInterrupt`, "Sibling send projects queue-only idle state" at lines 68 and 74. It fails alone on this build too (`hotfix137-rerun-SubagentCodexIntegrationTests.log`), with the same two assertions as on `v0.1.135` unchanged and on 0.1.136's build (`hotfix136-base135-SubagentCodexIntegrationTests-*.log`, `hotfix136-rerun/SubagentCodexIntegrationTests.log`). Not fixed here.
- **The gallery's failure, caused by this release and fixed in the test:** scene 20 sent a short question, then a 120 KB reply, compacted the idle chat and waited for the summary request. It relied on the 20,000-token tail splitting the large turn. Since this release an idle chat keeps its last exchange whole, and a manual compaction that would replace less than a summary costs is refused before anything is sent, so no request came in 90 s and the rest of that test's scenes were not taken. `7a9c293a` puts the large exchange first. The gallery alone, rebuilt (`hotfix137-gallery-2.log`): 3 tests, 0 failures, 238 screenshots. The change is to that one test file.
- None of 0.1.136's four load failures in the serial lane (`ChangesTabFrameTests`, `InspectorStorageTests`, `PiSheetWindowTests`, `QueueEditInteractionTests`) occurred: nothing else was building or testing during this gate.
- Of the gallery, scene 20 was looked at (one Compaction row, one request named "continuation checkpoint", its instruction first on the Conversation tab). The other images were not reviewed by eye: the release changes no view.

## Not run

The owner directed this release on 2026-11-11. These were not run:

- **`scripts/live-compaction-e2e.py` against the owner's gateway.** `docs/Release.md` requires it for a release that touches compaction, turns or requests. It needs the owner's gateway key and is billed to it:

  ```sh
  PI_BUILD_ROOT=… PI_LIVE_BASE_URL=… PI_LIVE_API_KEY=… PI_LIVE_MODEL=… PI_LIVE_CONTEXT_WINDOW=… \
    python3 scripts/live-compaction-e2e.py
  ```

  `PI_BUILD_ROOT` is the release's build root (`~/Library/Caches/BelloSwiftWork/hotfix137-build`), whose `swift-host` still holds this release's helper. Optional: `PI_LIVE_MODEL_OUTPUT_LIMIT`, `PI_LIVE_THINKING`, `PI_LIVE_MAX_COST_USD`.
- **A live Gemini tool loop on the owner's gateway**, with a long tool call id, checking that a chat near its limit compacts and goes on: the id's size is now counted, and no live request has measured that count against the gateway's.
- Installation and Sparkle update rehearsals, under the standing owner policy.

## Known

- **Encrypted reasoning is replayed as before.** It is still left out on connections set to portable history and after a model switch; a gateway's rejection of earlier reasoning is not yet turned into a question to the owner. Its size is counted now. The release notes say so.
- `SubagentCodexIntegrationTests.testNamedForkSiblingQueueReceivingTurnAndInterrupt` fails on 0.1.135, 0.1.136 and this build. To fix in the test.
- `AgentCodexRuntimeTests.testMultiMiBForkAcceptanceJournalAndCheckpointCarryOnlyReferences` failed once in three full helper runs of this tree. To watch.
- The one-summary-between-replies rule and the remembered refusals are held in memory: a relaunch starts without them. A refusal is then planned once more, at no cost; an overflow stays bounded by the journaled one-recovery allowance.
- A manual compaction of a chat whose only large exchange is its last is refused ("nothing useful to compact"), by design: the last exchange stays whole.
- The context meter's `compactionThreshold` still shows pi's window less 16,384. It is a display figure, not either trigger.
- A tool result over 65,536 bytes is cut by the session and saved to a file, so one result is at most about 16,000 tokens; the batch that outgrows half a 128,000-token window is four or more results in parallel.

## Release

- Tag `v0.1.137` on `40f6ab14` ("Record the validation of Bello Agent 0.1.137"), the commit that holds the version, the notes and this record, as `v0.1.136` does. The artifacts were built from its parent `7a9c293a`; the two differ by this record alone. On `main` by fast-forward from `dev/a137-hotfix`.
- `scripts/release.sh` ran from the worktree with `NOTARY_KEY_PATH` naming in full the file its default names beside the main checkout; every other value was its default. Signing did not stall.
- `BelloAgent-0.1.137.dmg`, sha256 `cbbdb17e7e41df528025200e22896ec61df309b97302252028b0d3b2d244399f`, 17,335,653 bytes; Developer ID signed and notarized (app submission `b2b5d3b3-f942-4542-ba54-3c02f07a0465`, DMG submission `b8be0b1b-f5ac-4589-8e91-14acbb96c544`, both Accepted), stapled. In `~/Library/Caches/BelloSwiftWork/hotfix137-build/releases/0.1.137`.
- `validate-release.py --previous-build 140`: passed (0.1.137 build 141, Ed25519 signature verified, 17,335,653 bytes); the Bello Agent and legacy Pi App staging feeds are byte-identical.
- **Publication decision** (lead, on the owner's instruction to release): the serial lane's one failure fails identically on `v0.1.135` and 0.1.136; the gallery's failure was the test's premise, restated and passing; the two live checks on the owner's gateway were not run.
- `scripts/publish-release.sh 0.1.137` ran from the worktree at `40f6ab14`. Website commit `68daa76` ("Publish Bello Agent 0.1.137 update", belloware.com `main`).
- `verify-published.py`: the public DMG matches (sha256 `cbbdb17e7e41df528025200e22896ec61df309b97302252028b0d3b2d244399f`, Ed25519 signature verified, 17,335,653 bytes), and the Bello Agent and legacy Pi App feeds are byte-identical. It passed on the fifth try at 30-second intervals, once the site had deployed (`hotfix137-build/verify-published.log`).
