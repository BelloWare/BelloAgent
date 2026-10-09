//! Read-only, point-in-time restored sidebar state. No controller is opened,
//! recovered, resumed or retained for an unloaded row.
use crate::{AgentView, workspace_lifetime::WindowBinding};
#[cfg(test)]
use bello_agent_core::session::SessionInspectionLease;
use bello_agent_core::{
    RunState, Session,
    workspace::{ChatMaterialization, ChatRecord, WorkspaceStore},
};
use gpui::Context;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, Weak},
    time::SystemTime,
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SavedRunState {
    Ready,
    Interrupted,
    Paused,
    Failed,
    Unknown,
}
impl SavedRunState {
    fn label(self) -> &'static str {
        match self {
            Self::Ready => "Ready",
            Self::Interrupted => "Interrupted",
            Self::Paused => "Paused",
            Self::Failed => "Failed",
            Self::Unknown => "Unavailable",
        }
    }
    fn from_session(session: &Session) -> Self {
        // HistoryReader.RunStateRecord.hold: active wins, failures are not
        // paused holds, stopped empty queues still wait for Resume. Rust
        // pending/held work also cannot resume merely because a row is read.
        if session.state == RunState::Running || session.active.is_some() {
            Self::Interrupted
        } else if session.state == RunState::Error {
            Self::Failed
        } else if session.state == RunState::Paused
            || session.queue_paused
            || !session.pending.is_empty()
            || session.edit.is_some()
        {
            Self::Paused
        } else {
            Self::Ready
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileIdentity {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}
impl FileIdentity {
    pub(crate) fn read(path: &Path) -> Option<Self> {
        let metadata = fs::symlink_metadata(path).ok()?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return None;
        }
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Some(Self {
            length: metadata.len(),
            modified: metadata.modified().ok()?,
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
        })
    }
}

#[cfg(test)]
fn inspect(record: &ChatRecord) -> SavedRunState {
    inspect_then(record, || {})
}
#[cfg(test)]
fn inspect_then(record: &ChatRecord, after_read: impl FnOnce()) -> SavedRunState {
    inspect_summary_then(record, after_read).0
}

// One lease, one parse, small output summary. Never acquire a second scanner.
#[cfg(test)]
fn inspect_summary_then(
    record: &ChatRecord,
    after_read: impl FnOnce(),
) -> (
    SavedRunState,
    bello_agent_core::read_observation::OutputProjection,
    Option<FileIdentity>,
) {
    use bello_agent_core::read_observation::{OutputProjection, project_outputs};
    let unknown = || (SavedRunState::Unknown, OutputProjection::Unknown, None);
    if record.materialization != ChatMaterialization::CheckpointRequired {
        return unknown();
    }
    let Some(before) = FileIdentity::read(&record.snapshot) else {
        return unknown();
    };
    let Ok(lease) = SessionInspectionLease::acquire(&record.snapshot, &record.id) else {
        return unknown();
    };
    let state = SavedRunState::from_session(lease.snapshot());
    let summary = project_outputs(lease.snapshot());
    drop(lease);
    after_read();
    if FileIdentity::read(&record.snapshot).as_ref() != Some(&before) {
        unknown()
    } else {
        (state, summary, Some(before))
    }
}

fn inspect_coordinated(
    record: &ChatRecord,
    permit: &mut bello_agent_core::inspection::InspectionPermit,
) -> bello_agent_core::Result<(
    SavedRunState,
    bello_agent_core::read_observation::OutputProjection,
    Option<FileIdentity>,
)> {
    use bello_agent_core::{
        Error,
        read_observation::{OutputProjection, project_outputs},
    };
    let unknown = || (SavedRunState::Unknown, OutputProjection::Unknown, None);
    if record.materialization != ChatMaterialization::CheckpointRequired {
        return Ok(unknown());
    }
    let Some(before) = FileIdentity::read(&record.snapshot) else {
        return Ok(unknown());
    };
    let cancel = permit.cancellation().clone();
    let lease = match permit.inspect(&record.snapshot, &record.id) {
        Ok(lease) => lease,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(_) => return Ok(unknown()),
    };
    let state = SavedRunState::from_session(lease.snapshot());
    let summary = project_outputs(lease.snapshot());
    drop(lease);
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(
        if FileIdentity::read(&record.snapshot).as_ref() != Some(&before) {
            unknown()
        } else {
            (state, summary, Some(before))
        },
    )
}

struct Scope {
    project: PathBuf,
    workspace: Weak<Mutex<WorkspaceStore>>,
    window: Option<WindowBinding>,
    navigation: u64,
    selected_load: u64,
}
impl Scope {
    fn capture(view: &AgentView) -> Self {
        Self {
            project: view.project.clone(),
            workspace: Arc::downgrade(&view.workspace),
            window: view.window_binding,
            navigation: view.navigation_generation,
            selected_load: view.load_generation,
        }
    }
    fn matches(&self, view: &AgentView) -> bool {
        self.project == view.project
            && self.workspace.ptr_eq(&Arc::downgrade(&view.workspace))
            && self.window.is_some()
            && self.window == view.window_binding
            && self.navigation == view.navigation_generation
            && self.selected_load == view.load_generation
    }
}
struct Observation {
    record: ChatRecord,
    state: SavedRunState,
    file_identity: Option<FileIdentity>,
}
#[derive(Default)]
pub(crate) struct SidebarRunStates {
    cancel: bello_agent_core::inspection::InspectionCancellation,
    scope: Option<Scope>,
    epoch: Uuid,
    observations: BTreeMap<String, Observation>,
    // Retain this even after scope invalidation: at most one full session is
    // parsed at a time, including across navigation and window replacement.
    in_flight: Option<Uuid>,
}
impl SidebarRunStates {
    pub(crate) fn cancel_pending(&mut self) {
        self.cancel.cancel();
        self.scope = None;
    }
    fn renew_scope(&mut self) {
        self.cancel.cancel();
        self.cancel = bello_agent_core::inspection::InspectionCancellation::new();
    }
}
impl Drop for SidebarRunStates {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

struct Target {
    request: Uuid,
    epoch: Uuid,
    record: ChatRecord,
}

impl AgentView {
    /// Called from render, but only queues background work. Completed errors
    /// are cached too: redraws cannot create an unbounded busy-writer retry.
    pub(crate) fn refresh_sidebar_run_states(&mut self, cx: &mut Context<Self>) {
        if self.shutting_down || self.close_ready || self.known_catalog_uncertainty {
            self.sidebar_run_states.cancel_pending();
            self.sidebar_run_states.scope = None;
            self.sidebar_run_states.observations.clear();
            self.sidebar_run_states.epoch = Uuid::new_v4();
            return;
        }
        if self
            .sidebar_run_states
            .scope
            .as_ref()
            .is_none_or(|scope| !scope.matches(self))
        {
            self.sidebar_run_states.renew_scope();
            self.sidebar_run_states.scope = Some(Scope::capture(self));
            self.sidebar_run_states.epoch = Uuid::new_v4();
            self.sidebar_run_states.observations.clear();
        }
        // Exact records invalidate path/catalog changes; loaded ownership
        // permanently supersedes a saved observation for that row.
        let mut observations = std::mem::take(&mut self.sidebar_run_states.observations);
        observations.retain(|id, observation| {
            self.chat_ref(id).is_none()
                && self
                    .records
                    .iter()
                    .any(|record| record == &observation.record)
        });
        self.sidebar_run_states.observations = observations;
        if self.sidebar_run_states.in_flight.is_some() || self.window_binding.is_none() {
            return;
        }
        let Some(record) = self.records.iter().find(|record| {
            self.chat_ref(&record.id).is_none()
                && !self
                    .sidebar_run_states
                    .observations
                    .contains_key(&record.id)
        }) else {
            return;
        };
        let target = Target {
            request: Uuid::new_v4(),
            epoch: self.sidebar_run_states.epoch,
            record: record.clone(),
        };
        self.sidebar_run_states.in_flight = Some(target.request);
        let record = target.record.clone();
        let workspace = self.workspace.clone();
        let cancel = self.sidebar_run_states.cancel.clone();
        let task = cx.background_executor().spawn(async move {
            let lane = workspace
                .lock()
                .map_err(|_| bello_agent_core::Error::Invalid("Workspace is unavailable".into()))?
                .inspection_coordinator();
            let mut permit = lane.background(&cancel).await?;
            inspect_coordinated(&record, &mut permit)
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                let (state, summary, file_identity) = match outcome {
                    Ok(value) => value,
                    Err(bello_agent_core::Error::Cancelled) => {
                        if view.sidebar_run_states.in_flight == Some(target.request) {
                            view.sidebar_run_states.in_flight = None;
                        }
                        view.refresh_sidebar_run_states(cx);
                        cx.notify();
                        return;
                    }
                    Err(_) => (
                        SavedRunState::Unknown,
                        bello_agent_core::read_observation::OutputProjection::Unknown,
                        None,
                    ),
                };
                let record = target.record.clone();
                let accepted = view.finish_sidebar_run_state(target, state);
                if accepted
                    && let Some(observation) =
                        view.sidebar_run_states.observations.get_mut(&record.id)
                {
                    observation.file_identity = file_identity;
                }
                if accepted
                    && view.chat_ref(&record.id).is_none()
                    && view
                        .sidebar_run_states
                        .observations
                        .get(&record.id)
                        .is_some_and(|o| o.record == record)
                    && let bello_agent_core::read_observation::OutputProjection::Known(summary) =
                        summary
                {
                    view.inspect_read_baseline(
                        &record,
                        &summary,
                        state != SavedRunState::Interrupted,
                        cx,
                    );
                }
                view.refresh_sidebar_run_states(cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn finish_sidebar_run_state(&mut self, target: Target, state: SavedRunState) -> bool {
        if self.sidebar_run_states.in_flight != Some(target.request) {
            return false;
        }
        self.sidebar_run_states.in_flight = None;
        if self.shutting_down
            || self.close_ready
            || self.known_catalog_uncertainty
            || self.sidebar_run_states.epoch != target.epoch
            || self
                .sidebar_run_states
                .scope
                .as_ref()
                .is_none_or(|scope| !scope.matches(self))
            || self.chat_ref(&target.record.id).is_some()
            || !self.records.iter().any(|record| record == &target.record)
        {
            return false;
        }
        self.sidebar_run_states.observations.insert(
            target.record.id.clone(),
            Observation {
                record: target.record,
                state,
                file_identity: None,
            },
        );
        true
    }

    pub(crate) fn sidebar_saved_identity(&self, record: &ChatRecord) -> Option<FileIdentity> {
        if self.shutting_down
            || self.close_ready
            || self.known_catalog_uncertainty
            || self.chat_ref(&record.id).is_some()
            || self
                .sidebar_run_states
                .scope
                .as_ref()
                .is_none_or(|scope| !scope.matches(self))
        {
            return None;
        }
        self.sidebar_run_states
            .observations
            .get(&record.id)
            .filter(|o| o.record == *record && o.state != SavedRunState::Unknown)
            .and_then(|o| o.file_identity.clone())
    }
    pub(crate) fn invalidate_saved_read_target(&mut self, record: &ChatRecord) {
        if let Some(observation) = self
            .sidebar_run_states
            .observations
            .get_mut(&record.id)
            .filter(|o| o.record == *record)
        {
            observation.state = SavedRunState::Unknown;
            observation.file_identity = None;
        }
    }

    pub(crate) fn sidebar_run_status(&self, record: &ChatRecord) -> &'static str {
        if let Some(chat) = self.chat_ref(&record.id) {
            // A loaded controller always wins, even when its load failed or
            // it owns a live persistence fence. Never replace it with disk.
            return if chat.loading {
                "Preparing…"
            } else if chat.load_failed {
                "Unavailable"
            } else {
                match chat.session.state {
                    RunState::Running => "Working",
                    RunState::Error => "Failed",
                    RunState::Paused => "Paused",
                    RunState::Idle if chat.session.queue_paused => "Paused",
                    RunState::Idle => "Ready",
                }
            };
        }
        if self.shutting_down
            || self.close_ready
            || self.known_catalog_uncertainty
            || self
                .sidebar_run_states
                .scope
                .as_ref()
                .is_none_or(|scope| !scope.matches(self))
        {
            return SavedRunState::Unknown.label();
        }
        self.sidebar_run_states
            .observations
            .get(&record.id)
            .filter(|observation| observation.record == *record)
            .map_or(SavedRunState::Unknown, |observation| observation.state)
            .label()
    }
}

#[cfg(test)]
#[path = "sidebar_run_state_tests.rs"]
mod tests;
