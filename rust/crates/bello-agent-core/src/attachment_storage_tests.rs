//! Metadata and retained bytes share the session transaction and recovery proof.
use super::*;
use crate::{attachments::AttachmentRecord, tool_content::ContentBlock, user_content::UserContent};
use std::sync::Arc;
fn input() -> Submission {
    let mut item = Submission::new(String::new(), Lane::FollowUp);
    item.attachments = vec![AttachmentRecord {
        id: Uuid::new_v4().to_string(),
        path: "/deleted/fixture.gif".into(),
        sha256: "a".repeat(64),
        bytes: 3,
        mime_type: "image/gif".into(),
    }];
    item
}
fn prepared(item: &Submission) -> PreparedUserInput {
    PreparedUserInput {
        item: item.clone(),
        content: Arc::new(
            UserContent::new(
                &item.text,
                item.attachments.clone(),
                vec![ContentBlock::Image {
                    data: "YWJj".into(),
                    mime_type: "image/gif".into(),
                }],
            )
            .unwrap(),
        ),
    }
}
#[test]
fn user_delivery_checkpoint_has_exactly_one_recovery_owner_at_rename_failures() {
    for (fault, delivered) in [
        (WriteFault::BeforeRename, false),
        (WriteFault::AfterRename, true),
    ] {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        let item = input();
        store.transact(|s| s.submit(item.clone())).unwrap();
        let before = fs::read(&path).unwrap();
        store.fault = fault;
        assert!(
            store
                .transact(|s| s.start_next_with_content(Some(prepared(&item))))
                .is_err()
        );
        assert_eq!(store.snapshot().pending.len(), 1);
        assert!(store.snapshot().messages.is_empty());
        if delivered {
            assert!(store.uncertain);
            store.fault = WriteFault::None;
            assert!(store.transact(|_| Ok(())).is_err());
        } else {
            assert_eq!(fs::read(&path).unwrap(), before);
        }
        drop(store);
        let reopened = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(reopened.version, if delivered { 8 } else { 7 });
        assert_eq!(
            reopened.pending.iter().filter(|s| s.id == item.id).count(),
            usize::from(!delivered)
        );
        assert_eq!(
            reopened.messages.iter().filter(|m| m.id == item.id).count(),
            usize::from(delivered)
        );
        if delivered {
            assert_eq!(
                reopened.retry.as_ref().unwrap().attachments,
                item.attachments
            );
            assert_eq!(
                reopened
                    .messages
                    .iter()
                    .find(|m| m.id == item.id)
                    .unwrap()
                    .user_content
                    .as_ref()
                    .unwrap()
                    .image_count(),
                1
            );
        }
    }
}
#[test]
fn unprepared_or_mismatched_delivery_cannot_remove_pending_metadata() {
    let mut s = Session::new();
    let item = input();
    s.submit(item.clone()).unwrap();
    assert!(s.start_next().is_err());
    assert_eq!(s.pending.len(), 1);
    let mut wrong = prepared(&item);
    wrong.item.attachments[0].id = Uuid::new_v4().to_string();
    assert!(s.start_next_with_content(Some(wrong)).is_err());
    assert_eq!(s.pending.len(), 1);
    assert!(s.messages.is_empty());
}
#[test]
fn retained_user_payload_wrong_version_role_base64_or_metadata_is_never_rewritten() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("session.json");
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
    for mutation in 0..5 {
        let mut value = valid.clone();
        match mutation {
            0 => value["version"] = serde_json::json!(6),
            1 => value["messages"][0]["role"] = serde_json::json!("assistant"),
            2 => {
                value["messages"][0]["user_content"]["blocks"][0]["data"] =
                    serde_json::json!("A===")
            }
            3 => {
                value["messages"][0]["user_content"]["attachments"][0]["bytes"] =
                    serde_json::json!(0)
            }
            _ => value["active"]["attachments"][0]["sha256"] = serde_json::json!("b".repeat(64)),
        };
        let bytes = serde_json::to_vec(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err(), "mutation {mutation}");
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}
#[test]
fn insufficient_snapshot_capacity_retains_metadata_and_does_not_publish_bytes() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let item = input();
    store.transact(|s| s.submit(item.clone())).unwrap();
    let before = fs::read(&path).unwrap();
    store.snapshot_limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 1024;
    let mut prepared = prepared(&item);
    Arc::make_mut(&mut prepared.content).blocks[0] = ContentBlock::Image {
        data: "AAAA".repeat(65536),
        mime_type: "image/gif".into(),
    };
    assert!(
        store
            .transact(|s| s.start_next_with_content(Some(prepared)))
            .is_err()
    );
    assert_eq!(fs::read(&path).unwrap(), before);
    assert_eq!(store.snapshot().pending.len(), 1);
    assert!(store.snapshot().messages.is_empty());
}
