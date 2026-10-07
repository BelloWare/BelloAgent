//! Attachment normalization reuses the native read-image processor. Unlike a
//! tool-result envelope, each hint follows its own image in original order.
use super::read::ImageResult;
use crate::{Error, Result, invalid, tool_content::ContentBlock};
use tokio_util::sync::CancellationToken;

pub(crate) fn process(
    bytes: &[u8],
    mime: &str,
    token: &CancellationToken,
) -> Result<Vec<ContentBlock>> {
    let result = super::read_image::process(bytes, mime, token).map_err(|error| match error {
        super::ToolError::Cancelled => Error::Cancelled,
        _ => invalid(error.to_string()),
    })?;
    Ok(match result {
        ImageResult::Image {
            data,
            mime_type,
            hints,
        } => {
            let mut blocks = vec![ContentBlock::Image { data, mime_type }];
            if !hints.is_empty() {
                blocks.push(ContentBlock::Text {
                    text: hints.join("\n"),
                });
            }
            blocks
        }
        ImageResult::Omitted(text) => vec![ContentBlock::Text { text }],
    })
}

/// A known generated one-pixel GIF only. This is a fixture normalizer, never a
/// portable ImageIO substitute. Runtime admission additionally requires explicit
/// synthetic saved-connection provenance and numeric loopback with fixed key.
#[cfg(any(test, feature = "synthetic-authority"))]
pub(crate) fn generated_fixture(
    bytes: &[u8],
    mime: &str,
    token: &CancellationToken,
) -> Result<Vec<ContentBlock>> {
    crate::attachments::cancelled(token)?;
    const GIF: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01L\x00;";
    if bytes != GIF || mime != "image/gif" {
        return Err(invalid(
            "Synthetic image preparation accepts only the documented generated fixture; native normalization requires macOS",
        ));
    }
    Ok(vec![ContentBlock::Image {
        data: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==".into(),
        mime_type: "image/gif".into(),
    }])
}
