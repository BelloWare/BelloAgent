//! A bounded Settings connection slice in the existing whole-envelope vault.
//! Unknown fields remain raw; no native composition or credential entry is enabled.
//! Source: ConfigurationVault, WorkspaceConfiguration and SettingsConnectionForm.
use super::{
    AuthorityError, AuthorityResult, Fields, LoadedProjects, ProjectAuthority, parse, raw,
};
use crate::{
    Credential, Profile,
    model_catalog::{CatalogRequest, CatalogUrl},
};
use std::{
    collections::{BTreeMap, HashSet},
    sync::Arc,
};

pub const SYNTHETIC_KEY: &str = "synthetic-project-fixture-only";
pub const SYNTHETIC_HEADER: &str = "synthetic-header-fixture-only";
const MAX_CONNECTIONS: usize = 128;
const PROFILE_FIELDS: &[&str] = &[
    "id",
    "api",
    "providerId",
    "modelId",
    "input",
    "baseUrl",
    "contextWindow",
    "maxOutputTokens",
    "modelOutputLimit",
    "outputCap",
    "reasoning",
    "thinkingLevel",
    "compat",
];

/// Safe list/form metadata. Header values and keys never leave the opaque record.
#[derive(Clone, Debug)]
pub struct SavedConnection {
    pub profile: Profile,
    pub name: String,
    pub revision: String,
    pub available: bool,
    /// Metadata only. Never part of the runtime Profile or provider route.
    pub catalog_url: Option<CatalogUrl>,
}

#[derive(Clone)]
pub struct LoadedConnections {
    authority: ProjectAuthority,
    envelope: LoadedProjects,
    entries: Vec<Fields>,
    profiles: Vec<SavedConnection>,
    catalog_sources: BTreeMap<String, String>,
}
impl LoadedConnections {
    fn decode(authority: &ProjectAuthority, envelope: LoadedProjects) -> AuthorityResult<Self> {
        let entries: Vec<Fields> = envelope
            .fields
            .0
            .get("profiles")
            .map(|v| parse(v))
            .transpose()?
            .unwrap_or_default();
        if entries.len() > MAX_CONNECTIONS {
            return Err(AuthorityError::Corrupt);
        }
        let mut ids = HashSet::new();
        let mut profiles = Vec::with_capacity(entries.len());
        for entry in &entries {
            let metadata = metadata(authority, entry)?;
            if !ids.insert(metadata.profile.id.clone()) {
                return Err(AuthorityError::Corrupt);
            }
            profiles.push(metadata);
        }
        let catalog_sources = decode_catalog_sources(&envelope.fields, &profiles)?;
        Ok(Self {
            catalog_sources,
            authority: authority.clone(),
            envelope,
            entries,
            profiles,
        })
    }
    pub fn revision(&self) -> i64 {
        self.envelope.revision()
    }
    pub fn profiles(&self) -> &[SavedConnection] {
        &self.profiles
    }
    pub fn catalog_sources(&self) -> &BTreeMap<String, String> {
        &self.catalog_sources
    }
    /// Resolves model-list metadata only, never a runtime dispatch profile.
    pub fn catalog_source(&self, id: &str) -> AuthorityResult<&SavedConnection> {
        self.index(id)?;
        let source = self
            .catalog_sources
            .get(id)
            .map(String::as_str)
            .unwrap_or(id);
        Ok(&self.profiles[self.index(source)?])
    }
    pub fn edit(&self, id: &str) -> AuthorityResult<ConnectionDraft> {
        let index = self.index(id)?;
        let saved = &self.profiles[index];
        Ok(ConnectionDraft {
            profile: saved.profile.clone(),
            name: saved.name.clone(),
            catalog_url: saved
                .catalog_url
                .as_ref()
                .map(|url| url.as_str().to_owned())
                .unwrap_or_default(),
            baseline_catalog_url: saved.catalog_url.clone(),
            key_input: String::new(),
            headers_input: String::new(),
            baseline: Some(self.entries[index].clone()),
            baseline_profile: saved.profile.clone(),
            baseline_name: saved.name.clone(),
        })
    }
    fn index(&self, id: &str) -> AuthorityResult<usize> {
        self.profiles
            .iter()
            .position(|p| p.profile.id == id)
            .ok_or(AuthorityError::UnsupportedConnection)
    }
    fn same_authority(&self, authority: &ProjectAuthority) -> bool {
        matches!((&self.authority.storage, &authority.storage), (Some(a), Some(b)) if Arc::ptr_eq(a, b))
    }
}

