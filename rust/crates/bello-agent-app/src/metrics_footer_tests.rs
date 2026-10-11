use super::*;
use bello_agent_core::accounting::RequestRecord;
use serde_json::json;

fn profile(window: u32) -> Profile {
    serde_json::from_value(
        json!({"id":"p","api":"openai-responses","providerId":"litellm",
        "modelId":"m","baseUrl":"http://127.0.0.1:1","contextWindow":window,"maxOutputTokens":4096,
        "modelOutputLimit":8192}),
    )
    .unwrap()
}
fn message(
    id: &str,
    role: &str,
    text: &str,
    usage: serde_json::Value,
) -> bello_agent_core::Message {
    serde_json::from_value(json!({"id":id,"role":role,"text":text,"reasoning":"",
        "replay_eligible":true,"state":"completed","usage":usage,"model":null}))
    .unwrap()
}

#[::core::prelude::v1::test]
fn the_context_pill_reads_the_last_reply_and_the_characters_since() {
    let mut session = Session::new();
    session.messages = vec![
        message("u1", "user", &"x".repeat(400), json!(null)),
        message(
            "a1",
            "assistant",
            "done",
            json!({"input_tokens":30000,"output_tokens":900,"total_tokens":30900}),
        ),
        message("u2", "user", &"y".repeat(4000), json!(null)),
    ];
    let reading = ContextReading::of(&session, Some(&profile(65_536)));
    // 30,900 reported + 1,000 for the 4,000 characters since.
    assert_eq!(reading.fraction(), Some(31_900. / 65_536.));
    assert_eq!(reading.label(), "49%");
    assert_eq!(
        reading.detail(),
        "≈31,900 / 65,536 configured · 48.7% · Last reply's reported tokens, plus about 4 characters per token for the messages since"
    );
    session.messages.truncate(1);
    let reading = ContextReading::of(&session, Some(&profile(65_536)));
    assert_eq!(reading.label(), "<1%");
    assert!(reading.detail().starts_with("≈100 / 65,536 configured · 0.2% · About 4 characters per token for every message; no reply has reported its tokens yet · Input is estimated"));
    assert_eq!(
        ContextReading::of(&session, None).label(),
        "Inspect context"
    );
}

#[::core::prelude::v1::test]
fn readings_are_worked_out_once_per_snapshot() {
    let mut session = Session::new();
    session.requests = serde_json::from_value::<Vec<RequestRecord>>(json!([
        {"id":"a","purpose":"turn","turn":"t","wall":1.0,"requested_model":"m","outcome":"completed",
         "usage":{"input":1200,"output":120,"cache_read":0},"cost":{"status":"reported","usd":0.0025},
         "ttft_ms":412.5,"stream_ms":3400.0}
    ]))
    .unwrap();
    let session = Arc::new(session);
    let first = readings(&session, Some(&profile(65_536)));
    let again = readings(&session, Some(&profile(65_536)));
    assert!(Rc::ptr_eq(&first, &again));
    let stats = first.stats();
    assert_eq!(stats.gauge_label(), "1 turn 1 step · 35 tok/s");
    let wide = usage_face(&stats, 1000.);
    assert_eq!(
        wide.label,
        "1.3K tok · 1.2K uncached · 0 cached · 120 out · Cache hit 0.00% · $0.0025"
    );
    let narrow = usage_face(&stats, 200.);
    assert_eq!(narrow.label, "1.3K tok · Cache hit 0.00% · $0.0025");
    let other = readings(&session, Some(&profile(32_000)));
    assert!(!Rc::ptr_eq(&first, &other));
}
