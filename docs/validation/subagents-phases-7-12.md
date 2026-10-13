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
