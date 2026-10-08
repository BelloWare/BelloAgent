//! Ephemeral per-invocation display state. Never journalled or replayed.
use super::{Controller, Inner, tool_runtime::ToolResultRow};
use crate::{
    RunState,
    tool_content::ContentBlock,
    tool_history::{LiveToolView, ToolOutcome},
};
use std::sync::{Arc, Weak, atomic::Ordering};

// Admission is stable in source-call order, not completion order. Excess calls
// still execute and commit normally, but have no ephemeral card payload. Keeping
// a fixed admission window avoids eviction tombstones and late reinsertion.
const MAX_LIVE_TOOL_CARDS: usize = 16;
const MAX_LIVE_PREVIEW_BYTES: usize = 3 * 32_768;
const MAX_LIVE_TOTAL_PREVIEW_BYTES: usize = MAX_LIVE_TOOL_CARDS * MAX_LIVE_PREVIEW_BYTES;

fn append_bounded(preview: &mut String, text: &str) {
    let mut end = text.len().min(MAX_LIVE_PREVIEW_BYTES - preview.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    preview.push_str(&text[..end]);
}

/// Describe retained images without cloning their base64 data or claiming the
/// eventual whole-batch checkpoint succeeded. Text already has canonical tool
/// normalization and outcome classification applied by the caller.
fn terminal_preview(result: &ToolResultRow) -> String {
    let mut preview = String::new();
    if let Some(content) = &result.content {
        for block in &content.blocks {
            if let ContentBlock::Image { mime_type, .. } = block {
                append_bounded(&mut preview, "[Image: ");
                append_bounded(&mut preview, mime_type);
                append_bounded(&mut preview, "]\n");
            }
            if preview.len() == MAX_LIVE_PREVIEW_BYTES {
                break;
            }
        }
    }
    append_bounded(&mut preview, &result.text);
    preview
}

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
            && session.active_tool_calls().is_some_and(|calls| {
                calls
                    .iter()
                    .take(MAX_LIVE_TOOL_CARDS)
                    .any(|call| call.id == self.call)
            })
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
        if !self.matches(&controller, &inner) || preview.len() > MAX_LIVE_PREVIEW_BYTES {
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
        debug_assert!(inner.live_tools.len() <= MAX_LIVE_TOOL_CARDS);
        debug_assert!(
            inner
                .live_tools
                .iter()
                .map(|view| view.preview.len())
                .sum::<usize>()
                <= MAX_LIVE_TOTAL_PREVIEW_BYTES
        );
        controller.publish_live(&inner, self.stop);
    }
    pub fn finish_result(&self, result: &ToolResultRow) {
        self.finish(&terminal_preview(result), result.outcome);
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
        let mut end = text.len().min(MAX_LIVE_PREVIEW_BYTES);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let preview: Arc<str> = text[..end].into();
        if let Some(view) = inner
            .live_tools
            .iter_mut()
            .find(|view| view.assistant_id == self.assistant && view.call_id == self.call)
        {
            if view.outcome.is_some() {
                return;
            }
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
        debug_assert!(inner.live_tools.len() <= MAX_LIVE_TOOL_CARDS);
        debug_assert!(
            inner
                .live_tools
                .iter()
                .map(|view| view.preview.len())
                .sum::<usize>()
                <= MAX_LIVE_TOTAL_PREVIEW_BYTES
        );
        controller.publish_live(&inner, self.stop);
    }
}
impl Controller {
    pub(super) fn live_tool_identity(
        self: &Arc<Self>,
        assistant: &str,
        call: &str,
    ) -> Option<Identity> {
        let mut inner = self.inner.lock().ok()?;
        let identity = Identity {
            controller: Arc::downgrade(self),
            worker: inner.worker_epoch.clone(),
            configuration: inner.configuration_epoch.clone(),
            stop: self.stop_epoch.load(Ordering::Acquire),
            turn: inner.store.snapshot_ref().active.as_ref()?.id.clone(),
            assistant: assistant.into(),
            call: call.into(),
        };
        if !identity.matches(self, &inner) {
            return None;
        }
        // Old batches must not accumulate throughout a long-running worker.
        // Their captured identities fail the active-assistant fence forever;
        // no update/finish path can reinsert those retired cards.
        inner
            .live_tools
            .retain(|view| view.assistant_id == assistant);
        Some(identity)
    }
}

#[cfg(test)]
#[path = "live_tool_runtime_tests.rs"]
mod tests;
