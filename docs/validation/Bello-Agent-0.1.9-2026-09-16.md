# Bello Agent 0.1.9 acceptance

Date: 2026-09-16. Branch: `master`. Release source:
`e3940fe61ff03af2a58b083d632a56b3f1b5329c`. Version **0.1.9/build 13**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 08:17:28 UTC.**

## Reviewed changes

This release adds session model/cost breakdowns and puts historical output TPS
and requested/resolved model distribution first in the status panel. Activity
lists running work only; sidebar unread behavior is preserved. Historical TPS
uses reported output divided by summed dispatch-to-completion time, with
coverage; it is separate from the live exposed-byte estimate.

Captured bodies load all retained bytes without manual pagination. Valid JSON
defaults to an expandable native tree; raw text/hex and original-byte export
remain. Partial/expired/omitted states stay explicit. Assistant status lines
show gateway-resolved model names with bounded mixed-model coverage and explicit
unreported/conflicting/incomplete identity.

Composer model selection uses a searchable native popover backed by the saved
connection's live catalog, including refresh-on-open, source changes and
last-good-list errors. A separate configured or catalog-recommended mini model
can generate a title in a retained, tools-disabled background session. Those
sessions have fixed titles and separate capture/cost scope, stay hidden until
revealed, preserve manual titles, and never retry uncertain work after restart.
Without a mini choice, the local text title remains.

The empty strip above chat/report titles is removed. Native traffic lights keep
their reserved sidebar area while detail headers begin at the window top;
dragging, double-click zoom/restore and retained composer/transcript state remain.
Keep the selected flat icon, bundle ID, history paths, ordinary single-item
Keychain vault and Sparkle key. New requests remain Responses-only; historical
Messages and encrypted captures remain readable.

Implementation commits: `07e436e` (gateway model status), `4fafc8c` (complete
JSON captures), `0934821` (usage distributions and TPS), `442ad6f` (isolated
title helper), `6aa9de6` (catalog/mini settings and compact header).
Release preparation is `e3940fe`.

## Focused acceptance

| Focused native suite | Final passing cases |
| --- | --- |
| AccountingScale | 1 |
| CapturedBody / MessageDetail / PayloadArchive | 9 / 7 / 13 |
| GatewayAccounting / LiveAccounting | 16 / 5 |
| MenuBarMetrics / MenuBarPresentation / SessionUsage | 21 / 3 / 6 |
| ModelCatalogEndpoint / ModelSwitch | 14 / 11 |
| ProjectSidebar / SessionOrganization | 6 / 8 |
| SettingsSave / TitleGeneration | 6 / 7 |
| WindowPresentation / ReportNavigation | 5 / 3 |
| Workspace | 14 |

**155 unique focused native tests pass after corrections and focused reruns.**
The first broad selected run executed 155 tests in 19.717 seconds with four
failed assertions across two cases: catalog-render inspection and a 28-point
native safe-area inset. The layout fix applies top safe-area handling to the
split child; the final WindowPresentation/ReportNavigation rerun passes.
The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.
ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.

Helper title/session/context checks: **17 passed in 0.494 seconds**. Transcript:
**24 passed in 0.811 seconds**; TypeScript passes. Capture coverage includes
CapturedBody 9, MessageDetail 7 and PayloadArchive 13. TitleGeneration 7 includes
an actual packaged-helper loopback request checking the chosen mini model,
512-token output cap, disabled tools, isolated instructions, one dispatch,
durable title session and separate capture/cost accounting.

The 100,000-attempt/300,100-link Debug fixture preserves attribution and
coverage: a 101-message page took **555.924 ms**, session-only **56.682 ms**, and
a single-message query **59.201 ms**. These are local database timings, not
input-to-paint measurements or the full Release performance budget.

Eleven synthetic JPEGs were inspected: five session/menu usage views, three window-chrome views, expandable JSON, and two model-picker views. They show only isolated fixture windows, not unrelated applications.
Unchanged broader provider/wire/process, Python, native/gallery and ordinary
Keychain evidence is reused from versioned records. No full gallery, deployed
LiteLLM test, production gateway credentials, install/update or signed owner/update
rehearsal was used.
## Initial failures and corrections

