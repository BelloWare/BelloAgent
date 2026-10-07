//! Retained, variable-height transcript. Immutable presentation inputs determine
//! rows; only event callbacks access the parent. The list measures the viewport
//! and the source's max(240px, half a viewport) buffer, never the whole history.
use crate::{AgentView, Palette, layout, transcript_actions};
use bello_agent_core::{Controller, Session};
use bello_workbench_ui::{EditorAppearance, EditorView};
#[path = "transcript_read_presentation.rs"]
mod read_presentation;
#[path = "transcript_tool_presentation.rs"]
mod tool_presentation;
use gpui::{prelude::*, *};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
    sync::{Arc, Weak},
};
use tool_presentation::ProjectedRow;

#[derive(Clone)]
pub(crate) struct TranscriptInput {
    pub controller: Weak<Controller>,
    pub chat_id: String,
    pub session: Arc<Session>,
    pub visible_messages: usize,
    pub palette: Palette,
    pub pane_width: f32,
    pub loading: bool,
    pub load_failed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum RowKey {
    Loading,
    Retry,
    Earlier,
    Message(String),
    Tool {
        assistant: Box<RowKey>,
        call_id: String,
        occurrence: usize,
    },
    // A duplicate has no stable model identity. Scope its presentation key to
    // the exact immutable snapshot instead of guessing after replacement.
    Duplicate {
        id: String,
        occurrence: usize,
        generation: usize,
    },
}

struct LogicalRow {
    key: RowKey,
    message_index: Option<usize>,
    projected: Option<ProjectedRow>,
    expanded: bool,
    read_expanded: bool,
    read_key: Option<RowKey>,
}

struct Presentation {
    input: TranscriptInput,
    rows: Vec<LogicalRow>,
    hidden_messages: usize,
    #[cfg(test)]
    estimate_override: std::cell::Cell<Option<Pixels>>,
}

impl Presentation {
    fn new(input: TranscriptInput) -> Self {
        Self::with_disclosure(input, &HashSet::new(), &HashSet::new())
    }

    fn with_disclosure(
        input: TranscriptInput,
        collapsed: &HashSet<RowKey>,
        expanded_reads: &HashSet<RowKey>,
    ) -> Self {
        let hidden_messages = input
            .session
            .messages
            .len()
            .saturating_sub(input.visible_messages);
        let mut rows = Vec::with_capacity(input.session.messages.len() - hidden_messages + 2);
        if input.loading {
            rows.push(LogicalRow {
                key: RowKey::Loading,
                message_index: None,
                projected: None,
                expanded: false,
                read_expanded: false,
                read_key: None,
            });
        } else if input.load_failed {
            rows.push(LogicalRow {
                key: RowKey::Retry,
                message_index: None,
                projected: None,
                expanded: false,
                read_expanded: false,
                read_key: None,
            });
        }
        if hidden_messages > 0 {
            rows.push(LogicalRow {
                key: RowKey::Earlier,
                message_index: None,
                projected: None,
                expanded: false,
                read_expanded: false,
                read_key: None,
            });
        }
        let mut counts = HashMap::<&str, usize>::new();
        for message in &input.session.messages {
            *counts.entry(message.id.as_str()).or_default() += 1;
        }
        let mut occurrences = HashMap::<&str, usize>::new();
        // Retain keys only for this page; hidden history contributes counts,
        // never cloned message bodies, arguments, output, or per-row UI state.
        let mut message_keys = HashMap::new();
        for (index, message) in input.session.messages.iter().enumerate() {
            let occurrence = occurrences.entry(message.id.as_str()).or_default();
            if index >= hidden_messages {
                let key = if counts[message.id.as_str()] == 1 {
                    RowKey::Message(message.id.clone())
                } else {
                    RowKey::Duplicate {
                        id: message.id.clone(),
                        occurrence: *occurrence,
                        generation: Arc::as_ptr(&input.session) as usize,
                    }
                };
                message_keys.insert(index, key);
            }
            *occurrence += 1;
        }
        for projected in tool_presentation::project(&input.session, hidden_messages) {
            let source = projected.source();
            let key = match projected {
                ProjectedRow::Call {
                    assistant, call, ..
                } => {
                    let tool = tool_presentation::call_at(&input.session, assistant, call);
                    let occurrence = (0..call)
                        .filter(|&previous| {
                            tool_presentation::call_at(&input.session, assistant, previous).id
                                == tool.id
                        })
                        .count();
                    RowKey::Tool {
                        assistant: Box::new(message_keys[&source].clone()),
                        call_id: tool.id.clone(),
                        occurrence,
                    }
                }
                _ => message_keys[&source].clone(),
            };
            let expanded = !collapsed.contains(&key);
            // A read's retained result keeps its window state when Show earlier
            // replaces a standalone result with its owning call card. Ambiguous
            // result IDs remain snapshot-scoped like all other transcript keys.
            let read_key = projected.result().map(|index| message_keys[&index].clone());
            let read_expanded = read_key
                .as_ref()
                .is_some_and(|key| expanded_reads.contains(key));
            rows.push(LogicalRow {
                key,
                message_index: Some(source),
                projected: Some(projected),
                expanded,
                read_expanded,
                read_key,
            });
        }
        Self {
            input,
            rows,
            hidden_messages,
            #[cfg(test)]
            estimate_override: std::cell::Cell::new(None),
        }
    }

