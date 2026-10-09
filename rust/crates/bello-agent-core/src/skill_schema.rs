//! Reject even empty new fields under older version markers before rewriting.
//! IgnoredAny checks field presence without copying retained bodies or media.
use crate::{Result, invalid};
use serde::Deserialize;
fn present<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<bool, D::Error> {
    serde::de::IgnoredAny::deserialize(deserializer)?;
    Ok(true)
}
#[derive(Default, Deserialize)]
struct ContentPresence {
    #[serde(default, deserialize_with = "present")]
    skills: bool,
}
#[derive(Default, Deserialize)]
struct ToolPresence {
    #[serde(default, deserialize_with = "present")]
    duration_us: bool,
    #[serde(default, deserialize_with = "present")]
    tool_batch_timing: bool,
}
#[derive(Default, Deserialize)]
struct RowPresence {
    #[serde(default)]
    tool_record: Option<ToolPresence>,
    #[serde(default, deserialize_with = "present")]
    task_root_id: bool,
    #[serde(default, deserialize_with = "present")]
    frozen_skills: bool,
    #[serde(default)]
    user_content: Option<ContentPresence>,
}
impl RowPresence {
    fn any(&self) -> bool {
        self.task_root_id
            || self.frozen_skills
            || self
                .user_content
                .as_ref()
                .is_some_and(|content| content.skills)
    }
}
#[derive(Deserialize)]
struct SnapshotPresence {
    #[serde(default, deserialize_with = "present")]
    tool_timing: bool,
    version: u32,
    #[serde(default)]
    messages: Vec<RowPresence>,
    #[serde(default)]
    pending: Vec<RowPresence>,
    #[serde(default)]
    active: Option<RowPresence>,
    #[serde(default)]
    retry: Option<RowPresence>,
}
pub(crate) fn parse_snapshot(bytes: &[u8]) -> Result<crate::Session> {
    parse_snapshot_cancelled(bytes, None)
}
pub(crate) fn parse_snapshot_cancelled(
    bytes: &[u8],
    cancel: Option<&dyn crate::sidebar_search::CancellationProbe>,
) -> Result<crate::Session> {
    let presence: SnapshotPresence = crate::inspection::parse(bytes, cancel)?;
    if presence.version < 9
        && (presence.tool_timing
            || presence.messages.iter().any(|row| {
                row.tool_record
                    .as_ref()
                    .is_some_and(|record| record.duration_us || record.tool_batch_timing)
            }))
    {
        return Err(invalid(
            "Tool timing fields require Rust snapshot version 9",
        ));
    }
    if presence.version < 8
        && presence
            .messages
            .iter()
            .chain(&presence.pending)
            .chain(presence.active.iter())
            .chain(presence.retry.iter())
            .any(RowPresence::any)
    {
        return Err(invalid("Skill fields require Rust snapshot version 8"));
    }
    crate::inspection::parse(bytes, cancel)
}
pub(crate) fn old_catalog_record_has_skills(
    text: &str,
) -> std::result::Result<bool, serde_json::Error> {
    Ok(serde_json::from_str::<ContentPresence>(text)?.skills)
}
