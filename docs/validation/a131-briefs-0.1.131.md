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
the sidebar rows were touched; round 2 merged `dev/next` at `de221981` (the
owner's decisions, a131-buttons, a131-blanktext, LIMIT-2). Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-briefs` (`$BUILD` below);
text logs in `$BUILD/logs`, images in `$BUILD/evidence/gallery` (round 1) and
`$BUILD/evidence/gallery-r2` (round 2). Generated
journals, a loopback gateway and the isolated test host only: no installed app,
real preferences, real chats, Keychain, paid provider or `xctrace`.

## Round 2: the owner's decisions and Astra's review (2026-10-23)

The owner's answers to round 1's decisions, as the lead relayed them:

1. Briefs **on by default**, updated at the end of runs; **no background
   backfill**.
2. **No spending cap**: the cap and its setting are gone.
3. **Brief usage beside the setting**: requests and spend today and over the
   last 30 days, from the request archive; the Background requests page's
   Chat briefs filter and the Usage count stay.
4. **Manual writing** for chats without a brief: **Write Brief** in the row's
   menu and in the hover card where the brief would be; in Settings, **Write
   Briefs for N Chats**, one at a time, with its progress and spend, and
   stoppable.
5. **Which chats**: main chats **and saved (kept) sides**.
6. **Every run's end**, with no 2-minute rest and no 30-minute spacing; never
   two requests at once for one chat: a run that ends while that chat's brief
   is in flight gets one more update after it, exactly once.

Unchanged, as decided: the hover card; off keeps briefs stored but hidden;
each request is its own background request.

Astra's review of `3d7b5893`, and what answers it:

- **[P1] The source chat's connection was not rechecked before dispatch**
  (`WorkspaceChatBriefs.swift:319`). `writeBrief` now holds the chat's
  connection lease (`connectionLease(for:)`) from before the first read: it
  waits out a connection change under way first, rechecks the lease once the
  model listing and the history read are done, before the request is built,
  and passes it to `askMiniModel(…, sourceLease:)`, which checks it again
  immediately before `turn.submit`, after the request's own chat is opened.
  A chat moved meanwhile sends nothing through the connection it left
  (`connectionChanged`); it is asked again, once, on the connection it is on.
- **[P2] Work could be pending with nothing scheduled.** There is no timer or
  deadline left: a run's end, Write Brief or a Write Briefs step starts the
  request at once, or, while that chat's request is in flight, marks it
  pending; the request's end takes the mark and starts the one update. Off,
  Stop and shutdown cancel what runs and drop every mark.
- **[P2] The update after an in-flight request ran on a stale deadline, or
  not at all.** The pending update starts when the request in flight ends,
  exactly once however many runs ended meanwhile, and reads on from where
  that request read to.

## What it does

- **A brief per chat.** At the end of every run, the chat's connection's mini
  model writes one or two sentences on what the chat is about and where it
  stands, and up to six keywords someone would search for (topics, files,
  tools, errors, names). The next update sends the earlier brief and keywords
  plus **only the rows after the one the brief read last**, so an update costs
  the same whether the chat is ten turns long or two thousand. A run's end with
  nothing new since the brief sends nothing.
- **One request at a time per chat.** A run that ends while the chat's brief is
  being written does not start a second request; the chat gets exactly one more
  update when the first one ends, however many runs ended meanwhile.
- **Bounded input.** The request reads the chat's newest page (60 rows, the
  history reader's), quotes only user and assistant text (no tool output,
  notices or summaries), each message clipped to 1,200 characters (start and
  end kept), newest first until 8,000 characters are used, then in the order
  they were said. A page that starts inside a long turn also quotes that turn's
  request. The title (120 characters), the earlier brief (at most 400) and its
  keywords (at most 8 × 40) complete it: at most about 11,000 characters,
  whatever the journal's size. Output is capped at 512 tokens; the mini model's
  lowest offered effort is used, as for titles.
