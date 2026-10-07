//! Typed selection and retained facts. These values do not grant tools or execute
//! scripts. Only a controller-owned fresh resource freeze authorizes admission.
use crate::{Result, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fmt, path::Path};
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_SKILLS: usize = 8;
pub const MAX_RECOVERED_SKILLS: usize = 16;
pub const MAX_SKILL_FILE_BYTES: usize = 262_144;
pub const MAX_SKILL_SOURCE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_SKILL_ARGUMENT_BYTES: usize = 16_384;
pub const MAX_SKILL_PATH_BYTES: usize = 65_536;
pub const MAX_RAW_TEXT_BYTES: usize = 262_144;
// 2 MiB bodies + 128 KiB arguments + 256 KiB raw text, plus eight pairs
// of paths at their 64 KiB bound with worst-case six-byte JSON escaping.
pub const MAX_EXPANDED_TEXT_BYTES: usize = 10 * 1024 * 1024;
pub const SELECTION_PREFIX: &str = "Current explicit selection IDs: ";
pub const SELECTION_POLICY: &str = "Only the latest user message's own explicit skill selection authorizes an explicit-only skill: that message lists it as \"Current explicit selection IDs: …\" after its skill blocks, and a message without that line selects none. Skills selected in earlier user messages are historical context, not a new authorization.";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SkillIntent {
    #[serde(rename = "picker")]
    Picker,
    #[serde(rename = "leading-command")]
    LeadingCommand,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SkillPolicy {
    ImplicitAllowed,
    ExplicitOnly,
    Disabled,
    NeedsAttention,
}
impl SkillPolicy {
    pub fn usable(self) -> bool {
        matches!(self, Self::ImplicitAllowed | Self::ExplicitOnly)
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ImplicitAllowed => "implicitAllowed",
            Self::ExplicitOnly => "explicitOnly",
            Self::Disabled => "disabled",
            Self::NeedsAttention => "needsAttention",
        }
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillSelection {
    pub id: String,
    pub content_hash: String,
    pub metadata_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub arguments: String,
    pub intent: SkillIntent,
}
impl SkillSelection {
    pub fn validate(&self) -> Result<()> {
        if !valid_hash(&self.id)
            || !valid_hash(&self.content_hash)
            || !valid_hash(&self.metadata_hash)
            || self.arguments.len() > MAX_SKILL_ARGUMENT_BYTES
        {
            return Err(invalid("Invalid retained skill selection"));
        }
        Ok(())
    }
}
impl fmt::Debug for SkillSelection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SkillSelection")
            .field("argument_bytes", &self.arguments.len())
            .field("intent", &self.intent)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillChip {
    pub selection: SkillSelection,
    pub name: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    pub scope: String,
    pub policy: SkillPolicy,
    pub source_root: String,
}
impl SkillChip {
    pub fn validate(&self) -> Result<()> {
        self.selection.validate()?;
        validate_display(
            &self.name,
            &self.path,
            Some(&self.description),
            Some(&self.scope),
        )?;
        validate_path(&self.source_root)?;
        if self.selection.id != hash(&self.path) {
            return Err(invalid("Invalid retained skill chip identity"));
        }
        Ok(())
    }
}
impl fmt::Debug for SkillChip {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SkillChip")
            .field("selection", &self.selection)
            .field("policy", &self.policy)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FrozenSkill {
    pub id: String,
    pub name: String,
    pub path: String,
    pub base_dir: String,
    pub body: String,
    /// Rust persistence integrity for stripped body bytes, separate from the
    /// full-source content hash and source-formula authorization metadata hash.
    pub body_hash: String,
    pub content_hash: String,
    pub metadata_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub arguments: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<SkillPolicy>,
}
impl FrozenSkill {
    pub fn selection(&self) -> SkillSelection {
        SkillSelection {
            id: self.id.clone(),
            content_hash: self.content_hash.clone(),
            metadata_hash: self.metadata_hash.clone(),
            arguments: self.arguments.clone(),
            intent: SkillIntent::Picker,
        }
    }
    pub fn recorded(&self) -> RecordedSkillUse {
        RecordedSkillUse {
            selection: self.selection(),
            name: self.name.clone(),
            path: self.path.clone(),
            description: self.description.clone(),
            scope: self.scope.clone(),
            policy: self.policy,
        }
    }
    pub fn validate(&self) -> Result<()> {
        if !valid_hash(&self.id)
            || !valid_hash(&self.content_hash)
            || !valid_hash(&self.metadata_hash)
            || !valid_hash(&self.body_hash)
            || self.arguments.len() > MAX_SKILL_ARGUMENT_BYTES
            || self.body.len() > MAX_SKILL_FILE_BYTES
        {
            return Err(invalid("Invalid frozen skill bounds or hashes"));
        }
        validate_display(
            &self.name,
            &self.path,
            self.description.as_deref(),
            self.scope.as_deref(),
        )?;
        validate_path(&self.base_dir)?;
        if self.id != hash(&self.path)
            || self.body_hash != hash(&self.body)
            || self.policy.is_some_and(|p| !p.usable())
        {
            return Err(invalid("Invalid frozen skill facts"));
        }
        Ok(())
    }
    pub fn expand(&self, turn_id: &str) -> String {
        format!(
            "Explicit user skill selection {}, turn {turn_id}, source {}, SHA256 {}. Relative references use {}. This grants no additional tools.\n{}\nSkill arguments: {}",
            quote(&self.name),
            quote(&self.path),
            self.content_hash,
            quote(&self.base_dir),
            self.body,
            self.arguments
        )
    }
}
impl fmt::Debug for FrozenSkill {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FrozenSkill")
            .field("body_bytes", &self.body.len())
            .field("argument_bytes", &self.arguments.len())
            .field("policy", &self.policy)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordedSkillUse {
    pub selection: SkillSelection,
    pub name: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<SkillPolicy>,
}
impl RecordedSkillUse {
    pub fn validate(&self) -> Result<()> {
        self.selection.validate()?;
        validate_display(
            &self.name,
            &self.path,
            self.description.as_deref(),
            self.scope.as_deref(),
        )?;
        if self.selection.id != hash(&self.path) || self.policy.is_some_and(|p| !p.usable()) {
            return Err(invalid("Invalid recorded skill facts"));
        }
        Ok(())
    }
}
impl fmt::Debug for RecordedSkillUse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RecordedSkillUse")
            .field("selection", &self.selection)
            .field("policy", &self.policy)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SkillDependency {
    #[serde(rename = "type")]
    pub kind: String,
    pub value: String,
}
impl fmt::Debug for SkillDependency {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SkillDependency")
            .field("kind_bytes", &self.kind.len())
            .field("value_bytes", &self.value.len())
            .finish()
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct DependencySnapshot {
    pub tool_names: Vec<String>,
    pub mcp_server_names: Vec<String>,
    pub revision: String,
}
impl DependencySnapshot {
    pub fn new(
        mut tool_names: Vec<String>,
        mut mcp_server_names: Vec<String>,
        configuration_revision: &str,
    ) -> Result<Self> {
        if tool_names.len() > 4096
            || mcp_server_names.len() > 1024
            || configuration_revision.len() > 65_536
            || tool_names
                .iter()
                .chain(&mcp_server_names)
                .any(|s| s.is_empty() || s.len() > 4096 || s.contains('\0'))
        {
            return Err(invalid("Invalid dependency snapshot"));
        }
        tool_names.sort();
        tool_names.dedup();
        mcp_server_names.sort();
        mcp_server_names.dedup();
        let revision = hash(&serde_json::to_string(&(
            &tool_names,
            &mcp_server_names,
            configuration_revision,
        ))?);
        Ok(Self {
            tool_names,
            mcp_server_names,
            revision,
        })
    }
    pub fn available(&self, dependency: &SkillDependency) -> bool {
        match dependency.kind.as_str() {
            "tool" | "builtin" => self.tool_names.contains(&dependency.value),
            "mcp" => self.mcp_server_names.contains(&dependency.value),
            _ => false,
        }
    }
    pub fn validate(&self) -> Result<()> {
        if !valid_hash(&self.revision)
            || self.tool_names.len() > 4096
            || self.mcp_server_names.len() > 1024
            || self
                .tool_names
                .iter()
                .chain(&self.mcp_server_names)
                .any(|s| s.is_empty() || s.len() > 4096 || s.contains('\0'))
        {
            return Err(invalid("Invalid dependency snapshot"));
        }
        Ok(())
    }
}
impl fmt::Debug for DependencySnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DependencySnapshot")
            .field("tool_count", &self.tool_names.len())
            .field("mcp_count", &self.mcp_server_names.len())
            .field("revision", &self.revision)
            .finish()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillDescriptor {
    pub id: String,
    pub name: String,
    pub path: String,
    pub base_dir: String,
    pub source_root: String,
    pub scope: String,
    pub description: String,
    pub content_hash: String,
    pub metadata_hash: String,
    pub policy: SkillPolicy,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasons: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dependencies: Vec<SkillDependency>,
    pub source_characters: usize,
}
impl SkillDescriptor {
    pub fn selection(&self, arguments: String) -> SkillSelection {
        SkillSelection {
            id: self.id.clone(),
            content_hash: self.content_hash.clone(),
            metadata_hash: self.metadata_hash.clone(),
            arguments,
            intent: SkillIntent::Picker,
        }
    }
    pub fn chip(&self, arguments: String) -> SkillChip {
        SkillChip {
            selection: self.selection(arguments),
            name: self.name.clone(),
            path: self.path.clone(),
            description: self.description.clone(),
            scope: self.scope.clone(),
            policy: self.policy,
            source_root: self.source_root.clone(),
        }
    }
    pub fn selectable(&self, dependencies: &DependencySnapshot) -> bool {
        self.policy.usable() && self.dependencies.iter().all(|d| dependencies.available(d))
    }
    pub fn missing_dependencies<'a>(
        &'a self,
        dependencies: &DependencySnapshot,
    ) -> Vec<&'a SkillDependency> {
        self.dependencies
            .iter()
            .filter(|d| !dependencies.available(d))
            .collect()
    }
}
impl fmt::Debug for SkillDescriptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SkillDescriptor")
            .field("policy", &self.policy)
            .field("dependency_count", &self.dependencies.len())
            .field("reason_count", &self.reasons.len())
            .field("source_characters", &self.source_characters)
            .finish_non_exhaustive()
    }
}

pub fn validate_selections(values: &[SkillSelection]) -> Result<()> {
    if values.len() > MAX_SKILLS {
        return Err(invalid("At most eight unique skills may be selected"));
    }
    let mut ids = HashSet::new();
    for value in values {
        value.validate()?;
        if !ids.insert(&value.id) {
            return Err(invalid("At most eight unique skills may be selected"));
        }
    }
    Ok(())
}
pub fn validate_frozen_skills(values: &[FrozenSkill]) -> Result<()> {
    if values.len() > MAX_SKILLS {
        return Err(invalid("Too many frozen skills"));
    }
    let mut ids = HashSet::new();
    let mut bytes = 0usize;
    for value in values {
        value.validate()?;
        if !ids.insert(&value.id) {
            return Err(invalid("Duplicate frozen skill"));
        }
        bytes += value.body.len();
    }
    if bytes > MAX_SKILL_SOURCE_BYTES {
        return Err(invalid("Frozen skill bodies exceed 2 MiB"));
    }
    Ok(())
}
pub fn validate_recorded_skills(values: &[RecordedSkillUse]) -> Result<()> {
    if values.len() > MAX_SKILLS {
        return Err(invalid("Too many recorded skills"));
    }
    let mut ids = HashSet::new();
    for value in values {
        value.validate()?;
        if !ids.insert(&value.selection.id) {
            return Err(invalid("Duplicate recorded skill"));
        }
    }
    Ok(())
}
pub fn validate_chips(values: &[SkillChip], maximum: usize) -> Result<()> {
    if maximum > MAX_RECOVERED_SKILLS || values.len() > maximum {
        return Err(invalid("Too many retained skill chips"));
    }
    for (i, value) in values.iter().enumerate() {
        value.validate()?;
        if values[..i].iter().any(|v| v.selection == value.selection) {
            return Err(invalid("Duplicate retained skill selection"));
        }
    }
    Ok(())
}
/// Conflicting same-ID variants survive recovery for explicit user resolution.
pub fn restore_chips(captured: &[SkillChip], newer: &[SkillChip]) -> Result<Vec<SkillChip>> {
    let mut values = captured.to_vec();
    for value in newer {
        if !values.iter().any(|v| v.selection == value.selection) {
            values.push(value.clone());
        }
    }
    validate_chips(&values, MAX_RECOVERED_SKILLS)?;
    Ok(values)
}
pub fn user_message_text(text: &str, values: &[FrozenSkill], turn_id: &str) -> Result<String> {
    if text.len() > MAX_RAW_TEXT_BYTES {
        return Err(invalid("Raw user text exceeds 256 KiB"));
    }
    validate_frozen_skills(values)?;
    if values.is_empty() {
        return Ok(text.into());
    }
    if turn_id.is_empty() || turn_id.len() > 1024 || turn_id.chars().any(char::is_control) {
        return Err(invalid("Invalid skill turn identity"));
    }
    let mut result = String::new();
    for value in values {
        let block = value.expand(turn_id);
        append_bounded(&mut result, &block)?;
        append_bounded(&mut result, "\n\n")?;
    }
    append_bounded(&mut result, SELECTION_PREFIX)?;
    for (index, value) in values.iter().enumerate() {
        if index > 0 {
            append_bounded(&mut result, ", ")?;
        }
        append_bounded(&mut result, &value.id)?;
    }
    append_bounded(&mut result, "\n\n")?;
    append_bounded(&mut result, text)?;
    Ok(result)
}
fn append_bounded(target: &mut String, text: &str) -> Result<()> {
    if text.len() > MAX_EXPANDED_TEXT_BYTES.saturating_sub(target.len()) {
        return Err(invalid("Expanded user text exceeds 10 MiB"));
    }
    target.push_str(text);
    Ok(())
}
pub(crate) fn hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
pub(crate) fn valid_hash(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphanumeric())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
pub(crate) fn validate_path(path: &str) -> Result<()> {
    if !Path::new(path).is_absolute() || path.len() > MAX_SKILL_PATH_BYTES || path.contains('\0') {
        return Err(invalid("Invalid retained skill path"));
    }
    Ok(())
}
fn validate_display(
    name: &str,
    path: &str,
    description: Option<&str>,
    scope: Option<&str>,
) -> Result<()> {
    validate_path(path)?;
    if !valid_name(name)
        || description
            .is_some_and(|v| v.is_empty() || v.len() > 65_536 || v.graphemes(true).count() > 1024)
        || scope.is_some_and(|v| v != "project")
    {
        return Err(invalid("Invalid retained skill display facts"));
    }
    Ok(())
}
pub(crate) fn quote(text: &str) -> String {
    serde_json::to_string(text).expect("string serialization is infallible")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frozen() -> FrozenSkill {
        FrozenSkill {
            id: hash("/project/skill/SKILL.md"),
            name: "review".into(),
            path: "/project/skill/SKILL.md".into(),
            base_dir: "/project/skill".into(),
            body: "Review carefully".into(),
            body_hash: hash("Review carefully"),
            content_hash: hash("full"),
            metadata_hash: hash("metadata"),
            arguments: "literal /do-not-run".into(),
            description: Some("Review".into()),
            scope: Some("project".into()),
            policy: Some(SkillPolicy::ExplicitOnly),
        }
    }
    #[test]
    fn source_expansion_and_no_implicit_slash_selection() {
        let value = frozen();
        let text = user_message_text("typed", std::slice::from_ref(&value), "turn-1").unwrap();
        assert_eq!(
            text,
            format!(
                "{}\n\nCurrent explicit selection IDs: {}\n\ntyped",
                value.expand("turn-1"),
                value.id
            )
        );
        assert_eq!(
            user_message_text("/review", &[], "turn-2").unwrap(),
            "/review"
        );
        assert!(text.contains("This grants no additional tools."));
    }
    #[test]
    fn bounds_and_redacted_debug() {
        let mut v = frozen();
        let debug = format!("{v:?} {:?}", v.recorded());
        assert!(!debug.contains("Review carefully"));
        assert!(!debug.contains("/project"));
        assert!(!debug.contains("do-not-run"));
        v.arguments = "x".repeat(MAX_SKILL_ARGUMENT_BYTES);
        v.validate().unwrap();
        v.arguments.push('x');
        assert!(v.validate().is_err());
    }
    #[test]
    fn dependency_presence_is_not_health_or_authority() {
        let deps =
            DependencySnapshot::new(vec!["ls".into()], vec!["docs".into()], "revision").unwrap();
        for (kind, value, expected) in [
            ("builtin", "ls", true),
            ("tool", "bash", false),
            ("mcp", "docs", true),
            ("unknown", "ls", false),
        ] {
            assert_eq!(
                deps.available(&SkillDependency {
                    kind: kind.into(),
                    value: value.into()
                }),
                expected
            );
        }
    }
}
