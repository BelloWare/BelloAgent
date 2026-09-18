# Bello Agent 0.1.3 review and release acceptance

Date: 2026-09-16. Branch: `master`. Released: **0.1.3/build 7**.
Source `92a53d3`; website `61456d6`. Public download and the actual 0.1.2→0.1.3
Sparkle installation pass; see the distribution section below.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

## Claude completion and review

Claude session `d41bbd9f-7500-418b-8b22-588f8b1a9a07` completed at
2026-09-15 22:48:26.757 UTC, before this review changed source. Its workflow
`wf_9ae3ef80-e72` returned all five agent results and a completion notification;
all main-session tool calls after 22:00 UTC had results. Three background jobs
had exited. The earlier manifest/test failure was superseded by 123 passing
native tests and a passing UI gallery. The final baseline was `a22f12a`.
Screen `26403.pi-app-claude` remains open with remote control; its Claude process
had no child processes after completion.

The review preserved Claude's multi-folder workspaces, per-chat model/effort,
session/turn attribution, editable branches, message details and report controls.
Small follow-up commits fix:

- Atomic edit journaling and paused replacement recovery; oversized rejected
  edits leave context intact. Compaction markers survive subsequent edits.
- Per-turn model capacity/output limits through submit, steering, edits, queues,
  summaries and compaction. Explicit model-default effort omits inherited
  reasoning fields; old model-specific effort mappings do not leak to a new alias.
- Offline branch replay, complete persisted edit drafts, restoring cancelled
  drafts, loading full earlier messages, and showing the latest edited branch.
- Folder changes during active work and dashboard stale-query/brush state races.
- Catalog origin-scoped credentials, anonymous external catalogs, bounded URL,
  numeric and schema validation, cancellation generations and stale-cache guards.
- Native model/effort menu buttons after interactive selection failed with the
  original Toggle items on macOS 14.8 (`9ba881c`).

## Deterministic verification

| Check | Actual result |
| --- | --- |
| Swift helper core | 74 tests, zero failures; 4.456 seconds |
| Optimized helper wire tests | 21 cases, zero failures; 4.756 seconds; both APIs, tools, exact bytes, malformed requests, compaction, cancellation and exact-serialized-request cache behavior |
| Optimized helper process/MCP | 2 cases, zero failures; 2.686 seconds |
| Python release/fixture suite | 48 cases, zero failures; 15.314 seconds after the report-page changes |
| Native combined suite | 158 executed: 156 passed, two opt-in tests skipped, zero failures; 12.807 seconds after the report-page changes |
| Final menu-change regression | 8 model-switch cases passed; 0.158 seconds |
| TypeScript | Passed |
| Optimized native helper/transcript staging | Passed; helper 1.56 MiB; no bundled Node runtime |
| Release build and packaged helper smoke | Passed; final signed/notarized app, DMG and public update verified below |
| Signed ordinary-Keychain acceptance | 51 checks/observations, zero failures; synthetic item removed and absence verified; no production-vault access |

The local gateway validates actual requests before selecting responses. Its
catalog offers an `auto-router` model with 2M/300k limits and `fixture-fast` with
128k/16k limits and no explicit reasoning. Wrong model limits, unsupported effort,
deprecated aliases, and incorrect secondary-root tool results are rejected.
Capture assertions compare retained bodies with independently observed bytes,
not normalized events. Exact-request caching uses the serialized body bytes,
without deleting session metadata to manufacture a cache hit.

## Interactive acceptance

The final fresh-state native test passed in **444.988 seconds**; together with
the eight model regressions, nine tests passed in 445.146 seconds. The first
preflight run was intentionally ended after discovering the menu-selection
problem and before menu acceptance; its failures remain in the scratch log.
It is not counted as passing acceptance.

CUA exercised the real native composers and WKWebView transcript against a
test-bundle-only memory vault and loopback gateway:

- Responses and Messages each performed a validated `read` tool round trip.
- Both selected the fast catalog model through the corrected native menu and
  sent 16,000-token output limits with no reasoning/thinking/output_config fields.
  The composer displayed the selected 128k context capacity.
- Editing `BRANCH-ORIGINAL-FIXTURE` after `ABANDONED-REPLY-FIXTURE` produced
  `BRANCH-REPLACEMENT-FIXTURE`. Subsequent wire context excluded both abandoned
  markers. The edited-branch marker remained visible after helper reopening.
  The preflight also verified cancelling an edit restored the previous draft,
  and revealed the synthetic request in the message-details sheet.
- Workspaces added and trusted a second synthetic folder. A subsequent Messages
  tool round trip read its `SECONDARY.md`; the gateway required the actual
  `SECONDARY-WORKSPACE-ROOT-VERIFIED` content before accepting the continuation.
