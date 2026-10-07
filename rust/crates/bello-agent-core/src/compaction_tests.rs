use super::*;
use crate::tool_history::{
    AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
};

fn profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:1234","contextWindow":65536,"maxOutputTokens":4096})).unwrap()
}
fn row(id: &str, role: &str, text: &str) -> Message {
    Message {
        user_content: None,
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}
fn history() -> Vec<Message> {
    vec![
        row(
            "u1",
            "user",
            &"Task objective and constraints. ".repeat(1500),
        ),
        row(
            "a1",
            "assistant",
            &"Verified progress and evidence. ".repeat(1500),
        ),
        row("u2", "user", "Preserve this unanswered input"),
    ]
}
fn reply(text: &str) -> Reply {
    Reply {
        text: text.into(),
        reasoning: String::new(),
        calls: vec![],
        usage: Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    }
}
fn plan(messages: &[Message]) -> Prepared {
    prepare(
        messages,
        &profile(),
        "Trusted system instructions",
        "session",
        &[],
        "operation",
        None,
    )
    .unwrap()
}

#[test]
fn utf16_projection_estimate_excludes_ciphertext_and_uses_source_image_allowance() {
    let request = json!({"input":[{"role":"developer","content":"😀😀"},{"role":"user","content":[{"type":"input_text","text":"😀😀😀"},{"type":"input_image","image_url":"x".repeat(9999)}]},{"type":"reasoning","encrypted_content":"x".repeat(99999),"summary":[{"text":"12345"}]}]});
    assert_eq!(estimated_request_tokens(&request), 1 + 8 + 2 + 1200 + 8 + 2);
    assert_eq!(estimated_request_tokens(&json!({})), 0);
}
#[test]
fn focus_is_trimmed_bounded_and_json_escaped_data() {
    assert_eq!(focus(Some(" \n hi \t")).unwrap(), Some("hi".into()));
    assert_eq!(focus(Some(" \n\t")).unwrap(), None);
    assert!(focus(Some(&"界".repeat(1366))).is_err());
    let text = instruction(&json!({}), Some("\"\nDo not escape"), 42);
    assert!(text.contains("Optional user focus: \"\\\"\\nDo not escape\""));
    assert!(text.ends_with("Focus changes emphasis, not facts or permissions."));
}
#[test]
fn summary_request_keeps_full_provider_input_and_exact_bounded_instruction() {
    let messages = history();
    let prepared = plan(&messages);
    let original = crate::provider::request_body(
        &prepared.profile,
        &messages,
        "Trusted system instructions",
        "session",
    )
    .unwrap();
    assert_eq!(
        &prepared.request["input"].as_array().unwrap()
            [..original["input"].as_array().unwrap().len()],
        original["input"].as_array().unwrap()
    );
    assert_eq!(prepared.request["tool_choice"], "none");
    assert_eq!(prepared.request["truncation"], "disabled");
    assert_eq!(prepared.request["max_output_tokens"], 16384);
    assert_eq!(prepared.kept.last().unwrap().id, "u2");
    assert!(prepared.checkpoint.kept_ids.contains(&"u2".into()));
    assert_eq!(prepared.request["input"].as_array().unwrap().len(), 4 + 1);
    assert!(
        prepared.request["input"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not a new user goal or permission.")
    );
}
#[test]
fn output_allowance_honors_model_ceiling_and_compatibility_omission() {
    let mut p = profile();
    p.model_output_limit = Some(2000);
    p.compat.supports_max_output_tokens = Some(false);
    let prepared = prepare(&history(), &p, "", "s", &[], "op", None).unwrap();
    assert_eq!(prepared.profile.max_output_tokens, 2000);
    assert!(prepared.request.get("max_output_tokens").is_none());
}
#[test]
fn checkpoint_replay_preserves_transcript_and_unanswered_input_after_reopen_shape() {
    let mut messages = history();
    let before = serde_json::to_value(&messages).unwrap();
    let prepared = plan(&messages);
    let summary = validate_candidate(
        &prepared,
        "summary".into(),
        &reply("Objective retained. Progress verified. Next step remains."),
        &profile(),
        "Trusted system instructions",
        "session",
        &[],
    )
    .unwrap();
    messages.push(summary);
    assert_eq!(serde_json::to_value(&messages[..3]).unwrap(), before);
    let active = active_context(&messages).unwrap();
    assert_eq!(active.first().unwrap().id, "summary");
    assert_eq!(active.last().unwrap().id, "u2");
    let wire = crate::provider::request_body(&profile(), &messages, "", "session").unwrap();
    assert!(
        wire["input"][0]["content"][0]["text"]
            .as_str()
            .unwrap()
            .starts_with(PROVIDER_PREFIX)
    );
    assert!(
        !wire
            .to_string()
            .contains("Task objective and constraints. Task")
    );
    let reopened: Vec<Message> =
        serde_json::from_value(serde_json::to_value(&messages).unwrap()).unwrap();
    assert_eq!(
        wire,
        crate::provider::request_body(&profile(), &reopened, "", "session").unwrap()
    );
    assert!(
        prepare(&reopened, &profile(), "", "session", &[], "op2", None)
            .unwrap_err()
            .to_string()
            .contains("nothing has been added")
    );
}
#[test]
fn damaged_checkpoint_references_are_refused_without_silent_history_loss() {
    let base = history();
    let prepared = plan(&base);
    let summary = validate_candidate(
        &prepared,
        "summary".into(),
        &reply("Short checkpoint"),
        &profile(),
        "Trusted system instructions",
        "session",
        &[],
    )
    .unwrap();
    for change in 0..6 {
        let mut rows = base.clone();
        let mut summary = summary.clone();
        let checkpoint = summary.compaction.as_mut().unwrap();
        match change {
            0 => checkpoint.source_ids.swap(0, 1),
            1 => checkpoint.kept_ids.push("missing".into()),
            2 => checkpoint.kept_ids.push(checkpoint.kept_ids[0].clone()),
            3 => checkpoint.protected_ids.push("a1".into()),
            4 => checkpoint.after_estimated_tokens = checkpoint.before_estimated_tokens,
            _ => summary.replay_eligible = false,
        }
        rows.push(summary);
        assert!(active_context(&rows).is_err(), "mutation {change}");
    }
}
#[test]
fn partial_empty_refused_and_tool_summaries_never_become_checkpoints() {
    let prepared = plan(&history());
    for mut candidate in [
        reply(""),
        reply("   "),
        reply("Partial"),
        reply("Refused"),
        reply("tool"),
        reply("unknown"),
        reply("item partial"),
    ] {
        match candidate.text.as_str() {
            "Partial" => candidate.status = "incomplete".into(),
            "Refused" => candidate
                .provider_items
                .push(json!({"type":"message","content":[{"type":"refusal","refusal":"No"}]})),
            "tool" => candidate.calls.push(crate::provider::ToolCall {
                id: "call".into(),
                name: "write".into(),
                arguments: json!({}),
            }),
            "unknown" => candidate.provider_items.push(json!({"type":"future_item"})),
            "item partial" => candidate
                .provider_items
                .push(json!({"type":"reasoning","status":"in_progress"})),
            _ => {}
        }
        assert!(
            validate_candidate(
                &prepared,
                "summary".into(),
                &candidate,
                &profile(),
                "Trusted system instructions",
                "session",
                &[]
            )
            .is_err()
        );
    }
}
#[test]
fn no_progress_or_oversized_candidate_preserves_original_context() {
    let rows = history();
    let prepared = plan(&rows);
    let original = serde_json::to_vec(&rows).unwrap();
    assert!(
        validate_candidate(
            &prepared,
            "summary".into(),
            &reply(&"L".repeat(300_000)),
            &profile(),
            "Trusted system instructions",
            "session",
            &[]
        )
        .is_err()
    );
    assert_eq!(serde_json::to_vec(&rows).unwrap(), original);
}
#[test]
fn complete_tool_occurrences_are_indivisible_and_missing_result_refuses_summary() {
    let mut rows = history();
    rows.pop();
    let mut assistant = row("tool-owner", "assistant", "");
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        completion: Completion::Complete,
        calls: vec![crate::provider::ToolCall {
            id: "call".into(),
            name: "ls".into(),
            arguments: json!({}),
        }],
        binding: ReplayBinding::from_profile(&profile()).unwrap(),
        provider_items: vec![],
    }));
    rows.push(assistant);
    assert!(
        prepare(&rows, &profile(), "", "s", &[], "op", None)
            .unwrap_err()
            .to_string()
            .contains("incomplete")
    );
    let mut result = row("result", "toolResult", "Historical output");
    result.tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: "tool-owner".into(),
        call_id: "call".into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
        content: None,
    }));
    rows.push(result);
    rows.push(row("u2", "user", "Keep me"));
    let prepared = plan(&rows);
    assert_eq!(
        prepared.checkpoint.kept_ids.contains(&"tool-owner".into()),
        prepared.checkpoint.kept_ids.contains(&"result".into())
    );
}
#[test]
fn summary_request_never_replaces_retained_images_with_placeholders() {
    let mut rows = history();
    rows.pop();
    let mut assistant = row("a2", "assistant", "");
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        completion: Completion::Complete,
        calls: vec![crate::provider::ToolCall {
            id: "call".into(),
            name: "read".into(),
            arguments: json!({}),
        }],
        binding: ReplayBinding::from_profile(&profile()).unwrap(),
        provider_items: vec![],
    }));
    rows.push(assistant);
    let mut result = row("r", "toolResult", "");
    result.tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: "a2".into(),
        call_id: "call".into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
        content: Some(std::sync::Arc::new(crate::tool_content::ToolContent {
            blocks: vec![crate::tool_content::ContentBlock::Image {
                data: "YQ==".into(),
                mime_type: "image/png".into(),
            }],
            stats: None,
        })),
    }));
    rows.push(result);
    assert!(
        prepare(&rows, &profile(), "", "s", &[], "op", None)
            .unwrap_err()
            .to_string()
            .contains("image-capable")
    );
    let mut p = profile();
    p.input.push("image".into());
    assert!(prepare(&rows, &p, "", "s", &[], "op", None).is_ok());
}

