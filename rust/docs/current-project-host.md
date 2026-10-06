# Current-project trust and runtime ownership

This implements a bounded part of the Swift Projects surface, separate from
Settings: inspect trust for the current primary folder, review Create/retrust,
and add or remove additional roots. The primary cannot be removed. Source
references are WorkspaceManagerView.swift, WorkspaceFolders.swift, and the
ConfigurationVault contracts. Locate Folder relocation, multi-project catalog
ownership, project removal, full Settings and per-chat tool modes remain gaps.

Production project authority is unavailable until an approved native backend and
signed identity are implemented. The UI reports this and cannot save production
trust. The nondefault `synthetic-authority` build feature and explicit debug
`--synthetic-project-authority` launch flag construct memory-only sample storage;
the Projects surface labels it. No environment fallback, plaintext trust store,
credential discovery, Keychain access or signing configuration is introduced.
Saved trust does not enable tools. Replacement controllers use default disabled
tool options, including during synthetic QA.

## Save boundary

The foreground coordinator fences new chat, actor, organization and load intents
before scheduling a root mutation. It checks selected and inactive chats for
running/queued/loading work, held edits, reconciliation and workspace uncertainty.
Normal window Close waits for an unfinished mutation; drafts remain in their
existing editor entities. This does not add a new native Quit veto.

Each loaded controller then acquires a single-owner idle admission guard under
its actor mutex. The guard checks the authoritative certain snapshot, preserves
writer kind atomically, and rejects direct stale-Arc mutations. Stop and
retirement remain available. Retirement can stop/join immediately, but writer
release waits until the temporary guard drops or seals. The wait owns no mutex.
An abandoned waiter does not release storage. A failed join retains the writer.

Unloaded saved sessions acquire nonblocking inspection leases in stable path
order. Existing lock/checkpoint files are required. The shared bounded journal
parser reads into memory without recovery, checkpoint, journal, or sync writes.
Corrupt/future/incomplete data and external writers fail closed. Ordinary empty
paused/error sessions are idle; queued/active/held work is not. Inspection never
clears known persistence uncertainty. A missing checkpoint/lock is currently a
reported limitation for an unloaded pending draft; loaded pending chats work.

Source ordering is save roots first, then retire affected runtimes. Pre-write
failure drops temporary guards and leaves old admission available. Once a write
is confirmed or unconfirmed, guards seal without reopening old admission. All
old runtimes join before any same-path replacement opens; current controller
identity is rechecked before UI installation. Authority is freshly confirmed
again after those asynchronous boundaries. A possible commit, lost confirmation,
failed join or reopen failure keeps admission blocked and reports what is known.
Reload can refresh the display but never silently revive those runtimes or claim
rollback. No automatic resume or safe-restart recommendation is made.

## UI ownership

The coordinator owns draft roots. Every accepted, cancelled or refused UI intent
advances a presentation revision. Pickers and loads carry window/generation
ownership; save completion belongs to the retained workspace across reattachment.
Trust requires explicit activation of the Create/retrust action. Tab/Shift-Tab
traverse enabled actions, and Space/Enter activate the explicitly focused action;
there is no implicit Enter trust confirmation. Offscreen focused controls scroll
into view. Modal keys cannot leak into composer submission.

Chat/tool preview focus restoration is scoped to current owners and exact live
focus. Runtime replacement preserves composer text, selection and editor identity.
Native Linux acceptance is recorded in the parity ledger after the final frozen
candidate is exercised; native macOS accessibility, IME, Keychain and same-machine
performance remain separate acceptance gates.
