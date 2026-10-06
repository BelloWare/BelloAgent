# Bello Agent 0.1.120 / build 124

**Publicly released and verified at 2026-10-06 01:07:03 UTC.**
Release commit `f8a3a79ac1077a94c4daaa6bf21505bca63a0557` is pushed and
tagged `v0.1.120`. Its code matches validated production source
`70812d5fee0087ba493a3436033cf37fa32f93dc`; later changes are records only.
The owner requested completion of the whole AppKit migration
and one release, with flexibility about the original handover checklist.

## Changes

The application entry point, workspace, transcript, composer/footer,
Inspector, statistics, dashboard, Settings, onboarding, Git/files, menus
and windows use AppKit. Native views are retained and updated only where
their inputs change. Production sources have no SwiftUI imports and the
final Release executable has no direct SwiftUI or Charts links. Independent
frozen SwiftUI references remain exclusively in the test target.

The terminal cursor correction is included. Final integration repairs
preserve side-pane proposals and original Git caption rendering, restore
the narrow Git background's 15.5-point overflow, and reduce first-character
composer/footer work. A test-only reveal-order correction replaces an
unspecified async-let entry-order assumption without relaxing assertions.

## Validation

- The complete `1aa78749` gate passes 628 serial cases (23 skips), 1,937
  parallel passes (34 skips), five helper-cost checks, 192 gallery captures,
  611 helper cases (six skips), 34 wire, four concurrent, two acceptance and
  72 Python checks. The original command exits one solely for the views
  test's unspecified task order. Its corrected complete package passes
  167 cases (three skips), followed by two ten-case repeats. The original
  failed log is preserved, not described as a fresh zero-exit gate.
- The later bounded background repair passes all 28 affected Debug Git
  cases, with independent frozen background/child frames. Mutation proof
  removes the overflow and fails leading/width checks, then byte-for-byte
  restoration, rebuild and rerun pass. Four light/dark caption crops have
  zero differing pixels, largest channel difference one. No reference,
  tolerance, timeout or wait was loosened.
- All 192 fresh pre-background-repair pairs were actually viewed. The final
  complete 192-capture run passes, with all 12 affected Git pairs reviewed
  afresh and original 2x narrow captures inspected. Unchanged-screen reviews
  are reused under `docs/Release.md`. No remaining actionable owned visible
  layout/color defect was found. This is not blanket pixel equality:
  generated paths/IDs/rates can change wrapping, initial lazy scroll-thumb
  estimates and focus/selection differ, and offscreen rows are not visually
  certified. Complete-document geometry checks provide separate coverage.
- Whole-change and subsequent bounded read-only Codex reviews report no
  introduced actionable findings. Runtime tests caught a transitional
  underlay fill; the final repair uses the existing flat `FillView` and
  passes the unchanged light/dark checks. Source review alone is not runtime
  or end-to-end input validation.
- The final optimized build passes all 15 affected Release cases. Both
  baseline and final performance sets pass all 16 invocations with the same
  fixtures, seed and load limit. Opening/reopening, streaming, scrolling and
  typical/p90 typing improve. Whole-window switch medians are broadly
  similar; typing maxima are slightly higher (9.9–10.8 ms versus 7.9–9.7),
  reduced from the earlier candidate's 15–17 ms. See the
  [complete comparison](../perf/appkit-0.1.120-final.md).

Passing unchanged checks are reused under the release workflow. The serial
frozen sizing probes emit intentional invalid-geometry messages; the gallery
has no geometry/constraint warnings. This is not a warning-free-log claim.
The first final Release test build omitted `ENABLE_TESTABILITY=YES` and
failed its `@testable` imports; the corrected invocation passes.

## Actual hour soak

Release source `70812d5f`, seed `1790822043708`, requested 3,600 seconds,
default stall/launch limits 250/2,000 ms, mixed actions with switch-only and
draw modes unset. It passes in 3,608.017 test seconds; the report covers
3,607 seconds and 177 launches. There are zero pauses over 250 ms, zero
idle-row jumps, zero slow/missing launches and zero quit failures. Sidebar
median/max are 256/349 ms. Main-thread answers over 100/150/200 ms are
5/0/0, longest 115 ms. Actions: 93 helper starts, 761 idles, 2,350 selections,
304 sends, 82 long sends, 549 switches and 348 waits.

Footprint grows 102→922 MB, peak 922 MB, 4.66 MB per cycle. The report
retains six recent models (cycles 172–177), all 177 windows and zero closed
views. The in-process harness teardown is unchanged from 0.1.119 apart
from the native root; 0.1.119 also retains all 181 windows and records
4.06 MB growth per launch. This documented test-window retention does not
prove bounded memory or attribute every byte of growth to those windows.
No responsiveness threshold was waived.

## Packaging and public verification

`scripts/release.sh` passes on release commit `f8a3a79a`: normal Release build,
stripped app/helper binaries with both dSYMs retained, Developer ID signing,
packaged-helper offline smoke, app and DMG notarization/stapling, Gatekeeper
acceptance, signed appcast and Ed25519 validation. The generated test bundle
is preserved outside the shipping app; the final bundle has no `.xctest`,
XCTest framework or frozen-reference directory and no direct SwiftUI/Charts
links. Local validation also checks build 124 is newer than build 123.

The installer is **12,653,046 bytes (12.07 MiB)**. SHA-256:
`494806a38135c6a77b7ed7829b3ab6d9373191037052054eb890047b8f45f206`.
Website publication commit `cdc3698a783c6136d4c9b853e95eae447edb55dc` is
pushed. The first public check still serves build 123; the successful second
check downloads the intended installer and verifies its identical hash and
Ed25519 signature. Canonical Bello Agent and legacy Pi App public feeds are
byte-identical; the public product page links to 0.1.120.

[Product page](https://belloware.com/bello-agent.html) ·
[Verified installer](https://belloware.com/assets/BelloAgent-0.1.120.dmg) ·
[Release source](https://github.com/BelloWare/BelloAgent/tree/v0.1.120).

## Limits

VoiceOver and a real-gateway compaction have not been run or explicitly
deferred for this release. A physical main-screen switch between 1x and 2x
has not been exercised on the 2x VM. Installation and Sparkle update/relaunch
rehearsals remain omitted under the standing owner policy. These omissions
are recorded, not converted into passing results.

Evidence is preserved under `/Users/admin/Library/Caches/BelloAgentNext`:
`logs/native-composer-final-full-gate.log`, `final-1aa-verify-logs`,
the corrected views-package/repeat logs, the gallery manifests/per-image
records, final Git mutation/restoration logs,
`logs/native-final-70812-release-affected-tests.log`, `perf-2be1/baseline`,
`perf-70812/final`, `logs/native-final-hour-soak.log` and the complete
`logs/native-final-hour-soak.txt`. Release artifacts and both dSYMs are in
`build/releases/0.1.120`; signing/notarization/build logs and helper proof are
in `build/release.zAhYJo`. Publication and both public-check logs are
`logs/release-0.1.120-{publication,public-verification-1,public-verification-2}.log`;
package/public metadata and final shipping linkage are preserved beside them.
See the
[integration record](AppKit-integration-0.1.120-2026-10-05.md) for exact paths
and review pins.
