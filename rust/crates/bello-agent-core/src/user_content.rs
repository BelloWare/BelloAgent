//! Ordered retained user content. This intentionally differs from ToolContent's
//! text-first projection and 16 MiB cap. Four legal images approach 18 MiB.
use crate::{
    Result, invalid,
    tool_content::{ContentBlock, MAX_IMAGE_BASE64_BYTES, canonical_base64},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const MAX_USER_CONTENT_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_SKILL_USER_CONTENT_BYTES: usize = 32 * 1024 * 1024;
// Separate source-derived expansion bound; serialized content and the complete
// request remain independently capped, including their actual JSON escaping.
pub const MAX_EXPANDED_USER_TEXT_BYTES: usize = crate::skills::MAX_EXPANDED_TEXT_BYTES;
pub const USER_IMAGE_PLACEHOLDER: &str = "(image omitted: model does not support images)";
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UserContent {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skills: Vec<crate::skills::RecordedSkillUse>,
    pub attachments: Vec<crate::attachments::AttachmentRecord>,
    pub blocks: Vec<ContentBlock>,
}
impl std::fmt::Debug for UserContent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let images: Vec<_> = self
            .blocks
            .iter()
            .filter_map(|block| match block {
                ContentBlock::Image { data, mime_type } => Some((
                    if ["image/png", "image/jpeg", "image/gif", "image/webp"]
                        .contains(&mime_type.as_str())
                    {
                        mime_type.as_str()
                    } else {
                        "[invalid MIME]"
                    },
                    data.len(),
                )),
                _ => None,
            })
            .take(crate::attachments::MAX_ATTACHMENTS)
            .collect();
        let text_bytes: usize = self
            .blocks
            .iter()
            .filter_map(|block| match block {
                ContentBlock::Text { text } => Some(text.len()),
                _ => None,
            })
            .fold(0, usize::saturating_add);
        f.debug_struct("UserContent")
            .field("skills", &self.skills.len())
            .field("attachments", &self.attachments.len())
            .field("blocks", &self.blocks.len())
            .field("images_mime_and_base64_length", &images)
            .field("text_bytes", &text_bytes)
            .finish()
    }
}

