//! ConversationPane.swift's implemented Compact Now action. Opening/dismissing
//! this menu never changes the composer, starts a model request or retargets a chat.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::{Controller, RunState, compaction::Phase, context_recovery};
use gpui::{prelude::*, *};
use std::{path::PathBuf, sync::Arc};

#[derive(Clone)]
pub(crate) struct CompactionMenu {
    chat_id: String,
    controller: Arc<Controller>,
    project: PathBuf,
    binding: Option<WindowBinding>,
    anchor: Point<Pixels>,
}
impl AgentView {
    pub(crate) fn open_compaction_menu(&mut self, anchor: Point<Pixels>, cx: &mut Context<Self>) {
        if self.shutting_down || self.loading || self.load_failed {
            return;
        }
        self.compaction_menu = Some(CompactionMenu {
            chat_id: self.record.id.clone(),
            controller: self.controller.clone(),
            project: self.project.clone(),
            binding: self.window_binding,
            anchor,
        });
        cx.notify();
    }
    fn compact_from_menu(&mut self, cx: &mut Context<Self>) {
        let Some(menu) = self.compaction_menu.take() else {
            return;
        };
        cx.notify();
        if menu.chat_id != self.record.id
            || menu.project != self.project
            || menu.binding != self.window_binding
            || !Arc::ptr_eq(&menu.controller, &self.controller)
        {
            return;
        }
        self.compact_current(cx);
    }
    pub(crate) fn compact_current(&mut self, cx: &mut Context<Self>) {
        let id = self.record.id.clone();
        if !self.controller.configured()
            || self.shutting_down
            || self.loading
            || self.load_failed
            || self.busy
            || self.actor_mutation_blocked(&id)
            || self.edit_recovery.blocked
            || self.queue_operation.is_some()
            || self.has_pending_cancel(&id)
            || self
                .session
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.is_running())
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_operation = Some(operation);
        let controller = self.controller.clone();
        let worker = controller.clone();
        let project = self.project.clone();
        let task = cx.background_executor().spawn(async move {
            worker
                .compact(None)
                .map_err(|error| format!("Chat could not be compacted: {error}"))
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_queue_operation(&id, &project, &controller, operation, result, cx)
            });
        })
        .detach();
        cx.notify();
    }
    pub(crate) fn compaction_menu_key(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.compaction_menu.is_none() {
            return false;
        }
        if self.close_dialog
            || self.connections.view.read(cx).is_open()
            || self.projects.view.read(cx).is_open()
            || self.quick_open.read(cx).is_open()
        {
            self.compaction_menu = None;
            return false;
        }
        match event.keystroke.key.as_str() {
            "escape" => {
                self.compaction_menu = None;
                cx.notify();
                true
            }
            "enter" if !self.composer.read(cx).has_marked_text() => {
                self.compact_from_menu(cx);
                true
            }
            _ => false,
        }
    }
    pub(crate) fn compaction_menu_element(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.compaction_menu.as_ref()?;
        let navigation = self.navigation_generation;
        let p = self.palette;
        Some(
            deferred(
                anchored()
                    .position(menu.anchor)
                    .anchor(Corner::BottomRight)
                    .snap_to_window_with_margin(px(8.))
                    .child(
                        div()
                            .id("conversation-actions-menu")
                            .debug_selector(|| "conversation-actions-menu".into())
                            .occlude()
                            .min_w(px(180.))
                            .p(px(4.))
                            .rounded(px(7.))
                            .border_1()
                            .border_color(p.hairline())
                            .bg(rgb(p.surface))
                            .shadow_lg()
                            .on_mouse_down_out(cx.listener(|view, _, _, cx| {
                                view.compaction_menu = None;
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .id("search-copy-conversation")
                                    .debug_selector(|| "search-copy-conversation".into())
                                    .px(px(8.))
                                    .py(px(6.))
                                    .text_size(px(13.))
                                    .text_color(rgb(p.ink))
                                    .cursor_pointer()
                                    .hover(|style| style.bg(p.accent_soft()))
                                    .child("Search and Copy Conversation")
                                    .on_click(cx.listener(move |view, _, window, cx| {
                                        let Some(menu) = view.compaction_menu.take() else {
                                            return;
                                        };
                                        if navigation == view.navigation_generation
                                            && menu.chat_id == view.record.id
                                            && menu.project == view.project
                                            && menu.binding == view.window_binding
                                            && Arc::ptr_eq(&menu.controller, &view.controller)
                                        {
                                            view.open_conversation_content(window, cx);
                                        }
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .id("compact-now")
                                    .debug_selector(|| "compact-now".into())
                                    .px(px(8.))
                                    .py(px(6.))
                                    .rounded(px(4.))
                                    .text_size(px(13.))
                                    .text_color(rgb(p.ink))
                                    .opacity(if menu.controller.configured() {
                                        1.
                                    } else {
                                        0.4
                                    })
                                    .when(menu.controller.configured(), |item| {
                                        item.cursor_pointer()
                                            .hover(|style| style.bg(p.accent_soft()))
                                    })
                                    .child(if menu.controller.configured() {
                                        "Compact Now"
                                    } else {
                                        "Compact Now · connection unavailable"
                                    })
                                    .on_click(
                                        cx.listener(|view, _, _, cx| view.compact_from_menu(cx)),
                                    ),
                            ),
                    ),
            )
            .with_priority(11)
            .into_any_element(),
        )
    }
}

pub(crate) fn progress_label(session: &bello_agent_core::Session) -> &'static str {
    // Only the current active operation may replace ordinary generation status.
    // Retained terminal receipts continue to label their own transcript rows.
    if session.state == RunState::Running
        && let Some(receipt) = session.context_recoveries.iter().rev().find(|receipt| {
            receipt.is_running()
                && session.active_reply.as_deref()
                    == Some(
                        receipt
                            .retry_reply_id
                            .as_deref()
                            .unwrap_or(&receipt.failed_reply_id),
                    )
        })
    {
        if receipt.reason == context_recovery::Reason::Threshold {
            return match receipt.phase {
                context_recovery::Phase::Preparing => "Compacting · Preparing checkpoint…",
                context_recovery::Phase::Summarizing => "Compacting · Summarizing…",
                _ => "Working · Generating response…",
            };
        }
        return recovery_label(receipt);
    }
    match session
        .compaction
        .as_ref()
        .map(|operation| &operation.phase)
    {
        Some(Phase::Planning) => "Compacting · Preparing checkpoint…",
        Some(Phase::Summarizing) => "Compacting · Summarizing…",
        _ => "Working · Generating response…",
    }
}

pub(crate) fn row_label<'a>(
    message: &bello_agent_core::Message,
    session: &'a bello_agent_core::Session,
) -> Option<&'a str> {
    if let Some(receipt) = session.context_recoveries.iter().rev().find(|receipt| {
        receipt.failed_reply_id == message.id
            || receipt.progress_id == message.id
            || receipt.retry_reply_id.as_deref() == Some(message.id.as_str())
    }) {
        if receipt.reason == context_recovery::Reason::Threshold {
            // Swift's automatic compaction is one execution row; the deferred
            // reply was never requested and the reply after it is ordinary.
            return (receipt.progress_id == message.id).then(|| threshold_label(receipt));
        }
        if receipt.failed_reply_id == message.id {
            // Provider text is evidence, not a safe display string. Never expose
            // raw messages, request fingerprints, endpoints or attempt metadata.
            let category = receipt.failure.as_ref().map(|failure| &failure.category);
            return Some(match category {
                Some(
                    bello_agent_core::provider_failure::Category::InputPlusOutputContextExceeded,
                ) => {
                    "Context rejected · Input plus output exceeded context; failed attempt retained"
                }
                _ => "Context rejected · Input exceeded context; failed attempt retained",
            });
        }
        if receipt.progress_id == message.id {
            return Some(recovery_label(receipt));
        }
        return Some("Retried after compaction");
    }
    if message.compaction.is_some() {
        return Some("Compaction · Checkpoint durably adopted");
    }
    if let Some(operation) = session
        .compaction
        .iter()
        .chain(session.compaction_history.iter().rev())
        .find(|operation| operation.progress_id == message.id)
    {
        if let Some(error) = &operation.error {
            return Some(error);
        }
        return Some(match operation.phase {
            Phase::Planning => "Compaction · Preparing",
            Phase::Summarizing => "Compaction · Summary request",
            Phase::Completed => "Compaction · Summary response retained",
            Phase::Cancelled => "Compaction · Cancelled; original context retained",
            Phase::Interrupted => "Compaction · Interrupted; no terminal receipt",
            Phase::Failed => "Compaction · Failed; original context retained",
        });
    }
    match message.state.as_str() {
        "compaction-complete" => Some("Compaction · Summary response retained"),
        "compaction-cancelled" => Some("Compaction · Cancelled; original context retained"),
        "compaction-failed" => Some("Compaction · Failed; original context retained"),
        "compaction-interrupted" => Some("Compaction · Interrupted; no terminal receipt"),
        _ => None,
    }
}

#[cfg(test)]
#[path = "compaction_actions_tests.rs"]
mod tests;

/// Replies deferred, unrequested and empty, by an automatic compaction. Swift
/// shows only the compaction row and the reply after it.
pub(crate) fn deferred_replies(
    session: &bello_agent_core::Session,
) -> std::collections::HashSet<&str> {
    let deferred: std::collections::HashSet<&str> = session
        .context_recoveries
        .iter()
        .filter(|receipt| receipt.reason == context_recovery::Reason::Threshold)
        .map(|receipt| receipt.failed_reply_id.as_str())
        .collect();
    session
        .messages
        .iter()
        .filter(|row| {
            deferred.contains(row.id.as_str())
                && row.tool_record.is_none()
                && row.text.is_empty()
                && row.reasoning.is_empty()
        })
        .map(|row| row.id.as_str())
        .collect()
}

/// Swift's "Compaction · …" execution row for `compactContext(reason: "threshold")`.
fn threshold_label(receipt: &context_recovery::Receipt) -> &'static str {
    use context_recovery::Phase;
    match receipt.phase {
        Phase::Preparing => "Compaction · Preparing · threshold",
        Phase::Summarizing => "Compaction · Summary request · attempt 1",
        Phase::RetryReady | Phase::Retrying | Phase::Completed => {
            "Compaction · Checkpoint durably adopted"
        }
        Phase::Failed if receipt.summary_id.is_some() => "Compaction · Checkpoint durably adopted",
        Phase::Failed => "Compaction · Failed; original context retained",
        Phase::Cancelled if receipt.summary_id.is_some() => {
            "Compaction · Checkpoint durably adopted"
        }
        Phase::Cancelled => "Compaction · Cancelled; original context retained",
        Phase::Interrupted if receipt.summary_id.is_some() => {
            "Compaction · Checkpoint durably adopted"
        }
        Phase::Interrupted => "Compaction · Interrupted; original context retained",
    }
}

