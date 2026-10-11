//! Per-chat model and reasoning choices: Swift ModelCatalog.swift's
//! `ThinkingLevel`, `TurnOverrides`, `ChatModelDefaults` and
//! `applyModelChoice`, and MetadataStore.swift's `saveChatModelChoice`.
//!
//! A choice only shapes the next submissions of its chat; the saved
//! connection itself is never rewritten. The chat's choice and the
//! connection's next-chat default commit together in one file write, so a
//! storage failure cannot leave the picker and new chats disagreeing.
use crate::{Profile, Result, Submission, invalid, model_catalog::ModelDescriptor};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

/// Swift `TurnOverrides.maximumModelLength`.
pub const MAXIMUM_MODEL_LENGTH: usize = 200;
/// Bounds the sidecar: one entry per chat plus one per connection.
const MAXIMUM_ENTRIES: usize = 8192;
const MAXIMUM_FILE_BYTES: u64 = 4 * 1024 * 1024;

/// Reasoning effort levels (contract H3). Profile default is stored as no
/// value; `Default` is sent as the wire `default`, which leaves effort to the
/// model.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThinkingLevel {
    ProfileDefault,
    Default,
    Off,
    Minimal,
    Low,
    Medium,
    High,
    XHigh,
    Max,
}
impl ThinkingLevel {
    pub const ALL: [Self; 9] = [
        Self::ProfileDefault,
        Self::Default,
        Self::Off,
        Self::Minimal,
        Self::Low,
        Self::Medium,
        Self::High,
        Self::XHigh,
        Self::Max,
    ];
    pub fn raw(self) -> &'static str {
        match self {
            Self::ProfileDefault => "profile-default",
            Self::Default => "default",
            Self::Off => "off",
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::XHigh => "xhigh",
            Self::Max => "max",
        }
    }
    pub fn from_raw(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|level| level.raw() == value)
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::ProfileDefault => "Profile default",
            Self::Default => "Model default",
            Self::Off => "Off",
            Self::Minimal => "Minimal",
            Self::Low => "Low",
            Self::Medium => "Medium",
            Self::High => "High",
            Self::XHigh => "Extra high",
            Self::Max => "Max",
        }
    }
    /// Short text for the composer pill, e.g. "Effort · medium".
    pub fn pill_label(self) -> String {
        match self {
            Self::ProfileDefault => "Effort · connection default".into(),
            Self::Default => "Effort · model decides".into(),
            other => format!("Effort · {}", other.raw()),
        }
    }
    /// The chat's level: its stored wire level, else the profile default.
    pub fn of(choice: &ModelChoice) -> Self {
        choice
            .thinking_level
            .as_deref()
            .and_then(Self::from_raw)
            .unwrap_or(Self::ProfileDefault)
    }
}

/// A trimmed model alias within the 1…200 character wire limit, or None.
pub fn normalized_model(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    // Also within the 256 bytes a profile's model id may take.
    (!trimmed.is_empty()
        && trimmed.chars().count() <= MAXIMUM_MODEL_LENGTH
        && trimmed.len() <= 256
        && !trimmed.bytes().any(|byte| byte < 32 || byte == 127))
    .then(|| trimmed.to_owned())
}
/// A wire level, including explicit `default`, or None for the profile setting.
pub fn normalized_thinking_level(value: Option<&str>) -> Option<String> {
    let level = ThinkingLevel::from_raw(value?)?;
    (level != ThinkingLevel::ProfileDefault).then(|| level.raw().to_owned())
}

