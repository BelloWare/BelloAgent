# Bello Agent 0.1.117 — file tabs, Quick Open, Changes tabs and faster forks

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.117, build 121. Public verification completed at **2026-10-01 06:38:03 UTC**. Tagged source: **`3fdb62b561a32755ccecad16a02302dab0d891dc`**, `v0.1.117`. Website: **`a109c15f8e77d3d41226d358875f9916e444fcae`**. The owner authorized release with the documented graphics/font-cache soak limitation accepted and the manual VoiceOver and real-gateway checks deferred. Previous public release: 0.1.116/build 120. Starting `main`: `3ba18fe5767bfdf244a1bb89961f0232f1988ecb`.

## Owner release authorization

On 2026-10-01, after receiving the candidate, failed-soak and pending VoiceOver/real-gateway summary, the owner instructed: "push to main, and belloware.com, lets just release it". Proceed with the already validated signed candidate, preserve the failed soak as a known limitation, and record both unperformed owner checks as deferred. This supersedes the earlier keep-local instruction for release publication. No test result or threshold is changed by this decision.

## Scope

The release adds native file tabs and separate windows, Find and Go to Line, visible-line syntax colours, live file following, and PDF/image previews. Quick Open uses the current window, preserves text-field selection, waits for the current query, and reports incomplete or failed listings. Reply code paths and diff-line menus open trusted files at the requested line.

Changes opens as a tab, stacks the file list above the diff below 900 pt, and opens new windows at 1040×720. Ordinary file windows remain 820×640. Saved side conversations join Next/Previous Chat in sidebar order, keep their drafts across switches, and open beside their parent. Editable tab text retains its own keyboard shortcuts.

Large forks can open from recent rows while history fills in. Edits and version reads share off-actor history preparation. New forks start their own cost; older readers can include the parent's cost when they ignore the new optional reset field. Existing forks retain their behavior. The helper retains pi 0.85.1 semantics and adds only optional wire fields.

The release notes are in `releases/0.1.117.html`. Product-page copy introduces Quick Open, files beside the chat, and Changes tabs within the existing layout.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1 and XcodeGen 2.44.1. Checks used the committed local ref in a separate worktree at `~/Library/Caches/BelloAgentNext/worktree`; products and evidence live under `~/Library/Caches/BelloAgentNext/build`. Development stayed local until release; source and final validation documentation are now pushed to `main` and `dev/next` under the owner's publication instruction.

