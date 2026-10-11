//! The terminal panel under the transcript (Swift 0.1.122
//! Workspaces/TerminalPanel.swift and TerminalPanelView.swift): the project's
//! shells as tabs, New, the shown one's shell title and the project's folder,
//! its state, Rename, Restart, Close and Hide, then the terminal itself. Its
//! height drags on its top edge and is remembered. Shells keep running while
//! the panel is hidden and end with the window.
use crate::terminal_grid::{CellMetrics, GridState, TerminalColors, TerminalGrid};
use crate::theme::Palette;
use bello_agent_core::terminal::{
    keys::{self, KeyModifiers},
    pty::TerminalLaunch,
    session::{Ending, Launcher, TerminalRegistry, TerminalSession},
};
use gpui::{prelude::*, *};
use std::collections::HashMap;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Widest the tab row grows before it scrolls.
pub(crate) const TABS_LIMIT: f32 = 360.;
pub(crate) const MINIMUM_HEIGHT: f32 = 120.;
pub(crate) const MAXIMUM_HEIGHT: f32 = 700.;
pub(crate) const DEFAULT_HEIGHT: f32 = 240.;
/// The panel's resize line and header above the terminal itself.
pub(crate) const CHROME_HEIGHT: f32 = 42.;
/// `PiKit.ResizeHandle.hitThickness`, `gripLength`, `gripThickness`.
const HIT_THICKNESS: f32 = 9.;
const GRIP_LENGTH: f32 = 18.;
const GRIP_THICKNESS: f32 = 2.;
/// The header: `HStack(spacing: 8)` in 12 points either side and 5 above and below.
const PAD_X: f32 = 12.;
const PAD_Y: f32 = 5.;
const SPACING: f32 = 8.;
const BUTTON: f32 = 22.;
const MARK_WIDTH: f32 = 16.;
const MARK_HEIGHT: f32 = 13.;
/// `PiKit.Tabs`: 3 points round the tabs, 2 between, each its title plus 22 wide.
const TABS_INSET: f32 = 3.;
const TABS_SPACING: f32 = 2.;
const TAB_HEIGHT: f32 = 25.;
/// Composer field ceiling while a terminal is open below the chat.
pub(crate) const COMPOSER_BESIDE_TERMINAL: f32 = 88.;

pub(crate) fn clamp_height(value: f32) -> f32 {
    if !value.is_finite() {
        return DEFAULT_HEIGHT;
    }
    value.clamp(MINIMUM_HEIGHT, MAXIMUM_HEIGHT)
}

/// Tests choose the program a terminal runs; the app runs the login shell.
pub(crate) struct TerminalLauncher(pub(crate) Launcher);
impl Global for TerminalLauncher {}

