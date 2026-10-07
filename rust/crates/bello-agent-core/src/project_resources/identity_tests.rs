use super::*;
use crate::{
    Controller, Lane, SessionStore, Submission, session::PreparedUserInput,
    user_content::UserContent, workspace::SubmissionIntent,
};
use std::{os::unix::fs::symlink, sync::Arc};

const ORIGINAL: &str = "---\nname: review\ndescription: Review fixtures\ndisable-model-invocation: true\n---\nOLD BODY";

struct Fixture {
    _temp: tempfile::TempDir,
    source: ProjectResourceSource,
    file: PathBuf,
    alias: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(temp.path()).unwrap();
        fs::write(root.join(".git"), "fixture boundary").unwrap();
        let file = root.join(".agents/skills/review/SKILL.md");
        fs::create_dir_all(file.parent().unwrap().join("agents")).unwrap();
        fs::write(&file, ORIGINAL).unwrap();
        fs::write(
            file.parent().unwrap().join("agents/openai.yaml"),
            "dependencies:\n  tools:\n    - type: builtin\n      value: ls\n",
        )
        .unwrap();
        let alias = root.join("source-spelling/SKILL.md");
        fs::create_dir(alias.parent().unwrap()).unwrap();
        symlink(&file, &alias).unwrap();
        let source = ProjectResourceSource::new(
            ResourceScope {
                project_id: "project".into(),
                roots: vec![root],
                chat_id: "chat".into(),
                controller_id: "controller".into(),
                connection_generation: 1,
                configuration_generation: 1,
                tool_mode: "read-only".into(),
                policy_revision: "project-picker-v1".into(),
                mcp_configuration_revision: "none".into(),
            },
            DependencySnapshot::new(vec!["ls".into()], vec![], "none").unwrap(),
        )
        .unwrap();
        Self {
            _temp: temp,
            source,
            file,
            alias,
        }
    }
    fn legacy(&self) -> (FrozenSkill, skills::SkillChip) {
        let snapshot = self.source.discover(&CancellationToken::new()).unwrap();
        let mut descriptor = snapshot.skills[0].clone();
        descriptor.path = self.file.to_str().unwrap().into();
        descriptor.id = skills::hash(&descriptor.path);
        descriptor.base_dir = self.file.parent().unwrap().to_str().unwrap().into();
        let chip = descriptor.chip("literal arguments".into());
        let mut frozen = snapshot
            .freeze(&[snapshot.skills[0].selection(chip.selection.arguments.clone())])
            .unwrap()
            .remove(0);
        frozen.id = descriptor.id;
        frozen.path = descriptor.path;
        frozen.base_dir = descriptor.base_dir;
        frozen.validate().unwrap();
        (frozen, chip)
    }
    fn current(&self) -> ProjectResourceSnapshot {
        let mut snapshot = self.source.discover(&CancellationToken::new()).unwrap();
        if let Some(descriptor) = snapshot.skills.first_mut() {
            // Portable simulation of Foundation's distinct source spelling.
            // Both paths are real and must still name exactly the same target.
            // No production resolver or global test override is replaced.
            assert_eq!(
                fs::canonicalize(&self.alias).unwrap(),
                fs::canonicalize(&self.file).unwrap()
            );
            let canonical = snapshot.canonical_paths.remove(&descriptor.id).unwrap();
            let body = snapshot.bodies.remove(&descriptor.id).unwrap();
            descriptor.path = self.alias.to_str().unwrap().into();
            descriptor.id = skills::hash(&descriptor.path);
            descriptor.base_dir = self.alias.parent().unwrap().to_str().unwrap().into();
            snapshot
                .canonical_paths
                .insert(descriptor.id.clone(), canonical);
            snapshot.bodies.insert(descriptor.id.clone(), body);
        }
        snapshot
    }
}

