//! Swift 0.1.122's full table (`Transcript/LargeMarkdownTable.swift`): a
//! table too large to show whole in a reply opens in a window of its own —
//! its bar (the title, the row count and "Copy full table as TSV"), the grid
//! with only the rows on screen drawn, and the chosen cell's whole text
//! under it, selectable. Nothing of the table is omitted.
use crate::Palette;
use bello_workbench_ui::{EditorAppearance, EditorView};
use gpui::{prelude::*, *};
use std::rc::Rc;

pub(crate) const PLACEHOLDER: &str =
    "Select a cell to read and copy its full contents. Rows are compact; no data is omitted.";
const BAR: f32 = 48.;
const DETAIL: f32 = 120.;
const ROW: f32 = 26.;
const SPACING: f32 = 12.;
/// Where the bar's words start, clear of the window's buttons.
const TRAFFIC_LIGHTS: f32 = 78.;

/// `MarkdownTablePresentation.tsv`: tab-separated, a field with a tab, a
/// line break or a quote in quotes, its quotes doubled.
pub(crate) fn tsv(header: &[String], rows: &[Vec<String>]) -> String {
    let field = |text: &String| {
        if text.contains(['\t', '\n', '\r', '"']) {
            format!("\"{}\"", text.replace('"', "\"\""))
        } else {
            text.clone()
        }
    };
    std::iter::once(header)
        .chain(rows.iter().map(Vec::as_slice))
        .map(|row| row.iter().map(field).collect::<Vec<_>>().join("\t"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Each column's width: from its title and the first 40 rows, a bounded
/// sample, so scrolling never changes a column's width.
pub(crate) fn column_widths(header: &[String], rows: &[Vec<String>]) -> Vec<f32> {
    let columns = header
        .len()
        .max(rows.iter().map(Vec::len).max().unwrap_or(0));
    (0..columns)
        .map(|index| {
            let title = title(header, index);
            let length = std::iter::once(title.as_str())
                .chain(
                    rows.iter()
                        .take(40)
                        .filter_map(|row| row.get(index).map(String::as_str)),
                )
                .map(|text| text.chars().take(60).count())
                .max()
                .unwrap_or(12);
            (length as f32 * 7. + 24.).clamp(120., 420.)
        })
        .collect()
}

fn title(header: &[String], index: usize) -> String {
    header
        .get(index)
        .cloned()
        .unwrap_or_else(|| format!("Column {}", index + 1))
}

/// A count as Swift's `formatted()` writes it.
fn grouped(count: usize) -> String {
    super::selection::grouped(count)
}

pub(crate) struct TableWindow {
    header: Rc<Vec<String>>,
    rows: Rc<Vec<Vec<String>>>,
    widths: Rc<Vec<f32>>,
    palette: Palette,
    selected: Option<(usize, Option<usize>)>,
    detail: Entity<EditorView>,
    scroll: UniformListScrollHandle,
    focus: FocusHandle,
}

/// Opens the full table in a window of its own.
pub(crate) fn open(header: Vec<String>, rows: Vec<Vec<String>>, palette: Palette, cx: &mut App) {
    let title = format!("Table · {} rows", grouped(rows.len()));
    let options = WindowOptions {
        titlebar: Some(TitlebarOptions {
            title: Some(title.into()),
            appears_transparent: true,
            traffic_light_position: Some(point(px(18.), px(17.))),
        }),
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            size(px(880.), px(600.)),
            cx,
        ))),
        window_min_size: Some(size(px(440.), px(300.))),
        ..Default::default()
    };
    let _ = cx.open_window(options, move |window, cx| {
        let table = cx.new(|cx| TableWindow::new(header, rows, palette, window, cx));
        table.read(cx).focus.focus(window);
        table
    });
}

impl TableWindow {
    fn new(
        header: Vec<String>,
        rows: Vec<Vec<String>>,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let detail = cx.new(|cx| {
            let mut editor = EditorView::new(PLACEHOLDER.to_owned(), window, cx);
            editor.set_read_only(true, cx);
            editor.set_appearance(Self::appearance(palette, true), cx);
            editor
        });
        Self {
            widths: Rc::new(column_widths(&header, &rows)),
            header: Rc::new(header),
            rows: Rc::new(rows),
            palette,
            selected: None,
            detail,
            scroll: UniformListScrollHandle::new(),
            focus: cx.focus_handle(),
        }
    }

    fn appearance(palette: Palette, placeholder: bool) -> EditorAppearance {
        let mut appearance = EditorAppearance::plain();
        appearance.text = rgb(if placeholder {
            palette.secondary
        } else {
            palette.ink
        })
        .into();
        appearance.background = None;
        appearance.selection = palette.accent_soft();
        appearance.caret = rgb(palette.accent).into();
        appearance.accent = rgb(palette.accent).into();
        appearance.wrap_lines = true;
        appearance.show_gutter = false;
        appearance.show_status = false;
        appearance.show_vim_toggle = false;
        appearance
    }

    /// `selectCell`: the cell's whole text, or the row's cells tab-joined
    /// where no column was hit.
    fn select(&mut self, row: usize, column: Option<usize>, cx: &mut Context<Self>) {
        let Some(cells) = self.rows.get(row) else {
            return;
        };
        self.selected = Some((row, column));
        let text = match column {
            Some(column) => cells.get(column).cloned().unwrap_or_default(),
            None => cells.join("\t"),
        };
        let palette = self.palette;
        self.detail.update(cx, |editor, cx| {
            editor.set_text(text, cx);
            editor.set_appearance(Self::appearance(palette, false), cx);
        });
        cx.notify();
    }