fn default_launcher() -> Launcher {
    if cfg!(test) {
        // Never the user's shell or its startup files in a test.
        Arc::new(|directory: &Path| TerminalLaunch {
            executable: "/bin/sh".into(),
            arguments: vec!["sh".into()],
            environment: vec![
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("TERM".into(), "xterm-256color".into()),
                ("PS1".into(), "$ ".into()),
            ],
            directory: directory.to_owned(),
        })
    } else {
        Arc::new(|directory: &Path| {
            bello_agent_core::terminal::pty::login_shell(
                directory,
                std::env::vars_os(),
                env!("CARGO_PKG_VERSION"),
            )
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TerminalPanelEvent {
    /// The panel's own Hide button.
    Hide,
}

/// A question about one terminal, captured when asked: a click that waited
/// behind a restart never acts on the new shell.
pub(crate) struct Question {
    pub(crate) kind: QuestionKind,
    pub(crate) id: Uuid,
    pub(crate) generation: u64,
    pub(crate) title: String,
    pub(crate) detail: String,
    pub(crate) action: &'static str,
    pub(crate) focus: FocusHandle,
}
pub(crate) enum QuestionKind {
    End(Ending),
    Rename(Entity<bello_workbench_ui::EditorView>),
}

pub(crate) struct TerminalPanel {
    pub(crate) registry: TerminalRegistry,
    grids: HashMap<(Uuid, u64), GridState>,
    pumps: HashMap<(Uuid, u64), Task<()>>,
    /// The project whose terminals it shows: its identity and folder.
    project: String,
    directory: PathBuf,
    pub(crate) focus: FocusHandle,
    pub(crate) palette: Palette,
    width: f32,
    stored_height: f32,
    height_store: Option<Arc<HeightStore>>,
    /// The height being dragged to, until the drag ends.
    dragging: Option<f32>,
    drag_start: Option<(f32, f32)>,
    handle_hovered: bool,
    pub(crate) metrics: Option<CellMetrics>,
    pub(crate) grid_bounds: Option<Bounds<Pixels>>,
    pub(crate) question: Option<Question>,
    /// The key that answered the last question, while it is held.
    pub(crate) answered_key: Option<String>,
    tabs_scroll: ScrollHandle,
    revealed: Option<Uuid>,
    /// The terminal last given the keyboard, by identity and generation.
    focused_key: Option<(Uuid, u64)>,
    focus_due: bool,
    _subscriptions: Vec<Subscription>,
}
impl EventEmitter<TerminalPanelEvent> for TerminalPanel {}

impl TerminalPanel {
    pub(crate) fn new(
        project: &Path,
        height_path: Option<PathBuf>,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let launcher = cx
            .try_global::<TerminalLauncher>()
            .map(|launcher| launcher.0.clone())
            .unwrap_or_else(default_launcher);
        let focus = cx.focus_handle();
        let subscriptions = vec![
            cx.on_focus(&focus, window, |panel, _, cx| panel.focus_changed(true, cx)),
            cx.on_blur(&focus, window, |panel, _, cx| {
                panel.focus_changed(false, cx)
            }),
        ];
        let height_store = height_path.map(|path| Arc::new(HeightStore::new(path)));
        let stored_height = height_store
            .as_ref()
            .map_or(DEFAULT_HEIGHT, |store| store.load());
        Self {
            registry: TerminalRegistry::new(launcher),
            grids: HashMap::new(),
            pumps: HashMap::new(),
            project: project.display().to_string(),
            directory: project.to_owned(),
            focus,
            palette,
            width: 0.,
            stored_height,
            height_store,
            dragging: None,
            drag_start: None,
            handle_hovered: false,
            metrics: None,
            grid_bounds: None,
            question: None,
            answered_key: None,
            tabs_scroll: ScrollHandle::new(),
            revealed: None,
            focused_key: None,
            focus_due: false,
            _subscriptions: subscriptions,
        }
    }

    // MARK: Sessions

    pub(crate) fn sessions(&self) -> &[TerminalSession] {
        self.registry.sessions(&self.project)
    }
    pub(crate) fn selected_session(&self) -> Option<&TerminalSession> {
        self.registry.selected(&self.project)
    }
    fn key(session: &TerminalSession) -> (Uuid, u64) {
        (session.id, session.generation)
    }
    pub(crate) fn grid_state(&self, session: &TerminalSession) -> GridState {
        self.grids
            .get(&Self::key(session))
            .cloned()
            .unwrap_or_default()
    }
    fn grid_mut(&mut self) -> Option<(&mut TerminalSession, &mut GridState)> {
        let session = self.registry.selected_mut(&self.project)?;
        let grid = self.grids.entry(Self::key(session)).or_default();
        Some((session, grid))
    }
    pub(crate) fn colors(&self) -> TerminalColors {
        TerminalColors {
            dark: self.palette.dark,
        }
    }
    /// The panel is shown: a project shown for the first time gets
    /// Terminal 1; one whose terminals were all closed stays empty.
    pub(crate) fn shown(&mut self, cx: &mut Context<Self>) {
        self.registry
            .ensure_initial_session(&self.project, &self.directory);
        self.watch_sessions(cx);
        self.focus_due = true;
    }
    pub(crate) fn create(&mut self, cx: &mut Context<Self>) {
        self.registry.create(&self.project, &self.directory);
        self.watch_sessions(cx);
        cx.notify();
    }
    pub(crate) fn select(&mut self, id: Uuid, cx: &mut Context<Self>) {
        if self.registry.select(id, &self.project) {
            cx.notify();
        }
    }
    /// Each running shell is pumped as its output arrives; a shell that
    /// ended, or went, stops its pump.
    fn watch_sessions(&mut self, cx: &mut Context<Self>) {
        let live: Vec<(Uuid, u64)> = self
            .registry
            .open_projects()
            .iter()
            .flat_map(|project| self.registry.sessions(project).iter().map(Self::key))
            .collect();
        self.pumps.retain(|key, _| live.contains(key));
        self.grids.retain(|key, _| live.contains(key));
        let colors = self.colors();
        for session in self.registry.sessions_mut(&self.project) {
            let key = Self::key(session);
            colors.publish(&mut session.emulator);
            if self.pumps.contains_key(&key) {
                continue;
            }
            let Some(waiter) = session.waiter() else {
                continue;
            };
            let project = self.project.clone();
            let task = cx.spawn(async move |panel, cx| {
                loop {
                    waiter.changed().await;
                    loop {
                        let Ok(state) = panel.update(cx, |panel, cx| panel.pump(&project, key, cx))
                        else {
                            return;
                        };
                        match state {
                            PumpState::Gone => return,
                            PumpState::More => {
                                // Draw this much before taking more.
                                cx.background_executor()
                                    .timer(Duration::from_millis(1))
                                    .await;
                            }
                            PumpState::Idle => break,
                        }
                    }
                }
            });
            self.pumps.insert(key, task);
        }
    }
    fn pump(&mut self, project: &str, key: (Uuid, u64), cx: &mut Context<Self>) -> PumpState {
        let Some(session) = self
            .registry
            .sessions_mut(project)
            .iter_mut()
            .find(|s| Self::key(s) == key)
        else {
            return PumpState::Gone;
        };
        let pumped = session.pump(Instant::now());
        if session.bell_due {
            session.bell_due = false;
            beep();
        }
        let exited = session.exited;
        let grid = self.grids.entry(key).or_default();
        grid.output_arrived(&session.emulator);
        if pumped.changed {
            cx.notify();
        }
        if pumped.more {
            PumpState::More
        } else if exited {
            PumpState::Gone
        } else {
            PumpState::Idle
        }
    }

    /// Input from the keyboard: the shown terminal goes back to its newest
    /// output first.
    pub(crate) fn send(&mut self, data: &[u8], cx: &mut Context<Self>) {
        if data.is_empty() {
            return;
        }
        let Some((session, grid)) = self.grid_mut() else {
            return;
        };
        if grid.scroll_offset != 0 {
            grid.scroll_offset = 0;
            cx.notify();
        }
        session.write(data);
    }
    fn focus_changed(&mut self, focused: bool, cx: &mut Context<Self>) {
        let key = self.selected_session().map(Self::key);
        self.report_focus(key, focused);
        cx.notify();
    }
    /// Focus in or out (`ESC[I`, `ESC[O`) to a terminal that asked for them.
    fn report_focus(&mut self, key: Option<(Uuid, u64)>, focused: bool) {
        let Some(key) = key else {
            return;
        };
        if let Some(session) = self
            .registry
            .sessions_mut(&self.project)
            .iter_mut()
            .find(|s| Self::key(s) == key)
            && session.emulator.focus_reporting()
        {
            session.write(if focused { b"\x1b[I" } else { b"\x1b[O" });
        }
    }
    /// The grid's bounds and cell size this frame: the emulator and the
    /// program follow the view's size.
    pub(crate) fn grid_laid_out(&mut self, bounds: Bounds<Pixels>, metrics: CellMetrics) {
        self.metrics = Some(metrics);
        self.grid_bounds = Some(bounds);
        let Some((columns, rows)) =
            metrics.grid(f32::from(bounds.size.width), f32::from(bounds.size.height))
        else {
            return;
        };
        let colors = self.colors();
        if let Some(session) = self.registry.selected_mut(&self.project) {
            session.emulator.cell_pixel_size =
                (f64::from(metrics.width), f64::from(metrics.height));
            colors.publish(&mut session.emulator);
            session.resize(columns, rows);
        }
    }
    pub(crate) fn set_width(&mut self, width: f32) {
        self.width = width;
    }
    pub(crate) fn set_palette(&mut self, palette: Palette, cx: &mut Context<Self>) {
        if self.palette != palette {
            self.palette = palette;
            let colors = self.colors();
            for session in self.registry.sessions_mut(&self.project) {
                colors.publish(&mut session.emulator);
            }
            cx.notify();
        }
    }

    // MARK: Height

    /// The terminal's own height: as dragged, else as remembered.
    pub(crate) fn terminal_height(&self) -> f32 {
        clamp_height(self.dragging.unwrap_or(self.stored_height))
    }
    pub(crate) fn header_height(&self) -> f32 {
        let tabs = if self.sessions().is_empty() {
            0.
        } else {
            TAB_HEIGHT + TABS_INSET * 2.
        };
        BUTTON.max(tabs).max(MARK_HEIGHT) + PAD_Y * 2.
    }
    pub(crate) fn chrome_height(&self) -> f32 {
        1. + self.header_height()
    }
    /// Its height when it has the room: the chrome and the terminal as dragged.
    pub(crate) fn ideal_height(&self) -> f32 {
        self.chrome_height() + self.terminal_height()
    }
    /// The least it takes: the terminal gives way down to its minimum.
    pub(crate) fn minimum_height(&self) -> f32 {
        self.chrome_height() + self.terminal_height().min(MINIMUM_HEIGHT)
    }
    fn drag_moved(&mut self, y: f32, cx: &mut Context<Self>) {
        let Some((start_y, start_height)) = self.drag_start else {
            return;
        };
        self.dragging = Some(clamp_height(start_height - (y - start_y)));
        cx.notify();
    }
    fn drag_ended(&mut self, y: f32, cx: &mut Context<Self>) {
        let Some((start_y, start_height)) = self.drag_start.take() else {
            return;
        };
        self.dragging = None;
        self.stored_height = clamp_height(start_height - (y - start_y));
        if let Some(store) = self.height_store.clone() {
            let height = self.stored_height;
            let revision = store.reserve();
            cx.background_executor()
                .spawn(async move {
                    let _ = store.save(revision, height);
                })
                .detach();
        }
        cx.notify();
    }

    // MARK: Questions

    /// Asks before restarting or closing a live shell (Cancel the default);
    /// one that has exited goes at once.
    pub(crate) fn request_ending(
        &mut self,
        ending: Ending,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.question.is_some() {
            return;
        }
        let Some(session) = self.selected_session() else {
            return;
        };
        let (id, generation) = Self::key(session);
        if !session.running() {
            self.end(ending, id, generation, cx);
            return;
        }
        let project = Path::new(&self.project)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.project.clone());
        let (title, detail, action) = bello_agent_core::terminal::session::ending_question(
            ending,
            &session.display_name(),
            &project,
            &self.directory.display().to_string(),
        );
        let focus = cx.focus_handle();
        focus.focus(window);
        self.question = Some(Question {
            kind: QuestionKind::End(ending),
            id,
            generation,
            title,
            detail,
            action,
            focus,
        });
        cx.notify();
    }
    pub(crate) fn request_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.question.is_some() {
            return;
        }
        let Some(session) = self.selected_session() else {
            return;
        };
        let (id, generation) = Self::key(session);
        let title = format!("Rename “{}”", session.display_name());
        let detail = format!(
            "Up to {} characters. Leave it empty for “Terminal {}”.",
            bello_agent_core::terminal::session::NAME_LIMIT,
            session.number
        );
        let value = session.custom_name().unwrap_or_default().to_owned();
        let palette = self.palette;
        let editor = cx.new(|cx| {
            let mut editor = bello_workbench_ui::EditorView::new(value, window, cx);
            let mut style = crate::AgentView::composer_style(palette);
            style.font_size = 13.;
            style.line_height = 19.;
            style.padding_x = 8.;
            style.padding_y = 4.;
            editor.set_appearance(style, cx);
            editor
        });
        editor.update(cx, |editor, cx| {
            let _ = editor.select_all(cx);
        });
        editor.read(cx).focus(window);
        self.question = Some(Question {
            kind: QuestionKind::Rename(editor),
            id,
            generation,
            title,
            detail,
            action: "Rename",
            focus: cx.focus_handle(),
        });
        cx.notify();
    }
    /// The answer: `true` goes ahead. Nothing happens if that terminal was
    /// closed or restarted meanwhile.
    pub(crate) fn answer(&mut self, go: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(question) = self.question.take() else {
            return;
        };
        if go {
            let current = self
                .registry
                .find(question.id, &self.project)
                .map(|s| s.generation);
            if current == Some(question.generation) {
                match &question.kind {
                    QuestionKind::End(ending) => {
                        self.end(*ending, question.id, question.generation, cx)
                    }
                    QuestionKind::Rename(editor) => {
                        let name = editor.read(cx).text().to_owned();
                        self.registry.rename(question.id, &self.project, &name);
                    }
                }
            }
        }
        self.focus.focus(window);
        cx.notify();
    }
    fn end(&mut self, ending: Ending, id: Uuid, generation: u64, cx: &mut Context<Self>) {
        match ending {
            Ending::Restart => {
                self.registry.restart(id, &self.project, generation);
            }
            Ending::Close => self.registry.close(id, &self.project, generation),
        }
        self.watch_sessions(cx);
        self.focus_due = true;
        cx.notify();
    }
    pub(crate) fn asking(&self) -> bool {
        self.question.is_some()
    }

    // MARK: Keyboard and clipboard

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let k = &event.keystroke;
        let m = k.modifiers;
        // A key held to answer a question stays the question's.
        if let Some(held) = self.answered_key.take()
            && event.is_held
            && held == k.key
        {
            self.answered_key = Some(held);
            cx.stop_propagation();
            return;
        }
        // Composition owns every key until the input method commits it.
        if self
            .selected_session()
            .is_some_and(|session| !self.grid_state(session).marked_text.is_empty())
        {
            return;
        }
        // ⌘C, ⌘V and ⌘A (⇧⌃ on Linux, where ⌃ belongs to the shell).
        let clipboard = if cfg!(target_os = "macos") {
            m.platform && !m.control && !m.alt
        } else {
            m.control && m.shift && !m.alt
        };
        if clipboard {
            match k.key.as_str() {
                "c" => {
                    if let Some(text) = self.selected_text() {
                        cx.write_to_clipboard(ClipboardItem::new_string(text));
                    }
                    cx.stop_propagation();
                }
                "v" => {
                    if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                        self.paste(&text, cx);
                    }
                    cx.stop_propagation();
                }
                "a" => {
                    if let Some((session, grid)) = self.grid_mut() {
                        grid.select_all(&session.emulator);
                    }
                    cx.notify();
                    cx.stop_propagation();
                }
                _ => {}
            }
            return;
        }
        if m.platform {
            return;
        }
        let modifiers = KeyModifiers {
            shift: m.shift,
            control: m.control,
            option: m.alt,
        };
        let application = self
            .selected_session()
            .is_some_and(|session| session.emulator.application_cursor_keys());
        if let Some(key) = keys::key_for_name(&k.key, m.shift) {
            self.send(&keys::encode(key, application, modifiers), cx);
            cx.stop_propagation();
            return;
        }
        let bare = k.key.chars().next().filter(|_| k.key.chars().count() == 1);
        if m.control
            && let Some(character) = bare.or(if k.key == "space" { Some(' ') } else { None })
        {
            let character = if m.shift {
                character.to_ascii_uppercase()
            } else {
                character
            };
            if let Some(bytes) = keys::control_bytes(character, m.alt) {
                self.send(&bytes, cx);
                cx.stop_propagation();
                return;
            }
        }
        // Option sends ESC before the character, the way most shells expect Meta.
        if m.alt
            && !m.control
            && let Some(character) = bare.or(if k.key == "space" { Some(' ') } else { None })
            && character.is_ascii()
        {
            let character = if m.shift {
                k.key_char
                    .as_deref()
                    .and_then(|c| c.chars().next())
                    .filter(char::is_ascii)
                    .unwrap_or(character)
            } else {
                character
            };
            let mut bytes = vec![0x1b];
            bytes.extend(character.to_string().as_bytes());
            self.send(&bytes, cx);
            cx.stop_propagation();
            return;
        }
        let _ = window;
    }
    fn selected_text(&self) -> Option<String> {
        let session = self.selected_session()?;
        self.grid_state(session)
            .selected_text(&session.emulator)
            .filter(|text| !text.is_empty())
    }
    /// Pasted text as one paste, bracketed when the program asked for that.
    pub(crate) fn paste(&mut self, text: &str, cx: &mut Context<Self>) {
        let bracketed = self
            .selected_session()
            .is_some_and(|session| session.emulator.bracketed_paste());
        self.send(&keys::paste_bytes(text, bracketed), cx);
    }

    // MARK: Mouse

    pub(crate) fn mouse_down(
        &mut self,
        point: Point<Pixels>,
        clicks: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focus.focus(window);
        let (Some(metrics), Some(bounds)) = (self.metrics, self.grid_bounds) else {
            return;
        };
        let local = point - bounds.origin;
        let Some((session, grid)) = self.grid_mut() else {
            return;
        };
        let at = grid.position(
            &session.emulator,
            metrics,
            f32::from(local.x),
            f32::from(local.y),
        );
        match clicks {
            2 => grid.select_word(&session.emulator, at),
            3 => grid.select_line(&session.emulator, at),
            _ => {
                grid.anchor = Some(at);
                grid.selection = None;
            }
        }
        cx.notify();
    }
    pub(crate) fn mouse_dragged(&mut self, point: Point<Pixels>, cx: &mut Context<Self>) {
        let (Some(metrics), Some(bounds)) = (self.metrics, self.grid_bounds) else {
            return;
        };
        let local = point - bounds.origin;
        let Some((session, grid)) = self.grid_mut() else {
            return;
        };
        if grid.anchor.is_none() {
            return;
        }
        let at = grid.position(
            &session.emulator,
            metrics,
            f32::from(local.x),
            f32::from(local.y),
        );
        grid.drag_to(at);
        cx.notify();
    }
    pub(crate) fn mouse_up(&mut self, cx: &mut Context<Self>) {
        if let Some((_, grid)) = self.grid_mut()
            && grid.anchor.is_some()
        {
            grid.mouse_up();
            cx.notify();
        }
    }
    /// The wheel moves through the scrollback; in a full-screen program,
    /// which has none, it moves the program's cursor instead.
    pub(crate) fn scrolled(&mut self, delta: ScrollDelta, cx: &mut Context<Self>) {
        let height = self.metrics.map_or(17., |m| m.height);
        let Some((session, grid)) = self.grid_mut() else {
            return;
        };
        let lines = match delta {
            ScrollDelta::Pixels(pixels) => {
                grid.scroll_accumulator += f32::from(pixels.y);
                let lines = (grid.scroll_accumulator / height) as i64;
                grid.scroll_accumulator -= lines as f32 * height;
                lines
            }
            ScrollDelta::Lines(lines) => lines.y.trunc() as i64 * 3,
        };
        if lines == 0 {
            return;
        }
        if session.emulator.alternate_screen() {
            let key = if lines > 0 {
                keys::TerminalKey::Up
            } else {
                keys::TerminalKey::Down
            };
            let bytes = keys::encode(
                key,
                session.emulator.application_cursor_keys(),
                KeyModifiers::default(),
            );
            for _ in 0..lines.unsigned_abs().min(20) {
                session.write(&bytes);
            }
            return;
        }
        let next = (grid.scroll_offset as i64 + lines)
            .clamp(0, session.emulator.scrollback_len() as i64) as usize;
        if next != grid.scroll_offset {
            grid.scroll_offset = next;
            cx.notify();
        }
    }
    /// Lines the reader has scrolled back from the newest output.
    #[cfg(test)]
    pub(crate) fn scrolled_back(&self) -> usize {
        self.selected_session()
            .map_or(0, |session| self.grid_state(session).scroll_offset)
    }

    // MARK: Rendering

    fn hairline_strong(&self) -> Hsla {
        rgba(if self.palette.dark {
            0xffffff29
        } else {
            0x0000001f
        })
        .into()
    }
    fn fill_strong(&self) -> Hsla {
        rgba(if self.palette.dark {
            0xffffff17
        } else {
            0x00000013
        })
        .into()
    }
    fn text_width(window: &mut Window, text: &str, size: f32, weight: FontWeight) -> f32 {
        if text.is_empty() {
            return 0.;
        }
        let font = Font {
            family: if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            }
            .into(),
            features: FontFeatures::default(),
            fallbacks: None,
            weight,
            style: FontStyle::Normal,
        };
        let run = TextRun {
            len: text.len(),
            font,
            color: black(),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        f32::from(
            window
                .text_system()
                .shape_line(SharedString::from(text.to_owned()), px(size), &[run], None)
                .width,
        )
        .ceil()
    }
    fn icon(&self, name: &'static str, size: f32, color: u32) -> Svg {
        svg().path(name).size(px(size)).text_color(rgb(color))
    }
    fn icon_button(
        &self,
        id: &'static str,
        icon: &'static str,
        tip: &'static str,
        cx: &mut Context<Self>,
        action: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> Stateful<Div> {
        let fill = self.fill_strong();
        let palette = self.palette;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .flex_none()
            .size(px(BUTTON))
            .rounded_full()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .hover(move |d| d.bg(fill))
            .child(self.icon(icon, BUTTON * 0.46, self.palette.secondary))
            .tooltip(move |_, cx| {
                cx.new(|_| crate::composer_attachments::TextHint {
                    text: tip.into(),
                    palette,
                })
                .into()
            })
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(cx.listener(move |panel, _, window, cx| action(panel, window, cx)))
    }

    fn header(&self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let sessions = self.sessions();
        let selected = self.selected_session();
        let project_name = Path::new(&self.project)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let inner = (self.width - PAD_X * 2.).max(0.);
        // The trailing controls, as one fixed group.
        let badge = selected.and_then(|session| {
            if session.failure.is_some() {
                Some(("Terminal error", p.danger))
            } else if session.exited {
                Some(("Shell exited", if p.dark { 0xe3b15c } else { 0xa8781c }))
            } else {
                None
            }
        });
        let badge_width = badge.map_or(0., |(text, _)| {
            Self::text_width(window, text, 10.5, FontWeight::MEDIUM) + 16.
        });
        let controls = usize::from(badge.is_some()) + if selected.is_some() { 4 } else { 1 };
        let controls_width = badge_width
            + (if selected.is_some() { 4. } else { 1. }) * BUTTON
            + SPACING * (controls as f32 - 1.).max(0.);
        // The tab row: its tabs, never more than leaves room for the rest.
        let titles: Vec<(Uuid, String, f32)> = sessions
            .iter()
            .map(|s| {
                let name = s.display_name();
                let width = Self::text_width(window, &name, 12., FontWeight::MEDIUM) + 22.;
                (s.id, name, width)
            })
            .collect();
        let natural = titles.iter().map(|t| t.2).sum::<f32>()
            + TABS_SPACING * (titles.len() as f32 - 1.).max(0.)
            + TABS_INSET * 2.;
        let room =
            (inner - (controls_width + MARK_WIDTH + BUTTON + SPACING * 5.)).clamp(72., TABS_LIMIT);
        let tabs_width = natural.max(1.).min(room);
        let overflows = natural > tabs_width;
        let mut x = MARK_WIDTH + SPACING;
        if !titles.is_empty() {
            x += tabs_width + SPACING;
        }
        x += BUTTON + SPACING;
        // What is left between: the title and the folder when both fit (the
        // folder down to forty points), the title alone, or neither.
        let space = (inner - controls_width - SPACING - x).max(0.);
        let title = selected.map(|s| s.shell_title.clone()).unwrap_or_default();
        let title_width = Self::text_width(window, &title, 11.5, FontWeight::NORMAL);
        let project_width = Self::text_width(window, &project_name, 10.5, FontWeight::MEDIUM);
        let with_title = if title.is_empty() {
            0.
        } else {
            title_width + SPACING
        };
        let (show_title, folder) = if space >= with_title + 40. {
            let share = ((space - with_title) / 2.).clamp(40., 320.);
            (!title.is_empty(), Some(project_width.min(share).max(40.)))
        } else if !title.is_empty() && space >= title_width {
            (true, None)
        } else {
            (false, None)
        };

        let mut row = div()
            .debug_selector(|| "terminal-header".into())
            .flex_none()
            .h(px(self.header_height()))
            .px(px(PAD_X))
            .flex()
            .items_center()
            .gap(px(SPACING))
            .bg(rgb(p.window))
            .child(
                div()
                    .flex_none()
                    .w(px(MARK_WIDTH))
                    .h(px(MARK_HEIGHT))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(self.icon("terminal", 11., p.secondary)),
            );
        if !titles.is_empty() {
            let selected_id = selected.map(|s| s.id);
            let surface = rgb(p.surface);
            let shadow: Hsla = rgba(if p.dark { 0x00000057 } else { 0x2a241817 }).into();
            // The tabs are the scroll row's own children, so the chosen one
            // can be brought into view by its index.
            let mut well = div()
                .id("terminal-tabs-row")
                .size_full()
                .flex()
                .gap(px(TABS_SPACING))
                .p(px(TABS_INSET))
                .overflow_x_scroll()
                .track_scroll(&self.tabs_scroll);
            for (id, name, width) in titles {
                let chosen = Some(id) == selected_id;
                let selector = format!("terminal-tab-{name}");
                well = well.child(
                    div()
                        .id(SharedString::from(format!("terminal-tab-{id}")))
                        .debug_selector(move || selector.clone())
                        .flex_none()
                        .w(px(width))
                        .h(px(TAB_HEIGHT))
                        .rounded_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(rgb(if chosen { p.ink } else { p.secondary }))
                        .when(chosen, |tab| {
                            tab.bg(surface).shadow(vec![BoxShadow {
                                color: shadow,
                                offset: point(px(0.), px(1.)),
                                blur_radius: px(3.),
                                spread_radius: px(0.),
                            }])
                        })
                        .cursor_pointer()
                        .child(name.clone())
                        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .on_click(cx.listener(move |panel, _, _, cx| panel.select(id, cx))),
                );
            }
            let mut tabs = div()
                .id("terminal-tabs")
                .debug_selector(|| "terminal-tabs".into())
                .relative()
                .flex_none()
                .w(px(tabs_width))
                .h(px(TAB_HEIGHT + TABS_INSET * 2.))
                .rounded_full()
                .overflow_hidden()
                .bg(self.fill_strong())
                .child(well);
            if overflows {
                // A row that scrolls fades at its end, so it reads as more.
                let window_colour: Hsla = rgb(p.window).into();
                let mut clear = window_colour;
                clear.a = 0.;
                tabs = tabs.child(div().absolute().top_0().right_0().w(px(24.)).h_full().bg(
                    linear_gradient(
                        90.,
                        linear_color_stop(clear, 0.),
                        linear_color_stop(window_colour, 1.),
                    ),
                ));
            }
            row = row.child(tabs);
        }
        row = row.child(self.icon_button(
            "terminal-new",
            "plus",
            "Open another terminal in this project",
            cx,
            |panel, _, cx| panel.create(cx),
        ));
        if show_title {
            row = row.child(
                div()
                    .debug_selector(|| "terminal-shell-title".into())
                    .flex_none()
                    .w(px(title_width))
                    .truncate()
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .child(title),
            );
        }
        if let Some(width) = folder {
            row = row.child(
                div()
                    .debug_selector(|| "terminal-project".into())
                    .flex_none()
                    .w(px(width))
                    .truncate()
                    .text_size(px(10.5))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgb(p.tertiary))
                    .child(project_name),
            );
        }
        row = row.child(div().flex_1());
        if let Some((text, tone)) = badge {
            let mut wash: Hsla = rgb(tone).into();
            wash.a = 0.13;
            let help = selected.and_then(|s| s.failure.clone());
            let palette = p;
            row = row.child(
                div()
                    .id("terminal-badge")
                    .debug_selector(|| "terminal-badge".into())
                    .flex_none()
                    .px(px(8.))
                    .h(px(19.))
                    .flex()
                    .items_center()
                    .rounded_full()
                    .bg(wash)
                    .text_size(px(10.5))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgb(tone))
                    .child(text)
                    .when_some(help, |badge, help| {
                        badge.tooltip(move |_, cx| {
                            cx.new(|_| crate::composer_attachments::TextHint {
                                text: help.clone(),
                                palette,
                            })
                            .into()
                        })
                    }),
            );
        }
        if selected.is_some() {
            row = row
                .child(self.icon_button(
                    "terminal-rename",
                    "pencil",
                    "Give this terminal a name of your own",
                    cx,
                    |panel, window, cx| panel.request_rename(window, cx),
                ))
                .child(self.icon_button(
                    "terminal-restart",
                    "arrow.clockwise",
                    "Starts a new shell in this terminal. Its scrollback is removed. Asks first while the shell is running.",
                    cx,
                    |panel, window, cx| panel.request_ending(Ending::Restart, window, cx),
                ))
                .child(self.icon_button(
                    "terminal-close",
                    "trash",
                    "Ends this terminal's shell and removes its output. Asks first while the shell is running.",
                    cx,
                    |panel, window, cx| panel.request_ending(Ending::Close, window, cx),
                ));
        }
        row.child(self.icon_button(
            "terminal-hide",
            "close",
            "Hide the terminals; they keep running",
            cx,
            |_, _, cx| cx.emit(TerminalPanelEvent::Hide),
        ))
    }

    fn body(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = self.palette;
        let surface = self.colors().background();
        if self.selected_session().is_none() {
            return div()
                .debug_selector(|| "terminal-empty".into())
                .flex_1()
                .min_h_0()
                .bg(rgb(surface))
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .child(
                    div()
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .child("No terminals in this project"),
                )
                .child(
                    div()
                        .id("terminal-empty-new")
                        .debug_selector(|| "terminal-empty-new".into())
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .px(px(10.))
                        .py(px(5.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(p.hairline())
                        .bg(rgb(p.surface))
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .cursor_pointer()
                        .child(self.icon("plus", 12., p.secondary))
                        .child("New Terminal")
                        .on_click(cx.listener(|panel, _, _, cx| panel.create(cx))),
                )
                .into_any_element();
        }
        div()
            .id("terminal-grid")
            .debug_selector(|| "terminal-grid".into())
            .flex_1()
            .min_h_0()
            .w_full()
            .track_focus(&self.focus)
            .key_context("BelloEditor")
            .cursor(CursorStyle::IBeam)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|panel, event: &MouseDownEvent, window, cx| {
                    panel.mouse_down(event.position, event.click_count, window, cx);
                    cx.stop_propagation();
                }),
            )
            .on_scroll_wheel(cx.listener(|panel, event: &ScrollWheelEvent, _, cx| {
                panel.scrolled(event.delta, cx);
                cx.stop_propagation();
            }))
            .child(TerminalGrid {
                panel: cx.entity(),
                focus: self.focus.clone(),
            })
            .into_any_element()
    }
}

