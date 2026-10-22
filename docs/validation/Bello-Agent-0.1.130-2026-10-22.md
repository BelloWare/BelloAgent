# Bello Agent 0.1.130 — whole-repository bug hunt, floating Agents/Diff/Files card, images in any format, sidebar search modes

Status: **released and verified 2026-10-22.** Marketing version 0.1.130, build 134. Previous public release: 0.1.129/build 133.

## Owner request

On 2026-10-18 the owner had Codex hunt the **whole** repository: app, helper, bello-views, scripts/release tooling, project/entitlements, catalogs, fixtures and test support. When it found things they said "keep going, spawn 4 astra", which added four cross-cutting hunts: wire contract, persistence compatibility, concurrency/lifecycle and security boundaries. The same request approved the release; the stop condition was a sweep with no new real bugs.

- **Sidebar search** (2026-10-18): two modes, "Titles & details" (the default, not remembered) and "Full chats", switched with a pill under the search field.
- **Git security policy** (2026-10-18), three answers:
  1. Background/read-only Git in trusted projects may run programs from the user's global/system Git config, such as LFS, but never programs configured inside the repository. Untrusted folders are fully confined.
  2. HTTP redirects are followed as Git normally does, except refused for remotes with `http.extraHeader`. The lead implemented the conservative superset: any extraHeader in a repository refuses redirects for all of its network commands.
  3. Git writes require a trusted project; untrusted projects can still browse.
- **Floating panel** (2026-10-20): "for top right panel for side and sub agents, it should be always visible if it has enough space, also, include diff, file explorer, in the side panel, include in this release, and send me screenshots". Answers: pinned tabs Agents | Diff | Files, and "it should be show whenever there is space, and it's not right panel, but a floating panel on main session".
- **Clipboard paste** (2026-10-20): image paste "does not seems to work".
- **Image formats** (2026-10-20 evening): "regarding image support, please support jpg and more image format, and if openai model does not support, just convert to a supported format".
  - Lead decisions: original names on chips, converted photos at 2,000 px, 32 MiB per message.
  - The owner-requested deviations from pi 0.85.1 are recorded in `docs/Swift-Feature-Parity.md`.
- **Process** (2026-10-20): "for new task, you spawn sub agents to implement, astra is used only for review". New tasks went to Claude subagents, reviewed by Codex (gpt-6-astra, max effort, read-only). Branches already in flight with Codex finished their task.
- **Release cut** (2026-10-21): the owner chose "After in-flight lands". No new hunts for 0.1.130 (further hunting goes to 0.1.131); the in-flight branches finish to clean reviews.
- **Live test** (2026-10-21): "Run it": one run of `scripts/live-compaction-e2e.py` against the owner's gateway after the gate. On 2026-10-22, with no gateway key available to this session, the owner chose "Release without it" (see Validation).

## Scope

Base `141666ca` (the 0.1.129 record). 36 merges into `dev/next` plus six lead commits, to `66ddf9e3`. Each record is under `docs/validation/`. "rN" is the workstream's round number. Push counts are what the lead recorded in `state.md` when pushing; "40/4/3" is wire/concurrent/acceptance. The lead's notes from before 2026-10-20 were lost in a restart, so some early pushes have no counts here ("not recorded"); each branch's own record has its validation.

