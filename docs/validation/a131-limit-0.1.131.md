# LIMIT-1: a raised cost limit that the helper never got — 0.1.131

Workstream `dev/a131-limit`, base `dev/next` f65c31a9. Xcode 16.1, macOS 14.8 on the shared Mac. Generated fixtures and loopback gateways only; no installed app, real preferences, chats, credentials, Keychain or paid provider. Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-limit`; text evidence in its `evidence/` (probes, not committed) and `logs/`.

Owner, 2026-10-22: "when a session is reaching its cost limit and I click $100, it doesn't work. It doesn't, I mean, it got switched to $100, but I couldn't resume it. But if I switch it to like $50, it works."

## Verdict

- **No amount is special.** Every amount above the spend resumes, $100 included, through the owner's own steps (Raise limit…, a chip or a typed amount, the card's Resume), for a plain chat, a chat with a sub-agent and a chat with a side. Amounts at or below the spend keep the pause. App and helper compare the limit and the spend as numbers everywhere (`SessionCostReading.reached`, `AgentSession.enforceCostLimit`); no text comparison, preset index or bound depends on the amount.
- **What the owner saw is one state: the chat shows the new limit and its helper still holds the old one.** The card offers Resume by the chat's limit; the helper refuses Resume by its own (`requireCostResumeRoom`), and the line under the composer keeps saying "Raise the limit above the spend". Nothing repaired that state. Only another choice sent a limit again: "if I switch it to like $50, it works".
- **How a chosen limit failed to reach the helper.** `setCostLimit` sends the limit (`sendCostLimit`) in its caller's task, after the save. The Raise limit… editor runs the choice in a task it cancels when it goes away (`CostLimitEditor.deinit`). Its popover goes away on a click outside it (on the Resume the card offers as soon as the limit is saved), on Escape, and by itself: AppKit closed it 504 ms after its anchor, the Raise limit… pill, left the window (`evidence/probe-anchor.log`), which the saved limit does when it turns the card to Resume. A send from a cancelled task never leaves (`HostSupervisor.requestFrame` checks cancellation first, and a request still waiting for one of the 32 command slots is removed). `sendCostLimit` had already recorded the limit as sent, so snapshots never sent it again (`observeCost` re-sends only "a limit not yet tried"), and Resume never checked the helper's limit.
- **Not proven:** the exact trigger in the owner's session. The loss needs the editor gone before the send leaves: the save still writing (a busy store) or the helper's command slots full (a busy helper), which the other 0.1.131 reports (slow opens and edits) make plausible. The failing tests reproduce the state deterministically through the same cancellation.
- **Fix.** (1) The saved choice reaches the helper whatever becomes of the caller. (2) Resume gives the main chat's helper the chat's limit first when the two differ, for a plain chat and its whole family.

## Reproduction

`fixtures/native/wire_gateway.py` reports a chosen cost when the message carries `usd=X` (unchanged otherwise). The owner's pause: the chat follows the $25 default, "wire paid usd=24.99" spends $24.99, then "wire paid-tool usd=0.02" crosses ($25.01) with its bash call held. The amount is chosen in Raise limit…'s popover and the card's Resume pill is pressed (`evidence/probe-matrix.log`):

| Choice | Chat | Helper | Card | Resumed |
| --- | --- | --- | --- | --- |
| $5, $10, $25 chips | $5 / $10 / $25 | same | Raise limit… | no, as it must |
| $50, $100 chips | $50 / $100 | same | Resume | yes, held call ran |
| typed 100, 99.99, 150, 1000 | same | same | Resume | yes |

Families on the UI fixture gateway, default $0.002, raised in the popover, Resume on the card (`evidence/probe-family*.log`): a sub-agent family and a side family each resume at $100 and at $50. The unchanged popover path also resumes when the popover closes during a held store write in XCTest (`evidence/probe-close2.log`): XCTest keeps closed popovers' content alive (the editor was still alive 3.7 s later), so the editor's cancellation does not happen there; the tests below apply it themselves.

## Fix

- `WorkspaceModel.setCostLimit` (`WorkspaceCostLimits.swift`): the send runs in its own task, awaited as before, so the caller's cancellation cannot stop it.
- `WorkspaceModel.resumeCostPausedFamily` (`WorkspaceResume.swift`), which every Resume of a chat paused at its cost limit goes through, plain or family: `rootCostPause` also returns the limit the main chat's helper reports (`limitUSD`); when it differs from the chat's, the helper is sent the chat's limit, in a send a Stop meanwhile does not cut short, before the main chat and its sides are resumed. A Resume already retired (Stop, Archive) sends nothing; a helper that reports no `limitUSD` is left alone. Nothing resumes while the spend is still at the chat's limit (unchanged: the app's check, then the helper's).
- Helper, wire contract and pause semantics are unchanged.

## Tests

Native, new (`apps/macos/PiAppTests`):

- `CostLimitTests.testEveryAmountAboveTheSpendResumesFromRaiseLimit`: the owner's steps with the $25 chip (pause kept, Resume refused, nothing ran), the $50 and $100 chips and typed 99.99 and 1000 (each resumes; the held call runs). Passes before and after: the amount was never the cause.
- `CostLimitTests.testA100LimitWhoseEditorWentAwayMidSaveStillReachesTheHelper`: $100 chosen while the store write is held; the task running the choice is cancelled, as the editor's `deinit` cancels it; the helper must hold $100 before any Resume, and the card's Resume goes on.
- `CostLimitTests.testResumeGivesAHelperStillUnderTheOldLimitTheChatsLimitFirst`: $100 saved and sent, then the helper put back to $25 (as a lost send leaves it); the card's Resume goes on.
- `CostPauseFamilyTests.testAFamilyResumeGivesTheChatsHelperItsRaisedLimitFirst`: a chat and its side paused together; $100 saved, the chat's helper put back to the old limit; Resume from the side resumes the chat and the side, each sending its next request, and the chat's helper ends up under $100.

Failing first on the unchanged app (`evidence/red-base.log`, 4 tests, 7 failures):

- `testA100LimitWhoseEditorWentAwayMidSave…`: "("usd(25.0)") is not equal to ("usd(100.0)") - The saved limit reached the chat's helper before any Resume", then Resume timed out with the chat paused.
- `testResumeGivesAHelperStillUnderTheOldLimit…`: Resume timed out (state paused, notice "Paused at the cost limit: $25.01 spent of $25.00. Raise the limit above the spend, then choose Resume.").
- `testAFamilyResumeGivesTheChatsHelper…`: neither went on; the helper still held $0.002.
- `testEveryAmountAboveTheSpend…`: passed.

Mutations (each built and run against the three tests of the fix, `evidence/mutation-m*.log`):

| Mutation | Detected by |
| --- | --- |
| m1: the limit is sent in the caller's task again (fix 1 removed) | `testA100LimitWhoseEditorWentAwayMidSave…`: "("usd(25.0)") is not equal to ("usd(100.0)") - The saved limit reached the chat's helper before any Resume" (its Resume then goes on through fix 2) |
| m2: Resume does not give the helper the chat's limit (fix 2 removed) | `testResumeGivesAHelperStillUnderTheOldLimit…` (Resume timed out, paused) and `testAFamilyResumeGivesTheChatsHelper…` (neither went on; the helper still held $0.002) |

Validation on the fixed build. Owner's scope rule (2026-10-22): the new tests and the classes that exercise `setCostLimit` or the cost-paused Resume; no helper, wire or full-lane runs (neither the helper nor the wire contract changed).

| Run | Result |
| --- | --- |
| Serial, under the lane lock: `CostLimitTests`, `CostPauseFamilyTests` (`logs/green-serial.log`) | 20 tests, 0 failures (16 + 4, the 4 new ones included) |
| Parallel lane, 4 workers: `CostPausePresentationTests`, `SideBudgetIntegrationTests`, `SubagentCostTests`, `SubagentTranscriptTests`, `WorkspaceRaceTests` (`logs/green-parallel.log`) | 111 passed, 0 failed (6, 18, 11, 11, 65) |
| Serial, alone, under the lane lock: `LifecycleHelperTests/testRecoveredSavedSideOpensWithoutItsParentAndHasAnEditableIndependentLimit`, the class's one use of `setCostLimit` (`logs/green-lifecycle.log`) | 1 test, 0 failures |

## Found on the way, not changed

- After a raise, the line under the composer keeps the helper's pause-time text ("Paused at the cost limit: $25.01 spent of $25.00. Raise the limit above the spend, then choose Resume.", `AgentSession.costPausedMessage`, shown through `applyToolNotice`, `WorkspaceRefresh.swift:365`) until Resume, while the card says the limit is raised and offers Resume. It may have added to the confusion; it is a helper message, outside this change.
- `sendCostLimit` still records a limit as sent before the helper confirms it, by design (a failed send is not retried from snapshots, so a quiesced helper is not flooded). With the send no longer cancellable, and Resume sending the chat's limit, a raise whose send fails no longer blocks Resume; a lowered limit whose send fails stays unsent until the next change or Resume.