    fn same_row(&self, index: usize, other: &Self, other_index: usize) -> bool {
        let row = &self.rows[index];
        let other_row = &other.rows[other_index];
        if row.key != other_row.key
            || (index + 1 == self.rows.len()) != (other_index + 1 == other.rows.len())
        {
            return false;
        }
        match (row.projected, other_row.projected) {
            (Some(projected), Some(other_projected)) => {
                row.expanded == other_row.expanded
                    && row.read_expanded == other_row.read_expanded
                    && tool_presentation::same_content(
                        &self.input.session,
                        projected,
                        &other.input.session,
                        other_projected,
                    )
            }
            (None, None) => {
                row.key != RowKey::Earlier || self.hidden_messages == other.hidden_messages
            }
            _ => false,
        }
    }
}

fn tool_section_visible(
    presentation: &Presentation,
    list: &ListState,
    key: &RowKey,
    section: &str,
    index: usize,
) -> bool {
    let bounds = list.viewport_bounds();
    presentation
        .rows
        .get(index)
        .filter(|row| {
            &row.key == key
                && row.expanded
                && row.projected.is_some_and(|projected| match section {
                    "IN" => {
                        matches!(projected, ProjectedRow::Call { .. })
                            && !(read_presentation::read_call(
                                &presentation.input.session,
                                projected,
                            )
                            .is_some()
                                && projected.result().is_some_and(|index| {
                                    tool_presentation::has_display_text(
                                        &presentation.input.session.messages[index],
                                    )
                                }))
                    }
                    "OUT" => projected.result().is_some(),
                    _ => false,
                })
        })
        .and_then(|_| list.bounds_for_item(index))
        .is_some_and(|row| row.bottom() > bounds.top() && row.top() < bounds.bottom())
}

pub(crate) struct ToolFocusRestore {
    window: AnyWindowHandle,
    owner: WeakEntity<TranscriptView>,
    chat_id: String,
    controller: Weak<Controller>,
}
impl ToolFocusRestore {
    pub(crate) fn capture(
        owner: &Entity<TranscriptView>,
        previous: &FocusHandle,
        window: &Window,
        cx: &App,
    ) -> Option<Self> {
        let view = owner.read(cx);
        view.tool_editors
            .borrow()
            .entries
            .values()
            .any(|entry| &entry.editor.read(cx).focus_handle(cx) == previous)
            .then(|| Self {
                window: window.window_handle(),
                owner: owner.downgrade(),
                chat_id: view.presentation.input.chat_id.clone(),
                controller: view.presentation.input.controller.clone(),
            })
    }
    pub(crate) fn restore(
        &self,
        previous: &FocusHandle,
        current: Option<&Entity<TranscriptView>>,
        window: &mut Window,
        cx: &App,
    ) -> bool {
        let Some(owner) = self.owner.upgrade() else {
            return false;
        };
        if current.is_none_or(|current| current.entity_id() != owner.entity_id()) {
            return false;
        }
        let view = owner.read(cx);
        if window.window_handle() != self.window
            || view.presentation.input.chat_id != self.chat_id
            || !Weak::ptr_eq(&view.presentation.input.controller, &self.controller)
        {
            return false;
        }
        let visible = view
            .tool_editors
            .borrow()
            .entries
            .iter()
            .any(|((key, section), entry)| {
                &entry.editor.read(cx).focus_handle(cx) == previous
                    && tool_section_visible(
                        &view.presentation,
                        &view.viewport.borrow().list,
                        key,
                        section,
                        entry.row_index,
                    )
            });
        if visible {
            previous.focus(window);
            true
        } else {
            view.focus_fallback(window)
        }
    }
}

struct ViewportState {
    list: ListState,
    presentation: Rc<Presentation>,
    buffer: Pixels,
    heights: HashMap<RowKey, Pixels>,
    pending_scroll: Option<ListOffset>,
    painted_scroll: ListOffset,
    #[cfg(test)]
    target_preflights: Vec<usize>,
    #[cfg(test)]
    tool_height_invalidations: usize,
}

impl ViewportState {
    fn new(presentation: Rc<Presentation>) -> Self {
        let buffer = px(240.);
        Self {
            list: ListState::new(presentation.rows.len(), ListAlignment::Top, buffer),
            presentation,
            buffer,
            heights: HashMap::new(),
            pending_scroll: None,
            #[cfg(test)]
            target_preflights: Vec::new(),
            #[cfg(test)]
            tool_height_invalidations: 0,
            painted_scroll: ListOffset {
                item_ix: 0,
                offset_in_item: px(0.),
            },
        }
    }

