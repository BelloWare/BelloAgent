//! Masked replacement input for Connections. Only masks reach shaping or platform
//! text retrieval. There is no reveal, Copy/Cut export, drag export, or Undo log.
//! GPUI has no native secure-input flag: native keyboard/IME/accessibility and
//! production credential acceptance remain separate, unopened gates.
use bello_workbench_ui::EditorAppearance;
use gpui::{
    App, Bounds, Context, CursorStyle, ElementInputHandler, EntityInputHandler, EventEmitter,
    FocusHandle, Focusable, IntoElement, KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent,
    Pixels, Point, Render, ShapedLine, TextRun, UTF16Selection, Window, canvas, div, fill, point,
    prelude::*, px, size,
};
use std::{fmt, ops::Range, rc::Rc};
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;

pub(super) const KEY_BYTES: usize = 16_384;
pub(super) const HEADER_BYTES: usize = 262_144;
const MASK: &str = "•";
const MAX_VISIBLE_MASKS: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SecureInputEvent {
    Changed,
    Rejected,
}

pub(super) struct SecureInput {
    content: Zeroizing<String>,
    limit: usize,
    boundaries: Rc<[usize]>,
    focus: FocusHandle,
    read_only: bool,
    selection: Range<usize>,
    reversed: bool,
    marked: Option<Range<usize>>,
    dragging: bool,
    appearance: EditorAppearance,
    layout: Option<MaskedLayout>,
    rejection: Option<&'static str>,
    rejected_presentation: bool,
}

// Never derive Debug: even future retained input state must stay redacted.
impl fmt::Debug for SecureInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecureInput([REDACTED])")
    }
}

struct MaskedLayout {
    line: ShapedLine,
    bounds: Bounds<Pixels>,
    /// Byte positions contain no text; the final entry is the end boundary.
    boundaries: Rc<[usize]>,
    first: usize,
}

