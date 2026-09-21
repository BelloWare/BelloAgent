# Bello Agent 0.1.75 / build 79

Released and publicly verified at **2026-09-21 12:29:51 UTC**.

## Change and validation

Removes the compaction planner's outcome/keyword rejection, including the same
check during checkpoint restoration. Unknown outcomes and phrases in ordinary
tool output no longer block compaction. Existing call/result pairing validation,
recorded outcomes and bounded summary source construction remain. Compaction
does not invoke historical tools. Implementation commit: `d32a921`.

**28 focused helper tests passed** in the preceding implementation turn, with
no subsequent helper changes: `CompactionSafetyTests`,
`CompactionTaskRegressionTests` and `QueueHandoffTests`. New cases cover manual
and threshold compaction with an unknown result, checkpoint restore, successful
read output containing warning phrases, retained source metadata and zero
historical tool invocations. Existing cases cover queues, failure/Stop and 20
concurrent compactions. Two stale queue expectations were corrected to the
automatic handoff released in 0.1.74; frozen summary isolation and exactly-once
delivery remain checked.

```sh
TMPDIR="$SESSION_SCRATCH/" swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'CompactionSafetyTests|CompactionTaskRegressionTests|QueueHandoffTests'
```

Final implementation log: session scratch `compaction-outcome-regression-final.log`.
macOS 14.8 (23J21), arm64, Xcode 16.1 (16B40), Swift 6 mode.

The native UI, wire schema and website staging code are unchanged. Reused the
43 actor-checked native, 21 optimized native and 12 website staging checks from
[0.1.74](Bello-Agent-0.1.74-2026-09-21.md). The release builds/stages the updated
optimized helper and runs packaged helper/catalog smoke. Signing and notarization
have passed, along with public artifact verification below.
Installation and updater rehearsals stay skipped under the owner's instruction.

Source commits remain local under the current release workflow. The website
publication commit was pushed to its configured upstream.

## Signing and publication

- Packaged source: `dfe006eba46d160838da49a9c3205953e9de1eb3`.
- Website commit: `43ab499a1130740befbff0ef02285d539dc79f6d`, pushed to
  configured upstream `origin/main`.
- App notarization: `27420ea6-179c-4614-a13c-e572d0f1cc8c`, accepted.
- DMG notarization: `7358c83d-3669-4d9e-845e-8a214e66e5d9`, accepted.
- `BelloAgent-0.1.75.dmg`: **8,857,813 bytes (8.45 MiB)**.
- SHA-256: `fada689ecd38670c0e7bf26e8581bd8848cf5812edc3babef1932d81f7b4f5dd`.
- Cloudflare check **106332227662** succeeded at **2026-09-21 12:26:47 UTC**.

The updated optimized helper was rebuilt from source. The app build reused its
compiler cache. Packaged helper/catalog smoke, Developer ID signing, hardened
runtime, app/DMG notarization, stapling, Gatekeeper, feed/build validation and
local Sparkle Ed25519 verification pass. No XCTest bundle ships. The final
signed installer was copied into the session outbox.

Release logs: session scratch `bello-agent-0.1.75` and
`bello-agent-0.1.6/build/release.zFflNf`.

Public verification passed at **2026-09-21 12:29:51 UTC**. The downloaded DMG
matches the validated local SHA-256 and passes Sparkle Ed25519 verification.
Canonical Bello Agent and legacy Pi App update feeds are byte-identical to the
validated release feeds. The public product page exactly matches the staged
publication and links to `BelloAgent-0.1.75.dmg`. Initial checks served 0.1.74
while deployment was in progress; both checks passed after deployment completed.

Evidence: session scratch `bello-agent-0.1.75/public-verify.log`,
`bello-agent-0.1.75/public/` and `bello-agent-0.1.75/public-page.html`.
