//! Current-project organization metadata. The enclosing catalog's canonical root
//! is the scope; topics never grant authority or touch a session store.
use super::*;
use unicode_segmentation::UnicodeSegmentation;

const MAX_TOPICS: usize = 512;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TopicRecord {
    pub id: String,
    pub title: String,
    pub created_at: u64,
    pub expanded: bool,
    pub revision: u64,
}
impl TopicRecord {
    pub fn normalized_title(title: &str) -> Result<String> {
        // Foundation CharacterSet.whitespacesAndNewlines includes U+200B;
        // Rust's White_Space property does not. U+FEFF is not whitespace.
        let normalized = title
            .split(|c: char| c.is_whitespace() || c == '\u{200b}')
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if normalized.is_empty() {
            return Err(invalid("Enter a title for this topic."));
        }
        Ok(normalized.graphemes(true).take(120).collect())
    }
    pub fn sidebar_cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.created_at
            .cmp(&other.created_at)
            .then_with(|| self.id.cmp(&other.id))
    }
    fn validate(&self) -> Result<()> {
        if Uuid::parse_str(&self.id).is_err() || Self::normalized_title(&self.title)? != self.title
        {
            return Err(invalid("Invalid Rust topic catalog record"));
        }
        Ok(())
    }
}
impl WorkspaceSnapshot {
    /// Unknown references are displayed at project top level. Do not filter out
    /// the retained chat merely because its old topic metadata is unavailable.
    pub fn effective_topic_id<'a>(&'a self, chat: &ChatRecord) -> Option<&'a str> {
        let id = chat.topic_id.as_deref()?;
        self.topics
            .iter()
            .find(|topic| topic.id == id)
            .map(|topic| topic.id.as_str())
    }
    pub(super) fn validate_topics(&self) -> Result<()> {
        if self.topics.len() > MAX_TOPICS {
            return Err(invalid(
                "This development workspace supports up to 512 topics",
            ));
        }
        if self.version < 10
            && (!self.topics.is_empty()
                || self
                    .chats
                    .iter()
                    .any(|chat| chat.topic_id.is_some() || chat.topic_revision != 0))
        {
            return Err(invalid("Topics require Rust workspace catalog version 10"));
        }
        let mut ids = std::collections::HashSet::new();
        for topic in &self.topics {
            topic.validate()?;
            if !ids.insert(&topic.id) {
                return Err(invalid("Duplicate topic identity"));
            }
        }
        Ok(())
    }
}
impl WorkspaceStore {
    pub fn create_topic(&mut self, title: &str) -> Result<TopicRecord> {
        self.ensure_certain()?;
        let topic = TopicRecord {
            id: Uuid::new_v4().to_string(),
            title: TopicRecord::normalized_title(title)?,
            created_at: organization_timestamp(),
            expanded: true,
            revision: 0,
        };
        self.transact(|state| {
            state.topics.push(topic.clone());
            Ok(topic)
        })
    }
    pub fn rename_topic(
        &mut self,
        id: &str,
        title: &str,
        expected_revision: u64,
    ) -> Result<TopicRecord> {
        self.ensure_certain()?;
        let title = TopicRecord::normalized_title(title)?;
        let topic = self.checked_topic(id, expected_revision)?;
        if topic.title == title {
            return Ok(topic.clone());
        }
        self.transact(|state| {
            let topic = state
                .topics
                .iter_mut()
                .find(|topic| topic.id == id)
                .expect("checked topic");
            topic.title = title;
            topic.revision = next_revision(topic.revision)?;
            Ok(topic.clone())
        })
    }
    pub fn set_topic_expanded(
        &mut self,
        id: &str,
        expanded: bool,
        expected_revision: u64,
    ) -> Result<TopicRecord> {
        self.ensure_certain()?;
        let topic = self.checked_topic(id, expected_revision)?;
        if topic.expanded == expanded {
            return Ok(topic.clone());
        }
        self.transact(|state| {
            let topic = state
                .topics
                .iter_mut()
                .find(|topic| topic.id == id)
                .expect("checked topic");
            topic.expanded = expanded;
            topic.revision = next_revision(topic.revision)?;
            Ok(topic.clone())
        })
    }
    /// Remove organization only; members, drafts, selection and all session files
    /// remain. Increment membership fences so delayed moves cannot resurrect it.
    pub fn delete_topic(&mut self, id: &str, expected_revision: u64) -> Result<WorkspaceSnapshot> {
        self.ensure_certain()?;
        self.checked_topic(id, expected_revision)?;
        self.transact(|state| {
            state.topics.retain(|topic| topic.id != id);
            for chat in &mut state.chats {
                if chat.topic_id.as_deref() == Some(id) {
                    chat.topic_id = None;
                    chat.topic_revision = next_revision(chat.topic_revision)?;
                }
            }
            Ok(())
        })?;
        Ok(self.snapshot())
    }
    /// Patch membership against the writer's latest row. A pending row and its
    /// draft are materialized in this same catalog commit, with no checkpoint or
    /// journal creation. Existing unrelated metadata and draft always win.
    /// Explicit moves expand their destination in the same durable transaction.
    pub fn move_chat_to_topic(
        &mut self,
        record: ChatRecord,
        draft: DraftRecord,
        destination: Option<&str>,
        expected_membership_revision: u64,
    ) -> Result<ChatRecord> {
        self.ensure_certain()?;
        if let Some(id) = destination
            && !self.state.topics.iter().any(|topic| topic.id == id)
        {
            return Err(invalid("Choose a topic in the same project."));
        }
        if let Some(existing) = self.state.chats.iter().find(|chat| chat.id == record.id) {
            if existing.snapshot != record.snapshot {
                return Err(invalid("Chat identity is already registered differently"));
            }
            if existing.topic_revision != expected_membership_revision {
                return Err(invalid("Chat topic membership changed before this move"));
            }
            if existing.topic_id.as_deref() == destination
                && destination.is_none_or(|id| {
                    self.state
                        .topics
                        .iter()
                        .any(|topic| topic.id == id && topic.expanded)
                })
            {
                return Ok(existing.clone());
            }
        } else {
            if expected_membership_revision != 0 || record.topic_revision != 0 {
                return Err(invalid("Pending chat topic membership is stale"));
            }
            draft.validate()?;
        }
        self.transact(|state| {
            let existing = state.chats.iter().position(|chat| chat.id == record.id);
            let index = if let Some(index) = existing {
                index
            } else {
                state.drafts.insert(record.id.clone(), draft);
                state.chats.push(record.clone());
                state.chats.len() - 1
            };
            let chat = &mut state.chats[index];
            if chat.sidebar_order.is_none() {
                chat.sidebar_order = record.sidebar_order;
            }
            if existing.is_none() || chat.topic_id.as_deref() != destination {
                chat.topic_id = destination.map(str::to_owned);
                chat.topic_revision = next_revision(chat.topic_revision)?;
            }
            let saved = chat.clone();
            if let Some(id) = destination {
                let topic = state
                    .topics
                    .iter_mut()
                    .find(|topic| topic.id == id)
                    .expect("checked destination");
                if !topic.expanded {
                    topic.expanded = true;
                    topic.revision = next_revision(topic.revision)?;
                }
            }
            Ok(saved)
        })
    }
    fn checked_topic(&self, id: &str, expected_revision: u64) -> Result<&TopicRecord> {
        let topic = self
            .state
            .topics
            .iter()
            .find(|topic| topic.id == id)
            .ok_or_else(|| invalid("This topic is no longer available."))?;
        if topic.revision != expected_revision {
            return Err(invalid("This topic changed before the operation"));
        }
        Ok(topic)
    }
}
fn next_revision(revision: u64) -> Result<u64> {
    revision
        .checked_add(1)
        .ok_or_else(|| invalid("Topic revision overflow"))
}
