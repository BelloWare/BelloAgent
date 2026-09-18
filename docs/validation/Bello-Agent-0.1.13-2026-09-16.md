# Bello Agent 0.1.13 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.13/build 17**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 12:57:46 UTC.**
Release source: `a06287bcf21873a0757dfdeb3e55b5aa9a366b1f`. Website: `cd28c3c4c630da9eec014acf5db8bb1dd1ffea17`.
Feature commits: `931705d` (catalog refresh), `66effc7` (session timings).
Publication template commit `84a65ff` follows packaging and does not change the
application source identified above.

## Changed behavior

- Explicit catalog Refresh reloads the saved configuration and resolves the
  same connection ID before fetching. Chat and Settings share this path.
  Loading spans configuration and network work; failures remain inline and
  preserve the previous list where appropriate. The refresh hit target is larger.
  An open picker observes revised saved metadata. It never substitutes a newer
  connection fork, changes a chat's model/effort, or discovers gateway models.
  Passive bundled/external catalog opening preserves its credential rules.
- Chat TTFT and output TPS come from the same latest completed retained request.
  They survive helper eviction, chat changes and application reopening, and
  background completion refreshes loaded sessions. Running requests leave the
  preceding completed values in place until completion; missing metrics remain
  unavailable and observed zeroes remain zeroes.
- Hover over either footer metric to preview both native timing charts; click
  keeps the popup open. Charts inspect up to 128 recent completed requests,
  scoped to that session/project, with gaps for missing observations. Hovering
  a point shows its timestamp and metrics. Reads use the existing metrics index,
  do not load request bodies and do not pull parent/fork history into the child.
  Dedicated usage-window/menu-bar historical averages remain separate. Output
  TPS includes dispatch-to-completion time, matching the existing rate definition.

## Focused acceptance

**108 native tests passed, zero failures, in 13.773 seconds.**

| Suite | Cases | Seconds |
| --- | ---: | ---: |
| GatewayAccounting | 19 | 0.731 |
| LiveAccounting | 5 | 0.648 |
| MenuBarMetrics | 21 | 0.905 |
| ModelCatalogEndpoint | 19 | 7.904 |
| ModelSwitch | 15 | 0.422 |
| ReleaseConfiguration | 4 | 0.011 |
| SessionTiming | 9 | 1.104 |
| SessionUsage | 10 | 1.866 |
| SettingsSave | 6 | 0.183 |

Coverage includes forced uncached requests, current saved catalog URLs and
credential revisions, connection-fork authority, anonymous external catalogs,
configuration/HTTP failure preservation, loading through the pre-network phase,
latest timing persistence/scoping, missing/zero handling, bounded indexed history,
late-read rejection, background completion and hover/pinning state transitions.
Synthetic before/after model-list and timing-chart JPEGs were inspected.

The initial new timing test helper failed Swift 6 isolation checks and was
corrected to a static async helper. An experimental native mouse-click harness
could not activate the XCTest-hosted window, so it did not establish a product
click failure. The retained regression instead mounts the shared chat picker,
executes its refresh action and checks actual before/after rendered pixels.
No physical pointer click or end-to-end hover gesture is claimed by that test.

## Reused evidence and limits

Provider/helper, transcript, captured-response parsing and release scripts are
unchanged. Reuse the [0.1.12 record](Bello-Agent-0.1.12-2026-09-16.md) and its
linked request-aware gateway/fixture acceptance for those paths. No production
vault data or live gateway credentials were used in the new tests. No full
gallery/performance matrix, deployed LiteLLM, fresh installation, Sparkle
update/relaunch or signed owner/update rehearsal was run. Full-text body search
remains deferred.

## Retained local evidence

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/picker-timing-fix`.
`native.log` records the final selected run; earlier exploratory test/build logs
remain in that scratch directory. `previews/` holds only synthetic own-window
views. Stable build root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.13.dmg](https://belloware.com/assets/BelloAgent-0.1.13.dmg).
- Size: **7,118,570 bytes (6.79 MiB)**.
- SHA-256: `4906755a2befbb89ff58cc85b032ac66517f33ff7d1faf6e3d1db015ec114228`.
- App notarization: `19de0941-8df1-4957-8830-67c101dd41d7` (accepted).
- DMG notarization: `b50e8272-a367-4058-b77f-2523fe296d17` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Public product/download, homepage,
legacy redirect, sitemap and unchanged icon pass. Canonical and legacy feeds
are byte-identical and advertise build 17; the downloaded archive matches its
SHA-256 and Sparkle Ed25519 signature. Verified at 2026-09-16 12:57:46 UTC.
The selected icon is unchanged, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
Release/publication/public checks are in `release.log`, `publish.log`,
`public.log` and `public-verification/` under the scratch folder above.
Detailed release logs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.QpgGNs`. No installation or update rehearsal
was performed. Public release facts refer to the packaged source commit; the
later documentation-only commit records those completed checks.

Cloudflare build `04f78c7f-eb1d-454b-af61-a3b606c71c6c` completed successfully
at 12:56:59 UTC for website commit `cd28c3c`; public checks followed at 12:57:46.
A concurrent completed Claude review produced the unrelated untracked
`docs/Code-Review-2026-09-16.md`. It was preserved without edits or inclusion in
this release. Publication used a clean checkout of `84a65ff`; the temporary
checkout was removed afterwards. No application source changed after packaging.
