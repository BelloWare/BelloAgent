use super::*;
use crate::skills::{SkillChip, SkillSelection};

fn skill(f: &Fixture, directory: &str, body: &str) -> PathBuf {
    let path = f
        .root
        .join(".agents/skills")
        .join(directory)
        .join("SKILL.md");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, format!("---\nname: review\ndescription: Review generated fixtures\ndisable-model-invocation: true\n---\n{body}")).unwrap();
    path
}
fn receipt(
    f: &Fixture,
    record: &ChatRecord,
    actor: &Arc<Controller>,
    item: &Submission,
    chips: Vec<SkillChip>,
    revision: u64,
) -> SubmissionIntent {
    let intent = SubmissionIntent {
        skills: chips.clone(),
        attachments: item.attachments.clone(),
        id: item.id.clone(),
        chat_id: record.id.clone(),
        text: item.text.clone(),
        lane: item.lane.clone(),
        draft_revision: revision,
    };
    let mut store = f.workspace.lock().unwrap();
    store
        .register(
            record.clone(),
            DraftRecord {
                skills: chips,
                attachments: item.attachments.clone(),
                revision,
                text: item.text.clone(),
                queued_edit: None,
            },
        )
        .unwrap();
    store.begin_submission(intent.clone()).unwrap();
    drop(store);
    actor.materialize(&record.snapshot).unwrap();
    intent
}
fn selections(chips: &[SkillChip]) -> Vec<SkillSelection> {
    chips.iter().map(|chip| chip.selection.clone()).collect()
}
fn user_inputs(body: &Value) -> Vec<&Value> {
    body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["role"] == "user")
        .collect()
}

