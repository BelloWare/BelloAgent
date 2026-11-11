# Bello Agent 0.1.136 — hotfix: Gemini tool calls, and turns that survive compaction

Status: **built, signed, notarized and validated 2026-11-11; not yet published.** Marketing version 0.1.136, build 140. Previous public release: 0.1.135/build 139. The lead publishes, tags and verifies the public artifacts, and adds that to "Release" below.

## Owner request

- 2026-11-11, on Gemini: "also for gemini model, I am getting invalid tool call id, please check and fix it. I think it's related to litellm concating things, and it goes too long which caused the issue". Then: "check fix/gemini-tool-call-ids, it might help you, and if it looks good, try merge it into current code, and release a new version".
- 2026-11-11, on compaction: "when it's working, it got compaction, either right after I send the message, or after few runs, and then it stopped, I am pretty sure the compaction method or prompt is bad". Then: "remove the cap directly, and you and astra figure what else to do, and then release a new version for both bello agent and bello hub".
- The task-based compaction redesign follows in the next release (`dev/a136-compaction-task`). This hotfix carries the two compaction fixes that were already tested.

## Change

Branch `dev/a136-hotfix`: `main` at `a5e026c8` (the 0.1.135 record), plus two branches merged without conflict, the version, and two review fixes.

- **Gemini tool call ids, `dev/a136-gemini-callid`**, merged as `acf71773`. Record: [gemini-tool-call-ids-2026-11-11.md](gemini-tool-call-ids-2026-11-11.md).
  - **Cause.** LiteLLM (1.80.5 on) carries Gemini's thought signature inside the tool call id, `call_<28 hex>__thought__<signature>`: hundreds of characters as a rule, 278,100 bytes in one measured run. `ProviderAccumulator.result()` refused an id over 512 bytes with `invalid_params: Invalid tool call id`. Smaller bounds stood in `session.tool.input` (256), the sub-agent link (512), the app's sub-agent target (512) and the timeline (clipped at 256).
  - `df01b524`, the owner's fix cherry-picked from `fix/gemini-tool-call-ids`: one `ProviderToolCallID` rule for all of them. Ids are kept whole and sent back byte for byte, as LiteLLM requires for the call and its result.
  - `252dc32a`: the Xcode project regenerated.
  - `d0d6fd3e`: the bound is 1 MiB, and an id over it says its size.
  - `d78624ce`: a request to another model names a call whose id is over 64 bytes by a short id derived from it (OpenAI refuses a longer one); the model that made the call still gets it whole.
- **Compaction, `dev/a136-compaction-room`**, merged as `e839335b`.
  - `904a9ec7` (COMPACT-1): after a compaction in the middle of a task, the next request held the summary alone. A tool batch no reply has answered is now kept while it fits, and the running task's own inputs are replayed after the summary.
  - `e54c4990` (COMPACT-2): a round larger than the growth reserve made the summary request `compaction_too_large` and failed the turn at about 85% of the window. The summary now takes the room that is left, down to 8,192 tokens; below that the refusal stands.
