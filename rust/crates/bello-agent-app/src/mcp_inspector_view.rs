//! Project-scoped MCP presentation. Saved secrets never enter this view. Only
//! typed header replacements use SecureInput; ordinary editors have no secrets.
use crate::{
    connection_settings_view::secure_input::{HEADER_BYTES, SecureInput, SecureInputEvent},
    theme::Palette,
};
use bello_workbench_ui::{EditorAppearance, EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::{collections::BTreeMap, fmt};
use zeroize::Zeroize;

const INPUT_BYTES: usize = 262_144;
const PAGE_BYTES: usize = 65_536;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum McpIntent {
    Refresh,
    ListTools,
    Describe,
    Save,
    Invoke,
    Acknowledge,
    EnableEditing,
    Confirm,
    CancelConfirmation,
    Close,
    KeepDraftClose,
    DiscardClose,
    Reload,
    CancelOperation,
    SelectServer(String),
    SelectTool(String),
    SelectHeader(String),
    PreviousPage,
    NextPage,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct McpToken {
    pub revision: u64,
    pub opening: u64,
}

/// No raw input is formatted by Debug, even malformed configuration/arguments.
#[derive(Clone, Default)]
pub(crate) struct McpInput {
    pub configuration: String,
    pub headers: BTreeMap<String, String>,
    pub arguments: String,
    pub server: String,
    pub tool: String,
}
impl Drop for McpInput {
    fn drop(&mut self) {
        for text in self.headers.values_mut() {
            text.zeroize();
        }
    }
}
impl fmt::Debug for McpInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("McpInput([REDACTED])")
    }
}
#[derive(Clone, Debug)]
pub(crate) struct McpEvent {
    pub token: McpToken,
    pub intent: McpIntent,
    pub input: Option<McpInput>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct McpPresentation {
    pub revision: u64,
    pub synthetic: bool,
    pub ready: bool,
    pub configuration_applied: bool,
    pub receipt_read_failed: bool,
    pub busy: bool,
    pub cancellable: bool,
    pub saving: bool,
    pub blocked: bool,
    pub project_id: Option<String>,
    pub project_path: String,
    pub chat_label: String,
    pub editing: bool,
    pub can_enable_editing: bool,
    pub unknown_id: Option<String>,
    pub pending_results: usize,
    pub servers: Vec<String>,
    pub tools: Vec<(String, String)>,
    pub configured_headers: Vec<String>,
    pub confirmation: Option<(String, String, String)>,
    pub close_confirmation: bool,
    pub notice: String,
}
impl McpPresentation {
    pub fn new(synthetic: bool) -> Self {
        Self {
            revision: 1,
            synthetic,
            ready: false,
            configuration_applied: false,
            receipt_read_failed: false,
            busy: false,
            cancellable: false,
            saving: false,
            blocked: false,
            project_id: None,
            project_path: String::new(),
            chat_label: String::new(),
            editing: false,
            can_enable_editing: false,
            unknown_id: None,
            pending_results: 0,
            servers: vec![],
            tools: vec![],
            configured_headers: vec![],
            confirmation: None,
            close_confirmation: false,
            notice: "Open a saved, trusted project to inspect its MCP configuration.".into(),
        }
    }
    pub fn allows(&self, intent: &McpIntent) -> bool {
        use McpIntent::*;
        if self.saving {
            return false;
        }
        if self.close_confirmation {
            return matches!(intent, CancelConfirmation | KeepDraftClose | DiscardClose);
        }
        if self.confirmation.is_some() {
            return matches!(intent, CancelConfirmation)
                || (matches!(intent, Confirm) && !self.busy);
        }
        if matches!(intent, Close) {
            return true;
        }
        if self.busy {
            return self.cancellable && matches!(intent, CancelOperation);
        }
        if matches!(intent, PreviousPage | NextPage) {
            return true;
        }
        if matches!(intent, Reload) {
            return !self.blocked;
        }
        if !self.synthetic || !self.ready || self.blocked {
            return false;
        }
        if !self.configuration_applied
            && matches!(
                intent,
                Refresh | ListTools | Describe | Invoke | Acknowledge
            )
        {
            return false;
        }
        match intent {
            Invoke => {
                self.editing
                    && !self.receipt_read_failed
                    && self.unknown_id.is_none()
                    && self.pending_results == 0
            }
            Acknowledge => self.unknown_id.is_some() && self.pending_results == 0,
            EnableEditing => self.can_enable_editing,
            Confirm | CancelConfirmation | KeepDraftClose | DiscardClose | CancelOperation => false,
            _ => true,
        }
    }
}

pub(crate) struct McpInspectorView {
    pub presentation: McpPresentation,
    palette: Palette,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    open: bool,
    opening: u64,
    pending: bool,
    baseline: String,
    config: Option<Entity<EditorView>>,
    arguments: Option<Entity<EditorView>>,
    reader: Option<Entity<EditorView>>,
    headers: BTreeMap<String, Entity<SecureInput>>,
    header_server: String,
    server: String,
    tool: String,
    output: String,
    page: usize,
    pages: Vec<std::ops::Range<usize>>,
    subscriptions: Vec<Subscription>,
    buttons: Vec<(McpIntent, FocusHandle)>,
    tab_order: Vec<FocusHandle>,
}
impl EventEmitter<McpEvent> for McpInspectorView {}
impl Focusable for McpInspectorView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}
impl McpInspectorView {
    pub fn new(presentation: McpPresentation, palette: Palette, cx: &mut Context<Self>) -> Self {
        Self {
            presentation,
            palette,
            focus: cx.focus_handle(),
            previous_focus: None,
            open: false,
            opening: 0,
            pending: false,
            baseline: "{\"servers\":{}}".into(),
            config: None,
            arguments: None,
            reader: None,
            headers: BTreeMap::new(),
            header_server: String::new(),
            server: String::new(),
            tool: String::new(),
            output: String::new(),
            page: 0,
            pages: std::iter::once(0..0).collect(),
            subscriptions: vec![],
            buttons: vec![],
            tab_order: vec![],
        }
    }
    fn appearance(&self) -> EditorAppearance {
        EditorAppearance {
            font_family: if cfg!(target_os = "macos") {
                "Menlo"
            } else {
                "DejaVu Sans Mono"
            }
            .into(),
            font_size: 12.,
            line_height: 18.,
            padding_x: 8.,
            padding_y: 5.,
            text: rgb(self.palette.ink).into(),
            selection: self.palette.accent_soft(),
            caret: rgb(self.palette.accent).into(),
            wrap_lines: true,
            ..EditorAppearance::plain()
        }
    }
    pub fn set_palette(&mut self, palette: Palette, cx: &mut Context<Self>) {
        self.palette = palette;
        for editor in [&self.config, &self.arguments, &self.reader]
            .into_iter()
            .flatten()
        {
            editor.update(cx, |e, cx| e.set_appearance(self.appearance(), cx));
        }
        for editor in self.headers.values() {
            editor.update(cx, |e, cx| e.set_appearance(self.appearance(), cx));
        }
        cx.notify();
    }
    pub fn is_open(&self) -> bool {
        self.open
    }
    pub fn token(&self) -> McpToken {
        McpToken {
            revision: self.presentation.revision,
            opening: self.opening,
        }
    }
    pub fn dirty(&self, cx: &App) -> bool {
        self.config
            .as_ref()
            .is_some_and(|e| e.read(cx).text() != self.baseline)
            || self.headers.values().any(|e| !e.read(cx).text().is_empty())
    }
    pub fn input(&self, cx: &App) -> Option<McpInput> {
        let configuration = self
            .config
            .as_ref()
            .map(|e| e.read(cx).text().to_owned())
            .unwrap_or_else(|| self.baseline.clone());
        let active_servers = serde_json::from_str::<serde_json::Value>(&configuration)
            .ok()
            .and_then(|v| {
                v.get("servers")
                    .and_then(serde_json::Value::as_object)
                    .map(|o| o.keys().cloned().collect::<std::collections::BTreeSet<_>>())
            });
        let mut headers = BTreeMap::new();
        for (name, input) in &self.headers {
            if active_servers
                .as_ref()
                .is_some_and(|servers| !servers.contains(name))
            {
                continue;
            }
            let value = input.read(cx).captured_text()?;
            if !value.is_empty() {
                headers.insert(name.clone(), value.to_owned());
            }
        }
        Some(McpInput {
            configuration,
            headers,
            arguments: self
                .arguments
                .as_ref()
                .map(|e| e.read(cx).text().to_owned())
                .unwrap_or_else(|| "{}".into()),
            server: self.server.clone(),
            tool: self.tool.clone(),
        })
    }
    pub fn install_configuration(&mut self, configuration: String, cx: &mut Context<Self>) {
        self.baseline = configuration.clone();
        if let Some(editor) = &self.config {
            editor.update(cx, |e, cx| e.set_text(configuration, cx));
        }
        for input in self.headers.values() {
            input.update(cx, |e, cx| {
                e.set_text(String::new(), cx);
            });
        }
        self.headers.clear();
        self.header_server.clear();
        cx.notify();
    }
    pub fn discard(&mut self, cx: &mut Context<Self>) {
        self.install_configuration(self.baseline.clone(), cx);
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn replace_configuration_draft(&mut self, text: String, cx: &mut Context<Self>) {
        if let Some(editor) = &self.config {
            editor.update(cx, |e, cx| e.set_text(text, cx));
        }
    }
    pub fn show(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.open {
            return;
        }
        self.open = true;
        self.opening = self.opening.wrapping_add(1);
        self.pending = false;
        self.previous_focus = window.focused(cx);
        if self.config.is_none() {
            let appearance = self.appearance();
            let config = cx.new(|cx| {
                let mut e = EditorView::new(self.baseline.clone(), window, cx);
                e.set_compact(true, cx);
                e.set_appearance(appearance.clone(), cx);
                e
            });
            self.subscriptions
                .push(cx.subscribe(&config, |_, _, event, cx| {
                    if matches!(event, EditorEvent::Changed) {
                        cx.notify();
                    }
                }));
            let arguments = cx.new(|cx| {
                let mut e = EditorView::new("{}".into(), window, cx);
                e.set_compact(true, cx);
                e.set_appearance(appearance.clone(), cx);
                e
            });
            let reader = cx.new(|cx| {
                let mut e = EditorView::new(String::new(), window, cx);
                e.set_read_only(true, cx);
                e.set_appearance(appearance, cx);
                e
            });
            self.config = Some(config);
            self.arguments = Some(arguments);
            self.reader = Some(reader);
        }
        self.lock_inputs(cx);
        self.focus.focus(window);
        cx.notify();
    }
    pub fn close(&mut self, restore: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.open = false;
        self.opening = self.opening.wrapping_add(1);
        self.pending = false;
        if restore
            && self.focus.contains_focused(window, cx)
            && let Some(focus) = self.previous_focus.take()
        {
            focus.focus(window);
        }
        self.previous_focus = None;
        self.lock_inputs(cx);
        cx.notify();
    }
    pub fn present(&mut self, presentation: McpPresentation, cx: &mut Context<Self>) {
        if presentation.revision <= self.presentation.revision {
            return;
        }
        self.presentation = presentation;
        self.pending = false;
        if !self.presentation.servers.contains(&self.server) {
            self.server = self
                .presentation
                .servers
                .first()
                .cloned()
                .unwrap_or_default();
            self.tool.clear();
        }
        if !self
            .presentation
            .tools
            .iter()
            .any(|(name, _)| name == &self.tool)
        {
            self.tool.clear();
        }
        self.lock_inputs(cx);
        cx.notify();
    }
    fn lock_inputs(&mut self, cx: &mut Context<Self>) {
        let locked = !self.open
            || self.pending
            || self.presentation.busy
            || self.presentation.saving
            || !self.presentation.ready
            || !self.presentation.synthetic
            || self.presentation.blocked
            || self.presentation.confirmation.is_some()
            || self.presentation.close_confirmation;
        for editor in [&self.config, &self.arguments].into_iter().flatten() {
            editor.update(cx, |e, cx| e.set_read_only(locked, cx));
        }
        for editor in self.headers.values() {
            editor.update(cx, |e, cx| e.set_read_only(locked, cx));
        }
    }
    pub fn select_server(&mut self, server: String, cx: &mut Context<Self>) {
        self.server = server;
        self.tool.clear();
        cx.notify();
    }
    pub fn select_tool(&mut self, tool: String, cx: &mut Context<Self>) {
        self.tool = tool;
        cx.notify();
    }
    pub fn select_header(&mut self, server: String, cx: &mut Context<Self>) {
        self.header_server = server;
        cx.notify();
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn output_text(&self) -> &str {
        &self.output
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn focus_intent(&self, intent: &McpIntent, window: &mut Window) {
        self.buttons
            .iter()
            .find(|(value, _)| value == intent)
            .expect("rendered control")
            .1
            .focus(window);
    }
    pub fn set_output(&mut self, text: String, cx: &mut Context<Self>) {
        self.output = text;
        self.page = 0;
        self.pages.clear();
        let mut start = 0;
        while start < self.output.len() {
            let mut end = (start + PAGE_BYTES).min(self.output.len());
            while !self.output.is_char_boundary(end) {
                end -= 1;
            }
            self.pages.push(start..end);
            start = end;
        }
        if self.pages.is_empty() {
            self.pages.push(0..0);
        }
        self.show_page(cx);
    }
    pub fn change_page(&mut self, forward: bool, cx: &mut Context<Self>) {
        self.page = if forward {
            (self.page + 1).min(self.pages.len() - 1)
        } else {
            self.page.saturating_sub(1)
        };
        self.show_page(cx);
    }
    fn show_page(&mut self, cx: &mut Context<Self>) {
        if let Some(editor) = &self.reader {
            let text = self.output[self.pages[self.page].clone()].to_owned();
            editor.update(cx, |e, cx| e.set_text(text, cx));
        }
        cx.notify();
    }
    fn enabled(&self, intent: &McpIntent) -> bool {
        self.open
            && !self.pending
            && self.presentation.allows(intent)
            && match intent {
                McpIntent::ListTools => !self.server.is_empty(),
                McpIntent::Describe | McpIntent::Invoke => {
                    !self.server.is_empty() && !self.tool.is_empty()
                }
                McpIntent::PreviousPage => self.page > 0,
                McpIntent::NextPage => self.page + 1 < self.pages.len(),
                _ => true,
            }
    }
    pub fn dispatch(&mut self, token: McpToken, intent: McpIntent, cx: &mut Context<Self>) {
        if token != self.token() || !self.enabled(&intent) {
            return;
        }
        let input = self.input(cx);
        self.pending = true;
        self.lock_inputs(cx);
        cx.emit(McpEvent {
            token,
            intent,
            input,
        });
        cx.notify();
    }
    pub fn request_close(&mut self, cx: &mut Context<Self>) {
        self.dispatch(self.token(), McpIntent::Close, cx);
    }
    pub fn key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.open {
            return false;
        }
        if self.headers.values().any(|e| e.read(cx).has_marked_text()) {
            return false;
        }
        let mods = event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        let intent = match event.keystroke.key.as_str() {
            "escape" => Some(
                if self.presentation.confirmation.is_some() || self.presentation.close_confirmation
                {
                    McpIntent::CancelConfirmation
                } else {
                    McpIntent::Close
                },
            ),
            "w" if command => Some(McpIntent::Close),
            "s" if command => Some(McpIntent::Save),
            _ => None,
        };
        if let Some(intent) = intent {
            if !event.is_held {
                self.dispatch(self.token(), intent, cx);
            }
            return true;
        }
        if event.keystroke.key == "tab" && !mods.platform && !mods.control && !mods.alt {
            if !self.tab_order.is_empty() {
                let current = self.tab_order.iter().position(|f| f.is_focused(window));
                let n = self.tab_order.len();
                let next = if mods.shift {
                    current.map(|i| (i + n - 1) % n).unwrap_or(n - 1)
                } else {
                    current.map(|i| (i + 1) % n).unwrap_or(0)
                };
                self.tab_order[next].focus(window);
            }
            return true;
        }
        if matches!(event.keystroke.key.as_str(), "enter" | "space")
            && !mods.platform
            && !mods.control
            && !mods.alt
            && let Some((intent, _)) = self.buttons.iter().find(|(_, f)| f.is_focused(window))
        {
            let intent = intent.clone();
            if !event.is_held {
                self.dispatch(self.token(), intent, cx);
            }
            return true;
        }
        false
    }
    fn button(
        &mut self,
        id: impl Into<ElementId>,
        label: impl Into<String>,
        intent: McpIntent,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let enabled = self.enabled(&intent);
        let token = self.token();
        let p = self.palette;
        let focus = if let Some((_, f)) = self.buttons.iter().find(|(i, _)| i == &intent) {
            f.clone()
        } else {
            let f = cx.focus_handle();
            self.buttons.push((intent.clone(), f.clone()));
            f
        };
        if enabled {
            self.tab_order.push(focus.clone());
        }
        div()
            .id(id)
            .px(px(9.))
            .py(px(5.))
            .rounded(px(6.))
            .border_1()
            .border_color(p.hairline())
            .text_size(px(12.))
            .flex_shrink_0()
            .when(enabled, |b| {
                b.track_focus(&focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .hover(|s| s.bg(p.accent_soft()))
                    .focus(|s| s.border_color(rgb(p.accent)))
            })
            .when(!enabled, |b| b.opacity(0.45))
            .child(label.into())
            .on_click(cx.listener(move |view, _, _, cx| view.dispatch(token, intent.clone(), cx)))
    }
    fn editor(&mut self, editor: Entity<EditorView>, height: f32, cx: &App) -> Div {
        if !self.presentation.busy
            && self.presentation.confirmation.is_none()
            && !self.presentation.close_confirmation
        {
            self.tab_order.push(editor.read(cx).focus_handle(cx));
        }
        div()
            .h(px(height))
            .flex_shrink_0()
            .border_1()
            .border_color(self.palette.hairline())
            .rounded(px(5.))
            .child(editor)
    }
    fn ensure_headers(&mut self, cx: &mut Context<Self>) -> Vec<String> {
        let names = self
            .config
            .as_ref()
            .and_then(|e| {
                let text = e.read(cx).text();
                if text.len() > INPUT_BYTES {
                    return None;
                }
                serde_json::from_str::<serde_json::Value>(text)
                    .ok()?
                    .get("servers")?
                    .as_object()
                    .map(|o| {
                        o.keys()
                            .filter(|s| s.len() <= 128)
                            .take(256)
                            .cloned()
                            .collect::<Vec<_>>()
                    })
            })
            .unwrap_or_default();
        for name in &names {
            if !self.headers.contains_key(name) {
                let input = cx.new(|cx| SecureInput::new(HEADER_BYTES, self.appearance(), cx));
                self.subscriptions
                    .push(cx.subscribe(&input, |_, _, event, cx| {
                        if matches!(
                            event,
                            SecureInputEvent::Changed | SecureInputEvent::Rejected
                        ) {
                            cx.notify();
                        }
                    }));
                self.headers.insert(name.clone(), input);
            }
        }
        if !names.contains(&self.header_server) {
            self.header_server = names.first().cloned().unwrap_or_default();
        }
        self.lock_inputs(cx);
        names
    }
}
impl Render for McpInspectorView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = self.palette;
        self.tab_order.clear();
        let names = self.ensure_headers(cx);
        let mut root = div()
            .size_full()
            .occlude()
            .track_focus(&self.focus)
            .bg(rgb(p.surface))
            .rounded(px(12.))
            .border_1()
            .border_color(p.hairline())
            .p(px(16.))
            .flex()
            .flex_col()
            .gap(px(9.))
            .text_color(rgb(p.ink));
        let close = self.button("mcp-close", "Close", McpIntent::Close, cx);
        root = root.child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(18.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("Project MCP Inspector"),
                )
                .child(close),
        );
        root = root.child(div().text_size(px(11.)).child(format!(
                "Project: {} · {}",
                self.presentation.project_path,
                self.presentation
                    .project_id
                    .as_deref()
                    .unwrap_or("No saved project selected")
            )));
        root=root.child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child(if self.presentation.synthetic{"Fixture-only · memory vault · numeric loopback HTTP · only synthetic-header-fixture-only header values. No real credentials."}else{"Native MCP configuration, credentials and tools are unavailable in this build."}));
        root=root.child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child("Streamable HTTP only. stdio is unsupported. Discovery does not invoke tools; tool annotations are not authorization."));
        let mut left = div().flex_1().min_w(px(0.)).flex().flex_col().gap(px(7.));
        left = left.child(
            div()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .child(if self.dirty(cx) {
                    "Configuration · unsaved draft"
                } else {
                    "Saved configuration"
                }),
        );
        left=left.child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child("JSON: servers → name → transport, url, enabled, allowedTools, timeoutSeconds. Put headers only in the masked field below."));
        if let Some(editor) = self.config.clone() {
            left = left.child(self.editor(editor, 185., cx));
        }
        let save = self.button("mcp-save", "Review and save…", McpIntent::Save, cx);
        let reload = self.button("mcp-reload", "Reload saved…", McpIntent::Reload, cx);
        left = left.child(div().flex().gap(px(6.)).child(save).child(reload));
        left = left.child(
            div()
                .text_size(px(12.))
                .child("Replace headers for one server"),
        );
        let mut header_names = div()
            .id("mcp-header-servers")
            .h(px(42.))
            .overflow_y_scroll()
            .flex()
            .flex_wrap()
            .gap(px(4.));
        for (i, name) in names.iter().enumerate() {
            let label = if name == &self.header_server {
                format!("● {name}")
            } else {
                name.clone()
            };
            header_names = header_names.child(self.button(
                ("mcp-header", i),
                label,
                McpIntent::SelectHeader(name.clone()),
                cx,
            ));
        }
        left = left.child(header_names);
        if let Some(input) = self.headers.get(&self.header_server).cloned() {
            if self.presentation.confirmation.is_none()
                && !self.presentation.close_confirmation
                && !self.presentation.busy
                && self.presentation.ready
                && !self.presentation.blocked
            {
                self.tab_order.push(input.read(cx).focus_handle(cx));
            }
            left = left.child(
                div()
                    .h(px(45.))
                    .border_1()
                    .border_color(p.hairline())
                    .child(input.clone()),
            );
            if let Some(rejection) = input.read(cx).rejection() {
                left = left.child(
                    div()
                        .text_size(px(11.))
                        .text_color(rgb(p.danger))
                        .child(rejection),
                );
            }
        }
        left=left.child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child("Masked JSON object. Blank preserves saved headers at the same endpoint; {} clears them. Changing the URL requires explicit replacement or clearing. Saved values never load here."));
        if !self.presentation.configured_headers.is_empty() {
            left = left.child(div().text_size(px(11.)).child(format!(
                "Saved headers exist for: {}",
                self.presentation.configured_headers.join(", ")
            )));
        }
        let mut right = div().flex_1().min_w(px(0.)).flex().flex_col().gap(px(7.));
        let refresh = self.button("mcp-refresh", "Refresh servers", McpIntent::Refresh, cx);
        let tools = self.button("mcp-list-tools", "List tools", McpIntent::ListTools, cx);
        right = right.child(div().flex().gap(px(6.)).child(refresh).child(tools));
        let mut servers = div()
            .id("mcp-server-list")
            .h(px(40.))
            .overflow_y_scroll()
            .flex()
            .flex_wrap()
            .gap(px(4.));
        for (i, name) in self.presentation.servers.clone().iter().enumerate() {
            let label = if name == &self.server {
                format!("● {name}")
            } else {
                name.clone()
            };
            servers = servers.child(self.button(
                ("mcp-server", i),
                label,
                McpIntent::SelectServer(name.clone()),
                cx,
            ));
        }
        right = right.child(servers);
        let mut tools = div()
            .id("mcp-tool-list")
            .h(px(82.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(3.));
        for (i, (name, description)) in self.presentation.tools.clone().iter().enumerate() {
            let label = format!(
                "{}{}{}",
                if name == &self.tool { "● " } else { "" },
                name,
                if description.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", description.chars().take(80).collect::<String>())
                }
            );
            tools = tools.child(self.button(
                ("mcp-tool", i),
                label,
                McpIntent::SelectTool(name.clone()),
                cx,
            ));
        }
        right = right.child(tools);
        let describe = self.button("mcp-describe", "Describe selected", McpIntent::Describe, cx);
        let invoke = self.button("mcp-invoke", "Invoke once…", McpIntent::Invoke, cx);
        right = right.child(div().flex().gap(px(6.)).child(describe).child(invoke));
        right = right.child(div().text_size(px(11.)).child(format!(
            "{} · {} · arguments: one JSON object",
            self.presentation.chat_label,
            if self.presentation.editing {
                "Editing"
            } else {
                "Read-only"
            }
        )));
        if self.presentation.can_enable_editing {
            right = right.child(self.button(
                "mcp-enable-editing",
                "Enable Editing Tools…",
                McpIntent::EnableEditing,
                cx,
            ));
        }
        if let Some(editor) = self.arguments.clone() {
            right = right.child(self.editor(editor, 65., cx));
        }
        if let Some(editor) = self.reader.clone() {
            right = right.child(self.editor(editor, 140., cx));
        }
        let previous = self.button(
            "mcp-result-previous",
            "Previous",
            McpIntent::PreviousPage,
            cx,
        );
        let next = self.button("mcp-result-next", "Next", McpIntent::NextPage, cx);
        right = right.child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(previous)
                .child(format!(
                    "Result page {} / {}",
                    self.page + 1,
                    self.pages.len()
                ))
                .child(next),
        );
        root = root.child(
            div()
                .id("mcp-body")
                .flex_1()
                .min_h(px(0.))
                .overflow_y_scroll()
                .flex()
                .gap(px(18.))
                .child(left)
                .child(right),
        );
        if self.presentation.unknown_id.is_some() {
            let ack = self.button(
                "mcp-acknowledge",
                "I checked the previous effects…",
                McpIntent::Acknowledge,
                cx,
            );
            root=root.child(div().p(px(8.)).bg(p.accent_soft()).flex().gap(px(8.)).items_center().child(div().flex_1().text_size(px(12.)).child("Previous invocation outcome is unknown for this project. Check external effects before acknowledging. No automatic retry.")).child(ack));
        }
        if self.presentation.busy && self.presentation.cancellable {
            let cancel = self.button(
                "mcp-cancel-operation",
                "Cancel operation",
                McpIntent::CancelOperation,
                cx,
            );
            root = root.child(cancel);
        }
        root = root.child(
            div()
                .text_size(px(12.))
                .text_color(rgb(if self.presentation.blocked {
                    p.danger
                } else {
                    p.secondary
                }))
                .child(if self.presentation.busy && !self.presentation.cancellable && !self.presentation.saving {
                    "Project work is in progress. Wait for it to settle; only operations started by this Inspector can be cancelled here.".into()
                } else { self.presentation.notice.clone() }),
        );
        if let Some((title, detail, label)) = self.presentation.confirmation.clone() {
            let cancel = self.button(
                "mcp-confirm-cancel",
                "Cancel",
                McpIntent::CancelConfirmation,
                cx,
            );
            let confirm = self.button("mcp-confirm", label, McpIntent::Confirm, cx);
            root = root.child(
                div()
                    .p(px(12.))
                    .border_1()
                    .border_color(rgb(p.accent))
                    .rounded(px(8.))
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
                    .child(div().text_size(px(12.)).child(detail))
                    .child(div().flex().gap(px(6.)).child(cancel).child(confirm)),
            );
        }
        if self.presentation.close_confirmation {
            let keep = self.button(
                "mcp-keep-editing",
                "Keep editing",
                McpIntent::CancelConfirmation,
                cx,
            );
            let retain = self.button(
                "mcp-keep-draft-close",
                "Close and keep draft",
                McpIntent::KeepDraftClose,
                cx,
            );
            let discard = self.button(
                "mcp-discard-close",
                "Discard and close",
                McpIntent::DiscardClose,
                cx,
            );
            root=root.child(div().p(px(12.)).border_1().border_color(rgb(p.accent)).rounded(px(8.)).flex().flex_col().gap(px(8.)).child("Unsaved MCP configuration draft").child(div().text_size(px(12.)).child("Keep the draft here for reopening, or explicitly discard it. Closing the workspace requires saving or discarding it.")).child(div().flex().gap(px(6.)).child(keep).child(retain).child(discard)));
        }
        root
    }
}

#[cfg(test)]
#[path = "mcp_inspector_view_tests.rs"]
mod tests;
