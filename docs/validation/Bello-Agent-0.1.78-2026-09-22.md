# Bello Agent 0.1.78 validation

Date: 2026-09-22. Version 0.1.78, build 82, arm64 macOS 14+.

## Change

Removed the 16 KiB response and 8 KiB reasoning display caps, per-position timeline prefixes, 64-part timeline cap, and shortened tool argument/result projections. Live and saved-history readers retain complete content. Large rows may exceed the preferred history-page byte size; the transport keeps its 1 MiB frame limit and automatically transfers large immutable results in 192 KiB chunks. Byte assembly and final decoding run outside the main actor.

Streaming text and timeline updates send suffixes with base revisions. Native readers reject stale/duplicated appends instead of duplicating content. Native block virtualization, history cursors and the reading/selection coordinator remain in place. Expanded tool details use full retained arguments/results.

Older shortened assistant timelines are reconstructed from the complete canonical message where retained, in canonical order without fabricated arrival chronology or source-file rewriting. Old standalone presentation fragments with no remaining source cannot be recreated. Existing explicit journal/transport resource limits and upstream model output limits still apply; they do not silently produce a successful truncated preview.

## Validation

- Helper: **301 tests passed, zero failures**, including full Unicode/control-character transfers beyond 1 MiB, complete long prose/reasoning, 100-part timelines, 400 tool cards, old-timeline recovery, large history traversal, and a >300 KiB streaming reply whose next text/timeline patch stays below 2 KiB.
- Debug native: 46 tests passed in the first 47-test selection; the new actual-helper test encountered one CancellationError in that run. Its focused rerun passed, then the entire full-display plus host-supervisor selection passed **10/10**. The completed initial selection covered all 19 fresh-presentation tests, full source projection, patching, native viewport/reading stability and frame validation.
- Actual-helper regression opens a synthetic saved response larger than the IPC frame limit, checks cold-file and reopened live content/timeline tails, loads the versioned history page, and verifies that the helper remains available.
- Optimized native: **45 tests passed, zero failures**, covering the actual-helper full-content path, transfer cancellation and frame validation, revision-bound appends, timeline projection, native Markdown/code viewport owners, reading/selection stability and bidirectional history traversal.
- Optimized synthetic scrolling: 300 rich rows over 120 steps measured p50 **3.806 ms**, p95 **26.761 ms**, p99 **82.856 ms** and maximum synchronous work **68.920 ms**. One 88 KiB Markdown answer measured p50 **5.576 ms**, p95 **8.671 ms**, p99 **15.455 ms** and maximum synchronous work **12.143 ms**. Mounted native view counts stayed stable. Rich-history mounting stalls remain; this change does not claim to eliminate all scrolling jank.
- Signed artifact: Developer ID app/helper signatures, packaged offline helper/catalog smoke, app and DMG notarization/stapling, Gatekeeper assessment and Sparkle Ed25519 validation passed. No Node runtime is bundled.
- Public artifact: canonical and legacy feeds are byte-identical; the downloaded DMG matches the local SHA-256 and verifies with the Sparkle Ed25519 key. The public product page advertises 0.1.78 and its installer. Verified **2026-09-22 02:10:13 UTC** after Cloudflare check **106589778913** succeeded for the website publication commit.

Environment: Apple Silicon remote Mac, macOS 14.8, Xcode 16.1, Swift 6 language mode. Native tests use explicit actor data-race checks. Native window tests run serially. Scratch logs are under `full-transcript-078` in the session temporary directory; reusable build caches stay under the existing external `bello-agent-0.1.6/build` root.

No live production gateway, fresh installation or actual updater/relaunch rehearsal was performed. The latter two remain skipped at the owner's request. Performance measurements establish synthetic native workloads, not a guarantee of physical frame cadence or unlimited-size replies.

## Commands

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests"
# Native selections use xcodebuild test, scheme PiApp, arm64 macOS,
# ENABLE_TESTABILITY=YES for Release and -enable-actor-data-race-checks.
PI_BUILD_ROOT="$PI_BUILD_ROOT" bash scripts/release.sh
PI_BUILD_ROOT="$PI_BUILD_ROOT" bash scripts/publish-release.sh 0.1.78
python3 scripts/verify-published.py "$PI_BUILD_ROOT/releases/0.1.78" "$SCRATCH/public"
```

## Release provenance

Packaged source: `939cbd9912df15b17f752ce6c0cee5b91a8f583e`, pushed to `BelloWare/BelloAgent` `main`. Website publication: `dae6f9ce4d5157679804bd551c23a5f8fc8fa602`, pushed to `BelloWare/belloware.com` `main`.

`BelloAgent-0.1.78.dmg`: **9,083,198 bytes (8.66 MiB)**. SHA-256: `06916c3feac79a490ffba7ee2e82bfff38853b7942e5f7489265b5b304aea59f`.

Apple accepted app submission `178302ee-dd49-4f18-b066-f22e332d4f26` and DMG submission `f8ab6c38-8d52-489f-9811-31fd7446aa03`. Release artifacts remain in the external versioned build directory, with application/helper dSYMs for crash symbolication.
