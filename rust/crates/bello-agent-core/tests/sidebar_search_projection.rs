//! Pure projection regression harness, including unchanged Find differential tests.
use bello_agent_core::sidebar_search::CancellationProbe;
pub use bello_agent_core::{Message, Session, tool_history};
#[path = "../src/sidebar_search/identity.rs"]
mod identity;
#[path = "../src/sidebar_search/projection.rs"]
mod projection;
use bello_agent_core::{
    provider::ToolCall,
    tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
};
use identity::ContentIdentity;
use projection::*;
use serde_json::{Value, json};
use std::sync::atomic::AtomicBool;
use unicode_normalization::UnicodeNormalization;
fn cancel() -> AtomicBool {
    AtomicBool::new(false)
}
fn row(id: &str, role: &str, text: &str) -> Message {
    Message {
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: false,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
        task_root_id: None,
        user_content: None,
    }
}
fn session() -> Session {
    let mut s = Session::new();
    s.messages = vec![
        row("u", "user", "early needle"),
        row("a", "assistant", "reply needle"),
        row("r", "toolResult", "output needle"),
    ];
    s.messages[1].tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        tool_batch_timing: None,
        completion: Completion::Complete,
        calls: vec![
            ToolCall {
                id: "c1".into(),
                name: "read".into(),
                arguments: json!({"path":"one", "text":"needle"}),
            },
            ToolCall {
                id: "c2".into(),
                name: "shell".into(),
                arguments: json!({"command":"second needle"}),
            },
        ],
        binding: ReplayBinding {
            profile_id: "fixture".into(),
            api: "openai-responses".into(),
            provider: "litellm".into(),
            model: "fixture".into(),
            endpoint_sha256: "0".repeat(64),
        },
        provider_items: vec![],
    }));
    s.messages[2].tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: "a".into(),
        call_id: "c2".into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
        duration_us: None,
        content: None,
    }));
    s
}
fn projected(s: &Session) -> SidebarProjection<'_> {
    SidebarProjection::new(s, ActivePolicy::AcceptedRetained, &cancel()).unwrap()
}
fn digest(s: &Session) -> ContentIdentity {
    ContentIdentity::of(&projected(s), &cancel()).unwrap()
}
#[test]
fn four_kinds_order_and_result_owner() {
    let s = session();
    let p = projected(&s);
    assert_eq!(
        p.pieces.iter().map(|p| p.key.kind).collect::<Vec<_>>(),
        vec![
            PieceKind::User,
            PieceKind::Assistant,
            PieceKind::ToolInput,
            PieceKind::ToolInput,
            PieceKind::ToolOutput
        ]
    );
    let result = &p.pieces[4];
    assert_eq!(result.key.message_id, "r");
    assert_eq!(result.key.assistant_id, Some("a"));
    assert_eq!(result.key.call_id, Some("c2"));
    let hit = p
        .newest_match(&Query::new("needle", &cancel()).unwrap(), &cancel())
        .unwrap()
        .unwrap();
    assert_eq!(hit.0, 4);
}
#[test]
fn newest_prose_before_tools_and_second_call_match() {
    let mut s = session();
    s.messages.pop();
    let p = projected(&s);
    assert_eq!(
        p.newest_match(&Query::new("needle", &cancel()).unwrap(), &cancel())
            .unwrap()
            .unwrap()
            .0,
        1
    );
    assert_eq!(
        p.newest_match(&Query::new("second", &cancel()).unwrap(), &cancel())
            .unwrap()
            .unwrap()
            .0,
        3
    );
}
#[test]
fn exact_pretty_input_and_source_targets() {
    let s = session();
    let p = projected(&s);
    let input = &p.pieces[2];
    let ToolRecord::Assistant(a) = s.messages[1].tool_record.as_ref().unwrap() else {
        panic!()
    };
    let pretty = serde_json::to_string_pretty(&a.calls[0].arguments).unwrap();
    assert_eq!(
        canonical_tool_input(&a.calls[0].arguments, &cancel()).unwrap(),
        pretty
    );
    assert_eq!(input.source, format!("read {pretty}"));
    assert_eq!(input.target(0..4), SourceTarget::ToolName(0..4));
    assert_eq!(input.target(5..6), SourceTarget::ToolInput(0..1));
    assert_eq!(input.target(0..6), SourceTarget::CardFallback);
    assert_eq!(p.pieces[0].target(0..5), SourceTarget::Message(0..5));
    assert_eq!(input.target(0..usize::MAX), SourceTarget::CardFallback);
}
#[test]
fn tool_input_identity_includes_same_size_argument_edit() {
    let a = session();
    let before = digest(&a);
    let mut b = a.clone();
    let Some(ToolRecord::Assistant(record)) = &mut b.messages[1].tool_record else {
        panic!()
    };
    record.calls[0].arguments["path"] = json!("two");
    assert_ne!(before, digest(&b));
    assert_eq!(before.prefixes[0], digest(&b).prefixes[0]);
    assert_ne!(before.prefixes[2], digest(&b).prefixes[2]);
}
#[test]
fn exact_identity_covers_old_text_role_order_owner_and_removal() {
    let a = session();
    let before = digest(&a);
    for mutation in 0..7 {
        let mut b = a.clone();
        match mutation {
            0 => b.messages[0].text = "early NEEDLE".into(),
            1 => b.messages[0].role = "assistant".into(),
            2 => b.messages.insert(0, row("blank", "user", "")),
            3 => {
                b.messages.remove(0);
            }
            4 => {
                b.messages[1].id = "other".into();
                if let Some(ToolRecord::Result(r)) = &mut b.messages[2].tool_record {
                    r.assistant_id = "other".into();
                }
            }
            5 => {
                if let Some(ToolRecord::Assistant(r)) = &mut b.messages[1].tool_record {
                    r.calls[0].name = "find".into();
                }
            }
            _ => {
                b.id = "other-chat".into();
            }
        }
        assert_ne!(before, digest(&b), "mutation {mutation}");
    }
}
#[test]
fn hidden_containers_and_unknown_roles_never_leak() {
    let mut s = session();
    let before = digest(&s);
    s.messages[0].reasoning = "REASONING_SECRET".into();
    s.messages[0].usage = json!({"ledger":"LEDGER_SECRET"});
    if let Some(ToolRecord::Assistant(a)) = &mut s.messages[1].tool_record {
        a.provider_items = vec![json!({"opaque":"PROVIDER_SECRET"})];
    }
    s.messages.push(row("x", "execution", "EXECUTION_SECRET"));
    s.messages.push(row("b", "branch", "BRANCH_SECRET"));
    s.messages.push(row("l", "requestLedger", "LEDGER_SECRET"));
    s.messages.push(row("c", "compaction", "SUMMARY_SECRET"));
    let p = projected(&s);
    assert_eq!(before, digest(&s));
    for marker in [
        "REASONING_SECRET",
        "LEDGER_SECRET",
        "PROVIDER_SECRET",
        "EXECUTION_SECRET",
        "BRANCH_SECRET",
        "SUMMARY_SECRET",
    ] {
        assert!(
            p.newest_match(&Query::new(marker, &cancel()).unwrap(), &cancel())
                .unwrap()
                .is_none()
        );
    }
}
#[test]
fn malformed_and_ambiguous_ownership_fail_closed() {
    for mutation in 0..6 {
        let mut s = session();
        match mutation {
            0 => s.messages[2].id = s.messages[1].id.clone(),
            1 => {
                if let Some(ToolRecord::Assistant(a)) = &mut s.messages[1].tool_record {
                    a.calls[1].id = a.calls[0].id.clone();
                }
            }
            2 => {
                if let Some(ToolRecord::Result(r)) = &mut s.messages[2].tool_record {
                    r.assistant_id = "missing".into();
                }
            }
            3 => s.messages[2].role = "user".into(),
            4 => s.messages[2].tool_record = None,
            _ => {
                let mut copy = s.messages[2].clone();
                copy.id = "duplicate-result".into();
                s.messages.push(copy);
            }
        }
        assert!(
            SidebarProjection::new(&s, ActivePolicy::AcceptedRetained, &cancel()).is_err(),
            "mutation {mutation}"
        );
    }
}
#[test]
fn stream_policy_is_explicit_and_incomplete_prefix_is_identified() {
    let mut s = session();
    s.active_reply = Some("a".into());
    s.messages[1].state = "streaming".into();
    let retained = projected(&s);
    let deferred = SidebarProjection::new(&s, ActivePolicy::DeferActive, &cancel()).unwrap();
    assert_eq!(deferred.deferred_from, Some(1));
    assert_eq!(deferred.pieces.len(), 1);
    assert_eq!(retained.pieces.len(), 5);
    assert_ne!(
        ContentIdentity::of(&retained, &cancel()).unwrap(),
        ContentIdentity::of(&deferred, &cancel()).unwrap()
    );
}
#[test]
fn normalization_mapped_envelopes_and_repeated_occurrences() {
    let text = "  Cafe\u{301}\t\nNEEDLE café needle  ";
    let query = Query::new("CAFÉ needle", &cancel()).unwrap();
    assert_eq!(query.normalized(), "café needle");
    let first = query.ranges(text, 0, 1, &cancel()).unwrap();
    assert_eq!(first.total, 2);
    assert_eq!(first.next, Some(1));
    assert_eq!(
        &text[first.occurrences[0].source.clone()],
        "Cafe\u{301}\t\nNEEDLE"
    );
    let next = query.ranges(text, 1, 1, &cancel()).unwrap();
    assert_eq!(next.occurrences[0].ordinal, 1);
    assert_eq!(&text[next.occurrences[0].source.clone()], "café needle");
    assert_eq!(first.occurrences[0].normalized, 0..12);
    assert_eq!(next.next, None);
}
#[test]
fn canonical_iterator_matches_existing_find_policy() {
    // Existing Find policy is NFC -> scalar lowercase -> NFC. Its exact mapped
    // implementation is included below too, so range differential is not merely
    // a comparison to a duplicated expected normalization algorithm.
    for text in [
        "A\u{30a} É e\u{301}",
        "İSTANBUL ΣΟΣ Straße",
        "각",
        "a\u{315}\u{300}",
        "👩🏽‍💻 שלום",
        "\tOne\nTwo  ",
    ] {
        preflight(text, &cancel()).unwrap();
        let actual: String = canonical_mapped(text, &cancel()).map(|p| p.ch).collect();
        let expected: String = text.nfc().flat_map(char::to_lowercase).nfc().collect();
        assert_eq!(actual, expected);
    }
}
#[test]
fn final_scalar_limits_nul_combining_and_cancel() {
    assert_eq!(Query::new("ab", &cancel()).unwrap_err(), Error::QueryLimit);
    assert!(Query::new("abc", &cancel()).is_ok());
    assert!(Query::new(&"x".repeat(256), &cancel()).is_ok());
    assert_eq!(
        Query::new(&"x".repeat(257), &cancel()).unwrap_err(),
        Error::QueryLimit
    );
    assert!(Query::new(&"İ".repeat(128), &cancel()).is_ok());
    assert_eq!(
        Query::new(&"İ".repeat(129), &cancel()).unwrap_err(),
        Error::QueryLimit
    );
    assert_eq!(
        Query::new("abc\0", &cancel()).unwrap_err(),
        Error::UnsupportedNul
    );
    assert_eq!(
        Query::new(&" ".repeat(MAX_QUERY_BYTES + 1), &cancel()).unwrap_err(),
        Error::QueryLimit
    );
    assert_eq!(
        preflight(&"\u{301}".repeat(MAX_NONSTARTERS + 1), &cancel()),
        Err(Error::CombiningLimit)
    );
    assert_eq!(
        Query::new("abc", &AtomicBool::new(true)).unwrap_err(),
        Error::Cancelled
    );
    assert_eq!(
        Query::new("abc", &cancel())
            .unwrap()
            .ranges("abc", 0, MAX_RANGE_PAGE + 1, &cancel()),
        Err(Error::PageLimit)
    );
}
#[test]
fn long_tail_and_literal_punctuation_are_not_snippet_first_match() {
    let text = format!(
        "{} needle OR \"NEAR\" {} needle OR \"NEAR\"",
        "x".repeat(32760),
        "y".repeat(32760)
    );
    let q = Query::new("needle OR \"NEAR\"", &cancel()).unwrap();
    let page = q.ranges(&text, 1, 1, &cancel()).unwrap();
    assert_eq!(page.total, 2);
    assert!(page.occurrences[0].source.start > 65500);
    assert_eq!(page.occurrences[0].ordinal, 1);
}

