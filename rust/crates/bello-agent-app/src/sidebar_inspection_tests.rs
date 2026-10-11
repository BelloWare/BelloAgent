use super::*;
use bello_agent_core::{
    Lane, SessionStore, Submission,
    sidebar_search::{
        SearchOutcome, SearchRequest,
        reconciliation::{CoverageState, ReconciliationPass},
    },
    workspace::{DraftRecord, WorkspaceStore},
};
use std::sync::{Arc, Mutex};
use uuid::Uuid;
fn fixture() -> (tempfile::TempDir, Arc<Mutex<WorkspaceStore>>, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let mut owner = WorkspaceStore::open(root.join("catalog.json"), &root).unwrap();
    let id = Uuid::new_v4().to_string();
    let path = owner.chat_path(&id).unwrap();
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    store
        .transact(|s| {
            s.submit(Submission::new("needle".into(), Lane::FollowUp))?;
            s.start_next()?;
            Ok(())
        })
        .unwrap();
    drop(store);
    let record = ChatRecord::new(id, "private".into(), path);
    owner
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    (dir, Arc::new(Mutex::new(owner)), record)
}
#[test]
fn coalesced_run_read_search_share_one_parse_and_search_only_has_no_read_output() {
    let (_dir, owner, record) = fixture();
    let membership = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
    let mut pass =
        ReconciliationPass::begin(&SearchRequest::new("needle", 1).unwrap(), &membership).unwrap();
    let work = pass.work(&record.id).unwrap();
    let lane = owner.lock().unwrap().inspection_coordinator();
    let mut permit = lane.try_background().unwrap().unwrap();
    let bytes = std::fs::read(&record.snapshot).unwrap();
    let output = inspect(
        &record,
        &mut permit,
        InspectionDemand::search(work).include_run_read(),
    )
    .unwrap();
    assert_eq!(
        output.run_read.as_ref().unwrap().0,
        SavedRunState::Interrupted
    );
    assert!(matches!(
        output.search.unwrap().unwrap().outcome(),
        SearchOutcome::Match(_)
    ));
    assert_eq!(std::fs::read(&record.snapshot).unwrap(), bytes);
    let work = pass.work(&record.id).unwrap();
    let output = inspect(&record, &mut permit, InspectionDemand::search(work)).unwrap();
    assert!(output.run_read.is_none());
    pass.record_observed(output.search.unwrap().unwrap())
        .unwrap();
    assert_eq!(
        pass.finish(&membership).unwrap().state,
        CoverageState::CompleteAsOf
    );
}
#[test]
fn lifecycle_block_survives_map_gap_and_new_query_until_explicit_success() {
    let (_dir, owner, record) = fixture();
    let membership = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
    let mut lifecycles = crate::sidebar_search_state::SearchLifecycles::default();
    lifecycles.block(&record.id);
    for generation in [1, 2] {
        let mut pass = ReconciliationPass::begin(
            &SearchRequest::new("needle", generation).unwrap(),
            &membership,
        )
        .unwrap();
        lifecycles.apply(&mut pass, [record.id.clone()]).unwrap();
        assert!(pass.work(&record.id).is_err());
    }
    let mut pass =
        ReconciliationPass::begin(&SearchRequest::new("needle", 3).unwrap(), &membership).unwrap();
    lifecycles.loaded(&record.id);
    lifecycles.apply(&mut pass, [record.id.clone()]).unwrap();
    let work = pass.work(&record.id).unwrap();
    let lane = owner.lock().unwrap().inspection_coordinator();
    let mut permit = lane.try_background().unwrap().unwrap();
    let output = inspect(&record, &mut permit, InspectionDemand::search(work)).unwrap();
    assert!(output.search.unwrap().is_err());
    lifecycles.unloaded(&record.id);
    lifecycles.apply(&mut pass, [record.id.clone()]).unwrap();
    let work = pass.work(&record.id).unwrap();
    assert!(
        inspect(&record, &mut permit, InspectionDemand::search(work))
            .unwrap()
            .search
            .unwrap()
            .is_ok()
    );
}
#[test]
fn cancelled_search_does_not_cancel_later_run_read_subscriber_or_permit() {
    let (_dir, owner, record) = fixture();
    let membership = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership).unwrap();
    let work = pass.work(&record.id).unwrap();
    request.cancel();
    let lane = owner.lock().unwrap().inspection_coordinator();
    let mut permit = lane.try_background().unwrap().unwrap();
    assert!(
        inspect(&record, &mut permit, InspectionDemand::search(work))
            .unwrap()
            .search
            .unwrap()
            .is_err()
    );
    let output = inspect(&record, &mut permit, InspectionDemand::run_read()).unwrap();
    assert!(output.search.is_none());
    assert_eq!(output.run_read.unwrap().0, SavedRunState::Interrupted);
}

#[test]
fn already_cancelled_search_keeps_coalesced_run_read_demand() {
    let (_dir, owner, record) = fixture();
    let membership = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership).unwrap();
    let work = pass.work(&record.id).unwrap();
    request.cancel();
    let lane = owner.lock().unwrap().inspection_coordinator();
    let mut permit = lane.try_background().unwrap().unwrap();
    let output = inspect(
        &record,
        &mut permit,
        InspectionDemand::search(work).include_run_read(),
    )
    .unwrap();
    assert!(matches!(output.search, Some(Err(SearchError::Cancelled))));
    assert_eq!(output.run_read.unwrap().0, SavedRunState::Interrupted);
}

#[test]
fn the_run_read_parse_also_reads_the_request_totals() {
    let (_dir, owner, record) = fixture();
    {
        let mut store = SessionStore::open(&record.snapshot).unwrap();
        store
            .transact(|s| {
                s.requests = serde_json::from_value(serde_json::json!([
                    {"id":"a","purpose":"turn","wall":1.0,"requested_model":"m","outcome":"completed",
                     "usage":{"input":10,"output":5},"cost":{"status":"reported","usd":0.5}}
                ]))
                .unwrap();
                Ok(())
            })
            .unwrap();
    }
    let lane = owner.lock().unwrap().inspection_coordinator();
    let mut permit = lane.try_background().unwrap().unwrap();
    let output = inspect(&record, &mut permit, InspectionDemand::run_read()).unwrap();
    let totals = output.totals.unwrap();
    assert_eq!(totals.requests, 1);
    assert_eq!(totals.cost.value(), Some(0.5));
}