impl UserContent {
    pub fn new(
        text: &str,
        attachments: Vec<crate::attachments::AttachmentRecord>,
        images: Vec<ContentBlock>,
    ) -> Result<Self> {
        let mut blocks = Vec::new();
        if !text.is_empty() || images.is_empty() {
            blocks.push(ContentBlock::Text { text: text.into() });
        }
        blocks.extend(images);
        let value = Self {
            skills: Vec::new(),
            attachments,
            blocks,
        };
        value.validate()?;
        Ok(value)
    }
    pub(crate) fn from_submission(
        item: &crate::Submission,
        images: Vec<ContentBlock>,
    ) -> Result<Self> {
        let text = crate::skills::user_message_text(&item.text, &item.frozen_skills, &item.id)?;
        if text.len() > MAX_EXPANDED_USER_TEXT_BYTES {
            return Err(invalid("Expanded user text exceeds 10 MiB"));
        }
        let mut blocks = Vec::new();
        if !text.is_empty() || images.is_empty() {
            blocks.push(ContentBlock::Text { text });
        }
        blocks.extend(images);
        let value = Self {
            attachments: item.attachments.clone(),
            skills: item
                .frozen_skills
                .iter()
                .map(|skill| skill.recorded())
                .collect(),
            blocks,
        };
        value.validate_submission(item)?;
        Ok(value)
    }
    pub(crate) fn validate_submission(&self, item: &crate::Submission) -> Result<()> {
        self.validate_display(&item.text)?;
        if self.attachments != item.attachments
            || self.skills
                != item
                    .frozen_skills
                    .iter()
                    .map(|skill| skill.recorded())
                    .collect::<Vec<_>>()
        {
            return Err(invalid(
                "Retained selection disagrees with frozen submission",
            ));
        }
        if !item.frozen_skills.is_empty() {
            let expected =
                crate::skills::user_message_text(&item.text, &item.frozen_skills, &item.id)?;
            if !matches!(self.blocks.first(), Some(ContentBlock::Text { text }) if text == &expected)
            {
                return Err(invalid(
                    "Retained skill expansion disagrees with frozen submission",
                ));
            }
        }
        Ok(())
    }
    pub fn image_count(&self) -> usize {
        self.blocks
            .iter()
            .filter(|b| matches!(b, ContentBlock::Image { .. }))
            .count()
    }
    pub fn validate(&self) -> Result<()> {
        crate::attachments::validate_selection(&self.attachments)?;
        crate::skills::validate_recorded_skills(&self.skills)?;
        if (self.attachments.is_empty() && self.skills.is_empty())
            || self.image_count() > self.attachments.len()
            || self.blocks.is_empty()
            || self.blocks.len() > 9
            || self.image_count() > 4
        {
            return Err(invalid("Invalid retained user image content"));
        }
        for block in &self.blocks {
            match block {
                ContentBlock::Text { text }
                    if text.len()
                        > if self.skills.is_empty() {
                            262_144
                        } else {
                            MAX_EXPANDED_USER_TEXT_BYTES
                        } =>
                {
                    return Err(invalid("Retained user text exceeds its limit"));
                }
                ContentBlock::Image { data, mime_type }
                    if data.len() >= MAX_IMAGE_BASE64_BYTES
                        || !canonical_base64(data)
                        || !["image/png", "image/jpeg", "image/gif", "image/webp"]
                            .contains(&mime_type.as_str()) =>
                {
                    return Err(invalid("Invalid or oversized retained user image"));
                }
                _ => {}
            }
        }
        struct Budget(usize);
        impl std::io::Write for Budget {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if bytes.len() > self.0 {
                    return Err(std::io::Error::other("user content limit"));
                }
                self.0 -= bytes.len();
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let maximum = if self.skills.is_empty() {
            MAX_USER_CONTENT_BYTES
        } else {
            MAX_SKILL_USER_CONTENT_BYTES
        };
        serde_json::to_writer(&mut Budget(maximum), self).map_err(|_| {
            invalid(if self.skills.is_empty() {
                "Retained user content exceeds 20 MiB"
            } else {
                "Retained skill-bearing user content exceeds 32 MiB"
            })
        })?;
        Ok(())
    }
    pub(crate) fn validate_display(&self, text: &str) -> Result<()> {
        self.validate()?;
        if !self.skills.is_empty() {
            if text.len() > 262_144 {
                return Err(invalid("Raw user text exceeds 256 KiB"));
            }
            let suffix = format!(
                "\n\nCurrent explicit selection IDs: {}\n\n{}",
                self.skills
                    .iter()
                    .map(|skill| skill.selection.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                text
            );
            if !matches!(self.blocks.first(), Some(ContentBlock::Text { text: first }) if first.starts_with("Explicit user skill selection ") && first.ends_with(&suffix))
            {
                return Err(invalid(
                    "Retained skill display text or selection IDs disagree with content",
                ));
            }
            return Ok(());
        }
        if !text.is_empty()
            && !matches!(self.blocks.first(), Some(ContentBlock::Text { text: first }) if first == text)
        {
            return Err(invalid("Retained user display text disagrees with content"));
        }
        Ok(())
    }
    pub fn provider_content(&self, images: bool) -> Vec<Value> {
        let mut output = Vec::new();
        let mut previous_placeholder = false;
        for block in &self.blocks {
            match block {
                ContentBlock::Text { text } => { output.push(json!({"type":"input_text","text":text})); previous_placeholder = text == USER_IMAGE_PLACEHOLDER; }
                ContentBlock::Image { data, mime_type } if images => output.push(json!({"type":"input_image","detail":"auto","image_url":format!("data:{mime_type};base64,{data}")})),
                ContentBlock::Image { .. } if !previous_placeholder => { output.push(json!({"type":"input_text","text":USER_IMAGE_PLACEHOLDER})); previous_placeholder = true; }
                _ => {}
            }
        }
        output
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn image() -> ContentBlock {
        ContentBlock::Image {
            data: "YWJj".into(),
            mime_type: "image/png".into(),
        }
    }
    fn text(s: &str) -> ContentBlock {
        ContentBlock::Text { text: s.into() }
    }
    fn metadata(n: usize) -> Vec<crate::attachments::AttachmentRecord> {
        (0..n)
            .map(|_| crate::attachments::AttachmentRecord {
                id: uuid::Uuid::new_v4().to_string(),
                path: "/fixture.png".into(),
                sha256: "a".repeat(64),
                bytes: 3,
                mime_type: "image/png".into(),
            })
            .collect()
    }
    #[test]
    fn source_order_image_only_and_adjacent_placeholders() {
        let image_only = UserContent::new("", metadata(1), vec![image()]).unwrap();
        assert_eq!(image_only.provider_content(true)[0]["type"], "input_image");
        let content = UserContent {
            skills: Vec::new(),
            attachments: metadata(4),
            blocks: vec![
                image(),
                image(),
                text("hint"),
                image(),
                text(USER_IMAGE_PLACEHOLDER),
                image(),
            ],
        };
        assert_eq!(
            content.provider_content(false),
            vec![
                json!({"type":"input_text","text":USER_IMAGE_PLACEHOLDER}),
                json!({"type":"input_text","text":"hint"}),
                json!({"type":"input_text","text":USER_IMAGE_PLACEHOLDER}),
                json!({"type":"input_text","text":USER_IMAGE_PLACEHOLDER})
            ]
        );
        assert_eq!(content.provider_content(true)[2]["text"], "hint");
    }
    #[test]
    fn four_legal_images_exceed_tool_limit_but_fit_user_limit() {
        let image = ContentBlock::Image {
            data: "AAAA".repeat(MAX_IMAGE_BASE64_BYTES / 4 - 1),
            mime_type: "image/png".into(),
        };
        let content = UserContent::new("caption", metadata(4), vec![image; 4]).unwrap();
        assert!(
            serde_json::to_vec(&content).unwrap().len() > crate::tool_content::MAX_CONTENT_BYTES
        );
    }
}

#[cfg(test)]
mod debug_tests {
    use super::*;
    #[test]
    fn debug_is_bounded_and_never_exposes_paths_text_or_base64() {
        let content = UserContent {
            skills: Vec::new(),
            attachments: vec![crate::attachments::AttachmentRecord {
                id: uuid::Uuid::new_v4().to_string(),
                path: "/private/owner-image.gif".into(),
                sha256: "a".repeat(64),
                bytes: 3,
                mime_type: "image/gif".into(),
            }],
            blocks: vec![
                ContentBlock::Text {
                    text: "private caption".into(),
                },
                ContentBlock::Image {
                    data: "SECRET".repeat(700_000),
                    mime_type: "image/gif".into(),
                },
            ],
        };
        let rendered = format!("{content:?}");
        assert!(rendered.len() < 400);
        for private in ["SECRET", "private caption", "owner-image", "/private/"] {
            assert!(!rendered.contains(private));
        }
        assert!(rendered.contains("image/gif"));
        assert!(rendered.contains("4200000"));
    }
}

#[cfg(test)]
mod request_budget_tests {
    use super::*;
    #[test]
    fn user_image_aggregate_wire_bound_rejects_before_allocating_oversized_projection() {
        let image = ContentBlock::Image {
            data: "AAAA".repeat(MAX_IMAGE_BASE64_BYTES / 4 - 1),
            mime_type: "image/png".into(),
        };
        let attachments = (0..4)
            .map(|_| crate::attachments::AttachmentRecord {
                id: uuid::Uuid::new_v4().to_string(),
                path: "/fixture.png".into(),
                sha256: "a".repeat(64),
                bytes: 3,
                mime_type: "image/png".into(),
            })
            .collect();
        let content =
            std::sync::Arc::new(UserContent::new("", attachments, vec![image; 4]).unwrap());
        let make = |id: &str| crate::Message {
            task_root_id: None,
            id: id.into(),
            role: "user".into(),
            text: String::new(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "complete".into(),
            usage: Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
            user_content: Some(content.clone()),
        };
        let profile:crate::Profile=serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:9","contextWindow":32000,"maxOutputTokens":4096,"input":["text","image"]})).unwrap();
        assert!(crate::tool_history::project(&[make("one")], &profile).is_ok());
        let error =
            crate::tool_history::project(&[make("one"), make("two")], &profile).unwrap_err();
        assert!(error.to_string().contains("32 MiB"));
    }
}

#[cfg(test)]
mod admission_bounds_tests {
    use super::*;

    fn records(count: usize) -> Vec<crate::attachments::AttachmentRecord> {
        (0..count)
            .map(|_| crate::attachments::AttachmentRecord {
                id: uuid::Uuid::new_v4().to_string(),
                path: "/generated/fixture.png".into(),
                sha256: "a".repeat(64),
                bytes: 3,
                mime_type: "image/png".into(),
            })
            .collect()
    }
    fn image(data: &str, mime_type: &str) -> ContentBlock {
        ContentBlock::Image {
            data: data.into(),
            mime_type: mime_type.into(),
        }
    }
    fn content(blocks: Vec<ContentBlock>) -> UserContent {
        UserContent {
            skills: Vec::new(),
            attachments: records(1),
            blocks,
        }
    }

    #[test]
    fn retained_user_image_rejects_noncanonical_base64_mime_and_strict_size_boundary() {
        for invalid in ["", "A===", "YR==", "YWJj\n", "YWJj_", "YQ"] {
            assert!(
                content(vec![image(invalid, "image/png")])
                    .validate()
                    .is_err()
            );
        }
        for mime in ["image/bmp", "IMAGE/PNG", "image/png; charset=utf-8"] {
            assert!(content(vec![image("YWJj", mime)]).validate().is_err());
        }
        let maximum = "AAAA".repeat(MAX_IMAGE_BASE64_BYTES / 4);
        assert!(
            content(vec![image(&maximum, "image/png")])
                .validate()
                .is_err()
        );
        assert!(
            content(vec![image(&maximum[..maximum.len() - 4], "image/png")])
                .validate()
                .is_ok()
        );
    }

    #[test]
    fn retained_user_content_requires_metadata_and_bounded_text_image_and_block_counts() {
        let valid = image("YWJj", "image/png");
        assert!(content(Vec::new()).validate().is_err());
        assert!(
            content(vec![valid.clone(), valid.clone()])
                .validate()
                .is_err()
        );
        let mut missing = content(vec![valid.clone()]);
        missing.attachments.clear();
        assert!(missing.validate().is_err());
        let texts = |count| {
            vec![
                ContentBlock::Text {
                    text: "hint".into()
                };
                count
            ]
        };
        assert!(content(texts(9)).validate().is_ok());
        assert!(content(texts(10)).validate().is_err());
        assert!(
            content(vec![ContentBlock::Text {
                text: "a".repeat(262_144)
            }])
            .validate()
            .is_ok()
        );
        assert!(
            content(vec![ContentBlock::Text {
                text: "a".repeat(262_145)
            }])
            .validate()
            .is_err()
        );
        let mut too_many = content(vec![valid; 5]);
        too_many.attachments = records(5);
        assert!(too_many.validate().is_err());
    }

    #[test]
    fn serialized_user_envelope_is_inclusive_and_counts_json_escaping() {
        let image = image(&"AAAA".repeat(MAX_IMAGE_BASE64_BYTES / 4 - 1), "image/png");
        let mut value = UserContent {
            skills: Vec::new(),
            attachments: records(4),
            blocks: vec![image; 4],
        };
        value.blocks.extend(vec![
            ContentBlock::Text {
                text: "a".repeat(262_144)
            };
            4
        ]);
        value.blocks.push(ContentBlock::Text {
            text: String::new(),
        });
        let remaining = MAX_USER_CONTENT_BYTES - serde_json::to_vec(&value).unwrap().len();
        let escaped = "\0".repeat(remaining / 6) + &"a".repeat(remaining % 6);
        assert!(escaped.len() <= 262_144);
        value.blocks[8] = ContentBlock::Text { text: escaped };
        assert_eq!(
            serde_json::to_vec(&value).unwrap().len(),
            MAX_USER_CONTENT_BYTES
        );
        assert!(value.validate().is_ok());
        let ContentBlock::Text { text } = &mut value.blocks[8] else {
            unreachable!()
        };
        text.push('a');
        assert_eq!(
            serde_json::to_vec(&value).unwrap().len(),
            MAX_USER_CONTENT_BYTES + 1
        );
        let error = value.validate().unwrap_err();
        assert!(error.to_string().contains("20 MiB"));
    }
}
