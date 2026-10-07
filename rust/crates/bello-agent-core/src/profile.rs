use crate::{Result, invalid};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use url::Url;
use zeroize::Zeroize;

/// Only an explicit in-memory credential is accepted. No file/environment lookup.
pub struct Credential(String);
impl Credential {
    pub fn new(value: String) -> Result<Self> {
        if value.is_empty() || value.len() > 16_384 || value.bytes().any(|b| b < 32 || b == 127) {
            return Err(invalid(
                "Supply a nonempty credential without control characters",
            ));
        }
        Ok(Self(value))
    }
    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
    pub(crate) fn redact(&self, text: &str) -> String {
        text.replace(&self.0, "[REDACTED]")
    }
}
impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Credential([REDACTED])")
    }
}
impl Drop for Credential {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Compatible with the validated subset of Swift Profile.swift's wire fields.
/// Credentials and opaque routing contracts are not part of this public config.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Profile {
    pub id: String,
    pub api: String,
    pub provider_id: String,
    pub model_id: String,
    /// Explicit declared model inputs; absent legacy metadata stays text-only.
    #[serde(default = "default_input")]
    pub input: Vec<String>,
    pub base_url: String,
    pub context_window: u32,
    pub max_output_tokens: u32,
    #[serde(default)]
    pub model_output_limit: Option<u32>,
    #[serde(default)]
    pub output_cap: Option<u32>,
    #[serde(default)]
    pub reasoning: bool,
    #[serde(default = "default_effort")]
    pub thinking_level: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub compat: Compatibility,
}
fn default_input() -> Vec<String> {
    vec!["text".into()]
}
fn default_effort() -> String {
    "default".into()
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Compatibility {
    #[serde(default)]
    pub allow_fallbacks: bool,
    #[serde(default)]
    pub supports_max_output_tokens: Option<bool>,
    #[serde(default)]
    pub supports_developer_role: Option<bool>,
}
impl Profile {
    pub fn supports_images(&self) -> bool {
        self.input.iter().any(|input| input == "image")
    }
    pub fn validate(&self) -> Result<()> {
        if self.input.len() > 2
            || self
                .input
                .iter()
                .any(|input| !["text", "image"].contains(&input.as_str()))
            || (self.input.len() == 2 && self.input[0] == self.input[1])
        {
            return Err(invalid("Invalid declared model inputs"));
        }
        for (value, max) in [
            (&self.id, 128),
            (&self.provider_id, 128),
            (&self.model_id, 256),
        ] {
            if value.is_empty() || value.len() > max || value.chars().any(char::is_control) {
                return Err(invalid("Invalid profile identity or model"));
            }
        }
        if self.api != "openai-responses" {
            return Err(invalid(
                "Only openai-responses is supported for new requests",
            ));
        }
        if self.provider_id != "litellm" {
            return Err(invalid(
                "Only explicit LiteLLM configuration is supported in this migration",
            ));
        }
        if self.max_output_tokens == 0
            || self.max_output_tokens >= self.context_window
            || self.context_window > 10_000_000
            || self.max_output_tokens > 1_000_000
            || [self.model_output_limit, self.output_cap]
                .into_iter()
                .flatten()
                .any(|n| n == 0 || n > 1_000_000)
        {
            return Err(invalid(
                "Output budget must be positive and below context capacity",
            ));
        }
        if ![
            "default", "off", "minimal", "low", "medium", "high", "xhigh", "max",
        ]
        .contains(&self.thinking_level.as_str())
        {
            return Err(invalid("Unsupported thinking level"));
        }
        self.endpoint()?;
        if self.headers.len() > 64 {
            return Err(invalid("At most 64 custom headers are supported"));
        }
        for (name, value) in &self.headers {
            if name.is_empty()
                || name.len() > 128
                || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                || value.len() > 16_384
                || value.bytes().any(|b| b < 32 || b == 127)
            {
                return Err(invalid("Invalid custom header"));
            }
            if [
                "host",
                "content-length",
                "transfer-encoding",
                "connection",
                "authorization",
                "x-api-key",
                "x-session-id",
                "x-turn-id",
                "session_id",
                "x-client-request-id",
            ]
            .contains(&name.to_ascii_lowercase().as_str())
            {
                return Err(invalid("Transport-owned headers cannot be overridden"));
            }
        }
        Ok(())
    }
    pub fn endpoint(&self) -> Result<Url> {
        if self.base_url.chars().any(char::is_whitespace) {
            return Err(invalid("Endpoint contains whitespace"));
        }
        // Check raw segments before URL normalization erases dot segments.
        let lower = self.base_url.to_ascii_lowercase();
        if lower.contains("%2f")
            || lower.contains("%2e")
            || self.base_url.split('/').any(|s| matches!(s, "." | ".."))
        {
            return Err(invalid(
                "Encoded or relative endpoint paths are not allowed",
            ));
        }
        let mut url = Url::parse(&self.base_url).map_err(|_| invalid("Invalid endpoint URL"))?;
        let loopback = matches!(
            url.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
        );
        if !(url.scheme() == "https" || url.scheme() == "http" && loopback)
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.host().is_none()
        {
            return Err(invalid(
                "Use HTTPS, or loopback HTTP, without URL credentials, query or fragment",
            ));
        }
        let mut path = url.path().trim_end_matches('/').to_owned();
        let full = path.ends_with("/responses");
        if full {
            path.truncate(path.len() - 10);
        }
        if ["/responses", "/messages", "/completions"]
            .iter()
            .any(|s| path.ends_with(s))
            || path.contains("/v1/v1")
            || path.contains("//")
        {
            return Err(invalid("Mixed or repeated API routes"));
        }
        if !full && !path.ends_with("/v1") {
            path.push_str("/v1");
        }
        path.push_str("/responses");
        url.set_path(&path);
        Ok(url)
    }
    pub fn wire_output_limit(&self) -> Option<u32> {
        (self.compat.supports_max_output_tokens != Some(false))
            .then(|| {
                self.output_cap
                    .or(self.model_output_limit)
                    .map(|v| v.max(16))
            })
            .flatten()
    }
    pub(crate) fn safe_error(&self, credential: &Credential, text: &str) -> String {
        let mut text = credential.redact(text);
        for value in self.headers.values().filter(|v| !v.is_empty()) {
            text = text.replace(value, "[REDACTED]");
        }
        text.chars().take(16_384).collect()
    }
}
pub fn correlation_value(value: &str) -> String {
    let value: String = value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "._:-".contains(*c))
        .take(128)
        .collect();
    if value.is_empty() {
        "unknown".into()
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    pub(crate) fn profile() -> Profile {
        serde_json::from_str(r#"{"id":"test","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096}"#).unwrap()
    }
    #[test]
    fn endpoint_normalization_and_rejection() {
        let mut p = profile();
        p.validate().unwrap();
        assert_eq!(p.endpoint().unwrap().path(), "/v1/responses");
        for bad in [
            "http://example.com",
            "https://a/v1/v1",
            "https://a/v1/../x",
            "https://a/%2e",
            "https://a/v1/messages",
            "https://a/v1/responses/responses",
            "https://x@y",
            "https://a/?token=x",
        ] {
            p.base_url = bad.into();
            assert!(p.validate().is_err(), "{bad}");
        }
        p.base_url = "https://a/custom/responses/".into();
        assert_eq!(p.endpoint().unwrap().path(), "/custom/responses");
    }
    #[test]
    fn budget_is_not_wire_limit() {
        let mut p = profile();
        assert_eq!(p.wire_output_limit(), None);
        p.model_output_limit = Some(8);
        assert_eq!(p.wire_output_limit(), Some(16));
        p.compat.supports_max_output_tokens = Some(false);
        assert_eq!(p.wire_output_limit(), None);
    }
    #[test]
    fn no_credential_leak() {
        let c = Credential::new("super-secret".into()).unwrap();
        assert!(!format!("{c:?}").contains("super-secret"));
        assert_eq!(
            profile().safe_error(&c, "bad super-secret"),
            "bad [REDACTED]"
        );
    }
    #[test]
    fn image_input_is_explicit_and_invalid_declarations_fail_closed() {
        let mut p = profile();
        assert_eq!(p.input, vec!["text"]);
        assert!(!p.supports_images());
        p.input = vec!["text".into(), "image".into()];
        p.validate().unwrap();
        assert!(p.supports_images());
        for input in [
            vec!["audio"],
            vec!["image", "image"],
            vec!["text", "image", "text"],
        ] {
            p.input = input.into_iter().map(str::to_owned).collect();
            assert!(p.validate().is_err());
        }
    }
}
