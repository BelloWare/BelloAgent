# Bello Agent 0.1.71 / build 75

Candidate validated on 2026-09-21. Publication provenance is filled after the
signed artifacts and public deployment are verified.

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

Pending signed app/DMG notarization, packaged-helper smoke, feed validation,
website deployment and public download hash/signature verification. Source
commits remain local under the current release policy; only the website
publication is pushed.
