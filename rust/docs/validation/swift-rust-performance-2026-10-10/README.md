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
   Fixed afterwards in BelloBox `de218fb`.
2. **Sort A→Z semantics.** Swift sorts with `localizedCaseInsensitiveCompare`
   (`alpha` before `Beta`); Rust sorts by bytes (`Beta` before `alpha`). The
   78× speed ratio therefore does not compare equal work. Fixed afterwards in
   BelloBox `2f475c5` (macOS sorts through Foundation's
   `localizedCaseInsensitiveCompare`; Trim and Remove Empty use Swift's
   whitespace set); the sort timing above predates that change.

### Box JSON Tools (end-to-end, external measurement)

Recorded in full in the BelloBox `rust` branch copy of this file (`box-e2e/`,
`dd110fc`). Paste -> pretty-printed result shown, p50, shipped Swift Box 0.0.77
vs Rust `d3fd43a`: 30 KB 2,264 vs 256 ms; 100 KB 24,571 vs 259 ms; 296 KB
~88,900 ms (n=2, the result never draws) vs 260 ms. Both debounce input by
220 ms; Swift draws its result as one SwiftUI `Text` on the main thread.

### Agent interaction and streaming (end-to-end, external measurement)

Same Mac, same loopback gateway (`harness/benchgw.py`: one 96,000-character
Markdown reply as 32-character `output_text.delta` events every 20 ms, 60 s),
same 400-turn / 800-message / 2.1 MB conversation (`harness/longchat_fixture.py`).
Swift is 0.1.122 (`6319e368`) built Release with testability and hosted by
`harness/swift-bench-host/SwiftRustBenchHost.swift`: the production
`WorkspaceRootView` and `ApplicationMenus` over an in-memory vault (the owner's
Keychain is never touched). Rust is the `973e7bed` release binary with the CLI
profile and a fake key; its session is seeded by `harness/rust-seeder`. Latency
= synthetic event post → first change of that window region in the window
server (`belloperf input`); its floor is one capture (~5 ms for the composer,
~8 ms for the transcript). Input was posted only while the app was frontmost.

| Measure | Swift 0.1.122 | Rust `973e7bed` |
|---|---|---|
| Typing in the composer, idle (n=40) p50 / p90 / max | 5.9 / 11.8 / 31 ms (at the capture floor) | 40.5 / 43.0 / 45 ms |
| Typing while a reply streams (n=40) p50 / p90 / max | 13.3 / 21.9 / 50 ms | 41.1 / 60.0 / 72 ms |
| Transcript wheel scroll (n=40) p50 / p90 / max | 21.0 / 31.0 / 51 ms | 39.3 / 45.1 / 50 ms |
| Find: first keystroke of a query whose only match is turn 200 → revealed (n=1) | 528 ms (150 ms debounce, paged from disk) | 260 ms (session in memory) |
| CPU while streaming, one core, p50 / p90 | 37.9 / 41.1% flat (reply on screen) | 28.8 / 51.6% with the reply off screen, climbing 10%→55%; 45.1 / 98.7% with the reply kept on screen, climbing 10%→100% |
| Footprint while streaming, start → peak | 90 → 132 MB (app + helper) | 83 → 107 MB (off screen); 82 → 120 MB (on screen) |

Rust's streaming cost grows with the reply's length. A mid-stream `sample`
(`interaction/rust-visible/sample-top-of-stack.txt`) attributes it to:

1. GPUI `WindowTextSystem::shape_text` ← `TextLayout::layout`: the streaming
   reply is one text element, so every frame re-shapes the whole growing reply
   (`memmove`/`madvise` dominate), i.e. O(reply length) per frame.
2. `bello_agent_core::stream_journal::append` ← `SessionStore::append_delta`:
   every delta is synchronized to stable storage (`fcntl`) before publication,
   ~50 times per second. Swift writes run records unsynced and synchronizes when
   the turn settles (`SessionJournal.append(flush:)`, `journalFlushesEachRecord`).

After these measurements the Rust transcript stopped re-shaping unchanged text
(`transcript_shaped_text.rs`: message text in runs of 24 lines, each run's
shaped lines reused across frames while its text, style and wrap width are
unchanged). `harness/stream-profile.sh` (same gateway, chat and reply, followed
on screen; per-second samples in `interaction/streaming-shaped-text/`):

