//! MCP coordinator. Every action binds project/workspace/window identity, and
//! every confirmation owns the captured input rather than a later selection.
use crate::{
    AgentView, Palette,
    mcp_inspector_host::{McpConfigurationSave, McpSaveFailure},
    mcp_inspector_view::*,
    project_host::LoadedChat,
};
use bello_agent_core::{
    Controller, RunState,
    mcp::{CancellationToken, McpManager},
    project_authority::{ProjectAuthority, SavedProject, mcp::LoadedMcp},
    workspace::{ChatToolMode, WorkspaceStore},
};
use gpui::{AppContext, Context, Entity, Subscription, Window};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

#[derive(Clone)]
struct Scope {
    project: SavedProject,
    workspace: Arc<Mutex<WorkspaceStore>>,
}
impl Scope {
    fn matches(&self, view: &AgentView) -> bool {
        // The bound WorkspaceStore never replaces its saved UUID. Pointer and
        // original root are the published UI scope. Reconfirm durable UUID and
        // authority in background host/core admission, never classify a busy
        // catalog mutex as a changed project and abandon a completing operation.
        view.project == self.project.path && Arc::ptr_eq(&view.workspace, &self.workspace)
    }
}

struct ChatTarget {
    id: String,
    controller: Weak<Controller>,
    path: PathBuf,
    mode: ChatToolMode,
}
impl ChatTarget {
    fn capture(view: &AgentView) -> Self {
        Self {
            id: view.record.id.clone(),
            controller: Arc::downgrade(&view.controller),
            path: view.record.snapshot.clone(),
            mode: view.record.tool_mode,
        }
    }
    fn matches(&self, view: &AgentView) -> bool {
        view.record.id == self.id
            && view.record.snapshot == self.path
            && view.record.tool_mode == self.mode
            && self.controller.ptr_eq(&Arc::downgrade(&view.controller))
            && !view.controller.is_retired()
    }
}
enum Confirmation {
    Save(McpInput),
    Invoke {
        input: McpInput,
        chat: ChatTarget,
        arguments: Value,
    },
    Acknowledge(String),
    EnableEditing(ChatTarget),
    Reload,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum OperationKind {
    Load,
    Save,
    Discovery,
    Invoke,
    Acknowledge,
}
struct Operation {
    id: uuid::Uuid,
    kind: OperationKind,
    cancel: CancellationToken,
}
pub(crate) struct McpInspectorController {
    pub view: Entity<McpInspectorView>,
    presentation: McpPresentation,
    authority: Arc<ProjectAuthority>,
    scope: Option<Scope>,
    loaded: Option<LoadedMcp>,
    manager: Option<Arc<McpManager>>,
    operation: Option<Operation>,
    confirmation: Option<Confirmation>,
    events: Option<Subscription>,
    pub open: bool,
    pub admission_blocked: bool,
    mode_pending: bool,
}
impl McpInspectorController {
    pub fn new(
        palette: Palette,
        authority: Arc<ProjectAuthority>,
        synthetic: bool,
        cx: &mut Context<AgentView>,
    ) -> Self {
        let presentation = McpPresentation::new(synthetic);
        let view = cx.new(|cx| McpInspectorView::new(presentation.clone(), palette, cx));
        Self {
            view,
            presentation,
            authority,
            scope: None,
            loaded: None,
            manager: None,
            operation: None,
            confirmation: None,
            events: None,
            open: false,
            admission_blocked: false,
            mode_pending: false,
        }
    }
    pub fn busy(&self) -> bool {
        self.operation.is_some()
    }
    pub fn saving(&self) -> bool {
        self.operation
            .as_ref()
            .is_some_and(|o| o.kind == OperationKind::Save)
    }
    fn cancellable(&self) -> bool {
        self.operation.as_ref().is_some_and(|operation| {
            matches!(
                operation.kind,
                OperationKind::Load | OperationKind::Discovery | OperationKind::Invoke
            )
        })
    }
    pub fn cancel(&self) -> bool {
        if let Some(operation) = &self.operation
            && self.cancellable()
        {
            operation.cancel.cancel();
            true
        } else {
            false
        }
    }
    fn publish(&mut self, cx: &mut Context<AgentView>) {
        self.presentation.revision = self
            .presentation
            .revision
            .checked_add(1)
            .expect("MCP presentation exhausted");
        self.presentation.saving = self.saving();
        self.presentation.cancellable = self.cancellable();
        self.presentation.blocked = self.admission_blocked;
        let status = self.manager.as_ref().map(|m| m.status());
        self.presentation.busy = self.operation.is_some()
            || self.mode_pending
            || status.as_ref().is_some_and(|s| s.busy);
        self.presentation.unknown_id = status.as_ref().and_then(|s| s.unknown_id.clone());
        self.presentation.pending_results = status.as_ref().map_or(0, |s| s.pending_results);
        let p = self.presentation.clone();
        self.view.update(cx, |v, cx| v.present(p, cx));
        cx.notify();
    }
}
fn config_input(input: &McpInput) -> Result<(), String> {
    if input.configuration.len() > 262_144 {
        return Err("Configuration JSON exceeds 256 KiB. Shorten the draft.".into());
    }
    let value: Value = serde_json::from_str(&input.configuration)
        .map_err(|_| "Configuration must be a valid JSON object.".to_owned())?;
    let servers = value
        .get("servers")
        .and_then(Value::as_object)
        .ok_or("Configuration needs a servers object.")?;
    for server in servers.values() {
        let fields = server
            .as_object()
            .ok_or("Each server must be one JSON object.")?;
        if fields.contains_key("headers") {
            return Err("Remove headers from the configuration editor. Use the masked per-server header replacement field.".into());
        }
        if fields.get("transport").and_then(Value::as_str) == Some("stdio")
            || fields.contains_key("command")
            || fields.contains_key("args")
            || fields.contains_key("env")
        {
            return Err("stdio is unsupported. Use Streamable HTTP with an explicit numeric loopback fixture URL.".into());
        }
    }
    Ok(())
}
fn arguments_input(input: &McpInput) -> Result<Value, String> {
    if input.arguments.len() > 262_144 {
        return Err("Invocation arguments exceed 256 KiB.".into());
    }
    let value: Value = serde_json::from_str(&input.arguments)
        .map_err(|_| "Invocation arguments must be valid JSON.".to_owned())?;
    if !value.is_object() {
        return Err("Invocation arguments must be one JSON object.".into());
    }
    Ok(value)
}

impl AgentView {
    pub(crate) fn bind_mcp(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.mcp.cancel();
        self.mcp.confirmation = None;
        self.mcp.presentation.confirmation = None;
        self.mcp.presentation.close_confirmation = false;
        self.mcp.open = false;
        self.mcp.view.update(cx, |v, cx| v.close(false, window, cx));
        self.mcp.publish(cx);
        let binding = self.window_binding;
        self.mcp.events =
            Some(
                cx.subscribe_in(&self.mcp.view, window, move |view, _, event, window, cx| {
                    if view.window_binding == binding {
                        view.mcp_intent(
                            event.token,
                            event.intent.clone(),
                            event.input.clone(),
                            window,
                            cx,
                        );
                    }
                }),
            );
    }
    pub(crate) fn open_mcp(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down
            || self.close_dialog
            || self.projects.view.read(cx).is_open()
            || self.connections.open
            || self.connections.picker
            || !self.connections.switches.is_empty()
            || self.projects.operation.is_some()
        {
            return;
        }
        self.cancel_queue_drag(window, cx);
        self.close_queue_detail(true, window, cx);
        self.sidebar_menu = None;
        self.compaction_menu = None;
        self.quick_open
            .update(cx, |v, cx| v.close(false, window, cx));
        self.mcp.open = true;
        if self.mcp.scope.is_none() {
            self.mcp.presentation.project_path = self.project.display().to_string();
        }
        self.mcp.view.update(cx, |v, cx| v.show(window, cx));
        self.update_mcp_chat_status();
        if self.mcp.loaded.is_none() && !self.mcp.busy() {
            self.load_mcp(cx);
        } else {
            if self.mcp.scope.as_ref().is_some_and(|s| !s.matches(self)) {
                self.mcp.presentation.ready = false;
                self.mcp.presentation.notice="This retained draft belongs to another saved project. Reload only after reviewing or discarding it.".into();
            }
            self.mcp.publish(cx);
        }
    }
    pub(crate) fn request_mcp_close(&mut self, cx: &mut Context<Self>) {
        self.mcp.view.update(cx, |v, cx| v.request_close(cx));
    }
    fn update_mcp_chat_status(&mut self) {
        self.mcp.presentation.chat_label = self.record.title.clone();
        if self.connections.presentation.mode == crate::launch_authority::AuthorityMode::Native {
            self.mcp.presentation.editing = false;
            self.mcp.presentation.can_enable_editing = false;
            return;
        }
        self.mcp.presentation.editing = self.record.tool_mode == ChatToolMode::Editing
            && self.record.connection_id.is_some()
            && self.controller.configured()
            && !self.loading
            && !self.load_failed;
        self.mcp.presentation.can_enable_editing = self.record.tool_mode == ChatToolMode::ReadOnly
            && self.record.connection_id.is_some()
            && self.records.iter().any(|r| r.id == self.record.id)
            && !self.pending
            && !self.chat_is_archived(&self.record.id)
            && !self.loading
            && !self.load_failed
            && !self.busy
            && !self.controller.is_retired();
    }
    pub(crate) fn sync_mcp_status(&mut self, cx: &mut Context<Self>) {
        if !self.mcp.open {
            return;
        }
        let before = (
            self.mcp.presentation.editing,
            self.mcp.presentation.can_enable_editing,
            self.mcp.presentation.busy,
            self.mcp.presentation.unknown_id.clone(),
            self.mcp.presentation.pending_results,
        );
        self.update_mcp_chat_status();
        if self.mcp.mode_pending && !self.chat_mode_operations.contains_key(&self.record.id) {
            self.mcp.mode_pending = false;
            self.mcp.presentation.notice = if self.record.tool_mode == ChatToolMode::Editing {
                "Editing tools apply to the next turn. MCP still requires an explicit one-shot confirmation.".into()
            } else {
                self.error.clone().unwrap_or_else(||"The editing-mode change did not complete. Review this chat's status before trying again.".into())
            };
        }
        let status = self.mcp.manager.as_ref().map(|m| m.status());
        let after = (
            self.mcp.presentation.editing,
            self.mcp.presentation.can_enable_editing,
            self.mcp.busy() || self.mcp.mode_pending || status.as_ref().is_some_and(|s| s.busy),
            status.as_ref().and_then(|s| s.unknown_id.clone()),
            status.as_ref().map_or(0, |s| s.pending_results),
        );
        if before != after {
            self.mcp.publish(cx);
        }
    }
    fn load_mcp(&mut self, cx: &mut Context<Self>) {
        if self.connections.presentation.mode == crate::launch_authority::AuthorityMode::Native {
            self.mcp.presentation.ready = false;
            self.mcp.presentation.notice =
                "MCP configuration and tools are unavailable for native connection-only chats."
                    .into();
            self.mcp.publish(cx);
            return;
        }
        if self.mcp.busy() || self.mcp.admission_blocked {
            return;
        }
        let id = uuid::Uuid::new_v4();
        let cancel = CancellationToken::new();
        self.mcp.operation = Some(Operation {
            id,
            kind: OperationKind::Load,
            cancel: cancel.clone(),
        });
        self.mcp.presentation.ready = false;
        self.mcp.presentation.notice = "Loading this project's saved MCP configuration…".into();
        self.mcp.publish(cx);
        let authority = self.mcp.authority.clone();
        let runtime = self.runtime.clone();
        let workspace = self.workspace.clone();
        let primary = self.project.clone();
        let task = cx.background_executor().spawn(async move {
            let project_id = {
                let store = workspace
                    .lock()
                    .map_err(|_| "The workspace is unavailable.".to_owned())?;
                if store.is_uncertain() {
                    return Err("The workspace has an unconfirmed save.".into());
                }
                let snapshot = store.snapshot();
                if snapshot.project != primary {
                    return Err("The selected project changed.".into());
                }
                snapshot
                    .project_id
                    .ok_or("Save and trust this project in Projects before configuring MCP.")?
            };
            let projects = authority.load().map_err(|e| e.to_string())?;
            let project = projects
                .projects()
                .iter()
                .find(|p| p.id == project_id && p.path == primary && p.trusted)
                .cloned()
                .ok_or("The selected project is no longer saved and trusted.")?;
            let loaded = authority.load_mcp(&project).map_err(|e| e.to_string())?;
            let manager = runtime.mcp_manager().map_err(|e| e.to_string())?;
            if manager.project_id() != project.id || cancel.is_cancelled() {
                return Err(
                    "MCP configuration loading was cancelled or its project changed.".into(),
                );
            }
            let applied = manager.configuration_matches(&loaded);
            let latest = if applied {
                manager
                    .latest_result(cancel)
                    .await
                    .map_err(|e| e.to_string())
            } else {
                Ok(None)
            };
            Ok::<_, String>((
                Scope { project, workspace },
                loaded,
                manager,
                applied,
                latest,
            ))
        });
        cx.spawn(async move|owner,cx|{let result=task.await;let _=owner.update(cx,|view,cx|{
            if view.mcp.operation.as_ref().map(|o|o.id)!=Some(id){return;}
            view.mcp.operation=None;
            match result{
                Ok((scope,loaded,manager,applied,latest)) if scope.matches(view)=>{
                    view.mcp.presentation.project_id=Some(scope.project.id.clone());view.mcp.presentation.project_path=scope.project.path.display().to_string();
                    view.mcp.presentation.configured_headers=loaded.configured_header_servers();
                    let config=loaded.configuration_json_without_headers();
                    view.mcp.presentation.servers=configured_names(&config);view.mcp.presentation.tools.clear();
                    let receipt_error=latest.as_ref().err().cloned();
                    let latest=latest.ok().flatten();
                    let had_result=latest.is_some();
                    let output=latest.and_then(|value|serde_json::to_string_pretty(&value).ok()).unwrap_or_default();
                    view.mcp.view.update(cx,|v,cx|{v.install_configuration(config,cx);v.set_output(output,cx);});
                    let unknown=manager.status().outcome_unknown;
                    view.mcp.scope=Some(scope);view.mcp.loaded=Some(loaded);view.mcp.manager=Some(manager);view.mcp.presentation.ready=true;
                    view.mcp.presentation.configuration_applied=applied;
                    view.mcp.presentation.receipt_read_failed=receipt_error.is_some();
                    view.mcp.presentation.notice=if !applied {
                        "Saved MCP configuration changed outside this Inspector. Review and explicitly save/apply it while the project is idle before discovery or invocation.".into()
                    } else if let Some(error)=receipt_error {
                        format!("Saved configuration loaded, but the latest retained result could not be read: {error}. One-shot invocation is blocked until a successful reload.")
                    } else if had_result {
                        if unknown { "Latest retained MCP result shown. It may precede the unresolved invocation; reading does not acknowledge or retry its effects.".into() }
                        else { "Latest retained MCP result shown. Reading it did not invoke or retry a tool.".into() }
                    } else { "Loaded saved MCP configuration. Discovery and invocation send nothing until requested.".into() };
                }
                Ok(_)=>view.mcp.presentation.notice="The selected project changed; the previous draft was preserved.".into(),
                Err(error)=>view.mcp.presentation.notice=error,
            }
            view.mcp.publish(cx);
        });}).detach();
    }
    pub(crate) fn mcp_intent(
        &mut self,
        token: McpToken,
        intent: McpIntent,
        input: Option<McpInput>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let allowed = self.mcp.open
            && token == self.mcp.view.read(cx).token()
            && self.mcp.presentation.allows(&intent)
            && !self.shutting_down;
        self.mcp.publish(cx);
        if !allowed {
            return;
        }
        use McpIntent::*;
        if matches!(
            intent,
            Close | KeepDraftClose | DiscardClose | CancelConfirmation | CancelOperation
        ) {
            match intent {
                CancelConfirmation => {
                    self.mcp.confirmation = None;
                    self.mcp.presentation.confirmation = None;
                    self.mcp.presentation.close_confirmation = false;
                }
                CancelOperation => {
                    if self.mcp.cancel() {
                        self.mcp.presentation.notice="Cancellation requested. Waiting for a durable outcome; nothing will retry automatically.".into();
                    }
                }
                Close => {
                    if self.mcp.busy() {
                        self.mcp.presentation.notice = if self.mcp.cancel() {
                            "Cancellation requested. Wait for the operation to settle before closing.".into()
                        } else {
                            "Wait for the current MCP acknowledgment to finish before closing."
                                .into()
                        };
                    } else if self.mcp.view.read(cx).dirty(cx) {
                        self.mcp.presentation.close_confirmation = true;
                    } else {
                        self.close_mcp(window, cx);
                        return;
                    }
                }
                DiscardClose => {
                    self.mcp.view.update(cx, |v, cx| v.discard(cx));
                    self.close_mcp(window, cx);
                    return;
                }
                KeepDraftClose => {
                    self.close_mcp(window, cx);
                    return;
                }
                _ => {}
            }
            self.mcp.publish(cx);
            return;
        }
        if matches!(intent, Reload) {
            if self.mcp.view.read(cx).dirty(cx) {
                self.mcp.confirmation = Some(Confirmation::Reload);
                self.mcp.presentation.confirmation=Some(("Discard this draft and reload?".into(),"The saved project configuration will replace the unsaved configuration and masked header replacements.".into(),"Discard and reload".into()));
                self.mcp.publish(cx);
            } else {
                self.load_mcp(cx);
            }
            return;
        }
        if matches!(intent, Confirm) && matches!(self.mcp.confirmation, Some(Confirmation::Reload))
        {
            self.confirm_mcp(window, cx);
            return;
        }
        if self.mcp.scope.as_ref().is_none_or(|s| !s.matches(self)) {
            self.mcp.presentation.notice="This action belongs to a different saved project. Its captured action was discarded; the draft was kept.".into();
            self.mcp.confirmation = None;
            self.mcp.presentation.confirmation = None;
            self.mcp.publish(cx);
            return;
        }
        if matches!(intent, Confirm) {
            self.confirm_mcp(window, cx);
            return;
        }
        match &intent {
            SelectServer(server) => {
                if self.mcp.presentation.servers.contains(server) {
                    self.mcp.presentation.tools.clear();
                    self.mcp
                        .view
                        .update(cx, |v, cx| v.select_server(server.clone(), cx));
                }
            }
            SelectTool(tool) => {
                if self
                    .mcp
                    .presentation
                    .tools
                    .iter()
                    .any(|(name, _)| name == tool)
                {
                    self.mcp
                        .view
                        .update(cx, |v, cx| v.select_tool(tool.clone(), cx));
                }
            }
            SelectHeader(server) => self
                .mcp
                .view
                .update(cx, |v, cx| v.select_header(server.clone(), cx)),
            PreviousPage | NextPage => self
                .mcp
                .view
                .update(cx, |v, cx| v.change_page(matches!(intent, NextPage), cx)),
            _ => {}
        }
        if matches!(
            intent,
            SelectServer(_) | SelectTool(_) | SelectHeader(_) | PreviousPage | NextPage
        ) {
            self.mcp.publish(cx);
            return;
        }
        let Some(input) = input else {
            self.mcp.presentation.notice="A header input was rejected; existing draft bytes were preserved. Correct the input before proceeding.".into();
            self.mcp.publish(cx);
            return;
        };
        match intent {
            Save => {
                if let Err(error) = config_input(&input) {
                    self.mcp.presentation.notice = error;
                } else {
                    self.mcp.confirmation = Some(Confirmation::Save(input));
                    self.mcp.presentation.confirmation = Some((
                        "Trust these MCP endpoints?".into(),
                        format!(
                            "Save for project {} at {}. Authenticated MCP endpoints can act with the supplied account permissions. Only explicit headers go to that server. Saving waits for the whole project to be idle and applies only after the vault confirms the save.",
                            self.mcp.presentation.project_id.as_deref().unwrap_or(""),
                            self.mcp.presentation.project_path
                        ),
                        "Trust, save and apply".into(),
                    ));
                }
            }
            Invoke => match arguments_input(&input) {
                Err(e) => self.mcp.presentation.notice = e,
                Ok(arguments) => {
                    self.mcp.presentation.confirmation=Some((format!("Invoke {} / {} once?",input.server,input.tool),"Exactly one invocation will be sent. It may change external state. Review the schema and arguments first. Cancellation may leave the outcome unknown; no automatic retry is performed.".into(),"Invoke once".into()));
                    self.mcp.confirmation = Some(Confirmation::Invoke {
                        input,
                        chat: ChatTarget::capture(self),
                        arguments,
                    });
                }
            },
            Acknowledge => {
                if let Some(id) = self
                    .mcp
                    .manager
                    .as_ref()
                    .and_then(|m| m.status().unknown_id)
                {
                    self.mcp.confirmation = Some(Confirmation::Acknowledge(id));
                    self.mcp.presentation.confirmation=Some(("Have you checked the previous invocation's effects?".into(),"Acknowledging permits a new invocation for this project. It does not retry, cancel or undo the previous invocation.".into(),"I checked — acknowledge".into()));
                }
            }
            EnableEditing => {
                self.mcp.confirmation =
                    Some(Confirmation::EnableEditing(ChatTarget::capture(self)));
                self.mcp.presentation.confirmation=Some(("Enable editing tools for this saved chat?".into(),"Future turns may change files or external state using this project's available tools and account permissions. This one-way change applies to this saved chat and does not change other chats. Unimplemented native tools and stdio remain unavailable.".into(),"Enable Editing".into()));
            }
            Refresh | ListTools | Describe => {
                self.start_mcp_request(intent, input, None, cx);
                return;
            }
            _ => {}
        }
        self.mcp.publish(cx);
    }
    fn close_mcp(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.mcp.open = false;
        self.mcp.confirmation = None;
        self.mcp.presentation.confirmation = None;
        self.mcp.presentation.close_confirmation = false;
        self.mcp.view.update(cx, |v, cx| v.close(true, window, cx));
        self.mcp.publish(cx);
    }
    fn confirm_mcp(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let confirmation = self.mcp.confirmation.take();
        self.mcp.presentation.confirmation = None;
        match confirmation {
            Some(Confirmation::Save(input)) => {
                self.save_mcp(input, cx);
                return;
            }
            Some(Confirmation::Invoke {
                input,
                chat,
                arguments,
            }) => {
                if chat.matches(self)
                    && self.record.tool_mode == ChatToolMode::Editing
                    && !self.chat_is_archived(&chat.id)
                    && self.controller.configured()
                {
                    self.start_mcp_request(
                        McpIntent::Invoke,
                        input,
                        Some((self.controller.clone(), arguments)),
                        cx,
                    );
                    return;
                }
                self.mcp.presentation.notice =
                    "The selected editing chat changed before confirmation. Nothing was invoked."
                        .into();
            }
            Some(Confirmation::Acknowledge(expected)) => {
                self.acknowledge_mcp(expected, cx);
                return;
            }
            Some(Confirmation::EnableEditing(chat)) => {
                if chat.matches(self) && self.mcp.presentation.can_enable_editing {
                    self.enable_chat_editing_after_confirmation(&chat.id, cx);
                    self.mcp.mode_pending = self.chat_mode_operations.contains_key(&chat.id);
                    self.mcp.presentation.notice = if self.mcp.mode_pending {
                        "Changing this saved chat to Editing…".into()
                    } else {
                        self.error.clone().unwrap_or_else(|| {
                            "This saved chat must be idle before changing its tools.".into()
                        })
                    };
                } else {
                    self.mcp.presentation.notice =
                        "The saved chat changed before confirmation. Its mode was not changed."
                            .into();
                }
            }
            Some(Confirmation::Reload) => {
                self.load_mcp(cx);
                return;
            }
            None => {}
        }
        self.mcp.publish(cx);
    }
    fn mcp_idle_error(&self) -> Option<String> {
        if self.projects.operation.is_some()
            || !self.chat_mode_operations.is_empty()
            || !self.connections.switches.is_empty()
            || self.connections.operation.is_some()
            || !self.chat_mode_blocked.is_empty()
            || !self.organization_operations.is_empty()
            || self.archive_visibility_writes != 0
            || self.known_catalog_uncertainty
            || !self.recoveries.is_empty()
            || self
                .queued_cancellations
                .keys()
                .any(|id| self.has_pending_cancel(id))
        {
            return Some(
                "Finish pending chat and workspace changes before saving MCP configuration.".into(),
            );
        }
        for chat in std::iter::once(&self.chat).chain(self.inactive.values()) {
            let s = chat.controller.snapshot_shared();
            if chat.busy
                || chat.loading
                || chat.load_failed
                || chat.inflight_submission.is_some()
                || chat.queue_operation.is_some()
                || chat.cancel_operation.is_some()
                || chat.begin_operation.is_some()
                || chat.editing.is_some()
                || chat.retained_edit.is_some()
                || chat.edit_recovery.blocked
                || s.state == RunState::Running
                || !s.pending.is_empty()
                || s.active.is_some()
                || s.active_reply.is_some()
                || s.edit.is_some()
            {
                return Some("Stop this project's work and finish queued messages or held edits before saving MCP.".into());
            }
        }
        None
    }
    fn save_mcp(&mut self, input: McpInput, cx: &mut Context<Self>) {
        if let Some(error) = self.mcp_idle_error() {
            self.mcp.presentation.notice = error;
            self.mcp.publish(cx);
            return;
        }
        let (Some(scope), Some(baseline), Some(manager)) = (
            self.mcp.scope.clone(),
            self.mcp.loaded.clone(),
            self.mcp.manager.clone(),
        ) else {
            return;
        };
        if !scope.matches(self) || self.mcp.busy() || self.mcp.admission_blocked {
            return;
        }
        let loaded: Vec<_> = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .map(|c| LoadedChat {
                record: c.record.clone(),
                controller: c.controller.clone(),
            })
            .collect();
        let unloaded = self
            .records
            .iter()
            .filter(|r| !loaded.iter().any(|c| c.record.id == r.id))
            .cloned()
            .collect();
        let change = McpConfigurationSave {
            authority: self.mcp.authority.clone(),
            baseline,
            project: scope.project.clone(),
            manager,
            workspace: self.workspace.clone(),
            configuration: input.configuration.clone(),
            headers: input.headers.clone(),
            loaded,
            unloaded,
        };
        let id = uuid::Uuid::new_v4();
        let cancel = CancellationToken::new();
        self.mcp.operation = Some(Operation {
            id,
            kind: OperationKind::Save,
            cancel: cancel.clone(),
        });
        self.mcp.presentation.notice =
            "Saving MCP configuration, then applying the confirmed revision…".into();
        self.mcp.publish(cx);
        let task = cx.background_executor().spawn(change.apply(cancel));
        cx.spawn(async move |owner, cx| {
            let result = task.await;
            let _ = owner.update(cx, |view, cx| view.finish_mcp_save(id, scope, result, cx));
        })
        .detach();
    }
    fn finish_mcp_save(
        &mut self,
        id: uuid::Uuid,
        scope: Scope,
        result: Result<LoadedMcp, McpSaveFailure>,
        cx: &mut Context<Self>,
    ) {
        if !scope.matches(self) {
            return;
        }
        if result.as_ref().is_err_and(|e| e.keep_blocked) {
            self.mcp.admission_blocked = true;
        }
        if self.mcp.operation.as_ref().map(|o| o.id) != Some(id) {
            self.mcp.publish(cx);
            return;
        }
        self.mcp.operation = None;
        match result {
            Ok(loaded) => {
                let config = loaded.configuration_json_without_headers();
                self.mcp.presentation.servers = configured_names(&config);
                self.mcp.presentation.tools.clear();
                self.mcp.presentation.configured_headers = loaded.configured_header_servers();
                self.mcp.view.update(cx, |v, cx| {
                    v.install_configuration(config, cx);
                    v.set_output(String::new(), cx);
                });
                self.mcp.loaded = Some(loaded);
                self.mcp.presentation.configuration_applied = true;
                self.mcp.presentation.notice =
                    "MCP configuration saved and applied. No tool was invoked.".into();
            }
            Err(error) => {
                self.mcp.presentation.notice = error.message;
                if error.unconfirmed {
                    self.mcp.presentation.ready = false;
                }
            }
        }
        self.mcp.publish(cx);
    }
    fn start_mcp_request(
        &mut self,
        intent: McpIntent,
        input: McpInput,
        invoke: Option<(Arc<Controller>, Value)>,
        cx: &mut Context<Self>,
    ) {
        let (Some(scope), Some(manager)) = (self.mcp.scope.clone(), self.mcp.manager.clone())
        else {
            return;
        };
        if self.mcp.busy() || !scope.matches(self) {
            return;
        }
        let id = uuid::Uuid::new_v4();
        let cancel = CancellationToken::new();
        let kind = if invoke.is_some() {
            OperationKind::Invoke
        } else {
            OperationKind::Discovery
        };
        self.mcp.operation = Some(Operation {
            id,
            kind,
            cancel: cancel.clone(),
        });
        self.mcp.presentation.notice = if kind == OperationKind::Invoke {
            "Invoking exactly once. No automatic retry.".into()
        } else {
            "Discovering MCP tools. No tool invocation will be sent.".into()
        };
        self.mcp.publish(cx);
        let task_intent = intent.clone();
        let task = cx.background_executor().spawn(async move {
            match task_intent {
                McpIntent::Refresh => manager.list_servers(cancel).await,
                McpIntent::ListTools => manager.list_tools(&input.server, cancel).await,
                McpIntent::Describe => {
                    manager
                        .describe(json!([{"server":input.server,"tool":input.tool}]), cancel)
                        .await
                }
                McpIntent::Invoke => {
                    let (controller, arguments) = invoke.expect("confirmed invocation");
                    controller
                        .mcp_invoke_once(
                            input.server.clone(),
                            input.tool.clone(),
                            arguments,
                            true,
                            cancel,
                        )
                        .await
                }
                _ => unreachable!(),
            }
        });
        cx.spawn(async move|owner,cx|{let result=task.await;let _=owner.update(cx,|view,cx|{
            if !scope.matches(view)||view.mcp.operation.as_ref().map(|o|o.id)!=Some(id){return;}
            view.mcp.operation=None;
            match result{
                Ok(value)=>{
                    match intent{
                        McpIntent::Refresh=>{view.mcp.presentation.servers=value.get("servers").and_then(Value::as_array).into_iter().flatten().filter_map(|v|v.get("server").and_then(Value::as_str).map(str::to_owned)).collect();view.mcp.presentation.tools.clear();}
                        McpIntent::ListTools=>{view.mcp.presentation.tools=value.get("tools").and_then(Value::as_array).into_iter().flatten().filter_map(|v|Some((v.get("name")?.as_str()?.to_owned(),v.get("description").and_then(Value::as_str).unwrap_or("").to_owned()))).collect();}
                        _=>{}
                    }
                    let text=serde_json::to_string_pretty(&value).unwrap_or_else(|_|"MCP result could not be displayed.".into());view.mcp.view.update(cx,|v,cx|v.set_output(text,cx));
                    view.mcp.presentation.notice=if kind==OperationKind::Invoke{"Invocation settled. Review the result; it will not be retried automatically.".into()}else{"Discovery completed. No tool was invoked.".into()};
                }
                Err(error)=>view.mcp.presentation.notice=error.to_string(),
            }view.mcp.publish(cx);
        });}).detach();
    }
    fn acknowledge_mcp(&mut self, expected: String, cx: &mut Context<Self>) {
        let (Some(scope), Some(manager)) = (self.mcp.scope.clone(), self.mcp.manager.clone())
        else {
            return;
        };
        if self.mcp.busy() || !scope.matches(self) {
            return;
        }
        let id = uuid::Uuid::new_v4();
        self.mcp.operation = Some(Operation {
            id,
            kind: OperationKind::Acknowledge,
            cancel: CancellationToken::new(),
        });
        self.mcp.publish(cx);
        let task = cx
            .background_executor()
            .spawn(async move { manager.acknowledge_unknown(&expected, true) });
        cx.spawn(async move|owner,cx|{let result=task.await;let _=owner.update(cx,|view,cx|{
            if !scope.matches(view)||view.mcp.operation.as_ref().map(|o|o.id)!=Some(id){return;}view.mcp.operation=None;
            view.mcp.presentation.notice=match result{Ok(())=>"The exact previous unknown outcome was acknowledged. Nothing was retried or undone.".into(),Err(e)=>e.to_string()};view.mcp.publish(cx);
        });}).detach();
    }
}
fn configured_names(configuration: &str) -> Vec<String> {
    serde_json::from_str::<Value>(configuration)
        .ok()
        .and_then(|v| {
            v.get("servers")
                .and_then(Value::as_object)
                .map(|o| o.keys().cloned().collect())
        })
        .unwrap_or_default()
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "mcp_inspector_controller_tests.rs"]
mod tests;
