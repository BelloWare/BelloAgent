# A4 same-bundle native decoder receipts

## Attribution and scope

These are the original JSON receipt bytes published by **migration-peer** in [BelloAgent issue comment 6067113669](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6067113669). Native execution belongs to the peer's report. This package independently audits the published receipt bytes and their internal consistency; its verifier did **not** execute either native binary.

The peer attributes both runs to the same modern-built A4 bundle from [run 37825970758, attempt 1 / job 113478806375](https://github.com/BelloWare/BelloAgent/actions/runs/37825970758/job/113478806375), source commit `a80b8719771d23156e1547bd9c7b67e84352c06c`, tree `842fcd81bb3b286b8e81f560657a3274d9142309`. The commit-to-tree mapping was independently checked against available Git objects. The peer used a later transport-helper repair only for extraction; that is not a claim that the bundle was rebuilt from that later revision.

## Independently verified from the published bytes

- `modern-host-receipt.json`: 5,641 bytes; SHA-256 `21229ea4f64c14bca0a23326f6ef81053e9b820beaa802384c9ceb829aec0a11`.
- `macos14-host-receipt.json`: 5,783 bytes; SHA-256 `99cd77c772316cc659f4a369eceb1e9117432bc3e791ee25c8cfd9c931b63129`.
- Both exactly match the peer's reported hashes. JSON formatting and the single terminal newline were retained, rather than parsing and reserializing.
- Each receipt contains 14 unique, identically paired test inputs and `actual == expected`, with `passed: true`.
- The embedded decoder output matches each receipt's `actual` array. Each embedded test log reports four tests passed, zero failed, zero ignored. These four tests include the receipt test and three decoder/ABI safety tests; they are not four additional ABI tests beyond the receipt test.
- Both probe and oracle stderr strings are empty.
- Both receipts name manifest SHA-256 `3e03233e43062a1b7c96d279393af5838a5a457e6b6cef54c59b1b99549118a5` and exactly the same six bundle-file hashes.
- The host fields identify arm64 macOS 26.6.2 (25G83) and arm64 macOS 14.8 (23J21).
- Exactly eight case outputs differ across hosts: `bom`, `single`, `double`, `nul`, `unicode`, `bom15`, `bom16`, `bom32`. In each, the modern receipt removes one leading BOM and the macOS 14 receipt preserves it. Each agrees with its own host's reported Swift oracle. Cross-host output equality is intentionally not required.

## Peer-reported assertions not independently recomputed here

The complete raw job log, archive, manifest bytes, build metadata bytes, and native executables were not supplied in the saved comment and are not included in this package. Accordingly, this audit cannot recompute:

- The 8,022,546-byte raw-log hash `ea0e043ba02797c015ef677a24e61774fc5adfcc34237cb5f072cf8e0e29f49b`.
- The 4,696,612-byte archive hash `eb5e9dabaafb0ab5f294bef0341ce4da7ad2a3c7204584bc87745229efeb15b4`, all 510 chunks, safe extraction checks, or the 18 peer-run transport controls.
- The manifest's cryptographic link to the A80 build source, clean checkout, toolchain versions, and modern build host. The Git source identity itself is verified; the actual build linkage remains peer-attested.
- The binary hashes, Mach-O linkage/deployment audit, local exit status, no-rebuild execution, or unchanged-before/after bundle assertions.

Matching receipt digests and file maps establish exact retention and consistent identity claims. They do not substitute for possession and independent hashing of the referenced artifacts, or independent native execution.

This is a scoped A4 same-bundle decoder evidence package. It makes no wider migration or unrelated CI acceptance claim.

## Retained files

- `modern-host-receipt.json` and `macos14-host-receipt.json`: original receipt bytes.
- `verification.json`: receipt checks, identities and explicit limitations.
- `SHA256SUMS`: hashes of these retained files and this report.

The original peer comment is linked above; the validator source remains available
at the cited immutable A80 commit.