enum PumpState {
    Idle,
    More,
    Gone,
}

impl Render for TerminalPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // The keyboard follows the shown terminal and its restarts.
        let key = self.selected_session().map(Self::key);
        if key != self.focused_key || self.focus_due {
            if key != self.focused_key && self.focus.is_focused(window) {
                // The keyboard stays on the panel, so its focus callbacks do
                // not run: the terminal left and the one shown are told.
                self.report_focus(self.focused_key, false);
                self.report_focus(key, true);
            }
            if key.is_some() && self.question.is_none() {
                self.focus.focus(window);
            }
            self.focused_key = key;
            self.focus_due = false;
        }
        // The chosen tab in view.
        let selected = key.map(|k| k.0);
        if selected != self.revealed {
            self.revealed = selected;
            if let Some(index) = self.sessions().iter().position(|s| Some(s.id) == selected) {
                self.tabs_scroll.scroll_to_item(index);
            }
        }
        let p = self.palette;
        let dragging = self.drag_start.is_some();
        let line = if dragging {
            self.hairline_strong()
        } else {
            p.hairline()
        };
        let grip_opacity = if dragging || self.handle_hovered {
            1.
        } else {
            0.35
        };
        let header = self.header(window, cx);
        let body = self.body(cx);
        let entity = cx.entity();
        div()
            .debug_selector(|| "terminal-panel".into())
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .child(div().flex_none().h(px(1.)).w_full().bg(line))
            .child(header)
            .child(body)
            // The handle's hairline is the panel's first point; the strip it
            // can be grabbed by reaches four points either side of it.
            .child(
                div()
                    .id("terminal-resize")
                    .debug_selector(|| "terminal-resize".into())
                    .absolute()
                    .left_0()
                    .w_full()
                    .top(px(0.5 - HIT_THICKNESS / 2.))
                    .h(px(HIT_THICKNESS))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor(CursorStyle::ResizeUpDown)
                    .on_hover(cx.listener(|panel, hovered: &bool, _, cx| {
                        panel.handle_hovered = *hovered;
                        cx.notify();
                    }))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|panel, event: &MouseDownEvent, _, cx| {
                            panel.drag_start =
                                Some((f32::from(event.position.y), panel.terminal_height()));
                            cx.stop_propagation();
                            cx.notify();
                        }),
                    )
                    .child(
                        div()
                            .w(px(GRIP_LENGTH))
                            .h(px(GRIP_THICKNESS))
                            .rounded(px(GRIP_THICKNESS / 2.))
                            .bg(self.hairline_strong())
                            .opacity(grip_opacity),
                    ),
            )
            // Drags and the grid's selection follow the pointer anywhere in the window.
            .child(
                canvas(
                    |_, _, _| (),
                    move |_, _, window, _| {
                        let panel = entity.clone();
                        window.on_mouse_event(move |event: &MouseMoveEvent, phase, _, cx| {
                            if phase != DispatchPhase::Bubble {
                                return;
                            }
                            panel.update(cx, |panel, cx| {
                                if panel.drag_start.is_some() {
                                    if event.pressed_button == Some(MouseButton::Left) {
                                        panel.drag_moved(f32::from(event.position.y), cx);
                                    }
                                } else if event.pressed_button == Some(MouseButton::Left) {
                                    panel.mouse_dragged(event.position, cx);
                                }
                            });
                        });
                        let panel = entity.clone();
                        window.on_mouse_event(move |event: &MouseUpEvent, phase, _, cx| {
                            if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
                                return;
                            }
                            panel.update(cx, |panel, cx| {
                                if panel.drag_start.is_some() {
                                    panel.drag_ended(f32::from(event.position.y), cx);
                                } else {
                                    panel.mouse_up(cx);
                                }
                            });
                        });
                    },
                )
                .absolute()
                .size_0(),
            )
            .children(crate::terminal_question::element(self, window, cx))
    }
}

