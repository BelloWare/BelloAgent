# Bello Agent 0.1.71 / build 75

Released and publicly verified on **2026-09-21 03:26:17 UTC**.

## Scope

Fresh three-turn presentation, explicit recoverable bidirectional history,
reader-centered row/byte bounds, cancellable complete supported-file indexing,
safe metadata/drafts/Stop during hydration, independent main/side generations,
viewport-first native Markdown and stable logical anchoring. Includes the
previously committed Live Monitor B with adaptive appearance and chart zoom.

Implementation commits: `1291404` (shared/helper source contract) and `e64ab7d`
(native presentation, indexing, rendering and regressions). See
[implementation and all 45 acceptance dispositions](../Fresh-Session-Loading-2026-09-21.md)
and [Live Monitor B](../Live-Monitor-B-2026-09-21.md).

## Tests actually performed

- **196 native tests passed across two final optimized runs.**
  `native-final-release` executed 196 tests: 195 passed, one opt-in Usage-panel
  capture skipped. `native-concurrent-final` passed the separate combined
  20-session native UI/capture test with `PI_REVIEW_VISUAL_LOAD=1`.
- The 195-test pass comprises FreshPresentation 19, AutomaticContext 10,
  CompletionSound 8, ConnectionSettingsFlow 6, ConversationPane 37, LiveMonitor 9,
  MenuBarPresentation 5, NativeMarkdownSizing 4, NativeMarkdownViewport 4,
  NativeTranscriptDocument 9, NativeTranscriptScroll 3, OrganizationBatch 9,
  ReportMessageNavigation 6, ReportNavigation 3, SessionReadState 12, Side 4,
  StorageTruth 11, TerminalPanelAudit 2, TranscriptDisclosure 14,
  TranscriptRowUpdate 4, WorkspaceConcurrency 5, WorkspaceLoading 7 and
  WorkspaceRefreshLifecycle 4. The optional screenshot skip is
  `testCaptureDefaultUsagePanelWhenRequested`; it is not counted as passed.
- **11 optimized helper tests passed:** HistoryWindowTests 3 and
  DisplayObservationTests 8 (`helper-release.log`). This includes 60 generated
  turn-boundary histories, exhaustive 1,101-turn traversal, oversized/escaped
  encoded pages and repeated provider tool-call IDs.
- **27 executable request-aware gateway tests passed** (`gateway-final.log`):
  actual request validation, JSON/fragmented SSE, tool rounds, cancellation,
  compaction, model/cost/usage observations and exact captured HTTP bodies.
- Focused Debug runs explicitly enabled actor data-race checks. Final anchor/
  disclosure/sizing run passed 22 tests; side hydration/retention passed 5;
  complete source-to-native-draw and ABC ownership fixtures passed separately.
  Earlier source/window/generation, automatic-preview and refresh checks also
  passed. Intermediate failing integration runs were investigated and rerun;
  they are not counted as passing suites.
- Tests exposed and drove fixes for same-chat missing context recovery, legacy
  numeric cursor compatibility, side draft overwrite, and logical Markdown
  position loss when a hosting ancestor adopted a new intrinsic height.

All logs/xcresults remain in the session's private `tmp/fresh-transcript`
directory. Normal app runs do not enable the performance probe.

## Measurements and limits

Apple M3 Max (Virtual), 16 GiB, macOS 14.8 (23J21), Xcode 16.1 (16B40), arm64.
Native tests serialized; optimized timing runs had no simultaneous compilation.
Selection-invocation to useful native draw for the 1,259,707-byte / 2,001-record
coding-history fixture: cold **179.79 ms** (source adoption 103.90 ms), 20 indexed
visits **66.23 ms p95** (source 9.34 ms p95, loading feedback 1.00 ms p95).
Fifty source-provided fresh UI generations: **55.89 ms p95**.

The combined 20-stream fixture completed every request/tool/capture, preserved
CJK marked text and kept both native panes active. Its UI step p95 was
**104.39 ms** and maximum MainActor heartbeat gap **194.78 ms**. Heavy-view
stalls remain; the proposed <5 ms main-thread and <16/33 ms typing targets are
not established. Native draw opportunities are not physical display scanout.

No authenticated live gateway call, physical trackpad/60/120 Hz assessment or
full VoiceOver/RTL/high-contrast/larger-text matrix was run. UX10 and UX13 remain
explicitly not run for their full physical matrices, with partial automated
coverage recorded. Fresh-install and actual Sparkle upgrade/relaunch rehearsals
remain excluded by standing owner instruction.

## Publication

- Packaged source commit: `3a29daf223fb2101be105ad24a7a6bdba01d2596`.
- Website commit: `1f73d9a39a585d1b2f169ced01d2e07bd576bb1f`, pushed to its
  configured `main` upstream. Cloudflare check **106203773143** succeeded,
  completed at 2026-09-21 03:25:17 UTC.
- Developer ID signing, app/DMG notarization and stapling, Gatekeeper, packaged
  helper/catalog smoke and feed validation passed. The staged application has
  no XCTest bundles. Notary app ID: `3fdaaffe-eb41-458f-8d7b-7bbf9c0cd0ca`;
  DMG ID: `be313025-6668-40eb-83c6-a9fe70c2a53c`.
- `BelloAgent-0.1.71.dmg`: **8,677,864 bytes (8.28 MiB)**;
  SHA-256 `d521989403074e10e1e44c0a4604e603a5e9be4f1b4c213444e0bbb51e048f44`.
- The public product page links 0.1.71. Downloaded canonical and legacy feeds
  are byte-identical to each other and the local signed feed. The public DMG
  matches the local SHA-256 and passes Sparkle Ed25519 verification. A final
  signed installer was copied to the session outbox.

Source commits remain local under the current release policy; only the website
publication was pushed. The public source link continues to point to the
repository's last explicitly pushed revision until a source push is requested.
