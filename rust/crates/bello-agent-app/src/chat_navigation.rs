//! Existing sidebar navigation, deferred creation, and source-style draft writes.
use super::*;
use bello_agent_core::Submission;
use std::time::Duration;
impl AgentView {
    pub(crate) fn chat_mut(&mut self, id: &str) -> Option<&mut ChatState> {
        if self.chat.record.id == id {
            Some(&mut self.chat)
        } else {
            self.inactive.get_mut(id)
        }
    }
    pub(super) fn chat_ref(&self, id: &str) -> Option<&ChatState> {
        if self.chat.record.id == id {
            Some(&self.chat)
        } else {
            self.inactive.get(id)
        }
    }
    pub(crate) fn draft_changed(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        let workspace = self.workspace.clone();
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        let Some(revision) = chat.draft_revision.checked_add(1) else {
            chat.error = Some("Draft revision limit reached; text remains in the composer.".into());
            cx.notify();
            return;
        };
        chat.draft_revision = revision;
        if chat.pending && chat.inflight_submission.is_none() {
            return;
        }
        let submitting = chat.inflight_submission.clone();
        let record = chat.record.clone();
        let draft = chat.saved_draft(cx);
        let id = id.to_owned();
        let timer = cx.background_executor().timer(Duration::from_millis(150));
        let task = cx.background_executor().spawn(async move {
            timer.await;
            let mut store = workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?;
            if let Some(intent) = submitting {
                store
                    .save_submitting_draft(record, draft, intent)
                    .map(|_| true)
                    .map_err(|e| e.to_string())
            } else {
                store.save_draft(&id, draft).map_err(|e| e.to_string())
            }
        });
        let id = chat.record.id.clone();
        chat.draft_task = Some(cx.spawn(async move |view, cx| {
            if let Err(error) = task.await {
                let _ = view.update(cx, |view, cx| {
                    if let Some(chat) = view.chat_mut(&id) {
                        chat.error = Some(format!("Draft could not be saved: {error}"));
                    }
                    cx.notify();
                });
            }
        }));
    }
    pub(super) fn remember_selection(&mut self, cx: &mut Context<Self>) {
        if self.pending || self.shutting_down {
            return;
        }
        let Some(revision) = self.selection_revision.checked_add(1) else {
            self.error = Some("Selection revision limit reached.".into());
            cx.notify();
            return;
        };
        self.selection_revision = revision;
        let id = self.record.id.clone();
        let workspace = self.workspace.clone();
        let timer = cx.background_executor().timer(Duration::from_millis(250));
        let task = cx.background_executor().spawn(async move {
            timer.await;
            workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?
                .select(&id, revision)
                .map_err(|e| e.to_string())
        });
        cx.spawn(async move |view, cx| {
            if let Err(error) = task.await {
                let _ = view.update(cx, |view, cx| {
                    view.error = Some(format!("Selection could not be saved: {error}"));
                    cx.notify();
                });
            }
        })
        .detach();
    }
    pub(super) fn install_chat(
        &mut self,
        chat: ChatState,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.cancel_queue_drag(window, cx);
        let outgoing = std::mem::replace(&mut self.chat, chat);
        let id = outgoing.record.id.clone();
        if outgoing.pending
            && !outgoing.busy
            && !self.pin_operations.contains_key(&id)
            && outgoing.inflight_submission.is_none()
            && outgoing.saved_draft(cx).is_empty()
            && !self.recoveries.values().any(|intent| intent.chat_id == id)
        {
            self.records.retain(|record| record.id != id);
        } else {
            self.inactive.insert(id, outgoing);
        }
        self.composer.read(cx).focus(window);
        self.remember_selection(cx);
        cx.notify();
    }
    pub(super) fn new_chat(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        if self.pending
            && !self.busy
            && !self.pin_operations.contains_key(&self.record.id)
            && self.saved_draft(cx).is_empty()
        {
            self.composer.read(cx).focus(window);
            return;
        }
        if self.records.len() >= 512 {
            self.error = Some("This development workspace supports up to 512 chats".into());
            return;
        }
        match Controller::with_configuration(
            SessionStore::pending(),
            self.controller.configuration(),
        ) {
            Ok(controller) => {
                let id = controller.snapshot_shared().id.clone();
                let record = ChatRecord::new(
                    id.clone(),
                    "New chat".into(),
                    self.chat_directory.join(format!("{id}.json")),
                );
                let chat = ChatState::new(
                    controller,
                    record.clone(),
                    chat::RestoredDraft {
                        draft: DraftRecord::default(),
                        cancellation: None,
                    },
                    true,
                    self.palette,
                    window,
                    cx,
                );
                self.records.insert(0, record);
                self.install_chat(chat, window, cx);
            }
            Err(error) => {
                self.error = Some(error.to_string());
                cx.notify();
            }
        }
    }
    pub(super) fn select_adjacent_chat(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down
            || self
                .files
                .iter()
                .any(|entry| entry.view.read(cx).has_close_prompt())
        {
            return;
        }
        // Do not move focus away from an active composition. This is only a
        // guard for the new shortcut; existing mouse navigation is unchanged.
        let composing = [&self.composer, &self.filter].into_iter().any(|editor| {
            let editor = editor.read(cx);
            editor.focus_handle(cx).is_focused(window) && editor.has_marked_text()
        }) || self
            .files
            .iter()
            .any(|entry| entry.view.read(cx).has_focused_composition(window, cx));
        if composing {
            return;
        }
        let records = self.visible_sidebar_records(cx);
        if records.is_empty() {
            return;
        }
        let current = records
            .iter()
            .position(|record| record.id == self.record.id);
        let index = match (current, forward) {
            (Some(index), true) => (index + 1).min(records.len() - 1),
            (Some(index), false) => index.saturating_sub(1),
            (None, true) => 0,
            (None, false) => records.len() - 1,
        };
        let id = records[index].id.clone();
        if id != self.record.id {
            self.select_chat(&id, window, cx);
        }
    }

