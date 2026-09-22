# Bello Agent 0.1.83 validation

Date: 2026-09-22. Version 0.1.83, build 87, arm64 macOS 14+.

## Confirmed lifecycle bugs

This audit followed completion/timing state from the helper's task receipts through native refresh, turn reports, copied info, request-detail ownership and the status monitor. It fixes reproduced problems; it is not a claim that every possible app bug has been eliminated.

1. A snapshot requested inside the live metrics throttle could observe a completed run while omitting its final metrics. If no further event arrived, timing and latest-request data remained stale. Transitioning out of a busy state after a metrics-free poll now schedules one final read. The regression controls the actual native host command/reply boundary, withholds any later event, and checks both final values and the absence of a refresh loop.
2. Some turn labels and copied summaries still tested the raw live flag after the duration clock had been changed to honor terminal evidence. They could say Pending, In progress or Still running for a completed/failed/stopped task. All these presentation decisions now use the same `isRunning` rule. The regression covers completed, failed, cancelled, interrupted and output-limited outcomes.
3. A reused request-detail controller retained the previous turn's records while fetching another execution and after a failed lookup. The controller now scopes retained records and selection to the session and execution, clearing them before a different owner's lookup. New replies and the finish timestamp within one execution preserve the reader's selection. Same-turn refresh failures may retain that turn's own data; cancelled/superseded reads remain rejected.
4. A successful unchanged monitoring poll returned before clearing the workspace's disconnected state. The connection warning could therefore persist despite successful communication. Successful polls now clear it without replaying or double-counting completed requests.
5. Removing the final monitored session of a disconnected project retained its warning indefinitely. Retiring the final session now removes that disconnected workspace. Other sessions/projects remain unaffected.

## Evidence

- Five new regression cases were run against the unmodified 0.1.82 application code and all five failed on the scenarios above. The final-metrics case timed out waiting for the missing second read; the remaining failures were state/data assertions.
- After the fixes, the same five cases passed.
- Expanded native selection: **71 passed, two optional visual tests skipped, zero test failures** (73 registered). Suites: TurnDurationClockTests, TurnInfoTests, TurnRequestPopupTests, CompactTurnReportTests, LivePopupTests, LiveMonitorTests, MenuBarPresentationTests, WorkspaceRefreshLifecycleTests and WorkspaceFailureTests.
- Includes exact completed-clock preservation, paced live updates, terminal outcome variants, unchanged-page deduplication, cross-session disconnect retirement, selection preservation through completion, stale async result rejection, native popup lifecycle, the 20-stream/10,000-chat status fixture, and actual helper calls to a local Responses mock gateway after reopening/paging a chat.
- Xcode 16.1, Debug with Swift 6 strict concurrency and actor data-race checks. The full regression command exited zero with `TEST SUCCEEDED`; Xcode subsequently warned that its optional xcresult activity-log bundle could not be fully saved (`mkstemp: No such file or directory`). The complete textual per-test results are retained in the session scratch log. This is a reporting-artifact limitation, not a test failure.
- Logs: `tmp/claude-ui-079/lifecycle-audit-083-before.log`, `lifecycle-audit-083-fixed.log`, and `lifecycle-audit-083-regression.log` under the current remote session's temporary folder. No production credentials or conversations were used in these fixtures.
- Helper/provider source is unchanged, so its previously passing gateway and accounting checks are reused. No deployed-gateway compatibility or universal performance claim follows from these focused tests. Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.

## Release provenance

- Source: tag `v0.1.83`; native tree `a18f805cf20316dea457107bee04999952429ab7`, unchanged helper tree `21c72b240da9f9c1b769d183919444c81c09c0a1`. Only release-provenance documentation changed after the candidate build.
- Website publication: `9b7fee6c53254814dbf1d9a69dfa4dc7b6ca33ab`; Cloudflare check `106813441104` completed successfully.
- Optimized native build, packaged offline helper/catalog smoke, Developer ID signing, app/DMG notarization, stapling, Gatekeeper and Sparkle artifact validation passed.
- Accepted notarizations: app `12b88351-3030-49d7-9c2b-2ecc9199ad2a`; DMG `b74ced6e-9f55-4e37-816f-79574f308ac8`.
- Public verification at **2026-09-22 15:29:58 UTC**: product page advertises 0.1.83, canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- DMG: **9,442,648 bytes (9.01 MiB)**; SHA-256 `03609f740f43f3213ada0b42ad3014eda2f6b86fd00f120ce9dc2bebd0b2eb16`.
- Download: [Bello Agent 0.1.83](https://belloware.com/assets/BelloAgent-0.1.83.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