    fn prepare(&mut self, next: Rc<Presentation>, bounds: Bounds<Pixels>) -> Option<ListOffset> {
        let buffer = px(240.).max(bounds.size.height / 2.);
        let old = &self.presentation;
        // Capture at prepaint, after any user input received since the last
        // frame. No scheduled callback can later overwrite a newer gesture.
        let offset = self.list.logical_scroll_top();
        let changed = !Rc::ptr_eq(old, &next);
        if self.list.viewport_bounds().size.width != bounds.size.width
            || old.input.pane_width != next.input.pane_width
            || old.input.palette != next.input.palette
        {
            self.heights.clear();
            self.pending_scroll = None;
        } else if changed {
            #[cfg(test)]
            let previous_tool_heights = self
                .heights
                .keys()
                .filter(|key| matches!(key, RowKey::Tool { .. }))
                .count();
            let old_indexes: HashMap<_, _> = old
                .rows
                .iter()
                .enumerate()
                .map(|(index, row)| (&row.key, index))
                .collect();
            self.heights = next
                .rows
                .iter()
                .enumerate()
                .filter_map(|(index, row)| {
                    let old_index = *old_indexes.get(&row.key)?;
                    old.same_row(old_index, &next, index)
                        .then(|| self.heights.get(&row.key).copied())
                        .flatten()
                        .map(|height| (row.key.clone(), height))
                })
                .collect();
            #[cfg(test)]
            {
                self.tool_height_invalidations += previous_tool_heights
                    - self
                        .heights
                        .keys()
                        .filter(|key| matches!(key, RowKey::Tool { .. }))
                        .count();
            }
        }
        let anchor = if changed {
            self.pending_scroll = None;
            self.painted_scroll = translated_anchor(old, &next, self.painted_scroll);
            translated_anchor(old, &next, offset)
        } else {
            offset
        };
        // A surviving row may no longer contain the old pixel after text or
        // width reflow. Only that row needs an exact preflight measurement;
        // viewport-height / buffer changes alone cannot change its height.
        let remeasure_anchor = anchor.offset_in_item > px(0.)
            && anchor.item_ix < next.rows.len()
            && (self.list.viewport_bounds().size.width != bounds.size.width
                || old.input.pane_width != next.input.pane_width
                || old.input.palette != next.input.palette
                || (changed
                    && old
                        .rows
                        .get(offset.item_ix)
                        .is_none_or(|_| !old.same_row(offset.item_ix, &next, anchor.item_ix))));
        if buffer != self.buffer {
            // GPUI 0.2.2 has no overdraw setter. Replace only when geometry
            // changes the actual buffer, and transfer the live logical offset.
            self.list = ListState::new(next.rows.len(), ListAlignment::Top, buffer);
            self.list.scroll_to(anchor);
            self.buffer = buffer;
        } else if changed {
            if old.input.pane_width != next.input.pane_width
                || old.input.palette != next.input.palette
            {
                self.list.splice(0..old.rows.len(), next.rows.len());
            } else {
                let mut prefix = 0;
                while prefix < old.rows.len().min(next.rows.len())
                    && old.same_row(prefix, &next, prefix)
                {
                    prefix += 1;
                }
                let mut old_end = old.rows.len();
                let mut next_end = next.rows.len();
                while old_end > prefix
                    && next_end > prefix
                    && old.same_row(old_end - 1, &next, next_end - 1)
                {
                    old_end -= 1;
                    next_end -= 1;
                }
                if old_end != prefix || next_end != prefix {
                    self.list.splice(prefix..old_end, next_end - prefix);
                }
            }
            // splice intentionally discards within-row offset for replaced
            // items. Restore identity and the pixel offset, even for a same-ID
            // streaming edit. Never use reset: it drops pending scroll events.
            self.list.scroll_to(anchor);
        }
        self.presentation = next;
        remeasure_anchor.then_some(anchor)
    }
}

// Like TranscriptRowEstimate.swift, unseen rows have a nonzero navigation
// estimate, never a view tree. Plain-message estimates mirror their text sizes,
// wrapping width and chrome; tool cards use their bounded section caps without
// copying retained payloads. Exact List measurements replace these guesses.
fn estimated_height(presentation: &Presentation, index: usize, width: Pixels) -> Pixels {
    #[cfg(test)]
    if let Some(height) = presentation.estimate_override.get() {
        return height;
    }
    let gap = if index + 1 < presentation.rows.len() {
        16.
    } else {
        0.
    };
    let row = &presentation.rows[index];
    let Some(source_index) = row.message_index else {
        return px(gap
            + match row.key {
                RowKey::Loading => 69.,
                _ => 29.25,
            });
    };
    let message = &presentation.input.session.messages[source_index];
    if matches!(
        row.projected,
        Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
    ) {
        return px(gap
            + if row.expanded {
                80. + tool_presentation::SECTION_CAP * 2.
            } else {
                56.
            });
    }
    let user = message.role == "user";
    let width = f32::from(width);
    let body_width = if user {
        layout::user_bubble_width(presentation.input.pane_width).min(width - 88.) - 28.
    } else {
        (width - 48.).min(640.)
    }
    .max(1.);
    let plain = |text: &str, font: f32, line_height: f32| {
        let columns = (body_width / (font * 0.52)).max(20.);
        text.split('\n')
            .map(|line| (line.chars().count() as f32 / columns).ceil().max(1.))
            .sum::<f32>()
            * line_height
    };
    let text = if message.text.is_empty() && message.state == "streaming" {
        "Generating response…"
    } else {
        &message.text
    };
    let mut height =
        12. + 6. + transcript_actions::ACTION_BAND_HEIGHT + gap + plain(text, 14.5, 21.);
    if user {
        height += 18.;
    }
    if !message.reasoning.is_empty() {
        height += 6. + plain(&message.reasoning, 12., 18.);
    }
    if message.state == "interrupted" {
        height += 6. + 17.25;
    }
    px(height)
}

// Preserve the original vertical-only Div scroller's native input semantics:
// lines use inherited typography, horizontal-only input maps onto its scroll
// axis, and every event contributes (including reversals and mixed units).
pub(crate) fn vertical_wheel_distance(delta: ScrollDelta, line_height: Pixels) -> Pixels {
    let pixels = delta.pixel_delta(line_height);
    if pixels.y != px(0.) {
        -pixels.y
    } else {
        -pixels.x
    }
}

fn wheel_anchor(
    presentation: &Presentation,
    heights: &HashMap<RowKey, Pixels>,
    width: Pixels,
    mut anchor: ListOffset,
    distance: Pixels,
) -> ListOffset {
    if presentation.rows.is_empty() {
        return ListOffset {
            item_ix: 0,
            offset_in_item: px(0.),
        };
    }
    let height = |index: usize, heights: &HashMap<RowKey, Pixels>| {
        heights
            .get(&presentation.rows[index].key)
            .copied()
            .unwrap_or_else(|| estimated_height(presentation, index, width))
    };
    anchor.item_ix = anchor.item_ix.min(presentation.rows.len() - 1);
    anchor.offset_in_item += distance;
    while anchor.offset_in_item < px(0.) && anchor.item_ix > 0 {
        anchor.item_ix -= 1;
        anchor.offset_in_item += height(anchor.item_ix, heights);
    }
    anchor.offset_in_item = anchor.offset_in_item.max(px(0.));
    while anchor.item_ix + 1 < presentation.rows.len() {
        let height = height(anchor.item_ix, heights);
        if anchor.offset_in_item < height {
            break;
        }
        anchor.offset_in_item -= height;
        anchor.item_ix += 1;
    }
    // List's final layout still applies the actual bottom-of-document clamp.
    anchor.offset_in_item = anchor.offset_in_item.min(height(anchor.item_ix, heights));
    anchor
}

fn translated_anchor(old: &Presentation, next: &Presentation, offset: ListOffset) -> ListOffset {
    let Some(row) = old.rows.get(offset.item_ix) else {
        return ListOffset {
            item_ix: offset.item_ix.min(next.rows.len()),
            offset_in_item: px(0.),
        };
    };
    if let Some(item_ix) = next
        .rows
        .iter()
        .position(|candidate| candidate.key == row.key)
    {
        return ListOffset {
            item_ix,
            offset_in_item: offset.offset_in_item,
        };
    }
    // Revealing an owner replaces a standalone result with its paired card.
    // Preserve that result's anchor instead of jumping to a neighbour.
    if let Some(result) = row.projected.and_then(ProjectedRow::result) {
        let id = &old.input.session.messages[result].id;
        if let Some(item_ix) = next.rows.iter().position(|candidate| {
            candidate
                .projected
                .and_then(ProjectedRow::result)
                .is_some_and(|result| &next.input.session.messages[result].id == id)
        }) {
            return ListOffset {
                item_ix,
                offset_in_item: offset.offset_in_item,
            };
        }
    }
    // Finishing Show earlier removes the header. Preserve that control's
    // top-of-history position, showing the newly revealed first row. A user
    // who has already wheeled into a message takes the identity branch above.
    if row.key == RowKey::Earlier {
        return ListOffset {
            item_ix: 0,
            offset_in_item: px(0.),
        };
    }
    let next_indexes: HashMap<_, _> = next
        .rows
        .iter()
        .enumerate()
        .map(|(index, row)| (&row.key, index))
        .collect();
    // A deleted/ambiguous anchor falls forward to a surviving neighbour, then
    // backward if no successor survives. Its old within-row offset has no
    // meaning in another row. Duplicate keys do not survive a new snapshot.
    for candidate in old
        .rows
        .iter()
        .skip(offset.item_ix + 1)
        .chain(old.rows[..offset.item_ix].iter().rev())
    {
        if let Some(&item_ix) = next_indexes.get(&candidate.key) {
            return ListOffset {
                item_ix,
                offset_in_item: px(0.),
            };
        }
    }
    ListOffset {
        item_ix: 0,
        offset_in_item: px(0.),
    }
}

#[cfg(test)]
#[derive(Default)]
struct Materialized {
    indexes: Vec<usize>,
    painted_indexes: Vec<usize>,
    texts: Vec<(usize, String)>,
}

pub(crate) struct TranscriptView {
    parent: WeakEntity<AgentView>,
    presentation: Rc<Presentation>,
    viewport: Rc<RefCell<ViewportState>>,
    collapsed: HashSet<RowKey>,
    expanded_reads: HashSet<RowKey>,
    tool_editors: Rc<RefCell<ToolEditors>>,
    focus: Option<FocusHandle>,
    removed_tool_focus: Rc<RefCell<Vec<FocusHandle>>>,
    #[cfg(test)]
    materialized: Rc<RefCell<Materialized>>,
    #[cfg(test)]
    render_count: usize,
}

impl TranscriptView {
    pub(crate) fn new(parent: WeakEntity<AgentView>, input: TranscriptInput) -> Self {
        let presentation = Rc::new(Presentation::new(input));
        Self {
            parent,
            collapsed: HashSet::new(),
            expanded_reads: HashSet::new(),
            tool_editors: Rc::new(RefCell::new(ToolEditors::default())),
            focus: None,
            removed_tool_focus: Rc::new(RefCell::new(Vec::new())),
            viewport: Rc::new(RefCell::new(ViewportState::new(presentation.clone()))),
            presentation,
            #[cfg(test)]
            materialized: Rc::new(RefCell::new(Materialized::default())),
            #[cfg(test)]
            render_count: 0,
        }
    }

