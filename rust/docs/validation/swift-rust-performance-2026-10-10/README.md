# Swift vs Rust performance on the same Mac — 2026-10-10

First same-machine comparison of the shipped Swift apps against Rust release
builds. Method, isolation and metric definitions: [METHOD.md](METHOD.md).
Raw trials: `launch/raw/`, `microbench/r*/`, `idle/`. Harness sources: `harness/`.

## Results

### Launch, idle CPU and memory (end-to-end, external measurement)

Interleaved trials; warm n=8, cold n=5 (`sudo purge` before each); p50 [min–max].

| App | Launch | First window (ms) | Visually settled (ms) | Idle CPU (% of one core) | Physical footprint (MB) |
|---|---|---|---|---|---|
| Swift Agent 0.1.122 | warm | 211 [197–222] | 307 [293–331] | 0.01 [0.01–0.02] | 25.1 [24.3–25.8] |
| Rust Agent `973e7bed` | warm | 154 [134–160] | 154 [134–160] | 0.46 [0.45–0.47] | 78.4 [74.6–78.8] |
| Swift Box 0.0.77 | warm | 570 [558–594] | 570 [558–594] | 0.02 [0.02–0.03] | 28.9 [28.5–29.7] |
| Rust Box `1ecbaa3d` | warm | 169 [162–177] | 169 [162–177] | 0.48 [0.47–0.52] | 124.3 [120.2–125.2] |
| Rust Box, same sandbox as Swift Box (control) | warm | 174 [162–199] | 174 [162–199] | 0.49 [0.48–0.53] | 124.3 [107.8–124.8] |
| Swift Agent | cold | 966 [821–1066] | 1344 [1124–1388] | 0.02 | 24.0 |
| Rust Agent | cold | 687 [521–725] | 687 [521–725] | 0.47 | 78.4 |
| Swift Box | cold | 1526 [1473–1574] | 1526 [1473–1574] | 0.02 | 28.6 |
| Rust Box | cold | 728 [652–842] | 851 [729–945] | 0.50 | 120.4 |

Interpretation:

- Rust shows a complete first window sooner. Swift Box's figure includes a
  deliberate 300 ms `asyncAfter` before it opens its main window
  (`BelloBoxApp.swift`), so the framework difference for Box is smaller than the
  table suggests. The sandbox control shows the Keychain-denial profile itself
  costs ~5 ms.
- Rust uses **25–50× more idle CPU** (0.46–0.50% vs 0.01–0.02% of one core) and
  **3–4× more memory** as Activity Monitor reports it. RSS points the other way
  (Swift 67–78 MB vs Rust 52–54 MB) because RSS counts shared system-framework
  pages; footprint is the user-visible figure.
- Idle diagnosis (`idle/`): with `BELLO_PERF_LOG` the Rust apps performed **zero**
  render callbacks during 10 s of idle, yet `top` shows ~63 wakeups/s — GPUI
  0.2.2 keeps a `CVDisplayLink` running for every visible window and calls its
  frame callback at the display rate (60 Hz here) even when nothing is dirty.
  Footprint breakdown: Rust Agent 33 MB IOSurface (window drawables) + 8 MB
  Metal; Rust Box 70 MB Metal (IOAccelerator) + 36 MB IOSurface. These are
  framework/renderer costs, not app logic.

### Box engine microbenchmark (in-process, not end-to-end UI)

Shipped Swift sources from `e43b1c4` (`DeveloperJSON.swift`, `TextTransforms.swift`
lines 281–332) compiled with `swiftc -O -wmo` vs rust-branch `bellobox-core`
(release, thin LTO). Same inputs; 3 interleaved process rounds × 30 samples.

| Operation | Input | Swift p50 ms | Rust p50 ms | Outputs |
|---|---|---|---|---|
| JSON pretty | 296 KB, 19,801 values | 50.8 [46.1–59.3] | 6.8 [5.8–7.7] | byte-identical |
| JSON minify | same | 47.0 [43.5–53.7] | 5.4 [5.0–6.5] | byte-identical |
| Lines: remove duplicates | 490 KB, 15,791 lines | 25.2 [22.4–28.9] | 9.7 [8.8–11.3] | byte-identical |
| Text counts | same | 68.0 [63.3–76.1] | 10.3 [9.8–12.6] | identical |
| Lines: sort A→Z | same | 220.3 [202.9–238.3] | 2.8 [2.4–3.4] | **different** (see below) |

Parity defects found by this run (both reproducible from `harness/`):

1. **JSON value limit.** A 486 KB document with 32,347 values (depth 4) formats
   in Swift (~83 ms) but Rust rejects it: `JSON exceeds 64 levels or 20,000 values.`
   Swift limits depth to 64 and input to 500 KB, but has no value-count limit.
2. **Sort A→Z semantics.** Swift sorts with `localizedCaseInsensitiveCompare`
   (`alpha` before `Beta`); Rust sorts by bytes (`Beta` before `alpha`). The
   78× speed ratio therefore does not compare equal work.

## Limitations

- The Mac is a virtual machine (paravirtualized GPU, 60 Hz virtual display).
- Launch times use direct `exec`, excluding LaunchServices/Gatekeeper. Rust apps
  are unsigned bare executables; Swift apps run from signed bundles.
- Launch screens differ in content (Swift Agent workspace without a selected
  chat vs Rust Agent disconnected empty project; both Boxes show Home).
- Swift Box runs with Keychain IPC denied (its synchronous launch-time Keychain
  read otherwise blocks on a password prompt on this Mac).
- Not yet measured: input-to-screen latency, Agent streaming/long-chat
  scrolling/search, Box tool-window and image/GIF workflows. Engine speed does
  not imply faster end-to-end interaction.

## Reproduce

Release builds as in METHOD.md; `harness/run-launch.sh` (owner approval needed
to launch the shipped Swift apps; it backs up and restores their preferences),
`harness/analyze-launch.py RUN`, `harness/idle-diagnose.sh`, and
`harness/microbench/run.sh` after extracting the two Swift sources from
`e43b1c4` (`git show e43b1c4:BelloBox/DeveloperTools/DeveloperJSON.swift`;
`TextTransforms.swift` lines 281–332 prefixed with `import Foundation`) and
generating inputs with the fixed-seed generator recorded in
`microbench/inputs.sha256`.