#[tokio::test]
async fn picker_skill_only_order_literal_arguments_receipt_context_and_plain_slash_followup() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    skill(&f, "a", "FIRST BODY");
    skill(&f, "b", "SECOND BODY");
    std::fs::write(f.root.join("AGENTS.md"), "PROJECT INSTRUCTIONS").unwrap();
    let (record, actor) = f.pending();
    let catalog = actor.discover_project_skills().await.unwrap();
    assert_eq!(catalog.skills.len(), 2);
    let chips = vec![
        catalog.skills[1].chip("$LITERAL /not-command\n\"quoted\"".into()),
        catalog.skills[0].chip(String::new()),
    ];
    let item = Submission::new(String::new(), Lane::FollowUp);
    let intent = receipt(&f, &record, &actor, &item, chips.clone(), 1);
    let before = std::fs::read(&record.snapshot).unwrap();
    let preview = actor
        .prepare_context_with_inputs("", &[], &selections(&chips))
        .await
        .unwrap();
    assert!(preview.request_json().contains("SECOND BODY"));
    assert_eq!(std::fs::read(&record.snapshot).unwrap(), before);
    actor
        .submit_identified_with_inputs(item.clone(), selections(&chips))
        .await
        .unwrap();
    assert!(actor.submission_intent_status(&intent).unwrap());
    let request = Request::accept(&listener).await;
    let inputs = user_inputs(&request.body);
    let text = inputs[0]["content"][0]["text"].as_str().unwrap();
    assert!(text.find("SECOND BODY").unwrap() < text.find("FIRST BODY").unwrap());
    assert!(text.contains("$LITERAL /not-command\n\"quoted\""));
    assert!(text.ends_with("\n\n"));
    assert!(request.body.to_string().contains("PROJECT INSTRUCTIONS"));
    let current = actor.snapshot();
    assert_eq!(current.version, 9);
    let row = current
        .messages
        .iter()
        .find(|row| row.id == item.id)
        .unwrap();
    assert_eq!(row.text, "");
    assert_eq!(row.task_root_id.as_deref(), Some(item.id.as_str()));
    assert_eq!(
        row.user_content.as_ref().unwrap().skills[0].selection,
        chips[0].selection
    );
    let deferred = actor
        .prepare_context_with_inputs(
            "later",
            &[],
            &[catalog.skills[0].selection("different".into())],
        )
        .await
        .unwrap();
    assert!(deferred.metadata().draft_deferred);
    assert!(!deferred.request_json().contains("different"));
    request.complete("complete").await;
    settled(&actor).await;
    actor
        .submit("/review pasted".into(), Lane::FollowUp)
        .unwrap();
    let second = Request::accept(&listener).await;
    let inputs = user_inputs(&second.body);
    assert_eq!(
        inputs.last().unwrap()["content"][0]["text"],
        "/review pasted"
    );
    second.complete("plain text").await;
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn queued_body_is_frozen_metadata_revocation_pauses_and_empty_edit_preserves_selection() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let path = skill(&f, "one", "OLD BODY");
    let (record, actor) = f.pending();
    let first = f.prepare(&record, &actor, "keep first request open");
    actor.submit_identified(first).unwrap();
    let request = Request::accept(&listener).await;
    let catalog = actor.discover_project_skills().await.unwrap();
    let selected = vec![catalog.skills[0].selection("literal".into())];
    let queued = Submission::new("queued text".into(), Lane::FollowUp);
    let queued_id = queued.id.clone();
    actor
        .submit_identified_with_inputs(queued, selected)
        .await
        .unwrap();
    actor.begin_edit(&queued_id, "edit-skills").unwrap();
    actor
        .resolve_edit("edit-skills", "saved", Some(""))
        .unwrap();
    skill(&f, "one", "NEW BODY");
    request.complete("first done").await;
    let delivered = Request::accept(&listener).await;
    let inputs = user_inputs(&delivered.body);
    let text = inputs.last().unwrap()["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(text.contains("OLD BODY"));
    assert!(!text.contains("NEW BODY"));
    let latest = actor.discover_project_skills().await.unwrap();
    let next = Submission::new(String::new(), Lane::FollowUp);
    let next_id = next.id.clone();
    actor
        .submit_identified_with_inputs(next, vec![latest.skills[0].selection(String::new())])
        .await
        .unwrap();
    let changed = std::fs::read_to_string(&path).unwrap().replace(
        "description: Review generated fixtures",
        "description: Changed policy metadata",
    );
    std::fs::write(&path, changed).unwrap();
    delivered.complete("skill done").await;
    settled(&actor).await;
    let paused = actor.snapshot();
    assert!(paused.queue_paused);
    assert_eq!(paused.pending.len(), 1);
    assert_eq!(paused.pending[0].id, next_id);
    assert!(paused.error.unwrap().contains("authorization changed"));
    assert!(
        timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn delivered_retry_and_reopen_never_reread_removed_skill_bodies() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let path = skill(&f, "one", "RETAINED BODY");
    std::fs::write(f.root.join("AGENTS.md"), "OLD INSTRUCTION").unwrap();
    let (record, actor) = f.pending();
    let catalog = actor.discover_project_skills().await.unwrap();
    let chips = vec![catalog.skills[0].chip("unchanged arguments".into())];
    let item = Submission::new("typed".into(), Lane::FollowUp);
    receipt(&f, &record, &actor, &item, chips.clone(), 1);
    actor
        .submit_identified_with_inputs(item.clone(), selections(&chips))
        .await
        .unwrap();
    let request = Request::accept(&listener).await;
    let retained = user_inputs(&request.body)[0]["content"].clone();
    let retained_prompt = request.body["input"][0].clone();
    assert_eq!(
        retained_prompt["content"],
        format!("Explicit fixture instructions\n\n{}", catalog.instructions)
    );
    assert_eq!(catalog.roots, vec![f.root.clone()]);
    std::fs::remove_file(path).unwrap();
    std::fs::write(f.root.join("AGENTS.md"), "NEW INSTRUCTION").unwrap();
    let active_preview: Value = serde_json::from_str(
        actor
            .prepare_context_with_inputs("", &[], &[])
            .await
            .unwrap()
            .request_json(),
    )
    .unwrap();
    assert_eq!(active_preview["input"][0], retained_prompt);
    actor.stop().unwrap();
    drop(request);
    settled(&actor).await;
    actor.retry().unwrap();
    let retry = Request::accept(&listener).await;
    assert_eq!(user_inputs(&retry.body)[0]["content"], retained);
    assert_eq!(retry.body["input"][0], retained_prompt);
    assert!(retry.body.to_string().contains("OLD INSTRUCTION"));
    actor.stop().unwrap();
    drop(retry);
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    let fresh_catalog = reopened.discover_project_skills().await.unwrap();
    reopened.retry().unwrap();
    let retry = Request::accept(&listener).await;
    assert_eq!(user_inputs(&retry.body)[0]["content"], retained);
    assert_eq!(
        retry.body["input"][0]["content"],
        format!(
            "Explicit fixture instructions\n\n{}",
            fresh_catalog.instructions
        )
    );
    assert_ne!(retry.body["input"][0], retained_prompt);
    assert!(retry.body.to_string().contains("NEW INSTRUCTION"));
    retry.complete("retry complete").await;
    settled(&reopened).await;
    assert_eq!(
        reopened
            .snapshot()
            .messages
            .iter()
            .filter(|row| row.id == item.id)
            .count(),
        1
    );
    std::fs::write(
        f.root.join("AGENTS.md"),
        "NEXT INSTRUCTION /private/literal",
    )
    .unwrap();
    let next_catalog = reopened.discover_project_skills().await.unwrap();
    reopened
        .submit("next /private/input".into(), Lane::FollowUp)
        .unwrap();
    let next = Request::accept(&listener).await;
    assert_eq!(
        next.body["input"][0]["content"],
        format!(
            "Explicit fixture instructions\n\n{}",
            next_catalog.instructions
        )
    );
    assert_eq!(user_inputs(&next.body)[0]["content"], retained);
    assert_ne!(next_catalog.revision, fresh_catalog.revision);
    next.complete("next complete").await;
    settled(&reopened).await;
    reopened.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn image_and_skill_share_ordered_content_and_dependency_freeze_uses_actual_tools() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let loaded = f.authority.load_connections().unwrap();
    let mut draft = loaded.edit(&f.connection).unwrap();
    draft.profile.input = vec!["text".into(), "image".into()];
    f.authority.save_connection(&loaded, &draft).unwrap();
    let path = skill(&f, "one", "IMAGE SKILL");
    let metadata = path.parent().unwrap().join("agents/openai.yaml");
    std::fs::create_dir(metadata.parent().unwrap()).unwrap();
    std::fs::write(
        &metadata,
        "dependencies:\n  tools:\n    - type: builtin\n      value: ls\n",
    )
    .unwrap();
    let (record, actor) = f.pending();
    let catalog = actor.discover_project_skills().await.unwrap();
    assert!(catalog.skills[0].selectable(&catalog.dependencies));
    let chips = vec![catalog.skills[0].chip(String::new())];
    let image = f.root.join("fixture.gif");
    std::fs::write(&image,b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01L\x00;").unwrap();
    let mut item = Submission::new(String::new(), Lane::FollowUp);
    item.attachments
        .push(crate::attachments::AttachmentRecord::inspect(&image).unwrap());
    receipt(&f, &record, &actor, &item, chips.clone(), 1);
    actor
        .submit_identified_with_inputs(item, selections(&chips))
        .await
        .unwrap();
    let request = Request::accept(&listener).await;
    let content = &user_inputs(&request.body)[0]["content"];
    assert_eq!(content[0]["type"], "input_text");
    assert_eq!(content[1]["type"], "input_image");
    assert!(content[0]["text"].as_str().unwrap().contains("IMAGE SKILL"));
    std::fs::write(
        &metadata,
        "dependencies:\n  tools:\n    - type: builtin\n      value: bash\n",
    )
    .unwrap();
    let missing = actor.discover_project_skills().await.unwrap();
    assert!(!missing.skills[0].selectable(&missing.dependencies));
    assert!(
        actor
            .submit_identified_with_inputs(
                Submission::new(String::new(), Lane::FollowUp),
                vec![missing.skills[0].selection(String::new())]
            )
            .await
            .is_err()
    );
    request.complete("done").await;
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
}

struct ResourceGate {
    released: Arc<(Mutex<bool>, std::sync::Condvar)>,
}
impl ResourceGate {
    fn install(actor: &Arc<Controller>) -> (Self, tokio::sync::oneshot::Receiver<()>) {
        let released = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let (send, started) = tokio::sync::oneshot::channel();
        let send = Mutex::new(Some(send));
        let held = released.clone();
        actor.set_resource_barrier_for_test(Some(Arc::new(move || {
            if let Some(send) = send.lock().unwrap().take() {
                let _ = send.send(());
            }
            let (lock, condition) = &*held;
            let mut done = lock.lock().unwrap();
            while !*done {
                done = condition.wait(done).unwrap();
            }
        })));
        (Self { released }, started)
    }
    fn release(&self) {
        let (lock, condition) = &*self.released;
        *lock.lock().unwrap() = true;
        condition.notify_all();
    }
}
impl Drop for ResourceGate {
    fn drop(&mut self) {
        self.release();
    }
}
#[tokio::test]
async fn stopped_or_suspended_fresh_freeze_retains_receipt_and_never_accepts() {
    for suspend in [false, true] {
        let (listener, url) = listener().await;
        let f = Fixture::new(&url);
        skill(&f, "one", "FROZEN");
        let (record, actor) = f.pending();
        let catalog = actor.discover_project_skills().await.unwrap();
        let chips = vec![catalog.skills[0].chip(String::new())];
        let item = Submission::new(String::new(), Lane::FollowUp);
        let intent = receipt(&f, &record, &actor, &item, chips.clone(), 1);
        let (gate, started) = ResourceGate::install(&actor);
        let copy = actor.clone();
        let pending = tokio::spawn(async move {
            copy.submit_identified_with_inputs(item, selections(&chips))
                .await
        });
        timeout(DEADLINE, started).await.unwrap().unwrap();
        let suspension = if suspend {
            Some(actor.suspend_idle_admission().unwrap())
        } else {
            actor.stop().unwrap();
            None
        };
        gate.release();
        assert!(timeout(DEADLINE, pending).await.unwrap().unwrap().is_err());
        drop(suspension);
        assert!(actor.snapshot().pending.is_empty());
        assert!(actor.snapshot().messages.is_empty());
        assert!(
            f.workspace
                .lock()
                .unwrap()
                .snapshot()
                .intents
                .contains_key(&intent.id)
        );
        assert!(
            timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
        actor.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn dropped_catalog_awaiter_keeps_physical_reader_and_writer_owned_until_retirement_joins() {
    let (_listener, url) = listener().await;
    let f = Fixture::new(&url);
    skill(&f, "one", "FROZEN");
    let (record, actor) = f.pending();
    let _ = f.prepare(&record, &actor, "materialize only");
    let (gate, started) = ResourceGate::install(&actor);
    let copy = actor.clone();
    let reader = tokio::spawn(async move { copy.discover_project_skills().await });
    timeout(DEADLINE, started).await.unwrap().unwrap();
    reader.abort();
    let _ = reader.await;
    let copy = actor.clone();
    let mut retirement = tokio::spawn(async move { copy.retire_and_wait().await });
    assert!(
        timeout(Duration::from_millis(30), &mut retirement)
            .await
            .is_err()
    );
    assert!(SessionStore::open(&record.snapshot).is_err());
    gate.release();
    timeout(DEADLINE, retirement)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(SessionStore::open(&record.snapshot).is_ok());
}

#[tokio::test]
async fn steering_task_roots_survive_reopen_compaction_then_new_task_releases_old_carriers() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let loaded = f.authority.load_connections().unwrap();
    let mut config = loaded.edit(&f.connection).unwrap();
    config.profile.context_window = 65536;
    f.authority.save_connection(&loaded, &config).unwrap();
    skill(&f, "one", "ROOT SKILL");
    skill(&f, "two", "STEERING SKILL");
    let (record, actor) = f.pending();
    let catalog = actor.discover_project_skills().await.unwrap();
    let chips = vec![catalog.skills[0].chip(String::new())];
    let item = Submission::new("original task".into(), Lane::FollowUp);
    let root = item.id.clone();
    receipt(&f, &record, &actor, &item, chips.clone(), 1);
    actor
        .submit_identified_with_inputs(item, selections(&chips))
        .await
        .unwrap();
    let request = Request::accept(&listener).await;
    let steering = Submission::new("steer current task".into(), Lane::Steering);
    let steering_id = steering.id.clone();
    actor
        .submit_identified_with_inputs(steering, vec![catalog.skills[1].selection(String::new())])
        .await
        .unwrap();
    request.call("ls", json!({})).await;
    let next = Request::accept(&listener).await;
    let snapshot = actor.snapshot();
    assert_eq!(
        snapshot
            .messages
            .iter()
            .find(|row| row.id == steering_id)
            .unwrap()
            .task_root_id
            .as_deref(),
        Some(root.as_str())
    );
    next.complete(&"Verified current task progress. ".repeat(3000))
        .await;
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
    let actor = f.factory.open_registered(&f.current(&record.id)).unwrap();
    actor.compact(None).unwrap();
    let summary = Request::accept(&listener).await;
    assert_eq!(summary.body["tool_choice"], "none");
    summary
        .complete("Current task facts retained; continue carefully.")
        .await;
    settled(&actor).await;
    let snapshot = actor.snapshot();
    assert_eq!(
        snapshot.compaction.as_ref().unwrap().phase,
        crate::compaction::Phase::Completed
    );
    let context = crate::compaction::active_context(&snapshot.messages).unwrap();
    let ids = context
        .iter()
        .map(|row| row.id.as_str())
        .collect::<Vec<_>>();
    assert!(
        ids.iter().position(|id| *id == root).unwrap()
            < ids.iter().position(|id| *id == steering_id).unwrap()
    );
    actor
        .submit("new unselected task".into(), Lane::FollowUp)
        .unwrap();
    let next = Request::accept(&listener).await;
    next.complete(&"Verified new task progress. ".repeat(3500))
        .await;
    settled(&actor).await;
    assert!(
        crate::compaction::protected_input_ids(&actor.snapshot().messages)
            .unwrap()
            .is_empty()
    );
    actor.compact(None).unwrap();
    Request::accept(&listener)
        .await
        .complete("New task checkpoint without old skill authorization.")
        .await;
    settled(&actor).await;
    let snapshot = actor.snapshot();
    assert_eq!(
        snapshot.compaction.as_ref().unwrap().phase,
        crate::compaction::Phase::Completed
    );
    let checkpoint = snapshot
        .messages
        .iter()
        .rev()
        .find_map(|row| row.compaction.as_ref())
        .unwrap();
    assert!(checkpoint.protected_ids.is_empty());
    let context = crate::compaction::active_context(&snapshot.messages).unwrap();
    assert!(
        !context
            .iter()
            .any(|row| row.id == root || row.id == steering_id)
    );
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn mcp_presence_scope_is_rechecked_at_acceptance_delivery_and_settled_steering_commit() {
    for phase in ["acceptance", "delivery", "steering"] {
        let (listener, url) = listener().await;
        let f = Fixture::new(&url);
        let project = f.authority.load().unwrap().projects()[0].clone();
        let config = json!({"servers":{"docs":{"url":format!("{url}/mcp"),"enabled":true}}});
        let loaded = f.authority.load_mcp(&project).unwrap();
        f.authority
            .save_mcp(
                &loaded,
                &config.to_string(),
                &std::collections::BTreeMap::new(),
            )
            .unwrap();
        let path = skill(&f, "one", "DEPENDENCY BODY");
        let metadata = path.parent().unwrap().join("agents/openai.yaml");
        std::fs::create_dir_all(metadata.parent().unwrap()).unwrap();
        std::fs::write(
            metadata,
            "dependencies:\n  tools:\n    - type: mcp\n      value: docs\n",
        )
        .unwrap();
        let (record, actor) = f.pending();
        let catalog = actor.discover_project_skills().await.unwrap();
        assert!(catalog.skills[0].selectable(&catalog.dependencies));
        let chips = vec![catalog.skills[0].chip(String::new())];
        let first = if phase == "steering" {
            let item = f.prepare(&record, &actor, "tool boundary");
            actor.submit_identified(item).unwrap();
            Some(Request::accept(&listener).await)
        } else {
            None
        };
        let lane = if phase == "steering" {
            Lane::Steering
        } else {
            Lane::FollowUp
        };
        let item = Submission::new(String::new(), lane);
        let id = item.id.clone();
        if phase != "steering" {
            receipt(&f, &record, &actor, &item, chips.clone(), 1);
        }
        let gate = actor.set_input_commit_gate_for_test(phase);
        let copy = actor.clone();
        let mut submitted = Some(tokio::spawn(async move {
            copy.submit_identified_with_inputs(item, selections(&chips))
                .await
        }));
        if let Some(first) = first {
            timeout(DEADLINE, submitted.take().unwrap())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            first.call("ls", json!({})).await;
        }
        timeout(DEADLINE, gate.entered.notified()).await.unwrap();
        let manager = f.factory.mcp_manager().unwrap();
        let change = manager.begin_configuration_change().unwrap();
        let old = f.authority.load_mcp(&project).unwrap();
        let disabled = json!({"servers":{"docs":{"url":format!("{url}/mcp"),"enabled":false}}});
        let next = f
            .authority
            .save_mcp(
                &old,
                &disabled.to_string(),
                &std::collections::BTreeMap::new(),
            )
            .unwrap();
        change
            .apply_configuration(next, tokio_util::sync::CancellationToken::new())
            .await
            .unwrap();
        gate.released.notify_one();
        let accepted = if let Some(submitted) = submitted {
            timeout(DEADLINE, submitted).await.unwrap().unwrap()
        } else {
            Ok(())
        };
        if phase == "acceptance" {
            assert!(accepted.is_err());
            assert!(actor.snapshot().pending.is_empty());
        } else {
            accepted.unwrap();
            settled(&actor).await;
            assert!(actor.snapshot().queue_paused);
            assert!(actor.snapshot().pending.iter().any(|item| item.id == id));
        }
        assert!(!actor.snapshot().messages.iter().any(|row| row.id == id));
        if phase == "steering" {
            assert!(
                actor
                    .snapshot()
                    .messages
                    .iter()
                    .any(|row| row.role == "toolResult")
            );
        }
        assert!(
            timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
        actor.retire_and_wait().await.unwrap();
    }
}
