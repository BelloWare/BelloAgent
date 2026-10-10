# macOS integration: main menu, Dock badge, completion sound (2026-10-10)

Branch `rust-macos`. Source of truth: Swift 0.1.122 `ApplicationMenus.swift`,
`WorkspaceReadState.swift` (`updateDockBadge`, `requestUserAttention`) and
`CompletionSound.swift`.

## What is implemented

**Main menu** (`application_menus.rs`, GPUI `set_menus`, macOS only). Swift's
menus, order, titles and key equivalents for every command Rust has:

| Menu | Items (Swift key) |
|---|---|
| Bello Agent | About, Settings… (⌘,), Services, Hide (⌘H), Hide Others (⌥⌘H), Show All, Quit (⌘Q) |
| File | New Chat (⌘N), Open File… (⌘P), Archive/Restore Chat, Pin/Unpin Chat, Move to Topic ▸ (Project root + topics), Mark as Read, Mark as Unread, Close Window (⌘W) |
| Edit | Undo (⌘Z), Redo (⇧⌘Z), Cut, Copy, Paste, Select All — routed to the focused GPUI editor |
| View | Show/Hide Archived Chats, Session Inspector… (⌥⌘I), Changes and History… (⇧⌘G), Next/Previous Chat (⌥⌘↓/↑), Widen/Narrow Sidebar (⌃⌘→/←, 24 pt, 200–420) |
| Conversation | Send / Queue Follow-up, Send / Steer Current Run (⌘↩), Stop (⌘.), Resume Follow-ups, Compact Now, Latest Messages, Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G, only with the find bar open), Search and Copy Conversation… (⌥⌘F) |
| Window | Minimize (⌘M), Zoom, Bring All to Front (registered as AppKit's Windows menu) |

Omitted because Rust has no such feature (never a dead item): Check for
Updates…, Open Project…, Import Pi Session…, Rename Chat…, Delete Chat…, Usage
Report, Background Requests, Show/Hide Terminal, Open Side, and the six fold
commands (`rust` now folds finished turns by click, but has no focused-turn or
fold-all command for them to call).

Routing: key bindings exist only for the menus' display (a context no view
carries), so the window handles its keys first and AppKit's menu only gets a
key the window left unhandled. The composer keeps ⌘↩, editors keep ⌘Z/⌘A,
and ⌃⌘←/→ are taken at the window before the composer's caret keys (AppKit
would give them to the menu before a text view). Availability follows Swift:
conversation commands need the workspace window to be key, no sheet/modal
and a loaded chat; Send needs an unarchived chat; Mark as Unread and Resume
Follow-ups need something to act on. GPUI menus are static and GPUI 0.2.2 keeps
every action of every `set_menus` call, so the Pin/Archive/Show Archived titles
change natively in place after a render (Swift retitles in `menuNeedsUpdate`)
and only a changed topic list rebuilds the bar.
GPUI has no native Return key equivalent, so Send / Steer gets `"\r"` natively.

**Dock badge** (`notifications.rs`): the count of chats with unread replies
(Swift `dockChats`: a failed run alone does not count, a manual unread mark
does, archived chats never). Updated on every read-state change, including
while the window is in the background. One informational Dock bounce when a
reply turns unread while another app is frontmost, not for a failed run or an
archived chat.

**Completion sound**: Tink at 0.8 volume, default on, shared by all chats;
completions within one second share a cue; nothing plays while the previous
cue is playing. A cue needs a confirmed task finish: the core counts
`completed_task_sequence` only for a checkpointed Running→Idle finish of a
final reply; tool rounds, compaction, Stop, failures, refused writes and
reopening history are silent. Consumed while muted, so turning sound on never
replays. Archived chats and shutdown are silent. Settings shows "Play task
completion sound" with Preview; Save/Cancel follow the Settings draft rules.
The setting lives in Rust's own
`~/Library/Application Support/BelloAgent-rust/notifications.json`, never in
the Swift app's preferences. `PI_APP_TESTING=1`/`BELLO_APP_TESTING=1` and test
builds never play a sound or bounce the Dock.