- Final full gate at `76bfb27`, **all checks passed in 18 min 20 s**. Native serial: **327 executed, 17 skipped, zero failures**. Native parallel: **1,632 passed, 18 skipped, zero failures**. Isolated StreamingCostTests: **5 passed**; remaining helper suite: **575 executed, 6 skipped, zero failures**. Views package: **110 executed, 3 skipped, zero failures**. Wire 34, concurrent wire 4, acceptance 2 and Python 72 passed. Gallery: **172 images, zero failures**. Isolated accumulation heap growth was 41,472 bytes, below the original 65,536-byte bound. Final logs and captures are retained in `verify-logs-final-0.1.117` and `gallery-final-0.1.117` beneath the cache root.
- Third full gate at `397c300b7884acbf23a1aad378979f6b6f77651f`, 18 min 21 s: native serial lane **327 executed, 17 skipped, zero failures**; native parallel lane **1,632 passed, 18 skipped, zero failures**. Views package **110 executed, 3 skipped, zero failures**; wire 34, concurrent wire 4, acceptance 2, Python 70; gallery **172 images, zero failures**. Helper **580 executed, 6 skipped, one failure**, described below and resolved in the final gate.
- Focused native corrections passed: QuickOpenTests 16, GitPanelWidthTests 3, ChangesTabFrameTests 7, FileTextViewTests 42, FileTabTests/ReplyFileLinkTests/TranscriptViewEqualityTests 19 combined, PiSheetWindowTests 10, MarkdownStreamingCorrectnessTests 12, and GitPanelRedrawTests 3. The final native lanes cover all of these.
- First gate at `ad8cdac` found preview pixel doubling, a Swift-owned window over-release during teardown, a stale view-equality inventory, delayed synthetic selection delivery and a sheet cleanup failure. The preview now keeps its decoded bitmap directly; the other corrections repair test ownership, expectations and delivery. The sheet class subsequently passed alone and in both parallel runs.
- The second gate at `deedae6` passed its serial lane but exposed one resize-redraw fixture measuring before the complete initial Git refresh. Commit `0965b98` waits for that refresh and settles layout over elapsed time. All redraw checks then passed alone and in the final parallel lane. Median-based markdown timing checks now explicitly use the serial lane; their original bounds remain unchanged.
- The third gate's only failure was StreamingCostTests' process-wide heap-growth check: 105,920 bytes against its unchanged 65,536-byte bound, with 103 fewer allocated blocks. All 5 StreamingCostTests passed alone afterward: heap growth 40,576 bytes, early/late accumulation CPU 4.86/4.74 microseconds per delta. The gate now runs this class in its own process before the gallery and excludes it from the second helper invocation. VerifyReleaseTests passed 2 tests for ordering, failure propagation and continuation of later checks. No product code or benchmark bound changed for this correction.
- Reviewed narrow Changes, image preview and reply-file-link scenes again in both appearances after the corrections. PDF, file-tab and Quick Open scenes were reviewed in the first gallery run. Evidence from all three runs is retained in separate cache directories.
- Release build-for-testing at the gated source passed with `ENABLE_TESTABILITY=YES`, compiling `@testable import FileView` and `GitView`. All **7 optimized ChangesTabFrameTests passed** in 67.34 s, including 1280×820, 580×800 and 820×640. Large-repository and workspace-window probes reported zero layout cycles; closed memory was 62.6 MB versus 59.6 MB before the large-repository probe. Logs are `BelloAgentNext-release-build.log` and `BelloAgentNext-release-frames.log` beneath `~/Library/Caches/`.
- Live compaction rehearsal in **synthetic mode passed 3 of 3 scenarios** on the Release helper, including mid-run recall and refusing a history too large for one summary before sending any request. Fixture-reported cost was $0.8336 against its $5 cap; it is not billed cost. Reports are under `build/live-e2e/20261001T023249Z/`. The owner's real gateway is not configured through `PI_LIVE_BASE_URL`, `PI_LIVE_API_KEY` and `PI_LIVE_MODEL`; no real-gateway result is claimed.
- The one-hour Release soak at `76bfb27` ran **3,606 s**, ending at **2026-10-01 03:34:10 UTC**, seed **1790822043708**. It **failed** the unchanged 250 ms main-thread pause check: six pauses of **539, 416, 317, 282, 281 and 264 ms**. Captured stacks show Core Animation/window-server synchronization, CoreGraphics font-cache locks and RenderBox/IOGPU allocation. There were **190 launches**, **zero idle-row jumps**, **zero slow/empty-sidebar launches** and **zero quit failures**; sidebar median/max was **272/489 ms**. Actions included 2,523 selects, 581 rapid switches, 187 short sends and 50 long sends. Footprint went from 504 to 942 MB (2.32 MB per launch); eight recent closed models remained weakly visible, no hosted views, and 190 windows, consistent with the fixture's already documented test-runner window retention. No new product leak is inferred from those numbers. Log: `~/Library/Caches/BelloAgentNext-soak.log`; original and symbolicated reports: `build/soak-0.1.117{,-symbolicated}.txt`.
- A **122 s replay** of the same seed at the same source **failed** with one **431 ms** pause at **32.2 s**, cycle 2 step 8, long streamed reply. That reproduces the first run's early 539 ms pause at 32.6 s. Its stack waits for a window-server graphics fence during a Core Animation commit. Five launches had zero row jumps, slow launches or quit failures. Log: `~/Library/Caches/BelloAgentNext-soak-replay-120.log`; report: `build/soak-0.1.117-replay-120.txt`. WindowServer showed about 65% CPU in a snapshot after the replay; a later snapshot showed 5.9%. This is evidence of variable desktop load, not proof of its cause. No app/test thresholds or rendering code have been changed to dismiss either failure.
- The [0.1.115 record](Bello-Agent-0.1.115-2026-09-30.md) documents 20 pauses above 250 ms in its final hour, in the same graphics/font-cache paths, while its other soak assertions passed. The owner accepted this known limitation for 0.1.117 when authorizing publication; investigation remains follow-up work. The two failed runs above remain failed.
- Native accessibility-interface coverage passed in FileTextViewTests. The owner deferred the manual one-minute VoiceOver exercise and real-gateway compaction check when authorizing publication; neither is claimed to have run.

### Compatibility with the published helper

The public 0.1.116 DMG matched SHA-256 `d2a8337a2642d8427798061a1792d9c515ce739298f5527147b4222812a9ecbb`. Its app metadata was 0.1.116/build 120 and `codesign --verify --deep --strict` passed. Only the helper was extracted from a read-only mount; the published app was never installed or launched.

