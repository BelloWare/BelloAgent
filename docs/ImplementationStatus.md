# Implementation evidence

The requirements in Features.md and Design.md are required v1 work. A checked
item below requires test or release evidence; scaffolding alone does not count.

- [x] Prerequisite: native dummy 0.0.1 signed/notarized and published.
- [x] Prerequisite: 0.0.2 published; real Sparkle upgrade from installed 0.0.1.
- [x] M0: locked Pi/Node; both provider fixture matrices; exact byte capture;
      tool cycles/cancellation/compaction; native/web bridge; packaged host;
      measured memory baseline and release budget.
- [x] M1: session persistence/protocol/composers/streaming/recovery;
      68 host tests, 11 native tests and an actual queued-stream/Stop UI check.
      See [M1Validation.md](M1Validation.md) for scope and remaining v1 work.
- [x] M2: full profiles/context/metrics/native inspector, read-only Pi references,
      images, portable handoff and bounded native retention/export.
      See [M2Validation.md](M2Validation.md) (79 host tests; 15 native cases).
- [x] M3: bounded skill/AGENTS discovery, strict policy, per-turn frozen grants,
      native completion/chips and inspectors; 88 host / 18 native tests and a
      live exact-request check. See [M3Validation.md](M3Validation.md).
- [x] M4: independent read-only side sessions, safe context, atomic Keep and
      editable bring-back; 103 distinct host / 21 native cases and live native
      concurrency/cancellation/undo/Keep checks. See [M4Validation.md](M4Validation.md).
- [ ] M5 final sign-off: native/security/acceptance implementation and measured
      performance pass (115 host, 34 native, 11 script tests). See
      [M5Validation.md](M5Validation.md). The 0.1.0 (build 4) preview is signed,
      notarized and stapled; packaged provider checks pass. VoiceOver spoken
      navigation remains a manual check because
      remote controls did not expose speech/caption output. Full-installer
      publication needs a download destination above the static 25 MiB limit.

## Distribution decision (2026-09-14)

M0: exact Node/Pi pins and 50 host tests pass. Real Responses and
Messages fixtures verify tool dispatch and continuation, text/thinking/argument
streaming, byte-for-byte HTTP capture, manual compaction (both summary calls),
opaque continuation persistence and resumed use of the Pi compaction summary.
Automatic compaction, failed compaction, HTTP 400/401/429/500 (including HTML),
HTTP-200 stream errors, pre-header disconnection, retry correlation, cancellation
before/after content and during tools, independent concurrent sessions, oversized
unknown events and recorder off/cap/failure also pass on both APIs. The storage
failure case is an injected recorder failure; persistent trace disk-full tests
belong to M2's actual opt-in disk store. The signed/notarized packaged runtime,
native/web bridge and measured aggregate memory baseline pass; see
[M0Validation.md](M0Validation.md). The M5 one-workspace/main-plus-side release
budget is 800 MiB sustained / 1 GiB peak aggregate RSS. M5 remains required.

The owner's latest instruction supersedes Design.md's allowance for manual-only
replacement releases. Use Sparkle 2.8.1, pinned to the sibling BelloBox release
workflow, with `https://belloware.com/assets/pi_app.appcast.xml` and bundle ID
`com.belloware.PiApp`. Reuse the existing BelloWare Developer ID and Sparkle
public key. Private keys remain in the existing Keychain/notarization location.
Automatic checks are enabled; installation/relaunch remains a user action and
must wait until hosts are idle. An older signed installer provides explicit
manual rollback; the appcast must never advertise a downgrade.

The initial dummy releases intentionally contain no agent implementation.
They cannot satisfy M0 or any provider acceptance requirement.

## Verified 0.0.1 release

- Source tag `v0.0.1`; website commit `15024dd`.
- 4 native tests and 7 release tests pass (including same-length signature tampering).
- Apple accepted app notarization `98cf0c56-cb54-4ede-97d5-5ab627aea013`
  and DMG notarization `61754948-6981-467e-b795-cd15806ffa33`.
- Stapler, Gatekeeper, strict nested code-signature verification pass.
- Public installer: 1,069,047 bytes; SHA-256
  `532321ebe29bf350ac426166db0140ed505cce511813c872ae5e396202f0912a`.
  Public download matches the staged file and verifies with the embedded public key.
- Native Sparkle UI in the installed 0.0.1 reports “You're up to date” against
  the production feed. The first Cloudflare deployment took several minutes.
- Publication verification uses macOS curl; Python urllib received HTTP 403
  in this environment while curl and the actual Sparkle client succeeded.

## Verified 0.0.2 upgrade

- Source version commit `60b18a1`; website commit `e5db74b`; tag `v0.0.2`.
- Apple accepted app `7989359e-ea8b-457e-a88a-a7edec915f9c` and DMG
  `56a36c8b-6948-4432-88b0-b82713eb13e3`; all signing/stapling checks pass.
- Public installer: 1,069,311 bytes; SHA-256
  `8cc642097d4f341fe41ad01860b61f03ddc7b0f7b0259c483191e8e5f3e565e6`.
  Byte-identical public feed/archive and Ed25519 verified independently.
- Installed 0.0.1 used the production feed and displayed “0.0.2 is now available”.
  Sparkle downloaded the archive and its installer logged a valid EdDSA signature.
  The standard “Install and Relaunch” action replaced/relaunched the app at the
  same writable `update-proof/PiApp.app` path, with CFBundleVersion `2` and
  native UI “Version 0.0.2 (2)”. Process changed from 58264 to 60085.
- Strict nested signature verification and Gatekeeper acceptance also pass on
  the upgraded installed app. The update window was behind the main window;
  Window → Updating Pi App exposed its Ready to Install action.
- These dummy checks ran on macOS 14.8. The subsequent M0 Node/WebKit memory and
  packaged runtime evidence is recorded separately in M0Validation.md.
