# BelloAgent: approved UI/UX implementation handoff

**Decision record:** 2 October 2026  
**Repository:** BelloWare/BelloAgent  
**Source baseline:** `f2e0c118aa55eff0ad93a242901c232343727765`  
**Status:** Final approved product requirements for a later coding task. This deliverable is a specification only; no application implementation, repository modification, commit, push, build, or native runtime test was performed to produce it.

## 1. Start here

Implement the decisions below when the owner starts the coding task. They replace the unselected alternatives in the earlier UI/UX review. The queue-wide edit pause, multiple terminals per project, whole-queue collapse/expand, and Git Blame are explicit approved scope, not optional follow-on ideas.

1. **D1:** Separate **Commit Checked Files** and **Commit Staged Changes**; provide a genuine **Reword Last Commit** operation
2. **D2:** Acquire a chat-wide pending-input hold before queued editing; Save and Cancel resolve it durably and acknowledge before dismissing the editor
3. **D3:** Settings uses **Save All** and an intentional Cancel that discards unsaved changes; dirty closure offers Save / Discard / Keep Editing
4. **D4:** Bound and scroll the queue, add whole-panel collapse/expand, distinguish steering/follow-ups, and expose full text plus captured model/effort on demand
5. **D5:** Support multiple independently managed terminals per project; confirm before restarting or closing a live session, with Cancel the default
6. **D6:** Preserve active Find and Go to Line state through live file reload
7. **D7:** Rename **Disconnect All** to **Remove All MCP Servers…** and confirm the project and removal of saved configuration
8. **A1:** Add contextual accessibility semantics through shared Pi controls, retaining their visuals
9. **A2:** Permit valid image-only messages for supported models consistently across applicable submission paths
10. **D8:** Add IntelliJ-inspired Git Blame in the native file viewer, with navigation to the real historical commit-versus-parent file diff

### Branch, environment, and authority boundaries

- Re-fetch and inspect current `dev/next` and `main` before implementation. All source facts and links here are pinned evidence, not a claim that future branches remain unchanged
- Implement on **`dev/next`**. Follow the current workstream process if separate worktrees are needed; integrate into `dev/next`. **`main` holds released versions only**
- Read current `AGENTS.md`, `NEXT-RELEASE.md`, `docs/Swift-Test-Handoff.md`, and relevant checkout skills before editing. Follow their current workflow once implementation is actually requested. Do not use this document alone as authority to start editing or publishing
- No version bump, release tag, merge into `main`, release packaging, website publication, or deployment is implied by these decisions
- Preserve unrelated work and existing published commit identities. No force-push or incidental history rewrite
- Stay native AppKit/SwiftUI with the app's Pi components. Keep reusable view packages free of app-specific types
- Preserve the actual current deployment targets: **app macOS 14.0; `bello-views` and `swift-host` packages macOS 13**. The owner's macOS 26 preference for BelloBox concerns a different project and does not change BelloAgent's targets

