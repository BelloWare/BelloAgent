//! Typed rejection evidence from the provider boundary, before display redaction.
//!
//! Source: Swift ProviderFailure.swift and PiProviderRules.swift at
//! f4f80ddda3c27fac9e266896f69b725a06242e8f. Intentionally stricter than Pi's
//! overflow text matching: generic token limits, request sizes, empty 400/413,
//! and arbitrary assistant/tool/transport text cannot authorize context recovery.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    InputContextExceeded,
    InputPlusOutputContextExceeded,
    OutputLimitInvalid,
    RequestBodyTooLarge,
    RateLimited,
    Authentication,
    Other,
}
impl Category {
    pub fn context_rejection(self) -> bool {
        matches!(
            self,
            Self::InputContextExceeded | Self::InputPlusOutputContextExceeded
        )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub category: Category,
    pub status: Option<u16>,
    pub message: String,
    pub attempt_id: Option<String>,
    pub reported_usage: Option<Value>,
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for Failure {}

impl Failure {
    /// Called only for a real non-success HTTP response or a JSON/SSE failure
    /// envelope, never for successful output, callbacks, or transport errors.
    pub(crate) fn rejection(value: &Value, http_status: Option<u16>) -> Self {
        let detail = if !value["response"]["error"].is_null() {
            &value["response"]["error"]
        } else if !value["error"].is_null() {
            &value["error"]
        } else {
            value
        };
        let nodes = [
            detail,
            &value["error"],
            &value["response"]["error"],
            value,
            &value["response"],
        ];
        let statuses: Vec<u16> = http_status
            .into_iter()
            .chain(nodes.iter().flat_map(|node| {
                ["status", "status_code"]
                    .into_iter()
                    .filter_map(move |key| node[key].as_u64().and_then(|n| u16::try_from(n).ok()))
            }))
            .collect();
        let codes: Vec<String> = nodes
            .iter()
            .flat_map(|node| {
                ["code", "type"]
                    .into_iter()
                    .filter_map(move |key| node[key].as_str().map(str::to_ascii_lowercase))
            })
            .collect();
        let has = |names: &[&str]| codes.iter().any(|code| names.contains(&code.as_str()));
        let message = detail["message"]
            .as_str()
            .or(detail.as_str())
            .or(value["message"].as_str())
            .unwrap_or("Provider reported an unsuccessful response")
            .to_owned();
        // All non-context structured categories veto context code AND text.
        let category = if statuses.iter().any(|s| matches!(s, 401 | 403))
            || has(&[
                "authentication_error",
                "authentication_failed",
                "invalid_api_key",
                "unauthorized",
                "permission_denied",
                "permission_error",
                "access_denied",
            ]) {
            Category::Authentication
        } else if statuses.contains(&429)
            || has(&[
                "rate_limit_exceeded",
                "rate_limit_error",
                "rate_limited",
                "too_many_requests",
                "insufficient_quota",
                "quota_exceeded",
                "resource_exhausted",
            ])
        {
            Category::RateLimited
        } else if statuses.contains(&413)
            || has(&[
                "request_too_large",
                "request_body_too_large",
                "payload_too_large",
                "entity_too_large",
                "content_too_large",
            ])
        {
            Category::RequestBodyTooLarge
        } else if has(&[
            "invalid_max_output_tokens",
            "max_output_tokens_exceeded",
            "invalid_max_tokens",
            "invalid_max_completion_tokens",
        ]) || nodes.iter().any(|node| {
            matches!(
                node["param"].as_str(),
                Some("max_output_tokens" | "max_tokens" | "max_completion_tokens")
            )
        }) {
            Category::OutputLimitInvalid
        } else if has(&["input_plus_output_context_exceeded"]) {
            Category::InputPlusOutputContextExceeded
        } else if has(&[
            "context_length_exceeded",
            "context_window_exceeded",
            "input_too_long",
            "contextwindowexceedederror",
            "model_context_window_exceeded",
        ]) || (codes.iter().all(|code| {
            matches!(
                code.as_str(),
                "error"
                    | "response.failed"
                    | "invalid_request_error"
                    | "bad_request"
                    | "invalid_argument"
            )
        }) && precise_context_text(&message))
        {
            Category::InputContextExceeded
        } else {
            Category::Other
        };
        let mut reported_usage = None;
        for usage in [
            &value["response"]["usage"],
            &value["usage"],
            &detail["usage"],
        ] {
            merge_reported_usage(&mut reported_usage, usage);
        }
        Self {
            category,
            status: http_status.or_else(|| statuses.first().copied()),
            message,
            attempt_id: None,
            reported_usage,
        }
    }
}

/// Merge persisted and current explicit usage observations. Callers should
/// translate absent wire usage (`null`) to None before calling this helper.
pub(crate) fn merge_usage(prior: Option<Value>, current: Option<Value>) -> Option<Value> {
    let mut merged = prior;
    if let Some(current) = current {
        if current.is_null() {
            return Some(Value::Null);
        }
        merge_reported_usage(&mut merged, &current);
    }
    merged
}

/// Combine only explicit observations. Conflicting fields remain unknown even
/// if a later envelope repeats one side of the conflict. Resource exhaustion
/// marks the entire observation unknown instead of retaining misleading totals.
pub(crate) fn merge_reported_usage(target: &mut Option<Value>, incoming: &Value) {
    if !incoming.is_object() {
        return;
    }
    if target.is_none() {
        *target = Some(Value::Object(Default::default()));
    }
    let target = target.as_mut().expect("initialized above");
    if target.is_null() {
        return;
    }
    fn merge(target: &mut Value, incoming: &Value, depth: usize, budget: &mut usize) {
        if *budget == 0 || depth > 8 {
            *target = Value::Null;
            return;
        }
        *budget -= 1;
        if let (Some(existing), Some(observed)) = (target.as_object_mut(), incoming.as_object()) {
            for (key, value) in observed {
                if key.len() > 1024 || *budget == 0 {
                    *budget = 0;
                    break;
                }
                if let Some(old) = existing.get_mut(key) {
                    merge(old, value, depth + 1, budget);
                } else {
                    let mut copy = match value {
                        Value::Object(_) => Value::Object(Default::default()),
                        Value::Array(_) => Value::Null,
                        Value::String(text) if text.len() > 1024 => Value::Null,
                        other => other.clone(),
                    };
                    if value.is_object() {
                        merge(&mut copy, value, depth + 1, budget);
                    } else {
                        *budget = budget.saturating_sub(1);
                    }
                    existing.insert(key.clone(), copy);
                }
            }
        } else if target != incoming {
            *target = Value::Null;
        }
    }
    let mut budget = 1024;
    merge(target, incoming, 0, &mut budget);
    if budget == 0 || serde_json::to_vec(target).map_or(true, |bytes| bytes.len() > 65_536) {
        *target = Value::Null;
    }
}

fn precise_context_text(message: &str) -> bool {
    let text = message.to_ascii_lowercase();
    // Source-derived explicit prompt/context phrases only. Textual rate and
    // service failures veto fallback, matching Pi's non-overflow exclusions.
    if [
        "rate limit",
        "too many requests",
        "throttling error",
        "service unavailable",
    ]
    .iter()
    .any(|phrase| text.contains(phrase))
    {
        return false;
    }
    [
        "prompt is too long",
        "input is too long for requested model",
        "exceeds the context window",
        "exceeds the model's maximum context length",
        "exceeds the maximum context length",
        "exceeds maximum context length",
        "exceeds the available context size",
        "prompt too long; exceeded context length",
        "prompt too long; exceeded max context length",
    ]
    .iter()
    .any(|phrase| text.contains(phrase))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn known_codes_and_precise_source_fallback() {
        for code in [
            "context_length_exceeded",
            "context_window_exceeded",
            "input_too_long",
            "ContextWindowExceededError",
            "model_context_window_exceeded",
        ] {
            assert_eq!(
                Failure::rejection(&json!({"error":{"code":code}}), Some(400)).category,
                Category::InputContextExceeded
            );
        }
        assert_eq!(
            Failure::rejection(
                &json!({"response":{"error":{"code":"input_plus_output_context_exceeded"}}}),
                None
            )
            .category,
            Category::InputPlusOutputContextExceeded
        );
        for message in [
            "prompt is too long",
            "input is too long for requested model",
            "Your input exceeds the context window",
            "Request exceeds the model's maximum context length of 4096 tokens",
        ] {
            assert!(
                Failure::rejection(
                    &json!({"error":{"message":message,"type":"invalid_request_error"}}),
                    Some(400)
                )
                .category
                .context_rejection()
            );
        }
    }
    #[test]
    fn structured_vetoes_win_over_context_codes_and_text() {
        for (code, expected) in [
            ("invalid_api_key", Category::Authentication),
            ("rate_limit_exceeded", Category::RateLimited),
            ("request_too_large", Category::RequestBodyTooLarge),
            ("invalid_max_output_tokens", Category::OutputLimitInvalid),
        ] {
            let value = json!({"code":"context_length_exceeded","error":{"code":code,"message":"prompt is too long"}});
            assert_eq!(Failure::rejection(&value, Some(400)).category, expected);
        }
        assert_eq!(
            Failure::rejection(
                &json!({"error":{"type":"authentication_error"},
            "response":{"error":{"code":"context_length_exceeded"}}}),
                None
            )
            .category,
            Category::Authentication
        );
        for (status, expected) in [
            (401, Category::Authentication),
            (403, Category::Authentication),
            (429, Category::RateLimited),
            (413, Category::RequestBodyTooLarge),
        ] {
            for value in [
                json!({"error":{"code":"context_length_exceeded"}}),
                json!({"error":{"message":"prompt is too long"}}),
            ] {
                assert_eq!(Failure::rejection(&value, Some(status)).category, expected);
                let mut nested = value.clone();
                nested["error"]["status_code"] = json!(status);
                assert_eq!(Failure::rejection(&nested, Some(200)).category, expected);
            }
        }
        assert_eq!(
            Failure::rejection(
                &json!({"error":{"code":"context_length_exceeded","param":"max_output_tokens"}}),
                None
            )
            .category,
            Category::OutputLimitInvalid
        );
    }
    #[test]
    fn vague_or_unrelated_limit_text_is_not_context_evidence() {
        for message in [
            "too many tokens",
            "token limit exceeded",
            "exceeds the limit of 42",
            "request_too_large",
            "400 status code (no body)",
            "413 status code (no body)",
            "rate limit: prompt is too long",
            "Service unavailable: prompt is too long",
            "maximum output tokens exceeded",
        ] {
            assert_eq!(
                Failure::rejection(&json!({"error":{"message":message}}), Some(400)).category,
                Category::Other,
                "{message}"
            );
        }
        assert_eq!(
            Failure::rejection(
                &json!({"error":{"code":"server_error","message":"prompt is too long"}}),
                Some(500)
            )
            .category,
            Category::Other
        );
    }
    #[test]
    fn usage_is_only_reported_not_synthesized() {
        let missing =
            Failure::rejection(&json!({"error":{"code":"context_length_exceeded"}}), None);
        assert_eq!(missing.reported_usage, None);
        let reported = Failure::rejection(
            &json!({"response":{"error":{"code":"context_length_exceeded"},"usage":{"input_tokens":123}}}),
            None,
        );
        assert_eq!(reported.reported_usage, Some(json!({"input_tokens":123})));
        assert_eq!(
            serde_json::from_value::<Failure>(serde_json::to_value(&reported).unwrap()).unwrap(),
            reported
        );
    }
    #[test]
    fn sparse_usage_merges_without_inventing_or_overwriting_evidence() {
        let failure = Failure::rejection(
            &json!({"response":{"error":{"code":"context_length_exceeded"},"usage":{}},
            "usage":{"input_tokens":123,"input_tokens_details":{"cached_tokens":40}}}),
            None,
        );
        assert_eq!(
            failure.reported_usage,
            Some(json!({"input_tokens":123,"input_tokens_details":{"cached_tokens":40}}))
        );
        let mut usage = failure.reported_usage;
        merge_reported_usage(
            &mut usage,
            &json!({"output_tokens":7,"input_tokens_details":{"reasoning_tokens":3}}),
        );
        assert_eq!(usage.as_ref().unwrap()["input_tokens"], 123);
        assert_eq!(usage.as_ref().unwrap()["output_tokens"], 7);
        assert_eq!(
            usage.as_ref().unwrap()["input_tokens_details"]["cached_tokens"],
            40
        );
        merge_reported_usage(
            &mut usage,
            &json!({"input_tokens":124,"input_tokens_details":{"cached_tokens":41}}),
        );
        merge_reported_usage(
            &mut usage,
            &json!({"input_tokens":123,"input_tokens_details":{"cached_tokens":40}}),
        );
        assert!(usage.as_ref().unwrap()["input_tokens"].is_null());
        assert!(usage.as_ref().unwrap()["input_tokens_details"]["cached_tokens"].is_null());
        assert_eq!(
            usage.as_ref().unwrap()["input_tokens_details"]["reasoning_tokens"],
            3
        );
    }
    #[test]
    fn usage_merge_has_sticky_resource_bounds() {
        let mut usage = None;
        let huge = Value::Object((0..1100).map(|n| (format!("field{n}"), json!(n))).collect());
        merge_reported_usage(&mut usage, &huge);
        assert_eq!(usage, Some(Value::Null));
        merge_reported_usage(&mut usage, &json!({"input_tokens":1}));
        assert_eq!(usage, Some(Value::Null));
    }
}
