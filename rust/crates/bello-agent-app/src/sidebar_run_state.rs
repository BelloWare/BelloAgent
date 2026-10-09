//! Read-only, point-in-time restored sidebar state. No controller is opened,
//! recovered, resumed or retained for an unloaded row.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::{
    RunState, Session,
    session::SessionInspectionLease,
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

#[derive(Debug, PartialEq, Eq)]
struct FileIdentity {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}
impl FileIdentity {
    fn read(path: &Path) -> Option<Self> {
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

fn inspect(record: &ChatRecord) -> SavedRunState {
    inspect_then(record, || {})
}

// The completion hook makes the post-read replacement race deterministic in
// tests. All metadata and checkpoint/journal reads happen on the background
// executor. This is a point-in-time observation, never a durability receipt.
fn inspect_then(record: &ChatRecord, after_read: impl FnOnce()) -> SavedRunState {
    if record.materialization != ChatMaterialization::CheckpointRequired {
        return SavedRunState::Unknown;
    }
    let Some(before) = FileIdentity::read(&record.snapshot) else {
        return SavedRunState::Unknown;
    };
    let Ok(lease) = SessionInspectionLease::acquire(&record.snapshot, &record.id) else {
        return SavedRunState::Unknown;
    };
    let state = SavedRunState::from_session(lease.snapshot());
    // Drop parsed history promptly, before returning even the small result.
    drop(lease);
    after_read();
    if FileIdentity::read(&record.snapshot).as_ref() != Some(&before) {
        SavedRunState::Unknown
    } else {
        state
    }
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
}
#[derive(Default)]
pub(crate) struct SidebarRunStates {
    scope: Option<Scope>,
    epoch: Uuid,
    observations: BTreeMap<String, Observation>,
    // Retain this even after scope invalidation: at most one full session is
    // parsed at a time, including across navigation and window replacement.
    in_flight: Option<Uuid>,
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
        let task = cx
            .background_executor()
            .spawn(async move { inspect(&record) });
        cx.spawn(async move |view, cx| {
            let state = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_sidebar_run_state(target, state);
                view.refresh_sidebar_run_states(cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn finish_sidebar_run_state(&mut self, target: Target, state: SavedRunState) {
        if self.sidebar_run_states.in_flight != Some(target.request) {
            return;
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
            return;
        }
        self.sidebar_run_states.observations.insert(
            target.record.id.clone(),
            Observation {
                record: target.record,
                state,
            },
        );
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
