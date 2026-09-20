# Bello Agent 0.1.68/build 72 acceptance — 2026-09-20

**Released and publicly verified 2026-09-20 15:29:15 UTC.**

## Change

The existing Command/Shift sidebar selection now offers **Copy Session
References** in its context menu and a copy icon in the selection bar. Copies
preserve the selection and order references as the sidebar lists the chats.
The single-session command uses the same implementation.

Each reference retains its identity, actual journal path and safely quoted Bash
read command, and adds gateway-reported retained input/output/total tokens,
cached input, cache writes, reasoning tokens, reported USD cost and reasoning
cost. Per-field sample coverage distinguishes partial or missing observations
from zero; cache and reasoning subsets are not added twice. Expired request
records are identified. Session totals exclude other sessions' inherited links.

One archive-actor call reads only the chosen project/session scopes, in batches
of 200 within the existing 500-selection limit. Copying opens no conversations
or helpers, reads no journal bodies and does not mutate sidebar accounting.
The async result rechecks records, copy generation, clipboard change count,
cancellation and shutdown before writing, preserving newer clipboard contents.

## Validation

**53 distinct native Debug tests passed with Swift actor data-race checks:**

- **11 session-reference tests**, 0.725 s: single and multiple references, fresh
  accounting despite a stale sidebar cache, exact inclusive token arithmetic,
  zero/missing/partial/expired reporting, reasoning cost, project isolation,
  the full 500-scope selection, stable order and marks, archived/imported/side
  references, unsaved chats, complete safely quoted journal reads, deleted
  members, unavailable accounting and newer clipboard copies.
- **20 gateway-accounting tests**, 0.531 s: existing accounting and attribution
  behavior remains intact.
- **16 sidebar interaction/multi-selection/drag tests**, 0.504 s: actual pointer
  selection, modifier behavior, native context menu access and grouped dragging.
- **6 sidebar appearance tests**, 2.217 s: the added copy button fits narrow and
  default sidebars in both appearances and preserves row/selection rendering.

Initial reference fixtures assumed copying never queried the archive. They were
updated to configure it, matching app startup, and to record the real versioned
dispatch timing required for a request to count. The final 31-test accounting
and reference run passes; no production validation guard was relaxed.

Scratch: session `tmp/references-068`, logs/result bundles
`native-references`, `native-references-final`, `native-reference-accounting`.
No helper or transport behavior changed; their prior validation is reused.
No subagents, installation tests or Sparkle install/update rehearsals are used.

## Signed release

- Shipping source: `73ff2334db6440c3fa31265b540f3898444c4c2a`.
- Website publication: `0f1358e79971dab6e99db426e9d87b29df18fa63`.
- Optimized native build, Developer ID signatures, hardened runtime, packaged
  helper offline/catalog smoke, Gatekeeper and app/DMG staples passed.
- Apple accepted app submission `e8506dc1-ca3c-49b9-b82e-8b66b7b4f514` and DMG
  submission `2ea078b4-a4cb-4110-ab25-64dd06feff90`.
- DMG: **8,253,957 bytes (7.87 MiB)**,
  SHA-256 `0f4d717763a9de0906d276d959480d79aa810ad797ff08492ef2ae6a1f7158bf`.
- Release scripts: `release.log`, `publish.log`; build/notary/smoke evidence in
  shared build cache `release.kQYAGk`. Final DMG copied to the session outbox.

Public product page, byte-identical canonical/legacy update feeds and downloaded
DMG SHA-256/Ed25519 verification passed **2026-09-20 15:29:15 UTC**. Cloudflare
check **106101546960** succeeded at 15:28:46 UTC. Public verification evidence:
`public-verification.log`, `public-verified.txt` and `public-0.1.68/` in scratch.
