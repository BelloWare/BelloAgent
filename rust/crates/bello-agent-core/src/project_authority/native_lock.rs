use super::super::{AuthorityError, AuthorityResult};
use std::{
    fs::{DirBuilder, File, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, OpenOptionsExt},
    },
    path::Path,
};

/// A cooperating-writer lock only, with the source's directory/file modes and
/// symlink/open flags. It is not protection from arbitrary same-user writers.
pub(super) struct FileLock(File);

impl FileLock {
    pub(super) fn acquire(path: &Path) -> AuthorityResult<Self> {
        let directory = path.parent().ok_or(AuthorityError::LockUnavailable)?;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)
            .map_err(|_| AuthorityError::LockUnavailable)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(path)
            .map_err(|_| AuthorityError::LockUnavailable)?;
        let lock = Self(file);
        // SAFETY: the descriptor remains owned by lock through this call and
        // Drop. LOCK_NB never waits for a competing writer.
        if unsafe { libc::flock(lock.0.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(AuthorityError::Busy);
        }
        Ok(lock)
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        // SAFETY: the file is still open. Explicit unlock precedes File's close,
        // including every error return and Rust unwind after lock acquisition.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
    };

    #[test]
    fn lock_is_nonblocking_explicitly_unlocked_and_close_on_exec() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("support/configuration.lock");
        let lock = FileLock::acquire(&path).unwrap();
        assert!(matches!(
            FileLock::acquire(&path),
            Err(AuthorityError::Busy)
        ));
        let flags = unsafe { libc::fcntl(lock.0.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // A duplicate keeps the same open-file description alive after Drop.
        // Reacquisition proves explicit LOCK_UN, not merely last-handle close.
        let duplicate = lock.0.try_clone().unwrap();
        drop(lock);
        let reacquired = FileLock::acquire(&path).unwrap();
        drop(reacquired);
        drop(duplicate);
    }

    #[test]
    fn lock_open_failure_and_symlink_are_unavailable_without_rewriting_target() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"unchanged").unwrap();
        let link = directory.path().join("configuration.lock");
        symlink(&target, &link).unwrap();
        assert!(matches!(
            FileLock::acquire(&link),
            Err(AuthorityError::LockUnavailable)
        ));
        assert!(matches!(
            FileLock::acquire(&target.join("configuration.lock")),
            Err(AuthorityError::LockUnavailable)
        ));
        assert_eq!(fs::read(&target).unwrap(), b"unchanged");
    }

    #[test]
    fn existing_modes_are_not_rewritten_and_unwind_releases_lock() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("configuration.lock");
        fs::write(&path, b"existing").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let result = std::panic::catch_unwind(|| {
            let _lock = FileLock::acquire(&path).unwrap();
            panic!("test unwind");
        });
        assert!(result.is_err());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );
        assert_eq!(fs::read(&path).unwrap(), b"existing");
        drop(FileLock::acquire(&path).unwrap());
    }
}