- The first usage-focused run had one query-plan assertion failure. The
  session query used a global time index. An explicit session/project index and
  matching query-plan assertion now protect the intended scoped lookup.
- The initial compile rejected a test-only compactMap expression. The fixture
  was corrected; no product behavior was bypassed.
- `native-final.log` executed 155 tests with four assertions failing in two
  cases: the test process exposed an empty accessibility tree for the catalog,
  and the actual split detail retained a 28-point safe-area gap above its header.
  The layout fix removes that inset at the split-child boundary; focused
  WindowPresentation 5 and ReportNavigation 3 now pass. Catalog evidence:
  ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.
- Focused reruns are repeated evidence for the same cases, not additional
  unique tests. The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.

TitleGeneration's packaged-helper fixture validates the complete HTTP request
before returning a synthetic JSON reply. It uses a loopback listener and an
in-memory vault. It verifies one mini-model request, disabled tools, isolated
project instructions, a 512-token output cap, retained task journal and cost
charged only to the background task session. The prompt is UTF-8 bounded,
accepted titles are at most 80 characters, atomic claims survive restart, and a
late generated result cannot overwrite a manual rename.

The shared body reader verifies retained length/state/hash stability around
complete reads and cancels stale selections. Native JSON tree presentation,
raw text/hex and exact exports remain separate. Tests cover large bodies,
streaming-prefix/expired/unavailable states, cancellation and storage continuity;
they do not establish hidden upstream traffic or TLS-level capture.

## Signing and public distribution

- Source: `e3940fe61ff03af2a58b083d632a56b3f1b5329c`.
- Website: `856b71140ccbc20adfc1074e8275b1190d32c9e2`.
- Product: [belloware.com/bello-agent.html](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.9.dmg](https://belloware.com/assets/BelloAgent-0.1.9.dmg).
- Size: **6,902,731 bytes (6.58 MiB)**.
- SHA-256: `bf115a54a31210cf683949433eb0f8450e56637bc1354fba7925a91d56869bbc`.
- App notarization: `9cd559bb-e761-4469-8abb-7f1436bc6655` (accepted).
- DMG notarization: `e160a2d4-3f6c-4f29-97e8-89f3d0d93dc9` (accepted).

App/DMG signing and notarization, local smoke checks, public pages/icon,
byte-identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Initial public checks still served the previous feed during deployment. The fourth scheduled retry verified both byte-identical feeds, the downloaded archive hash/signature, product page and download link, legacy redirect, homepage, sitemap and selected icon at 2026-09-16 08:17:28 UTC.
The icon remains the selected flat master, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
No installation/update or signed owner/update rehearsal was performed, following
owner instruction. Updater functionality remains enabled; actual-update evidence
is historical in the [0.1.6 record](Bello-Agent-0.1.6-2026-09-16.md).

## Commands and evidence

Per-run scratch:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/session-usage-followup`.
Stable incremental PI_BUILD_ROOT:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.
Its older directory name identifies a reused cache, not the release version.
Native fixtures use isolated PI_APP_SCRATCH_ROOT; focused captures contain only
synthetic own-window content, and no raw logs/state are published.

Source/test logs: `native-focused.log` (original query-plan failure),
`native-compile.log` (initial test compilation),
`native-final.log` (155-case run), `native-ui-rerun.log` (focused UI follow-up).
Additional final rerun evidence is described above. The native selection
comprises the suites in the table with parallel native testing disabled.
Transcript command: `node --import tsx --test packages/host/test/transcript.test.ts`;
TypeScript: `npm run typecheck`. Helper selection covers 17 title/session/context
cases; unchanged full suites are explicitly reused.

Release/publication uses `scripts/release.sh`, `scripts/publish-release.sh` and
`scripts/verify-published.py` with the stable build root.
Detailed release logs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.0CxrPV`.

Existing limits remain: local fixtures are not a deployed LiteLLM installation;
physical status-item clicks, chart dragging, foreground unread clearing through
CUA, real-language IME and the full Release performance budget are not newly
verified. Ordinary Keychain's same-user write/delete limits remain. HTTP-body
full-text search is deferred.
