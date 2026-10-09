use super::*;
use bello_agent_core::provider::ToolCall;
use bello_agent_core::tool_content::ContentBlock;
use bello_agent_core::tool_history::{AssistantRecord, Completion, ReplayBinding, ToolRecord};
use bello_agent_core::{Lane, Message, Submission};

fn message(id: &str, text: &str) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: id.into(),
        role: "assistant".into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}
fn session(texts: &[&str]) -> Arc<Session> {
    let mut value = Session::new();
    value.messages = texts
        .iter()
        .enumerate()
        .map(|(i, text)| message(&format!("row-{i}"), text))
        .collect();
    Arc::new(value)
}
fn not_cancelled() -> AtomicBool {
    AtomicBool::new(false)
}

#[test]
fn pages_all_retained_rows_and_keeps_original_positions() {
    let mut value = Session::new();
    value.messages = (0..205)
        .map(|i| message(&format!("row-{i}"), &format!("Match {i}")))
        .collect();
    let snapshot = Snapshot::new(Arc::new(value));
    let first = snapshot.search("match", 0).unwrap();
    assert_eq!(first.total, 205);
    assert_eq!(first.hits.len(), 100);
    assert_eq!(first.hits[0].position, 1);
    assert_eq!(first.next, Some(100));
    let second = snapshot.search("match", first.next.unwrap()).unwrap();
    assert_eq!(second.hits[0].position, 101);
    assert_eq!(second.next, Some(200));
    let last = snapshot.search("match", second.next.unwrap()).unwrap();
    assert_eq!(last.hits.len(), 5);
    assert_eq!(last.hits[4].position, 205);
    assert_eq!(last.next, None);
    let no_match = snapshot.search("absent", 0).unwrap();
    assert!(no_match.hits.is_empty());
    assert_eq!(no_match.total, 205);
    assert_eq!(no_match.next, None);
    assert!(snapshot.search("", 100_001).is_err());
    assert!(snapshot.search("", 206).unwrap().hits.is_empty());
}
#[test]
fn query_limit_counts_graphemes_and_portable_canonical_case_matching() {
    let snapshot = Snapshot::new(session(&["CAFÉ", "Straße", "İstanbul"]));
    assert_eq!(snapshot.search("cafe\u{301}", 0).unwrap().hits.len(), 1);
    assert!(snapshot.search(&"👩🏽‍💻".repeat(256), 0).is_ok());
    assert!(snapshot.search(&"e\u{301}".repeat(256), 0).is_ok());
    assert!(snapshot.search(&"e\u{301}".repeat(257), 0).is_err());
    // Explicit portability boundary: lowercase is not locale/full case folding.
    assert!(snapshot.search("STRASSE", 0).unwrap().hits.is_empty());
    assert!(snapshot.search("istanbul", 0).unwrap().hits.is_empty());
}
#[test]
fn previews_follow_source_byte_prefix_and_edge_replacement_trimming() {
    assert_eq!(preview(&format!("{}é", "a".repeat(239))), "a".repeat(239));
    assert_eq!(preview(&format!("{}é", "a".repeat(238))).len(), 240);
    assert_eq!(preview("\u{fffd}a\u{fffd}b\u{fffd}"), "a\u{fffd}b");
    assert_eq!(preview("\r\n  text \t"), "\r\n  text \t");
    let snapshot = Snapshot::new(session(&[&format!("{} needle", "x".repeat(300))]));
    assert_eq!(
        snapshot.search("needle", 0).unwrap().hits[0].preview,
        "x".repeat(240)
    );
}
#[test]
fn collect_is_inclusive_exact_concatenation_without_invented_separators() {
    let snapshot = Snapshot::new(session(&[
        "  **one**\r\n",
        "",
        "你好 e\u{301} 👩🏽‍💻\t",
        "last",
    ]));
    assert_eq!(
        snapshot.collect(1, 3, &not_cancelled()).unwrap(),
        "  **one**\r\n你好 e\u{301} 👩🏽‍💻\t"
    );
    assert_eq!(snapshot.collect(2, 2, &not_cancelled()).unwrap(), "");
    assert_eq!(snapshot.collect(4, 4, &not_cancelled()).unwrap(), "last");
    for (first, last) in [(0, 1), (2, 1), (1, 5), (5, 5)] {
        assert!(snapshot.collect(first, last, &not_cancelled()).is_err());
    }
    let empty = Snapshot::new(session(&[]));
    assert_eq!(empty.search("", 0).unwrap().total, 0);
    assert!(empty.collect(1, 1, &not_cancelled()).is_err());
}
#[test]
fn copy_limit_is_inclusive_and_unicode_pages_never_lose_bytes() {
    let text = format!(
        "{}🦀{}",
        "a".repeat(PAGE_BYTES - 1),
        "x".repeat(COPY_LIMIT - PAGE_BYTES - 3)
    );
    assert_eq!(text.len(), COPY_LIMIT);
    let snapshot = Snapshot::new(session(&[&text, "z"]));
    assert_eq!(snapshot.collect(1, 1, &not_cancelled()).unwrap(), text);
    assert!(
        snapshot
            .collect(1, 2, &not_cancelled())
            .unwrap_err()
            .contains("8 MiB")
    );
    assert!(
        Snapshot::new(session(&[&"x".repeat(COPY_LIMIT + 1)]))
            .collect(1, 1, &not_cancelled())
            .is_err()
    );
    assert!(
        snapshot
            .collect(1, 1, &AtomicBool::new(true))
            .unwrap_err()
            .contains("cancelled")
    );
}
#[test]
fn content_fence_detects_equal_length_text_identity_order_and_session_changes() {
    let original = session(&["same", "size"]);
    let snapshot = Snapshot::new(original.clone());
    assert!(snapshot.matches(&original));
    let mut changed = (*original).clone();
    changed.messages[0].text = "else".into();
    assert!(!snapshot.matches(&Arc::new(changed)));
    let mut changed = (*original).clone();
    changed.messages[0].id = "replacement".into();
    assert!(!snapshot.matches(&Arc::new(changed)));
    let mut changed = (*original).clone();
    changed.messages.swap(0, 1);
    assert!(!snapshot.matches(&Arc::new(changed)));
    let mut changed = (*original).clone();
    changed.id = "another session".into();
    assert!(!snapshot.matches(&Arc::new(changed)));
    let mut changed = (*original).clone();
    changed.messages.push(message("new", ""));
    assert!(!snapshot.matches(&Arc::new(changed)));
}
#[test]
fn queue_usage_and_hidden_payload_changes_do_not_invalidate_display_selection() {
    let original = session(&["display"]);
    let snapshot = Snapshot::new(original.clone());
    let mut changed = (*original).clone();
    changed.revision += 1;
    changed.title = "renamed".into();
    changed.queue_paused = true;
    changed
        .pending
        .push(Submission::new("unsent draft".into(), Lane::FollowUp));
    changed.messages[0].usage = serde_json::json!({"tokens":12});
    changed.messages[0].reasoning = "not display".into();
    assert!(snapshot.matches(&Arc::new(changed)));
}
#[test]
fn duplicate_identity_is_retained_positionally_but_never_silently_deduplicated() {
    let mut original = (*session(&["first", "second"])).clone();
    original.messages[1].id = original.messages[0].id.clone();
    let snapshot = Snapshot::new(Arc::new(original.clone()));
    let page = snapshot.search("", 0).unwrap();
    assert_eq!(page.hits[0].id, page.hits[1].id);
    assert_eq!(page.hits[0].position, 1);
    assert_eq!(page.hits[1].position, 2);
    assert_eq!(
        snapshot.collect(1, 2, &not_cancelled()).unwrap(),
        "firstsecond"
    );
    original.messages.swap(0, 1);
    assert!(!snapshot.matches(&Arc::new(original)));
    // Reveal is separately required to reject non-unique IDs in the controller.
}
#[test]
fn search_and_copy_never_project_tool_provider_images_or_expanded_skill_payloads() {
    let mut value = Session::new();
    let mut row = message("input", "Literal skill arguments");
    row.role = "user".into();
    row.reasoning = "SECRET_REASONING".into();
    row.task_root_id = Some("SECRET_CONTEXT_ID".into());
    row.user_content = Some(Arc::new(bello_agent_core::user_content::UserContent {
        skills: Vec::new(),
        attachments: vec![bello_agent_core::attachments::AttachmentRecord {
            id: uuid::Uuid::new_v4().to_string(),
            path: "/SECRET_ATTACHMENT_PATH.png".into(),
            sha256: "a".repeat(64),
            bytes: 3,
            mime_type: "image/png".into(),
        }],
        blocks: vec![
            ContentBlock::Text {
                text: "SECRET_EXPANDED_SKILL_BODY".into(),
            },
            ContentBlock::Image {
                data: "SECRET_IMAGE_BYTES".into(),
                mime_type: "image/png".into(),
            },
        ],
    }));
    let mut tool = message("tool", "Visible tool result");
    tool.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        tool_batch_timing: None,
        completion: Completion::Complete,
        calls: vec![ToolCall {
            id: "call".into(),
            name: "mcp".into(),
            arguments: serde_json::json!({"headers":"SECRET_CREDENTIAL"}),
        }],
        binding: ReplayBinding {
            profile_id: "SECRET_PROFILE".into(),
            api: "openai-responses".into(),
            provider: "litellm".into(),
            model: "model".into(),
            endpoint_sha256: "a".repeat(64),
        },
        provider_items: vec![
            serde_json::json!({"encrypted_content":"SECRET_OPAQUE_PROVIDER_STATE"}),
        ],
    }));
    value.messages = vec![row, tool, message("image-only", "")];
    let snapshot = Snapshot::new(Arc::new(value));
    assert!(snapshot.search("SECRET", 0).unwrap().hits.is_empty());
    assert_eq!(
        snapshot.collect(1, 3, &not_cancelled()).unwrap(),
        "Literal skill argumentsVisible tool result"
    );
    assert_eq!(snapshot.search("", 0).unwrap().hits[2].preview, "");
}

