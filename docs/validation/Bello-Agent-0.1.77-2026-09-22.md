# Bello Agent 0.1.77 / build 81

## Scope

Reviewed base: `bb586c0f2e9f0759921a770c73273f46765ad6bb` (0.1.76). The newly uploaded `Implementation-Plan _1_.md` is byte-for-byte identical to the **Stable Reading During Streaming and a Faithful Execution Timeline** plan already implemented for 0.1.76 (SHA-256 `2fa2229de8cd04f2e7d05a205e5883e36df02d9fb7c2f3dda72b73ab192bd6ff`). This is a follow-up against its source-identity and A11 final-reconciliation requirements, with additional scrolling diagnostics. It does not reimplement the timeline or claim the remaining physical/performance gaps are closed.

## Reproduced failures and changes

Implementation commits: `8bdbb72` (source identity/selection mapping), `c52d94a` (scroll phase diagnostics), `2d89168` (previous scopes and edited code owner preservation).

The initial two regressions failed before the production edits (three assertions):

- A terminal response replacing earlier streaming source increased the parser generation but reused old block identities by offset/equal text. The new source now clears those identities; canonical reconciliation no longer matches unrelated equal paragraphs. Normal append/finalization still retains source-derived identities.
- A late reference definition changed the selected label from UTF-16 position 19 to 18, while the field editor kept position 19. The mapper previously assumed the old display was literal source and parsed only the local paragraph, without the later definition. It now maps the prior literal or parsed fragment into the document's canonical source positions, scoped to the original block. UTF-8 block bounds are explicitly converted to UTF-16. Source maps are lazy and retained only by affected leaves; normal appends and unchanged blocks do not trigger full-document reconciliation work.

The last-paragraph variant additionally retains the previous source scope: a definition can join the final paragraph’s canonical range, so parsing only the new scope cannot reconstruct the old display. That variant also reproduced before its fix. Existing edited-code selection checks caught an overly broad identity reset; the reset is now limited to restarts and replacement of streamed terminal content. Already-canonical editable/detail views retain their native containers.

The same mapping restores both native selections and unselected reading anchors. It uses source provenance rather than searching for repeated rendered words. If Foundation supplies only an ambiguous transformed run without exact character provenance, the mapper declines to invent a source offset; existing anchor fallback applies.

The additional diagnostic counters separate row attachment, detachment, host release and viewport layout. They are disabled during normal operation. Measurements confirm native rich-row mounting/layout remains the main cost; this release does not claim to eliminate that performance tail.

## Verification

1. **Pure state/projection:** terminal replacement generations, duplicate labels, Unicode source scopes and invalid ranges; existing Markdown parser/streaming and chronological presentation tests.
2. **Helper integration and durability:** no helper/provider/journal changes. The 296 passing helper tests and request-aware gateway/durability evidence from [0.1.76](Bello-Agent-0.1.76-2026-09-22.md) are reused, not counted as rerun here. The packaged helper/catalog smoke is part of release validation.
3. **Mounted macOS:** the final focused Debug reconciliation run passes 23 tests. New checks retain the same field editor and an unaffected paragraph's native owner, and verify an unselected middle-of-paragraph source anchor at draw opportunities as a late definition resolves. Existing literal finalization, code-threshold selection, pending-parent-adoption and Unicode-width-reflow cases also pass.
4. **Physical UI:** no human trackpad/momentum, physical display refresh-rate, or gesture-to-photon certification was performed. The virtual mounted-window checks do not establish universal 60/120 Hz smoothness.
5. **Live LiteLLM route:** not exercised; this follow-up changes native presentation only.

The final optimized Release run passes **61 focused native tests, zero failures**, with actor data-race checks (`native-verified.log`). It includes all five source-reconciliation tests, four native Markdown viewport tests, seven native code tests, nine native document tests, five stable-reading tests, nine streaming-Markdown tests, six geometry-cache tests, nine chronological-presentation tests, four shared idle-scheduler tests, two scrolling fixtures, and the pane-retention test. This is focused coverage, not a full-native-suite claim. No failing check remains in this selected set.

