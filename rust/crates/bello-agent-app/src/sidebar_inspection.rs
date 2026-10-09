//! One worker adapter for restored run/read and explicitly requested search.
//! Production currently requests run/read only. Search lifecycle/UI wiring is a
//! separate gate; this module does not create a second scanner or dispatcher.
use crate::sidebar_run_state::{FileIdentity, SavedRunState};
use bello_agent_core::{
    Error, Result,
    inspection::InspectionPermit,
    read_observation::{OutputProjection, project_outputs},
    sidebar_search::{SearchError, UnloadedObserved, reconciliation::SearchWork},
    workspace::{ChatMaterialization, ChatRecord},
};

pub(crate) struct InspectionDemand {
    run_read: bool,
    search: Option<SearchWork>,
}
impl InspectionDemand {
    pub(crate) fn run_read() -> Self {
        Self {
            run_read: true,
            search: None,
        }
    }
    /// Demand is frozen before dispatch. A subscriber arriving after dispatch
    /// requires a queued-again pass; it cannot freshen the old source interval.
    #[allow(dead_code)] // Explicit non-UI API; production search remains gated.
    pub(crate) fn search(work: SearchWork) -> Self {
        Self {
            run_read: false,
            search: Some(work),
        }
    }
    #[allow(dead_code)] // Coalesce before dispatch only.
    pub(crate) fn include_run_read(mut self) -> Self {
        self.run_read = true;
        self
    }
}
pub(crate) struct InspectionOutput {
    pub(crate) run_read: Option<(SavedRunState, OutputProjection, Option<FileIdentity>)>,
    #[allow(dead_code)] // Not served by production UI until lifecycle gates pass.
    pub(crate) search: Option<std::result::Result<UnloadedObserved, SearchError>>,
}
pub(crate) fn inspect(
    record: &ChatRecord,
    permit: &mut InspectionPermit,
    demand: InspectionDemand,
) -> Result<InspectionOutput> {
    let unknown = || InspectionOutput {
        run_read: demand.run_read.then_some((
            SavedRunState::Unknown,
            OutputProjection::Unknown,
            None,
        )),
        search: demand
            .search
            .as_ref()
            .map(|_| Err(SearchError::Unavailable)),
    };
    if record.materialization != ChatMaterialization::CheckpointRequired {
        return Ok(unknown());
    }
    let mut cancelled_search = false;
    if let Some(work) = &demand.search {
        if work.member().chat_id() != record.id
            || work.member().checkpoint_path() != record.snapshot
        {
            return Ok(unknown());
        }
        if let Err(error) = work.require_unloaded() {
            if error == SearchError::Cancelled && demand.run_read {
                cancelled_search = true;
            } else {
                return Ok(InspectionOutput {
                    search: Some(Err(error)),
                    ..unknown()
                });
            }
        }
    }
    let before = if demand.run_read {
        match FileIdentity::read(&record.snapshot) {
            Some(v) => Some(v),
            None => return Ok(unknown()),
        }
    } else {
        None
    };
    let cancel = permit.cancellation().clone();
    let active_search = demand.search.as_ref().filter(|_| !cancelled_search);
    let lease = match active_search {
        Some(work) => permit.inspect_search(work),
        None => permit.inspect(&record.snapshot, &record.id),
    };
    let lease = match lease {
        Ok(v) => v,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(_) => return Ok(unknown()),
    };
    let run_read = demand.run_read.then(|| {
        (
            SavedRunState::from_session(lease.snapshot()),
            project_outputs(lease.snapshot()),
            before.clone(),
        )
    });
    let search = if cancelled_search {
        Some(Err(SearchError::Cancelled))
    } else {
        active_search.map(|work| lease.prepare_search(work))
    };
    drop(lease);
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    let run_read = run_read.map(|summary| {
        if FileIdentity::read(&record.snapshot) != before {
            (SavedRunState::Unknown, OutputProjection::Unknown, None)
        } else {
            summary
        }
    });
    Ok(InspectionOutput { run_read, search })
}
#[cfg(test)]
#[path = "sidebar_inspection_tests.rs"]
mod tests;
