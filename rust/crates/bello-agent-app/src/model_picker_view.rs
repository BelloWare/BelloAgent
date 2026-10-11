//! The model and effort pills and their lists, drawn after Swift
//! ModelSwitchControls.swift (`ComposerPillButton`, `PiKit.ChoiceList`) and
//! CatalogModelPickerView.swift (390-point column, 16-point padding, 12-point
//! gaps, rows of at most 340 points at 68 a row).
use crate::{
    AgentView,
    model_picker::{
        PickerKind, clock_time, context_label, filtered, menu_title, output_limit_label,
    },
};
use bello_agent_core::model_choice::ThinkingLevel;
use gpui::{prelude::*, *};

const PICKER_WIDTH: f32 = 390.;
const ROWS_HEIGHT: f32 = 340.;
const ROW_ESTIMATE: f32 = 68.;
const EFFORT_LABEL_WIDTH: f32 = 176.;
const INCLUDED_NOTE: &str = "Included models change with app updates. Choose a saved custom catalog above or set its URL in Settings.";

fn hint(text: String, palette: crate::Palette, cx: &mut App) -> AnyView {
    cx.new(|_| crate::composer_attachments::TextHint { text, palette })
        .into()
}
fn warning(p: crate::Palette) -> u32 {
    if p.dark { 0xe3b15c } else { 0xb97a1e }
}

