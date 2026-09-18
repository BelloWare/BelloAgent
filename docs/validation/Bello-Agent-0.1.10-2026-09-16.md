# Bello Agent 0.1.10 acceptance

Date: 2026-09-16. Branch: `master`. Release source:
`d1908dc978e6652f62eb04d2aec1dc6858d4dca2`. Version **0.1.10/build 14**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 10:03:51 UTC.**

## Corrected default model source

Version 0.1.9 honored a model catalog only when a custom URL was saved; the
repository's catalog file was not packaged in the app. Version 0.1.10 fixes that
missed default path: nil, empty and whitespace catalog settings now load the
bundled six-model Bello catalog without requesting gateway models or reading an
API key. Existing selected aliases, reasoning efforts and per-connection defaults
are preserved. Explicit custom catalogs remain authoritative, with no fallback
to either the bundle or gateway after a custom-source failure.

The signed application now includes the exact reviewed
[`catalogs/bello-agent.models.json`](../../catalogs/bello-agent.models.json).
Its SHA-256 is `f925021201808c8d305e1490c96d555a52ab140743880ddc1a35b3dde2097419`.
Composer, Settings and onboarding show its rich model descriptors, context and
output limits, ordering and reasoning choices. The six aliases are:
`deepseek-v4.1-flash`, `glm-5.3-flash`, `glm-5.3`, `kimi-k3`,
`gemini-3.8-flash` and `auto-router`. The default picker identifies the source as
“Bello model catalog” / “Included with Bello Agent”. Listing is not proof that a
particular deployment serves those aliases; the selected-model onboarding probe
remains the connection check.

Explicit custom sources retain same-origin credential rules, anonymous external
fetches, hourly caching and cancellation/source-change guards. Saved choices are
not rewritten. Title generation resolves explicit mini choices against the same
catalog; the bundled file has no `mini:true` recommendation, so an upgrade alone
does not enable auxiliary model calls. Provider/helper, transcript, assets,
bundle ID, history paths, ordinary Keychain and Sparkle key are unchanged.

Feature commit: `3c98a18303c1e85d07618a3bee0a192fa5d818c5`.
Release preparation: `d1908dc978e6652f62eb04d2aec1dc6858d4dca2`.

## Focused acceptance

**60 focused native tests passed, zero failures, in 6.899 seconds.**

| Native suite | Passed | Seconds |
| --- | ---: | ---: |
| ModelCatalogEndpoint | 18 | 5.365 |
| ModelSwitch | 11 | 0.243 |
| Onboarding | 18 | 0.684 |
| SettingsSave | 6 | 0.169 |
| TitleGeneration | 7 | 0.439 |

Checks read the actual application-bundle catalog and assert all six aliases,
context/output limits and reasoning choices. Legacy/blank defaults require no
gateway traffic or credential lookup; explicit catalogs retain source isolation,
credential-origin checks, caching and cancellation guards. Remembered choices,
Settings saves, onboarding probes and title-session isolation remain covered.

Three synthetic own-window picker JPEGs were visually inspected, with OCR
assertions for the default, custom-catalog and error views. No unrelated
application content is captured.
The unchanged helper, transcript, capture/accounting, chrome, broader native and
Keychain evidence is reused explicitly from the [0.1.9 record](Bello-Agent-0.1.9-2026-09-16.md)
and its linked historical records. Those are not additional tests run for 0.1.10.
No full gallery, deployed LiteLLM, fresh-install, Sparkle update/relaunch or signed
owner/update rehearsal was run. Log: `catalog-default-fix/native.log` in session scratch.

The default-list tests load `Bundle.main` resources rather than a source-tree
fixture, verify the exact six aliases/caps/efforts, and decode a pre-catalog
saved profile. Loopback spies record no gateway requests for nil/blank defaults;
the visible picker additionally records zero vault reads. Custom-catalog tests
retain redirect/body/timeout/credential bounds, latest-source isolation, stale
result rejection and rendered failure states. Their failure path never merges
or substitutes the bundled or gateway list.