// These labels are deliberately source-safe constants. Raw provider errors can
// include secrets or copied request content even in a reopened receipt.
fn recovery_label(receipt: &context_recovery::Receipt) -> &'static str {
    use context_recovery::Phase;
    match receipt.phase {
        Phase::Preparing => "Context rejected · Preparing summary…",
        Phase::Summarizing => "Context rejected · Summarizing…",
        Phase::RetryReady => "Context rejected · Summary adopted; preparing retry…",
        Phase::Retrying => "Retrying after compaction…",
        Phase::Completed => "Context recovery · Retry completed; summary response retained",
        Phase::Failed if receipt.summary_id.is_some() && receipt.retry_reply_id.is_none() => {
            "Context rejected · Recovery failed after compaction; checkpoint retained"
        }
        Phase::Failed if receipt.summary_id.is_some() => {
            "Context rejected · Retry failed after compaction; checkpoint retained"
        }
        Phase::Failed if receipt.summary_attempts > 0 => {
            "Context rejected · Summary failed; original context retained"
        }
        Phase::Failed => "Context rejected · Preparation failed; original context retained",
        Phase::Cancelled if receipt.summary_id.is_some() => {
            "Context recovery · Stopped after compaction; checkpoint retained"
        }
        Phase::Cancelled => "Context recovery · Stopped; original context retained",
        Phase::Interrupted if receipt.summary_id.is_some() => {
            "Context recovery · Interrupted after compaction; checkpoint retained"
        }
        Phase::Interrupted => "Context recovery · Interrupted; original context retained",
    }
}

