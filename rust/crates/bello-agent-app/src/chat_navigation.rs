//! Existing sidebar navigation, deferred creation, and source-style draft writes.
use super::*;
use crate::chat_organization::catalog_operation;
use bello_agent_core::Submission;
use std::time::Duration;

/// Extracting a user-reviewed receipt from a missing checkpoint is distinct from
/// certain nonacceptance. It never revives the failed loader or enables Send.
enum IntentResolution {
    Accepted,
    Absent,
    ExtractUnavailable,
}

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
        let project = self.project.clone();
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
        let snapshot_path = record.snapshot.clone();
        let expected_error = chat.error.clone();
        let draft = chat.saved_draft(cx);
        let id = id.to_owned();
        let timer = cx.background_executor().timer(Duration::from_millis(150));
        let task = cx.background_executor().spawn(async move {
            timer.await;
            catalog_operation(&workspace, |store| {
                if let Some(intent) = submitting {
                    store
                        .save_submitting_draft(record, draft, intent)
                        .map(|_| true)
                } else {
                    store.save_draft(&id, draft)
                }
            })
        });
        let id = chat.record.id.clone();
        chat.draft_task = Some(cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project != project {
                    return;
                }
                view.observe_catalog_uncertainty(outcome.uncertain, cx);
                let result = outcome.display_result();
                if let Some(chat) = view.chat_mut(&id) {
                    if chat.record.snapshot != snapshot_path {
                        return;
                    }
                    match result {
                        Ok(true) => chat.draft_save_status.confirm(revision, &mut chat.error),
                        Ok(false) => {}
                        Err(error) => chat.draft_save_status.fail(
                            revision,
                            error,
                            &mut chat.error,
                            &expected_error,
                        ),
                    }
                }
                cx.notify();
            });
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
            catalog_operation(&workspace, |store| store.select(&id, revision))
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                view.observe_catalog_uncertainty(outcome.uncertain, cx);
                if let Err(error) = outcome.display_result() {
                    view.error = Some(format!("Selection could not be saved: {error}"));
                    cx.notify();
                }
            });
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
        self.skill_picker = None;
        let outgoing = std::mem::replace(&mut self.chat, chat);
        let selected_id = self.record.id.clone();
        let selected_source = Arc::downgrade(&self.controller);
        self.receive_snapshot(
            &selected_id,
            &selected_source,
            self.controller.snapshot_shared(),
            cx,
        );
        let id = outgoing.record.id.clone();
        if outgoing.pending
            && !outgoing.busy
            && !self.organization_operations.contains_key(&id)
            && !self.topic_owns_chat(&id)
            && outgoing.inflight_submission.is_none()
            && !self.picker_owns_chat(&id)
            && !outgoing.skill_catalog.loading()
            && outgoing.saved_draft(cx).is_empty()
            && !self.recoveries.values().any(|intent| intent.chat_id == id)
        {
            self.records.retain(|record| record.id != id);
        } else {
            self.inactive.insert(id, outgoing);
        }
        self.focus_visible_composer(window, cx);
        self.remember_selection(cx);
        cx.notify();
    }
    pub(super) fn new_chat(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down || !self.advance_navigation(cx) {
            return;
        }
        if self.pending
            && self.record.connection_id == self.connections.choice
            && !self.controller.is_retired()
            && !self.busy
            && !self.organization_operations.contains_key(&self.record.id)
            && !self.topic_owns_chat(&self.record.id)
            && !self.picker_owns_chat(&self.record.id)
            && self.skill_picker.is_none()
            && !self.skill_catalog.loading()
            && self.saved_draft(cx).is_empty()
        {
            self.focus_visible_composer(window, cx);
            return;
        }
        if self.records.len() >= 512 {
            self.error = Some("This development workspace supports up to 512 chats".into());
            return;
        }
        if self.connections.uncertain {
            self.error = Some("An unconfirmed connection save blocks new chats.".into());
            cx.notify();
            return;
        }
        if self.connections.presentation.mode == crate::launch_authority::AuthorityMode::Native {
            let runtime = self.runtime.clone();
            let choice = self.connections.choice.clone();
            let project = self.project.clone();
            let generation = self.navigation_generation;
            let binding = self.window_binding;
            let handle = window
                .window_handle()
                .downcast::<AgentView>()
                .expect("workspace window");
            let requested = choice.clone();
            let task = cx.background_executor().spawn(async move {
                runtime.new_chat(
                    requested.as_deref(),
                    bello_agent_core::workspace::ChatToolMode::Editing,
                )
            });
            cx.spawn(async move |_, cx| {
                let result = task.await;
                let _ = handle.update(cx, |view, window, cx| {
                    if view.shutting_down
                        || view.project != project
                        || view.navigation_generation != generation
                        || view.window_binding != binding
                        || view.connections.choice != choice
                        || view.connections.uncertain
                        || !view.connections.switches.is_empty()
                        || view.project_actions_blocked()
                    {
                        return;
                    }
                    view.install_new_chat(result, window, cx);
                });
            })
            .detach();
            return;
        }
        let result = self.runtime.new_chat(
            self.connections.choice.as_deref(),
            bello_agent_core::workspace::ChatToolMode::Editing,
        );
        self.install_new_chat(result, window, cx);
    }
    fn install_new_chat(
        &mut self,
        result: bello_agent_core::Result<(
            bello_agent_core::workspace::ChatRecord,
            Arc<Controller>,
        )>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok((record, controller)) => {
                let chat = ChatState::new(
                    controller,
                    crate::chat::ChatSource {
                        record: record.clone(),
                        workspace: self.workspace.clone(),
                        read_states: self.read_states.clone(),
                    },
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
        self.select_chat_internal(id, true, window, cx);
    }
    pub(crate) fn select_chat_internal(
        &mut self,
        id: &str,
        explicit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.chat_mode_blocked.contains(id) && self.chat_ref(id).is_none() {
            return;
        }
        if self.shutting_down || !self.advance_navigation(cx) {
            return;
        }
        if explicit && self.chat_is_archived(id) && !self.show_archived {
            self.set_archive_visibility(true, cx);
        }
        if explicit && self.record.id == id {
            self.reader_opened(id, false, cx);
            self.resume_durable_cancel_explicit(id, cx);
        }
        if self.record.id == id {
            self.focus_visible_composer(window, cx);
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
            if explicit {
                self.reader_opened(id, true, cx);
            }
            if self.load_failed {
                self.load_chat(id, cx);
            }
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id).cloned() else {
            return;
        };
        let draft = self.unloaded_drafts.get(id).cloned().unwrap_or_default();
        let placeholder = match crate::saved_runtime_adapter::AppRuntime::placeholder(&record) {
            Ok(controller) => controller,
            Err(error) => {
                self.error = Some(error.to_string());
                return;
            }
        };
        self.unloaded_drafts.remove(id);
        let chat = ChatState::new(
            placeholder,
            crate::chat::ChatSource {
                record: record.clone(),
                workspace: self.workspace.clone(),
                read_states: self.read_states.clone(),
            },
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
        if explicit {
            self.reader_opened(id, true, cx);
        }
        self.load_chat(id, cx);
    }
    pub(super) fn load_chat(&mut self, id: &str, cx: &mut Context<Self>) {
        self.begin_coordinated_chat_load(id, cx);
    }
    pub(super) fn submit_chat(&mut self, lane: Lane, cx: &mut Context<Self>) {
        if self.actor_mutation_blocked(&self.record.id)
            || (self.record.connection_id.is_some() && !self.controller.configured())
            || self.busy
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
        if self
            .recoveries
            .values()
            .any(|intent| intent.chat_id == self.record.id)
        {
            self.error = Some("Resolve the unconfirmed submission before sending again.".into());
            self.reconcile_intents(&self.record.id.clone(), cx);
            cx.notify();
            return;
        }
        let text = self.composer.read(cx).text().to_owned();
        if text.trim().is_empty() && self.attachments.is_empty() && self.skills.is_empty() {
            return;
        }
        if let Err(error) = bello_agent_core::attachments::validate_selection(&self.attachments) {
            self.error = Some(error.to_string());
            cx.notify();
            return;
        }
        if let Err(error) = crate::composer_skills::validate_fresh(&self.skills) {
            self.error = Some(error.to_string());
            cx.notify();
            return;
        }
        let selections = self
            .skills
            .iter()
            .map(|chip| chip.selection.clone())
            .collect();
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
        let mut item = Submission::new(text.clone(), lane);
        item.attachments = self.attachments.clone();
        let intent = SubmissionIntent {
            skills: self.skills.clone(),
            attachments: item.attachments.clone(),
            id: item.id.clone(),
            chat_id: self.record.id.clone(),
            text: text.clone(),
            lane: item.lane.clone(),
            draft_revision: captured_revision,
        };
        self.inflight_submission = Some(intent.clone());
        // Every debounce from this clear carries the captured intent atomically.
        self.attachments.clear();
        self.skills.clear();
        self.composer
            .update(cx, |editor, cx| editor.set_text(String::new(), cx));
        let record = self.record.clone();
        let id = record.id.clone();
        let controller = self.controller.clone();
        let source = Arc::downgrade(&controller);
        let project = self.project.clone();
        let workspace = self.workspace.clone();
        let identity_workspace = workspace.clone();
        let receipt = intent.clone();
        let read_states = self.read_states.clone();
        let task = cx.background_executor().spawn(async move {
            let prepare = catalog_operation(&workspace, |store| {
                store.register(record.clone(), captured.clone())?;
                store.save_draft(&record.id, captured)?;
                crate::sidebar_read_state::prepare_admission(
                    &read_states,
                    store,
                    &record,
                    &controller,
                )?;
                store.begin_submission(intent.clone())?;
                Ok(())
            });
            let catalog_uncertain = prepare.uncertain;
            let (outcome, dispatch_started) = match prepare.result {
                Ok(()) => match controller.materialize(&record.snapshot) {
                    Ok(()) => (
                        controller
                            .submit_identified_with_inputs(item, selections)
                            .await,
                        true,
                    ),
                    Err(error) => (Err(error), false),
                },
                Err(error) => (Err(error), false),
            };
            let registered = workspace
                .lock()
                .is_ok_and(|store| store.snapshot().chats.iter().any(|chat| chat.id == id));
            match outcome {
                Ok(()) => {
                    let ack = catalog_operation(&workspace, |store| {
                        store.acknowledge_submission(&intent.id)
                    });
                    let ack_uncertain = ack.uncertain;
                    let warning = ack.display_result().err();
                    (
                        true,
                        registered,
                        warning.is_some(),
                        warning,
                        catalog_uncertain || ack_uncertain,
                        dispatch_started,
                    )
                }
                Err(error) => {
                    let uncertain =
                        matches!(error, bello_agent_core::Error::PersistenceUncertain(_))
                            || catalog_uncertain;
                    (
                        false,
                        registered,
                        uncertain,
                        Some(crate::chat_organization::catalog_error(
                            &error,
                            catalog_uncertain,
                        )),
                        catalog_uncertain,
                        dispatch_started,
                    )
                }
            }
        });
        let id = receipt.chat_id.clone();
        cx.spawn(async move |view, cx| {
            let (accepted, registered, uncertain, error, catalog_uncertain, dispatch_started) = task.await;
            let _ = view.update(cx, move |view, cx| {
                if view.project != project || !Arc::ptr_eq(&view.workspace, &identity_workspace) { return; }
                view.observe_catalog_uncertainty(catalog_uncertain, cx);
                if view.chat_ref(&id).is_none_or(|chat| !source.ptr_eq(&Arc::downgrade(&chat.controller)) || chat.inflight_submission.as_ref() != Some(&receipt)) { return; }
                let latest = view.workspace.lock().ok().and_then(|store| store.snapshot().chats.into_iter().find(|record| record.id == id));
                if let Some(record) = &latest && let Some(row) = view.records.iter_mut().find(|record| record.id == id) {
                    row.materialization = record.materialization;
                }
                let mut restore = None;
                let mut revision_exhausted = false;
                if let Some(chat) = view.chat_mut(&id) {
                    if let Some(record) = &latest { chat.record.materialization = record.materialization; }
                    chat.busy = !accepted && !uncertain;
                    chat.inflight_submission = None;
                    chat.error = error;
                    if registered || accepted {
                        chat.pending = false;
                    }
                    chat.session = chat.controller.snapshot_shared();
                    // An uncertain acceptance lives only in its durable receipt.
                    // Re-inserting it now could duplicate an accepted input on reopen.
                    if !accepted && (!uncertain || !dispatch_started) {
                        // A catalog/baseline failure happened before dispatch.
                        // Restore the composer even when catalog durability is
                        // uncertain; keep its existing receipt/admission fence.
                        match bello_agent_core::attachments::restore(&receipt.attachments,&chat.attachments) {
                            Ok(restored)=>chat.attachments=restored,
                            Err(error)=>{chat.error=Some(error.to_string());revision_exhausted=true;chat.busy=false;}
                        }
                        match crate::composer_skills::restore_chips(&receipt.skills, &chat.skills) {
                            Ok(restored) => chat.skills = restored,
                            Err(error) => { chat.error = Some(error.to_string()); revision_exhausted = true; chat.busy = false; }
                        }
                        let later = chat.composer.read(cx).text();
                        let merged = merge_restored_text(&text, later);
                        chat.composer
                            .update(cx, |editor, cx| editor.set_text(merged, cx));
                        if let Some(revision) = chat.draft_revision.checked_add(1) {
                            chat.draft_revision = revision;
                            if !revision_exhausted { restore = Some((chat.record.clone(), chat.saved_draft(cx))); }
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
                    let recovery_workspace = workspace.clone();
                    let intent = receipt.clone();
                    let task = cx.background_executor().spawn(async move {
                        catalog_operation(&workspace, |store| {
                            if uncertain { store.save_draft(&intent.chat_id, draft).map(|_| ()) }
                            else { store.settle_rejected(record, intent, draft) }
                        })
                    });
                    let settled_chat = id.clone();
                    let recovery_source = source.clone();
                    let recovery_project = project.clone();
                    cx.spawn(async move |view, cx| {
                        let outcome = task.await;
                        let _ = view.update(cx, |view, cx| {
                            if view.project != recovery_project || !view.observe_bound_catalog_uncertainty(&recovery_workspace, outcome.uncertain, cx) { return; }
                            if view.chat_ref(&settled_chat).is_none_or(|chat| !recovery_source.ptr_eq(&Arc::downgrade(&chat.controller))) { return; }
                            let result = outcome.display_result();
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
        source: &std::sync::Weak<Controller>,
        snapshot: Arc<bello_agent_core::Session>,
        cx: &mut Context<Self>,
    ) {
        if self
            .chat_ref(id)
            .is_none_or(|chat| !source.ptr_eq(&Arc::downgrade(&chat.controller)))
        {
            return;
        }
        // Only the selected ordinary watch path adopts the atomic latest pair.
        // Inactive chat behavior and all lifecycle fences remain unchanged.
        let binding = (self.record.id == id)
            .then(|| self.controller.find_snapshot())
            .flatten();
        let snapshot = binding
            .as_ref()
            .map(|b| b.session_shared())
            .unwrap_or(snapshot);
        self.adopt_snapshot(id, source, snapshot, binding, cx);
    }
    /// Synthetic transcript projection tests intentionally supply impossible or
    /// historical display states. They get no verified Find binding or authority.
    #[cfg(test)]
    pub(crate) fn receive_fixture_snapshot(
        &mut self,
        id: &str,
        source: &std::sync::Weak<Controller>,
        snapshot: Arc<bello_agent_core::Session>,
        cx: &mut Context<Self>,
    ) {
        self.adopt_snapshot(id, source, snapshot, None, cx);
    }
    fn adopt_snapshot(
        &mut self,
        id: &str,
        source: &std::sync::Weak<Controller>,
        snapshot: Arc<bello_agent_core::Session>,
        binding: Option<bello_agent_core::retained_find::FindSnapshot>,
        cx: &mut Context<Self>,
    ) {
        // Reject before title writes, edit recovery, errors or notifications.
        if self
            .chat_ref(id)
            .is_none_or(|chat| !source.ptr_eq(&Arc::downgrade(&chat.controller)))
        {
            return;
        }
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
            chat.display_find_binding = binding;
        }
        if let Some(title) = title {
            if let Some(record) = self.records.iter_mut().find(|record| record.id == id) {
                record.title = title.clone();
            }
            let id = id.to_owned();
            let workspace = self.workspace.clone();
            let source = source.clone();
            let saved_id = id.clone();
            let task = cx.background_executor().spawn(async move {
                catalog_operation(&workspace, |store| store.name_chat(&id, &title))
            });
            cx.spawn(async move |view, cx| {
                let outcome = task.await;
                let _ = view.update(cx, |view, cx| {
                    view.finish_snapshot_title(&saved_id, &source, outcome, cx);
                });
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
    pub(crate) fn finish_snapshot_title(
        &mut self,
        id: &str,
        source: &std::sync::Weak<Controller>,
        outcome: crate::chat_organization::CatalogOutcome<()>,
        cx: &mut Context<Self>,
    ) {
        // Catalog uncertainty is workspace-wide even if this chat generation
        // was replaced while its already-admitted title write was finishing.
        self.observe_catalog_uncertainty(outcome.uncertain, cx);
        if let Some(chat) = self.chat_mut(id)
            && source.ptr_eq(&Arc::downgrade(&chat.controller))
            && let Err(error) = outcome.display_result()
        {
            chat.error = Some(format!("Chat title could not be saved: {error}"));
            cx.notify();
        }
    }
    pub(crate) fn reconcile_intents(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.projects.operation.is_some() || self.chat_mode_blocked.contains(id) {
            return;
        }
        let Some(chat) = self.chat_ref(id) else {
            return;
        };
        let intents: Vec<_> = self
            .recoveries
            .values()
            .filter(|intent| intent.chat_id == id)
            .cloned()
            .collect();
        if intents.is_empty() {
            return;
        }
        let controller = chat.controller.clone();
        let source = Arc::downgrade(&controller);
        let project = self.project.clone();
        let chat_id = id.to_owned();
        let workspace = self.workspace.clone();
        let task = cx.background_executor().spawn(async move {
            let mut accepted = Vec::new();
            let mut error = None;
            for intent in intents {
                match controller.submission_intent_status(&intent) {
                    Ok(true) => accepted.push(intent.id),
                    Ok(false) => {}
                    Err(problem) => {
                        error = Some(format!("Submission recovery is not confirmed: {problem}"));
                        break;
                    }
                }
            }
            let outcome = if accepted.is_empty() {
                None
            } else {
                Some(catalog_operation(&workspace, |store| {
                    for id in &accepted {
                        store.acknowledge_submission(id)?;
                    }
                    Ok(())
                }))
            };
            (accepted, outcome, error)
        });
        cx.spawn(async move |view, cx| {
            let (accepted, outcome, error) = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project != project {
                    return;
                }
                if let Some(outcome) = &outcome {
                    view.observe_catalog_uncertainty(outcome.uncertain, cx);
                }
                if view
                    .chat_ref(&chat_id)
                    .is_none_or(|chat| !source.ptr_eq(&Arc::downgrade(&chat.controller)))
                {
                    return;
                }
                if let Some(outcome) = outcome {
                    match outcome.display_result() {
                        Ok(()) => {
                            for id in accepted {
                                view.recoveries.remove(&id);
                            }
                        }
                        Err(error) => {
                            if let Some(chat) = view.chat_mut(&chat_id) {
                                chat.error = Some(error);
                            }
                        }
                    }
                }
                if let Some(error) = error
                    && let Some(chat) = view.chat_mut(&chat_id)
                {
                    chat.error = Some(error);
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn resolve_intent(&mut self, intent_id: &str, insert: bool, cx: &mut Context<Self>) {
        if self.actor_mutation_blocked(&self.record.id)
            || self.busy
            || self.loading
            || self.shutting_down
            || self.edit_recovery.blocked
            || self.has_pending_cancel(&self.record.id)
            || self.picker_owns_chat(&self.record.id)
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
            cx.notify();
            return;
        }
        let draft_source = draft.clone();
        let Some(revision) = self.draft_revision.checked_add(1) else {
            self.error = Some(
                "Draft revision limit reached; text and recovery receipt are preserved.".into(),
            );
            cx.notify();
            return;
        };
        self.draft_revision = revision;
        draft.revision = revision;
        self.busy = true;
        self.composer
            .update(cx, |editor, cx| editor.set_read_only(true, cx));
        let workspace = self.workspace.clone();
        let controller = self.controller.clone();
        let source = Arc::downgrade(&controller);
        let project = self.project.clone();
        let unavailable_placeholder = self.load_failed
            && controller.is_retired()
            && !controller.configured()
            && controller.is_never_materialized();
        let record = self.record.clone();
        let checkpoint = record.snapshot.clone();
        let load_generation = self.load_generation;
        let workspace_identity = Arc::downgrade(&workspace);
        let binding = self.window_binding;
        let receipt = intent.clone();
        let task = cx.background_executor().spawn(async move {
            let resolution = if unavailable_placeholder {
                match std::fs::symlink_metadata(&checkpoint) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound =>
                        Ok(IntentResolution::ExtractUnavailable),
                    _ => Err(bello_agent_core::Error::Invalid(
                        "The unavailable checkpoint could not be confirmed missing; the receipt is preserved.".into(),
                    )),
                }
            } else {
                controller.submission_intent_status(&receipt).map(|accepted| {
                    if accepted { IntentResolution::Accepted } else { IntentResolution::Absent }
                })
            };
            let accepted = matches!(resolution, Ok(IntentResolution::Accepted));
            let extracted_unavailable = matches!(resolution, Ok(IntentResolution::ExtractUnavailable));
            let prepared = resolution.and_then(|_| {
                if insert && !accepted {
                    draft.attachments = bello_agent_core::attachments::restore(
                        &receipt.attachments,
                        &draft.attachments,
                    )?;
                    draft.skills = crate::composer_skills::restore_chips(&receipt.skills, &draft.skills)?;
                    draft.text = merge_restored_text(&receipt.text, &draft.text);
                }
                Ok(())
            });
            let outcome = catalog_operation(&workspace, |store| {
                prepared?;
                // A saved receipt is the recovery source. A cached UI row is
                // insufficient, especially when no session can be inspected.
                let saved = store.snapshot();
                if saved.intents.get(&receipt.id) != Some(&receipt) {
                    return Err(bello_agent_core::Error::Invalid(
                        "The saved submission receipt changed; recovery was not applied.".into(),
                    ));
                }
                let same_chat = saved.chats.iter().any(|chat| chat.id == record.id
                    && chat.snapshot == record.snapshot && chat.connection_id == record.connection_id
                    && chat.tool_mode == record.tool_mode && chat.materialization == record.materialization);
                let current_draft = saved.drafts.get(&receipt.chat_id).cloned().unwrap_or_default();
                if !same_chat || current_draft.revision > draft_source.revision
                    || (current_draft.revision == draft_source.revision && current_draft != draft_source) {
                    return Err(bello_agent_core::Error::Invalid(
                        "The saved chat or draft changed; the submission receipt is preserved.".into(),
                    ));
                }
                if extracted_unavailable && !matches!(std::fs::symlink_metadata(&checkpoint),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound) {
                    return Err(bello_agent_core::Error::Invalid(
                        "The checkpoint changed during recovery; the submission receipt is preserved.".into(),
                    ));
                }
                if accepted {
                    store.acknowledge_submission(&receipt.id)
                } else {
                    store.withdraw_submission(&receipt.id, draft.clone())
                }
            });
            (outcome, draft, accepted, extracted_unavailable)
        });
        cx.spawn(async move |view, cx| {
            let (outcome, draft, accepted, extracted_unavailable) = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project != project || !workspace_identity.ptr_eq(&Arc::downgrade(&view.workspace)) {
                    return;
                }
                view.observe_catalog_uncertainty(outcome.uncertain, cx);
                if view
                    .chat_ref(&intent.chat_id)
                    .is_none_or(|chat| !source.ptr_eq(&Arc::downgrade(&chat.controller)))
                {
                    return;
                }
                let result = outcome.display_result();
                // Durable draft ownership is per workspace/chat. A window-only
                // rebind can adopt the same data but never triggers focus or
                // navigation. Runtime/load replacement cannot adopt old input.
                let _window_rebound = view.window_binding != binding;
                let current_owner = view.chat_ref(&intent.chat_id).is_some_and(|chat| {
                    chat.load_generation == load_generation && (!extracted_unavailable
                        || (chat.load_failed && chat.controller.is_retired()
                            && !chat.controller.configured() && chat.controller.is_never_materialized()))
                });
                if !current_owner { return; }
                let archived = view.chat_is_archived(&intent.chat_id);
                if let Some(chat) = view.chat_mut(&intent.chat_id) {
                    chat.busy = false;
                    chat.composer
                        .update(cx, |editor, cx| editor.set_read_only(archived, cx));
                    match &result {
                        Ok(()) if !accepted => {
                            chat.attachments = draft.attachments;
                            chat.skills = draft.skills;
                            chat.composer
                                .update(cx, |editor, cx| editor.set_text(draft.text, cx));
                            if extracted_unavailable && insert {
                                chat.error = Some("The unverified receipt was copied into the draft. It may already have executed. The checkpoint is unavailable, so sending remains blocked.".into());
                            }
                        }
                        Ok(()) => {
                            chat.error = Some(
                                "This submission was already accepted; it was not inserted again."
                                    .into(),
                            );
                        }
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
        // Failure-held permits may have newer selected waiters. Cancel them
        // before the legacy loading veto, so draft-save + cleanup is reachable.
        if self.load_retirement.failed() {
            self.cancel_queued_chat_loads();
        }
        if self.projects.operation.is_some() {
            self.error =
                Some("Wait for the project folder change to finish before closing.".into());
            cx.notify();
            return;
        }
        if let Some(chat) = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .find(|chat| {
                self.chat_is_archived(&chat.record.id)
                    && chat.queue_operation.is_some()
                    && !self.archive_chat_work_live(&chat.record.id)
            })
        {
            self.error = Some(format!(
                "Restore “{}” and finish its deferred composition or queued edit before closing. Your text is preserved.",
                chat.record.title
            ));
            cx.notify();
            return;
        }
        if !self.chat_mode_operations.is_empty()
            || !self.organization_operations.is_empty()
            || self.archive_visibility_writes != 0
            || !self.read_manual_operations.is_empty()
            || self.topic_write.is_some()
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
        self.connections.cancel_catalog_loads();
        self.shutting_down = true;
        self.sidebar_run_states.cancel_pending();
        self.close_dialog = false;
        let mut drafts = Vec::new();
        let mut controllers = Vec::new();
        for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
            if chat.activity_write.is_pending() {
                chat.activity_write.flush();
            }
            crate::sidebar_activity::capture_current(
                &mut chat.record,
                &mut chat.activity_write,
                &chat.controller,
            );
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
        let read_controllers = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .map(|chat| (chat.record.clone(), chat.controller.clone()))
            .collect();
        let shutdown_workspace = self.workspace.clone();
        let plan = crate::shutdown_barrier::ShutdownPlan {
            load_retirement: self.load_retirement.clone(),
            read_states: Some(self.read_states.clone()),
            read_controllers,
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
                    if !Arc::ptr_eq(&view.workspace, &shutdown_workspace) {
                        return false;
                    }
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
        self.observe_catalog_uncertainty(outcome.catalog_uncertain, cx);
        for id in outcome.registered {
            if let Some(chat) = self.chat_mut(&id) {
                chat.pending = false;
            }
        }
        match outcome.result {
            Ok(()) => {
                self.close_context_inspectors(cx);
                self.close_ready = true;
                cx.notify();
                true
            }
            Err(error) => {
                self.shutting_down = false;
                self.error = Some(format!("Could not save drafts before closing: {error}"));
                for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
                    chat.composer.update(cx, |editor, cx| {
                        editor.set_read_only(chat.record.archived_at.is_some(), cx)
                    });
                }
                cx.notify();
                false
            }
        }
    }
}

fn merge_restored_text(captured: &str, newer: &str) -> String {
    if captured.is_empty() {
        newer.to_owned()
    } else if newer.is_empty() {
        captured.to_owned()
    } else {
        format!("{captured}\n\n{newer}")
    }
}
