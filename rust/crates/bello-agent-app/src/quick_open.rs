//! Source layout: QuickOpenPanel.swift / WorkspaceQuickOpen.swift. Search and
//! listing use the shared bounded FileFinder index on background executors.
use crate::theme::Palette;
use bello_workbench::{
    git::CancellationToken,
    quick_open::{FileFinderIndex, FileFinderMatch, FileFinderQuery, FileListingOptions},
};
use bello_workbench_ui::{EditorAppearance, EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::{path::PathBuf, sync::Arc};
#[derive(Clone, Debug)]
pub enum QuickOpenEvent {
    Open { path: PathBuf, line: Option<usize> },
    Dismissed,
}
#[derive(Default)]
struct RequestOrder {
    presentation: u64,
    query: u64,
    open: bool,
}
impl RequestOrder {
    fn show(&mut self) -> u64 {
        self.presentation += 1;
        self.open = true;
        self.presentation
    }
    fn close(&mut self) {
        self.presentation += 1;
        self.query += 1;
        self.open = false;
    }
    fn search(&mut self) -> (u64, u64) {
        self.query += 1;
        (self.presentation, self.query)
    }
    fn accepts(&self, key: (u64, u64)) -> bool {
        self.open && (self.presentation, self.query) == key
    }
}
pub struct QuickOpenView {
    root: PathBuf,
    palette: Palette,
    field: Entity<EditorView>,
    order: RequestOrder,
    index: Option<Arc<FileFinderIndex>>,
    rows: Vec<FileFinderMatch>,
    recent: Vec<FileFinderMatch>,
    selected: usize,
    scroll: UniformListScrollHandle,
    listing: bool,
    searching: bool,
    notice: Option<String>,
    line: Option<usize>,
    listing_cancel: CancellationToken,
    search_cancel: CancellationToken,
    previous_focus: Option<FocusHandle>,
    _subscription: Subscription,
}
impl EventEmitter<QuickOpenEvent> for QuickOpenView {}
impl QuickOpenView {
    pub fn new(
        root: PathBuf,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let field = cx.new(|cx| {
            let mut field = EditorView::new(String::new(), window, cx);
            field.set_appearance(Self::style(palette), cx);
            field
        });
        let subscription = cx.subscribe(&field, |view, _, event, cx| {
            if matches!(event, EditorEvent::Changed) {
                view.search(cx);
            }
        });
        Self {
            root,
            palette,
            field,
            order: RequestOrder::default(),
            index: None,
            rows: Vec::new(),
            recent: Vec::new(),
            selected: 0,
            scroll: UniformListScrollHandle::new(),
            listing: false,
            searching: false,
            notice: None,
            line: None,
            listing_cancel: CancellationToken::new(),
            search_cancel: CancellationToken::new(),
            previous_focus: None,
            _subscription: subscription,
        }
    }
    fn style(p: Palette) -> EditorAppearance {
        let mut style = EditorAppearance::plain();
        style.font_family = if cfg!(target_os = "macos") {
            ".SystemUIFont"
        } else {
            "DejaVu Sans"
        }
        .into();
        style.font_size = 15.;
        style.line_height = 22.;
        style.padding_x = 0.;
        style.padding_y = 0.;
        style.text = rgb(p.ink).into();
        style.selection = p.accent_soft();
        style.caret = rgb(p.accent).into();
        style.wrap_lines = false;
        style
    }
    pub fn set_palette(&mut self, p: Palette, cx: &mut Context<Self>) {
        self.palette = p;
        self.field
            .update(cx, |field, cx| field.set_appearance(Self::style(p), cx));
    }
    pub fn is_open(&self) -> bool {
        self.order.open
    }
    pub fn show(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.order.open {
            return;
        }
        self.previous_focus = window.focused(cx);
        let presentation = self.order.show();
        self.listing_cancel.cancel();
        self.listing_cancel = CancellationToken::new();
        self.notice = None;
        self.selected = 0;
        self.field.update(cx, |field, cx| {
            field.set_text(String::new(), cx);
            field.focus(window);
        });
        self.search(cx);
        self.listing = true;
        let root = self.root.clone();
        let options = FileListingOptions {
            cancellation: self.listing_cancel.clone(),
            ..Default::default()
        };
        let task = cx
            .background_executor()
            .spawn(async move { FileFinderIndex::build(root, &options) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if !view.order.open || view.order.presentation != presentation {
                    return;
                }
                view.listing = false;
                match result {
                    Ok(index) => {
                        view.index = Some(Arc::new(index));
                        view.search(cx);
                    }
                    Err(error) => view.notice = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub fn close(&mut self, restore: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.order.close();
        self.listing_cancel.cancel();
        self.search_cancel.cancel();
        self.listing = false;
        self.searching = false;
        if restore && let Some(focus) = self.previous_focus.take() {
            focus.focus(window);
        }
        cx.emit(QuickOpenEvent::Dismissed);
        cx.notify();
    }
    fn search(&mut self, cx: &mut Context<Self>) {
        if !self.order.open {
            return;
        }
        self.search_cancel.cancel();
        self.search_cancel = CancellationToken::new();
        let query = FileFinderQuery::new(self.field.read(cx).text());
        self.line = query.line;
        let key = self.order.search();
        self.selected = 0;
        self.rows.clear();
        self.searching = false;
        if query.is_empty() {
            // These are actual project-local open receipts, not a recursive
            // membership scan on the UI thread. A removed file reports its
            // current state when selected, as any stale search result can.
            self.rows = self.recent.clone();
            cx.notify();
            return;
        }
        let Some(index) = self.index.clone() else {
            cx.notify();
            return;
        };
        self.searching = true;
        let cancel = self.search_cancel.clone();
        let task = cx
            .background_executor()
            .spawn(async move { index.search(&query, 50, &cancel) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if !view.order.accepts(key) {
                    return;
                }
                view.searching = false;
                match result {
                    Ok(rows) => {
                        view.rows = rows;
                        view.selected = 0;
                        view.scroll.scroll_to_item(0, ScrollStrategy::Top);
                    }
                    Err(error) => view.notice = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.rows.is_empty() {
            return;
        }
        self.selected =
            (self.selected as isize + delta).clamp(0, self.rows.len() as isize - 1) as usize;
        self.scroll
            .scroll_to_item(self.selected, ScrollStrategy::Top);
        cx.notify();
    }
    fn choose(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(row) = self.rows.get(index) else {
            return;
        };
        let recent = row.clone();
        let relative = row.path.clone();
        let path = self
            .index
            .as_ref()
            .map(|index| index.root().join(&relative))
            .unwrap_or_else(|| self.root.join(&relative));
        self.recent.retain(|old| old.path != relative);
        self.recent.insert(0, recent);
        self.recent.truncate(30);
        cx.emit(QuickOpenEvent::Open {
            path,
            line: self.line,
        });
        self.close(false, window, cx);
    }
    pub fn key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.order.open {
            return false;
        }
        let key = event.keystroke.key.as_str();
        let mods = &event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        match key {
            "escape" => self.close(true, window, cx),
            "w" if command => self.close(true, window, cx),
            "up" => self.move_selection(-1, cx),
            "down" => self.move_selection(1, cx),
            "pageup" => self.move_selection(-12, cx),
            "pagedown" => self.move_selection(12, cx),
            "n" if mods.control => self.move_selection(1, cx),
            "p" if mods.control => self.move_selection(-1, cx),
            "enter" if !self.field.read(cx).has_marked_text() => {
                self.choose(self.selected, window, cx)
            }
            _ => return false,
        }
        true
    }
    fn footer_status(&self, cx: &App) -> String {
        if let Some(notice) = &self.notice {
            return notice.clone();
        }
        let name = self.root.file_name().unwrap_or_default().to_string_lossy();
        if self.listing && self.rows.is_empty() {
            return format!("Finding the files in {name}…");
        }
        let typed = self.field.read(cx).text().trim();
        let coverage = if self.index.as_ref().is_some_and(|index| index.truncated()) {
            format!(
                " · Only the first {} files are searched",
                self.index.as_ref().unwrap().count()
            )
        } else {
            String::new()
        };
        if self.rows.is_empty() {
            return if typed.is_empty() {
                format!(
                    "Type part of a file's name to find it in {name}. End with :N to open at line N.{coverage}"
                )
            } else if self.searching {
                "Finding…".into()
            } else {
                format!("No file in {name} matches “{typed}”.{coverage}")
            };
        }
        format!(
            "↑↓ to choose · ↩ to open{} · esc to close{coverage}",
            self.line
                .map(|line| format!(" at line {line}"))
                .unwrap_or_default()
        )
    }
    fn footer(&self, cx: &App) -> String {
        let status = self.footer_status(cx);
        if let Some(index) = &self.index
            && let Some(warning) = index.warnings().first()
        {
            format!(
                "{status}\n{warning}{}",
                if index.warnings().len() > 1 {
                    format!(" (and {} more)", index.warnings().len() - 1)
                } else {
                    String::new()
                }
            )
        } else {
            status
        }
    }
}
impl Drop for QuickOpenView {
    fn drop(&mut self) {
        self.listing_cancel.cancel();
        self.search_cancel.cancel();
    }
}
impl Render for QuickOpenView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = self.palette;
        let placeholder = format!(
            "Find a file in {}",
            self.root.file_name().unwrap_or_default().to_string_lossy()
        );
        let mut panel = div()
            .id("quick-open-panel")
            .w_full()
            .rounded(px(14.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .overflow_hidden()
            .flex()
            .flex_col()
            .text_color(rgb(p.ink))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .h(px(46.))
                    .px(px(14.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(
                        svg()
                            .path("search")
                            .size(px(14.))
                            .text_color(rgb(p.tertiary)),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_w_0()
                            .h(px(22.))
                            .child(self.field.clone())
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|view, _, window, cx| {
                                    view.field.read(cx).focus(window)
                                }),
                            )
                            .when(self.field.read(cx).text().is_empty(), |d| {
                                d.child(
                                    div()
                                        .absolute()
                                        .inset_0()
                                        .text_size(px(15.))
                                        .text_color(rgb(p.tertiary))
                                        .child(placeholder),
                                )
                            }),
                    )
                    .when(self.listing || self.searching, |d| {
                        d.child(
                            div()
                                .text_size(px(11.5))
                                .text_color(rgb(p.tertiary))
                                .child("…"),
                        )
                    }),
            );
        if !self.rows.is_empty() {
            let recent = self.field.read(cx).text().trim().is_empty();
            if recent {
                panel = panel.child(
                    div()
                        .px(px(14.))
                        .pt(px(8.))
                        .pb(px(4.))
                        .text_size(px(10.5))
                        .text_color(rgb(p.tertiary))
                        .child("OPENED LATELY"),
                );
            }
            panel = panel.child(
                uniform_list(
                    "quick-open-results",
                    self.rows.len(),
                    cx.processor(|view, range: std::ops::Range<usize>, _, cx| {
                        range
                            .map(|i| {
                                let row = &view.rows[i];
                                let name_start = row.display_path.rfind('/').map_or(0, |at| at + 1);
                                let name = row.display_path[name_start..].to_owned();
                                let folder =
                                    row.display_path[..name_start.saturating_sub(1)].to_owned();
                                let highlights = row
                                    .highlights
                                    .iter()
                                    .filter_map(|range| {
                                        let start = range.start.max(name_start);
                                        let end = range.end;
                                        if start >= end {
                                            return None;
                                        }
                                        Some((
                                            start - name_start..end - name_start,
                                            HighlightStyle {
                                                color: Some(rgb(view.palette.accent).into()),
                                                font_weight: Some(FontWeight::SEMIBOLD),
                                                ..Default::default()
                                            },
                                        ))
                                    })
                                    .collect::<Vec<_>>();
                                div()
                                    .id(i)
                                    .h(px(32.))
                                    .mx(px(6.))
                                    .px(px(10.))
                                    .rounded(px(8.))
                                    .flex()
                                    .items_center()
                                    .gap(px(9.))
                                    .when(i == view.selected, |d| d.bg(view.palette.accent_soft()))
                                    .cursor_pointer()
                                    .hover(|d| d.bg(view.palette.fill()))
                                    .on_click(cx.listener(move |view, _, window, cx| {
                                        view.choose(i, window, cx)
                                    }))
                                    .child(
                                        svg()
                                            .path("book")
                                            .size(px(16.))
                                            .text_color(rgb(view.palette.tertiary)),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(13.))
                                            .font_weight(FontWeight::MEDIUM)
                                            .truncate()
                                            .child(
                                                StyledText::new(name).with_highlights(highlights),
                                            ),
                                    )
                                    .when(!folder.is_empty(), |d| {
                                        d.child(
                                            div()
                                                .flex_1()
                                                .min_w_0()
                                                .text_size(px(12.))
                                                .text_color(rgb(view.palette.secondary))
                                                .truncate()
                                                .child(folder),
                                        )
                                    })
                            })
                            .collect()
                    }),
                )
                .track_scroll(self.scroll.clone())
                .h(px((self.rows.len().min(12) * 32) as f32 + 12.))
                .py(px(6.))
                .border_t_1()
                .border_color(p.hairline()),
            );
        }
        panel.child(
            div()
                .px(px(14.))
                .py(px(9.))
                .border_t_1()
                .border_color(p.hairline())
                .bg(rgb(p.sunken))
                .text_size(px(11.5))
                .text_color(rgb(p.secondary))
                .line_clamp(2)
                .child(self.footer(cx)),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::RequestOrder;
    #[test]
    fn stale_search_and_closed_listing_cannot_publish() {
        let mut order = RequestOrder::default();
        order.show();
        let old = order.search();
        let latest = order.search();
        assert!(!order.accepts(old));
        assert!(order.accepts(latest));
        order.close();
        assert!(!order.accepts(latest));
        order.show();
        assert!(!order.accepts(latest));
    }
}
