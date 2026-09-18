# Bello Agent 0.1.15 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.15/build 19**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 14:27:04 UTC.**
Release source: `65061de7440755b7f328fb4706d45e2ec5c5fc91`. Website: `dd6f206fa24c2210f3f0d380c6e8d4f73ec04bce`.
Fix and regression commit: `67ba645`.

## Changed behavior

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

The previous optional-state binding captured a value snapshot. The folder picker
successfully returned a path, but the subsequent extra-folder cleanup wrote the
old empty primary back. This also left Trust and Create disabled. Onboarding's
separate path bypassed the faulty form. The original two writes were reproduced
in a standalone Swift harness before the fix. The shared live binding and atomic
mutation now cover the actual form state path used by the parent and child views.

## Focused acceptance

**27 focused native tests passed with zero failures in 0.714 seconds**:
Workspace 17, ProjectSidebar 6 and ReleaseConfiguration 4. Three new regressions
cover live folder-selection state, cancellation/reopening and second-project
persistence with a fresh vault readback. These are state/integration checks;
physical NSOpenPanel interaction was not exercised. Unchanged context/catalog,
provider/transcript/capture evidence is reused from 0.1.14 and earlier records.
Installation/update rehearsals were skipped by owner instruction.

| Suite | Passed | Seconds |
| --- | ---: | ---: |
| Workspace | 17 | 0.405 |
| ProjectSidebar | 6 | 0.302 |
| ReleaseConfiguration | 4 | 0.008 |

The three added cases passed on the first run. No production vault/credentials
were read or changed by these fixtures. The second-project test starts with an
existing trusted project, chooses another folder through the production draft
binding, saves it and verifies both projects using a fresh in-memory vault read.
No physical folder-picker gesture, full gallery, deployed gateway, installation,
Sparkle update/relaunch or signed owner/update rehearsal was performed.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.15.dmg](https://belloware.com/assets/BelloAgent-0.1.15.dmg).
- Size: **7,137,895 bytes (6.81 MiB)**.
- SHA-256: `cbe8d87022dd1455ea241fdd6b4b5b59b59b72c865d9c4f00c597ffd2768ef0f`.
- App notarization: `32f38a9b-ea53-42ee-bc96-623f8391e9c2` (accepted).
- DMG notarization: `8cfe68e1-6aa7-442d-be1e-0ab007186aac` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Product/download, home, legacy
redirect, sitemap and unchanged icon pass. Canonical/legacy feeds are identical;
the downloaded archive matches SHA-256 and Sparkle Ed25519 verification.
Bundle ID, Keychain ownership, saved history, selected icon and updater identity
are preserved.

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/project-picker-fix`. Logs: `native.log`, `release.log`, `publish.log`,
`public.log`, `pages.log`, `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.0ZOnMQ`. The unrelated Claude review
`docs/Code-Review-2026-09-16.md` was preserved unmodified and uncommitted.
Publication used a clean temporary source worktree. The later documentation-only
commit records completed checks; the packaged source SHA above remains exact.

Cloudflare build `8d4c8010-b2b1-4a54-bb6e-3f46a40f627f` completed successfully
at 2026-09-16 14:26:34 UTC. The initial public probes still saw the old feed while
deployment was in progress; final feed/archive/page verification passed after
completion at 14:27:04 UTC.
