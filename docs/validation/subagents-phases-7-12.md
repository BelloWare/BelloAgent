# Sub-agents continuation validation — 0.1.126

Worktree `wt-subagents`, branch `dev/subagents`. Build/test artifacts use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents`.
Only generated fixtures and loopback gateways; no installed app, real vault,
preferences, Keychain or paid providers. The production switch remains off.

## Review fixes after phases 1–6

Started from `ea952f1e` (merged `dev/next`); `git pull --ff-only origin dev/subagents`
was already up to date. No changes to `dev/next` or `main`.

- Baseline: `SessionSettlementTests|CostLimitTests|CaptureDrainTests|HostServiceTests`:
  **23 passed** (`subagents-review-baseline.log`).
- Failing-first: new ordinary-accounting, queued-child pin, runtime replacement,
  durable-side, copy-fork and throwing-MCP regressions: **10 assertion failures**
  across 28 tests (`subagents-review-red.log`). An earlier compile error was fixed
  before recording that behavioral red run.
- Focused implementation run: **104 passed** (`subagents-review-green.log`).
- Eight guard mutations killed: eager ordinary-chat activation, missing seed
  reset, ignored child Stop generation, idle child unpinning, cross-runtime
  cancellation, retained consumed jobs, retained throwing MCP token, copied
  fork admissions/corrections (`subagents-review-mutation-*.log`). The first
  runtime mutation exposed an assertion that observed too early; the regression
  now checks the replacement child's durable completed result and kills it.
- Owner-key consistency is structural: the current depth-one identity contract
  requires owner == parent, so an unequal-owner runtime fixture is invalid.

The ordinary physical-attempt replay test now calls the durable accounting entry
point explicitly. Ordinary chats intentionally keep the pre-feature bounded
in-memory guard and best-effort cost writes; family attempts retain durable dedup.

- Restored broader run: **126 passed, 1 skipped**, 127 executed
  (`subagents-review-restored.log`), including the four requested classes.
  The skip is the opt-in shared-fork-fixture writer. The committed version-1
  checkpoint fixture remains unchanged; its test now verifies intentional
  fallback and compares the rebuilt checkpoint without the new derived indexes.
- Native smoke checks (`SubagentMetadataTests`, `SubagentModelGrantTests`,
  `WireContractTests`, all parallel lane) were started with a bash array; their
  result will be recorded below when the merged app finishes rebuilding.

- Native review smoke result: **13 passed, 1 skipped**, 14 executed
  (`subagents-review-native.log`). The skip is the opt-in per-token performance
  fixture. All three classes ran using a bash array after lane inspection.

## Phase 7 — Stop and recovery

- Failing-first recovery suite: **19 failures** across 6 tests, including the
  expected JSON-envelope parse failure on the old generic interrupted text
  (`phase7-red.log`). Marker-only child creation then failed independently
  (`phase7-creation-red.log`); restored-child reader unload failed as busy before
  distinguishing it from a coordinator-owned job (`phase7-child-viewer-red.log`).
- Restored helper run: **153 passed**, no skips (`phase7-restored.log`). Includes
  sub-agent suites, SessionSettlementTests, CostLimitTests, CaptureDrainTests,
  HostServiceTests, ContinueRunTests, parallel tools, tool outcome/persistence,
  MCP retention, checkpoint/slimming, retries, capture, compaction shapes and
  host dispatch.
- `scripts/test-subagent-crashes.py`: **21 passed** (18 crash barriers and
  Stop/shutdown/update), `phase7-crashes-final.log`. Each crash reopen sent no
  requests; Resume sent exactly one parent request; child request counts and
  external-effect bytes did not increase. Completed terminal results were
  adopted exactly once. Control cases had 16 active slots plus 2 queued, with
  6 child HTTP requests overlapping under the existing transport connection
  pool; all 18 child outcomes settled before journals closed.
- Seven unit guard mutations killed: exact terminal adoption, reciprocal
  origin, result identity, registered cost evidence, unknown cost, immediate
  queued cancellation, terminal synchronization (`phase7-mutation-*.log`).
- Real-helper shutdown mutation killed: omitting coordinator drain produced
  failed child outcomes from closed journals (`phase7-mutation-shutdown.log`).
  The generated fixture delays terminal persistence and fixes the valid
  dictionary traversal order to child-first to make that race deterministic.
  The restored generated helper then passed all 21 cases.
- Native lifecycle validation runs `LifecycleHelperTests` in its serial lane
  alone, then `RunHoldTests` and `SubagentMetadataTests` as a bash array.

The journal marker remains v1 for parents and v2 only for children. Recovery is
available independently of the disabled rollout switch. No production capture
policy, installed app, or real preferences/vault data were changed.

- Native phase 7 results: `LifecycleHelperTests` **10 passed**, serial lane
  alone (`phase7-native-serial.log`); `RunHoldTests|SubagentMetadataTests`
  **18 passed** using a bash array (`phase7-native-parallel.log`).
- Final record-validation review: mismatched terminal/metadata status and
  nonexistent result references failed first (2 assertions,
  `phase7-result-validation-red.log`). Both individual mutations were killed.
  The affected helper run passed **50 tests** (`phase7-final-guards.log`),
  and the three completed-result crash barriers passed again
  (`phase7-final-terminal-crashes.log`). The final restored recovery suite
  is recorded in `phase7-recovery-restored.log`.
