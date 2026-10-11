//! The one request a chat title takes (Swift `generateSessionTitle`'s turn),
//! sent on the chat's own connection outside its history.
use super::*;
use crate::title_generation::{TITLE_TIMEOUT, TitlePlan, title_from_reply};

impl Controller {
    /// Sends `plan` to this chat's connection as one request outside the
    /// chat's history and returns the title its reply carries. The chat's
    /// session, queue and checkpoint are untouched. A reply with tool calls,
    /// an unfinished reply or one without a usable line is an error.
    pub async fn request_title(
        self: &Arc<Self>,
        plan: TitlePlan,
        cancel: CancellationToken,
    ) -> Result<String> {
        if self.is_retired() {
            return Err(invalid("This chat is closed."));
        }
        let config = self
            .configuration()
            .ok_or_else(|| invalid("This chat's connection is unavailable."))?;
        let controller = self.clone();
        // Retiring the chat stops the request: a watcher cancels it as soon
        // as the controller retires, and nothing is sent after that.
        let cancel = cancel.child_token();
        let watched = cancel.clone();
        let watcher = Arc::downgrade(self);
        self.runtime.spawn(async move {
            while !watched.is_cancelled() {
                if watcher.upgrade().is_none_or(|c| c.is_retired()) {
                    watched.cancel();
                    break;
                }
                tokio::select! {
                    _ = watched.cancelled() => break,
                    _ = tokio::time::sleep(std::time::Duration::from_millis(25)) => {}
                }
            }
        });
        let finished = cancel.clone().drop_guard();
        let task = self.runtime.spawn(async move {
            config.confirm_for_request().await?;
            if controller.is_retired() || cancel.is_cancelled() {
                return Err(invalid("Title generation stopped."));
            }
            let profile = plan.profile(&config.profile);
            let message = crate::Message {
                task_root_id: None,
                user_content: None,
                id: uuid::Uuid::new_v4().to_string(),
                role: "user".into(),
                text: plan.prompt.clone(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "completed".into(),
                usage: serde_json::Value::Null,
                model: Some(plan.model.clone()),
                tool_record: None,
                compaction: None,
            };
            let session = uuid::Uuid::new_v4().to_string();
            let turn = uuid::Uuid::new_v4().to_string();
            let reply = tokio::time::timeout(
                TITLE_TIMEOUT,
                controller.client.complete(
                    &profile,
                    &config.credential,
                    &[message],
                    "",
                    &session,
                    &turn,
                    cancel,
                    |_| Ok(()),
                ),
            )
            .await
            .map_err(|_| {
                invalid("Title generation timed out. The original title was kept; nothing was retried.")
            })??;
            if reply.status != "completed" || !reply.calls.is_empty() {
                return Err(invalid(
                    "Title generation did not complete. The original title was kept; nothing was retried.",
                ));
            }
            title_from_reply(&reply.text).ok_or_else(|| {
                invalid("The mini model did not return a usable title. The original title was kept.")
            })
        });
        // Dropping this future aborts the request rather than detaching it.
        struct Abort<T>(tokio::task::JoinHandle<T>);
        impl<T> Drop for Abort<T> {
            fn drop(&mut self) {
                self.0.abort();
            }
        }
        let mut task = Abort(task);
        let result = (&mut task.0)
            .await
            .map_err(|_| invalid("Title generation stopped."))?;
        drop(finished);
        result
    }
}
