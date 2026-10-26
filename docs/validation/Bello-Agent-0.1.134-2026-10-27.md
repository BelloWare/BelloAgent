# Bello Agent 0.1.134 — Ask in sidebar search

Status: **packaged; publication pending.** Marketing version 0.1.134, build 138. Previous public release: 0.1.133/build 137.

## Owner request

- 2026-10-22: the owner's idea of a mini model that keeps chat briefs and helps find chats; they chose "Briefs, then Ask" (FIND-1 shipped in 0.1.133, FIND-2 here).
- 2026-10-25: "Pick a connection": a chooser limits Ask to one connection at a time (only its chats, its mini model).
- 2026-10-26/27: release the remaining work soon, without review rounds where possible ("don't check too much for edge case that might not happen for now").

## Change

`dev/a131-ask` (Codex Sol; record `a131-ask-0.1.134.md`), merged into `dev/next` as `d449bb2f`; on `main`, `f4b3c76a` merges `dev/next`.

- **Ask** beside Titles & details and Full chats: typing stays local; Return sends one `chat-ask` background request to the chosen connection's mini model with at most 96 candidates (titles, briefs, keywords, project, topic, last activity; prefiltered by word overlap and recency, the prompt bounded by 32,000 bytes and the model's context). The validated ranking (at most 12 chats, one plain-text reason each, up to 240 characters) shows at once; the top eight then get excerpts from the library search index, or from a bounded read of the chat's newest 256 KiB / 512 records when the index has no entry, with nothing written to disk. Progress, Cancel and errors show in the result area. With chats on several connections a PiKit menu chooses the connection (Settings order; connections without a mini model disabled; the choice kept until quit). Each Ask is an "Ask chats" background request counted in Usage.
- **Rounds:** r1 `8b84c2f2`; Astra review: one P2 (rankings waited for the library-wide index) → r2 `e4c436fa` (chooser, rankings first, distinct fixtures); Astra review of r2: three P2 (uncached catalogs disabled a connection; the chooser hid when its connection emptied; an interrupted check left a transcript index on disk) and the lead's review: two P2 (a fenced or wrapped JSON ranking failed; a cold check could index a whole journal) plus P3s → r3 (`f8f6e6ea`: Sol's fixes, restored by the lead after an interrupted validation, and the lead's change that Ask's connection refreshes run only in Ask mode) → r4 `8537ba16` (emoji joiners in reasons; a stopped Ask says why; two test fixtures). No review round after r3 (owner).

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1. Focused checks only (owner): no full gate, soak, measurements, mutation runs or gallery capture for this release; 0.1.133's gate and soak cover the rest of the tree, which is unchanged since then apart from Ask.

- Sol's round-4 run on `8537ba16` (0.1.133 + Ask): 121 passed, 2 skipped (optional gallery), 0 failed: SidebarAskPlan 7, SidebarAsk 11, SidebarAskConnection 10, SidebarAskPublishing 8, SidebarAskText 2, SidebarSearchScope 12, SidebarSearchIndex 17, SidebarSearchSidebar 10, SidebarProjectFilter 21, SidebarScrollPosition 19 (+2 skipped), SidebarAskKeyboard 1, SidebarSearchKeyboard 1, SidebarSearchTyping 2.
- Lead, on the merged tree `d449bb2f`: helper Ask/utility classes 10/0; wire 41, concurrent 4, acceptance 3 against the Release helper; app BackgroundRequests, BackgroundRequestLayout, SidebarAsk, SidebarAskPlan, SidebarAskConnection, SidebarAskPublishing and SidebarSearchScope 56/0.

## Known

- Round 3's and round 4's fixes had no review round; the round-2 gallery screenshots predate round 3's layout changes (Cancel on the status line, "Details" for the first scope tab when the full labels do not fit), which were not captured again.
- A chat with no library index entry gets an excerpt only from its newest 256 KiB / 512 records; when that window cannot tell what is shown, it shows "No matching excerpt available."

## Release

RELEASE_IDENTITY
