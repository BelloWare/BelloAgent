//! The project-resource half of the common saved-runtime input preparation.
//! Reads share physical ownership with image workers; no picker DTO is authority.
use super::{Configuration, Controller};
use crate::{
    Result, Submission, invalid,
    project_resources::{ProjectResourceSnapshot, ProjectResourceSource, ResourceScope},
    skills::{DependencySnapshot, SkillSelection},
};
use std::sync::{Arc, atomic::Ordering};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub(crate) struct ProjectRuntimeBinding {
    pub project_id: String,
    pub roots: Vec<std::path::PathBuf>,
    pub chat_id: String,
    pub controller_id: String,
    pub tool_mode: String,
}
#[derive(Clone)]
pub(super) struct AppliedProjectResources {
    pub turn_id: String,
    pub snapshot: Arc<ProjectResourceSnapshot>,
    pub instructions: String,
}
#[cfg(test)]
#[derive(Default)]
pub(crate) struct InputCommitGate {
    pub entered: tokio::sync::Notify,
    pub released: tokio::sync::Notify,
}
impl Controller {
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn set_input_commit_gate_for_test(&self, phase: &str) -> Arc<InputCommitGate> {
        let gate = Arc::new(InputCommitGate::default());
        *self.input_commit_gate.lock().unwrap() = Some((phase.into(), gate.clone()));
        gate
    }
    #[cfg(test)]
    pub(super) async fn pause_input_commit_for_test(&self, phase: &str) {
        let gate = {
            let mut slot = self.input_commit_gate.lock().unwrap();
            if slot.as_ref().is_some_and(|(expected, _)| expected == phase) {
                slot.take().map(|(_, gate)| gate)
            } else {
                None
            }
        };
        if let Some(gate) = gate {
            gate.entered.notify_one();
            gate.released.notified().await;
        }
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn set_resource_barrier_for_test(
        &self,
        barrier: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.resource_preparation_barrier.lock().unwrap() = barrier;
    }
    pub(crate) fn with_project_resources(
        mut self: Arc<Self>,
        binding: ProjectRuntimeBinding,
    ) -> Arc<Self> {
        Arc::get_mut(&mut self)
            .expect("new controller has unique ownership")
            .project_resources = Some(binding);
        self
    }
    fn dependency_snapshot(&self, confirm: bool) -> Result<DependencySnapshot> {
        let mut names = Vec::new();
        let mut mcp_revision = String::new();
        if let Some(mcp) = self
            .options
            .tools
            .as_ref()
            .and_then(|tools| tools.mcp.as_ref())
        {
            let snapshot = mcp.manager.configured_names_snapshot(confirm)?;
            names = snapshot.0;
            mcp_revision = snapshot.1;
        }
        let tool_names = self
            .options
            .definitions()
            .into_iter()
            .map(|tool| tool.name)
            .collect::<Vec<_>>();
        DependencySnapshot::new(tool_names, names, &mcp_revision)
    }
    fn project_scope(&self, dependencies: &DependencySnapshot) -> Result<ResourceScope> {
        let binding = self
            .project_resources
            .as_ref()
            .ok_or_else(|| invalid("Project skills require a saved project runtime"))?;
        Ok(ResourceScope {
            project_id: binding.project_id.clone(),
            roots: binding.roots.clone(),
            chat_id: binding.chat_id.clone(),
            controller_id: binding.controller_id.clone(),
            connection_generation: self.configuration_generation.load(Ordering::Acquire),
            configuration_generation: self.suspension_generation.load(Ordering::Acquire),
            tool_mode: binding.tool_mode.clone(),
            policy_revision: "project-picker-v1".into(),
            mcp_configuration_revision: dependencies.revision.clone(),
        })
    }
    /// Presentation-only invalidation token. No locks, I/O or authority grant.
    pub fn project_skills_ui_generation(&self) -> (u64, u64) {
        (
            self.configuration_generation.load(Ordering::Acquire),
            self.suspension_generation.load(Ordering::Acquire),
        )
    }
    pub fn project_skills_catalog_current(&self, snapshot: &ProjectResourceSnapshot) -> bool {
        !self.is_retired()
            && self.admission_suspension.load(Ordering::Acquire) == 0
            && self.check_resources().is_ok()
            && self
                .config
                .try_read()
                .is_ok_and(|config| config.as_ref().is_some_and(|config| config.check().is_ok()))
            && self
                .dependency_snapshot(false)
                .ok()
                .and_then(|dependencies| self.project_scope(&dependencies).ok())
                .is_some_and(|scope| scope == snapshot.scope)
    }
    pub async fn discover_project_skills(self: &Arc<Self>) -> Result<Arc<ProjectResourceSnapshot>> {
        let confirmed = self.confirm_resources()?;
        let config = confirmed
            .configuration
            .clone()
            .ok_or_else(|| invalid("No connection configured"))?;
        let snapshot = self
            .prepare_project_snapshot(&config, None, CancellationToken::new())
            .await?
            .ok_or_else(|| invalid("Project skills require a saved project runtime"))?;
        let reconfirmed = self.confirm_resources()?;
        let inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        self.require_confirmed_admission(&inner, &reconfirmed)?;
        if !self.project_skills_catalog_current(&snapshot) {
            return Err(invalid(
                "Project skills changed while loading; refresh the picker",
            ));
        }
        Ok(snapshot)
    }
    pub(super) async fn prepare_project_snapshot(
        &self,
        config: &Arc<Configuration>,
        retained: Option<Arc<ProjectResourceSnapshot>>,
        cancel: CancellationToken,
    ) -> Result<Option<Arc<ProjectResourceSnapshot>>> {
        if self.project_resources.is_none() {
            return Ok(None);
        }
        let dependencies = self.dependency_snapshot(false)?;
        let scope = self.project_scope(&dependencies)?;
        let source = ProjectResourceSource::new(scope, dependencies)?;
        let authority = self.authority.clone();
        let mcp = self
            .options
            .tools
            .as_ref()
            .and_then(|tools| tools.mcp.as_ref())
            .map(|mcp| mcp.manager.clone());
        let config = config.clone();
        #[cfg(test)]
        let barrier = self
            .resource_preparation_barrier
            .lock()
            .map_err(|_| invalid("Resource fixture barrier unavailable"))?
            .clone();
        let lease = {
            let _inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.require_admission()?;
            self.attachment_jobs.register(cancel.clone())?
        };
        let snapshot = self
            .attachment_workers
            .run(cancel, move |token| {
                let _lease = lease;
                #[cfg(test)]
                if let Some(barrier) = &barrier {
                    barrier();
                }
                Ok((|| {
                    if token.is_cancelled() {
                        return Err(crate::Error::Cancelled);
                    }
                    config.confirm(false)?;
                    if let Some(authority) = &authority {
                        authority.confirm()?;
                    }
                    if let Some(mcp) = &mcp {
                        mcp.configured_names_snapshot(true)?;
                    }
                    let snapshot = match retained {
                        Some(snapshot) => snapshot,
                        None => Arc::new(source.discover(&token)?),
                    };
                    if let Some(mcp) = &mcp {
                        mcp.configured_names_snapshot(true)?;
                    }
                    if token.is_cancelled() {
                        return Err(crate::Error::Cancelled);
                    }
                    Ok(snapshot)
                })())
            })
            .await
            .map_err(|error| match error {
                crate::tools::ToolError::Cancelled => crate::Error::Cancelled,
                _ => invalid(error.to_string()),
            })??;
        if !self.project_skills_catalog_current(&snapshot) {
            return Err(invalid(
                "Resource scope or dependencies changed during preparation",
            ));
        }
        Ok(Some(snapshot))
    }
    pub(super) fn validate_prepared_request(
        &self,
        item: &Submission,
        messages: &[crate::Message],
        config: &Arc<Configuration>,
        applied: Option<&AppliedProjectResources>,
    ) -> Result<()> {
        let profile = config.effective_profile(Some(item));
        let instructions = applied
            .map(|value| value.instructions.as_str())
            .unwrap_or(&self.options.instructions);
        let session_id = self
            .project_resources
            .as_ref()
            .map(|binding| binding.chat_id.as_str())
            .unwrap_or("prepared-input");
        let request = crate::provider::request_body_with_tools(
            &profile,
            messages,
            instructions,
            session_id,
            &self.options.definitions(),
        )?;
        crate::provider::serialize_request(&request)?;
        Ok(())
    }
    pub(super) fn confirm_dependency_snapshot(
        &self,
        applied: Option<&AppliedProjectResources>,
    ) -> Result<()> {
        if let Some(applied) = applied {
            let current = self.dependency_snapshot(true)?;
            if current != applied.snapshot.dependencies {
                return Err(invalid(
                    "Skill dependency configuration changed during preparation",
                ));
            }
        }
        Ok(())
    }
    pub(super) async fn freeze_submission_skills(
        &self,
        mut item: Submission,
        selections: &[SkillSelection],
        config: &Arc<Configuration>,
        cancel: CancellationToken,
    ) -> Result<(Submission, Option<Arc<ProjectResourceSnapshot>>)> {
        if !item.frozen_skills.is_empty() {
            return Err(invalid(
                "Fresh admission requires explicit picker selections, not supplied frozen bodies",
            ));
        }
        crate::skills::validate_selections(selections)?;
        if selections.is_empty() {
            return Ok((item, None));
        }
        let snapshot = self
            .prepare_project_snapshot(config, None, cancel)
            .await?
            .ok_or_else(|| invalid("Project skills require a saved project runtime"))?;
        item.frozen_skills = snapshot.freeze(selections)?;
        Ok((item, Some(snapshot)))
    }
    pub(super) async fn prepare_delivery_resources(
        &self,
        item: &Submission,
        config: &Arc<Configuration>,
        retry: bool,
        cancel: CancellationToken,
    ) -> Result<Option<AppliedProjectResources>> {
        let retained = if retry {
            self.inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?
                .applied_project
                .as_ref()
                .filter(|applied| applied.turn_id == item.id)
                .cloned()
        } else {
            None
        };
        if let Some(mut retained) = retained {
            // Retry replays delivered authorization carriers without fresh skill
            // validation. The applied prompt/body stays fixed, while its scope
            // is rebound to the current confirmed configuration and definitions.
            let dependencies = self.dependency_snapshot(true)?;
            let mut snapshot = (*retained.snapshot).clone();
            snapshot.scope = self.project_scope(&dependencies)?;
            snapshot.dependencies = dependencies;
            retained.snapshot = Arc::new(snapshot);
            return Ok(Some(retained));
        }
        let Some(snapshot) = self.prepare_project_snapshot(config, None, cancel).await? else {
            if !item.frozen_skills.is_empty() {
                return Err(invalid("Queued skills require their saved project runtime"));
            }
            return Ok(None);
        };
        if !retry {
            snapshot.validate_delivery(&item.frozen_skills)?;
        }
        let mut instructions = self.options.instructions.clone();
        if !instructions.is_empty() {
            instructions.push_str("\n\n");
        }
        instructions.push_str(&snapshot.instructions);
        Ok(Some(AppliedProjectResources {
            turn_id: item.id.clone(),
            snapshot,
            instructions,
        }))
    }
}
