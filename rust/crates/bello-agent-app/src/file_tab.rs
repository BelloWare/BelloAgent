//! Existing FileTab header/text placement, with the requested editable/Vim
//! capability implemented by the shared editor and conflict-safe file document.
use crate::theme::Palette;
use bello_workbench::document::{FileDocument, OpenedFile};
use bello_workbench_ui::{EditorAppearance, EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub enum FileTabEvent {
    Changed,
    CloseReady,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum CloseIntent {
    #[default]
    None,
    Ask,
    AfterSave,
}
#[derive(Default)]
struct Lifecycle {
    generation: u64,
    saving: bool,
    close: CloseIntent,
}
impl Lifecycle {
    fn request_close(&mut self, dirty: bool) -> bool {
        if self.saving || dirty {
            self.close = CloseIntent::Ask;
            false
        } else {
            true
        }
    }
    fn begin_save(&mut self) -> Option<u64> {
        if self.saving {
            return None;
        }
        self.saving = true;
        Some(self.generation)
    }
    fn complete_save(&mut self, generation: u64, success: bool, dirty: bool) -> bool {
        if generation != self.generation {
            return false;
        }
        self.saving = false;
        let close = success && !dirty && self.close == CloseIntent::AfterSave;
        if close {
            self.close = CloseIntent::None;
        } else if self.close == CloseIntent::AfterSave {
            self.close = CloseIntent::Ask;
        }
        close
    }
}
pub struct FileTabView {
    root: PathBuf,
    path: PathBuf,
    editor: Entity<EditorView>,
    document: Option<FileDocument>,
    palette: Palette,
    lifecycle: Lifecycle,
    loading: bool,
    notice: Option<String>,
    vim: bool,
    menu: bool,
    pending_line: Option<usize>,
    _subscription: Subscription,
}
impl EventEmitter<FileTabEvent> for FileTabView {}
impl FileTabView {
    pub fn new(
        root: PathBuf,
        path: PathBuf,
        line: Option<usize>,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let editor = cx.new(|cx| {
            let mut editor = EditorView::new(String::new(), window, cx);
            editor.set_appearance(Self::style(palette), cx);
            editor.set_read_only(true, cx);
            editor
        });
        let subscription = cx.subscribe(&editor, |view, _, event, cx| match event {
            EditorEvent::SaveRequested => view.save(cx),
            EditorEvent::Changed => {
                cx.emit(FileTabEvent::Changed);
                cx.notify();
            }
            EditorEvent::LayoutChanged => cx.notify(),
        });
        let mut view = Self {
            root,
            path,
            editor,
            document: None,
            palette,
            lifecycle: Lifecycle::default(),
            loading: false,
            notice: None,
            vim: false,
            menu: false,
            pending_line: line,
            _subscription: subscription,
        };
        view.load(cx);
        view
    }
    fn style(p: Palette) -> EditorAppearance {
        let mut style = EditorAppearance::code();
        style.background = Some(rgb(p.content).into());
        style.text = rgb(p.ink).into();
        style.line_number = rgb(p.tertiary).into();
        style.selection = p.accent_soft();
        style.caret = rgb(p.accent).into();
        style.accent = rgb(p.accent).into();
        style
    }
    pub fn set_palette(&mut self, p: Palette, cx: &mut Context<Self>) {
        self.palette = p;
        self.editor
            .update(cx, |editor, cx| editor.set_appearance(Self::style(p), cx));
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn title(&self) -> String {
        self.path()
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    }
    pub fn is_dirty(&self, cx: &App) -> bool {
        self.document
            .as_ref()
            .is_some_and(|document| document.is_dirty(self.editor.read(cx).text()))
    }
    pub fn is_saving(&self) -> bool {
        self.lifecycle.saving
    }
    #[cfg(test)]
    pub(crate) fn editor_for_test(&self) -> Entity<EditorView> {
        self.editor.clone()
    }
    pub(crate) fn has_close_prompt(&self) -> bool {
        self.lifecycle.close != CloseIntent::None
    }
    pub(crate) fn close_prompt_key(
        &mut self,
        event: &KeyDownEvent,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.has_close_prompt() || self.has_focused_composition(window, cx) {
            return false;
        }
        if matches!(event.keystroke.key.as_str(), "escape" | "enter") {
            // Same Keep Editing transition as the existing child handler.
            // Never save/discard text or change the prior focus here.
            self.lifecycle.close = CloseIntent::None;
            cx.notify();
        }
        true
    }
    pub(crate) fn has_focused_composition(&self, window: &Window, cx: &App) -> bool {
        let editor = self.editor.read(cx);
        editor.focus_handle(cx).is_focused(window) && editor.has_marked_text()
    }
    pub fn focus(&self, window: &mut Window, cx: &App) {
        self.editor.read(cx).focus(window);
    }
    pub fn reveal_line(&mut self, line: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.loading {
            self.pending_line = Some(line);
        } else {
            self.editor
                .update(cx, |editor, cx| editor.reveal_line(line, window, cx));
        }
    }
    pub fn request_close(&mut self, cx: &mut Context<Self>) {
        if self.lifecycle.request_close(self.is_dirty(cx)) {
            cx.emit(FileTabEvent::CloseReady);
        }
        cx.notify();
    }
    fn load(&mut self, cx: &mut Context<Self>) {
        self.lifecycle.generation += 1;
        let generation = self.lifecycle.generation;
        self.loading = true;
        self.notice = None;
        let root = self.root.clone();
        let path = self.path.clone();
        let task = cx
            .background_executor()
            .spawn(async move { FileDocument::open(root, path) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.lifecycle.generation != generation {
                    return;
                }
                view.loading = false;
                match result {
                    Ok(OpenedFile::Editable(document)) => {
                        view.editor.update(cx, |editor, cx| {
                            editor.set_read_only(false, cx);
                            editor.set_text(document.text().into(), cx);
                        });
                        view.document = Some(document);
                    }
                    Ok(OpenedFile::Preview(preview)) => {
                        view.editor.update(cx, |editor, cx| {
                            editor.set_text(preview.text, cx);
                            editor.set_read_only(true, cx);
                        });
                        view.notice = Some(preview.reason);
                    }
                    Err(error) => view.notice = Some(error.to_string()),
                }
                cx.emit(FileTabEvent::Changed);
                cx.notify();
            });
        })
        .detach();
    }
    pub fn save(&mut self, cx: &mut Context<Self>) {
        let Some(mut document) = self.document.clone() else {
            self.notice = Some("This file is read-only".into());
            cx.notify();
            return;
        };
        let Some(generation) = self.lifecycle.begin_save() else {
            return;
        };
        let text = self.editor.read(cx).text().to_owned();
        let task = cx
            .background_executor()
            .spawn(async move { document.save(&text).map(|outcome| (document, outcome)) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.lifecycle.generation != generation {
                    return;
                }
                let success = result.is_ok();
                match result {
                    Ok((document, outcome)) => {
                        view.document = Some(document);
                        view.notice = Some(if outcome.directory_synced {
                            "Saved".into()
                        } else {
                            "Saved; directory durability could not be confirmed".into()
                        });
                    }
                    Err(error) => view.notice = Some(error.to_string()),
                }
                let dirty = view.is_dirty(cx);
                let close = view.lifecycle.complete_save(generation, success, dirty);
                cx.emit(if close {
                    FileTabEvent::CloseReady
                } else {
                    FileTabEvent::Changed
                });
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn toggle_vim(&mut self, cx: &mut Context<Self>) {
        if self.editor.read(cx).has_marked_text() {
            return;
        }
        self.vim = !self.vim;
        self.editor
            .update(cx, |editor, cx| editor.set_vim(self.vim, cx));
        self.menu = false;
        cx.notify();
    }
    fn button(&self, id: &'static str, label: impl Into<SharedString>) -> Stateful<Div> {
        let p = self.palette;
        div()
            .id(id)
            .px(px(10.))
            .py(px(5.))
            .rounded(px(8.))
            .border_1()
            .border_color(p.hairline())
            .text_size(px(11.5))
            .cursor_pointer()
            .hover(move |d| d.bg(p.fill()))
            .child(label.into())
    }
}
impl Render for FileTabView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.loading
            && let Some(line) = self.pending_line.take()
        {
            self.editor
                .update(cx, |editor, cx| editor.reveal_line(line, window, cx));
        }
        let p = self.palette;
        let relative = self
            .path
            .strip_prefix(&self.root)
            .unwrap_or(&self.path)
            .display()
            .to_string();
        let dirty = self.is_dirty(cx);
        let mut content = div()
            .relative()
            .flex_1()
            .size_full()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(rgb(p.content))
            .text_color(rgb(p.ink))
            .capture_key_down(cx.listener(|view, event: &KeyDownEvent, window, cx| {
                if view.close_prompt_key(event, window, cx) {
                    cx.stop_propagation();
                    return;
                }
                let mods = &event.keystroke.modifiers;
                if event.keystroke.key == "v" && mods.control && mods.alt {
                    view.toggle_vim(cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .h(px(32.))
                    .flex_shrink_0()
                    .px(px(12.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .border_b_1()
                    .border_color(p.hairline())
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .child(div().flex_1().min_w_0().truncate().child(format!(
                        "{}{}{}",
                        relative,
                        if dirty { " •" } else { "" },
                        if self.loading { " · Opening…" } else { "" }
                    )))
                    .when(self.vim, |d| d.child("Vim"))
                    .child(
                        div()
                            .id("file-actions")
                            .size(px(26.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .child(
                                svg()
                                    .path("dots")
                                    .size(px(14.))
                                    .text_color(rgb(p.secondary)),
                            )
                            .on_click(cx.listener(|view, _, _, cx| {
                                view.menu = !view.menu;
                                cx.notify();
                            })),
                    ),
            )
            .child(self.editor.clone());
        if let Some(notice) = &self.notice {
            content = content.child(
                div()
                    .px(px(12.))
                    .py(px(6.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .line_clamp(3)
                    .child(notice.clone()),
            );
        }
        if self.menu {
            content = content.child(
                div()
                    .absolute()
                    .right(px(8.))
                    .top(px(31.))
                    .w(px(210.))
                    .p(px(6.))
                    .rounded(px(8.))
                    .border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.surface))
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(
                        self.button(
                            "file-save",
                            if self.lifecycle.saving {
                                "Saving…"
                            } else {
                                "Save · Ctrl/⌘S"
                            },
                        )
                        .on_click(cx.listener(|view, _, _, cx| {
                            view.menu = false;
                            view.save(cx);
                        })),
                    )
                    .child(
                        self.button(
                            "file-vim",
                            if self.vim {
                                "Vim: On · CtrlAltV"
                            } else {
                                "Vim: Off · CtrlAltV"
                            },
                        )
                        .on_click(cx.listener(|view, _, _, cx| view.toggle_vim(cx))),
                    ),
            );
        }
        if self.lifecycle.close != CloseIntent::None {
            content = content.child(
                div()
                    .absolute()
                    .inset_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000033))
                    .child(
                        div()
                            .mx(px(16.))
                            .max_w(px(400.))
                            .p(px(16.))
                            .rounded(px(12.))
                            .border_1()
                            .border_color(p.hairline())
                            .bg(rgb(p.surface))
                            .flex()
                            .flex_col()
                            .gap(px(12.))
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("Save changes before closing? "),
                            )
                            .child(div().text_size(px(13.)).child(self.title()))
                            .child(
                                div()
                                    .flex()
                                    .flex_wrap()
                                    .gap(px(8.))
                                    .child(self.button("keep-editing", "Keep Editing").on_click(
                                        cx.listener(|view, _, _, cx| {
                                            view.lifecycle.close = CloseIntent::None;
                                            cx.notify();
                                        }),
                                    ))
                                    .child(
                                        self.button("discard-file", "Discard")
                                            .opacity(if self.lifecycle.saving { 0.45 } else { 1.0 })
                                            .on_click(cx.listener(|view, _, _, cx| {
                                                if !view.lifecycle.saving {
                                                    cx.emit(FileTabEvent::CloseReady);
                                                }
                                            })),
                                    )
                                    .child(self.button("save-close", "Save").on_click(
                                        cx.listener(|view, _, _, cx| {
                                            view.lifecycle.close = CloseIntent::AfterSave;
                                            view.save(cx);
                                        }),
                                    )),
                            ),
                    ),
            );
        }
        content
    }
}
#[cfg(test)]
mod tests {
    use super::{CloseIntent, Lifecycle};
    #[test]
    fn close_requires_explicit_decision() {
        let mut state = Lifecycle::default();
        assert!(!state.request_close(true));
        assert_eq!(state.close, CloseIntent::Ask);
        state.close = CloseIntent::None;
        assert!(state.request_close(false));
    }
    #[test]
    fn save_close_never_drops_new_typing_or_failed_save() {
        let mut state = Lifecycle {
            close: CloseIntent::AfterSave,
            ..Default::default()
        };
        let id = state.begin_save().unwrap();
        assert!(!state.complete_save(id, true, true));
        assert_eq!(state.close, CloseIntent::Ask);
        state.close = CloseIntent::AfterSave;
        let id = state.begin_save().unwrap();
        assert!(!state.complete_save(id, false, true));
        assert_eq!(state.close, CloseIntent::Ask);
    }
    #[test]
    fn stale_save_cannot_close_newer_document() {
        let mut state = Lifecycle {
            close: CloseIntent::AfterSave,
            ..Default::default()
        };
        let id = state.begin_save().unwrap();
        state.generation += 1;
        assert!(!state.complete_save(id, true, false));
        assert_eq!(state.close, CloseIntent::AfterSave);
    }

    #[gpui::test]
    fn adjacent_chat_file_composition_guard_only_tracks_focused_marked_editor(
        cx: &mut gpui::TestAppContext,
    ) {
        use super::{FileTabView, Palette};
        use gpui::EntityInputHandler;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file.txt");
        std::fs::write(&path, "original").unwrap();
        let window = cx.add_window(|window, cx| {
            FileTabView::new(
                dir.path().into(),
                path,
                None,
                Palette::for_appearance(gpui::WindowAppearance::Light),
                window,
                cx,
            )
        });
        cx.run_until_parked();
        window
            .update(cx, |view, window, cx| {
                assert!(!view.has_focused_composition(window, cx));
                view.editor.update(cx, |editor, cx| {
                    editor.focus(window);
                    editor.replace_and_mark_text_in_range(None, "日本", Some(2..2), window, cx);
                });
                assert!(view.has_focused_composition(window, cx));
                let other = cx.focus_handle();
                other.focus(window);
                assert!(!view.has_focused_composition(window, cx));
                assert!(view.editor.read(cx).has_marked_text());
                view.editor.update(cx, |editor, cx| {
                    editor.focus(window);
                    editor.unmark_text(window, cx);
                });
                assert!(!view.has_focused_composition(window, cx));
            })
            .unwrap();
    }
}
