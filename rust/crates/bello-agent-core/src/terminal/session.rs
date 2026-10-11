//! A project's shells and the bookkeeping around them, as Swift 0.1.122
//! Workspaces/TerminalPanel.swift keeps them (TerminalSession and
//! TerminalRegistry): an ordered list per project, which one is shown, the
//! next number to give, names, restarts and closes. Drawing is the app's.
use super::emulator::{TerminalEmulator, TerminalEvent};
use super::pty::{PseudoTerminal, TerminalLaunch, TerminalWaiter};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// Longest name a terminal can be given, in characters.
pub const NAME_LIMIT: usize = 64;
/// Bells closer together than this ring once: `cat` on a binary file writes thousands.
pub const BELL_INTERVAL: Duration = Duration::from_millis(250);
/// A new terminal's grid until its view measures it (Swift's 100 x 24).
pub const INITIAL_COLUMNS: usize = 100;
pub const INITIAL_ROWS: usize = 24;
pub const SCROLLBACK_LINES: usize = 10_000;
pub const TEXT_LIMIT_NOTICE: &str =
    "A terminal character exceeded the 64-byte combining-mark limit and was replaced with �.";

/// What the program for a project's directory is (a login shell in the app,
/// a `/bin/sh` script in tests).
pub type Launcher = Arc<dyn Fn(&Path) -> TerminalLaunch + Send + Sync>;

pub struct TerminalSession {
    /// Which terminal of the project this is: the same through a restart.
    pub id: Uuid,
    /// "Terminal N": numbered per project, never reused while the app runs.
    pub number: usize,
    /// Bumped by each restart, which makes a new session in this one's place.
    pub generation: u64,
    pub directory: PathBuf,
    pub emulator: TerminalEmulator,
    pub process: Option<PseudoTerminal>,
    /// The title the shell sets with escape sequences.
    pub shell_title: String,
    /// The reader's own name; None for "Terminal N".
    custom_name: Option<String>,
    pub exited: bool,
    pub failure: Option<String>,
    pub exit_code: Option<i32>,
    /// Bells actually rung.
    pub bells_rung: usize,
    last_bell: Option<Instant>,
    /// A bell is due: the app rings it.
    pub bell_due: bool,
}

/// What a `pump` changed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Pumped {
    /// The grid or the session's state changed: draw again.
    pub changed: bool,
    /// More output is waiting: pump again after this frame.
    pub more: bool,
}

impl TerminalSession {
    fn new(
        directory: PathBuf,
        id: Uuid,
        number: usize,
        custom_name: Option<String>,
        generation: u64,
        launcher: &Launcher,
    ) -> Self {
        let mut session = Self {
            id,
            number,
            generation,
            directory,
            emulator: TerminalEmulator::new(INITIAL_COLUMNS, INITIAL_ROWS, SCROLLBACK_LINES),
            process: None,
            shell_title: String::new(),
            custom_name,
            exited: false,
            failure: None,
            exit_code: None,
            bells_rung: 0,
            last_bell: None,
            bell_due: false,
        };
        session.start(launcher);
        session
    }
    fn start(&mut self, launcher: &Launcher) {
        self.exited = false;
        self.failure = None;
        let launch = launcher(&self.directory);
        match PseudoTerminal::start(
            &launch,
            self.emulator.columns() as u16,
            self.emulator.rows() as u16,
        ) {
            Ok(process) => self.process = Some(process),
            Err(error) => {
                self.failure = Some(error.to_string());
                self.exited = true;
            }
        }
    }
    pub fn custom_name(&self) -> Option<&str> {
        self.custom_name.as_deref()
    }
    pub fn display_name(&self) -> String {
        self.custom_name
            .clone()
            .unwrap_or_else(|| format!("Terminal {}", self.number))
    }
    /// The shell is still running: ending it asks first.
    pub fn running(&self) -> bool {
        self.process.as_ref().is_some_and(PseudoTerminal::running)
    }
    pub fn waiter(&self) -> Option<TerminalWaiter> {
        self.process.as_ref().map(PseudoTerminal::waiter)
    }
    /// Input from the keyboard or a paste.
    pub fn write(&mut self, data: &[u8]) {
        if let Some(process) = self.process.as_mut() {
            // A refused paste is reported by the next pump.
            process.write(data);
        }
    }
    /// Fits the grid and the program's window size to the view.
    pub fn resize(&mut self, columns: usize, rows: usize) {
        if columns == self.emulator.columns() && rows == self.emulator.rows() {
            return;
        }
        self.emulator.resize(columns, rows);
        if let Some(process) = self.process.as_mut() {
            process.resize(self.emulator.columns() as u16, self.emulator.rows() as u16);
        }
    }
    /// Feeds what the program wrote to the grid, sends the replies it asked
    /// for, and takes in its exit once everything before it is drawn.
    pub fn pump(&mut self, now: Instant) -> Pumped {
        let Some(process) = self.process.as_mut() else {
            return Pumped::default();
        };
        let output = process.take_output();
        let mut changed = !output.bytes.is_empty();
        if !output.bytes.is_empty() {
            self.emulator.feed(&output.bytes);
        }
        let replies = self.emulator.take_output();
        if !replies.is_empty() {
            process.write(&replies);
        }
        for notice in output.notices {
            self.failure = Some(notice);
            changed = true;
        }
        for event in self.emulator.take_events() {
            match event {
                TerminalEvent::Bell => self.ring_bell(now),
                TerminalEvent::TitleChanged(title) => {
                    self.shell_title = title;
                    changed = true;
                }
                TerminalEvent::DirectoryChanged(_) => {}
                TerminalEvent::TextLimit => {
                    self.failure = Some(TEXT_LIMIT_NOTICE.into());
                    changed = true;
                }
            }
        }
        if let Some(code) = output.exit {
            self.exit_code = Some(code);
            self.exited = true;
            changed = true;
        }
        Pumped {
            changed,
            more: output.more,
        }
    }
    fn ring_bell(&mut self, now: Instant) {
        if self
            .last_bell
            .is_some_and(|last| now.saturating_duration_since(last) < BELL_INTERVAL)
        {
            return;
        }
        self.last_bell = Some(now);
        self.bells_rung += 1;
        self.bell_due = true;
    }
    fn end(&mut self) {
        if let Some(process) = self.process.as_mut() {
            process.terminate();
        }
    }
}

