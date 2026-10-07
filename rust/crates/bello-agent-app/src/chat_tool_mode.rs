//! The confirmed, one-way saved-chat mode transaction from WorkspaceSides.swift.
//! This is a lifecycle/metadata boundary, not a tool grant or a UI workflow.
use crate::project_host::Replacement;
use bello_agent_core::{
    Controller, Error, Result,
    session::SessionInspectionLease,
    workspace::{ChatRecord, ChatToolMode, WorkspaceStore},
};
use std::{
    future::Future,
    path::PathBuf,
    sync::{Arc, Mutex},
};

pub(crate) struct ChatModeChange {
    pub workspace: Arc<Mutex<WorkspaceStore>>,
    pub runtime: crate::saved_runtime_adapter::AppRuntime,
    pub primary: PathBuf,
    pub record: ChatRecord,
    pub controller: Option<Arc<Controller>>,
}
pub(crate) struct ChangedChatMode {
    pub record: ChatRecord,
    pub replacement: Option<Replacement>,
}
pub(crate) struct ChatModeFailure {
    pub message: String,
    pub keep_blocked: bool,
    pub uncertain: bool,
    /// A definite failed metadata write may reopen the unchanged read-only
    /// session after the old worker has joined. Old Arcs stay permanently dead.
    pub recovery: Option<Replacement>,
}
impl ChatModeFailure {
    fn before_close(message: impl ToString) -> Self {
        Self {
            message: message.to_string(),
            keep_blocked: false,
            uncertain: false,
            recovery: None,
        }
    }
    fn fenced(message: impl ToString, uncertain: bool) -> Self {
        Self {
            message: message.to_string(),
            keep_blocked: true,
            uncertain,
            recovery: None,
        }
    }
}

impl ChatModeChange {
    /// Caller has already obtained consent and checked the source's UI-only
    /// eligibility conditions. The actor and catalog are checked again here.
    pub async fn apply(self) -> std::result::Result<ChangedChatMode, ChatModeFailure> {
        self.apply_using(
            |controller| async move { controller.retire_and_wait().await },
            |store, id| store.enable_editing_after_confirmation(id),
        )
        .await
    }

    fn validate_catalog(&self, store: &WorkspaceStore) -> Result<ChatRecord> {
        if store.is_uncertain() {
            return Err(Error::PersistenceUncertain(
                "The workspace save is unconfirmed.".into(),
            ));
        }
        let snapshot = store.snapshot();
        if snapshot.project != self.primary {
            return Err(Error::Invalid("The workspace identity changed.".into()));
        }
        snapshot
            .chats
            .into_iter()
            .find(|chat| {
                chat.id == self.record.id
                    && chat.snapshot == self.record.snapshot
                    && chat.connection_id == self.record.connection_id
                    && chat.tool_mode == ChatToolMode::ReadOnly
            })
            .ok_or_else(|| {
                Error::Invalid("This saved read-only chat is no longer eligible.".into())
            })
    }

    fn reopen(&self, record: &ChatRecord) -> Result<Option<Replacement>> {
        let Some(previous) = &self.controller else {
            return Ok(None);
        };
        let controller = self.runtime.reopen(record, previous)?;
        Ok(Some(Replacement {
            id: self.record.id.clone(),
            previous: previous.clone(),
            controller,
        }))
    }

    async fn apply_using<F: Future<Output = Result<()>>>(
        self,
        close: impl FnOnce(Arc<Controller>) -> F,
        save: impl FnOnce(&mut WorkspaceStore, &str) -> Result<ChatRecord>,
    ) -> std::result::Result<ChangedChatMode, ChatModeFailure> {
        if self.record.tool_mode != ChatToolMode::ReadOnly {
            return Err(ChatModeFailure::before_close("This chat is not read-only."));
        }
        if let Some(id) = self.record.connection_id.as_deref() {
            self.runtime
                .preflight(id)
                .map_err(ChatModeFailure::before_close)?;
        }
        {
            let store = self
                .workspace
                .lock()
                .map_err(|_| ChatModeFailure::before_close("The workspace is unavailable."))?;
            self.validate_catalog(&store).map_err(|error| {
                if store.is_uncertain() {
                    ChatModeFailure::fenced(error, true)
                } else {
                    ChatModeFailure::before_close(error)
                }
            })?;
        }
        let mut lease = None;
        if let Some(controller) = &self.controller {
            if controller.snapshot_shared().id != self.record.id {
                return Err(ChatModeFailure::before_close(
                    "The chat runtime identity changed.",
                ));
            }
            let guard = controller
                .suspend_idle_admission()
                .map_err(ChatModeFailure::before_close)?;
            if !guard.is_persistent() {
                return Err(ChatModeFailure::before_close(
                    "Save this chat before changing its mode.",
                ));
            }
            // Set permanent admission before the first await, including when
            // this future is cancelled while the worker is being joined.
            guard.retain_fence();
            controller
                .retire()
                .map_err(|error| ChatModeFailure::fenced(error, false))?;
            close(controller.clone())
                .await
                .map_err(|error| ChatModeFailure::fenced(error, false))?;
        } else {
            lease = Some(
                SessionInspectionLease::acquire(&self.record.snapshot, &self.record.id)
                    .and_then(|lease| lease.into_idle_lease())
                    .map_err(ChatModeFailure::before_close)?,
            );
        }
        // No mutex crosses close/join. Re-read the latest catalog so concurrent
        // draft, selection, rename and other-chat writes are preserved.
        let saved = {
            let mut store = self.workspace.lock().map_err(|_| {
                ChatModeFailure::fenced(
                    "The workspace is unavailable after closing the chat.",
                    false,
                )
            })?;
            self.validate_catalog(&store)
                .map_err(|error| ChatModeFailure::fenced(error, store.is_uncertain()))?;
            match save(&mut store, &self.record.id) {
                Ok(record) => Ok(record),
                Err(error) => Err((error, store.is_uncertain())),
            }
        };
        drop(lease);
        let record = match saved {
            Ok(record) => record,
            Err((error, catalog_uncertain)) => {
                let uncertain =
                    catalog_uncertain || matches!(error, Error::PersistenceUncertain(_));
                if uncertain {
                    return Err(ChatModeFailure::fenced(error, true));
                }
                let recovery = self.reopen(&self.record).map_err(|reopen| ChatModeFailure::fenced(
                    format!("The chat mode was not saved: {error}. Its read-only session could not reopen: {reopen}"), false,
                ))?;
                return Err(ChatModeFailure {
                    message: error.to_string(),
                    keep_blocked: false,
                    uncertain: false,
                    recovery,
                });
            }
        };
        let replacement = self.reopen(&record).map_err(|error| {
            ChatModeFailure::fenced(
                format!("The chat mode was saved, but its session could not reopen: {error}"),
                false,
            )
        })?;
        Ok(ChangedChatMode {
            record,
            replacement,
        })
    }
}

#[cfg(test)]
#[path = "chat_tool_mode_tests.rs"]
mod tests;
