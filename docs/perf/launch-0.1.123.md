# Launch to a settled window (0.1.123)

The Rust port's comparison (rust/docs/validation/swift-rust-performance-2026-10-10)
timed the shipped 0.1.122 to its first window at 211 ms warm / 966 ms cold
and to a visually settled window at 307 / 1344 ms; Rust settled at 154 / 687.
This record covers where Swift's launch spends that time, what was moved out
of the way, and the numbers before and after.

## Method

- **Fixture, never the reader's data.** `LaunchFixtureWriter` (opt-in test,
  `PI_APP_LAUNCH_FIXTURE=<folder>`) writes the app's own records: two
  projects, 60 chats, the reopened one 200 turns of Markdown (262 KB), five
  unread, one marked unread, two paused, three with drafts, one pinned. Its
  only connection is a loopback port nothing listens on. The fixture is then
  settled in place by one launch and quit, so the request archive and the
  search index exist as on a reader's Mac.
- **Build.** Release, `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited)
  PI_LAUNCH_FIXTURE'`: such a build reads the fixture's `vault.json`
  (`LaunchFixtureVault.swift`) and never opens the Keychain. Release builds
  never set the condition. Each measured copy gets the bundle id
  `com.belloware.PiApp.launchperf`, so the reader's preferences are never
  written.
- **Harness.** `scripts/perf-launch.sh` drives the port's `belloperf`: process
  spawn → first on-screen window (polled every 4 ms) and → last frame change
  over 0.5% of the window before 1.5 s of quiet. Each trial gets a fresh copy
  of the state with `HOME`/`CFFIXED_USER_HOME` inside it; apps alternate;
  cold trials run `sudo purge` first. Nearest-rank percentiles.
- **Where the time goes.** A throwaway probe build (not committed) printed
  milliseconds since process start at each launch step, and every
  main-thread busy span over 2 ms from a run-loop observer.
- **Machine.** The owner's VM (Apple M3 Max, 10 vCPU, macOS 14.8). Other
  agents were building throughout: one-minute load 4–7 during the final run
  (the port's run had about 1). Absolute numbers are higher than the port's
  and noisy; the before/after comparison is interleaved, trial by trial.

`before` is `dev/next` at `3702d5d3` plus the fixture hook; `after` is
`dev/launch-perf` with the change below.

## Where a warm launch spends its time (before)

Typical warm probe run, milliseconds since process start:

| Step | ms | Main thread |
|---|---|---|
| `main()` reached (dyld, Swift runtime) | 10 | |
| `NSApplication.shared` returns | 61–74 | 50–64 ms in AppKit's own setup (LaunchServices check-in and bundle evaluation; a bare executable takes ~45 ms) |
| model, update controller, delegate | 66–80 | 5 ms |
| `applicationDidFinishLaunching` | 86–125 | AppKit's finishLaunching |
| main menu installed | 90–129 | 3–4 ms |
| **status item and its panel made** | 132–181 | **42–52 ms** (status item ~20, panel views ~23) |
| window and root view made, shown | 165–224 | 30–40 ms |
| first frame committed | 220–280 | 55–60 ms of layout and drawing |
| chats read (store opened off the main thread) | 256–312 | |
| sidebar built and drawn | 300–394 | 32 ms building rows, 44 ms drawing |
| read states, run holds, drafts, readings, project states | 340–411 | small store reads, each redrawing a few rows |
| the reopened chat's transcript | 355–505 | ~150 ms, most of it laying out and drawing the transcript |
| restore ends (retained totals for the other chats) | 495–560 | |

Not app-controlled or not deferrable without changing what launch shows:
AppKit's own launch (~110 ms before `applicationDidFinishLaunching`), the
window's first frame, the sidebar (its rows are already built only where
visible) and the transcript (owned by the transcript work in this release).

## Why cold is four times warm

Cold probe runs (after `purge`), against the warm run above:

| Step | warm | cold |
|---|---|---|
| process start → `main()` | 10 | 363–368 |
| `NSApplication.shared` | 51–64 | 225–270 |
| status item and panel | 42–52 | 135 |
| window made and shown | 30–40 | 230–240 |
| first frame | 55–60 | 165–190 |
| first frame → restore ends | 275–310 | 450–490 |

Two thirds of the extra time comes before the app's own code runs or inside
AppKit: dyld paging in the 30 MB executable, Sparkle and the system
frameworks the purge evicted, then AppKit's, Metal's and the window server's
first use of each. The app's share grows by about the same factor, because
every first call pages its code in. Doing less before the first window (below)
helps cold by the code that no longer runs then.

## What changed