| Rust build | CPU p50 / p90 / max, one core | Over the 60 s reply |
|---|---|---|
| `9a5c960b` (whole reply shaped every frame) | 31.5 / 60.8 / 82.5% | climbs 11% → 82% |
| shaped-text runs | 14.7 / 17.6 / 19.1% | 11% → 19% |

A mid-stream `sample` before the change put 37% of the main thread in GPUI's
`shape_text`, three quarters of it copying `WrappedLine`s (each carries an
inline 32-entry decoration array) into a vector that grows by doubling. After
it, the main thread is idle 79% of the time; ~7% is spent waiting for the
controller lock that the runtime holds while it synchronizes each delta to disk.
The opening frame of the follow check is byte-identical before and after.

Then each delta's sync changed from `F_FULLFSYNC` to a write barrier
(`F_BARRIERFSYNC`; the turn-ending checkpoint still syncs fully). On this Mac
one 200-byte append costs 0.002 ms unsynced, 1.4–2.3 ms with a barrier and
5.4–5.7 ms with a full sync (median of 400, `harness/syncbench.c`). In the same
streaming profile the runtime worker's share of time in the sync fell from 31%
to 10% and the UI thread's waits for the controller lock from 7.2% to 0.9%;
CPU stayed at 14.5% p50 (`after-barrier-sync-cpu.json`), since sync waits are
not CPU time.

Behavior observed while measuring (screens in `interaction/screens/`): the Rust
transcript shows Markdown as raw text; it opens a chat at the top of its loaded
100-message window and does not follow a streaming reply (it is created with
`ListAlignment::Top` and preserves the reader's anchor). Swift opens this idle
chat at the question of its last turn, which is taller than the window (with a
Back to bottom button), renders Markdown with syntax-highlighted code and follows
the reply.

Transcript placement was fixed after these measurements (the follow-up `rust`
commit). `harness/follow-check.sh` repeats the scenario on the release build:
the chat opens at question 399 as Swift does (`rust-follow-01-opened.jpg`), a
sent message's reply is followed while it streams (`rust-follow-03-streaming-8s.jpg`),
a reader who scrolls up keeps their place (`rust-follow-05-held-5s-later.jpg`,
identical to the frame 5 s earlier) and following resumes once they scroll back
to the end (`rust-follow-07-following-5s-later.jpg`). A first attempt that only
followed when the previous frame showed the end failed in the app although its
tests passed: sending queues the message first, the queue panel shortens the
transcript for a frame, and the end dropped out of view
(`rust-before-fix-02-sent-not-followed.jpg`); the fix keeps a follow state,
as Swift's `followsBottom`, instead of inferring it from the last frame.

## Limitations

- The Mac is a virtual machine (paravirtualized GPU, 60 Hz virtual display).
- Launch times use direct `exec`, excluding LaunchServices/Gatekeeper. Rust apps
  are unsigned bare executables; Swift apps run from signed bundles.
- Launch screens differ in content (Swift Agent workspace without a selected
  chat vs Rust Agent disconnected empty project; both Boxes show Home).
- Swift Box runs with Keychain IPC denied (its synchronous launch-time Keychain
  read otherwise blocks on a password prompt on this Mac).
- Agent interaction results are single sessions per app (n=40 per latency
  series, n=1 for Find and each streaming run); Swift ran as an XCTest-hosted
  Release build, not the shipped bundle. Box end-to-end covers JSON Tools only (see
  above); Text Tools, the image editor and Box typing latency are not yet
  measured, and movie-to-GIF cannot be compared (Rust's movie reader is closed).

## Reproduce

Release builds as in METHOD.md; `harness/run-launch.sh` (owner approval needed
to launch the shipped Swift apps; it backs up and restores their preferences),
`harness/analyze-launch.py RUN`, `harness/idle-diagnose.sh`, and
`harness/microbench/run.sh` after extracting the two Swift sources from
`e43b1c4` (`git show e43b1c4:BelloBox/DeveloperTools/DeveloperJSON.swift`;
`TextTransforms.swift` lines 281–332 prefixed with `import Foundation`) and
generating inputs with the fixed-seed generator recorded in
`microbench/inputs.sha256`.
