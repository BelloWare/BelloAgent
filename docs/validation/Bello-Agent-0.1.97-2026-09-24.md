# Bello Agent 0.1.97 validation

Date: 2026-09-24. Version 0.1.97, build 101, arm64 macOS 14+.

## Changes

- **Footer form** (`4d233b2`).
  - At some widths (1,120–1,160 pt on the test's sweep) the footer switched between one row (30 pt) and two (48 pt) as a run changed phase or its clock stepped.
  - The run line now takes a fixed 220 pt slot, and its clock reserves the width of `00m 00s`.
  - `SessionTimingTests.testTheFooterKeepsItsFormThroughARunsPhasesAndClockSteps` sweeps 600–1,600 pt; it failed on the old code.
- **Composer height** (`4afaaeb`).
  - The field reported its height through view state, one update behind the text.
  - SwiftUI also treats an AppKit view's intrinsic height as a minimum, so the field grew but did not shrink.
  - Its height now comes from `sizeThatFits` on the scroll view, with the intrinsic size invalidated when the text's height changes: 44–240 pt.
  - `ComposerSubmissionTests.testTheFieldTakesItsHeightFromItsText` covers growth, the ceiling and the shrink after a clear.
- **Git panel during builds** (`bbf7ce6`).
  - Writes into ignored folders (read with `git ls-files --others --ignored --exclude-standard --directory`) no longer start a refresh.
  - An automatic refresh under way finishes, and one more runs after it, instead of restarting at every change.
  - FSEvents paths keep `/private` while resolved roots drop it; both are compared without it.
  - Tests: `GitWorkingTreeWatcherTests` (an ignored folder's writes, a slow refresh while the tree keeps changing, and which paths an ignored entry covers).
- **Helper memory** (`4e7d660`).
  - A chat whose display is let go of (more than eight loaded) now has its idle helper session closed; its journal stays and the next open reads it back. The next open waits for a close in flight. Busy chats, unkept sides and chats with an open Inspector window keep theirs.
  - A prepared context preview (up to 32 MiB) is let go of when it expires (300 s), not only when it is read again.
  - The journal hands its parsed records over once at open, instead of keeping a second parsed copy while the session is loaded.
  - Tests: `WorkspaceRefreshLifecycleTests.testEvictingAnIdleDisplayClosesItsHelperSessionBeforeItOpensAgain`, `ContextPreviewTests.testAPreviewIsReleasedAtItsExpiryWithoutBeingReadAgain`, and a held-records assertion in `AcceptanceTests`. Each failed with its fix removed.
- **Composer after a resize** (`539fe47`). The first gate caught `InlineSkillPillTests.testNarrowComposerWrapsTokensLikeWords`: widening a window that had wrapped three skill tokens onto a second row left the field 54 pt tall instead of 44. A height change reported inside SwiftUI's layout pass (the text rewrapped for the new width) was not taken up by that pass. The height is now asked for again once the pass is over.
- **A live chat with a gap** (`1888559`).
  - A reply longer than the live page (256 KiB) comes in a page that starts after the message it answers. A chat that sent that message a moment ago may not have the helper's row for it yet.
  - Such a page did not join the rows shown, so the chat switched into history mode: it stopped at the previous reply behind the "newer" edge until the reader pressed it.
  - A reader at the live end now has the gap read in at once (the newer-page read, at most four pages, after waiting up to 2 s for a first presentation or a read under way), which returns the chat to the live tail. A reader who scrolled up keeps the edge, as before.
  - Found by the gallery's scene 20 (a 120 KiB reply right after a question), which failed in 3 of 5 full-gallery runs. A diagnostic run showed the page `[ledger, reply]` following the just-sent question while the chat held the turn before. Whether the question still fit on the page depended on how the stream was chunked.
  - Tests: `WorkspaceRefreshLifecycleTests.testALivePageThatLeavesAGapIsFilledForAReaderAtTheLiveEnd` (failed with the fill removed) and `testALivePageThatLeavesAGapWaitsForAReaderWhoScrolledUp`.
- **Test stability** (`8655cfb`): `ConversationPaneTests.testTwoChatsStreamingAtOnceFollowTheSelection` waits for the live bar after a chat switch (on 0.1.96's code it failed 1 run in 5; 8 of 8 passed after).

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on `1888559`, the tree released:
  - serial lane: 208 tests, 7 skipped, 0 failures;
  - parallel lane: 1,410 passed, 13 skipped, 0 failed;
  - gallery: 112 screenshots, 0 failures;
  - helper: 434 tests;
  - scripts: wire 32, concurrent 3, acceptance 2, Python 65;
  - 11 min 9 s.
- **First gate run** on `4e7d660`: the serial lane (208), the helper (434) and the script checks passed. Two things failed:
  - the parallel lane's `InlineSkillPillTests.testNarrowComposerWrapsTokensLikeWords`, fixed by `539fe47`;
  - the gallery's scene 20, fixed by `1888559`. Scene 20 failed in 3 of 5 full-gallery runs (the gate's and four diagnostic runs) and passed alone. The last diagnostic run logged the gap.
- The "AttributeGraph: cycle detected" lines in the gallery log predate 0.1.5, and are not failures.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed; in the mid-run scenario, 10 of 10 markers were recalled. Reported cost $2.28 of the fixture's $5.00 cap (synthetic).

## Release provenance

- **Source:** tag `v0.1.97`. `release/0.1.97` was merged into main with `--no-ff` (7 commits since 0.1.96), followed by one release commit.
  - The release commit before these docs, `10fe22f`, has native tree `a39f3b64ca599fc9e9dd7ae2e7a1accf64f87a90` and helper tree `075d018b652194ada51f85c78b5a7944e20c98eb`. The DMG was built from it.
  - Only release-provenance documentation changed after the candidate build.
- **Website publication:** `024bdd6`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `dd9e397a-975d-4ed0-ac11-435aac2f122e`; DMG `f4a33ef7-bd9c-4a86-a022-a55e7e682f90`.
- **Public verification** at **2026-09-24 14:38:05 UTC**: the product page advertises 0.1.97, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,848,082 bytes (10.35 MiB)**; SHA-256 `98a9971df7fa8f8c61f8294122b29b8c41b23639532be3373caea16c09ecf3eb`.
- **Download:** [Bello Agent 0.1.97](https://belloware.com/assets/BelloAgent-0.1.97.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