/// One chat's choice, or one connection's next-chat default. None values
/// mean the connection's own model and effort.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelChoice {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<String>,
}
impl ModelChoice {
    fn normalized(self) -> Self {
        Self {
            model: normalized_model(self.model.as_deref()),
            thinking_level: normalized_thinking_level(self.thinking_level.as_deref()),
        }
    }
    /// Swift `applyModelChoice`: the chosen model (None for the connection's
    /// own), and an effort the effective model offers. A catalog that says the
    /// model takes no effort, or not the one in force, leaves it to the model.
    pub fn choosing_model(
        &self,
        model: Option<&str>,
        profile: &Profile,
        descriptor: Option<&ModelDescriptor>,
    ) -> Self {
        let mut next = Self {
            model: normalized_model(model),
            thinking_level: self.thinking_level.clone(),
        };
        let effective = next
            .thinking_level
            .clone()
            .unwrap_or_else(|| profile.thinking_level.clone());
        if let Some(efforts) = descriptor.and_then(|d| d.reasoning.as_ref())
            && (efforts.is_empty() || effective != "default" && !efforts.contains(&effective))
        {
            next.thinking_level = Some(ThinkingLevel::Default.raw().into());
        }
        next
    }
    pub fn choosing_level(&self, level: ThinkingLevel) -> Self {
        Self {
            model: self.model.clone(),
            thinking_level: normalized_thinking_level(Some(level.raw())),
        }
    }
}

/// Efforts the effective model accepts per the catalog; every level when
/// unknown (Swift `ModelSwitchPills.offeredLevels`).
pub fn offered_levels(
    profile: &Profile,
    descriptor: Option<&ModelDescriptor>,
) -> Vec<ThinkingLevel> {
    let Some(descriptor) = descriptor else {
        return ThinkingLevel::ALL.to_vec();
    };
    let Some(efforts) = &descriptor.reasoning else {
        return ThinkingLevel::ALL.to_vec();
    };
    let mut levels: Vec<_> = ThinkingLevel::ALL
        .into_iter()
        .filter(|level| {
            matches!(
                level,
                ThinkingLevel::ProfileDefault | ThinkingLevel::Default
            ) || efforts.iter().any(|effort| effort == level.raw())
        })
        .collect();
    let inherited = profile.thinking_level.as_str();
    if efforts.is_empty() && profile.reasoning
        || inherited != "default" && !efforts.iter().any(|effort| effort == inherited)
    {
        levels.retain(|level| *level != ThinkingLevel::ProfileDefault);
    }
    levels
}

/// Swift `TurnOverrides.params`: what a submission carries. The app supplies
/// the chat's choice on the item; anything not chosen is the connection's.
pub(crate) fn capture(item: &mut Submission, profile: &Profile) -> Result<()> {
    let model = match item.model.take() {
        Some(model) => normalized_model(Some(&model))
            .ok_or_else(|| invalid("Enter a model alias of 1 to 200 printable characters."))?,
        None => profile.model_id.clone(),
    };
    let effort = match item.effort.take() {
        Some(effort) => normalized_thinking_level(Some(&effort))
            .ok_or_else(|| invalid(format!("Unknown reasoning level “{effort}”.")))?,
        None => profile.thinking_level.clone(),
    };
    item.model = Some(model);
    item.effort = Some(effort);
    Ok(())
}

/// The model a submission would use for image checks before it is captured.
pub fn submission_with(choice: &ModelChoice) -> Submission {
    let mut item = Submission::new(String::new(), crate::Lane::FollowUp);
    item.model.clone_from(&choice.model);
    item.effort.clone_from(&choice.thinking_level);
    item
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    #[serde(default)]
    chats: BTreeMap<String, ModelChoice>,
    /// Keyed by saved connection id (Swift `ChatModelDefaults` by profile).
    #[serde(default)]
    defaults: BTreeMap<String, ModelChoice>,
}

