# M0 validation — 2026-09-14

Build: Pi App 0.0.3 (3), Release, Swift 6 / Xcode 16.1 (16B40), macOS 14.8
(23J21). Machine: VirtualMac2,1, Apple M3 Max (Virtual), 16 GiB RAM. These
measurements describe this VM, not physical-Mac battery life or universal
performance.

## Provider and transport gate

50 host tests pass with the real published Pi 0.85.1 adapters and Node 24.21.0.
Fixtures cover both APIs' tools, text/thinking/argument streaming, split Unicode,
manual/automatic/failed compaction, persisted opaque continuation and resume,
HTTP errors, stream errors, retry attempts, cancellation before/after content and
during tools, independent sessions, overlapping main compaction/side requests,
oversized unknown events, bounded capture, eviction and recorder failures.
The fixture server's received/emitted bytes and hashes are compared with the
actual fetch-boundary captures. No live paid provider request was needed.

The pinned SDK differences and reader cleanup correction are documented in
[Compatibility.md](Compatibility.md). A simulated recorder failure is not an
actual disk-full persistence test; that M2 gate remains required.

## Native, packaging and signing gate

- 6 native tests and 7 release/signature tests pass.
- Native SwiftUI/AppKit shell launches the bundled Node executable through
  anonymous pipes, with an explicit environment and absolute executable path.
- Packaged smoke test runs outside the repository with system-only PATH,
  verifies both real adapters/tool cycles and exact bytes, emits no stderr,
  and exits cleanly on stdin EOF. It also passes after Developer ID signing.
- React 19.3.0 / TypeScript transcript loads from scoped bundled files into one
  nonpersistent WKWebView. The native identity/sequence acknowledgment verifies
  both directions of the bridge. Both provider results are visible in the
  signed app launched through macOS Launch Services.
- Node alone receives `com.apple.security.cs.allow-jit`. Six nested host
  Mach-O dependencies are separately signed. Native UI entitlements remain
  empty; Release hardened runtime is enabled. Strict signatures pass.
- Apple accepted application submission
  `03cac54e-af53-4934-9706-3f00fd2010af` and DMG submission
  `440166ae-aec4-42a6-a5b6-b785a8a8373a`. Both are stapled. Gatekeeper reports
  **Notarized Developer ID** for the app. The DMG's Ed25519 signature verifies
  independently against its 179,906,372 bytes.
- This M0 verification installer is staged locally. The production update feed
  remains on the already-verified dummy 0.0.2 until a later release is published.

## Measured baseline and release budget

The identified process set was native PID 73271, Node 73276, and newly created
WebKit WebContent/Networking/GPU PIDs 73275/73277/73278. The earlier debug app
and all three of its WebKit processes were gone before launch. Unrelated
Safari, ChatGPT and the old dummy app were excluded.

| Release state | Aggregate mean RSS | Aggregate peak RSS | Interval |
| --- | ---: | ---: | ---: |
| Connected, before Pi adapter imports | 211.24 MiB | 211.27 MiB | 5.19 s / 6 samples |
| Idle after both provider/tool checks | 353.98 MiB | 354.02 MiB | 62.48 s / 61 samples |

Post-check aggregate idle CPU was **0.032% of one core**, computed from process
CPU-time deltas over the interval, rather than `ps`'s lifetime average. RSS is
summed conservatively; shared pages may be counted more than once. The fixture
sessions have been disposed, so this is the loaded-runtime baseline, not a
capture-budget-exhaustion benchmark. Capture mode during checks was Session
memory with the normal limits; there was no trace persistence.

M0 fixes the M5 release gate for **one active workspace, main plus one visible
side** at **800 MiB sustained aggregate RSS and 1 GiB transient peak**. This
leaves approximately 446 MiB above the measured baseline for the second pane,
active contexts, tool output and the unchanged 128 MiB capture allocation cap.
Additional workspaces must have an explicit app concurrency budget; they are
not silently excluded from total memory accounting.

M5 must still prove these limits under the required 10,000-message, 1 MiB
response, 50 MiB tool output, two-stream, capture exhaustion and 100-history-
open/close scenarios. Typing/render latency and warm/cold timings need their
own distributions. This baseline is not a claim that those gates already pass.

Reproduce with `scripts/smoke-bundle.mjs` and `scripts/measure-processes.py`.
Identify the app's current process set before sampling; do not reuse these PIDs.
Keep measurement JSON and build products under `PI_BUILD_ROOT`/session scratch.
