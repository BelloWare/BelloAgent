use std::sync::atomic::{AtomicBool, Ordering};
use tokio_util::sync::CancellationToken;
mod sealed {
    pub trait Sealed {}
    impl Sealed for std::sync::atomic::AtomicBool {}
    impl Sealed for tokio_util::sync::CancellationToken {}
    impl Sealed for super::CombinedCancellation<'_> {}
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

pub(crate) struct CombinedCancellation<'a>(
    pub &'a AtomicBool,
    pub &'a CancellationToken,
    pub &'a AtomicBool,
);
impl CancellationProbe for CombinedCancellation<'_> {
    fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire) || self.1.is_cancelled() || self.2.load(Ordering::Acquire)
    }
}
