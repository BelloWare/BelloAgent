//! Source-equivalent synchronous storage orchestration. The only native entry
//! point is explicitly composed; tests use an inert fake API, never Security.
use super::{AuthorityError, AuthorityResult, ProjectAuthority};

#[cfg(any(target_os = "macos", test))]
use super::{MAX_BYTES, VaultStorage};

#[cfg(any(target_os = "macos", test))]
#[path = "native_status.rs"]
mod status;

#[cfg(any(target_os = "macos", test))]
const BUNDLE_ID: &str = "com.belloware.BelloAgentRust";
#[cfg(any(target_os = "macos", test))]
const SERVICE: &str = "com.belloware.BelloAgentRust.configuration";
#[cfg(any(target_os = "macos", test))]
const ACCOUNT: &str = "vault-v1";
#[cfg(any(target_os = "macos", test))]
const REQUIREMENT: &str = "anchor apple generic and identifier \"com.belloware.BelloAgentRust\" and certificate leaf[subject.OU] = \"43TXHV3TM3\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists";

#[cfg(all(unix, any(target_os = "macos", test)))]
#[path = "native_lock.rs"]
mod file_lock;
#[cfg(target_os = "macos")]
#[path = "native_macos.rs"]
mod macos;

pub(super) fn authority() -> AuthorityResult<ProjectAuthority> {
    #[cfg(target_os = "macos")]
    {
        Ok(ProjectAuthority {
            storage: Some(std::sync::Arc::new(NativeStorage {
                api: macos::SecurityApi,
            })),
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(AuthorityError::Unavailable)
    }
}

/// Only an add's duplicate-item response proves a post-entry conflict without
/// a write. Every failed update and other uncertain completion is Unconfirmed.
#[cfg(any(target_os = "macos", test))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MutationOutcome {
    Confirmed,
    Conflict,
    Unconfirmed,
}

#[cfg(any(target_os = "macos", test))]
impl MutationOutcome {
    fn into_result(self) -> AuthorityResult<()> {
        match self {
            Self::Confirmed => Ok(()),
            Self::Conflict => Err(AuthorityError::Conflict),
            Self::Unconfirmed => Err(AuthorityError::Unconfirmed),
        }
    }
}

/// Only Rust-owned bytes/errors may leave an operation. The real adapter is
/// stateless and creates every Foundation, Security, and LAContext value locally.
#[cfg(any(target_os = "macos", test))]
trait NativeApi: Send + Sync {
    type Lock;
    fn pool<T>(&self, operation: impl FnOnce() -> T) -> T;
    fn validate_identity(&self) -> AuthorityResult<()>;
    fn acquire_lock(&self) -> AuthorityResult<Self::Lock>;
    fn copy_matching(&self) -> AuthorityResult<Option<Vec<u8>>>;
    fn update(&self, bytes: &[u8]) -> MutationOutcome;
    fn add(&self, bytes: &[u8]) -> MutationOutcome;
}

#[cfg(any(target_os = "macos", test))]
struct NativeStorage<A> {
    api: A,
}

#[cfg(any(target_os = "macos", test))]
impl<A: NativeApi> NativeStorage<A> {
    fn read_in_pool(&self) -> AuthorityResult<Option<Vec<u8>>> {
        self.api.validate_identity()?;
        let bytes = self.api.copy_matching()?;
        if bytes.as_ref().is_some_and(|bytes| bytes.len() > MAX_BYTES) {
            return Err(AuthorityError::Corrupt);
        }
        Ok(bytes)
    }
}

#[cfg(any(target_os = "macos", test))]
impl<A: NativeApi> VaultStorage for NativeStorage<A> {
    fn read(&self) -> AuthorityResult<Option<Vec<u8>>> {
        self.api.pool(|| self.read_in_pool())
    }

    fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()> {
        self.api.pool(|| {
            self.api.validate_identity()?;
            if replacement.len() > MAX_BYTES
                || expected.is_some_and(|bytes| bytes.len() > MAX_BYTES)
            {
                return Err(AuthorityError::Corrupt);
            }
            let _lock = self.api.acquire_lock()?;
            // Like Swift replace -> read, check identity again inside the lock.
            // Compare entire optional bytes, including absent versus empty.
            if self.read_in_pool()?.as_deref() != expected {
                return Err(AuthorityError::Conflict);
            }
            // Existing items only update. Missing items only add once. No
            // delete, fallback, retry, or compensating write is available here.
            if expected.is_some() {
                self.api.update(replacement)
            } else {
                self.api.add(replacement)
            }
            .into_result()
        })
    }
}

#[cfg(test)]
#[path = "native_tests.rs"]
mod tests;
