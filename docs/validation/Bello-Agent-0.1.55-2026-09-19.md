# Bello Agent 0.1.55/build 59 acceptance — 2026-09-19

**Public release verified at 2026-09-18 22:58:16 UTC.**
Release source: `f42d237efe30c298523a47b62dd23c35fdda107e` (local `main` commit under the owner's
source-push policy). Website: `5c1aec57e1c8e9a69ef44cbbd053715280db3e01`. Later documentation commits
do not change the packaged source.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.55.dmg](https://belloware.com/assets/BelloAgent-0.1.55.dmg).
- Size: **7,357,293 bytes (7.02 MiB)**.
- SHA-256: `031ec071db485f796e9dc2e66c9b8b24f13da443778877db54a1f35d8f1955db`.
- App notarization: `fd4d796d-8590-4a45-a993-2bcc20f5dfcb` (accepted).
- DMG notarization: `b24b9011-1600-4d82-802b-9135748dcce8` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `f42d237efe30c298523a47b62dd23c35fdda107e` remains local under the
owner's source-push policy. Website publication commit `5c1aec57e1c8e9a69ef44cbbd053715280db3e01`
was pushed; Cloudflare check **105788774388** succeeded.
Public verification at **2026-09-18 22:58:16 UTC** confirms identical canonical/legacy
feed bytes, the downloaded DMG SHA-256 and Sparkle signature, and the product
page's 0.1.55 download link. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the standing owner policy.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.dC53Yj`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.55`.

## Evidence

- `scroll-final.log`: 78 Release XCTest cases executed, 76 passed, two explicit
  interactive pointer skips, no failures. Coverage includes native document
  geometry, retained selection, deferred height changes while scrolling away,
  session identity, read offsets, Markdown, paging, transcript activity, motion,
  release configuration, and native scroll benchmarks.
- `scroll-copy-width.log`: the final four-case Markdown/scroll rerun passed
  after fixing Copy/Copied layout feedback; it supplies the measurements below.
- 300 rich messages: mean **9.637 ms**, p95 **32.099 ms** per native scroll step,
  versus **85.720 / 104.682 ms** on 0.1.54. Mounted native views fall from
  **13,814 to 342**. The full initial geometry pass takes 5.35 seconds; this
  release does not claim improved initial loading for that fixture.
- One 88 KiB Markdown answer: mean **13.029 ms**, p95 **23.036 ms**, versus
  **44.552 / 58.483 ms**. Mounted views fall from **9,005 to 277**; initial
  geometry settles in **1.17 seconds** instead of timing out.
- Each benchmark uses 120 native layout/display scroll steps after warm-up.
  Clip targets, full document/row geometry and exact-width caches stay stable.
  The 300-row fixture performs 64 coalesced intrinsic-size validations during
  attachment; the large-answer fixture performs zero. Width-cache misses are
  zero for both. These are stress-test CPU/layout/display timings, not a
  physical trackpad/display FPS claim.
- Full content, selected native fields, copy targets, append/reflow and reduced
  mounted block count are checked in `NativeMarkdownViewportTests`. A captured
  native viewport was inspected for paragraph, heading, syntax/code and table
  layout; no content truncation or unexpected gaps were observed.

The two pointer-driven disclosure/retry checks need an active desktop; they were
skipped because this session cannot deliver real pointer events to native SwiftUI
buttons. VoiceOver traversal and physical trackpad smoothness are not claimed.
A single huge table/list remains one block, and selection within a streaming
reply may reset once when it crosses the 32-block renderer threshold. Earlier
settled messages and later block appends/reflows have selection regression
coverage. See the [scrolling review](../Scrolling-Review-2026-09-19.md).

Unchanged provider, helper, gateway, worker and website-staging checks reuse
previous passing evidence. Signed distribution and public feed/archive
verification passed as recorded above. Installation/update rehearsals are skipped under
the owner's standing instruction.

Scratch logs and XCTest results:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/scroll-055-20260919`.
