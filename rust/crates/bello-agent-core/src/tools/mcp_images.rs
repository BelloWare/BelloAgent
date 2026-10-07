//! Reuse the source-backed ImageIO normalization on macOS. Portable MCP keeps
//! already-supported bounded image payloads; it does not claim a substitute
//! decoder/resizer. Unsupported payloads become explicit omission descriptors.
use super::{ToolResult, check_cancelled};
use serde_json::Value;
use tokio_util::sync::CancellationToken;
pub(crate) fn normalize(mut value: Value, cancel: &CancellationToken) -> ToolResult<Value> {
    check_cancelled(cancel)?;
    #[cfg(target_os = "macos")]
    {
        use super::read::ImageResult;
        use base64::{Engine, engine::general_purpose::STANDARD};
        if let Some(blocks) = value.get_mut("content").and_then(Value::as_array_mut) {
            let mut output = Vec::new();
            for block in std::mem::take(blocks) {
                check_cancelled(cancel)?;
                if block["type"] == "image"
                    && let (Some(encoded), Some(mime)) =
                        (block["data"].as_str(), block["mimeType"].as_str())
                    && encoded.len() <= 4 * 1024 * 1024
                    && let Ok(bytes) = STANDARD.decode(encoded)
                    && let Ok(ImageResult::Image {
                        data,
                        mime_type,
                        hints,
                    }) = super::read_image::process(&bytes, mime, cancel)
                {
                    output
                        .push(serde_json::json!({"type":"image","data":data,"mimeType":mime_type}));
                    if !hints.is_empty() {
                        output.push(serde_json::json!({"type":"text","text":hints.join("\n")}));
                    }
                } else {
                    output.push(block);
                }
            }
            *blocks = output;
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = &mut value;
    check_cancelled(cancel)?;
    Ok(value)
}
