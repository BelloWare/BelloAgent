//! Measured pane/composer inputs for QueuePanel.room, not estimated text heights.
use crate::{AgentView, queue_presentation, workspace_lifetime::WindowBinding};
use gpui::{Bounds, Context, Pixels};

// ComposerInput.swift includes these outer spacings in its measured geometry.
// Use the same constants for rendering and the GPUI border-box measurement.
pub(crate) const COMPOSER_TOP: f32 = 8.;
pub(crate) const COMPOSER_BOTTOM: f32 = 6.;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct QueueGeometry {
    pub(crate) pane_height: f32,
    pub(crate) pane_width: f32,
    pub(crate) composer_height: f32,
    pub(crate) footer_height: f32,
    /// An open terminal panel sits between the queue and the composer.
    pub(crate) terminal: bool,
}
impl QueueGeometry {
    pub(crate) fn from_children(bounds: &[Bounds<Pixels>]) -> Option<Self> {
        // Conversation children: transcript, queue, the terminal while it is
        // open, composer, footer, absolute full-pane probe. The probe is out
        // of flow and has no paint/hitbox.
        let terminal = match bounds.len() {
            5 => false,
            6 => true,
            _ => return None,
        };
        let last = bounds.len() - 1;
        let composer = bounds.get(last - 2)?;
        let footer = bounds.get(last - 1)?;
        let pane = bounds.get(last)?;
        let measured = Self {
            terminal,
            pane_height: pane.size.height.into(),
            pane_width: pane.size.width.into(),
            composer_height: f32::from(composer.size.height) + COMPOSER_TOP + COMPOSER_BOTTOM,
            footer_height: footer.size.height.into(),
        };
        [
            measured.pane_height,
            measured.pane_width,
            measured.composer_height,
            measured.footer_height,
        ]
        .iter()
        .all(|value| value.is_finite() && *value >= 0.)
        .then_some(measured)
    }
    pub(crate) fn room(self) -> f32 {
        // An open terminal reserves its minimum and its chrome, as Swift's
        // QueuePanel.room does. Rust's current footer can wrap in a narrow
        // split. The source already reserves 36pt, so subtract only measured
        // overflow beyond that budget. This preserves the source formula when
        // the footer fits one line.
        let terminal = if self.terminal {
            crate::terminal_panel::MINIMUM_HEIGHT + crate::terminal_panel::CHROME_HEIGHT
        } else {
            0.
        };
        queue_presentation::room(self.pane_height, self.composer_height, terminal)
            - (self.footer_height - queue_presentation::FOOTER_HEIGHT).max(0.)
    }
}
impl AgentView {
    pub(crate) fn record_queue_geometry(
        &mut self,
        chat_id: &str,
        binding: Option<WindowBinding>,
        geometry: QueueGeometry,
        cx: &mut Context<Self>,
    ) {
        if self.record.id != chat_id || self.window_binding != binding {
            return;
        }
        if self.queue_geometry != Some(geometry) {
            self.queue_geometry = Some(geometry);
            cx.notify();
        }
    }
}

#[cfg(test)]
#[path = "queue_geometry_tests.rs"]
mod tests;
