//! Bounded operator catalog metadata. Explicit catalog URLs never discover
//! provider models or change routing. Native inputs merge with declared inputs.
use crate::{Credential, Profile};
use futures_util::StreamExt;
use serde_json::{Map, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fmt,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
pub use tokio_util::sync::CancellationToken;
use url::Url;

pub const MAX_CATALOG_BYTES: usize = 2_097_152;
pub const MAX_CATALOG_MODELS: usize = 2048;
const MAX_TEXT_BYTES: usize = 2048;
const EFFORTS: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const BUNDLED: &[u8] = include_bytes!("../../../../catalogs/bello-agent.models.json");

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelDescriptor {
    pub id: String,
    pub name: String,
    pub description: String,
    pub context_window: Option<u32>,
    pub max_output_tokens: Option<u32>,
    /// None is unreported. Some([]) explicitly accepts no effort setting.
    pub reasoning: Option<Vec<String>>,
    pub deprecated: bool,
    pub order: Option<i64>,
    pub input: Option<Vec<String>>,
}
impl ModelDescriptor {
    pub fn display_name(&self) -> &str {
        if self.name.is_empty() {
            &self.id
        } else {
            &self.name
        }
    }
    /// Apply metadata only. Existing input permissions and requested budget are
    /// never widened, and no credential, endpoint, identity or header is changed.
    pub fn applying(&self, profile: &mut Profile) {
        profile.model_id.clone_from(&self.id);
        if let Some(context) = self.context_window {
            profile.context_window = context;
        }
        profile.model_output_limit = self.max_output_tokens;
        profile.max_output_tokens = profile
            .max_output_tokens
            .min(self.max_output_tokens.unwrap_or(1_000_000))
            .min(profile.context_window.saturating_sub(1));
        if let Some(reasoning) = &self.reasoning {
            profile.reasoning = !reasoning.is_empty();
            if reasoning.is_empty() || !reasoning.contains(&profile.thinking_level) {
                profile.thinking_level = "default".into();
            }
        }
    }
}

/// Query strings can contain access tokens, so URLs never implement Display and
/// Debug never prints any component. UI may explicitly expose its editing value.
#[derive(Clone, PartialEq, Eq)]
pub struct CatalogUrl(String);
impl CatalogUrl {
    pub fn parse(value: &str) -> Result<Self, CatalogError> {
        let value = value.trim();
        if value.is_empty()
            || value.len() > 8192
            || value.chars().any(|c| c.is_whitespace() || c.is_control())
            || value.contains('\\')
        {
            return Err(CatalogError::Url);
        }
        let authority = value
            .split_once("://")
            .map(|(_, rest)| rest.split(['/', '?', '#']).next().unwrap_or_default())
            .ok_or(CatalogError::Url)?;
        if authority.contains('@') {
            return Err(CatalogError::Url);
        }
        let url = Url::parse(value).map_err(|_| CatalogError::Url)?;
        // Swift permits these explicit HTTP hosts, not alternate numeric forms
        // which URL parsers can normalize to 127.0.0.1 (e.g. 127.1).
        let host = authority
            .strip_prefix('[')
            .and_then(|value| value.split_once(']').map(|(host, _)| host))
            .unwrap_or_else(|| authority.split(':').next().unwrap_or_default());
        let loopback = ["localhost", "127.0.0.1", "::1"]
            .iter()
            .any(|allowed| host.eq_ignore_ascii_case(allowed));
        if !(url.scheme() == "https" || url.scheme() == "http" && loopback)
            || url.host().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.port() == Some(0)
        {
            return Err(CatalogError::Url);
        }
        Ok(Self(value.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    fn url(&self) -> Result<Url, CatalogError> {
        Url::parse(&self.0).map_err(|_| CatalogError::Url)
    }
    pub fn uses_gateway_credential(&self, profile: &Profile) -> bool {
        if profile.api != "openai-responses" {
            return false;
        }
        match (self.url(), profile.endpoint()) {
            (Ok(catalog), Ok(gateway)) => {
                catalog.scheme() == gateway.scheme()
                    && catalog.host() == gateway.host()
                    && catalog.port_or_known_default() == gateway.port_or_known_default()
            }
            _ => false,
        }
    }
    pub(crate) fn numeric_loopback(&self) -> bool {
        self.url().is_ok_and(|url| match url.host() {
            Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
            Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
            _ => false,
        })
    }
}
impl fmt::Debug for CatalogUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CatalogUrl([REDACTED])")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error(
        "Use an HTTPS catalog URL, or explicit loopback HTTP, without credentials or a fragment."
    )]
    Url,
    #[error("The catalog API key is invalid.")]
    Credential,
    #[error("The catalog endpoint redirected. Use its final URL; the API key was not forwarded.")]
    Redirected,
    #[error("The catalog endpoint returned an unsuccessful HTTP status.")]
    Http,
    #[error("The catalog response exceeded the supported size.")]
    Oversized,
    #[error("The catalog response was not in the expected format.")]
    Malformed,
    #[error("The catalog request timed out.")]
    TimedOut,
    #[error("The catalog endpoint could not be reached.")]
    Unavailable,
    #[error("Remote catalogs are available only in explicit numeric-loopback fixtures.")]
    FixtureOnly,
    #[error("The bundled Bello model catalog could not be loaded.")]
    BundledUnavailable,
    #[error("Catalog loading was cancelled.")]
    Cancelled,
}

pub fn bundled() -> Result<Vec<ModelDescriptor>, CatalogError> {
    bundled_models().cloned()
}
fn bundled_models() -> Result<&'static Vec<ModelDescriptor>, CatalogError> {
    static MODELS: OnceLock<Result<Vec<ModelDescriptor>, CatalogError>> = OnceLock::new();
    MODELS
        .get_or_init(|| parse(BUNDLED).map_err(|_| CatalogError::BundledUnavailable))
        .as_ref()
        .map_err(Clone::clone)
}
fn text(value: Option<&Value>, clean: bool) -> String {
    let Some(mut value) = value.and_then(Value::as_str) else {
        return String::new();
    };
    if clean {
        value = value.trim();
        if value.chars().any(char::is_control) {
            return String::new();
        }
    }
    let mut end = value.len().min(MAX_TEXT_BYTES);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}
