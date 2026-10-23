# FIND-1: chat briefs — 0.1.131

Owner, 2026-10-22: "maybe we can have, you know, have like using the mini model
to go through some of the chat and adding some keyword to make it more
searchable, or just have like a brief on what's going on about the topic. And
then maybe I can just ask an agent to find the relevant chat, if that makes
sense." From the lead's proposals the owner chose **Briefs, then Ask**: this is
the first half (FIND-1); the Ask mode (FIND-2) comes later and reads these
briefs.

Workstream `dev/a131-briefs`, worktree `wt-a131-briefs`, from `dev/next`
`ee41c072`, fast-forwarded to `47a80fc1` (SIDEBAR-1, PERF-1, LIMIT-1) before
the sidebar rows were touched. Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-briefs` (`$BUILD` below);
text logs in `$BUILD/logs`, images in `$BUILD/evidence/gallery`. Generated
journals, a loopback gateway and the isolated test host only: no installed app,
real preferences, real chats, Keychain, paid provider or `xctrace`.

## What it does

- **A brief per chat.** When a chat finishes a run and rests, its connection's
  mini model writes one or two sentences on what the chat is about and where it
  stands, and up to six keywords someone would search for (topics, files,
  tools, errors, names). The next update sends the earlier brief and keywords
  plus **only the rows after the one the brief read last**, so an update costs
  the same whether the chat is ten turns long or two thousand.
- **Bounded input.** The request reads the chat's newest page (60 rows, the
  history reader's), quotes only user and assistant text (no tool output,
  notices or summaries), each message clipped to 1,200 characters (start and
  end kept), newest first until 8,000 characters are used, then in the order
  they were said. A page that starts inside a long turn also quotes that turn's
  request. The title (120 characters), the earlier brief (at most 400) and its
  keywords (at most 8 × 40) complete it: at most about 11,000 characters,
  whatever the journal's size. Output is capped at 512 tokens; the mini model's
  lowest offered effort is used, as for titles.
- **When.** At a run's end (the same receipt signal as the completion sound),
  the update waits until the chat has rested 2 minutes (a quick follow-up joins
  it) and at most once every 30 minutes per chat. A run's end with nothing new
  since the brief sends nothing.
- **Chats without one** (or whose activity moved on since their brief) are
  filled in one request at a time, at most one a minute, starting 2 minutes
  after launch: the chat the reader has open first, then the newest activity
  first. A chat already running waits for its run's end.
- **Spending cap.** Every brief request counts against a daily cap (default
  $0.25 over any 24 hours): the cost the gateway reported, read from the
  request archive, or $0.01 for a request with no reported cost (yet), so a
  gateway that reports none still stops. At the cap nothing more is sent
  (updates included); the spend is read again 15 minutes later. A failed
  request pauses briefs for 10 minutes.
- **Which chats.** The reader's own saved main chats in a project. Never a
  side, a sub-agent, imported history, a background request or connection test,
  or a chat not yet sent; an archived chat is not filled in (its brief stays).
  A chat whose connection has no mini model (none chosen, none in its catalog)
  is never asked about, and the conversation model is never used instead.
- **Search.** Sidebar search's Titles & details (and Full chats, which includes
  the same details) finds a main chat by its brief or a keyword, in Topics and
  Flat, compared as titles are.
- **Hover.** Resting the pointer on a row whose chat has a brief brings up a
  card (the app's `PiHoverCardPresenter`, as skill pills use) with "Brief ·
  updated 5m ago", the brief, its keywords and the row's state and figures; the
  card replaces the row's tooltip, which rows without a brief keep. VoiceOver
  reads the brief as the row's help.
- **Setting.** Settings → Chats & notifications → Chat briefs: **Write chat
  briefs** (off until turned on) and **Spending cap** ($0.10, $0.25, $0.50, $1
  or $5 a day). Off stops the request under way, drops every waiting update, and
  hides briefs from search and hover; the kept briefs come back without being
  asked for again when it is turned on.
- **Where it is kept.** `ChatRecord.brief` (text, keywords, the row it read
  last, when, the chat activity it covers), written only by
  `MetadataStore.applyChatBrief` onto the record the store holds; a copy read
  before it landed, or an older brief, never takes it back
  (`ChatRecordMerge`). A brief this build cannot read reads as none, never as an
  unreadable chat. Deleting a chat deletes its brief with its record.
- **Nothing enters the conversation.** The brief request is a background
  request of its own ("Chat brief", purpose `chat-brief`): a chat outside every
  project with its own journal, captured requests and billing, sent through the
  chat's own connection and key. The chat itself is only read; it is never
  opened in its helper, its journal is not written, and its model context never
  sees a brief.
- **Spend in Usage.** Each request is kept on the Background requests page
  (a new **Chat briefs** filter; the brief and keywords as its result) and in
  Usage under the purpose `chat-brief`.

## Code

- `apps/macos/PiApp/Workspaces/ChatBriefPlan.swift` (new): `ChatBrief`, and
  the request (`ChatBriefPlan`: mini model, bounded excerpts, prompt) and how a
  reply is read (JSON anywhere in it, or "Brief:"/"Keywords:" lines; cleaned and
  capped).
- `apps/macos/PiApp/Workspaces/WorkspaceChatBriefs.swift` (new): the setting,
  the scheduler (`ChatBriefs`: run-end updates, backfill, pauses, cap) and
  `writeBrief`/`briefSpend` on the model.
- `apps/macos/PiApp/Workspaces/SidebarBriefCard.swift` (new): the hover card.
- Storage: `ChatRecord.brief` and its decoding, `MetadataStore.applyChatBrief`
  (`MetadataStore.swift`), the merge rule (`ChatRecordMerge.swift`),
  `VaultConfiguration.chatBriefs` (`ConfigurationVault.swift`).
- Wiring: a run's end (`CompletionSound.swift`), launch (`WorkspaceRestore.swift`),
  shutdown (`WorkspaceShutdown.swift`), the model's storage
  (`WorkspaceModel.swift`; going on or off invalidates the sidebar's caches),
  the utility kind (`BackgroundRequests.swift`, `WorkspaceHosts.swift`), search
  (`WorkspaceSessionOrganization.sidebarFilterMatches`), the rows
  (`SidebarChatRow.swift`, `SidebarEntryViews.swift`, `SidebarChatRows.swift`),
  Settings (`ProfileSettings.swift`, `ConnectionSettingsController.swift`,
  `WorkspaceConfiguration.swift`).
- Helper: `chat-brief` is a utility purpose (`HostService.utilityPurposes`)
  with its own short system prompt (`Resources.resolve`), no tools, no project
  context, no compaction; a tool call in its reply says which request it was
  (`SessionRun.swift`). This adds one accepted value to `session.open`'s
  `backgroundTask`; nothing else in the wire contract changed.
- Docs: `Features.md` (F24 and the search paragraph), `docs/Background-Requests.md`,
  `docs/Swift-Feature-Parity.md`, `docs/Swift-Test-Handoff.md` (the gallery).

## Needs owner decision

Each was decided conservatively; the first option is what is built.

1. **When an update runs.** (a) After a run's end once the chat has rested 2
   minutes, at most once every 30 minutes per chat (built); (b) at every run's
   end; (c) only when the reader leaves the chat or the app is idle.
2. **Backfill pace and cap.** (a) One at a time, at most one a minute, open chat
   first then newest, from 2 minutes after launch; one cap of $0.25 per 24 hours
   for all brief requests, unreported cost counted at $0.01 (built); (b) a
   larger default ($1 a day) or a faster pace; (c) cap only the backfill and let
   run-end updates through; (d) no background backfill: a chat gets its first
   brief only when opened or at its next run's end.
3. **Which chats.** (a) Main chats in a project only (built); (b) also saved
   sides; (c) also sub-agents; (d) also archived and imported chats in the
   backfill.
4. **On by default.** (a) Off until turned on (built); (b) on for run-end
   updates, backfill opt-in; (c) on for everything, under the cap.
5. **How the hover shows them.** (a) A hover card in place of the row's tooltip
   (built; screenshots below); (b) the plain tooltip with the brief first;
   (c) a second line under the row's title.
6. **Briefs while off.** (a) Kept on the records but neither shown nor searched,
   back without a new request when turned on (built); (b) deleted when turned
   off; (c) still shown and searched, only new requests stop.
7. **Brief requests on the Background requests page.** (a) Kept like every
   utility request, each with its journal (which quotes the excerpts) and its
   capture under the capture retention (built; the backfill adds one record per
   chat, the updates one per active stretch of work); (b) keep only the latest
   N brief requests; (c) list them in Usage only, without a record each.

## Tests

New, in `apps/macos/PiAppTests/ChatBriefTests.swift` (a loopback Responses
gateway, `BriefGateway`, answers the mini model with a numbered JSON brief and
a reported cost, or holds a request unanswered; journals are generated):

- `ChatBriefPlanTests` (pure): an update asks only the mini model (never the
  conversation model; the catalog's mini default; a too-small window asks
  nothing) with the earlier brief and keywords and only the rows after the one
  it read, no tool output; nothing new asks nothing; the request for the
  newest page of a 30-turn chat and of a 5,000-turn chat is the same size
  (within 100 characters), the newest reply quoted; a reply's brief is read from JSON
  anywhere in it or from lines, cleaned and capped; brief matching agrees with
  title matching (`localizedCaseInsensitiveContains`) on case, composed and
  decomposed accents, ß/SS, CJK and part boundaries; the cap counts reported
  cost and unreported requests at $0.01; a brief survives an older copy of the
  record and an older brief, and a brief this build cannot read leaves the chat
  readable; settings decode as off from an older vault, are validated, and
  carry through Settings' merge.
- `ChatBriefSettingsTests`: the switch and the cap are in Chats &
  notifications, off by default, and Save All writes them to the vault.
- `ChatBriefSearchTests`: Titles & details (and Full chats) find a main chat by
  its brief and keywords in Topics and Flat; a side's brief does not list it;
  off, nothing is found by a brief; on again, the kept brief is found.
- `ChatBriefHoverTests` (window): a row with a brief has no tooltip and brings
  up the card with the brief, the keywords and the row's state line; a row
  without one keeps its tooltip and gets no card; VoiceOver help is the brief;
  turning briefs off takes the card away and gives the tooltip back.
- `ChatBriefTests` (the packaged helper end to end): a run's end writes the
  brief through the mini model, saved on the record; the request is the brief's
  own (its session, `chat-brief` purpose in the request log, its own cost of
  $0.004, the chat's billing untouched), with the chat's own key and no project
  instructions; the chat's journal bytes are unchanged, no `.meta` is written,
  the chat is never opened in a helper; the next run's end sends the earlier
  brief and only the new rows; a run's end with nothing new sends nothing. A
  42.6 MB, 2,000-turn journal's request stays under 12,000 characters with the
  newest reply quoted. Off: neither a run's end nor the backfill asks anything;
  turned off while the mini model is answering, the request is stopped
  (interrupted) and no brief lands. A connection without a mini model is never
  asked. The backfill goes newest first and stops at the cap: two $0.01
  requests reach a $0.02 cap, the third chat is not sent. A chat whose
  connection is gone, or whose journal cannot be read, does not hold up or
  pause the others.
- Extended: `SidebarAppearanceTests.testEveryRowRedrawsWhenSomethingItShowsChanges`
  (a brief that arrives, and briefs going off, reach the row), as the row
  signature's comment asks; `MetadataDurabilityTests.testChatRecordRoundTripsEveryFieldUnchanged`
  (its fixture now sets `brief`: the guard failed until it did).
- Helper: `TitleTaskTests.testHostChatBriefSessionAsksTheMiniModelWithItsOwnInstructionsAndPurpose`
  (mini model, no tools, no project instructions, no compaction, its own
  system prompt and purpose; a tool call in the reply runs nothing and names
  the brief's request).
- Gallery: `ChatBriefGalleryTests` (below).

## Validation

Commands use `PI_BUILD_ROOT=$BUILD` and `scripts/test-macos.sh` with the
classes named; logs in `$BUILD/logs`. Window, focus, timing and gallery runs
held the full-lane lock; every heavy run waited while a131-buttons' soak held
it.

### Failing first

The tests ran against a stub that keeps the API and turns every brief
behavior off (no plan, no parse, no scheduling, no write, no search, no hover,
no setting, no helper purpose; never committed):

| Run | Result |
| --- | --- |
| `ChatBriefPlanTests`, `ChatBriefSettingsTests`, `ChatBriefSearchTests` (`red-unit.log`) | 8 tests, 52 failures |
| `ChatBriefTests` (`red-integration.log`) | 5 tests, 10 failures |
| `ChatBriefHoverTests` (`red-hover.log`) | 1 test, 5 failures |
| helper `TitleTaskTests` (`helper-titletask-red.log`) | 6 tests, 1 failure: "Unknown background task" |

The two backfill tests were added after the first green run, against the
unfixed scheduler (`red-backfill.log`): 2 tests, 4 failures (the chat after an
orphan never got its brief; an unreadable journal paused every brief).

### Mutations

Each built and run against its tests, then restored byte for byte
(`mutation-*.log`, `mutations-summary.log`):

| Mutation | Caught by |
| --- | --- |
| m1 search ignores briefs | `ChatBriefSearchTests` (6) |
| m1b folded match never matches | `ChatBriefSearchTests` (20) |
| m1c folding drops case-insensitivity | `testABriefIsFoundAsATitleWouldBe` (29) |
| m2 an update rereads the whole page | `ChatBriefPlanTests` (4); end to end (4: old messages sent again; a run's end with nothing new sends) |
| m3 no input budget | `ChatBriefPlanTests` (4: 3,352,944 characters); end to end (1: 243,785 characters for the 42.6 MB journal) |
| m4 off does not stop the request under way | `testTheSettingStopsEveryBriefRequest` (2) |
| m5 the setting is ignored | `testTheSettingStopsEveryBriefRequest` (4) |
| m6 no cap | `testTheSpendingCapStopsTheBackfill` (2) |
| m7 the conversation model when there is no mini model | `testAChatWhoseConnectionHasNoMiniModelIsNeverAskedAbout` (2) |
| m8 the chat is opened in its helper first | not caught: inconclusive. The `try?` swallowed the helper's refusal to open the generated journal, so nothing changed; replaced by m8b |
| m8b the brief is written into the chat's journal | `testARunsEndWritesTheBriefAndTheNextUpdateReadsOnlyWhatIsNew` (3: 624 bytes, not 571) |
| m9 a row with a brief keeps its tooltip | `ChatBriefHoverTests` (1) |
| m10 a card stays up when its row loses the brief | `ChatBriefHoverTests` (1) |
| m11 an older copy takes the brief back | `testABriefIsKeptOverOlderCopies…` (3) |
| m12 Settings' save leaves the choice out | `ChatBriefSettingsTests` (2) |
| m13 a chat without a connection is not set aside | `testAChatWhoseConnectionIsGoneDoesNotHoldUpTheOthers` (timed out) |
| m14 an unreadable journal counts as a failed request | `testAChatWhoseJournalCannotBeReadDoesNotPauseTheOthers` (timed out) |

### Final runs (the pushed code)

| Run | Result |
| --- | --- |
| Parallel lane (`final-parallel.log`): `ChatBriefPlanTests` 7, `ChatBriefSearchTests` 1, `ChatBriefSettingsTests` 1, `BackgroundRequestLayoutTests` 2, `ChatRecordMergeTests` 8, `CompletionSoundTests` 8, `MetadataDurabilityTests` 10, `RetrySettingsTests` 5, `SettingsRefreshRegressionTests` 1, `SidebarDocumentRegressionTests` 10, `SidebarFlatTopicsTests` 30, `SidebarMetricsLayoutTests` 10, `SidebarProjectFilterTests` 21, `SidebarSearchScopeTests` 12, `SidebarSearchSidebarTests` 10 | 136 passed, 0 failed |
| Serial lane, under the lock, `-parallel-testing-enabled NO` (`final-serial.log`): `ChatBriefTests` 7, `ChatBriefHoverTests` 1, `ChatBriefGalleryTests` 4, `BackgroundRequestsTests` 6, `BackgroundRequestLayoutParityTests` 2, `SidebarAppearanceTests` 6, `SettingsFullDocumentGeometryTests` 2, `SidebarSearchTypingTests` 2, `TitleGenerationTests` 12, `WebhookTests` 18 | 60 passed, 0 failed |
| Helper: `swift test --package-path packages/swift-host --scratch-path $BUILD/swift-verify --filter TitleTaskTests` (`helper-titletask-green.log`) | 6 passed |
| Wire: `python3 scripts/test-native-host.py $BUILD/swift-host/arm64-apple-macosx/release/pi-native-host`, the Release helper the app tests embed (`wire.log`) | 40 passed |

The concurrent and acceptance suites were not run: the only wire change is one
more accepted `backgroundTask` value, and no concurrency or acceptance path
changed. On the way to green, two existing guards failed and were answered in
this change: `MetadataDurabilityTests` (the round-trip fixture must set every
field; it now sets `brief`) and the first `ChatBriefSettingsTests` run (the
save gap below).

`SidebarSearchTypingTests` (Debug, machine load 8–13, no briefs in its
fixture; its bounds are unchanged and met): index build 6.59 s; keystroke max
36.9 ms, median 0.8 ms; main-thread stall max 55.9 ms; with 600 matches,
keystroke max 49.2 ms, median 49.0 ms, stall 48.6 ms. The 0.1.130 record had
6.07–6.11 s, 26–30 ms, 42–47 ms on a quieter machine. Debug numbers are not
evidence of speed either way; with briefs off the new path is one flag check
per chat, and its cost with briefs on is measured below.

### Gallery

22 PNGs in `$BUILD/evidence/gallery`, each opened and checked:

- `hover-{flat,topics}-{300,220}-{light,dark}.png`: the card over the briefed
  row (heading with "updated 23m ago", the brief, keywords, the row's state);
  at 220 points it overhangs the sidebar, as the skill cards do.
- `search-keyword-{light,dark}.png`: "crlf", a keyword only, lists "Error
  recovery pass" in Titles & details.
- `settings-chats-{off,on}-{light,dark}.png`: the Chat briefs card between
  Transcript and Notifications, off by default, $0.25 a day.
- `background-{all,briefs}-{1000,700}-{light,dark}.png`: the Chat briefs
  filter (a fifth tab: beside the title at 1000 points, on its own row at 700)
  and brief rows ("Chat brief", the brief · its keywords).

### Search typing cost (standalone, `-O`)

Each keystroke compares every briefed main chat. A standalone benchmark
(`swiftc -O`, 400-character briefs with 8 keywords, the stored maximum; 15
typed prefixes × 3; machine load about 10, both variants alike) of the
comparison alone:

| Briefs | `localizedCaseInsensitiveContains` (median / p95) | folded bytes (median / p95) | one-time folding |
| ---: | --- | --- | ---: |
| 1,000 | 4.34 / 9.94 ms | 0.34 / 0.43 ms | 6.3 ms |
| 5,000 | 22.02 / 51.11 ms | 1.64 / 2.10 ms | 33.6 ms |
| 30,000 | 130.77 / 296.24 ms | 9.66 / 12.87 ms | 187.8 ms |

Both found the same chats (24,600 / 123,000 / 738,000 hits). Search therefore
folds each brief once (cached per chat until its brief changes) and the query
once per keystroke, and compares bytes; `testABriefIsFoundAsATitleWouldBe`
pins it to title matching. With briefs off it costs one flag check per chat.
`SidebarSearchTypingTests` (no briefs in its fixture) keeps its bounds; see
the final runs.

## Found on the way

- Fixed (part of this change): Settings saves preferences through two
  functions that copy each field by hand (`WorkspaceModel.savePreferences` and
  `saveProfile`), besides `ConnectionSettingsController.preferenceFields`. The
  new setting was first left out of them, so Save All reported "Saved" and the
  vault kept briefs off; `ChatBriefSettingsTests` caught it (m12). The three
  lists are still separate; a new preference has to be added to all three.
- Fixed: the backfill's two stalls above (an orphaned chat picked forever; an
  unreadable journal pausing every brief).
- Not changed: a brief request that finishes while its chat is being deleted
  fails its store write (the chat's tombstone refuses it) and pauses briefs for
  10 minutes, as any failed request does. Rare; the pause is the safe side.
- Gallery note: a capture taken right after `displayIfNeeded()` with a new
  window appearance can read stale layer colors; the gallery displays and
  waits before each capture.