impl EntityInputHandler for TerminalPanel {
    fn text_for_range(
        &mut self,
        _: Range<usize>,
        _: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        None
    }
    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: 0..0,
            reversed: false,
        })
    }
    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        let session = self.selected_session()?;
        let marked = self.grid_state(session).marked_text;
        (!marked.is_empty()).then(|| 0..marked.encode_utf16().count())
    }
    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if let Some((_, grid)) = self.grid_mut() {
            grid.marked_text.clear();
        }
        cx.notify();
    }
    fn replace_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some((_, grid)) = self.grid_mut() {
            grid.marked_text.clear();
        }
        self.send(text.as_bytes(), cx);
        cx.notify();
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some((_, grid)) = self.grid_mut() {
            grid.marked_text = text.to_owned();
        }
        cx.notify();
    }
    fn bounds_for_range(
        &mut self,
        _: Range<usize>,
        element: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let metrics = self.metrics?;
        let session = self.selected_session()?;
        let grid = self.grid_state(session);
        let cursor = session.emulator.cursor();
        let row = (session.emulator.scrollback_len() + cursor.y)
            .saturating_sub(grid.first_visible(&session.emulator));
        Some(Bounds::new(
            point(
                element.origin.x
                    + px(crate::terminal_grid::INSET + cursor.x as f32 * metrics.width),
                element.origin.y + px(crate::terminal_grid::INSET + row as f32 * metrics.height),
            ),
            size(px(metrics.width), px(metrics.height)),
        ))
    }
    fn character_index_for_point(
        &mut self,
        _: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        Some(0)
    }
}

