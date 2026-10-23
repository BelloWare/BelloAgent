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
  keywords (at most 8 × 40) complete it: about 10,000 characters at most,
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

## Validation

TBD

## Found on the way, not changed

- TBD