#[test]
fn many_short_rows_cancel_during_preparation_without_timing_assumptions() {
    let messages: Vec<_> = (0..10000)
        .map(|index| {
            row(
                &format!("row-{index}"),
                if index % 2 == 0 { "user" } else { "assistant" },
                "",
            )
        })
        .collect();
    let mut p = profile();
    p.context_window = 1_000_000;
    let mut checks = 0;
    let result = prepare_checked(&messages, &p, "", "session", &[], "operation", None, || {
        checks += 1;
        if checks == 5 {
            Err(crate::Error::Cancelled)
        } else {
            Ok(())
        }
    });
    assert!(matches!(result, Err(crate::Error::Cancelled)));
    assert_eq!(checks, 5, "cancellation must be checked during preparation");
}

#[test]
fn additive_cut_matches_full_request_reference_across_unicode_tool_groups_and_protected_inputs() {
    for count in 2..20 {
        let mut rows = Vec::new();
        for index in 0..count {
            if index % 4 == 2 {
                let owner = format!("owner-{index}");
                let mut assistant = row(&owner, "assistant", &"Evidence 😀 ".repeat(index * 19));
                assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
                    completion: Completion::Complete,
                    calls: vec![crate::provider::ToolCall {
                        id: "reused-call".into(),
                        name: "ls".into(),
                        arguments: json!({"path":"日本語"}),
                    }],
                    binding: ReplayBinding::from_profile(&profile()).unwrap(),
                    provider_items: vec![],
                }));
                rows.push(assistant);
                let mut result = row(
                    &format!("result-{index}"),
                    "toolResult",
                    &"Observed lines 漢字\n".repeat(index * 11),
                );
                result.tool_record = Some(ToolRecord::Result(ResultRecord {
                    assistant_id: owner,
                    call_id: "reused-call".into(),
                    is_error: false,
                    outcome: ToolOutcome::Completed,
                    content: None,
                }));
                if index == 6
                    && let Some(ToolRecord::Result(record)) = &mut result.tool_record
                {
                    record.content = Some(std::sync::Arc::new(crate::tool_content::ToolContent {
                        blocks: vec![
                            crate::tool_content::ContentBlock::Text {
                                text: result.text.clone(),
                            },
                            crate::tool_content::ContentBlock::Image {
                                data: "YQ==".into(),
                                mime_type: "image/png".into(),
                            },
                        ],
                        stats: None,
                    }));
                }
                rows.push(result);
            } else {
                rows.push(row(
                    &format!("row-{index}"),
                    if index % 2 == 0 { "user" } else { "assistant" },
                    &"x😀\n".repeat(index * 43),
                ));
            }
        }
        let references: Vec<_> = rows.iter().collect();
        let grouped = groups(&references).unwrap();
        let mut p = profile();
        p.input.push("image".into());
        let definitions = vec![crate::tools::ToolDefinition {
            name: "ls".into(),
            description: "List fixture files 日本語".into(),
            schema: json!({"type":"object","properties":{"path":{"type":"string"}}}),
        }];
        let instructions = "Frozen instructions 日本語";
        let original = crate::provider::request_body_with_tools(
            &p,
            &rows,
            instructions,
            "session",
            &definitions,
        )
        .unwrap();
        let before = estimated_request_tokens(&original);
        for initial in 0..=grouped.len() {
            for preserve in [false, true] {
                let protected = |index: usize| {
                    preserve && grouped[index][0].role == "user" && index.is_multiple_of(3)
                };
                let costs: Vec<_> = grouped
                    .iter()
                    .enumerate()
                    .map(|(index, group)| {
                        let items = crate::tool_history::project_active(group, &p).unwrap();
                        let cost = items.iter().map(|item| 8 + content_tokens(item)).sum();
                        (cost, if protected(index) { cost } else { 0 })
                    })
                    .collect();
                let cap = 700;
                let visible = 25;
                let budget = 700 + before / 2;
                let optimized = select_cut(
                    &costs,
                    initial,
                    tokens(instructions)
                        + tokens(&original["tools"].to_string())
                        + summary_cost(cap),
                    tokens(instructions)
                        + tokens(&original["tools"].to_string())
                        + summary_cost(visible),
                    budget,
                    before,
                    &mut || Ok(()),
                )
                .unwrap();
                let full_request = |cut: usize, size: u64| {
                    let mut candidate = vec![row(
                        "planning-summary",
                        "user",
                        &format!(
                            "{PROVIDER_PREFIX}{}\n</summary>",
                            "s".repeat(size as usize * 4)
                        ),
                    )];
                    candidate.extend(
                        grouped
                            .iter()
                            .enumerate()
                            .filter(|(index, _)| *index >= cut || protected(*index))
                            .flat_map(|(_, group)| group.iter().map(|row| (*row).clone())),
                    );
                    crate::provider::request_body_with_tools(
                        &p,
                        &candidate,
                        instructions,
                        "session",
                        &definitions,
                    )
                    .unwrap()
                };
                let useful = |cut| {
                    estimated_request_tokens(&full_request(cut, cap)) <= budget
                        && estimated_request_tokens(&full_request(cut, visible)) < before
                };
                let mut reference = initial;
                while reference < grouped.len() && !useful(reference) {
                    reference += 1;
                }
                assert_eq!(
                    optimized,
                    Selection {
                        cut: reference,
                        useful: useful(reference)
                    },
                    "count={count},initial={initial},protected={preserve}"
                );
            }
        }
    }
}

