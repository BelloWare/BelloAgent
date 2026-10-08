# Source UTF-8 compatibility bridge — 2026-10-08

Status: isolated A4 candidate, based on
`6eee1d06776b18b55b45f0f8adbbe6204c3cb328`. The old-host source oracle failures
are fixed locally. Same-artifact modern/macOS14 acceptance remains pending.
Dot owns workflow updates and integration; no shared `rust` publication is
authorized by this record.

## Behavior and preserved boundaries

Grep, Read and Write/Edit use the original Swift
`String(data:encoding:.utf8)` operation. A public Objective-C class method in
`native/source_utf8.swift` performs that operation and copies its UTF-8 result
through a bounded synchronous pointer/length interface. No Swift value or
ownership crosses the ABI. Invalid text, insufficient capacity and a broken
adapter contract have distinct statuses. Rust checks every returned length and
consumes no partial result on failure. Read/Edit expose a distinct internal
`native_utf8_adapter` failure; Grep retains its existing skip-on-read/decode-error
behavior. The adapter accepts at most16MiB; Grep's existing2MiB bound is unchanged.

Already-decoded strings enter Foundation regex and replacement operations as
copied UTF-16 code units. `NSString::from_str` invokes the UTF-8 data initializer,
which stripped another leading BOM on the macOS14 host. This conversion preserves
the existing String, including embedded NUL, without deciding a BOM policy.
The actual Swift runtime chooses the initial data-decoding behavior. No compiler
or OS version heuristic, hard-coded strip/preserve rule, or weakened source
expectation is used.

Path admission, descriptor/regular-file/size checks, cancellation, worker lanes,
native tool gates and authority/vault boundaries remain intact. Validation uses
generated files and in-memory bytes only. No GUI interaction, native capture,
credentials, Keychain, signing or permission acceptance is claimed.

## Native build contract

The target is Apple Silicon macOS with a14.0 minimum. Set
`MACOSX_DEPLOYMENT_TARGET=14.0` for every native Cargo invocation. `build.rs`
requires that explicit value, resolves the selected Xcode Swift compiler and
macOS SDK with `xcrun`, and passes `arm64-apple-macosx14.0` to Swift. A conflicting
`SDKROOT` is rejected. `DEVELOPER_DIR` selects the Xcode installation normally.

The small archive is built in Cargo's `OUT_DIR`. The public Objective-C class is
retained through `static:+whole-archive` linkage, including downstream Rust links
and optimized builds. Swift runtime/compatibility search paths come from
`swiftc -print-target-info`; unsupported metadata fails clearly. No private Swift
ABI export, generated stub, runtime downloader, copied dylib or signing step is
used. Linux targets return from the build script before Apple environment/path
discovery, including `OUT_DIR`; they do not compile or discover Swift. Darwin
cross-host and non-Apple-Silicon targets fail explicitly.

Only the already-locked `serde_json` is reused as a build dependency. The lockfile
is unchanged. Dot retains ownership of `.github/workflows/rust*.yml` and the
matching deployment-target environment setting.

## Validation bundle protocol

From `rust/`, on the modern Apple Silicon builder, using its selected Xcode:

```sh
export MACOSX_DEPLOYMENT_TARGET=14.0
python3 scripts/validate-source-utf8-macos.py build-bundle /tmp/a4-modern-bundle
python3 scripts/validate-source-utf8-macos.py run-bundle /tmp/a4-modern-bundle \
  --receipt /tmp/a4-modern-receipt.json
```

Add `--offline` to `build-bundle` only if Cargo dependencies are already cached.
The destination must not exist. Upload the complete bundle and modern receipt
without rebuilding or modifying its files. Transfer that exact bundle to the
macOS14 Apple Silicon host, preserving executable modes, and run:

```sh
python3 scripts/validate-source-utf8-macos.py run-bundle /tmp/a4-modern-bundle \
  --receipt /tmp/a4-macos14-receipt.json
```

Build mode compiles the actual release core test binary with the adapter and an
independent Swift oracle using the exact source decoding expression. It records
source/toolchain/SDK identities, SHA-256 hashes, deployment target and load
commands. Both binaries must be arm64 with minimum macOS14.0 and only system
runtime dependencies. The Rust release profile uses optimization, thin LTO and
one codegen unit; the class must remain available despite dead-code stripping.

Run mode verifies every bundle file hash and executes only those already-built
binaries. It does not invoke Cargo, Swift, SDK discovery or Git. The Rust ABI
tests and14 decoder cases cover empty/BOM-only, single/double/interior BOM,
embedded NUL, invalid/truncated/overlong/surrogate UTF-8, non-ASCII text and short
versus longer storage. Its results must exactly match the separately compiled
oracle, with the same manifest and executable hashes in both host receipts.
The ABI suite also checks pointer/capacity failures, maximum input, invalid
outputs and injected failure statuses without exposing partial text.