## Tests (GPUI TestPlatform; native menus are not available there)

- `application_menus::tests`: menu order/titles/omissions and live titles;
  every item's key equivalent equals Swift's; window-first key equivalents
  (⌘F, ⇧⌘G with and without the find bar, ⌘↩ submits once through the
  composer, ⌘, , ⌘N, ⌥⌘I and ⌃⌘←/→ through the menu path); menu commands act on
  the selected chat (pin, archive, archived toggle, send, Mark Unread/Read and
  the badge) and retitle the menus; modal owners disable chat commands.
- `in_place_retitles_name_the_titles_the_built_menus_show`: native retitles
  match the built menus' titles.
- `workspace_lifetime::tests::menu_quit_from_the_workspace_window_starts_the_close_barrier`:
  Quit with the workspace window key (failed before the fix below).
- `notifications::tests`: badge rule, Dock attention rule and an observed
  background reply raising the badge and one attention request; completion
  tracker baseline/consumption/fast follow-up; playback coalescing; preference
  default and round trip; Settings toggle/Preview/Cancel/Save.
- `read_observation_tests`: task completion survives a fast follow-up and an
  `incomplete` reply; streaming, tool rounds, Stop, failure, compaction,
  a refused write and reopening do not count.

## Gate (this Mac, rust 1.99.0)

All exit 0 (logs here): `cargo fmt --all -- --check`; clippy `-D warnings` for
`bello-agent-core --all-targets --all-features`, `bello-agent-app --all-targets`
with no features, `synthetic-authority`, `native-authority`, both, and
`--workspace --all-targets`; `cargo test`: core `--all-features` 1134 passed,
app `synthetic-authority` 843 passed, app `native-authority` 701 passed — on
the merge of `origin/rust` (`c4bfc55f`) into this branch.
Builds used a worktree-specific `RUSTC_WORKSPACE_WRAPPER` (and clippy driver
path) so the shared target directory never mixed this worktree's workspace
crates with another worktree's.

## Native check (this Mac)

A debug build (the disk had about 1.3 GB free, too little for a release
build), launched with a scratch `HOME` and project, a loopback gateway
(`benchgw.py`, fake key) and `BELLO_APP_TESTING=1` so nothing was audible:

- System Events lists the six menus with Swift's titles, enabling and key
  equivalents (`native-menus.txt`; the app menu carries the executable's
  name because the binary ran outside a bundle). AppKit adds its own
  AutoFill/Dictation/Emoji, Full Screen and window-tiling items, as for Swift.
- Send / Steer shows ↩ (glyph 11); typing during a running reply and pressing
  ⌘↩ added exactly one steering message (session file: two user messages).
- Clicking View ▸ Show Archived Chats and File ▸ Pin Chat retitled them to
  Hide Archived Chats and Unpin Chat; Mark as Unread became enabled after the reply.
  After the in-place retitle change, Show/Hide Archived Chats toggled both ways
  on the merged build.
- ⌥⌘I opened the Session Inspector through the menu; with the inspector key,
  the Conversation commands were disabled.
- A reply that finished while the app was hidden set the Dock badge to `1`
  (Dock `AXStatusLabel`); showing the chat again cleared it.
- ⌘Q from the inspector and Quit Bello Agent from the workspace window both
  quit the app. The second failed before the fix (GPUI ran the global Quit
  listener inside the workspace window's own update, so updating that window
  again failed silently); `request_quit` now defers.

The app was quit after each run and the gateway stopped; no badge or sound was
left, and the Swift app's preferences were not touched.

## Remaining differences

- Swift enables app-level File/View commands (New Chat, Archive, …) while an
  inspector window is key; in Rust they need the workspace window key.
- Edit commands act only when a GPUI editor has focus and are disabled
  elsewhere; Swift's AppKit responder chain can also reach other text views.
- Native sound playback and the Dock bounce were not heard/seen in this check
  (kept silent on purpose); their policy is tested.
- Release-build native acceptance, IME and VoiceOver were not part of this.
