//! Worker-side loaded acceptance and unloaded as-of observation with bounded outputs.
//! No content UI, persistent cache or runtime authority is enabled.
mod admission;
pub mod cache;
pub(crate) mod cancellation;
pub mod identity;
pub mod projection;
pub use admission::*;
pub use cancellation::CancellationProbe;

pub mod reconciliation;
mod unloaded;
pub use unloaded::UnloadedObserved;
#[cfg(test)]
mod unloaded_tests;
