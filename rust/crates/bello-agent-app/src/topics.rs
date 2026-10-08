//! Current-project desktop organization only. No Controller operation is called.
use crate::{
    AgentView,
    chat_organization::{CatalogOutcome, catalog_operation},
};
use bello_agent_core::workspace::{TopicRecord, WorkspaceSnapshot};
use gpui::*;

#[derive(Clone)]
pub(crate) enum TopicAction {
    Create(String),
    Rename(String, String, u64),
    Delete(String, u64),
    Expand(String, bool, u64),
    Move(String, Option<String>, u64),
}
#[derive(Clone)]
pub(crate) struct TopicWrite {
    token: uuid::Uuid,
    panel_token: Option<uuid::Uuid>,
    project: std::path::PathBuf,
    pub chat_id: Option<String>,
}
impl AgentView {
    pub(crate) fn effective_topic_id<'a>(
        &'a self,
        record: &'a bello_agent_core::workspace::ChatRecord,
    ) -> Option<&'a str> {
        record
            .topic_id
            .as_deref()
            .filter(|id| self.topics.iter().any(|topic| topic.id == *id))
    }
    pub(crate) fn topic_owns_chat(&self, id: &str) -> bool {
        self.topic_write
            .as_ref()
            .is_some_and(|write| write.chat_id.as_deref() == Some(id))
    }
    pub(crate) fn apply_topic_action(&mut self, action: TopicAction, cx: &mut Context<Self>) {
        if self.shutting_down
            || self.topic_write.is_some()
            || self.project_actions_blocked()
            || self.known_catalog_uncertainty
            || !self.connections.switches.is_empty()
            || self.connections.uncertain
        {
            self.topic_notice(
                "Finish pending workspace changes before changing topics.",
                cx,
            );
            return;
        }
        let moving = if let TopicAction::Move(id, _, revision) = &action {
            let Some(record) = self
                .records
                .iter()
                .find(|record| record.id == *id && record.topic_revision == *revision)
                .cloned()
            else {
                self.topic_notice(
                    "This chat's topic changed. Review its current location and try again.",
                    cx,
                );
                return;
            };
            if self.chat_mode_operations.contains_key(id)
                || self.connections.switches.contains_key(id)
            {
                self.topic_notice("Wait for this chat's settings change to finish.", cx);
                return;
            }
            let draft = self
                .chat_ref(id)
                .map(|chat| chat.saved_draft(cx))
                .unwrap_or_else(|| self.unloaded_drafts.get(id).cloned().unwrap_or_default());
            Some((record, draft))
        } else {
            None
        };
        let write = TopicWrite {
            token: uuid::Uuid::new_v4(),
            panel_token: self.topic_panel.as_ref().map(|panel| panel.token),
            project: self.project.clone(),
            chat_id: moving.as_ref().map(|(record, _)| record.id.clone()),
        };
        self.topic_write = Some(write.clone());
        if let Some(panel) = &mut self.topic_panel {
            panel.notice = Some("Saving topic change…".into());
            panel
                .editor
                .update(cx, |editor, cx| editor.set_read_only(true, cx));
        }
        let workspace = self.workspace.clone();
        // The background task owns the catalog Arc through physical completion;
        // closing the panel only discards presentation, never this ownership.
        let task = cx.background_executor().spawn(async move {
            catalog_operation(&workspace, |store| {
                match action {
                    TopicAction::Create(title) => {
                        store.create_topic(&title)?;
                    }
                    TopicAction::Rename(id, title, revision) => {
                        store.rename_topic(&id, &title, revision)?;
                    }
                    TopicAction::Delete(id, revision) => {
                        store.delete_topic(&id, revision)?;
                    }
                    TopicAction::Expand(id, expanded, revision) => {
                        store.set_topic_expanded(&id, expanded, revision)?;
                    }
                    TopicAction::Move(_, destination, revision) => {
                        let (record, draft) = moving.expect("move captures a record");
                        store.move_chat_to_topic(
                            record,
                            draft,
                            destination.as_deref(),
                            revision,
                        )?;
                    }
                }
                Ok(store.snapshot())
            })
        });
        cx.spawn(async move |owner, cx| {
            let outcome = task.await;
            let _ = owner.update(cx, |view, cx| view.finish_topic_write(write, outcome, cx));
        })
        .detach();
        cx.notify();
    }
    fn finish_topic_write(
        &mut self,
        write: TopicWrite,
        outcome: CatalogOutcome<WorkspaceSnapshot>,
        cx: &mut Context<Self>,
    ) {
        if !self
            .topic_write
            .as_ref()
            .is_some_and(|current| current.token == write.token && current.project == write.project)
        {
            return;
        }
        self.topic_write = None;
        if let Some(panel) = &self.topic_panel {
            panel
                .editor
                .update(cx, |editor, cx| editor.set_read_only(false, cx));
        }
        if self.project != write.project {
            return;
        }
        self.observe_catalog_uncertainty(outcome.uncertain, cx);
        match outcome.display_result() {
            Ok(snapshot)
                if snapshot.project == self.project
                    && snapshot.revision >= self.topics_revision =>
            {
                self.topics_revision = snapshot.revision;
                self.topics = snapshot.topics;
                self.topics.sort_by(TopicRecord::sidebar_cmp);
                let mut materialized = Vec::new();
                for saved in snapshot.chats {
                    // Merge only our columns. A delayed topic callback may not
                    // revert a concurrent pin, archive, draft, title or mode.
                    if let Some(record) = self
                        .records
                        .iter_mut()
                        .find(|record| record.id == saved.id && record.snapshot == saved.snapshot)
                        && saved.topic_revision >= record.topic_revision
                    {
                        record.topic_id = saved.topic_id.clone();
                        record.topic_revision = saved.topic_revision;
                    }
                    if let Some(chat) = self.chat_mut(&saved.id)
                        && chat.record.snapshot == saved.snapshot
                        && saved.topic_revision >= chat.record.topic_revision
                    {
                        chat.record.topic_id = saved.topic_id;
                        chat.record.topic_revision = saved.topic_revision;
                        if chat.pending {
                            chat.pending = false;
                            materialized.push(saved.id);
                        }
                    }
                }
                for id in materialized {
                    self.draft_changed(&id, cx);
                    if self.record.id == id {
                        self.remember_selection(cx);
                    }
                }
                if let Some(panel) = &mut self.topic_panel
                    && Some(panel.token) == write.panel_token
                {
                    panel.notice =
                        Some("Saved. Conversations and running work are unchanged.".into());
                    panel.renaming = None;
                    panel.deleting = None;
                    panel
                        .editor
                        .update(cx, |editor, cx| editor.set_text(String::new(), cx));
                }
            }
            Ok(_) => {}
            Err(error) => {
                self.topic_notice(&format!("Topic change could not be saved: {error}"), cx)
            }
        }
        cx.notify();
    }
    pub(crate) fn topic_notice(&mut self, message: &str, cx: &mut Context<Self>) {
        if let Some(panel) = &mut self.topic_panel {
            panel.notice = Some(message.into());
        } else {
            self.error = Some(message.into());
        }
        cx.notify();
    }
}

#[cfg(test)]
#[path = "topics_tests.rs"]
mod tests;
