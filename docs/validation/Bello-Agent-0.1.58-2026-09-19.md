# Bello Agent 0.1.58/build 62 acceptance — 2026-09-19

**Public release verified at 2026-09-19 02:56:13 UTC.**
Release source: `998411e757bddfe419d4afdd3e578f299689ad60` (local `main` commit under the owner's source-push
policy). Website: `fa044232670ca60292baf2de3744526aed86f3ff`. Later
documentation commits do not change the packaged source.

## Changes

Version 0.1.58 answers two owner requests. The sidebar now selects several
chats at once: Shift-click extends a range in the order the list shows,
Command-click adds or removes one row, and an ordinary click drops the marks
and opens the chat. A bar above the list says how many are marked and archives
or restores them in one press; a right-click on a marked row archives,
restores, pins, unpins, moves to a topic or marks read for the whole set, each
through the same durable per-chat path as its single-chat menu item. Dragging a
marked row carries every marked chat of that project in one bounded payload,
previewed as "N chats", and drops into a topic or a project root exactly as one
chat already did. Chats are still deleted one at a time.

Git history browsing was rebuilt around what a click actually needs. Choosing a
commit ran three git processes in a row, the last one producing the whole patch,
and the app then parsed that patch on the main thread inside a view body, so it
was re-parsed on every redraw and nothing appeared until all of it finished. Now
two cheap reads return the message, the changed paths and their line counts
without any patch text, so the file list and a "12 files · +340 −58" summary
appear first; the patch is read and parsed in one background task and never
crosses the main thread as text. Each commit's metadata, patch and per-file
patches are kept for the last 24 commits, so returning to one starts no process
at all, and choosing another commit terminates the reads of the one before it.
A commit of more than 30 files or 3,000 changed lines keeps its patch behind
"Show the whole diff" and opens one file at a time. Any file has its own
history through "Show History of This File", which follows renames, with a chip
naming the filtered path until it is cleared.

## Validation

**626 native tests pass with 9 skipped**, including the two heavy capture
integration checks, and the screenshot gallery and terminal capture classes
pass with 42 light/dark captures. The Swift helper package is unchanged
in this version and its 195 tests pass again; the Python fixture tests
(52) pass. Local HTTP/SSE fixtures and throwaway git repositories back every
check; no deployed gateway and no personal repository were used.

New coverage: `SidebarMultiSelectionTests` drives Shift ranges, Command
toggles, the anchor that keeps a second Shift-click measuring from the same
row, marks that drop when a chat disappears, one bulk archive and restore with
a durable write per chat, the ids one drag carries, and a cross-project
selection that refuses to move. `TopicSessionDragTests` covers the multi-chat
payload, its bound and its rejections. `GitCommitBrowsingTests` drives a real
repository: a commit's files and counts before any patch, a cached commit that
returns with no git process and no loading state, racing through commits
settling on the last one, a forty-file commit that defers its patch and opens
one file at a time, and one path's history across a rename. `GitToolTests` now
reads through the parsed, cancellable diff API, which is the only diff path the
app has.

Measured against this repository's own checkout (12 commits, 89 changed files,
7,587 diff lines, Release configuration, Apple silicon, macOS 14.8):

| One click on a commit | 0.1.57 | 0.1.58 |
| --- | ---: | ---: |
| Until the commit's files and message appear | 47–65 ms (three reads, whole patch, parsed by the waiting caller) | 25 ms (two reads, no patch text) |
| Whole patch, read and parsed | included above, on the main thread | 22 ms, in a background task |
| Returning to a commit already read | the same 47–65 ms again | no read, no parse |

The previous shape also re-parsed the patch inside the view body on every
redraw of the detail pane; that parse is gone. The figures are one machine's
medians for a medium repository, not a guarantee for very large ones.

A pre-existing local failure was diagnosed and dismissed: the two capture
integration tests failed against a stale packaged helper left in this
scratchpad by an earlier session. Rebuilding the bundle made both pass without
any source change; nothing in the shipped app was involved.

Fresh-install and actual Sparkle update/relaunch rehearsals remain skipped by
owner instruction. Physical pointer, trackpad and VoiceOver behavior stays
unverified: drag-and-drop and modifier clicks are covered by model-level tests
and the AppKit modifier flags read at click time, not by a synthetic pointer.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.58.dmg](https://belloware.com/assets/BelloAgent-0.1.58.dmg).
- Size: **7,593,537 bytes (7.24 MiB)**.
- SHA-256: `be36e9bbfe783c3463038fca6337ad19fc9808aa17334c28bd567fc7fafb979d`.
- App notarization: `3310a45c-13b2-4f49-a68b-eb38b6a49472` (accepted).
- DMG notarization: `0420daef-3cde-4f16-8f6a-ce79f28c7f0f` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `998411e757bddfe419d4afdd3e578f299689ad60` remains local under the owner's source-push
policy. Website publication commit `fa044232670ca60292baf2de3744526aed86f3ff` was pushed and the live site served
it. Public verification at **2026-09-19 02:56:13 UTC** confirms identical
canonical/legacy feed bytes, the downloaded DMG SHA-256 and its Sparkle
signature, and the product page's 0.1.58 download link. Fresh-install and
Sparkle update/relaunch rehearsals remain skipped under the standing owner
policy.

Signing and notarization work: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/release.RdDubX`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/releases/0.1.58`.

## Evidence

Scratch: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.

- Native suite: `verify-0.1.58.log`; gallery and terminal captures:
  `gallery-0.1.58.log` with captures under `scratchpad/gallery58/screenshots`.
- Helper package: `helper-0.1.58.log`. Python fixtures: `python-0.1.58.log`.
- Git browsing measurement: `git-bench-1.log` and `git-bench-2.log`, from
  `GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested` with
  `PI_APP_GIT_BENCH_REPO` pointing at this checkout.
- Stale-helper diagnosis: `baseline-capture.log` (failing, unmodified source),
  `bundle-0.1.58.log` (helper rebuilt), `capture-0.1.58.log` (passing).
- Signing and publication: `release-0.1.58-sign.log`, `publish-0.1.58.log`,
  `public-0.1.58.log`.

Historical [0.1.57 evidence](Bello-Agent-0.1.57-2026-09-19.md) remains unchanged.
