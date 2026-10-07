//! Source-exact Foundation file bridge: path aliases, one bounded native read,
//! native error identity and UTF-8 BOM behavior. Objects never leave the worker.
use super::{FILE_BYTES, FileToolContext, ToolError, ToolResult};
use crate::tools::find::macos::resolve_path;
use objc2::{
    AnyThread, msg_send,
    rc::{Retained, autoreleasepool},
};
use objc2_foundation::{
    NSData, NSError, NSFileHandle, NSFileManager, NSString, NSUTF8StringEncoding,
};
use serde_json::Value;
use std::mem::MaybeUninit;

pub(super) fn acquire(
    context: &FileToolContext,
    arguments: &Value,
) -> ToolResult<(String, Vec<u8>)> {
    autoreleasepool(|_| {
        let url = resolve_path(
            context,
            &arguments["path"],
            &NSFileManager::defaultManager(),
        )?;
        let path = url
            .path()
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid path"))?
            .to_string();
        // Swift's C-string bridge retains embedded NUL, whose prefix POSIX open
        // observes. Preserve it rather than silently reading a different path.
        let mut c_path = path.as_bytes().to_vec();
        c_path.push(0);
        // SAFETY: live NUL-terminated storage; read-only open has no mode argument.
        let descriptor = unsafe {
            libc::open(
                c_path.as_ptr().cast(),
                libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(ToolError::failure(
                "file_unavailable",
                format!("Cannot open {path}"),
            ));
        }
        let handle = ClosingFileHandle(NSFileHandle::initWithFileDescriptor_closeOnDealloc(
            NSFileHandle::alloc(),
            descriptor,
            true,
        ));
        let mut info = MaybeUninit::<libc::stat>::zeroed();
        // SAFETY: the owned descriptor is open and output is correctly aligned.
        if unsafe { libc::fstat(descriptor, info.as_mut_ptr()) } != 0 {
            return Err(ToolError::failure(
                "not_regular_file",
                "Only regular files can be read",
            ));
        }
        // SAFETY: successful fstat initialized info.
        let info = unsafe { info.assume_init() };
        if info.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Err(ToolError::failure(
                "not_regular_file",
                "Only regular files can be read",
            ));
        }
        if info.st_size > FILE_BYTES as libc::off_t {
            return Err(ToolError::failure(
                "file_too_large",
                "File exceeds the supported size limit",
            ));
        }
        let mut error: Option<Retained<NSError>> = None;
        // SAFETY: exact nullable Foundation readDataUpToLength:error: signature.
        let data: Option<Retained<NSData>> =
            unsafe { msg_send![&*handle.0,readDataUpToLength: FILE_BYTES+1,error: &mut error] };
        if let Some(error) = error {
            return Err(ToolError::Native {
                domain: error.domain().to_string(),
                code: error.code() as i64,
                message: error.localizedDescription().to_string(),
            });
        }
        let bytes = data.map_or_else(Vec::new, |data| data.to_vec());
        if bytes.len() > FILE_BYTES {
            return Err(ToolError::failure(
                "file_too_large",
                "File exceeds the supported size limit",
            ));
        }
        Ok((path, bytes))
    })
}

pub(super) fn decode_utf8(bytes: &[u8]) -> Option<String> {
    autoreleasepool(|_| {
        let data = NSData::with_bytes(bytes);
        NSString::initWithData_encoding(NSString::alloc(), &data, NSUTF8StringEncoding)
            .map(|text| text.to_string())
    })
}

struct ClosingFileHandle(Retained<NSFileHandle>);
impl Drop for ClosingFileHandle {
    fn drop(&mut self) {
        let _ = self.0.closeAndReturnError();
    }
}

#[cfg(test)]
#[path = "macos/tests.rs"]
mod tests;
