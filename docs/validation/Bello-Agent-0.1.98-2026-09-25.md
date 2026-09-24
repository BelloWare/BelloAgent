# Bello Agent 0.1.98 validation

Date: 2026-09-25. Version 0.1.98, build 102, arm64 macOS 14+.

## Changes

- **One text per rendered reply** (`f289470`).
  - A reply was a stack of text views, one per paragraph, heading, list item, code block and table, so a selection stopped at a block's edge. Every block is now laid out by TextKit in one `NSTextView` (TextKit 1); a drag, Shift-click or Select All runs across the whole reply.
  - A copy is the reply as it reads: list items with `- ` / `1. ` markers (nested items indented), table cells split by tabs, blocks by a blank line; the large-table preview line is left out. Quoting a selection into a side chat takes the same text.
  - The blocks keep the rows' geometry: the same measures, gaps and paddings, and SwiftUI's line height (TextKit sets 14.5 pt text at 17 pt, SwiftUI at 18; a minimum line height of the face's natural height, rounded up, matches it).
  - Code panels, quote bars and table outlines are drawn behind the text by a layout manager; tables are TextKit tables at their natural column widths, narrowed in proportion when wider than the page. The fence toolbar, heading copy buttons, "Open full table" and the caret are overlays; the fence and heading controls come with the pointer.
  - Streaming still reads through `StreamingMarkdownState`, so incomplete markdown never flickers. A token replaces only the characters that read differently (and, for a block that changed in the middle, keeps the characters after it), so TextKit lays out only from there and a selection above stays. A top-level list is set an item at a time; an open fence is appended to and coloured from its last neutral point.
  - Measured per token: a paragraph 0.41 ms after 120 blocks and after 1,150; a 400-item list 0.68 ms; a 30 KB fence 0.11 ms (29 ms before the fence fast path); through the page, 0.55 ms under 131 blocks and 0.69 ms under 1,195.
  - A selection or reading position in a paragraph that reads anew (a reference defined late) follows its words through the source.
  - A fence over 32 KB is shown whole (0.1.97 showed it 8 KB at a time, with Previous and Next); a table wider than the page wraps its cells instead of scrolling sideways. VoiceOver gets Copy code and Copy section actions.
- **A streaming reply under its header** (`11f4a7c`). A token grew the surface outside SwiftUI, inside a wrapper that is not flipped: it grew upward over the response header, and the taller row centred the wrapper's stale size. The reply stood up to 81 pt too high until the row's next full measurement, every 64 tokens; 0.1.97 did the same (probed on its code). The surface now keeps its top and tells SwiftUI its new size.
- **Typing into a reply** (`11f4a7c`): a text the reader can only select no longer counts as taking typing, so a keystroke there goes to the composer, and ⌥← / ⌥→ there switch versions as they do elsewhere in the chat (Shift-⌥-arrows still extend the selection).

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on `11f4a7c`:
  - serial lane: 207 tests, 7 skipped, 0 failures;
  - parallel lane: 1,416 passed, 16 skipped, 0 failed;
  - gallery: 112 screenshots, 0 failures;
  - helper: 434 tests, one failing: `DecodeSpanTests.testHiddenReasoningIsInsideTheDecodeSpan` parsed its gateway's `ready.json` half written ("Unexpected end of file"). The gateway created the file before filling it, and the test waits only for the file to exist. `26ab397` has it, and the two other fixtures that wrote theirs the same way (`HTTPIngressTests`, `MCPRecoveryTests`), write a temporary file and rename it, as the other fixture gateways do. After that, `DecodeSpanTests` passed five runs in a row, and `HTTPIngressTests` and `MCPRecoveryTests` passed; `26ab397` changes only those three helper test files;
  - scripts: wire 32, concurrent 3, acceptance 2, Python 65;
  - 10 min 59 s.
- **First gate run** on `f289470`: the gallery (112 screenshots), the helper (434) and the script checks passed. Five native tests failed, each written for the stack of views a reply used to be, and `11f4a7c` updates them:
  - serial: `ConversationPaneTests.testFindingTheComposerForStrayTypingDoesNotWalkTheWindowPerKeystroke` (a long chat now has fewer than its 150-view floor; the floor is 80), and `TranscriptPerformanceRegressionTests.testMarkdownContentRemainsSelectableWithoutSelectableDecorations` and `…testStreamingTailKeepsSettledNativeTextSelectionAndCachedLayout`;
  - parallel: `StableToolPresentationTests.testNativeSelectionAndDrawGeometrySurviveToolFragmentsAndLateAccounting` and `TimelineStreamingFastPathTests.testATimelineReplyTakesTheStreamingFastPaths` (its word check).
- **Gallery against 0.1.97's:** the 112 screenshots from the gate differ from 0.1.97's by a median of 0.28% of their pixels, at most 3.36%. The largest differences are fixture content (a random turn ID that wraps differently, clocks), and text set up to 1 pt lower in its line, with even paragraph spacing where 0.1.97's varied around a line holding an emoji.
- The "AttributeGraph: cycle detected" lines in the gallery log predate 0.1.5, and are not failures.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed; in the mid-run scenario, 10 of 10 markers were recalled. Reported cost $2.28 of the fixture's $5.00 cap (synthetic).

## Release provenance

- **Source:** tag `v0.1.98`. `release/0.1.98` was merged into main with `--no-ff` (3 commits since 0.1.97), followed by one release commit.
  - The release commit before these docs, `f4854c8`, has native tree `8ddf61ba8edd030be9b2f2290c3996f7883fa04e` and helper tree `020114c5192befdd881f30f0fc09dbbdfbfa73d4`. The DMG was built from it.
  - Only release-provenance documentation changed after the candidate build.
- **Website publication:** `ebbd7f5`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `6f99aa9e-cc09-4a33-8645-4a60f314bb79`; DMG `ea235e0b-f274-482e-970c-50eccb780043`.
- **Public verification** at **2026-09-24 16:54:57 UTC**: the product page advertises 0.1.98, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,855,712 bytes (10.35 MiB)**; SHA-256 `c76094273c2a92c9f47f64761cda2790e7c4ccb3516415a218624cc79bd18296`.
- **Download:** [Bello Agent 0.1.98](https://belloware.com/assets/BelloAgent-0.1.98.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
