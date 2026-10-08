# Completed tool timing validation — 2026-10-08

Base: `fdc5bb0232f54def59b7a7df5363b6d73bdc2573`. Source candidate r3 is identified
by `candidate-r3-manifest.json`; this pre-publication record does not claim a remote
commit or CI result. See `../../tool-timing.md` for the contract and remaining gates.

## Final checked results

Rust1.99.0, locked cached official dependencies and isolated cloud GPUI prerequisites.
From `rust/`:

- `cargo test --offline --locked -p bello-agent-core`:429 unit+127 integration tests pass.
- `cargo test --offline --locked -p bello-agent-core --all-features`:606 unit+127
  integration tests pass. Two isolated child invocations also run in the log;
  their repeated test counts are not added to606.
- `cargo test --offline --locked -p bello-agent-app --all-features`:598pass,0fail,
  3existingignored. Ignored tests are manual CPU benchmark, native Foundation
  editing workflow and native ImageIO read workflow. They are not acceptance.
- `cargo clippy --offline --locked -p bello-agent-core -p bello-agent-app
  --all-targets -- -D warnings`, repeated with `--all-features`:both pass.
- `cargo fmt --all -- --check`:passes.

Core and App packages were explicitly cleaned after both mutation controls;
`clean-verification.json` records zero surviving Agent test executables before the
final candidate rebuild. Final source hashes were checked after all gates. Binary
identities are in `verification.json`. This prevents reuse of a stale mutant or
other-worktree Agent binary from the shared dependency cache.

## Negative controls and failures preserved

The isolated sum mutant substituted sum(call durations) for batch wall. The focused
once-only checkpoint test failed with240000µs versus140000µs. The isolated App
mutant removed duration equality; the duration-only projection test failed its
same-content assertion. Each ran one intended failing test, and neither mutant
was applied to the publication candidate.

Earlier logs remain under `earlier-attempts/`. Initial schema compilation needed
an updated batch fixture; first broad core run had577pass/19legacy fixture/version
failures. Explicit legacy fixtures now omit timing fields, retaining their original
upgrade/byte-preservation checks; proven-new session expectations are version9.
A later probe had602pass/one remaining version assertion, corrected. New tests also
needed an import/type annotation and tuple destructuring repair.

The first clean full App run had596pass/1fail/3ignored: the new footer badge's
wrapped vertical spacing left146px transcript height below the existing150px
reading reserve (available queue room153px). The repair reduces only footer row
gap to4px, retaining12px horizontal spacing. The original150px assertion was not
weakened; additional badge-within-footer/single-line geometry assertions pass.
Final r3 includes an integrated36-case formatter-oracle test and passes598 tests.

## Coverage and evidence boundaries

New checks cover per-call explicit entry versus pre-entry cancellation/refusal;
invoked failures and queued cancellations; unmeasured result-normalization and disk
retention fallbacks; measured MCP rejection/unprocessed expiry with receipts and
uncertainty preserved; wall-time charge once through real image steering projection;
before/after-rename recovery; sticky unknown/checked overflow; v1–8 timing presence
gates including null/empty fields; byte-preserving legacy reads/inspection; unchanged
provider replay; compaction preservation; independent terminal duration while a
sibling remains held; terminal immutability and existing bounded identity checks;
duration-only GPUI selection/disclosure/scroll; narrow footer geometry.

`native-formatter/` contains the peer's exact-source macOS14.8/Swift6.0.2 oracle,
independently verified portable bytes, complete48 native fixtures, and comparison
of the36 cases representable in unsigned integer microseconds. Native execution
is attributed to the peer. This proves formatting fixtures, not interactive GUI,
TCC/AX/Keychain/signing, speed, complete migration or release readiness.
