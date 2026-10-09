//! Private filename admission. The default SQLite VFS still reopens filenames;
//! same-UID malicious processes and privileged attackers are outside this boundary.
use super::{CacheBinding, CacheError, Result};
use std::{
    fs::File,
    path::{Path, PathBuf},
};

pub(crate) struct PrivateDirectory {
    pub path: PathBuf,
    // Descriptor and stable exclusive lease live until every connection closes.
    pub(crate) directory: File,
    _lease: File,
}

/// No current-directory or --session-parent fallback is permitted.
pub fn platform_data_base() -> Result<PathBuf> {
    #[cfg(target_os = "linux")]
    if let Some(value) = std::env::var_os("XDG_DATA_HOME") {
        let path = PathBuf::from(value);
        return valid_absolute(&path).map(|()| path);
    }
    let home = std::env::var_os("HOME").ok_or(CacheError::UnsafeLocation)?;
    let home = PathBuf::from(home);
    valid_absolute(&home)?;
    #[cfg(target_os = "macos")]
    return Ok(home.join("Library/Application Support"));
    #[cfg(target_os = "linux")]
    return Ok(home.join(".local/share"));
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    Err(CacheError::PlatformPending)
}
fn valid_absolute(path: &Path) -> Result<()> {
    use std::path::Component;
    if !path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, Component::RootDir | Component::Normal(_)))
    {
        return Err(CacheError::UnsafeLocation);
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod unix {
    use super::*;
    use std::{
        ffi::{CString, OsStr},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::{ffi::OsStrExt, fs::MetadataExt},
        },
    };
    fn name(value: &OsStr) -> Result<CString> {
        CString::new(value.as_bytes()).map_err(|_| CacheError::UnsafeLocation)
    }
    fn checked(fd: i32) -> Result<File> {
        if fd < 0 {
            return Err(CacheError::UnsafeLocation);
        }
        // SAFETY: a successful open/openat created this uniquely owned descriptor.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    #[cfg(target_os = "macos")]
    fn check_acl(file: &File) -> Result<()> {
        super::super::mac_acl::check(file)
    }
    #[cfg(target_os = "linux")]
    fn check_acl(file: &File) -> Result<()> {
        for attr in [c"system.posix_acl_access", c"system.posix_acl_default"] {
            // SAFETY: descriptor remains owned and the query has no output buffer.
            let count = unsafe {
                libc::fgetxattr(file.as_raw_fd(), attr.as_ptr(), std::ptr::null_mut(), 0)
            };
            if count >= 0 {
                return Err(CacheError::UnsafeLocation);
            }
            let error = std::io::Error::last_os_error().raw_os_error();
            if error != Some(libc::ENODATA) && error != Some(libc::ENOTSUP) {
                return Err(CacheError::UnsafeLocation);
            }
        }
        Ok(())
    }
    fn validate(file: &File, directory: bool, private: bool) -> Result<()> {
        let m = file.metadata().map_err(|_| CacheError::UnsafeLocation)?;
        // SAFETY: geteuid has no arguments or memory preconditions.
        let uid = unsafe { libc::geteuid() };
        if (directory && !m.is_dir())
            || (!directory && !m.is_file())
            || (private && m.uid() != uid)
            || (!private && m.uid() != uid && m.uid() != 0)
            || (private && m.mode() & 0o7777 != if directory { 0o700 } else { 0o600 })
            || (!private && m.mode() & 0o022 != 0)
            || (!directory && m.nlink() != 1)
        {
            return Err(CacheError::UnsafeLocation);
        }
        check_acl(file)
    }
    fn child(parent: &File, component: &OsStr, private: bool, create: bool) -> Result<File> {
        let name = name(component)?;
        if create {
            // SAFETY: valid parent and NUL-terminated single component; never chmod existing data.
            let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
            if result < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
                return Err(CacheError::UnsafeLocation);
            }
        }
        // SAFETY: descriptors/strings are valid; NOFOLLOW rejects link substitution.
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY
                    | libc::O_DIRECTORY
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK,
            )
        };
        let file = checked(fd)?;
        validate(&file, true, private)?;
        Ok(file)
    }
    fn regular(parent: &File, component: &str, create: bool) -> Result<File> {
        let component = CString::new(component).map_err(|_| CacheError::UnsafeLocation)?;
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // SAFETY: exclusively creates only the dedicated known cache filename.
        let mut fd = if create {
            unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    component.as_ptr(),
                    flags | libc::O_CREAT | libc::O_EXCL,
                    0o600,
                )
            }
        } else {
            -1
        };
        if !create
            || (fd < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST))
        {
            // SAFETY: validated parent; no-follow and non-blocking also protect against FIFOs.
            fd = unsafe { libc::openat(parent.as_raw_fd(), component.as_ptr(), flags) };
        }
        let file = checked(fd)?;
        validate(&file, false, true)?;
        Ok(file)
    }
    impl PrivateDirectory {
        pub fn open(binding: &CacheBinding) -> Result<Self> {
            let base = platform_data_base()?;
            // SAFETY: fixed absolute root, only directories, no symlinks.
            let mut parent = checked(unsafe {
                libc::open(
                    c"/".as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                )
            })?;
            validate(&parent, true, false)?;
            for component in base.components() {
                if let std::path::Component::Normal(component) = component {
                    // Missing data-base ancestors are not silently created/taken over.
                    parent = child(&parent, component, false, false)?;
                }
            }
            Self::under(base, parent, binding)
        }
        fn under(mut path: PathBuf, mut parent: File, binding: &CacheBinding) -> Result<Self> {
            for component in [
                "BelloAgent-rust",
                "search-cache",
                "v1",
                &binding.namespace(),
            ] {
                parent = child(&parent, OsStr::new(component), true, true)?;
                path.push(component);
            }
            let lease = regular(&parent, "owner.lock", true)?;
            lease.try_lock().map_err(|_| CacheError::Busy)?;
            let out = Self {
                path,
                directory: parent,
                _lease: lease,
            };
            out.validate_siblings()?;
            regular(&out.directory, "cache.sqlite3", true)?;
            out.validate_siblings()?;
            Ok(out)
        }
        #[cfg(any(test, feature = "synthetic-authority"))]
        pub fn fixture(base: &Path, binding: &CacheBinding) -> Result<Self> {
            // Disposable fixture anchor explicitly supplies trust; production always traverses /.
            let base = base
                .canonicalize()
                .map_err(|_| CacheError::UnsafeLocation)?;
            let parent = File::open(&base).map_err(|_| CacheError::UnsafeLocation)?;
            validate(&parent, true, true)?;
            Self::under(base, parent, binding)
        }
        pub fn validate_siblings(&self) -> Result<()> {
            validate(&self.directory, true, true)?;
            let by_path =
                std::fs::symlink_metadata(&self.path).map_err(|_| CacheError::UnsafeLocation)?;
            let by_fd = self
                .directory
                .metadata()
                .map_err(|_| CacheError::UnsafeLocation)?;
            if by_path.dev() != by_fd.dev() || by_path.ino() != by_fd.ino() {
                return Err(CacheError::UnsafeLocation);
            }
            for entry in std::fs::read_dir(&self.path).map_err(|_| CacheError::UnsafeLocation)? {
                let entry = entry.map_err(|_| CacheError::UnsafeLocation)?;
                let name = entry.file_name();
                let name = name.to_str().ok_or(CacheError::UnsafeLocation)?;
                if !matches!(
                    name,
                    "owner.lock"
                        | "cache.sqlite3"
                        | "cache.sqlite3-wal"
                        | "cache.sqlite3-shm"
                        | "cache.sqlite3-journal"
                ) {
                    return Err(CacheError::UnsafeLocation);
                }
                regular(&self.directory, name, false)?;
            }
            Ok(())
        }
    }
}
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl PrivateDirectory {
    pub fn open(_: &CacheBinding) -> Result<Self> {
        Err(CacheError::PlatformPending)
    }
    pub fn validate_siblings(&self) -> Result<()> {
        Err(CacheError::PlatformPending)
    }
}
