//! These tests never instantiate SecurityApi or call a framework. Even macOS
//! all-features/ignored-test runs stay inside this fake and temporary lock files.
use super::*;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

const EMPTY: &[u8] = br#"{"schema":1,"revision":0,"workspaces":[]}"#;
const ID: &str = "63fe1a77-72de-4b2c-b1e7-e125d65ffb52";

#[derive(Default)]
struct State {
    bytes: Option<Vec<u8>>,
    events: Vec<&'static str>,
    identities: VecDeque<AuthorityResult<()>>,
    read_error: Option<AuthorityError>,
    lock_error: Option<AuthorityError>,
    race: Option<Option<Vec<u8>>>,
    mutation: Option<(MutationOutcome, bool)>,
    writes: usize,
}

#[derive(Clone, Default)]
struct Fake(Arc<Mutex<State>>);

struct Scope {
    state: Arc<Mutex<State>>,
    event: &'static str,
}
impl Drop for Scope {
    fn drop(&mut self) {
        self.state.lock().unwrap().events.push(self.event);
    }
}
impl Fake {
    fn events(&self) -> Vec<&'static str> {
        std::mem::take(&mut self.0.lock().unwrap().events)
    }
    fn mutate(&self, operation: &'static str, bytes: &[u8]) -> MutationOutcome {
        let mut state = self.0.lock().unwrap();
        state.events.push(operation);
        let (outcome, commit) = state
            .mutation
            .take()
            .unwrap_or((MutationOutcome::Confirmed, true));
        if commit {
            state.bytes = Some(bytes.to_vec());
            state.writes += 1;
        }
        outcome
    }
}
impl NativeApi for Fake {
    type Lock = Scope;
    fn pool<T>(&self, operation: impl FnOnce() -> T) -> T {
        self.0.lock().unwrap().events.push("pool");
        let _scope = Scope {
            state: self.0.clone(),
            event: "drain",
        };
        operation()
    }
    fn validate_identity(&self) -> AuthorityResult<()> {
        let mut state = self.0.lock().unwrap();
        state.events.push("identity");
        state.identities.pop_front().unwrap_or(Ok(()))
    }
    fn acquire_lock(&self) -> AuthorityResult<Self::Lock> {
        let mut state = self.0.lock().unwrap();
        state.events.push("lock");
        if let Some(error) = state.lock_error.take() {
            return Err(error);
        }
        if let Some(race) = state.race.take() {
            state.bytes = race;
        }
        Ok(Scope {
            state: self.0.clone(),
            event: "unlock",
        })
    }
    fn copy_matching(&self) -> AuthorityResult<Option<Vec<u8>>> {
        let mut state = self.0.lock().unwrap();
        state.events.push("read");
        if let Some(error) = state.read_error.take() {
            return Err(error);
        }
        Ok(state.bytes.clone())
    }
    fn update(&self, bytes: &[u8]) -> MutationOutcome {
        self.mutate("update", bytes)
    }
    fn add(&self, bytes: &[u8]) -> MutationOutcome {
        self.mutate("add", bytes)
    }
}

fn fixture(bytes: Option<&[u8]>) -> (Arc<NativeStorage<Fake>>, Fake) {
    let fake = Fake::default();
    fake.0.lock().unwrap().bytes = bytes.map(<[u8]>::to_vec);
    (Arc::new(NativeStorage { api: fake.clone() }), fake)
}

#[test]
fn native_feature_never_changes_default_composition() {
    for authority in [ProjectAuthority::new(), ProjectAuthority::default()] {
        assert!(matches!(authority.load(), Err(AuthorityError::Unavailable)));
    }
    #[cfg(not(target_os = "macos"))]
    assert!(matches!(
        ProjectAuthority::with_native_storage(),
        Err(AuthorityError::Unavailable)
    ));
}

