# Resource-instruction source spelling

This is a presentation-only correction over commit
`8914fd798e30750a0bd07c209d36138397b9ec4a`, tree
`1770c0b10103a773573bfef867fc1cd98f1758d5`. It is separate from the sealed
Skills identity correction and does not rewrite its evidence or historical claims.

## Contract

The checked-in Swift `Support.swift:75` resolves display/provenance paths with
Foundation. `Resources.swift:112–127` keeps an ordinary instruction's locator
filename in its header and budget diagnostic, while resolving the source metadata
path. Approved additional instructions use the resolved target for both header
and metadata. `Resources.swift:175–179` constructs the workspace/implicit-skill
prompt; `SessionContext.swift:144–147` supplies the request policy.

Rust now captures source-compatible `prompt_roots` during instruction discovery
and uses them only in its two resource prompt renderers. Ordinary headers append
the locator filename to a checked source-spelled directory; source metadata and
additional headers use a checked resolved target. The existing Foundation helper
is exposed only within the crate and still requires equality with the bounded
reader's/scanner's canonical target. Missing optional paths remain optional.

The canonical path resolver, project directory discovery, bounded regular-file
reader, canonical roots, ResourceScope, saved project roots and authority remain
unchanged. There is no global `/private` replacement or instruction/skill/body/
argument/history rewriting. FrozenSkill, Submission, receipts, UserContent and
storage versions are unchanged. Same-controller Retry retains applied prompt
bytes; new delivery and reopened controllers resolve fresh instruction snapshots.
Revisions naturally reflect the newly rendered prompt. The full Rust catalog
revision is not asserted equal to Swift's different catalog encoding.

## Validation

At the source freeze recorded in `test-source-sha256.json`:

- Default core: 388 unit + 127 integration = 515 passed; no failed or ignored tests.
- All-features core: 542 unit + 127 integration = 669 passed; no failed or ignored tests.
- Both strict core Clippy configurations (`--all-targets`, default/all features) passed.
- Workspace `cargo fmt --all -- --check` passed.
- Six isolated behavioral controls failed at the intended test assertions:
  ignoring captured prompt spelling, resolving the locator leaf in the ordinary
  header, removing the same-target check, rewriting literal instruction text,
  refreshing instruction-only Retry, and refreshing saved-project Retry.
- The control checkout was restored byte-exactly. The tested final candidate was
  never modified by these controls. Detailed commands, hashes and logs are retained.
- Six source/LOC verifier controls detected source drift, missing source,
  manifest reclassification, rewritten sealed evidence, unexpected Rust source,
  and unrelated Rust drift; the restored positive verification passed.

The all-features run includes 18 instruction-runtime and eight saved-skill-runtime
regressions. These cover exact framing, active capture, leaf retargeting, unchanged
Retry prompt/user-content bytes, fresh next delivery, and fresh reopened Retry.
The macOS runtime framing expectation independently executes the checked-in Swift
canonical function rather than reusing the Rust adapter under test.

The expanded native oracle now requires full-result equality for all six former
Darwin prompt exceptions. Its complete matrix has 26 project/resource cases,
18 instruction-only cases, and six retained compaction cases. Real AGENTS files
cover both Darwin aliases, override precedence, nested/shared ancestors,
multiple/deduplicated roots, a symlink leaf with a different target, implicit
skills, missing/empty optional resources, global/additional links, zero and UTF-8
budgets, truncation diagnostics, and literal `/private` text. Source JSON is
projected only to Swift's field schema; no path, body, instruction or diagnostic
string is normalized, and no instruction result is excluded.

**Native execution is pending.** Linux runs zero tests for the macOS-only oracle.
The successful Linux checks are not Foundation/Swift/native acceptance. Require
both CI workflows for the exact published correction, including actual macOS
oracle execution, before making that claim. No owner Mac, real credentials,
release, signing or paid service was used here.

## Additive source/LOC evidence

`source-loc.json` records the ten source/test afterimages, exact baseline preimages,
Git blob and SHA-256 identities, classification spans and preserved spans.
This patch adds 21 production and 674 test/support nonblank physical Rust lines,
with no benchmark change. Its isolated totals are 43,663 production / 59,186 support
/ 1,192 benchmark, across 200 Rust files. These totals include this patch only;
independent catalog or UI work must be counted separately. 3,706 preserved
nonblank Rust lines keep their prior classifications.

Synthetic-only `resource_runtime.rs` remains test/support as in the inherited
ledger. The shared source-path helper remains production; test modules and their
positive cfg declarations remain support. Swift, Python, logs and documentation
are excluded from Rust LOC. Source volume is not a feature-completion or
performance metric.

The prior sealed Skills verifier was rerun read-only against the immutable base
and passed. Its ledger, archive, logs and verifier are checked unchanged by this
new additive verifier. The original working checkout was not modified.

Reproduce the source/LOC check from a repository that retains the base Git objects:

```sh
python3 rust/scripts/verify-instruction-source-path-2026-10-08.py \
  --repo /path/to/BelloAgent --source-root /path/to/candidate --strict-tree
```

Omit `--strict-tree` only when checking the scoped afterimages in a separately
integrated tree; that does not certify unrelated changes or combined LOC totals.
Run behavioral controls in a disposable copied source tree with a coordinated
compiler lane, `CARGO_BUILD_JOBS=1`, and a separate `CARGO_TARGET_DIR`:

```sh
python3 rust/scripts/test-instruction-source-controls-2026-10-08.py \
  --source-root /path/to/candidate --output-dir /path/to/control-results
```

The standard workflow commands remain the release/CI gates. This evidence does
not attest remote publication, native execution, GUI acceptance or performance.
