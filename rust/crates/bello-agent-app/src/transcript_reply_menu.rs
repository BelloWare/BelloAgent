//! Swift 0.1.122's reply menus (`ReplyMenu.entries`, the response strip's
//! and a reply part's `menu(for:)`, `MarkdownTextView.menu(for:)`): a
//! right-click on a response's strip offers its fold and Copy Reply; on a
//! reply's words, Fold This Response to One Line and Copy Reply; on a
//! selection, the selection's own Copy. Request Details (the Session
//! Inspector) and Fork from Here are not offered: Rust has neither yet.
use super::{RowKey, TranscriptView, selection::SelectionHost};
use crate::{AgentView, native_menu::MenuEntry, transcript_actions::MessageKey};
use bello_agent_core::Controller;
use gpui::{App, ClipboardItem, MouseDownEvent, Pixels, Point, WeakEntity, Window};
use std::{cell::RefCell, rc::Rc, sync::Weak};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReplyCommand {
    Fold,
    Show,
    CopyReply,
    CopySelection,
}

/// Where the right-click landed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Place {
    /// The response's strip; whether the response is folded to it.
    Strip { collapsed: bool },
    /// A reply's own row.
    Reply,
    /// The reader's selection.
    Selection,
}

/// The menu's lines and what each does, in Swift's order.
pub(crate) fn entries(place: Place) -> Vec<(Option<ReplyCommand>, MenuEntry)> {
    let item = |command, title: &str| {
        (
            Some(command),
            MenuEntry::Item {
                title: title.into(),
                symbol: None,
                enabled: true,
            },
        )
    };
    match place {
        Place::Selection => vec![item(ReplyCommand::CopySelection, "Copy")],
        Place::Strip { collapsed } => vec![
            if collapsed {
                item(ReplyCommand::Show, "Show This Response")
            } else {
                item(ReplyCommand::Fold, "Fold This Response to One Line")
            },
            (None, MenuEntry::Separator),
            item(ReplyCommand::CopyReply, "Copy Reply"),
        ],
        Place::Reply => vec![
            item(ReplyCommand::Fold, "Fold This Response to One Line"),
            (None, MenuEntry::Separator),
            item(ReplyCommand::CopyReply, "Copy Reply"),
        ],
    }
}

/// What a menu acts on, captured when it opens; checked again when the
/// reader chooses.
#[derive(Clone)]
pub(super) struct Target {
    pub transcript: WeakEntity<TranscriptView>,
    pub parent: WeakEntity<AgentView>,
    pub chat_id: String,
    pub controller: Weak<Controller>,
    /// The response's own key and the reply's message.
    pub owner: RowKey,
    pub message: String,
    pub selection: Rc<RefCell<SelectionHost>>,
}

impl Target {
    pub(super) fn perform(&self, command: ReplyCommand, window: &mut Window, cx: &mut App) {
        match command {
            ReplyCommand::CopySelection => {
                if let Some(text) = self.selection.borrow().copy() {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
            }
            ReplyCommand::CopyReply => {
                let key = MessageKey::new(self.chat_id.clone(), self.message.clone());
                let controller = self.controller.clone();
                let _ = self.parent.update(cx, |view, cx| {
                    view.copy_transcript_message(&key, &controller, cx)
                });
            }
            ReplyCommand::Fold | ReplyCommand::Show => {
                let fold = command == ReplyCommand::Fold;
                let (owner, chat_id, controller) = (
                    self.owner.clone(),
                    self.chat_id.clone(),
                    self.controller.clone(),
                );
                let _ = self.transcript.update(cx, |view, cx| {
                    let folded = view
                        .opened
                        .contains(&RowKey::Response(Box::new(owner.clone())));
                    if folded != fold {
                        view.toggle_response(owner, &chat_id, &controller, window, cx);
                    }
                });
            }
        }
    }

    /// Opens the menu for `place` where the pointer is.
    pub(super) fn open(
        &self,
        place: Place,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let entries = entries(place);
        #[cfg(test)]
        {
            let _ = (position, &window);
            OPENED.with(|opened| *opened.borrow_mut() = Some((entries, self.clone())));
            let _ = cx;
        }
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let native = entries.iter().map(|(_, entry)| entry.clone()).collect();
            let target = self.clone();
            let handle = window.window_handle();
            crate::native_menu::show_menu(cx, handle, position, native, move |index, _, cx| {
                let Some(command) = index.and_then(|index| entries.get(index)?.0) else {
                    return;
                };
                let _ = handle.update(cx, |_, window, cx| target.perform(command, window, cx));
            });
        }
        #[cfg(all(not(target_os = "macos"), not(test)))]
        {
            // The drawn menu other platforms use is the sidebar's alone.
            let _ = (entries, position, window, cx);
        }
    }
}

/// A right-click on a reply's row: the selection's menu over the selection,
/// the reply's elsewhere.
pub(super) fn on_reply(
    target: Target,
) -> impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static {
    move |event, window, cx| {
        let place = {
            let host = target.selection.borrow();
            let on_selection = host.range_in_message(&target.message).is_some()
                && host.painted.iter().any(|row| row.contains(&event.position));
            if on_selection {
                Place::Selection
            } else {
                Place::Reply
            }
        };
        cx.stop_propagation();
        target.open(place, event.position, window, cx);
    }
}

#[cfg(test)]
type Opened = Option<(Vec<(Option<ReplyCommand>, MenuEntry)>, Target)>;
#[cfg(test)]
thread_local! {
    /// The menu a right-click opened last, for tests: native menus track
    /// in a nested loop no test can reach.
    pub(crate) static OPENED: RefCell<Opened> =
        const { RefCell::new(None) };
}

/// Chooses `title` in the menu a right-click opened last.
#[cfg(test)]
pub(crate) fn choose(title: &str, window: &mut Window, cx: &mut App) -> bool {
    let Some((entries, target)) = OPENED.with(|opened| opened.borrow_mut().take()) else {
        return false;
    };
    let Some(command) = entries.iter().find_map(|(command, entry)| match entry {
        MenuEntry::Item { title: item, .. } if item == title => *command,
        _ => None,
    }) else {
        return false;
    };
    target.perform(command, window, cx);
    true
}

/// The titles of the menu a right-click opened last.
#[cfg(test)]
pub(crate) fn opened_titles() -> Vec<String> {
    OPENED.with(|opened| {
        opened
            .borrow()
            .as_ref()
            .map_or_else(Vec::new, |(entries, _)| {
                entries
                    .iter()
                    .map(|(_, entry)| match entry {
                        MenuEntry::Item { title, .. } => title.clone(),
                        MenuEntry::Note(note) => note.clone(),
                        MenuEntry::Separator => "-".into(),
                    })
                    .collect()
            })
    })
}
