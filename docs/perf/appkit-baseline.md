# AppKit port: performance baseline

The numbers every 0.1.120 change is measured against: `dev/next` at
`e59e41a7`, before any SwiftUI was removed. Measured 2026-10-04 on the
owner's machine (macOS 14.8, a VM on Apple Silicon) from a Release
build-for-testing, with other agents building in parallel; each group waited
for the one-minute load to fall below 4 and ran three times.

## How to rerun

Build the commit to compare once, keep its derived-data folder, and run the
same script against it and the new build back to back, under the same load:

```sh
X=(-project PiApp.xcodeproj -scheme PiApp -configuration Release -destination 'platform=macOS,arch=arm64' \
   -derivedDataPath "$DD" ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO)
PI_BUILD_ROOT=… python3 scripts/build-bundle.py && xcodegen generate && PI_BUILD_ROOT=… xcodebuild build-for-testing "${X[@]}"
scripts/perf-transcript.sh "$DD" "$OUT" 3 122 4     # rounds, soak seconds, highest load to start at
ONLY=budget scripts/perf-transcript.sh "$DD" "$OUT" 3 0 4   # one group
```

The script runs through the build's `.xctestrun`, so the sources can move on
after the build. Groups: `probe` (RedrawCostProbeTests: chat switch, typing,
a streamed reply, first open), `budget` (TranscriptFrameBudgetTests opening
and streaming, TranscriptSwitchBudgetTests, TranscriptScrollBudgetTests, the
sixty-tool fold), `scroll` (NativeTranscriptScrollingPerformanceTests),
`baseline` (PerformanceBaselineTests) and `soak` (three 122 s switch-aimed
soaks, seed 1790822043708, and one 60 s draw report). The baseline's
derived data is kept at the integrator's scratchpad as `baseline-0.1.120`.

## Numbers (three rounds each)

| Measure | Round 1 | Round 2 | Round 3 |
|---|---|---|---|
| Chat switch, main thread per switch, median (max) | 54.4 (96.9) ms | 49.9 (164.4) ms | 51.8 (104.6) ms |
| Chat switch, to ready, median (max) | 62.6 (103.1) ms | 58.7 (183.0) ms | 60.4 (109.1) ms |
| Chat switch with its settling, median (max) | 60.9 (106.7) ms | 62.7 (172.6) ms | 58.0 (119.5) ms |
| Switch to another 300-row chat, cold, first paint | 47 ms | 63 ms | 51 ms |
| Switch back to a 300-row chat already read, first paint | 29 ms | 30 ms | 36 ms |
| Same switch, pane rebuilt, first paint | 44 ms | 49 ms | 53 ms |
| First open of a chat (three chats) | 269 / 283 / 197 ms | 267 / 276 / 191 ms | 264 / 274 / 199 ms |
| Back to a chat already open | 158 / 149 / 155 ms | 169 / 147 / 156 ms | 164 / 153 / 153 ms |
| Open 300 rows: first paint / fully settled | 68 / 646 ms | 63 / 613 ms | 65 / 649 ms |
| Streaming a 10 KB reply: main thread busy | 3.35 s of 11.2 s (30%) | 3.38 s of 11.3 s | 3.37 s of 11.2 s |
| Streaming delta into 300 rows: mean (worst) | 6.9 (9.8) ms | 7.2 ms | 7.1 ms |
| Streaming delta, layout + display (PerformanceBaselineTests) | 2.8 ms | — | — |
| Scrolling 300 rich rows: mean / p95 / max step | 6.05 / 17.3 / 51.7 ms | 6.58 / 18.1 / 60.3 ms | 5.93 / 16.8 / 52.1 ms |
| Scrolling one 88 KB answer: mean / p95 / max step | 0.56 / 0.62 / 5.8 ms | 0.56 / 0.69 / 5.8 ms | 0.60 / 0.78 / 5.7 ms |
| Scrolling 400 rows, 2462 steps: mean / worst | 1.48 / 25.8 ms | 1.46 / 28.6 ms | 1.47 / 19.3 ms |
| Folding / unfolding a 60-tool turn | 10.3 / 12.8 ms | 11.6 / 13.3 ms | 11.1 / 13.2 ms |
| Typing in the composer, main thread per key: median / p90 / max | 3.6 / 5.8 / 9.6 ms | 3.6 / 5.2 / 8.0 ms | 3.7 / 5.7 / 9.4 ms |
| Begin editing the first message of 300 rows | 62.8 ms | — | — |
| 122 s switch-aimed soak: answers over 100 / 150 / 200 ms | 21 / 0 / 0 | 10 / 1 / 0 | 11 / 0 / 0 |
| Soak, longest main-thread answer | 133 ms | 150 ms | 135 ms |

Load at the start of each round was 2.3–3.9 (one-minute average).

The 60 s draw report (`PI_SOAK_DRAW_REPORT`) spent 449 ms of CPU drawing in
3,012 draws while selecting chats, 149 ms launching and 62 ms switching; the
two costliest places are 118×25 pt SwiftUI layers at the window's top right
(960,0 and 970,0), drawn on the CPU.
