# Bello Agent 0.1.56/build 60 acceptance — 2026-09-19

**Public release verified at 2026-09-18 23:34:17 UTC.**
Release source: `bb114ef07a69ef6e1cb33c60e733564e930a8a27` (local `main` commit under the owner's
source-push policy). Website: `3fe37bb891f544f6ed464a1f82d9e60d4c7a1b08`. Later documentation commits
do not change the packaged source.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.56.dmg](https://belloware.com/assets/BelloAgent-0.1.56.dmg).
- Size: **7,478,445 bytes (7.13 MiB)**.
- SHA-256: `e19097bbaaf6c2eaa3fcc69ba9db2d1427ffaf299f03761546266c2d57fd822b`.
- App notarization: `64fab777-3bd2-4f74-88d5-d43526a2c0eb` (accepted).
- DMG notarization: `2d416491-f581-4154-8edb-dc81056eea5b` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `bb114ef07a69ef6e1cb33c60e733564e930a8a27` remains local under the
owner's source-push policy. Website publication commit `3fe37bb891f544f6ed464a1f82d9e60d4c7a1b08`
was pushed; Cloudflare check **105796177570** succeeded.
Public verification at **2026-09-18 23:34:17 UTC** confirms identical canonical/legacy
feed bytes, the downloaded DMG SHA-256 and Sparkle signature, and the product
page's 0.1.56 download link. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the standing owner policy.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.W23AVq`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.56`.

## Evidence

Native Release tests on macOS 14.8 arm64, Xcode 16.1/Swift 6.0.2:

| Suite | Passed |
| --- | ---: |
| TopicStorageTests | 16 |
| TopicOrganizationTests | 14 |
| TopicSessionDragTests | 3 |
| TopicSidebarPresentationTests | 3 |
| MetadataDurabilityTests | 6 |
| ProjectSidebarTests | 6 |
| SessionOrganizationTests | 8 |
| SideTests | 4 |
| WorkspaceTests | 17 |
| WorkspaceDurabilityTests | 6 |
| WorkspaceMotionTests | 3 |
| ReleaseConfigurationTests | 4 |
| **Total** | **90** |

`topics-native-final.log` and its `.xcresult` report **90 passed, zero failed,
zero skipped**. The tests ran for 4.047 seconds after the incremental Release
build. The first attempt (`topics-native.log`) stopped during test compilation:
the test tried to assign the SDK's read-only Reduce Motion environment value.
Replacing that harness override with a transaction that disables animations
resolved it; no tests ran in the failed compilation attempt.

After declaring the custom drag type in the app's Info.plist, the final
`topics-bundle-drag.log` run passed all **7 selected tests**, zero failures or
skips (the three drag tests and four release-configuration tests). These are
reruns from the 90-test set, not seven additional unique tests. The added
assertion verifies the custom data type in the packaged application.

The command wrapper `run-native.py topics-native-final` selected the 12 suites
above with `xcodebuild test`, Release configuration, arm64 destination, the
shared incremental build cache, `ENABLE_TESTABILITY=YES`, and ad-hoc test
signing. Production release signing is recorded separately below. Tests use
scratch metadata and an in-memory configuration vault, not production keys.

The focused validation covers:

- Durable topics and session membership; legacy sessions remain ungrouped.
- Atomic moves and topic removal, cross-project rejection, stale metadata
  protection, and removal without deleting conversation data.
- Side/fork inheritance and kept-side publication racing a parent move;
  session organization while active work, drafts, and queues remain intact.
  The deterministic deletion regression reproduces the successful metadata/UI
  removal phase; it does not operate the deletion dialog or Trash.
- Topic-first sidebar navigation, archive and pin behavior, selected-child
  visibility, per-group pagination, and matching-title/ancestor filtering.
- Actual own-process `NSItemProvider` dispatch, bounded/versioned payload
  decoding, duplicate IDs, cross-project batch rejection, and generic text
  drops being ignored.
- Native SwiftUI/AppKit sidebar layout with empty and collapsed topics,
  filtered expansion, and restoration of saved disclosure state.

These provider/layout checks run in process. The inactive remote desktop does
not establish physical pointer drag/drop, native context-menu interaction, or
VoiceOver behavior. No claim of those checks passing is made. A topic is one
level within a project; nested topics, cross-project moves, topic reordering,
and sidebar multi-selection are outside this change.

The provider, helper, gateway, request, and transcript scrolling implementations
are unchanged by this feature; their [0.1.55 evidence](Bello-Agent-0.1.55-2026-09-19.md)
is reused. Signing, notarization, stapling, Gatekeeper, packaged helper/catalog
smoke, and public archive/feed verification were run freshly for this release
and are recorded in Distribution. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the owner's standing instruction.

See the [topic review](../Topics-Review-2026-09-19.md). Scratch logs and XCTest
results belong under
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/topics-056-20260919`.