    pub(super) fn select_chat(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        if self.record.id == id {
            self.composer.read(cx).focus(window);
            if self.load_failed {
                self.load_chat(id, cx);
            }
            if self.edit_recovery.blocked {
                self.reconcile_edit(id, cx);
            }
            return;
        }
        if let Some(chat) = self.inactive.remove(id) {
            self.install_chat(chat, window, cx);
            if self.load_failed {
                self.load_chat(id, cx);
            }
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id).cloned() else {
            return;
        };
        let draft = self.unloaded_drafts.remove(id).unwrap_or_default();
        let config = self.controller.configuration();
        let placeholder = match SessionStore::pending_with_id(id)
            .and_then(|store| Controller::with_configuration(store, config.clone()))
        {
            Ok(controller) => controller,
            Err(error) => {
                self.error = Some(error.to_string());
                return;
            }
        };
        let chat = ChatState::new(
            placeholder,
            record.clone(),
            chat::RestoredDraft {
                draft,
                cancellation: self.queued_cancellations.get(id),
            },
            false,
            self.palette,
            window,
            cx,
        );
        self.install_chat(chat, window, cx);
        self.load_chat(id, cx);
    }
    pub(super) fn load_chat(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.loading || chat.busy || chat.queue_operation.is_some() {
            return;
        }
        chat.load_generation = chat.load_generation.saturating_add(1);
        let generation = chat.load_generation;
        chat.loading = true;
        chat.load_failed = false;
        chat.error = None;
        let record = chat.record.clone();
        let config = chat.controller.configuration();
        let id = id.to_owned();
        let task = cx.background_executor().spawn(async move {
            let store = if record.snapshot.exists() {
                SessionStore::open(&record.snapshot)?
            } else {
                SessionStore::pending_with_id(&record.id)?
            };
            if store.snapshot().id != record.id {
                return Err(bello_agent_core::Error::Invalid(
                    "This snapshot belongs to another chat".into(),
                ));
            }
            Controller::with_configuration(store, config)
        });
        cx.spawn(async move |view, cx| {
            let loaded = task.await;
            let success = loaded.is_ok();
            let _ = view.update(cx, |view, cx| {
                if view
                    .chat_ref(&id)
                    .is_none_or(|chat| chat.load_generation != generation)
                {
                    return;
                }
                if let Some(chat) = view.chat_mut(&id) {
                    chat.loading = false;
                    match loaded {
                        Ok(controller) => chat.replace_controller(controller, cx),
                        Err(error) => {
                            chat.load_failed = true;
                            chat.error = Some(format!("Chat could not be opened: {error}"));
                        }
                    }
                }
                if success {
                    let snapshot = view
                        .chat_ref(&id)
                        .filter(|chat| chat.controller.is_persistent())
                        .map(|chat| chat.session.clone());
                    if let Some(snapshot) = snapshot {
                        view.receive_snapshot(&id, snapshot, cx);
                    }
                    view.reconcile_edit(&id, cx);
                    view.reconcile_intents(&id, cx);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn submit_chat(&mut self, lane: Lane, cx: &mut Context<Self>) {
        if self.busy
            || self.loading
            || self.load_failed
            || self.shutting_down
            || self.edit_recovery.blocked
            || self.has_pending_cancel(&self.record.id)
            || self.queue_operation.is_some()
        {
            return;
        }
        if self.editing.is_some() {
            self.error = Some(
                "Finish or cancel the queued edit before sending or steering another message."
                    .into(),
            );
            cx.notify();
            return;
        }
        let text = self.composer.read(cx).text().to_owned();
        if text.trim().is_empty() {
            return;
        }
        let captured = self.saved_draft(cx);
        let captured_revision = self.draft_revision;
        let Some(revision) = self.draft_revision.checked_add(1) else {
            self.error = Some("Draft revision limit reached; text remains in the composer.".into());
            cx.notify();
            return;
        };
        self.draft_revision = revision;
        self.busy = true;
        self.error = None;
        self.dismissed_error = None;
        let item = Submission::new(text.clone(), lane);
        let intent = SubmissionIntent {
            id: item.id.clone(),
            chat_id: self.record.id.clone(),
            text: text.clone(),
            lane: item.lane.clone(),
            draft_revision: captured_revision,
        };
        self.inflight_submission = Some(intent.clone());
        // Every debounce from this clear carries the captured intent atomically.
        self.composer
            .update(cx, |editor, cx| editor.set_text(String::new(), cx));
        let record = self.record.clone();
        let id = record.id.clone();
        let controller = self.controller.clone();
        let workspace = self.workspace.clone();
        let receipt = intent.clone();
        let task = cx.background_executor().spawn(async move {
            let prepare = (|| -> bello_agent_core::Result<()> {
                let mut store = workspace.lock().map_err(|_| {
                    bello_agent_core::Error::Invalid("Workspace is unavailable".into())
                })?;
                store.register(record.clone(), captured.clone())?;
                store.save_draft(&record.id, captured)?;
                store.begin_submission(intent.clone())?;
                Ok(())
            })();
            let outcome = prepare.and_then(|()| {
                controller.materialize(&record.snapshot)?;
                controller.submit_identified(item)
            });
            let registered = workspace
                .lock()
                .is_ok_and(|store| store.snapshot().chats.iter().any(|chat| chat.id == id));
            match outcome {
                Ok(()) => {
                    let warning = workspace
                        .lock()
                        .map_err(|_| "Workspace is unavailable".to_owned())
                        .and_then(|mut store| {
                            store
                                .acknowledge_submission(&intent.id)
                                .map_err(|e| e.to_string())
                        })
                        .err();
                    (true, registered, warning.is_some(), warning)
                }
                Err(error) => {
                    let uncertain =
                        matches!(error, bello_agent_core::Error::PersistenceUncertain(_));
                    (false, registered, uncertain, Some(error.to_string()))
                }
            }
        });
        let id = receipt.chat_id.clone();
        cx.spawn(async move |view, cx| {
            let (accepted, registered, uncertain, error) = task.await;
            let _ = view.update(cx, move |view, cx| {
                let mut restore = None;
                let mut revision_exhausted = false;
                if let Some(chat) = view.chat_mut(&id) {
                    chat.busy = !accepted;
                    chat.inflight_submission = None;
                    chat.error = error;
                    if registered || accepted {
                        chat.pending = false;
                    }
                    chat.session = chat.controller.snapshot_shared();
                    if !accepted {
                        let later = chat.composer.read(cx).text();
                        let merged = if later.is_empty() {
                            text
                        } else {
                            format!("{text}\n\n{later}")
                        };
                        chat.composer
                            .update(cx, |editor, cx| editor.set_text(merged, cx));
                        if let Some(revision) = chat.draft_revision.checked_add(1) {
                            chat.draft_revision = revision;
                            restore = Some((chat.record.clone(), chat.saved_draft(cx)));
                        } else {
                            revision_exhausted = true;
                            chat.busy = false;
                            chat.error = Some("Draft revision limit reached; restored text and submission receipt are preserved.".into());
                        }
                    }
                }
                if uncertain || revision_exhausted {
                    view.recoveries.insert(receipt.id.clone(), receipt.clone());
                }
                if let Some((record, draft)) = restore {
                    let workspace = view.workspace.clone();
                    let intent = receipt.clone();
                    let task = cx.background_executor().spawn(async move {
                        let mut store = workspace
                            .lock()
                            .map_err(|_| "Workspace is unavailable".to_owned())?;
                        if uncertain {
                            store
                                .save_draft(&intent.chat_id, draft)
                                .map(|_| ())
                                .map_err(|e| e.to_string())
                        } else {
                            store
                                .settle_rejected(record, intent, draft)
                                .map_err(|e| e.to_string())
                        }
                    });
                    let settled_chat = id.clone();
                    cx.spawn(async move |view, cx| {
                        let result = task.await;
                        let _ = view.update(cx, |view, cx| {
                            if let Some(chat) = view.chat_mut(&settled_chat) {
                                chat.busy = false;
                                match &result {
                                    Ok(()) => chat.pending = false,
                                    Err(error) => {
                                        chat.error = Some(format!(
                                            "Draft recovery could not be saved: {error}"
                                        ))
                                    }
                                }
                            }
                            if result.is_err() {
                                view.recoveries.insert(receipt.id.clone(), receipt);
                            }
                            view.draft_changed(&settled_chat, cx);
                            view.drain_edit_recheck(&settled_chat, cx);
                            if view.record.id == settled_chat {
                                view.remember_selection(cx);
                            }
                            cx.notify();
                        });
                    })
                    .detach();
                }
                view.draft_changed(&id, cx);
                view.drain_edit_recheck(&id, cx);
                if view.record.id == id {
                    view.remember_selection(cx);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(crate) fn receive_snapshot(
        &mut self,
        id: &str,
        snapshot: Arc<bello_agent_core::Session>,
        cx: &mut Context<Self>,
    ) {
        let mut title = None;
        let mut notify = self.record.id == id;
        if let Some(chat) = self.chat_mut(id) {
            notify |= chat.session.state != snapshot.state
                || chat.session.error != snapshot.error
                || chat.record.title != snapshot.title;
            chat.last_revision = chat.controller.revision();
            if chat.session.error != snapshot.error {
                chat.dismissed_error = None;
                chat.error_expanded = false;
            }
            if chat.record.title != snapshot.title {
                chat.record.title = snapshot.title.clone();
                title = Some(snapshot.title.clone());
            }
            chat.session = snapshot;
        }
        if let Some(title) = title {
            if let Some(record) = self.records.iter_mut().find(|record| record.id == id) {
                record.title = title.clone();
            }
            let id = id.to_owned();
            let workspace = self.workspace.clone();
            let task = cx.background_executor().spawn(async move {
                workspace
                    .lock()
                    .map_err(|_| "Workspace is unavailable".to_owned())?
                    .name_chat(&id, &title)
                    .map_err(|e| e.to_string())
            });
            cx.spawn(async move |view, cx| {
                if let Err(error) = task.await {
                    let _ = view.update(cx, |view, cx| {
                        view.error = Some(format!("Chat title could not be saved: {error}"));
                        cx.notify();
                    });
                }
            })
            .detach();
        }
        let needs_status = self.chat_ref(id).is_some_and(|chat| {
            !chat.edit_recovery.blocked
                && chat.editing.as_ref().is_some_and(|edit_id| {
                    chat.session
                        .edit
                        .as_ref()
                        .is_none_or(|hold| &hold.edit_id != edit_id)
                })
        });
        if needs_status {
            self.reconcile_edit(id, cx);
        }
        if notify {
            cx.notify();
        }
    }
    pub(crate) fn reconcile_intents(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_ref(id) else {
            return;
        };
        let accepted: Vec<_> = self
            .recoveries
            .values()
            .filter(|intent| {
                intent.chat_id == id
                    && (chat
                        .session
                        .messages
                        .iter()
                        .any(|message| message.id == intent.id)
                        || chat.session.pending.iter().any(|item| item.id == intent.id)
                        || chat
                            .session
                            .active
                            .as_ref()
                            .is_some_and(|item| item.id == intent.id)
                        || chat
                            .session
                            .retry
                            .as_ref()
                            .is_some_and(|item| item.id == intent.id))
            })
            .map(|intent| intent.id.clone())
            .collect();
        if accepted.is_empty() {
            return;
        }
        let workspace = self.workspace.clone();
        let done = accepted.clone();
        let task = cx.background_executor().spawn(async move {
            let mut store = workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?;
            for id in accepted {
                store
                    .acknowledge_submission(&id)
                    .map_err(|e| e.to_string())?;
            }
            Ok::<_, String>(())
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                match result {
                    Ok(()) => {
                        for id in done {
                            view.recoveries.remove(&id);
                        }
                    }
                    Err(error) => view.error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn resolve_intent(&mut self, intent_id: &str, insert: bool, cx: &mut Context<Self>) {
        if self.busy
            || self.loading
            || self.load_failed
            || self.shutting_down
            || self.edit_recovery.blocked
            || self.has_pending_cancel(&self.record.id)
        {
            return;
        }
        let Some(intent) = self.recoveries.get(intent_id).cloned() else {
            return;
        };
        if intent.chat_id != self.record.id {
            return;
        }
        let mut draft = self.saved_draft(cx);
        if draft.queued_edit.is_some() {
            self.error =
                Some("Finish the queued edit before recovering another submission.".into());
            return;
        }
        if insert {
            draft.text = if draft.text.is_empty() {
                intent.text.clone()
            } else {
                format!("{}\n\n{}", intent.text, draft.text)
            };
        }
        let Some(revision) = self.draft_revision.checked_add(1) else {
            self.error = Some(
                "Draft revision limit reached; text and recovery receipt are preserved.".into(),
            );
            cx.notify();
            return;
        };
        self.draft_revision = revision;
        draft.revision = self.draft_revision;
        self.busy = true;
        self.composer
            .update(cx, |editor, cx| editor.set_read_only(true, cx));
        let workspace = self.workspace.clone();
        let saved = draft.clone();
        let receipt = intent.clone();
        let task = cx.background_executor().spawn(async move {
            workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?
                .withdraw_submission(&receipt.id, saved)
                .map_err(|e| e.to_string())
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if let Some(chat) = view.chat_mut(&intent.chat_id) {
                    chat.busy = false;
                    chat.composer
                        .update(cx, |editor, cx| editor.set_read_only(false, cx));
                    match &result {
                        Ok(()) => chat
                            .composer
                            .update(cx, |editor, cx| editor.set_text(draft.text, cx)),
                        Err(error) => chat.error = Some(error.clone()),
                    }
                }
                if result.is_ok() {
                    view.recoveries.remove(&intent.id);
                }
                view.drain_edit_recheck(&intent.chat_id, cx);
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn begin_shutdown(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        if !self.pin_operations.is_empty()
            || self.busy
            || self.loading
            || self.queue_operation.is_some()
            || self
                .inactive
                .values()
                .any(|chat| chat.busy || chat.loading || chat.queue_operation.is_some())
        {
            self.error = Some("Wait for chat operations to finish before closing.".into());
            cx.notify();
            return;
        }
        if self.selection_revision.checked_add(1).is_none()
            || std::iter::once(&self.chat)
                .chain(self.inactive.values())
                .any(|chat| chat.draft_revision.checked_add(1).is_none())
        {
            self.error = Some("A draft or selection revision is exhausted; text is preserved and closing is blocked.".into());
            cx.notify();
            return;
        }
        self.shutting_down = true;
        self.close_dialog = false;
        let mut drafts = Vec::new();
        let mut controllers = Vec::new();
        for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
            chat.draft_task = None;
            chat.draft_revision = chat
                .draft_revision
                .checked_add(1)
                .expect("shutdown revision preflight");
            chat.composer
                .update(cx, |editor, cx| editor.set_read_only(true, cx));
            let draft = chat.saved_draft(cx);
            if !chat.pending || !draft.is_empty() {
                drafts.push((chat.record.clone(), draft));
            }
            controllers.push(chat.controller.clone());
        }
        let selected = self.record.id.clone();
        self.selection_revision = self
            .selection_revision
            .checked_add(1)
            .expect("shutdown selection preflight");
        let revision = self.selection_revision;
        let operation = uuid::Uuid::new_v4();
        self.shutdown_operation = Some(operation);
        let binding = self.window_binding;
        let window_handle = window.window_handle();
        let plan = crate::shutdown_barrier::ShutdownPlan {
            drafts,
            controllers,
            selected,
            selection_revision: revision,
            workspace: self.workspace.clone(),
        };
        let task = cx.background_executor().spawn(plan.execute());
        // Saving/stopping belongs to the app-owned workspace. Its outcome must
        // still restore failure state if the original native window disappears.
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let remove_window = view
                .update(cx, |view, cx| {
                    let completed = view.finish_shutdown(operation, outcome, cx);
                    completed && view.window_binding == binding
                })
                .unwrap_or(false);
            if remove_window {
                // Only presentation is window-scoped; never remove a replacement.
                let _ = window_handle.update(cx, |_, window, _| window.remove_window());
            }
        })
        .detach();
        cx.notify();
    }
    pub(super) fn finish_shutdown(
        &mut self,
        operation: uuid::Uuid,
        outcome: crate::shutdown_barrier::ShutdownOutcome,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.shutdown_operation != Some(operation) {
            return false;
        }
        self.shutdown_operation = None;
        for id in outcome.registered {
            if let Some(chat) = self.chat_mut(&id) {
                chat.pending = false;
            }
        }
        match outcome.result {
            Ok(()) => {
                self.close_ready = true;
                cx.notify();
                true
            }
            Err(error) => {
                self.shutting_down = false;
                self.error = Some(format!("Could not save drafts before closing: {error}"));
                for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
                    chat.composer
                        .update(cx, |editor, cx| editor.set_read_only(false, cx));
                }
                cx.notify();
                false
            }
        }
    }
}