- **Chats without one.** Nothing is written in the background. A chat without
  a brief gets one at its next run's end, from **Write Brief** (its row's menu,
  "Writing Brief…" while it is written, or the button on its hover card), or
  from Settings' **Write Briefs for N Chats**: every chat that can have one and
  has none, one request at a time, newest activity first, a chat that is being
  written already counted when it ends. Settings shows "3 of 12 chats · 2
  written · $0.008 so far" and Stop; Stop also stops the request it waits on
  (a run's end that came meanwhile still gets its update). Three failed
  requests in a row stop it, with the reason. A chat whose connection has no
  mini model, or whose journal cannot be read, is passed over.
- **No spending cap.** Beside the switch, Settings shows the brief requests of
  today and of the last 30 days, counted as the Background requests page lists
  them, with the cost the gateway reported for them from the request archive,
  and how many reached it without a reported cost.
- **Which chats.** The reader's own saved main chats and saved sides in a
  project. Never an unsaved side, a sub-agent, imported history, a background
  request or connection test, or a chat not yet sent. Archived chats keep their
  briefs and can be asked with Write Brief, but get none on their own
  (see the decisions below). A chat whose connection has no mini model (none
  chosen, none in its catalog) is never asked about, and the conversation model
  is never used instead.
- **Its connection only.** The chat's connection is held from the first read to
  the moment the request is sent; a chat moved to another connection meanwhile
  sends nothing through the one it left and is asked again, once, on its new
  one.
- **Search.** Sidebar search's Titles & details (and Full chats, which includes
  the same details) finds a chat by its brief or a keyword, in Topics and
  Flat, compared as titles are. A saved side is found by its own brief and
  listed under its chat, as a title match lists it.
- **Hover.** Resting the pointer on a row brings up a card beside it (the
  app's `PiHoverCardPresenter`, as skill pills use, now with an opt-in
  interactive mode and a trailing placement): "Brief · updated 5m ago", the
  brief, its keywords and the row's state and figures; for a chat without a
  brief, "No brief yet." and **Write Brief** (or "Writing the brief…"; after
  a request that wrote none, why: no mini model, unreadable history, or the
  failure). The card replaces the row's tooltip. It sits beside the row, its
  top level with the row's, so it covers no other row; the pointer can move onto it (it stays
  while the pointer is on the row or the card, and goes 300 ms after it left
  both, or at a press elsewhere, a scroll or a key); it never takes focus.
  VoiceOver reads the brief as the row's help; the row's menu has Write Brief.
- **Setting.** Settings → Chats & notifications → Chat briefs: **Write chat
  briefs** (on unless turned off), the two usage rows, and **Chats without a
  brief** with its button. Off stops every request under way and Write Briefs,
  and hides briefs from search and hover; the kept briefs come back without
  being asked for again when it is turned on. Turning it on asks nothing by
  itself.
- **Where it is kept.** `ChatRecord.brief` (text, keywords, the row it read
  last, when, the chat activity it covers), written only by
  `MetadataStore.applyChatBrief` onto the record the store holds; a copy read
  before it landed, or an older brief, never takes it back
  (`ChatRecordMerge`). A brief this build cannot read reads as none, never as an
  unreadable chat. Deleting a chat deletes its brief with its record. A vault a
  development build wrote with the dropped `dailyCapUSD` still reads.
- **Nothing enters the conversation.** The brief request is a background
  request of its own ("Chat brief", purpose `chat-brief`): a chat outside every
  project with its own journal, captured requests and billing, sent through the
  chat's own connection and key. The chat itself is only read; it is never
  opened in its helper, its journal is not written, and its model context never
  sees a brief.
- **Spend in Usage.** Each request is kept on the Background requests page
  (the **Chat briefs** filter; the brief and keywords as its result) and in
  Usage under the purpose `chat-brief`.

## Code

- `apps/macos/PiApp/Workspaces/ChatBriefPlan.swift` (new in round 1): `ChatBrief`,
  and the request (`ChatBriefPlan`: mini model, bounded excerpts, prompt) and
  how a reply is read (JSON anywhere in it, or "Brief:"/"Keywords:" lines;
  cleaned and capped).
