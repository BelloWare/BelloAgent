//! Explicit SessionTools.swift95–143 normalization. Structured data becomes
//! durable text, supported image bytes stay typed, other payloads become short
//! descriptors. Configured header values never enter durable/UI/provider text.
use super::{McpError, McpResult};
use crate::tool_content::{ContentBlock, MAX_CONTENT_BYTES, MAX_IMAGE_BASE64_BYTES, ToolContent};
use serde_json::{Value, json};
use std::sync::Arc;
#[derive(Clone)]
pub(crate) struct Normalized {
    pub content: Arc<ToolContent>,
    pub is_error: bool,
}
impl Normalized {
    pub fn value(&self) -> Value {
        json!({"content":self.content.blocks,"isError":self.is_error})
    }
}
pub(super) fn redact(value: &mut Value, secrets: &[String]) -> McpResult<()> {
    match value {
        Value::String(text) => *text = redact_text(text, secrets)?,
        Value::Array(values) => {
            for value in values {
                redact(value, secrets)?;
            }
        }
        Value::Object(values) => {
            let old = std::mem::take(values);
            for (key, mut value) in old {
                redact(&mut value, secrets)?;
                let key = redact_text(&key, secrets)?;
                if values.insert(key, value).is_some() {
                    return Err(McpError::unknown(
                        "mcp_result",
                        "MCP result keys collide after credential redaction",
                    ));
                }
            }
        }
        _ => {}
    }
    Ok(())
}
fn redact_text(text: &str, secrets: &[String]) -> McpResult<String> {
    if secrets.is_empty() {
        return Ok(text.into());
    }
    let mut out = String::new();
    let mut at = 0;
    while at < text.len() {
        if let Some(secret) = secrets
            .iter()
            .filter(|s| !s.is_empty())
            .find(|s| text[at..].starts_with(s.as_str()))
        {
            out.push_str("[redacted]");
            at += secret.len();
        } else {
            let c = text[at..].chars().next().expect("UTF-8 boundary");
            out.push(c);
            at += c.len_utf8();
        }
        if out.len() > MAX_CONTENT_BYTES {
            return Err(McpError::limit());
        }
    }
    Ok(out)
}
pub(super) fn normalize(mut value: Value, secrets: &[String]) -> McpResult<Normalized> {
    if !value.is_object() || value.get("isError").is_some_and(|v| !v.is_boolean()) {
        return Err(McpError::unknown("mcp_result", "Invalid MCP result object"));
    }
    redact(&mut value, secrets)?;
    let is_error = value["isError"].as_bool().unwrap_or(false);
    let mut blocks = vec![];
    let entries = match value.get("content") {
        Some(Value::Array(values)) => values.as_slice(),
        None => &[],
        _ => return Err(McpError::unknown("mcp_result", "Invalid MCP content list")),
    };
    if entries.len() > 62 {
        return Err(McpError::limit());
    }
    for part in entries {
        if !part.is_object() {
            return Err(McpError::unknown("mcp_result", "Invalid MCP content block"));
        }
        if let Some(text) = part["text"].as_str() {
            blocks.push(ContentBlock::Text { text: text.into() });
            continue;
        }
        if part["type"] == "image" {
            if let (Some(data), Some(mime)) = (part["data"].as_str(), part["mimeType"].as_str())
                && data.len() < MAX_IMAGE_BASE64_BYTES
                && crate::tool_content::canonical_base64(data)
                && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(&mime)
            {
                blocks.push(ContentBlock::Image {
                    data: data.into(),
                    mime_type: mime.into(),
                });
                continue;
            }
            blocks.push(ContentBlock::Text {
                text: "[Image omitted: unsupported, malformed or oversized MCP image.]".into(),
            });
            continue;
        }
        let kind = part["mimeType"]
            .as_str()
            .or_else(|| part["type"].as_str())
            .unwrap_or("content");
        let kind = kind
            .chars()
            .filter(|c| !c.is_control())
            .take(128)
            .collect::<String>();
        let bytes = part["data"]
            .as_str()
            .filter(|d| crate::tool_content::canonical_base64(d))
            .map(|d| d.len() / 4 * 3 - d.bytes().rev().take_while(|b| *b == b'=').count());
        blocks.push(ContentBlock::Text {
            text: format!(
                "[{kind} result{}]",
                bytes.map(|n| format!(", {n} bytes")).unwrap_or_default()
            ),
        });
    }
    if blocks.is_empty() {
        blocks.push(ContentBlock::Text {
            text: serde_json::to_string(&value).map_err(|_| McpError::protocol())?,
        });
    }
    if value.get("structuredContent").is_some_and(|v| !v.is_null()) {
        blocks.push(ContentBlock::Text {
            text: format!("Structured content:\n{}", value["structuredContent"]),
        });
    }
    let content = ToolContent {
        blocks,
        stats: None,
    };
    content.validate().map_err(|_|McpError::unknown("mcp_result","MCP result exceeds its durable content limit; effects may have occurred. No automatic replay."))?;
    Ok(Normalized {
        content: Arc::new(content),
        is_error,
    })
}
