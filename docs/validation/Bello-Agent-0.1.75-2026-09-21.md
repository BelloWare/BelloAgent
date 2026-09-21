# Bello Agent 0.1.75 / build 79

Release preparation; publication is pending.

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

The native UI, wire schema and website staging code are unchanged. Reuse the
43 actor-checked native, 21 optimized native and 12 website staging checks from
[0.1.74](Bello-Agent-0.1.74-2026-09-21.md). The release builds/stages the updated
optimized helper and runs packaged helper/catalog smoke. Signing, notarization
and public artifact verification are recorded below when complete.
Installation and updater rehearsals stay skipped under the owner's instruction.

Source commits remain local under the current release workflow. The website
publication commit will be pushed to its configured upstream.