- **Version and notes**, `c2dbcc16`: 0.1.136 (140), `releases/0.1.136.html`, project regenerated with XcodeGen 2.44.1.
- **Review of `a5e026c8..acf71773`** (Astra, one pass): two P2 findings, both fixed failing-first.
  - `8a6f4453`: **a regression of COMPACT-1.** In a 32,768-token window, an 8,000-token request fitted the replay allowance, yet with the 8,192-token summary allowance it passed the automatic trigger (16,057 tokens) whatever was cut. Planning threw `compact_budget` for a turn 0.1.135 could compact. Replaying the task's inputs is the planner's choice: when no cut has room beside them, the checkpoint is planned without them, by pi's rules. Test: `CompactionFlowTests.testATaskThatLeavesNoRoomBesideTheSummaryIsSummarizedNotRefused` (before: `compact_budget`).
  - `ac55d8ea`: **the whole call id was written to the reply's recovery log with every argument delta.** 302 events of two calls with 203 KB ids wrote 61,509,846 bytes; a 278 KB id over a thousand deltas would be about 278 MB of synchronous writes, counted as 256 bytes an event. The log now writes a part's id with the first event that carries one and restores it to the later ones on reading; a log with the id on every line reads as before; what waits is counted with the id it will write. Tests: `PartialReplyLogTests.testALongCallIDIsWrittenOncePerPartAndRestoredWhole` (under 560,132 bytes now; a helper killed mid-stream reopens with every segment's whole id, from the new log and from the same log rewritten in the earlier form) and `testALongCallIDCountsTowardsTheBatchOnce`.
  - The other paths a delta takes, checked for the same growth:
    - **Host channel to the app.** A timeline append names its segment by the segment's own short id. A new or changed segment carries its part, and so the call id, once. A tool-input append carries the call id once per coalesced update, not per delta.
    - **Traces and captures.** They keep the response bytes as they arrived, once. LiteLLM itself names the item by the long id in every argument delta it sends.
    - **Journal.** Written when the reply settles: the id is in the call's block, twice in its provider item, in its result, and once per timeline segment.

## Validation

Toolchain: macOS 14.8 arm64, Xcode 16.1, Swift 6.0.2, XcodeGen 2.44.1. Fixtures and loopback gateways only.

- **Workstreams before the merge.**
  - Gemini fix: the owner's commit compiled unchanged; focused classes 42 tests, each old bound restored alone fails its tests; the helper suite 1,250 then 1,258 tests, no failure. Details in its record.
  - Compaction fixes: `CompactionFlowTests`, failing first on 0.1.135's planner, as their commits state.
- **Review fixes** (`hotfix136-astra-failing-first.log`, `hotfix136-astra-fixed.log`): the three new tests failed before their fix (9 assertions). After it, twelve compaction, reply-log, timeline, fork and journal classes ran 158 tests with 1 skip and no failure.
- **Full gate on `ac55d8ea`** (`scripts/verify-release.sh`, 109 min; logs `hotfix136-build/verify-logs`, copied as `hotfix136-*.log`). Other jobs were building and testing on the machine during it.

  | Check | Result |
  |---|---|
  | Helper bundle, Debug app and tests, helper and views test builds | built |
  | Native suite, serial lane | 2,611 tests, 111 skipped, 5 tests failed (12 assertions) |
  | Native suite, parallel lane, 8 clones | 2,039 passed, 0 failed, 25 skipped |
  | StreamingCostTests, alone | 5 tests, 0 failures |
  | Gallery | 3 tests, 0 failures, 238 screenshots |
  | Helper suite | 1,271 tests, 8 skipped, 0 failures |
  | Views package | 489 tests, 4 skipped, 0 failures |
  | Wire / concurrent / acceptance | 41 / 4 / 3, OK |
  | Script tests | 150, OK |

  The classes this hotfix is about ran and passed: `SubagentTranscriptTests` 12 (with `testSubagentTargetsPreserveSignatureBearingCallIDs`), `CompactionResponsivenessTests` 1, `ManualCompactionTests` 1, `InspectorSummaryRequestTests` 5.
- **Triage of the serial lane** (`hotfix136-rerun/`): every failed class was run alone on the same build.
  - **Passed alone** (load): `ChangesTabFrameTests` 8, `InspectorStorageTests` 44 (2 skipped), `PiSheetWindowTests` 12, `QueueEditInteractionTests` 18. Two of them waited for closed views to be let go.
  - **Pre-existing:** `SubagentCodexIntegrationTests.testNamedForkSiblingQueueReceivingTurnAndInterrupt` fails alone too. It expects the `send_message` card to read "Waiting for its next turn"; the card reads "Waiting for its next turn · model default". It fails the same way on `v0.1.135` unchanged, built in its own worktree, 2 runs of 2 (`hotfix136-base135-SubagentCodexIntegrationTests-*.log`). The hotfix changes one line of app code, the call id check in `SubagentTarget`. Not fixed here.
- **Fixture end-to-end compaction** (`scripts/live-compaction-e2e.py --fixture`, the release helper against the script's local gateway): 3 of 3 scenarios passed, in each of 3 runs (`hotfix136-fixture-e2e-*.log`).
- The gallery's images were not reviewed by eye: the hotfix changes no view.

## Not run

The owner directed this release on 2026-11-11. These were not run:

- **`scripts/live-compaction-e2e.py` against the owner's gateway.** `docs/Release.md` requires it for a release that touches compaction, turns or requests. It needs the owner's gateway key and is billed to it:

  ```sh
  PI_BUILD_ROOT=… PI_LIVE_BASE_URL=… PI_LIVE_API_KEY=… PI_LIVE_MODEL=… PI_LIVE_CONTEXT_WINDOW=… \
    python3 scripts/live-compaction-e2e.py
  ```

  `PI_BUILD_ROOT` is the release's build root (`~/Library/Caches/BelloSwiftWork/hotfix136-build`), whose `swift-host` still holds this release's helper. Optional: `PI_LIVE_MODEL_OUTPUT_LIMIT`, `PI_LIVE_THINKING`, `PI_LIVE_MAX_COST_USD`.
- **A live Gemini tool loop on the owner's gateway**, with a sub-agent call and a resumed chat, checking that the whole `call_id` comes back. The gateway's LiteLLM version and whether it sets `thought_signature_in_tool_call_id` are not known here.
- Installation and Sparkle update rehearsals, under the standing owner policy.

## Known

- `SubagentCodexIntegrationTests.testNamedForkSiblingQueueReceivingTurnAndInterrupt` fails on 0.1.135 and on this build: the test's expected label lacks the effort the card now shows. To fix in the test.
- With LiteLLM's `thought_signature_in_tool_call_id: false` (1.109.0 on) the app works, but the request rebuilds a call without `provider_specific_fields`, so the signature is not returned and Gemini 3 and newer get LiteLLM's placeholder. Keep LiteLLM's default with this app.
- A gateway alias that can answer from Gemini and from another provider (an auto-router) can still send a Gemini-minted id to a provider that refuses it: the app cannot tell which route the next request takes.
- A tool-input append to the app carries its call id once per update; with a very long id and arguments spread over many updates that is the id many times over the host channel.
- The serial lane's four load failures are still to be confirmed on a quiet machine, as are the machine-sensitive classes listed for 0.1.135.

## Release

- Source: `dev/a136-hotfix`; the artifacts were built from `ac55d8ea`.
- `BelloAgent-0.1.136.dmg`, sha256 `cecdcdea749acfa44f9c3c48b0b58d9e51a327e601020ff782ea6996e2cf0333`, 17,325,808 bytes; Developer ID signed and notarized (app submission `df7c8e95-62c5-4d58-aa63-1efe36f7048f`, DMG submission `e96e5e14-665c-437f-ba07-16df513f9890`, both Accepted), stapled.
- `scripts/release.sh` ran from the worktree with `NOTARY_KEY_PATH` naming in full the file its default names beside the main checkout; every other value was its default.
- `validate-release.py --previous-build 139`: passed (0.1.136 build 140, Ed25519 signature verified); the Bello Agent and legacy Pi App staging feeds are byte-identical.
- Not yet done: publication (`scripts/publish-release.sh 0.1.136`), `verify-published.py`, the tag `v0.1.136`, `main`, and the merge into `dev/next`.