## Final optimized measurements

| Fixture (120 scroll steps) | p50 | p95 | p99 | Maximum synchronous work |
| --- | ---: | ---: | ---: | ---: |
| 300 rich transcript rows | 3.771 ms | 25.276 ms | 82.504 ms | 63.773 ms |
| One 88 KiB Markdown answer | 6.047 ms | 8.761 ms | 15.997 ms | 10.942 ms |

Both traversals preserve settled row frames and the requested clip position, with zero exact-width row cache misses and bounded mounted view counts. The 300-row fixture has 69 native intrinsic validations as hosts reenter the window; the large-answer fixture has zero. The results do not establish a material scrolling-speed improvement over the baseline; the code fixes concern source identity and stable reading/selection.

Reproduction: use the commands in the [0.1.76 record](Bello-Agent-0.1.76-2026-09-22.md#reproduction-commands), adding `MarkdownSourceReconciliationTests` and the affected native Markdown/code, geometry-cache, document, idle-scheduler and pane-retention suites. Scratch logs are kept outside the repository under the session's `tmp/stable-reading-077` directory.

## Publication

Version **0.1.77/build 81**, arm64 macOS 14+, is publicly released. Packaged source: `ae7366fdc1721fea61e0fec41d9fb99c3aa82065`; website publication: `2448ad9b7c54371bc9e7c460980a66f08806c07c`. Both repositories are pushed to GitHub `main`.

- Developer ID **Zhaofeng Wang (43TXHV3TM3)**. Nested components, native helper and app signed and validated.
- App notarization **c1b50a73-2a40-4de6-a8ae-2781579692f4** and DMG notarization **f2d0a4a5-a0fd-4ab7-bc99-17cf443e8e62** accepted and stapled. Gatekeeper reports Notarized Developer ID.
- Packaged helper/catalog offline smoke passed: six bundled models, native Swift helper, no bundled Node runtime.
- Installer: **9,090,069 bytes (8.67 MiB)**; SHA-256 **`26e539f0a60ba2ba9fbf1d8cbc8df679f1188e30be653599e7f6aed86f7ccf01`**.
- Local and public Sparkle Ed25519 signature/hash validation passed. Canonical Bello Agent and legacy Pi App feeds are byte-identical; the public product page advertises 0.1.77 and its installer.
- Cloudflare check **106550760154** succeeded at **2026-09-21 23:02:33 UTC**. Public verification passed at **2026-09-21 23:04:06 UTC**.

[Download 0.1.77](https://belloware.com/assets/BelloAgent-0.1.77.dmg) · [Product page](https://belloware.com/bello-agent.html) · [Released source](https://github.com/BelloWare/BelloAgent/commit/ae7366fdc1721fea61e0fec41d9fb99c3aa82065). Installation/update rehearsals remain omitted under the owner's standing instruction.

## Performance baseline

Environment: Apple M3 Max Virtual, 16 GiB RAM; macOS 14.8 (23J21), Xcode 16.1 (16B40), arm64 Swift 6. Native tests enable actor data-race checks. Timings include layout/draw opportunities and a main-run-loop opportunity per scroll step.

The optimized 300-rich-row baseline measured p50 **4.013 ms**, p95 **24.769 ms**, p99 **81.108 ms**, maximum synchronous work **68.685 ms** over 120 steps. Exact-width row cache misses were zero; row frames/reader positions remained unchanged. Mounted native view counts stayed at 276 before/after. These tails exceed a universal <5 ms target.

A subsequent Debug phase-isolation run attributed 351 ms of 608 ms inclusive mount work to viewport layout; host creation was 13 ms, attachment 24 ms, detachment 24 ms and release 6 ms. Inclusive counters overlap and must not be summed. This finding does not justify deferring all reclamation or retaining unbounded native trees. No speculative performance behavior was changed on the basis of these measurements.
