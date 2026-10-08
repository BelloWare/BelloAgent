# macOS UTF-8 source parity: A3 investigation

Report-only finding, 2026-10-08, by migration-peer. The unchanged Rust decoder
does not reproduce the checked-in Swift source on this supported macOS 14.8
host. Grep's anchored BOM fixture fails, and the independent Write/Edit oracle
also detects loss of a leading BOM in the edited file. Modern macOS CI passes
both exact tests. This is an unresolved compatibility defect, not permission to
raise the product's macOS 14 minimum or normalize the oracle.

## Scope and identity

- Exact base: `6eee1d06776b18b55b45f0f8adbbe6204c3cb328`.
- Base tree: `9de46a57039fce8e06973ff8d8578d25438bc441`.
- [Acknowledged claim](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6052838788)
  and [report-only direction](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6052896580).
- This delivery changes only this report. Production Rust delta: **0**;
  Rust test/support delta: **0**. Temporary probe code reproduced below is
  documentation, not compiled repository code.
- Production, the original Swift source, oracle drivers/assertions, workflows,
  minimum OS and all native/tool/vault gates remain unchanged. Read/Edit was
  inspected and its existing test run without source edits.

The root README explicitly describes macOS 14+ / Apple Silicon. The Rust
workflow's newer runner does not replace that product compatibility contract.

## Exact environments and outcomes

| Property | Local reproduction | Existing exact-base CI |
| --- | --- | --- |
| macOS | 14.8, build 23J21, arm64 | 26.6.2, build 25G83, arm64 |
| Xcode | 16.1 | 26.6, build 17F113 |
| SDK | 15.1 | 26.5 |
| Swift compiler | Apple Swift 6.0.2, swiftlang-6.0.2.1.2 / clang-1600.0.26.4 | Not printed in the job log |
| Oracle language mode | `-swift-version 5` | Same checked-in test invocation |
| Rust | Homebrew 1.91.1 | Pinned 1.99.0 |
| Find/Grep source oracle | FAIL at BOM case | PASS twice |
| Write/Edit source oracle | FAIL at case 17 file bytes | PASS twice |