#[derive(Default)]
pub struct TerminalProject {
    pub sessions: Vec<TerminalSession>,
    pub selected: Option<Uuid>,
    next_number: usize,
}

/// What ends a shell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ending {
    Restart,
    Close,
}

/// The question asked before ending a live shell: title, detail, action.
pub fn ending_question(
    ending: Ending,
    name: &str,
    project: &str,
    directory: &str,
) -> (String, String, &'static str) {
    let ends = "This ends the shell in this terminal and may interrupt a command it is running.";
    match ending {
        Ending::Restart => (
            format!("Restart “{name}” in “{project}”?"),
            format!("{ends} Its scrollback is removed, and a new shell starts in {directory}."),
            "Restart Terminal",
        ),
        Ending::Close => (
            format!("Close “{name}” in “{project}”?"),
            format!("{ends} Its output is removed. The project's other terminals keep running."),
            "Close Terminal",
        ),
    }
}

/// Every project's terminals, keyed by the project's identity.
pub struct TerminalRegistry {
    projects: BTreeMap<String, TerminalProject>,
    launcher: Launcher,
}

impl TerminalRegistry {
    pub fn new(launcher: Launcher) -> Self {
        Self {
            projects: BTreeMap::new(),
            launcher,
        }
    }
    /// Projects with at least one shell.
    pub fn open_projects(&self) -> Vec<String> {
        self.projects
            .iter()
            .filter(|(_, project)| !project.sessions.is_empty())
            .map(|(key, _)| key.clone())
            .collect()
    }
    pub fn sessions(&self, project: &str) -> &[TerminalSession] {
        self.projects
            .get(project)
            .map_or(&[], |project| project.sessions.as_slice())
    }
    pub fn sessions_mut(&mut self, project: &str) -> &mut [TerminalSession] {
        self.projects
            .get_mut(project)
            .map_or(&mut [], |project| project.sessions.as_mut_slice())
    }
    fn selected_index(&self, project: &str) -> Option<usize> {
        let project = self.projects.get(project)?;
        if project.sessions.is_empty() {
            return None;
        }
        Some(
            project
                .sessions
                .iter()
                .position(|s| Some(s.id) == project.selected)
                .unwrap_or(0),
        )
    }
    pub fn selected(&self, project: &str) -> Option<&TerminalSession> {
        let index = self.selected_index(project)?;
        self.projects.get(project)?.sessions.get(index)
    }
    pub fn selected_mut(&mut self, project: &str) -> Option<&mut TerminalSession> {
        let index = self.selected_index(project)?;
        self.projects.get_mut(project)?.sessions.get_mut(index)
    }
    pub fn find(&self, id: Uuid, project: &str) -> Option<&TerminalSession> {
        self.sessions(project).iter().find(|s| s.id == id)
    }
    pub fn find_mut(&mut self, id: Uuid, project: &str) -> Option<&mut TerminalSession> {
        self.sessions_mut(project).iter_mut().find(|s| s.id == id)
    }
    /// The terminal the panel shows for a project. A project shown for the
    /// first time gets Terminal 1; one whose terminals were all closed stays
    /// empty until the reader asks for a new one.
    pub fn ensure_initial_session(&mut self, project: &str, directory: &Path) -> Option<Uuid> {
        if self.projects.contains_key(project) {
            return self.selected(project).map(|s| s.id);
        }
        Some(self.create(project, directory))
    }
    /// A new terminal for the project, shown at once.
    pub fn create(&mut self, project: &str, directory: &Path) -> Uuid {
        let launcher = self.launcher.clone();
        let entry = self
            .projects
            .entry(project.to_owned())
            .or_insert_with(|| TerminalProject {
                next_number: 1,
                ..TerminalProject::default()
            });
        let session = TerminalSession::new(
            directory.to_owned(),
            Uuid::new_v4(),
            entry.next_number,
            None,
            0,
            &launcher,
        );
        entry.next_number += 1;
        let id = session.id;
        entry.sessions.push(session);
        entry.selected = Some(id);
        id
    }
    pub fn select(&mut self, id: Uuid, project: &str) -> bool {
        let Some(entry) = self.projects.get_mut(project) else {
            return false;
        };
        if !entry.sessions.iter().any(|s| s.id == id) || entry.selected == Some(id) {
            return false;
        }
        entry.selected = Some(id);
        true
    }
    /// Gives a terminal the reader's name: trimmed, at most `NAME_LIMIT`
    /// characters, and empty for its "Terminal N" name back.
    pub fn rename(&mut self, id: Uuid, project: &str, name: &str) {
        let Some(session) = self.find_mut(id, project) else {
            return;
        };
        let trimmed = name.trim();
        session.custom_name = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.graphemes(true).take(NAME_LIMIT).collect())
        };
    }
    /// A fresh shell in this terminal's place: same name and number, new
    /// emulator and scrollback. None when that terminal, at that generation,
    /// is no longer there.
    pub fn restart(&mut self, id: Uuid, project: &str, generation: u64) -> Option<Uuid> {
        let launcher = self.launcher.clone();
        let entry = self.projects.get_mut(project)?;
        let index = entry.sessions.iter().position(|s| s.id == id)?;
        if entry.sessions[index].generation != generation {
            return None;
        }
        let old = &entry.sessions[index];
        let fresh = TerminalSession::new(
            old.directory.clone(),
            old.id,
            old.number,
            old.custom_name.clone(),
            old.generation + 1,
            &launcher,
        );
        let mut old = std::mem::replace(&mut entry.sessions[index], fresh);
        old.end();
        Some(id)
    }
    /// Ends one terminal and gives up its output. The one after it is shown,
    /// or the one before; the shown terminal stays shown when another closes.
    pub fn close(&mut self, id: Uuid, project: &str, generation: u64) {
        let Some(entry) = self.projects.get_mut(project) else {
            return;
        };
        let Some(index) = entry.sessions.iter().position(|s| s.id == id) else {
            return;
        };
        if entry.sessions[index].generation != generation {
            return;
        }
        let mut old = entry.sessions.remove(index);
        if entry.selected == Some(id) {
            entry.selected = if entry.sessions.is_empty() {
                None
            } else {
                Some(entry.sessions[index.min(entry.sessions.len() - 1)].id)
            };
        }
        old.end();
    }
    /// Ends every shell of a project and gives up their scrollback.
    pub fn close_project(&mut self, project: &str) {
        if let Some(entry) = self.projects.remove(project) {
            for mut session in entry.sessions {
                session.end();
            }
        }
    }
    /// Ends every shell as the app quits: SIGHUP to all, `grace` for them to
    /// go, then SIGKILL to any left. Swift's two-second SIGKILL would need a
    /// thread that outlives the app, so a shell ignoring SIGHUP survived Quit.
    pub fn end_all_now(&mut self, grace: Duration) {
        let mut processes: Vec<PseudoTerminal> = std::mem::take(&mut self.projects)
            .into_values()
            .flat_map(|entry| entry.sessions)
            .filter_map(|mut session| session.process.take())
            .collect();
        for process in &mut processes {
            process.terminate();
        }
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline && processes.iter().any(|p| !p.reaped()) {
            std::thread::sleep(Duration::from_millis(5));
        }
        for process in &mut processes {
            process.kill_now();
        }
    }
    /// Ends every shell, on the way out of the app.
    pub fn shutdown(&mut self) {
        for (_, entry) in std::mem::take(&mut self.projects) {
            for mut session in entry.sessions {
                session.end();
            }
        }
    }
}

impl Drop for TerminalRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}