A local-old-toolchain bundle is useful supplementary evidence. It is **not** a
substitute for running the same modern-built artifact on both OS hosts. Matching
rebuilds, a CI badge alone or merely compiling the App do not close that gate.

## Recorded checks and open acceptance

The initial baseline failures are retained in the independently reviewable
[A3 report PR](https://github.com/BelloWare/BelloAgent/pull/2). Original Grep and
Write/Edit expectations remain unchanged. On macOS14.8 (`23J21`), Xcode16.1
(`16B40`), Swift6.0.2, SDK15.1 and Rust1.91.1:

- Initial bridge unit suite:4 passed,0 failed. A subsequent Grep oracle still
  detected the second NSString conversion; the UTF-16 bridge corrected it.
- Expanded source oracle suite: Find/Grep2 passed, Read1 passed, Write/Edit1
  passed. Read compares24 complete JSON results including exact16MiB and
  oversized inputs. Grep adds12 BOM/storage comparisons. Write/Edit adds14
  complete result, written-byte and file-mode comparisons. Existing cases stay.
- A compiled build-script binary with only `CARGO_CFG_TARGET_OS=linux` and a
  minimal environment returned successfully before any Apple lookup. This is
  a guard check, not a Linux Rust suite result.
- Full `cargo test --offline --locked -p bello-agent-core --all-features`:
  562 library tests and133 integration tests passed;0 failed/ignored. Two owned
  subprocess checks repeat individual tests and are not double-counted.
  Core emitted no warnings. `cargo fmt --all -- --check` passed.
- Downstream `cargo build --offline --locked -p bello-agent-app --all-features`
  passed. This compilation includes the existing lifecycle feature's68 legacy
  Objective-C macro configuration warnings on Rust1.91. No App source is changed.
  The linked binary has only system library dependencies and was not launched.
- Local optimized adapter/oracle bundle passed14 exact comparisons and all4 ABI
  tests. Both binary load-command audits passed (arm64, macOS14.0, system-only
  dependencies). This was built locally with Xcode16.1, not on the modern host.
- Linux-target build-script exit and missing deployment target, unsupported
  Darwin target and cross-host rejection controls passed. Full Linux CI,
  modern native CI and same-modern-artifact receipts remain pending.

All native Cargo commands above set `MACOSX_DEPLOYMENT_TARGET=14.0` and used
`CARGO_BUILD_JOBS=2`. Hashes for this local App/core check:

| Item | SHA-256 |
| --- | --- |
| Swift production decoder | `13a81d041366cd12c657eee8bccf25412121d65482643980d9e811de9d613759` |
| Rust adapter including tests | `4d939d0109a6422712724d049e7062f388b3b27a92b999c02299d04d5a05c12e` |
| All-feature App binary | `477f32daa4eae817c2d4179ebd77c057d4e20b85c4887480c3e43a52f39c1453` |
| Full core test log | `3a811e4626b7223ff1f97f930988a8851ca94863ea9e8df6bc065542d3ff4768` |
| App build log | `d054c54621252021e7492102e6c0813ded573e7cc09d0827b7311332ad10ae14` |
| Local optimized bundle manifest (216 frozen source files) | `c691025b5625390a3d0b13bd3f106788575780d8149a98de7ef62ec705fcd5dd` |
| Local optimized Rust probe | `401525353cdfb9cfe771701ab984bb233a59e91c8c2fe81e8637e8836f8589fc` |
| Local independent Swift oracle | `57556b9a0bc1556871850644ced0734d29ff453eebc1642276573698a31ad4a0` |
| Local static Swift archive | `53bb07ce2bcc120d0ee05eb4c95fd18161efd3d04da3cd0c4502b4684cf9a520` |
| Local optimized bundle receipt | `d10f2d77726485f7f92e6a51391e9a3a7e0913b71499b31cec19d06a5c5dd6a1` |

The bundle builder compares all frozen source hashes before and after compilation
and refuses a moving source tree. A separate detecting control appended a byte
to a copied archive; run mode rejected the changed bundle before execution and
created no success receipt. The recorded local manifest identifies the stable
pre-commit worktree contents explicitly; it does not claim the clean6eee base
produced these binaries.

Compared with the exact6eee base, nonblank/non-comment Rust production changes
are net+64 lines; Rust build support+141 and test support+381 are separate.
The Swift production adapter is23 nonblank/non-comment lines. Swift oracle
fixtures and Python bundle tooling are test support, not production Rust.
The count splits the inline `#[cfg(test)]` module into support and includes its
attribute there. These counts establish neither feature completion nor speed.
The tool and vault gates remain independently held. Final bundle manifest and
receipt hashes, exact PR/CI links and any integration reconciliation belong in
the issue handoff.
