# Bello Agent 0.1.2 acceptance and release

Work continues on `master`, preserving the completed native Swift helper and
Claude's native UI redesign. The product is Bello Agent; the existing bundle ID,
Keychain item, history paths and Sparkle signing key remain unchanged.

## Claude handoff

Before editing, verified the remote Claude session had reached an assistant
`end_turn` at 2026-09-15T16:30:54Z. Every tool invocation had a result, all eight
background commands had exited, and the Claude process had no child tasks.
The screen session remains available and idle with Remote Control. No new work
was submitted to it. Its finished UI changes were committed as `8f1d760` after
73 passing native tests (two opt-in tests skipped) and TypeScript validation.

## Ordinary Keychain and signing

The existing Developer ID identity now signs successfully, using Clipboard's
profile-free approach. No signing-key ACL, exported credential, provisioning
profile or persistent Keychain policy was changed.

`scripts/test-keychain-identity.py` completed **51 checks and observations** with
no failures against a random synthetic service. The original signed owner and a
changed signed update binary could read and update it. Missing/stale revision
conflicts and concurrent-writer rejection passed. Production identity guards
rejected other, helper and ad-hoc identities; noninteractive raw reads also failed.
The synthetic item was removed and its absence verified.

The ordinary login Keychain does **not** promise raw same-user write isolation:
the foreign raw updates succeeded, and the ad-hoc update also changed subsequent
owner read access. Raw deletions in this particular noninteractive run failed
with OSStatus -25244. These are recorded policy observations, not an app-isolation
claim. The test resets only its synthetic item between destructive probe cases.

The standalone legacy raw probe disables optional UI **in its own process**;
that grants no access and changes no item ACL or system setting. Production
continues to use the existing native backend and its LAContext policy.

Evidence in the session scratch folder:
`bello-agent/keychain-acceptance-final.log` and
`bello-agent/keychain-3063ecc7-4640-4bc4-b7c6-84d71eca35f4/report.json`.

## New identity and menu

The final generated icon and exact prompt are preserved in
[`assets/branding/README.md`](../../assets/branding/README.md). Ten macOS icon
sizes were regenerated and verified for dimensions and transparent corners.
The final original raster was also copied into the session outbox.

The native menu panel queries durable request metadata across workspaces for
the last 24 hours, seven days or retained history. It shows normalized input and
output tokens, total-token coverage, gateway-reported USD cost, response-cache
coverage and requested-alias/resolved-model distribution. Each dispatched HTTP
attempt counts once, including tool rounds and compaction. Unknown, incomplete,
invalid and conflicting evidence remains explicit; prompt-cache tokens remain
separate from response-cache hits. Closing the menu cancels its polling.

First-launch fixes keep setup visible until a chat is saved, preserve profile
identity across retries, require explicit workspace trust and reject duplicate
in-flight completion. Model discovery handles endpoint prefixes, uses bounded
responses and refuses redirects while preserving manual alias entry.

## Release state

Combined native checks pass: **106 executed, two opt-in tests skipped, 104
passed, zero failures in 11.298 seconds**. This includes 11 menu-metrics tests,
nine model-discovery tests, 11 onboarding tests and the unchanged 100,000-attempt
accounting-scale regression. Swift 6 compilation and TypeScript checks pass.
The final **44 release/fixture Python tests pass in 14.116 seconds**, including
the configurable auto-router evidence (three new cases). A legacy
empty-token projection mismatch found by the full suite was corrected without
weakening the existing scale test.

The final interactive native XCTest passed in **283.042 seconds**. CUA exercised
both APIs and read-tool round trips, a zero-cost response-cache hit, streaming,
live activity/partial coverage, all three usage scopes, refresh, report opening,
closing the main window and reopening it from the panel. The independent gateway
records verified **all 12 retained bodies for six current-run requests**, with no
historical evidence gaps. Final metadata totals were **500 tokens / $0.00625**.
The panel was opened three times; requested `auto-router` stayed distinct from
`fixture-responses-model` and `fixture-messages-model`. The earlier screenshots
show the five-request checkpoint (257 tokens / $0.005), before the slow stream.

CUA's app surface does not expose status-bar buttons. Fixture-only toolbar
controls therefore invoke the real `NSStatusBarButton` action, and CUA operates
the resulting production panel against the isolated archive. This is explicit
AppKit/CUA integration evidence, not a claim of a physical click on the production
status item. The first harness run could not reach that button, failed only its
four operator-menu assertions, and independently verified its eight bodies.
That limitation prompted the test-only controls; production has no fixture
entry points. AppKit window raising was needed before CUA could type after a
popover closed. Reopened composition and another completed stream were verified.

