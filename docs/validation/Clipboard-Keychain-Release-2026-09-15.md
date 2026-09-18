# Clipboard-style Keychain and current-UI release

Date: 2026-09-15. Platform: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2,
XcodeGen 2.44.1. Branch: `master`, continued from the existing native implementation.

## Owner decision and implementation

The owner explicitly selected keeping Keychain and following Clipboard's release
approach, releasing the current UI first. The three generated design concepts
are deferred. The temporary plaintext-settings UI copy was reverted in `80725c9`;
no plaintext configuration backend was introduced.

- `e9d28cd`: profile-free Developer ID signing and release validation.
- `113522c`: ordinary Keychain backend and signed synthetic acceptance.
- The root release script uses the same timestamp retry helper for DMG signing.

Compared the existing release scripts and Keychain implementations in
`BelloClipboardManager`, `BelloTracker` and `BelloBox`. They use the installed
BelloWare Developer ID identity, hardened runtime, secure timestamps,
notarization and Sparkle. Ordinary Keychain storage does not require Pi App's
previous restricted access-group entitlements or an embedded provisioning
profile. No sibling repository or signing-key access policy was changed.

The production configuration remains one versioned generic-password item:
service `com.belloware.PiApp.configuration`, account `vault-v1`. Revision checks,
cooperating-process locking, update-in-place and no plaintext fallback remain.
The application checks its own Developer ID identity. This check is distinct
from raw Security-framework access by another program. Ordinary Keychain does
not establish app-exclusive raw same-user update/delete isolation.

New captured HTTP bodies remain plaintext, with authentication fingerprints;
this storage choice does not apply to configuration/API-key storage. Existing
encrypted history and existing Keychain items are preserved.

## Checks completed

- `python3 -m unittest discover -s scripts/tests`: **32 passed**, 8.690 seconds.
  Signing tests cover inside-out order, timestamp retries without an unsigned
  fallback, stale profiles, restricted entitlements and release signature gates.
- Native Debug `xcodebuild test`, after the Keychain backend change:
  **74 executed, one opt-in interactive harness skipped, zero failures**;
  73 ordinary tests passed in 5.063 seconds.
- Original and changed update probes compile with Swift 6,
  `-warnings-as-errors -O`, using the production Keychain backend.
- Fresh interactive fixture run: **one XCTest passed**, 145.604 seconds;
  **five local HTTP requests and eight retained bodies independently verified**.
  Both Responses and Messages performed read-tool round trips, and the side
  conversation replied. No historical fixture state or real gateway credentials
  were used. All fixture processes exited normally.
- Current UI screenshots were captured from that real native app, with synthetic
  conversations and metrics. They show the existing chat/side pane and request
  dashboard; they are not generated redesigns.

The existing 58 core tests, 19 strict helper cases (24 malformed request probes),
two process/MCP cases, TypeScript and packaged helper acceptance remain recorded
in the preceding continuation evidence. The helper/API implementations did not
change during this Keychain/signing adjustment.

## Signed access and publication state

The first signed synthetic acceptance attempt stopped before creating any item:
its initial `codesign` invocation stalled without returning an error. Only that
owned signing process was terminated. The script now bounds compilation/signing
to 120 seconds and preserves synthetic-item cleanup for actual probe operations.
No signed Keychain acceptance pass is claimed from this attempt.

The native Release build completed successfully. The real release pipeline then
stalled at the first nested Developer ID signature (`Downloader.xpc`). A bounded
process sample found all 743 samples waiting in signing-key ACL/integrity access:
`SecCodeSigner` → `SecKeyCopyAttributes` → `KeyImpl::getAcl` →
`SecurityServer::ClientSession::getAcl`. Certificate lookup had already completed;
this was before secure timestamping. Selecting a different lookup path is not
evidence of a fix for this observed wait.

Computer-use review rejected opening `com.apple.SecurityAgent`, stating that
computer control of that app is not allowed for safety reasons. No alternative
UI path, signing-key export, Keychain unlock or ACL change was attempted. The
owner was asked to check the remote Mac for a signing/Keychain prompt; the sample
does not establish that a visible prompt exists rather than a stalled service.

The prepared app and release work stay in session scratch. No new notarized DMG,
published page/feed/archive or successful current-version update installation is
claimed from this attempt. Existing public 0.0.2 assets remain unchanged. Resume
the signed synthetic Keychain matrix and distribution pipeline once macOS signing
key access is available, then record actual notarization/public/update results.

The old Data Protection/provisioning-profile blocker is superseded, not a current
release requirement. Live deployment-specific LiteLLM checks, real language IME
composition and the previously documented performance limits remain separate
from this requested initial-version release.

Scratch logs and generated test data remain under the session temporary folder
in `clipboard-release`; no signing keys, configuration vaults or fixture logs
are published as release assets.
