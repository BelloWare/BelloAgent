# Bello Agent 0.1.117 — Mac validation handoff

**Release completed.** 0.1.117/build 121 is published at [belloware.com](https://belloware.com/bello-agent.html), with source on `main` and tag `v0.1.117` at `3fdb62b`. Website commit: `a109c15`. Public product-page equality, installer SHA-256/Ed25519 and identical canonical/legacy feeds passed at **2026-10-01 06:38:03 UTC**. The documented soak limitation and deferred checks below remain actual release limitations, not passing results.

Development stayed local on `dev/next` until release. On 2026-10-01, after receiving the failed-soak and pending owner-check summary, the owner instructed: "push to main, and belloware.com, lets just release it". Publication is authorized with the documented soak limitation accepted and the manual VoiceOver and real-gateway checks deferred. Preserve published history and fast-forward `main` as part of release.

The implementation checklist is updated in [NEXT-RELEASE.md](../NEXT-RELEASE.md). The final full gate at `76bfb27` passed both native lanes, all 580 helper tests (6 skipped), the 110-test views package (3 skipped), wire/script checks and all 172 gallery captures. The optimized build compiled testable FileView/GitView modules; all 7 Release ChangesTabFrameTests and all 3 synthetic compaction scenarios passed. The hour-long Release soak failed on six graphics/font-cache pauses above 250 ms, with no idle-row jumps, slow launches or quit failures in 190 launches. A same-seed two-minute replay reproduced the early graphics pause. The signed, notarized candidate is now published with the owner's accepted limitation and deferrals recorded. [The release validation record](validation/Bello-Agent-0.1.117-2026-10-01.md) contains the complete evidence and earlier failures/corrections.

The narrow Changes checklist item is validated: GitPanelWidthTests passed 3 tests and ChangesTabFrameTests passed 7 tests, including all three window sizes. The required file, preview, reply-link and Quick Open scenes were reviewed in light and dark; no layout corrections were needed. First-run logs and images are preserved under `~/Library/Caches/BelloAgentNext/verify-logs-first-0.1.117` and `gallery-first-0.1.117`.

The corrected native checks passed: FileTabTests/ReplyFileLinkTests/TranscriptViewEqualityTests (19 combined), FileTextViewTests (42), PiSheetWindowTests (10) and MarkdownStreamingCorrectnessTests (12). The sheet class also passed the parallel diagnostic lane. A timing failure in that lane placed the median-based markdown tests in the serial lane; the original bounds passed there. These focused checks precede the final full gate.

The second gate at `deedae6` passed all 327 serial tests, the helper/package/wire/script checks and the 172-image gallery. Its parallel lane passed 1,631 tests and failed one Changes resize-redraw test. Commit `0965b98` makes that fixture await the complete initial Git refresh and settle layout by elapsed time; GitPanelRedrawTests then passed all 3 tests. Second-run logs and images are preserved in `verify-logs-second-0.1.117` and `gallery-second-0.1.117` under the same cache directory.

The third gate at `397c300` passed both native lanes (327 executed serial, 1,632 passed parallel; 17/18 skipped), the views package (110 executed, 3 skipped), wire/script checks and all 172 gallery images. Its sole failure was StreamingCostTests' process-wide heap measurement; all 5 tests then passed alone with the original bounds. The gate now runs this class alone in a fresh helper-test process before the gallery, then runs the remaining helper classes alongside it. VerifyReleaseTests passed 2 tests for ordering and failure handling. Third-run logs and images are preserved separately too. [The release validation record](validation/Bello-Agent-0.1.117-2026-10-01.md) tracks subsequent checks and publication.

Old-helper interoperability passed on 2026-10-01. The downloaded published 0.1.116 DMG matched SHA-256 `d2a8337a2642d8427798061a1792d9c515ce739298f5527147b4222812a9ecbb`; its app metadata was 0.1.116/build 120 and its deep strict code-signature check passed. Only the helper was extracted from a read-only mount. It created whole-chat and reply-point forks after an edited synthetic conversation, then added a billed fixture follow-up to each. The candidate helper reopened each twice: messages (9 and 6 rows), context, origin, version groups, the whole-chat historical edit page and $0.0123 fixture cost remained identical. Each journal remained byte-identical. Runtime incarnation UUIDs were excluded from history-page comparison because they change on every open. The runner, log and JSON report are retained in `~/Library/Caches/BelloAgentNext/compat-0.1.116/`. The published app was never installed or launched.

## Prepare the project

Stay on `dev/next` in the source checkout. XcodeGen must include the new source and test files before the release gate, which refuses an uncommitted generated-project difference. Generate with XcodeGen 2.44.1, inspect the resulting project diff, and commit only the generated project:

```sh
xcodegen generate --quiet
git diff -- PiApp.xcodeproj
git add PiApp.xcodeproj
git commit -m 'Regenerate the next-release Xcode project' \
  -m 'Check: QuickOpenTests, ChangesTabTests, FileTabTests, FileSyntaxTests, ReplyFileLinkTests; helper and gallery required.'
```

Keep this commit local too. Do not discard other local changes. If the project is already current, there is no regeneration commit to make.

## Focused checks

`PI_NEXT_REF=dev/next` checks the local committed branch without fetching. The script resolves that ref once and prints the checked commit; all commands in one invocation use that commit in a separate worktree under `~/Library/Caches/BelloAgentNext`. Its normal default still fetches `origin/dev/next`, which lacks these local commits.

Run the native classes one invocation at a time so focus and timing checks have the machine to themselves:

```sh
PI_NEXT_REF=dev/next scripts/check-next.sh
PI_NEXT_REF=dev/next scripts/check-next.sh test QuickOpenTests
PI_NEXT_REF=dev/next scripts/check-next.sh test WindowPresentationTests
PI_NEXT_REF=dev/next scripts/check-next.sh test TabHostTests
PI_NEXT_REF=dev/next scripts/check-next.sh test GitPanelWidthTests
PI_NEXT_REF=dev/next scripts/check-next.sh test ChangesTabFrameTests
PI_NEXT_REF=dev/next scripts/check-next.sh test GitDiffTableTests
PI_NEXT_REF=dev/next scripts/check-next.sh test ChangesTabTests
PI_NEXT_REF=dev/next scripts/check-next.sh test ReplyFileLinkTests
PI_NEXT_REF=dev/next scripts/check-next.sh test ChatFileLinkTests
PI_NEXT_REF=dev/next scripts/check-next.sh test TranscriptActionsForwardingTests
PI_NEXT_REF=dev/next scripts/check-next.sh test FileSyntaxTests
PI_NEXT_REF=dev/next scripts/check-next.sh test FileTextViewTests
PI_NEXT_REF=dev/next scripts/check-next.sh test FileTabTests
PI_NEXT_REF=dev/next scripts/check-next.sh test FileFindTabTests
PI_NEXT_REF=dev/next scripts/check-next.sh helper
```

ChangesTabFrameTests exercises 1280×820, 580×800 and the default 820×640 window. The helper suite includes HistoryFillTests, HistoricalEditTests, MessageVersionTests, OlderRowsTests, ForkCloneTests and ForkReplayHandoffTests. The package suite includes FileDocumentTests and its unchanged default symlink behaviour; file tabs opt into refusing redirected paths.

The check-script regression class can also run independently, without builds or network access:

```sh
python3 -m unittest discover -s scripts/tests -p test_check_next.py
```

## Full gate and gallery

After fixing any focused failures, run the gate alone:

```sh
PI_NEXT_REF=dev/next scripts/check-next.sh gate
```

It runs the full native lanes, helper/package/wire/script suites, and gallery. Logs are under `~/Library/Caches/BelloAgentNext/build/verify-logs`; gallery images are under `~/Library/Caches/BelloAgentNext/build/verify-gallery/screenshots`.

Review both appearances for `10c-changes-window-narrow`, `24-tabs-file`, `24b-tabs-window`, `24f-image-preview`, `24g-pdf-preview`, `24h-reply-file-link`, `25-quick-open`, and `25a-quick-open-recent`. Check syntax colours, Pi spacing, native previews, reply-path appearance, and Quick Open focus/placement. Narrow Changes must retain the same chosen file, first visible row, diff position and commit draft.

## Release testability and one-hour soak

Use the same checked worktree and helper bundle. This build must compile the test bundle's `@testable import FileView` and `GitView`. Do not run other builds/tests alongside the soak.

```sh
cd "$HOME/Library/Caches/BelloAgentNext/worktree"
export PI_BUILD_ROOT="$HOME/Library/Caches/BelloAgentNext/build"
NEXT_RELEASE_DD="$PI_BUILD_ROOT/next-release-tests"
NEXT_RELEASE_XCODE=(-project PiApp.xcodeproj -scheme PiApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$NEXT_RELEASE_DD" \
  ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO)
xcodebuild build-for-testing "${NEXT_RELEASE_XCODE[@]}"
xcodebuild test-without-building "${NEXT_RELEASE_XCODE[@]}" \
  -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
TEST_RUNNER_PI_SOAK_SECONDS=3600 \
  TEST_RUNNER_PI_SOAK_REPORT="$PI_BUILD_ROOT/soak-0.1.117.txt" \
  xcodebuild test-without-building "${NEXT_RELEASE_XCODE[@]}" \
  -parallel-testing-enabled NO -only-testing:PiAppTests/SoakTests
python3 scripts/soak-symbolicate.py "$PI_BUILD_ROOT/soak-0.1.117.txt" \
  --dsym-root "$NEXT_RELEASE_DD/Build/Products/Release"
```

Keep the checked SHA, toolchain versions, pass/fail logs and soak report. If source changes after a failure, record the new SHA and rerun affected checks; the final gate and soak must cover the release candidate.

The first hour at `76bfb27` ran 3,606 s with seed `1790822043708` and failed on six 264–539 ms pauses. The 122 s replay failed on a 431 ms pause during cycle 2, step 8 (long streamed reply), matching the first run's early pause. Keep the 250 ms limit; do not treat these as passing runs. The captured stacks show Core Animation/window-server synchronization and CoreGraphics font-cache locks. The 0.1.115 record describes the same classes of pauses. The owner accepted this limitation for 0.1.117 when authorizing publication. Investigation remains follow-up work; a future quiet-desktop run should pause unrelated animation/recording and run no other builds/tests.

## Owner checks and decisions

- Old-helper interoperability and ForkCloneTests passed as recorded above. A retained owner fork can provide additional coverage; the release checklist did not require owner data specifically.
- The owner deferred the manual VoiceOver exercise for this release. Future check: move through lines, select and copy text, use Find and Go to Line, and open a linked file with VoiceOver enabled.
- The owner deferred the real-gateway compaction check for this release. A future run must use designated test settings or the `PI_LIVE_*` environment variables; do not obtain production vault credentials through CLI tools. The synthetic rehearsal passed, and its report is retained in `build/live-e2e/20261001T023249Z/`.
- The owner delegated the four decisions. NEXT-RELEASE.md records the chosen shortcut, Changes-window and saved-side behaviours and their regression tests.
- Review [0.1.117 release notes](../releases/0.1.117.html), including partial fork loading and older apps' interpretation of the new cost-reset field.

## Packaging and website

`project.yml` and the regenerated project are committed for 0.1.117/build 121 (the public 0.1.116 feed used 120). A local candidate was packaged from `6218b86`; its app code is identical to the gated `76bfb27`. The app and DMG were signed, notarized and stapled, Gatekeeper accepted them, and the feed's Ed25519 signature passed. The installer is 12,268,767 bytes (11.70 MiB), SHA-256 `c7222bf7ffeadf0c1bc4427ca6dcf5f595aa0d8de5df01efaddf06cff90d973a`.

The released app is `~/Library/Caches/BelloAgentNext/build/releases/0.1.117/Bello Agent.app`; the installer is alongside it as `BelloAgent-0.1.117.dmg`. Packaging logs are in `~/Library/Caches/BelloAgentNext/build/release.YgIk64` and `~/Library/Caches/BelloAgentNext-package-0.1.117.log`. Artifact validation against build 120 and website staging `--check-only` passed. The proposed site files and exact diff are under `build/site-preview-0.1.117`; the product page was reviewed locally and the new feature copy fits its existing card. Website publication used commit `a109c15` and the public page matches its committed bytes exactly.

Keep the released artifact directory immutable. Future product fixes require a new version and fresh release artifacts. Source was incorporated into `main` by fast-forward, preserving every existing commit identity, under the owner's release instruction.

Follow [docs/Release.md](Release.md) for the exact signing/notarization/stapling, monotonic-build validation and publication sequence. `scripts/publish-release.sh 0.1.117` updates the sibling `../belloware.com` repository's product page, homepage, sitemap, icon, DMG and identical `bello_agent.appcast.xml` / `pi_app.appcast.xml` feeds, then commits and pushes its configured upstream. The canonical domain is **belloware.com**.

`scripts/verify-published.py` passed after deployment: the public installer hash and Ed25519 signature match, and both public feeds are byte-identical. The first attempt still saw 0.1.116 while deployment caught up; the second passed. Logs are `~/Library/Caches/BelloAgentNext-public-0.1.117-{first,second}.log`; verified downloads are under `build/public-0.1.117-second`. The release tag and final validation record are pushed. Installation/update rehearsals remain skipped under the owner's standing instruction.
