//! PiApp's Command-. and WorkspaceChanges.stopFocused: editable tab text
//! and modal work own their keys; otherwise stop the currently selected chat.
use crate::{AgentView, RunState};
use gpui::{App, Context, Window};

impl AgentView {
    pub(super) fn stop_current_run(&mut self, cx: &mut Context<Self>) {
        let result = self.controller.stop();
        self.result(result, cx);
    }

    pub(super) fn stop_shortcut_allowed(&self, window: &Window, cx: &App) -> bool {
        !self.shutting_down
            && !self.loading
            && !self.load_failed
            && !self.close_dialog
            && self.sidebar_menu.is_none()
            && !self.quick_open.read(cx).is_open()
            && !self.files.iter().any(|entry| {
                let tab = entry.view.read(cx);
                tab.has_close_prompt()
                    || (self.show_files
                        && self.selected_file == Some(entry.id)
                        && tab.has_focused_editable_text(window, cx))
            })
            && !(self.show_files
                && self.selected_file.is_none()
                && self
                    .workbench
                    .read(cx)
                    .has_focused_editable_text(window, cx))
    }

    pub(super) fn stop_from_shortcut(&mut self, window: &Window, cx: &mut Context<Self>) {
        if self.stop_shortcut_allowed(window, cx)
            && self.controller.snapshot_shared().state == RunState::Running
        {
            // Same cancellation and outcome path as the existing Stop button.
            // Do not replace/focus the composer or commit its marked text.
            self.stop_current_run(cx);
        }
    }
}