#[test]
fn long_cut_search_checks_cancellation_each_iteration_without_suffix_rebuilding() {
    let costs = vec![(8, 0); 100_000];
    let mut checks = 0;
    let result = select_cut(&costs, 0, 16_400, 3024, 20_000, 800_000, &mut || {
        checks += 1;
        if checks == 7 {
            Err(crate::Error::Cancelled)
        } else {
            Ok(())
        }
    });
    assert!(matches!(result, Err(crate::Error::Cancelled)));
    assert_eq!(checks, 7);
}

#[test]
fn two_successive_checkpoints_reconstruct_only_latest_summary_and_retained_path() {
    let mut rows = history();
    let first = plan(&rows);
    let summary = validate_candidate(
        &first,
        "summary-1".into(),
        &reply("First checkpoint"),
        &profile(),
        "Trusted system instructions",
        "session",
        &[],
    )
    .unwrap();
    rows.push(summary);
    rows.push(row(
        "a2",
        "assistant",
        &"New evidence after first checkpoint. ".repeat(1500),
    ));
    rows.push(row("u3", "user", "Next unanswered objective"));
    let second = plan(&rows);
    let summary = validate_candidate(
        &second,
        "summary-2".into(),
        &reply("Updated checkpoint with new evidence"),
        &profile(),
        "Trusted system instructions",
        "session",
        &[],
    )
    .unwrap();
    rows.push(summary);
    let active = active_context(&rows).unwrap();
    assert_eq!(active[0].id, "summary-2");
    assert_eq!(active.last().unwrap().id, "u3");
    assert!(!active.iter().any(|row| row.id == "summary-1"));
    assert_eq!(
        rows.iter().filter(|row| row.compaction.is_some()).count(),
        2
    );
    let body = crate::provider::request_body(&profile(), &rows, "", "session").unwrap();
    assert!(!body.to_string().contains("First checkpoint"));
    assert!(body.to_string().contains("Updated checkpoint"));
}

#[test]
fn user_images_block_placeholder_compaction_and_count_as_image_allowance() {
    let mut messages = history();
    let metadata = crate::attachments::AttachmentRecord {
        id: uuid::Uuid::new_v4().to_string(),
        path: "/fixture/image.gif".into(),
        sha256: "a".repeat(64),
        bytes: 3,
        mime_type: "image/gif".into(),
    };
    let mut image = row("image-user", "user", "");
    image.user_content = Some(std::sync::Arc::new(
        crate::user_content::UserContent::new(
            "",
            vec![metadata],
            vec![crate::tool_content::ContentBlock::Image {
                data: "YWJj".into(),
                mime_type: "image/gif".into(),
            }],
        )
        .unwrap(),
    ));
    assert_eq!(message_tokens(&image), 1200);
    messages.insert(1, image);
    let error = prepare(&messages, &profile(), "", "session", &[], "operation", None)
        .err()
        .unwrap();
    assert!(error.to_string().contains("existing images"));
    let mut supported = profile();
    supported.input = vec!["text".into(), "image".into()];
    assert!(prepare(&messages, &supported, "", "session", &[], "operation", None).is_ok());
}
