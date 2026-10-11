//! The integrated terminal's core (Swift 0.1.122 apps/macos/PiApp/Terminal/
//! and Workspaces/TerminalPanel.swift): the VT emulator and its cell grid,
//! the key encoder, and on Unix the pseudo-terminal and the per-project
//! registry of shells. Drawing and input routing live in the app.
pub mod emulator;
pub mod keys;
#[cfg(unix)]
pub mod pty;
pub mod screen;
#[cfg(unix)]
pub mod session;
pub mod width;
mod width_table;

pub use emulator::{TerminalEmulator, TerminalEvent};
pub use screen::{CellStyle, CellText, TerminalCell, TerminalColor, TerminalCursorShape};

#[cfg(test)]
#[path = "emulator_tests.rs"]
mod emulator_tests;
#[cfg(all(test, unix))]
#[path = "pty_tests.rs"]
mod pty_tests;