- **Hunts.** Round 3 wave A: 7 hunts on `28dbfb30` (helper-sessions, helper-agents-io, inspector-storage, tooling-config, wire-contract, persistence-compat, concurrency-lifecycle). `hunt4-grapheme` on `f80e83cb`: 7 findings. Wave B: transcript (2 P2) and app-ui (1 P0, already fixed on the security branch) on `f80e83cb`; app-workspace (2 P1, 1 P2) on `78729efa`. Wave B git-files and security-boundaries: not run (see Known).
- **Helper** (`a130-helper-0.1.130.md`, Codex):
  - merges `10efb352`, `83ab455f`, `33e2cdc8` (hunt rounds 1–2), `d1d3cc4b`, `3249aa24`, `649ea623` (round 3);
  - 10 rounds; `83ab455f` and `33e2cdc8` merged "review clean"; reviews of r8–r10 clean;
  - capture masks credential echoes in metadata while keeping fixed schemas; wait IDs; model time for failed, retried and compaction requests; tool output shared by forks, sides and drafts survives deletion and slimming; import opens the existing chat; exports keep their identity. Markdown export stays text-only (lead decision);
  - live response reconciliation is indexed: 5,000-item streams took 19.4–29.4 s, now under 100 ms; legacy timelines build in linear time;
  - push: `d1d3cc4b` with `fe734912` (see Transcript); `3249aa24` helper 1,137/0, 40/4/3; `649ea623` helper 1,144/0, 40/4/3, app build; round 1–2 merges not recorded.
- **Inspector** (`a130-inspector-0.1.130.md`, Codex):
  - merges `6fc551e1` (round 1, "review clean"), `a8f155eb` (round 2 hunt), `d6b7aa78` (round 3 hunt);
  - 7 rounds; review of r7 clean;
  - finite charts for tiny costs, clearing an open capture, report paging past 100,000 rows, Headers Copy, narrow Raw toolbar; retention, clear and quota sweeps page through indexes past 100,000 requests; capture metadata over 4 MiB stays readable; manifests export at any size; metadata export freezes its request;
  - push: `d6b7aa78` with `fe734912`; `6fc551e1`, `a8f155eb` not recorded.
- **Wire contracts** (`a130-wire-0.1.130.md`, Codex):
  - merges `28dbfb30` (round 2 hunt, r1–r3), `f80e83cb` (r4–r10);
  - 10 rounds; review of r10 clean;
  - larger capture packets go in acknowledged 32 KiB pages; Inspector MCP work pins helper activity; snapshots follow the runtime epoch; copy/export validity depends only on the selected rows (row fingerprints); live and saved copies share one formatter; imported journals keep their identity; scans yield; history indexes stay in the eight-entry LRU;
  - push: `28dbfb30` helper 1,120/0, wire 39 (idle and 16-way load, twice), concurrent 4, acceptance 3; `f80e83cb` see Floating panel.
- **Workspace** (`a130-workspace-0.1.130.md`, Codex):
  - merges `735c1c14` (round 1), `78729efa` (r2–r17);
  - 17 rounds; review of r17 clean;
  - hunt fixes: capture preferences, Delete and Archive against pending sends, fork navigation, replacement keys, side switching, Quit during image import, Restart Terminal;
  - captured input (Send, Steer, Resend, queued Save, side first send) stays recoverable through storage failures, rejections, crashes and second instances: ordered draft writers, per-launch leases, an explicit state model (r17). PiKit capsule end seams fixed (lead decision: a rendering defect);
  - push `78729efa`: parallel 461/0 (1 skipped), serial 295/0 (7 skipped).