    pub(crate) fn update_inputs(&mut self, input: TranscriptInput, cx: &mut Context<Self>) {
        let old = &self.presentation.input;
        if Weak::ptr_eq(&old.controller, &input.controller)
            && old.chat_id == input.chat_id
            && Arc::ptr_eq(&old.session, &input.session)
            && old.visible_messages == input.visible_messages
            && old.palette == input.palette
            && old.pane_width == input.pane_width
            && old.loading == input.loading
            && old.load_failed == input.load_failed
        {
            return;
        }
        if old.chat_id != input.chat_id || !Weak::ptr_eq(&old.controller, &input.controller) {
            self.collapsed.clear();
            self.expanded_reads.clear();
            self.removed_tool_focus.borrow_mut().extend(
                self.tool_editors
                    .borrow()
                    .entries
                    .values()
                    .map(|entry| entry.editor.read(cx).focus_handle(cx)),
            );
            self.tool_editors.borrow_mut().entries.clear();
        }
        self.presentation = Rc::new(Presentation::with_disclosure(
            input,
            &self.collapsed,
            &self.expanded_reads,
        ));
        let keys: HashSet<_> = self.presentation.rows.iter().map(|row| &row.key).collect();
        self.collapsed.retain(|key| keys.contains(key));
        let read_keys: HashSet<_> = self
            .presentation
            .rows
            .iter()
            .filter_map(|row| row.read_key.as_ref())
            .collect();
        self.expanded_reads.retain(|key| read_keys.contains(key));
        self.tool_editors
            .borrow_mut()
            .entries
            .retain(|(key, _), entry| {
                let keep = keys.contains(key);
                if !keep {
                    self.removed_tool_focus
                        .borrow_mut()
                        .push(entry.editor.read(cx).focus_handle(cx));
                }
                keep
            });
        cx.notify();
    }

    fn toggle_tool(
        &mut self,
        key: RowKey,
        chat_id: &str,
        controller: &Weak<Controller>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.presentation.input.chat_id != chat_id
            || !Weak::ptr_eq(&self.presentation.input.controller, controller)
            || !self.presentation.rows.iter().any(|row| {
                row.key == key
                    && matches!(
                        row.projected,
                        Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
                    )
            })
        {
            return;
        }
        if !self.collapsed.contains(&key)
            && self
                .tool_editors
                .borrow()
                .entries
                .iter()
                .any(|((row, _), entry)| {
                    row == &key && entry.editor.read(cx).focus_handle(cx).is_focused(window)
                })
            && let Some(focus) = &self.focus
        {
            // Hiding the focused read-only payload must leave a visible owner.
            // Keep its editor/selection cached without routing keys to it.
            focus.focus(window);
        }
        if !self.collapsed.remove(&key) {
            self.collapsed.insert(key);
        }
        self.presentation = Rc::new(Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.collapsed,
            &self.expanded_reads,
        ));
        cx.notify();
    }

    fn toggle_read(
        &mut self,
        key: RowKey,
        chat_id: &str,
        controller: &Weak<Controller>,
        cx: &mut Context<Self>,
    ) {
        if self.presentation.input.chat_id != chat_id
            || !Weak::ptr_eq(&self.presentation.input.controller, controller)
            || !self.presentation.rows.iter().any(|row| {
                row.key == key
                    && row.expanded
                    && row.projected.is_some_and(|projected| {
                        let Some(call) = read_presentation::read_call(
                            &self.presentation.input.session,
                            projected,
                        ) else {
                            return false;
                        };
                        projected.result().is_some_and(|index| {
                            read_presentation::ReadWindow::new(
                                &tool_presentation::display_text(
                                    &self.presentation.input.session.messages[index],
                                ),
                                &call.arguments,
                            )
                            .collapsible()
                        })
                    })
            })
        {
            return;
        }
        let read_key = self
            .presentation
            .rows
            .iter()
            .find(|row| row.key == key)
            .and_then(|row| row.read_key.clone())
            .expect("validated read result");
        if !self.expanded_reads.remove(&read_key) {
            self.expanded_reads.insert(read_key);
        }
        self.presentation = Rc::new(Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.collapsed,
            &self.expanded_reads,
        ));
        cx.notify();
    }

    fn open_read_file(
        &mut self,
        key: &RowKey,
        chat_id: &str,
        controller: &Weak<Controller>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.presentation.input.chat_id != chat_id
            || !Weak::ptr_eq(&self.presentation.input.controller, controller)
        {
            return;
        }
        // Resolve from the current row, never a captured old result's path.
        let Some(link) = self
            .presentation
            .rows
            .iter()
            .find(|row| &row.key == key && row.expanded)
            .and_then(|row| {
                read_presentation::file_link(&self.presentation.input.session, row.projected?)
            })
        else {
            return;
        };
        // A newer root snapshot can precede the child's next frame. Do not
        // follow a removed/replaced result even when chat/controller match.
        let source = self.presentation.input.session.clone();
        let _ = self.parent.update(cx, |view, cx| {
            if view.active_transcript_matches(chat_id, controller)
                && Arc::ptr_eq(&view.session, &source)
            {
                let path = std::path::PathBuf::from(&link.path);
                let path = if path.is_absolute() {
                    path
                } else {
                    view.project.join(path)
                };
                view.open_file(
                    path,
                    link.lines.as_ref().map(|lines| *lines.start()),
                    window,
                    cx,
                );
            }
        });
    }

    /// Capture exact owners before controller replacement drops this subtree.
    /// The bounded handles remain testable after its dispatch nodes disappear.
    pub(crate) fn owned_focus_handles(&self, cx: &App) -> Vec<FocusHandle> {
        self.focus
            .iter()
            .cloned()
            .chain(
                self.tool_editors
                    .borrow()
                    .entries
                    .values()
                    .map(|entry| entry.editor.read(cx).focus_handle(cx)),
            )
            .collect()
    }

    pub(crate) fn focus_fallback(&self, window: &mut Window) -> bool {
        if let Some(focus) = &self.focus {
            focus.focus(window);
            true
        } else {
            false
        }
    }

    #[cfg(test)]
    pub(crate) fn tool_height_invalidation_count(&self) -> usize {
        self.viewport.borrow().tool_height_invalidations
    }

    #[cfg(test)]
    pub(crate) fn retained_tool_editor_count(&self) -> usize {
        self.tool_editors.borrow().entries.len()
    }

    #[cfg(test)]
    pub(crate) fn tool_card_selectors(&self) -> Vec<String> {
        self.presentation
            .rows
            .iter()
            .filter(|row| {
                matches!(
                    row.projected,
                    Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
                )
            })
            .map(|row| format!("transcript-tool-{:?}", row.key))
            .collect()
    }
    #[cfg(test)]
    pub(crate) fn tool_section_editors(&self) -> Vec<(&'static str, Entity<EditorView>)> {
        self.tool_editors
            .borrow()
            .entries
            .iter()
            .map(|((_, label), entry)| (*label, entry.editor.clone()))
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn override_navigation_estimate(&self, height: Pixels) {
        self.presentation.estimate_override.set(Some(height));
    }
    #[cfg(test)]
    pub(crate) fn has_pending_navigation(&self) -> bool {
        self.viewport.borrow().pending_scroll.is_some()
    }
    #[cfg(test)]
    pub(crate) fn target_preflight_counts(&self) -> Vec<usize> {
        self.viewport.borrow().target_preflights.clone()
    }
    #[cfg(test)]
    pub(crate) fn render_count(&self) -> usize {
        self.render_count
    }
    #[cfg(test)]
    pub(crate) fn list_state(&self) -> ListState {
        self.viewport.borrow().list.clone()
    }
    #[cfg(test)]
    pub(crate) fn buffer_margin(&self) -> Pixels {
        self.viewport.borrow().buffer
    }
    #[cfg(test)]
    pub(crate) fn materialized_indexes(&self) -> Vec<usize> {
        self.materialized.borrow().indexes.clone()
    }
    #[cfg(test)]
    pub(crate) fn painted_indexes(&self) -> Vec<usize> {
        self.materialized.borrow().painted_indexes.clone()
    }
    #[cfg(test)]
    pub(crate) fn materialized_texts(&self) -> Vec<(usize, String)> {
        self.materialized.borrow().texts.clone()
    }
    #[cfg(test)]
    pub(crate) fn logical_row_ids(&self) -> Vec<String> {
        self.viewport
            .borrow()
            .presentation
            .rows
            .iter()
            .map(|row| match &row.key {
                RowKey::Loading => "@loading".into(),
                RowKey::Retry => "@retry".into(),
                RowKey::Earlier => "@earlier".into(),
                RowKey::Message(id) => id.clone(),
                RowKey::Tool {
                    assistant,
                    call_id,
                    occurrence,
                } => format!("@tool:{assistant:?}:{call_id}:{occurrence}"),
                RowKey::Duplicate { id, occurrence, .. } => format!("{id}#{occurrence}"),
            })
            .collect()
    }
}

