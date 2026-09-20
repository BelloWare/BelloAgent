# Bello Agent 0.1.67/build 71 acceptance — 2026-09-20

**Released and publicly verified 2026-09-20 11:11:39 UTC.**

## Change

The previous spinner explicitly paused its animation timeline when SwiftUI's
`accessibilityReduceMotion` was true. Waiting dots rendered a static frame, and
controls, disclosures and navigation independently suppressed motion. A change
only at the main window would miss separately created transcript hosting views.

All app-owned SwiftUI motion now reads `piReduceMotion`, whose default comes from
`PiMotion.reducesMotion = false`. Native disclosure and jump-to-latest motion use
the same policy instead of querying NSWorkspace's accessibility preference.
The system setting is neither written nor overridden through private APIs in
the shipped app. Explicit local/test overrides remain possible.

`piStableLayout` still removes inherited geometry animations. Animation timing,
viewport virtualization, update coalescing and streaming layout are unchanged.
This implements the owner's request to keep app animations enabled even when
macOS Reduce Motion is on; it supersedes earlier requirements to honor it.

## Validation

**21 native Debug tests passed with Swift actor data-race checks**, 8.817 s:
6 workspace motion tests, 14 native transcript disclosure tests and the design
system motion-token test. Fixtures inject SwiftUI's system motion environment
without changing macOS preferences, verify local feedback still animates while
native geometry stays unanimated, and compare rendered spinner and waiting-dot
frames over time. Both indicators moved with system Reduce Motion enabled.
Separate hosting roots exercise the policy used by virtualized transcript rows.
Disclosure tests cover reversals, streaming, exact stacked geometry, forty-tool
folds, persisted collapsed state and explicit fixture overrides. Chat replacement
and side-pane changes preserve editor identity, selection and final geometry.

Log/result bundle: `native-motion.log` / `native-motion.xcresult` in scratch.
The helper is unchanged; 0.1.66's helper and gateway evidence is reused.

Scratch: session `tmp/motion-067`. No helper or transport behavior changed.
No subagents, installation tests or Sparkle install/update rehearsals are used.

## Signed release

- Shipping source: `406bc17ff101ada6608f69b7a4b2a3f10ca0e3d2`.
- Website publication: `a8a84a6b39e2f8dd7d65dd82ece7876c07ac4940`.
- Optimized native build, Developer ID signatures, hardened runtime, packaged
  helper offline/catalog smoke, Gatekeeper and app/DMG staples passed.
- Apple accepted app submission `3835814b-d790-486b-ad37-d423f114a3ed` and DMG
  submission `fc4e7891-c51e-4ff9-8c03-2ca4238dd078`.
- DMG: **8,228,882 bytes (7.85 MiB)**,
  SHA-256 `3a641c8fe55bf2ac90c8028a91ef1034b26038afb2b731671bcda6ab9408df02`.
- Release scripts: `release.log`, `publish.log`; build/notary/smoke evidence in
  shared build cache `release.9ngcN6`. Final DMG copied to the session outbox.

Public product page, byte-identical canonical/legacy update feeds and downloaded
DMG SHA-256/Ed25519 verification passed **2026-09-20 11:11:39 UTC**. Cloudflare
check **106068742987** succeeded at 11:11:21 UTC. Public verification evidence:
`public-verification.log`, `public-verified.txt` and `public-0.1.67/` in scratch.
