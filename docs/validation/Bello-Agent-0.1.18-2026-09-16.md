# Bello Agent 0.1.18 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.18/build 22**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 15:46:54 UTC.**
Release source: `29e2da5569165df79572218b490b3b63f8685bc9`. Website: `69c6862688c6baf6d33220593f5f59246a7554e1`.

## Changed behavior and corrected diagnosis

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
[issue resolution](../Issue-Stale-Chat-Model-Catalog.md).

The repair banner appears beside the current model-list source. It offers a
single direct action or an explicit chooser, deduplicating repeated URLs and
excluding earlier records, other gateways/APIs and linked-source followers.
It does not fetch a suggested catalog before selection. Displayed catalog
locations omit URL query values. Selecting the suggested source saves a model-list
binding and refreshes the mounted picker without changing the chat's request
route. That catalog's own configured authority supplies list credentials;
existing same-origin/anonymous-external credential boundaries remain.
The original Catalog source menu remains available for deliberate alternatives.

The fresh-save regression continues to prove that a changed default model plus
catalog URL on the same request authority inherits the new catalog. This release
does not claim that path was newly broken or newly implemented. Its new behavior
is visibility and direct repair of legacy records that lack that stored lineage.

## Focused acceptance

**67 focused native tests passed**, with 0 skips and
zero unresolved failures. Counts come from the actual test log, with repeated
cases counted once. Coverage includes the original save/inherit flow, legacy
repair and restart, distinct/multiple sources, explicit-binding preservation,
refresh source routing and the mounted picker's visible banner/replacement rows.
The mounted-view check invokes the action shared by the button; it does not
claim a physical mouse click. Unchanged helper/context/capture and transcript/
TypeScript evidence is reused from 0.1.17 and its referenced earlier records.
No live deployed gateway or full screenshot gallery was run. Installation/update
rehearsals were skipped by owner instruction.

| Log | Passed executions | Skipped | Failed cases | Failed assertions |
| --- | ---: | ---: | ---: | ---: |
| `native.log` | 67 | 0 | 0 | 0 |

Each case's last observed result is counted once: **67 passes**,
0 skips and zero unresolved failures.
The focused native run completed without failed cases or assertions.

The original-save integration checks that an old chat follows a new catalog URL
and a subsequent edit/refresh while preserving its original route and credentials.
Legacy integration checks persistence/restart, unchanged selected model/effort/
budget, matching picker metadata, and continued refresh against the explicitly
chosen catalog. Other fixtures exclude unrelated sources, preserve explicit
bindings, deduplicate repeated URLs, retain multiple choices and prove that
changing profileChoice cannot hide the suggested repair.

A real mounted SwiftUI picker is rendered before and after invoking the same
action used by its visible repair button. OCR checks the banner and action text,
replacement model rows and disappearance of the old rows/banner. The URL query
value is absent from visible text. No catalog is prefetched until chosen, no
conversation helper starts, and external catalog requests contain no request
connection authentication. This is mounted-view/action coverage, not physical
mouse automation or a newly inspected screenshot gallery.

## Reused evidence and limits

Core helper, request usage/context accounting, HTTP capture and React/TypeScript
transcript code are unchanged. Their passing evidence is reused from the
[0.1.17 record](Bello-Agent-0.1.17-2026-09-16.md) and its explicitly referenced
prior records; these are not counted as new test executions for 0.1.18.
The compatibility/estimation limits in [Context-Accounting.md](../Context-Accounting.md)
remain. No remote token-count endpoint, live deployed LiteLLM, full Release
performance matrix, physical picker click, full screenshot gallery, installation,
Sparkle update/relaunch or signed owner/update rehearsal was performed.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.18.dmg](https://belloware.com/assets/BelloAgent-0.1.18.dmg).
- Size: **7,230,028 bytes (6.90 MiB)**.
- SHA-256: `cd8374400c12f508fa8b0f1b653a90c5660dc4756a147306203609f3cb728629`.
- App notarization: `d4cfa9f2-4048-45f5-ae62-4451e12277a4` (accepted).
- DMG notarization: `81c956ec-40a7-42e4-989d-995c162a65b7` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Product/download, home, legacy
redirect, sitemap and unchanged icon pass. Canonical/legacy feeds are identical;
the downloaded archive matches SHA-256 and Sparkle Ed25519 verification.
Bundle ID, Keychain ownership, saved history, selected icon and updater identity
are preserved.

Cloudflare build `fa6d7d33-e3fe-46d3-8605-8bee3ea5617f` completed successfully at 2026-09-16T15:46:43Z.

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/catalog-repair-018`. Logs: `native.log`, `release.log`, `publish.log`,
`public.log`, `pages.log`, `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.eVXRno`.
The unrelated `docs/Code-Review-2026-09-16.md` remains untouched. The catalog issue
document is now task-relevant and its resolution is included in source.
Publication uses a clean temporary source worktree. This later documentation-only
commit records completed checks; the packaged source SHA above remains exact.