/// Retained in-memory form. Never Debug/Serialize: typed fields may be sensitive.
#[derive(Clone)]
pub struct ConnectionDraft {
    pub profile: Profile,
    pub name: String,
    pub key_input: String,
    pub headers_input: String,
    /// Unvalidated editing value; validation happens at fetch/save boundaries.
    pub catalog_url: String,
    baseline_catalog_url: Option<CatalogUrl>,
    baseline: Option<Fields>,
    baseline_profile: Profile,
    baseline_name: String,
}
impl ConnectionDraft {
    pub fn new(mut profile: Profile, name: String) -> Self {
        profile.headers.clear();
        Self {
            baseline_profile: profile.clone(),
            baseline_name: name.clone(),
            profile,
            name,
            key_input: String::new(),
            headers_input: String::new(),
            catalog_url: String::new(),
            baseline_catalog_url: None,
            baseline: None,
        }
    }
    pub fn has_changes(&self) -> bool {
        !self.key_input.is_empty()
            || !self.headers_input.is_empty()
            || self.name != self.baseline_name
            || self.catalog_url
                != self
                    .baseline_catalog_url
                    .as_ref()
                    .map(CatalogUrl::as_str)
                    .unwrap_or("")
            || serde_json::to_vec(&self.profile).ok()
                != serde_json::to_vec(&self.baseline_profile).ok()
    }
}

pub struct ConnectionSave {
    pub loaded: LoadedConnections,
    pub profile: SavedConnection,
    pub forked: bool,
}
/// Fresh exact membership evidence. No credential getters or Debug formatter.
pub struct ConfirmedConnection {
    metadata: SavedConnection,
    entry: Fields,
    authority: ProjectAuthority,
}
impl ConfirmedConnection {
    pub fn metadata(&self) -> &SavedConnection {
        &self.metadata
    }
}