#[test]
fn connection_only_native_storage_keeps_normal_credentials_and_authority_without_tools() {
    use crate::{
        project_authority::connections::ConnectionDraft,
        saved_runtime::{SavedChatOptions, SavedRuntimeFactory},
        tools::Capability,
        workspace::{ChatMaterialization, ChatToolMode, DraftRecord, WorkspaceStore},
    };
    let directory = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(directory.path()).unwrap();
    std::fs::write(root.join("AGENTS.md"), "NEVER_INCLUDE_PROJECT_INSTRUCTIONS").unwrap();
    let (storage, fake) = fixture(None);
    let authority = ProjectAuthority::with_test_storage(storage);
    let profile = serde_json::from_value(serde_json::json!({
        "id":uuid::Uuid::new_v4().to_string(), "api":"openai-responses", "providerId":"litellm",
        "baseUrl":"https://gateway.example.test", "modelId":"test-model",
        "contextWindow":32000,"maxOutputTokens":4096
    }))
    .unwrap();
    let mut connection = ConnectionDraft::new(profile, "Fake native connection".into());
    connection.key_input = "ordinary-test-key-never-a-real-secret".into();
    connection.headers_input = r#"{"x-test":"ordinary-test-header"}"#.into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &connection)
        .unwrap();
    let id = saved.profile.profile.id;
    let workspace = Arc::new(Mutex::new(
        WorkspaceStore::open(root.join("state/catalog.json"), &root).unwrap(),
    ));
    let factory = SavedRuntimeFactory::connection_only(authority.clone(), workspace.clone());
    assert!(
        factory.new_chat(&id, ChatToolMode::Editing).is_err(),
        "saving a connection does not grant project trust"
    );
    let mut draft = authority.load().unwrap().edit();
    let project = draft
        .trust_project(&uuid::Uuid::new_v4().to_string(), &root, &[])
        .unwrap();
    let trusted = authority.save(&mut draft).unwrap();
    workspace
        .lock()
        .unwrap()
        .bind_project_identity(
            authority
                .confirm_project_binding(&trusted, &project)
                .unwrap(),
        )
        .unwrap();
    for mode in [ChatToolMode::ReadOnly, ChatToolMode::Editing] {
        let (record, actor) = factory.new_chat(&id, mode).unwrap();
        assert!(actor.configured());
        assert!(!actor.has_available_tool_definitions());
        let request = actor.prepare_context("").unwrap();
        assert!(
            !request
                .request_json()
                .contains("NEVER_INCLUDE_PROJECT_INSTRUCTIONS")
        );
        let request: serde_json::Value = serde_json::from_str(request.request_json()).unwrap();
        assert!(
            request
                .get("tools")
                .is_none_or(|tools| tools.as_array().is_some_and(Vec::is_empty))
        );
        assert!(actor.snapshot().messages.is_empty());
        assert!(!record.snapshot.exists());
        assert!(factory.mcp_manager().is_err());
        assert!(workspace.lock().unwrap().mcp_manager.is_none());
        workspace
            .lock()
            .unwrap()
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        let opened = factory.open_registered(&record).unwrap();
        assert!(opened.configured());
        let mut wrong = record.clone();
        wrong.connection_id = Some(uuid::Uuid::new_v4().to_string());
        assert!(factory.open_registered(&wrong).is_err());
        let mut missing = record;
        missing.materialization = ChatMaterialization::CheckpointRequired;
        assert!(factory.open_registered(&missing).is_err());
    }
    // A manager owned by another explicit composition is not borrowed by the
    // connection-only route, even when both share the workspace object.
    let tool_factory = SavedRuntimeFactory::new(
        authority.clone(),
        workspace.clone(),
        SavedChatOptions {
            home: root,
            read_only_capabilities: vec![Capability::Ls],
            editing_capabilities: vec![Capability::Ls],
            instructions: String::new(),
        },
    );
    let _manager = tool_factory.mcp_manager().unwrap();
    assert!(factory.mcp_manager().is_err());
    let (_, actor) = factory.new_chat(&id, ChatToolMode::Editing).unwrap();
    assert!(!actor.has_available_tool_definitions());
    authority
        .delete_connection(&authority.load_connections().unwrap(), &id)
        .unwrap();
    assert!(factory.preflight(&id).is_err());
    assert!(actor.prepare_context("").is_err());
    assert!(
        actor
            .submit("never dispatch".into(), crate::Lane::FollowUp)
            .is_err()
    );
    assert!(actor.snapshot().messages.is_empty());
    assert!(
        fake.0.lock().unwrap().writes > 0,
        "all storage was the inert fake NativeApi"
    );
}