- `apps/macos/PiApp/Workspaces/WorkspaceChatBriefs.swift`: the setting
  (`enabled` only, on by default), `ChatBriefBatch`, `ChatBriefUsage`, and
  `ChatBriefs` (round 2: no timers; `write` at a run's end or on request, one
  task per chat with one pending update, `startBatch`/`stopBatch` one at a
  time, published `writing` and `batch`), and on the model `writeBrief` (the
  connection lease held through dispatch), `briefUsage(since:for:)`,
  `offersBrief`, `writeBriefNow`, `lastProblem`, the eligibility (saved sides
  included; archived chats only by Write Brief).
- `apps/macos/PiApp/Workspaces/ChatBriefSettingsCard.swift` (new in round 2):
  the Settings card (switch, usage rows, Write Briefs with progress, spend
  and Stop).
- `apps/macos/PiApp/Workspaces/SidebarBriefCard.swift`: the hover card, with
  Write Brief, "Writing the brief…" and why the last request wrote none for a
  chat without a brief, shown beside the row and kept current while it is up.
- `apps/macos/PiApp/Design/PiHoverCard.swift`: opt-in `interactive` (the panel
  takes the pointer; a tracking area on the card and a 300 ms grace keep it up
  while the pointer moves between the control and the card; a press on the
  card is the card's own), `placement` (`.trailing`: beside the control, top
  level with it), `refresh(over:width:view:)` (a shown card rebuilt without
  fading), and a `pointerLocation` seam. Off by default: skill pills are
  unchanged.
- `apps/macos/PiApp/Workspaces/WorkspaceTitleGeneration.swift`:
  `askMiniModel(…, sourceLease:)` rechecks the source chat's connection just
  before `turn.submit` (title suggestions and webhooks pass none: unchanged).
- Search: `WorkspaceSessionOrganization.sidebarFilterMatches` matches a brief
  for every eligible chat, saved sides included; the other details still follow
  the main-chat list.
- Rows: `SidebarChatRowState.offersBrief` (added to the row's signature, and
  to `SidebarAppearanceTests` as its comment asks), `ChatRowBodyView.Content.offersBrief`,
  the card's content and Write Brief (`SidebarChatRows.swift`), the row's menu
  and action binding (`SidebarEntryViews.swift`).
- Removed: the launch backfill (`WorkspaceRestore.swift`), the cap's
  validation (`ConfigurationVault.swift`), the scheduler's timers, pauses,
  cap, settled and no-mini-model cooldown, `briefSpend`.
- Unchanged from round 1: storage (`ChatRecord.brief`, `MetadataStore.applyChatBrief`,
  `ChatRecordMerge`, `VaultConfiguration.chatBriefs`), the run's-end hook
  (`CompletionSound.swift`), shutdown, the utility kind and filter, the save
  paths, and the helper's `chat-brief` purpose and prompt (no helper change in
  round 2).
- Docs: `Features.md` (F24), `docs/Background-Requests.md`,
  `docs/Swift-Test-Handoff.md` (the gallery), `NEXT-RELEASE.md` (FIND-1).

## Lead decisions (round 2, 2026-10-23)

The lead kept the first option of each; the owner can change any of them.

1. **Archived chats.** (a) They keep their briefs, and Write Brief works on
   them, but a run's end and Write Briefs leave them alone, as round 1's
   backfill did (round 1's option "also archived chats in the backfill" was not
   chosen) (kept); (b) treat them as every other main chat.
2. **Write Briefs and failures.** (a) Three failed requests in a row stop it,
   with the reason (kept); (b) go on to the end whatever fails; (c) stop at
   the first failure.
3. **The card for a chat without a brief.** (a) The card, with "No brief yet."
   and Write Brief, replaces the row's tooltip whenever briefs are on (kept);
   (b) such rows keep their tooltip, and Write Brief is in the menu only.
4. **What the usage rows count.** (a) Every brief request the Background
   requests page lists (failed and stopped ones too) with the cost the gateway
   reported (kept); (b) completed requests only.

## Tests (round 2)

In `apps/macos/PiAppTests/ChatBriefTests.swift`. The loopback Responses
gateway (`BriefGateway`) answers the mini model with a numbered JSON brief and
a reported cost, with nothing usable while told to, or holds requests and
answers them when let go; journals are generated.

