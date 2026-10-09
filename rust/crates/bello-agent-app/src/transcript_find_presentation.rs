//! Transient exact-text decorations; source occurrences are never confused with
//! generated line numbers, input arguments or omitted preview suffixes.
use crate::transcript_find_search::{MAX_RANGE_PAGE, Query};
use crate::transcript_find_state::{Destination, Match};
use gpui::{HighlightStyle, StyledText, TextLayout, *};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    ops::Range,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Clone)]
pub(crate) struct Ranges {
    pub all: Vec<Range<usize>>,
    pub selected: Option<Range<usize>>,
    pub limited: bool,
    pub total: usize,
    pub numbered: Arc<crate::transcript_find_numbered::NumberedPreviewMap>,
    pub role: String,
    pub tool_owner: Option<(String, String)>,
    pub sidebar_input: Option<bello_agent_core::sidebar_search::OwnedHit>,
}
#[derive(Clone, Copy)]
pub(crate) struct HostGeometry {
    pub origin: ListOffset,
    pub viewport: Bounds<Pixels>,
    pub row: Option<Bounds<Pixels>>,
}
pub(crate) struct FindPaint {
    pub notice: RefCell<Option<String>>,
    pub destination: Option<Destination>,
    pub serial: u64,
    pub owner: uuid::Uuid,
    lifetime_cancel: Arc<AtomicBool>,
    pub landed: Cell<bool>,
    sidebar_navigation_completed: Option<Rc<Cell<bool>>>,
    pub confirmed: Cell<bool>,
    #[cfg(test)]
    pub confirmed_geometry: Cell<Option<Bounds<Pixels>>>,
    pub measuring: Cell<bool>,
    pub attempts: Cell<u8>,
    pub host_row: Cell<Option<usize>>,
    pub host_geometry: RefCell<Option<HostGeometry>>,
    pub layouts: RefCell<Vec<(usize, TextLayout, Range<usize>)>>,
    source: bello_agent_core::retained_find::FindSnapshot,
    sidebar_admission: Option<Arc<bello_agent_core::sidebar_search::SearchAdmissionSlot>>,
    sidebar_ui_admission: Option<crate::sidebar_search_controller::RevealAdmission>,
    prepared: HashMap<String, Ranges>,
}
pub(crate) struct Prepared {
    source: bello_agent_core::retained_find::FindSnapshot,
    ranges: HashMap<String, Ranges>,
    notice: Option<String>,
}
/// Background-only preparation. No text copies: all source bytes stay in the
/// immutable session. Work and allocation are bounded independently of total hits.
pub(crate) fn prepare(
    query: &Query,
    source: bello_agent_core::retained_find::FindSnapshot,
    wanted: Vec<String>,
    current: Option<&Match>,
    cancel: &AtomicBool,
) -> Result<Prepared, String> {
    const MAX_ROWS: usize = 64;
    const MAX_SPANS: usize = 16_384;
    let mut indexes = HashMap::new();
    let omitted_rows = wanted.len() > MAX_ROWS;
    let selected_id = current.map(|m| m.id.clone());
    let wanted: HashSet<_> = selected_id
        .iter()
        .cloned()
        .chain(
            wanted
                .into_iter()
                .filter(|id| selected_id.as_ref() != Some(id)),
        )
        .take(MAX_ROWS)
        .collect();
    let session = source.session_shared();
    for (index, message) in session.messages.iter().enumerate() {
        if index % 1024 == 0 && cancel.load(Ordering::Acquire) {
            return Err("Find cancelled.".into());
        }
        if wanted.contains(&message.id) {
            indexes
                .entry(message.id.clone())
                .and_modify(|old| *old = None)
                .or_insert(Some(index));
        }
    }
    let mut ranges = HashMap::new();
    let mut budget = MAX_SPANS;
    let mut notice = omitted_rows.then(|| "Soft highlights cover at most 64 nearby records; the selected match is always reserved and all retained matches remain counted.".into());
    let mut ids: Vec<_> = indexes.keys().cloned().collect();
    ids.sort_by_key(|id| !current.is_some_and(|m| &m.id == id));
    for id in ids {
        if cancel.load(Ordering::Acquire) {
            return Err("Find cancelled.".into());
        }
        let Some(index) = indexes[&id] else {
            continue;
        };
        let text = &session.messages[index].text;
        if text.len() > 8 * 1024 * 1024 {
            notice = Some("A visible row exceeds the 8 MiB decoration limit; its retained matches remain counted and its row can be opened.".into());
            continue;
        }
        let maximum = budget.clamp(1, MAX_RANGE_PAGE);
        let page = query.ranges(text, 0, maximum, cancel)?;
        let selected = if let Some(found) = current.filter(|m| m.id == id) {
            if let Some(range) = page.ranges.get(found.occurrence) {
                Some(range.clone())
            } else {
                query
                    .ranges(text, found.occurrence, 1, cancel)?
                    .ranges
                    .into_iter()
                    .next()
            }
        } else {
            None
        };
        let soft = if budget == 0 { vec![] } else { page.ranges };
        budget = budget.saturating_sub(soft.len());
        let limited = soft.len() < page.total;
        if limited {
            notice = Some("Visible highlights are bounded to 4096 per row and 16384 in total; all retained occurrences remain counted and the selected match is highlighted separately.".into());
        }
        let soft = merge_ranges(soft);
        let numbered = Arc::new(crate::transcript_find_numbered::NumberedPreviewMap::new(
            text,
            &soft,
            selected.as_ref(),
            cancel,
        )?);
        ranges.insert(
            id,
            Ranges {
                all: soft,
                numbered,
                role: session.messages[index].role.clone(),
                tool_owner: match &session.messages[index].tool_record {
                    Some(bello_agent_core::tool_history::ToolRecord::Result(record)) => {
                        Some((record.assistant_id.clone(), record.call_id.clone()))
                    }
                    _ => None,
                },
                sidebar_input: None,
                selected,
                limited,
                total: page.total,
            },
        );
    }
    Ok(Prepared {
        source,
        ranges,
        notice,
    })
}
impl FindPaint {
    pub fn new(
        prepared: Prepared,
        _current: Option<Match>,
        destination: Option<Destination>,
        serial: u64,
        owner: uuid::Uuid,
        lifetime_cancel: Arc<AtomicBool>,
    ) -> Rc<Self> {
        Rc::new(Self {
            notice: RefCell::new(prepared.notice),
            destination,
            serial,
            owner,
            lifetime_cancel,
            landed: Cell::new(false),
            sidebar_navigation_completed: None,
            confirmed: Cell::new(false),
            #[cfg(test)]
            confirmed_geometry: Cell::new(None),
            measuring: Cell::new(false),
            attempts: Cell::new(0),
            host_row: Cell::new(None),
            host_geometry: RefCell::new(None),
            layouts: RefCell::new(vec![]),
            source: prepared.source,
            sidebar_admission: None,
            sidebar_ui_admission: None,
            prepared: prepared.ranges,
        })
    }
    pub fn matches_binding(
        &self,
        binding: Option<&bello_agent_core::retained_find::FindSnapshot>,
    ) -> bool {
        !self.lifetime_cancel.load(Ordering::Acquire)
            && self
                .sidebar_ui_admission
                .as_ref()
                .is_none_or(|admission| admission.is_current())
            && self
                .sidebar_admission
                .as_ref()
                .is_none_or(|slot| slot.current().is_ok_and(|candidate| candidate.is_some()))
            && binding.is_some_and(|b| self.source.same_content(b))
    }
    pub(crate) fn complete_navigation(&self) {
        if self.matches_binding(Some(&self.source))
            && let Some(completed) = &self.sidebar_navigation_completed
        {
            completed.set(true);
        }
    }
    pub fn navigating(&self) -> bool {
        self.active_navigation()
    }
    pub fn active_navigation(&self) -> bool {
        !self.landed.get()
            && self.destination.as_ref().is_some_and(|d| {
                !d.search.cancellation().load(Ordering::Acquire)
                    && !d.navigation.cancellation().load(Ordering::Acquire)
            })
    }
    pub fn ranges(&self, id: &str) -> Option<Ranges> {
        self.prepared.get(id).cloned()
    }
    pub(crate) fn sidebar_input(&self) -> Option<&bello_agent_core::sidebar_search::OwnedHit> {
        self.prepared
            .values()
            .find_map(|ranges| ranges.sidebar_input.as_ref())
    }
    pub(crate) fn prose_target(&self, id: &str) -> bool {
        self.prepared
            .get(id)
            .is_some_and(|ranges| ranges.sidebar_input.is_none())
    }
    pub fn has_record(&self, id: &str) -> bool {
        self.prepared.contains_key(id)
    }
    pub fn scope_matches(&self, message: &bello_agent_core::Message) -> bool {
        let Some(ranges) = self.prepared.get(&message.id) else {
            return false;
        };
        let owner = match &message.tool_record {
            Some(bello_agent_core::tool_history::ToolRecord::Result(r)) => {
                Some((&r.assistant_id, &r.call_id))
            }
            _ => None,
        };
        ranges.role == message.role && ranges.tool_owner.as_ref().map(|(a, c)| (a, c)) == owner
    }
    pub fn prose(self: &Rc<Self>, id: &str, text: String, row: usize) -> FindText {
        let ranges = self.ranges(id);
        let mut highlights = Vec::new();
        if let Some(ranges) = &ranges {
            // Split around emphasized span to keep StyledText runs disjoint.
            let visual = merge_ranges(
                ranges
                    .all
                    .iter()
                    .cloned()
                    .chain(ranges.selected.clone())
                    .collect(),
            );
            for range in &visual {
                let mut pieces = vec![(range.clone(), false)];
                if let Some(selected) = &ranges.selected {
                    pieces.clear();
                    if range.start < selected.start {
                        pieces.push((range.start..range.end.min(selected.start), false));
                    }
                    if range.start < selected.end && range.end > selected.start {
                        pieces.push((
                            range.start.max(selected.start)..range.end.min(selected.end),
                            true,
                        ));
                    }
                    if range.end > selected.end {
                        pieces.push((range.start.max(selected.end)..range.end, false));
                    }
                }
                for (range, selected) in pieces {
                    if !range.is_empty() {
                        highlights.push((range, highlight(selected)));
                    }
                }
            }
        }
        let styled = StyledText::new(text).with_highlights(highlights);
        FindText {
            styled,
            find: self.clone(),
            row,
            selected: ranges.and_then(|r| r.selected),
        }
    }
}
fn highlight(selected: bool) -> HighlightStyle {
    HighlightStyle {
        background_color: Some(if selected {
            gpui::rgba(0xe6a83b99).into()
        } else {
            gpui::rgba(0xe6a83b44).into()
        }),
        ..Default::default()
    }
}
pub(crate) fn merge_ranges(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.sort_by_key(|r| (r.start, r.end));
    let mut out: Vec<Range<usize>> = vec![];
    for range in ranges {
        if let Some(last) = out.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
        } else {
            out.push(range);
        }
    }
    out
}
/// Publish geometry only after this exact text element actually painted. List
/// preflight measurements never contribute coordinates or trigger navigation.
pub(crate) struct FindText {
    styled: StyledText,
    find: Rc<FindPaint>,
    row: usize,
    selected: Option<Range<usize>>,
}
impl IntoElement for FindText {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}
impl Element for FindText {
    type RequestLayoutState = <StyledText as Element>::RequestLayoutState;
    type PrepaintState = <StyledText as Element>::PrepaintState;
    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        self.styled.request_layout(id, inspector, window, cx)
    }
    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.styled
            .prepaint(id, inspector, bounds, state, window, cx)
    }
    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.styled
            .paint(id, inspector, bounds, state, prepaint, window, cx);
        if self.find.navigating()
            && let Some(range) = self.selected.clone()
        {
            self.find
                .layouts
                .borrow_mut()
                .push((self.row, self.styled.layout().clone(), range));
        }
    }
}

