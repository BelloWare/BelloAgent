//! Per-chat presentation ownership. Background completion always addresses the
//! captured chat identity, even after the reader changes the selected row.
use super::{AgentView, Palette};
use bello_agent_core::{
    Controller, Session,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, SubmissionIntent},
};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::*;
use std::sync::Arc;

pub(crate) struct RestoredDraft<'a> {
    pub draft: DraftRecord,
    pub cancellation: Option<&'a bello_agent_core::workspace::QueuedCancelReceipt>,
}

pub struct ChatState {
    pub record: ChatRecord,
    pub controller: Arc<Controller>,
    pub session: Arc<Session>,
    pub composer: Entity<EditorView>,
    pub transcript: Option<Entity<crate::transcript_view::TranscriptView>>,
    pub error: Option<String>,
    pub archive_stop_warning: Option<String>,
    pub editing: Option<String>,
    pub queued_turn_id: Option<String>,
    pub queued_original: Option<String>,
    pub draft_before_edit: String,
    pub retained_edit: Option<QueuedDraft>,
    pub begin_error: Option<crate::queue_begin::BeginFailure>,
    pub begin_operation: Option<crate::queue_begin::BeginOperation>,
    pub cancel_operation: Option<crate::queue_cancel::CancelOperation>,
    pub visible_messages: usize,
    pub queue_open: bool,
    pub queue_geometry: Option<crate::queue_geometry::QueueGeometry>,
    pub queue_scroll: ScrollHandle,
    pub queue_drag: Option<crate::queue_drag::QueueDragState>,
    pub queue_drag_task: Option<Task<()>>,
    pub queue_operation: Option<uuid::Uuid>,
    pub queue_operation_error: Option<String>,
    pub edit_recovery: crate::queue_edit::EditRecovery,
    pub _recovery_events: Subscription,
    pub queue_detail: Option<crate::queue_detail::QueueDetail>,
    pub last_revision: u64,
    pub busy: bool,
    pub loading: bool,
    pub load_failed: bool,
    pub load_generation: u64,
    pub pending: bool,
    pub error_expanded: bool,
    pub dismissed_error: Option<String>,
    pub draft_revision: u64,
    pub draft_save_status: crate::draft_status::DraftSaveStatus,
    pub draft_task: Option<Task<()>>,
    pub inflight_submission: Option<SubmissionIntent>,
    pub _editor_events: Subscription,
    pub _poll: Task<()>,
}
impl ChatState {
    pub fn new(
        controller: Arc<Controller>,
        record: ChatRecord,
        restored: RestoredDraft<'_>,
        pending: bool,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<AgentView>,
    ) -> Self {
        let RestoredDraft {
            draft,
            cancellation,
        } = restored;
        let session = controller.snapshot_shared();
        let pending_cancel = cancellation.and_then(|receipt| match &receipt.state {
            bello_agent_core::workspace::QueuedCancelState::Pending { edit_id, turn_id } => {
                Some((edit_id, turn_id))
            }
            bello_agent_core::workspace::QueuedCancelState::Settled => None,
        });
        let retain_unowned = pending_cancel.is_some_and(|(edit, turn)| {
            draft
                .queued_edit
                .as_ref()
                .is_none_or(|saved| &saved.edit_id == edit && &saved.turn_id == turn)
        });
        let text = if retain_unowned {
            draft.text.clone()
        } else {
            draft
                .queued_edit
                .as_ref()
                .map(|v| v.rewrite.clone())
                .unwrap_or_else(|| draft.text.clone())
        };
        let composer = cx.new(|cx| {
            let mut view = EditorView::new(text, window, cx);
            view.set_composer_mode(cx);
            view.set_read_only(record.archived_at.is_some(), cx);
            view.set_appearance(AgentView::composer_style(palette), cx);
            view
        });
        let id = record.id.clone();
        let editor_events = cx.subscribe(&composer, move |view, _, event, cx| {
            if matches!(event, EditorEvent::Changed) {
                view.draft_changed(&id, cx);
            }
            cx.notify();
        });
        let recovery_id = record.id.clone();
        let recovery_events = cx.observe(&composer, move |view, _, cx| {
            view.resume_edit_reconciliation(&recovery_id, cx);
            view.resume_deferred_cancel(&recovery_id, cx);
            view.resume_deferred_begin(&recovery_id, cx);
        });
        let poll = Self::subscribe(&controller, record.id.clone(), cx);
        Self {
            last_revision: controller.revision(),
            controller,
            record,
            session,
            composer,
            transcript: None,
            editing: if retain_unowned {
                None
            } else {
                draft.queued_edit.as_ref().map(|v| v.edit_id.clone())
            },
            queued_turn_id: if retain_unowned {
                None
            } else {
                draft.queued_edit.as_ref().map(|v| v.turn_id.clone())
            },
            queued_original: if retain_unowned {
                None
            } else {
                draft
                    .queued_edit
                    .as_ref()
                    .and_then(|v| v.original_text.clone())
            },
            retained_edit: if retain_unowned {
                draft.queued_edit.clone()
            } else {
                None
            },
            cancel_operation: None,
            begin_operation: None,
            begin_error: None,
            draft_before_edit: if !retain_unowned && draft.queued_edit.is_some() {
                draft.text
            } else {
                String::new()
            },
            error: None,
            archive_stop_warning: None,
            visible_messages: 100,
            queue_open: true,
            queue_geometry: None,
            queue_scroll: ScrollHandle::new(),
            queue_drag: None,
            queue_drag_task: None,
            queue_operation: None,
            queue_operation_error: None,
            edit_recovery: crate::queue_edit::EditRecovery::new(
                draft.queued_edit.is_some() || pending_cancel.is_some(),
            ),
            _recovery_events: recovery_events,
            queue_detail: None,
            busy: false,
            loading: false,
            load_failed: false,
            load_generation: 0,
            pending,
            error_expanded: false,
            dismissed_error: None,
            draft_revision: draft.revision,
            draft_save_status: crate::draft_status::DraftSaveStatus::new(draft.revision),
            draft_task: None,
            inflight_submission: None,
            _editor_events: editor_events,
            _poll: poll,
        }
    }
    fn subscribe(
        controller: &Arc<Controller>,
        id: String,
        cx: &mut Context<AgentView>,
    ) -> Task<()> {
        let mut updates = controller.subscribe();
        // Weak identity neither retains the writer lock nor allows an old
        // publication to address a replacement with the same chat ID.
        let source = Arc::downgrade(controller);
        cx.spawn(async move |view, cx| {
            while updates.changed().await.is_ok() {
                let snapshot = updates.borrow_and_update().clone();
                if view
                    .update(cx, |view, cx| {
                        view.receive_snapshot(&id, &source, snapshot, cx);
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
    }
    /// Presentation replacement only. The owner must explicitly retire/join
    /// any outgoing runtime before transferring persistent-store authority.
    pub fn replace_controller(&mut self, controller: Arc<Controller>, cx: &mut Context<AgentView>) {
        if !Arc::ptr_eq(&self.controller, &controller) {
            self.transcript = None;
            self.queue_drag = None;
            self.queue_drag_task = None;
            self.queue_operation = None;
            self.cancel_operation = None;
            self.begin_operation = None;
            self.begin_error = None;
            self.edit_recovery = crate::queue_edit::EditRecovery::new(
                self.editing.is_some() || self.retained_edit.is_some(),
            );
            if self
                .queue_operation_error
                .as_ref()
                .is_some_and(|owned| self.error.as_ref() == Some(owned))
            {
                self.error = None;
            }
            self.queue_operation_error = None;
        }
        self._poll = Self::subscribe(&controller, self.record.id.clone(), cx);
        self.session = controller.snapshot_shared();
        self.last_revision = controller.revision();
        self.controller = controller;
    }
    pub fn saved_draft(&self, cx: &App) -> DraftRecord {
        let text = self.composer.read(cx).text().to_owned();
        let queued_edit = self
            .editing
            .as_ref()
            .and_then(|edit_id| {
                let turn_id = self.queued_turn_id.clone().or_else(|| {
                    self.session
                        .edit
                        .as_ref()
                        .filter(|edit| &edit.edit_id == edit_id)
                        .map(|edit| edit.turn_id.clone())
                })?;
                let original_text = self.queued_original.clone().or_else(|| {
                    self.session
                        .pending
                        .iter()
                        .find(|item| item.id == turn_id)
                        .map(|item| item.text.clone())
                });
                Some(QueuedDraft {
                    edit_id: edit_id.clone(),
                    turn_id,
                    rewrite: text.clone(),
                    original_text,
                })
            })
            .or_else(|| self.retained_edit.clone());
        DraftRecord {
            revision: self.draft_revision,
            text: if self.editing.is_some() {
                self.draft_before_edit.clone()
            } else {
                text
            },
            queued_edit,
        }
    }
}
