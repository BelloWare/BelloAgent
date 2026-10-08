//! Bounded operator catalog metadata. Catalogs never discover provider models,
//! grant model inputs, or change runtime routing. Remote transport is fixture-only.
use crate::{Credential, Profile};
use futures_util::StreamExt;
use serde_json::{Map, Value};
use std::{collections::HashSet, fmt, time::Duration};
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
        let loopback = match url.host() {
            Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
            Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
            Some(url::Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
            None => false,
        };
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
    parse(BUNDLED).map_err(|_| CatalogError::BundledUnavailable)
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
/// Only ProjectAuthority can authorize remote fixture construction.
pub struct CatalogRequest {
    source_id: Option<String>,
    remote: Option<(CatalogUrl, Option<Credential>)>,
}
impl CatalogRequest {
    pub(crate) fn bundled(source_id: Option<String>) -> Self {
        Self {
            source_id,
            remote: None,
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
        Ok(Self {
            source_id,
            remote: Some((url, key)),
        })
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
        if !url.numeric_loopback() {
            return Err(CatalogError::FixtureOnly);
        }
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(CatalogError::Cancelled),
            result = tokio::time::timeout(limits.total, fetch(url, key, limits)) => {
                result.map_err(|_| CatalogError::TimedOut)?
            }
        }
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
