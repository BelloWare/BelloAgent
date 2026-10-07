# Native attachment oracle path identity correction

Baseline: `38a9d1f3efc414eb018a5a170cc01acfbc52aacd`.

Linux workflow [37628446533](https://github.com/BelloWare/BelloAgent/actions/runs/37628446533)
passed. macOS workflow [37628446507](https://github.com/BelloWare/BelloAgent/actions/runs/37628446507),
job `112816181006`, compiled and linked native targets, then failed the attachment
Swift oracle metadata assertion. The domain test result was 357 passed / 1 failed.
The first GIF record differed only in its path spelling: Rust resolved the runner's
temporary path to `/private/var/folders/...`, while Foundation returned
`/var/folders/...`. MIME, byte count and SHA-256 matched.

The correction canonicalizes the existing Swift-record path before the complete
metadata equality assertion. It does not strip prefixes, omit path checks, change
production path handling, or weaken content/order/error comparisons. A source
symlink and a distinct same-byte GIF file are added to the native oracle matrix:
the latter must retain its own canonical target despite identical content.

Local formatting and whitespace checks pass. All six portable attachment tests
pass with `cargo test -p bello-agent-core --features synthetic-authority attachments::
-- --test-threads=1`, after package-only cleanup and an explicitly verified build
from this repository root. A separate read-only review found no issue in the
strict existing-target comparison. Native Swift/ImageIO execution must
be confirmed by CI for the correction; the failed baseline is not native acceptance.
Previously captured Linux GUI evidence remains tied to its recorded binaries.

This changes only test-support Rust and this validation note. Counting nonblank
tracked Rust lines, including comments, the delta is +19 test-support lines,
with production and benchmarks unchanged: 38,771 production / 52,831 test-support /
1,189 benchmark. Shared code remains counted only in BelloBox.
