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
    pub catalog_uncertain: bool,
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
        // Only records already admitted by the existing draft policy. Activity
        // alone must not materialize an untouched pending chat on shutdown.
        let activity_records: Vec<_> = self
            .drafts
            .iter()
            .map(|(record, _)| record.clone())
            .collect();
        let saved = crate::chat_organization::catalog_operation(&self.workspace, |store| {
            for (record, draft) in self.drafts {
                store.register(record.clone(), draft.clone())?;
                registered.push(record.id.clone());
                store.save_draft(&record.id, draft)?;
            }
            if store
                .snapshot()
                .chats
                .iter()
                .any(|chat| chat.id == self.selected)
            {
                // Keep current Rust policy: a selection-save failure is fatal.
                // The Swift Quit path's best-effort selection is a separate gap.
                store.select(&self.selected, self.selection_revision)?;
            }
            Ok(())
        });
        let mut catalog_uncertain = saved.uncertain;
        let saved = saved.display_result();
        let mut result = if saved.is_ok() {
            let mut result = Ok(());
            for controller in &self.controllers {
                if let Err(error) = stop(controller.clone()).await {
                    result = Err(error);
                    break;
                }
            }
            result
        } else {
            saved
        };
        if result.is_ok() {
            // Stop/join may publish a final interruption/completion watermark.
            // Read it after every worker has joined, not from a stale UI watch.
            let activity = crate::chat_organization::catalog_operation(&self.workspace, |store| {
                for record in &activity_records {
                    let final_stamp = self
                        .controllers
                        .iter()
                        .find(|controller| controller.snapshot_shared().id == record.id)
                        .and_then(|controller| controller.activity().timestamp_micros)
                        .unwrap_or(0)
                        .max(record.last_activity_at.unwrap_or(0));
                    if final_stamp > 0 {
                        store.record_activity(&record.id, &record.snapshot, final_stamp)?;
                    }
                }
                Ok(())
            });
            catalog_uncertain |= activity.uncertain;
            result = activity.display_result();
        }
        ShutdownOutcome {
            registered,
            result,
            catalog_uncertain,
        }
    }
}

#[cfg(test)]
#[path = "shutdown_barrier_tests.rs"]
mod tests;