- A reported cache hit displayed zero USD cost. The menu and report agreed on
  **11 requests, 511 consumed tokens and $0.0125 USD**, with one hit and ten misses.
- The menu showed both requested aliases and all four resolved models. CUA
  opened it twice, used all three time scopes, opened Report, closed the main
  window, and reopened it through the status panel.
- Report presets, custom date controls, cache-ratio display and live alias
  filtering worked. Filtering to `fixture-fast` changed the report from 11 to
  seven requests, $0.0125 to $0.0075 and 9% to 14% cache hits. Reset restored totals.

All **22 current-run request/response bodies** independently verified; there
were **no unverified prior attempts**. Verification JSON:

```json
{"requests":11,"verifiedRetainedBodies":22,"currentRunVerifiedBodies":22,"priorUnverifiedAttemptIDs":[],"catalogModelEditAndMultiRootChecks":true,"menuOpens":2,"menuReportOpens":1,"menuScopes":["day","retained","week"],"menuRequests":11,"menuTokens":511,"menuCostUSD":0.0125}
```

CUA does not expose the physical status item: a fixture toolbar invoked the
actual `NSStatusButton`, then CUA operated the production panel. Report menu
selection required native keyboard navigation when the remote click did not
apply. Chart drag probes produced no usable selection; source review found no
clear defect, so physical chart dragging remains unverified. Do not claim those
physical gestures passed.

## Artwork and distribution

The richer icon was generated with the built-in imagegen tool using BelloBox
and Bello Clipboard as references. Four outputs painted the outer checkerboard
instead of providing alpha. The artwork proposal has been shared; permission
to remove only that outer background with native image processing is pending.
No generated image with painted transparency has replaced the production icon.

The UI release retains the checked-in icon while the alternate background-cleanup
choice is pending. Artwork cleanup did not block this release. 0.1.3 signing,
notarization, website publication, public-byte verification and an actual
0.1.2-to-0.1.3 Sparkle installation are complete, as recorded below.
The updated nine-feature product-page template passed a desktop Safari layout
check against a local preview; this was not a deployment verification.
Use [Release.md](../Release.md) and preserve the existing identity, vault, history
and canonical/legacy feed continuity. Do not treat this candidate's tests as
proof of a published or installed release without the distribution checks below.

## Evidence and limits

