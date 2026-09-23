# Bello Agent

Native macOS 14+ / Apple Silicon application, SwiftUI/AppKit throughout: the
composers, the conversation page (Markdown, syntax colouring, diffs and usage
drawn by the app itself) and a supervised, self-contained Swift helper. There
is no web view, no JavaScript and no Node in the build or in the bundle; the
only linked third-party code is Sparkle for updates. Pi v0.85.1 remains a
behavioral reference, not the current application runtime.

Open source under the [MIT License](LICENSE) at
[github.com/BelloWare/BelloAgent](https://github.com/BelloWare/BelloAgent).
Continue on **main**. Read [implementation status](docs/Implementation-Status.md)
first, then [Features.md](Features.md), [Design.md](Design.md) and the
[test handoff](docs/Swift-Test-Handoff.md).

New requests use the LiteLLM Responses API. Existing Messages history and
credentials remain readable; converting a saved connection is explicit. The app
includes tools and MCP, queues and side conversations, exact HTTP inspection,
and per-message/session/report cost and cache accounting. New captured bodies
are stored without encryption for 30 days by default, subject to quota.
Authentication headers are masked: longer request tokens retain at most their
last four characters; short tokens, cookies, response authentication and
credential echoes are fully masked. Known credential literals in captured
request bodies use labeled SHA-256 transformations, without changing wire bytes.
Existing encrypted captures remain readable. Full-text search inside HTTP bodies
is deferred.

Onboarding checks the selected gateway model before opening the first chat.
The native menu bar opens on either mouse button. Usage shows historical output
speed, tokens, reported costs and requested/resolved model distribution; Activity
shows running work; TPS is the decode speed: reported output tokens after the first (hidden reasoning included) divided
by the time from the first generated token to the last; replies under 250 ms of generation are left out. Session headers and
cost totals open resizable usage windows with tokens, cache and model/cost breakdowns. Unread history remains in the sidebar.

**Bello Agent 0.1.57/build 61 is publicly released** at
[belloware.com](https://belloware.com/bello-agent.html), from source `dbbf3421a7143e606768659be8e688ba64d8ac59`
and website `eaaa9f647ff410dacc4126d3e370ea7249357264`. The DMG measures **7,538,829 bytes (7.19 MiB)**,
SHA-256 `f82811cec97b217385e2d58b9fb6a1ac62b3a6a8c8fa725e937a08afe00b5f3b`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 01:00:09 UTC**.
Cloudflare check **105810946636** succeeded.
Read the [0.1.57 release record](docs/validation/Bello-Agent-0.1.57-2026-09-19.md) and
[five-session performance review](docs/Five-Session-Performance-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

**Bello Agent 0.1.56/build 60 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `bb114ef07a69ef6e1cb33c60e733564e930a8a27`
and website `3fe37bb891f544f6ed464a1f82d9e60d4c7a1b08`. The DMG measures **7,478,445 bytes (7.13 MiB)**,
SHA-256 `e19097bbaaf6c2eaa3fcc69ba9db2d1427ffaf299f03761546266c2d57fd822b`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 23:34:17 UTC**.
Cloudflare check **105796177570** succeeded.
Read the [0.1.56 release record](docs/validation/Bello-Agent-0.1.56-2026-09-19.md) and
[topics review](docs/Topics-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

**Bello Agent 0.1.55/build 59 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f42d237efe30c298523a47b62dd23c35fdda107e`
and website `5c1aec57e1c8e9a69ef44cbbd053715280db3e01`. The DMG measures **7,357,293 bytes (7.02 MiB)**,
SHA-256 `031ec071db485f796e9dc2e66c9b8b24f13da443778877db54a1f35d8f1955db`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 22:58:16 UTC**.
Cloudflare check **105788774388** succeeded.
Read the [0.1.55 release record](docs/validation/Bello-Agent-0.1.55-2026-09-19.md) and
[scrolling review](docs/Scrolling-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

**Bello Agent 0.1.54/build 58 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `49ed3c95e7fe53605bfb31b7ad8c0c8595ed0f4d`
and website `8170e23d0ef7b0f9284c37679aa4895108b679d0`. The DMG measures **7,335,665 bytes (7.00 MiB)**,
SHA-256 `f97d207d8f18ed7c0d2a12f7898d04b70463598c3067cce3590b2076e35b0a83`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 22:03:23 UTC**.
Cloudflare check **105776630049** succeeded.
Read the [0.1.54 release record](docs/validation/Bello-Agent-0.1.54-2026-09-19.md) and
[session-reference review](docs/Session-Reference-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

**Bello Agent 0.1.53/build 57 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `feb9df30c02c21e38ccb95d378ac619688062e49`
and website `5d43a239e2fdc8665e5782976ba8e3ec7c9cd352`. The DMG measures **7,329,401 bytes (6.99 MiB)**,
SHA-256 `6354391322a03c8bc408b8db57e2edddc0fa1eb15cdece0f68c29edd30ae9c24`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 21:30:15 UTC**.
Cloudflare check **105767983479** succeeded.
Read the [0.1.53 release record](docs/validation/Bello-Agent-0.1.53-2026-09-19.md) and
[responsiveness review](docs/Responsiveness-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

**Bello Agent 0.1.52/build 56 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `78e7b8f80a89e497978d915908f97b080a751512`
and website `f188c0db312da614df13b97a6f113b899b87932a`. The DMG measures **7,269,703 bytes (6.93 MiB)**,
SHA-256 `39037ef81f15ef1c3c28be59c1c142b258f5b967372df03ceec71cb534887c4a`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 20:13:40 UTC**.
Read the [0.1.52 release record](docs/validation/Bello-Agent-0.1.52-2026-09-19.md)
and [throughput/worker review](docs/TPS-Workers-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

[Download 0.1.57](https://belloware.com/assets/BelloAgent-0.1.57.dmg).

Signing and notarization need credentials this repository does not carry: a
Developer ID identity, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`
and the Sparkle update key in the login keychain. Building, running and the
whole test suite need none of them.

<!-- release-summary:0.1.57 -->
Version 0.1.57 isolates per-chat usage notifications, skips hidden helper transcript
projection, rejects stale refresh replies and reuses verified immutable native row
geometry. In the five-session fixture, background content/billing work fell from
12.51 ms to 7.24 ms mean, with zero whole-workspace notifications. A return to the
initially mounted chat took 629.11 ms to readiness plus 68.76 ms deferred settlement;
the original readiness-only baseline was 1,421.23 ms. Repeated helper status reads
fell 98.0%. Acceptance covers 118 distinct native passes, 41 helper passes and three
request-aware concurrent gateway scenarios (162 distinct passes), with two native
interactive checks skipped. The final shipping-source selection passed 23/23;
unchanged checks reuse the earlier successful selections, excluding four discarded
experimental tests. Twenty simultaneous requests completed tools and exact capture.
A shared Markdown-block cache was rejected after it slowed long-answer scrolling.
Rich foreground layout still has spikes (54.46 ms mean, 124.57 ms maximum), and cold
large-history loading remains expensive. Physical trackpad/VoiceOver smoothness is
unverified on this inactive desktop. Installation and actual update rehearsals stay
skipped under the owner’s policy.
<!-- /release-summary:0.1.57 -->

<!-- release-summary:0.1.56 -->
Version 0.1.56 adds project topics: collapsible, named groups for related
sessions, with New Chat, rename, removal that keeps chats, and drag-and-drop
between topics or back to the project header. Move to Topic is also available
in session menus. New chats inherit the focused topic, sides/forks inherit
the source group, and moving a parent includes its saved side descendants.
Atomic metadata updates preserve active work, drafts, history and session IDs;
regressions cover side publication, late writes and concurrent deletion.
Topics and their disclosure state persist across restart.

The native Release selection passed 90 tests with no failures or skips; a
final seven-test subset also passed after checking the packaged drag-type
declaration. Unchanged helper/gateway/scrolling evidence was reused. Physical
pointer drag/drop, context-menu interaction and VoiceOver remain unverified
on the inactive remote desktop; real item-provider dispatch and hosted native
sidebar layout passed. Installation/update rehearsals remain skipped.
<!-- /release-summary:0.1.56 -->

<!-- release-summary:0.1.55 -->
Version 0.1.55 keeps only nearby native transcript rows and Markdown blocks
attached while retaining complete content, exact geometry and selected text.
The 300-message fixture drops from 85.7 to 9.6 ms per native scroll step on
average; the 88 KiB answer drops from 44.6 to 13.0 ms. These are comparable
layout/display stress measurements, not physical display FPS. Initial loading
of every retained row still requires an up-front geometry pass.
The affected Release XCTest run executed 78 cases: 76 passed and two interactive
pointer checks were explicitly skipped on the inactive remote desktop. A final
four-case Markdown/scroll rerun passed after fixing Copy/Copied layout feedback.
Unchanged provider/helper/gateway/worker and website-staging acceptance is
reused; physical trackpad and VoiceOver checks are not claimed. Single enormous
Markdown blocks and selection at the streaming renderer threshold remain
qualified in the scrolling review. Installation/update rehearsals are skipped
under the owner’s standing instruction.
<!-- /release-summary:0.1.55 -->

<!-- release-summary:0.1.54 -->
Version 0.1.54 adds Copy Session ID and Copy Session Reference to session right-click and conversation “…” menus. References include the authoritative local JSONL path and a shell-quoted read command, without switching chats, loading history or starting helpers. Empty chats and imported identities are explicit. All 27 focused native tests and 12 site-staging tests pass, including executable Bash quoting and complete retained-history reads. The release-page template now preserves native-transcript and reported-throughput wording. Existing helper, gateway, concurrency and rendering evidence is reused. Physical menu/VoiceOver and install/update rehearsals were not repeated.
<!-- /release-summary:0.1.54 -->

<!-- release-summary:0.1.53 -->
Version 0.1.53 uses Bello-styled selection panels and disables the system window tab strip. Exact row-layout caches isolate retained transcript text from streaming updates; ownership-scoped accounting avoids repeated history reads. Comparable native rendering fixtures open about 37% faster and reduce per-update layout/display work by 85.4% (61 rows) and 91.7% (300 rows); these are stress measurements, not a 60 fps guarantee. Final focused evidence contains 191 distinct native passes and four explicit interactive-desktop skips. The native/helper/gateway fixture completed 20 concurrent sessions and tool round trips with 80 exact retained bodies. Unchanged helper/provider/worker evidence is reused from 0.1.52. Pointer/popover and VoiceOver behavior are not claimed as verified on this remote desktop. Installation/update rehearsals remain skipped under the standing owner policy.
<!-- /release-summary:0.1.53 -->

Version 0.1.52 uses gateway-reported output divided by request duration for TPS,
including hidden reasoning once. The latest completed rate remains steady while
a new response runs; native timing uses completion even without visible text.
Read/list/find/grep run on bounded worker threads, with real parallel execution,
queue limits and cancellation coverage. Final checks cover 140 native passes,
188 helper passes and 29 packaged gateway/process scenarios. See the
[throughput/worker review](docs/TPS-Workers-Review-2026-09-19.md).

Version 0.1.51 fixed concurrency limits in capture delivery, command admission,
native storage and project/session startup. Twenty actual native conversations
complete overlapping model requests, tools and durable captures; stopping one
does not interrupt the others. Final evidence covers 137 native cases, 176 helper
cases and 29 packaged helper gateway/process scenarios. Background session usage
updates automatically. In that release, file tools shared the project tool actor; 0.1.52 moves
reads/searches onto bounded workers. Editing gates and remote gateway limits remain. See the
[concurrency review](docs/Concurrency-Review-2026-09-19.md).

Version 0.1.50 improved warm chat loading, trimmed unnecessary initial history,
kept native text geometry stable during transitions, sped up code coloring,
and preserved scrolling while new output arrives. Its focused Release checks cover
195 passing native cases and one opt-in skip, with no failures. Unchanged helper,
gateway and release-tool evidence is reused from 0.1.49. Large rich histories
still have expensive native layout; this release does not establish a universal
frame-rate target. See the [performance review](docs/Performance-Review-2026-09-19.md)
and [0.1.50 acceptance record](docs/validation/Bello-Agent-0.1.50-2026-09-19.md).

The historical 0.1.19 review covered the Settings-to-existing-chat catalog flow.
It fixed clock-correction write loss,
quit and side recovery failures, non-atomic handoffs, false transcript paint/read
acknowledgements, command replay after ledger eviction and duplicated queued
messages after a partial journal commit. Response capture masks known credential
echoes across streaming boundaries and labels that transformation. Archive
maintenance avoids repeated whole-store sweeps; partial cache observations keep
paired sample coverage. Existing catalog lineage and explicit repair remain.
Unavailable live-export bodies cannot be misrepresented as empty captured files.
See the [review and remaining limits](docs/Deep-Review-2026-09-17.md).

Historical catalog changes retained in this release:

Version 0.1.18 makes stale catalog sources visible in older unbound chats.
The model picker offers a direct Use this catalog action for one later saved
custom list on the same gateway, or a chooser for multiple alternatives. The
selected source loads immediately and persists across restart. Repair preserves
the request connection, credentials, selected model, reasoning effort, output
budget and history. Explicit source bindings remain authoritative.

The originally reported fresh-save alias/catalog flow was already handled
by inheritCatalog and covered by an integration test. The remaining gap was
older records without catalog lineage: Refresh correctly reloaded their old
source but gave no prominent repair path. Suggestions now use later saved
same-base/API records with a different custom URL, independently of profileChoice.
No independent connections are silently merged. See the
[issue resolution](docs/Issue-Stale-Chat-Model-Catalog.md).

Version 0.1.17 uses one request-aware context count for the ring, inspector,
preflight and compaction. It counts the actual provider-built instructions,
tools and replayed input. Gateway-reported input is reused only for a matching
prefix and an explicitly pinned, reported model; previous output is not added
wholesale. Counts carry method, request fingerprint, model and uncertainty.
Safe idle tabs and draft edits refresh through a shared debounce/cache; pending
counts do not display stale conversation totals. Output budgets are separate
from catalog model ceilings, with a distinct safety margin. Reported usage,
request context and estimated live output activity remain separate measurements.

These remain estimates, not exact tokenizer results or independently
verified billing usage. No remote counting endpoint is enabled: the reviewed
LiteLLM interfaces do not establish complete Responses request compatibility
and a route-bound counted model. Automatic routing and opaque/image costs retain
explicit uncertainty. See [Context-Accounting.md](docs/Context-Accounting.md).

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

Version 0.1.14 calculates prepared context automatically when a safe idle
chat opens, using the local helper without sending a model request or executing
tools. Matching estimates are reused; cancelled or changed inputs cannot publish
stale results. Unsent chats retain their allocated journal across helper eviction.

Catalog lists now resolve independently of preserved request connections.
New same-authority default-model forks keep catalog linkage; older chats can
choose a saved custom catalog through **Catalog source…** in the model picker.
Refresh reloads saved bindings, requests HTTP revalidation and displays its
successful update time. Changing the list preserves the chat's request route,
credentials, selected model and effort. Legacy lookalike connections are not
automatically merged because their records contain no reliable lineage.

The composer defaults to the bundled six-model Bello catalog; a custom catalog
URL replaces it. It never implicitly lists gateway models. The searchable picker remembers model/effort choices
per connection. Connections can select a separate mini model for automatic
titles, or use the catalog's mini recommendation. Title jobs are retained,
tools-disabled background sessions with their own request/cost scope and a
fixed title; reveal them from the sidebar when needed. Manual titles are kept,
and uncertain work is never retried automatically.

Native window controls keep their sidebar area; chat/report headers start at
the top without a blank full-width strip. Dragging and double-click zoom remain.

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
Since 0.1.38 the transcript is native Swift: its grouping, accounting, Markdown,
highlighting, copy scanning and page behaviour are covered by
`TranscriptActivityTests`, `TranscriptMarkdownTests` and `NativeTranscriptTests`
in the native suite. Local HTTP/SSE fixtures validate requests, tools,
cancellation, compaction and capture; no deployed LiteLLM was used. No full
screenshot gallery or Release performance matrix was run. Installation/update
rehearsals were skipped by owner instruction.

Deployed LiteLLM, physical status-item clicks, chart dragging, foreground unread
clearing through CUA, real-language IME and the full Release performance budget
remain outside this acceptance scope.

The new name preserves bundle ID `com.belloware.PiApp`, the existing Keychain
item and local history locations. The app bundle is `Bello Agent.app`; the
internal Xcode project and module remain `PiApp`; the repository is `BelloWare/BelloAgent`.
The canonical product page is `/bello-agent.html`; both the new
`bello_agent.appcast.xml` and legacy `pi_app.appcast.xml` advertise the same update.

Build toolchain: Xcode 16.1 (16B40), Swift 6.0.2, XcodeGen 2.44.1.
The only dependency is Sparkle 2.8.1 (updates), resolved revision committed with
the project. The terminal panel, the conversation page, Markdown and syntax
colouring are the app's own code (`apps/macos/PiApp/Terminal`,
`apps/macos/PiApp/Transcript`).

```sh
export PI_BUILD_ROOT=/path/to/scratch
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests"
python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 -m unittest discover -s scripts/tests
```

The [test handoff](docs/Swift-Test-Handoff.md) contains the macOS build/UI and
signed Keychain procedures. Follow its current policy: focused checks, reuse
passing results for unchanged code and run independent suites in parallel.
Installation/update rehearsals are skipped unless explicitly requested again;
signing, notarization and public artifact verification remain. Reuse incremental
build caches rather than fresh DerivedData for every run. Build products and logs stay outside the source tree
under `PI_BUILD_ROOT`. Follow [Release.md](docs/Release.md) for signing,
notarization, website publication and public update verification. Historical
Node/Pi milestone records remain in `docs/`; they do not establish the current
native release's acceptance state.
