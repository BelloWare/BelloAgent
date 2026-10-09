//! Loaded-only, worker-side search acquisition and bounded in-memory admission.
//! No UI, cache, disk fallback, runtime authority or unloaded receipt is enabled.
mod admission;
mod cancellation;
pub mod identity;
pub mod projection;
pub use admission::*;
pub use cancellation::CancellationProbe;
