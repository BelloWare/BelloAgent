//! The questions the terminal panel asks over the window (Swift's PiQuestion
//! sheets from TerminalRegistry.requestEnding and requestRename): Restart or
//! Close a live shell, with Cancel the default, and a terminal's name.
use crate::terminal_panel::{QuestionKind, TerminalPanel};
use gpui::{prelude::*, *};

pub(crate) fn element(
    panel: &TerminalPanel,
    window: &mut Window,
    cx: &mut Context<TerminalPanel>,
) -> Option<AnyElement> {
    let question = panel.question.as_ref()?;
    let p = panel.palette;
    let viewport = window.viewport_size();
    let width = 440f32.min((f32::from(viewport.width) - 32.).max(240.));
    let destructive = matches!(question.kind, QuestionKind::End(_));
    let button = |id: &'static str, label: &'static str, primary: bool| {
        div()
            .id(id)
            .debug_selector(move || id.into())
            .px(px(14.))
            .py(px(6.))
            .rounded(px(8.))
            .text_size(px(13.))
            .cursor_pointer()
            .when(primary && destructive, |b| {
                b.bg(rgb(p.danger))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgb(0xffffff))
            })
            .when(primary && !destructive, |b| {
                b.bg(rgb(p.accent))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.on_accent())
            })
            .when(!primary, |b| {
                b.border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.surface))
                    .text_color(rgb(p.ink))
            })
            .child(label)
    };
    let mut body = div()
        .id("terminal-question")
        .debug_selector(|| "terminal-question".into())
        .w(px(width))
        .p(px(24.))
        .rounded(px(16.))
        .bg(rgb(p.surface))
        .border_1()
        .border_color(p.hairline())
        .shadow_lg()
        .flex()
        .flex_col()
        .gap(px(16.))
        .occlude()
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .child(
            div()
                .debug_selector(|| "terminal-question-title".into())
                .text_size(px(17.))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(p.ink))
                .child(question.title.clone()),
        )
        .child(
            div()
                .debug_selector(|| "terminal-question-detail".into())
                .text_size(px(13.))
                .text_color(rgb(p.secondary))
                .child(question.detail.clone()),
        );
    if let QuestionKind::Rename(editor) = &question.kind {
        body = body.child(
            div()
                .debug_selector(|| "terminal-question-field".into())
                .h(px(30.))
                .rounded(px(8.))
                .border_1()
                .border_color(p.hairline())
                .bg(rgb(p.sunken))
                .child(editor.clone()),
        );
    }
    body = body.child(
        div()
            .flex()
            .gap(px(12.))
            .justify_end()
            .child(
                button("terminal-question-cancel", "Cancel", false)
                    .on_click(cx.listener(|panel, _, window, cx| panel.answer(false, window, cx))),
            )
            .child(
                button("terminal-question-action", question.action, true)
                    .on_click(cx.listener(|panel, _, window, cx| panel.answer(true, window, cx))),
            ),
    );
    let rename = matches!(question.kind, QuestionKind::Rename(_));
    let overlay = div()
        .w(viewport.width)
        .h(viewport.height)
        .bg(rgba(0x00000055))
        .flex()
        .items_center()
        .justify_center()
        .occlude()
        .track_focus(&question.focus)
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .capture_key_down(cx.listener(move |panel, event: &KeyDownEvent, window, cx| {
            let key = &event.keystroke;
            let marked = match panel.question.as_ref().map(|q| &q.kind) {
                Some(QuestionKind::Rename(editor)) => editor.read(cx).has_marked_text(),
                _ => false,
            };
            if marked {
                return;
            }
            let command =
                key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
            if key.key == "escape" || (command && key.key == "w") {
                panel.answer(false, window, cx);
                cx.stop_propagation();
            } else if key.key == "enter" && !key.modifiers.shift {
                // Return renames; for an ending it is Cancel, the default.
                if !event.is_held {
                    panel.answer(rename, window, cx);
                }
                cx.stop_propagation();
            } else if key.key == "tab" {
                cx.stop_propagation();
            }
        }))
        .child(body);
    Some(
        deferred(
            anchored()
                .position_mode(AnchoredPositionMode::Window)
                .position(point(px(0.), px(0.)))
                .child(overlay),
        )
        .with_priority(2)
        .into_any_element(),
    )
}