// A list with Auto sizing does not render items in request_layout. This tiny
// adapter can therefore select the correct overdraw from actual prepaint bounds
// before any row is measured, in the same frame and without entity updates.
struct ViewportList {
    focus: FocusHandle,
    removed_tool_focus: Rc<RefCell<Vec<FocusHandle>>>,
    viewport: Rc<RefCell<ViewportState>>,
    presentation: Rc<Presentation>,
    parent: WeakEntity<AgentView>,
    child: WeakEntity<TranscriptView>,
    tool_editors: Rc<RefCell<ToolEditors>>,
    list: List,
    #[cfg(test)]
    materialized: Rc<RefCell<Materialized>>,
}

impl ViewportList {
    fn build_list(&self, width: Pixels) -> List {
        let state = self.viewport.borrow().list.clone();
        let presentation = self.presentation.clone();
        let parent = self.parent.clone();
        let viewport = self.viewport.clone();
        let child = self.child.clone();
        let tool_editors = self.tool_editors.clone();
        #[cfg(test)]
        let materialized = self.materialized.clone();
        list(state, move |index, window, cx| {
            let mut row = materialize_row(
                &presentation,
                index,
                RowRenderContext {
                    parent: &parent,
                    child: &child,
                    tool_editors: &tool_editors,
                },
                width,
                window,
                cx,
                #[cfg(test)]
                &materialized,
            );
            // List immediately measures with these identical constraints. GPUI
            // reuses LayoutComputed, so this captures *all* exact row heights,
            // including leading overdraw, without a second layout or tree.
            let measured = row.layout_as_root(
                size(AvailableSpace::Definite(width), AvailableSpace::MinContent),
                window,
                cx,
            );
            viewport
                .borrow_mut()
                .heights
                .insert(presentation.rows[index].key.clone(), measured.height);
            row
        })
        .w_full()
        .h_full()
        .min_h_0()
        .pb(px(13.))
    }
}

#[derive(Clone, Copy)]
struct RowRenderContext<'a> {
    parent: &'a WeakEntity<AgentView>,
    child: &'a WeakEntity<TranscriptView>,
    tool_editors: &'a Rc<RefCell<ToolEditors>>,
}

// Both List's normal renderer and the single-row clamp preflight use this
// constructor, so bounded-work instrumentation includes every row tree.
fn materialize_row(
    presentation: &Presentation,
    index: usize,
    context: RowRenderContext<'_>,
    width: Pixels,
    window: &mut Window,
    cx: &mut App,
    #[cfg(test)] materialized: &Rc<RefCell<Materialized>>,
) -> AnyElement {
    #[cfg(test)]
    {
        let mut materialized = materialized.borrow_mut();
        materialized.indexes.push(index);
        if let Some(source_index) = presentation.rows[index].message_index {
            materialized.texts.push((
                index,
                presentation.input.session.messages[source_index]
                    .text
                    .clone(),
            ));
        }
    }
    let row = render_row(presentation, index, context, width, window, cx);
    #[cfg(test)]
    let row = {
        let materialized = materialized.clone();
        row.child(
            canvas(
                |_, _, _| (),
                move |_, _, _, _| {
                    materialized.borrow_mut().painted_indexes.push(index);
                },
            )
            .absolute()
            .inset_0(),
        )
    };
    row.into_any_element()
}

