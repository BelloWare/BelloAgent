//! Skill presentation/ID spelling, separate from canonical filesystem identity.
//! No path rewriting or global instruction/authority canonicalization changes.
use crate::{Result, invalid};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Match Swift canonical(_:): fileURL, standardizedFileURL, then
/// resolvingSymlinksInPath. Darwin Foundation may retain /var where realpath
/// returns /private/var. Verify the spelling names the same existing target as
/// the bounded reader/scanner; only owned Rust paths leave the autorelease pool.
pub(super) fn existing(path: &Path, canonical: &Path) -> Result<PathBuf> {
    #[cfg(target_os = "macos")]
    let source = {
        use objc2::rc::autoreleasepool;
        use objc2_foundation::{NSString, NSURL};
        autoreleasepool(|_| {
            let path = path
                .to_str()
                .ok_or_else(|| invalid("Skill path is not UTF-8"))?;
            NSURL::fileURLWithPath(&NSString::from_str(path))
                .URLByStandardizingPath()
                .and_then(|url| url.URLByResolvingSymlinksInPath())
                .and_then(|url| url.path())
                .map(|path| PathBuf::from(path.to_string()))
                .ok_or_else(|| invalid("Invalid skill source path"))
        })?
    };
    #[cfg(not(target_os = "macos"))]
    let source = canonical.to_path_buf();
    if fs::canonicalize(&source)? != canonical || fs::canonicalize(path)? != canonical {
        return Err(invalid("Skill source changed during discovery; refresh"));
    }
    Ok(source)
}
