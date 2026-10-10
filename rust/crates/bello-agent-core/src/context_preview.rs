//! Read-only request inspection, following SessionContext.swift's prepared
//! request contract. No preview is stored in the session or sent to a provider.
use super::Controller;
#[cfg(test)]
use super::tool_runtime::effective_profile;
use crate::{Message, Result, Session, invalid};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    borrow::Cow,
    sync::{Arc, Weak},
};

const MAX_DRAFT_BYTES: usize = 256 * 1024;
const COUNT_UNAVAILABLE: &str =
    "Token count unavailable: this runtime does not calculate request tokens";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextPreviewMode {
    ActiveContext,
    PreparedNextRequest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContextPreviewMetadata {
    pub mode: ContextPreviewMode,
    pub session_id: String,
    /// Captured persistence revision, not Controller::revision(). Stream-only
    /// changes can advance this without changing the request's inputs.
    pub session_revision: u64,
    pub input_binding: String,
    pub model: String,
    pub thinking_level: String,
    pub draft_included: bool,
    pub draft_deferred: bool,
    pub queue_count: usize,
    pub context_messages: usize,
    pub input_items: usize,
    pub context_window: u32,
    pub output_budget: u32,
    pub output_cap: Option<u32>,
    pub tokens: Option<u64>,
    pub count_source: &'static str,
    pub credentials_redacted: bool,
}

/// The UI owns this immutable, bounded, redacted snapshot. Refresh replaces it;
/// closing the inspector releases it. It retains no session, credential, or
/// hidden session-level cache and cannot be used to dispatch a request.
#[derive(Clone)]
pub struct ContextPreview {
    metadata: ContextPreviewMetadata,
    request_json: String,
    owner: Weak<Controller>,
    configuration: Weak<super::Configuration>,
    resources: Option<Arc<crate::project_resources::ProjectResourceSnapshot>>,
}
impl ContextPreview {
    pub fn metadata(&self) -> &ContextPreviewMetadata {
        &self.metadata
    }
    pub fn request_json(&self) -> &str {
        &self.request_json
    }
}
impl std::fmt::Debug for ContextPreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContextPreview")
            .field("metadata", &self.metadata)
            .field("request_json_bytes", &self.request_json.len())
            .finish()
    }
}

struct PreviewState {
    snapshot: Session,
    active: bool,
    configuration: Arc<super::Configuration>,
    active_epoch: Option<Arc<()>>,
}