- `ChatBriefPlanTests` (pure, 7): round 1's plan, size, parsing, search and
  storage tests, plus `testUsageCountsEveryRequestAndWhatTheGatewayReported`
  (every request counts; the cost is what the gateway reported; one never
  dispatched, or not in the archive yet, is a request at $0.00; one that came
  back without a cost is noted under the row; one still running is not), and
  `testBriefsAreOnUnlessTurnedOffAndTheChoiceIsKept` in place of round 1's
  off-by-default test (on in a new and an older vault; off is kept; a vault a
  development build wrote with `dailyCapUSD`, even an invalid 101, reads and
  validates; Settings' merge carries the choice).
- `ChatBriefSettingsTests` (1): on by default, no cap control; the usage rows
  read "None" from the archive; Chats without a brief: none ("Every chat has a
  brief.", the button off), two main chats and a saved side without one ("Write
  Briefs for 3 Chats"; a briefed chat and a background request are not
  counted), switched off but not saved ("Chat briefs are off."), saved off, and
  switched on but not saved ("Save to turn chat briefs on, then write them
  here.").
- `ChatBriefSearchTests` (1): as round 1, and a saved side is found by its own
  brief, listed under its chat exactly as a match on its title lists it; its
  chat is not found by the side's brief.
- `ChatBriefHoverTests` (window, 1): the card sits beside the row (its left
  edge 6 points after the row's trailing edge, its top level with the row's)
  and takes the pointer; it stays while the pointer is on the card and goes
  once the pointer is off both; a chat without a brief has no tooltip and its
  card says "No brief yet." with Write Brief; a click sent to the card's panel
  as the window server sends one (the panel is never key) asks for the brief
  and puts the card away; the row's menu offers Write Brief only without a
  brief; while the brief is written (here waiting out a connection change) the
  card says "Writing the brief…" and the menu "Writing Brief…", disabled; once
  done, the card still up offers Write Brief again and says why none was
  written ("no mini model"); off, no card, no Write Brief, the tooltip back.
- `ChatBriefTests` (the packaged helper end to end, 12):
  - a run's end writes the brief and the next one updates it with only what is
    new (round 1's test, now with no rest and no spacing);
  - a 42.6 MB, 2,000-turn chat's request stays within the budget (round 1);
  - `testARunThatEndsWhileItsBriefIsWrittenGetsExactlyOneMoreUpdate`: two runs
    end while the first request is held; one update waits; no second request
    while the first is in flight; exactly one more after it, with the earlier
    brief and only the two new turns;
  - `testWriteBriefAsksForOneChatAndItsMenuSaysSoWhileItIsWritten`: an archived
    chat's run's end asks nothing and Write Briefs leaves it out; Write Brief
    asks at once; "Writing Brief…" while held; nothing to offer once it has a
    brief;
  - `testASavedSideGetsItsBriefAndAnUnsavedSideNever`: a saved side's run's
    end writes its own brief (its own messages only), and search finds it; a
    side open but not saved gets nothing at its run's end or from Write Brief;
  - `testWriteBriefsGoesOneAtATimeNewestFirstAndPassesOverChatsThatCannotHaveOne`:
    a chat whose connection is gone and one whose journal is gone are passed
    over, an archived chat and a briefed one are not asked; one request at a
    time (none other while the first is held), newest first; 3 written of 5; a
    run that ends on the briefed chat meanwhile gets its own update beside the
    batch; the archive has $0.016 for the four brief requests since the batch
    began, and the batch's spend is its own three, $0.012;
  - `testWriteBriefsStopsWhenToldAndAfterThreeFailedRequestsInARow`, driven
    through Settings' card: "0 of 4 chats · 0 written · …" and Stop; Stop stops
    the request it waits on (interrupted) and nothing more is asked; a running
    request is not one "without a reported cost" and, stopped, it is; with
    replies holding no brief, the third failure in a row ends it and the fourth
    chat is never asked;
  - `testTheSettingStopsEveryBriefRequest`: off, neither a run's end, Write
    Brief nor Write Briefs asks anything; turned on, nothing is asked by itself;
    turned off while the mini model answers, the request stops and no brief
    lands;
  - `testALaunchAsksNothingForChatsWithoutABrief`: a launch (`restore`) over a
    store of chats without a brief asks nothing (2 s), and Settings offers them;
  - `testAChatWhoseConnectionHasNoMiniModelIsNeverAskedAbout`: at a run's end
    or from Write Brief;
  - `testAChatMovedToAnotherConnectionWhileItsBriefIsPreparedSendsNothingThroughTheOldOne`
    (P1): two gateways; the chat moves to the second between the reads and the
    request (through the `beforeDispatch` seam, doing to the chat what
    `setConnection` does to its lease: the connection generation bumped, the
    record on the new connection; the real switch also rebinds a journal in the
    project's Sessions folder, where this fixture's journals are not); nothing
    reaches the first, one request reaches the second with its own key, one
    background request is kept, on the new connection; and `askMiniModel` with
    a lease taken before a move sends nothing;
  - `testUsageBesideTheSettingCountsTodayAndTheLast30Days`: today 1 request
    · $0.004; 30 days 2 (a request from ten days ago counts, one from forty days
    ago and a title request do not).
- Removed with what they tested: round 1's cap tests and its two backfill
  tests (their cases, an orphaned chat and an unreadable journal, are in the
  Write Briefs test now).
- Changed elsewhere because of the default: `WebhookTests.testAFinishedChatSendsItsWebhookWithTheMiniModelsParameters`
  (a finished run now also asks for the chat's brief: the webhook's request is
  picked by its own session, not as the first mini-model request; it failed
  until then); `UIScreenshotTests` (its fixture turns briefs off, so its
  Background requests and usage scenes stay as they are described; not run
  here: it is the full gallery, and only its vault changed); `SoakTests`, at
  the lead's request (its fixture turns briefs off through
  `gatewayWorkspace(chatBriefs:)`, and it fails if any launch lists a brief
  request).
- `SidebarAppearanceTests.testEveryRowRedrawsWhenSomethingItShowsChanges`:
  extended for `offersBrief`, as the row signature's comment asks.
- Gallery: `ChatBriefGalleryTests` (4 tests, below).

## Validation (round 2)

Commands use `PI_BUILD_ROOT=$BUILD` and `scripts/test-macos.sh` with the
classes named; logs in `$BUILD/logs`. Window, focus, timing and gallery runs,
and every mutation, held the full-lane lock, and waited while another
workstream's soak held it. No helper change in round 2: the helper's tests and
the wire suite were not run again.

### Failing first

The new and changed tests ran against a stub that puts round 1's behavior
back where round 2 changes it, keeping the API the tests compile against
(off by default; a run's end during a request dropped; no retry and no
connection recheck; no Write Briefs; no usage; main chats only in eligibility
and search; no Write Brief in the menu or the card; the card under the row,
not reachable, kept beside the tooltip; a launch that starts writing briefs;
never committed, `brief-stub2.py`):

| Run | Result |
| --- | --- |
| `ChatBriefPlanTests`, `ChatBriefSettingsTests`, `ChatBriefSearchTests` (`r2-stub-parallel.log`) | 9 tests, 18 failures: the default-on, settings and search tests failed; the usage test passed (it tests the new type's sums, which the stub left alone) |
| `ChatBriefHoverTests` (`r2-stub-hover.log`) | 1 test, 7 failures |
| `ChatBriefTests` (`r2-stub-e2e.log`) | 12 tests, 11 failed (25 failures); `testTheSettingStopsEveryBriefRequest` passed: round 1 already stopped everything while off, and its new parts are mutations m23 and m26 below |

The assertions added after that run (archived chats, a running request's
cost, the switch as shown, the card's note, the row signature) each have a
mutation below.

### Mutations

Each built and run alone against the tests named, under the lock, then
restored byte for byte (`mut-*.log`; `r2-mutations.txt`). All 38 caught.

| Mutation | Caught by |
| --- | --- |
| m1 off by default | `testBriefsAreOnUnlessTurnedOffAndTheChoiceIsKept` |
| m2 a run's end during a request is dropped | `testARunThatEndsWhileItsBriefIsWrittenGetsExactlyOneMoreUpdate` (nothing waits) |
| m3 every run's end starts its own request | the same test (3 requests in flight for one chat, 3 sent instead of 2) |
| m4 no second try on the new connection | the P1 test (no brief is written). First built with a reference the compiler refused; fixed and run again |
| m5 no recheck before the request is built | the P1 test (a failed request lands on the old connection: `["profile", "profile-b"]`) |
| m6 no recheck just before `turn.submit` | the P1 test (the stale-lease request is sent) |
| m7 main chats only | `testASavedSideGetsItsBriefAndAnUnsavedSideNever` |
| m8 unsaved sides allowed | the same test (2 requests, not 1) |
| m9 Write Briefs does not wait for each request | the batch test (never exactly one request in flight) |
| m10 oldest first | the batch test (order) |
| m11 no stop after three failures | the stop test (4 requests, not 3) |
| m12 Stop leaves the request it waits on running | the stop test |
| m13 a 45-day window | the usage test |
| m14 every kind of background request counted | the usage test |
| m15 "today" over 30 days | the usage test |
| m16 the card above or below the row | the hover test (x 132, not 388) |
| m17 the card not interactive | the hover test (not reachable; gone when the pointer reaches it; the press never arrives) |
| m18 no Write Brief in the menu | the Write Brief test |
| m19 no "Writing Brief…" | the Write Brief test |
| m20 no button on the card | the hover test |
| m21 the shown card not kept current | the hover test (still "Writing the brief…" once done) |
| m22 the tooltip kept beside the card | the hover test |
| m23 turning briefs off stops nothing | `testTheSettingStopsEveryBriefRequest` |
| m24 a launch starts Write Briefs | `testALaunchAsksNothingForChatsWithoutABrief` |
| m25 search matches main chats' briefs only | `ChatBriefSearchTests` |
| m26 Write Brief works while off | `testTheSettingStopsEveryBriefRequest` |
| m27 the pending mark never cleared | the one-more-update test (1,144 attempts, not 2) |
| m28 today's row shows the 30 days' figure | the usage test |
| m29 an interactive card goes at once when the pointer leaves the row | the hover test |
| m30 the pointer's place ignored | the hover test |
| m31 chats with a brief counted for Write Briefs | the batch test |
| m32 the batch's spend counts every brief request | the batch test (4 requests, not 3). Missed at first: the test had no brief request outside the batch; it now ends a run on the briefed chat during the batch, and the batch's spend leaves that request out |
| m33 an archived chat's run's end asks | the Write Brief test |
| m34 archived chats in Write Briefs | the batch test |
| m35 `offersBrief` left out of the row's state | `SidebarAppearanceTests.testEveryRowRedrawsWhenSomethingItShowsChanges` |
| m36 a running request counted as without a cost | the stop test |
| m37 the batch row ignores the switch as shown | `ChatBriefSettingsTests` |
| m38 no note on why no brief was written | the hover test |

### Final runs

| Run | Result |
| --- | --- |
| Parallel lane (`r2-final-parallel-2.log`): `ChatBriefPlanTests` 7, `ChatBriefSettingsTests` 1, `ChatBriefSearchTests` 1, `BackgroundRequestLayoutTests` 2, `CompletionSoundTests` 8, `ConversationFamilyTests` 22, `DraftMarkTests` 5, `RetrySettingsTests` 5, `RunHoldTests` 18, `SessionOrderingTests` 5, `SettingsRefreshRegressionTests` 1, `SidebarBindingActionTests` 3, `SidebarDocumentRegressionTests` 10, `SidebarFlatTopicsTests` 30, `SidebarMetricsLayoutTests` 10, `SidebarProjectFilterTests` 21, `SidebarRecencyTests` 4, `SidebarSearchScopeTests` 12, `SidebarSearchSidebarTests` 10, `SubagentDisplayTests` 8, `SubagentOrganizationTests` 13, `SubagentPanelTests` 8, `WebhookExchangeTests` 5 | 209 passed, 0 failed |
| Serial lane, under the lock, `-parallel-testing-enabled NO`, with the gallery (`r2-final-serial-2.log`): `ChatBriefTests` 12, `ChatBriefHoverTests` 1, `ChatBriefGalleryTests` 4, `BackgroundRequestsTests` 6, `BackgroundRequestLayoutParityTests` 2, `CompactionResponsivenessTests` 1, `InlineSkillPillTests` 16, `MiniModelSettingsTests` 1, `SessionReadStateTests` 16, `SettingsFullDocumentGeometryTests` 2, `ShellParityTests` 15, `SidebarAppearanceTests` 6, `SidebarInteractionTests` 9, `SidebarNativeBindingTests` 4, `SidebarRowDragTests` 4, `SidebarSearchTypingTests` 2, `TitleGenerationTests` 12, `TopicOrganizationTests` 14, `WebhookTests` 18 | 145 passed, 1 skipped (`InlineSkillPillTests.testCaptureSkillPillLooks`, which needs `PI_APP_UI_SCREENSHOT_ROOT`), 0 failed |
| `ChatBriefTests` and `ChatBriefHoverTests` again after the batch test was strengthened (`r2-final-e2e.log`) | 13 passed, 0 failed |
| After merging `dev/next` again (`f1331028`: PERF-3, SCROLL-1, EDIT-2, the new plan lines; `SidebarEntryViews.swift` and the project file merged without conflict), parallel (`r2-post-merge-parallel.log`): the three brief classes, `ChatSwitchRefreshTests` and `LiveAccountingTests` (new or changed there) and 13 sidebar and settings classes above | 147 passed, 0 failed |
| The same, serial, under the lock (`r2-post-merge-serial.log`): `ChatBriefTests`, `ChatBriefHoverTests`, `SidebarAppearanceTests`, `StatPillRollTests`, `SubagentReaderTests`, `TranscriptRevealTests` (changed there), `SidebarInteractionTests`, `SidebarNativeBindingTests`, `SessionReadStateTests`, `WebhookTests`, `InlineSkillPillTests`, `TitleGenerationTests` | 168 passed, 1 skipped (the same capture), 0 failed |
| `SoakTests`, briefs off in its fixture, a short run under the lock: `TEST_RUNNER_PI_SOAK_SECONDS=20`, the stall and launch limits raised to 5,000 and 60,000 ms because this is a Debug build and the check is about requests, not speed (`r3-soak-short-2.log`) | passed: 18 seeded runs and the cycles after them, no brief request listed |
| The same with the fixture's briefs left on (`r3-soak-mutant.log`; not committed) | failed as it should: 17 brief requests |
| The same serial lane before the `WebhookTests` fix, and without the last two classes (`r2-final-serial.log`) | 143 passed, 1 skipped, 1 failed: `WebhookTests.testAFinishedChatSendsItsWebhookWithTheMiniModelsParameters` took the run's brief request for the webhook's (below) |

The classes are those whose code or fixtures round 2 touches: the hover
presenter (skill pills), `askMiniModel` (titles, suggestions, webhooks), the
sidebar's search, rows, menus and signature, Settings, the vault's
validation, and every fixture that gives its connection a mini model and so
now sends brief requests (`CompactionResponsivenessTests`,
`MiniModelSettingsTests`, `TitleGenerationTests`, `WebhookTests`).

### Gallery

36 PNGs in `$BUILD/evidence/gallery-r2` (round 1's 22 stay in
`$BUILD/evidence/gallery`), from the final serial run, each opened and checked:

- `hover-brief-{flat,topics}-{300,220}-{light,dark}.png`: the brief's card
  beside its row, its top level with the row's, over no other row; at 220
  points it starts just past the row's body, over the sidebar's edge.
- `hover-write-{flat,topics}-{300,220}-{light,dark}.png`: "No brief yet.",
  Write Brief and the row's state, for "Welcome screen copy".
- `settings-chats-off-{light,dark}.png`: switched off, not saved: usage "None",
  "Chat briefs are off.", Write Briefs unavailable.
- `settings-chats-on-{light,dark}.png`: on by default: "None" twice, "5 chats
  have no brief yet. Each is asked for one in turn, newest first, on its own
  connection." and Write Briefs for 5 Chats.
- `settings-chats-writing-{880,640}-{light,dark}.png`: under way: "1 of 5
  chats · 1 written · $0.004 so far" and Stop; the usage rows as the archive
  had them at that moment (1 or 2 requests, $0.004; the second, still running,
  is never "without a reported cost"); at 640 points everything fits.
- `settings-chats-done-{light,dark}.png`: "Wrote 5 briefs for 5 chats ·
  $0.02"; both usage rows "5 requests · $0.02"; Write Briefs unavailable (none
  left).
- `search-keyword-{light,dark}.png` and `background-{all,briefs}-{1000,700}-{light,dark}.png`:
  as in round 1.

The first gallery run of round 2 showed the usage row's text running past the
card at 640 points (it carried "· 1 without a reported cost", for a request
still running) and Write Briefs offered while the switch showed off; both are
fixed above (the note under the row, running requests not counted, the batch
row following the switch as shown and as saved).

## Found on the way (round 2)

- **The default reaches other fixtures.** With briefs on by default, every
  finished run in a fixture whose connection has a mini model also sends a
  brief request (the bundled catalog has no mini default, so only fixtures
  that set `miniModelId` do). `WebhookTests` took the first mini-model request
  for the webhook's and failed; it now picks the webhook's own session.
  `UIScreenshotTests` turns briefs off in its fixture (its scenes list the
  background requests they expect). `TitleGenerationTests`,
  `CompactionResponsivenessTests` and `MiniModelSettingsTests` pass with briefs
  on. **For the lead:** `SoakTests` gives its connection a mini model
  (`gatewayWorkspace(miniModel: "fixture-fast")`), so each finished run in the
  soak now also sends a brief request. `ui-gateway.py` answers a brief's
  prompt as any other prompt (it treats only a webhook's prompt as data), so
  its replies hold no brief, or a scenario's tool call when the quoted chat
  names one: each is a failed request. At the lead's request its fixture now
  turns briefs off (`gatewayWorkspace(chatBriefs: false)`), so soak numbers stay
  comparable with earlier releases, and the soak checks that no launch lists a
  brief request. No other soak or perf harness gives its connection a mini
  model (`PerformanceBaselineTests` and the other `PI_PERF` tests, the launch
  and benchmark fixtures), so none of them sends a brief request.
- **A card that hides itself from its own button.** `PiHoverCardPresenter.hide()`
  released the panel at once; pressing a button on an interactive card that
  hides it would have released the panel while it was still handling the
  click. The panel now outlives the event (released on the next turn of the
  main queue). Skill pills never press anything on their cards.
- **Settings refreshes only for its own inputs.** `ProfileSettingsView.refresh()`
  returns early unless its section's inputs changed, so a card that shows live
  state (here the usage and the Write Briefs progress) has to watch that state
  itself; `ChatBriefSettingsCard` watches `ChatBriefs.batch` and `writing`.
- Test note: the synthesized click in `ChatBriefHoverTests` needs the card
  laid out first (`layoutIfNeeded`); a click sent before the first layout pass
  hit an unplaced button (one run of three before the fix). On screen the card
  is always laid out before it can be clicked.

## Round 1 (2026-10-22, `3d7b5893`)

Round 1 built briefs off until turned on; an update once a chat had rested 2
minutes after a run's end, at most every 30 minutes; chats without a brief
filled in one a minute from 2 minutes after launch (the open chat first, then
newest); one daily cap ($0.25, unreported requests at $0.01) over every brief
request; main chats only; the hover card above or below the row. Its plan,
size, parsing, search, storage, helper and hover evidence below still holds;
its scheduler, cap and backfill tests were replaced in round 2 (above).

### Round 1 tests

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

### Round 1 validation

Commands use `PI_BUILD_ROOT=$BUILD` and `scripts/test-macos.sh` with the
classes named; logs in `$BUILD/logs`. Window, focus, timing and gallery runs
held the full-lane lock; every heavy run waited while a131-buttons' soak held
it.

#### Failing first

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

#### Mutations

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

#### Final runs (the pushed code)

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

#### Gallery

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

#### Search typing cost (standalone, `-O`)

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

### Found on the way (round 1)

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
