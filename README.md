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
shows running work with a separate live output estimate. Session headers and
cost totals open resizable usage windows with tokens, cache and model/cost breakdowns. Unread history remains in the sidebar.

**Bello Agent 0.1.37/build 41 is publicly released** at
[belloware.com](https://belloware.com/bello-agent.html). The DMG measures
**7,336,336 bytes (7.00 MiB)**, SHA-256
`19801f32ec462a9cba321629802db2ee4eecb2a07907377fbbe8ed3428577a06`.
Signing, notarization, packaged-catalog and helper smoke, identical
canonical/legacy update feeds and downloaded-archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 01:57:55 UTC**.
Read the [0.1.37 release record](docs/validation/Bello-Agent-0.1.37-2026-09-18.md).
Installation and update rehearsals are skipped by owner instruction.

[Download 0.1.37](https://belloware.com/assets/BelloAgent-0.1.37.dmg).

Signing and notarization need credentials this repository does not carry: a
Developer ID identity, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`
and the Sparkle update key in the login keychain. Building, running and the
whole test suite need none of them.

Version 0.1.19 completes a deeper review of Claude's recent changes and the
Settings-to-existing-chat catalog flow. It fixes clock-correction write loss,
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
