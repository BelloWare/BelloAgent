# The sides panel

A chat's sides open one at a time in the side pane beside it. Switching
between them meant a trip across the window to the sidebar, where they are
listed under their chat. The sides panel lists the open chat's sides at the
window's right edge, next to the side pane. The sidebar still lists every
side, and the side pane's header is as it was.

## What it lists

- **New side** first. It starts a side, as New side in the chat's menu does.
- Each side of the open chat, in the sidebar's order. A side has a mark (a
  ring while it works, the orange dot of a new reply, the red dot of a
  failure, otherwise a quiet dot), its title (two lines at most) and what it
  is doing or when it last did something: "Working", "New reply · 3m ago",
  "Saved". A side opened and not yet saved is listed first, as "New side".
- The side in the side pane is highlighted, and the highlight glides to the
  one chosen, as the sidebar's does.
- The header reads "Sides" with the count and the chat's title, and holds
  the pin.

A click on a side shows it in the side pane, opening the pane if no side is
open. Nothing in the sidebar unfolds for it, as for a click in the sidebar:
the side list the reader folded, a collapsed topic and the archive switch
all stay as they were.

## Hidden until the pointer rests at the edge

Unpinned, which is the default, the panel is hidden.

- It comes when the pointer rests on the window's rightmost 3 points for
  0.2 s. It slides in over the conversation as an overlay with a shadow, so
  nothing under it moves, reflows or draws again.
- It never comes while a mouse button is down, so dragging the side pane's
  scroll bar or the window's edge does not bring it.
- It stays while the pointer is on it. It goes 0.4 s after the pointer has
  left it and the edge, so crossing the edge on the way somewhere else does
  not flicker it.
- With Reduce Motion it appears and disappears without sliding.
- It is there only on the chats page, beside a chat that has sides or can
  open one.

While the panel is out, where the pointer is gets checked every tenth of a
second rather than left to enter and exit events: AppKit sends none for a
view that appears under a pointer already there. The strips that sense the
pointer take no clicks, so a press goes to whatever is under them.

## The handle

While the panel is hidden, a faint grip at the right edge, halfway down,
says it is there. It stands clear of the scroll bar when the system shows
scroll bars all the time. It carries the ring, the orange dot or the red dot
when a side other than the one on screen is working, has a new reply or
failed. Resting the pointer on it brings the panel, as the edge does. A chat
with no sides has no handle, but the edge still brings the panel, with only
New side in it.

## Pinned

The pin in the panel's header makes it a column of the window, docked at
the right as the sidebar is at the left. The panes narrow to give it room.
Pinning and unpinning are the only times the panel changes the layout.
Unpinned under the pointer, it stays out as an overlay until the pointer
leaves it. The pin is remembered across launches with the chat that was open
(`RememberedSelection.sidesPanelPinned`).

## Code

- `Workspaces/SidesPanel.swift`:
  - `SidesPanelReveal` (the rest, the grace and the checks while out);
  - `SidesPanelPointerArea` (a strip that senses the pointer and takes no
    clicks);
  - `SidesPanelEdge` (the handle, the edge and the overlay);
  - `SidesPanel` and its rows;
  - `sidesPanelEntries`, `sidesPanelActivity`, `openFromSidesPanel` and
    `setSidesPanelPinned` on `WorkspaceModel`.
- `WorkspaceView`: the overlay on the content column, and the pinned column.
- `WorkspaceModel.sidesPanelPinned` and `sidesPanelReveal`, remembered in
  `Workspaces/WorkspaceLaunchSelection.swift`.
- Tests: `SidesPanelTests`. The gallery scenes are
  `22-sides-handle-{light,dark}`, `22a-sides-revealed-{light,dark}` and
  `22b-sides-pinned-{light,dark}`; `PI_APP_UI_GALLERY_SIDES_PANEL_ONLY=1`
  renders them alone.