/// The remembered height (Swift's `terminalHeight` default): saves land in
/// order, the newest wins, and each replaces the file whole.
pub(crate) struct HeightStore {
    path: PathBuf,
    latest: std::sync::atomic::AtomicU64,
    write: std::sync::Mutex<()>,
}
impl HeightStore {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            latest: std::sync::atomic::AtomicU64::new(0),
            write: std::sync::Mutex::new(()),
        }
    }
    pub(crate) fn load(&self) -> f32 {
        std::fs::read(&self.path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .and_then(|value| value["terminalHeight"].as_f64())
            .map_or(DEFAULT_HEIGHT, |value| clamp_height(value as f32))
    }
    pub(crate) fn reserve(&self) -> u64 {
        self.latest
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel)
            + 1
    }
    /// Writes `height` unless a newer save was reserved meanwhile.
    pub(crate) fn save(&self, revision: u64, height: f32) -> std::io::Result<bool> {
        let _guard = self
            .write
            .lock()
            .map_err(|_| std::io::Error::other("Terminal height storage lock failed"))?;
        if self.latest.load(std::sync::atomic::Ordering::Acquire) != revision {
            return Ok(false);
        }
        let parent = self
            .path
            .parent()
            .ok_or_else(|| std::io::Error::other("Terminal height storage has no parent"))?;
        std::fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".terminal-{}.tmp", Uuid::new_v4()));
        let result = (|| {
            std::fs::write(
                &temporary,
                serde_json::json!({ "terminalHeight": height }).to_string(),
            )?;
            std::fs::rename(&temporary, &self.path)?;
            Ok(true)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
}

/// The bell, coalesced by the session.
fn beep() {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        #[link(name = "AppKit", kind = "framework")]
        unsafe extern "C" {
            fn NSBeep();
        }
        unsafe { NSBeep() };
    }
}

