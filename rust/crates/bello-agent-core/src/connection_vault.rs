//! A bounded Settings connection slice in the existing whole-envelope vault.
//! Unknown fields remain raw; no native composition or credential entry is enabled.
//! Source: ConfigurationVault, WorkspaceConfiguration and SettingsConnectionForm.
use super::{
    AuthorityError, AuthorityResult, Fields, LoadedProjects, ProjectAuthority, parse, raw,
};
use crate::Profile;
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
}

#[derive(Clone)]
pub struct LoadedConnections {
    authority: ProjectAuthority,
    envelope: LoadedProjects,
    entries: Vec<Fields>,
    profiles: Vec<SavedConnection>,
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
            let metadata = metadata(entry)?;
            if !ids.insert(metadata.profile.id.clone()) {
                return Err(AuthorityError::Corrupt);
            }
            profiles.push(metadata);
        }
        Ok(Self {
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
    pub fn edit(&self, id: &str) -> AuthorityResult<ConnectionDraft> {
        let index = self.index(id)?;
        let saved = &self.profiles[index];
        Ok(ConnectionDraft {
            profile: saved.profile.clone(),
            name: saved.name.clone(),
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
            baseline: None,
        }
    }
    pub fn has_changes(&self) -> bool {
        !self.key_input.is_empty()
            || !self.headers_input.is_empty()
            || self.name != self.baseline_name
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
    #[cfg(feature = "synthetic-authority")]
    entry: Fields,
    #[cfg(feature = "synthetic-authority")]
    authority: ProjectAuthority,
}
impl ConfirmedConnection {
    pub fn metadata(&self) -> &SavedConnection {
        &self.metadata
    }
}

fn field<T: for<'de> serde::Deserialize<'de>>(fields: &Fields, name: &str) -> AuthorityResult<T> {
    parse(fields.0.get(name).ok_or(AuthorityError::Corrupt)?)
}
fn metadata(entry: &Fields) -> AuthorityResult<SavedConnection> {
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
        PROFILE_FIELDS.contains(&key.as_str()) || ["name", "revision"].contains(&key.as_str())
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
        && known_fields
        && secrets(entry).is_ok_and(|(key, headers)| {
            let mut configured = profile.clone();
            configured.headers = headers;
            validate_synthetic(&configured, &key).is_ok()
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
        validate_synthetic(&profile, &key)?;
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
        profile_fields.0.insert("name".into(), raw(&draft.name)?);
        profile_fields
            .0
            .insert("revision".into(), raw(&uuid::Uuid::new_v4().to_string())?);
        entry.0.insert("profile".into(), raw(&profile_fields)?);
        entry.0.insert("apiKey".into(), raw(&key)?);
        entry.0.insert("headers".into(), raw(&profile.headers)?);
        // Source catalog inheritance for model-only forks of the same route
        // authority. No model discovery or unrelated raw catalog field is read.
        if forked && let Some(index) = previous {
            let old = &current.profiles[index].profile;
            let (old_key, old_headers) = secrets(&current.entries[index])?;
            if old.api == profile.api
                && old.base_url == profile.base_url
                && old_key == key
                && old_headers == profile.headers
            {
                let mut links: Fields = current
                    .envelope
                    .fields
                    .0
                    .get("catalogSources")
                    .filter(|value| value.get() != "null")
                    .map(|value| parse(value))
                    .transpose()?
                    .unwrap_or_else(|| Fields(BTreeMap::new()));
                let authority = links
                    .0
                    .get(&old.id)
                    .map(|value| parse::<String>(value))
                    .transpose()?
                    .unwrap_or_else(|| old.id.clone());
                if authority != old.id {
                    links.0.insert(profile.id.clone(), raw(&authority)?);
                } else {
                    for value in links.0.values_mut() {
                        if parse::<String>(value).ok().as_deref() == Some(old.id.as_str()) {
                            *value = raw(&profile.id)?;
                        }
                    }
                    links.0.insert(old.id.clone(), raw(&profile.id)?);
                    links.0.remove(&profile.id);
                }
                current
                    .envelope
                    .fields
                    .0
                    .insert("catalogSources".into(), raw(&links)?);
            }
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
        // Source forgetCatalogLinks: preserve every unrelated link as its raw value.
        if let Some(value) = current.envelope.fields.0.get("catalogSources")
            && value.get() != "null"
        {
            let mut links: Fields = parse(value)?;
            links.0.retain(|key, value| {
                key != id && parse::<String>(value).ok().as_deref() != Some(id)
            });
            current
                .envelope
                .fields
                .0
                .insert("catalogSources".into(), raw(&links)?);
        }
        self.replace_connections(current, entries)
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
            #[cfg(feature = "synthetic-authority")]
            entry: current.entries[index].clone(),
            #[cfg(feature = "synthetic-authority")]
            authority: self.clone(),
        })
    }
}

#[cfg(feature = "synthetic-authority")]
#[path = "synthetic_connection_runtime.rs"]
mod synthetic_runtime;
#[cfg(feature = "synthetic-authority")]
pub(crate) use synthetic_runtime::ConnectionLease;
#[cfg(feature = "synthetic-authority")]
pub use synthetic_runtime::SyntheticConnectionRuntime;

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "connection_vault_tests.rs"]
mod tests;
