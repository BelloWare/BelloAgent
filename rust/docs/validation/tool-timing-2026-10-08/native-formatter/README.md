# Native formatter oracle

Source and execution: [migration-peer report](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6068923733), exact Swift main `f4f80ddda3c27fac9e266896f69b725a06242e8f`.
The peer ran the unchanged extracted formatter/display validator/elapsed helper on
macOS 14.8 arm64 with Swift 6.0.2. The controlled ToolView/outcome shim only proves
threshold/running guards, not full UI classification or interactive GUI behavior.

The portable Swift harness, complete48-case inputs and raw outputs were extracted
from that comment with their trailing LF preserved. Their byte sizes and SHA256
hashes match the peer receipt. The three production bodies were independently
re-extracted from exact Git objects and match both receipt hashes and the harness.
Native execution, compiler environment and native binary identity are peer-attested;
the Linux coordinator did not run that native binary.

The local `oracle-comparison.rs` uses byte-for-byte current Rust production
formatting/elapsed functions and a minimal DurationUs.get() adapter. Its36
representable nonnegative microsecond cases match native output and terminal-row
thresholds. This caught four errors in an earlier integer-half-up proposal:
150ms→0.1s,250ms→0.2s,350ms→0.3s,850ms→0.8s. The adopted subsecond formatter follows
binary64 decimal formatting; whole-unit arithmetic remains overflow-safe.

The twelve other native cases are preserved, not coerced into unsigned Rust
microseconds: missing, negative/negative-zero, nonfinite and above-range values.
The source's 18446744073709552ms case lies just outside UInt64 microseconds; its
similar display to UInt64.max is not an exact-input equivalence claim. Invalid
Rust JSON numbers are rejected and checked runtime conversion overflow is unknown.

No runtime speed, macOS interactive GUI, signing/TCC/AX/Keychain or release claim
follows from formatting agreement. See verification.json for exact scope.
