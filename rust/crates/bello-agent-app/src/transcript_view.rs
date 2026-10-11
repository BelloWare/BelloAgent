//! Retained, variable-height transcript. Immutable presentation inputs determine
//! rows; only event callbacks access the parent. The list measures the viewport
//! and the source's max(240px, half a viewport) buffer, never the whole history.
use crate::{AgentView, Palette, layout, transcript_actions};
use bello_agent_core::{Controller, RunState, Session};
use bello_workbench_ui::{EditorAppearance, EditorView, TextDecoration, TextPresentation};
#[path = "transcript_card_lines.rs"]
mod card_lines;
#[path = "transcript_edit_presentation.rs"]
mod edit_presentation;
#[path = "transcript_markdown.rs"]
mod markdown_view;
#[cfg(test)]
pub(crate) use markdown_view::Child as MarkdownChild;
#[cfg(test)]
#[path = "transcript_polish_oracle_tests.rs"]
mod polish_oracle;
#[path = "transcript_read_presentation.rs"]
mod read_presentation;
#[path = "transcript_response.rs"]
mod response;
#[path = "transcript_shaped_text.rs"]
mod shaped_text;
#[path = "transcript_tool_presentation.rs"]
mod tool_presentation;
#[path = "transcript_tool_row.rs"]
mod tool_row;
#[path = "transcript_turn_fold.rs"]
mod turn_fold;
pub(crate) use response::FoldCommand;
pub(crate) use turn_fold::TranscriptDisplayMode;
#[path = "transcript_work_line.rs"]
mod work_line;
use gpui::{prelude::*, *};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
    sync::{Arc, Weak},
};
use tool_presentation::ProjectedRow;

