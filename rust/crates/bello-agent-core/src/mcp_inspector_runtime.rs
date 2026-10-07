//! One-shot Inspector work uses the same saved Editing capability and joined
//! Controller lifetime as model calls. The project receipt is its canonical
//! durable result; it is never fabricated as a conversation turn.
use super::*;
use crate::mcp::CancellationToken;
use serde_json::{Value, json};
struct InspectorLifetime {
    controller: Arc<Controller>,
    guard: Option<IdleAdmissionGuard>,
}
impl Drop for InspectorLifetime {
    fn drop(&mut self) {
        if let Ok(mut cancel) = self.controller.active_cancel.write() {
            *cancel = None;
        }
        self.guard.take();
    }
}
impl Controller {
    pub async fn mcp_invoke_once(
        self: &Arc<Self>,
        server: String,
        tool: String,
        arguments: Value,
        confirmed: bool,
        cancel: CancellationToken,
    ) -> Result<Value> {
        if !confirmed {
            return Err(invalid("Confirm this exact one-shot MCP invocation first"));
        }
        let tools=self.options.tools.as_ref().and_then(|t|t.mcp.as_ref()).filter(|t|!t.read_only)
            .ok_or_else(||invalid("MCP invocation requires a saved Editing chat; server annotations do not grant permission"))?.clone();
        let stopped = self.stop_epoch.load(Ordering::Acquire);
        let guard = self.suspend_idle_admission()?;
        let _cancel_on_drop = cancel.clone().drop_guard();
        let (sender, receiver) = tokio::sync::oneshot::channel();
        {
            // Register under the same retirement barrier. The worker owns the
            // guard until completion, even if this caller abandons its future.
            let _inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            if self.is_retired()
                || self.stop_epoch.load(Ordering::Acquire) != stopped
                || cancel.is_cancelled()
            {
                return Err(crate::Error::Cancelled);
            }
            self.check_resources()?;
            let mut joins = self
                .worker_joins
                .lock()
                .map_err(|_| invalid("Worker is unavailable"))?;
            *self
                .active_cancel
                .write()
                .map_err(|_| invalid("Session cancellation is unavailable"))? =
                Some(cancel.clone());
            if self.is_retired() || self.stop_epoch.load(Ordering::Acquire) != stopped {
                cancel.cancel();
            }
            let owner = self.clone();
            let handle=self.runtime.spawn(async move {
                let _lifetime=InspectorLifetime{controller:owner.clone(),guard:Some(guard)};
                let result=async {
                    let parameters=json!({"action":"invoke","server":server,"tool":tool,"arguments":arguments});
                    let performed=tools.manager.perform(&parameters,false,cancel.clone(),||async {
                        if owner.is_retired()||cancel.is_cancelled() { return Err(crate::Error::Cancelled) }
                        if let Some(configuration)=owner.configuration() { configuration.confirm_for_request().await?; }
                        owner.confirm_runtime_authority(cancel.clone()).await
                    }).await?;
                    tools.manager.retain_inspector(performed).await
                }.await;
                let _=sender.send(result);
            });
            Self::remember_worker(&mut joins, handle);
        }
        receiver.await.map_err(|_| {
            invalid("MCP Inspector worker did not finish; check the project outcome")
        })?
    }
}
