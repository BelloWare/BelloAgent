# Bello Agent 0.1.117 — file tabs, Quick Open, Changes tabs and faster forks

Status: local candidate on `dev/next`; not published. Marketing version 0.1.117, build 121. The previous public release is 0.1.116/build 120. Starting `main`: `3ba18fe5767bfdf244a1bb89961f0232f1988ecb`.

## Scope

The release adds native file tabs and separate windows, Find and Go to Line, visible-line syntax colours, live file following, and PDF/image previews. Quick Open uses the current window, preserves text-field selection, waits for the current query, and reports incomplete or failed listings. Reply code paths and diff-line menus open trusted files at the requested line.

Changes opens as a tab, stacks the file list above the diff below 900 pt, and opens new windows at 1040×720. Ordinary file windows remain 820×640. Saved side conversations join Next/Previous Chat in sidebar order, keep their drafts across switches, and open beside their parent. Editable tab text retains its own keyboard shortcuts.

Large forks can open from recent rows while history fills in. Edits and version reads share off-actor history preparation. New forks start their own cost; older readers can include the parent's cost when they ignore the new optional reset field. Existing forks retain their behavior. The helper retains pi 0.85.1 semantics and adds only optional wire fields.

The release notes are in `releases/0.1.117.html`. Product-page copy introduces Quick Open, files beside the chat, and Changes tabs within the existing layout.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1 and XcodeGen 2.44.1. Checks use the committed local ref in a separate worktree at `~/Library/Caches/BelloAgentNext/worktree`; products and evidence live under `~/Library/Caches/BelloAgentNext/build`. No development changes have been pushed under the owner's instruction to keep them local until release.

- Final full gate at `76bfb27`, **all checks passed in 18 min 20 s**. Native serial: **327 executed, 17 skipped, zero failures**. Native parallel: **1,632 passed, 18 skipped, zero failures**. Isolated StreamingCostTests: **5 passed**; remaining helper suite: **575 executed, 6 skipped, zero failures**. Views package: **110 executed, 3 skipped, zero failures**. Wire 34, concurrent wire 4, acceptance 2 and Python 72 passed. Gallery: **172 images, zero failures**. Isolated accumulation heap growth was 41,472 bytes, below the original 65,536-byte bound. Final logs and captures are retained in `verify-logs-final-0.1.117` and `gallery-final-0.1.117` beneath the cache root.
- Third full gate at `397c300b7884acbf23a1aad378979f6b6f77651f`, 18 min 21 s: native serial lane **327 executed, 17 skipped, zero failures**; native parallel lane **1,632 passed, 18 skipped, zero failures**. Views package **110 executed, 3 skipped, zero failures**; wire 34, concurrent wire 4, acceptance 2, Python 70; gallery **172 images, zero failures**. Helper **580 executed, 6 skipped, one failure**, described below. A final gate with isolated streaming-cost measurements remains pending.
- Focused native corrections passed: QuickOpenTests 16, GitPanelWidthTests 3, ChangesTabFrameTests 7, FileTextViewTests 42, FileTabTests/ReplyFileLinkTests/TranscriptViewEqualityTests 19 combined, PiSheetWindowTests 10, MarkdownStreamingCorrectnessTests 12, and GitPanelRedrawTests 3. The final native lanes cover all of these.
- First gate at `ad8cdac` found preview pixel doubling, a Swift-owned window over-release during teardown, a stale view-equality inventory, delayed synthetic selection delivery and a sheet cleanup failure. The preview now keeps its decoded bitmap directly; the other corrections repair test ownership, expectations and delivery. The sheet class subsequently passed alone and in both parallel runs.
- The second gate at `deedae6` passed its serial lane but exposed one resize-redraw fixture measuring before the complete initial Git refresh. Commit `0965b98` waits for that refresh and settles layout over elapsed time. All redraw checks then passed alone and in the final parallel lane. Median-based markdown timing checks now explicitly use the serial lane; their original bounds remain unchanged.
- The third gate's only failure was StreamingCostTests' process-wide heap-growth check: 105,920 bytes against its unchanged 65,536-byte bound, with 103 fewer allocated blocks. All 5 StreamingCostTests passed alone afterward: heap growth 40,576 bytes, early/late accumulation CPU 4.86/4.74 microseconds per delta. The gate now runs this class in its own process before the gallery and excludes it from the second helper invocation. VerifyReleaseTests passed 2 tests for ordering, failure propagation and continuation of later checks. No product code or benchmark bound changed for this correction.
- Reviewed narrow Changes, image preview and reply-file-link scenes again in both appearances after the corrections. PDF, file-tab and Quick Open scenes were reviewed in the first gallery run. Evidence from all three runs is retained in separate cache directories.
- Release build-for-testing with testability, optimized Changes frame checks and the one-hour soak remain pending.
- Live compaction rehearsal against the synthetic gateway remains pending. The owner's real gateway is not configured through `PI_LIVE_BASE_URL`, `PI_LIVE_API_KEY` and `PI_LIVE_MODEL`; no real-gateway result is claimed.
- Native accessibility-interface coverage passed in FileTextViewTests. The owner's one-minute VoiceOver exercise remains pending.

### Compatibility with the published helper

The public 0.1.116 DMG matched SHA-256 `d2a8337a2642d8427798061a1792d9c515ce739298f5527147b4222812a9ecbb`. Its app metadata was 0.1.116/build 120 and `codesign --verify --deep --strict` passed. Only the helper was extracted from a read-only mount; the published app was never installed or launched.

That helper created whole-chat and reply-point forks after an edited synthetic conversation and added a billed fixture follow-up to each. The candidate reopened both forks twice. The transcript (9 and 6 rows), context, origin, version groups, available historical edit page and $0.0123 fixture cost matched exactly. Reading left both journals byte-identical. History-page runtime incarnation UUIDs were excluded because they change on every open. The runner, log and JSON report are retained under `~/Library/Caches/BelloAgentNext/compat-0.1.116/`. ForkCloneTests also covers copied-journal compatibility across open/reopen.

## Publication

Signing, notarization, artifact/feed validation, source publication, website publication and public verification remain pending. Fetches confirmed upstream source `main` remains at the starting commit and the website is clean and synchronized at `6d4fa0d7ee7f024c5b315324a6393d26024340b6` (0.1.116). Development commits remain local on `dev/next`. No `v0.1.117` tag exists yet.

Installation and Sparkle update/relaunch rehearsals are excluded by the owner's standing instruction. Keep the source/site commit identities, notarization IDs, installer size and SHA-256, public Ed25519 result and equality of both public feeds here when performed.