#[test]
fn active_streaming_reply_is_not_retained_until_terminal_and_deltas_keep_selection() {
    let mut value = (*session(&["before", "partial", "after"])).clone();
    value.active_reply = Some("row-1".into());
    value.messages[1].state = "streaming".into();
    let snapshot = Snapshot::new(Arc::new(value.clone()));
    let page = snapshot.search("", 0).unwrap();
    assert_eq!(page.total, 2);
    assert_eq!(
        page.hits.iter().map(|hit| hit.position).collect::<Vec<_>>(),
        vec![1, 2]
    );
    assert_eq!(page.hits[1].id, "row-2");
    assert!(snapshot.search("partial", 0).unwrap().hits.is_empty());
    assert_eq!(
        snapshot.collect(1, 2, &not_cancelled()).unwrap(),
        "beforeafter"
    );
    assert_eq!(snapshot.collect(2, 2, &not_cancelled()).unwrap(), "after");
    value.messages[1].text.push_str(" more streaming bytes");
    assert!(snapshot.matches(&Arc::new(value.clone())));
    for state in ["complete", "cancelled", "interrupted", "failed"] {
        let mut terminal = value.clone();
        terminal.messages[1].state = state.into();
        terminal.active_reply = None;
        assert!(!snapshot.matches(&Arc::new(terminal.clone())));
        let terminal = Snapshot::new(Arc::new(terminal));
        assert_eq!(terminal.search("partial", 0).unwrap().hits[0].position, 2);
        assert_eq!(
            terminal.collect(2, 2, &not_cancelled()).unwrap(),
            "partial more streaming bytes"
        );
    }
}
#[test]
fn starting_or_replacing_only_active_stream_does_not_change_retained_content() {
    let base = session(&["completed"]);
    let snapshot = Snapshot::new(base.clone());
    let mut streaming = (*base).clone();
    let mut partial = message("new-stream", "not yet retained");
    partial.state = "streaming".into();
    streaming.messages.push(partial);
    streaming.active_reply = Some("new-stream".into());
    assert!(snapshot.matches(&Arc::new(streaming.clone())));
    streaming.messages[1].id = "replacement-stream".into();
    streaming.active_reply = Some("replacement-stream".into());
    assert!(snapshot.matches(&Arc::new(streaming)));
}

