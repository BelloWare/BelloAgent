# Sidebar chats: rename, delete, marks, recency, draft marker, Open Project (2026-10-11)

Workstream C, branch `work/sidebar-chats`. Swift source of truth: 0.1.122
(`apps/macos/PiApp/...`).

## What matches Swift

| Feature | Swift | Rust |
|---|---|---|
| Rename sheet: "Rename chat", subtitle = current title, field "Chat title", SUGGESTIONS heading, disabled "Suggest titles" with the no-mini-model explainer and tooltip, Cancel / Rename ("Renaming…"), Return saves, Escape/⌘W closes, 520×400 | `Workspaces/RenameChatSheet.swift` | `sidebar_chat_rename.rs` |
| Title normalization (whitespace runs → one space, U+200B, 120 graphemes, "Enter a title for this chat.") | `Storage/MetadataStore.swift` `ChatRecord.normalizedTitle` | `bello-agent-core/src/workspace_chat_lifecycle.rs` `ChatRecord::normalized_title` |
| Double-click a row renames; "Rename…" is first in the row menu | `SidebarEntryViews.swift`, `SidebarGroups.swift` `SessionOrganizationActions` | `sidebar_chats.rs` `sidebar_row_clicked`, `sidebar_actions.rs` `chat_menu_entries` |
| Delete question: "Delete this chat?" / "Delete the archived chat “T”?", managed vs imported detail text, "Delete Chat" | `WorkspaceChatLifecycle.swift` `deleteChat` | `sidebar_chat_delete.rs` |
| Delete refusals: busy/loading/queued work ("Stop work and remove queued submissions before deleting this chat") | same | `delete_refusal`, core `DELETE_WORK_NOTICE` |
| Delete data semantics: a chat that exists only on screen is discarded, nothing written; a saved chat's writer is retired (session.forget), its catalog record, draft, read state and settled receipts are removed, its *managed* checkpoint is moved to the Trash (NSFileManager trashItemAtURL, as NSWorkspace.recycle), an imported/outside file is never touched; other chats' rows and files are untouched | `performDelete` | core `WorkspaceStore::delete_chat` + app `confirm_delete_chat`, `trash_chat_files` |
| "Delete Chat…" in the row menu only for archived chats, after a divider | `SessionOrganizationActions.entries` | `chat_menu_entries` |
| Row menu order: Rename…, Pin/Unpin, Archive/Restore, [– Delete Chat…], –, Copy Session ID, Copy Session Reference, then one of Mark as Read / Mark as Unread | `SidebarChatRowView.entries` | `chat_menu_entries` (native NSMenu built from the same entries) |
| Copy Session Reference(s): Swift's line layout, heading "Bello Agent session references (N)", "---" separators, shell-quoted `cat --` line | `WorkspaceContent.swift`, `Storage/SessionReference.swift` | `sidebar_chats.rs` `session_reference`, `copy_session_references` |
| Marks: ⌘-click toggles (first one includes the open chat), ⇧-click extends from the anchor in listed order, plain click clears; one mark on the open chat is no mark; 500 limit | `SidebarSelection.swift`, `TopicSessionDrag.swift` `SidebarRowClick` | `toggle_session_mark`, `extend_session_marks`, `apply_marks` |
| Marked menu: "N chats selected", Copy Session References, Archive N / Restore N Chats, Pin All, Unpin All, Mark N as Read/Unread, Clear Selection | `SidebarEntryViews.swift` `MarkedSessionActions` | `marked_menu_entries`, `run_marked_action` |
| Batch archive never lands the reader on another chat of the same batch | `SessionOrganizationSelection.afterArchive` | `chat_organization.rs` fallback skips chats with a pending archive |
| Marked row: quiet fill + accent outline at 0.55 | `PiKitRows.swift` `styleFace` | `decorate_sidebar_row` |
| Recency wash ladder [1, 0.75, 0.5, 0.3, 0.15] of the open row's wash, order of opening, 16 remembered, survives relaunch, gone chats hold no place | `WorkspaceRecency.swift`, `PiKitRows.swift` | `sidebar_chats.rs` (`note_opened`, `RecentStore` → `chats/recent-chats.json`) |
| Draft marker: pencil 10pt, tooltip "Unsent draft", follows *committed* draft writes (not keystrokes), restored from saved drafts at launch; `holdsUnsentDraft` rules | `WorkspaceDraftMarks.swift`, `SidebarChatRows.swift`, `MetadataStore.swift` | `DraftRecord::holds_unsent`, `note_draft_mark` (hooked in `draft_changed`), `shows_draft_mark` |
| File menu: New Chat, Open Project… ⌘O, Open File…, Rename Chat…, Delete Chat…, – … | `Application/ApplicationMenus.swift` | `application_menus.rs` (Open Project opens the existing project manager, Rust's project-adding flow) |

## How it was checked

- Core: `cargo test -p bello-agent-core` (779 + integration, all pass), including
  `workspace::chat_lifecycle::tests` (normalization incl. grapheme clusters, holds_unsent,
  rename survives reopen, delete removes only the chat's rows and lists only its own
  checkpoint + UUID-named journals, refuses retained intents, outside checkpoints list no
  files, unloaded checkpoint rename takes the writer lock).
- App: `cargo test -p bello-agent-app` (717 pass, 1 pre-existing ignore). New GPUI tests in
  `sidebar_chats_tests.rs` and `sidebar_chat_delete_tests.rs` drive real handlers over a
  disposable catalog: menu entries for active/archived/pending/marked chats, ⌘/⇧ clicks and
  double-click on the real rendered rows, batch archive/restore persisted to the catalog,
  recency ranks, draft marker after the debounced save only, references text and order,
  rename of unloaded (checkpoint then catalog) and loaded (controller → snapshot → catalog)
  chats, Return/Escape keys, delete of unloaded / open archived / unsaved / outside chats with
  file-level assertions. In tests the "Trash" is `<state>/Deleted Chats`, so nothing leaves
  the temp root; in the app on macOS it is the user's Trash.
- `cargo fmt --all`, `cargo clippy --workspace --all-targets -D warnings` clean (macOS).

## Codex review

Two rounds (`codex exec review`, gpt-6.1-sol, xhigh, read-only). Fixed: deletion now refuses
a running reply, queued/held work in an unloaded checkpoint (read-only
`SessionInspectionLease` under the writer lock, held across the catalog removal) and
failed-load placeholders; settled cancellation receipts no longer block and are removed;
read state is forgotten only after a confirmed deletion; shutdown waits for rename/delete;
titles are capped to the catalog's 512 bytes on grapheme boundaries; the draft marker
follows cancellation settlements; reading acknowledgement is suspended while the sheets are
open; the startup anchor is not resurrected after deletion.

## What still differs

- No title suggestions (no mini-model titling in Rust): the sheet always shows Swift's
  no-mini-model state.
- Rename is refused for a chat that exists only on screen or is registered but has no
  checkpoint yet ("Send a first message before renaming this chat."); Swift materializes it.
  Reason: Rust's title lives in the checkpoint and the first submission sets it.
- Deleting the only chat is refused ("Create another chat before deleting this one.");
  Rust always has an open chat, Swift can show none.
- Move to Topic is not in the right-click menus (no submenu support yet); the row's Move
  button and File ▸ Move to Topic remain. Batch actions run as one organization intent per
  chat rather than one store transaction.
- Session references: Rust keeps no request accounting, so usage reads "0 requests / not
  reported"; the file line says "Conversation file (JSON)" with an adapted description
  (Rust checkpoints are JSON, not Pi JSONL); without a bound project ID it prints
  "Project folder: <path>".
- The app's own startup checkpoint (`default.json`) is treated as managed and trashed; a
  checkpoint passed with `--session` is treated like an imported original and kept, so it is
  registered again if it is the only chat at the next launch.
- Delete detail text keeps Swift's wording about memory traces; Rust has none to remove.
- Native "Delete Chat…" is not tinted red; the drawn (non-macOS) menu has no destructive tint.
- Non-macOS: "Trash" is `<state>/Deleted Chats` (files are kept, never unlinked).
- The non-macOS drawn menu and its keyboard path were edited but could not be compiled
  here (no Linux target); the Linux-only tests' key sequences were kept valid by keeping
  Pin as the initial selection.
