//! Ephemeral per-invocation display state. Never journalled or replayed.
use super::{Controller, Inner};
use crate::{
    RunState,
    tool_history::{LiveToolView, ToolOutcome},
};
use std::sync::{Arc, Weak, atomic::Ordering};

#[derive(Clone)]
pub(super) struct Identity {
    controller: Weak<Controller>,
    worker: Arc<()>,
    configuration: Arc<()>,
    stop: u64,
    turn: String,
    assistant: String,
    call: String,
}
impl Identity {
    fn matches(&self, controller: &Controller, inner: &Inner) -> bool {
        let session = inner.store.snapshot_ref();
        !controller.is_retired()
            && !controller.stop_requested.load(Ordering::Acquire)
            && controller.stop_epoch.load(Ordering::Acquire) == self.stop
            && inner.worker_running
            && Arc::ptr_eq(&self.worker, &inner.worker_epoch)
            && Arc::ptr_eq(&self.configuration, &inner.configuration_epoch)
            && inner
                .cancel
                .as_ref()
                .is_some_and(|token| !token.is_cancelled())
            && session.state == RunState::Running
            && session
                .active
                .as_ref()
                .is_some_and(|turn| turn.id == self.turn)
            && session.active_reply.as_deref() == Some(&self.assistant)
            && session
                .active_tool_calls()
                .is_some_and(|calls| calls.iter().any(|call| call.id == self.call))
    }
    pub fn update(&self, sequence: u64, preview: String) {
        // A preview may be discarded while persistence owns the actor. Never
        // block process drainage behind disk I/O or enqueue unbounded updates.
        let Some(controller) = self.controller.upgrade() else {
            return;
        };
        let Ok(mut inner) = controller.inner.try_lock() else {
            return;
        };
        if !self.matches(&controller, &inner) || preview.len() > 3 * 32_768 {
            return;
        }
        if let Some(view) = inner
            .live_tools
            .iter_mut()
            .find(|view| view.assistant_id == self.assistant && view.call_id == self.call)
        {
            if view.outcome.is_some() || sequence <= view.sequence {
                return;
            }
            view.sequence = sequence;
            view.preview = preview.into();
        } else {
            inner.live_tools.push(LiveToolView {
                assistant_id: self.assistant.clone(),
                call_id: self.call.clone(),
                sequence,
                preview: preview.into(),
                outcome: None,
            });
        }
        controller.publish_live(&inner, self.stop);
    }
    pub fn finish(&self, text: &str, outcome: ToolOutcome) {
        let Some(controller) = self.controller.upgrade() else {
            return;
        };
        let Ok(mut inner) = controller.inner.lock() else {
            return;
        };
        if !self.matches(&controller, &inner) {
            return;
        }
        // A bounded terminal preview precedes the durable whole-batch receipt.
        // It never asserts durability and is omitted entirely on reopen.
        let mut end = text.len().min(3 * 32_768);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let preview: Arc<str> = text[..end].into();
        if let Some(view) = inner
            .live_tools
            .iter_mut()
            .find(|view| view.assistant_id == self.assistant && view.call_id == self.call)
        {
            view.outcome = Some(outcome);
            view.preview = preview;
        } else {
            inner.live_tools.push(LiveToolView {
                assistant_id: self.assistant.clone(),
                call_id: self.call.clone(),
                sequence: 0,
                preview,
                outcome: Some(outcome),
            });
        }
        controller.publish_live(&inner, self.stop);
    }
}
impl Controller {
    pub(super) fn live_tool_identity(
        self: &Arc<Self>,
        assistant: &str,
        call: &str,
    ) -> Option<Identity> {
        let inner = self.inner.lock().ok()?;
        let identity = Identity {
            controller: Arc::downgrade(self),
            worker: inner.worker_epoch.clone(),
            configuration: inner.configuration_epoch.clone(),
            stop: self.stop_epoch.load(Ordering::Acquire),
            turn: inner.store.snapshot_ref().active.as_ref()?.id.clone(),
            assistant: assistant.into(),
            call: call.into(),
        };
        identity.matches(self, &inner).then_some(identity)
    }
}

#[cfg(test)]
#[path = "live_tool_runtime_tests.rs"]
mod tests;