TitleGeneration includes a request-aware loopback fixture through the unchanged
packaged helper, checking the selected mini model, bounded output, no tools or
project resources, one request, durable task history and separate accounting.
Onboarding state tests inject probe success/failure/cancellation and require a
successful probe before chat creation. Earlier packaged onboarding HTTP/UI
acceptance is reused from the linked historical records.
There were no compile errors or failed assertions in this focused run.

## Reused evidence and limits

The [0.1.9 record](Bello-Agent-0.1.9-2026-09-16.md) retains its 155 unique native
tests, 17 helper tests, 24 transcript tests and TypeScript check, capture/body and
accounting fixtures, window geometry and historical failures/corrections. Only
the five suites listed above were rerun for 0.1.10; other unchanged results are
reused. Broader provider/wire/process, Python, gallery and ordinary Keychain
evidence remains in the linked historical records. No production credentials
or deployed LiteLLM endpoint were used by these local fixtures.

Physical status-item clicks, chart dragging, foreground unread clearing through
CUA, real-language IME and the full Release performance budget are not newly
verified. HTTP-body full-text search remains deferred. Install/update/relaunch
and signed owner/update rehearsals were skipped at the owner's request; the
actual-update evidence in [0.1.6](Bello-Agent-0.1.6-2026-09-16.md) is historical.

## Signing and public distribution

- Source: `d1908dc978e6652f62eb04d2aec1dc6858d4dca2`.
- Website: `b93433bb28172179ce9e7d3b1c52295ba3029b94`.
- Product: [belloware.com/bello-agent.html](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.10.dmg](https://belloware.com/assets/BelloAgent-0.1.10.dmg).
- Size: **6,901,746 bytes (6.58 MiB)**.
- SHA-256: `92ca6ffb4d09e84a6f78f8ec592bd0d21e27504b1f15af522e1a0af015b9fa49`.
- App notarization: `f965c195-5b10-452a-92ae-cb4e302dbf7e` (accepted).
- DMG notarization: `bed9d807-8da3-4bd3-9eaf-41d5bfa35895` (accepted).

App/DMG Developer ID signing, notarization and stapling pass. The packaged-helper
smoke additionally checks that the packaged resource bytes match the reviewed
catalog. Public product/download, homepage, legacy redirect, sitemap and icon
checks pass. Canonical `bello_agent.appcast.xml` and legacy `pi_app.appcast.xml`
are byte-identical and advertise build 14; the downloaded archive matches its
SHA-256 and Sparkle Ed25519 signature. Public verification completed at
2026-09-16 10:03:51 UTC. The initial six checks still saw the previous feed
while deployment was pending; the next check passed. Cloudflare Workers build
`b51fe9bf-bde1-4c4a-8820-714a96383a78` completed successfully at 10:03:18 UTC
for the website commit above. Public logs are retained in `public.log` and
`public-retry.log` in the session scratch directory.

The selected flat icon remains unchanged, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
No installed app was replaced as an acceptance rehearsal.

## Commands and retained local evidence

Per-run scratch:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/catalog-default-fix`.
`native.log` records all 60 passing native cases. `previews/` contains
`catalog-picker-bundled-default.jpg`, `catalog-picker.jpg` and
`catalog-picker-source-error.jpg`; these contain only isolated synthetic windows.
Native tests use isolated fixture state in one serialized Xcode invocation.

Stable incremental build root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.
The older directory name identifies a reused cache, not the release version.
Release artifacts are under `releases/0.1.10` within that build root.
Detailed release logs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.ZJG2VC`.

Release/publication uses `scripts/release.sh`, `scripts/publish-release.sh` and
`scripts/verify-published.py`; `scripts/smoke-native-bundle.py` now verifies the
packaged catalog byte-for-byte. Source/documentation checks include
`git diff --check`. Raw logs and private application state are not published.