**The status item comes after the launch window, and its panel on first
open** (`PiApp.swift`, `MenuBarController.swift`). It was made before the
workspace window: the status item, then the whole panel (live monitor, usage
charts and their controllers), 42–52 ms warm and ~135 ms cold of the main
thread. Now the status item is made once launch has put the restored chat on
screen (after the next committed frame), or after two seconds if launch takes
longer (a Keychain that asks first). Its panel is built the first time it
opens, and reused. The panel read nothing until it was shown anyway. Nothing
in the window changes. `MenuBarPresentationTests.testThePanelIsBuiltTheFirstTimeItOpens`
covers the lazy panel (mutation-checked).

Part of that time does not go away: the status item was the process's first
window, and its share of first-window setup (Metal device, window-server
context) is now paid by the workspace window. In the probe, making the
window and its first frame cost 15–35 ms more after the change, against the
42–52 ms no longer spent before it.

## Before and after

Final run: the fixture settled in place, its journals read in place, its two
paused chats kept; warm n=15, cold n=6, p50 [min–max], one-minute load 4.9–5.8:

| Build | Launch | First window ms | Settled ms | Idle CPU % | Footprint MB |
|---|---|---|---|---|---|
| before | warm | 264 [220–394] | 573 [495–760] | 0.03 | 39.5 |
| after | warm | **235** [173–348] | **555** [468–707] | 0.03 | 38.5 |
| before | cold | 1078 [988–1720] | 1645 [1532–2379] | 0.02 | 37.9 |
| after | cold | **1038** [952–1214] | **1611** [1556–1792] | 0.03 | 36.7 |

Earlier interleaved runs, warm p50 before → after (r1–r3 on a first layout of
the fixture, whose records named another copy's journals; r4 is left out:
its trials read copied journals, which the search index read again in full
during the idle window; r5 had lost the paused chats in settling):

| Run | n warm/cold | window warm | settled warm | window cold | settled cold |
|---|---|---|---|---|---|
| r1 | 8/5 | 239 → 221 | 546 → 542 | 1180 → 1192 | 1780 → 1769 |
| r2 | 10/5 | 242 → 222 | 569 → 506 | 1184 → 1110 | 1727 → 1675 |
| r3 | 15/6 | 250 → 228 | 557 → 561 | 1124 → 1070 | 1686 → 1689 |
| r5 | 15/6 | 268 → 213 | 597 → 524 | 1133 → 963 | 1686 → 1522 |

Every run puts the first window sooner warm, by 18–55 ms (p50 8–21%, about
25 ms typically). The settled window moves from 4 ms later to 73 ms sooner,
mostly within the run-to-run noise at this load (±30 ms): what came out ran
while the main thread was otherwise waiting for the first frame. Cold moves
the same way with more spread (n=6). Idle CPU and footprint are unchanged.
The port measured Rust settled at 154 ms warm on a quieter machine; most of
what Swift has left before it settles is the sidebar and the transcript laid
out and drawn on the main thread (below).

## Tried and not kept

- **Reading the store and vault while the window is made.** Starting
  `restore()`'s first reads (chat list, vault, remembered chat) in
  `applicationDidFinishLaunching` instead of after the first frame: chats
  were ready the moment `restore()` ran, but the sidebar was then built
  before the first frame, and the settled window came later (warm p50 506 →
  541 ms in r2). Not kept.
- **`NSPrefersDisplaySafeAreaCompatibilityMode`.** Part of
  `NSApplication.shared` is the bundle's camera-housing compatibility
  lookup through LaunchServices; declaring the key did not change it.

## Left

- The transcript of the reopened chat is ~150 ms of the ~300 ms from first
  frame to the end of restore (layout of its first rows and drawing). That is the
  transcript work's; measuring it off the main thread is its next step.
- The sidebar's first build (rows only where visible) and draw are ~75 ms;
  the five small restore reads after it each redraw a few rows.
- Cold launch is dominated by paging (dyld and AppKit). An order file that
  puts launch code together, or loading Sparkle on first use, would be the
  next levers; neither is a deferral.

## Reproduce

```
# fixture
TEST_RUNNER_PI_APP_LAUNCH_FIXTURE=<fixture> xcodebuild test-without-building … -only-testing:PiAppTests/LaunchFixtureWriter
# build
xcodebuild build -configuration Release … CODE_SIGNING_ALLOWED=NO "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PI_LAUNCH_FIXTURE"
# settle the fixture in place: one launch and quit with
#   HOME=<fixture>/home CFFIXED_USER_HOME=<fixture>/home PI_APP_LAUNCH_FIXTURE_VAULT=<fixture>/vault.json
# (after changing the bundle id as perf-launch.sh does)
BELLOPERF=<belloperf> WARM=15 COLD=6 scripts/perf-launch.sh <fixture> <out> before=<app> after=<app>
python3 <port>/harness/analyze-launch.py <out>   # with its app order list edited
```