Current evidence: `bello-agent/interactive-menu-ui.log`,
`bello-agent/ui-menu-acceptance/verification.json`, and compressed synthetic
conversation/menu/report screenshots in the session outbox. SwiftUI emitted
AttributeGraph cycle diagnostics during the opt-in harness; the process remained
responsive and all assertions passed. This is retained as an observed diagnostic,
not silently described as a warning-free UI runtime.
The intended release is **0.1.2/build 6**, with `Bello Agent.app`,
`BelloAgent-0.1.2.dmg`, `/bello-agent.html` and identical canonical/legacy feeds.
The corrected Release app and installer have now been signed, notarized and
stapled. Native-helper packaged smoke, secure timestamp/hardened-runtime and
Developer ID checks, Gatekeeper, Sparkle Ed25519, feed metadata and installer
staple validation pass. The final DMG is **5,545,309 bytes (5.29 MiB)**, below the
20 MiB target, with SHA-256
`f7f054064dceab3af032e60b6b4b1228f8125b44f27c4da0302c82b6387c3375`.
Release log: `bello-agent/release-0.1.2.log`; signing/notary details:
`release-final/build/release.MCPItI`. The earlier interrupted staging candidate
was never published and is preserved separately in scratch.
Both Apple submissions were accepted: app
`049ab056-0d04-4978-8aa5-659f297b903a` and DMG
`cf2b7365-7c44-4276-95cd-b5100b900185`.

## Public deployment and real update

Website commit **`2dc8baf`** was pushed through the existing commit/push Cloudflare
workflow. During deployment the site briefly continued serving build 2 and new
URLs returned 404. No hosting settings, cache policy or credentials were changed.
Automatic deployment subsequently completed. The final verifier downloaded the
public **5,545,309-byte DMG**, matched its SHA-256 above, and verified its Sparkle
Ed25519 signature. Canonical `bello_agent.appcast.xml` and legacy
`pi_app.appcast.xml` are byte-identical and advertise build 6.

The public product page, old-page redirect, homepage, sitemap and icon each match
their committed website bytes:

- [Product page](https://belloware.com/bello-agent.html)
- [Notarized DMG](https://belloware.com/assets/BelloAgent-0.1.2.dmg)
- [Canonical feed](https://belloware.com/assets/bello_agent.appcast.xml)
- [Legacy feed](https://belloware.com/assets/pi_app.appcast.xml)

CUA opened the signed **Pi App 0.0.2/build 2** outside its DMG, checked for updates,
observed the Bello Agent 0.1.2 release notes, downloaded the release, then selected
**Install and Relaunch**. The application relaunched as **Bello Agent 0.1.2/build
6**. Its About panel shows the new name, version and generated icon. The updater
retained the existing `PiApp.app` filesystem path, as expected from Sparkle's
bundle-ID matching behavior; new DMG installs use `Bello Agent.app`.

All 75 installed regular-file digests and symlink targets match the staged
release app, including the executable, helper, transcript and asset catalog.
Deep strict code-signature verification, secure timestamp, Developer ID team
43TXHV3TM3, stapled notarization ticket and Gatekeeper acceptance pass at the
actual installation path. Existing local chat index/history remains visible.
The signed app opens Settings and Reload Vault succeeds with revision 0 (empty
configuration). No gateway was configured or called, and no production credential
was added or changed. Existing-key update continuity is separately established
by the synthetic signed Keychain probe above.

Evidence: `bello-agent/publish-0.1.2.log`,
`bello-agent/public-verification-final.log`, `bello-agent/public-site-verification/`
and `bello-agent/sparkle-installed-verification.log`. The final DMG was also copied
to the session outbox, with its SHA-256 rechecked. No unsigned or interrupted
candidate was uploaded.

The local website desktop, 375px and 305px previews passed visual inspection,
including the homepage card, redirect, download button, metrics copy and footer.
The narrow previews had no horizontal overflow. Preview screenshots contain
explicit preview content and stay in scratch.

## Existing acceptance boundaries

No deployed LiteLLM endpoint/version/model aliases or secure key location has
been supplied. Acceptance uses request-aware loopback fixtures without paid
model calls. Real language IME composition and the complete Release performance
budget remain unverified; historical Debug timing misses remain documented in
the earlier validation records. HTTP-body full-text search remains deferred.