    fn copy_table(&self, cx: &mut App) {
        cx.write_to_clipboard(ClipboardItem::new_string(tsv(&self.header, &self.rows)));
    }

    #[cfg(test)]
    pub(crate) fn detail_text(&self, cx: &App) -> String {
        self.detail.read(cx).text().to_owned()
    }
}

impl Render for TableWindow {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = self.palette;
        let hairline = p.hairline();
        let strong = rgba(if p.dark { 0xffffff29 } else { 0x0000001f });
        let total: f32 = self.widths.iter().sum();
        let header = div()
            .flex()
            .flex_row()
            .h(px(ROW))
            .bg(rgb(p.sunken))
            .border_b_1()
            .border_color(hairline)
            .children(self.widths.iter().enumerate().map(|(index, width)| {
                div()
                    .flex_none()
                    .w(px(*width))
                    .h_full()
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .border_r_1()
                    .border_color(hairline)
                    .text_size(px(11.5))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(p.secondary))
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis()
                    .child(title(&self.header, index))
            }));
        let (rows, widths, selected) = (self.rows.clone(), self.widths.clone(), self.selected);
        let view = cx.entity().downgrade();
        let list = uniform_list(
            "markdown-table-rows",
            self.rows.len(),
            move |range, _, _| {
                range
                    .map(|row| {
                        let lit = selected.is_some_and(|(at, _)| at == row);
                        div()
                            .id(("markdown-table-row", row))
                            .debug_selector(move || format!("markdown-table-row-{row}"))
                            .flex()
                            .flex_row()
                            .h(px(ROW))
                            .border_b_1()
                            .border_color(hairline)
                            .when(lit, |line| line.bg(p.accent_soft()))
                            .children(widths.iter().enumerate().map(|(column, width)| {
                                let view = view.clone();
                                div()
                                    .id(("markdown-table-cell", row * 4096 + column))
                                    .flex_none()
                                    .w(px(*width))
                                    .h_full()
                                    .px(px(8.))
                                    .flex()
                                    .items_center()
                                    .border_r_1()
                                    .border_color(hairline)
                                    .text_size(px(13.))
                                    .text_color(rgb(p.ink))
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .text_ellipsis()
                                    .child(rows[row].get(column).cloned().unwrap_or_default())
                                    .on_click(move |_, _, cx| {
                                        let _ = view.update(cx, |table, cx| {
                                            table.select(row, Some(column), cx)
                                        });
                                    })
                            }))
                    })
                    .collect()
            },
        )
        .track_scroll(self.scroll.clone())
        .w(px(total))
        .flex_1();
        let frame = |surface: bool| {
            div()
                .rounded(px(12.))
                .border_1()
                .border_color(hairline)
                .overflow_hidden()
                .when(surface, |frame| frame.bg(rgb(p.surface)))
        };
        div()
            .track_focus(&self.focus)
            // File > Close Window (⌘W) closes the table's own window.
            .on_action(|_: &crate::application_menus::CloseWindow, window, _| {
                window.remove_window()
            })
            .size_full()
            .bg(rgb(p.window))
            .flex()
            .flex_col()
            .text_color(rgb(p.ink))
            .child(
                div()
                    .h(px(BAR))
                    .flex_none()
                    .pl(px(TRAFFIC_LIGHTS))
                    .pr(px(SPACING))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("Table"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.5))
                                    .text_color(rgb(p.secondary))
                                    .child(format!("{} rows", grouped(self.rows.len()))),
                            ),
                    )
                    .child(
                        div()
                            .id("table-window-copy")
                            .debug_selector(|| "table-window-copy".into())
                            .px(px(11.))
                            .py(px(5.))
                            .rounded(px(8.))
                            .bg(rgb(p.surface))
                            .border_1()
                            .border_color(strong)
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .cursor_pointer()
                            .hover(move |button| button.bg(p.fill()))
                            .child("Copy full table as TSV")
                            .on_click(cx.listener(|table, _, _, cx| table.copy_table(cx))),
                    ),
            )
            .child(
                frame(false).mx(px(SPACING)).flex_1().min_h_0().child(
                    div()
                        .id("markdown-table-grid")
                        .size_full()
                        .overflow_x_scroll()
                        .child(
                            div()
                                .w(px(total))
                                .h_full()
                                .flex()
                                .flex_col()
                                .child(header)
                                .child(list),
                        ),
                ),
            )
            .child(
                frame(true)
                    .m(px(SPACING))
                    .h(px(DETAIL))
                    .flex_none()
                    .p(px(8.))
                    .child(self.detail.clone()),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::{column_widths, tsv};

    #[test]
    fn tsv_quotes_fields_that_need_it() {
        let header = vec!["a".to_owned(), "b\tc".to_owned()];
        let rows = vec![vec!["say \"hi\"".to_owned(), "two\nlines".to_owned()]];
        assert_eq!(
            tsv(&header, &rows),
            "a\t\"b\tc\"\n\"say \"\"hi\"\"\"\t\"two\nlines\""
        );
    }

    #[test]
    fn columns_are_sized_from_a_bounded_sample() {
        let header = vec!["id".to_owned()];
        let mut rows: Vec<Vec<String>> = (0..50).map(|_| vec!["x".to_owned()]).collect();
        // Past the sample: no effect.
        rows[45] = vec!["y".repeat(80), "z".to_owned()];
        assert_eq!(column_widths(&header, &rows), [120., 120.]);
        rows[0] = vec!["w".repeat(30)];
        assert_eq!(column_widths(&header, &rows)[0], 30. * 7. + 24.);
        rows[1] = vec!["w".repeat(90)];
        assert_eq!(column_widths(&header, &rows)[0], 420.);
    }
}