CI evidence is [run 37723409432, job 113136003324](https://github.com/BelloWare/BelloAgent/actions/runs/37723409432/job/113136003324),
attempt 1, head exactly the base above. Find/Grep passed at 03:42:21 and
03:44:32 UTC; Write/Edit passed at 03:42:37 and 03:44:48 UTC. The runner image
was `macos-26-arm64`, version `20260907.0351.1`.

The BOM case was executed in CI; it was not skipped. Both jobs use the same
checked-in fixture and source extraction. Green CI therefore establishes parity
on that modern runner, while lacking coverage of the supported older runtime.
It does not establish an OS version cutoff, nor isolate compiler versus SDK
versus runtime effects. No modern-built probe was run on macOS 14 in this work.

## Reproduction on the unchanged base

From `rust/`, using an isolated Cargo target directory and two build jobs:

```sh
cargo test --offline --locked -p bello-agent-core --all-features --test find \
  native_find_and_grep_match_the_current_swift_source_on_macos -- --exact --nocapture
cargo test --offline --locked -p bello-agent-core --all-features --test write_edit \
  native_write_edit_match_current_swift_source_and_file_effects -- --exact --nocapture
```

Both commands completed with exit 101. The first compiled in 7.45 seconds and
ran for 4.22 seconds; the second compiled in 1.05 seconds and ran for 3.44 seconds.
The existing timeout bounds, exact JSON/file comparisons and error handling
were retained. Only generated files/processes were used, with no app launch,
provider, credentials, Keychain, capture or permission changes.

### Grep

`tests/find.rs:379`, case `UTF-8 BOM decoding`: the file named `bom` contains
`ef bb bf 6e 65 65 64 6c 65`; the regex is `^needle$`.

```text
Rust:  "bom:1: needle\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]"
Swift: "\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]"
```

Swift's `String(data:encoding:.utf8)` preserves U+FEFF here. The anchored pattern
does not match that first character. Rust's `NSString::initWithData_encoding`
removes the leading UTF-8 BOM before matching. File acquisition and regex
assertions need no alteration to expose this discrepancy.

### Write/Edit, assessed without editing those paths

`tests/write_edit.rs:328`, case 17, compares the actual written bytes with the
independently extracted Swift tool's file effects. Initial bytes encode
`U+FEFF + é + LF`; arguments replace `é` with decomposed `e + U+0301`.

```text
Rust:  [101, 204, 129, 10]                # 65 cc 81 0a
Swift: [239, 187, 191, 101, 204, 129, 10] # ef bb bf 65 cc 81 0a
```

The shared `src/tools/read/macos.rs::decode_utf8` uses the same NSString decoder.
Read calls it directly; Edit and Write's previous-content bookkeeping call it
through `src/tools/edit/macos.rs::FoundationFiles::read_text`. Source `Tools.swift`
uses `String(data:encoding:.utf8)` at lines 289, 292, 349 and 394 for Write, Edit,
Read and Grep respectively.

Consequences supported by this evidence: Edit demonstrably changes BOM bytes
differently on this host; Read's decoder would omit the initial U+FEFF; Write's
previous-content diff/statistics can differ. The latter two tool-level outcomes
were not separately exercised. Some unit tests calculate their expected value
with the same Rust helper, so their success alone cannot establish source parity.
The independent Write/Edit integration oracle does catch this defect.

## Decoder characterization and upstream evidence

The standalone probe below writes generated bytes, reads through FileHandle,
and reports exact UTF-8 bytes from Swift/Data, Swift/bytes and NSString decoding.
All ten cases completed locally. `nil` means decoding was rejected, not empty.

| Input | Swift/Data and Swift/bytes | NSString |
| --- | --- | --- |
| Empty | Empty | Empty |
| `efbbbf` | `efbbbf` | Empty |
| `efbbbf` + `needle` | All input bytes | `needle` |
| Two leading BOMs + `needle` | Both BOMs retained | First BOM removed |
| `a` + BOM + `needle` | All input bytes | All input bytes |
| BOM + `ff` | `nil` | `nil` |
| BOM + `00 61` | BOM and NUL retained | BOM removed, NUL retained |
| BOM + 12, 13 or 29 ASCII bytes | BOM retained in all three | First BOM removed in all three |

[Swift Foundation PR 1165](https://github.com/swiftlang/swift-foundation/pull/1165),
merged 2025-02-13, changed Swift UTF-8 decoding to discard one initial BOM while
retaining an interior U+FEFF. The [implementation commit](https://github.com/swiftlang/swift-foundation/commit/7aacaff577c4dbbf4017e2c0f8eafe8505b209bf)
removes the initial three bytes before UTF-8 conversion and adds regression
coverage. This supports the observed old/new Foundation behavior, but is not an
Apple OS availability contract. No exact deployment-version boundary is inferred.

Unconditionally preserving the BOM in Rust would fix the demonstrated old-host
case while disagreeing with the observed modern Swift oracle. Unconditionally
stripping it is the present old-host bug. Stripping output in the oracle would
hide observable file contents and is not a solution.

## Compatibility approach proposed for review

No production Swift bridge or `build.rs` was found in the Rust crates at this
base. The macOS adapters use Objective-C Foundation through `objc2`; Swift
compiler invocations found in core are test-oracle compilation. The existing
Swift helper is a separate application component, not a linked Rust decoder.

A runtime capability check can measure the relevant property **only by executing
the actual Swift decoder**: decode `ef bb bf 61` and inspect `String.utf8` as
length-delimited bytes. This returns preserve/drop/unknown without an OS guess.
The existing NSString API alone cannot distinguish the two observed behaviors;
it strips on the local host and agrees with the stripping modern source case.
Do not use undocumented symbols, framework version heuristics, or `xcrun` at
customer runtime. A build-time result also cannot classify a different deployment
host.

The smallest semantics-preserving approach worth reviewing is a tiny compiled
Swift C-ABI adapter that directly calls `String(data:encoding:.utf8)` and returns
its `.utf8` bytes to Rust. It avoids recreating Foundation semantics from a
single BOM flag. The decoder can be shared by Grep and Read/Edit under a new
explicit claim. It need not launch the Swift helper or load project/provider
state. The current bounded native read, cancellation, worker ownership, regular
file checks, tool admission and error mapping must stay in Rust unchanged.

The temporary prototype below validates feasibility on this local toolchain:
Rust calls a compiled Swift library, all ten outputs exactly match the independent
Swift/Data probe, and three null/empty/capacity checks pass. Its capability probe
returns `0` (preserves). This is **not** a production-ready adapter, shipped
artifact, modern-runtime proof, or passing repository oracle after a fix.
The prototype's underscored `@_cdecl` spelling and dynamic library layout are
experimental choices requiring toolchain/ABI review; no new build dependency
has been introduced by this report.

Before implementation, dot should review a separate scope covering a macOS-only
bridge/build integration and shared decoder, then acknowledge exact files. The
current four-path claim does not authorize new build machinery or Read/Edit
edits. Required design/acceptance points are:

1. Compile the adapter with the shipped product's toolchain and deployment target;
   retain the macOS 14 baseline. Review linkage/runtime dependency availability
   and packaging without requiring a compiler on the end user's machine.
2. Use an explicit byte-pointer/length ABI with caller-owned buffers and distinct
   invalid-UTF8, capacity and internal-failure results. Never pass Swift objects
   across the boundary or use C-string length for data containing NUL. Preserve
   existing 2 MiB Grep and 16 MiB Read/Edit bounds. Review allocation/copy costs.
3. Run the **same shipped build** on a supported macOS 14 host and the modern CI
   host, against independently compiled source oracles with recorded Swift/SDK
   identities. Also characterize at least single, double and interior BOM, BOM
   only, NUL, invalid UTF-8 and short/long storage forms. Do not assume a cached
   BOM flag fully specifies all Foundation decoding behavior.
4. Keep the current anchored Grep result and written-file-byte assertions exact.
   Add source-based Read coverage and appropriate Write prior-content cases in
   the separately claimed scope. Existing Read/Edit helper-derived expectations
   are not sufficient on their own.

If a Swift dependency is rejected, a pure Rust implementation needs an explicit,
evidence-backed supported-runtime contract and an independently justified way to
select it. This investigation has not established such a selector. Raising the
minimum OS or replacing expected Swift results is not an approved fallback.

## Verification record

- FAIL: unchanged exact Grep source oracle on macOS 14.8 (BOM anchored result).
- FAIL: unchanged exact Write/Edit source oracle on macOS 14.8 (case 17 bytes).
- PASS: ten generated FileHandle/Swift/NSString characterization cases.
- PASS: temporary Rust-to-Swift ABI prototype, ten exact byte comparisons and
  three boundary checks on macOS 14.8 / Xcode 16.1.
- Historical PASS: both unchanged source oracles on exact-base macOS 26.6.2 CI.
- NOT RUN: this prototype on modern macOS; modern-built prototype on macOS 14;
  complete repository suites; packaging/release/native interactive acceptance.

No production fix is claimed. The existing failures remain visible until a
reviewed compatibility implementation passes both supported environments.

## Source and evidence hashes (SHA-256)

Repository paths below are unchanged at the exact base. The generated Find
oracle was obtained by evaluating the test's actual `oracle_source()` extraction;
its UTF-8 source is 43,967 bytes. This locally calculated hash was not separately
printed by historical CI.

| Path | SHA-256 |
| --- | --- |
| `rust/crates/bello-agent-core/src/tools/grep/macos.rs` | `f9e08ddac0f7040e7f6cdb04386196afc5a202e88fc60cfb996100657b6bd9dd` |
| `rust/crates/bello-agent-core/src/tools/read/macos.rs` | `d6998bd7877382a553299d517279707538b2e539f120b61276aa4440d2e78fc2` |
| `rust/crates/bello-agent-core/src/tools/edit/macos.rs` | `eb3b8e8bc7f021c5867a8a5fe16c69919dfa656e51bad6873a2e8c4c5d2c778f` |
| `rust/crates/bello-agent-core/tests/find.rs` | `bc52e732bc5df9ec261774b841eaf454e09c0492c31f1ce4acf50999f65b700e` |
| `rust/crates/bello-agent-core/tests/fixtures/find_oracle.swift` | `4aca9a4c257047ba091371a11195e85735cf5ecac82f14bc17fc20b98ffbeaa5` |
| `rust/crates/bello-agent-core/tests/write_edit.rs` | `3c89457f03fcc21e662df6bf1454a06866785b7168aefb85c48e548524ed4fbe` |
| `packages/swift-host/Sources/PiAgentCore/Tools.swift` | `73ef1d04f13fab1c651550135d9c3d957c7f5f6f0afa6b26daa6df77b4248060` |
| `packages/swift-host/Sources/PiAgentCore/Support.swift` | `74b8eae612e2a7d7a09b2d3df6f663f21e252ba94b81df6de189a567dac59f0e` |
| Generated Find oracle | `8900ac56c8b620e8ee029f8783fbe5c7a119b8e639ac71a3b13000e93f0c9792` |

The following temporary evidence hashes identify the local run; raw logs are
local artifacts, while the failure excerpts and complete characterization
sources/results are retained in this report. Binary hashes identify this
particular experiment only and are not release attestations.

| Evidence | SHA-256 |
| --- | --- |
| Find failure log | `b8cb06f7b5460791bc2341e77208c63c870093b750fda499795d8bc1b887b961` |
| Write/Edit failure log | `89299af91f1c1a7aee52f253c4188128fdd7d71bd1346175e35d1947525a9b20` |
| Swift characterization source | `04193b26a5cb246fe365bebac725212246804cd6644965bcfb89dac1e6a4a0de` |
| Swift characterization JSONL | `82f9ea0ce28a4b613bfe09df94a1834cf5a94488ed6c68a9c31d4740ec717f9d` |
| ABI Swift source | `e776848d12cd65da4eb4f852a4643665bcc32498f3a8b240fe33336001589dfd` |
| ABI Rust driver | `0c8f58ddfdf7d0b6bd5b1e5e2e74cf155785ab8a5647a373e3efd7c4465fd462` |
| ABI Swift library | `2f07008de61a3a14f73e0e0e5b360901f98a61eb0236c7dad7ee7cf41f8ff86b` |
| ABI Rust executable | `3da858927645734d807e3abf9f870526cbcef7a8245aac70ed099d1528b677db` |

## Reproducible temporary probes

Create a fresh temporary directory outside the repository, save the following
sources there, and compile with the selected Xcode toolchain. `probe.swift`
expects an existing temporary fixture directory as its first argument. No
existing user file is read. Example commands, with `A3_DIR` set to that directory:

```sh
mkdir -p "$A3_DIR/fixtures"
xcrun swiftc -swift-version 5 -module-cache-path "$A3_DIR/cache" \
  "$A3_DIR/probe.swift" -o "$A3_DIR/probe"
"$A3_DIR/probe" "$A3_DIR/fixtures"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -parse-as-library -emit-library -module-name A3Probe \
  -module-cache-path "$A3_DIR/cache" "$A3_DIR/bridge.swift" \
  -o "$A3_DIR/liba3swift.dylib"
rustc --edition=2024 "$A3_DIR/driver.rs" -L "native=$A3_DIR" \
  -C "link-arg=-Wl,-rpath,$A3_DIR" -o "$A3_DIR/driver"
"$A3_DIR/driver"
```

### FileHandle and independent decoder probe: `probe.swift`

```swift
import Foundation
import CoreFoundation
let cases: [(String, [UInt8])] = [
("empty", []), ("bom", [0xef,0xbb,0xbf]),
("bom-needle", [0xef,0xbb,0xbf]+Array("needle".utf8)),
("double-bom", [0xef,0xbb,0xbf,0xef,0xbb,0xbf]+Array("needle".utf8)),
("interior-bom", Array("a".utf8)+[0xef,0xbb,0xbf]+Array("needle".utf8)),
("invalid", [0xef,0xbb,0xbf,0xff]),
("nul", [0xef,0xbb,0xbf,0,0x61]),
("bom-15", [0xef,0xbb,0xbf]+Array(repeating:0x61,count:12)),
("bom-16", [0xef,0xbb,0xbf]+Array(repeating:0x61,count:13)),
("bom-32", [0xef,0xbb,0xbf]+Array(repeating:0x61,count:29))]
func hex(_ text: String?) -> String { text.map { $0.utf8.map { String(format:"%02x",$0) }.joined() } ?? "nil" }
for (name,bytes) in cases {
 let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
 try Data(bytes).write(to:url)
 let file=try FileHandle(forReadingFrom:url)
 let data=try file.read(upToCount:1024) ?? Data()
 try file.close()
 let n=NSString(data:data,encoding:String.Encoding.utf8.rawValue).map { $0 as String }
 let output:[String:String] = ["case":name,"input":bytes.map{String(format:"%02x",$0)}.joined(),"swiftData":hex(String(data:data,encoding:.utf8)),"nsString":hex(n),"swiftBytes":hex(String(bytes:bytes,encoding:.utf8))]
 print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)
}
```

### Observed local output

```jsonl
{"case":"empty","input":"","nsString":"","swiftBytes":"","swiftData":""}
{"case":"bom","input":"efbbbf","nsString":"","swiftBytes":"efbbbf","swiftData":"efbbbf"}
{"case":"bom-needle","input":"efbbbf6e6565646c65","nsString":"6e6565646c65","swiftBytes":"efbbbf6e6565646c65","swiftData":"efbbbf6e6565646c65"}
{"case":"double-bom","input":"efbbbfefbbbf6e6565646c65","nsString":"efbbbf6e6565646c65","swiftBytes":"efbbbfefbbbf6e6565646c65","swiftData":"efbbbfefbbbf6e6565646c65"}
{"case":"interior-bom","input":"61efbbbf6e6565646c65","nsString":"61efbbbf6e6565646c65","swiftBytes":"61efbbbf6e6565646c65","swiftData":"61efbbbf6e6565646c65"}
{"case":"invalid","input":"efbbbfff","nsString":"nil","swiftBytes":"nil","swiftData":"nil"}
{"case":"nul","input":"efbbbf0061","nsString":"0061","swiftBytes":"efbbbf0061","swiftData":"efbbbf0061"}
{"case":"bom-15","input":"efbbbf616161616161616161616161","nsString":"616161616161616161616161","swiftBytes":"efbbbf616161616161616161616161","swiftData":"efbbbf616161616161616161616161"}
{"case":"bom-16","input":"efbbbf61616161616161616161616161","nsString":"61616161616161616161616161","swiftBytes":"efbbbf61616161616161616161616161","swiftData":"efbbbf61616161616161616161616161"}
{"case":"bom-32","input":"efbbbf6161616161616161616161616161616161616161616161616161616161","nsString":"6161616161616161616161616161616161616161616161616161616161","swiftBytes":"efbbbf6161616161616161616161616161616161616161616161616161616161","swiftData":"efbbbf6161616161616161616161616161616161616161616161616161616161"}
```

### Temporary C-ABI adapter: `bridge.swift`

```swift
import Foundation

// Temporary characterization only; not a production API.
@_cdecl("a3_bom_policy")
public func a3BomPolicy() -> Int32 {
    let input: [UInt8] = [0xef, 0xbb, 0xbf, 0x61]
    guard let text = String(data: Data(input), encoding: .utf8) else { return -1 }
    let bytes = Array(text.utf8)
    if bytes == input { return 0 }
    if bytes == [0x61] { return 1 }
    return -1
}

@_cdecl("a3_decode_utf8")
public func a3DecodeUTF8(_ input: UnsafePointer<UInt8>?, _ count: Int,
                       _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    guard count >= 0, count <= 16 * 1024 * 1024, capacity >= 0,
          count == 0 || input != nil else { return -2 }
    let data = count == 0 ? Data() : Data(bytes: input!, count: count)
    guard let text = String(data: data, encoding: .utf8) else { return -1 }
    let bytes = Array(text.utf8)
    guard bytes.count <= capacity else { return -3 }
    guard bytes.isEmpty || output != nil else { return -2 }
    if !bytes.isEmpty { bytes.withUnsafeBufferPointer { output!.update(from: $0.baseAddress!, count: $0.count) } }
    return bytes.count
}
```

### Temporary Rust caller: `driver.rs`

```rust
#[link(name = "a3swift")]
unsafe extern "C" {
    fn a3_bom_policy() -> i32;
    fn a3_decode_utf8(input: *const u8, count: isize, output: *mut u8, capacity: isize) -> isize;
}
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }
fn main() {
    eprintln!("bom_policy={}", unsafe { a3_bom_policy() });
    let cases: &[(&str, &[u8])] = &[
        ("empty", &[]),
        ("bom", &[239,187,191]),
        ("bom-needle", &[239,187,191,110,101,101,100,108,101]),
        ("double-bom", &[239,187,191,239,187,191,110,101,101,100,108,101]),
        ("interior-bom", &[97,239,187,191,110,101,101,100,108,101]),
        ("invalid", &[239,187,191,255]),
        ("nul", &[239,187,191,0,97]),
        ("bom-15", &[239,187,191,97,97,97,97,97,97,97,97,97,97,97,97]),
        ("bom-16", &[239,187,191,97,97,97,97,97,97,97,97,97,97,97,97,97]),
        ("bom-32", &[239,187,191,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97,97]),
    ];
    for (name, input) in cases {
        let mut output = vec![0u8; input.len() * 3 + 16];
        let count = unsafe { a3_decode_utf8(input.as_ptr(), input.len() as isize,
                                           output.as_mut_ptr(), output.len() as isize) };
        let result = if count == -1 { "nil".to_owned() } else {
            assert!(count >= 0 && count as usize <= output.len());
            hex(&output[..count as usize])
        };
        println!("{}\t{}", name, result);
    }
    assert_eq!(unsafe { a3_decode_utf8(std::ptr::null(), 1, std::ptr::null_mut(), 0) }, -2);
    assert_eq!(unsafe { a3_decode_utf8(b"a".as_ptr(), 1, std::ptr::null_mut(), 0) }, -3);
    assert_eq!(unsafe { a3_decode_utf8(std::ptr::null(), 0, std::ptr::null_mut(), 0) }, 0);
}
```

The caller reports `bom_policy=0` on stderr and prints the same ten decoded
hex results as the `swiftData` column above. Exact comparison by case name with
the independent probe passed for all ten rows. Compilation, linking, execution
and all three boundary assertions completed with exit 0.
