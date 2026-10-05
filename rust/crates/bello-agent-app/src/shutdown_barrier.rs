//! Existing Rust draft-save/worker-stop ordering, independent of any window.
//! This is not a native Quit veto or the source's separate install barrier.
use bello_agent_core::{
    Controller,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use std::sync::{Arc, Mutex};

pub(super) struct ShutdownPlan {
    pub drafts: Vec<(ChatRecord, DraftRecord)>,
    pub controllers: Vec<Arc<Controller>>,
    pub selected: String,
    pub selection_revision: u64,
    pub workspace: Arc<Mutex<WorkspaceStore>>,
}

pub(super) struct ShutdownOutcome {
    /// Registration can succeed before a later write/stop fails.
    pub registered: Vec<String>,
    pub result: Result<(), String>,
}

impl ShutdownPlan {
    pub async fn execute(self) -> ShutdownOutcome {
        self.execute_with_stop(|controller| async move {
            controller
                .shutdown()
                .await
                .map_err(|error| error.to_string())
        })
        .await
    }

    async fn execute_with_stop<F, Fut>(self, mut stop: F) -> ShutdownOutcome
    where
        F: FnMut(Arc<Controller>) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        let mut registered = Vec::new();
        let saved = (|| -> Result<(), String> {
            let mut store = self
                .workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?;
            for (record, draft) in self.drafts {
                store
                    .register(record.clone(), draft.clone())
                    .map_err(|error| error.to_string())?;
                registered.push(record.id.clone());
                store
                    .save_draft(&record.id, draft)
                    .map_err(|error| error.to_string())?;
            }
            if store
                .snapshot()
                .chats
                .iter()
                .any(|chat| chat.id == self.selected)
            {
                // Keep current Rust policy: a selection-save failure is fatal.
                // The Swift Quit path's best-effort selection is a separate gap.
                store
                    .select(&self.selected, self.selection_revision)
                    .map_err(|error| error.to_string())?;
            }
            Ok(())
        })();
        let result = if saved.is_ok() {
            let mut result = Ok(());
            for controller in self.controllers {
                if let Err(error) = stop(controller).await {
                    result = Err(error);
                    break;
                }
            }
            result
        } else {
            saved
        };
        ShutdownOutcome { registered, result }
    }
}

#[cfg(test)]
#[path = "shutdown_barrier_tests.rs"]
mod tests;