fn integer(value: &Value) -> Result<i64, CatalogError> {
    value
        .as_i64()
        .or_else(|| {
            // Preserve exact integer JSON values above 2^53 via as_i64 first. Float
            // syntax is accepted only for integral values strictly within i64 range.
            value
                .as_f64()
                .filter(|n| {
                    n.is_finite()
                        && n.fract() == 0.0
                        && *n >= i64::MIN as f64
                        && *n < -(i64::MIN as f64)
                })
                .map(|n| n as i64)
        })
        .ok_or(CatalogError::Malformed)
}
fn tokens(
    row: &Map<String, Value>,
    names: &[&str],
    min: u32,
    max: u32,
) -> Result<Option<u32>, CatalogError> {
    names
        .iter()
        .find_map(|name| row.get(*name))
        .map(|v| {
            let n = integer(v)?;
            if n < i64::from(min) || n > i64::from(max) {
                return Err(CatalogError::Malformed);
            }
            Ok(n as u32)
        })
        .transpose()
}
fn known_strings(value: &Value, known: &[&str]) -> Result<Vec<String>, CatalogError> {
    let list = value.as_array().ok_or(CatalogError::Malformed)?;
    if list.iter().any(|v| !v.is_string()) {
        return Err(CatalogError::Malformed);
    }
    Ok(known
        .iter()
        .filter(|known| list.iter().any(|v| v.as_str() == Some(**known)))
        .map(|s| (*s).to_owned())
        .collect())
}
pub fn parse(body: &[u8]) -> Result<Vec<ModelDescriptor>, CatalogError> {
    if body.len() > MAX_CATALOG_BYTES {
        return Err(CatalogError::Oversized);
    }
    let root: Value = serde_json::from_slice(body).map_err(|_| CatalogError::Malformed)?;
    let list = if let Some(object) = root.as_object() {
        if let Some(version) = object.get("version")
            && integer(version)? != 1
        {
            return Err(CatalogError::Malformed);
        }
        object.get("models").and_then(Value::as_array)
    } else {
        root.as_array()
    }
    .ok_or(CatalogError::Malformed)?;
    if list.len() > MAX_CATALOG_MODELS {
        return Err(CatalogError::Oversized);
    }
    let mut ids = HashSet::new();
    let mut models = Vec::with_capacity(list.len());
    for row in list {
        let row = row.as_object().ok_or(CatalogError::Malformed)?;
        let id = row
            .get("id")
            .and_then(Value::as_str)
            .ok_or(CatalogError::Malformed)?
            .trim();
        if id.is_empty()
            || id.len() > 200
            || id.chars().any(char::is_control)
            || !ids.insert(id.to_owned())
        {
            return Err(CatalogError::Malformed);
        }
        let reasoning = row
            .get("reasoning")
            .map(|v| {
                known_strings(
                    v.as_object().and_then(|o| o.get("efforts")).unwrap_or(v),
                    EFFORTS,
                )
            })
            .transpose()?;
        let deprecated = row
            .get("deprecated")
            .map(|v| v.as_bool().ok_or(CatalogError::Malformed))
            .transpose()?
            .unwrap_or(false);
        // Validate recognized Swift metadata even though this bounded slice does
        // not yet offer utility-model selection.
        if let Some(mini) = row.get("mini")
            && !mini.is_boolean()
        {
            return Err(CatalogError::Malformed);
        }
        models.push(ModelDescriptor {
            id: id.to_owned(),
            name: text(row.get("name"), true),
            description: text(row.get("description"), false),
            context_window: tokens(
                row,
                &["contextWindow", "context_window", "context"],
                2,
                10_000_000,
            )?,
            max_output_tokens: tokens(
                row,
                &["maxOutputTokens", "max_output_tokens", "maxOutput"],
                1,
                1_000_000,
            )?,
            reasoning,
            deprecated,
            order: row.get("order").map(integer).transpose()?,
            input: row
                .get("input")
                .map(|v| known_strings(v, &["text", "image"]))
                .transpose()?,
        });
    }
    // Stable sorting preserves array order for equal explicit orders and for
    // unordered rows, including when an explicit order is i64::MAX.
    models.sort_by_key(|model| (model.order.is_none(), model.order.unwrap_or_default()));
    Ok(models)
}

