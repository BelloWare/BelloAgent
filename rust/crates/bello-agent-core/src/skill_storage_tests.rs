use super::*;
use crate::{
    skills::{FrozenSkill, SkillPolicy},
    user_content::UserContent,
};
use std::sync::Arc;
fn skill(name: &str) -> FrozenSkill {
    let path = format!("/generated/{name}/SKILL.md");
    FrozenSkill {
        id: crate::skills::hash(&path),
        name: name.into(),
        path,
        base_dir: format!("/generated/{name}"),
        body: "frozen source body".into(),
        body_hash: crate::skills::hash("frozen source body"),
        content_hash: crate::skills::hash("full source"),
        metadata_hash: crate::skills::hash("metadata"),
        arguments: "literal arguments".into(),
        description: Some("Generated skill fixture".into()),
        scope: Some("project".into()),
        policy: Some(SkillPolicy::ExplicitOnly),
    }
}
fn input() -> Submission {
    let mut item = Submission::new(String::new(), Lane::FollowUp);
    item.frozen_skills = vec![skill("one"), skill("two")];
    item
}
fn prepared(item: &Submission) -> PreparedUserInput {
    PreparedUserInput {
        item: item.clone(),
        content: Arc::new(UserContent::from_submission(item, Vec::new()).unwrap()),
    }
}
#[test]
fn frozen_delivery_rename_faults_keep_exactly_one_recoverable_owner() {
    for (fault, delivered) in [
        (WriteFault::BeforeRename, false),
        (WriteFault::AfterRename, true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        let item = input();
        store.transact(|s| s.submit(item.clone())).unwrap();
        assert_eq!(store.snapshot().version, 8);
        let before = fs::read(&path).unwrap();
        store.fault = fault;
        assert!(
            store
                .transact(|s| s.start_next_with_content(Some(prepared(&item))))
                .is_err()
        );
        if !delivered {
            assert_eq!(fs::read(&path).unwrap(), before);
        } else {
            assert!(store.uncertain);
        }
        drop(store);
        let reopened = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(
            reopened.pending.iter().filter(|v| v.id == item.id).count(),
            usize::from(!delivered)
        );
        assert_eq!(
            reopened.messages.iter().filter(|v| v.id == item.id).count(),
            usize::from(delivered)
        );
        let retained = if delivered {
            reopened.retry.as_ref().unwrap()
        } else {
            &reopened.pending[0]
        };
        assert_eq!(retained.frozen_skills, item.frozen_skills);
    }
}
#[test]
fn corrupt_skill_versions_hashes_expansions_and_foreign_roots_preserve_original_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let item = input();
    store
        .transact(|s| {
            s.submit(item.clone())?;
            s.start_next_with_content(Some(prepared(&item)))?;
            Ok(())
        })
        .unwrap();
    let valid = serde_json::to_value(store.snapshot()).unwrap();
    drop(store);
    for mutation in 0..7 {
        let mut value = valid.clone();
        match mutation {
            0 => value["version"] = 7.into(),
            1 => value["active"]["frozen_skills"][0]["body"] = "replaced body".into(),
            2 => {
                value["messages"][0]["user_content"]["blocks"][0]["text"] =
                    "replaced expansion".into()
            }
            3 => value["messages"][0]["task_root_id"] = "foreign-root".into(),
            4 => {
                value["messages"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("task_root_id");
            }
            5 => value["active"]["frozen_skills"][0]["arguments"] = "replaced arguments".into(),
            _ => {
                value["messages"][0]["user_content"]["skills"][0]["selection"]["contentHash"] =
                    "bad".into()
            }
        };
        let bytes = serde_json::to_vec(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err(), "mutation {mutation}");
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}
#[test]
fn old_empty_new_fields_fail_without_rewrite_and_clean_legacy_opens_byte_preservingly() {
    for version in 2..=7 {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut model = Session::new();
        model.version = version;
        let value = serde_json::to_value(model).unwrap();
        let bytes = serde_json::to_vec(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        let store = SessionStore::open(&path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        drop(store);
        let mut value = value.clone();
        value["pending"] = serde_json::json!([{"id":"generated","text":"text","lane":"follow-up","model":null,"effort":null,"frozen_skills":[]}]);
        let bytes = serde_json::to_vec(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}
#[test]
fn exact_preparation_includes_skill_order_arguments_body_and_metadata() {
    let item = input();
    for change in 0..4 {
        let mut altered = item.clone();
        match change {
            0 => altered.frozen_skills.reverse(),
            1 => altered.frozen_skills[0].arguments.push('x'),
            2 => altered.frozen_skills[0].metadata_hash = "b".repeat(64),
            _ => altered.frozen_skills[0].content_hash = "b".repeat(64),
        };
        assert!(!same_submission(&item, &altered));
        assert!(checked_prepared(&altered, Some(prepared(&item))).is_err());
    }
    let mut session = Session::new();
    session.submit(item.clone()).unwrap();
    assert!(session.start_next().is_err());
    assert_eq!(session.pending.len(), 1);
}
#[test]
fn skill_envelope_uses_exact_32mib_escaping_budget_and_accepts_ordinary_max_image_combination() {
    use crate::tool_content::{ContentBlock, MAX_IMAGE_BASE64_BYTES};
    let mut item = input();
    item.frozen_skills = (0..8)
        .map(|i| {
            let mut skill = skill(&format!("skill{i}"));
            skill.body = "x".repeat(262_000);
            skill.body_hash = crate::skills::hash(&skill.body);
            skill.arguments = "a".repeat(16_384);
            skill
        })
        .collect();
    item.text = "t".repeat(262_144);
    item.attachments = (0..4)
        .map(|_| crate::attachments::AttachmentRecord {
            id: Uuid::new_v4().to_string(),
            path: "/fixture.png".into(),
            sha256: "a".repeat(64),
            bytes: 3,
            mime_type: "image/png".into(),
        })
        .collect();
    let image = ContentBlock::Image {
        mime_type: "image/png".into(),
        data: "AAAA".repeat(MAX_IMAGE_BASE64_BYTES / 4 - 1),
    };
    let content = UserContent::from_submission(&item, vec![image; 4]).unwrap();
    assert!(
        serde_json::to_vec(&content).unwrap().len() > crate::user_content::MAX_USER_CONTENT_BYTES
    );
    let mut budget = UserContent {
        attachments: Vec::new(),
        skills: vec![skill("budget").recorded()],
        blocks: vec![ContentBlock::Text {
            text: String::new(),
        }],
    };
    let remaining = crate::user_content::MAX_SKILL_USER_CONTENT_BYTES
        - serde_json::to_vec(&budget).unwrap().len();
    budget.blocks[0] = ContentBlock::Text {
        text: "\0".repeat(remaining / 6) + &"a".repeat(remaining % 6),
    };
    assert_eq!(
        serde_json::to_vec(&budget).unwrap().len(),
        crate::user_content::MAX_SKILL_USER_CONTENT_BYTES
    );
    budget.validate().unwrap();
    if let ContentBlock::Text { text } = &mut budget.blocks[0] {
        text.push('a');
    }
    assert!(
        budget
            .validate()
            .unwrap_err()
            .to_string()
            .contains("32 MiB")
    );
}

fn delivered(session: &mut Session, item: Submission) {
    session.submit(item.clone()).unwrap();
    session
        .start_next_with_content(Some(prepared(&item)))
        .unwrap();
    let reply = session.active_reply.clone().unwrap();
    session
        .finish(
            &reply,
            Ok(crate::Reply {
                text: "answer".into(),
                reasoning: String::new(),
                usage: Value::Null,
                status: "completed".into(),
                calls: Vec::new(),
                provider_items: Vec::new(),
            }),
        )
        .unwrap();
}
#[test]
fn compaction_protects_answered_latest_and_current_task_but_not_older_task_forever() {
    let mut session = Session::new();
    session.version = 8;
    let first = input();
    let first_id = first.id.clone();
    delivered(&mut session, first);
    assert_eq!(
        crate::compaction::protected_input_ids(&session.messages).unwrap(),
        std::collections::BTreeSet::from([first_id.clone()])
    );
    let mut steering = input();
    steering.id = "steering-carrier".into();
    let second_id = steering.id.clone();
    delivered(&mut session, steering);
    session
        .messages
        .iter_mut()
        .find(|row| row.id == second_id)
        .unwrap()
        .task_root_id = Some(first_id.clone());
    let mut plain = Message::new(
        "plain-steering".into(),
        "user",
        "new instructions".into(),
        true,
        "complete",
        None,
    );
    plain.task_root_id = Some(first_id.clone());
    session.messages.push(plain);
    session.messages.push(Message::new(
        "answered-steering".into(),
        "assistant",
        "done".into(),
        true,
        "completed",
        None,
    ));
    let expected = std::collections::BTreeSet::from([first_id.clone(), second_id.clone()]);
    assert_eq!(
        crate::compaction::protected_input_ids(&session.messages).unwrap(),
        expected
    );
    let mut next = Message::new(
        "new-task".into(),
        "user",
        "unselected new task".into(),
        true,
        "complete",
        None,
    );
    next.task_root_id = Some(next.id.clone());
    session.messages.push(next);
    session.messages.push(Message::new(
        "new-answer".into(),
        "assistant",
        "done".into(),
        true,
        "completed",
        None,
    ));
    assert!(
        crate::compaction::protected_input_ids(&session.messages)
            .unwrap()
            .is_empty()
    );
    session.validate_task_roots().unwrap();
}

#[test]
fn missing_later_root_or_return_to_old_task_is_rejected_before_rewrite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let mut model = Session::new();
    model.version = 8;
    let one = input();
    let old = one.id.clone();
    delivered(&mut model, one);
    let next = input();
    let next_id = next.id.clone();
    delivered(&mut model, next);
    let mut steering = Message::new(
        "later-steering".into(),
        "user",
        "latest instructions".into(),
        true,
        "complete",
        None,
    );
    steering.task_root_id = Some(next_id);
    model.messages.push(steering);
    model.validate_task_roots().unwrap();
    let valid = serde_json::to_value(&model).unwrap();
    let index = model.messages.len() - 1;
    for foreign in [false, true] {
        let mut value = valid.clone();
        if foreign {
            value["messages"][index]["task_root_id"] = old.clone().into();
        } else {
            value["messages"][index]
                .as_object_mut()
                .unwrap()
                .remove("task_root_id");
        }
        let bytes = serde_json::to_vec(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        let parsed: Session = serde_json::from_slice(&bytes).unwrap();
        assert!(crate::compaction::protected_input_ids(&parsed.messages).is_err());
    }
}