/// Prepare exactly the already-admitted sidebar occurrence, using its byte
/// mapping rather than Find's independently normalized query semantics.
pub(crate) fn prepare_sidebar(
    source: bello_agent_core::retained_find::FindSnapshot,
    hit: &bello_agent_core::sidebar_search::OwnedHit,
    slot: &bello_agent_core::sidebar_search::SearchAdmissionSlot,
    cancel: &AtomicBool,
) -> Result<Prepared, String> {
    use bello_agent_core::sidebar_search::{projection::PieceKind, projection::SourceTarget};
    let candidate = slot
        .current()
        .map_err(|_| "Search source changed")?
        .ok_or("Search source changed")?;
    let session = source.session();
    let stamp = candidate.source_stamp();
    if session.id != stamp.session_id()
        || session.revision != stamp.revision()
        || session.stream_generation != stamp.stream_generation()
        || session.stream_sequence != stamp.stream_sequence()
    {
        return Err("Search display has not reached the accepted source".into());
    }
    let message = session
        .messages
        .get(hit.key().message_position)
        .filter(|m| m.id == hit.key().message_id)
        .ok_or("Search message identity changed")?;
    let input = hit.key().kind == PieceKind::ToolInput;
    let name = match &message.tool_record {
        Some(bello_agent_core::tool_history::ToolRecord::Assistant(record)) => record
            .calls
            .iter()
            .find(|call| hit.key().call_id.as_deref() == Some(call.id.as_str()))
            .map(|call| call.name.as_str()),
        _ => None,
    };
    let (text, selected) = match hit.target() {
        SourceTarget::Message(range) => (message.text.as_str(), Some(range.clone())),
        SourceTarget::ToolName(range) => (
            name.ok_or("Search tool identity changed")?,
            Some(range.clone()),
        ),
        _ => (message.text.as_str(), None),
    };
    if let Some(range) = &selected
        && (range.is_empty()
            || range.end > text.len()
            || !text.is_char_boundary(range.start)
            || !text.is_char_boundary(range.end))
    {
        return Err("Search range changed".into());
    }
    let numbered = Arc::new(crate::transcript_find_numbered::NumberedPreviewMap::new(
        text,
        &[],
        selected.as_ref(),
        cancel,
    )?);
    let owner = match &message.tool_record {
        Some(bello_agent_core::tool_history::ToolRecord::Result(result)) => {
            Some((result.assistant_id.clone(), result.call_id.clone()))
        }
        _ => None,
    };
    let mut ranges = HashMap::new();
    ranges.insert(
        message.id.clone(),
        Ranges {
            all: vec![],
            selected,
            limited: false,
            total: 1,
            numbered,
            role: message.role.clone(),
            tool_owner: owner,
            sidebar_input: input.then(|| hit.clone()),
        },
    );
    Ok(Prepared {
        source,
        ranges,
        notice: matches!(hit.target(), SourceTarget::CardFallback)
            .then(|| "The match crosses presentation fields; showing its owning card.".into()),
    })
}
impl FindPaint {
    pub(crate) fn new_sidebar(
        prepared: Prepared,
        slot: Arc<bello_agent_core::sidebar_search::SearchAdmissionSlot>,
        hit: &bello_agent_core::sidebar_search::OwnedHit,
        owner: uuid::Uuid,
        ui_admission: crate::sidebar_search_controller::RevealAdmission,
        navigation_completed: Rc<Cell<bool>>,
    ) -> Rc<Self> {
        let found = Match {
            id: hit.key().message_id.clone(),
            occurrence: hit.occurrence().ordinal,
        };
        let destination = crate::transcript_find_state::Destination::sidebar(found.clone());
        let mut paint = Self::new(
            prepared,
            Some(found),
            Some(destination),
            1,
            owner,
            Arc::new(AtomicBool::new(false)),
        );
        let unique = Rc::get_mut(&mut paint).unwrap();
        unique.sidebar_admission = Some(slot);
        unique.sidebar_ui_admission = Some(ui_admission);
        unique.sidebar_navigation_completed = Some(navigation_completed);
        paint
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn overlapping_source_envelopes_merge_only_for_decoration() {
        assert_eq!(merge_ranges(vec![3..6, 0..4, 8..9]), vec![0..6, 8..9]);
    }
    #[::core::prelude::v1::test]
    fn preparation_reserves_offscreen_selected_beyond_all_soft_budgets_without_text_copies() {
        use bello_agent_core::{Controller, Message, SessionStore};
        let directory = tempfile::tempdir().unwrap();
        let mut store = SessionStore::open(directory.path().join("session.json")).unwrap();
        store
            .transact(|s| {
                s.messages = (0..70)
                    .map(|i| Message {
                        id: format!("row-{i}"),
                        role: "assistant".into(),
                        text: "a".repeat(7000),
                        task_root_id: None,
                        user_content: None,
                        reasoning: String::new(),
                        replay_eligible: true,
                        state: "complete".into(),
                        usage: serde_json::Value::Null,
                        model: None,
                        tool_record: None,
                        compaction: None,
                    })
                    .collect();
                Ok(())
            })
            .unwrap();
        let controller = Controller::new(store, None).unwrap();
        let source = controller.find_snapshot().unwrap();
        let session = source.session_shared();
        let cancel = AtomicBool::new(false);
        let query = Query::new("a", &cancel).unwrap();
        let current = Match {
            id: "row-69".into(),
            occurrence: 6000,
        };
        let prepared = prepare(
            &query,
            source,
            (0..70).map(|i| format!("row-{i}")).collect(),
            Some(&current),
            &cancel,
        )
        .unwrap();
        assert!(prepared.ranges.len() <= 64);
        assert!(prepared.ranges.values().map(|r| r.all.len()).sum::<usize>() <= 16384);
        assert_eq!(prepared.ranges["row-69"].selected, Some(6000..6001));
        assert_eq!(prepared.ranges["row-69"].total, 7000);
        assert!(prepared.notice.is_some());
        assert!(Arc::ptr_eq(&session, &prepared.source.session_shared()));
        assert!(
            prepare(
                &query,
                prepared.source,
                vec!["row-69".into()],
                Some(&current),
                &AtomicBool::new(true)
            )
            .is_err()
        );
    }
}
