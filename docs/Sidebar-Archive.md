# The archive switch

Archiving a chat takes it out of the sidebar's lists without deleting
anything: its history, draft, unread state and captures stay, and a running
chat is stopped. Archived chats are read-only until they are restored.

## One switch for every project

Until this version each project had its own archive: an "Archive · N" link
under its chats, and "Show Archived Chats" in its menu, swapped the project's
list for its archived chats. Now one switch in the sidebar's footer (the
archive box beside the other toggles, also View ▸ Show Archived Chats)
lists the archived chats of every project at once.

- **Off:** every project lists its active chats. A project whose chats are
  all archived says "No active chats".
- **On:** each group lists its archived chats after its active ones, under
  an "Archived · N" heading. A group is a topic or a project's own chats
  outside any topic, so an archived chat stays in its topic. Archived titles
  read quieter than active ones, until one is the chat on screen.

An archived row is the row the archive list had: its "Archived" line, its
Restore button, marking, and dragging into another topic or project. The
archived chats of a group page on their own ("Show N more"), so turning the
switch on or off leaves the active list on the page it was on. The filter
field searches both lists while the switch is on.

## What turns it on

- The switch itself, or the View menu.
- Opening an archived chat any other way, such as from the Usage Report or
  by selecting its side: its row has to be seen.

Nothing turns it off but the switch. Opening an active chat, starting a new
one, archiving or restoring a chat leave it as it is. Archiving the open chat
moves to the project's next active chat, as it did before; with no active
chat left, the archived one stays open.

## Across launches

The switch is remembered with the chat that was open
(`RememberedSelection.showArchivedChats`). When a relaunch reopens an
archived chat while the switch is off, the archive is listed for that launch
only, so the chat's row can be seen; the switch the reader left off stays
off, and their own press of it decides from then on.

Project preferences written by earlier versions still read: what they saved
about disclosure stands, and their per-project archive flag is ignored. The
field is kept in the records, as it was read, because earlier versions
require it.

## Code

- `WorkspaceModel.showArchivedSessions`, `sidebarShowsArchived`,
  `setArchivedChatsShown` and `toggleArchivedChats`
  (`Workspaces/ProjectSidebarState.swift`).
- Each group's archived section: `sidebarArchiveContents` and
  `topicGroupContents(includesArchive:)` (`Workspaces/SidebarChatRow.swift`),
  drawn by `SidebarSessionGroup` with its heading
  (`Workspaces/SidebarGroups.swift`).
- Tests: `ArchiveSwitchTests`, and the archive cases in
  `LaunchSelectionTests`, `ProjectSidebarTests` and
  `SessionOrganizationTests`. The gallery scene is
  `14c-sidebar-archive-{light,dark}`.
