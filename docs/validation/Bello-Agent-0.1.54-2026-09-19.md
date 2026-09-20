# Bello Agent 0.1.54/build 58 — 2026-09-19

**Public release verified at 2026-09-18 22:03:23 UTC.**
Release source: `49ed3c95e7fe53605bfb31b7ad8c0c8595ed0f4d` (local `main` commit under the owner's
source-push policy). Website: `8170e23d0ef7b0f9284c37679aa4895108b679d0`. Later documentation commits
do not change the packaged source.

This release adds Copy Session ID and Copy Session Reference to session
right-click and conversation “…” menus. References point directly to the local
retained JSONL journal, with shell-safe paths and clear unsaved/imported states.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.54.dmg](https://belloware.com/assets/BelloAgent-0.1.54.dmg).
- Size: **7,335,665 bytes (7.00 MiB)**.
- SHA-256: `f97d207d8f18ed7c0d2a12f7898d04b70463598c3067cce3590b2076e35b0a83`.
- App notarization: `6f9ba9bd-f1bd-4b20-9617-023365fb58d0` (accepted).
- DMG notarization: `31b7dc05-20e1-4190-b5a3-0bda50dc936c` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `49ed3c95e7fe53605bfb31b7ad8c0c8595ed0f4d` remains local under the
owner's source-push policy. Website publication commit `8170e23d0ef7b0f9284c37679aa4895108b679d0`
was pushed; Cloudflare check **105776630049** succeeded.
Public verification at **2026-09-18 22:03:23 UTC** confirms identical canonical/legacy
feed bytes, the downloaded DMG SHA-256 and Sparkle signature, and the product
page's 0.1.54 download link. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the standing owner policy.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.jVxymf`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.54`.

## Evidence

**27 native tests passed, zero failures or skips**, in 1.551 seconds after the
Release build. `native-acceptance.log` and its xcresult bundle retain the results.

- SessionReference: 5 pass. Named pasteboards verify the exact target ID and
  current path without selecting, loading or opening a helper. The generated
  Bash command reads all 125 retained messages, tool/branch/compaction records
  byte-for-byte from a filename containing spaces, an apostrophe, dollar sign,
  backticks and a newline. File contents and modification time stay unchanged.
  Saved side/fork/import paths, pending chats and clipboard preservation after
  a session disappears are covered.
- SessionOrganization: 8 pass; ProjectSidebar: 6 pass; Side: 4 pass;
  ReleaseConfiguration: 4 pass. The side/fork integration uses the packaged
  helper and preserves history/drafts across closing and restart.
- Site staging: 12 Python tests pass in 4.736 seconds. Publication inspection
  caught stale React and live-throughput copy in the source page template;
  correcting that template prevents future releases from overwriting the
  previously corrected website wording. The page also documents session
  reference copying. This template-only follow-up does not change the signed app.

The helper, journal format, gateway, concurrency and rendering implementations
are unchanged. Their passing evidence from 0.1.53 and 0.1.52 is reused; no new
performance or provider claim is made.

Physical menu clicks and VoiceOver are not claimed as verified on this locked
remote desktop. Installation/update rehearsals remain skipped under the standing
owner policy. Signing, notarization and public download/feed verification remain
required before publication is recorded as verified.

Scratch evidence:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/session-reference-054-20260919`.