// TestPlatform can hold the actual fresh-paint callback while changing the host.
// Production always consumes it immediately through the same handler.
#[cfg(test)]
type FindGeometryCallback = Box<dyn FnOnce(&mut Window, &mut App)>;
#[cfg(test)]
thread_local! {
    static FIND_GEOMETRY_PAUSED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static FIND_GEOMETRY_CALLBACKS: RefCell<Vec<FindGeometryCallback>> = const { RefCell::new(Vec::new()) };
}
#[cfg(test)]
thread_local! {
    static TOOL_ROWS_OPEN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Tests of what an open card holds start as if the reader had opened
/// every tool row on this thread; a click still closes one.
#[cfg(test)]
pub(crate) fn open_tool_rows_for_test() {
    TOOL_ROWS_OPEN.with(|open| open.set(true));
}
#[cfg(test)]
thread_local! {
    static TURNS_LOOSE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Tests of a finished turn's own rows read the turn loose, as Swift's
/// Normal display does; the turn-fold tests leave Swift's default.
#[cfg(test)]
pub(crate) fn loose_turns_for_test() {
    TURNS_LOOSE.with(|loose| loose.set(true));
}
/// The display a new transcript starts in: Swift's compact display, its
/// default, unless a test asked for the turns loose.
fn initial_display() -> TranscriptDisplayMode {
    #[cfg(test)]
    if TURNS_LOOSE.with(std::cell::Cell::get) {
        return TranscriptDisplayMode::Normal;
    }
    TranscriptDisplayMode::Compact
}
fn tool_rows_open_by_default() -> bool {
    #[cfg(test)]
    return TOOL_ROWS_OPEN.with(std::cell::Cell::get);
    #[cfg(not(test))]
    false
}
#[cfg(test)]
pub(crate) fn pause_find_geometry(paused: bool) {
    FIND_GEOMETRY_PAUSED.with(|v| v.set(paused));
}
#[cfg(test)]
pub(crate) fn resume_find_geometry(window: &mut Window, cx: &mut App) -> usize {
    let callbacks = FIND_GEOMETRY_CALLBACKS.with(|v| std::mem::take(&mut *v.borrow_mut()));
    let count = callbacks.len();
    for callback in callbacks {
        callback(window, cx);
    }
    count
}

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
    pub find_binding: Option<bello_agent_core::retained_find::FindSnapshot>,
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
    /// A finished turn's fold control, by the row of the question that opened
    /// the turn. In the open set, the fold is open.
    Fold(Box<RowKey>),
    /// A response by its reply's row key. In the open set, the response is
    /// folded to its header line (Swift's `responseLine`). Never a row's key.
    Response(Box<RowKey>),
    /// In the open set, everything inside the response draws closed (Swift's
    /// `response`). Never a row's key.
    ResponseInside(Box<RowKey>),
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
    fold: turn_fold::RowFold,
    response: response::RowResponse,
}

struct Presentation {
    input: TranscriptInput,
    rows: Vec<LogicalRow>,
    /// Rows a closed turn fold holds. They keep their identity and what the
    /// reader opened in them, but are not list items: a long folded turn
    /// costs the list nothing.
    folded: Vec<LogicalRow>,
    hidden_messages: usize,
    #[cfg(test)]
    estimate_override: std::cell::Cell<Option<Pixels>>,
}

impl Presentation {
    fn new(input: TranscriptInput, display: TranscriptDisplayMode) -> Self {
        Self::with_disclosure(input, &HashSet::new(), &HashSet::new(), display)
    }

    fn with_disclosure(
        input: TranscriptInput,
        opened: &HashSet<RowKey>,
        expanded_reads: &HashSet<RowKey>,
        display: TranscriptDisplayMode,
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
                fold: turn_fold::RowFold::default(),
                response: Default::default(),
            });
        } else if input.load_failed {
            rows.push(LogicalRow {
                key: RowKey::Retry,
                message_index: None,
                projected: None,
                expanded: false,
                read_expanded: false,
                read_key: None,
                fold: turn_fold::RowFold::default(),
                response: Default::default(),
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
                fold: turn_fold::RowFold::default(),
                response: Default::default(),
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
            // Swift opens a call's card only on request (`TranscriptDisclosure`).
            let expanded = opened.contains(&key) != tool_rows_open_by_default();
            // A read's retained result keeps its window state when Show earlier
            // replaces a standalone result with its owning call card. Ambiguous
            // result IDs remain snapshot-scoped like all other transcript keys.
            let read_key = if edit_presentation::edit_call(&input.session, projected).is_some() {
                if let ProjectedRow::Result(index) = projected {
                    let Some(bello_agent_core::tool_history::ToolRecord::Result(result)) =
                        &input.session.messages[index].tool_record
                    else {
                        unreachable!("validated edit result");
                    };
                    // edit_call already proved this owner ID is unique. The
                    // assistant can be outside this page's message_keys map.
                    Some(RowKey::Tool {
                        assistant: Box::new(RowKey::Message(result.assistant_id.clone())),
                        call_id: result.call_id.clone(),
                        occurrence: 0,
                    })
                } else {
                    Some(key.clone())
                }
            } else {
                projected.result().map(|index| message_keys[&index].clone())
            };
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
                fold: turn_fold::RowFold::default(),
                response: Default::default(),
            });
        }
        response::apply(&mut rows, &input.session, opened);
        for row in &mut rows {
            // A response folded from inside draws its cards closed and keeps
            // what the reader opened for when it opens again.
            row.expanded &= !row.response.inside_folded;
        }
        if display == TranscriptDisplayMode::Compact {
            turn_fold::apply(&mut rows, &input.session, opened);
        }
        let (folded, rows) = rows
            .into_iter()
            .partition(|row| row.fold.hidden || row.response.line_hidden);
        Self {
            input,
            rows,
            folded,
            hidden_messages,
            #[cfg(test)]
            estimate_override: std::cell::Cell::new(None),
        }
    }

    /// Every row of the page, folded ones included.
    fn all_rows(&self) -> impl Iterator<Item = &LogicalRow> {
        self.rows.iter().chain(&self.folded)
    }

    fn same_row(&self, index: usize, other: &Self, other_index: usize) -> bool {
        let row = &self.rows[index];
        let other_row = &other.rows[other_index];
        if row.key != other_row.key
            || row.fold != other_row.fold
            || row.response != other_row.response
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
                // A capped list's tail is drawn only while the list is capped.
                && !(section.split('#').next().is_some_and(|run| run.ends_with("-tail"))
                    && row.read_expanded)
                && row.projected.is_some_and(|projected| match card_lines::section_of(section) {
                    "IN" => {
                        (matches!(projected, ProjectedRow::Call { .. })
                            || edit_presentation::has_request(
                                &presentation.input.session,
                                projected,
                            ))
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
                    "OUT" => {
                        projected.result().is_some()
                            && !(edit_presentation::has_request(
                                &presentation.input.session,
                                projected,
                            ) && tool_presentation::status(
                                &presentation.input.session,
                                projected,
                            ) == tool_presentation::Status::Completed)
                    }
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
    /// Each row's last drawn height, kept while its content changes (a
    /// streaming reply): close enough to tell which of a long reply's blocks
    /// are near the viewport before the row is measured again.
    drawn_heights: HashMap<RowKey, Pixels>,
    pending_scroll: Option<ListOffset>,
    reveal: Option<RowKey>,
    painted_scroll: ListOffset,
    /// The page keeps the newest row in view, as Swift's `followsBottom`. A
    /// chat opens following and sending follows the new turn; from then on
    /// the reader decides: a scroll that ends within `FOLLOW_BAND` of the end
    /// pins it, going up or any navigation elsewhere unpins it.
    follows_end: bool,
    /// The reader's wheel went down; once that lands, the band decides whether
    /// the page follows again. Going up unpins at once and is not re-pinned
    /// by the band: a reply arriving between the events of one upward gesture
    /// must not pull the page back to the end under the reader's hand.
    reader_landing: bool,
    /// An idle chat opens at the question of its last turn when that turn is
    /// taller than the viewport (Swift's opening placement), decided once on
    /// the first frame with real geometry.
    opening: bool,
    /// The last laid-out frame had the end within the follow band. Anywhere
    /// else the transcript offers Swift's "Jump to the latest message" circle.
    end_shown: bool,
    /// The frame being laid out: what a long reply needs to draw only the
    /// blocks near the viewport.
    frame: Frame,
    #[cfg(test)]
    target_preflights: Vec<usize>,
    #[cfg(test)]
    tool_height_invalidations: usize,
}

/// Swift's `TranscriptPage.followThreshold` plus its rounding point.
const FOLLOW_BAND: Pixels = px(25.);

/// A frame as the list is about to lay it out.
#[derive(Default)]
struct Frame {
    number: u64,
    /// The scroll top the list lays out from (past the last row: the end).
    top: Option<ListOffset>,
    bounds: Bounds<Pixels>,
}

/// The part of row `index` the viewport shows this frame, in the row's own
/// coordinates, from the scroll top the list lays out from and the rows'
/// last heights; None where a height is unknown.
fn row_visible(
    viewport: &ViewportState,
    presentation: &Presentation,
    index: usize,
) -> Option<std::ops::Range<f32>> {
    let top = viewport.frame.top?;
    let view = f32::from(viewport.frame.bounds.size.height);
    let rows = &presentation.rows;
    let height = |row: usize| {
        let key = &rows[row].key;
        let height = viewport
            .heights
            .get(key)
            .or(viewport.drawn_heights.get(key));
        height.map(|height| f32::from(*height))
    };
    let mut row_top = -f32::from(top.offset_in_item);
    if top.item_ix >= rows.len() {
        // Following: the last row ends at the viewport's bottom, above the
        // list's 13 pt padding.
        row_top = view - 13.;
        for row in (index..rows.len()).rev() {
            row_top -= height(row)?;
        }
    } else if index >= top.item_ix {
        for row in top.item_ix..index {
            row_top += height(row)?;
        }
    } else {
        for row in index..top.item_ix {
            row_top -= height(row)?;
        }
    }
    Some(-row_top..view - row_top)
}

/// One past the last row: GPUI's top-aligned list clamps this to the real
/// bottom while filling the viewport upward, so it shows the newest content.
fn end_offset(presentation: &Presentation) -> ListOffset {
    ListOffset {
        item_ix: presentation.rows.len(),
        offset_in_item: px(0.),
    }
}

fn same_offset(a: ListOffset, b: ListOffset) -> bool {
    a.item_ix == b.item_ix && a.offset_in_item == b.offset_in_item
}

impl ViewportState {
    fn new(presentation: Rc<Presentation>) -> Self {
        let buffer = px(240.);
        let end = end_offset(&presentation);
        let list = ListState::new(presentation.rows.len(), ListAlignment::Top, buffer);
        list.scroll_to(end);
        Self {
            list,
            buffer,
            heights: HashMap::new(),
            drawn_heights: HashMap::new(),
            pending_scroll: None,
            reveal: None,
            #[cfg(test)]
            target_preflights: Vec::new(),
            #[cfg(test)]
            tool_height_invalidations: 0,
            painted_scroll: end,
            follows_end: true,
            end_shown: true,
            frame: Frame::default(),
            reader_landing: false,
            opening: presentation.input.session.state != RunState::Running,
            presentation,
        }
    }

    /// Whether the end of the last row is on screen, or within the follow
    /// band below it. Only a partly visible last row counts: rows between the
    /// scroll top and it are then measured exactly by this layout.
    fn end_in_band(&self) -> bool {
        let Some(last) = self.presentation.rows.len().checked_sub(1) else {
            return true;
        };
        let viewport = self.list.viewport_bounds();
        self.list.bounds_for_item(last).is_some_and(|row| {
            row.top() < viewport.bottom() && row.bottom() <= viewport.bottom() + FOLLOW_BAND
        })
    }

    /// Navigation the reader or the app asked for takes the page off the end.
    fn unpin(&mut self) {
        self.follows_end = false;
        self.reader_landing = false;
        self.opening = false;
    }

    /// Follow the newest row again, as Swift's `followSubmittedTurn`.
    fn follow_latest(&mut self) {
        self.follows_end = true;
        self.opening = false;
        self.reader_landing = false;
        self.pending_scroll = None;
        self.reveal = None;
    }

    fn prepare(&mut self, next: Rc<Presentation>, bounds: Bounds<Pixels>) -> Option<ListOffset> {
        let buffer = px(240.).max(bounds.size.height / 2.);
        // Capture at prepaint, after any user input received since the last
        // frame. No scheduled callback can later overwrite a newer gesture.
        let offset = self.list.logical_scroll_top();
        // A move since the last painted frame that this view did not make,
        // and no gesture is landing, is navigation elsewhere.
        if self.pending_scroll.is_none() && !same_offset(offset, self.painted_scroll) {
            self.unpin();
        }
        // While following, the end stays in view through new rows, a growing
        // reply, and any viewport change (the queue panel opening as a message
        // is sent, the composer growing, a resize), as in Swift.
        let follow = self.follows_end;
        if follow {
            self.pending_scroll = None;
        }
        let old = &self.presentation;
        let changed = !Rc::ptr_eq(old, &next);
        if self.list.viewport_bounds().size.width != bounds.size.width
            || old.input.pane_width != next.input.pane_width
            || old.input.palette != next.input.palette
        {
            self.heights.clear();
            self.drawn_heights.clear();
            self.pending_scroll = None;
        } else if changed {
            let keys: HashSet<&RowKey> = next.rows.iter().map(|row| &row.key).collect();
            self.drawn_heights.retain(|key, _| keys.contains(key));
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
        if follow {
            let end = end_offset(&self.presentation);
            self.painted_scroll = end;
            self.list.scroll_to(end);
        }
        if let Some(key) = self.reveal.take()
            && let Some(item_ix) = self.presentation.rows.iter().position(|row| row.key == key)
        {
            let target = ListOffset {
                item_ix,
                offset_in_item: px(0.),
            };
            self.unpin();
            self.pending_scroll = None;
            self.painted_scroll = target;
            self.list.scroll_to(target);
            return Some(target);
        }
        (remeasure_anchor && !follow).then_some(anchor)
    }
}

// Like TranscriptRowEstimate.swift, unseen rows have a nonzero navigation
// estimate, never a view tree. Plain-message estimates mirror their text sizes,
// wrapping width and chrome; tool cards use their bounded section caps without
// copying retained payloads. Exact List measurements replace these guesses.
/// `TranscriptNativeTurnFoldRow.controlHeight`: the 24-point line, eight
/// points under it, and its hairline.
const FOLD_CONTROL_HEIGHT: f32 = 32.;

/// The room under a row. A reply's calls stack as Swift's part rows do, line
/// on line, and the first sits just under the reply's Copy band; everything
/// else keeps the 16-point gap.
fn row_gap(presentation: &Presentation, index: usize) -> f32 {
    // A folded row draws nothing, and a fold's line keeps its own room.
    let row = &presentation.rows[index];
    if row.fold.hidden || row.fold.control.is_some() {
        return 0.;
    }
    let Some(next) = presentation.rows[index + 1..]
        .iter()
        .find(|row| !row.fold.hidden)
    else {
        return 0.;
    };
    let assistant = |row: &LogicalRow| match row.projected {
        Some(ProjectedRow::Call { assistant, .. }) => Some(assistant),
        _ => None,
    };
    let Some(owner) = assistant(next) else {
        return 16.;
    };
    match presentation.rows[index].projected {
        Some(ProjectedRow::Call { assistant, .. }) if assistant == owner => 0.,
        Some(ProjectedRow::Message(source)) if source == owner => 4.,
        _ => 16.,
    }
}

/// The response strip a row draws: none when its turn's fold hides it.
fn drawn_header(row: &LogicalRow) -> Option<&response::Header> {
    // A response the reader folded to its line keeps that line even inside
    // a closed turn: the fold is what they asked for, not the turn's.
    row.response
        .header
        .as_ref()
        .filter(|header| !row.fold.header_hidden || header.collapsed)
}

fn estimated_height(presentation: &Presentation, index: usize, width: Pixels) -> Pixels {
    #[cfg(test)]
    if let Some(height) = presentation.estimate_override.get() {
        return height;
    }
    let gap = row_gap(presentation, index);
    let row = &presentation.rows[index];
    if row.fold.hidden {
        return px(0.);
    }
    if let Some(control) = &row.fold.control {
        return px(FOLD_CONTROL_HEIGHT + if control.open { 4. } else { 8. });
    }
    let Some(source_index) = row.message_index else {
        return px(gap
            + match row.key {
                RowKey::Loading => 69.,
                _ => 29.25,
            });
    };
    let header = drawn_header(row);
    if let Some(header) = header.filter(|header| header.collapsed) {
        // A response folded to its line is its strip and nothing else.
        return px(gap + header.height());
    }
    let message = &presentation.input.session.messages[source_index];
    if matches!(
        row.projected,
        Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
    ) {
        // The line, and while open its card 2 under it and 8 above what follows.
        return px(gap
            + header.map_or(0., response::Header::height)
            + work_line::HEIGHT
            + if row.expanded {
                2. + 64. + tool_presentation::SECTION_CAP * 2. + 8.
            } else {
                0.
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
    let text = crate::composer_attachments::message_label(message);
    let body = if message.role != "assistant" {
        plain(&text, 14.5, 21.)
    } else if message.text.is_empty() {
        // The waiting dots' line before a reply's first token.
        if message.state == "streaming" {
            WAITING_HEIGHT
        } else {
            0.
        }
    } else {
        // A reply's lines as its Markdown sets them, without the spacing
        // below the last.
        let (line, spacing) = markdown_view::body_line(bello_agent_core::markdown::Style::PROSE);
        plain(&message.text, 14.5, line + spacing) - spacing
    };
    // A response's strip stands where the row's top room was.
    let top = header.map_or(12., response::Header::height);
    let mut height = top + 6. + transcript_actions::ACTION_BAND_HEIGHT + gap + body;
    if user {
        height += 18.;
        if let Some(content) = &message.user_content {
            height += content.skills.len() as f32 * 30.;
        }
    }
    if !message.reasoning.is_empty() && !row.fold.think_hidden {
        // The Think row, closed until opened.
        height += 6. + work_line::HEIGHT;
    }
    if let Some(label) = crate::compaction_actions::row_label(message, &presentation.input.session)
    {
        height += 6. + plain(label, 11.5, 17.25);
    }
    if message.state == "interrupted" {
        height += 6. + 17.25;
    }
    // Layout lands on whole points.
    px(height.round())
}

/// Swift's `TranscriptReplyRow.waitingHeight`: the line the waiting dots take.
const WAITING_HEIGHT: f32 = 22.;

/// Swift's `TranscriptWaitingDots`: before a reply's first token, three 7 pt
/// dots 12 apart, lit one more every 0.4 s and then all dim again.
fn waiting_dots(owner: &str, p: Palette) -> Div {
    let muted = rgb(if p.dark { 0xa9a59b } else { 0x6e6a61 });
    div()
        .h(px(WAITING_HEIGHT))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(5.))
        .children((0..3).map(|index| {
            div()
                .flex_none()
                .size(px(7.))
                .rounded_full()
                .bg(muted)
                .with_animation(
                    SharedString::from(format!("{owner}-waiting-{index}")),
                    Animation::new(std::time::Duration::from_millis(1600)).repeat(),
                    move |dot, progress| {
                        let phase = ((progress * 4.) as usize).min(3);
                        dot.opacity(if phase != 0 && index < phase {
                            1.
                        } else {
                            0.25
                        })
                    },
                )
        }))
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
    /// Tool rows the reader opened; every other one is closed.
    opened: HashSet<RowKey>,
    expanded_reads: HashSet<RowKey>,
    /// How finished turns read: Normal keeps them loose, Compact folds them.
    display: TranscriptDisplayMode,
    /// Settings' display preference, while this view follows it.
    _display: Option<Subscription>,
    tool_editors: Rc<RefCell<ToolEditors>>,
    focus: Option<FocusHandle>,
    removed_tool_focus: Rc<RefCell<Vec<FocusHandle>>>,
    #[cfg(test)]
    materialized: Rc<RefCell<Materialized>>,
    #[cfg(test)]
    render_count: usize,
    #[cfg(test)]
    offered_jump: bool,
}

impl TranscriptView {
    pub(crate) fn follows_bottom(&self) -> bool {
        let viewport = self.viewport.borrow();
        viewport.pending_scroll.is_none()
            && self
                .presentation
                .rows
                .len()
                .checked_sub(1)
                .and_then(|index| viewport.list.bounds_for_item(index))
                .is_some_and(|row| reply_end_visible(row, viewport.list.viewport_bounds()))
    }
    pub(crate) fn new(parent: WeakEntity<AgentView>, input: TranscriptInput) -> Self {
        let display = initial_display();
        let presentation = Rc::new(Presentation::new(input, display));
        Self {
            parent,
            opened: HashSet::new(),
            expanded_reads: HashSet::new(),
            display,
            _display: None,
            tool_editors: Rc::new(RefCell::new(ToolEditors::default())),
            focus: None,
            removed_tool_focus: Rc::new(RefCell::new(Vec::new())),
            viewport: Rc::new(RefCell::new(ViewportState::new(presentation.clone()))),
            presentation,
            #[cfg(test)]
            materialized: Rc::new(RefCell::new(Materialized::default())),
            #[cfg(test)]
            render_count: 0,
            #[cfg(test)]
            offered_jump: false,
        }
    }

    #[cfg(test)]
    pub(crate) fn find_decoration_state(&self) -> (bool, usize) {
        let editors = self.tool_editors.borrow();
        (
            editors.find.is_some(),
            editors
                .entries
                .values()
                .filter(|e| e.find_installed.is_some())
                .count(),
        )
    }
    #[cfg(test)]
    pub(crate) fn find_geometry_state(&self) -> Option<(u8, bool, bool)> {
        self.tool_editors
            .borrow()
            .find
            .as_ref()
            .map(|f| (f.attempts.get(), f.measuring.get(), f.landed.get()))
    }
    #[cfg(test)]
    pub(crate) fn find_scope_matches(&self, message: &bello_agent_core::Message) -> bool {
        self.tool_editors
            .borrow()
            .find
            .as_ref()
            .is_some_and(|f| f.scope_matches(message))
    }
    #[cfg(test)]
    pub(crate) fn find_confirmed_geometry(&self) -> Option<Bounds<Pixels>> {
        self.tool_editors
            .borrow()
            .find
            .as_ref()
            .and_then(|f| f.confirmed_geometry.get())
    }
    #[cfg(test)]
    pub(crate) fn find_landed(&self) -> bool {
        self.tool_editors
            .borrow()
            .find
            .as_ref()
            .is_some_and(|f| f.landed.get())
    }
    #[cfg(test)]
    pub(crate) fn find_has_current_binding(&self) -> bool {
        self.tool_editors
            .borrow()
            .find
            .as_ref()
            .is_some_and(|f| f.matches_binding(self.presentation.input.find_binding.as_ref()))
    }
    pub(crate) fn find_visible_ids(&self) -> HashSet<String> {
        let viewport = self.viewport.borrow();
        let bounds = viewport.list.viewport_bounds();
        self.presentation
            .rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| {
                let drawn = viewport.list.bounds_for_item(i)?;
                if drawn.bottom() <= bounds.top() || drawn.top() >= bounds.bottom() {
                    return None;
                }
                row.projected
                    .and_then(|p| p.result())
                    .or(row.message_index)
                    .map(|i| self.presentation.input.session.messages[i].id.clone())
            })
            .collect()
    }
    pub(crate) fn clear_find_owner(&mut self, owner: uuid::Uuid, cx: &mut Context<Self>) {
        let matches = self
            .tool_editors
            .borrow()
            .find
            .as_ref()
            .is_some_and(|find| find.owner == owner);
        if matches {
            self.set_find(None, cx);
        }
    }
    pub(crate) fn set_find(
        &mut self,
        find: Option<Rc<crate::transcript_find_presentation::FindPaint>>,
        cx: &mut Context<Self>,
    ) {
        let mut editors = self.tool_editors.borrow_mut();
        if find.is_none() && editors.sidebar.is_none() {
            self.viewport.borrow_mut().reveal = None;
            for entry in editors.entries.values_mut() {
                entry.editor.update(cx, |e, cx| {
                    let _ = e.set_text_presentation(None, cx);
                });
                entry.find_installed = None;
            }
        }
        editors.find = find;
        cx.notify();
    }
    pub(crate) fn reveal_find(
        &mut self,
        input: TranscriptInput,
        find: Rc<crate::transcript_find_presentation::FindPaint>,
        navigate: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        self.reveal_paint(input, find, navigate, false, cx)
    }
    pub(crate) fn reveal_sidebar(
        &mut self,
        input: TranscriptInput,
        paint: Rc<crate::transcript_find_presentation::FindPaint>,
        cx: &mut Context<Self>,
    ) -> bool {
        self.reveal_paint(input, paint, true, true, cx)
    }
    #[cfg(all(test, target_os = "linux", feature = "synthetic-authority"))]
    pub(crate) fn sidebar_decoration_current(&self) -> bool {
        self.tool_editors
            .borrow()
            .sidebar
            .as_ref()
            .is_some_and(|paint| {
                paint.matches_binding(self.presentation.input.find_binding.as_ref())
            })
    }
    pub(crate) fn sidebar_decoration_owned(&self, owner: uuid::Uuid) -> bool {
        self.tool_editors
            .borrow()
            .sidebar
            .as_ref()
            .is_some_and(|paint| {
                paint.owner == owner
                    && paint.matches_binding(self.presentation.input.find_binding.as_ref())
            })
    }
    pub(crate) fn decorate_sidebar(
        &mut self,
        input: TranscriptInput,
        paint: Rc<crate::transcript_find_presentation::FindPaint>,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some(destination) = &paint.destination {
            destination.navigation.cancel();
        }
        paint.landed.set(true);
        self.reveal_paint(input, paint, false, true, cx)
    }
    fn reveal_paint(
        &mut self,
        input: TranscriptInput,
        find: Rc<crate::transcript_find_presentation::FindPaint>,
        navigate: bool,
        sidebar: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        let target = find.destination.as_ref().map(|d| d.found.id.clone());
        let input_target = find.sidebar_input().cloned();
        self.update_inputs(input, cx);
        if !navigate
            && !sidebar
            && let Some(old) = &self.tool_editors.borrow().find
        {
            find.landed.set(old.landed.get());
            find.confirmed.set(old.confirmed.get());
            #[cfg(test)]
            find.confirmed_geometry.set(old.confirmed_geometry.get());
        }
        if sidebar {
            self.tool_editors.borrow_mut().sidebar = Some(find);
            self.rearm_find_geometry(cx);
        } else {
            if navigate {
                self.tool_editors.borrow_mut().sidebar = None;
            }
            self.set_find(Some(find), cx);
        }
        if !navigate {
            return true;
        }
        let Some(id) = target else {
            return true;
        };
        if self
            .presentation
            .input
            .session
            .messages
            .iter()
            .filter(|m| m.id == id)
            .count()
            != 1
        {
            return false;
        }
        let Some(source) = self
            .presentation
            .input
            .session
            .messages
            .iter()
            .position(|m| m.id == id)
        else {
            return false;
        };
        let Some(row) = self.presentation.all_rows().find(|r| {
            input_target.as_ref().is_some_and(|hit| match r.projected {
                Some(ProjectedRow::Call {
                    assistant, call, ..
                }) => {
                    let session = &self.presentation.input.session;
                    let tool = tool_presentation::call_at(session, assistant, call);
                    session.messages[assistant].id == hit.key().message_id
                        && hit.key().call_id.as_deref() == Some(tool.id.as_str())
                }
                _ => false,
            }) || (input_target.is_none() && r.projected.and_then(|p| p.result()) == Some(source))
                || (input_target.is_none()
                    && r.message_index == Some(source)
                    && matches!(r.projected, Some(ProjectedRow::Message(_))))
        }) else {
            return false;
        };
        let key = row.key.clone();
        let read_key = row.read_key.clone();
        // As a browser's find reveals hidden text, the finished turn that
        // folded the match away opens.
        if let Some(group) = row.fold.group.clone() {
            self.opened.insert(RowKey::Fold(Box::new(group)));
        }
        // And the response folded around it opens.
        if let Some(owner) = row.response.owner.clone() {
            self.opened
                .remove(&RowKey::Response(Box::new(owner.clone())));
            self.opened.remove(&RowKey::ResponseInside(Box::new(owner)));
        }
        self.opened.insert(key.clone());
        if let Some(read_key) = read_key {
            self.expanded_reads.insert(read_key);
        }
        self.presentation = Rc::new(Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        self.viewport.borrow_mut().reveal = Some(key);
        cx.notify();
        true
    }
    fn land_find_point(
        &mut self,
        find: &Rc<crate::transcript_find_presentation::FindPaint>,
        index: usize,
        point: Point<Pixels>,
        span_height: Pixels,
        line_height: Pixels,
        cx: &mut Context<Self>,
    ) {
        if !find.matches_binding(self.presentation.input.find_binding.as_ref()) {
            return;
        }
        if !find.navigating()
            || !self
                .tool_editors
                .borrow()
                .active_find()
                .as_ref()
                .is_some_and(|own| Rc::ptr_eq(own, find))
        {
            return;
        }
        let mut viewport = self.viewport.borrow_mut();
        let Some(row) = viewport.list.bounds_for_item(index) else {
            return;
        };
        let bounds = viewport.list.viewport_bounds();
        if !f32::from(bounds.size.height).is_finite()
            || !f32::from(bounds.size.width).is_finite()
            || bounds.size.height <= px(0.)
            || bounds.size.width <= px(0.)
        {
            return;
        }
        if !f32::from(point.y).is_finite()
            || !f32::from(span_height).is_finite()
            || !f32::from(line_height).is_finite()
            || line_height <= px(0.)
            || span_height <= px(0.)
        {
            return;
        }
        // A match the reader navigates to holds the page, as a Swift reveal
        // lands on an explicit, unpinned anchor.
        viewport.unpin();
        let partial = span_height > bounds.size.height;
        let visible_height = if partial { line_height } else { span_height };
        let fully_visible = point.y >= bounds.top() && point.y + visible_height <= bounds.bottom();
        let padding =
            (bounds.size.height / 3.).min((bounds.size.height - visible_height).max(px(0.)) / 2.);
        let confirm = || {
            find.landed.set(true);
            find.complete_navigation();
            find.confirmed.set(true);
            #[cfg(test)]
            find.confirmed_geometry.set(Some(Bounds {
                origin: point,
                size: size(px(1.), visible_height),
            }));
            if partial {
                *find.notice.borrow_mut() = Some("This match is taller than the available transcript viewport; only its first line is shown.".into());
            }
        };
        let margin = px(24.).min((bounds.size.height - visible_height).max(px(0.)) / 2.);
        if fully_visible
            && point.y >= bounds.top() + margin
            && point.y + visible_height <= bounds.bottom() - margin
        {
            confirm();
            if partial {
                cx.notify();
            }
            return;
        }
        let target = wheel_anchor(
            &self.presentation,
            &viewport.heights,
            bounds.size.width,
            ListOffset {
                item_ix: index,
                offset_in_item: point.y - row.top(),
            },
            -padding,
        );
        let previous = viewport.list.logical_scroll_top();
        if target.item_ix == previous.item_ix
            && (target.offset_in_item - previous.offset_in_item).abs() < px(0.5)
            && fully_visible
        {
            confirm();
            if partial {
                cx.notify();
            }
            return;
        }
        viewport.pending_scroll = Some(target);
        viewport.reveal = None;
        viewport.list.scroll_to(target);
        // A scroll request is not visibility evidence. Keep navigation active
        // and require another fresh painted receipt at the resulting origin.
        self.rearm_find_geometry(cx);
    }
    /// Lands a find on line `line` of a lines section's run, from where the
    /// run's block was drawn; a block not drawn yet is tried on the next frame.
    #[allow(clippy::too_many_arguments)]
    fn land_find_line(
        &mut self,
        find: &Rc<crate::transcript_find_presentation::FindPaint>,
        index: usize,
        key: &RowKey,
        label: &'static str,
        first: (usize, usize),
        (last, past): ((usize, usize), usize),
        cx: &mut Context<Self>,
    ) {
        if self
            .presentation
            .rows
            .get(index)
            .is_none_or(|row| &row.key != key)
        {
            return;
        }
        let geometry = self
            .tool_editors
            .borrow()
            .entries
            .get(&(key.clone(), label))
            .and_then(|entry| entry.lines.clone());
        let Some((block, rows)) = geometry else {
            return;
        };
        let Some(block) = block
            .get()
            .filter(|_| last.0 < rows.len() && first.0 <= last.0)
        else {
            self.rearm_find_geometry(cx);
            return;
        };
        // The editor rows the match runs over: a long line wraps, and its
        // start may be far above the match.
        let top_of = |(line, within): (usize, usize)| {
            (rows[..line].iter().sum::<usize>() + within.min(rows[line].saturating_sub(1))) as f32
                * card_lines::LINE_HEIGHT
        };
        let top = top_of(first);
        let height = top_of(last) - top + (1 + past) as f32 * card_lines::LINE_HEIGHT;
        self.land_find_point(
            find,
            index,
            point(block.left(), block.top() + px(top)),
            px(height),
            px(card_lines::LINE_HEIGHT),
            cx,
        );
    }
    fn invalidate_sidebar_geometry(&self, cx: &mut Context<Self>) {
        if let Some(paint) = self.tool_editors.borrow().sidebar.clone() {
            paint.confirmed.set(false);
            paint.landed.set(false);
            paint.measuring.set(false);
            paint.attempts.set(0);
            *paint.host_geometry.borrow_mut() = None;
            paint.layouts.borrow_mut().clear();
            for entry in self.tool_editors.borrow().entries.values() {
                entry.editor.update(cx, |editor, cx| {
                    editor.cancel_presentation_reveal(paint.serial, cx);
                    editor.invalidate_presentation_geometry(cx);
                });
            }
        }
        self.rearm_find_geometry(cx);
    }
    pub(crate) fn finish_sidebar_wait(
        &mut self,
        owner: uuid::Uuid,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(paint) = self
            .tool_editors
            .borrow()
            .sidebar
            .clone()
            .filter(|paint| paint.owner == owner)
        else {
            return false;
        };
        self.finish_paint_wait(paint, cx).is_some()
    }
    fn rearm_find_geometry(&self, cx: &mut Context<Self>) {
        for entry in self.tool_editors.borrow_mut().entries.values_mut() {
            entry.find_installed = None;
            entry
                .editor
                .update(cx, |e, cx| e.invalidate_presentation_geometry(cx));
        }
        cx.notify();
    }
    /// The reader sent a message: follow its new turn from wherever they were
    /// reading, as Swift's `followSubmittedTurn`. Callers end any find landing
    /// first, as a wheel gesture does.
    pub(crate) fn follow_latest(&mut self, cx: &mut Context<Self>) {
        self.viewport.borrow_mut().follow_latest();
        cx.notify();
    }
    pub(crate) fn cancel_find_navigation(&mut self, cx: &mut Context<Self>) {
        self.viewport.borrow_mut().reveal = None;
        if let Some(sidebar) = &self.tool_editors.borrow().sidebar {
            sidebar.landed.set(true);
            if let Some(destination) = &sidebar.destination {
                destination.navigation.cancel();
            }
        }
        if let Some(find) = self.tool_editors.borrow().active_find() {
            find.measuring.set(false);
            for entry in self.tool_editors.borrow().entries.values() {
                entry
                    .editor
                    .update(cx, |e, cx| e.cancel_presentation_reveal(find.serial, cx));
            }
        }
    }
    pub(crate) fn finish_find_wait(
        &mut self,
        serial: u64,
        cx: &mut Context<Self>,
    ) -> Option<crate::transcript_find_state::Destination> {
        let find = self.tool_editors.borrow().find.clone()?;
        if find.serial != serial {
            return None;
        }
        self.finish_paint_wait(find, cx)
    }
    fn finish_paint_wait(
        &mut self,
        find: Rc<crate::transcript_find_presentation::FindPaint>,
        cx: &mut Context<Self>,
    ) -> Option<crate::transcript_find_state::Destination> {
        if !find.active_navigation()
            || !find.matches_binding(self.presentation.input.find_binding.as_ref())
        {
            return None;
        }
        let serial = find.serial;
        find.landed.set(true);
        find.complete_navigation();
        find.measuring.set(false);
        if self
            .tool_editors
            .borrow()
            .active_find()
            .is_some_and(|active| Rc::ptr_eq(&active, &find))
        {
            for entry in self.tool_editors.borrow().entries.values() {
                entry
                    .editor
                    .update(cx, |e, cx| e.cancel_presentation_reveal(serial, cx));
            }
        }
        find.destination.clone()
    }
    pub(crate) fn clear_sidebar_search(&mut self, cx: &mut Context<Self>) {
        let Some(paint) = self.tool_editors.borrow_mut().sidebar.take() else {
            return;
        };
        paint.landed.set(true);
        paint.measuring.set(false);
        for entry in self.tool_editors.borrow_mut().entries.values_mut() {
            entry.find_installed = None;
            entry.editor.update(cx, |editor, cx| {
                editor.cancel_presentation_reveal(paint.serial, cx);
                let _ = editor.set_text_presentation(None, cx);
            });
        }
        self.viewport.borrow_mut().reveal = None;
        cx.notify();
    }
    pub(crate) fn clear_content_reveal(&mut self) {
        self.tool_editors.borrow_mut().sidebar = None;
        self.viewport.borrow_mut().reveal = None;
    }

    /// Reveal a uniquely identified retained message, including a result paired
    /// into its owning tool card. Never select a duplicate or a stale controller.
    pub(crate) fn reveal_message(
        &mut self,
        input: TranscriptInput,
        id: &str,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.presentation.input.chat_id != input.chat_id
            || !self.presentation.input.controller.ptr_eq(&input.controller)
            || input
                .session
                .messages
                .iter()
                .filter(|message| message.id == id)
                .count()
                != 1
        {
            return false;
        }
        let Some(index) = input
            .session
            .messages
            .iter()
            .position(|message| message.id == id)
        else {
            return false;
        };
        self.update_inputs(input, cx);
        let row = self.presentation.all_rows().find(|row| {
            row.message_index == Some(index)
                || row
                    .projected
                    .is_some_and(|projected| projected.result() == Some(index))
        });
        let Some(row) = row else {
            return false;
        };
        let key = row.key.clone();
        let mut changed = false;
        if row.fold.hidden
            && let Some(group) = row.fold.group.clone()
        {
            // The finished turn that folded the message away opens.
            changed |= self.opened.insert(RowKey::Fold(Box::new(group)));
        }
        if let Some(owner) = row.response.owner.clone() {
            // So does the response folded around it.
            changed |= self
                .opened
                .remove(&RowKey::Response(Box::new(owner.clone())));
            changed |= self.opened.remove(&RowKey::ResponseInside(Box::new(owner)));
        }
        if matches!(
            row.projected,
            Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
        ) {
            // A retained result shows in its card, which opens.
            changed |= self.opened.insert(key.clone());
        }
        if changed {
            self.presentation = Rc::new(Presentation::with_disclosure(
                self.presentation.input.clone(),
                &self.opened,
                &self.expanded_reads,
                self.display,
            ));
        }
        self.viewport.borrow_mut().reveal = Some(key);
        cx.notify();
        true
    }

    pub(crate) fn update_inputs(&mut self, input: TranscriptInput, cx: &mut Context<Self>) {
        if self
            .tool_editors
            .borrow()
            .sidebar
            .as_ref()
            .is_some_and(|paint| !paint.matches_binding(input.find_binding.as_ref()))
        {
            self.clear_sidebar_search(cx);
        }
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
        if !Arc::ptr_eq(&old.session, &input.session) {
            self.viewport.borrow_mut().reveal = None;
        }
        if old.chat_id != input.chat_id || !Weak::ptr_eq(&old.controller, &input.controller) {
            self.viewport.borrow_mut().reveal = None;
            self.opened.clear();
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
        // A standalone result the reader opened stays open when paging
        // brings its call onto the page and the result joins the call's card.
        let open_results: HashSet<String> = self
            .presentation
            .all_rows()
            .filter(|row| {
                matches!(row.projected, Some(ProjectedRow::Result(_)))
                    && self.opened.contains(&row.key)
            })
            .filter_map(|row| row.message_index)
            .map(|index| self.presentation.input.session.messages[index].id.clone())
            .collect();
        self.presentation = Rc::new(Presentation::with_disclosure(
            input,
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        if !open_results.is_empty() {
            let session = self.presentation.input.session.clone();
            let joined: Vec<RowKey> = self
                .presentation
                .all_rows()
                .filter(|row| {
                    matches!(row.projected, Some(ProjectedRow::Call { result: Some(result), .. })
                        if open_results.contains(&session.messages[result].id))
                })
                .map(|row| row.key.clone())
                .collect();
            let mut changed = false;
            for key in joined {
                changed |= self.opened.insert(key);
            }
            if changed {
                self.presentation = Rc::new(Presentation::with_disclosure(
                    self.presentation.input.clone(),
                    &self.opened,
                    &self.expanded_reads,
                    self.display,
                ));
            }
        }
        let keys: HashSet<_> = self.presentation.all_rows().map(|row| &row.key).collect();
        let responses: HashSet<_> = self
            .presentation
            .all_rows()
            .filter_map(|row| row.response.owner.as_ref())
            .collect();
        // A fold's choice lasts as long as its question: a retry runs the turn
        // again and its control comes back with the reader's choice. A
        // response's lasts as long as the response.
        self.opened.retain(|key| match key {
            RowKey::Fold(question) => keys.contains(question.as_ref()),
            RowKey::Response(owner) | RowKey::ResponseInside(owner) => {
                responses.contains(owner.as_ref())
            }
            key => keys.contains(key),
        });
        let read_keys: HashSet<_> = self
            .presentation
            .all_rows()
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

    /// Opens or closes a reply's Think row.
    fn toggle_thinking(&mut self, message_id: &str, cx: &mut Context<Self>) {
        {
            let mut editors = self.tool_editors.borrow_mut();
            if !editors.open_thinking.remove(message_id) {
                editors.open_thinking.insert(message_id.to_owned());
            }
        }
        cx.notify();
    }
    /// Opens or closes a finished turn's fold. What the reader opened inside
    /// it stays as it was.
    fn toggle_fold(
        &mut self,
        key: RowKey,
        chat_id: &str,
        controller: &Weak<Controller>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.presentation.input.chat_id != chat_id
            || !Weak::ptr_eq(&self.presentation.input.controller, controller)
            || !self.presentation.rows.iter().any(|row| row.key == key)
        {
            return;
        }
        if !self.opened.remove(&key) {
            self.opened.insert(key);
        }
        self.refold(window, cx);
    }
    /// Lays the page out again after a fold changed, leaving the keyboard
    /// with a visible owner when the fold hid a focused card's payload, as
    /// closing the card itself does.
    fn refold(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.presentation = Rc::new(Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        let folded: HashSet<_> = self
            .presentation
            .folded
            .iter()
            .map(|row| &row.key)
            .collect();
        if self
            .tool_editors
            .borrow()
            .entries
            .iter()
            .any(|((row, _), entry)| {
                folded.contains(row) && entry.editor.read(cx).focus_handle(cx).is_focused(window)
            })
            && let Some(focus) = &self.focus
        {
            focus.focus(window);
        }
        self.invalidate_sidebar_geometry(cx);
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
        if self.opened.contains(&key)
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
        if !self.opened.remove(&key) {
            self.opened.insert(key);
        }
        self.presentation = Rc::new(Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        self.invalidate_sidebar_geometry(cx);
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
                        if edit_presentation::edit_call(&self.presentation.input.session, projected)
                            .is_some()
                        {
                            return self
                                .tool_editors
                                .borrow_mut()
                                .edit_previews
                                .get(&row.key, &self.presentation.input.session, projected, false)
                                .is_some_and(|edit| edit.collapsible);
                        }
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
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        self.invalidate_sidebar_geometry(cx);
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
            .find(|row| &row.key == key)
            .and_then(|row| {
                read_presentation::file_link(&self.presentation.input.session, row.projected?)
                    .or_else(|| {
                        edit_presentation::file_link(
                            &self.presentation.input.session,
                            row.projected?,
                        )
                    })
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

    #[cfg(all(test, target_os = "linux", feature = "synthetic-authority"))]
    pub(crate) fn sidebar_paint(
        &self,
    ) -> Option<Rc<crate::transcript_find_presentation::FindPaint>> {
        self.tool_editors.borrow().sidebar.clone()
    }
    #[cfg(all(test, target_os = "linux", feature = "synthetic-authority"))]
    pub(crate) fn toggle_first_tool_for_test(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let row = self
            .presentation
            .rows
            .iter()
            .find(|row| {
                matches!(
                    row.projected,
                    Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
                )
            })
            .expect("tool fixture row");
        let key = row.key.clone();
        let chat = self.presentation.input.chat_id.clone();
        let controller = self.presentation.input.controller.clone();
        self.toggle_tool(key, &chat, &controller, window, cx);
    }

    #[cfg(test)]
    pub(crate) fn edit_cache_computations(&self) -> usize {
        self.tool_editors.borrow().edit_previews.computations
    }
    #[cfg(test)]
    pub(crate) fn edit_card_labels(&self) -> Vec<String> {
        self.presentation
            .rows
            .iter()
            .filter_map(|row| {
                let projected = row.projected?;
                self.tool_editors
                    .borrow_mut()
                    .edit_previews
                    .get(&row.key, &self.presentation.input.session, projected, false)
                    .map(|preview| preview.label.clone())
            })
            .collect()
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
    /// What the card `selector` names last drew as its lines.
    #[cfg(test)]
    pub(crate) fn drawn_lines(&self, selector: &str) -> Option<DrawnLines> {
        self.tool_editors
            .borrow()
            .drawn_lines
            .get(selector)
            .cloned()
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
    /// Whether the last render offered the jump to the latest message.
    #[cfg(test)]
    pub(crate) fn offers_jump(&self) -> bool {
        self.offered_jump
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
    /// The rows whose text was read as Markdown.
    #[cfg(test)]
    pub(crate) fn markdown_owners(&self) -> Vec<String> {
        let mut owners: Vec<String> = self
            .tool_editors
            .borrow()
            .markdown
            .keys()
            .map(ToString::to_string)
            .collect();
        owners.sort();
        owners
    }
    /// What a fence's Copy does, as its button calls it (outside any update).
    #[cfg(test)]
    pub(crate) fn copy_handler(&self, transcript: WeakEntity<Self>) -> markdown_view::CopyCode {
        copy_code(&self.tool_editors, &transcript)
    }
    /// A reply's slots, its column's top in its row, the children its last
    /// frame drew, and whether it is to be drawn whole.
    #[cfg(test)]
    pub(crate) fn reply_layout(&self, owner: &str) -> ReplyLayout {
        let editors = self.tool_editors.borrow();
        let place = &editors.markdown[owner].place;
        ReplyLayout {
            slots: place.slots.clone(),
            text_top: place.text_top,
            children: place.children.clone(),
            whole: place.whole,
        }
    }
    /// The fence whose Copy reads "Copied".
    #[cfg(test)]
    pub(crate) fn copied_code(&self) -> Option<String> {
        self.tool_editors
            .borrow()
            .copied_code
            .as_ref()
            .map(|(key, _)| key.to_string())
    }
    #[cfg(test)]
    pub(crate) fn presentation_identity(&self) -> usize {
        Rc::as_ptr(&self.presentation) as usize
    }
    #[cfg(test)]
    /// Each fold control's line and whether its turn is open.
    #[cfg(test)]
    pub(crate) fn fold_lines(&self) -> Vec<(String, bool)> {
        self.presentation
            .rows
            .iter()
            .filter_map(|row| row.fold.control.as_ref())
            .map(|control| (control.label.clone(), control.open))
            .collect()
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
                RowKey::Fold(group) => format!("@fold:{group:?}"),
                RowKey::Response(_) | RowKey::ResponseInside(_) => {
                    unreachable!("a response's fold is never a row")
                }
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
    /// Swift's opening placement: an idle chat whose last turn, from its
    /// question to the end, is taller than the viewport opens with that
    /// question at the top, held there until the reader moves. Measured before
    /// the first layout, so no frame shows the end first.
    fn place_opening(&self, bounds: Bounds<Pixels>, window: &mut Window, cx: &mut App) {
        self.viewport.borrow_mut().opening = false;
        let messages = &self.presentation.input.session.messages;
        let Some(question) = self
            .presentation
            .rows
            .iter()
            .rev()
            .find_map(|row| {
                row.message_index.filter(|&index| {
                    !matches!(row.key, RowKey::Tool { .. })
                        && messages.get(index).is_some_and(|m| m.role == "user")
                })
            })
            .and_then(|index| {
                self.presentation
                    .rows
                    .iter()
                    .position(|row| row.message_index == Some(index))
            })
        else {
            return;
        };
        let mut turn = px(0.);
        for index in question..self.presentation.rows.len() {
            let key = self.presentation.rows[index].key.clone();
            let known = self.viewport.borrow().heights.get(&key).copied();
            turn += match known {
                Some(height) => height,
                None => {
                    let mut row = materialize_row(
                        &self.presentation,
                        index,
                        RowRenderContext {
                            parent: &self.parent,
                            child: &self.child,
                            tool_editors: &self.tool_editors,
                            visible: None,
                            frame: 0,
                        },
                        bounds.size.width,
                        window,
                        cx,
                        #[cfg(test)]
                        &self.materialized,
                    );
                    let height = row
                        .layout_as_root(
                            size(
                                AvailableSpace::Definite(bounds.size.width),
                                AvailableSpace::MinContent,
                            ),
                            window,
                            cx,
                        )
                        .height;
                    self.viewport.borrow_mut().heights.insert(key, height);
                    height
                }
            };
            if turn > bounds.size.height + px(1.) {
                let mut viewport = self.viewport.borrow_mut();
                viewport.follows_end = false;
                let target = ListOffset {
                    item_ix: question,
                    offset_in_item: px(0.),
                };
                viewport.painted_scroll = target;
                viewport.list.scroll_to(target);
                return;
            }
        }
    }

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
            let (visible, frame) = {
                let viewport = viewport.borrow();
                (
                    row_visible(&viewport, &presentation, index),
                    viewport.frame.number,
                )
            };
            let mut row = materialize_row(
                &presentation,
                index,
                RowRenderContext {
                    parent: &parent,
                    child: &child,
                    tool_editors: &tool_editors,
                    visible,
                    frame,
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
            let key = &presentation.rows[index].key;
            let mut viewport = viewport.borrow_mut();
            viewport.heights.insert(key.clone(), measured.height);
            viewport.drawn_heights.insert(key.clone(), measured.height);
            row
        })
        .w_full()
        .h_full()
        .min_h_0()
        .pb(px(13.))
    }
}

#[derive(Clone)]
struct RowRenderContext<'a> {
    parent: &'a WeakEntity<AgentView>,
    child: &'a WeakEntity<TranscriptView>,
    tool_editors: &'a Rc<RefCell<ToolEditors>>,
    /// The row's part on screen this frame, when the list draws it: a long
    /// reply then draws only the blocks near it. None draws every block.
    visible: Option<std::ops::Range<f32>>,
    frame: u64,
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
        let current_find = self.tool_editors.borrow().active_find();
        if let Some(find) = current_find {
            find.layouts.borrow_mut().clear();
            let changed = self.viewport.borrow().list.viewport_bounds() != bounds;
            let live = find.destination.as_ref().is_some_and(|d| {
                !d.search
                    .cancellation()
                    .load(std::sync::atomic::Ordering::Acquire)
                    && !d
                        .navigation
                        .cancellation()
                        .load(std::sync::atomic::Ordering::Acquire)
            });
            if changed && find.confirmed.get() && live {
                find.confirmed.set(false);
                find.landed.set(false);
                find.attempts.set(0);
                for entry in self.tool_editors.borrow_mut().entries.values_mut() {
                    entry.find_installed = None;
                    entry
                        .editor
                        .update(cx, |e, cx| e.invalidate_presentation_geometry(cx));
                }
            }
        }
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
                    visible: None,
                    frame: 0,
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
        if self.viewport.borrow().opening
            && !self.presentation.input.loading
            && bounds.size.height > px(0.)
        {
            self.place_opening(bounds, window, cx);
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
        // The end target (one past the last row) is left for List's own bottom
        // clamp, which shows the end of a last row taller than the viewport.
        if target.item_ix < self.presentation.rows.len() {
            target = wheel_anchor(
                &self.presentation,
                &self.viewport.borrow().heights,
                bounds.size.width,
                target,
                px(0.),
            );
        }
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
                    visible: None,
                    frame: 0,
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
        {
            let mut viewport = self.viewport.borrow_mut();
            viewport.frame.number += 1;
            viewport.frame.top = Some(viewport.list.logical_scroll_top());
            viewport.frame.bounds = bounds;
        }
        self.list = self.build_list(bounds.size.width);
        let prepaint = self
            .list
            .prepaint(id, inspector_id, bounds, state, window, cx);
        let mut viewport = self.viewport.borrow_mut();
        viewport.painted_scroll = viewport.list.logical_scroll_top();
        if self.tool_editors.borrow_mut().settle_replies(
            viewport.frame.number,
            bounds,
            &viewport.list,
        ) {
            window.request_animation_frame();
        }
        // The reader's downward movement has landed: standing within the band
        // pins the page to the newest row, anywhere else leaves it unpinned.
        if viewport.reader_landing && viewport.pending_scroll.is_none() {
            viewport.reader_landing = false;
            viewport.follows_end = viewport.end_in_band();
        }
        // The jump circle is the view's own content: render again only when
        // the end comes into or leaves the band, after this draw.
        let end_shown = viewport.end_in_band();
        if end_shown != viewport.end_shown {
            viewport.end_shown = end_shown;
            let child = self.child.clone();
            window.defer(cx, move |_, cx| {
                let _ = child.update(cx, |_, cx| cx.notify());
            });
        }
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
        let find_parent = self.parent.clone();
        window.on_mouse_event(move |event: &ScrollWheelEvent, phase, window, cx| {
            if phase == DispatchPhase::Capture && bounds.contains(&event.position) {
                let _ = find_parent.update(cx, |view, cx| {
                    view.abandon_find_navigation();
                    if let Some(t) = view.transcript.clone() {
                        t.update(cx, |t, cx| t.cancel_find_navigation(cx));
                    }
                });
                let parent = find_parent.clone();
                window.defer(cx, move |_, cx| {
                    let _ = parent.update(cx, |v, cx| v.refresh_find_viewport(cx));
                });
            }
            if phase == DispatchPhase::Bubble && hitbox.should_handle_scroll(window) {
                let step = vertical_wheel_distance(event.delta, line_height);
                distance += step;
                let anchor = wheel_anchor(
                    &presentation,
                    &viewport.borrow().heights,
                    bounds.size.width,
                    origin,
                    distance,
                );
                {
                    let mut state = viewport.borrow_mut();
                    state.pending_scroll = Some(anchor);
                    state.opening = false;
                    if step < px(0.) {
                        // Going up leaves the end at once, before this lands.
                        state.unpin();
                    } else if step > px(0.) {
                        state.reader_landing = true;
                    }
                }
                list.scroll_to(anchor);
                cx.notify(current_view);
            }
        });
        self.list
            .paint(id, inspector_id, bounds, state, &mut prepaint.0, window, cx);
        if let Some(find) = self.tool_editors.borrow().active_find()
            && find.navigating()
        {
            if find.measuring.get()
                && find.host_geometry.borrow().is_none()
                && let Some(index) = find.host_row.get()
            {
                let viewport = self.viewport.borrow();
                *find.host_geometry.borrow_mut() =
                    Some(crate::transcript_find_presentation::HostGeometry {
                        origin: viewport.list.logical_scroll_top(),
                        viewport: viewport.list.viewport_bounds(),
                        row: viewport.list.bounds_for_item(index),
                    });
            }
            let measured = find
                .layouts
                .borrow()
                .iter()
                .find_map(|(row, layout, range)| {
                    let point = layout.position_for_index(range.start)?;
                    let end = layout.position_for_index(range.end)?;
                    Some((
                        *row,
                        point,
                        end.y - point.y + layout.line_height(),
                        layout.line_height(),
                    ))
                });
            if let Some((row, point, span_height, line_height)) = measured {
                let child = self.child.clone();
                let presentation = self.presentation.clone();
                let size = window.viewport_size();
                let origin = self.viewport.borrow().list.logical_scroll_top();
                let painted_viewport = self.viewport.borrow().list.viewport_bounds();
                let painted_row = self.viewport.borrow().list.bounds_for_item(row);
                window.defer(cx, move |window, cx| {
                    let complete = move |window: &mut Window, cx: &mut App| {
                        if size != window.viewport_size() {
                            return;
                        }
                        let _ = child.update(cx, |view, cx| {
                            let now = view.viewport.borrow().list.logical_scroll_top();
                            if Rc::ptr_eq(&view.presentation, &presentation)
                                && now.item_ix == origin.item_ix
                                && now.offset_in_item == origin.offset_in_item
                                && view.viewport.borrow().list.viewport_bounds() == painted_viewport
                                && view.viewport.borrow().list.bounds_for_item(row) == painted_row
                                && painted_row.is_some()
                            {
                                view.land_find_point(
                                    &find,
                                    row,
                                    point,
                                    span_height,
                                    line_height,
                                    cx,
                                );
                            }
                        });
                    };
                    #[cfg(test)]
                    if FIND_GEOMETRY_PAUSED.with(|v| v.get()) {
                        FIND_GEOMETRY_CALLBACKS.with(|v| v.borrow_mut().push(Box::new(complete)));
                        return;
                    }
                    complete(window, cx);
                });
            }
        }
        if let Some(find) = self.tool_editors.borrow().active_find()
            && let Some(notice) = find.notice.borrow_mut().take()
            && let Some(destination) = find.destination.clone()
        {
            let parent = self.parent.clone();
            let sidebar = self
                .tool_editors
                .borrow()
                .sidebar
                .as_ref()
                .is_some_and(|paint| Rc::ptr_eq(paint, &find));
            let notice_find = find.clone();
            window.defer(cx, move |_, cx| {
                let _ = parent.update(cx, |v, cx| {
                    if sidebar {
                        if v.sidebar_search_scope_blocked()
                            || !v.sidebar_search.cache_ready()
                            || v.filter.read(cx).text() != v.sidebar_search.query
                            || v.filter.read(cx).has_marked_text()
                            || !v.transcript.as_ref().is_some_and(|transcript| {
                                let transcript = transcript.read(cx);
                                transcript
                                    .tool_editors
                                    .borrow()
                                    .sidebar
                                    .as_ref()
                                    .is_some_and(|current| Rc::ptr_eq(current, &notice_find))
                                    && notice_find.matches_binding(
                                        transcript.presentation.input.find_binding.as_ref(),
                                    )
                            })
                        {
                            return;
                        }
                        v.error = Some(notice);
                        cx.notify();
                    } else {
                        v.find_landing_notice(&destination, notice, cx);
                    }
                });
            });
        }
        let list = self.viewport.borrow().list.clone();
        // List has completed layout/paint. Bounds may include overdraw, so
        // only the actual end of the last projected row of the exact newest
        // accepted output can constitute visibility evidence.
        if self.viewport.borrow().pending_scroll.is_none()
            && let Some(controller) = self.presentation.input.controller.upgrade()
            && let observation = controller.published_read_observation()
            && observation.source_revision == self.presentation.input.session.revision
            && let bello_agent_core::read_observation::OutputProjection::Known(summary) =
                observation.history
            && let Some(target) = summary.latest_id
            && let Some(index) = self.presentation.rows.iter().rposition(|row| {
                row.message_index
                    .is_some_and(|i| self.presentation.input.session.messages[i].id == target)
            })
            // A response folded to its strip shows none of its end.
            && !drawn_header(&self.presentation.rows[index]).is_some_and(|header| header.collapsed)
            && measured_reply_end_visible(&list, index)
        {
            let parent = self.parent.clone();
            let child = self.child.clone();
            let presentation = self.presentation.clone();
            let offset = list.logical_scroll_top();
            let painted_window_size = window.viewport_size();
            let viewport = self.viewport.clone();
            window.defer(cx, move |window, cx| {
                let current = window.viewport_size() == painted_window_size
                    && child.upgrade().is_some_and(|child| {
                        Rc::ptr_eq(&child.read(cx).presentation, &presentation)
                    })
                    && viewport.borrow().pending_scroll.is_none()
                    && {
                        let now = viewport.borrow().list.logical_scroll_top();
                        now.item_ix == offset.item_ix && now.offset_in_item == offset.offset_in_item
                    }
                    && measured_reply_end_visible(&viewport.borrow().list, index);
                let _ = parent.update(cx, |view, cx| {
                    view.acknowledge_reply_end(
                        &presentation.input.chat_id,
                        &presentation.input.controller,
                        &target,
                        presentation.input.session.revision,
                        &observation.generation,
                        current,
                        window,
                        cx,
                    )
                });
            });
        }
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

pub(crate) fn measured_reply_end_visible(list: &ListState, index: usize) -> bool {
    list.bounds_for_item(index)
        .is_some_and(|row| reply_end_visible(row, list.viewport_bounds()))
}

/// Measured/painted overdraw alone is insufficient; require a finite real
/// viewport and the end (including the copy band) inside its vertical extent.
pub(crate) fn reply_end_visible(row: Bounds<Pixels>, viewport: Bounds<Pixels>) -> bool {
    [
        row.left(),
        row.right(),
        row.bottom(),
        viewport.left(),
        viewport.right(),
        viewport.top(),
        viewport.bottom(),
    ]
    .iter()
    .all(|v| v.to_f64().is_finite())
        && viewport.size.width > px(0.)
        && viewport.size.height > px(0.)
        && row.size.height > px(0.)
        && row.left() >= viewport.left()
        && row.right() <= viewport.right()
        && row.bottom() > viewport.top()
        && row.bottom() <= viewport.bottom()
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
        let jump = !self.viewport.borrow().end_shown && !self.presentation.rows.is_empty();
        #[cfg(test)]
        {
            self.offered_jump = jump;
        }
        let p = self.presentation.input.palette;
        div()
            .id("transcript")
            .track_focus(&focus)
            .on_any_mouse_down(|_, window, _| window.prevent_default())
            .debug_selector(|| "queue-measured-transcript".into())
            .relative()
            .w_full()
            .h_full()
            .min_h_0()
            .flex()
            .flex_col()
            .child(element)
            .when(jump, |transcript| {
                // Swift's PiKit.BackToBottomPill: a 34 pt circle centred twelve
                // points above the transcript's foot.
                transcript.child(
                    div()
                        .id("transcript-jump-to-latest")
                        .debug_selector(|| "transcript-jump-to-latest".into())
                        .group("transcript-jump-to-latest")
                        .absolute()
                        .bottom(px(12.))
                        .left(relative(0.5))
                        .ml(px(-17.))
                        .size(px(34.))
                        .rounded_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .bg(rgb(p.surface))
                        .border_1()
                        .border_color(rgba(if p.dark { 0xffffff29 } else { 0x00000024 }))
                        .hover(move |circle| {
                            circle.border_color(rgba(if p.dark { 0xa9a59b73 } else { 0x6e6a6173 }))
                        })
                        .shadow(vec![BoxShadow {
                            color: hsla(0., 0., 0., 0.22),
                            offset: point(px(0.), px(4.)),
                            blur_radius: px(12.),
                            spread_radius: px(0.),
                        }])
                        .tooltip(|_, cx| cx.new(|_| LatestHint).into())
                        .child(
                            svg()
                                .path("arrow.down")
                                .size(px(13.))
                                .text_color(rgb(p.ink))
                                .group_hover("transcript-jump-to-latest", move |icon| {
                                    icon.text_color(rgb(p.accent))
                                }),
                        )
                        .on_click(cx.listener(|view, _, _, cx| {
                            let _ = view
                                .parent
                                .update(cx, |parent, _| parent.abandon_find_navigation());
                            view.cancel_find_navigation(cx);
                            view.follow_latest(cx);
                        })),
                )
            })
    }
}

/// The jump circle's tooltip, worded as Swift's.
struct LatestHint;
impl Render for LatestHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .bg(rgb(0x333333))
            .text_color(rgb(0xffffff))
            .text_size(px(12.))
            .child("Jump to the latest message")
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

/// A row's gutters and widest measure (Swift's `TranscriptMetrics`: a
/// 48-point gutter, an 840-point page).
const ROW_GUTTER: f32 = 24.;
const ROW_MAX_WIDTH: f32 = 840.;

/// The width of a row's content in a list `width` wide.
/// Swift's turn fold control (`TranscriptNativeTurnFoldControl`): the
/// label in 13-point medium and a 10-point chevron 6 after it on a 24-point
/// line, a hairline across the foot of its 32 points; muted, and the text
/// colour under the pointer. The chevron points down while the turn is open.
fn fold_control(
    selector: &str,
    control: &turn_fold::Control,
    palette: &Palette,
    toggle: impl Fn(&mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let colors = work_line::card_colors(palette);
    let group = SharedString::from(format!("{selector}-group"));
    let (text, muted) = (colors.text, colors.muted);
    div()
        .id(SharedString::from(selector.to_owned()))
        .debug_selector({
            let selector = selector.to_owned();
            move || selector
        })
        .group(group.clone())
        .w_full()
        .h(px(FOLD_CONTROL_HEIGHT))
        .flex()
        .flex_col()
        .cursor_pointer()
        .on_click(move |_, window, cx| toggle(window, cx))
        .child(
            div()
                .h(px(work_line::HEIGHT))
                .flex()
                .items_center()
                .gap(px(6.))
                .child(
                    div()
                        .debug_selector({
                            let selector = format!("{selector}-label");
                            move || selector
                        })
                        .min_w_0()
                        .truncate()
                        .text_size(px(13.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(muted)
                        .group_hover(group.clone(), move |label| label.text_color(text))
                        .child(control.label.clone()),
                )
                .child(
                    svg()
                        .path("chevron.down")
                        .flex_none()
                        .size(px(10.))
                        .text_color(colors.faint)
                        .group_hover(group, move |chevron| chevron.text_color(text))
                        .with_transformation(Transformation::rotate(radians(if control.open {
                            0.
                        } else {
                            -std::f32::consts::FRAC_PI_2
                        }))),
                ),
        )
        .child(div().flex_1())
        .child(div().w_full().h(px(1.)).bg(colors.hair))
}

/// The response strip a row carries, and whether the response is folded to
/// it. Pressing it folds or opens the response.
fn response_strip(
    presentation: &Presentation,
    index: usize,
    child: &WeakEntity<TranscriptView>,
) -> Option<(bool, AnyElement)> {
    let row = &presentation.rows[index];
    let header = drawn_header(row)?;
    let input = &presentation.input;
    let (child, owner) = (child.clone(), header.owner.clone());
    let (chat_id, controller) = (input.chat_id.clone(), input.controller.clone());
    let selector = format!("transcript-response-{:?}", header.owner);
    Some((
        header.collapsed,
        response::render(&selector, header, &input.palette, move |window, cx| {
            let _ = child.update(cx, |view, cx| {
                view.toggle_response(owner.clone(), &chat_id, &controller, window, cx)
            });
        })
        .into_any_element(),
    ))
}

fn row_width(width: Pixels) -> f32 {
    (f32::from(width) - 2. * ROW_GUTTER).clamp(0., ROW_MAX_WIDTH)
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
        visible,
        frame,
    } = context;
    let input = &presentation.input;
    let row = &presentation.rows[index];
    let p = input.palette;
    // A row its turn's closed fold holds keeps its place and draws nothing.
    if row.fold.hidden {
        return div().w_full();
    }
    if let Some(control) = &row.fold.control {
        let (child, key) = (child.clone(), row.key.clone());
        let (chat_id, controller) = (input.chat_id.clone(), input.controller.clone());
        return div().w_full().px(px(ROW_GUTTER)).child(
            div()
                .w_full()
                .max_w(px(ROW_MAX_WIDTH))
                .mx_auto()
                .pb(px(if control.open { 4. } else { 8. }))
                .child(fold_control(
                    &format!("transcript-fold-{:?}", row.key),
                    control,
                    &p,
                    move |window, cx| {
                        let _ = child.update(cx, |view, cx| {
                            view.toggle_fold(key.clone(), &chat_id, &controller, window, cx)
                        });
                    },
                )),
        );
    }
    let (collapsed, strip) = match response_strip(presentation, index, child) {
        Some((collapsed, strip)) => (collapsed, Some(strip)),
        None => (false, None),
    };
    let content = if collapsed {
        // A response folded to its line: its first row is the strip alone.
        let selector = match &row.key {
            RowKey::Message(id) => Some(format!("transcript-row-{id}")),
            _ => None,
        };
        div()
            .when_some(selector, |d, selector| d.debug_selector(|| selector))
            .w_full()
            .max_w(px(ROW_MAX_WIDTH))
            .mx_auto()
            .children(strip)
            .into_any_element()
    } else if matches!(
        row.projected,
        Some(ProjectedRow::Call { .. } | ProjectedRow::Result(_))
    ) {
        let card = render_tool_card(presentation, index, child, tool_editors, width, window, cx);
        match strip {
            Some(strip) => div()
                .w_full()
                .max_w(px(ROW_MAX_WIDTH))
                .mx_auto()
                .flex()
                .flex_col()
                .child(strip)
                .child(card)
                .into_any_element(),
            None => card.into_any_element(),
        }
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
            RowKey::Fold(_) => unreachable!("fold control rendered above"),
            RowKey::Response(_) | RowKey::ResponseInside(_) => {
                unreachable!("a response's fold is never a row")
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
                // A reply's Markdown caps its own prose at 640 pt; its code
                // and tables run the row's width, as Swift's do.
                let reply = message.role == "assistant";
                let mut body = div()
                    .min_w_0()
                    .when(!user, |d| d.w_full())
                    .when(!reply, |d| d.max_w(px(640.)))
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
                if let Some(label) = crate::compaction_actions::row_label(message, &input.session) {
                    body = body.child(
                        div()
                            .text_size(px(11.5))
                            .line_height(px(17.25))
                            .text_color(rgb(p.secondary))
                            .child(label.to_owned()),
                    );
                }
                if !message.reasoning.is_empty() && !row.fold.think_hidden {
                    // Swift's Think row: closed by default, even while it
                    // streams; open, the reasoning read as Markdown under it.
                    let streaming = message.state == "streaming";
                    // A response folded from inside draws its thought closed.
                    let open = tool_editors.borrow().open_thinking.contains(&message.id)
                        && !row.response.inside_folded;
                    let think = work_line::WorkLine {
                        icon: "brain",
                        title: "Think".into(),
                        summary: work_line::think_summary(&message.reasoning, streaming).into(),
                        suffix: None,
                        state: if streaming {
                            work_line::WorkState::Running
                        } else {
                            work_line::WorkState::Ok
                        },
                        expandable: true,
                        open,
                        trailing: None,
                        follow: streaming,
                        help: None,
                    };
                    let (toggle_child, message_id) = (child.clone(), message.id.clone());
                    // One view, as Swift's: the line, and what it opens 4
                    // points under it, at the line's text.
                    let mut row = div().flex().flex_col().child(
                        div().debug_selector(|| format!("{selector}-think")).child(
                            work_line::work_line(
                                SharedString::from(format!("{selector}-think")),
                                &think,
                                &p,
                                move |_, cx| {
                                    let _ = toggle_child.update(cx, |view, cx| {
                                        view.toggle_thinking(&message_id, cx)
                                    });
                                },
                                None,
                            ),
                        ),
                    );
                    if open {
                        row = row.child(
                            div()
                                .debug_selector(|| format!("{selector}-reasoning"))
                                .pl(px(work_line::INDENT))
                                .pt(px(4.))
                                .pb(px(4.))
                                .child(reasoning_markdown(
                                    &message.reasoning,
                                    &selector,
                                    tool_editors,
                                    child,
                                    p,
                                    width,
                                    window,
                                )),
                        );
                    }
                    body = body.child(row);
                }
                if let Some(pills) = crate::transcript_skills::pills(message, p) {
                    body = body.child(pills);
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
                        .children({
                            // A reply is its own text (the waiting dots stand in
                            // for it before its first token); a message the reader
                            // sent reads as its input label.
                            let text = if reply {
                                message.text.clone()
                            } else {
                                crate::composer_attachments::message_label(message).into_owned()
                            };
                            if !ambiguous
                                && text == message.text
                                && let Some(find) = tool_editors.borrow().active_find()
                                && find.prose_target(&message.id)
                                && find.matches_binding(input.find_binding.as_ref())
                                && find.scope_matches(message)
                            {
                                vec![
                                    div()
                                        .max_w(px(markdown_view::PROSE_WIDTH))
                                        .child(find.prose(&message.id, text, index))
                                        .into_any_element(),
                                ]
                            } else if reply && text.is_empty() && message.state == "streaming" {
                                vec![waiting_dots(&selector, p).into_any_element()]
                            } else if reply {
                                // A reply's Markdown as Swift draws it (a message
                                // the reader sent reads literally, as there). The
                                // parse and shaped lines are reused while unchanged,
                                // so a streaming reply redoes its tail.
                                let style = bello_agent_core::markdown::Style::PROSE;
                                let owner = SharedString::from(selector.clone());
                                let (blocks, (slots, text_top, whole), shapes, copied) = {
                                    let mut editors = tool_editors.borrow_mut();
                                    let blocks = editors.markdown(&owner, &text, style);
                                    (
                                        blocks,
                                        editors.placement(&owner, width),
                                        editors.shaped_text.clone(),
                                        editors.copied_code.as_ref().map(|(key, _)| key.clone()),
                                    )
                                };
                                // A viewport's height of blocks above and below
                                // the screen is drawn; the rest stands aside.
                                let visible = visible.clone().filter(|_| !whole).zip(text_top).map(
                                    |(row, top)| {
                                        let margin = row.end - row.start;
                                        row.start - top - margin..row.end - top + margin
                                    },
                                );
                                let (column, children) = markdown_view::render(
                                    &blocks,
                                    style,
                                    &markdown_view::Context {
                                        cache: &shapes,
                                        owner: &selector,
                                        palette: p,
                                        window,
                                        prose_width: Some(markdown_view::PROSE_WIDTH),
                                        column: Some(row_width(width)),
                                        copied,
                                        text: None,
                                        on_copy: copy_code(tool_editors, child),
                                    },
                                    &markdown_view::Placement {
                                        slots: &slots,
                                        visible,
                                    },
                                );
                                let editors = tool_editors.clone();
                                vec![
                                    column
                                        .on_children_prepainted(move |bounds, _, _| {
                                            record_reply_slots(
                                                &editors, &owner, &children, &bounds, frame, index,
                                            )
                                        })
                                        .into_any_element(),
                                ]
                            } else {
                                // Shaped lines are reused across frames, so a
                                // streaming reply re-shapes only its tail.
                                let shapes = tool_editors.borrow().shaped_text.clone();
                                shaped_text::message_text(&shapes, selector.clone().into(), &text)
                                    .into_iter()
                                    .map(IntoElement::into_any_element)
                                    .collect()
                            }
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
                // The row's selector names the whole row, its strip included.
                let row_selector = selector.clone();
                let message_row = div()
                    .group(group)
                    .when(strip.is_none(), |d| d.debug_selector(|| row_selector))
                    // Keep the message content-sized, ending at its action band.
                    .w_full()
                    .max_w(px(ROW_MAX_WIDTH))
                    .mx_auto()
                    .min_w_0()
                    .flex_shrink_0()
                    // A response's strip stands in the row's top room.
                    .when(strip.is_none(), |d| d.pt(px(12.)))
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
                    .child(actions);
                match strip {
                    Some(strip) => div()
                        .debug_selector(|| selector)
                        .w_full()
                        .max_w(px(ROW_MAX_WIDTH))
                        .mx_auto()
                        .min_w_0()
                        .flex_shrink_0()
                        .flex()
                        .flex_col()
                        .child(strip)
                        .child(message_row)
                        .into_any_element(),
                    None => message_row.into_any_element(),
                }
            }
        }
    };
    // List's padding does not subtract horizontal space from its child layout;
    // put the original gutters on rows, and count each gap in that row's height.
    // The message's own bounds still finish at the bottom of its Copy band.
    div()
        .w_full()
        .px(px(ROW_GUTTER))
        .pb(px(row_gap(presentation, index)))
        .flex()
        .flex_col()
        .child(content)
}

// Only materialized, expanded sections acquire editors. Stable bounded entries
// retain selection and scroll across unrelated snapshots and streaming frames.
const TOOL_EDITOR_LIMIT: usize = 64;
#[derive(Default)]
struct ToolEditors {
    /// Replies whose Think row the reader opened.
    open_thinking: HashSet<String>,
    sidebar: Option<Rc<crate::transcript_find_presentation::FindPaint>>,
    find: Option<Rc<crate::transcript_find_presentation::FindPaint>>,
    entries: HashMap<(RowKey, &'static str), ToolEditor>,
    edit_previews: edit_presentation::EditCache,
    shaped_text: Rc<RefCell<shaped_text::ShapeCache>>,
    markdown: HashMap<SharedString, MarkdownEntry>,
    /// The fence whose Copy was pressed last and the press's number: it
    /// reads "Copied" for two seconds, as Swift's button does.
    copied_code: Option<(SharedString, u64)>,
    copy_presses: u64,
    tick: u64,
    /// Each lines run's rows per line, by its text and width.
    run_rows: HashMap<(RowKey, &'static str), (f32, String, Vec<usize>)>,
    /// Where each lines piece last stood.
    places: HashMap<(RowKey, &'static str), Placed>,
    /// What each card's lines section last drew, for checks.
    #[cfg(test)]
    drawn_lines: HashMap<String, DrawnLines>,
}
/// A lines section as it was last drawn: each run's editor section and its
/// marks (and whether each is tinted), and the middle line.
#[cfg(test)]
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct DrawnLines {
    pub runs: Vec<(&'static str, Vec<(String, bool)>)>,
    pub more: Option<String>,
}
/// A reply's reasoning as Swift's Think row opens it: Markdown in the
/// reasoning style (13 pt, muted), the whole width, drawn whole.
fn reasoning_markdown(
    reasoning: &str,
    selector: &str,
    tool_editors: &Rc<RefCell<ToolEditors>>,
    child: &WeakEntity<TranscriptView>,
    p: Palette,
    width: Pixels,
    window: &Window,
) -> impl IntoElement {
    let style = bello_agent_core::markdown::Style::REASONING;
    let owner = format!("{selector}-think");
    let (blocks, shapes, copied) = {
        let mut editors = tool_editors.borrow_mut();
        (
            editors.markdown(&SharedString::from(owner.clone()), reasoning, style),
            editors.shaped_text.clone(),
            editors.copied_code.as_ref().map(|(key, _)| key.clone()),
        )
    };
    let muted = rgb(if p.dark { 0xa9a59b } else { 0x6e6a61 }).into();
    markdown_view::render(
        &blocks,
        style,
        &markdown_view::Context {
            cache: &shapes,
            owner: &owner,
            palette: p,
            window,
            prose_width: None,
            column: Some(row_width(width) - work_line::INDENT),
            copied,
            on_copy: copy_code(tool_editors, child),
            text: Some(muted),
        },
        &markdown_view::Placement {
            slots: &[],
            visible: None,
        },
    )
    .0
}
/// Where a reply's drawn blocks landed (their slots, from the column's top)
/// and where its spacers and column are, for the frame's settling.
fn record_reply_slots(
    editors: &Rc<RefCell<ToolEditors>>,
    owner: &SharedString,
    children: &[markdown_view::Child],
    bounds: &[Bounds<Pixels>],
    frame: u64,
    row: usize,
) {
    let Some(column_top) = bounds.first().map(|first| first.top()) else {
        return;
    };
    let mut editors = editors.borrow_mut();
    let Some(entry) = editors.markdown.get_mut(owner) else {
        return;
    };
    let mut spacers = Vec::new();
    for (child, bounds) in children.iter().zip(bounds) {
        let slot = (
            f32::from(bounds.top() - column_top),
            f32::from(bounds.bottom() - column_top),
        );
        match child {
            markdown_view::Child::Block(index) => {
                if let Some(known) = entry.place.slots.get_mut(*index) {
                    *known = Some(slot);
                }
            }
            markdown_view::Child::Spacer => spacers.push(slot),
        }
    }
    entry.place.drawn = (frame > 0).then_some(Drawn {
        frame,
        row,
        column_top,
        spacers,
    });
    #[cfg(test)]
    {
        entry.place.children = children.to_vec();
    }
}

/// A fence's Copy: the code to the clipboard, and the button reads "Copied"
/// until two seconds pass or another fence is copied.
fn copy_code(
    editors: &Rc<RefCell<ToolEditors>>,
    transcript: &WeakEntity<TranscriptView>,
) -> markdown_view::CopyCode {
    let (editors, transcript) = (editors.clone(), transcript.clone());
    Rc::new(move |key, code, cx| {
        cx.write_to_clipboard(ClipboardItem::new_string(code.to_owned()));
        let press = {
            let mut editors = editors.borrow_mut();
            editors.copy_presses += 1;
            editors.copied_code = Some((key, editors.copy_presses));
            editors.copy_presses
        };
        let _ = transcript.update(cx, |_, cx| cx.notify());
        let (editors, transcript) = (editors.clone(), transcript.clone());
        let reset = cx
            .background_executor()
            .timer(std::time::Duration::from_secs(2));
        cx.spawn(async move |cx| {
            reset.await;
            let current = editors
                .borrow()
                .copied_code
                .as_ref()
                .is_some_and(|(_, at)| *at == press);
            if current {
                editors.borrow_mut().copied_code = None;
                let _ = transcript.update(cx, |_, cx| cx.notify());
            }
        })
        .detach();
    })
}
/// A row's parsed Markdown, kept while its text and style are unchanged.
struct MarkdownEntry {
    text: String,
    style: bello_agent_core::markdown::Style,
    blocks: Rc<Vec<bello_agent_core::markdown::Block>>,
    used: u64,
    place: ReplyPlace,
}
/// A frame that drew a reply: its row, the column's top in the window, and
/// the spacers it drew (column coordinates).
struct Drawn {
    frame: u64,
    row: usize,
    column_top: Pixels,
    spacers: Vec<(f32, f32)>,
}

/// What a reply's last frame drew, for tests.
#[cfg(test)]
pub(crate) struct ReplyLayout {
    pub slots: Vec<markdown_view::Slot>,
    pub text_top: Option<f32>,
    pub children: Vec<markdown_view::Child>,
    pub whole: bool,
}

/// Where a reply's top-level blocks were drawn, for drawing only those near
/// the viewport. Slots stay while their block and every block before it are
/// unchanged and the width is the same.
#[derive(Default)]
struct ReplyPlace {
    width: Option<Pixels>,
    slots: Vec<markdown_view::Slot>,
    /// The column's top from its row's top.
    text_top: Option<f32>,
    /// The last frame that drew the reply.
    drawn: Option<Drawn>,
    /// A spacer was on screen: the next frame draws every block.
    whole: bool,
    /// What the last frame drew: each child of the column.
    #[cfg(test)]
    children: Vec<markdown_view::Child>,
}
const MARKDOWN_LIMIT: usize = 256;
struct ToolEditor {
    row_index: usize,
    editor: Entity<EditorView>,
    style: ToolEditorStyle,
    used: u64,
    find_installed: Option<Rc<crate::transcript_find_presentation::FindPaint>>,
    /// A run of a lines section: where its block last stood in the window,
    /// and how many of the editor's rows each of its lines takes.
    lines: Option<LinesPlace>,
    /// The width a lines run's texts wrap at.
    lines_width: f32,
}
/// Where a lines run's block last stood, and its lines' rows.
type LinesPlace = (Placed, Vec<usize>);
/// Where a lines piece last stood in the window.
type Placed = Rc<std::cell::Cell<Option<Bounds<Pixels>>>>;
#[derive(Clone, Copy, PartialEq)]
struct ToolEditorStyle {
    palette: Palette,
    tone: Tone,
    /// A terminal's output scrolls past 224 points, any other section past 150.
    terminal: bool,
    /// A diff's or a read's lines: as tall as they are, their marks beside them.
    uncapped: bool,
}
/// What a card's payload is set in (`TranscriptNativeCards`): a request or a
/// result muted, a command or a diff's and a read's lines in the text colour,
/// a failure's result red.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tone {
    Muted,
    Text,
    Danger,
}
impl ToolEditorStyle {
    fn cap(self) -> f32 {
        if self.uncapped {
            f32::INFINITY
        } else if self.terminal {
            TERMINAL_CAP
        } else {
            tool_presentation::SECTION_CAP
        }
    }
}
/// `TranscriptCardFaces.code`: the system's monospaced face (SF Mono).
const CARD_MONO: &str = if cfg!(target_os = "macos") {
    ".AppleSystemUIFontMonospaced"
} else {
    "DejaVu Sans Mono"
};
/// `TranscriptCardMetrics.terminalCap`.
const TERMINAL_CAP: f32 = 224.;
impl ToolEditors {
    /// How many editor rows each of a run's lines takes, kept while the
    /// run's text and width are unchanged.
    fn run_rows(
        &mut self,
        key: &RowKey,
        label: &'static str,
        text: &str,
        width: f32,
        measure: impl FnOnce() -> Vec<usize>,
    ) -> Vec<usize> {
        let slot = (key.clone(), label);
        if let Some((known, known_text, rows)) = self.run_rows.get(&slot)
            && *known == width
            && known_text == text
        {
            return rows.clone();
        }
        if self.run_rows.len() >= 256 {
            self.run_rows.clear();
        }
        let rows = measure();
        self.run_rows
            .insert(slot, (width, text.to_owned(), rows.clone()));
        rows
    }
    /// Where a lines piece last stood in the window, kept for its row.
    fn place(
        &mut self,
        key: &RowKey,
        label: &'static str,
    ) -> Rc<std::cell::Cell<Option<Bounds<Pixels>>>> {
        if self.places.len() >= 4096 {
            self.places.clear();
        }
        self.places.entry((key.clone(), label)).or_default().clone()
    }
    fn active_find(&self) -> Option<Rc<crate::transcript_find_presentation::FindPaint>> {
        self.sidebar.clone().or_else(|| self.find.clone())
    }
    /// `text` read as Markdown, parsed again only when it changed (a reply
    /// still streaming), least recently drawn rows forgotten first.
    fn markdown(
        &mut self,
        owner: &SharedString,
        text: &str,
        style: bello_agent_core::markdown::Style,
    ) -> Rc<Vec<bello_agent_core::markdown::Block>> {
        self.tick += 1;
        if let Some(entry) = self.markdown.get_mut(owner)
            && entry.style == style
            && entry.text == text
        {
            entry.used = self.tick;
            return entry.blocks.clone();
        }
        let blocks = Rc::new(bello_agent_core::markdown::parse(text, style));
        // A reply that grew keeps the slots of the blocks before its change.
        let place = match self.markdown.remove(owner) {
            Some(old) if old.style == style => {
                let mut place = old.place;
                let same = old
                    .blocks
                    .iter()
                    .zip(blocks.iter())
                    .take_while(|(old, new)| old == new)
                    .count();
                place.slots.truncate(same);
                place
            }
            _ => ReplyPlace::default(),
        };
        if self.markdown.len() >= MARKDOWN_LIMIT {
            let oldest = self
                .markdown
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(key, _)| key.clone());
            if let Some(oldest) = oldest {
                self.markdown.remove(&oldest);
            }
        }
        self.markdown.insert(
            owner.clone(),
            MarkdownEntry {
                text: text.to_owned(),
                style,
                blocks: blocks.clone(),
                used: self.tick,
                place,
            },
        );
        blocks
    }
    /// The slots a reply's blocks were last drawn in at this width, where its
    /// column sits in its row, and whether it must be drawn whole.
    fn placement(
        &mut self,
        owner: &SharedString,
        width: Pixels,
    ) -> (Vec<markdown_view::Slot>, Option<f32>, bool) {
        let Some(entry) = self.markdown.get_mut(owner) else {
            return (Vec::new(), None, true);
        };
        let place = &mut entry.place;
        if place.width != Some(width) {
            *place = ReplyPlace {
                width: Some(width),
                ..ReplyPlace::default()
            };
        }
        place.slots.resize(entry.blocks.len(), None);
        (place.slots.clone(), place.text_top, place.whole)
    }
    /// After the list's layout: where each reply drawn this frame sits in its
    /// row, and whether a spacer of one turned out to be on screen (the
    /// reply is then drawn whole on the next frame, which this asks for).
    fn settle_replies(&mut self, frame: u64, viewport: Bounds<Pixels>, list: &ListState) -> bool {
        let mut missed = false;
        for entry in self.markdown.values_mut() {
            let place = &mut entry.place;
            let Some(Drawn {
                row,
                column_top,
                spacers,
                ..
            }) = place.drawn.take_if(|drawn| drawn.frame == frame)
            else {
                continue;
            };
            if let Some(item) = list.bounds_for_item(row) {
                place.text_top = Some(f32::from(column_top - item.top()));
            }
            let visible =
                f32::from(viewport.top() - column_top)..f32::from(viewport.bottom() - column_top);
            place.whole = spacers
                .iter()
                .any(|&(top, bottom)| bottom > visible.start && top < visible.end);
            missed |= place.whole;
        }
        missed
    }
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
        let p = style.palette;
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
                editor.set_appearance(tool_editor_appearance(p, style.tone), cx);
                editor
            });
            self.entries.insert(
                key.clone(),
                ToolEditor {
                    row_index,
                    editor,
                    style,
                    used: self.tick,
                    find_installed: None,
                    lines: None,
                    lines_width: 0.,
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
                entry.find_installed = None;
            }
            if entry.style != style {
                editor.set_appearance(tool_editor_appearance(p, style.tone), cx);
            }
            editor
                .measured_content_height(width.max(1.), window)
                .clamp(17., style.cap())
        });
        entry.style = style;
        (entry.editor.clone(), height)
    }
}
fn find_host_geometry_current(
    find: &crate::transcript_find_presentation::FindPaint,
    viewport: &ViewportState,
    index: usize,
) -> bool {
    let Some(crate::transcript_find_presentation::HostGeometry {
        origin,
        viewport: bounds,
        row,
    }) = *find.host_geometry.borrow()
    else {
        return false;
    };
    let now = viewport.list.logical_scroll_top();
    now.item_ix == origin.item_ix
        && now.offset_in_item == origin.offset_in_item
        && viewport.list.viewport_bounds() == bounds
        && row.is_some()
        && viewport.list.bounds_for_item(index) == row
}

fn sidebar_input_matches(
    presentation: &Presentation,
    index: usize,
    hit: &bello_agent_core::sidebar_search::OwnedHit,
) -> bool {
    match presentation.rows[index].projected {
        Some(ProjectedRow::Call {
            assistant, call, ..
        }) => {
            let session = &presentation.input.session;
            session.messages[assistant].id == hit.key().message_id
                && hit.key().call_id.as_deref()
                    == Some(
                        tool_presentation::call_at(session, assistant, call)
                            .id
                            .as_str(),
                    )
        }
        _ => false,
    }
}
fn sidebar_input_span(
    shown: Option<&str>,
    range: &std::ops::Range<usize>,
    canonical: bool,
) -> Result<std::ops::Range<usize>, &'static str> {
    let Some(shown) = shown else {
        return Err("This card omits the retained input preview; showing its owning card.");
    };
    if !canonical {
        return Err(
            "This card transforms its input preview; showing the owning card rather than an invented character range.",
        );
    }
    if range.start <= range.end
        && range.end <= shown.len()
        && shown.is_char_boundary(range.start)
        && shown.is_char_boundary(range.end)
    {
        Ok(range.clone())
    } else {
        Err("The input match is outside this card’s displayed preview; showing its owning card.")
    }
}

#[allow(clippy::too_many_arguments)]
fn decorate_find_tool(
    presentation: &Presentation,
    index: usize,
    label: &'static str,
    shown: &str,
    // A read's run of lines: where `shown` starts in the result's text, and
    // every run the card shows.
    slice: Option<(usize, &[std::ops::Range<usize>])>,
    canonical_input: bool,
    editor: &Entity<EditorView>,
    editors: &Rc<RefCell<ToolEditors>>,
    child: &WeakEntity<TranscriptView>,
    window: &mut Window,
    cx: &mut App,
) {
    let find = editors.borrow().active_find();
    let Some(find) = find else {
        return;
    };
    // A capped list's tail is its section's too.
    let section = card_lines::section_of(label);
    if !find.matches_binding(presentation.input.find_binding.as_ref()) {
        editor.update(cx, |e, cx| {
            let _ = e.set_text_presentation(None, cx);
        });
        return;
    }
    let row = &presentation.rows[index];
    let source = row
        .projected
        .and_then(|p| p.result())
        .map(|i| &presentation.input.session.messages[i]);
    let key = (row.key.clone(), label);
    if section == "OUT" && source.is_some_and(|m| find.has_record(&m.id) && !find.scope_matches(m))
    {
        editor.update(cx, |e, cx| {
            let _ = e.set_text_presentation(None, cx);
        });
        if let Some(entry) = editors.borrow_mut().entries.get_mut(&key) {
            entry.find_installed = None;
        }
        *find.notice.borrow_mut() = Some(
            "This tool preview changed. Choose the match again after the conversation settles."
                .into(),
        );
        return;
    }
    let installed = editors
        .borrow()
        .entries
        .get(&key)
        .and_then(|e| e.find_installed.as_ref())
        .is_some_and(|old| Rc::ptr_eq(old, &find));
    if installed {
        return;
    }
    let mut selected = None;
    let mut leads = true;
    // A read match running past this piece: the text beyond it.
    let mut beyond = String::new();
    let mut decorations = vec![];
    if section == "IN"
        && let Some(hit) = find.sidebar_input()
        && sidebar_input_matches(presentation, index, hit)
        && let bello_agent_core::sidebar_search::projection::SourceTarget::ToolInput(range) =
            hit.target()
    {
        match sidebar_input_span(Some(shown), range, canonical_input) {
            Ok(range) => selected = Some(range),
            Err(notice) => *find.notice.borrow_mut() = Some(notice.into()),
        }
    }

    if section == "OUT"
        && let Some(source) = source
        && let Some(ranges) = find.ranges(&source.id)
    {
        let prefix = source.text.len().min(tool_presentation::PREVIEW_BYTES);
        let mut prefix = prefix.min(shown.len());
        while !source.text.is_char_boundary(prefix) {
            prefix -= 1;
        }
        let generic_verified = shown.starts_with(&source.text[..prefix]);
        // A read's lines are exact slices of its result: a match maps by its
        // offset, once the slice is the retained text byte for byte.
        let slice_verified = slice
            .is_some_and(|(start, _)| source.text.get(start..start + shown.len()) == Some(shown));
        let map = |range: &std::ops::Range<usize>| {
            if let Some((start, _)) = slice {
                // A match running across pieces shows its part in each.
                let (low, high) = (range.start.max(start), range.end.min(start + shown.len()));
                (slice_verified && low < high).then(|| low - start..high - start)
            } else {
                (generic_verified && range.end <= prefix).then_some(range.clone())
            }
        };
        decorations = crate::transcript_find_presentation::merge_ranges(
            ranges.all.iter().filter_map(map).collect(),
        );
        selected = ranges.selected.as_ref().and_then(map);
        if let (Some((start, _)), Some(full)) = (slice, ranges.selected.as_ref()) {
            let end = start + shown.len();
            if full.end > end {
                beyond = source
                    .text
                    .get(end..full.end)
                    .unwrap_or_default()
                    .to_owned();
            }
        }
        // The piece the selected match starts in is the one that lands it.
        leads = slice.is_none_or(|(start, _)| {
            ranges.selected.as_ref().is_some_and(|selected| {
                selected.start >= start && selected.start < start + shown.len()
            })
        });
        // The match another of the card's runs draws is that run's to show.
        let elsewhere = slice.is_some_and(|(_, runs)| {
            ranges.selected.as_ref().is_some_and(|selected| {
                runs.iter()
                    .any(|run| selected.start >= run.start && selected.end <= run.end)
            })
        });
        if ranges.selected.is_some() && selected.is_none() && !elsewhere {
            *find.notice.borrow_mut() = Some("Match is outside this card’s displayed preview; showing its row. Full retained text remains searchable.".into());
        } else if ranges.limited {
            *find.notice.borrow_mut() = Some("Only the first 4096 matches in this output are softly highlighted; the selected occurrence is still revealed.".into());
        }
        if let Some(destination) = find.destination.clone()
            && leads
            && destination.found.id == source.id
            && !ranges.limited
            && selected.is_some()
        {
            let parent = child.upgrade().map(|c| c.read(cx).parent.clone());
            if let Some(parent) = parent {
                let count = ranges.total;
                window.defer(cx, move |_, cx| {
                    let _ = parent.update(cx, |v, cx| v.find_render_count(&destination, count, cx));
                });
            }
        }
    }
    let presentation_value = TextPresentation {
        token: find.serial,
        text: Arc::from(shown),
        decorations: decorations
            .into_iter()
            .map(|range| TextDecoration {
                range,
                color: rgba(0xe6a83b44).into(),
            })
            .collect(),
        emphasized: selected.clone().map(|range| TextDecoration {
            range,
            color: rgba(0xe6a83b99).into(),
        }),
    };
    let installed = editor.update(cx, |editor, cx| {
        editor.set_text_presentation(Some(presentation_value), cx)
    });
    if let Err(error) = installed {
        *find.notice.borrow_mut() = Some(format!(
            "Couldn’t decorate this preview: {error:?}. Showing its row."
        ));
        return;
    }
    if let Some(entry) = editors.borrow_mut().entries.get_mut(&key) {
        entry.find_installed = Some(find.clone());
    }
    if let Some(range) = selected
        && leads
        && find.navigating()
        && !find.measuring.get()
    {
        let Some(host) = child.upgrade() else {
            return;
        };
        let bound = host.read(cx).presentation.clone();
        if !std::ptr::eq(bound.as_ref(), presentation) {
            return;
        }
        if find.attempts.get() >= 3 {
            find.landed.set(true);
            find.complete_navigation();
            *find.notice.borrow_mut() = Some("The preview kept changing during navigation; showing its row. Choose the match again to retry.".into());
            return;
        }
        find.attempts.set(find.attempts.get() + 1);
        if slice.is_some() {
            // A read's lines are as tall as they are: nothing scrolls inside
            // them, and the match's place is the line's, from the lines'
            // own layout. The conversation goes there once the frame is drawn.
            let width = editors
                .borrow()
                .entries
                .get(&(row.key.clone(), label))
                .map(|entry| entry.lines_width);
            // A byte's line, and the editor row of that line it wraps onto.
            let position = |at: usize| {
                let line = shown[..at].matches('\n').count();
                let start = shown[..at].rfind('\n').map_or(0, |found| found + 1);
                let within = width.map_or(0, |width| {
                    card_lines::row_of(CARD_MONO, &shown[start..], at - start, width, window)
                });
                (line, within)
            };
            let first = position(range.start);
            let mut end = range.end.max(range.start + 1).min(shown.len()) - 1;
            while !shown.is_char_boundary(end) {
                end -= 1;
            }
            let last = position(end.max(range.start));
            // The match's rows past this piece, wrapped as the next pieces
            // wrap them (the text after this piece starts at a line's end).
            let past = match (width, beyond.strip_prefix('\n')) {
                (Some(width), Some(rest)) => {
                    card_lines::rows(CARD_MONO, rest.split('\n'), width, window)
                        .iter()
                        .sum()
                }
                _ => 0,
            };
            let (child, find, key) = (child.clone(), find.clone(), row.key.clone());
            window.defer(cx, move |_, cx| {
                let _ = child.update(cx, |view, cx| {
                    view.land_find_line(&find, index, &key, label, first, (last, past), cx)
                });
            });
            return;
        }
        find.measuring.set(true);
        find.host_row.set(Some(index));
        *find.host_geometry.borrow_mut() = None;
        let token = find.serial;
        let child = child.clone();
        let callback_find = find.clone();
        let window_id = window.window_handle().window_id();
        let size = window.viewport_size();
        let result = editor.update(cx, |editor, cx| {
            editor.reveal_presented_range(token, range.clone(), cx)?;
            editor.measure_presented_range(
                token,
                range,
                token,
                move |geometry, window, cx| {
                    let complete = move |window: &mut Window, cx: &mut App| {
                        callback_find.measuring.set(false);
                        let valid = geometry.token == token
                            && geometry.host_generation == token
                            && geometry.window_id == window_id
                            && window.viewport_size() == size;
                        let _ = child.update(cx, |view, cx| {
                            let current = view
                                .tool_editors
                                .borrow()
                                .active_find()
                                .as_ref()
                                .is_some_and(|f| Rc::ptr_eq(f, &callback_find));
                            if !current || !callback_find.navigating() {
                                return;
                            }
                            let geometry_current = find_host_geometry_current(
                                &callback_find,
                                &view.viewport.borrow(),
                                index,
                            );
                            if valid && geometry_current && Rc::ptr_eq(&view.presentation, &bound) {
                                view.land_find_point(
                                    &callback_find,
                                    index,
                                    geometry.first_visible_fragment.origin,
                                    geometry.first_visible_fragment.size.height,
                                    geometry.first_visible_fragment.size.height,
                                    cx,
                                );
                                if callback_find.landed.get() {
                                    let viewport = view.viewport.borrow();
                                    let bounds = viewport.list.viewport_bounds();
                                    let whole_card_visible = viewport.list.bounds_for_item(index).is_some_and(|row| row.top() >= bounds.top() && row.bottom() <= bounds.bottom());
                                    if !geometry.fully_visible || !whole_card_visible {
                                        *callback_find.notice.borrow_mut() = Some("Showing the first visible match fragment; the entire occurrence is not confirmed visible in this output.".into());
                                        cx.notify();
                                    }
                                }
                            } else {
                                // Reservation is released; the next fresh child render
                                // may re-arm at most three times, never spin forever.
                                for entry in view.tool_editors.borrow_mut().entries.values_mut() {
                                    entry.find_installed = None;
                                    entry.editor.update(cx, |editor, cx| {
                                        editor.invalidate_presentation_geometry(cx)
                                    });
                                }
                                cx.notify();
                            }
                        });
                    };
                    #[cfg(test)]
                    if FIND_GEOMETRY_PAUSED.with(|v| v.get()) {
                        FIND_GEOMETRY_CALLBACKS.with(|v| v.borrow_mut().push(Box::new(complete)));
                        return;
                    }
                    complete(window, cx);
                },
                cx,
            )
        });
        if let Err(error) = result {
            find.measuring.set(false);
            find.landed.set(true);
            find.complete_navigation();
            *find.notice.borrow_mut() = Some(format!(
                "Couldn’t reveal this preview: {error:?}. Showing its row."
            ));
        }
    }
}

fn tool_editor_appearance(p: Palette, tone: Tone) -> EditorAppearance {
    let colors = work_line::card_colors(&p);
    EditorAppearance {
        font_family: CARD_MONO.into(),
        font_size: 12.,
        line_height: 17.,
        padding_x: 0.,
        padding_y: 0.,
        text: match tone {
            Tone::Muted => colors.muted,
            Tone::Text => colors.text,
            Tone::Danger => colors.danger,
        },
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
    // Swift's work row (`TranscriptNativeActionRow`): the call's one line,
    // closed until the reader opens it, and its card under it.
    let model = tool_row::row_model(session, projected);
    let line = match &model {
        Some(model) => work_line::WorkLine {
            icon: model.icon,
            title: model.title.clone().into(),
            summary: model.summary.clone().into(),
            suffix: model.suffix.clone().map(Into::into),
            state: tool_row::work_state(model.state),
            expandable: true,
            open: row.expanded,
            trailing: model.trailing.clone().map(Into::into),
            follow: false,
            help: Some(model.help.clone().into()),
        },
        // A result whose call is not on this page reads as its own line.
        None => work_line::WorkLine {
            icon: "circle",
            title: "Tool result".into(),
            summary: name
                .strip_prefix("Tool result · ")
                .unwrap_or("")
                .to_owned()
                .into(),
            suffix: None,
            state: if status.is_error() {
                work_line::WorkState::Failed
            } else {
                work_line::WorkState::Ok
            },
            expandable: true,
            open: row.expanded,
            trailing: tool_presentation::elapsed(session, projected).map(Into::into),
            follow: false,
            help: None,
        },
    };
    // A sidebar hit on the tool's name: the line says what the call did, not
    // its name, so the row is the owner shown.
    if let Some(paint) = editors.borrow().active_find()
        && paint.matches_binding(presentation.input.find_binding.as_ref())
        && let Some(hit) = paint.sidebar_input()
        && sidebar_input_matches(presentation, index, hit)
        && matches!(
            hit.target(),
            bello_agent_core::sidebar_search::projection::SourceTarget::ToolName(_)
        )
    {
        *paint.notice.borrow_mut() =
            Some("This row transforms the tool name; showing its owning row.".into());
    }
    let link = model
        .as_ref()
        .filter(|model| model.links_summary && !model.summary.is_empty())
        .and_then(|model| model.file.as_ref())
        .map(|_| {
            let (child, key) = (child.clone(), row.key.clone());
            let (chat_id, controller) = (chat_id.clone(), controller.clone());
            Box::new(move |window: &mut Window, cx: &mut App| {
                let _ = child.update(cx, |view, cx| {
                    view.open_read_file(&key, &chat_id, &controller, window, cx)
                });
            }) as work_line::Link
        });
    let card = div()
        .debug_selector(|| selector.clone())
        .w_full()
        .max_w(px(ROW_MAX_WIDTH))
        .mx_auto()
        .min_w_0()
        .flex()
        .flex_col()
        .child(
            div()
                .pl(px(4.))
                .debug_selector(|| format!("{selector}-disclosure"))
                .child(work_line::work_line(
                    SharedString::from(format!("{selector}-disclosure")),
                    &line,
                    &p,
                    move |window, cx| {
                        let _ = disclosure_child.update(cx, |view, cx| {
                            view.toggle_tool(key.clone(), &chat_id, &controller, window, cx)
                        });
                    },
                    link,
                )),
        );
    if !row.expanded {
        return card;
    }
    // Swift's card (`TranscriptNativeCard`): one rounded panel with a
    // hairline, set in to the line's title, 2 points under the line and 8
    // above what follows.
    let colors = work_line::card_colors(&p);
    let mut panel = div()
        .debug_selector(|| format!("{selector}-card"))
        .ml(px(4. + work_line::INDENT))
        .mt(px(2.))
        .mb(px(8.))
        .min_w_0()
        .flex()
        .flex_col()
        .rounded(px(12.))
        .border_1()
        .border_color(colors.hair)
        .bg(colors.code_background)
        .overflow_hidden();
    let shown_output = projected
        .result()
        .map(|index| tool_presentation::display_text(&session.messages[index]))
        .or_else(|| {
            tool_presentation::live(session, projected)
                .map(|view| std::borrow::Cow::Borrowed(view.preview.as_ref()))
        });
    let edit_preview =
        editors
            .borrow_mut()
            .edit_previews
            .get(&row.key, session, projected, row.read_expanded);
    if let Some(edit) = &edit_preview {
        input = Some(tool_presentation::Preview {
            // A diff's rows are drawn as lines below; this is only what
            // stands in the section of a change too large to diff.
            text: if edit.too_large {
                edit.text(row.read_expanded).to_owned()
            } else {
                edit.rows.clone()
            },
            truncated: false,
        });
    }
    let read_call = read_presentation::read_call(session, projected);
    let read_window = read_call.and_then(|call| {
        let text = shown_output.as_deref()?;
        (!text.is_empty()).then(|| read_presentation::ReadWindow::new(text, &call.arguments))
    });
    if read_window.is_some() {
        input = None;
    }
    if input.is_none()
        && let Some(paint) = editors.borrow().active_find()
        && let Some(hit) = paint.sidebar_input()
        && sidebar_input_matches(presentation, index, hit)
        && let bello_agent_core::sidebar_search::projection::SourceTarget::ToolInput(range) =
            hit.target()
        && let Err(notice) = sidebar_input_span(None, range, true)
    {
        *paint.notice.borrow_mut() = Some(notice.into());
    }

    let read_link = read_presentation::file_link(session, projected)
        .or_else(|| edit_presentation::file_link(session, projected));
    // A change's card is its diff; what a change that did not land printed
    // stays under it, but an empty result says nothing there.
    let output = shown_output
        .as_deref()
        .filter(|text| {
            edit_preview.is_none()
                || (status != tool_presentation::Status::Completed && !text.is_empty())
        })
        .map(|text| {
            if read_window.is_some() {
                // The window's lines are drawn below, each an exact slice of
                // the result, without the generic 8 KiB prefix.
                return tool_presentation::Preview {
                    text: String::new(),
                    truncated: false,
                };
            }
            tool_presentation::preview(if text.is_empty() {
                bello_agent_core::tool_history::EMPTY_RESULT
            } else {
                text
            })
        });
    // A command opens as Swift's terminal: `$ command` over what it printed.
    let terminal = model
        .as_ref()
        .is_some_and(|model| model.kind == tool_row::ActionKind::Command)
        && edit_preview.is_none()
        && read_window.is_none()
        && matches!(projected, ProjectedRow::Call { .. });
    if terminal
        && let (
            Some(model),
            ProjectedRow::Call {
                assistant, call, ..
            },
        ) = (&model, projected)
    {
        let call = tool_presentation::call_at(session, assistant, call);
        input = Some(tool_presentation::preview(
            call.arguments["command"].as_str().unwrap_or(&model.object),
        ));
    }
    let truncated = input.as_ref().is_some_and(|preview| preview.truncated)
        || output.as_ref().is_some_and(|preview| preview.truncated);
    let rule = colors.hair;
    if read_window.is_some() || read_link.is_some() || edit_preview.is_some() {
        // The banner: what became of a change and its file, or a read's file
        // and how much of it the card shows.
        let mut header = div()
            .w_full()
            .min_w_0()
            .border_b_1()
            .border_color(rule)
            .px(px(16.))
            .py(px(8.))
            .flex()
            .items_center()
            .gap(px(8.));
        if let Some(edit) = &edit_preview {
            let tint = match status {
                tool_presentation::Status::Completed => colors.muted,
                tool_presentation::Status::Failed | tool_presentation::Status::NotExecuted => {
                    colors.danger
                }
                _ => colors.warning,
            };
            header = header
                .child(
                    div()
                        .debug_selector(|| format!("{selector}-edit-label"))
                        .flex_shrink_0()
                        .font_weight(FontWeight::MEDIUM)
                        .text_size(px(11.5))
                        .text_color(tint)
                        .child(edit.label.clone()),
                )
                .child(div().flex_1());
        }
        if let Some(link) = read_link {
            let path_selector = format!(
                "{selector}-{}-path",
                if edit_preview.is_some() {
                    "edit"
                } else {
                    "read"
                }
            );
            let child = child.clone();
            let key = row.key.clone();
            let chat_id = presentation.input.chat_id.clone();
            let controller = presentation.input.controller.clone();
            header = header.child(
                div()
                    .id(SharedString::from(path_selector.clone()))
                    .debug_selector(|| path_selector.clone())
                    .when(edit_preview.is_none(), |d| d.flex_1())
                    .min_w_0()
                    .text_size(px(11.5))
                    .text_color(if edit_preview.is_some() {
                        colors.faint
                    } else {
                        colors.muted
                    })
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
                    .text_color(colors.faint)
                    .child(read.window_label(row.read_expanded)),
            );
        }
        panel = panel.child(header);
    }
    // The panel's inner width: its 16-point sides and hairline border.
    let inner =
        (f32::from(width) - 2. * ROW_GUTTER).min(ROW_MAX_WIDTH) - 4. - work_line::INDENT - 2. - 32.;
    let sections = [("IN", input), ("OUT", output)];
    let shown = sections
        .iter()
        .filter(|(_, preview)| preview.is_some())
        .count();
    for (position, (label, preview)) in sections
        .into_iter()
        .filter_map(|(label, preview)| Some((label, preview?)))
        .enumerate()
    {
        // A diff's and a read's lines: Swift's `TranscriptCardLines`.
        let diff = edit_preview
            .as_ref()
            .filter(|edit| label == "IN" && !edit.too_large);
        let read = read_window.as_ref().filter(|_| label == "OUT");
        if diff.is_some() || read.is_some() {
            let spec = match (diff, read) {
                (Some(edit), _) => diff_lines(edit, status, row.read_expanded, &colors),
                (_, Some(read)) => read_lines(read, status, row.read_expanded, &colors),
                _ => unreachable!("lines"),
            };
            panel = panel.child(
                lines_section(
                    presentation,
                    index,
                    spec,
                    inner,
                    &selector,
                    editors,
                    child,
                    window,
                    cx,
                )
                .when(position + 1 < shown, |d| d.border_b_1())
                .border_color(rule),
            );
            continue;
        }
        // A change too large to diff says so in its section; a terminal's
        // command stands after its prompt; everything else beside its IN/OUT
        // label.
        let lines = label == "IN" && edit_preview.is_some();
        let gutter = !lines && !terminal;
        let failed = label == "OUT" && status.is_error();
        let style = ToolEditorStyle {
            palette: p,
            tone: if failed {
                Tone::Danger
            } else if lines || (terminal && label == "IN") {
                Tone::Text
            } else {
                Tone::Muted
            },
            terminal: terminal && label == "OUT",
            uncapped: false,
        };
        let prompt = if terminal && label == "IN" {
            7. + 8.
        } else {
            0.
        };
        let (editor, height) = editors.borrow_mut().section(
            (index, row.key.clone(), label),
            &preview.text,
            style,
            if gutter {
                inner - 30. - 14.
            } else {
                inner - prompt
            },
            window,
            cx,
        );
        decorate_find_tool(
            presentation,
            index,
            label,
            &preview.text,
            None,
            edit_preview.is_none() && read_window.is_none() && !terminal,
            &editor,
            editors,
            child,
            window,
            cx,
        );
        let mut section = div()
            .w_full()
            .min_w_0()
            .when(position + 1 < shown, |d| d.border_b_1())
            .border_color(rule)
            .px(px(16.))
            .py(px(if lines {
                0.
            } else if terminal {
                10.
            } else {
                12.
            }))
            .flex()
            .items_start();
        if gutter {
            section = section.gap(px(14.)).child(
                div()
                    .w(px(30.))
                    .flex_shrink_0()
                    .font_family(CARD_MONO)
                    .font_weight(FontWeight::MEDIUM)
                    .text_size(px(11.))
                    .text_color(colors.faint)
                    .child(label),
            );
        } else if prompt > 0. {
            section = section.gap(px(8.)).child(
                div()
                    .flex_shrink_0()
                    .font_family(CARD_MONO)
                    .text_size(px(12.))
                    .line_height(px(17.))
                    .text_color(colors.faint)
                    .child("$"),
            );
        }
        panel = panel.child(
            section.child(
                div()
                    .id(SharedString::from(format!("{selector}-{label}")))
                    .debug_selector(|| format!("{selector}-{label}"))
                    .flex_1()
                    .min_w_0()
                    .h(px(height))
                    .max_h(px(style.cap()))
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
    if let Some(note) = read_window.as_ref().and_then(|read| read.note) {
        panel = panel.child(
            div()
                .debug_selector(|| format!("{selector}-read-note"))
                .px(px(16.))
                .py(px(8.))
                .text_size(px(11.5))
                .text_color(colors.muted)
                .child(note.to_owned()),
        );
    }
    if let Some(edit) = edit_preview {
        // A change too large to diff opens its whole content from its foot.
        if edit.too_large {
            let child = child.clone();
            let key = row.key.clone();
            let chat_id = presentation.input.chat_id.clone();
            let controller = presentation.input.controller.clone();
            panel = panel.child(card_lines::more(
                format!("{selector}-edit-disclosure"),
                if row.read_expanded {
                    "Show fewer lines".to_owned()
                } else {
                    "View full content".to_owned()
                },
                colors.faint,
                colors.muted,
                CARD_MONO,
                move |_, cx| {
                    let _ = child.update(cx, |view, cx| {
                        view.toggle_read(key.clone(), &chat_id, &controller, cx)
                    });
                },
            ));
        }
        if let Some(footer) = &edit.footer {
            // `└ +3 −1`: the change's size at the diff's foot.
            let (plus, minus) = footer.split_once(' ').unwrap_or((footer, ""));
            panel = panel.child(
                div()
                    .debug_selector(|| format!("{selector}-edit-counts"))
                    .px(px(16.))
                    .py(px(6.))
                    .flex()
                    .text_size(px(12.))
                    .child(
                        div()
                            .font_family(CARD_MONO)
                            .text_color(colors.faint)
                            .child("└ "),
                    )
                    .child(div().text_color(colors.success).child(plus.to_owned()))
                    .child(div().text_color(colors.danger).child(format!(" {minus}"))),
            );
        }
    }
    if truncated {
        panel = panel.child(
            div()
                .px(px(16.))
                .py(px(10.))
                .text_size(px(11.5))
                .text_color(colors.muted)
                .child("Preview truncated; retained input and output are unchanged."),
        );
    }
    card.child(panel)
}

/// One run of a lines section: which of the editor sections draws it, its
/// text's place in the section's text, and each line's mark.
struct LinesRun<'a> {
    label: &'static str,
    bytes: std::ops::Range<usize>,
    lines: Vec<&'a str>,
    marks: Vec<card_lines::Mark>,
}
/// A diff's or a read's lines as Swift's card draws them.
struct LinesSpec<'a> {
    style: card_lines::Style,
    /// The text the runs are slices of.
    text: &'a str,
    runs: Vec<LinesRun<'a>>,
    /// The middle line: "… 8 more lines", or while every line shows, the
    /// way back; none for a list that never collapses.
    more: Option<(String, String)>,
    /// An expanded diff scrolls past the terminal's cap.
    scroll: bool,
    /// A change that did not land, or a read that failed, dims as one.
    dimmed: bool,
    /// A read's runs map a find's matches by offset.
    find: bool,
}

fn diff_lines<'a>(
    edit: &'a edit_presentation::EditPreview,
    status: tool_presentation::Status,
    expanded: bool,
    colors: &work_line::CardColors,
) -> LinesSpec<'a> {
    use edit_presentation::Kind;
    use tool_presentation::Status;
    let lines: Vec<&str> = edit.rows.split('\n').collect();
    let offset = |line: &str| line.as_ptr() as usize - edit.rows.as_ptr() as usize;
    let cap = card_lines::head_tail(lines.len(), card_lines::MAX_LINES, expanded);
    let collapses = card_lines::collapses(cap.hidden);
    let runs = card_lines::runs(lines.len(), cap)
        .into_iter()
        .enumerate()
        .filter(|(_, run)| !run.is_empty())
        .map(|(n, run)| LinesRun {
            label: if n == 0 { "IN" } else { "IN-tail" },
            bytes: offset(lines[run.start])..offset(lines[run.end - 1]) + lines[run.end - 1].len(),
            marks: edit.kinds[run.clone()]
                .iter()
                .map(|kind| match kind {
                    Kind::Added => card_lines::Mark {
                        text: "+".into(),
                        color: colors.diff_added_mark,
                        background: Some(colors.diff_added),
                    },
                    Kind::Removed => card_lines::Mark {
                        text: "−".into(),
                        color: colors.danger,
                        background: Some(Hsla {
                            a: 0.1,
                            ..colors.danger
                        }),
                    },
                    Kind::Context => card_lines::Mark {
                        text: " ".into(),
                        color: colors.faint,
                        background: None,
                    },
                })
                .collect(),
            lines: lines[run].to_vec(),
        })
        .collect();
    LinesSpec {
        style: card_lines::Style::Diff,
        text: &edit.rows,
        runs,
        more: collapses.then(|| {
            (
                "edit-disclosure".into(),
                if cap.capped {
                    card_lines::more_lines(cap.hidden)
                } else {
                    "Show fewer lines".into()
                },
            )
        }),
        scroll: !cap.capped && expanded,
        dimmed: matches!(
            status,
            Status::Failed | Status::NotExecuted | Status::Cancelled | Status::Unknown
        ),
        find: false,
    }
}

fn read_lines<'a>(
    read: &'a read_presentation::ReadWindow<'a>,
    status: tool_presentation::Status,
    expanded: bool,
    colors: &work_line::CardColors,
) -> LinesSpec<'a> {
    let cap = read.head_tail(expanded);
    let runs = read
        .parts(expanded)
        .into_iter()
        .enumerate()
        .map(|(n, part)| LinesRun {
            label: if n == 0 { "OUT" } else { "OUT-tail" },
            marks: part
                .lines
                .clone()
                .map(|index| card_lines::Mark {
                    text: read.number(index).into(),
                    color: colors.faint,
                    background: None,
                })
                .collect(),
            lines: read.lines[part.lines].to_vec(),
            bytes: part.bytes,
        })
        .collect();
    LinesSpec {
        style: card_lines::Style::Numbered,
        text: read.text,
        runs,
        more: card_lines::collapses(cap.hidden).then(|| {
            (
                "read-disclosure".into(),
                if cap.capped {
                    card_lines::more_lines(cap.hidden)
                } else {
                    "Show fewer lines".into()
                },
            )
        }),
        scroll: false,
        dimmed: status == tool_presentation::Status::Failed,
        find: true,
    }
}

/// A diff's or a read's lines in their card: the head, the middle line, the
/// tail, each run one selectable editor beside its marks.
#[allow(clippy::too_many_arguments)]
fn lines_section(
    presentation: &Presentation,
    index: usize,
    spec: LinesSpec<'_>,
    inner: f32,
    selector: &str,
    editors: &Rc<RefCell<ToolEditors>>,
    child: &WeakEntity<TranscriptView>,
    window: &mut Window,
    cx: &mut App,
) -> Div {
    let row = &presentation.rows[index];
    let p = presentation.input.palette;
    let colors = work_line::card_colors(&p);
    // The panel's width less its sides and the marks: where the texts wrap.
    let text_width = (inner + 32. - spec.style.text_left() - 16.).max(1.);
    let style = ToolEditorStyle {
        palette: p,
        tone: Tone::Text,
        terminal: false,
        uncapped: true,
    };
    let all: Vec<std::ops::Range<usize>> = spec.runs.iter().map(|run| run.bytes.clone()).collect();
    #[cfg(test)]
    editors.borrow_mut().drawn_lines.insert(
        selector.to_owned(),
        DrawnLines {
            runs: spec
                .runs
                .iter()
                .map(|run| {
                    (
                        run.label,
                        run.marks
                            .iter()
                            .map(|mark| (mark.text.to_string(), mark.background.is_some()))
                            .collect(),
                    )
                })
                .collect(),
            more: spec.more.as_ref().map(|(_, label)| label.clone()),
        },
    );
    let mut section = div()
        .w_full()
        .min_w_0()
        .flex()
        .flex_col()
        .when(spec.dimmed, |d| d.opacity(0.72));
    // The card's selected find match, which its piece must draw to land on.
    let selected = spec
        .find
        .then(|| row.projected.and_then(|projected| projected.result()))
        .flatten()
        .and_then(|source| {
            let find = editors.borrow().active_find()?;
            let id = &presentation.input.session.messages[source].id;
            find.ranges(id)?.selected.clone()
        });
    let band = f32::from(window.viewport_size().height);
    for (n, run) in spec.runs.iter().enumerate() {
        let rows = editors.borrow_mut().run_rows(
            &row.key,
            run.label,
            &spec.text[run.bytes.clone()],
            text_width,
            || card_lines::rows(CARD_MONO, run.lines.iter().copied(), text_width, window),
        );
        let mut pieces = div().w_full().flex().flex_col();
        // A long run is drawn a piece at a time: only the pieces near the
        // window are editors, the rest stand aside at their height, so an
        // expanded read costs what is on screen.
        let offset = |line: &str| line.as_ptr() as usize - spec.text.as_ptr() as usize;
        for (k, lines) in card_lines::pieces(&rows).into_iter().enumerate() {
            let label = card_lines::piece_label(run.label, k);
            let last = run.lines[lines.end - 1];
            let bytes = offset(run.lines[lines.start])..offset(last) + last.len();
            let piece_rows = &rows[lines.clone()];
            let height = piece_rows.iter().sum::<usize>() as f32 * card_lines::LINE_HEIGHT;
            let placed = editors.borrow_mut().place(&row.key, label);
            // The piece the reader is typing or selecting in stays an editor.
            let focused = editors
                .borrow()
                .entries
                .get(&(row.key.clone(), label))
                .is_some_and(|entry| entry.editor.read(cx).focus_handle(cx).is_focused(window));
            let near = focused
                || placed.get().map_or(k < 4, |bounds| {
                    f32::from(bounds.bottom()) > -band && f32::from(bounds.top()) < 2. * band
                })
                || selected
                    .as_ref()
                    .is_some_and(|selected| bytes.contains(&selected.start));
            if !near {
                pieces = pieces.child(
                    div().relative().w_full().h(px(height)).child(
                        canvas(
                            move |bounds, window, _| {
                                placed.set(Some(bounds));
                                // A piece standing aside that comes near is
                                // drawn on the next frame.
                                let band = window.viewport_size().height;
                                if bounds.bottom() > -band && bounds.top() < band * 2. {
                                    window.request_animation_frame();
                                }
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full(),
                    ),
                );
                continue;
            }
            let shown = &spec.text[bytes.clone()];
            let (editor, measured) = editors.borrow_mut().section(
                (index, row.key.clone(), label),
                shown,
                style,
                text_width,
                window,
                cx,
            );
            if let Some(entry) = editors
                .borrow_mut()
                .entries
                .get_mut(&(row.key.clone(), label))
            {
                // Where the piece stands and wraps, for a find landing on it.
                entry.lines_width = text_width;
                entry.lines = Some((placed.clone(), piece_rows.to_vec()));
            }
            decorate_find_tool(
                presentation,
                index,
                label,
                shown,
                spec.find.then_some((bytes.start, all.as_slice())),
                false,
                &editor,
                editors,
                child,
                window,
                cx,
            );
            pieces = pieces.child(card_lines::render(
                format!("{selector}-{label}"),
                spec.style,
                &run.marks[lines.clone()],
                piece_rows,
                div()
                    .id(SharedString::from(format!("{selector}-{label}-text")))
                    .debug_selector({
                        let selector = format!("{selector}-{label}-text");
                        move || selector
                    })
                    .size_full()
                    .child(editor)
                    .into_any_element(),
                height.max(measured),
                placed,
            ));
        }
        let block = pieces;
        section = if n == 0 && spec.scroll {
            // Every line of a long diff, in a scroll of its own past the
            // terminal's cap. GPUI List registers its wheel listener after
            // children; exclude its hitbox while this scroller is hit.
            section.child(
                div()
                    .id(SharedString::from(format!(
                        "{selector}-{}-scroll",
                        run.label
                    )))
                    .debug_selector({
                        let selector = format!("{selector}-{}-scroll", run.label);
                        move || selector
                    })
                    .w_full()
                    .max_h(px(TERMINAL_CAP))
                    .overflow_y_scroll()
                    .occlude()
                    .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
                    .child(block),
            )
        } else {
            section.child(block)
        };
        if n == 0
            && let Some((name, label)) = spec.more.clone()
        {
            let child = child.clone();
            let key = row.key.clone();
            let chat_id = presentation.input.chat_id.clone();
            let controller = presentation.input.controller.clone();
            section = section.child(card_lines::more(
                format!("{selector}-{name}"),
                label,
                colors.faint,
                colors.muted,
                CARD_MONO,
                move |_, cx| {
                    let _ = child.update(cx, |view, cx| {
                        view.toggle_read(key.clone(), &chat_id, &controller, cx)
                    });
                },
            ));
        }
    }
    section
}

#[cfg(test)]
mod sidebar_preview_tests {
    use super::sidebar_input_span;
    #[test]
    fn exact_input_mapping_rejects_transformed_omitted_and_truncated_previews() {
        assert_eq!(
            sidebar_input_span(Some("日本 needle"), &(7..13), true),
            Ok(7..13)
        );
        assert!(
            sidebar_input_span(Some("日本 needle"), &(1..4), true)
                .unwrap_err()
                .contains("outside")
        );
        assert!(
            sidebar_input_span(Some("needle"), &(0..6), false)
                .unwrap_err()
                .contains("transforms")
        );
        assert!(
            sidebar_input_span(None, &(0..6), true)
                .unwrap_err()
                .contains("omits")
        );
        assert!(
            sidebar_input_span(Some("nee"), &(0..6), true)
                .unwrap_err()
                .contains("outside")
        );
    }
}