#[test]
fn huge_single_grapheme_query_is_refused_before_grapheme_or_normalization_work() {
    let snapshot = Snapshot::new(session(&["ordinary"]));
    let query = format!("a{}", "\u{301}".repeat(QUERY_BYTE_LIMIT));
    assert_eq!(query.graphemes(true).count(), 1);
    assert!(snapshot.search(&query, 0).unwrap_err().contains("16 KiB"));
}
#[test]
fn pathological_message_combining_segment_has_visible_error_not_partial_results() {
    let bad = format!("a{}", "\u{301}".repeat(MAX_NONSTARTERS + 1));
    let snapshot = Snapshot::new(session(&["match", &bad]));
    assert!(
        snapshot
            .search("match", 0)
            .unwrap_err()
            .contains("combining-character")
    );
    let boundary = format!("a{}", "\u{301}".repeat(MAX_NONSTARTERS));
    assert!(
        Snapshot::new(session(&[&boundary]))
            .search("absent", 0)
            .is_ok()
    );
}
#[test]
fn large_nonmatching_and_overlapping_kmp_search_streams_without_full_text_projection() {
    let text = format!("{}Z", "abab".repeat(1024 * 1024));
    let snapshot = Snapshot::new(session(&[&text]));
    assert!(snapshot.search("absent", 0).unwrap().hits.is_empty());
    assert_eq!(snapshot.search("abababz", 0).unwrap().hits.len(), 1);
    let source = "a".repeat(2 * 1024 * 1024);
    let cancel = AtomicBool::new(false);
    let mut normalized = normalized_chars(&source, &cancel);
    assert_eq!(normalized.next(), Some('a'));
    cancel.store(true, Ordering::Release);
    assert!(normalized.count() <= CANCEL_INTERVAL + 1);
    assert!(search_check_cancel(&cancel).is_err());
    assert!(
        snapshot
            .search_cancelled("match", 0, &cancel)
            .unwrap_err()
            .contains("cancelled")
    );
}

