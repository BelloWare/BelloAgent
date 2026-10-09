use super::*;
use crate::conversation_content::Hit;
fn state() -> (FindState, Ticket) {
    let mut state = FindState::default();
    state.show();
    let ticket = state.set_query("a".into()).unwrap();
    (state, ticket)
}
fn page(rows: usize, next: Option<usize>, hits: &[(&str, usize, usize)]) -> SearchPage {
    SearchPage {
        total: rows,
        next,
        hits: hits
            .iter()
            .map(|(id, position, count)| Hit {
                id: id.to_string(),
                position: *position,
                count: Some(*count),
                preview: String::new(),
            })
            .collect(),
    }
}
#[test]
fn lifecycle_aba_same_query_close_and_snapshot_restart() {
    let (mut s, a) = state();
    assert_eq!(s.label(), "Searching…");
    assert!(s.set_query("a".into()).is_none());
    assert!(s.accepts(&a));
    s.set_query("b".into());
    let new_a = s.set_query("a".into()).unwrap();
    assert!(!s.accepts(&a));
    assert!(a.cancellation().load(Ordering::Acquire));
    assert!(
        !s.append(&a, 0, page(1, None, &[("x", 1, 1)]), &HashSet::new())
            .unwrap()
    );
    let restarted = s.restart().unwrap();
    assert!(!s.accepts(&new_a));
    assert!(s.accepts(&restarted));
    s.close();
    assert!(!s.open);
    assert_eq!(s.query, "");
    assert_eq!(s.label(), "");
    s.show();
    assert_eq!(s.query, "");
}
#[test]
fn incremental_near_reader_counts_navigation_wrap_and_partial_failure() {
    let (mut s, t) = state();
    s.append(
        &t,
        0,
        page(300, Some(100), &[("a", 1, 2), ("b", 99, 3)]),
        &HashSet::from(["b".into()]),
    )
    .unwrap();
    assert_eq!(s.label(), "3 of 5+");
    assert_eq!(s.current().unwrap().id, "b");
    s.append(&t, 100, page(300, None, &[("c", 201, 1)]), &HashSet::new())
        .unwrap();
    assert_eq!(s.label(), "3 of 6");
    for _ in 0..4 {
        s.step(false);
    }
    assert_eq!(s.ordinal(), Some(0));
    s.step(true);
    assert_eq!(s.ordinal(), Some(5));
    let target = s.destination().unwrap();
    s.step(false);
    assert!(!s.accepts_destination(&target));
    s.landing_failed(&target);
    assert!(!s.unreachable);
    let target = s.destination().unwrap();
    s.landing_failed(&target);
    assert_eq!(s.label(), "Couldn’t open match");
    s.abandon_navigation();
    assert!(!s.accepts_destination(&target));
    let t = s.restart().unwrap();
    s.append(&t, 0, page(300, Some(100), &[("a", 1, 2)]), &HashSet::new())
        .unwrap();
    s.fail(&t);
    assert_eq!(s.label(), "Search failed");
    assert_eq!(s.total(), 2);
}
#[test]
fn reconciliation_preserves_identity_clamps_and_never_zeroes() {
    let (mut s, t) = state();
    s.append(
        &t,
        0,
        page(3, None, &[("a", 1, 2), ("b", 2, 3), ("c", 3, 1)]),
        &HashSet::from(["b".into()]),
    )
    .unwrap();
    s.step(false);
    s.step(false);
    assert_eq!(s.current().unwrap().occurrence, 2);
    s.reconcile(&t, "a", 5).unwrap();
    assert_eq!(s.ordinal(), Some(7));
    s.reconcile(&t, "b", 1).unwrap();
    assert_eq!(s.ordinal(), Some(5));
    assert_eq!(s.current().unwrap().occurrence, 0);
    assert!(!s.reconcile(&t, "b", 0).unwrap());
    assert_eq!(s.total(), 7);
    s.reconcile(&t, "c", 4).unwrap();
    assert_eq!(s.ordinal(), Some(5));
    assert_eq!(s.total(), 10);
}
#[test]
fn malformed_pages_and_overflow_fail_without_partial_append() {
    for bad in [
        page(2, Some(0), &[]),
        page(2, None, &[("a", 1, 1), ("a", 2, 1)]),
        page(2, None, &[("a", 2, 1), ("b", 1, 1)]),
        page(2, None, &[("a", 1, usize::MAX), ("b", 2, 1)]),
    ] {
        let (mut s, t) = state();
        assert!(s.append(&t, 0, bad, &HashSet::new()).is_err());
        assert!(s.failed);
        assert_eq!(s.total(), 0);
    }
    let (mut s, t) = state();
    s.append(
        &t,
        0,
        page(2, None, &[("a", 1, usize::MAX - 1), ("b", 2, 1)]),
        &HashSet::new(),
    )
    .unwrap();
    assert!(s.reconcile(&t, "b", 2).is_err());
    assert_eq!(s.total(), usize::MAX);
}
#[test]
fn hundred_record_pages_remain_grouped_and_old_page_is_ignored() {
    let (mut s, t) = state();
    let hits: Vec<_> = (0..100)
        .map(|i| Hit {
            id: format!("r{i}"),
            position: i + 1,
            count: Some(1_000_000),
            preview: String::new(),
        })
        .collect();
    s.append(
        &t,
        0,
        SearchPage {
            total: 101,
            next: Some(100),
            hits,
        },
        &HashSet::new(),
    )
    .unwrap();
    assert_eq!(s.groups().len(), 100);
    assert_eq!(s.total(), 100_000_000);
    assert!(
        !s.append(&t, 0, page(101, None, &[]), &HashSet::new())
            .unwrap()
    );
    s.append(
        &t,
        100,
        page(101, None, &[("last", 101, 1)]),
        &HashSet::new(),
    )
    .unwrap();
    assert_eq!(s.total(), 100_000_001);
    let t = s.restart().unwrap();
    s.append(&t, 0, page(0, None, &[]), &HashSet::new())
        .unwrap();
    assert_eq!(s.label(), "No matches");
    assert!(s.set_query(String::new()).is_none());
    assert_eq!(s.label(), "");
}

#[test]
fn dropping_state_cancels_pending_work_and_navigation() {
    let (mut s, t) = state();
    s.append(&t, 0, page(1, None, &[("a", 1, 1)]), &HashSet::new())
        .unwrap();
    let target = s.destination().unwrap();
    drop(s);
    assert!(t.cancellation().load(Ordering::Acquire));
    assert!(target.navigation.cancellation().load(Ordering::Acquire));
}

#[test]
fn initial_visible_preference_is_limited_to_first_available_page_like_swift() {
    let (mut state, ticket) = state();
    let visible = HashSet::from(["later".to_string()]);
    state
        .append(
            &ticket,
            0,
            page(240, Some(100), &[("first", 1, 1)]),
            &visible,
        )
        .unwrap();
    assert_eq!(state.current().unwrap().id, "first");
    state
        .append(
            &ticket,
            100,
            page(240, None, &[("later", 150, 1)]),
            &visible,
        )
        .unwrap();
    assert_eq!(
        state.current().unwrap().id,
        "first",
        "later pages do not steal established navigation"
    );
}
