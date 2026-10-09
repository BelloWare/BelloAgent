use crate::{
    AgentView, Palette,
    conversation_content::{SearchPage, Snapshot},
    conversation_content_controller::{Control, Target},
};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

pub(crate) struct ContentSheet {
    pub token: uuid::Uuid,
    pub operation: uuid::Uuid,
    pub target: Target,
    pub query: Entity<EditorView>,
    pub first: Entity<EditorView>,
    pub last: Entity<EditorView>,
    pub snapshot: Option<Snapshot>,
    pub result: Option<SearchPage>,
    pub searched: String,
    pub selected: Option<usize>,
    pub busy: bool,
    pub notice: Option<String>,
    cancel: Arc<AtomicBool>,
    focuses: BTreeMap<&'static str, FocusHandle>,
    controls: Vec<(FocusHandle, Control)>,
    _events: Vec<Subscription>,
}
impl Drop for ContentSheet {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Release);
    }
}
impl ContentSheet {
    pub fn new(
        target: Target,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<AgentView>,
    ) -> Self {
        let mut editor = |text: &str| {
            cx.new(|cx| {
                let mut editor = EditorView::new(text.into(), window, cx);
                editor.set_composer_mode(cx);
                editor.set_appearance(AgentView::composer_style(palette), cx);
                editor
            })
        };
        let query = editor("");
        let first = editor("1");
        let last = editor("1");
        query.read(cx).focus(window);
        let events = [&query, &first, &last]
            .iter()
            .map(|editor| {
                cx.subscribe(editor, |_, _, event, cx| {
                    if matches!(event, EditorEvent::Changed) {
                        cx.notify();
                    }
                })
            })
            .collect();
        Self {
            token: uuid::Uuid::new_v4(),
            operation: uuid::Uuid::new_v4(),
            target,
            query,
            first,
            last,
            snapshot: None,
            result: None,
            searched: String::new(),
            selected: None,
            busy: false,
            notice: None,
            cancel: Arc::new(AtomicBool::new(false)),
            focuses: BTreeMap::new(),
            controls: Vec::new(),
            _events: events,
        }
    }
    pub fn begin(&mut self) -> (uuid::Uuid, uuid::Uuid, Arc<AtomicBool>) {
        self.cancel.store(true, Ordering::Release);
        self.cancel = Arc::new(AtomicBool::new(false));
        self.operation = uuid::Uuid::new_v4();
        self.busy = true;
        self.notice = Some("Reading retained conversation…".into());
        (self.token, self.operation, self.cancel.clone())
    }
    fn button(
        &mut self,
        id: &'static str,
        label: &'static str,
        control: Control,
        enabled: bool,
        palette: Palette,
        cx: &mut Context<AgentView>,
    ) -> Stateful<Div> {
        let focus = self
            .focuses
            .entry(id)
            .or_insert_with(|| cx.focus_handle())
            .clone();
        if enabled {
            self.controls.push((focus.clone(), control.clone()));
        }
        let token = self.token;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .px(px(9.))
            .py(px(6.))
            .rounded(px(5.))
            .border_1()
            .border_color(palette.hairline())
            .text_size(px(12.))
            .child(label)
            .when(!enabled, |d| d.opacity(0.45))
            .when(enabled, |d| {
                d.track_focus(&focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .hover(|d| d.bg(palette.accent_soft()))
                    .focus(|d| d.border_color(rgb(palette.accent)))
            })
            .on_click(cx.listener(move |view, _, window, cx| {
                if enabled {
                    view.content_control(token, control.clone(), window, cx);
                }
            }))
    }
}
impl AgentView {
    pub(crate) fn conversation_content_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(sheet) = self.conversation_content.as_ref() else {
            return;
        };
        let token = sheet.token;
        let editor_focused = [&sheet.query, &sheet.first, &sheet.last]
            .iter()
            .any(|editor| editor.read(cx).focus_handle(cx).is_focused(window));
        let control_focused = sheet
            .controls
            .iter()
            .any(|(focus, _)| focus.is_focused(window));
        if !editor_focused && !control_focused {
            sheet.query.read(cx).focus(window);
            cx.stop_propagation();
            return;
        }
        let marked = [&sheet.query, &sheet.first, &sheet.last]
            .iter()
            .any(|editor| editor.read(cx).has_marked_text());
        if marked {
            return;
        }
        let key = &event.keystroke;
        if key.key == "tab"
            && !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
        {
            let mut focuses = vec![
                sheet.query.read(cx).focus_handle(cx),
                sheet.first.read(cx).focus_handle(cx),
                sheet.last.read(cx).focus_handle(cx),
            ];
            focuses.extend(sheet.controls.iter().map(|(focus, _)| focus.clone()));
            let current = focuses.iter().position(|focus| focus.is_focused(window));
            let next = match current {
                Some(index) if key.modifiers.shift => (index + focuses.len() - 1) % focuses.len(),
                Some(index) => (index + 1) % focuses.len(),
                None => 0,
            };
            focuses[next].focus(window);
            cx.stop_propagation();
            return;
        }
        if key.modifiers.platform || key.modifiers.control || key.modifiers.alt {
            return;
        }
        let control = match event.keystroke.key.as_str() {
            "escape" => Some(Control::Close),
            "enter" | "space" => sheet
                .controls
                .iter()
                .find(|(focus, _)| focus.is_focused(window))
                .map(|(_, control)| control.clone())
                .or_else(|| {
                    (event.keystroke.key == "enter"
                        && sheet.query.read(cx).focus_handle(cx).is_focused(window))
                    .then_some(Control::Search)
                }),
            _ => None,
        };
        if let Some(control) = control {
            self.content_control(token, control, window, cx);
            self.cancelled_prompt_key = Some(event.keystroke.key.clone());
            cx.stop_propagation();
        }
    }
    pub(crate) fn conversation_content_element(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Div> {
        let mut sheet = self.conversation_content.take()?;
        if !sheet.target.matches(self) {
            return None;
        }
        let p = self.palette;
        let token = sheet.token;
        let ready = !sheet.busy;
        sheet.controls.clear();
        let mut panel = div().id("conversation-content-sheet").debug_selector(|| "conversation-content-sheet".into()).w(px(860.)).max_w(window.viewport_size().width - px(40.)).max_h(window.viewport_size().height - px(40.)).p(px(20.)).rounded(px(12.)).bg(rgb(p.surface)).border_1().border_color(p.hairline()).text_color(rgb(p.ink)).flex().flex_col().gap(px(10.)).occlude().on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(div().text_size(px(18.)).child("Search and copy conversation"))
            .child(div().text_size(px(12.)).text_color(rgb(p.secondary)).child("Retained text in this loaded chat, including older messages. Hidden context, provider state and image bytes are omitted."));
        panel = panel.child(
            div()
                .flex()
                .gap(px(8.))
                .child(
                    div()
                        .id("content-query")
                        .debug_selector(|| "content-query".into())
                        .h(px(38.))
                        .flex_1()
                        .border_1()
                        .border_color(p.hairline())
                        .child(sheet.query.clone()),
                )
                .child(sheet.button("content-search", "Search", Control::Search, ready, p, cx)),
        );
        let mut results = div()
            .id("content-results")
            .debug_selector(|| "content-results".into())
            .h(px(
                (f32::from(window.viewport_size().height) - 405.).clamp(100., 330.)
            ))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(3.));
        if let Some(result) = &sheet.result {
            for hit in &result.hits {
                let position = hit.position;
                results = results.child(
                    div()
                        .id(SharedString::from(format!("content-hit-{position}")))
                        .debug_selector(move || format!("content-hit-{position}"))
                        .p(px(7.))
                        .rounded(px(4.))
                        .text_size(px(12.))
                        .when(sheet.selected == Some(position), |d| d.bg(p.accent_soft()))
                        .child(format!("{} · {}", position, hit.preview))
                        .cursor_pointer()
                        .on_click(cx.listener(move |view, _, window, cx| {
                            view.content_control(token, Control::Select(position), window, cx)
                        })),
                );
            }
            if result.hits.is_empty() {
                results = results.child("No matches on this page");
            }
        }
        let total = sheet.result.as_ref().map_or(0, |r| r.total);
        let hits = sheet.result.as_ref().map_or(0, |r| r.hits.len());
        let next = ready && sheet.result.as_ref().is_some_and(|r| r.next.is_some());
        let selected = ready && sheet.selected.is_some();
        panel = panel.child(results).child(
            div()
                .flex()
                .gap(px(8.))
                .items_center()
                .child(div().flex_1().text_size(px(12.)).child(format!(
                    "{hits} matches on this page · {total} retained messages"
                )))
                .child(sheet.button("content-next", "Next Results", Control::Next, next, p, cx))
                .child(sheet.button(
                    "content-reveal",
                    "Show in Transcript",
                    Control::Reveal,
                    selected,
                    p,
                    cx,
                )),
        );
        panel = panel.child(
            div()
                .flex()
                .gap(px(8.))
                .items_center()
                .child(div().text_size(px(12.)).child("From"))
                .child(
                    div()
                        .id("content-first")
                        .debug_selector(|| "content-first".into())
                        .w(px(70.))
                        .h(px(36.))
                        .border_1()
                        .border_color(p.hairline())
                        .child(sheet.first.clone()),
                )
                .child(div().text_size(px(12.)).child("through"))
                .child(
                    div()
                        .id("content-last")
                        .debug_selector(|| "content-last".into())
                        .w(px(70.))
                        .h(px(36.))
                        .border_1()
                        .border_color(p.hairline())
                        .child(sheet.last.clone()),
                )
                .child(sheet.button(
                    "content-start",
                    "Start at Selection",
                    Control::Start,
                    selected,
                    p,
                    cx,
                ))
                .child(sheet.button(
                    "content-end",
                    "End at Selection",
                    Control::End,
                    selected,
                    p,
                    cx,
                )),
        );
        if let Some(notice) = &sheet.notice {
            panel = panel.child(div().text_size(px(12.)).child(notice.clone()));
        }
        let valid = sheet
            .first
            .read(cx)
            .text()
            .trim()
            .parse::<usize>()
            .ok()
            .zip(sheet.last.read(cx).text().trim().parse::<usize>().ok())
            .is_some_and(|(first, last)| first >= 1 && last >= first && last <= total);
        panel = panel
            .child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child(
                "Copy limit: 8 MiB. Use a smaller inclusive range for larger conversations.",
            ))
            .child(
                div()
                    .flex()
                    .gap(px(8.))
                    .justify_end()
                    .child(sheet.button("content-close", "Done", Control::Close, true, p, cx))
                    .child(sheet.button(
                        "content-copy-range",
                        "Copy Range",
                        Control::CopyRange,
                        ready && valid,
                        p,
                        cx,
                    ))
                    .child(sheet.button(
                        "content-copy-all",
                        "Copy Conversation",
                        Control::CopyAll,
                        ready && total > 0,
                        p,
                        cx,
                    )),
            );
        self.conversation_content = Some(sheet);
        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00000060))
                .occlude()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(panel),
        )
    }
}