#[test]
fn latest_loaded_occurrence_counts_are_nonoverlapping_case_insensitive_and_record_scoped() {
    let snapshot = Snapshot::new(session(&["AaAaA", "AAA", "aA-aa-AA", "absent"]));
    let page = snapshot.search("aa", 0).unwrap();
    assert_eq!(
        page.hits.iter().map(|hit| hit.count).collect::<Vec<_>>(),
        vec![Some(2), Some(1), Some(3)]
    );
    assert_eq!(
        page.hits.iter().map(|hit| hit.position).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(page.total, 4);
    assert_eq!(snapshot.search("aaa", 0).unwrap().hits[0].count, Some(1));
    assert!(snapshot.search("missing", 0).unwrap().hits.is_empty());
}

#[test]
fn latest_loaded_empty_query_supplies_zero_and_legacy_count_is_optional() {
    let page = Snapshot::new(session(&["", "aaa"])).search("", 0).unwrap();
    assert_eq!(page.hits.len(), 2);
    assert!(page.hits.iter().all(|hit| hit.count == Some(0)));
    let mut legacy_hit = page.hits[0].clone();
    legacy_hit.count = None;
    assert_eq!(legacy_hit.count.unwrap_or(1), 1);
}

#[test]
fn occurrence_counting_keeps_unicode_streaming_and_page_limits() {
    let row = "CAFÉ cafe\u{301} CAFÉ ";
    let mut value = Session::new();
    value.messages = (0..101)
        .map(|index| message(&format!("row-{index}"), row))
        .collect();
    let snapshot = Snapshot::new(Arc::new(value));
    let first = snapshot.search("cafe\u{301}", 0).unwrap();
    assert_eq!(first.hits.len(), 100);
    assert!(first.hits.iter().all(|hit| hit.count == Some(3)));
    assert_eq!(first.next, Some(100));
    let last = snapshot.search("CAFÉ", first.next.unwrap()).unwrap();
    assert_eq!(last.hits[0].position, 101);
    assert_eq!(last.hits[0].count, Some(3));
    assert_eq!(last.next, None);
    // Scans beyond the first occurrence without retaining a normalized text copy.
    let text = format!("Aa{}aA", "x".repeat(PAGE_BYTES * 3));
    assert_eq!(
        Snapshot::new(session(&[&text]))
            .search("aa", 0)
            .unwrap()
            .hits[0]
            .count,
        Some(2)
    );
}