impl IntoElement for ViewportList {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for ViewportList {
    type RequestLayoutState = ();
    type PrepaintState = (ListPrepaintState, Hitbox);
    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        self.list.request_layout(id, inspector_id, window, cx)
    }
    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);
        #[cfg(test)]
        {
            *self.materialized.borrow_mut() = Materialized::default();
        }
        let anchor = self
            .viewport
            .borrow_mut()
            .prepare(self.presentation.clone(), bounds);
        if let Some(mut anchor) = anchor {
            let mut row = materialize_row(
                &self.presentation,
                anchor.item_ix,
                RowRenderContext {
                    parent: &self.parent,
                    child: &self.child,
                    tool_editors: &self.tool_editors,
                },
                bounds.size.width,
                window,
                cx,
                #[cfg(test)]
                &self.materialized,
            );
            // Match List::layout_items exactly: full list width, including
            // row-owned gutters, and intrinsic variable height. No parent
            // reads or delayed placement can race a later user gesture.
            let measured = row.layout_as_root(
                size(
                    AvailableSpace::Definite(bounds.size.width),
                    AvailableSpace::MinContent,
                ),
                window,
                cx,
            );
            self.viewport.borrow_mut().heights.insert(
                self.presentation.rows[anchor.item_ix].key.clone(),
                measured.height,
            );
            if anchor.offset_in_item >= measured.height {
                anchor.offset_in_item = (measured.height - px(1.)).max(px(0.));
                self.viewport.borrow().list.scroll_to(anchor);
            }
        }
        // At most two unseen target preflights in one frame. Adversarial
        // overestimates retain their residual target for the next frame while
        // the last canonical viewport remains interactive. A new gesture or
        // presentation/geometry change supersedes that pending work.
        let mut target = {
            let viewport = self.viewport.borrow();
            viewport
                .pending_scroll
                .unwrap_or_else(|| viewport.list.logical_scroll_top())
        };
        // A deferred target may have become measured by the fallback viewport.
        // Normalize against those newly exact heights before spending a preflight.
        target = wheel_anchor(
            &self.presentation,
            &self.viewport.borrow().heights,
            bounds.size.width,
            target,
            px(0.),
        );
        let mut complete = false;
        #[cfg(test)]
        let mut target_preflights = 0;
        for _ in 0..2 {
            if target.offset_in_item <= px(0.)
                || target.item_ix >= self.presentation.rows.len()
                || self
                    .viewport
                    .borrow()
                    .heights
                    .contains_key(&self.presentation.rows[target.item_ix].key)
            {
                complete = true;
                break;
            }
            #[cfg(test)]
            {
                target_preflights += 1;
            }
            let mut row = materialize_row(
                &self.presentation,
                target.item_ix,
                RowRenderContext {
                    parent: &self.parent,
                    child: &self.child,
                    tool_editors: &self.tool_editors,
                },
                bounds.size.width,
                window,
                cx,
                #[cfg(test)]
                &self.materialized,
            );
            let measured = row.layout_as_root(
                size(
                    AvailableSpace::Definite(bounds.size.width),
                    AvailableSpace::MinContent,
                ),
                window,
                cx,
            );
            let mut viewport = self.viewport.borrow_mut();
            viewport.heights.insert(
                self.presentation.rows[target.item_ix].key.clone(),
                measured.height,
            );
            if target.offset_in_item < measured.height
                || target.item_ix + 1 == self.presentation.rows.len()
            {
                complete = true;
                break;
            }
            target = wheel_anchor(
                &self.presentation,
                &viewport.heights,
                bounds.size.width,
                target,
                px(0.),
            );
        }
        {
            let mut viewport = self.viewport.borrow_mut();
            if complete
                || target.offset_in_item <= px(0.)
                || self
                    .presentation
                    .rows
                    .get(target.item_ix)
                    .is_none_or(|row| viewport.heights.contains_key(&row.key))
            {
                viewport.pending_scroll = None;
                viewport.list.scroll_to(target);
            } else {
                viewport.pending_scroll = Some(target);
                viewport.list.scroll_to(viewport.painted_scroll);
                // A notification during this prepaint is absorbed by the
                // current draw. This schedules only invalidation on the next
                // animation frame, never restoration of an old position.
                window.request_animation_frame();
            }
        }
        #[cfg(test)]
        self.viewport
            .borrow_mut()
            .target_preflights
            .push(target_preflights);
        self.list = self.build_list(bounds.size.width);
        let prepaint = self
            .list
            .prepaint(id, inspector_id, bounds, state, window, cx);
        let mut viewport = self.viewport.borrow_mut();
        viewport.painted_scroll = viewport.list.logical_scroll_top();
        (prepaint, hitbox)
    }
    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut (),
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let list = self.viewport.borrow().list.clone();
        let origin = list.logical_scroll_top();
        let presentation = self.presentation.clone();
        let viewport = self.viewport.clone();
        let hitbox = prepaint.1.clone();
        let current_view = window.current_view();
        let line_height = window.line_height();
        let mut distance = px(0.);
        // Bubble handlers run in reverse paint-registration order. Keep List's
        // handler (and row/ancestor propagation) intact, then correct its
        // measured-only extent clamp with a logical measured/estimated anchor.
        // Unlike List's hardcoded20px/coalescing, preserve the original Div's
        // inherited line height and sum every delta from this painted origin.
        window.on_mouse_event(move |event: &ScrollWheelEvent, phase, window, cx| {
            if phase == DispatchPhase::Bubble && hitbox.should_handle_scroll(window) {
                distance += vertical_wheel_distance(event.delta, line_height);
                let anchor = wheel_anchor(
                    &presentation,
                    &viewport.borrow().heights,
                    bounds.size.width,
                    origin,
                    distance,
                );
                viewport.borrow_mut().pending_scroll = Some(anchor);
                list.scroll_to(anchor);
                cx.notify(current_view);
            }
        });
        self.list
            .paint(id, inspector_id, bounds, state, &mut prepaint.0, window, cx);
        let removed_focused = self
            .removed_tool_focus
            .borrow_mut()
            .drain(..)
            .any(|focus| focus.is_focused(window));
        let focused_row = self
            .tool_editors
            .borrow()
            .entries
            .iter()
            .find(|(_, entry)| entry.editor.read(cx).focus_handle(cx).is_focused(window))
            .map(|((key, section), entry)| (key.clone(), *section, entry.row_index));
        let hidden_focused = focused_row.is_some_and(|(key, section, index)| {
            !tool_section_visible(
                &self.presentation,
                &self.viewport.borrow().list,
                &key,
                section,
                index,
            )
        });
        if removed_focused || hidden_focused {
            // This component's cached read-only editor left the rendered page.
            // A visible noneditable owner keeps parent shortcuts routable.
            self.focus.focus(window);
        }
    }
}

impl Render for TranscriptView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focus = self.focus.get_or_insert_with(|| cx.focus_handle()).clone();
        #[cfg(test)]
        {
            self.render_count += 1;
        }
        let element = ViewportList {
            focus: focus.clone(),
            removed_tool_focus: self.removed_tool_focus.clone(),
            viewport: self.viewport.clone(),
            presentation: self.presentation.clone(),
            parent: self.parent.clone(),
            child: cx.entity().downgrade(),
            tool_editors: self.tool_editors.clone(),
            // request_layout only needs these invariant sizing styles.
            list: list(self.viewport.borrow().list.clone(), |_, _, _| {
                div().into_any_element()
            })
            .w_full()
            .h_full()
            .min_h_0()
            .pb(px(13.)),
            #[cfg(test)]
            materialized: self.materialized.clone(),
        };
        div()
            .id("transcript")
            .track_focus(&focus)
            .on_any_mouse_down(|_, window, _| window.prevent_default())
            .debug_selector(|| "queue-measured-transcript".into())
            .w_full()
            .h_full()
            .min_h_0()
            .flex()
            .flex_col()
            .child(element)
    }
}

// Same tokens as AgentView::button, without reading the parent entity.
fn button(p: Palette, id: impl Into<ElementId>, label: impl Into<SharedString>) -> Stateful<Div> {
    div()
        .id(id)
        .px(px(10.))
        .py(px(5.))
        .rounded(px(8.))
        .border_1()
        .border_color(p.hairline())
        .bg(rgb(p.surface))
        .text_size(px(11.5))
        .text_color(rgb(p.secondary))
        .cursor_pointer()
        .hover(move |d| d.bg(p.fill()))
        .child(label.into())
}