impl EventEmitter<SecureInputEvent> for SecureInput {}
impl Focusable for SecureInput {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl SecureInput {
    pub(super) fn new(limit: usize, appearance: EditorAppearance, cx: &mut Context<Self>) -> Self {
        Self {
            content: Zeroizing::new(String::new()),
            limit,
            boundaries: Rc::from([0]),
            focus: cx.focus_handle(),
            read_only: false,
            selection: 0..0,
            reversed: false,
            marked: None,
            dragging: false,
            appearance,
            layout: None,
            rejection: None,
            rejected_presentation: false,
        }
    }
    /// The coordinator alone captures replacement bytes. Never render this value.
    pub(super) fn text(&self) -> &str {
        &self.content
    }
    // An out-of-contract presentation remains coordinator-owned until an actual
    // accepted edit replaces it. Never capture an empty stand-in as a deletion.
    pub(super) fn captured_text(&self) -> Option<&str> {
        (!self.rejected_presentation).then_some(self.text())
    }
    pub(super) fn has_marked_text(&self) -> bool {
        self.marked.is_some()
    }
    pub(super) fn rejection(&self) -> Option<&'static str> {
        self.rejection
    }
    pub(super) fn set_appearance(&mut self, appearance: EditorAppearance, cx: &mut Context<Self>) {
        self.appearance = appearance;
        cx.notify();
    }
    pub(super) fn set_read_only(&mut self, value: bool, cx: &mut Context<Self>) {
        if self.read_only != value {
            self.read_only = value;
            self.dragging = false;
            cx.notify();
        }
    }
    pub(super) fn set_text(&mut self, value: String, cx: &mut Context<Self>) -> bool {
        let value = Zeroizing::new(value);
        if value.len() > self.limit {
            self.rejected_presentation = true;
            self.reject(cx);
            return false;
        }
        self.content = value;
        self.reindex();
        self.selection = self.content.len()..self.content.len();
        self.reversed = false;
        self.marked = None;
        self.layout = None;
        self.rejection = None;
        self.rejected_presentation = false;
        cx.notify();
        true
    }
    fn reject(&mut self, cx: &mut Context<Self>) {
        self.rejection = Some(if self.limit == KEY_BYTES {
            "Not inserted: API key exceeds 16 KiB. Existing input is unchanged."
        } else {
            "Not inserted: header JSON exceeds 256 KiB. Existing input is unchanged."
        });
        cx.emit(SecureInputEvent::Rejected);
        cx.notify();
    }
    fn cursor(&self) -> usize {
        if self.reversed {
            self.selection.start
        } else {
            self.selection.end
        }
    }
    fn move_to(&mut self, offset: usize, select: bool, cx: &mut Context<Self>) {
        let anchor = if select {
            if self.reversed {
                self.selection.end
            } else {
                self.selection.start
            }
        } else {
            offset
        };
        self.selection = anchor.min(offset)..anchor.max(offset);
        self.reversed = offset < anchor;
        cx.notify();
    }
    fn reindex(&mut self) {
        let mut boundaries: Vec<_> = self
            .content
            .grapheme_indices(true)
            .map(|(index, _)| index)
            .collect();
        boundaries.push(self.content.len());
        self.boundaries = boundaries.into();
    }
    fn previous(&self, offset: usize) -> usize {
        self.boundaries[self
            .boundaries
            .partition_point(|&byte| byte < offset)
            .saturating_sub(1)]
    }
    fn next(&self, offset: usize) -> usize {
        self.boundaries
            .get(self.boundaries.partition_point(|&byte| byte <= offset))
            .copied()
            .unwrap_or(self.content.len())
    }
    fn to_utf16(&self, range: Range<usize>) -> Range<usize> {
        self.content[..range.start].encode_utf16().count()
            ..self.content[..range.end].encode_utf16().count()
    }
    fn utf16_range(text: &str, range: Range<usize>) -> Option<Range<usize>> {
        if range.start > range.end {
            return None;
        }
        // A collapsed offset inside a surrogate pair stays collapsed. A nonempty
        // range covers the whole scalar rather than splitting UTF-8/surrogates.
        fn byte(text: &str, requested: usize, ceil: bool) -> usize {
            let mut units = 0;
            for (index, ch) in text.char_indices() {
                if units >= requested {
                    return index;
                }
                units += ch.len_utf16();
                if units > requested {
                    return if ceil { index + ch.len_utf8() } else { index };
                }
            }
            text.len()
        }
        Some(byte(text, range.start, false)..byte(text, range.end, !range.is_empty()))
    }
    fn replacement_range(&self, range: Option<Range<usize>>) -> Option<Range<usize>> {
        match range {
            Some(range) => Self::utf16_range(&self.content, range),
            None => Some(
                self.marked
                    .clone()
                    .unwrap_or_else(|| self.selection.clone()),
            ),
        }
    }
    fn replace(&mut self, range: Range<usize>, text: &str, cx: &mut Context<Self>) -> bool {
        if self.read_only {
            return false;
        }
        let remaining = self.content.len() - range.len();
        if text.len() > self.limit.saturating_sub(remaining) {
            self.reject(cx);
            return false;
        }
        let mut replacement = Zeroizing::new(String::with_capacity(remaining + text.len()));
        replacement.push_str(&self.content[..range.start]);
        replacement.push_str(text);
        replacement.push_str(&self.content[range.end..]);
        self.content = replacement; // Zeroize the replaced input-owned allocation.
        self.reindex();
        self.selection = range.start + text.len()..range.start + text.len();
        self.reversed = false;
        self.layout = None;
        self.rejection = None;
        self.rejected_presentation = false;
        true
    }
    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let key = &event.keystroke;
        let command =
            key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
        // Consume export/history even during composition and in disabled fields.
        if (command && matches!(key.key.as_str(), "c" | "x" | "z" | "y" | "insert"))
            || (key.modifiers.shift && key.key == "delete")
        {
            cx.stop_propagation();
            window.prevent_default();
            return;
        }
        if self.marked.is_some() {
            return;
        }
        if command && key.key == "a" {
            self.selection = 0..self.content.len();
            self.reversed = false;
            cx.notify();
        } else if (command && key.key == "v") || (key.modifiers.shift && key.key == "insert") {
            if !self.read_only
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                let text = Zeroizing::new(text);
                self.replace_text_in_range(None, &text, window, cx);
            }
        } else if command && !matches!(key.key.as_str(), "left" | "right" | "backspace" | "delete")
        {
            return;
        } else {
            let select = key.modifiers.shift;
            match key.key.as_str() {
                "left" => {
                    let offset = if command {
                        0
                    } else if !select && !self.selection.is_empty() {
                        self.selection.start
                    } else {
                        self.previous(self.cursor())
                    };
                    self.move_to(offset, select, cx);
                }
                "right" => {
                    let offset = if command {
                        self.content.len()
                    } else if !select && !self.selection.is_empty() {
                        self.selection.end
                    } else {
                        self.next(self.cursor())
                    };
                    self.move_to(offset, select, cx);
                }
                "home" => self.move_to(0, select, cx),
                "end" => self.move_to(self.content.len(), select, cx),
                "backspace" | "delete" if !self.read_only => {
                    let range = if !self.selection.is_empty() {
                        self.selection.clone()
                    } else if key.key == "backspace" {
                        (if command {
                            0
                        } else {
                            self.previous(self.cursor())
                        })..self.cursor()
                    } else {
                        self.cursor()..(if command {
                            self.content.len()
                        } else {
                            self.next(self.cursor())
                        })
                    };
                    if self.replace(range, "", cx) {
                        cx.emit(SecureInputEvent::Changed);
                        cx.notify();
                    }
                }
                "enter" | "backspace" | "delete" => {}
                _ => return,
            }
        }
        cx.stop_propagation();
        window.prevent_default();
    }
    fn mouse_index(&self, position: Point<Pixels>) -> Option<usize> {
        let layout = self.layout.as_ref()?;
        let local = layout
            .line
            .closest_index_for_x(position.x - layout.bounds.left())
            / MASK.len();
        layout
            .boundaries
            .get((layout.first + local).min(layout.boundaries.len() - 1))
            .copied()
    }
    fn mouse_down(&mut self, event: &MouseDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.read_only || self.marked.is_some() {
            return;
        }
        self.focus.focus(window);
        self.dragging = true;
        if event.click_count > 1 {
            self.selection = 0..self.content.len();
            self.reversed = false;
            cx.notify();
        } else if let Some(index) = self.mouse_index(event.position) {
            self.move_to(index, event.modifiers.shift, cx);
        }
    }
    fn mouse_move(&mut self, event: &MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.dragging
            && !self.read_only
            && self.marked.is_none()
            && let Some(index) = self.mouse_index(event.position)
        {
            self.move_to(index, true, cx);
        }
    }
}