impl Controller {
    /// Builds exactly the provider request body from a certain in-memory
    /// snapshot. Instructions and definitions are the Controller's already
    /// frozen options. Inspection never resolves files, skills or settings.
    ///
    /// Active work defers the draft and pending queue. Idle (including paused
    /// or failed) inspection appends a nonempty draft verbatim. It does not
    /// simulate Retry, deliver queued turns, or replay retained partial output.
    /// Call from background work: serialization can process up to 32 MiB.
    pub fn prepare_context(self: &Arc<Self>, draft: &str) -> Result<ContextPreview> {
        let state = self.preview_state()?;
        let resources = if state.active {
            self.inner
                .try_lock()
                .map_err(|_| invalid("The conversation is changing. Refresh the context preview."))?
                .applied_project
                .clone()
        } else {
            None
        };
        self.prepare_context_prepared(draft, Some(state), None, false, resources)
    }
    /// Picker draft preparation is explicit. Active work defers the draft and
    /// never opens its files. All image work runs outside the conversation actor.
    pub async fn prepare_context_with_attachments(
        self: &Arc<Self>,
        draft: &str,
        attachments: &[crate::attachments::AttachmentRecord],
    ) -> Result<ContextPreview> {
        self.prepare_context_with_inputs(draft, attachments, &[])
            .await
    }
    pub async fn prepare_context_with_inputs(
        self: &Arc<Self>,
        draft: &str,
        attachments: &[crate::attachments::AttachmentRecord],
        selections: &[crate::skills::SkillSelection],
    ) -> Result<ContextPreview> {
        if draft.len() > MAX_DRAFT_BYTES {
            return Err(invalid(
                "Draft exceeds the supported 256 KiB submission limit",
            ));
        }
        crate::attachments::validate_selection(attachments)?;
        crate::skills::validate_selections(selections)?;
        let state = self.preview_state()?;
        let active = state.active;
        let config = state.configuration.clone();
        let cancel = tokio_util::sync::CancellationToken::new();
        let resources = if active {
            self.inner
                .try_lock()
                .map_err(|_| invalid("The conversation is changing. Refresh the context preview."))?
                .applied_project
                .clone()
        } else {
            let item = crate::Submission::new(draft.to_owned(), crate::Lane::FollowUp);
            self.prepare_delivery_resources(&item, &config, false, cancel.clone())
                .await?
        };
        let has_input = !attachments.is_empty() || !selections.is_empty();
        let content = if active || !has_input {
            None
        } else {
            let mut item = crate::Submission::new(draft.to_owned(), crate::Lane::FollowUp);
            item.attachments = attachments.to_vec();
            item.model = Some(config.profile.model_id.clone());
            if !selections.is_empty() {
                item.frozen_skills = resources
                    .as_ref()
                    .ok_or_else(|| invalid("Project skills require a saved project runtime"))?
                    .snapshot
                    .freeze(selections)?;
            }
            self.prepare_user_input(&item, &config, cancel.clone(), false)
                .await?
                .map(|prepared| prepared.content)
        };
        self.confirm_dependency_snapshot(resources.as_ref())?;
        if !active && let Some(resources) = &resources {
            let fresh = self
                .prepare_project_snapshot(&config, None, cancel)
                .await?
                .ok_or_else(|| invalid("Project resources are unavailable"))?;
            if fresh.revision != resources.snapshot.revision
                || fresh.scope != resources.snapshot.scope
            {
                return Err(invalid(
                    "Project resources changed. Refresh the context preview.",
                ));
            }
        }
        self.prepare_context_prepared(draft, Some(state), content, has_input, resources)
    }
    fn prepare_context_prepared(
        self: &Arc<Self>,
        draft: &str,
        captured: Option<PreviewState>,
        content: Option<Arc<crate::user_content::UserContent>>,
        has_attachments: bool,
        resources: Option<super::project_input_runtime::AppliedProjectResources>,
    ) -> Result<ContextPreview> {
        // The synthetic delivery path resolves instructions per turn. Its
        // lifetime-fixed options cannot truthfully describe that request, and
        // read-only inspection must not silently discover fresh resources.
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return Err(invalid(
                "Context inspection is not yet available for synthetic resource runtimes",
            ));
        }
        if self.project_resources.is_some() && resources.is_none() {
            return Err(invalid(
                "Project Context requires asynchronous resource preparation; refresh the inspector",
            ));
        }
        // The source bounds even a draft deferred by active work.
        if draft.len() > MAX_DRAFT_BYTES {
            return Err(invalid(
                "Draft exceeds the supported 256 KiB submission limit",
            ));
        }
        // Preserve Inspector's nonblocking actor contract. Capture with try_lock
        // first, release it, then perform full authority I/O. The final semantic
        // currentness check still rejects configuration/input changes meanwhile.
        let PreviewState {
            snapshot,
            active,
            configuration: config,
            active_epoch,
        } = match captured {
            Some(state) => state,
            None => self.preview_state()?,
        };
        let confirmed = super::AdmissionConfirmation {
            configuration: Some(config.clone()),
            active_epoch,
        };
        if let Some(authority) = &self.authority {
            authority.confirm()?;
        }
        config.confirm(!active)?;
        let profile =
            config.effective_profile(active.then_some(snapshot.active.as_ref()).flatten());
        let boundary = preview_messages(&snapshot, active);
        let context_messages = crate::compaction::active_context(boundary)?.len();
        let mut messages = Cow::Borrowed(boundary);
        let draft_included = !active && (!draft.is_empty() || has_attachments);
        if draft_included {
            messages.to_mut().push(Message {
                task_root_id: None,
                user_content: content,
                id: uuid::Uuid::new_v4().to_string(),
                role: "user".into(),
                text: draft.into(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "complete".into(),
                usage: Value::Null,
                model: Some(profile.model_id.clone()),
                tool_record: None,
                compaction: None,
            });
        }
        let instructions = resources
            .as_ref()
            .map(|resources| resources.instructions.as_str())
            .unwrap_or(&self.options.instructions);
        let body = crate::provider::request_body_with_tools(
            &profile,
            &messages,
            instructions,
            &snapshot.id,
            &self.options.definitions(),
        )?;
        // Check the unredacted request first; redaction cannot turn an
        // undispatchable oversized request into a purported valid preview.
        crate::provider::serialize_request(&body)?;
        let input_items =
            body["input"].as_array().map_or(0, Vec::len) - usize::from(!instructions.is_empty());
        let secrets: Vec<&str> = std::iter::once(config.credential.expose())
            .chain(
                profile
                    .headers
                    .iter()
                    .map(|(name, value)| header_credential(name, value)),
            )
            .filter(|value| !value.is_empty())
            .collect();
        let mut redacted = false;
        let body = redact_value(body, &secrets, &mut redacted)?;
        let request_json = String::from_utf8(crate::provider::serialize_bounded(&body, true)?)
            .map_err(|_| invalid("Prepared request is not UTF-8"))?;
        let metadata = ContextPreviewMetadata {
            mode: if active {
                ContextPreviewMode::ActiveContext
            } else {
                ContextPreviewMode::PreparedNextRequest
            },
            session_id: redact_text(&snapshot.id, &secrets, &mut redacted),
            session_revision: snapshot.revision,
            input_binding: input_binding(&snapshot, active),
            model: redact_text(&profile.model_id, &secrets, &mut redacted),
            thinking_level: redact_text(&profile.thinking_level, &secrets, &mut redacted),
            draft_included,
            draft_deferred: active && (!draft.is_empty() || has_attachments),
            queue_count: snapshot.pending.len(),
            context_messages,
            input_items,
            context_window: profile.context_window,
            output_budget: profile.max_output_tokens,
            output_cap: profile.wire_output_limit(),
            tokens: None,
            count_source: COUNT_UNAVAILABLE,
            credentials_redacted: redacted,
        };
        let preview = ContextPreview {
            metadata,
            request_json,
            owner: Arc::downgrade(self),
            configuration: Arc::downgrade(&config),
            resources: resources.map(|resources| resources.snapshot),
        };
        // Match the source's final input-change guard. Rust builds outside the
        // actor lock, so recheck delivered inputs after serialization; partial
        // streaming and undelivered queue edits remain harmless.
        {
            let inner = self.inner.try_lock().map_err(|_| {
                invalid("The conversation is changing. Refresh the context preview.")
            })?;
            self.require_confirmed_admission(&inner, &confirmed)?;
        }
        if !self.context_preview_current(&preview)? {
            return Err(invalid(
                "The conversation changed. Refresh the context preview.",
            ));
        }
        Ok(preview)
    }

