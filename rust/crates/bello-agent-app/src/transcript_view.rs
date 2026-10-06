//! Retained, variable-height transcript. Immutable presentation inputs determine
//! rows; only event callbacks access the parent. The list measures the viewport
//! and the source's max(240px, half a viewport) buffer, never the whole history.
use crate::{AgentView, Palette, layout, transcript_actions};
use bello_agent_core::{Controller, Session};
use gpui::{prelude::*, *};
use std::{
    cell::RefCell,
    collections::HashMap,
    rc::Rc,
    sync::{Arc, Weak},
};

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
            });
        } else if input.load_failed {
            rows.push(LogicalRow {
                key: RowKey::Retry,
                message_index: None,
            });
        }
        if hidden_messages > 0 {
            rows.push(LogicalRow {
                key: RowKey::Earlier,
                message_index: None,
            });
        }
        let mut counts = HashMap::<&str, usize>::new();
        for message in &input.session.messages {
            *counts.entry(message.id.as_str()).or_default() += 1;
        }
        let mut occurrences = HashMap::<&str, usize>::new();
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
                rows.push(LogicalRow {
                    key,
                    message_index: Some(index),
                });
            }
            *occurrence += 1;
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
        match (row.message_index, other_row.message_index) {
            (Some(index), Some(other_index)) => {
                let message = &self.input.session.messages[index];
                let other_message = &other.input.session.messages[other_index];
                message.role == other_message.role
                    && message.text == other_message.text
                    && message.reasoning == other_message.reasoning
                    && message.state == other_message.state
            }
            (None, None) => {
                row.key != RowKey::Earlier || self.hidden_messages == other.hidden_messages
            }
            _ => false,
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
// estimate, never a view tree. Current Rust rows display literal text; estimates
// mirror their existing text sizes, wrapping width and chrome, not Swift's
// richer Markdown/tool presentation. Exact List measurements replace guesses.
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
        self.presentation = Rc::new(Presentation::new(input));
        cx.notify();
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
                RowKey::Duplicate { id, occurrence, .. } => format!("{id}#{occurrence}"),
            })
            .collect()
    }
}

// A list with Auto sizing does not render items in request_layout. This tiny
// adapter can therefore select the correct overdraw from actual prepaint bounds
// before any row is measured, in the same frame and without entity updates.
struct ViewportList {
    viewport: Rc<RefCell<ViewportState>>,
    presentation: Rc<Presentation>,
    parent: WeakEntity<AgentView>,
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
        #[cfg(test)]
        let materialized = self.materialized.clone();
        list(state, move |index, window, cx| {
            let mut row = materialize_row(
                &presentation,
                index,
                &parent,
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

// Both List's normal renderer and the single-row clamp preflight use this
// constructor, so bounded-work instrumentation includes every row tree.
fn materialize_row(
    presentation: &Presentation,
    index: usize,
    parent: &WeakEntity<AgentView>,
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
    let row = render_row(presentation, index, parent);
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
                &self.parent,
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
                &self.parent,
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
    }
}

impl Render for TranscriptView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        #[cfg(test)]
        {
            self.render_count += 1;
        }
        let element = ViewportList {
            viewport: self.viewport.clone(),
            presentation: self.presentation.clone(),
            parent: self.parent.clone(),
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

fn render_row(presentation: &Presentation, index: usize, parent: &WeakEntity<AgentView>) -> Div {
    let input = &presentation.input;
    let row = &presentation.rows[index];
    let p = input.palette;
    let content = match &row.key {
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
