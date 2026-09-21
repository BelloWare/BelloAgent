# Bello Agent 0.1.72 / build 76

Released and publicly verified on **2026-09-21 06:31:17 UTC**.

## Included changes

- Stable task work rows and per-source prose during tool streaming; no empty
  answer placeholders or premature Turn summaries between tool rounds.
- Fixed-height progress dock and coalesced cosmetic updates, preserving prose
  geometry, reading position and native selection.
- Source-scoped tool details/fetches and explicit interrupted retry output.
- Caret-local inline skill selection with preserved draft text and native undo.
- Safe retained-input edits in compacted chats and saved forks, preserving
  original history and checking missing attachments/legacy skill selections.
- Live refresh in reopened chats and after browsing earlier history, plus
  reported zero and very small costs in turn/session summaries.

See [stable tool presentation and all 49 acceptance dispositions](../Stable-Tool-Streaming-2026-09-21.md)
and [inline skills/historical edits](../Inline-Skills-and-Historical-Edits-2026-09-21.md).

## Validation performed and reused

The source implementation is unchanged from the preceding passing checks;
the release commit changes version/build metadata, release notes and product
page copy. Reused evidence includes **82 distinct helper, 107 distinct Debug
native and 49 distinct optimized native cases** from stable-tool validation.
Actor data-race checks were enabled on the native runs. Two optional physical
pointer tests were skipped and are not counted as passed. The optimized final
compatibility case also exercises compacted-fork editing and inline skill
selection through the packaged helper. The earlier inline-skill/historical-edit
record provides its broader implementation evidence; overlapping tests are not
added into the totals above.

The request-aware loopback fixture validated tool schemas, inputs and replayed
call/result pairs, then matched all three request and three response bodies
byte-for-byte with actual captures. This is not deployed LiteLLM verification.
The 30-sample optimized native draw fixture measured median 0.306 ms and p95
0.430 ms with unchanged prose origin and preserved selection. These are mounted
AppKit draw opportunities, not physical display frame times or an app-wide
latency guarantee. Workload/physical-input limits remain in the acceptance record.

For this release, **12 website staging tests passed**. The production app/helper
were rebuilt using existing compiler caches. Cached test-host app contents were
removed before packaging; the final app contains no XCTest bundles. The signed
packaged helper/catalog smoke passed with six bundled catalog models. Developer
ID signatures, hardened runtime, profile-free entitlements, app and DMG
notarization/stapling, Gatekeeper, monotonic build number, feed metadata and
Sparkle Ed25519 archive verification all passed.

Fresh-install and actual Sparkle update/relaunch rehearsals were skipped under
the standing owner instruction. No new authenticated model call, physical
trackpad/display assessment or full accessibility matrix was run.

## Publication artifacts

- Packaged source: `b5d0b86bba594e34f837904d2af7b971da9f7ef6`.
- Website commit: `0fddf033603b3d83cd6249d81b09ae56e9b52d86`, pushed to its
  configured `origin/main` upstream.
- Cloudflare check **106235729685** succeeded at **2026-09-21 06:30:01 UTC**.
- App notarization: `ba717e9c-37ab-4db1-b783-e0a661b0e508`, accepted.
- DMG notarization: `d20784dd-a25c-4cb0-8dc7-cb4ec695691a`, accepted.
- `BelloAgent-0.1.72.dmg`: **8,823,949 bytes (8.42 MiB)**.
- SHA-256: `8958bde71dd74ac746028af67404276f87ad2b0975ffe0440be5acd885b0ab7f`.
- Final signed installer copied to the session outbox.

The public product page matches the staged 0.1.72 page exactly, including its
download link. Both downloaded update feeds are byte-identical to each other and
the locally validated feeds. The public DMG matches the SHA-256 above and passes
Sparkle Ed25519 verification. Initial checks saw the old feed while Cloudflare
was building; verification was repeated after successful deployment.

Release/build/signing logs are in the session scratch folder
`bello-agent-0.1.72` and `bello-agent-0.1.6/build/release.TeKfZi`. Existing native
results remain under `fresh-transcript`. No secret/key material is in the
published artifacts or outbox. Source commits remain local under the current
release policy; the website commit was pushed to deploy the release.