impl EntityInputHandler for SecureInput {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        actual: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let range = Self::utf16_range(&self.content, range)?;
        let range = self.to_utf16(range);
        let masked = MASK.repeat(range.len());
        *actual = Some(range);
        Some(masked)
    }
    fn selected_text_range(
        &mut self,
        ignore_disabled: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        (!self.read_only || ignore_disabled).then(|| UTF16Selection {
            range: self.to_utf16(self.selection.clone()),
            reversed: self.reversed,
        })
    }
    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked.clone().map(|range| self.to_utf16(range))
    }
    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if self.marked.take().is_some() {
            cx.emit(SecureInputEvent::Changed);
            cx.notify();
        }
    }
    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(range) = self.replacement_range(range) else {
            return;
        };
        if self.replace(range, text, cx) {
            self.marked = None;
            cx.emit(SecureInputEvent::Changed);
            cx.notify();
        }
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(range) = self.replacement_range(range) else {
            return;
        };
        let selection = selected.and_then(|range| Self::utf16_range(text, range));
        let start = range.start;
        if self.replace(range, text, cx) {
            self.marked = (!text.is_empty()).then_some(start..start + text.len());
            if let Some(selected) = selection {
                self.selection = start + selected.start..start + selected.end;
            }
            cx.emit(SecureInputEvent::Changed);
            cx.notify();
        }
    }
    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        _: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let range = Self::utf16_range(&self.content, range)?;
        let layout = self.layout.as_ref()?;
        let column = layout
            .boundaries
            .partition_point(|&byte| byte < range.start);
        let index = column.saturating_sub(layout.first) * MASK.len();
        Some(Bounds::new(
            point(
                layout.bounds.left() + layout.line.x_for_index(index.min(layout.line.len)),
                layout.bounds.top(),
            ),
            size(px(2.), layout.bounds.size.height),
        ))
    }
    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        self.mouse_index(point)
            .map(|byte| self.to_utf16(byte..byte).start)
    }
}

