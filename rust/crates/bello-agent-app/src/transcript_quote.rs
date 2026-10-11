//! Swift 0.1.122's quote bar (`TranscriptQuoteSelection.swift`): one compact
//! bar floating just above a reply's selection, centred on it, below its
//! last line where there is no room above, inside the part of the
//! conversation on screen. It goes on a press, a scroll or Escape; Return
//! acts. Swift's bar asks in a side chat; Rust has no side chats yet, so the
//! bar quotes the selection into this chat's draft, as Swift quotes it into
//! the side's draft ("> " before each line, a blank line after).
use super::selection::{SelectionHost, quoted_draft};
use crate::{AgentView, Palette};
use bello_agent_core::Controller;
use gpui::{prelude::*, *};
use std::{cell::RefCell, rc::Rc, sync::Weak};

pub(super) const TITLE: &str = "Quote in draft";
const HINT: &str = "↩";
/// Between the bar and the line it stands above (or below).
const GAP: f32 = 6.;
/// The glyph's box (SF Symbol bubble.left.and.bubble.right, 11.5 pt semibold).
const ICON: Size<f32> = Size {
    width: 15.,
    height: 12.,
};

/// The bar's size from its words, as Swift's `QuoteActionBarView` adds it
/// up: the glyph, the title and the key seven apart, 10 in from the lit
/// area, which is 3 in from the surface, 6 above and below.
fn bar_size(window: &Window) -> Size<f32> {
    let width = |text: &str, size: f32, weight: FontWeight| {
        let run = TextRun {
            len: text.len(),
            font: Font {
                weight,
                ..font(".SystemUIFont")
            },
            color: black(),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        f32::from(
            window
                .text_system()
                .shape_line(text.to_owned().into(), px(size), &[run], None)
                .width,
        )
        .ceil()
    };
    let title = width(TITLE, 12.5, FontWeight::MEDIUM);
    let key = width(HINT, 10.5, FontWeight::SEMIBOLD) + 10.;
    let line = Size {
        width: ICON.width + 7. + title + 7. + key,
        height: ICON.height.max(16.),
    };
    Size {
        width: line.width + 26.,
        height: line.height + 18.,
    }
}

/// Where the bar goes: above the selection's first line, centred on the
/// selection, below its last line when there is no room above; never
/// outside the transcript on screen.
pub(super) fn place(
    rows: &[Bounds<Pixels>],
    visible: Bounds<Pixels>,
    bar: Size<f32>,
) -> Option<Point<Pixels>> {
    let first = rows
        .iter()
        .filter(|row| row.intersects(&visible))
        .min_by(|a, b| a.top().partial_cmp(&b.top()).unwrap())?;
    let all = rows
        .iter()
        .filter(|row| row.intersects(&visible))
        .fold(*first, |all, row| all.union(row));
    let (width, height) = (px(bar.width), px(bar.height));
    let x = (all.center().x - width / 2.)
        .min(visible.right() - px(8.) - width)
        .max(visible.left() + px(8.));
    let mut y = first.top() - px(GAP) - height;
    if y < visible.top() {
        y = all.bottom() + px(GAP);
    }
    Some(point(x, y))
}

/// The bar, where the last frame painted the selection.
pub(super) fn bar(
    host: &Rc<RefCell<SelectionHost>>,
    visible: Bounds<Pixels>,
    p: Palette,
    on_quote: impl Fn(&mut Window, &mut App) + 'static,
    window: &Window,
) -> Option<AnyElement> {
    let state = host.borrow();
    if !state.bar || state.quotable().is_none() {
        return None;
    }
    let size = bar_size(window);
    let at = place(&state.painted, visible, size)?;
    let ink = rgb(p.ink);
    let tertiary = rgb(p.tertiary);
    let fill = rgba(if p.dark { 0xffffff0d } else { 0x0000000b });
    let strong = rgba(if p.dark { 0xffffff17 } else { 0x00000013 });
    let hairline = rgba(if p.dark { 0xffffff29 } else { 0x0000001f });
    let shadow = if p.dark {
        hsla(0., 0., 0., 0.34)
    } else {
        rgba(0x2a241817).into()
    };
    let claim = host.clone();
    let bar = div()
        .id("quote-in-draft")
        .debug_selector(|| "quote-in-draft".into())
        .w(px(size.width))
        .h(px(size.height))
        .p(px(3.))
        .rounded(px(10.))
        .bg(rgb(p.surface))
        .border_1()
        .border_color(hairline)
        .shadow(vec![BoxShadow {
            color: shadow,
            offset: point(px(0.), px(3.)),
            blur_radius: px(10.),
            spread_radius: px(0.),
        }])
        .cursor_pointer()
        .group("quote-in-draft")
        .tooltip(|_, cx| cx.new(|_| Hint).into())
        // The bar's own press is no press elsewhere: the selection stays.
        .on_mouse_down(MouseButton::Left, move |_, _, _| {
            claim.borrow_mut().claimed = true;
        })
        .on_click(move |_, window, cx| on_quote(window, cx))
        .child(
            div()
                .size_full()
                .rounded(px(7.))
                .px(px(9.))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(7.))
                .group_hover("quote-in-draft", move |lit| lit.bg(strong))
                .child(
                    svg()
                        .path("bubble.left.and.bubble.right")
                        .w(px(ICON.width))
                        .h(px(ICON.height))
                        .text_color(rgb(p.accent)),
                )
                .child(
                    div()
                        .text_size(px(12.5))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ink)
                        .child(TITLE),
                )
                .child(
                    div()
                        .px(px(5.))
                        .py(px(1.))
                        .rounded(px(4.))
                        .bg(fill)
                        .text_size(px(10.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(tertiary)
                        .child(HINT),
                ),
        );
    Some(deferred(anchored().position(at).child(bar)).into_any_element())
}

struct Hint;
impl Render for Hint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.))
            .py(px(4.))
            .text_size(px(11.))
            .child("Quote the selected text in this chat’s draft (Return)")
    }
}

