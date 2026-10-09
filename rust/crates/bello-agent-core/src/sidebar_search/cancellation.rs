use std::sync::atomic::{AtomicBool, Ordering};
use tokio_util::sync::CancellationToken;
mod sealed {
    pub trait Sealed {}
    impl Sealed for std::sync::atomic::AtomicBool {}
    impl Sealed for tokio_util::sync::CancellationToken {}
}
/// Synchronous, sealed cancellation probe. No user callback runs during search.
/// Both existing pure AtomicBool fixtures and shared inspection cancellation work.
pub trait CancellationProbe: sealed::Sealed {
    fn is_cancelled(&self) -> bool;
}
impl CancellationProbe for AtomicBool {
    fn is_cancelled(&self) -> bool {
        self.load(Ordering::Acquire)
    }
}
impl CancellationProbe for CancellationToken {
    fn is_cancelled(&self) -> bool {
        CancellationToken::is_cancelled(self)
    }
}