/// An opaque, single-use request. Neither endpoint nor credential is formatted.
/// Only ProjectAuthority can authorize native or fixture construction.
pub struct CatalogRequest {
    source_id: Option<String>,
    remote: Option<(CatalogUrl, Option<Credential>)>,
    publication: Option<CatalogPublication>,
}

/// Authority-local metadata only. Fingerprints include the credential only for
/// same-origin catalogs, without retaining another copy of its plaintext.
#[derive(Default)]
pub(crate) struct CatalogCache(Mutex<BTreeMap<[u8; 32], CachedCatalog>>);
/// Swift's ModelCatalog.Entry freshness: a listing is reused for five minutes,
/// a failure is not retried for thirty seconds unless forced, and a failed
/// refresh keeps the last good list beside it.
pub(crate) const CATALOG_TTL: Duration = Duration::from_secs(300);
pub(crate) const CATALOG_FAILURE_RETRY: Duration = Duration::from_secs(30);
struct CachedCatalog {
    generation: uuid::Uuid,
    loading: bool,
    fetched: Option<std::time::Instant>,
    failed: bool,
    models: Arc<Vec<ModelDescriptor>>,
}
struct CatalogPublication {
    cache: Arc<CatalogCache>,
    identity: [u8; 32],
    generation: uuid::Uuid,
}
#[derive(Clone)]
pub(crate) struct CatalogBinding {
    cache: Arc<CatalogCache>,
    identity: Option<[u8; 32]>,
}
impl CatalogBinding {
    pub(crate) fn new(
        cache: Arc<CatalogCache>,
        url: Option<&CatalogUrl>,
        profile: &Profile,
        key: &str,
    ) -> Self {
        use sha2::{Digest, Sha256};
        let identity = url.map(|url| {
            let mut hash = Sha256::new();
            for value in [
                profile.api.as_str(),
                profile.base_url.as_str(),
                url.0.as_str(),
                if url.uses_gateway_credential(profile) {
                    key
                } else {
                    ""
                },
            ] {
                hash.update((value.len() as u64).to_le_bytes());
                hash.update(value.as_bytes());
            }
            hash.finalize().into()
        });
        Self { cache, identity }
    }
    fn begin(&self) -> Option<CatalogPublication> {
        let identity = self.identity?;
        let mut entries = self.cache.0.lock().ok()?;
        let generation = uuid::Uuid::new_v4();
        if !entries.contains_key(&identity) && entries.len() >= 128 {
            let first = *entries.keys().next()?;
            entries.remove(&first);
        }
        let entry = entries.entry(identity).or_insert_with(|| CachedCatalog {
            generation,
            loading: false,
            fetched: None,
            failed: false,
            models: Arc::new(vec![]),
        });
        entry.generation = generation;
        entry.loading = true;
        Some(CatalogPublication {
            cache: self.cache.clone(),
            identity,
            generation,
        })
    }
    /// A custom catalog that a passive (unforced) listing would fetch now:
    /// never listed, stale, or past its failure retry, and not already loading.
    /// The bundled catalog needs no request.
    pub(crate) fn needs_load(&self) -> bool {
        let Some(identity) = self.identity else {
            return false;
        };
        let Ok(entries) = self.cache.0.lock() else {
            return false;
        };
        let Some(entry) = entries.get(&identity) else {
            return true;
        };
        !entry.loading
            && entry.fetched.is_none_or(|fetched| {
                fetched.elapsed()
                    >= if entry.failed {
                        CATALOG_FAILURE_RETRY
                    } else {
                        CATALOG_TTL
                    }
            })
    }
    pub(crate) fn same_source(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.cache, &other.cache) && self.identity == other.identity
    }
    pub(crate) fn descriptor(&self, model: &str) -> Option<ModelDescriptor> {
        if let Some(identity) = self.identity {
            self.cache
                .0
                .lock()
                .ok()?
                .get(&identity)?
                .models
                .iter()
                .find(|row| row.id == model)
                .cloned()
        } else {
            bundled_models()
                .ok()?
                .iter()
                .find(|row| row.id == model)
                .cloned()
        }
    }
}
impl CatalogPublication {
    /// Only the newest listing for a source writes its entry. A cancelled or
    /// abandoned listing writes nothing but stops counting as in flight.
    fn finish(&self, result: Option<&Result<Vec<ModelDescriptor>, CatalogError>>) {
        if let Ok(mut entries) = self.cache.0.lock()
            && let Some(entry) = entries.get_mut(&self.identity)
            && entry.generation == self.generation
            && entry.loading
        {
            entry.loading = false;
            match result {
                Some(Ok(models)) => {
                    entry.models = Arc::new(models.clone());
                    entry.fetched = Some(std::time::Instant::now());
                    entry.failed = false;
                }
                Some(Err(_)) => {
                    entry.fetched = Some(std::time::Instant::now());
                    entry.failed = true;
                }
                None => {}
            }
        }
    }
}
impl Drop for CatalogPublication {
    fn drop(&mut self) {
        self.finish(None);
    }
}
impl CatalogRequest {
    pub(crate) fn bundled(source_id: Option<String>) -> Self {
        Self {
            source_id,
            remote: None,
            publication: None,
        }
    }
    pub(crate) fn fixture(
        source_id: Option<String>,
        url: CatalogUrl,
        key: Option<Credential>,
    ) -> Result<Self, CatalogError> {
        if !url.numeric_loopback() {
            return Err(CatalogError::FixtureOnly);
        }
        if key
            .as_ref()
            .is_some_and(|key| key.expose() != crate::project_authority::connections::SYNTHETIC_KEY)
        {
            return Err(CatalogError::FixtureOnly);
        }
        Ok(Self {
            source_id,
            remote: Some((url, key)),
            publication: None,
        })
    }
    pub(crate) fn native(
        source_id: Option<String>,
        url: CatalogUrl,
        key: Option<Credential>,
        binding: CatalogBinding,
    ) -> Self {
        Self {
            source_id,
            remote: Some((url, key)),
            publication: binding.begin(),
        }
    }
    pub fn source_id(&self) -> Option<&str> {
        self.source_id.as_deref()
    }
    pub fn is_bundled(&self) -> bool {
        self.remote.is_none()
    }
    /// Safe on GPUI's executor without a Tokio reactor. Dropping this future
    /// aborts its worker instead of detaching an unowned network operation.
    pub async fn load(
        self,
        cancel: CancellationToken,
    ) -> Result<Vec<ModelDescriptor>, CatalogError> {
        if cancel.is_cancelled() {
            return Err(CatalogError::Cancelled);
        }
        let runtime = crate::runtime::shared_runtime().map_err(|_| CatalogError::Unavailable)?;
        let mut task = AbortFetch(runtime.spawn(self.load_inner(cancel, FetchLimits::default())));
        (&mut task.0).await.map_err(|_| CatalogError::Unavailable)?
    }
    /// For non-Tokio host background threads, including GPUI's executor.
    /// Async callers should prefer `load`; do not invoke inside a Tokio runtime.
    pub fn load_blocking(
        self,
        cancel: CancellationToken,
    ) -> Result<Vec<ModelDescriptor>, CatalogError> {
        let runtime = crate::runtime::shared_runtime().map_err(|_| CatalogError::Unavailable)?;
        runtime.block_on(self.load(cancel))
    }
    async fn load_inner(
        self,
        cancel: CancellationToken,
        limits: FetchLimits,
    ) -> Result<Vec<ModelDescriptor>, CatalogError> {
        if cancel.is_cancelled() {
            return Err(CatalogError::Cancelled);
        }
        let Some((url, key)) = self.remote else {
            return bundled();
        };
        let result = tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(CatalogError::Cancelled),
            result = tokio::time::timeout(limits.total, fetch(url, key, limits)) => {
                result.map_err(|_| CatalogError::TimedOut)?
            }
        };
        if cancel.is_cancelled() {
            return Err(CatalogError::Cancelled);
        }
        if let Some(publication) = &self.publication
            && !matches!(result, Err(CatalogError::Cancelled))
        {
            publication.finish(Some(&result));
        }
        result
    }
}
struct AbortFetch(tokio::task::JoinHandle<Result<Vec<ModelDescriptor>, CatalogError>>);
impl Drop for AbortFetch {
    fn drop(&mut self) {
        self.0.abort();
    }
}
#[derive(Clone, Copy)]
struct FetchLimits {
    idle: Duration,
    total: Duration,
}
impl Default for FetchLimits {
    fn default() -> Self {
        Self {
            idle: Duration::from_secs(8),
            total: Duration::from_secs(120),
        }
    }
}
fn transport_error(error: reqwest::Error) -> CatalogError {
    if error.is_timeout() {
        CatalogError::TimedOut
    } else {
        CatalogError::Unavailable
    }
}
async fn fetch(
    url: CatalogUrl,
    key: Option<Credential>,
    limits: FetchLimits,
) -> Result<Vec<ModelDescriptor>, CatalogError> {
    // A fresh client has no cookies or default provider headers. Proxy and
    // redirect discovery are explicitly disabled even in fixture builds.
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(limits.idle)
        .read_timeout(limits.idle)
        .build()
        .map_err(transport_error)?;
    let mut request = client
        .get(url.url()?)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::CACHE_CONTROL, "no-cache");
    if let Some(key) = &key {
        request = request.bearer_auth(key.expose());
    }
    let response = request.send().await.map_err(transport_error)?;
    if response.status().is_redirection() {
        return Err(CatalogError::Redirected);
    }
    if !response.status().is_success() {
        return Err(CatalogError::Http);
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_CATALOG_BYTES as u64)
    {
        return Err(CatalogError::Oversized);
    }
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(transport_error)?;
        if chunk.len() > MAX_CATALOG_BYTES.saturating_sub(body.len()) {
            return Err(CatalogError::Oversized);
        }
        body.extend_from_slice(&chunk);
    }
    parse(&body)
}

#[cfg(test)]
#[path = "model_catalog_tests.rs"]
mod tests;
