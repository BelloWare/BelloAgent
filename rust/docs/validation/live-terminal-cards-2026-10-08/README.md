# Live terminal cards: fresh integration validation

This local candidate applies the frozen eight-path r3 patch to published
`b3acabc25817fbac97f54b73c88362fa584d40e3`, tree
`b88d8335683a7c116b1f9aac21f7fda7842c5f16`. All eight preimages and postimages
were verified; the other 2,105 original tracked files remain unchanged. This
includes the workspace lease repair, decoder, native evidence, workflows and
catalog. These records do not claim candidate publication or exact-commit CI.

## Behavior and limits

Native and MCP terminal outcomes can appear while siblings are still running.
Live display state does not acknowledge durable settlement: original-call-order
whole-batch checkpointing, pending MCP receipts and no automatic replay remain
unchanged. Terminal previews omit image bytes and base64, retaining only short
MIME descriptors alongside normalized text. Stale or repeated updates cannot
revive completed cards.

The presentation admission window is explicitly **the first 16 calls in source
order**, not the first 16 to finish. Later calls still execute and commit normally
but show Awaiting until canonical results arrive. Each preview is bounded to
98,304 UTF-8 bytes, totaling at most 1,572,864 preview bytes plus bounded metadata.
Previous batches are pruned; live state is neither serialized nor replayed.

## Fresh execution after package clean

Pinned Rust 1.99.0 on Linux, two compiler jobs and two test threads:

- Live-runtime focused tests: **9 passed**.
- MCP concurrency focused tests: **18 passed**.
- Default core: **421 unit + 127 integration tests passed**.
- All-feature core: **596 unit + 127 integration tests passed**.
- Generic App filter: **9 passed**, including five new card-specific tests.
- All-feature App: **593 passed, zero failed, 3 ignored**.
- Formatting and strict default/all-feature core and all-feature App Clippy passed.

The first isolated MCP command used an incomplete module filter and selected zero
tests. That log is retained as no coverage. The corrected full module path ran
18 tests successfully; those tests also ran in the full all-feature suite.
Subprocess repetitions are not added to unit totals.

To exclude earlier shared-target mutation artifacts, both Agent packages were
explicitly cleaned before compilation. The clean removed 1,029 files / 1.2 GiB;
a filesystem assertion verified no Agent App/core test executable survived.
Subsequent logs show fresh package compilation before execution. Dependencies
were retained. No mutation was introduced during these integration runs.

`fresh-validation.json` records exact commands, exits, counts and log digests.
`source-binding.json` binds 304 compile-input files; all 2,113 original frozen
inputs were verified unchanged through testing. `test-binaries.json` records
the three newly built test-executable hashes. Their hashes match the prior
candidate's final binaries, following this independent clean rebuild.

## Preserved prior evidence

`prior-candidate-history.json` distinguishes earlier candidate execution from the
fresh integrated runs. It retains the initial zero-test mutation invocation, the
corrected detecting mutation, the failed switch-back that reused the mutant in
the shared target, and the later forced-rebuild pass. Prior full-suite logs are
attributed separately. Raw original-log digests and normalized publication-log
digests are both recorded; workspace paths alone are normalized for publication.

The r2 test-module import compile problem was corrected in frozen r3 before this
integration. No runtime repair or expectation weakening occurred during the fresh
validation above.

## Acceptance boundaries

These are generated-fixture, loopback and headless App checks. They do not provide
actual interactive GUI, macOS, native source-oracle, input/accessibility, signing,
Keychain or production credential acceptance. The three ignored App tests remain
unexecuted. Existing `proc-macro-error2` future-incompatibility advice is retained;
it did not fail current strict Clippy.

Per-call and batch timing remain a separate deferred feature. Compile times and
test durations are not performance or Swift timing-parity claims. Production
authority/tool gates and all previously documented acceptance limits remain.