Sources: [repository workflow](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/AGENTS.md), [next-release rules](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/NEXT-RELEASE.md), [app target](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/project.yml#L1-L15), [view-package target](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Package.swift#L18-L25), [helper target](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Package.swift#L1-L9).

### What is fixed, and what the implementer chooses

The behavior, safety invariants, and acceptance criteria in this document are required. Button placement, spacing, suitable Pi-control composition, internal types, RPC names, token formats, and persistence representation remain implementation choices. Suggested mechanisms below explain how to meet the contract; their names are not mandatory protocol names.

Use the smallest changes that satisfy the contract. Do not introduce a universal state framework, new navigation system, terminal split panes, a temporary MCP disconnect mode, or unrelated refactors. Resolve technical details from the current checkout without reopening settled product choices. Escalate only a material conflict with current behavior or a safety requirement that cannot be met within scope.

## 2. D1: explicit Git commit scope and true reword

### Required behavior

- Provide distinct **Commit Checked Files** and **Commit Staged Changes** actions or explicitly selected modes. The visible active action and scope must agree; an empty checked list must never silently select the staged-index action
- Commit Checked Files requires at least one checked path. Its explanation states that it commits the selected files' complete working-tree state, not just their staged hunks
- Commit Staged Changes explicitly commits the index and displays its applicable count/scope. Merely unchecking all files is not consent to this operation
- If Amend is supported for either content action, keep the content scope explicit: checked files or staged changes. Do not call an amend that includes content changes “Reword only”
- Provide a dedicated **Reword Last Commit** operation. It changes the commit message while preserving the previous HEAD tree and the user's preexisting index and worktree. Unrelated staged changes must not enter that commit, and neither staged nor unstaged work may be discarded or moved as a side effect
- Reword requires a valid HEAD and the existing safety/error handling for Git mutations. If repository state changes while the action is pending, refresh/revalidate or refuse with a useful message rather than operating on a different commit silently
- Preserve the entered message and selection on failure. Prevent duplicate in-flight mutations and ensure narrow layouts still disclose scope
- Keep literal paths, renames, deletions, untracked files, and long selected-path lists safe. Selecting a file is distinct from staging it

**Implementation guidance:** model the operation's scope explicitly at the UI-to-service boundary rather than inferring intent from an empty array. Choose the safest Git mechanism for reword and prove tree/index/worktree invariants with real repository fixtures. Do not bypass hooks/security protections or force-push as a convenience.

### Acceptance

1. Stage A, leave B unstaged, uncheck all: checked-files commit is unavailable and commits nothing; the separately invoked staged action includes A and leaves B unchanged
2. Give one file both staged and unstaged edits: checked-files and staged actions produce their respective promised content, with truthful labels/diff context
3. Reword with unrelated staged and unstaged changes: message/hash changes, HEAD tree does not; index entries/content and worktree content are unchanged
4. Cover ordinary commit, both content-amend scopes, no-HEAD reword, failure, refresh while editing, repeated clicks, renames, deletions, special-character paths, and long path lists

Extend `GitPanelAuditTests` and `GitToolTests`; retain recent literal-path and rename fixtures. Existing zero-check refresh tests do not prove commit safety.

Source anchors: [checkbox semantics](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Git/GitPanel.swift#L418-L481), [current enablement and misleading reword hint](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Git/GitPanel.swift#L525-L568), [controller](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitController.swift#L476-L490), [Git commit service](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitService.swift#L604-L636).

## 3. D2: queued editing holds all pending inputs in that chat

### User-visible contract

Editing a queued message pauses delivery of **all pending follow-ups and steering in that chat**, including later messages. Those messages must wait. The currently active model/tool turn continues normally; other chats are unaffected. This supersedes the earlier report's recommendation against adding an edit pause.

- Clicking Edit first acquires the hold and authoritative complete queued text. Until acknowledged, show pending feedback and leave the ordinary composer draft untouched
- Only after acquisition succeeds does the editor become active. Explain that this message and other waiting messages are paused while editing
- **Save** validates and durably updates the existing queued message, then releases only its edit hold. Complete in the UI only after confirmed acknowledgement
- **Cancel** keeps the original queued message and releases only its edit hold. Restore the ordinary draft only after confirmed resolution
- Neither Save nor Cancel clears a separate manual/Stop, error, cost-limit, or restart/recovery pause
- A failed Save retains the complete rewrite and the hold. An uncertain result remains recoverable and visibly pending reconciliation; do not claim it saved, silently resubmit it, or dismiss it
- Return saves while queued editing; all applicable keyboard/button paths use the same completion semantics. Repeated Save/Cancel cannot start conflicting operations
- Preserve the complete ordinary draft separately: text, images, and selected skills. A queued rewrite is a different recovery record

### Backend correctness requirements

**Acquisition and dispatch have an atomic winner.** Establish the hold and read the pending item's complete text/revision as one operation. For a persistent session, durably record the hold before acknowledging acquisition or enabling the editor. Do not read first and hold later, even for short preview text. A claimed/delivering message cannot be recalled: if delivery wins, reject Edit with a clear explanation and leave the ordinary draft unchanged. If acquisition wins, no additional pending entry may be claimed until resolution. Already-claimed input may finish delivery; do not promise to retract it.

**Gate every entry into pending-input delivery.** The gate must cover idle submit, Resume, run entry, steering drain, follow-up start, completion decisions, and relaunch. Recheck immediately before each claim, including after suspension in a batch. Existing all-batch membership remains fixed: newly added messages cannot replace removed/held members. Merely filtering one drain loop is insufficient; a nonempty held queue must not cause extra model calls, old-context replay, or a relaunch spin.

**Keep current-turn work separate.** The hold does not cancel active requests, tool batches, retries, or ordinary continuation of the current turn. When that turn finishes, it can settle normally with held messages still waiting. New submissions remain permitted within current queue limits and join the held pending queue. Preserve existing steering/follow-up lane boundaries and independent one-at-a-time/all modes; do not introduce a new global cross-lane FIFO.

**Make resolution durable before dispatch.** Save preserves item ID, original submission command identity, queue position, lane, attachments, frozen skills, and captured model/effort/capacity overrides. Commit replacement text, hold resolution, and a reconcilable successful edit outcome before that input becomes eligible. A no-change Save still resolves the hold. Definitive validation/storage failure preserves the original queued content and active hold. An ambiguous storage outcome fails closed for scheduling until established.

Cancel atomically retains the original item and durably records hold resolution plus the cancelled outcome before dispatch or successful acknowledgement. A definitive Cancel failure leaves the editor/hold intact; an uncertain reply must be reconciled. Held Remove has the same durable resolution requirement while removing the item instead of retaining it.

**Use edit identity and stale-operation protection.** A helper-owned reservation with an edit identity and source revision is a suitable design. Exact representation is discretionary; equivalent protection is required. Begin/retry, Save, Cancel, and status reconciliation must distinguish the same edit from a later one. A late Cancel cannot undo a saved edit; a late Save cannot override a cancelled edit. Keep enough durable terminal outcome information to recognize committed, cancelled, or removed edits across lost acknowledgements and helper restart. Transport replay protection tied only to one host epoch is insufficient.

**Avoid a dispatch gap on removal.** Removing an item under edit must atomically remove the item and resolve its hold. Never perform Cancel followed by ordinary Remove, which could dispatch the original in between. Protect held-item mutation in the backend, not just disabled controls. The recommended minimal policy is one active edit per chat and disabling reorder/steering promotion in that chat until resolution; an equivalent implementation may differ only if it preserves the promised position, lane, and hold semantics. Different chats remain independent.

**Release once, conditionally.** After resolution, schedule eligible work once if allowed by all other pause reasons. Stop during editing still stops the active run and leaves pending work paused. Active failure/cost-limit pause survives resolution. Resume must not bypass an edit hold; disable it with “Finish or cancel the queued edit first” or provide equally clear guarded behavior. Restart recovery must retain the existing no-automatic-replay pause.

### Navigation and recovery

- Navigation, panel hiding, switching chats, or closing a view must not implicitly save, cancel, or release the hold
- Retain a recoverable rewrite record with edit identity/revision, last persisted rewrite, set-aside ordinary draft, and unresolved operation. Use existing bounded/debounced draft patterns and failure-aware quit flushing; do not promise recovery of keystrokes newer than the last successful write after a crash
- On app/helper restart, reconcile reservation and operation outcome before enabling mutation or Resume. If a hold survives, restore editing or expose clear resume-edit/cancel recovery. If local rewrite text is unavailable, expose the held original rather than stranding the queue
- An item disappearing after durable Save can mean it has already delivered. Use the edit outcome to resolve success; queue absence or equal text alone proves neither success nor failure
- Reconcile an uncertain Begin using the same identity. Do not leave an invisible hold after an abandoned response or create duplicate reservations on retry
- Bind replies to the original chat/edit generation. Late callbacks cannot overwrite newer drafts or steal focus from another pane/window
- Preserve existing unkept-side lifetime and parent-draft recovery; this feature must not silently turn ephemeral sides into durable chats
- Do not add timeout-based or view-disappearance auto-release. A surviving hold must remain visible and recoverable

**Compatibility:** keep existing persisted sessions readable and current optional-field wire compatibility rules. Do not enable an edit UI that promises a hold against a helper that cannot enforce it. Unsupported combinations need truthful disabled/error behavior, not a silent return to unsafe editing.

### Acceptance and focused failure matrix

1. Both acquisition/dequeue race winners, both lanes, short and truncated/long messages
2. Acquisition during an all-batch await: no still-pending item enters the transcript/provider input after acquisition wins
3. Steering and follow-up × one-at-a-time/all, with new submissions during editing: none bypass the hold
4. The active turn finishes normally; held work causes no additional model call/relaunch loop
5. Manual pause before edit; Stop, failure, or cost limit during edit; Resume while held; restart recovery after resolution
6. Save, unchanged Save, Cancel, and held Remove with validation failure, persistence failure, delayed/lost response, and repeated commands
7. Restart after acquisition, during Save, after durable Save before reply, and after Cancel before reply
8. No original-text dispatch after successful Save, no duplicate turn, and preserved IDs/position/lane/skills/images/overrides
9. Multiple views of one chat, navigation/close/reopen, stale identities, and late callbacks preserve both drafts and focus ownership
10. Release while active honors existing lane timing; release after settle starts eligible work only once

Extend `QueueEditingTests`, `QueueDeliveryRecoveryTests`, `ConversationQueueTests`, and the real-helper queued Save cases in `ConversationRunTests`. Replace assertions expecting draft restoration before Save acknowledgement. Verify actual durable transition behavior: existing `persistState()` batches writes during active runs and cannot simply be assumed to have flushed.

Source anchors: [queue admission/update/delivery](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L12-L186), [run gating and relaunch](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/SessionRun.swift#L116-L295), [batched persistence](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/SessionPersistence.swift#L367-L397), [epoch replay protection](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/HostService.swift#L93-L120), [current edit/Save ordering](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/QueuePanel.swift#L99-L190), [queue disappearance and saved-draft handling](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/SessionDisplay.swift#L414-L555), [draft flush](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceDrafts.swift#L19-L77).

## 4. D3: one explicit-save Settings contract

### Required behavior

- Use **Save All** for all edited connections and preferences. Show a global unsaved-changes indication, retaining useful per-tab dirty markers
- The explicit **Cancel** action abandons all unsaved Settings drafts consistently. Reopening starts from saved state, for both the standalone Settings window and project sheet
- Closing a dirty window/sheet offers **Save / Discard / Keep Editing**. Save applies Save All and closes only when resolved successfully; Discard abandons unsaved changes; Keep Editing preserves them. Escape/window-close/dismissal routes must not become an accidental hidden discard path
- Apply the same dirty-work protection when quitting with Settings open, coordinated with the existing failure-aware quit flow
- Reload must guard against discarding dirty changes. Cancelling Reload writes nothing and keeps drafts. A failed reload must not erase the only draft copy; replace drafts only after the fresh load succeeds
- During Save, block conflicting close/reload/duplicate-save paths or defer them with truthful pending feedback. Do not show a successful close while a write is unresolved
- Preserve sequential partial-save semantics honestly. If an earlier connection saved before a later one failed, identify what saved, retain unsaved edits, and focus the failed tab. Cancel/Discard after this does not undo already committed changes
- Preserve revision-aware conflict checks/merging, connection-switch serialization, reasoning-transfer confirmation, Keychain/origin credential safety, and existing sanitized errors
- Typed secrets stay in the existing secure design. No ordinary on-disk Settings draft persistence, logging of keys, or silent autosave of privacy/webhook/security-affecting choices

### Acceptance

Exercise existing and new connection drafts plus preferences in both presentations: clean/dirty/saving/error, Save All, Cancel, window close, Escape, Reload, reopen, and quit. Include a stale revision, load failure, second-tab save failure after first-tab success, and repeat clicks. Verify that the UI describes partial success accurately and no secret appears in draft files/logs.

Extend `ConnectionSettingsFlowTests` and `SettingsSaveTests`, plus native window/sheet lifecycle coverage. Controller-only tests are insufficient for dismissal behavior.

Source anchors: [Settings controls and Reload](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ProfileSettings.swift#L65-L144), [draft/load behavior](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ConnectionSettingsController.swift#L71-L123), [sequential saves](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ConnectionSettingsController.swift#L188-L218), [persistent window controller](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Application/SettingsWindowContent.swift#L5-L20).

## 5. D4: bounded, collapsible, truthful pending-message panel

### Required behavior

- Cap the total queue region, including both steering and follow-ups, and scroll overflow. Every pending item remains reachable; rows remain compact
- Add **collapse/expand for the entire panel**. The collapsed header keeps the total pending count and paused/editing status visible. Collapsing changes presentation only; it does not pause, resume, cancel, or alter the queue
- Keep transcript reading space and composer/Stop/relevant Resume controls usable at the supported minimum window size. Choose and document a concrete cap/reading-space budget during native implementation; do not require a new queue-manager window
- Use separate visible steering and follow-up headings with truthful timing. Steering is delivered at the current tool-batch boundary; follow-ups wait for the run boundary under existing rules. Manual/error/recovery/edit holds take precedence over promises that something is about to dispatch
- Expose complete message text and captured model/effort details on demand through a keyboard-accessible lightweight detail view. Merely inspecting details must not acquire the edit hold or change the ordinary draft
- Show saved overrides from the item, not the current composer picker. If metadata is missing/legacy, say inherited or unknown as appropriate; never reconstruct a false historical choice. Do not change routing choices for already queued messages
- Preserve existing reorder, remove, edit, and steering-promotion behavior outside D2's edit restrictions. Retain lane boundaries and correct full-text loading rather than treating truncated previews as authoritative
- If an item leaves while its detail view is open, handle disappearance clearly without editing/sending a replacement. No focus theft, unexpected transcript jumps, or per-token whole-window layout work

### Acceptance

1. Mount 1, 5, 20, and boundary-capacity queue fixtures, including all-steering and mixed lanes, at the supported minimum size (baseline 920 × 600), with tall draft, terminal open, and split pane cases
2. Test expanded/collapsed state, count and pause visibility, all overflow rows, keyboard/VoiceOver access, first-to-last reorder across scroll boundaries, and concurrent removal/delivery during drag
3. Queue A with model A/high, change picker to B/low, queue B: detail shows each captured choice and helper requests retain existing routing. Legacy metadata is truthful
4. Test idle/running/manual-paused/error/recovery/edit-held timing labels and no side effects from read-only details

Extend `ConversationQueueTests`, `ConversationRunTests`, `ComposerSubmissionTests`, and `TurnCapacityTests`. Retain all-batch and cross-lane helper tests. Include a maximum-capacity rendering fixture without changing the actual admission limit.

Source anchors: [queue geometry, preview model, and headings](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/QueuePanel.swift#L9-L104), [queue placement](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ConversationPane.swift#L126-L167), [captured wire overrides](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/Sessions.swift#L3-L24), [frozen submission](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceRun.swift#L95-L174).

## 6. D5: multiple terminals per project, with safe lifecycle actions

### Required behavior

- Replace the one-terminal-per-project limitation with **multiple independent sessions per project**, following the familiar VS Code/IntelliJ pattern
- The user can **create, switch, rename, and close individual sessions**. Use a compact native Pi-styled selector/tabs/list; exact presentation is discretionary
- Keep each session's shell, scrollback, terminal state, and identity alive while hidden or while another terminal/project is selected. Return to that project's previously selected surviving terminal
- Renaming changes the display name, not process identity. A user-chosen name must not be silently replaced by later shell title escape sequences; retain shell-provided title separately if useful
- **Restart Terminal…** affects only the selected/captured terminal, never every terminal in the project. It creates a fresh shell/emulator and makes the scrollback-loss consequence clear
- **Close Terminal…** removes the selected/captured session and its output. **Hide Terminal** remains separate and non-destructive
- Confirm before restarting or closing any **live** session. Identify terminal and project; explain shell termination, possible interruption of running commands, and loss of that session's history. **Cancel is the default**; Escape cancels. Do not rely on imperfect foreground-job detection to decide that a live shell is safe to destroy
- An already-exited terminal's close/restart behavior may use the simpler existing pattern, but still communicate history loss accurately. Do not add an extra requirement to preserve history across restart
- Bind confirmation to exact project/session identity and generation. Cancel, project switch, hiding/closing the originating panel, or replacement elsewhere must not let a late confirmation act on another session. Repeat clicks produce at most one confirmation and one operation
- Creating a new terminal uses the project's existing startup directory and environment protections. Preserve current PTY input/resize/process cleanup, bounded scrollback, secure environment filtering, and focus handoff
- Project removal and app shutdown must clean up every owned session using their existing authorized lifecycle paths, not leak the additional shells

**Implementation guidance:** use stable terminal IDs within per-project collections plus selected-session state. Keep each session's runtime owner independent of the visible view. After closing the selected session, select a surviving neighbor; an empty project can show New Terminal rather than silently re-creating a just-closed shell. Precise selector layout and naming defaults are implementation choices.

**Scope limit:** session continuity is within the running app. Do not invent cross-app-restart shell resurrection, automatic command replay, split panes, terminal profiles, or remote terminal management.

### Acceptance

1. Create at least three terminals in project A and two in B; run distinguishable shell state/output, rename them, switch/hide/reopen: state stays with each session and the right keyboard target is shown
2. Confirm restart/close for A2: only A2 is affected. Other A and B sessions retain process identity/output. Cancel/Escape has no effect
3. Exercise project switch, hide, replacement, shell exit, rapid repeated clicks, and stale confirmation while a question is open
4. Verify user rename versus shell title, closing last session, creation failure, PTY exit/reaping, project removal, and shutdown
5. Retain bounded memory/scrollback and multi-terminal performance tests; hidden sessions must not retain stacked onscreen views or steal focus

Extend `TerminalPanelAuditTests`, `TerminalPanelSerialTests`, `TerminalEmulatorTests`, and `PseudoTerminalReapTests`. Run focus/window-state tests in their serial lane.

Source anchors: [current one-session registry and lifecycle](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/TerminalPanel.swift#L4-L101), [view ownership and controls](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/TerminalPanel.swift#L104-L179), [shell termination](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Terminal/PseudoTerminal.swift#L235-L250), [registry/focus tests](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiAppTests/TerminalPanelAuditTests.swift#L179-L318).

## 7. D6: retain file-search intent through disk reload

- A live reload keeps the active Find/Go to Line bar, query, case-matching setting, field draft, field selection, and owned focus intact
- Cancel old source-bound search work and rebind to the new document. Recompute highlights/counts safely near the current reading anchor; do not reuse stale results or force a jump to the top
- A disappeared match produces the correct new state without closing/reopening the bar. A newer query/save supersedes older asynchronous results
- Go to Line retains its typed value during reload; Return validates/clamps using the new document under existing rules
- Do not steal focus if the user moved to another pane/window. Hidden tabs must not start unnecessary searches
- Preserve current reading position/selection behavior, bounded file reads, cancellation, symlink replacement checks, and trust revocation. Continuity does not authorize reading a newly untrusted target

**Acceptance:** active Find with nonfirst match and case mode during atomic save; two quick saves; query edit during reload; append, delete/recreate, binary replacement, very large file/long line; active Go to Line draft; another focused window; trust revoked or symlink redirected. Highlights must refer only to the latest trusted document generation.

Extend `FileTabTests` and `FileFindTabTests`, including native focus tests. Source anchors: [reload currently clears the bar](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Files/FileTab.swift#L54-L107), [bar state and close](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Files/FileTab.swift#L220-L298), [cancellable source-bound search](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/FileView/FileFind.swift#L32-L149).

## 8. D7: honestly name saved MCP configuration removal

- Rename the current action to **Remove All MCP Servers…**
- Confirm the affected project and that its saved MCP server configuration, including any explicitly stored server credential configuration, is being removed. Do not describe this as a temporary disconnect
- Cancel does not write the vault or reconfigure a helper. Preserve existing project/active-work/unkept-side guards and revision checks
- Report persistence and runtime results accurately. If the configuration was saved empty but helper reconfiguration failed, disclose that partial outcome rather than claiming complete success; retain existing safe helper shutdown behavior
- Keep connection trust confirmations and existing explicit-credential handling. Do not add a reversible disconnect/disable mode or auto-reconnect policy

**Acceptance:** two projects, empty/nonempty configuration, cancelled confirmation, offline helper, vault write failure, helper configuration failure after vault success, duplicate clicks, and switching project while confirmation is visible. Verify the captured project is the only target and no secrets appear in confirmation or errors.

Source anchors: [current label](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Inspector/ResourceInspector.swift#L333-L340), [trust/removal handlers](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Inspector/ResourceInspector.swift#L425-L445), [configuration guards](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceConfiguration.swift#L331-L338).

## 9. A1: contextual accessibility in shared controls

- Add shared Pi-control support for contextual labels, current values, selected state, bounds, and enabled state, and apply it to affected consumers
- A selected tab is exposed as selected. Increase/decrease controls identify the field they change and its value rather than announcing generic duplicate labels. Label the automatic-update switch and other unlabeled call sites
- Preserve visual appearance, existing native control semantics, keyboard behavior, focus order, and hit targets. Avoid duplicate announcements or making nested controls inaccessible through over-grouping
- Apply the same quality to the new queue, terminal, Git scope, and blame controls. A pointer-only tooltip is not an accessible equivalent

**Acceptance:** native AX-tree assertions and actual VoiceOver/keyboard use across Settings, onboarding model choice, queue, file viewer, and terminal selection. Verify purpose/value/selected/enabled announcements, no duplicates, and stable focus through rerender. Source inspection alone is not a VoiceOver pass.

Sources: [tabs](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Design/PiControls.swift#L7-L37), [steppers and rows](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Design/PiControls.swift#L142-L205), [update switch](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ProfileSettings.swift#L286-L286).

## 10. A2: image-only input is valid input

- Permit a draft with valid image attachments and no text when its selected/captured model supports images. Do not fabricate a caption or prompt on the user's behalf
- Share one eligibility contract across Send, Return, Command-Return, main/side submission, queued follow-up, steering, and applicable historical/queued edit paths. Preserve each path's existing timing and destination semantics
- A truly empty draft remains disabled. Existing text-only and skill-only behavior stays intact. An empty-text queued rewrite that retains valid images must not be rejected solely because its text is empty
- Validate attachment readiness, access, conversion result, and model capability at the proper dispatch boundary. Invalid/missing/changed images or unsupported models receive actionable feedback and retain the full draft
- Preserve failed-dispatch recovery, origin-session ownership of late attachment conversion, and complete image/skill retention across navigation/reopen
- Give image-only transcript/queue items a useful presentation, accessibility label, and title fallback; display metadata must not become fabricated user text sent to the provider
- Verify provider payload encoding for each supported adapter. If a concrete adapter cannot support image-only content, expose its actual limitation and retain the draft; do not silently inject filler text or drop the image

**Acceptance:** valid image-only send via button and both keys, busy/paused/editing states and both lanes, side draft, historical edit, unsupported model, lost image, conversion failure/late completion after navigation, rejected dispatch, and reopen recovery. Inspect adapter request fixtures to prove an image-only turn carries the image without invented text. Any real-provider check must be reported separately from fake-gateway tests.

Extend `ComposerSubmissionTests`, `ComposerAttachmentDestinationTests`, `PiImageTests`, and `SideTests`, plus appropriate edit-path tests.

Sources: [frontend eligibility](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/ComposerInput.swift#L14-L119), [normal send guard](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceRun.swift#L37-L48), [historical edit guard](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceEditing.swift#L127-L134), [helper admission/image validation](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L12-L139).

## 11. D8: Git Blame and historical diff navigation

### Approved experience

The owner likes IntelliJ's Git behavior. Add a focused native implementation of its useful annotation-to-history pattern: **Show Blame** on the file viewer, aligned line attribution, concise author/commit information, richer date/message details, and direct investigation of the change that produced the line. The approved destination is the real historical diff, not merely the current file or a generic history list.

- Add Show Blame / Hide Blame in the native file-viewer controls. An annotation gutter shows author and short commit attribution aligned with displayed lines. Accessible on-demand detail includes commit date and message; full commit identity remains available for investigation
- Preserve text selection, scroll position, horizontal scrolling, Find/Go to Line state, and existing line-number selection. Blame click targets must not take over ordinary line-number selection behavior
- Each committed attribution must carry enough information to map the displayed line to the **full commit ID, historical filename, and original line number**. A current path/line alone is insufficient after renames and line shifts
- Clicking a committed annotation opens/reuses the project's existing **Changes → History** surface, selects that exact commit and historical file, and reveals/highlights the relevant line or hunk in the **commit-versus-parent diff**
- The destination must work for commits outside the first history page and despite a preexisting history filter. Do not lose the target when history refreshes. Loading is cancellable; newer navigation owns the result
- Returning to the originating file preserves its reading position and active search state. Keep the original tab/view identity and reading anchor; avoid opening a duplicate current-file tab merely to return
- Continue to offer existing ordinary current-file navigation with its current meaning. It is not an acceptable substitute for the blame click's historical destination

### Historical and edge-case semantics

- Normal commits compare the attributed commit to its parent. Root commits compare to the empty tree. Merges use the **existing first-parent historical diff behavior**, clearly labelled; do not silently change blame attribution itself to first-parent-only
- Resolve the historical path on the appropriate diff side, including rename old/new paths and original line coordinates. Preserve the distinction between one-based Git line numbers and native viewer coordinates
- When a line has no changed hunk under the selected comparison (possible with first-parent merge views), or the target falls outside available/bounded diff content, explain that precisely. Show the correct commit/file context without pretending a different hunk is the selected line; do not manufacture a match
- Locally uncommitted lines have an honest “Uncommitted” state and no fabricated commit target. Untracked files have no historical blame action; unavailable history is explicit
- Missing/shallow objects, binary files, deleted/replaced files, non-repository files, cancelled reads, and output limits get clear non-destructive unavailable/limited states. No checkout/reset/stash or worktree/index mutation is needed to investigate history
- Attribution must correspond to the **displayed document generation**. Do not run against newer disk content and attach those results to an older visible snapshot. Refresh/invalidate on file or repository change while retaining reading state safely

### Integration and safety requirements

The baseline has no blame implementation. Extend native FileView/GitView rather than adding a second history browser. The existing history controller can read a single commit/file, and existing diff models contain old/new paths and line numbers, but current navigation callbacks only carry current-tree path/line. Add an explicit historical destination and a bounded target-reveal capability. Exact types/APIs are engineering choices.

- Keep the file viewer's trusted project/resolved-path ownership throughout blame reads and navigation. The existing Changes project lookup alone is not the viewer's trust gate
- Hide/close, trust revocation, resolved-path replacement, project switch, file replacement, and newer requests cancel work and reject stale completion. Clear inaccessible cached content when trust is lost
- Pass paths as opaque/literal data with command-appropriate handling, argument separation, and robust machine-output parsing. Cover whitespace, Unicode, wildcard/colon characters, leading hyphens, tabs/newlines, and quoted historical filenames; do not interpolate filenames into shell commands
- Reuse cancellable Git process execution, timeout/concurrency limits, safe diagnostic handling, off-main parsing, and explicit output bounds. Reject partial/overflowed data rather than misattributing lines
- Keep gutter drawing to visible lines and loading/caches bounded for large files/histories. Choose a bounded whole-file or range-based strategy appropriate to existing architecture; do not read every historical file or render an entire large history per scroll
- Preserve existing large-commit deferred/file-specific diff behavior. If a target exceeds a bound, show the limitation instead of silently opening the top or wrong line as if successful
- Keep `bello-views` free of app-specific workspace/navigation types; app-owned integration supplies project and return-view context

### Acceptance

1. Real repository fixture with several authors/commits: line attribution, date/message details, exact SHA, historical path, and clicked diff/hunk agree with Git
2. A renamed file with inserted/deleted lines: click uses the original historical filename and line, not the current name/offset; both unified and split diff views reveal correctly
3. Root commit, merge with explicit first-parent label, and a merge attribution without a corresponding first-parent changed hunk produce honest results
4. Commit beyond the first 50 history entries and a conflicting existing history filter: exact destination remains selected through loading/refresh
5. Mixed committed/uncommitted lines, untracked file, missing objects/shallow history, binary file, and unavailable repository: no fake historical destination or working-copy mutation
6. Toggle blame, scroll horizontally/vertically, select line numbers/text, open Find, jump to history and return: reading/search state and native focus remain coherent
7. Rapid annotation clicks, hide/show, file save/replacement, project switch, trust revocation, symlink replacement, and cancellation: no stale attribution, stale focus, or leaked process
8. Large file/very long line, large commit, target beyond diff cap, malicious-looking literal filenames, output overflow, and timeout: bounded work and accurate feedback
9. Keyboard and VoiceOver can enable blame, inspect attribution, activate the historical destination, and return without pointer-only affordances

Extend `FileTabTests`, `FileTextViewTests`, `GitCommitBrowsingTests`, `ChangesTabTests`, `GitDiffTableTests`, `GitPanelShownTests`, and `GitLiteralPathTests`. Add dedicated blame parser/service fixtures for original/final line mapping, renamed filenames, root/merge/uncommitted output, limits, and cancellation. Preserve process-concurrency tests and current-file navigation tests as separate behaviors.

Source anchors: [viewer reads, trust, and closure](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Files/FileTab.swift#L123-L215), [native selection/scroll preservation](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/FileView/FileTextView.swift#L436-L479), [visible-line ruler](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/FileView/FileTextView.swift#L1402-L1466), [current-file routing and Changes reuse](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Workspaces/WorkspaceChanges.swift#L7-L30), [history-page selection limitation](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitController.swift#L400-L414), [commit/file loading and history filter](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitController.swift#L527-L597), [historical diff service](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitService.swift#L414-L467), [historical display and merge label](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Git/GitPanel.swift#L728-L766), [diff paths and lines](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitDiff.swift#L5-L72), [current diff navigation](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/packages/bello-views/Sources/GitView/GitDiffTable.swift#L563-L575).

Interaction references: [official IntelliJ change-investigation help](https://www.jetbrains.com/help/idea/investigate-changes.html#annotate_blame) describes gutter annotations, author/revision/date information, commit details and navigation into Git history/line changes. [Official Git blame documentation](https://git-scm.com/docs/git-blame#_the_porcelain_format) documents original/final line numbers, attributed filename, author/time and summary in machine output. These support the focused design; arbitrary-revision annotation, movement/whitespace configuration, Code Vision, and new multi-parent merge tools are outside scope.

## 12. Cross-cutting safety and scope limits

- Preserve data integrity: queue delivery journal/checkpoint behavior, command identity and receipt handling, whole-side drafts, connection rebind serialization, and failure-aware close/quit
- Preserve cancellation and ownership: old async results cannot mutate a newly selected chat, terminal, file, project, or historical destination
- Preserve security: Keychain/origin-scoped credentials, sanitized errors, trusted project/file boundaries, symlink and trust-revocation guards, MCP active-work restrictions, and literal Git path handling
- Preserve behavior unrelated to the approved work: capture/retention defaults, cost limits, routing, side snapshots, connection reasoning confirmations, and webhook sending
- Preserve package separation, deployment targets, bounded memory/read/render work, and the helper's upstream compatibility contract. Do not make required wire fields out of optional additions
- **Motion policy stays unchanged.** The source records an owner-requested always-on app-motion policy; A1 does not authorize restoring OS-driven Reduce Motion. Retain test-only reduced-motion overrides and existing meaningful progress indicators
- Do not add a new onboarding flow, generic error center, command palette, design system, or release work

Motion evidence: [PiMotion](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiApp/Design/PiMotion.swift#L5-L32), [historical owner decision](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/docs/validation/Bello-Agent-0.1.67-2026-09-20.md#L7-L21), [regression tests](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/apps/macos/PiAppTests/SmoothHoverAndMotionTests.swift#L61-L82).

## 13. Implementation sequence and validation handoff

### Recommended sequence

1. **Refresh baseline and tests:** fetch current branches, read rules, inspect drift from the pinned commit, establish exact target commit and correct test lanes. Preserve unrelated ongoing work
2. **Data-safety contracts:** D1 Git scope/reword, D2 queue hold/durable recovery, D3 Settings lifecycle. Add failing regression fixtures before fixes; use mutation checks where required by current repository rules
3. **Queue presentation:** D4 on top of D2's authoritative hold/pause state; bring A1 semantics into shared controls as consumers are changed
4. **Independent continuity work:** D5 multi-terminal lifecycle and D6 search continuity. Coordinate D6's document-generation/focus handling with D8
5. **Git Blame:** D8 through the existing history/diff path, with real Git fixtures and native interaction coverage
6. **Finish bounded changes:** D7 truthful MCP removal and A2 consistent image-only input; complete A1 native audit
7. **Integration validation:** final-state focused tests, applicable helper/view/wire suites, native UI evidence, and aggregate checks under current repository rules. Re-run affected checks after later edits or conflict resolution

These are reviewable work units, not mandatory module or RPC names. Independent work can proceed in parallel in appropriate worktrees; shared queue/file/control changes need integration ownership. Do not start unrelated deferred refactors listed in the pinned next-release file.

### Native evidence required

- Light/dark appearances, supported minimum window size, split panes and detached windows where applicable
- Empty, loading, busy, paused, dirty, saving, error, cancelled, repeated-click, interrupted, and recovered states
- Actual keyboard routing, focus after dismissal, native AX/VoiceOver, queue overflow/drag, terminal process ownership, and blame-to-history return navigation
- Existing screenshot gallery plus targeted fixtures for new states. Screenshots support layout review but do not prove cancellation, durability, keyboard/AX behavior, or provider compatibility
- Keep performance measurements in the correct isolated lane; no concurrent compilation or unrelated performance run while measuring. Do not use poll-count waits where the checkout requires time-bounded `eventually`

At the pinned baseline, `scripts/check-next.sh` supports build, `test <Class>…`, `helper`, and `gate`. It fetches/checks a fixed commit in a dedicated worktree. Serial classes run individually; the aggregate gate runs alone. Re-read current script and lane guidance before use. A gate whose filename mentions release is validation, not permission to release.

Sources: [check-next workflow](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/scripts/check-next.sh), [test lanes and live-check requirements](https://github.com/BelloWare/BelloAgent/blob/f2e0c118aa55eff0ad93a242901c232343727765/docs/Swift-Test-Handoff.md). The pinned release record leaves an owner VoiceOver check and one real-gateway compaction check deferred; do not silently treat them as completed. Any required later paid/live check needs the appropriate environment and authority.

### Definition of done for the implementation task

For every decision, report:

1. The implemented contract and its relevant source changes
2. Focused regression cases, including failure/interruption paths, and required mutation-check evidence
3. Native before/after evidence for changed UI and actual keyboard/AX validation where required
4. The exact tested commit, commands, and results, separating **passed**, **failed**, **skipped**, and **not run**
5. Any remaining limitation or unmet acceptance criterion; do not hide one behind “UX polish complete”
6. If a later authorized coding task publishes changes, verify the expected commit on `dev/next` and report its CI/validation status accurately; no direct-main or release action follows from this handoff

**Verification boundary for this document:** requirements reconciled with approved decisions and pinned source inspection. No build, native app launch, VoiceOver session, performance measurement, provider request, or application test pass is claimed here.