#[test]
fn connection_only_native_denied_corrupt_and_unconfirmed_state_never_falls_back() {
    use crate::{
        project_authority::connections::ConnectionDraft,
        saved_runtime::SavedRuntimeFactory,
        workspace::{ChatToolMode, WorkspaceStore},
    };
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let (storage, fake) = fixture(None);
    let authority = ProjectAuthority::with_test_storage(storage);
    let workspace = Arc::new(Mutex::new(
        WorkspaceStore::open(root.join("catalog.json"), &root).unwrap(),
    ));
    let mut project_draft = authority.load().unwrap().edit();
    let project = project_draft.trust_project(ID, &root, &[]).unwrap();
    let trusted = authority.save(&mut project_draft).unwrap();
    workspace
        .lock()
        .unwrap()
        .bind_project_identity(
            authority
                .confirm_project_binding(&trusted, &project)
                .unwrap(),
        )
        .unwrap();
    let factory = SavedRuntimeFactory::connection_only(authority.clone(), workspace);
    for error in [AuthorityError::Unsigned, AuthorityError::Denied] {
        fake.0.lock().unwrap().read_error = Some(error);
        assert!(factory.new_chat(ID, ChatToolMode::Editing).is_err());
    }
    fake.0.lock().unwrap().bytes = Some(b"corrupt vault".to_vec());
    assert!(factory.new_chat(ID, ChatToolMode::Editing).is_err());
    assert_eq!(
        fake.0.lock().unwrap().bytes.as_deref(),
        Some(b"corrupt vault".as_slice())
    );
    fake.0.lock().unwrap().bytes = None;
    let profile=serde_json::from_value(serde_json::json!({"id":ID,"api":"openai-responses","providerId":"litellm","baseUrl":"https://gateway.example.test","modelId":"test","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let mut draft = ConnectionDraft::new(profile, "retained draft".into());
    draft.key_input = "fake-production-key".into();
    let baseline = authority.load_connections().unwrap();
    fake.0.lock().unwrap().mutation = Some((MutationOutcome::Unconfirmed, true));
    assert!(matches!(
        authority.save_connection(&baseline, &draft),
        Err(AuthorityError::Unconfirmed)
    ));
    assert_eq!(draft.key_input, "fake-production-key");
    assert!(matches!(
        authority.save_connection(&baseline, &draft),
        Err(AuthorityError::Conflict)
    ));
    assert!(
        factory.new_chat(ID, ChatToolMode::Editing).is_err(),
        "unconfirmed connection save cannot invent project authority"
    );
}

#[test]
fn fixed_native_identity_matches_reviewed_packaging() {
    let identity: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../packaging/macos/native-authority-identity.json"
    ))
    .unwrap();
    assert_eq!(identity["bundle_identifier"], BUNDLE_ID);
    assert_eq!(identity["support_namespace"], BUNDLE_ID);
    assert_eq!(identity["keychain_service"], SERVICE);
    assert_eq!(identity["keychain_account"], ACCOUNT);
    assert_eq!(identity["requirement"], REQUIREMENT);
    assert_eq!(identity["team_identifier"], "43TXHV3TM3");
    assert_eq!(identity["lock_filename"], "configuration.lock");
    assert_ne!(SERVICE, "com.belloware.PiApp.configuration");
}

#[test]
fn every_read_and_replace_checks_identity_before_side_effects() {
    let (storage, fake) = fixture(None);
    assert_eq!(storage.read().unwrap(), None);
    assert_eq!(fake.events(), ["pool", "identity", "read", "drain"]);
    fake.0
        .lock()
        .unwrap()
        .identities
        .push_back(Err(AuthorityError::Unsigned));
    assert_eq!(storage.read(), Err(AuthorityError::Unsigned));
    assert_eq!(fake.events(), ["pool", "identity", "drain"]);
    fake.0
        .lock()
        .unwrap()
        .identities
        .push_back(Err(AuthorityError::Unsigned));
    assert_eq!(storage.replace(None, EMPTY), Err(AuthorityError::Unsigned));
    assert_eq!(fake.events(), ["pool", "identity", "drain"]);
    assert_eq!(fake.0.lock().unwrap().writes, 0);
}

#[test]
fn lock_and_second_identity_failures_stop_before_read_or_write() {
    let (storage, fake) = fixture(None);
    for error in [AuthorityError::Busy, AuthorityError::LockUnavailable] {
        fake.0.lock().unwrap().lock_error = Some(error.clone());
        assert_eq!(storage.replace(None, EMPTY), Err(error));
        assert_eq!(fake.events(), ["pool", "identity", "lock", "drain"]);
    }
    fake.0
        .lock()
        .unwrap()
        .identities
        .extend([Ok(()), Err(AuthorityError::Unsigned)]);
    assert_eq!(storage.replace(None, EMPTY), Err(AuthorityError::Unsigned));
    assert_eq!(
        fake.events(),
        ["pool", "identity", "lock", "identity", "unlock", "drain"]
    );
    assert_eq!(fake.0.lock().unwrap().writes, 0);
}

#[test]
fn denied_corrupt_and_oversized_reads_never_become_missing_items() {
    let (storage, fake) = fixture(None);
    for error in [AuthorityError::Denied, AuthorityError::Corrupt] {
        fake.0.lock().unwrap().read_error = Some(error.clone());
        assert_eq!(storage.replace(None, EMPTY), Err(error));
        assert_eq!(
            fake.events(),
            [
                "pool", "identity", "lock", "identity", "read", "unlock", "drain"
            ]
        );
    }
    fake.0.lock().unwrap().bytes = Some(vec![b' '; MAX_BYTES + 1]);
    assert_eq!(storage.read(), Err(AuthorityError::Corrupt));
    assert_eq!(storage.replace(None, EMPTY), Err(AuthorityError::Corrupt));
    assert_eq!(fake.0.lock().unwrap().writes, 0);
    fake.0.lock().unwrap().bytes = Some(Vec::new());
    assert_eq!(storage.read().unwrap(), Some(Vec::new()));
    assert_eq!(storage.replace(None, EMPTY), Err(AuthorityError::Conflict));
}

#[test]
fn size_limit_is_checked_before_lock_or_mutation_and_accepts_exact_bound() {
    let (storage, fake) = fixture(None);
    let oversized = vec![0; MAX_BYTES + 1];
    for (expected, replacement) in [
        (None, oversized.as_slice()),
        (Some(oversized.as_slice()), EMPTY),
    ] {
        assert_eq!(
            storage.replace(expected, replacement),
            Err(AuthorityError::Corrupt)
        );
        assert_eq!(fake.events(), ["pool", "identity", "drain"]);
    }
    storage.replace(None, &vec![0; MAX_BYTES]).unwrap();
    assert_eq!(storage.read().unwrap().unwrap().len(), MAX_BYTES);
    assert_eq!(fake.0.lock().unwrap().writes, 1);
}

#[test]
fn source_cas_compares_whole_bytes_after_acquiring_lock() {
    let (storage, fake) = fixture(Some(EMPTY));
    let mut raced = EMPTY.to_vec();
    raced.push(b' '); // Same schema, revision, and records; different whole bytes.
    fake.0.lock().unwrap().race = Some(Some(raced.clone()));
    assert_eq!(
        storage.replace(Some(EMPTY), b"replacement"),
        Err(AuthorityError::Conflict)
    );
    assert_eq!(
        fake.events(),
        [
            "pool", "identity", "lock", "identity", "read", "unlock", "drain"
        ]
    );
    assert_eq!(
        fake.0.lock().unwrap().bytes.as_deref(),
        Some(raced.as_slice())
    );
    assert_eq!(fake.0.lock().unwrap().writes, 0);
}

#[test]
fn absent_items_add_once_and_existing_items_update_once_without_fallback() {
    for existing in [false, true] {
        let expected = existing.then_some(EMPTY);
        let (storage, fake) = fixture(expected);
        storage.replace(expected, b"replacement").unwrap();
        assert_eq!(
            fake.events(),
            [
                "pool",
                "identity",
                "lock",
                "identity",
                "read",
                if existing { "update" } else { "add" },
                "unlock",
                "drain"
            ]
        );
        assert_eq!(fake.0.lock().unwrap().writes, 1);
        fake.0.lock().unwrap().mutation = Some((MutationOutcome::Unconfirmed, false));
        assert_eq!(
            storage.replace(Some(b"replacement"), b"next"),
            Err(AuthorityError::Unconfirmed)
        );
        assert_eq!(
            fake.events()
                .iter()
                .filter(|event| **event == "update")
                .count(),
            1
        );
        assert_eq!(fake.0.lock().unwrap().writes, 1);
    }
    let (storage, fake) = fixture(None);
    fake.0.lock().unwrap().mutation = Some((MutationOutcome::Conflict, false));
    assert_eq!(storage.replace(None, EMPTY), Err(AuthorityError::Conflict));
    assert_eq!(
        fake.events(),
        [
            "pool", "identity", "lock", "identity", "read", "add", "unlock", "drain"
        ]
    );
}

#[test]
fn failed_and_possible_commit_saves_preserve_draft_and_baseline() {
    for commit in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (storage, fake) = fixture(None);
        let authority = ProjectAuthority {
            provenance: super::super::AuthorityProvenance::Production,
            storage: Some(storage),
            ..ProjectAuthority::default()
        };
        let mut draft = authority.load().unwrap().edit();
        let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
        fake.0.lock().unwrap().read_error = Some(AuthorityError::Denied);
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Denied)
        ));
        assert_eq!(draft.baseline_revision(), 0);
        assert_eq!(draft.projects().unwrap(), vec![project.clone()]);
        assert_eq!(fake.0.lock().unwrap().writes, 0);
        fake.0.lock().unwrap().mutation = Some((MutationOutcome::Unconfirmed, commit));
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Unconfirmed)
        ));
        assert_eq!(draft.baseline_revision(), 0);
        assert_eq!(draft.projects().unwrap(), vec![project]);
        assert!(draft.has_changes());
        assert_eq!(fake.0.lock().unwrap().writes, usize::from(commit));
        if commit {
            assert!(matches!(
                authority.save(&mut draft),
                Err(AuthorityError::Conflict)
            ));
            assert_eq!(fake.0.lock().unwrap().writes, 1);
            assert_eq!(authority.load().unwrap().revision(), 1);
        }
    }
}

