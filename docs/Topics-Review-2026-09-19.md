# Project topics — 2026-09-19

Released: Bello Agent 0.1.56/build 60.

## Behavior

Topics group related sessions within one project, like a single level of
subfolders. They are Bello Agent desktop metadata rather than filesystem
directories, and do not add instructions or change a conversation's working
directory, model, context, or tools.

Each project has a New Topic action. Topic rows show a folder, name, chat count,
disclosure control, New Chat button, and actions menu. Empty topics remain
visible. Topics can be renamed, and removing one returns its chats to the
project; the confirmation explicitly says that the chats are kept. Topics are
listed before ungrouped chats in stable creation order, so renaming a topic
does not rearrange the sidebar.

New Chat inside a topic creates the session there. A session can be dragged onto
a topic header, or onto its project header to return to the project root. The
session's context menu and conversation actions also offer Move to Topic. A
parent move includes its saved side-session descendants; the menus and drop
help disclose that behavior. Moving a child independently preserves its parent
relationship. Children whose parent is in another topic remain accessible as
roots in their own group. Side sessions and independent forks inherit their
source's group when created; a fork remains a separate session rather than a
child branch.

Pins, unread indicators, project archive filters, and session reference actions
continue to work within each group. Each topic and the ungrouped section have
their own Show more limit. Filtering a topic name reveals all its contents;
matching a chat reveals its topic and any matching branch's ancestors. Clearing
the filter restores stored topic disclosure preferences. Explicit session
selection reveals its project, topic, and ancestors. Sidebar keyboard ordering
follows the same topics-first order. Only deliberate disclosure and paging
actions animate; streamed metrics do not animate the whole sidebar.

Topic names and membership survive restart, including retained history whose
project configuration is unavailable. That history can still be organized;
starting a new chat continues to require a trusted configured project. Scratch,
connection-test, and background utility sessions cannot be moved into topics.

## Persistence and concurrent work

Topic creation, rename, disclosure changes, session moves, and removal use the
desktop metadata store. Membership moves validate the entire requested batch
and commit together in an SQLite transaction. The store discovers durable side
descendants within that transaction, including a child committed just before
its sidebar row becomes visible. Invalid targets or cross-project members
reject the operation before membership changes.

Topic membership participates in the session's organization revision alongside
rename, pin, and archive state. An older path, model, title, or turn-metadata
write cannot restore an earlier topic. Topic rows have their own revisions;
deletion records prevent delayed writes from resurrecting a removed topic.
Removing a topic clears every retained member rather than only the currently
loaded sidebar page. Invalid or missing topic references fall back to the
project root so history stays reachable.

Keeping a side and moving its parent use the current durable group at commit
time. A side that appears while a move is completing follows its parent's
current published organization, rather than an older operation's captured
destination. A delayed move result cannot reinsert a previously known chat whose deletion
completed while the move was pending. Pending disclosure writes are coalesced
per topic, and shutdown
can drain topic writes and in-flight operations. Topic changes are rejected
while conflicting project changes or app installation preparation are active.

Moving or removing a topic does not select, send, stop, restart, or replace a
running conversation. Journals, drafts, queued messages, request captures, and
session identifiers remain separate from this organizational metadata.

## Drag boundary

The sidebar advertises a custom session drag type with own-process visibility;
it does not advertise text or file representations. Its versioned payload
contains the source session and project identifiers plus a per-process nonce.
The decoder bounds payloads to 4 KiB and a drop to 32 providers, validates every
item, rejects other projects/processes, and deduplicates repeated session IDs.
One invalid provider rejects the entire drop. Successful drops call the same
model transaction as the Move to Topic menu. The packaged Info.plist declares
this custom data type with public.data conformance, following [Apple's custom
type declaration requirements](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app). It advertises no file extension.

## Validation

The focused native Release run passed 90 tests, including topic/store transactions,
legacy metadata, stale writes, side publication and removal races, session
creation/inheritance, sidebar ordering and selection, and organization while
work is running. The native item-provider checks exercise decoding, dispatch,
deduplication, and rejection without a physical drag. A hosted SwiftUI/AppKit
sidebar check covers empty topics and filtering a collapsed topic without
changing its saved disclosure state. The final bundle check and release verification are recorded in the
[0.1.56 acceptance record](validation/Bello-Agent-0.1.56-2026-09-19.md).

This remote desktop is inactive. Physical pointer drag/drop, context-menu
interaction, and VoiceOver traversal have not been verified. In-process
provider/layout tests are not presented as that interactive coverage. Fresh
installation and Sparkle update/relaunch rehearsals remain skipped under the
owner's standing instruction. This feature adds one topic level; it does not
add nested topics, cross-project moves, topic reordering, or a multi-selection
sidebar interface.

Scratch evidence is under
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/topics-056-20260919`.
