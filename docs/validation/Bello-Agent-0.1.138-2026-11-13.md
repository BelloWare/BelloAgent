# Bello Agent 0.1.138 — reasoning sent back, a kept model list, and requests over the window

Status: **in validation, 2026-11-13.** Marketing version 0.1.138, build 142. Previous public release: 0.1.137/build 141. The headless gates and the live runs below are done; the on-screen gate, signing and the release section are still to come.

## Owner request

- 2026-11-11, on reasoning: "encrypted reasoning should be not ignored… unless it got rejected by litellm due to model switch, which then we need user confirmation to proceed with previous encrypted reasoning removed or something like that, while keep new encrypted reasoning". 0.1.137 only counted it; this release does it.
- 2026-11-11, on compaction: "when it's working, it got compaction, either right after I send the message, or after few runs, and then it stopped, I am pretty sure the compaction method or prompt is bad". And: "It has to be backward compatible".
- 2026-11-12, on the model list: "Do both for catalog loading".
- 2026-11-12, on live tests: "you can setup litellm gateway, and test different providers and models (only cheap one please)".
- 2026-11-13, on the reasoning question across a restart: "I think what bello agent is doing is good". On its UX: "and try to make the UX even more intuitive and better, you figure out how".

## Change

Branch `dev/a138-hotfix`: `main` at `805f7425` (the 0.1.137 publication record), plus two branches, five commits from live tests, and the version.

- **Model catalog, `dev/a138-catalog-options`** (`7ba63689`, `e9e9ed1b`), merged as `037e3408`. A saved connection's last good custom catalog is kept on disk (`ModelCatalogs/`; models and a digest of their source, never the address, a key or a header) and used at once; a list older than five minutes is used as it is and read again behind. Contract: `docs/Model-Catalog.md`, "The list in hand".
- **Reasoning, `dev/a138-reasoning`** (`a68aa400`), merged as `50e176ab`. A connection sends a reply's reasoning back by default, for replies stored from this version on; a provider's refusal of replayed reasoning becomes a durable notice with one button, per refusing model; the pinned route no longer stops when the gateway's header and body name the model differently; Gemini-to-Gemini call ids are kept. Contract: `docs/Reasoning-Replay.md`.
  - The merge's one conflict was `NEXT-RELEASE.md` (both branches added an entry in the same place; both kept). `project.pbxproj` merged cleanly and equals what XcodeGen 2.44.1 writes.
- `6084ca09`, from the first live run. **A request over the window.** Ten file reads in one batch made a 78,362-token request in a window declared as 50,000; it went out with `max_output_tokens: 16` and the 17-token reply ended the task as if answered. The output limit is clipped to the room the window leaves only while that room holds a reply (`PiContext.outputCap`); one row per task says the request is over the window; an idle chat whose last task was cut at the output limit says `stoppedEarly` in its snapshot. **A summary never orders finished work redone:** one sentence added to the summarizer's instruction and one clause to a mid-task checkpoint's line; structure unchanged; recorded checkpoints replay their own words.
- `21a7b195`: `scripts/live-compaction-e2e.py` (the compact-now seed scales to the window; a request the script cut does not end the run; the mid-run task no longer forbids `offset`/`limit`).
- `0945b8f7`: two findings of the local review (Astra, two P2).
- `b3f03fbc`, from the second live run. **Before a request goes out over the window, what must stay is kept with a checkpoint.** In a 32,768-token window with reasoning sent back, one 7,200-token result with its reasoning passed half the usable input, so no plan could be made, ten times, and the turn grew to 80,982 tokens; 0.1.137 compacted the same task five times. The plan a provider's refusal already allowed is made before sending, and its summary request is sent though it is itself over the window as declared, with an 8,192-token cap. **A summary answered with no text or a tool call is asked for once more**, the same request and one line, as Bello Hub does. The harness counts only compactions that sent a summary request and scales its evidence files to the window.
- `84989faf`: the test that pinned "no summary is sent after a switch to a window too small" restated for `b3f03fbc`; one P2 of the second local review (a fixture switch without `--fixture` never starts a live run).
- The version commit: 0.1.138 (142), `releases/0.1.138.html`, project regenerated with XcodeGen 2.44.1, and this record.

Design: `Design.md`, "The output limit is never squeezed toward nothing", "Over the window, said once per task", "Before a request goes out over the window…", "A summary with no text is asked for once more", "A summary records; it does not order work redone"; `docs/Context-Accounting.md`, "A request over the window, 0.1.138".

## Validation

Toolchain: macOS 14.8 arm64, Xcode 16.1, Swift 6.0.2, XcodeGen 2.44.1. Logs are in `~/Library/Caches/BelloSwiftWork`, named `hotfix138-*.log`, `hotfix138b-*.log` and `hotfix138c-*.log`.

- **Failing first.**
  - Over the window and the cut reply (`hotfix138-failing-first-a.log`, `-a-cap.log`): 8 of 9 new tests failed, 18 assertions; with only the cap rule reverted, 6 assertions.
  - Summary wording (`hotfix138-failing-first-b.log`): 2 of 3; the third pins the replay of a recorded checkpoint.
  - Harness (`hotfix138-failing-first-c.log`, `-c-32k-oldseed.log`): all 6; with the old seed forced, the fixture reproduces the live `compaction_too_large` at 32,768.
  - The first review's two findings (`hotfix138-failing-first-review.log`).
  - The second live run (`hotfix138b-failing-first-swift.log`): 5 of 6, 18 assertions, turns of 28,312 and 38,345 tokens sent whole in a 32,768-token window; `hotfix138b-failing-first-script.log`: 3 of 4.
  - The regression in the fixture (`--fixture --fixture-window 32768 --fixture-reasoning 12000 --evidence-tokens 7200 --scenario mid-run`): on the `0945b8f7` helper nine plans, none sent, and the turn grew from 13,695 to 63,631 tokens until the fixture's real window refused it (`hotfix138b-failing-first-fixture-32k-reasoning.log`); on `b3f03fbc` five adopted compactions, largest turn request 20,884, 10 of 10 markers (`hotfix138b-fixture-32k-reasoning-after.log`).
