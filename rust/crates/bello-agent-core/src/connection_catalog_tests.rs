use super::*;
#[cfg(feature = "synthetic-authority")]
use crate::project_authority::AuthorityProvenance;
use crate::project_authority::VaultStorage;
use serde_json::{Value, json};
use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};

#[derive(Default)]
struct Storage {
    bytes: Mutex<Option<Vec<u8>>>,
    reads: AtomicUsize,
}
impl VaultStorage for Storage {
    fn read(&self) -> AuthorityResult<Option<Vec<u8>>> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        Ok(self.bytes.lock().unwrap().clone())
    }
    fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()> {
        let mut current = self.bytes.lock().unwrap();
        if current.as_deref() != expected {
            return Err(AuthorityError::Conflict);
        }
        *current = Some(replacement.to_vec());
        Ok(())
    }
}
fn setup() -> (ProjectAuthority, Arc<Storage>) {
    let storage = Arc::new(Storage::default());
    let authority = ProjectAuthority::with_test_storage(storage.clone());
    (authority, storage)
}
fn draft(id: usize) -> ConnectionDraft {
    let p: Profile = serde_json::from_value(json!({"id":format!("00000000-0000-4000-8000-{id:012}"),"api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let mut draft = ConnectionDraft::new(p, format!("Fixture {id}"));
    draft.key_input = SYNTHETIC_KEY.into();
    draft.catalog_url = format!("http://127.0.0.1:3333/catalog-{id}");
    draft
}
fn three(authority: &ProjectAuthority) -> LoadedConnections {
    let mut loaded = authority.load_connections().unwrap();
    for n in 1..=3 {
        loaded = authority
            .save_connection(&loaded, &draft(n))
            .unwrap()
            .loaded;
    }
    loaded
}
fn key_reads() -> usize {
    CATALOG_TEST_KEY_READS.with(std::cell::Cell::get)
}
fn reset_key_reads() {
    CATALOG_TEST_KEY_READS.with(|reads| reads.set(0));
}
#[test]
fn catalog_url_is_known_redacted_metadata_and_never_a_runtime_profile_field() {
    let (authority, storage) = setup();
    let mut form = draft(1);
    form.catalog_url = "https://catalog.example/list?access_token=private-catalog-secret".into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &form)
        .unwrap();
    assert!(saved.profile.available);
    assert_eq!(
        saved.profile.catalog_url.as_ref().unwrap().as_str(),
        form.catalog_url
    );
    assert!(!format!("{:?}", saved.profile).contains("private-catalog-secret"));
    let metadata = serde_json::to_value(&saved.profile.profile).unwrap();
    assert!(metadata.get("catalogUrl").is_none());
    assert_eq!(saved.profile.profile.base_url, form.profile.base_url);
    let mut edited = saved.loaded.edit(&form.profile.id).unwrap();
    assert!(!edited.has_changes());
    edited.catalog_url = "https://catalog.example/new".into();
    assert!(edited.has_changes());
    let changed = authority.save_connection(&saved.loaded, &edited).unwrap();
    assert!(!changed.forked);
    assert_eq!(changed.profile.profile.id, form.profile.id);
    let bytes: Value =
        serde_json::from_slice(storage.bytes.lock().unwrap().as_ref().unwrap()).unwrap();
    assert_eq!(
        bytes["profiles"][0]["profile"]["catalogUrl"],
        edited.catalog_url
    );
    let mut invalid = changed.loaded.edit(&form.profile.id).unwrap();
    invalid.catalog_url = "https://private-secret@catalog.example/".into();
    let before = storage.bytes.lock().unwrap().clone();
    assert!(matches!(
        authority.save_connection(&changed.loaded, &invalid),
        Err(AuthorityError::InvalidConnection)
    ));
    assert_eq!(*storage.bytes.lock().unwrap(), before);
    assert!(invalid.has_changes());
}
#[test]
fn invalid_saved_catalog_is_opaque_unavailable_and_unknown_raw_values_survive() {
    let (authority, storage) = setup();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &draft(1))
        .unwrap();
    let mut root: Fields =
        serde_json::from_slice(storage.bytes.lock().unwrap().as_ref().unwrap()).unwrap();
    root.0.insert(
        "future".into(),
        serde_json::value::RawValue::from_string(
            r#"{"huge":123456789012345678901234567890,"escaped":"\u0061"}"#.into(),
        )
        .unwrap(),
    );
    let mut entries: Vec<Fields> = parse(root.0.get("profiles").unwrap()).unwrap();
    let mut record: Fields = field(&entries[0], "profile").unwrap();
    record.0.insert(
        "catalogUrl".into(),
        raw(&"https://private-secret@catalog.example").unwrap(),
    );
    entries[0].0.insert("profile".into(), raw(&record).unwrap());
    root.0.insert("profiles".into(), raw(&entries).unwrap());
    *storage.bytes.lock().unwrap() = Some(serde_json::to_vec(&root).unwrap());
    let current = authority.load_connections().unwrap();
    assert!(!current.profiles()[0].available);
    assert!(current.profiles()[0].catalog_url.is_none());
    assert!(!format!("{:?}", current.profiles()[0]).contains("private-secret"));
    authority.save_connection(&current, &draft(2)).unwrap();
    let output = String::from_utf8(storage.bytes.lock().unwrap().clone().unwrap()).unwrap();
    assert!(output.contains(r#"{"huge":123456789012345678901234567890,"escaped":"\u0061"}"#));
    assert!(output.contains("https://private-secret@catalog.example"));
    assert!(matches!(
        authority.prepare_catalog(
            &saved.loaded,
            &saved.loaded.edit(&draft(1).profile.id).unwrap()
        ),
        Err(AuthorityError::Conflict)
    ));
}
#[test]
fn source_links_are_flat_and_only_touch_catalog_metadata() {
    let (authority, storage) = setup();
    let loaded = three(&authority);
    let ids: Vec<_> = loaded
        .profiles()
        .iter()
        .map(|p| p.profile.id.clone())
        .collect();
    let before: Value =
        serde_json::from_slice(storage.bytes.lock().unwrap().as_ref().unwrap()).unwrap();
    let linked = authority
        .use_catalog_source(&loaded, &ids[0], &ids[1])
        .unwrap();
    let linked = authority
        .use_catalog_source(&linked, &ids[1], &ids[2])
        .unwrap();
    assert_eq!(linked.catalog_sources().get(&ids[0]), Some(&ids[2]));
    assert_eq!(linked.catalog_sources().get(&ids[1]), Some(&ids[2]));
    assert_eq!(linked.catalog_source(&ids[0]).unwrap().profile.id, ids[2]);
    let after: Value =
        serde_json::from_slice(storage.bytes.lock().unwrap().as_ref().unwrap()).unwrap();
    assert_eq!(before["profiles"], after["profiles"]);
    assert_eq!(before["workspaces"], after["workspaces"]);
    assert!(matches!(
        authority.use_catalog_source(&loaded, &ids[0], &ids[2]),
        Err(AuthorityError::Conflict)
    ));
    let own = authority
        .use_catalog_source(&linked, &ids[0], &ids[0])
        .unwrap();
    assert!(!own.catalog_sources().contains_key(&ids[0]));
    assert_eq!(own.catalog_source(&ids[0]).unwrap().profile.id, ids[0]);
    let deleted = authority.delete_connection(&own, &ids[2]).unwrap();
    assert!(deleted.catalog_sources().is_empty());
    assert_eq!(deleted.catalog_source(&ids[1]).unwrap().profile.id, ids[1]);
}
#[test]
fn self_missing_chained_cyclic_nonresponses_and_duplicate_links_are_rejected() {
    let (authority, storage) = setup();
    let loaded = three(&authority);
    let ids: Vec<_> = loaded
        .profiles()
        .iter()
        .map(|p| p.profile.id.clone())
        .collect();
    let baseline: Value =
        serde_json::from_slice(storage.bytes.lock().unwrap().as_ref().unwrap()).unwrap();
    for links in [
        json!({ids[0].clone():ids[0]}),
        json!({ids[0].clone():"missing"}),
        json!({"missing":ids[0]}),
        json!({ids[0].clone():ids[1],ids[1].clone():ids[2]}),
        json!({ids[0].clone():ids[1],ids[1].clone():ids[0]}),
        json!({ids[0].clone():1}),
    ] {
        let mut value = baseline.clone();
        value["catalogSources"] = links;
        *storage.bytes.lock().unwrap() = Some(serde_json::to_vec(&value).unwrap());
        assert!(matches!(
            authority.load_connections(),
            Err(AuthorityError::Corrupt)
        ));
    }
    let mut value = baseline.clone();
    value["catalogSources"] = json!({ids[0].clone():ids[1]});
    value["profiles"][1]["profile"]["api"] = json!("anthropic-messages");
    *storage.bytes.lock().unwrap() = Some(serde_json::to_vec(&value).unwrap());
    assert!(matches!(
        authority.load_connections(),
        Err(AuthorityError::Corrupt)
    ));
    let mut value: Fields =
        serde_json::from_slice(&serde_json::to_vec(&baseline).unwrap()).unwrap();
    value.0.insert(
        "catalogSources".into(),
        serde_json::value::RawValue::from_string(format!(
            r#"{{"{}":"{}","{}":"{}"}}"#,
            ids[0], ids[1], ids[0], ids[2]
        ))
        .unwrap(),
    );
    *storage.bytes.lock().unwrap() = Some(serde_json::to_vec(&value).unwrap());
    assert!(matches!(
        authority.load_connections(),
        Err(AuthorityError::Corrupt)
    ));
}
#[test]
fn own_catalog_edit_detaches_and_model_forks_inherit_only_compatible_lineage() {
    for change in ["model", "url", "key", "headers"] {
        let (authority, _) = setup();
        let initial = authority
            .save_connection(&authority.load_connections().unwrap(), &draft(1))
            .unwrap();
        let id = initial.profile.profile.id.clone();
        let mut form = initial.loaded.edit(&id).unwrap();
        form.profile.model_id = "new-model".into();
        if change == "url" {
            form.profile.base_url = "http://127.0.0.1:3334".into();
        }
        if change == "key" {
            form.key_input = "different-test-key".into();
        }
        if change == "headers" {
            form.headers_input = r#"{"X-Team":"different-test-header"}"#.into();
        }
        let next = authority.save_connection(&initial.loaded, &form).unwrap();
        assert!(next.forked);
        if change == "model" {
            assert_eq!(
                next.loaded.catalog_sources().get(&id),
                Some(&next.profile.profile.id)
            );
            assert_eq!(next.loaded.profiles()[0].profile.model_id, "fixture");
        } else {
            assert!(next.loaded.catalog_sources().is_empty(), "{change}");
        }
    }
    let (authority, _) = setup();
    let loaded = three(&authority);
    let ids: Vec<_> = loaded
        .profiles()
        .iter()
        .map(|p| p.profile.id.clone())
        .collect();
    let linked = authority
        .use_catalog_source(&loaded, &ids[0], &ids[1])
        .unwrap();
    let linked = authority
        .use_catalog_source(&linked, &ids[2], &ids[1])
        .unwrap();
    let mut follower = linked.edit(&ids[0]).unwrap();
    follower.profile.model_id = "changed".into();
    let inherited = authority.save_connection(&linked, &follower).unwrap();
    assert_eq!(
        inherited
            .loaded
            .catalog_sources()
            .get(&inherited.profile.profile.id),
        Some(&ids[1])
    );
    let mut edited = inherited.loaded.edit(&ids[0]).unwrap();
    edited.catalog_url = "https://catalog.example/own".into();
    edited.profile.model_id = "own-model".into();
    let own = authority
        .save_connection(&inherited.loaded, &edited)
        .unwrap();
    assert_eq!(
        own.loaded.catalog_sources().get(&ids[0]),
        Some(&own.profile.profile.id)
    );
    assert_eq!(own.loaded.catalog_sources().get(&ids[2]), Some(&ids[1]));
    let mut detach = own.loaded.edit(&ids[2]).unwrap();
    detach.catalog_url.clear();
    let detached = authority.save_connection(&own.loaded, &detach).unwrap();
    assert!(!detached.forked);
    assert!(!detached.loaded.catalog_sources().contains_key(&ids[2]));
}
#[test]
fn bundled_draft_needs_no_key_or_profile_validation_and_saved_prepare_exact_cas() {
    let (authority, storage) = setup();
    let loaded = authority.load_connections().unwrap();
    let mut form = draft(1);
    form.key_input.clear();
    form.catalog_url.clear();
    form.profile.model_id.clear();
    form.profile.base_url.clear();
    form.headers_input = "partial invalid JSON".into();
    let reads = storage.reads.load(Ordering::SeqCst);
    reset_key_reads();
    assert!(
        authority
            .prepare_catalog(&loaded, &form)
            .unwrap()
            .is_bundled()
    );
    assert_eq!(key_reads(), 0);
    assert_eq!(storage.reads.load(Ordering::SeqCst), reads);
    let mut saved_form = draft(1);
    saved_form.catalog_url.clear();
    let saved = authority.save_connection(&loaded, &saved_form).unwrap();
    let edit = saved.loaded.edit(&saved_form.profile.id).unwrap();
    reset_key_reads();
    let reads = storage.reads.load(Ordering::SeqCst);
    assert!(
        authority
            .prepare_catalog(&saved.loaded, &edit)
            .unwrap()
            .is_bundled()
    );
    assert_eq!(key_reads(), 0);
    assert_eq!(storage.reads.load(Ordering::SeqCst), reads + 1);
    let (foreign, _) = setup();
    assert!(matches!(
        foreign.prepare_catalog(&saved.loaded, &edit),
        Err(AuthorityError::Conflict)
    ));
    storage.bytes.lock().unwrap().as_mut().unwrap().push(b' ');
    assert!(matches!(
        authority.prepare_catalog(&saved.loaded, &edit),
        Err(AuthorityError::Conflict)
    ));
}
#[test]
fn production_remote_preparation_stays_closed_even_for_loopback_and_without_key_reads() {
    let (authority, _) = setup();
    let loaded = authority.load_connections().unwrap();
    let form = draft(1);
    reset_key_reads();
    assert!(matches!(
        authority.prepare_catalog(&loaded, &form),
        Err(AuthorityError::Unavailable)
    ));
    assert_eq!(key_reads(), 0);
}
#[cfg(feature = "synthetic-authority")]
#[test]
fn fixture_external_is_anonymous_same_origin_resolves_only_key_and_inherited_source() {
    let storage = Arc::new(Storage::default());
    let authority = ProjectAuthority {
        storage: Some(storage),
        provenance: AuthorityProvenance::Fixture,
    };
    let loaded = authority.load_connections().unwrap();
    let mut form = draft(1);
    form.catalog_url = "http://127.0.0.1:3334/catalog".into();
    form.key_input = "invalid\nprivate-secret".into();
    form.headers_input = "incomplete JSON private-header".into();
    form.profile.model_id.clear();
    reset_key_reads();
    assert!(
        !authority
            .prepare_catalog(&loaded, &form)
            .unwrap()
            .is_bundled()
    );
    assert_eq!(key_reads(), 0);
    form.catalog_url = "http://127.0.0.1:3333/catalog".into();
    assert!(matches!(
        authority.prepare_catalog(&loaded, &form),
        Err(AuthorityError::InvalidConnection)
    ));
    for prohibited in [
        "http://localhost:3333/catalog",
        "https://example.test/catalog",
    ] {
        form.catalog_url = prohibited.into();
        assert!(matches!(
            authority.prepare_catalog(&loaded, &form),
            Err(AuthorityError::Unavailable)
        ));
    }
    let loaded = three(&authority);
    let ids: Vec<_> = loaded
        .profiles()
        .iter()
        .map(|p| p.profile.id.clone())
        .collect();
    let linked = authority
        .use_catalog_source(&loaded, &ids[0], &ids[1])
        .unwrap();
    let edit = linked.edit(&ids[0]).unwrap();
    reset_key_reads();
    let request = authority.prepare_catalog(&linked, &edit).unwrap();
    assert_eq!(request.source_id(), Some(ids[1].as_str()));
    assert_eq!(key_reads(), 1);
    let mut header_only = edit.clone();
    header_only.headers_input = r#"{"X-Fixture":"synthetic-header-fixture-only"}"#.into();
    reset_key_reads();
    let request = authority.prepare_catalog(&linked, &header_only).unwrap();
    assert_eq!(request.source_id(), Some(ids[1].as_str()));
    assert_eq!(key_reads(), 1);
    let mut own = edit.clone();
    own.catalog_url = "http://127.0.0.1:3334/own".into();
    reset_key_reads();
    let request = authority.prepare_catalog(&linked, &own).unwrap();
    assert_eq!(request.source_id(), Some(ids[0].as_str()));
    assert_eq!(key_reads(), 0);
    own.catalog_url.clear();
    reset_key_reads();
    assert!(
        authority
            .prepare_catalog(&linked, &own)
            .unwrap()
            .is_bundled()
    );
    assert_eq!(key_reads(), 0);
}