Scratch root for this session:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.3`.
Key logs: `claude-completion.txt`, `host-review/swift-final.log`,
`optimized-host-tests.log`, `process-mcp-tests.log`, `python-tests.log`,
`typecheck.log`, `native-tests.log`, `ui-acceptance.log` (failed preflight),
`ui-final.log`, `ui-final/verification.json`, `keychain-acceptance.log` and
`keychain-20682dd1-7d2c-4815-8ea5-ab5ce6fc0dc9/report.json`.

These are request-aware mocks, not an installed/deployed LiteLLM process. No
specific live endpoint/version/model aliases/key location has been supplied.
Ordinary Keychain does not promise raw same-user write/delete isolation.
Language IME and the full Release performance budget remain unverified; the
historical Debug burst-input and helper-to-paint target misses in the
[0.1.2 evidence](Bello-Agent-Release-2026-09-16.md) remain applicable limits.
Full-text HTTP body search remains deferred.

## Owner-requested report page and independent review

The owner's exact UI request was submitted to the existing Claude screen session
at 2026-09-15T23:39:38.631Z. Claude finished at 23:50:13.636Z, producing `d1fc721`
and `d6b8210`. All 27 tool calls had results; no unmatched tools, asynchronous
tasks or child processes remained. Completion evidence is
`claude-ui-completion.json`; the screen session remains open and idle.

Independent review added native conversation visibility/focus preservation,
hidden-send guards and retained view identity (`912fc36`), report re-entry and
query-race fixes (`9d83db6`), and responsive layouts with consistent summary
semantics (`8d8b6dc`). Requirements and release copy are in `775fd5b`.
The dashboard is an in-window page; filters and details are collapsed initially.
Filters wrap, selected chips remain visible, custom ranges reveal date controls,
and the request table scrolls horizontally in compact windows. Native composers
and WKWebViews retain their instances while the report is visible. Reduced
Motion disables report/navigation animations.

- Final regular native run: **156 passed, two opt-in tests skipped, 158 executed**,
  zero failures in **12.807 seconds**. Includes 11 report-controller tests and
  three native navigation tests covering responder, undo, selection, drafts,
  hidden sends and live WKWebView identity. Earlier fixture failures used invalid
  non-UUID request IDs; those fixtures were corrected before the passing run.
- Python release/fixture suite: **48 passed in 15.314 seconds**. Core, optimized
  wire, process/MCP, TypeScript and signed synthetic Keychain results above are
  reused because their source has not changed in this UI batch.
- Screenshot gallery: **one test passed in 67.724 seconds**, producing 26 light/
  dark captures, including 920×740 compact reports with collapsed and expanded
  custom-date filters. Compact/full report images were visually inspected.
- Fresh interactive CUA run: **one test passed in 260.101 seconds**. Responses
  streamed across report navigation; the original composer draft survived and
  ignored hidden typing. Messages performed a validated read-tool continuation.
  API filters, collapsed chips, report freshness, details, row inspection and
  the icon-only New Chat button worked. The menu panel opened twice, including
  with the main window closed, used three scopes and opened the report page.
  All **six bodies from three requests** independently matched retained bytes;
  no body gaps. Totals were **333 tokens, $0.00375**, with `auto-router` and both
  `fixture-responses-model` and `fixture-messages-model` visible.

This focused UI run does not replace the earlier 11-request feature acceptance.
The post-reopen Cmd-N probe targeted the test app's empty default model: its
separate bare NSWindow lost SwiftUI scene-focused routing. Production WindowGroup
and fallback commands share one model. Button navigation and the New Chat icon
passed; post-reopen fixture shortcut routing is not claimed. No production vault
configuration was changed. Physical menu-bar clicks, chart dragging, real IME and
the complete performance budget retain the limits recorded above.

Logs: `ui-review/native-tests-passing.log`, `ui-review/python-tests.log`,
`ui-review/gallery.log`, `ui-review/live.log`, `ui-review/live/verification.json`,
and `ui-review/live/hidden-composer-proof.json`. The final report screenshot is
shared as `bello-agent-report-page.jpg`.

## Verified public distribution and actual update

The authorized release was built from clean, pushed source **`92a53d3`**, then
published by `scripts/publish-release.sh 0.1.3` as website commit
**`61456d6d6c8bb7f6d63318b05558ecbe73ef9d0e`**. Documentation-only follow-up
commits record these results; they do not change the installed binary.

- `BelloAgent-0.1.3.dmg`: **4,787,386 bytes (4.57 MiB)**, below the 20 MiB target.
  SHA-256: `2d5f4e985b595d1dd84fa12cf8dfa0a545f4c9400b40869a186ddf926f9b4de5`.
- Developer ID team `43TXHV3TM3`, secure timestamps, hardened runtime and nested
  signatures pass. One transient DMG timestamp-service failure retried
  successfully; no unsigned or untimestamped fallback was used.
- Apple accepted app submission `f4e579ea-5cd3-4937-8320-1c04089001f1` and DMG
  submission `0861f06b-bbaa-4547-9c97-7958d79a79fc`. Both tickets were stapled and
  validated. The signed helper smoke passed with no bundled Node runtime.
- After the deployment propagated, `scripts/verify-published.py` verified the
  public installer hash and Sparkle Ed25519 signature. The canonical
  `bello_agent.appcast.xml` and legacy `pi_app.appcast.xml` were byte-identical.
- The public `/bello-agent.html`, `/pi-app.html` compatibility redirect, homepage,
  sitemap and icon each matched the committed website bytes.
  Safari also displayed the live product page with its 0.1.3 download link,
  4.57 MiB size and updated report-page feature description.
- CUA used **Check for Updates → Install Update → Install and Relaunch** in the
  installed **0.1.2/build 6** app. Sparkle installed and relaunched **0.1.3/build 7**
  at the same `clipboard-release/update/PiApp.app` path. All **75 files and symlinks**
  matched the signed release; deep strict `codesign`, notarization-ticket and
  Gatekeeper verification passed. Preserving the older folder name is expected.
- The five existing historical chats and their transcript remained visible.
  Settings → Reload Vault succeeded at revision 0 with its existing empty
  configuration. No credentials/preferences were saved and no real gateway call
  was made. The installed production window's ⇧⌘R and Escape navigation passed;
  this is separate from the post-reopen bare-NSWindow fixture limitation above.

Public downloads: [product page](https://belloware.com/bello-agent.html) and
[notarized installer](https://belloware.com/assets/BelloAgent-0.1.3.dmg).
The final DMG is also shared in the session outbox. The generated icon proposal
remains a separate pending refinement; this release uses the checked-in icon.

Evidence: `release-0.1.3.log`, `build/release.jNqsGH/`, `publish-0.1.3.log`,
`public-verification.log`, `public-site-verification.json`,
`installed-update-verification.json` and `installed-signature.log` under the
scratch root above. These distribution checks complete the release; they do not
remove the deployed-gateway, chart-drag, IME or performance limits.
