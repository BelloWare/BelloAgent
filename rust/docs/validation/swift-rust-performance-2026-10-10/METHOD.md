# Swift vs Rust on the same Mac — method (2026-10-10)

## Machine

Apple M3 Max **virtual machine** (10 vCPU, 16 GB), macOS 14.8 (23J21), one
"Apple Virtual" display 1728×992 pt @2x, 60 Hz, paravirtualized GPU. Xcode 16.1,
Swift 6.0.2, Rust 1.99.0 (official toolchain). Other resident load during runs:
a Python agent process (~8–13% of one core), ChatGPT app idle. Results are valid
for this VM; physical Macs (ProMotion, native GPU) may differ.

## Binaries

| App | Binary | Identity |
|---|---|---|
| Swift Bello Agent 0.1.122 | shipped DMG (Developer ID, notarized) | DMG SHA-256 `f0e0fd4a…48ae1` = release record |
| Swift Bello Box 0.0.77 | shipped DMG (Developer ID, notarized) | DMG SHA-256 `75800c74…ff56d` = website release commit `56cbc33` |
| Rust BelloAgent | `cargo build --locked --release -p bello-agent-app` (thin LTO, 1 CGU, default features) at `973e7bed` | see `binaries.sha256` |
| Rust BelloBox | `cargo build --locked --release -p bellobox-app` at `1ecbaa3d` | see `binaries.sha256` |

The Rust apps are bare executables (not app bundles, unsigned); the Swift apps run
from their signed bundles. All four are started by direct `exec` (no LaunchServices),
so the comparison excludes LaunchServices/Gatekeeper first-launch costs.

## Isolation and owner data

- Swift Agent: `PI_APP_BENCHMARK_STATE_ROOT` (scratch state root) and
  `PI_APP_BENCHMARK_OUTPUT`; its Keychain vault is the owner's (owner-approved
  2026-10-10); no message was sent.
- Swift Box: run under `sandbox-exec` with Keychain IPC denied
  (`harness/no-keychain.sb`), because the shipped app blocks its main thread at
  launch on a Keychain read that prompts for the login password on this Mac.
  Control: Rust Box was also run under the same profile (`rust-box-sandboxed`).
- Both Swift preference domains and their HTTP/cache folders were backed up
  before and restored after every run; restoration is checked semantically.
- Rust Agent: scratch `HOME` (all Rust data is under `$HOME`), empty project.
  Rust Box: scratch `BELLOBOX_CONFIG_DIR`.

Visible state at launch: Swift Agent shows its workspace without a selected chat
(scratch state root); Rust Agent shows a disconnected empty project; both Boxes
show Home. Window sizes are each app's default (Swift Agent 1240×828, Rust Agent
1280×868, both Boxes 1000×788, including title bars).

## Metrics (harness/belloperf.swift)

- **window**: process spawn → first on-screen layer-0 window of the process
  (CGWindowList polled every 4 ms).
- **settled**: last frame change touching ≥0.5% of the window's pixels before a
  1.5 s quiet period (window images via CGWindowListCreateImage every ~25 ms).
  This is window-server composited content, not physical scanout.
- **idle CPU**: process-tree CPU time over 20 s (warm) / 10 s (cold), starting
  2 s after settling, as a percentage of one core.
- **footprint**: physical footprint (`ri_phys_footprint`, Activity Monitor's
  "Memory", includes GPU/IOSurface memory owned by the process); **RSS** for
  reference; **peak footprint** = lifetime maximum.
- **warm**: repeated launches with file caches populated (one unmeasured priming
  launch per app first). **cold**: `sudo purge` before each launch.
- Trials are interleaved across apps with alternating order; nearest-rank
  percentiles; every raw trial is retained in `raw/`.

## Not measured here

Input latency, streaming, scrolling, search and image/GIF workflows are separate
runs. Rendering cost per frame and frame pacing are not captured by this method.
