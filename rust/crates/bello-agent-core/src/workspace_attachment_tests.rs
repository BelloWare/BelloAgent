use super::*;
use crate::attachments::AttachmentRecord;
fn records(count: usize) -> Vec<AttachmentRecord> {
    (0..count)
        .map(|_| AttachmentRecord {
            id: Uuid::new_v4().to_string(),
            path: "/fixture/image.gif".into(),
            sha256: "a".repeat(64),
            bytes: 3,
            mime_type: "image/gif".into(),
        })
        .collect()
}
fn fixture(d: &Path) -> (WorkspaceStore, ChatRecord, DraftRecord, SubmissionIntent) {
    let mut store = WorkspaceStore::open(d.join("catalog.json"), d).unwrap();
    let chat = ChatRecord::new(
        Uuid::new_v4().to_string(),
        "New chat".into(),
        d.join("chat.json"),
    );
    let draft = DraftRecord {
        skills: Vec::new(),
        revision: 1,
        text: String::new(),
        queued_edit: None,
        attachments: records(1),
    };
    let intent = SubmissionIntent {
        skills: Vec::new(),
        id: Uuid::new_v4().to_string(),
        chat_id: chat.id.clone(),
        text: String::new(),
        lane: Lane::FollowUp,
        draft_revision: 1,
        attachments: draft.attachments.clone(),
    };
    store.register(chat.clone(), draft.clone()).unwrap();
    (store, chat, draft, intent)
}
#[test]
fn image_only_receipt_and_draft_clear_have_one_owner_at_each_rename_boundary() {
    for (fault, committed) in [(Fault::BeforeRename, false), (Fault::AfterRename, true)] {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("catalog.json");
        let (mut store, chat, draft, intent) = fixture(d.path());
        let before = fs::read(&path).unwrap();
        store.fault = fault;
        assert!(store.begin_submission(intent.clone()).is_err());
        assert_eq!(store.snapshot().drafts[&chat.id], draft);
        if !committed {
            assert_eq!(fs::read(&path).unwrap(), before);
        }
        drop(store);
        let restored = WorkspaceStore::open(&path, d.path()).unwrap().snapshot();
        assert_eq!(restored.version, CURRENT_VERSION);
        assert_eq!(restored.intents.contains_key(&intent.id), committed);
        if committed {
            assert!(restored.drafts[&chat.id].is_empty());
            assert_eq!(restored.intents[&intent.id].attachments, intent.attachments);
        } else {
            assert_eq!(restored.drafts[&chat.id].attachments, draft.attachments);
        }
        let value: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(!value.to_string().contains("\"data\":"));
    }
}
#[test]
fn newer_image_draft_and_exact_receipt_identity_cannot_be_erased_or_replaced() {
    let d = tempfile::tempdir().unwrap();
    let (mut store, chat, mut draft, intent) = fixture(d.path());
    draft.revision = 2;
    draft.attachments = records(2);
    store.save_draft(&chat.id, draft.clone()).unwrap();
    store.begin_submission(intent.clone()).unwrap();
    assert_eq!(store.snapshot().drafts[&chat.id], draft);
    let mut changed = intent.clone();
    changed.attachments = records(1);
    assert!(store.begin_submission(changed).is_err());
    assert_eq!(store.snapshot().intents[&intent.id], intent);
    draft.revision = 3;
    draft.attachments = records(8);
    store.save_draft(&chat.id, draft.clone()).unwrap();
    assert_eq!(store.snapshot().drafts[&chat.id].attachments.len(), 8);
    assert!(crate::attachments::validate_selection(&draft.attachments).is_err());
}
#[test]
fn legacy_catalog_is_byte_preserved_and_wrong_version_images_are_rejected() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("catalog.json");
    let (store, chat, _, _) = fixture(d.path());
    let mut value = serde_json::to_value(store.snapshot()).unwrap();
    drop(store);
    value["version"] = serde_json::json!(7);
    let bad = serde_json::to_vec(&value).unwrap();
    fs::write(&path, &bad).unwrap();
    assert!(WorkspaceStore::open(&path, d.path()).is_err());
    assert_eq!(fs::read(&path).unwrap(), bad);
    value["drafts"][&chat.id]
        .as_object_mut()
        .unwrap()
        .remove("attachments");
    let legacy = serde_json::to_vec(&value).unwrap();
    fs::write(&path, &legacy).unwrap();
    let restored = WorkspaceStore::open(&path, d.path()).unwrap();
    assert_eq!(restored.snapshot().version, 7);
    assert!(restored.snapshot().drafts[&chat.id].attachments.is_empty());
    assert_eq!(fs::read(&path).unwrap(), legacy);
}
