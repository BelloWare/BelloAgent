//! Pure selected-conversation Find reducer. Workspace/controller/snapshot fences,
//! debounce timing and actual scroll/focus delivery belong to the UI adapter.
//! Groups store one allocation per hit record, never one per occurrence.
use crate::conversation_content::SearchPage;
use std::{
    collections::HashSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Clone, Debug)]
pub(crate) struct Ticket(Arc<AtomicBool>);
impl Ticket {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }
    fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub(crate) fn cancellation(&self) -> &AtomicBool {
        &self.0
    }
    fn matches(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0) && !self.0.load(Ordering::Acquire)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Group {
    pub id: String,
    pub position: usize,
    pub count: usize,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Match {
    pub id: String,
    pub occurrence: usize,
}
#[derive(Clone, Debug)]
pub(crate) struct Destination {
    pub search: Ticket,
    pub navigation: Ticket,
    pub found: Match,
}
#[derive(Default)]
pub(crate) struct FindState {
    pub open: bool,
    pub query: String,
    pub searching: bool,
    pub failed: bool,
    pub unreachable: bool,
    groups: Vec<Group>,
    ends: Vec<usize>,
    current: Option<(usize, usize)>,
    search: Option<Ticket>,
    navigation: Option<Ticket>,
    next: Option<usize>,
    rows: Option<usize>,
}
impl FindState {
    /// Repeated show preserves the query. Adapter focuses/selects its field.
    pub(crate) fn show(&mut self) {
        self.open = true;
    }
    pub(crate) fn close(&mut self) {
        self.cancel_search();
        self.abandon_navigation();
        *self = Self::default();
    }
    pub(crate) fn set_query(&mut self, query: String) -> Option<Ticket> {
        if !self.open || self.query == query {
            return None;
        }
        self.query = query;
        self.restart()
    }
    /// A changed immutable content snapshot restarts even an unchanged query.
    /// The adapter must bind the returned identity to that snapshot before work.
    pub(crate) fn restart(&mut self) -> Option<Ticket> {
        self.cancel_search();
        self.abandon_navigation();
        self.groups.clear();
        self.ends.clear();
        self.current = None;
        self.rows = None;
        self.next = None;
        self.failed = false;
        self.unreachable = false;
        self.searching = self.open && !self.query.is_empty();
        if !self.searching {
            return None;
        }
        let ticket = Ticket::new();
        self.search = Some(ticket.clone());
        self.next = Some(0);
        Some(ticket)
    }
    fn cancel_search(&mut self) {
        if let Some(ticket) = self.search.take() {
            ticket.cancel();
        }
    }
    pub(crate) fn abandon_navigation(&mut self) {
        if let Some(ticket) = self.navigation.take() {
            ticket.cancel();
        }
    }
    pub(crate) fn accepts(&self, ticket: &Ticket) -> bool {
        self.open && self.search.as_ref().is_some_and(|own| own.matches(ticket))
    }
    pub(crate) fn next_page(&self) -> Option<usize> {
        self.next
    }
    pub(crate) fn groups(&self) -> &[Group] {
        &self.groups
    }
    pub(crate) fn total(&self) -> usize {
        self.ends.last().copied().unwrap_or(0)
    }
    pub(crate) fn current(&self) -> Option<Match> {
        self.current.map(|(i, occurrence)| Match {
            id: self.groups[i].id.clone(),
            occurrence,
        })
    }
    pub(crate) fn ordinal(&self) -> Option<usize> {
        self.current.map(|(i, occurrence)| {
            if i == 0 {
                occurrence
            } else {
                self.ends[i - 1] + occurrence
            }
        })
    }
    pub(crate) fn label(&self) -> String {
        if self.query.is_empty() {
            return String::new();
        }
        if self.unreachable {
            return "Couldn’t open match".into();
        }
        if self.failed {
            return "Search failed".into();
        }
        if self.total() == 0 {
            return if self.searching {
                "Searching…"
            } else {
                "No matches"
            }
            .into();
        }
        let suffix = if self.searching { "+" } else { "" };
        match self.ordinal() {
            Some(n) => format!("{} of {}{suffix}", n + 1, self.total()),
            None => format!("{}{suffix} matches", self.total()),
        }
    }
    /// Atomically append one ordered page. Stale/duplicate callbacks are no-ops;
    /// malformed current pages fail visibly, without accepting their prefix.
    pub(crate) fn append(
        &mut self,
        ticket: &Ticket,
        start: usize,
        page: SearchPage,
        visible: &HashSet<String>,
    ) -> Result<bool, String> {
        if !self.accepts(ticket) || !self.searching || self.next != Some(start) {
            return Ok(false);
        }
        let result = self.validate_page(start, &page);
        let (groups, ends) = match result {
            Ok(value) => value,
            Err(error) => {
                self.fail(ticket);
                return Err(error);
            }
        };
        self.groups.extend(groups);
        self.ends.extend(ends);
        self.rows = Some(page.total);
        self.next = page.next;
        self.searching = page.next.is_some();
        if self.current.is_none() && !self.groups.is_empty() {
            let i = self
                .groups
                .iter()
                .position(|group| visible.contains(&group.id))
                .unwrap_or(0);
            self.current = Some((i, 0));
        }
        Ok(true)
    }
    fn validate_page(
        &self,
        start: usize,
        page: &SearchPage,
    ) -> Result<(Vec<Group>, Vec<usize>), String> {
        if page.hits.len() > 100
            || self.rows.is_some_and(|rows| rows != page.total)
            || start > page.total
            || page
                .next
                .is_some_and(|next| next <= start || next >= page.total)
        {
            return Err("Find page identity or cursor changed.".into());
        }
        let mut ids: HashSet<&str> = self.groups.iter().map(|group| group.id.as_str()).collect();
        let mut last = start;
        let mut total = self.total();
        let mut groups = Vec::new();
        let mut ends = Vec::new();
        for hit in &page.hits {
            if hit.position <= last
                || hit.position > page.next.unwrap_or(page.total)
                || !ids.insert(&hit.id)
            {
                return Err("Find page contains ambiguous or unordered records.".into());
            }
            last = hit.position;
            let count = hit.count.unwrap_or(1).max(1);
            total = total
                .checked_add(count)
                .ok_or("Find occurrence count overflow.")?;
            groups.push(Group {
                id: hit.id.clone(),
                position: hit.position,
                count,
            });
            ends.push(total);
        }
        Ok((groups, ends))
    }
    pub(crate) fn fail(&mut self, ticket: &Ticket) {
        if self.accepts(ticket) {
            self.searching = false;
            self.failed = true;
            self.next = None;
        }
    }
    pub(crate) fn step(&mut self, previous: bool) -> Option<Destination> {
        let total = self.total();
        if total == 0 {
            return None;
        }
        let index = match (self.ordinal(), previous) {
            (Some(0) | None, true) => total - 1,
            (Some(n), true) => n - 1,
            (Some(n), false) if n == total - 1 => 0,
            (Some(n), false) => n + 1,
            (None, false) => 0,
        };
        let group = self.ends.partition_point(|end| *end <= index);
        self.current = Some((
            group,
            index - if group == 0 { 0 } else { self.ends[group - 1] },
        ));
        self.destination()
    }
    pub(crate) fn destination(&mut self) -> Option<Destination> {
        let found = self.current()?;
        let search = self.search.clone()?;
        self.abandon_navigation();
        self.unreachable = false;
        let navigation = Ticket::new();
        self.navigation = Some(navigation.clone());
        Some(Destination {
            search,
            navigation,
            found,
        })
    }
    pub(crate) fn accepts_destination(&self, target: &Destination) -> bool {
        self.accepts(&target.search)
            && self
                .navigation
                .as_ref()
                .is_some_and(|own| own.matches(&target.navigation))
            && self.current().as_ref() == Some(&target.found)
    }
    pub(crate) fn landing_failed(&mut self, target: &Destination) {
        if self.accepts_destination(target) {
            self.unreachable = true;
        }
    }
    /// Only a fully observed positive rendered count reconciles. Zero leaves
    /// hidden/source-only hits as row destinations, matching Swift deliberately.
    pub(crate) fn reconcile(
        &mut self,
        ticket: &Ticket,
        id: &str,
        rendered: usize,
    ) -> Result<bool, String> {
        if !self.accepts(ticket) || rendered == 0 {
            return Ok(false);
        }
        let Some(index) = self.groups.iter().position(|group| group.id == id) else {
            return Ok(false);
        };
        let old = self.groups[index].count;
        if old == rendered {
            return Ok(false);
        }
        if self
            .total()
            .checked_sub(old)
            .and_then(|n| n.checked_add(rendered))
            .is_none()
        {
            self.fail(ticket);
            return Err("Find occurrence count overflow.".into());
        }
        self.groups[index].count = rendered;
        let mut sum = 0;
        for (group, end) in self.groups.iter().zip(&mut self.ends) {
            sum += group.count;
            *end = sum;
        }
        if let Some((current, occurrence)) = &mut self.current
            && *current == index
        {
            *occurrence = (*occurrence).min(rendered - 1);
        }
        self.abandon_navigation();
        Ok(true)
    }
}
impl Drop for FindState {
    fn drop(&mut self) {
        self.cancel_search();
        self.abandon_navigation();
    }
}
#[cfg(test)]
#[path = "transcript_find_state_tests.rs"]
mod tests;
