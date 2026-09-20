# Bello Agent 0.1.50 acceptance

Date: 2026-09-19 (Asia/Singapore). Branch: `main` in `BelloWare/BelloAgent`.
Version **0.1.50/build 54**. Environment: macOS 14.8 arm64,
Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

**Public release verified at 2026-09-18 18:56:46 UTC.**
Release source: `0969ad030f769aadf1761d9e18869ca85130c031` (local `main` commit
under the owner's source-push policy). Website:
`178662a9abad8bd567553ed5f3dcf899d3f265b4`. Later documentation commits do not
change the packaged source.

## Changes and acceptance

This release improves warm chat loading, avoids excess initial history pages,
keeps native layout stable during transitions, reduces syntax-coloring work,
preserves scroll intent and fixes accounting refresh for larger displayed pages.
See the [performance review](../Performance-Review-2026-09-19.md) for mechanisms,
baseline/final measurements and the remaining large-history rendering limit.

The focused Release native run passed 194 cases with one opt-in skip. The final
rendering run passed 30 cases, including one new normal-page benchmark. The
fixture cleanup rerun passed 33 cases without SQLite unlink warnings. Repeated
cases are counted once: **195 passed, one skipped, zero failures**.

Native coverage includes loading/paging, selection and draft durability,
transcript content/scroll/selection, Unicode syntax colors, live accounting,
usage, report navigation, window geometry, model switching, prepared context,
sides and release configuration. No provider/helper, capture, transport or
release-tool source changed. Their passing 0.1.49 helper (170), Python (52)
and local HTTP/SSE/MCP (24) checks are reused, not counted as fresh tests.

The full attributed-color fixture fell from 629.2 ms to 22.0 ms. Large native
transcripts remain expensive: the 300-row forced streaming-layout stress test
did not improve. The review records those measurements explicitly. No blanket
frame-rate guarantee, full performance-matrix pass or physical interaction
validation is claimed.

Installation and actual Sparkle update/relaunch rehearsals remain skipped under
the owner's standing instruction. This pass uses synthetic local fixtures and
does not access a deployed gateway or production credentials.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.50.dmg](https://belloware.com/assets/BelloAgent-0.1.50.dmg).
- Size: **7,232,970 bytes (6.90 MiB)**.
- SHA-256: `e3e5b43e042fa435a691819e6d30918c7915e7bd6298c3b5c8298f8c65e67e30`.
- App notarization: `5fe2bf73-07ae-45c6-b77b-b50b7cd674d5` (accepted).
- DMG notarization: `d8630110-a189-4ae1-abb8-eef5da9f5789` (accepted).

Developer ID signing, executable hardened runtime, notarization, stapling,
Gatekeeper, packaged helper/catalog smoke, version/build validation and the
local Sparkle Ed25519 check pass. The existing Clipboard-style signing and
ordinary Keychain approach, bundle identity, history paths and icon remain
unchanged. The source commits stay local under the owner's source-push policy;
the website publication commit is pushed for deployment. Cloudflare check
105723392799 completed successfully. Public verification confirms the exact
staged canonical and legacy feed bytes, downloaded DMG SHA-256 and Sparkle
Ed25519 signature. The product page links to 0.1.50. The same signed installer
was copied to the session outbox.

## Evidence

Scratch root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/performance-050-20260919`.
Logs and result bundles: `baseline-release`, `focused-final`, `rendering-final`,
`fixture-cleanup`. The final rendering run completed at
2026-09-18 18:41:56 UTC and the fixture cleanup run at 18:45:40 UTC.
Distribution logs: `release.log`, `publish.log`. Signing and notarization work:
`tmp/bello-agent-0.1.6/build/release.sxBroe`. The immutable release, signed app,
DMG, feeds, hash and retained app/helper dSYMs are under
`tmp/bello-agent-0.1.6/build/releases/0.1.50`.

An initial public check still saw the previous feed during deployment; the
final post-deployment check passed.

Public evidence: `public-verification.log` and `public-verification.json`.
