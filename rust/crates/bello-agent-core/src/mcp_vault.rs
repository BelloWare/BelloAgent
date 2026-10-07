//! Project-scoped MCP configuration in the same opaque, whole-byte CAS vault.
//! Headers never enter the editable general JSON view or a Debug formatter.
use super::*;
use serde_json::Value;
use std::collections::BTreeMap;

pub const MAX_CONFIG_BYTES: usize = 262_144;
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct ServerConfiguration {
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default = "http")]
    pub transport: String,
    pub url: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    pub allowed_tools: Option<Vec<String>>,
    #[serde(default = "timeout")]
    pub timeout_seconds: u64,
}
fn yes() -> bool {
    true
}
fn http() -> String {
    "http".into()
}
fn timeout() -> u64 {
    60
}
#[derive(Clone)]
pub(crate) struct Configuration {
    pub servers: BTreeMap<String, ServerConfiguration>,
}
fn valid_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    name.len() <= 128
        && (first.is_ascii_alphanumeric() || b"_:-".contains(&first))
        && bytes.all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(&c))
}
fn bounded(value: &str) -> bool {
    value.len() <= 16_384 && !value.contains('\0')
}
fn validate_headers(headers: &BTreeMap<String, String>) -> AuthorityResult<()> {
    if headers.len() > 64
        || headers.iter().any(|(key, value)| {
            key.is_empty()
                || key.len() > 128
                || !key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
                || !bounded(value)
                || value.bytes().any(|c| c < 32 || c == 127)
                || [
                    "host",
                    "content-length",
                    "transfer-encoding",
                    "connection",
                    "mcp-session-id",
                    "mcp-protocol-version",
                ]
                .contains(&key.to_ascii_lowercase().as_str())
        })
    {
        return Err(AuthorityError::InvalidMcp);
    }
    let mut names = HashSet::new();
    if headers
        .keys()
        .any(|key| !names.insert(key.to_ascii_lowercase()))
    {
        return Err(AuthorityError::InvalidMcp);
    }
    Ok(())
}
fn decode(value: &RawValue, authority: &ProjectAuthority) -> AuthorityResult<Configuration> {
    if value.get().len() > MAX_CONFIG_BYTES {
        return Err(AuthorityError::InvalidMcp);
    }
    let root: Fields = parse(value).map_err(|_| AuthorityError::InvalidMcp)?;
    if root.0.len() != 1 {
        return Err(AuthorityError::InvalidMcp);
    }
    let servers: Fields = parse(root.0.get("servers").ok_or(AuthorityError::InvalidMcp)?)
        .map_err(|_| AuthorityError::InvalidMcp)?;
    if servers.0.len() > 32 {
        return Err(AuthorityError::InvalidMcp);
    }
    let mut result = BTreeMap::new();
    for (name, value) in servers.0 {
        if !valid_name(&name) {
            return Err(AuthorityError::InvalidMcp);
        }
        let fields: Fields = parse(&value).map_err(|_| AuthorityError::InvalidMcp)?;
        if fields
            .0
            .get("transport")
            .and_then(|v| parse::<String>(v).ok())
            .as_deref()
            == Some("stdio")
            || fields.0.contains_key("command")
        {
            return Err(AuthorityError::UnsupportedMcp);
        }
        // Missing permits discovery; an empty list permits no tools.
        // Present null must never silently erase that distinction.
        if fields
            .0
            .get("allowedTools")
            .is_some_and(|value| value.get() == "null")
        {
            return Err(AuthorityError::InvalidMcp);
        }
        let config: ServerConfiguration = parse(&value).map_err(|_| AuthorityError::InvalidMcp)?;
        if config.transport != "http" {
            return Err(AuthorityError::UnsupportedMcp);
        }
        if !(1..=300).contains(&config.timeout_seconds)
            || config
                .allowed_tools
                .as_ref()
                .is_some_and(|names| names.len() > 256 || names.iter().any(|n| !bounded(n)))
            || config.url.len() > 16_384
            || config.url.chars().any(char::is_whitespace)
        {
            return Err(AuthorityError::InvalidMcp);
        }
        validate_headers(&config.headers)?;
        let url = url::Url::parse(&config.url).map_err(|_| AuthorityError::InvalidMcp)?;
        if url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !(url.scheme() == "https"
                || url.scheme() == "http"
                    && matches!(
                        url.host_str(),
                        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
                    ))
        {
            return Err(AuthorityError::InvalidMcp);
        }
        #[cfg(feature = "synthetic-authority")]
        if authority.provenance == AuthorityProvenance::Fixture {
            let numeric_loopback = match url.host() {
                Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
                Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
                _ => false,
            };
            if !numeric_loopback
                || config.headers.values().any(|v| {
                    v != connections::SYNTHETIC_KEY
                        && v != "synthetic-header-fixture-only"
                        && v != &format!("Bearer {}", connections::SYNTHETIC_KEY)
                })
            {
                return Err(AuthorityError::InvalidMcp);
            }
        }
        let _ = authority;
        result.insert(name, config);
    }
    Ok(Configuration { servers: result })
}
/// Immutable exact project/configuration snapshot. Sensitive fields stay opaque.
#[derive(Clone)]
pub struct LoadedMcp {
    envelope: LoadedProjects,
    pub(crate) project: SavedProject,
    pub(crate) authority: ProjectAuthority,
    record: Box<RawValue>,
    pub(crate) configuration: Configuration,
}
impl LoadedMcp {
    pub fn revision(&self) -> i64 {
        self.envelope.revision()
    }
    pub fn project_id(&self) -> &str {
        &self.project.id
    }
    pub fn configuration_json_without_headers(&self) -> String {
        let mut value: Value = serde_json::from_str(self.record.get()).expect("validated MCP JSON");
        for server in value["servers"]
            .as_object_mut()
            .expect("validated servers")
            .values_mut()
        {
            server
                .as_object_mut()
                .expect("validated server")
                .remove("headers");
        }
        serde_json::to_string_pretty(&value).expect("bounded JSON")
    }
    pub fn configured_header_servers(&self) -> Vec<String> {
        self.configuration
            .servers
            .iter()
            .filter(|(_, s)| !s.headers.is_empty())
            .map(|(n, _)| n.clone())
            .collect()
    }
    pub(crate) fn same_authority(&self, other: &Self) -> bool {
        self.project == other.project && self.same_store(other)
    }
    pub(crate) fn same_store(&self, other: &Self) -> bool {
        matches!((&self.authority.storage,&other.authority.storage),(Some(a),Some(b)) if Arc::ptr_eq(a,b))
    }
    pub(crate) fn same_configuration(&self, other: &Self) -> bool {
        self.same_authority(other) && self.record.get() == other.record.get()
    }
    pub(crate) fn confirm(&self) -> AuthorityResult<()> {
        let current = self.authority.load_mcp(&self.project)?;
        if current.record.get() != self.record.get() {
            return Err(AuthorityError::Conflict);
        }
        Ok(())
    }
    pub(crate) fn redactions(&self) -> Vec<String> {
        let mut values = self
            .configuration
            .servers
            .values()
            .flat_map(|server| server.headers.values())
            .filter(|v| !v.is_empty())
            .cloned()
            .collect::<Vec<_>>();
        values.extend(values.clone().into_iter().filter_map(|v| {
            v.strip_prefix("Bearer ")
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        }));
        values.sort_by_key(|v| std::cmp::Reverse(v.len()));
        values.dedup();
        values
    }
}
impl ProjectAuthority {
    pub fn load_mcp(&self, project: &SavedProject) -> AuthorityResult<LoadedMcp> {
        let envelope = self.load()?;
        Self::project_membership(&envelope, project)?;
        if fs::canonicalize(&project.path).map_err(|_| AuthorityError::InvalidProject)?
            != project.path
        {
            return Err(AuthorityError::InvalidProject);
        }
        let configs: Fields = envelope
            .fields
            .0
            .get("mcp")
            .filter(|v| v.get() != "null")
            .map(|v| parse(v))
            .transpose()?
            .unwrap_or_else(|| Fields(BTreeMap::new()));
        let record = configs
            .0
            .get(&project.id)
            .cloned()
            .unwrap_or(raw(&serde_json::json!({"servers":{}}))?);
        let configuration = decode(&record, self)?;
        Ok(LoadedMcp {
            envelope,
            project: project.clone(),
            authority: self.clone(),
            record,
            configuration,
        })
    }
    /// Visible JSON must omit headers. Blank replacements retain headers only
    /// for the same named endpoint; {} explicitly clears them. Moving secrets
    /// to a different endpoint requires an explicit replacement, never inference.
    pub fn save_mcp(
        &self,
        expected: &LoadedMcp,
        configuration_json: &str,
        header_replacements: &BTreeMap<String, String>,
    ) -> AuthorityResult<LoadedMcp> {
        if configuration_json.len() > MAX_CONFIG_BYTES || header_replacements.len() > 32 {
            return Err(AuthorityError::InvalidMcp);
        }
        if !matches!((&self.storage,&expected.authority.storage),(Some(a),Some(b)) if Arc::ptr_eq(a,b))
        {
            return Err(AuthorityError::Conflict);
        }
        let current = self.load_mcp(&expected.project)?;
        if current.envelope.previous != expected.envelope.previous {
            return Err(AuthorityError::Conflict);
        }
        let mut root: Fields =
            serde_json::from_str(configuration_json).map_err(|_| AuthorityError::InvalidMcp)?;
        if root.0.len() != 1 {
            return Err(AuthorityError::InvalidMcp);
        }
        let mut servers: Fields = parse(root.0.get("servers").ok_or(AuthorityError::InvalidMcp)?)
            .map_err(|_| AuthorityError::InvalidMcp)?;
        if header_replacements
            .keys()
            .any(|key| !servers.0.contains_key(key))
        {
            return Err(AuthorityError::InvalidMcp);
        }
        for (name, server) in &mut servers.0 {
            let mut fields: Fields = parse(server).map_err(|_| AuthorityError::InvalidMcp)?;
            if fields.0.contains_key("headers") {
                return Err(AuthorityError::InvalidMcp);
            }
            let replacement = header_replacements.get(name).filter(|v| !v.is_empty());
            let headers = if let Some(replacement) = replacement {
                if replacement.len() > MAX_CONFIG_BYTES {
                    return Err(AuthorityError::InvalidMcp);
                }
                let unique: Fields =
                    serde_json::from_str(replacement).map_err(|_| AuthorityError::InvalidMcp)?;
                let headers: BTreeMap<String, String> =
                    parse(&raw(&unique)?).map_err(|_| AuthorityError::InvalidMcp)?;
                validate_headers(&headers)?;
                headers
            } else if let Some(old) = current.configuration.servers.get(name) {
                let new_url: String = parse(fields.0.get("url").ok_or(AuthorityError::InvalidMcp)?)
                    .map_err(|_| AuthorityError::InvalidMcp)?;
                if new_url != old.url && !old.headers.is_empty() {
                    return Err(AuthorityError::McpSecretDestination);
                }
                old.headers.clone()
            } else {
                BTreeMap::new()
            };
            if !headers.is_empty() {
                fields.0.insert("headers".into(), raw(&headers)?);
            }
            *server = raw(&fields)?;
        }
        root.0.insert("servers".into(), raw(&servers)?);
        let record = raw(&root)?;
        decode(&record, self)?;
        let mut fields = current.envelope.fields.clone();
        let mut configs: Fields = fields
            .0
            .get("mcp")
            .filter(|v| v.get() != "null")
            .map(|v| parse(v))
            .transpose()?
            .unwrap_or_else(|| Fields(BTreeMap::new()));
        configs.0.insert(expected.project.id.clone(), record);
        fields.0.insert("mcp".into(), raw(&configs)?);
        let revision = current
            .revision()
            .checked_add(1)
            .ok_or(AuthorityError::Conflict)?;
        fields.0.insert("revision".into(), raw(&revision)?);
        let bytes = serde_json::to_vec(&fields).map_err(|_| AuthorityError::Corrupt)?;
        LoadedProjects::decode(Some(bytes.clone()))?;
        self.storage()?
            .replace(current.envelope.previous.as_deref(), &bytes)?;
        // Do not perform a fallible reread after a successful CAS: return the
        // exact committed bytes so an unrelated writer cannot disguise success.
        let envelope = LoadedProjects::decode(Some(bytes))?;
        let configs: Fields = parse(
            envelope
                .fields
                .0
                .get("mcp")
                .ok_or(AuthorityError::Corrupt)?,
        )?;
        let record = configs
            .0
            .get(&expected.project.id)
            .ok_or(AuthorityError::Corrupt)?
            .clone();
        let configuration = decode(&record, self)?;
        Ok(LoadedMcp {
            envelope,
            project: expected.project.clone(),
            authority: self.clone(),
            record,
            configuration,
        })
    }
}