fn render_row(
    presentation: &Presentation,
    index: usize,
    context: RowRenderContext<'_>,
    width: Pixels,
    window: &mut Window,
    cx: &mut App,
) -> Div {
    let RowRenderContext {
        parent,
        child,
        tool_editors,
    } = context;
    let input = &presentation.input;
    let row = &presentation.rows[index];
    let p = input.palette;
    let content = if matches!(
        row.projected,
        Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
    ) {
        render_tool_card(presentation, index, child, tool_editors, width, window, cx)
            .into_any_element()
    } else {
        match &row.key {
            RowKey::Loading => div()
                .py(px(24.))
                .text_color(rgb(p.secondary))
                .child("Preparing…")
                .into_any_element(),
            RowKey::Retry => {
                let parent = parent.clone();
                let controller = input.controller.clone();
                let chat_id = input.chat_id.clone();
                button(p, "retry-chat-load", "Retry opening chat")
                    .on_click(move |_, _, cx| {
                        let _ = parent.update(cx, |view, cx| {
                            if view.active_transcript_matches(&chat_id, &controller) {
                                view.load_chat(&chat_id, cx);
                            }
                        });
                    })
                    .into_any_element()
            }
            RowKey::Earlier => {
                let parent = parent.clone();
                let controller = input.controller.clone();
                let chat_id = input.chat_id.clone();
                button(
                    p,
                    "earlier",
                    format!("Show earlier messages ({})", presentation.hidden_messages),
                )
                .on_click(move |_, _, cx| {
                    let _ = parent.update(cx, |view, cx| {
                        if view.active_transcript_matches(&chat_id, &controller) {
                            view.visible_messages = view.visible_messages.saturating_add(100);
                            cx.notify();
                        }
                    });
                })
                .into_any_element()
            }
            RowKey::Tool { .. } => unreachable!("tool card rendered above"),
            RowKey::Message(_) | RowKey::Duplicate { .. } => {
                let source_index = row.message_index.expect("message row");
                let message = &input.session.messages[source_index];
                let ambiguous = matches!(row.key, RowKey::Duplicate { .. });
                let selector = if ambiguous {
                    format!("transcript-row-{}-duplicate-{source_index}", message.id)
                } else {
                    format!("transcript-row-{}", message.id)
                };
                let user = message.role == "user";
                let mut body = div()
                    .min_w_0()
                    .when(!user, |d| d.w_full())
                    .max_w(px(640.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .when(user, |d| {
                        d.w(px(layout::user_bubble_width(input.pane_width)))
                            .px(px(14.))
                            .py(px(9.))
                            .rounded(px(14.))
                            .bg(rgb(p.user))
                    });
                if !message.reasoning.is_empty() {
                    body = body.child(
                        div()
                            .text_size(px(12.))
                            .text_color(rgb(p.secondary))
                            .child(message.reasoning.clone()),
                    );
                }
                body = body.child(
                    div()
                        .debug_selector(|| {
                            if ambiguous {
                                format!("transcript-text-{}-duplicate-{source_index}", message.id)
                            } else {
                                format!("transcript-text-{}", message.id)
                            }
                        })
                        .min_w_0()
                        .max_w_full()
                        .text_size(px(14.5))
                        .line_height(px(21.))
                        .child(if message.text.is_empty() && message.state == "streaming" {
                            "Generating response…".into()
                        } else {
                            message.text.clone()
                        }),
                );
                if message.state == "interrupted" {
                    body = body.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.secondary))
                            .child("Interrupted"),
                    );
                }
                let key =
                    transcript_actions::MessageKey::new(input.chat_id.clone(), message.id.clone());
                let group = if ambiguous {
                    SharedString::from(format!(
                        "transcript-duplicate-{}-{source_index}",
                        input.chat_id
                    ))
                } else {
                    key.hover_group()
                };
                let actions = if ambiguous {
                    // Legacy snapshots can contain repeated IDs. Keep all their text
                    // and geometry, but never offer an action with ambiguous identity.
                    div()
                        .w_full()
                        .h(px(transcript_actions::ACTION_BAND_HEIGHT))
                        .flex_shrink_0()
                } else {
                    transcript_actions::transcript_copy_band(
                        key,
                        p,
                        parent.clone(),
                        input.controller.clone(),
                    )
                };
                div()
                    .group(group)
                    .debug_selector(|| selector)
                    // Keep the message content-sized, ending at its action band.
                    .w_full()
                    .max_w(px(840.))
                    .mx_auto()
                    .min_w_0()
                    .flex_shrink_0()
                    .pt(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .w_full()
                            .min_w_0()
                            .flex()
                            .when(user, |d| d.justify_end().pl(px(40.)))
                            .child(body),
                    )
                    .child(actions)
                    .into_any_element()
            }
        }
    };
    // List's padding does not subtract horizontal space from its child layout;
    // put the original gutters on rows, and count each gap in that row's height.
    // The message's own bounds still finish at the bottom of its Copy band.
    div()
        .w_full()
        .px(px(24.))
        .when(index + 1 < presentation.rows.len(), |row| row.pb(px(16.)))
        .flex()
        .flex_col()
        .child(content)
}