    /// A nonblocking semantic stale-result check for the same live Controller.
    /// The caller separately binds its captured draft/window/chat. Partial
    /// streaming, accounting, and queued-but-undelivered input are harmless;
    /// delivered input, completed replies and tool continuations invalidate.
    pub fn context_preview_is_current(&self, preview: &ContextPreview) -> bool {
        self.context_preview_current(preview).unwrap_or(false)
    }

    /// Distinguishes a stale snapshot from temporarily unavailable actor state.
    /// An existing inspector may retain its labeled snapshot on an error; it
    /// must not present that as a newly verified current request.
    pub fn context_preview_current(&self, preview: &ContextPreview) -> Result<bool> {
        // Keeping the Weak allocation identity prevents address reuse after
        // an old Controller drops, without retaining its writer or runtime.
        if !std::ptr::eq(preview.owner.as_ptr(), self) || self.is_retired() {
            return Ok(false);
        }
        self.check_resources()?;
        let inner = self
            .inner
            .try_lock()
            .map_err(|_| invalid("The conversation is changing. Refresh the context preview."))?;
        if inner.fatal.is_some() {
            return Err(invalid(
                "The session is unavailable. Reopen before inspecting context.",
            ));
        }
        inner.store.require_certain()?;
        if inner.compaction_pending
            || inner
                .store
                .snapshot_ref()
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.is_running())
        {
            return Err(invalid(
                "Compaction is preparing a checkpoint. Refresh after it settles to inspect the next request.",
            ));
        }
        // A completed request can commit before its outer worker publishes.
        // Read authoritative actor state without cloning retained text.
        if !self.configuration().is_some_and(|config| {
            config.check().is_ok()
                && std::ptr::eq(preview.configuration.as_ptr(), Arc::as_ptr(&config))
        }) {
            return Ok(false);
        }
        if let Some(resources) = &preview.resources {
            if !self.project_skills_catalog_current(resources) {
                return Ok(false);
            }
            if inner.worker_running
                && !inner.applied_project.as_ref().is_some_and(|applied| {
                    applied.snapshot.revision == resources.revision
                        && applied.snapshot.scope == resources.scope
                })
            {
                return Ok(false);
            }
        }
        Ok(
            input_binding(inner.store.snapshot_ref(), inner.worker_running)
                == preview.metadata.input_binding,
        )
    }

    fn preview_state(&self) -> Result<PreviewState> {
        self.check_resources()?;
        let inner = self
            .inner
            .try_lock()
            .map_err(|_| invalid("The conversation is changing. Refresh the context preview."))?;
        if self.is_retired() {
            return Err(invalid(
                "This session was replaced. Reopen its context inspector.",
            ));
        }
        if inner.fatal.is_some() {
            return Err(invalid(
                "The session is unavailable. Reopen before inspecting context.",
            ));
        }
        inner.store.require_certain()?;
        if inner.compaction_pending
            || inner
                .store
                .snapshot_ref()
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.is_running())
        {
            return Err(invalid(
                "Compaction is preparing a checkpoint. Refresh after it settles to inspect the next request.",
            ));
        }
        let config = self
            .configuration()
            .ok_or_else(|| invalid("No connection configured for a context preview"))?;
        config.check()?;
        Ok(PreviewState {
            snapshot: inner.store.snapshot(),
            active: inner.worker_running,
            active_epoch: (inner.worker_running && config.has_saved_connection())
                .then(|| inner.worker_epoch.clone()),
            configuration: config,
        })
    }
}