#[test]
fn every_failed_update_and_nonduplicate_add_is_unconfirmed() {
    use status::{
        Mutation::{Add, Update},
        mutation_outcome,
    };
    for operation in [Add, Update] {
        assert_eq!(mutation_outcome(0, operation), MutationOutcome::Confirmed);
        for code in [
            -50, -25291, -25292, -25293, -25294, -25307, -25308, -25315, -36, -34, -108, -2070,
            -128, -99999, 12345,
        ] {
            assert_eq!(
                mutation_outcome(code, operation),
                MutationOutcome::Unconfirmed
            );
        }
    }
    assert_eq!(mutation_outcome(-25299, Add), MutationOutcome::Conflict);
    assert_eq!(
        mutation_outcome(-25300, Update),
        MutationOutcome::Unconfirmed
    );
    assert_eq!(
        mutation_outcome(-25299, Update),
        MutationOutcome::Unconfirmed
    );
    assert_eq!(mutation_outcome(-25300, Add), MutationOutcome::Unconfirmed);
}

#[test]
fn update_that_mutates_before_authentication_failure_retains_uncertainty() {
    let directory = tempfile::tempdir().unwrap();
    let (storage, fake) = fixture(Some(EMPTY));
    let authority = ProjectAuthority {
        provenance: super::super::AuthorityProvenance::Production,
        storage: Some(storage),
        ..ProjectAuthority::default()
    };
    let mut draft = authority.load().unwrap().edit();
    let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
    fake.events();
    // Model the native repair hazard: storage changes before the framework
    // returns errSecAuthFailed. Classification must preserve the host's
    // Unconfirmed fence instead of claiming this was a pre-write denial.
    fake.0.lock().unwrap().mutation = Some((
        status::mutation_outcome(-25293, status::Mutation::Update),
        true,
    ));
    assert!(matches!(
        authority.save(&mut draft),
        Err(AuthorityError::Unconfirmed)
    ));
    assert_eq!(draft.baseline_revision(), 0);
    assert_eq!(draft.projects().unwrap(), vec![project]);
    assert!(draft.has_changes());
    assert_eq!(fake.0.lock().unwrap().writes, 1);
    let events = fake.events();
    assert_eq!(events.iter().filter(|event| **event == "update").count(), 1);
    assert!(!events.contains(&"add"));
    assert!(matches!(
        authority.save(&mut draft),
        Err(AuthorityError::Conflict)
    ));
    assert_eq!(fake.0.lock().unwrap().writes, 1);
    assert_eq!(authority.load().unwrap().revision(), 1);
}