// Only materialized, expanded sections acquire editors. Stable bounded entries
// retain selection and scroll across unrelated snapshots and streaming frames.
const TOOL_EDITOR_LIMIT: usize = 64;
#[derive(Default)]
struct ToolEditors {
    entries: HashMap<(RowKey, &'static str), ToolEditor>,
    tick: u64,
}
struct ToolEditor {
    row_index: usize,
    editor: Entity<EditorView>,
    style: ToolEditorStyle,
    used: u64,
}
#[derive(Clone, Copy, PartialEq)]
struct ToolEditorStyle {
    palette: Palette,
    failed: bool,
}
impl ToolEditors {
    fn section(
        &mut self,
        key: (usize, RowKey, &'static str),
        preview: &str,
        style: ToolEditorStyle,
        width: f32,
        window: &mut Window,
        cx: &mut App,
    ) -> (Entity<EditorView>, f32) {
        let (row_index, row, section) = key;
        let key = (row, section);
        self.tick += 1;
        let ToolEditorStyle { palette: p, failed } = style;
        if !self.entries.contains_key(&key) {
            if self.entries.len() >= TOOL_EDITOR_LIMIT {
                let oldest = self
                    .entries
                    .iter()
                    .filter(|(_, entry)| !entry.editor.read(cx).focus_handle(cx).is_focused(window))
                    .min_by_key(|(_, entry)| entry.used)
                    .map(|(key, _)| key.clone());
                if let Some(oldest) = oldest {
                    self.entries.remove(&oldest);
                }
            }
            let editor = cx.new(|cx| {
                let mut editor = EditorView::new(preview.into(), window, cx);
                editor.set_read_only(true, cx);
                editor.set_vim(false, cx);
                editor.set_appearance(tool_editor_appearance(p, failed), cx);
                editor
            });
            self.entries.insert(
                key.clone(),
                ToolEditor {
                    row_index,
                    editor,
                    style,
                    used: self.tick,
                },
            );
        }
        let entry = self.entries.get_mut(&key).expect("created section");
        // Every visible row renders before paint, even with a cached height.
        // Keep focus visibility checks bounded to the editor cache.
        entry.row_index = row_index;
        entry.used = self.tick;
        let height = entry.editor.update(cx, |editor, cx| {
            if editor.text() != preview {
                editor.set_text(preview.into(), cx);
            }
            if entry.style != style {
                editor.set_appearance(tool_editor_appearance(p, failed), cx);
            }
            editor
                .measured_content_height(width.max(1.), window)
                .clamp(17., tool_presentation::SECTION_CAP)
        });
        entry.style = style;
        (entry.editor.clone(), height)
    }
}
fn tool_editor_appearance(p: Palette, failed: bool) -> EditorAppearance {
    EditorAppearance {
        font_family: "monospace".into(),
        font_size: 12.,
        line_height: 17.,
        padding_x: 0.,
        padding_y: 0.,
        text: rgb(if failed { p.danger } else { p.secondary }).into(),
        selection: p.accent_soft(),
        caret: rgb(p.accent).into(),
        normal_caret: p.accent_soft(),
        ..EditorAppearance::plain()
    }
}

fn render_tool_card(
    presentation: &Presentation,
    index: usize,
    child: &WeakEntity<TranscriptView>,
    editors: &Rc<RefCell<ToolEditors>>,
    width: Pixels,
    window: &mut Window,
    cx: &mut App,
) -> Div {
    let row = &presentation.rows[index];
    let projected = row.projected.expect("tool projection");
    let session = &presentation.input.session;
    let p = presentation.input.palette;
    let status = tool_presentation::status(session, projected);
    let (name, mut input) = match projected {
        ProjectedRow::Call {
            assistant, call, ..
        } => {
            let call = tool_presentation::call_at(session, assistant, call);
            (
                call.name.clone(),
                row.expanded
                    .then(|| tool_presentation::arguments_preview(&call.arguments)),
            )
        }
        ProjectedRow::Result(source) => {
            let label = match &session.messages[source].tool_record {
                Some(bello_agent_core::tool_history::ToolRecord::Result(result)) => {
                    format!("Tool result · {} · {}", result.assistant_id, result.call_id)
                }
                _ => "Tool result".into(),
            };
            (label, None)
        }
        _ => unreachable!("tool card"),
    };
    let selector = format!("transcript-tool-{:?}", row.key);
    let key = row.key.clone();
    let chat_id = presentation.input.chat_id.clone();
    let controller = presentation.input.controller.clone();
    let disclosure_child = child.clone();
    let mut card = div()
        .debug_selector(|| selector.clone())
        .w_full()
        .max_w(px(640.))
        .mx_auto()
        .min_w_0()
        .flex()
        .flex_col()
        .rounded(px(10.))
        .border_1()
        .border_color(p.hairline())
        .bg(rgb(p.surface))
        .child(
            div()
                .px(px(16.))
                .py(px(10.))
                .flex()
                .gap(px(10.))
                .items_start()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(3.))
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(p.ink))
                                .child(name.clone()),
                        )
                        .child(
                            div()
                                .debug_selector(|| format!("{selector}-status"))
                                .text_size(px(11.5))
                                .text_color(rgb(if status.is_error() {
                                    p.danger
                                } else {
                                    p.secondary
                                }))
                                .child(status.label(&name)),
                        ),
                )
                .child(
                    button(
                        p,
                        SharedString::from(format!("{selector}-disclosure")),
                        if row.expanded {
                            "Hide details"
                        } else {
                            "Show details"
                        },
                    )
                    .debug_selector(|| format!("{selector}-disclosure"))
                    .on_click(move |_, window, cx| {
                        let _ = disclosure_child.update(cx, |view, cx| {
                            view.toggle_tool(key.clone(), &chat_id, &controller, window, cx)
                        });
                    }),
                ),
        );
    if !row.expanded {
        return card;
    }
    let shown_output = projected
        .result()
        .map(|index| tool_presentation::display_text(&session.messages[index]));
    let read_call = read_presentation::read_call(session, projected);
    let read_window = read_call.and_then(|call| {
        let text = shown_output.as_deref()?;
        (!text.is_empty()).then(|| read_presentation::ReadWindow::new(text, &call.arguments))
    });
    if read_window.is_some() {
        input = None;
    }
    let read_link = read_presentation::file_link(session, projected);
    let output = shown_output.as_deref().map(|text| {
        if let Some(read) = &read_window {
            // Source's six-head/six-tail window, without the generic 8 KiB
            // prefix. The selectable Editor remains a bounded 150 px scroller;
            // Show more exposes every retained line, and raw Copy stays exact.
            return tool_presentation::Preview {
                text: read.numbered(row.read_expanded),
                truncated: false,
            };
        }
        tool_presentation::preview(if text.is_empty() {
            bello_agent_core::tool_history::EMPTY_RESULT
        } else {
            text
        })
    });
    let truncated = input.as_ref().is_some_and(|preview| preview.truncated)
        || output.as_ref().is_some_and(|preview| preview.truncated);
    if read_window.is_some() || read_link.is_some() {
        let mut header = div()
            .w_full()
            .min_w_0()
            .border_t_1()
            .border_color(p.hairline())
            .px(px(16.))
            .py(px(8.))
            .flex()
            .items_center()
            .gap(px(8.));
        if let Some(link) = read_link {
            let child = child.clone();
            let key = row.key.clone();
            let chat_id = presentation.input.chat_id.clone();
            let controller = presentation.input.controller.clone();
            header = header.child(
                div()
                    .id(SharedString::from(format!("{selector}-read-path")))
                    .debug_selector(|| format!("{selector}-read-path"))
                    .flex_1()
                    .min_w_0()
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .text_ellipsis()
                    .cursor_pointer()
                    .hover(|d| d.underline())
                    .child(link.path)
                    .on_click(move |_, window, cx| {
                        let _ = child.update(cx, |view, cx| {
                            view.open_read_file(&key, &chat_id, &controller, window, cx)
                        });
                    }),
            );
        }
        if let Some(read) = &read_window {
            header = header.child(
                div()
                    .debug_selector(|| format!("{selector}-read-window"))
                    .flex_shrink_0()
                    .text_size(px(11.5))
                    .text_color(rgb(p.tertiary))
                    .child(read.window_label(row.read_expanded)),
            );
        }
        card = card.child(header);
    }
    let body_width = (f32::from(width) - 48.).min(640.) - 32. - 28. - 14. - 2.;
    for (label, preview) in [("IN", input), ("OUT", output)] {
        let Some(preview) = preview else {
            continue;
        };
        let (editor, height) = editors.borrow_mut().section(
            (index, row.key.clone(), label),
            &preview.text,
            ToolEditorStyle {
                palette: p,
                failed: label == "OUT" && status.is_error(),
            },
            body_width,
            window,
            cx,
        );
        card = card.child(
            div()
                .w_full()
                .min_w_0()
                .border_t_1()
                .border_color(p.hairline())
                .px(px(16.))
                .py(px(12.))
                .flex()
                .items_start()
                .gap(px(14.))
                .child(
                    div()
                        .w(px(28.))
                        .flex_shrink_0()
                        .text_size(px(11.))
                        .text_color(rgb(p.tertiary))
                        .child(label),
                )
                .child(
                    div()
                        .id(SharedString::from(format!("{selector}-{label}")))
                        .debug_selector(|| format!("{selector}-{label}"))
                        .flex_1()
                        .min_w_0()
                        .h(px(height))
                        .max_h(px(tool_presentation::SECTION_CAP))
                        .overflow_hidden()
                        // GPUI List registers its wheel listener after children,
                        // so bubbling alone cannot stop it. Exclude the outer
                        // list's hitbox while this selectable scroller is hit.
                        .occlude()
                        .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
                        .child(editor),
                ),
        );
    }
    if let Some(read) = read_window {
        if read.collapsible() {
            let child = child.clone();
            let key = row.key.clone();
            let chat_id = presentation.input.chat_id.clone();
            let controller = presentation.input.controller.clone();
            card = card.child(
                div().px(px(16.)).pb(px(8.)).child(
                    button(
                        p,
                        SharedString::from(format!("{selector}-read-disclosure")),
                        if row.read_expanded {
                            "Show less".into()
                        } else {
                            format!(
                                "Show {} more lines",
                                read.lines.len() - read_presentation::READ_LINES
                            )
                        },
                    )
                    .debug_selector(|| format!("{selector}-read-disclosure"))
                    .on_click(move |_, _, cx| {
                        let _ = child.update(cx, |view, cx| {
                            view.toggle_read(key.clone(), &chat_id, &controller, cx)
                        });
                    }),
                ),
            );
        }
        if let Some(note) = read.note {
            card = card.child(
                div()
                    .debug_selector(|| format!("{selector}-read-note"))
                    .px(px(16.))
                    .pb(px(10.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .child(note.to_owned()),
            );
        }
    }
    if truncated {
        card = card.child(
            div()
                .px(px(16.))
                .pb(px(10.))
                .text_size(px(11.5))
                .text_color(rgb(p.secondary))
                .child("Preview truncated; retained input and output are unchanged."),
        );
    }
    card
}
