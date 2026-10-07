# Project MCP Rust source volume — 2026-10-07

Baseline: `33c79e21ca336a98483ca77adf7435aa885bf5d3`, tree `b1b6e4afef9b8126fb7347489f90999c217c7544`.

- Production: **37,090** nonblank physical Rust lines (+4,497)
- Tests and test support: **49,741** (+3,243)
- Benchmarks/examples: **1,186** (unchanged)
- Total: **88,017** across **164 Rust files**

Comments count. The shared runtime/transport/vault/Inspector implementations are
production code even though normal native startup remains gated. Standalone tests,
numeric-loopback fixtures, the supplemental ReadOnly catalog seed, positive test
and fixture-only cfg spans are support. Under the established physical-source
convention, eight unguarded, production-compiled fault-check branch lines remain
production, even though production supplies zero and only test setters select
injection values. Platform-specific native implementations remain production. The shared secure input was reused with visibility-only changes and
adds zero lines in this delta.

This is source volume, not a feature-completion percentage, speedup, memory result
or native acceptance claim. The exact 164-file source manifest is
`4615f74a232134b3bcce77980b5ffaa8ca1f4d9c7109ea6ba0f0bd914ef3b3a9`. The previous saved-runtime ledger remains
immutable.

From the repository root, verify the published MCP revision with:

```sh
python3 rust/scripts/verify-loc-project-mcp-2026-10-07.py --repo . --after HEAD
```

Before commit, `--after WORKTREE` verifies the same source closure. The verifier
uses only Git objects, exact blob/range anchors and reviewed classifications; it
does not require the scratch parser used while preparing the ranges.

Independent review approved the classifications, matched all 16 existing changed
source blobs to prior reviewed counts, found no missing positive-cfg span and
passed the exact verifier. The compiled-fault-branch convention is documented
above and in the JSON review notes.

The baseline already includes the separately published completed-worker-tail
retirement repair, so its 26 production / 377 support lines are not counted again
as MCP additions.

The final rebaselined ledger and narrow cancellability delta were independently
audited again; the exact WORKTREE verifier passed.

Final writer-lease protection adds 95 production and 348 support lines over
immutable GUI candidate 3. The canonical-path OS lease, factory serialization and
lease-preserving rebind are production; collision, subprocess, alias/symlink and
dropped-owner/settlement regressions are test support.

The writer-only classifications and exact final manifest were independently
approved after the 33 MCP/five default-ledger reruns. Root separately reran the
WORKTREE verifier; see the retained writer-lease review addendum.