impl Render for SecureInput {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let input = cx.entity();
        let paint_input = input.clone();
        let appearance = &self.appearance;
        div()
            .size_full()
            .overflow_hidden()
            .track_focus(&self.focus)
            .cursor(CursorStyle::IBeam)
            .font_family(appearance.font_family.clone())
            .text_size(px(appearance.font_size))
            .line_height(px(appearance.line_height))
            .text_color(appearance.text)
            .px(px(appearance.padding_x))
            .py(px(appearance.padding_y))
            .on_key_down(cx.listener(Self::key))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::mouse_down))
            .on_mouse_move(cx.listener(Self::mouse_move))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|view, _, _, _| view.dragging = false),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|view, _, _, _| view.dragging = false),
            )
            .child(
                canvas(
                    move |bounds, window, cx| {
                        let input = input.read(cx);
                        // Boundary-only cache is rebuilt on accepted edits, never on
                        // selection, focus, palette or ordinary repaint.
                        let boundaries = input.boundaries.clone();
                        let style = window.text_style();
                        let run = TextRun {
                            len: MASK.len(),
                            font: style.font(),
                            color: input.appearance.text,
                            background_color: None,
                            underline: None,
                            strikethrough: None,
                        };
                        let glyph = window.text_system().shape_line(
                            MASK.into(),
                            px(input.appearance.font_size),
                            std::slice::from_ref(&run),
                            None,
                        );
                        let advance = glyph.width.max(px(1.));
                        let visible = ((bounds.size.width / advance).floor() as usize)
                            .clamp(1, MAX_VISIBLE_MASKS);
                        let caret_column =
                            boundaries.partition_point(|&byte| byte < input.cursor());
                        let old_first = input.layout.as_ref().map_or(0, |layout| layout.first);
                        let first = old_first
                            .min(caret_column)
                            .max(caret_column.saturating_sub(visible.saturating_sub(1)));
                        let count = visible.min(boundaries.len() - 1 - first);
                        let masked = MASK.repeat(count);
                        let line = window.text_system().shape_line(
                            masked.clone().into(),
                            px(input.appearance.font_size),
                            &[TextRun {
                                len: masked.len(),
                                ..run
                            }],
                            None,
                        );
                        MaskedLayout {
                            line,
                            bounds,
                            boundaries,
                            first,
                        }
                    },
                    move |_, layout, window, cx| {
                        let input = paint_input.read(cx);
                        if !input.read_only {
                            window.handle_input(
                                &input.focus,
                                ElementInputHandler::new(layout.bounds, paint_input.clone()),
                                cx,
                            );
                        }
                        let x = |byte| {
                            let column = layout.boundaries.partition_point(|&index| index < byte);
                            let index = (column.saturating_sub(layout.first) * MASK.len())
                                .min(layout.line.len);
                            layout.bounds.left() + layout.line.x_for_index(index)
                        };
                        if input.focus.is_focused(window) {
                            if input.selection.is_empty() {
                                window.paint_quad(fill(
                                    Bounds::new(
                                        point(x(input.cursor()), layout.bounds.top()),
                                        size(px(1.), layout.bounds.size.height),
                                    ),
                                    input.appearance.caret,
                                ));
                            } else {
                                window.paint_quad(fill(
                                    Bounds::from_corners(
                                        point(x(input.selection.start), layout.bounds.top()),
                                        point(x(input.selection.end), layout.bounds.bottom()),
                                    ),
                                    input.appearance.selection,
                                ));
                            }
                            if let Some(marked) = &input.marked {
                                window.paint_quad(fill(
                                    Bounds::new(
                                        point(x(marked.start), layout.bounds.bottom() - px(1.)),
                                        size((x(marked.end) - x(marked.start)).max(px(1.)), px(1.)),
                                    ),
                                    input.appearance.caret,
                                ));
                            }
                        }
                        // The shaped line contains only masks, never replacement bytes.
                        let _ = layout.line.paint(
                            layout.bounds.origin,
                            px(input.appearance.line_height),
                            window,
                            cx,
                        );
                        paint_input.update(cx, |input, _| input.layout = Some(layout));
                    },
                )
                .w_full()
                .h(px(appearance.line_height)),
            )
    }
}

#[cfg(test)]
#[path = "connection_secure_input_tests.rs"]
mod tests;