impl AgentView {
    /// One composer pill: icon (accent while a choice is in force), words at
    /// 12 points medium, a spinner slot while the catalog loads, and the
    /// chevron; 9 points across (7 compact), 4 points above and below.
    fn composer_pill(
        &self,
        id: &'static str,
        icon: &'static str,
        text: Option<(String, f32)>,
        active: bool,
        loading: bool,
        disabled: bool,
    ) -> Stateful<Div> {
        let p = self.palette;
        let compact = text.is_none();
        let mut pill = div()
            .id(id)
            .debug_selector(move || id.into())
            .flex()
            .flex_shrink_0()
            .items_center()
            .gap(px(5.))
            .px(px(if compact { 7. } else { 9. }))
            .py(px(4.))
            .rounded_full()
            .bg(p.fill())
            .text_size(px(12.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(rgb(p.ink))
            .child(svg().path(icon).size(px(11.)).text_color(rgb(if active {
                p.accent
            } else {
                p.secondary
            })));
        if let Some((text, width)) = text {
            pill = pill.child(div().max_w(px(width)).truncate().child(text));
        }
        if loading {
            pill = pill.child(
                svg()
                    .path("spinner")
                    .size(px(6.))
                    .mx(px(2.))
                    .text_color(rgb(p.secondary)),
            );
        }
        pill = pill.child(self.icon("down", 9.));
        if disabled {
            pill.opacity(0.45)
        } else {
            pill.cursor_pointer().hover(move |s| s.bg(p.accent_soft()))
        }
    }
    /// The model and effort pills (Swift `session-model-picker` and
    /// `session-reasoning-picker`); `compact` drops the effort words and
    /// `icons` the model's, as the bar narrows.
    pub(crate) fn model_switch_pills(
        &self,
        compact: bool,
        icons: bool,
        cx: &mut Context<Self>,
    ) -> [Stateful<Div>; 2] {
        let reading = self.model_pill_reading();
        let model = self
            .composer_pill(
                "session-model-picker",
                "cpu",
                (!icons).then(|| (reading.model.clone(), if compact { 110. } else { 170. })),
                reading.model_active,
                reading.loading,
                reading.disabled,
            )
            .tooltip({
                let help = reading.model_help.clone();
                let palette = self.palette;
                move |_, cx| hint(help.clone(), palette, cx)
            })
            .on_click(cx.listener(|view, event: &ClickEvent, window, cx| {
                view.model_pickers.anchor = event.position();
                view.toggle_model_picker(PickerKind::Model, window, cx)
            }));
        let effort = self
            .composer_pill(
                "session-reasoning-picker",
                "brain",
                (!compact).then(|| (reading.effort.clone(), EFFORT_LABEL_WIDTH)),
                reading.effort_active,
                false,
                reading.disabled,
            )
            .on_click(cx.listener(|view, event: &ClickEvent, window, cx| {
                view.model_pickers.anchor = event.position();
                view.toggle_model_picker(PickerKind::Effort, window, cx)
            }));
        [model, effort]
    }

    /// The open list, above the pill it came from, over a backdrop that
    /// closes it (a second press on the pill closes it too).
    pub(crate) fn model_picker_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<[AnyElement; 2]> {
        let open = self.model_pickers.open.as_ref()?;
        if open.chat != self.record.id || self.model_picker_suppressed(cx) {
            self.model_pickers.open = None;
            return None;
        }
        let panel = match open.kind {
            PickerKind::Model => self.model_panel(window, cx),
            PickerKind::Effort => self.effort_panel(cx),
        };
        let backdrop = div()
            .id("model-picker-backdrop")
            .absolute()
            .inset_0()
            .occlude()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|view, _, window, cx| view.close_model_picker(window, cx)),
            )
            .into_any_element();
        let popover = deferred(
            anchored()
                .position(self.model_pickers.anchor)
                .anchor(Corner::BottomLeft)
                .offset(point(px(-12.), px(-14.)))
                .snap_to_window_with_margin(px(8.))
                .child(
                    panel
                        .occlude()
                        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation()),
                ),
        )
        .with_priority(10)
        .into_any_element();
        Some([backdrop, popover])
    }

    fn effort_panel(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = self.palette;
        let open = self.model_pickers.open.as_ref().expect("open picker");
        let token = open.token;
        let levels = self.offered_effort_levels();
        let current = ThinkingLevel::of(&self.chat_model_choice());
        let mut list = div()
            .id("reasoning-effort-list")
            .debug_selector(|| "reasoning-effort-list".into())
            .w(px(240.))
            .p(px(6.))
            .rounded(px(10.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(1.))
            .child(
                div()
                    .px(px(8.))
                    .pt(px(4.))
                    .pb(px(4.))
                    .text_size(px(10.5))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgb(p.tertiary))
                    .child("REASONING EFFORT"),
            );
        for (index, level) in levels.into_iter().enumerate() {
            let chosen = level == current;
            let selector = format!("reasoning-effort-{}", level.raw());
            list = list.child(
                div()
                    .id(("reasoning-effort", index))
                    .debug_selector(move || selector.clone())
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(8.))
                    .py(px(5.))
                    .rounded(px(6.))
                    .text_size(px(13.))
                    .text_color(rgb(p.ink))
                    .cursor_pointer()
                    .when(index == open.highlighted, |row| row.bg(p.accent_soft()))
                    .hover(move |row| row.bg(p.fill()))
                    .child(
                        div().w(px(12.)).child(
                            svg()
                                .path(if chosen { "checkmark" } else { "circle" })
                                .size(px(11.))
                                .text_color(rgb(if chosen { p.accent } else { p.tertiary }))
                                .when(!chosen, |icon| icon.opacity(0.)),
                        ),
                    )
                    .child(level.label())
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.choose_chat_effort(token, level, window, cx)
                    })),
            );
        }
        if let Some(note) = self.effort_note() {
            list = list.child(
                div()
                    .debug_selector(|| "reasoning-effort-note".into())
                    .px(px(8.))
                    .pt(px(6.))
                    .pb(px(2.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.tertiary))
                    .child(note),
            );
        }
        list
    }

    fn model_panel(&self, window: &mut Window, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = self.palette;
        let open = self.model_pickers.open.as_ref().expect("open picker");
        let token = open.token;
        let choice = self.chat_model_choice();
        let profile_model = self
            .controller
            .profile()
            .map(|profile| profile.model_id)
            .unwrap_or_default();
        let current = choice
            .model
            .clone()
            .unwrap_or_else(|| profile_model.clone());
        let default_selected = choice.model.is_none();
        let catalog = self.chat_catalog();
        let loading = open.refreshing || catalog.is_none_or(|c| c.loading);
        let configured = catalog.is_some_and(|c| c.configured);
        let offered = catalog.map_or_else(Vec::new, |c| c.offered(Some(&current)));
        let query = open
            .search
            .as_ref()
            .map(|search| search.read(cx).text().to_owned())
            .unwrap_or_default();
        let matches = filtered(offered.clone(), &query);
        let error = open
            .refresh_error
            .clone()
            .or_else(|| catalog.and_then(|c| c.error.clone()));
        let fetched = catalog.and_then(|c| c.fetched).map(|(_, at)| at);

        // The whole list fits the window and scrolls when it cannot.
        let available = (f32::from(window.viewport_size().height) - 16.).max(200.);
        let mut column = div()
            .id("model-catalog-picker")
            .max_h(px(available))
            .overflow_y_scroll()
            .debug_selector(|| "model-catalog-picker".into())
            .w(px(PICKER_WIDTH))
            .p(px(16.))
            .rounded(px(10.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(12.))
            .text_color(rgb(p.ink));
        // The titles, the spinner while it loads, and Refresh.
        let refresh_enabled = !loading;
        column = column.child(
            div()
                .flex()
                .items_center()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(3.))
                        .child(
                            div()
                                .text_size(px(13.))
                                .font_weight(FontWeight::BOLD)
                                .child(if configured {
                                    "Model catalog"
                                } else {
                                    "Bello model catalog"
                                }),
                        )
                        .child(
                            div()
                                .text_size(px(11.5))
                                .text_color(rgb(p.secondary))
                                .truncate()
                                .child(catalog.map(|c| c.source_name.clone()).unwrap_or_default()),
                        )
                        .child(
                            div()
                                .debug_selector(|| "model-picker-source".into())
                                .text_size(px(11.5))
                                .text_color(rgb(p.tertiary))
                                .line_clamp(2)
                                .child(
                                    catalog
                                        .map(|c| c.source_label.clone())
                                        .filter(|label| !label.is_empty())
                                        .unwrap_or_else(|| crate::model_picker::source_label(None)),
                                ),
                        ),
                )
                .child(div().w(px(8.)))
                .when(loading, |row| {
                    row.child(
                        svg()
                            .path("spinner")
                            .size(px(12.))
                            .mr(px(8.))
                            .text_color(rgb(p.secondary)),
                    )
                })
                .child(
                    div()
                        .id("refresh-model-catalog")
                        .debug_selector(|| "refresh-model-catalog".into())
                        .size(px(28.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(6.))
                        .tooltip(move |_, cx| {
                            hint(
                                "Reload this saved connection and refresh its model list".into(),
                                p,
                                cx,
                            )
                        })
                        .child(
                            svg()
                                .path("arrow.clockwise")
                                .size(px(13.))
                                .text_color(rgb(p.ink)),
                        )
                        .when(!refresh_enabled, |button| button.opacity(0.45))
                        .when(refresh_enabled, |button| {
                            button
                                .cursor_pointer()
                                .hover(move |s| s.bg(p.fill()))
                                .on_click(cx.listener(move |view, _, _, cx| {
                                    view.refresh_chat_catalog(token, cx)
                                }))
                        }),
                ),
        );
        // Search.
        if let Some(search) = &open.search {
            let empty_query = query.is_empty();
            column = column.child(
                div()
                    .id("model-catalog-search")
                    .debug_selector(|| "model-catalog-search".into())
                    .relative()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(8.))
                    .h(px(28.))
                    .rounded(px(7.))
                    .border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.content))
                    .child(
                        svg()
                            .path("magnifyingglass")
                            .size(px(12.))
                            .text_color(rgb(p.tertiary)),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_w_0()
                            .h_full()
                            .child(search.clone())
                            .when(empty_query, |field| {
                                field.child(
                                    div()
                                        .absolute()
                                        .left(px(6.))
                                        .top(px(5.))
                                        .text_size(px(13.))
                                        .text_color(rgb(p.tertiary))
                                        .child("Search model names or aliases"),
                                )
                            }),
                    ),
            );
        }
        // Use connection default.
        column = column.child(
            div()
                .id("model-use-connection-default")
                .debug_selector(|| "model-use-connection-default".into())
                .flex()
                .items_center()
                .gap(px(8.))
                .cursor_pointer()
                .child(
                    svg()
                        .path(if default_selected {
                            "checkmark"
                        } else {
                            "circle"
                        })
                        .size(px(11.5))
                        .text_color(rgb(if default_selected {
                            p.accent
                        } else {
                            p.tertiary
                        })),
                )
                .child(
                    div()
                        .flex_1()
                        .text_size(px(11.5))
                        .line_clamp(2)
                        .child(format!("Use connection default · {profile_model}")),
                )
                .on_click(cx.listener(move |view, _, window, cx| {
                    view.choose_chat_model(token, None, window, cx)
                })),
        );
        if let Some(error) = &error {
            let mut block = div()
                .debug_selector(|| "model-catalog-error".into())
                .flex()
                .flex_col()
                .gap(px(3.))
                .text_size(px(11.5))
                .text_color(rgb(warning(p)));
            if !offered.is_empty() {
                block = block.child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .child("Refresh failed · showing the last list"),
                );
            }
            column = column.child(block.child(error.clone()));
        }
        if matches.is_empty() {
            column = column.child(
                div()
                    .debug_selector(|| "model-catalog-empty".into())
                    .h(px(70.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(13.))
                    .text_color(rgb(p.secondary))
                    .child(if loading {
                        "Loading models…"
                    } else if offered.is_empty() {
                        "No models are listed by this connection."
                    } else {
                        "No matching models."
                    }),
            );
        } else {
            let mut rows = div()
                .id("model-catalog-rows")
                .h(px((matches.len() as f32 * ROW_ESTIMATE).min(ROWS_HEIGHT)))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap(px(2.));
            for (index, item) in matches.iter().enumerate() {
                let chosen = !default_selected && item.id == current;
                let id = item.id.clone();
                let selector = format!("catalog-choice-{}", item.id);
                let mut name_row = div().flex().items_baseline().gap(px(5.)).child(
                    div()
                        .text_size(px(13.))
                        .child(item.display_name().to_owned()),
                );
                if item.mini == Some(true) {
                    name_row = name_row.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.accent))
                            .child("Mini"),
                    );
                }
                if item
                    .input
                    .as_ref()
                    .is_some_and(|i| i.iter().any(|k| k == "image"))
                {
                    name_row = name_row.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.secondary))
                            .child("Images"),
                    );
                }
                if item.deprecated {
                    name_row = name_row.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(warning(p)))
                            .child("Deprecated"),
                    );
                }
                let mut words = div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(name_row);
                if item.display_name() != item.id {
                    words = words.child(
                        div()
                            .text_size(px(12.))
                            .font_family("Menlo")
                            .text_color(rgb(p.secondary))
                            .child(item.id.clone()),
                    );
                }
                if !item.description.is_empty() {
                    words = words.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.secondary))
                            .line_clamp(2)
                            .child(item.description.clone()),
                    );
                }
                for line in [context_label(item), output_limit_label(item)]
                    .into_iter()
                    .flatten()
                {
                    words = words.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.tertiary))
                            .child(line),
                    );
                }
                let title = menu_title(item);
                rows = rows.child(
                    div()
                        .id(("catalog-choice", index))
                        .debug_selector(move || selector.clone())
                        .flex()
                        .items_start()
                        .gap(px(8.))
                        .p(px(8.))
                        .rounded(px(6.))
                        .cursor_pointer()
                        .when(chosen, |row| row.bg(p.accent_soft()))
                        .when(!chosen, |row| row.hover(move |s| s.bg(p.fill())))
                        .child(
                            div().w(px(14.)).pt(px(2.)).flex().justify_center().child(
                                svg()
                                    .path(if chosen { "checkmark" } else { "cpu" })
                                    .size(px(11.))
                                    .text_color(rgb(if chosen { p.accent } else { p.tertiary })),
                            ),
                        )
                        .child(words)
                        .tooltip(move |_, cx| hint(title.clone(), p, cx))
                        .on_click(cx.listener(move |view, _, window, cx| {
                            view.choose_chat_model(token, Some(id.clone()), window, cx)
                        })),
                );
            }
            column = column.child(rows);
        }
        let listed =
            fetched.is_some() && catalog.is_some_and(|c| c.error.is_none() || !c.models.is_empty());
        if listed && !current.is_empty() && !offered.iter().any(|row| row.id == current) {
            column = column.child(
                div()
                    .debug_selector(|| "model-not-listed".into())
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .child(format!("Current selection “{current}” is not listed by this source. It remains selected until you choose another model.")),
            );
        }
        // Count, last update and the alias toggle.
        let entering = open.entering_alias;
        column = column.child(
            div()
                .flex()
                .items_baseline()
                .gap(px(8.))
                .text_size(px(11.5))
                .text_color(rgb(p.tertiary))
                .child(format!("{} models", offered.len()))
                .when_some(
                    fetched.filter(|_| !loading && catalog.is_some_and(|c| c.error.is_none())),
                    |row, at| {
                        row.child(
                            div()
                                .debug_selector(|| "model-catalog-refreshed-at".into())
                                .child(format!("Updated {}", clock_time(at))),
                        )
                    },
                )
                .child(div().flex_1())
                .child(
                    div()
                        .id("model-enter-alias")
                        .debug_selector(|| "model-enter-alias".into())
                        .text_color(rgb(p.ink))
                        .cursor_pointer()
                        .child(if entering {
                            "Hide alias field"
                        } else {
                            "Enter alias…"
                        })
                        .on_click(cx.listener(move |view, _, window, cx| {
                            view.toggle_alias_entry(token, window, cx)
                        })),
                ),
        );
        if entering && let Some(alias) = &open.alias {
            let empty_alias = alias.read(cx).text().is_empty();
            column = column.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(
                        div()
                            .id("model-alias-field")
                            .debug_selector(|| "model-alias-field".into())
                            .relative()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .px(px(8.))
                            .h(px(28.))
                            .rounded(px(7.))
                            .border_1()
                            .border_color(p.hairline())
                            .bg(rgb(p.content))
                            .child(svg().path("cpu").size(px(12.)).text_color(rgb(p.tertiary)))
                            .child(
                                div()
                                    .relative()
                                    .flex_1()
                                    .min_w_0()
                                    .h_full()
                                    .child(alias.clone())
                                    .when(empty_alias, |field| {
                                        field.child(
                                            div()
                                                .absolute()
                                                .left(px(6.))
                                                .top(px(5.))
                                                .text_size(px(12.))
                                                .text_color(rgb(p.tertiary))
                                                .child(profile_model.clone()),
                                        )
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .id("model-alias-use")
                            .debug_selector(|| "model-alias-use".into())
                            .px(px(10.))
                            .py(px(4.))
                            .rounded(px(7.))
                            .bg(rgb(p.brand))
                            .text_color(p.on_accent())
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .cursor_pointer()
                            .child("Use")
                            .on_click(cx.listener(move |view, _, window, cx| {
                                view.submit_model_alias(token, window, cx)
                            })),
                    ),
            );
        }
        if !configured {
            column = column.child(
                div()
                    .text_size(px(11.5))
                    .text_color(rgb(p.tertiary))
                    .child(INCLUDED_NOTE),
            );
        }
        column
    }
}