- **Workspace 2** (`a130-workspace2-0.1.130.md`, Claude subagent):
  - merge `a515d752`;
  - 5 rounds; reviews of r1 clean, r3 and r4 one P2 each, r5 clean (r3's review covered r2);
  - APP-WORKSPACE-7/8/9: `/side Q` is captured before publication and never lost; Archive retires a pending family Resume and Continue; a connection deleted mid-switch is never committed. One request per Continue, Retry or Compact press; a published side reopens its own journal after helper loss; a refused `/side Q` keeps the keyboard;
  - push: parallel 533/0, serial 286/0.
- **Git, Files, Terminal and test tooling** (`a130-gitfiles-0.1.130.md`, Codex):
  - merges `5c52621c`, `daade17e` (round 1, narrow splits), `77ca6cb1` (round 2), `fa18c41e`, `0253956f`, `688f8751`, `6f7310af`, `b532f6a4`;
  - 20 rounds; review of r20 clean (one P2 rejected with evidence in r17);
  - GIT-FILES-1–7 (path whitespace, preview refresh and identity, terminal colours and alternate screen, syntax), APP-UI-1 (Show Terminal needs Chats), the chat composer keeps its minimum in narrow splits, TOOLING-CONFIG-1–5;
  - tests: fixture helpers get their own homes; focus-aware lanes (133 classes serial, about +20 min per gate); fixture hooks owned per class; two intermittent native failures (sheet survivor, preview timeout) explained and fixed;
  - Git watcher: queued events are dropped only when covered by an ignore scan that started after them; displayed paths are kept; indexed ignore recheck 772 ms → about 3 ms; stress 600/600;
  - push: `688f8751` 69 native/0, python OK; `6f7310af` session 234/0, lead parallel 59/0; `b532f6a4` views 348/0, parallel 78/0, serial 355/0; `0253956f` with `fe734912`; others not recorded.
- **Transcript Find** (`a130-transcript-0.1.130.md`, Codex):
  - merge `fe734912`;
  - 13 review rounds; review of r13 clean;
  - TRANSCRIPT-1–3 (heading Copy offsets, literal truncation markers, Find on rendered text). Find then matches what each row shows (Markdown, tool cards, agents, recovery rows, selection-copy text), paged, within a yielding 16 MiB budget;
  - push (with `d1d3cc4b`, `d6b7aa78`, `a22c5556`, `0253956f`, `517a1aaa`): helper 1,132/0, wire 40, concurrent 4, acceptance 3, python OK, transcript lanes serial 210/0 and parallel 440/0, inspector/isolation/supervisor 59/0.
- **Transcript 2** (`a130-transcript2-0.1.130.md`, Claude subagent):
  - merge `f6ac5cfd`;
  - 2 rounds; review of r1 two P2s, r2 clean;
  - an open Find searches again once streamed content has been quiet for 0.5 s (while the chat runs, at least four times its last search), keeps other readers' marks and waits while hidden; reopened image-only tool results keep their description;
  - push: parallel 81/0, serial 309/0.
- **Sidebar search** (`a130-search-0.1.130.md`, Codex):
  - merges `f7b6a2a7` (modes), `a115d3c3` (`dev/a130-search2`);
  - rounds for `f7b6a2a7` not recorded; search2: 1 round, review clean;
  - Titles & details by default, Full chats from the pill, the scope never persisted. search2 limits metadata matches to rows the sidebar shows, fixing the `SubagentPanelTests` topic-search regression;
  - push: `f7b6a2a7` not recorded; `a115d3c3` with `3249aa24`: SubagentPanel and Sidebar 52/0, helper 1,137/0, 40/4/3.
- **Cost-limit pause, round 12** (`pause-r12-0.1.130.md`, Codex):
  - merges `e18ccba2`, `a22c5556` (round 3 hunt);
  - 9 review rounds to `e18ccba2`; review of r10 clean;
  - the three 0.1.129 Known items: recovery no longer requeues a reader-stopped child, Stop racing an accepted Resume halts child tools, the side-pause fan-out survives a helper exit. Then generation-fenced pause messages, two-phase Resume and durable membership intents. Hunt fixes: Stop fences a preparing Resume; recovered copies keep only their own paused members;
  - push: `e18ccba2` with `ce881ffd` (below); `a22c5556` with `fe734912`.
- **Clipboard images** (`a130-paste-0.1.130.md`, Codex):
  - merges `8d41ff9a` (r1–r3), `955545ed` (r4–r6);
  - 6 rounds; reviews of r3 and r6 clean;
  - cause: menu validation disabled Edit → Paste for image-only clipboards. Large screenshots normalize in the background (a 32.4 MB Retina PNG was refused); JPEG, HEIC, GIF and BMP are read in their own format, not a synthesized TIFF; Finder HEIC/TIFF copies accepted; refusals stay visible;
  - a second instance's startup sweep no longer deletes a live instance's unsent images (per-generation flock lease); sweeps hold at most 32 leases, images first;
  - push: `8d41ff9a` with `688f8751`; `955545ed` with `f80e83cb`.
- **Floating panel** (`a130-panel-0.1.130.md`, screenshots in the record, Codex):
  - merge `01de28cf`;
  - 9 rounds; review of r9 clean;
  - a 288 pt Agents | Diff | Files card on main chats at least 800 pt wide, else the family pill; tab and collapse per window, not persisted. Diff counts follow `git status` per row, keep rename pairs together (512-file rename 7.53 s → 0.72 s, 516 → 4 Git calls) and split case/Unicode collisions;
  - push (paste r4–r6, panel, wire): helper 1,162/0 (7 skipped), views 345/0 (3 skipped), 40/4/3, affected native parallel 546/0 (3 skipped), serial 942/0 (10 skipped).
- **Image formats** (`a130-images-0.1.130.md`, Claude subagent):
  - merge `77f17247`;
  - 3 rounds; reviews of r1 (one P2) and r3 (whole branch, clean);
  - Attach Images…, paste and drop take any still image macOS reads, decided by content. Other formats and originals over 8 MiB become PNGs of at most 2,000 px (the model got 1,125–1,500 px before); chips keep original names (draft only, never sent); animations go as their first frame; the read tool converts ImageIO formats; 32 MiB per message (was 16) in app and helper;
  - push (with `5cb9d2d5`): helper 1,170/0, 40/4/3, parallel 388 (+1 fixed), serial 272/0.
- **Async XCTest issues** (`a130-asynctests-0.1.130.md`, Claude subagent):
  - merge `2b5d6414`, then lead `d6cd317a`;
  - review of r1 clean; r2 (views package, lead decision) was merged before its review. The review afterwards found one P2: the views guard failed falsely under Xcode, which builds each test target as its own bundle. A Claude subagent gave each target its own guard (`dev/a130-guard`, review clean, merge `391f3c61`: views 350/0, 3 skipped; Python guard 3 OK);
  - Xcode 16.1's XCTest drops an issue recorded off the main thread while it records another (as few as 30 of 40). `HelperTestCase`, `ViewsTestCase` and `IssueRecordingGuard.m` record it afterwards, with guards. Verdicts were never affected; no hidden failures;
  - push: views 346/0, python 148, 40/4/3, native 390 + 277/0, helper 1,171 with one failure (`SubagentAdmissionTests`, 8/8 alone), fixed by `54718149`.
- **Grapheme boundaries** (`a130-grapheme-0.1.130.md`, Claude subagent):
  - merge `4a8e22f5`;
  - 2 rounds; both reviews clean;
  - GRAPHEME-1/3/6: credentials and path containment are matched as bytes where a delimiter is followed by a combining mark, ZWJ or variation selector (capture, Inspector id/model echoes, reply links, opener, history, helper grep/find). GRAPHEME-2/4/5/7 are covered on the security branch (r9, `6fbe70bc`);
  - push: helper 1,182/0, views 348/0, python 148, 40/4/3, native 249 + 345/0.
- **Security boundaries** (`a130-security-0.1.130.md`, Codex):
  - merge `176c14c5`;
  - 17 rounds; reviews of r13 (two P2s), r14 (one P2), r15 (three P2s) and r16 (one P1, one P2) each fixed in the next round, r17 clean;
  - the owner's Git policy above: repository-configured programs neutralised in trusted background reads, untrusted reads confined, any `http.extraHeader` refuses all redirects, writes need trust. Webhooks refuse redirects (the wave-B app-ui P0; `dev/next` followed them until this merge). Byte-level Git parsing and byte-exact Git arguments; trust and filesystem probes resolved off the main actor with deadlines; cached config inventories re-check the repository's path spelling; Git's own location is looked up once, bounded;
  - pushed with `66ddf9e3` after the full gate (below); r17 itself: views 485/0 (4 skipped), native 347/0 (1 skipped), helper 1,181/0 (8 skipped), 40/4/3.
- **Lead commits on `dev/next`:**
  - `ce881ffd`: the cost-pause merge reset `boundary = context`, undoing the helper fix that starts a new side or fork before an unfinished held tool batch; both now use `AgentSession.completeBoundary`. `CostLimitTests` failed on the merge and pass; helper 1,114/0 (7 skipped), wire 36, concurrent 4, acceptance 3.
  - `517a1aaa`: one Inspector export rule across the helper and Inspector merges. A selection change refuses the export until a destination is chosen; after that, the export completes for the original request.
  - `5cb9d2d5`: the images branch's four-image recovery fixture versions its draft write, as merged draft versioning requires (`RecoveredDraftTests` 14/0).
  - `d6cd317a`: `PiImageFormatTests` derives from `HelperTestCase`.
  - `54718149`: two fixture servers wrote `ready.json` in place, so the harness could read partial JSON. They now rename a complete file, and the harness waits for complete JSON. Fails first on the old harness; 34 passed.
  - `66ddf9e3`: test-only changes for the gate's serial-lane failures (see Validation).

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

Run after the security merge, with all workstreams idle. Per-merge checks are under Scope.

- **Full gate** (`verify-release.sh`) on `dev/next` `176c14c5`, 86 min:
  - native serial lane 2,374 passed, **4 failed** (94 skipped);
  - native parallel lane, 8 clones, 1,834 passed, 0 failed (22 skipped);
  - views package 489/0 (4 skipped), helper 1,184/0 (8 skipped), helper cost 5/0, wire 40, concurrent 4, acceptance 3, Python 148, gallery 3/0 with 230 screenshots.
- **The four gate failures** (`66ddf9e3` changes only tests; Codex review: no findings). Three were defects in the tests; the fourth is unexplained:
  - `ShellParityTests.testComposerPills`: the compact active pill differed by 557 of 12,144 px against a 4% allowance (486). The capsule-outline repair (`edab6936`) draws a capsule outline's ends on circular arcs, where the SwiftUI reference's continuous capsule bends differently. The same pill differed by 423 px on 2026-10-18, before the repair; every pill gained 40–150 px at its ends. Compact pills now get the cut pill's 5%.
  - `SettingsCloseNativeTests.testSettingsEditedDuringTheStopAndQuitQuestionAreAskedAbout` timed out waiting for quit to be asked again. It took the first window wearing any sheet for the stop-and-quit question's, so a sheet another test left closing would be answered in the question's place. It now takes the newly attached sheet.
  - `LayoutCycleTests.testClosedSheetsAndTheCostOfAModelChange` counted one hidden sheet window holding views anywhere in the test host. It now counts only the ten Settings sheets it opened, and names (does not count) windows earlier tests left.
  - `ConversationPaneRetentionTests.testTheWholeWindowKeepsAtMostOneChatBeyondItsCache`: the four chats evicted last were still alive at its check (12 pages for 8 cached). Not reproduced: 7 of 7 passes since (alone, after the 29 classes that ran before it in the gate, and in reruns), and a probe saw every evicted chat released in time with the window covered and under full CPU and fsync load. Unchanged; cause unconfirmed (see Known).
  - In reruns, not the gate: `LayoutCycleTests.testTheSettingsWindowLetsGoOfItsFormWhileClosed` failed twice, the reopened Settings window holding one view instead of its form. A probe showed the test host was not active and the window not key, not main and covered; the form comes back when the window becomes key, main or visible. The test now brings the reopened window in front, as activation does in the app.
- **Hour soak**, Release build of `66ddf9e3`, seed **1790822043708**, selecting and switching chats, no other builds running: **passed**.
  - 3,611 s, 178 launches (sidebar median 271 ms, max 316 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.129: 0).
  - Main-thread answers over 100/150/200 ms: **72**/1/0, longest 152 ms (0.1.129: 4/1/0, longest 167 ms). See below.
  - Footprint 109 → 715 MB, **3.42 MB per launch** (0.1.129: 3.70). This measures per-window state that XCTest retains (178 of 178 closed windows alive).
  - The 60 s draw soak passed: 0 stalls, 6/0/0, longest 145 ms (0.1.129: 4/0/0, longest 134 ms).
- **Why 72 answers over 100 ms** (0.1.129: 4):
  - A 30-minute rerun that captured every answer over 100 ms found 16. Four came while the six chats were seeded (121–155 ms, transcript layout as replies stream). Twelve came opening the largest chat, all 101–105 ms.
  - Side by side on the same machine, same seed, 15 minutes each, with every main-thread answer over 50 ms recorded with its action. 0.1.129 was built from its tag with its own helper. Over the first 755 s (the profiles below came after):
    - Answers over 50 ms while opening a chat: median 60 → 66 ms, p90 72 → 84 ms. The largest chat: 75 → 86 ms (p90 81 → 97). At launch: 67 → 77 ms.
    - Answers over 75 ms 67 → 204, over 100 ms 3 → 8 (whole runs 8 → 26), over 150 ms none in either.
    - Over the whole runs (all 44 launches each), the sidebar listed in a median of 238 → 268 ms.
  - Two-minute `sample` profiles (1 ms) of each run: main-thread busy time 20.9 → 22.6 s (+8%). The new Agents, Diff and Files card accounts for most of it:
    - 0.84 s: replies laid out twice. A reply's text is first laid out at the 840 pt page width when it joins the window. In the 1,280 pt soak window the reading column beside the card is narrower, so measuring lays it out again. In 0.1.129 the column was the full page width, and measuring found the layout done.
    - 0.52 s: the card itself, refreshing, its Agents list and pill buttons drawing their symbols (11 ms in 0.1.129; the card's folder menu is such a pill).
    - The other 0.33 s is spread across smaller items.
  - Answers over 150 ms are unchanged (one in each hour soak). The fix, laying a reply out at its real width before it joins the window, is deferred to 0.1.131 (see Known).
- **Live compaction e2e** (`scripts/live-compaction-e2e.py`): **not run**. It needs the owner's gateway key, which this session does not have; the owner chose to release without it. Against the local stand-in gateway whose model reasons, on the release helper, `--fixture` passed 3 of 3 scenarios (`live-e2e/20261022T073808Z`). With 0.1.90's 8,192-token summary cap (`--fixture-summary-limit 8192`) it failed 1 of 3, as it must (`live-e2e/20261022T073810Z`).
- **Reruns of the affected classes** after `66ddf9e3`: all four classes 35/0 (1 skipped); Settings, layout-cycle and retention classes 20/0 twice; retention class 6/0 twice. The app is unchanged since the gate, so the rest of the gate was not rerun.

## Known

- **Deferred to 0.1.131** (P3 or not reachable):
  - Opening a chat beside the Agents, Diff and Files card takes about 10–15% more main-thread time (soak above). A newly shown reply's text is laid out at the 840 pt page width, where `NativeMarkdownContainer` starts (`NativeMarkdownSurface.swift:89`), then again at the narrower reading column. The card's own refresh and drawing add the rest.
  - Unicode leftovers: `FileTabViews.swift:223` home-path abbreviation; `WorkspaceFolders` and `FileRecentState` reject "/" followed by a combining mark (fails closed).
  - A file tab's ownership is captured when it opens, for files that don't exist yet.
  - `GitController` startRefresh: a queued watch callback can cancel the reader task before it starts (`GitController.swift:370/516`).
  - `JournalSlimming.removeLeftovers` cleans up by age alone and can remove another helper's live staging; slimming then fails safe, with no data loss.
  - Continue/Retry has no Stop fence. Stop is not offered at the limit, so this is unreachable from the UI.
  - After `/side Q`, the parent's emptied draft is still the ordinary 150 ms delayed write.
  - Transcript action-pill border seams (`TranscriptNativeParts.swift:505`).
  - The wave-B git-files and security-boundaries hunts never ran (release cut).
  - Main-thread file I/O that predates 0.1.130, when a file tab opens or a working-tree watcher starts (`WorkspaceTabs.openFile`, `projectID(holding:)`, `fileProjectState`, `FileTab` init, `WorkspaceChanges`, `FileBlame`, `GitWorkingTreeWatcher` setup); found by the security r16 sweep.
- **Shipped with an owner decision pending** (asked after the release; on 2026-10-22 the owner kept all three as shipped):
  1. Legacy (≤0.1.129) side-keep records with no publication lease and a missing journal keep their review notice instead of being recovered automatically.
  2. `/side Q` while the chat has a pending side refuses with a notice and keeps Q in the parent.
  3. Show/Hide Terminal is disabled on Usage Report and Background Requests instead of switching to Chats.
- **Gate failure not reproduced:** `ConversationPaneRetentionTests.testTheWholeWindowKeepsAtMostOneChatBeyondItsCache` (above). Since 0.1.102 this class has had timing-dependent holds in view teardown.
- **Other open items in the records:**
  - At narrow widths an open file keeps whatever width the chat's minimum leaves (98/29 pt idle/busy at 920 pt with a 420 pt sidebar); collapsing panes needs an owner UX decision. Side conversations at 920 pt, where both composers cannot fit, keep 0.1.129's split geometry, including its clipping. (from a130-gitfiles)
  - Popped-out sub-agent windows keep their family pill (`SubagentTab.swift:68`) and get no floating card; hiding it needs an owner decision. (from a130-panel)
  - A text-first copy of an image and caption with no file URL and no image-only HTML pastes text; promise-only files are not received, and a notice says so. (from a130-paste)
  - Attach Images… does not offer animated AVIF; CMYK JPEGs are sent unchanged. (from a130-images)
  - With Find open, the refresh after a long run costs one whole search (Debug: 2–3 s at 400 turns, about 22 s at 2,000). (from a130-transcript2)
  - The live ledger copies its segment array on each part change: 32.56/107.74 ms for 1,000/2,000 parts. (from a130-helper)
  - A completed Markdown export can name a full-output file that is later reclaimed (lead decision: export stays text-only). (from a130-helper)
  - `TranscriptStreamingSerialTests.testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen`, skipped in workstream runs (it needs an unoccluded key window), passed in the gate's serial lane. (from a130-transcript)
  - Failure counts in earlier failing-first and mutation logs may be low; verdicts hold. Assertions in unawaited tasks remain a hazard; none were found. (from a130-asynctests)
  - Test fixtures still log SQLite "vnode unlinked while in use" at `WorkspaceTests.swift:238/:274` and `TranscriptBugRegressionTests.swift:625/:664`. (from a130-wire)
  - Where Git config or refs cannot be passed byte-for-byte, reads run confined and fetch/pull/push refuse rather than launch. (from a130-security)
  - After the wire merge, the first wire/concurrent run under heavy load had 3 "command reply did not arrive" timeouts; idle and 16-way load reruns passed, and so did the gate's wire and concurrent suites. Cause unconfirmed. (from state.md)

## Release

- Release commit `300e9f9c` ("Release Bello Agent 0.1.130"), tag `v0.1.130`, pushed atomically to `main` and `dev/next`.
- `BelloAgent-0.1.130.dmg`, sha256 `569401efc221ef24263ddfe17e47f31649b86d636cdd719817d4bd1584b6910d`, 16,705,336 bytes; Developer ID signed and notarized (app submission `2fd96fad-1588-4690-ab81-a60ecf1099f6`, DMG submission `f81b199f-33df-4376-9127-34b0a1fab895`, both Accepted), stapled.
- `validate-release.py --previous-build 133`: passed (0.1.130 build 134, Ed25519 signature verified).
- Website commit `92da118` (belloware.com `main`).
- `verify-published.py`: the public DMG matches, and the Bello Agent and legacy Pi App feeds are byte-identical.