#[cfg(test)]
thread_local! { static CATALOG_TEST_KEY_READS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) }; }
fn field<T: for<'de> serde::Deserialize<'de>>(fields: &Fields, name: &str) -> AuthorityResult<T> {
    #[cfg(test)]
    if name == "apiKey" {
        CATALOG_TEST_KEY_READS.with(|reads| reads.set(reads.get() + 1));
    }
    parse(fields.0.get(name).ok_or(AuthorityError::Corrupt)?)
}
fn decode_catalog_sources(
    fields: &Fields,
    profiles: &[SavedConnection],
) -> AuthorityResult<BTreeMap<String, String>> {
    let links: Fields = fields
        .0
        .get("catalogSources")
        .filter(|value| value.get() != "null")
        .map(|value| parse(value))
        .transpose()?
        .unwrap_or_else(|| Fields(BTreeMap::new()));
    if links.0.len() > MAX_CONNECTIONS {
        return Err(AuthorityError::Corrupt);
    }
    let sources: BTreeMap<String, String> = parse(&raw(&links)?)?;
    for (route, source) in &sources {
        if route == source
            || sources.contains_key(source)
            || !profiles
                .iter()
                .any(|p| p.profile.id == *route && p.profile.api == "openai-responses")
            || !profiles
                .iter()
                .any(|p| p.profile.id == *source && p.profile.api == "openai-responses")
        {
            return Err(AuthorityError::Corrupt);
        }
    }
    Ok(sources)
}
fn catalog_url(value: &str) -> AuthorityResult<Option<CatalogUrl>> {
    if value.trim().is_empty() {
        return Ok(None);
    }
    CatalogUrl::parse(value)
        .map(Some)
        .map_err(|_| AuthorityError::InvalidConnection)
}
fn store_catalog_sources(current: &mut LoadedConnections) -> AuthorityResult<()> {
    if current.catalog_sources.is_empty() {
        current.envelope.fields.0.remove("catalogSources");
    } else {
        current
            .envelope
            .fields
            .0
            .insert("catalogSources".into(), raw(&current.catalog_sources)?);
    }
    Ok(())
}
fn metadata(authority: &ProjectAuthority, entry: &Fields) -> AuthorityResult<SavedConnection> {
    let fields: Fields = field(entry, "profile")?;
    let id: String = field(&fields, "id")?;
    if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
        return Err(AuthorityError::Corrupt);
    }
    let name: String = fields
        .0
        .get("name")
        .map(|v| parse(v))
        .transpose()?
        .unwrap_or_else(|| "LiteLLM connection".into());
    let revision: String = fields
        .0
        .get("revision")
        .map(|v| parse(v))
        .transpose()?
        .unwrap_or_default();
    let catalog_value: Option<String> = fields
        .0
        .get("catalogUrl")
        .map(|v| parse(v))
        .transpose()?
        .flatten();
    let parsed_catalog = catalog_url(catalog_value.as_deref().unwrap_or(""));
    let catalog_valid = parsed_catalog.is_ok();
    let catalog_url = parsed_catalog.unwrap_or_default();
    let known = Fields(
        fields
            .0
            .iter()
            .filter(|(key, _)| PROFILE_FIELDS.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    );
    let decoded: AuthorityResult<Profile> = parse(&raw(&known)?);
    let known_fields = fields.0.keys().all(|key| {
        PROFILE_FIELDS.contains(&key.as_str())
            || ["name", "revision", "catalogUrl"].contains(&key.as_str())
    }) && entry
        .0
        .keys()
        .all(|key| ["profile", "apiKey", "headers"].contains(&key.as_str()));
    // Unsupported records keep an inspectable identity without normalizing their raw content.
    let (mut profile, parsed) = match decoded {
        Ok(profile) => (profile, true),
        Err(_) => (
            Profile {
                id,
                api: String::new(),
                provider_id: String::new(),
                model_id: String::new(),
                input: vec!["text".into()],
                base_url: String::new(),
                context_window: 0,
                max_output_tokens: 0,
                model_output_limit: None,
                output_cap: None,
                reasoning: false,
                thinking_level: "default".into(),
                headers: BTreeMap::new(),
                compat: Default::default(),
            },
            false,
        ),
    };
    let available = parsed
        && catalog_valid
        && known_fields
        && secrets(entry).is_ok_and(|(key, headers)| {
            let mut configured = profile.clone();
            configured.headers = headers;
            validate_connection(authority, &configured, &key).is_ok()
        });
    profile.headers.clear();
    // Invalid endpoint text can itself contain credentials/query tokens. Keep
    // the raw record opaque instead of echoing such text through list/Debug/UI.
    if profile.endpoint().is_err() {
        profile.base_url.clear();
    }
    Ok(SavedConnection {
        profile,
        name,
        revision,
        available,
        catalog_url,
    })
}
fn secrets(entry: &Fields) -> AuthorityResult<(String, BTreeMap<String, String>)> {
    let key: String = field(entry, "apiKey")?;
    let headers: BTreeMap<String, String> = entry
        .0
        .get("headers")
        .map(|value| {
            let fields: Fields = parse(value)?;
            parse(&raw(&fields)?)
        })
        .transpose()?
        .unwrap_or_default();
    if key.is_empty()
        || key.len() > 16_384
        || key.bytes().any(|b| b < 32 || b == 127)
        || headers.len() > 64
    {
        return Err(AuthorityError::InvalidConnection);
    }
    Ok((key, headers))
}
fn same_route(left: &Profile, right: &Profile) -> bool {
    left.id == right.id
        && left.api == right.api
        && left.base_url == right.base_url
        && left.model_id == right.model_id
}
fn validate_connection(
    authority: &ProjectAuthority,
    profile: &Profile,
    key: &str,
) -> AuthorityResult<()> {
    profile
        .validate()
        .map_err(|_| AuthorityError::InvalidConnection)?;
    if uuid::Uuid::parse_str(&profile.id).is_err()
        || key.is_empty()
        || key.len() > 16_384
        || key.bytes().any(|b| b < 32 || b == 127)
    {
        return Err(AuthorityError::InvalidConnection);
    }
    match authority.provenance {
        super::AuthorityProvenance::Unavailable => Err(AuthorityError::Unavailable),
        super::AuthorityProvenance::Production => Ok(()),
        #[cfg(feature = "synthetic-authority")]
        super::AuthorityProvenance::Fixture => validate_synthetic(profile, key),
    }
}
#[cfg(feature = "synthetic-authority")]
fn validate_synthetic(profile: &Profile, key: &str) -> AuthorityResult<()> {
    profile
        .validate()
        .map_err(|_| AuthorityError::InvalidConnection)?;
    let endpoint = profile
        .endpoint()
        .map_err(|_| AuthorityError::InvalidConnection)?;
    if uuid::Uuid::parse_str(&profile.id).is_err()
        || key != SYNTHETIC_KEY
        || profile
            .headers
            .values()
            .any(|value| value != SYNTHETIC_HEADER)
        || !(matches!(endpoint.host(), Some(url::Host::Ipv4(ip)) if ip.is_loopback())
            || matches!(endpoint.host(), Some(url::Host::Ipv6(ip)) if ip.is_loopback()))
    {
        return Err(AuthorityError::InvalidConnection);
    }
    Ok(())
}
impl ProjectAuthority {
    pub fn load_connections(&self) -> AuthorityResult<LoadedConnections> {
        LoadedConnections::decode(self, self.load()?)
    }
    fn current_connections(
        &self,
        expected: &LoadedConnections,
    ) -> AuthorityResult<LoadedConnections> {
        if !expected.same_authority(self) {
            return Err(AuthorityError::Conflict);
        }
        let current = self.load_connections()?;
        if current.envelope.previous != expected.envelope.previous
            || current.revision() != expected.revision()
        {
            return Err(AuthorityError::Conflict);
        }
        Ok(current)
    }
    fn replace_connections(
        &self,
        current: LoadedConnections,
        entries: Vec<Fields>,
    ) -> AuthorityResult<LoadedConnections> {
        let revision = current
            .revision()
            .checked_add(1)
            .ok_or(AuthorityError::Conflict)?;
        let mut fields = current.envelope.fields.clone();
        fields.0.insert("revision".into(), raw(&revision)?);
        fields.0.insert("profiles".into(), raw(&entries)?);
        let bytes = serde_json::to_vec(&fields).map_err(|_| AuthorityError::Corrupt)?;
        let next = LoadedConnections::decode(self, LoadedProjects::decode(Some(bytes.clone()))?)?;
        self.storage()?
            .replace(current.envelope.previous.as_deref(), &bytes)?;
        Ok(next)
    }
    /// One tab, one whole-envelope CAS. The caller retains the draft on every failure.
    /// Blank secrets preserve; a nonblank header object replaces, including {}.
    pub fn save_connection(
        &self,
        expected: &LoadedConnections,
        draft: &ConnectionDraft,
    ) -> AuthorityResult<ConnectionSave> {
        let mut current = self.current_connections(expected)?;
        let next_catalog = catalog_url(&draft.catalog_url)?;
        if !draft.profile.headers.is_empty() {
            return Err(AuthorityError::InvalidConnection);
        }
        let previous = current
            .profiles
            .iter()
            .position(|p| p.profile.id == draft.profile.id);
        if let Some(baseline) = &draft.baseline {
            let index = previous.ok_or(AuthorityError::Conflict)?;
            if raw(baseline)?.get() != raw(&current.entries[index])?.get() {
                return Err(AuthorityError::Conflict);
            }
            if !current.profiles[index].available {
                return Err(AuthorityError::UnsupportedConnection);
            }
        } else if previous.is_some() {
            return Err(AuthorityError::Conflict);
        }
        let old_secrets = previous
            .map(|index| secrets(&current.entries[index]))
            .transpose()?;
        let key = if draft.key_input.is_empty() {
            old_secrets
                .as_ref()
                .map(|v| v.0.clone())
                .unwrap_or_default()
        } else {
            draft.key_input.clone()
        };
        let headers = if draft.headers_input.is_empty() {
            old_secrets.map(|v| v.1).unwrap_or_default()
        } else {
            if draft.headers_input.len() > 262_144 {
                return Err(AuthorityError::InvalidConnection);
            }
            // Fields rejects duplicate names before the string-only decode.
            let parsed: Fields = serde_json::from_str(&draft.headers_input)
                .map_err(|_| AuthorityError::InvalidConnection)?;
            parse(&raw(&parsed)?).map_err(|_| AuthorityError::InvalidConnection)?
        };
        let mut profile = draft.profile.clone();
        profile.provider_id = "litellm".into();
        profile.headers = headers;
        validate_connection(self, &profile, &key)?;
        let forked =
            previous.is_some_and(|index| !same_route(&current.profiles[index].profile, &profile));
        if forked {
            profile.id = uuid::Uuid::new_v4().to_string();
        }
        if (previous.is_none() || forked) && current.entries.len() >= MAX_CONNECTIONS {
            return Err(AuthorityError::InvalidConnection);
        }
        let mut entry = previous
            .map(|index| current.entries[index].clone())
            .unwrap_or_else(|| Fields(BTreeMap::new()));
        let mut profile_fields = previous
            .map(|index| field::<Fields>(&current.entries[index], "profile"))
            .transpose()?
            .unwrap_or_else(|| Fields(BTreeMap::new()));
        let mut safe = profile.clone();
        safe.headers.clear();
        let generated: Fields = parse(&raw(&safe)?)?;
        for (key, value) in generated.0 {
            if key != "headers" {
                profile_fields.0.insert(key, value);
            }
        }
        if let Some(url) = &next_catalog {
            profile_fields
                .0
                .insert("catalogUrl".into(), raw(&url.as_str())?);
        } else {
            profile_fields.0.remove("catalogUrl");
        }
        profile_fields.0.insert("name".into(), raw(&draft.name)?);
        profile_fields
            .0
            .insert("revision".into(), raw(&uuid::Uuid::new_v4().to_string())?);
        entry.0.insert("profile".into(), raw(&profile_fields)?);
        entry.0.insert("apiKey".into(), raw(&key)?);
        entry.0.insert("headers".into(), raw(&profile.headers)?);
        // Only a fork made here establishes lineage. Similar legacy routes do
        // not justify sharing a model list. URL edits detach a follower.
        if let Some(index) = previous {
            let old = &current.profiles[index];
            let old_id = old.profile.id.clone();
            let edited_catalog = old.catalog_url != next_catalog;
            if !forked {
                if edited_catalog {
                    current.catalog_sources.remove(&old_id);
                }
            } else {
                let (old_key, old_headers) = secrets(&current.entries[index])?;
                if old.profile.api == profile.api
                    && old.profile.base_url == profile.base_url
                    && old_key == key
                    && old_headers == profile.headers
                {
                    let source = current
                        .catalog_sources
                        .get(&old_id)
                        .cloned()
                        .unwrap_or_else(|| old_id.clone());
                    if source != old_id && !edited_catalog {
                        current.catalog_sources.insert(profile.id.clone(), source);
                    } else if source == old_id {
                        for target in current.catalog_sources.values_mut() {
                            if *target == old_id {
                                target.clone_from(&profile.id);
                            }
                        }
                        current.catalog_sources.insert(old_id, profile.id.clone());
                        current.catalog_sources.remove(&profile.id);
                    } else {
                        current.catalog_sources.insert(old_id, profile.id.clone());
                    }
                }
            }
            store_catalog_sources(&mut current)?;
        }
        let mut entries = current.entries.clone();
        if let Some(index) = previous.filter(|_| !forked) {
            entries[index] = entry;
        } else {
            entries.push(entry);
        }
        let loaded = self.replace_connections(current, entries)?;
        let saved = loaded.profiles[loaded.index(&profile.id)?].clone();
        Ok(ConnectionSave {
            loaded,
            profile: saved,
            forked,
        })
    }
    pub fn delete_connection(
        &self,
        expected: &LoadedConnections,
        id: &str,
    ) -> AuthorityResult<LoadedConnections> {
        let mut current = self.current_connections(expected)?;
        let index = current.index(id)?;
        let mut entries = current.entries.clone();
        entries.remove(index);
        current
            .catalog_sources
            .retain(|route, source| route != id && source != id);
        store_catalog_sources(&mut current)?;
        self.replace_connections(current, entries)
    }
    /// One exact whole-envelope CAS, changing catalog metadata links only.
    pub fn use_catalog_source(
        &self,
        expected: &LoadedConnections,
        route_id: &str,
        source_id: &str,
    ) -> AuthorityResult<LoadedConnections> {
        let mut current = self.current_connections(expected)?;
        let route = &current.profiles[current.index(route_id)?];
        let source = &current.profiles[current.index(source_id)?];
        if !route.available
            || !source.available
            || route.profile.api != "openai-responses"
            || source.profile.api != "openai-responses"
        {
            return Err(AuthorityError::UnsupportedConnection);
        }
        let source = if source_id == route_id {
            route_id.to_owned()
        } else {
            current
                .catalog_sources
                .get(source_id)
                .cloned()
                .unwrap_or_else(|| source_id.to_owned())
        };
        if source == route_id {
            current.catalog_sources.remove(route_id);
        } else {
            for target in current.catalog_sources.values_mut() {
                if target == route_id {
                    target.clone_from(&source);
                }
            }
            current.catalog_sources.insert(route_id.to_owned(), source);
        }
        store_catalog_sources(&mut current)?;
        let entries = current.entries.clone();
        self.replace_connections(current, entries)
    }
    /// Prepare catalog-only metadata. A saved form must still exactly match its
    /// authority snapshot. Public/bundled catalogs never decode a saved key or
    /// provider headers; a gateway key is resolved only after same-origin proof.
    pub fn prepare_catalog(
        &self,
        expected: &LoadedConnections,
        draft: &ConnectionDraft,
    ) -> AuthorityResult<CatalogRequest> {
        let mut source_id = None;
        let mut source_profile = &draft.profile;
        let mut selected_url = catalog_url(&draft.catalog_url)?;
        let mut source_entry = None;
        let mut use_draft_key = true;
        if let Some(baseline) = &draft.baseline {
            if !expected.same_authority(self) {
                return Err(AuthorityError::Conflict);
            }
            // Do not call load_connections here: metadata validation would
            // unnecessarily decode every record's key and provider headers.
            let current = self.load()?;
            if current.previous != expected.envelope.previous
                || current.revision() != expected.revision()
            {
                return Err(AuthorityError::Conflict);
            }
            let index = expected.index(&draft.profile.id)?;
            if raw(baseline)?.get() != raw(&expected.entries[index])?.get() {
                return Err(AuthorityError::Conflict);
            }
            if !expected.profiles[index].available {
                return Err(AuthorityError::UnsupportedConnection);
            }
            source_id = Some(draft.profile.id.clone());
            source_entry = Some(&expected.entries[index]);
            if selected_url == draft.baseline_catalog_url
                && draft.profile.api == draft.baseline_profile.api
                && draft.profile.base_url == draft.baseline_profile.base_url
                && draft.key_input.is_empty()
                && let Some(source) = expected.catalog_sources.get(&draft.profile.id)
            {
                let source_index = expected.index(source)?;
                let saved = &expected.profiles[source_index];
                if !saved.available {
                    return Err(AuthorityError::UnsupportedConnection);
                }
                source_id = Some(source.clone());
                source_profile = &saved.profile;
                selected_url = saved.catalog_url.clone();
                source_entry = Some(&expected.entries[source_index]);
                use_draft_key = false;
            }
        } else if expected
            .profiles
            .iter()
            .any(|p| p.profile.id == draft.profile.id)
        {
            return Err(AuthorityError::Conflict);
        }
        let Some(url) = selected_url else {
            return Ok(CatalogRequest::bundled(source_id));
        };
        // This slice never enables production catalog networking, including on
        // a production connection that happens to name a local endpoint.
        let fixture = match self.provenance {
            #[cfg(feature = "synthetic-authority")]
            super::AuthorityProvenance::Fixture => true,
            _ => false,
        };
        if !fixture || !url.numeric_loopback() {
            return Err(AuthorityError::Unavailable);
        }
        let key = if url.uses_gateway_credential(source_profile) {
            let value = if use_draft_key && !draft.key_input.is_empty() {
                draft.key_input.clone()
            } else {
                source_entry
                    .map(|entry| field::<String>(entry, "apiKey"))
                    .transpose()?
                    .unwrap_or_default()
            };
            if value != SYNTHETIC_KEY {
                return Err(AuthorityError::InvalidConnection);
            }
            Some(Credential::new(value).map_err(|_| AuthorityError::InvalidConnection)?)
        } else {
            None
        };
        CatalogRequest::fixture(source_id, url, key).map_err(|_| AuthorityError::InvalidConnection)
    }
    pub fn confirm_connection(
        &self,
        expected: &LoadedConnections,
        id: &str,
    ) -> AuthorityResult<ConfirmedConnection> {
        let current = self.current_connections(expected)?;
        let index = current.index(id)?;
        let metadata = current.profiles[index].clone();
        if !metadata.available {
            return Err(AuthorityError::UnsupportedConnection);
        }
        Ok(ConfirmedConnection {
            metadata,
            entry: current.entries[index].clone(),
            authority: self.clone(),
        })
    }
}

