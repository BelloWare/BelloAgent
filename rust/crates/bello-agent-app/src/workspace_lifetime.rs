//! App-owned retention groundwork for the source's single workspace window.
//! Close/Quit policy is deliberately unchanged until a cancellable native quit
//! coordinator exists. Reattachment is exercised in headless tests only for now.
use crate::{AgentView, LaunchState, initial_size};
use gpui::{
    App, AppContext, Bounds, Entity, Global, WindowBounds, WindowHandle, WindowId, WindowOptions,
    px, size,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct WindowBinding {
    window: WindowId,
    generation: uuid::Uuid,
}
impl WindowBinding {
    pub(crate) fn new(window: WindowId) -> Self {
        Self {
            window,
            generation: uuid::Uuid::new_v4(),
        }
    }
}

/// Keeping the actual entity graph preserves editor undo and unsaved buffers;
/// a disk-based reconstruction would retain only persisted chat state.
pub(crate) struct WorkspaceLifetime {
    view: Entity<AgentView>,
    window: WindowHandle<AgentView>,
    title: &'static str,
}
impl Global for WorkspaceLifetime {}

fn options(cx: &App) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            initial_size(),
            cx,
        ))),
        window_min_size: Some(size(px(920.), px(600.))),
        ..Default::default()
    }
}

impl WorkspaceLifetime {
    /// Global menu Quit also works while an inspector owns the key window.
    /// It still passes through the workspace's save/stop/dirty-close policy.
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn request_quit(cx: &mut App) {
        if !cx.has_global::<Self>() {
            return;
        }
        let window = cx.global::<Self>().window;
        let _ = window.update(cx, |view, window, cx| {
            if view.request_close(window, cx) {
                cx.quit();
            }
        });
    }

    pub(crate) fn launch(
        launch: LaunchState,
        cx: &mut App,
    ) -> Result<WindowHandle<AgentView>, String> {
        Self::launch_with_title(launch, "Bello Agent", cx)
    }

    /// Set the final title in root construction before the first draw. The
    /// Linux validation fixture must not retitle the window after open_window
    /// returns: that extra synchronous X11 title update can stall initial paint.
    pub(crate) fn launch_with_title(
        launch: LaunchState,
        title: &'static str,
        cx: &mut App,
    ) -> Result<WindowHandle<AgentView>, String> {
        if cx.has_global::<Self>() {
            return Err("Workspace lifetime is already installed".into());
        }
        let window = cx
            .open_window(options(cx), move |window, cx| {
                window.set_window_title(title);
                cx.new(|cx| AgentView::new(launch, window, cx))
            })
            .map_err(|error| error.to_string())?;
        let view = window
            .update(cx, |_, _, cx| cx.entity())
            .map_err(|error| error.to_string())?;
        cx.set_global(Self {
            view,
            window,
            title,
        });
        cx.on_app_quit(|cx| {
            // Match the old window-owned release timing: shutdown calls this
            // before clearing windows and flushing entity release effects.
            // This is cleanup only, never a cancellable Quit/save coordinator.
            if cx.has_global::<Self>() {
                cx.remove_global::<Self>();
            }
            async {}
        })
        .detach();
        Self::ensure_window(cx)
    }

    /// Startup uses the already-open branch. A future reviewed reopen handler
    /// can use the detached branch without replacing any chat/editor entity.
    /// This method does not bypass the existing shutdown policy.
    pub(crate) fn ensure_window(cx: &mut App) -> Result<WindowHandle<AgentView>, String> {
        let owner = cx.global::<Self>();
        let handle = owner.window;
        let view = owner.view.clone();
        let title = owner.title;
        if view.read(cx).shutting_down || view.read(cx).close_ready {
            return Err("Workspace is shutting down".into());
        }
        if cx
            .windows()
            .iter()
            .any(|window| window.window_id() == handle.window_id())
        {
            // Startup activation remains owned by the existing App::activate
            // call; retention must not introduce another native activation
            // during initial window creation.
            return Ok(handle);
        }
        // Opening is synchronous on the foreground App borrow, so another
        // request cannot interleave and create a duplicate workspace window.
        let replacement = cx
            .open_window(options(cx), move |window, cx| {
                window.set_window_title(title);
                view.update(cx, |view, cx| view.bind_window(window, cx));
                view
            })
            .map_err(|error| error.to_string())?;
        cx.global_mut::<Self>().window = replacement;
        Ok(replacement)
    }
}

#[cfg(test)]
#[path = "workspace_lifetime_tests.rs"]
mod tests;
