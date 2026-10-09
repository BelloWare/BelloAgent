//! Native Rust migration core. Its versioned snapshots are intentionally separate
//! from Swift journals. No credentials are read, discovered, or persisted here.
pub mod attachments;
pub mod compaction;
#[path = "compaction_session.rs"]
mod compaction_session;
pub mod context_recovery;
pub mod inspection;
pub mod instructions;
pub mod mcp;
pub mod model_catalog;
pub mod observed_source;
pub mod profile;
pub mod project_authority;
pub mod project_resources;
pub mod provider;
pub mod provider_failure;
pub mod read_observation;
pub mod retained_find;
pub mod runtime;
pub mod saved_runtime;
pub mod session;
pub mod sidebar_search;
mod skill_metadata;
mod skill_schema;
pub mod skills;
pub mod source_admission;
pub mod sse;
mod stream_journal;
#[cfg(feature = "synthetic-authority")]
pub mod synthetic_project_runtime;
pub mod tool_content;
pub mod tool_history;
pub mod tool_timing;
pub mod tools;
pub mod user_content;
pub mod workspace;
pub mod workspace_membership;
pub mod workspace_read_state;

pub use profile::{Credential, Profile};
pub use provider::{Delta, Reply, ResponsesClient};
pub use retained_find::FindSnapshot;
pub use runtime::Controller;
pub use session::{
    Lane, Message, QueueEditState, QueueEditStatus, RunState, Session, SessionStore, Submission,
};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Invalid(String),
    #[error("The queue changed while you were dragging, so nothing was moved. Drag again.")]
    QueueOrder,
    #[error("{0}")]
    Provider(String),
    #[error("{0}")]
    ProviderFailure(Box<crate::provider_failure::Failure>),
    #[error("The response stream ended before a terminal response event")]
    IncompleteStream,
    #[error("Stopped")]
    Cancelled,
    #[error(
        "Session data may have been written but could not be synchronized. Reopen before continuing: {0}"
    )]
    PersistenceUncertain(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
}
pub type Result<T> = std::result::Result<T, Error>;
pub(crate) fn invalid(message: impl Into<String>) -> Error {
    Error::Invalid(message.into())
}
