# MCP core, integration and review evidence

Baseline: published runtime-tail repair
`33c79e21ca336a98483ca77adf7435aa885bf5d3`, tree
`b1b6e4afef9b8126fb7347489f90999c217c7544`. Earlier MCP review/staging began on
`50da4e9969a75182461dd24619bbad083155d4cb` (metadata-equivalent local `c58800c`,
tree `b328816ff6b6ae9b99f3cbae2a6297d4ffbf9f2a`). Scoped integration preserved
its final capability badge, Projects notice, tests and evidence, then merged the
separately reviewed retirement repair without replacing MCP hooks. Prior ledgers
remain immutable.

The repaired baseline's exact [Linux run 37602221180](https://github.com/BelloWare/BelloAgent/actions/runs/37602221180)
and [macOS run 37602220932](https://github.com/BelloWare/BelloAgent/actions/runs/37602220932)
both completed successfully. These validate the published retirement repair;
they do not establish exact CI for the next MCP commit.

The frozen MCP Rust-source manifest is
`4615f74a232134b3bcce77980b5ffaa8ca1f4d9c7109ea6ba0f0bd914ef3b3a9`, recorded by
`../loc-project-mcp-2026-10-07-delta.json`. It covers all 164 Rust files, including
the standalone support-only ReadOnly fixture helper. The GUI evidence has a
separate build-input manifest that also includes Cargo/assets, plus an immutable
binary hash; those different scopes must not be conflated.

## Final integrated Linux checks

- Core all features: **450 unit + 107 integration tests passed**
- Core default: **313 unit + 107 integration tests passed**
- Focused MCP core: **33 tests passed**, included in the all-feature total
- App synthetic authority: **501 passed / 3 intentionally ignored**
- App default: **408 passed / 1 intentionally ignored**
- Focused MCP host/Inspector/GPUI: **44 passed**, included above
- Strict all-target core/app Clippy passed in default and covered all-feature or
  synthetic configurations; workspace formatting passed
- Independent review reran the exact frozen core's 23 tests and strict all-target,
  all-feature Clippy, and the exact frozen app's focused tests

Representative commands from `rust/`:

```sh
cargo fmt --all -- --check
cargo test --locked -p bello-agent-core --all-features
cargo test --locked -p bello-agent-core
cargo test --locked -p bello-agent-core --lib --all-features mcp::tests
cargo test --locked -p bello-agent-app --features synthetic-authority
cargo test --locked -p bello-agent-app
cargo test --locked -p bello-agent-app --features synthetic-authority mcp_inspector
cargo clippy --locked -p bello-agent-core --all-targets --all-features -- -D warnings
cargo clippy --locked -p bello-agent-core --all-targets -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets --features synthetic-authority -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets -- -D warnings
```

Both Linux and macOS CI explicitly include saved-factory, MCP core and Inspector
fixture suites. Exact native CI for a subsequently published MCP commit remains
separate from these local Linux results. Native signing, Keychain, credentials,
keyboard/IME/accessibility and actual macOS GUI acceptance remain unearned gates.

## Discriminating cases

The tests use injected vault storage and numeric-loopback HTTP only. They cover
whole-byte configuration CAS, unknown raw fields, explicit secure-header
preserve/clear and endpoint-change rules, duplicate/schema/cursor rejection,
allowlists, exactly one wrapper, initialize/session/protocol headers, chunked SSE
priming/notifications/cache changes, bounded session expiry retry, and no proxy or
redirect traffic. No fake fixture sends external requests or invokes a paid model.

The real Controller path returns Failed text/structured/image content, continues
the provider request, checkpoints v6 and reopens without execution. Negative cases
reject native-tool owners, wrong assistant/call identities, Unknown content,
is_error disagreement, and v5 Failed content without rewriting existing bytes.

Durability tests cut both before and after canonical-result and ledger renames.
Uncertain canonical persistence leaves unresolved evidence across restart. A
readable latest Inspector receipt never clears a later unknown invocation. An
uncertain housekeeping clear after an already-confirmed canonical result leaves
the live manager quarantined, while restart follows whichever valid ledger was
committed. Tests also cover two MCP calls in one Controller batch, distinct chats
sharing the edit gate, cancelled waits, dispatched interruption, dropped Inspector
callers, retirement/join and exact-fingerprint acknowledgment.

## Independent review corrections and negative controls

Before freeze, review required these corrections:

1. Explicitly disable reqwest's implicit protocol retry policy, in addition to
   application-level no-replay behavior and no proxy/redirect settings.
2. Add strict bounded latest-Inspector-result reload without using read success as
   permission to clear unknown evidence.
3. Keep an externally changed configuration reloadable/reviewable independently
   of the old manager's stale-config receipt-read refusal; require explicit
   trust/save/apply before operations resume.
4. Make foreground status nonblocking even while the durable ledger mutex is held
   across fsync. A separate cached snapshot and conservative contention fallback
   preserve unknown/pending state without freezing GPUI Cancel/Close.

In an isolated copy, replacing cached status with the former blocking ledger lock
made the bounded regression fail. The test uses recv_timeout, always releases the
held lock before joining/asserting, and cannot hang waiting for its own release.
Removing the Failed-content MCP-owner requirement made the foreign/native-owner
negative fail. Restoring the exact reviewed source passed all 23 MCP tests again.
Neither negative control modified the accepted source or Git state.

A final strict-null correction rejected a present `allowedTools: null` before
Option deserialization or vault writes. Real discovery verifies omitted → all
tools, empty array → no tools, and an explicit name list → only those tools;
null and other wrong types leave saved bytes unchanged. Independent review
accepted the exact two-file change, a guard-removal negative detected the bug,
and that restored source passed all **24 MCP tests**. Its full core
suite passed **436 unit + 107 integration tests** before the later baseline repair.
Candidate 1 GUI evidence is explicitly preliminary; candidate 2 was built but
never launched. Candidate 3 completed the full bounded GUI matrix on its own
immutable binary and source manifests.

These checks establish the stated portable contracts. The accompanying GUI
README records actual computer-use coverage separately; automated fake-platform
checks are not substituted for it, and neither establishes full Swift parity.

## Source-volume audit

Independent classification review and the portable verifier passed **37,090
production / 49,741 tests-support / 1,186 benchmark** nonblank physical Rust lines,
**88,017 total** in 164 files. This is **+4,497 / +3,243 / 0** over the verified
published baseline. All 16 existing changed before-source blobs match prior
reviewed categories; no positive-cfg support span is missing. Eight unguarded
compiled fault checks remain production under the established physical-source
convention, explicitly noting that only test setters select injection values.
Shared secure input adds zero lines. These are source-volume counts, not parity
or performance measurements.

The subsequent baseline retirement repair and truthful cancellability controls
were merged before immutable candidate3. That pre-lease core validation passed
441 all-feature unit and 107 integration tests, plus 308 default unit and 107
integration tests; the final post-lease counts are recorded below.
The separately published retirement repair retains its own discriminating
reproduction/stress record and is excluded from the MCP-only LOC delta.


## Canonical outcome-file writer lease correction

Final ownership review found that supported alternate `--session` catalogs can
have different workspace locks but share one project outcome filename. The
ledger now acquires a separate nonblocking exclusive OS lease on a stable private
sidecar derived from the canonical parent and project filename, before reading
or writing evidence. Lock leaves reject nonregular files and symlinks; the
sidecar is never unlinked on release. `Ledger` owns the lease, so tickets and
physical receipt workers retain it across dropped workspaces/callers. No runtime
joining architecture was replaced.

Same-workspace first manager creation is serialized outside the catalog mutex.
Root re-trust rebinds only that owner's cached same-project/same-storage manager,
sharing its ledger and operation/editing gates while confirming fresh authority
and resetting transport/catalog state. Old exact project authority cannot
acknowledge or dispatch, and unresolved fingerprints remain unchanged.

Focused checks passed **33 MCP tests** (28 synthetic workflow cases plus five
ordinary ledger tests), with **five default-feature ledger tests** also passing.
Two independent catalog locks, marker byte preservation, no second dispatch,
last-ticket ownership after workspace drop, detached blocking settlement,
concurrent factory reuse and same-workspace root re-trust are covered. Bounded
subprocess probes prove real process exclusion and fail-closed FIFO handling;
alias/symlink, stable inode and explicit-unlock checks are included.

Removing only `try_lock` in an isolated source copy made both the subprocess and
two-catalog regressions fail as intended. An initial restored run was discarded
because Cargo reused a mutated-copy artifact from the shared target. After
scoped cleanup, the original BelloAgent core visibly recompiled and passed all
33 tests; source hashes were verified unchanged. Subsequent negative controls
must use their own target. An extracted exact lease helper also typechecked for
`aarch64-apple-darwin` with warnings denied; that is compile-only evidence, not a
macOS execution claim. Candidate 4 records final scoped GUI acceptance separately
from the broader, unchanged candidate 3 matrix.

The final original-source all-feature suite passed **450 unit + 107 integration
tests**, and default features passed **313 unit + 107 integration tests**. Both
strict all-target Clippy configurations and workspace formatting passed; exact
changed-source hashes matched before and after. Logs are retained in
[`writer-lease/`](writer-lease/).

[Independent final lease review](writer-lease/WRITER-LEASE-ADDENDUM.md) reran
33 MCP and five default-ledger tests, checked all six changed-source hashes,
reviewed the discriminating negative controls and approved the final LOC spans.
No remaining safety blocker was found in that exact source.

## Raw evidence whitespace

Cargo test output is retained byte-for-byte, including terminal blank lines and
an original trailing progress-line space. The staged whitespace check excludes
only immutable `rust/docs/validation/mcp-2026-10-07/**/*.log` payloads so their
recorded hashes remain valid. Source, tests, workflows and all non-log documents
pass the strict check; no repository-wide whitespace rule was relaxed.