#[cfg(test)]
#[path = "context_recovery_feedback_tests.rs"]
mod recovery_tests;

/// Recovery observations are projected onto their owned transcript rows by core.
/// Receipts identify missing attempts, but their forensic usage is never added.
/// A missing/conflicting dimension is not an inferred zero.
pub(crate) fn recovery_usage_label(session: &bello_agent_core::Session) -> Option<String> {
    if session.context_recoveries.is_empty() {
        return None;
    }
    let mut attempted = std::collections::BTreeSet::new();
    // A reply deferred by an automatic compaction made no request.
    let deferred: std::collections::BTreeSet<_> = session
        .context_recoveries
        .iter()
        .filter(|receipt| receipt.reason == context_recovery::Reason::Threshold)
        .map(|receipt| receipt.failed_reply_id.as_str())
        .collect();
    for receipt in &session.context_recoveries {
        if !deferred.contains(receipt.failed_reply_id.as_str()) {
            attempted.insert(receipt.failed_reply_id.as_str());
        }
        if receipt.summary_attempts > 0 {
            attempted.insert(receipt.progress_id.as_str());
        }
        if receipt.retry_attempts > 0
            && let Some(id) = &receipt.retry_reply_id
        {
            attempted.insert(id.as_str());
        }
    }
    // Explicit Retry creates assistant IDs without reopening automatic recovery.
    let recovery_turns: std::collections::BTreeSet<_> = session
        .context_recoveries
        .iter()
        .flat_map(|receipt| {
            std::iter::once(receipt.turn_id.as_str()).chain(receipt.retry_turn_id.as_deref())
        })
        .collect();
    let progress_rows: std::collections::BTreeSet<_> = session
        .context_recoveries
        .iter()
        .map(|receipt| receipt.progress_id.as_str())
        .collect();
    let mut recovery_turn = false;
    for row in &session.messages {
        if row.role == "user" {
            recovery_turn = recovery_turns.contains(row.id.as_str());
        }
        if recovery_turn
            && row.role == "assistant"
            && row.compaction.is_none()
            && !progress_rows.contains(row.id.as_str())
            && !deferred.contains(row.id.as_str())
        {
            attempted.insert(row.id.as_str());
        }
    }
    for receipt in &session.context_recoveries {
        if let Some(id) = &receipt.resolved_reply_id {
            attempted.insert(id.as_str());
        }
    }
    fn dimension(
        session: &bello_agent_core::Session,
        attempted: &std::collections::BTreeSet<&str>,
        key: &str,
    ) -> String {
        let mut sum = 0u64;
        let mut observed = false;
        let mut partial = false;
        let mut overflow = false;
        let mut missing = attempted.clone();
        for row in &session.messages {
            missing.remove(row.id.as_str());
            // Checkpoints copy context, not a second physical summary request.
            if row.compaction.is_some() || !["assistant", "toolResult"].contains(&row.role.as_str())
            {
                continue;
            }
            if !attempted.contains(row.id.as_str()) && row.usage.is_null() {
                continue;
            }
            match row.usage[key].as_u64() {
                Some(value) => {
                    observed = true;
                    if let Some(total) = sum.checked_add(value) {
                        sum = total;
                    } else {
                        overflow = true;
                    }
                }
                None => partial = true,
            }
        }
        partial |= !missing.is_empty();
        if overflow || !observed {
            "unknown".into()
        } else if partial {
            format!("{sum} (partial)")
        } else {
            sum.to_string()
        }
    }
    Some(format!(
        "Reported tokens · {} in · {} out",
        dimension(session, &attempted, "input_tokens"),
        dimension(session, &attempted, "output_tokens")
    ))
}