#[test]
fn legacy_delivery_keeps_queued_bytes_and_receipts_while_fresh_selection_stays_strict() {
    let f = Fixture::new();
    let (legacy, chip) = f.legacy();
    // Prove stale ID rejection independently of a body/content-hash change.
    assert!(
        f.current()
            .freeze(std::slice::from_ref(&chip.selection))
            .is_err()
    );
    let mut item = Submission::new("retained raw text".into(), Lane::FollowUp);
    item.frozen_skills = vec![legacy];
    let before = serde_json::to_vec(&item).unwrap();
    let expected_content = UserContent::from_submission(&item, vec![]).unwrap();
    fs::write(&f.file, ORIGINAL.replace("OLD BODY", "NEW BODY")).unwrap();
    let current = f.current();
    assert_ne!(current.skills[0].id, chip.selection.id);
    assert!(
        current
            .freeze(std::slice::from_ref(&chip.selection))
            .is_err()
    );
    current.validate_delivery(&item.frozen_skills).unwrap();
    assert_eq!(serde_json::to_vec(&item).unwrap(), before);
    assert!(
        skills::user_message_text(&item.text, &item.frozen_skills, &item.id)
            .unwrap()
            .contains("OLD BODY")
    );
    let path = f._temp.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let intent = SubmissionIntent {
        skills: vec![chip],
        attachments: vec![],
        id: item.id.clone(),
        chat_id: store.snapshot().id,
        text: item.text.clone(),
        lane: item.lane.clone(),
        draft_revision: 1,
    };
    store
        .transact(|session| session.submit(item.clone()))
        .unwrap();
    drop(store);
    let store = SessionStore::open(&path).unwrap();
    assert_eq!(
        serde_json::to_vec(&store.snapshot().pending[0]).unwrap(),
        before
    );
    let controller = Controller::new(store, None).unwrap();
    assert!(controller.submission_intent_status(&intent).unwrap());
    let mut changed_receipt = intent.clone();
    changed_receipt.skills[0].selection.id = current.skills[0].id.clone();
    changed_receipt.skills[0].path = current.skills[0].path.clone();
    assert!(
        controller
            .submission_intent_status(&changed_receipt)
            .is_err()
    );
    drop(controller);
    let mut store = SessionStore::open(&path).unwrap();
    current
        .validate_delivery(&store.snapshot().pending[0].frozen_skills)
        .unwrap();
    store
        .transact(|session| {
            session.start_next_with_content(Some(PreparedUserInput {
                item: item.clone(),
                content: Arc::new(expected_content.clone()),
            }))
        })
        .unwrap();
    assert_eq!(
        store.snapshot().messages[0].user_content.as_deref(),
        Some(&expected_content)
    );
    drop(store);
    // Reopen interruption recovery and historical Retry never consult sources.
    fs::remove_file(&f.file).unwrap();
    let store = SessionStore::open(&path).unwrap();
    assert_eq!(
        store.snapshot().retry.as_ref().unwrap().frozen_skills,
        item.frozen_skills
    );
    assert_eq!(
        store.snapshot().messages[0].user_content.as_deref(),
        Some(&expected_content)
    );
    let controller = Controller::new(store, None).unwrap();
    assert!(controller.submission_intent_status(&intent).unwrap());
    assert!(
        controller
            .submission_intent_status(&changed_receipt)
            .is_err()
    );
    drop(controller);
    let mut store = SessionStore::open(&path).unwrap();
    let retried = store.transact(|session| session.retry_turn()).unwrap();
    assert_eq!(serde_json::to_vec(&retried).unwrap(), before);
    assert_eq!(
        store
            .snapshot()
            .messages
            .iter()
            .filter(|row| row.id == item.id)
            .count(),
        1
    );
    assert_eq!(
        store.snapshot().messages[0].user_content.as_deref(),
        Some(&expected_content)
    );
}

#[test]
fn legacy_delivery_rechecks_metadata_policy_dependencies_deletion_and_filesystem_scope() {
    let f = Fixture::new();
    let (legacy, _) = f.legacy();
    f.current()
        .validate_delivery(std::slice::from_ref(&legacy))
        .unwrap();
    fs::write(
        &f.file,
        ORIGINAL.replace("Review fixtures", "Changed metadata"),
    )
    .unwrap();
    assert!(
        f.current()
            .validate_delivery(std::slice::from_ref(&legacy))
            .is_err()
    );
    fs::write(&f.file, ORIGINAL).unwrap();
    let mut revoked = f.current();
    revoked.skills[0].policy = SkillPolicy::Disabled;
    assert!(
        revoked
            .validate_delivery(std::slice::from_ref(&legacy))
            .is_err()
    );
    let mut missing = f.current();
    missing.dependencies = DependencySnapshot::new(vec![], vec![], "none").unwrap();
    assert!(
        missing
            .validate_delivery(std::slice::from_ref(&legacy))
            .is_err()
    );
    // A different discovered filesystem scope cannot inherit this lookup.
    // Controller generation/admission scope is covered by runtime regressions.
    let other = Fixture::new();
    assert!(
        other
            .current()
            .validate_delivery(std::slice::from_ref(&legacy))
            .is_err()
    );
    fs::remove_file(&f.file).unwrap();
    assert!(f.current().validate_delivery(&[legacy]).is_err());
}

#[test]
fn legacy_delivery_requires_exact_canonical_path_and_unique_current_target() {
    let f = Fixture::new();
    let (legacy, _) = f.legacy();
    let current = f.current();
    let fresh = current
        .freeze(&[current.skills[0].selection(String::new())])
        .unwrap()
        .remove(0);
    assert!(current.validate_delivery(&[legacy.clone(), fresh]).is_err());
    let mut ambiguous = current.clone();
    ambiguous.skills.push(ambiguous.skills[0].clone());
    assert!(
        ambiguous
            .validate_delivery(std::slice::from_ref(&legacy))
            .is_err()
    );
    let mut forged = legacy.clone();
    forged.path = f
        .file
        .parent()
        .unwrap()
        .join("./SKILL.md")
        .to_str()
        .unwrap()
        .into();
    forged.id = skills::hash(&forged.path);
    forged.validate().unwrap();
    assert_eq!(fs::canonicalize(&forged.path).unwrap(), f.file);
    assert!(current.validate_delivery(&[forged]).is_err());
    // Canonical path reuse as a symlink to another current target is a revoke,
    // even with identical body and metadata. No old-path re-resolution fallback.
    let moved = f._temp.path().join("replacement/SKILL.md");
    fs::create_dir_all(moved.parent().unwrap().join("agents")).unwrap();
    fs::write(&moved, ORIGINAL).unwrap();
    fs::copy(
        f.file.parent().unwrap().join("agents/openai.yaml"),
        moved.parent().unwrap().join("agents/openai.yaml"),
    )
    .unwrap();
    fs::remove_file(&f.file).unwrap();
    symlink(&moved, &f.file).unwrap();
    assert!(f.current().validate_delivery(&[legacy]).is_err());
}

#[test]
fn source_spelling_must_resolve_to_the_scanned_target() {
    let f = Fixture::new();
    assert!(source_path::existing(&f.alias, &f.file).is_ok());
    let other = f._temp.path().join("other.md");
    fs::write(&other, ORIGINAL).unwrap();
    fs::remove_file(&f.alias).unwrap();
    symlink(&other, &f.alias).unwrap();
    assert!(source_path::existing(&f.alias, &f.file).is_err());
    assert!(source_path::existing(&f.file, &fs::canonicalize(&other).unwrap()).is_err());
}
