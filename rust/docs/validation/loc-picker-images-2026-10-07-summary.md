# Picker-selected attachment LOC delta

Reviewed against published MCP `8498464d31778b14c7090c2a34835bac3319849c` (tree `a3cfa620379fd0e5cf7fce50b0756ca9b10cbfba`).
Counts are nonblank physical Rust lines, including comments. They are source
volume, not a percentage of feature parity or a performance result.

- Production: 38,771 (+1,681)
- Tests and test support: 52,812 (+3,071)
- Benchmarks/examples: 1,189 (+3)
- Total: 92,772 across 175 Rust files

The separate ordered user-content/runtime/app vertical is production. Explicit
synthetic fixture code and the feature-only resource runtime are test support;
positive cfg spans start at the attribute, leaving preceding comments in their
prior category. Standalone test modules are wholly support. Existing before
spans were reused where available and reviewed directly for the changed ordinary
chat/queue/Inspector modules that lacked a retained span record.

Source manifest: `b5a38875edff8551bd9ed31e9804d152fa3233e16985897005f788ada5bff50f`.

Run from repository root:

    python3 rust/scripts/verify-loc-picker-images-2026-10-07.py --repo . --after HEAD

Before a commit use `--after WORKTREE`; publication verification must use its
exact revision. The verifier checks exact source blobs, reviewed span endpoints,
all Rust file counts and the full physical total.