fn preview_messages(snapshot: &Session, active: bool) -> &[Message] {
    if active && snapshot.active_tool_calls().is_some() {
        // Swift's waitingTool preview uses boundary, before the outstanding
        // assistant tool request. Do not invent missing tool-result messages.
        &snapshot.messages[..snapshot.messages.len() - 1]
    } else {
        &snapshot.messages
    }
}

fn input_binding(snapshot: &Session, active: bool) -> String {
    // Delivered replay rows are immutable in the Controller; only its current
    // non-replayable assistant receives deltas. Excluding those rows is what
    // makes this identity stable during streaming. The Controller owns frozen
    // profile/instruction/tool options; ownership is checked separately.
    let mut hash = Sha256::new();
    let mut field = |text: &str| {
        hash.update((text.len() as u64).to_le_bytes());
        hash.update(text.as_bytes());
    };
    field(&snapshot.id);
    field(if active { "active" } else { "idle" });
    if active {
        field(snapshot.active_reply.as_deref().unwrap_or(""));
        if let Some(item) = &snapshot.active {
            field(&item.id);
            field(item.model.as_deref().unwrap_or(""));
            field(item.effort.as_deref().unwrap_or(""));
        }
    }
    for message in preview_messages(snapshot, active)
        .iter()
        .filter(|row| row.replay_eligible)
    {
        field(&message.id);
    }
    format!("{:x}", hash.finalize())
}

fn header_credential<'a>(name: &str, value: &'a str) -> &'a str {
    // CaptureCredentials.credential preserves an auth-scheme prefix but treats
    // its suffix as the known credential. In particular, a body can contain
    // only the token from a configured Proxy-Authorization header.
    if (name.eq_ignore_ascii_case("authorization")
        || name.eq_ignore_ascii_case("proxy-authorization"))
        && let Some((scheme, credential)) = value.split_once(' ')
        && (1..=32).contains(&scheme.len())
        && scheme.as_bytes()[0].is_ascii_alphabetic()
        && scheme
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"+.-".contains(&byte))
    {
        return credential;
    }
    value
}

fn redact_text(text: &str, secrets: &[&str], changed: &mut bool) -> String {
    if secrets.iter().any(|secret| text.contains(*secret)) {
        // Match CaptureCredentials.metadata: fingerprint the entire field,
        // rather than repeatedly replacing inside a newly produced hash.
        *changed = true;
        format!("[sha256:{:x}]", Sha256::digest(text.as_bytes()))
    } else {
        text.into()
    }
}

fn redact_value(value: Value, secrets: &[&str], changed: &mut bool) -> Result<Value> {
    Ok(match value {
        Value::String(text) => Value::String(redact_text(&text, secrets, changed)),
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| redact_value(item, secrets, changed))
                .collect::<Result<_>>()?,
        ),
        Value::Object(items) => {
            let mut safe = serde_json::Map::new();
            for (key, value) in items {
                let key = redact_text(&key, secrets, changed);
                if safe
                    .insert(key, redact_value(value, secrets, changed)?)
                    .is_some()
                {
                    return Err(invalid(
                        "Credential redaction made request fields ambiguous",
                    ));
                }
            }
            Value::Object(safe)
        }
        other => other,
    })
}

#[cfg(test)]
#[path = "context_preview_tests.rs"]
mod tests;
