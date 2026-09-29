# The soak test

`SoakTests` (apps/macos/PiAppTests/SoakTests.swift) is a long run of what a
reader does, at random moments. It launches the app, opens and switches
chats (sometimes twice within 50 ms), sends while a helper is still
starting, waits, idles, quits, and launches again, over the synthetic
gateway, in a real window. It is opt-in: it runs only when
`PI_SOAK_SECONDS` is set, and it belongs to the serial lane.

It looks for what the focused tests had each seen once and never again: a
launch whose sidebar stayed empty for 30 s, and a conversation that jumped
when its helper started late. It fails on:

- **A stall.** A thread of its own asks the main queue to answer every
  16 ms, and an answer later than 250 ms (`PI_SOAK_STALL_MS`) is a stall.
  While one lasts, it takes the main thread's stack every 50 ms: it suspends
  the thread for the microseconds it takes to read its registers and walk
  its frame pointers, without allocating, and resumes it.
- **A jump.** After each action it reads, every 4 ms, where the rows on
  screen sit in the viewport. A row of the chat shown that moves or changes
  height once drawn, while that chat is not running or sending and has not
  just finished, is a jump. It records the rows, which fields of a resized
  row's item changed, the viewport and composer before and after, the
  chat's load state and anchor, whether its helper opened meanwhile, and the
  actions just before.
- **A slow launch.** The sidebar listing every chat later than 2 s after
  launch (`PI_SOAK_LAUNCH_MS`).
- **A quit that never answers.**

After each launch it also prints the test host's footprint, so memory held
across launches shows as a trend.

## Running it

Measure in a Release build on a quiet machine: Debug overstates the app's
own code ten to twentyfold, and other builds make stalls of their own. From
the repository root, with a derived-data folder in `$DD`:

```sh
X=(-project PiApp.xcodeproj -scheme PiApp -configuration Release \
   -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
   ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO)
xcodebuild build-for-testing "${X[@]}"
TEST_RUNNER_PI_SOAK_SECONDS=3600 TEST_RUNNER_PI_SOAK_REPORT="$PWD/soak-report.txt" \
  xcodebuild test-without-building "${X[@]}" -only-testing:PiAppTests/SoakTests
python3 scripts/soak-symbolicate.py soak-report.txt --dsym-root "$DD/Build/Products/Release"
```

xcodebuild hands the test host `TEST_RUNNER_<NAME>` with the prefix kept;
the test reads either name (`testEnvironment`). The run prints its seed;
`TEST_RUNNER_PI_SOAK_SEED=<seed>` repeats the same actions (the timing of
what they meet can still differ).

The `SOAK` lines in the log are the summary. The report (`PI_SOAK_REPORT`,
else `soak-report-<seed>.txt` beside the run's scratch folder) has the same
lines and every stalled frame with its image and load address, which
`scripts/soak-symbolicate.py` names with atos.

## What it has found

Its first runs, in September 2026, found jumps the focused tests had not:
a chat drawn first where the chat before it was scrolled to; a chat whose
last turn is taller than the pane opening at its end one time and at the
question that started it another, and shaking while held there; rows kept
from a run that finished while the chat was in the background, which
changed when the finished page came; and the live turn bar holding the
actions of the chat the reader left. `ChatOpenPlacementTests` and
`TranscriptFrameBudgetTests` hold those fixes.
