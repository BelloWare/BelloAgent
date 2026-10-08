# Current-project Topics

Specification: immutable Swift main `f4f80ddda3c27fac9e266896f69b725a06242e8f`,
`Storage/TopicRecord.swift`, `Workspaces/WorkspaceTopics.swift`, `TopicSheet.swift`
and `SidebarGroups.swift`. Rust base: `a73f56acdf5847e7a9e34c1cb2aceeb051df0db3`.

## Workflow

Open **Topics** beside the current project, or **Move** beside a chat. The sheet
captures that chat; changing topics does not select a different chat. Enter a
name and Create topic, move the captured chat into a topic or project top level,
rename a topic, or explicitly confirm Delete topic. Deleting a topic retains its
chats and moves them to project top level. Topic headers persist expansion;
filtering can reveal matching chats inside a collapsed topic. A restored selected
chat's topic is temporarily revealed until that topic's own expansion choice.

This is a compact GPUI adaptation: one combined management/move sheet rather than
Swift's separate editor sheet and native submenus. It stays open after a successful
write. Individual current-project chats only: multi-project selection, child/side
branches, bulk drag/reordering and Swift's five-root pagination are not represented.

## Persistence and safety

Catalog schema v10 is distinct from session snapshot v9. Legacy reads preserve
bytes; explicit topic fields are rejected in older schema versions, even empty
or null values. Normal mutations promote the catalog. Topics live in the already
root-scoped catalog and grant no project/tool authority. Unknown topic references
fall back to project top level rather than hiding a retained conversation.

Titles collapse Foundation-style whitespace and truncate to 120 extended grapheme
clusters. IDs use the Rust catalog's UUID convention. Topic title/expansion and
chat membership have independent optimistic revision checks. Stale rendered move
controls carry their original membership revision and cannot replace newer moves.
A move patches only the latest row's membership; pin/archive/mode/connection/title,
drafts and submission receipts remain authoritative. Explicitly moving an unsent
empty chat atomically materializes its catalog row and draft, without creating a
session checkpoint or journal. Moving into a collapsed topic atomically expands it.

All topic operations use the existing catalog transaction and uncertainty fence.
Before-rename failure leaves memory unchanged; unconfirmed writes keep catalog
admission blocked. Background work retains the catalog's physical ownership even
if its sheet closes. App-controlled shutdown and project/configuration lifecycle
changes refuse overlap with an outstanding topic write. These checks do not add
native forced-termination guarantees. Completion patches only topic columns,
checks operation/project identity, and cannot clear a newly opened sheet's draft.

No topic operation calls Send, Stop, Retry, tool execution or session journal
mutation. Production authority, tools, vault and native acceptance gates remain.

## Validation scope

Focused catalog tests and GPUI fake-platform workflow tests accompany the change.
Their final commands/results are recorded separately once executed. Synthetic GPUI
mouse/keyboard dispatch is not actual interactive desktop evidence or native
macOS/TCC/AX/Keychain/signing/performance acceptance. No completion date or speedup
is inferred from this slice.
