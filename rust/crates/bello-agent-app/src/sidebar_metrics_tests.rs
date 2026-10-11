use super::{RATE_WIDTH, RowFigures, live};
use bello_agent_core::{
    Session,
    accounting::{self, GatewayTotals, RequestRecord},
};
use serde_json::json;
use std::{rc::Rc, sync::Arc};

fn records() -> Vec<RequestRecord> {
    serde_json::from_value(json!([
        {"id":"a","purpose":"turn","turn":"t","wall":1.0,"requested_model":"m","outcome":"completed",
         "usage":{"input":12000,"output":300,"cache_read":8100},"cost":{"status":"reported","usd":0.00499},
         "ttft_ms":400.0,"stream_ms":2990.0}
    ]))
    .unwrap()
}

#[::core::prelude::v1::test]
fn a_row_reads_cost_rate_and_tokens_as_chat_row_stats() {
    let totals = GatewayTotals::of(&records());
    let rate = accounting::latest_rate_label(&records());
    assert_eq!(rate.as_deref(), Some("Latest 100 tok/s"));
    let figures = RowFigures::of(&totals, Some(rate), false);
    assert_eq!(figures.cost.as_deref(), Some("$0.0050"));
    assert_eq!(figures.tokens.as_deref(), Some("· 12.3K tok"));
    let running = RowFigures::of(&totals, None, true);
    assert_eq!(running.tokens, None);
    assert_eq!(running.cost.as_deref(), Some("$0.0050"));
    let empty = RowFigures::of(&GatewayTotals::default(), None, false);
    assert_eq!((empty.cost, empty.tokens), (None, None));
}

#[::core::prelude::v1::test]
fn a_loaded_chats_figures_are_worked_out_once_per_snapshot() {
    let mut session = Session::new();
    session.requests = records();
    let session = Arc::new(session);
    let first = live(&session);
    assert!(Rc::ptr_eq(&first, &live(&session)));
    assert_eq!(first.0.requests, 1);
}

#[gpui::test]
fn an_open_chats_row_shows_its_rate_slot_and_cost(cx: &mut gpui::TestAppContext) {
    let (_dir, window, root, chats) =
        crate::sidebar_chats::tests::app_fixture(cx, &[("One", ""), ("Two", "")]);
    crate::sidebar_chats::tests::select(window, &chats[0].id, cx);
    root.update(cx, |view, cx| {
        let mut session = (*view.session).clone();
        session.requests = records();
        view.session = Arc::new(session);
        cx.notify();
    });
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    cx.run_until_parked();
    let rate = visual.debug_bounds("sidebar-reported-rate").unwrap();
    assert_eq!(rate.size.width, gpui::px(RATE_WIDTH));
    let figures = root.read_with(cx, |view, _| {
        let record = view
            .records
            .iter()
            .find(|r| r.id == chats[0].id)
            .unwrap()
            .clone();
        view.sidebar_row_figures(&record)
    });
    assert_eq!(figures.cost.as_deref(), Some("$0.0050"));
    assert_eq!(figures.rate, Some(Some("Latest 100 tok/s".into())));
    // The other chat is not open: no rate slot, and no figures until its
    // saved state has been read.
    let other = root.read_with(cx, |view, _| {
        let record = view
            .records
            .iter()
            .find(|r| r.id == chats[1].id)
            .unwrap()
            .clone();
        view.sidebar_row_figures(&record)
    });
    assert_eq!(other.rate, None);
}
