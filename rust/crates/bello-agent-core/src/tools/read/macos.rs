//! Source-exact Foundation file bridge: path aliases, one bounded native read,
//! native error identity and UTF-8 BOM behavior. Objects never leave the worker.
use super::{FILE_BYTES, FileToolContext, ToolError, ToolResult};
use crate::tools::find::macos::resolve_path;
use objc2::{
    AnyThread, msg_send,
    rc::{Retained, autoreleasepool},
};
use objc2_foundation::{NSData, NSError, NSFileHandle, NSFileManager, NSString};
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
        let bytes = acquire_resolved(&path)?;
        Ok((path, bytes))
    })
}

pub(in crate::tools) fn acquire_resolved(path: &str) -> ToolResult<Vec<u8>> {
    autoreleasepool(|_| {
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
        Ok(bytes)
    })
}

#[path = "macos/source_utf8.rs"]
mod source_utf8;

pub(in crate::tools) fn decode_utf8(bytes: &[u8]) -> ToolResult<Option<String>> {
    source_utf8::decode(bytes).map_err(|error| {
        ToolError::failure(
            "native_utf8_adapter",
            format!("Native UTF-8 adapter failed: {error:?}"),
        )
    })
}

/// Bridge an already-decoded String without interpreting its UTF-8 bytes again.
/// NSString's UTF-8 initializer can consume a leading BOM on macOS 14, unlike
/// Swift String -> NSString. Explicit UTF-16 preserves every existing code unit.
pub(in crate::tools) fn foundation_string(text: &str) -> Retained<NSString> {
    let mut characters: Vec<u16> = text.encode_utf16().collect();
    // SAFETY: Vec supplies a non-null, aligned pointer even at length zero;
    // NSString copies the initialized UTF-16 units before this buffer is dropped.
    unsafe {
        NSString::initWithCharacters_length(
            NSString::alloc(),
            std::ptr::NonNull::new(characters.as_mut_ptr()).unwrap(),
            characters.len(),
        )
    }
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