#[path = "saved_connection_runtime.rs"]
mod saved_runtime;
pub(crate) use saved_runtime::ConnectionLease;
pub use saved_runtime::SavedConnectionRuntime;
#[cfg(feature = "synthetic-authority")]
#[path = "synthetic_connection_runtime.rs"]
mod synthetic_runtime;
#[cfg(feature = "synthetic-authority")]
pub use synthetic_runtime::SyntheticConnectionRuntime;

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "connection_vault_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "connection_catalog_tests.rs"]
mod catalog_tests;

#[cfg(test)]
mod production_contract_tests {
    use super::*;
    use crate::project_authority::VaultStorage;
    use std::sync::Mutex;
    #[derive(Default)]
    struct Storage(Mutex<Option<Vec<u8>>>, std::sync::atomic::AtomicUsize);
    impl VaultStorage for Storage {
        fn read(&self) -> AuthorityResult<Option<Vec<u8>>> {
            self.1.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(self.0.lock().unwrap().clone())
        }
        fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()> {
            let mut bytes = self.0.lock().unwrap();
            if bytes.as_deref() != expected {
                return Err(AuthorityError::Conflict);
            }
            *bytes = Some(replacement.to_vec());
            Ok(())
        }
    }
    fn draft() -> ConnectionDraft {
        let profile=serde_json::from_value(serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":"https://gateway.example.test","modelId":"example-model","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
        let mut draft = ConnectionDraft::new(profile, "Production contract fixture".into());
        draft.key_input = "test-only-ordinary-format-key".into();
        draft.headers_input = r#"{"x-example":"test-only-ordinary-header"}"#.into();
        draft
    }
    #[test]
    fn production_contract_validates_ordinary_inputs_without_native_or_network_access() {
        let authority = ProjectAuthority::with_test_storage(Arc::new(Storage::default()));
        let mut draft = draft();
        let saved = authority
            .save_connection(&authority.load_connections().unwrap(), &draft)
            .unwrap();
        assert!(saved.profile.available);
        let confirmed =
            SavedConnectionRuntime::confirm(&authority, &saved.loaded, &saved.profile.profile.id)
                .unwrap();
        assert_eq!(
            confirmed.metadata().profile.base_url,
            "https://gateway.example.test"
        );
        assert!(confirmed.metadata().profile.headers.is_empty());
        let mut edit = saved.loaded.edit(&saved.profile.profile.id).unwrap();
        assert!(edit.key_input.is_empty());
        assert!(edit.headers_input.is_empty());
        edit.name = "Renamed".into();
        edit.headers_input = "{}".into();
        let changed = authority.save_connection(&saved.loaded, &edit).unwrap();
        assert!(!changed.forked);
        for key in ["", "test\nkey", "test\u{7f}key"] {
            draft.profile.id = uuid::Uuid::new_v4().to_string();
            draft.key_input = key.into();
            assert!(authority.save_connection(&changed.loaded, &draft).is_err());
        }
        assert!(matches!(
            ProjectAuthority::default().load(),
            Err(AuthorityError::Unavailable)
        ));
    }
    #[test]
    fn current_project_membership_needs_one_read_and_unrelated_revision_does_not_revoke() {
        let dir = tempfile::tempdir().unwrap();
        let storage = Arc::new(Storage::default());
        let authority = ProjectAuthority::with_test_storage(storage.clone());
        let mut edit = authority.load().unwrap().edit();
        let project = edit
            .trust_project(&uuid::Uuid::new_v4().to_string(), dir.path(), &[])
            .unwrap();
        authority.save(&mut edit).unwrap();
        authority
            .save_connection(&authority.load_connections().unwrap(), &draft())
            .unwrap();
        let reads = storage.1.load(std::sync::atomic::Ordering::SeqCst);
        assert!(authority.confirm_current_project_binding(&project).is_ok());
        assert_eq!(
            storage.1.load(std::sync::atomic::Ordering::SeqCst),
            reads + 1
        );
        let mut raw: serde_json::Value =
            serde_json::from_slice(storage.0.lock().unwrap().as_ref().unwrap()).unwrap();
        raw["workspaces"][0]["futurePolicy"] = true.into();
        *storage.0.lock().unwrap() = Some(serde_json::to_vec(&raw).unwrap());
        assert!(matches!(
            authority.confirm_current_project_binding(&project),
            Err(AuthorityError::UnsupportedProject)
        ));
    }
}