/// The project's model choices, beside its chats. A missing file is empty;
/// an unreadable one is reported and never overwritten.
pub struct ModelChoiceStore {
    path: PathBuf,
    state: Mutex<std::result::Result<Stored, String>>,
}
impl ModelChoiceStore {
    pub fn open(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref().to_owned();
        let state = Self::read(&path);
        Self {
            path,
            state: Mutex::new(state),
        }
    }
    fn read(path: &Path) -> std::result::Result<Stored, String> {
        let unreadable = |_| {
            "Saved model choices are unreadable; choices are not saved until the file is repaired."
                .to_owned()
        };
        match fs::metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Stored {
                    version: 1,
                    ..Default::default()
                });
            }
            Err(error) => return Err(unreadable(error.to_string())),
            Ok(meta) if meta.len() > MAXIMUM_FILE_BYTES => return Err(unreadable(String::new())),
            Ok(_) => {}
        }
        let bytes = fs::read(path).map_err(|e| unreadable(e.to_string()))?;
        let stored: Stored =
            serde_json::from_slice(&bytes).map_err(|e| unreadable(e.to_string()))?;
        if stored.version != 1 || stored.chats.len() + stored.defaults.len() > MAXIMUM_ENTRIES {
            return Err(unreadable(String::new()));
        }
        Ok(Stored {
            version: 1,
            chats: stored
                .chats
                .into_iter()
                .map(|(id, choice)| (id, choice.normalized()))
                .collect(),
            defaults: stored
                .defaults
                .into_iter()
                .map(|(id, choice)| (id, choice.normalized()))
                .collect(),
        })
    }
    /// Why choices cannot be saved, if the file was unreadable.
    pub fn error(&self) -> Option<String> {
        self.state.lock().ok()?.as_ref().err().cloned()
    }
    /// The chat's choice; connection defaults when it has none.
    pub fn chat(&self, chat: &str) -> ModelChoice {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.as_ref().ok()?.chats.get(chat).cloned())
            .unwrap_or_default()
    }
    pub fn has_chat(&self, chat: &str) -> bool {
        self.state
            .lock()
            .is_ok_and(|state| state.as_ref().is_ok_and(|s| s.chats.contains_key(chat)))
    }
    /// The last deliberate choice made on a connection, for its next new chat.
    pub fn default_for(&self, connection: &str) -> Option<ModelChoice> {
        self.state
            .lock()
            .ok()?
            .as_ref()
            .ok()?
            .defaults
            .get(connection)
            .cloned()
    }
    /// A new chat starts from its connection's remembered choice. Nothing is
    /// written: the chat keeps it in memory until a choice is saved.
    pub fn adopt_defaults(&self, chat: &str, connection: Option<&str>) -> ModelChoice {
        if self.has_chat(chat) {
            return self.chat(chat);
        }
        connection
            .and_then(|connection| self.default_for(connection))
            .unwrap_or_default()
    }
    /// Saves the chat's choice and, for a chat on a saved connection, makes it
    /// that connection's next-chat default, in one atomic write. Re-choosing
    /// an unchanged option still updates the default (Swift).
    pub fn save(&self, chat: &str, connection: Option<&str>, choice: ModelChoice) -> Result<()> {
        if chat.is_empty()
            || chat.len() > 128
            || connection.is_some_and(|c| c.is_empty() || c.len() > 128)
        {
            return Err(invalid("This chat cannot save a model choice."));
        }
        let choice = choice.normalized();
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("Model choices are unavailable."))?;
        state.as_ref().map_err(|e| invalid(e.clone()))?;
        // Another window on the same chats may have saved since: start from
        // what is on disk, so its choices are kept (an unreadable file is
        // never overwritten).
        let mut next = Self::read(&self.path).map_err(invalid)?;
        next.chats.insert(chat.to_owned(), choice.clone());
        if let Some(connection) = connection {
            next.defaults.insert(connection.to_owned(), choice);
        }
        if next.chats.len() + next.defaults.len() > MAXIMUM_ENTRIES {
            return Err(invalid("Too many saved model choices."));
        }
        self.write(&next)?;
        *state = Ok(next);
        Ok(())
    }
    /// Forgets a deleted chat's choice. Connection defaults stay.
    pub fn forget(&self, chat: &str) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("Model choices are unavailable."))?;
        if state.is_err() {
            return Ok(());
        }
        let mut next = Self::read(&self.path).map_err(invalid)?;
        if !next.chats.contains_key(chat) {
            return Ok(());
        }
        next.chats.remove(chat);
        self.write(&next)?;
        *state = Ok(next);
        Ok(())
    }
    fn write(&self, stored: &Stored) -> Result<()> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| invalid("Model choices have no folder."))?;
        fs::create_dir_all(parent)?;
        let temp = parent.join(format!(".chat-models-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> std::io::Result<()> {
            let mut file = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&temp)?;
            file.write_all(&serde_json::to_vec_pretty(stored)?)?;
            file.sync_all()?;
            fs::rename(&temp, &self.path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        Ok(result?)
    }
}

#[cfg(test)]
#[path = "model_choice_tests.rs"]
mod tests;