// Compile the real existing Find matcher and its unchanged pure dependencies.
// No GPUI module, production export, or alternate copied oracle implementation.
#[allow(dead_code)]
#[path = "../../bello-agent-app/src/conversation_content.rs"]
mod conversation_content;
#[path = "../../bello-agent-app/src/transcript_find_search.rs"]
mod existing_find;
#[test]
fn mapped_range_differential_against_unchanged_find() {
    let atoms = [
        "A",
        "a",
        "é",
        "e\u{301}",
        "İ",
        "\u{307}",
        "\u{315}\u{300}",
        "ᄀ",
        "ᅡ",
        "ᆨ",
        "😀",
        "中",
        "ß",
    ];
    for a in atoms {
        for b in atoms {
            for c in atoms {
                let text = format!("start{a}{b}{c}end {a}{b}{c}");
                let needle = format!("{a}{b}{c}");
                let Ok(query) = Query::new(&needle, &cancel()) else {
                    continue;
                };
                let ours = query.ranges(&text, 0, MAX_RANGE_PAGE, &cancel()).unwrap();
                let existing = existing_find::Query::new(&needle, &cancel())
                    .unwrap()
                    .ranges(&text, 0, MAX_RANGE_PAGE, &cancel())
                    .unwrap();
                assert_eq!(ours.total, existing.total, "{text:?} {needle:?}");
                assert_eq!(
                    ours.occurrences
                        .iter()
                        .map(|p| p.source.clone())
                        .collect::<Vec<_>>(),
                    existing.ranges,
                    "{text:?} {needle:?}"
                );
            }
        }
    }
}
#[test]
fn separate_image_skill_draft_live_and_compaction_containers_are_excluded() {
    use bello_agent_core::{
        Lane, Submission,
        tool_content::{ContentBlock, ToolContent},
        user_content::UserContent,
    };
    use std::sync::Arc;
    let mut s = session();
    let before = digest(&s);
    s.messages[0].user_content = Some(Arc::new(UserContent {
        skills: vec![],
        attachments: vec![],
        blocks: vec![
            ContentBlock::Image {
                data: "USER_IMAGE_SECRET".into(),
                mime_type: "image/png".into(),
            },
            ContentBlock::Text {
                text: "EXPANDED_SKILL_SECRET".into(),
            },
        ],
    }));
    if let Some(ToolRecord::Result(result)) = &mut s.messages[2].tool_record {
        result.content = Some(Arc::new(ToolContent {
            blocks: vec![ContentBlock::Image {
                data: "RESULT_IMAGE_SECRET".into(),
                mime_type: "image/png".into(),
            }],
            stats: None,
        }));
    }
    s.pending
        .push(Submission::new("DRAFT_SECRET".into(), Lane::FollowUp));
    s.retry = Some(Submission::new("RETRY_SECRET".into(), Lane::FollowUp));
    s.live_tools
        .push(bello_agent_core::tool_history::LiveToolView {
            duration_us: None,
            assistant_id: "a".into(),
            call_id: "c2".into(),
            sequence: 1,
            preview: "LIVE_SECRET".into(),
            outcome: None,
        });
    let mut checkpoint = row("cp", "assistant", "SUMMARY_SECRET");
    checkpoint.compaction = Some(bello_agent_core::compaction::Checkpoint {
        version: 1,
        operation_id: "op".into(),
        source_ids: vec![],
        kept_ids: vec![],
        protected_ids: vec![],
        before_estimated_tokens: 10,
        after_estimated_tokens: 1,
    });
    s.messages.push(checkpoint);
    assert_eq!(before, digest(&s));
    let p = projected(&s);
    for needle in [
        "USER_IMAGE_SECRET",
        "RESULT_IMAGE_SECRET",
        "EXPANDED_SKILL_SECRET",
        "DRAFT_SECRET",
        "RETRY_SECRET",
        "LIVE_SECRET",
        "SUMMARY_SECRET",
    ] {
        assert!(
            p.newest_match(&Query::new(needle, &cancel()).unwrap(), &cancel())
                .unwrap()
                .is_none()
        );
    }
    // Admission validation is separate; this deliberately malformed opaque
    // fixture proves projection never traverses/validates excluded containers.
}
#[test]
fn visible_argument_strings_are_not_heuristically_redacted() {
    let mut s = session();
    if let Some(ToolRecord::Assistant(a)) = &mut s.messages[1].tool_record {
        a.calls[0].arguments = json!({"data":"data:image/png;base64,VISIBLE_ARGUMENT"});
    }
    assert!(
        projected(&s)
            .newest_match(
                &Query::new("VISIBLE_ARGUMENT", &cancel()).unwrap(),
                &cancel()
            )
            .unwrap()
            .is_some()
    );
}
#[test]
fn limits_and_cancellation_fail_without_partial_projection_or_identity() {
    let mut s = session();
    s.messages[2].text = "x".repeat(MAX_SOURCE_BYTES + 1);
    assert_eq!(
        SidebarProjection::new(&s, ActivePolicy::AcceptedRetained, &cancel()).unwrap_err(),
        Error::SourceLimit
    );
    assert_eq!(
        canonical_tool_input(&json!("x"), &AtomicBool::new(true)),
        Err(Error::Cancelled)
    );
    assert_eq!(
        ContentIdentity::of(&projected(&session()), &AtomicBool::new(true)),
        Err(Error::Cancelled)
    );
    let mut nested = json!(0);
    for _ in 0..130 {
        nested = json!([nested]);
    }
    assert_eq!(
        canonical_tool_input(&nested, &cancel()),
        Err(Error::SourceLimit)
    );
}
#[test]
fn full_pretty_input_matches_renderer_algorithm_beyond_preview_and_unicode_seam() {
    let value = json!({"value":format!("{}🌍needle","a".repeat(8200)),"quote":"a\"b\nc"});
    let canonical = canonical_tool_input(&value, &cancel()).unwrap();
    let expected = serde_json::to_string_pretty(&value).unwrap();
    assert_eq!(canonical, expected);
    let found = Query::new("🌍needle", &cancel())
        .unwrap()
        .ranges(&canonical, 0, 1, &cancel())
        .unwrap();
    assert_eq!(found.total, 1);
    assert!(found.occurrences[0].source.start > 8192);
}
#[test]
fn source_nul_makes_whole_projection_unavailable_and_diagnostics_are_redacted() {
    let mut s = session();
    let q = Query::new("SECRET_QUERY", &cancel()).unwrap();
    s.messages[0].text = "SECRET_TRANSCRIPT".into();
    let p = projected(&s);
    for diagnostic in [
        format!("{q:?}"),
        format!("{p:?}"),
        format!("{:?}", p.pieces[0]),
    ] {
        assert!(!diagnostic.contains("SECRET"));
    }
    s.messages[2].text = "retained\0unavailable".into();
    assert_eq!(
        SidebarProjection::new(&s, ActivePolicy::AcceptedRetained, &cancel()).unwrap_err(),
        Error::UnsupportedNul
    );
}
