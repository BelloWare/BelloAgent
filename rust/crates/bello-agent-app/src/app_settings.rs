//! App-wide reading preferences from Settings' "Chats & notifications"
//! section (Swift ConfigurationVault.swift `transcriptView`,
//! TranscriptTurnFold.swift `TranscriptDisplayMode`).
//!
//! The transcript reads the mode through [`transcript_display`] and follows
//! changes with [`observe_transcript_display`]. Only Settings' Save All
//! writes it; a failed write leaves the mode in force unchanged.
use gpui::{App, Context, Global, Subscription};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// How a finished turn reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum TranscriptDisplayMode {
    /// A finished turn keeps every row it had while it ran.
    Normal,
    /// A finished turn's work folds behind one line above its answer. The
    /// default when nothing was saved (Swift `fallback`).
    #[default]
    Compact,
}
impl TranscriptDisplayMode {
    pub(crate) const ALL: [Self; 2] = [Self::Normal, Self::Compact];
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Normal => "Normal",
            Self::Compact => "Compact",
        }
    }
    pub(crate) fn detail(self) -> &'static str {
        match self {
            Self::Normal => "A finished turn keeps every tool call and thought on screen.",
            Self::Compact => "A finished turn folds its work behind one line above the answer.",
        }
    }
    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Compact => "compact",
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    /// Swift's vault key; an unknown value reads as the default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transcript_view: Option<String>,
}
impl Stored {
    fn mode(&self) -> TranscriptDisplayMode {
        match self.transcript_view.as_deref() {
            Some("normal") => TranscriptDisplayMode::Normal,
            _ => TranscriptDisplayMode::Compact,
        }
    }
}

/// The saved preferences, as a GPUI global so views can observe them.
pub(crate) struct AppSettings {
    path: Option<PathBuf>,
    stored: Stored,
}
impl Global for AppSettings {}
impl AppSettings {
    /// Reads the file if there is one; a missing or unreadable file is the
    /// defaults. `None` keeps everything in memory (tests).
    pub(crate) fn new(path: Option<PathBuf>) -> Self {
        let stored = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .filter(|bytes| bytes.len() <= 64 * 1024)
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self { path, stored }
    }
    pub(crate) fn transcript_display(&self) -> TranscriptDisplayMode {
        self.stored.mode()
    }
    pub(crate) fn set_transcript_display(
        &mut self,
        mode: TranscriptDisplayMode,
    ) -> std::io::Result<()> {
        let next = Stored {
            transcript_view: Some(mode.raw().into()),
        };
        if let Some(path) = &self.path {
            let parent = path
                .parent()
                .ok_or_else(|| std::io::Error::other("Settings have no folder"))?;
            std::fs::create_dir_all(parent)?;
            let temp = parent.join(format!(".app-settings-{}.tmp", uuid::Uuid::new_v4()));
            let result = (|| {
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&temp)?;
                file.write_all(&serde_json::to_vec(&next)?)?;
                file.sync_all()?;
                std::fs::rename(&temp, path)
            })();
            if result.is_err() {
                let _ = std::fs::remove_file(&temp);
            }
            result?;
        }
        self.stored = next;
        Ok(())
    }
}

/// The transcript display mode in force: the saved one, or Compact.
pub(crate) fn transcript_display(cx: &App) -> TranscriptDisplayMode {
    cx.try_global::<AppSettings>()
        .map(AppSettings::transcript_display)
        .unwrap_or_default()
}

/// Calls `changed` with the new mode whenever Settings saves a different one.
/// Keep the returned subscription for as long as the view should follow.
/// The transcript stream is its consumer; until it subscribes only tests do.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn observe_transcript_display<V: 'static>(
    cx: &mut Context<V>,
    mut changed: impl FnMut(&mut V, TranscriptDisplayMode, &mut Context<V>) + 'static,
) -> Subscription {
    let mut last = transcript_display(cx);
    cx.observe_global::<AppSettings>(move |view, cx| {
        let mode = transcript_display(cx);
        if mode != last {
            last = mode;
            changed(view, mode, cx);
        }
    })
}

#[cfg(test)]
#[path = "app_settings_tests.rs"]
mod tests;