impl AgentView {
    /// The selection, quoted below this chat's draft, which takes the
    /// focus: refused where the draft cannot take it now.
    pub(crate) fn quote_into_draft(
        &mut self,
        chat_id: &str,
        controller: &Weak<Controller>,
        quote: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // The draft is not the reader's while an operation holds it (it
        // adopts a draft of its own when it settles).
        if !self.active_transcript_matches(chat_id, controller)
            || quote.trim().is_empty()
            || self.busy
            || self.loading
            || self.load_failed
            || self.shutting_down
            || self.queue_operation.is_some()
            || self.edit_recovery.blocked
            || self.has_pending_cancel(&self.record.id)
            || self.editing.is_some()
            || self.chat_is_archived(&self.record.id)
            || self.composer.read(cx).has_marked_text()
        {
            return;
        }
        let draft = quoted_draft(self.composer.read(cx).text(), quote);
        if draft.len() > 262_144 {
            self.error = Some("The quoted draft exceeds 256 KiB. Select a shorter passage.".into());
            cx.notify();
            return;
        }
        let lines = draft.split('\n').count();
        self.composer.update(cx, |editor, cx| {
            editor.set_text(draft, cx);
            editor.reveal_line(lines, window, cx);
        });
        cx.notify();
    }
}

/// The controller a transcript acts for, and its chat.
pub(super) fn quote_target(
    parent: &WeakEntity<AgentView>,
    chat_id: String,
    controller: Weak<Controller>,
) -> impl Fn(&str, &mut Window, &mut App) + 'static {
    let parent = parent.clone();
    move |text, window, cx| {
        let _ = parent.update(cx, |view, cx| {
            view.quote_into_draft(&chat_id, &controller, text, window, cx);
        });
    }
}