That helper created whole-chat and reply-point forks after an edited synthetic conversation and added a billed fixture follow-up to each. The candidate reopened both forks twice. The transcript (9 and 6 rows), context, origin, version groups, available historical edit page and $0.0123 fixture cost matched exactly. Reading left both journals byte-identical. History-page runtime incarnation UUIDs were excluded because they change on every open. The runner, log and JSON report are retained under `~/Library/Caches/BelloAgentNext/compat-0.1.116/`. ForkCloneTests also covers copied-journal compatibility across open/reopen.

## Publication

### Local candidate

Packaged from **`6218b86fc7c3184d2532728a5b524b2626d5ab4f`**. Its diff from the gated `76bfb27` contains validation documentation only. The normal `scripts/release.sh` flow completed successfully on 2026-10-01: optimized native/helper build, stripped binaries with retained dSYMs, Developer ID signing, packaged-helper offline smoke, app/DMG notarization and stapling, Gatekeeper validation, signed appcast generation and Ed25519 verification. The smoke checked six packaged catalog models and the native helper protocol without model calls or credentials.

- App notarization: **`f486bf24-b963-4132-9601-bafc67f4fcc1`**, Accepted.
- DMG notarization: **`9d188970-f380-4f61-95b2-4492e61d12ef`**, Accepted.
- Installer: **12,268,767 bytes (11.70 MiB)**, below the 20 MiB target.
- SHA-256: **`c7222bf7ffeadf0c1bc4427ca6dcf5f595aa0d8de5df01efaddf06cff90d973a`**.
- `validate-release.py --previous-build 120` passed: candidate build 121, canonical download URL, archive Ed25519 signature, signed/notarized app, DMG staple and Gatekeeper checks.
- Both local feeds are byte-identical. Website staging `--check-only` passed. Seven proposed site files and their exact text diff are retained in `build/site-preview-0.1.117`; the rendered product page's version, size and new file/Changes copy were reviewed locally. The feature paragraph fits its existing card without overflow. The temporary browser tab/server were closed after review.

Artifacts: `~/Library/Caches/BelloAgentNext/build/releases/0.1.117/`. Logs: `~/Library/Caches/BelloAgentNext-package-0.1.117.log` and `build/release.YgIk64/{build,notary-app,notary-dmg}.log`; offline smoke evidence: `build/release.YgIk64/host-proof.json`. Preserve this candidate directory unchanged. A product fix requires a fresh candidate scratch root and repeated affected validation.

### Source, website and public verification

The approved source was fast-forwarded from the starting `main` to **`3fdb62b561a32755ccecad16a02302dab0d891dc`**, then pushed atomically to both `main` and `dev/next`. This tagged release differs from the packaged `6218b86` only in validation documentation. No published history was rewritten. The annotated tag `v0.1.117` points to this source; the later final validation-record commit is pushed on both branches.

`scripts/publish-release.sh 0.1.117` passed its signed-app/archive/feed and website preflight checks, then committed and pushed website **`a109c15f8e77d3d41226d358875f9916e444fcae`** ("Publish Bello Agent 0.1.117 update"). The commit updates the product page, sitemap, both feeds and installer. Existing homepage/icon/redirect inputs remained current; earlier installers remain available for rollback. Publication log: `~/Library/Caches/BelloAgentNext-publish-0.1.117.log`.

Public verification passed at **2026-10-01 06:38:03 UTC**:

- The canonical and legacy public feeds exactly match the intended local feed and each other.
- The downloaded **12,268,767-byte** installer has SHA-256 **`c7222bf7ffeadf0c1bc4427ca6dcf5f595aa0d8de5df01efaddf06cff90d973a`** and a valid Sparkle Ed25519 signature.
- The public product page exactly matches the committed HTML, including version, size, download URL and Quick Open/file/Changes copy.

The first public verification attempt still received 0.1.116 while deployment caught up. The second passed; preserve both logs at `~/Library/Caches/BelloAgentNext-public-0.1.117-{first,second}.log` and the downloaded feeds/installer under `build/public-0.1.117-second`. The public product page was saved as `~/Library/Caches/BelloAgentNext-public-page-0.1.117.html`. Git push success alone was not treated as deployment verification.

Installation and Sparkle update/relaunch rehearsals are excluded by the owner's standing instruction. Keep the source/site commit identities, notarization IDs, installer size and SHA-256, public Ed25519 result and equality of both public feeds here when performed.
