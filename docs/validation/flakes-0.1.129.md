# Intermittent test failures — 0.1.129 (flakes workstream)

Branch `dev/a129-flakes` from `dev/next` 9d4123f6 (released 0.1.128). Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-flakes`; logs named below are in
its `logs/` folder. The machine is a 10-core VM shared with two other workstreams.

## Method

- Load like the parallel lane's: up to eight concurrent test hosts, each running a
  mix of the affected classes with `-test-iterations`, plus busy loops; and whole
  traced parallel lanes (8 clones). Heavy runs held the shared full-lane lock.
- A temporary in-process trace (removed before commit) logged test boundaries,
  window counts, Overview page builds and what triggered them, model/terminal
  shutdowns and every automatic-context scheduling decision. Time profiles came
  from `xctrace record --attach` on an ad-hoc-signed copy of the test host
  (never `--launch`).
- Baseline: one full parallel lane on the unchanged branch passed 2,630 with no
  failures (`base-1.log`); the known failures are rare per lane.

## Explained and fixed

| Failure | Before | Cause (evidence) | Fix | After |
| --- | --- | --- | --- | --- |
| `MarkdownSourceReconciliationTests…UnselectedMiddleCharacterAtDrawTime` (16.5 pt) | 1/5 alone; first test in a cold process | The reader's line can start on a reference link's `[`/label. When the late definition arrives the new rendering drops those characters; their reading position had no mapping and fell back to the old offset, a line or more away. Which character starts the line depends on wrapping (a cold process's first layout wraps 640 pt like 656 pt). A width sweep reproduces it deterministically: 7 of 21 widths off by 12–44 pt. | A dropped character stands where its source resumes (`Reconciliation.position`); selections keep their exact rule. | New sweep and mapping tests; class 35/35 (5 iterations); mutation (old lookup) 14 failures. |
| `TerminalSessionsTests` timeout (`MARK-A2 shows`) | 0/468 timeouts, but 9.2 s median / 12.0 s max for the five-shell test with six hosts | Test shells are real login shells that read the developer's zsh files from the real home (nvm twice, brew shellenv, rbenv): about 3 s per shell alone. A/B under the same six-host load with `ZDOTDIR` pointed at an empty folder: 0.075 s median / 0.246 s max. The 20 s wait was spent in dotfiles. | Scheme sets `ZDOTDIR` to the isolated test home; the rc-reading test writes its own `.zprofile`/`.zshrc` and checks both are read; isolation test asserts the setting. | 756/756 terminal tests across 6×6 concurrent runs. Mutations: no `ZDOTDIR` → isolation test fails; non-login start → rc test fails. Rare ~10 s zsh exec stalls remained only while another workstream's gate overlapped (load average ~60). |
| `CatalogModelPickerTests` timeout (`the chooser grows`) | reproduced deterministically | The source chooser is a transient popover: it closes when another app activates. In the parallel lane that app is another test host (21 test files call `NSApp.activate`). A closed chooser no longer resizes. Probe: host active, then Finder activated → chooser closed and the unchanged test failed. | The test owns the popover's closing (`.applicationDefined`); product behaviour unchanged. | Same probe passes. |
| `SubagentPerformanceTests` 50 KB expansion heartbeat (94.6 / 101.7 ms vs 100) | reproduced in a clean, locked serial lane: 101.69 ms (`serial1.log`) | Time profile: the main thread is saturated during expansion, ~45 % by a long chat's idle measuring slices (the 400 settled rows), which measure for as long as one page placement takes and then place the page. Each placement read every row's id by copying its whole `TranscriptItem` (17 % of samples) and looked every unmeasured row up in the shared geometry cache again (~16 %). | Rows keep their id with their item; a row remembers a shared-cache miss until something new is stored or its content changes. Threshold unchanged. | Alone: worst gap 45 → 24 ms, expansion 1.46 → 0.97 s (3 runs each). Unit test plus mutation (memo removed → fails). Full serial lane: see final gate. |
| `ContextReadingTests…WithoutAHelper` nil fraction after helper shutdown | 1/64 under eight hosts (`ctxs`), diagnostics `preparing=true opened=false` with the reading standing | Opening a chat on a helper publishes its figures before the chat counts as open. An activation in that window saw no saved reading serving and the chat not open, and scheduled an automatic count (`preparingContext = true`). If the helper went before the count's next look cancelled it, the pill said "calculating" over the reading. Trace: a transient start happened on every explicit count. | With no helper open the pill shows a standing reading even while such a stale count is pending (the scheduler never counts over it there). | Deterministic test red without the fix; 0/240 under eight hosts (`ctxs2`) and 0/640 in the mixed stress (`s2`). |
| `UIScreenshotTests.testRenderRedesignGallery` (11 file-viewer waits, family-delete gate) | reproduced exactly: same 11 waits plus the two sub-agent galleries | The gallery lost the app focus to another process. The family-delete gallery failed from about 01:01:40 to 01:07; this workstream's chooser probes brought Finder forward at 00:59:41, 01:00:55 and 01:01:03 without holding the lock. Re-running the gallery with Finder brought forward every 20 s produced the identical failures (`gal-finder.log`, every one reporting `app active: false, key window: none`). | No product change. The waits now report app focus, key window, first responder and frontmost app. Rule: anything that changes app focus (activating apps, focus-dependent tests) holds the full-lane lock. Taking the focus back inside the gallery was tried and rejected: it broke the Inspector scenes. | Probes removed; later gates without focus theft pass the file scenes. |
| `SessionTimingTests.testNarrowSidebar…` (new, 2 of 3 traced lanes, then the first final gate) | 3 of 5 lanes on this branch; 0 in the baseline lane and both other workstreams' gates | **Not explained.** The failing reading still shows the previous fixture's "latest 100 tok/s". Reading until two readings agree did not help (the first final gate failed again). One theory was tested and rejected: an occluded window does not freeze its captured image. | The message now says what the app itself draws, and whether the window was occluded and on screen, so the next miss tells app state from window-server state apart. | Still open. |
| `WorkspaceRedrawTests.testAChangeElsewhere…` (new, 1 of 3 traced lanes) | 1/3 | The chat's automatic context count starts ~0.2 s into the test and ends after a 180 ms pause; under load its end (a footer change) could land between the settling draws and the footer being watched, so one figures draw was counted with no counted change (trace shows the count starting in that window). | Wait for the count to end before counting. | Class passes; final gate below. |
| `TranscriptQuoteSelectionTests…CopySurvivePopover` (new, 1 kept-message lane) | reproduced deterministically | Same class as the chooser: the quote bar goes when its window resigns key. Another host activating itself did that before the ask. Probe: host active, Finder brought forward, nothing emitted. | If its window resigned key, the test shows the surviving selection's bar again before asking. | Class 8/8. |
| `SessionStatsPopoverTests` Overview hover `panels == 1` | not reproduced: 0 in 128 loaded runs and 4 lanes | Most likely a late opening read: the test waited only for three still looks (~0.3 s); traces show the opening's builds spread over ~0.5 s even in loaded lanes, and anything spaced further rebuilds the page mid-hover. | Wait for the index, chart history and usage read first; the failure message names which observed object published during hover. | — |

## Not reproduced — diagnostics added

Each passed every loaded run here: 48 (`s1`) + 80 (`s2`) per class under eight hosts, plus four full parallel lanes.

- `FileHiddenReadTests` resume timeout. The message now gives document reading/status, whether the tab still holds the same document, identity check, and the find search's count/stopped/stale state. A changed-identity reopen is the leading candidate: `hasChanged` compares ctime, and anything touching the file's metadata would replace the document the test holds.
- `PiSheetWindowTests` closed-sheet release: the message now lists the surviving views with their window and superview types.
- `TranscriptRevealTests` landing: the message gives landing, scroll, document height and whether the target message is loaded.
- `PastedAttachmentTests` cleanup start: the message gives whether the sweep was scheduled and each condition that defers it. The leading candidate is the sweep's `.utility` priority starving under eight hosts (0.1.127 saw a 60 s utility scan).
- `ContextReadingTests.testAChangedModelOrJournalCountsAgain` (66.7 s, the same duration as 0.1.126): reproduced once (1/48 in `s1`, before the scheduler trace existed), then 0/80 and 0/80 with tracing. The failure now prints the full footer and reading state. Cause still unknown.
- `SettingsFullDocumentGeometryTests` (new, 1 pt in this workstream's serial lane): 0/10 alone and 0/3 with its serial neighbours. Not attributed.
- Older single sightings (`AppShellPerformanceTests` page retention, `ModelCatalogEndpointTests` nil capture, `TerminalPanelAuditTests` empty registry) did not recur and were not investigated further.

## Shared-machine note

This workstream's unlocked focused runs perturbed other gates. The chooser probes caused the family-delete gallery failure above. Four-host stress at about 00:42 overlapped the family-delete serial lane that measured 101.7 ms. The clean, locked serial lane here measured the same margin, so the expansion work was fixed regardless.

## Final gates

First `verify-release.sh` (commit 1ca80288), 55 min 39 s:
- serial lane: 886 executed, 42 skipped, **0 failures**. The 50 KB expansion heartbeat measured **55.1 ms** (101.7 before).
- parallel lane: 2,627 passed, **1 failed** (`SessionTimingTests.testNarrowSidebar…`, above), 38 skipped.
- helper cost: 5/5.
- gallery: 3 tests, 0 failures, 230 screenshots.
- helper: 961 executed, 7 skipped, 0 failures.
- wire 36, concurrent 4, acceptance 3, python 86: all passed.

A further parallel lane that kept its failure messages (`keep1`): 2,627 passed, 1 failed. The failure was the quote-bar test above, then fixed.

Second `verify-release.sh` (commit 97088821), 54 min 46 s, **all passed**:
- serial lane: 886 executed, 42 skipped, 0 failures. The 50 KB expansion heartbeat measured **61.4 ms**.
- parallel lane: **2,628 passed, 0 failed**, 38 skipped.
- helper cost: 5/5.
- gallery: 3 tests, 0 failures, 230 screenshots.
- helper: 961 executed, 7 skipped, 0 failures.
- wire 36, concurrent 4, acceptance 3, python 86: all passed.

Logs: `build-flakes/verify-logs`.

## The limit-pause gallery failure

The limit-pause gate's gallery failed differently, at 02:50: `Session … did not settle: state idle, 1 messages` (fork scenes). Its wire cost-limit test failed in the same gate. This workstream ran nothing that took the app's focus at that time. Neither failure appeared in any gallery or wire run on this branch: three full galleries and two gates. Most likely it comes from that branch's cost-limit and pause changes; it was not investigated here.