- **Headless gates on `84989faf`** (`hotfix138c-gate-summary.log`), before the version commit, which changes no source:

  | Check | Result |
  |---|---|
  | Helper suite | 1,355 tests, 8 skipped, 0 failures |
  | StreamingCostTests, alone | 5 tests, 0 failures |
  | Wire / concurrent / acceptance | 41 / 4 / 3, OK |
  | Fixture end-to-end compaction | 3 of 3 scenarios |
  | Fixture at 32,768 tokens, compact-now | 1 of 1 |
  | Script tests | 164, OK |
  | `scripts/older-reader-check.sh v0.1.137` | 3 tests, 0 failures |
  | XcodeGen | no project difference |
  | App and tests, `build-for-testing` | succeeded |

  - The same gates on `b3f03fbc` had one failing test, `TurnCapacityTests.testAWindowTooSmallForOneSummaryRequestSendsNoSummary`: a pin of what that commit changed on purpose, restated in `84989faf`.
  - The older-reader check has 0.1.137's helper open three things this build wrote: the reasoning chat (its records, lines and standing refusal), a chat with the over-window row (from its checkpoint and from the journal alone, then retried to idle), and a checkpoint record whose framing line has 0.1.138's clause.
- **Two local reviews** (Astra, `gpt-6-astra`, xhigh, read-only), one per change set: `hotfix138-astra-review.log` (two P2, both fixed in `0945b8f7`) and `hotfix138b-astra-review.log` (one P2 on the harness, fixed in `84989faf`; none on the planner). No second pass after the fixes.
- **Live, on real models** (run by the lead; evidence, read-only, in `~/Library/Caches/BelloSwiftWork/live-gateway/evidence/apps/agent/`, `agent138/` and `agent138b/`). The gateway was a local LiteLLM 1.108.0 on an OpenRouter key, **not the owner's own gateway**; only small, cheap models: a small OpenAI model, Gemini flash-lite and a small Claude model. About $1.14 for all live testing of this release.
  - `scripts/live-compaction-e2e.py`, which `docs/Release.md` requires for a release that touches compaction, turns or requests, is **run**: 9 of 9 on the `b3f03fbc` helper (the small OpenAI model at 32,768 and at 100,000 tokens, Gemini flash-lite at 100,000).
  - The regression case with 7,200-token files at 32,768: three adopted compactions, largest turn request 22,273 tokens, all three summary requests over the declared window and completed by the provider, 10 of 10 markers.
  - Mid-task compaction at 50,000 tokens on both models with reasoning replayed unchanged.
  - Earlier rounds, on the `0945b8f7` helper, 7 of 8 areas: the over-window row and the ordinary reply limit, the mark on a cut reply, the summary wording (on the prompt that had made the small OpenAI model restart: no restart, next steps "continue with part-09… do not repeat reads already attempted"), reasoning replay, the pinned route's naming, the refusal notice end to end. The eighth was the regression fixed in `b3f03fbc`.
  - The second ask for a summary was exercised on a stand-in: Gemini flash-lite gave no empty summary in 11 live tries.

## Not run

- **Real direct provider keys.** Every provider reached was behind OpenRouter and LiteLLM, and every refusal of earlier reasoning was a stand-in's, not a provider's own.
- **A provider actually refusing an over-window request**, the turn's or the summary's: the providers reached had real windows larger than the declared ones and accepted them.
- **The app's own button and Settings on a live gateway**: "Continue without earlier reasoning" and the three reasoning choices were driven through the helper, not clicked in the app against a live gateway.
- The on-screen gate (`scripts/verify-release.sh`), signing and notarization: to come, below.
- Installation and Sparkle update rehearsals, under the standing owner policy.

## Known

- Alternating between two models whose providers refuse each other's reasoning brings the notice back on each round trip.
- "Never send reasoning back" chosen in 0.1.138 reads as "Send reasoning back" again after the connection is saved by 0.1.137.
- A provider that enforces a declared window strictly refuses the over-window summary request once per task; the task's automatic compaction ends there, where before nothing was sent.
- A gateway that counts the reply limit against its window refuses a request that used to be answered under a squeezed limit, within about 8,192 tokens of the declared window. Anthropic's wording for that refusal is not among pi's overflow patterns, so there it is a failed turn, not a compaction and retry.
- The webhook still reports a task whose reply was cut at the output limit as "completed".
- The over-window row and the compaction row of a second ask are execution records the app already draws; neither has been looked at on screen yet, and the inspector shows a second ask's last line, not its instruction.
- A guard against compactions that succeed while a task repeats itself is described in `Design.md` and not built.
- `SubagentCodexIntegrationTests.testNamedForkSiblingQueueReceivingTurnAndInterrupt` fails on 0.1.135 to 0.1.137 (app-hosted; not run headless).

## Release

To be written after the on-screen gate and signing.
