# Bello Agent 0.1.117 — Mac validation handoff

All new development remains local on `dev/next` under the owner's 2026-10-01 instruction. No new feature commits have been pushed. The four earlier Quick Open commits were already upstream before that instruction. Published history and `main` are unchanged.

The implementation checklist is updated in [NEXT-RELEASE.md](../NEXT-RELEASE.md). Validation is now running on this Mac after the owner delegated the remaining decisions. The focused helper run passed 47 tests (one skipped), and CheckNextTests passed 4 tests. Native compilation passed. The first full gate at `ad8cdac` passed 580 helper tests (6 skipped), the views package and wire/script suites, and rendered 172 gallery images. Five native cases failed: a delayed word-selection regression, image pixel dimensions, reply-link fixture teardown, a view-equality inventory and workspace-sheet cleanup. Corrections are being checked before the final gate, Release soak, signing and publication. A checked implementation item does not mean its validation passed.

The narrow Changes checklist item is validated: GitPanelWidthTests passed 3 tests and ChangesTabFrameTests passed 7 tests, including all three window sizes. The required file, preview, reply-link and Quick Open scenes were reviewed in light and dark; no layout corrections were needed. First-run logs and images are preserved under `~/Library/Caches/BelloAgentNext/verify-logs-first-0.1.117` and `gallery-first-0.1.117`.

The corrected native checks passed: FileTabTests/ReplyFileLinkTests/TranscriptViewEqualityTests (19 combined), FileTextViewTests (42), PiSheetWindowTests (10) and MarkdownStreamingCorrectnessTests (12). The sheet class also passed the parallel diagnostic lane. A timing failure in that lane placed the median-based markdown tests in the serial lane; the original bounds passed there. These focused checks precede the final full gate.

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

## Owner checks and decisions

- Open a retained fork made by 0.1.116 or earlier and compare its transcript, context, versions, origin and cost. ForkCloneTests adds generated copied-format coverage, but that is not a claim that the retained-data check has passed.
- Turn VoiceOver on in the file viewer for a minute: move through lines, select and copy text, use Find and Go to Line, and open a linked file.
- The owner delegated the four decisions. NEXT-RELEASE.md records the chosen shortcut, Changes-window and saved-side behaviours and their regression tests.
- Review [0.1.117 release notes](../releases/0.1.117.html), including partial fork loading and older apps' interpretation of the new cost-reset field.

## Packaging and website

`project.yml` and the regenerated project are prepared and committed for 0.1.117/build 121 (the public 0.1.116 feed used 120). Once the remaining checks are complete, package this committed candidate. Incorporate the release into `main` only as the release step, preserving all commit identities. The owner's instruction permits pushes at that point.

Follow [docs/Release.md](Release.md) for the exact signing/notarization/stapling, monotonic-build validation and publication sequence. `scripts/publish-release.sh 0.1.117` updates the sibling `../belloware.com` repository's product page, homepage, sitemap, icon, DMG and identical `bello_agent.appcast.xml` / `pi_app.appcast.xml` feeds, then commits and pushes its configured upstream. The canonical domain is **belloware.com**.

Run `scripts/verify-published.py` after deployment; record downloaded SHA-256, Ed25519 verification and equality of both public feeds. Push the final validation-record commit and `v0.1.117` tag. Do not mark the release complete before public verification. Existing release instructions skip installation/update rehearsals unless the owner asks for them.
