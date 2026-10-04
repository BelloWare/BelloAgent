# Two-chat / durable-draft development checkpoint

This extends the source-only Rust checkpoint `07c6a2b2c7052f91e0157b452964ed697b1d5078`.
It preserves the existing Projects sidebar, New Chat controls, conversation and
composer layout. It is not complete multi-project or tool-loop parity.

## Implemented scope

- Multiple independent chats in **one explicitly selected project**. The existing
  New Chat button, project-row plus button, and Ctrl/Command-N create a pending
  chat; existing sidebar rows switch chats. Hidden runs keep their own controller,
  queue, composer, errors and completion routing. Stop addresses its own chat.
- Empty New Chat is reused and writes no chat record or session file. A nonempty
  pending draft stays in memory across navigation and is materialized on first
  use or successful quit-flush. This distinction follows
  `WorkspaceChatLifecycle.swift` and `DeferredCreationTests.swift`.
- Saved-chat drafts use revisioned 150 ms background debounce. Remembered selection
  uses 250 ms debounce. A late save or load cannot replace newer text; cold load
  preserves the editor entity, undo/focus state, draft generation and held-edit
  metadata. No new message is automatically sent on reopen.
- Drafts are separate from transcript checkpoints. They include the rewrite,
  original queued text, edit identity and displaced ordinary draft. Recovery
  reconciles committed Save/Cancel/Remove outcomes without trapping the composer
  or silently losing an unsaved rewrite.
- Return clears the composer immediately so later typing is a new draft. Every
  in-flight draft write atomically retains the captured submission receipt before
  replacing submitted text. Identical receipts are idempotent; conflicting ones
  fail. Per-chat settled revision barriers stop late debounces from resurrecting
  acknowledged or definitively rejected submissions.
- Uncertain acceptance retains a recovery receipt. Reopen reconciles accepted
  turn IDs; remaining receipts show an explicit review/Insert/Dismiss notice.
  Recovery never automatically executes or resubmits an intent.
- Close flushes all loaded drafts, materializes nonempty pending drafts and waits
  for controllers to stop. Failure keeps the window and text. Partial successful
  materialization is reflected in the UI even if a later draft fails. Unsaved file
  drafts still require the existing close decision.

Source references are under `apps/macos/PiApp/Workspaces/`:
`WorkspaceDrafts.swift`, `WorkspaceSelection.swift`, `WorkspaceLaunchSelection.swift`,
`WorkspaceChatLifecycle.swift`, `WorkspaceRun.swift`, `QueuePanel.swift`, and
`WorkspaceShutdown.swift`. Tests were derived from `WorkspaceDurabilityTests`,
`DeferredCreationTests`, `LaunchSelectionTests` and `ComposerSubmissionTests`.

## Storage boundaries

The `--session FILE` argument now anchors an isolated Rust workspace: its initial
snapshot, adjacent `FILE.workspace.json` catalog, and `chats/<UUID>.json` snapshots.
The catalog restores the last saved selection. Use a separate anchor for another
project; a catalog is bound to one canonical project and refuses silent rebinding.
The native Projects manager, multiple root sets, topics, archive/pin/reorder and
native vault-backed configuration remain unported.

Catalogs are private-mode plaintext, just as Rust transcripts are plaintext.
They contain project paths, chat metadata, drafts and recovery receipts, never
credentials. This is not the original Keychain-backed project configuration or
SQLite metadata format. The catalog has a 16 MiB safety bound and 512-chat limit;
individual draft components are bounded. Failed bounds/writes leave previous
storage intact and report that text has not been saved. Backup the whole isolated
Rust workspace directory after closing, including catalog and stream journals.
See [storage and privacy](storage-and-privacy.md).

The current loaded-chat cache is not the original eight-display LRU policy.
Markdown/attachments, multiple projects, connection switching, profile management,
read-state, side conversations and rich transcript parity remain separate work.

## Read-only tool groundwork only

`bello-agent-core::tools` implements an explicit **ls-only** experimental capability
and a bounded shared four-worker / 64-waiter FIFO executor. Fixtures cover schema,
source argument preparation, hidden names, ordering, default/zero/max limits,
multiple-root fallback, absolute/tilde/parent/symlink paths, cancellation and panic
recovery. Tests use disposable files and fake request data.

**The production provider and Controller still offer and execute no model tools.**
A real tool loop still needs paired durable call/results, call-ID replay, ordered
batch outcomes, incomplete-response handling, output retention and source mode UI.
The source's new tool list must not be advertised until that contract is ready.

The original Swift tool policy automatically executes tools it offers. Read-only
mode removes write/edit/bash and rejects MCP invocation. Project roots are path
resolution context, **not a filesystem sandbox**. The Rust fixture module does not
invent a per-call approval layer. Native project trust and explicit mode selection
must be integrated before later production tool execution. Named-user tilde lookup,
Foundation-specific platform aliases, general schema coercion, retained long tool
output, and all other tools are unported.

## Verification and current blocker

Automated tests cover two loopback streams, hidden/visible cancellation isolation,
shared in-memory configuration, pending materialization, concurrent A/B draft
writes, stale revisions, receipt/draft atomicity, rename failure cuts, delayed
in-flight debounce, missing-receipt rejection, held-edit reopen and transactional
reconciliation failure. No real AI endpoint or user data is used.

The final exact test/build counts are recorded in the checkpoint validation record.
The native desktop transport is disconnected, so latest New Chat/switch/close,
recovery-banner interaction and source-equivalent screenshots have **not** been
validated visually. Earlier screenshots do not validate this newer interaction
slice. macOS build and platform behavior remain unverified.
