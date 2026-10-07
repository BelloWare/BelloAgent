//! Durable, validated native-tool content. Text-only legacy records remain
//! representable without this optional payload; image replay never rereads paths.
use crate::{Result, invalid};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const MAX_IMAGE_BASE64_BYTES: usize = 4_718_592;
pub const MAX_CONTENT_BYTES: usize = 16 * 1024 * 1024;
pub const TOOL_IMAGE_PLACEHOLDER: &str = "(tool image omitted: model does not support images)";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum ContentBlock {
    Text {
        text: String,
    },
    Image {
        data: String,
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadStats {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToolContent {
    pub blocks: Vec<ContentBlock>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stats: Option<ReadStats>,
}

impl ToolContent {
    pub fn from_native(value: &Value) -> Result<Self> {
        let content = Self {
            blocks: serde_json::from_value(value["content"].clone())?,
            stats: value
                .get("stats")
                .map(|stats| serde_json::from_value(stats.clone()))
                .transpose()?,
        };
        content.validate()?;
        Ok(content)
    }

    pub fn validate(&self) -> Result<()> {
        if self.blocks.len() > 64 || encoded_length(self, MAX_CONTENT_BYTES).is_none() {
            return Err(invalid(
                "Retained tool content exceeds its bounded storage limit",
            ));
        }
        for block in &self.blocks {
            match block {
                ContentBlock::Text { text } if text.len() > MAX_CONTENT_BYTES => {
                    return Err(invalid("Retained tool text exceeds 16 MiB"));
                }
                ContentBlock::Image { data, mime_type }
                    if !["image/png", "image/jpeg", "image/gif", "image/webp"]
                        .contains(&mime_type.as_str())
                        || data.len() >= MAX_IMAGE_BASE64_BYTES
                        || !canonical_base64(data) =>
                {
                    return Err(invalid("Invalid or oversized retained tool image"));
                }
                _ => {}
            }
        }
        if let Some(stats) = &self.stats {
            if stats.path.is_empty() || stats.path.len() > 65_536 {
                return Err(invalid("Invalid retained read path"));
            }
            match (stats.added, stats.removed) {
                (None, None) => {}
                (Some(added), Some(removed))
                    if added <= 20 * 1024 * 1024 + 1 && removed <= 20 * 1024 * 1024 + 1 => {}
                _ => return Err(invalid("Invalid retained mutation line counts")),
            }
            let maximum_line = if stats.added.is_some() {
                20 * 1024 * 1024 + 1
            } else {
                16 * 1024 * 1024 + 1
            };
            match (stats.line, stats.last_line) {
                (None, None) => {}
                (Some(first), Some(last)) if first > 0 && first <= last && last <= maximum_line => {
                }
                _ => return Err(invalid("Invalid retained read line range")),
            }
        }
        Ok(())
    }

    pub(crate) fn encoded_len(&self) -> Result<usize> {
        encoded_length(self, MAX_CONTENT_BYTES)
            .ok_or_else(|| invalid("Retained tool content exceeds its bounded storage limit"))
    }

    pub fn text(&self) -> String {
        self.blocks
            .iter()
            .filter_map(|block| match block {
                ContentBlock::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// ResponsesInput.swift toolOutput, including placeholder deduplication.
    pub fn provider_output(&self, supports_images: bool) -> Value {
        let mut texts = Vec::new();
        let mut images = Vec::new();
        let mut previous_was_placeholder = false;
        for block in &self.blocks {
            match block {
                ContentBlock::Text { text } => {
                    texts.push(text.as_str());
                    previous_was_placeholder = text == TOOL_IMAGE_PLACEHOLDER;
                }
                ContentBlock::Image { data, mime_type } if supports_images => {
                    images.push(json!({"type":"input_image","detail":"auto","image_url":format!("data:{mime_type};base64,{data}")}));
                }
                ContentBlock::Image { .. } if !previous_was_placeholder => {
                    texts.push(TOOL_IMAGE_PLACEHOLDER);
                    previous_was_placeholder = true;
                }
                _ => {}
            }
        }
        let text = texts.join("\n");
        if images.is_empty() {
            return json!(if text.is_empty() {
                "(no tool output)"
            } else {
                &text
            });
        }
        let mut blocks = Vec::new();
        if !text.is_empty() {
            blocks.push(json!({"type":"input_text","text":text}));
        }
        blocks.extend(images);
        Value::Array(blocks)
    }
}

// Count JSON bytes without materializing another full encoded payload. A
// malicious string can expand six-fold under JSON escaping.
fn encoded_length(value: &impl Serialize, maximum: usize) -> Option<usize> {
    struct Budget(usize);
    impl std::io::Write for Budget {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > self.0 {
                return Err(std::io::Error::other("content budget exceeded"));
            }
            self.0 -= bytes.len();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut budget = Budget(maximum);
    serde_json::to_writer(&mut budget, value).ok()?;
    Some(maximum - budget.0)
}

// Validate without allocating decoded bytes. Standard padded base64 only,
// including zero unused bits; no whitespace, URL alphabet or noncanonical tails.
pub(crate) fn canonical_base64(data: &str) -> bool {
    let bytes = data.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return false;
    }
    fn digit(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let padding = if bytes.ends_with(b"==") {
        2
    } else if bytes.ends_with(b"=") {
        1
    } else {
        0
    };
    let end = bytes.len() - padding;
    if !bytes[..end].iter().all(|b| digit(*b).is_some()) {
        return false;
    }
    match padding {
        2 => digit(bytes[end - 1]).is_some_and(|n| n & 15 == 0),
        1 => digit(bytes[end - 1]).is_some_and(|n| n & 3 == 0),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(value: &str) -> ContentBlock {
        ContentBlock::Text { text: value.into() }
    }
    fn image() -> ContentBlock {
        ContentBlock::Image {
            data: "YWJj".into(),
            mime_type: "image/png".into(),
        }
    }
    #[test]
    fn source_output_preserves_text_order_and_gathers_images() {
        let content = ToolContent {
            blocks: vec![image(), text("a"), image(), text("b")],
            stats: None,
        };
        assert_eq!(
            content.provider_output(true),
            json!([
                {"type":"input_text","text":"a\nb"},
                {"type":"input_image","detail":"auto","image_url":"data:image/png;base64,YWJj"},
                {"type":"input_image","detail":"auto","image_url":"data:image/png;base64,YWJj"}
            ])
        );
        assert_eq!(content.text(), "a\nb");
    }
    #[test]
    fn unsupported_images_collapse_only_adjacent_placeholders() {
        let content = ToolContent {
            blocks: vec![
                image(),
                image(),
                text("a"),
                image(),
                text(TOOL_IMAGE_PLACEHOLDER),
                image(),
            ],
            stats: None,
        };
        assert_eq!(
            content.provider_output(false),
            json!(format!("{0}\na\n{0}\n{0}", TOOL_IMAGE_PLACEHOLDER))
        );
        assert_eq!(
            ToolContent {
                blocks: vec![],
                stats: None
            }
            .provider_output(true),
            json!("(no tool output)")
        );
    }
    #[test]
    fn canonical_base64_rejects_padding_alphabet_and_unused_bits() {
        for value in ["YQ==", "YWI=", "YWJj", "/w=="] {
            assert!(canonical_base64(value), "{value}");
        }
        for value in [
            "", "YQ", "YQ=", "YQ===", "YQ==\n", "YR==", "YWJ=", "_w==", "=WJj", "AAAA====",
        ] {
            assert!(!canonical_base64(value), "{value}");
        }
    }
    #[test]
    fn payload_stats_and_unknown_fields_are_validated() {
        let mut content = ToolContent {
            blocks: vec![image()],
            stats: Some(ReadStats {
                path: "/fixture".into(),
                line: Some(1),
                last_line: Some(2),
                added: None,
                removed: None,
            }),
        };
        content.validate().unwrap();
        let encoded = serde_json::to_vec(&content).unwrap();
        assert_eq!(
            serde_json::from_slice::<ToolContent>(&encoded).unwrap(),
            content
        );
        content.stats.as_mut().unwrap().last_line = None;
        assert!(content.validate().is_err());
        assert!(
            ToolContent::from_native(
                &json!({"content":[{"type":"image","data":"YWJj","mimeType":"image/bmp"}]})
            )
            .is_err()
        );
        assert!(serde_json::from_value::<ContentBlock>(json!({"type":"image","data":"YWJj","mimeType":"image/png","url":"https://untrusted.invalid"})).is_err());
    }
    #[test]
    fn strict_source_base64_cap_is_not_inclusive() {
        let content = ToolContent {
            blocks: vec![ContentBlock::Image {
                data: "A".repeat(MAX_IMAGE_BASE64_BYTES),
                mime_type: "image/png".into(),
            }],
            stats: None,
        };
        assert!(content.validate().is_err());
    }
}

#[cfg(test)]
#[test]
fn mutation_stats_pair_and_larger_edited_viewer_bounds_are_strict() {
    let native = |stats| serde_json::json!({"content":[{"type":"text","text":"Edited fixture"}],"isError":false,"stats":stats});
    let content=ToolContent::from_native(&native(serde_json::json!({"path":"/fixture","added":0,"removed":1,"line":20*1024*1024+1,"lastLine":20*1024*1024+1}))).unwrap();
    assert_eq!(
        serde_json::from_slice::<ToolContent>(&serde_json::to_vec(&content).unwrap()).unwrap(),
        content
    );
    for stats in [
        serde_json::json!({"path":"/fixture","added":0}),
        serde_json::json!({"path":"/fixture","removed":0}),
        serde_json::json!({"path":"/fixture","added":-1,"removed":0}),
        serde_json::json!({"path":"/fixture","added":20*1024*1024+2,"removed":0}),
        serde_json::json!({"path":"/fixture","line":16*1024*1024+2,"lastLine":16*1024*1024+2}),
    ] {
        assert!(ToolContent::from_native(&native(stats)).is_err());
    }
}
