//! Native Rust migration core. Its versioned snapshots are intentionally separate
//! from Swift journals. No credentials are read, discovered, or persisted here.
pub mod profile;
pub mod provider;
pub mod runtime;
pub mod session;
pub mod sse;
mod stream_journal;

pub use profile::{Credential, Profile};
pub use provider::{Delta, Reply, ResponsesClient};
pub use runtime::Controller;
pub use session::{Lane, Message, RunState, Session, SessionStore, Submission};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Provider(String),
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