/// The window's terminal: the panel and whether it is shown.
pub(crate) struct TerminalHost {
    pub(crate) panel: Entity<TerminalPanel>,
    pub(crate) visible: bool,
    _events: Subscription,
}

impl TerminalHost {
    pub(crate) fn new(
        project: &Path,
        height_path: Option<PathBuf>,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<crate::AgentView>,
    ) -> Self {
        let panel = cx.new(|cx| TerminalPanel::new(project, height_path, palette, window, cx));
        let events = cx.subscribe_in(
            &panel,
            window,
            |view: &mut crate::AgentView, _, event, window, cx| match event {
                TerminalPanelEvent::Hide => view.toggle_terminal(window, cx),
            },
        );
        Self {
            panel,
            visible: false,
            _events: events,
        }
    }
}

impl crate::AgentView {
    /// Shows or hides the integrated terminal under the chat (⌃`). Hidden,
    /// its shells keep running; the composer takes the keyboard back.
    pub(crate) fn toggle_terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.terminal.visible = !self.terminal.visible;
        if self.terminal.visible {
            self.terminal.panel.update(cx, |panel, cx| panel.shown(cx));
        } else {
            self.focus_visible_composer(window, cx);
        }
        cx.notify();
    }
    /// The window's keys for the terminal, after every modal has had its
    /// own: Show/Hide Terminal (⌃`, before any field takes it), and on
    /// Linux, where the app's commands are on Control, a focused shell keeps
    /// its Control keys. True when the key was taken.
    pub(crate) fn terminal_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let m = event.keystroke.modifiers;
        if event.keystroke.key == "`"
            && m.control
            && !m.platform
            && !m.alt
            && !m.shift
            && !m.function
            && self.records.iter().any(|r| r.id == self.record.id)
        {
            self.toggle_terminal(window, cx);
            cx.stop_propagation();
            return true;
        }
        // Not stopped: the key goes on to the terminal's own handler.
        cfg!(not(target_os = "macos"))
            && self.terminal.visible
            && m.control
            && !m.platform
            && self.terminal.panel.read(cx).focus.is_focused(window)
    }
    pub(crate) fn terminal_asking(&self, cx: &App) -> bool {
        self.terminal.panel.read(cx).asking()
    }
    /// The composer's field ceiling: lower while a terminal is open below.
    pub(crate) fn composer_ceiling(&self) -> f32 {
        if self.terminal.visible {
            COMPOSER_BESIDE_TERMINAL
        } else {
            240.
        }
    }
    /// The panel between the queue and the composer. The transcript and the
    /// terminal share what the pane leaves as a stack shares it between two
    /// flexible views: the terminal is offered half and takes it within its
    /// own minimum and ideal heights; the transcript takes the rest.
    pub(crate) fn terminal_slot(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.terminal.visible {
            return None;
        }
        let palette = self.palette;
        let width = self.pane_width;
        let (least, most) = self.terminal.panel.update(cx, |panel, cx| {
            panel.set_width(width);
            panel.set_palette(palette, cx);
            (
                panel.minimum_height(),
                panel.ideal_height().max(panel.minimum_height()),
            )
        });
        Some(
            div()
                .debug_selector(|| "terminal-slot".into())
                .flex_1()
                .w_full()
                .min_h(px(least))
                .max_h(px(most))
                .child(self.terminal.panel.clone())
                .into_any_element(),
        )
    }
}

#[cfg(test)]
#[path = "terminal_panel_tests.rs"]
mod tests;
