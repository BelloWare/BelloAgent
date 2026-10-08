//! Foundation operations used by the source write/edit body. All Objective-C
//! identities and temporary buffers remain inside one serialized worker job.
use super::{FileToolContext, ToolError, ToolResult, source};
use crate::tools::{
    find::macos::resolve_path,
    read::macos::{acquire_resolved, decode_utf8, foundation_string},
};
use objc2::rc::{Retained, autoreleasepool};
use objc2_foundation::{
    NSData, NSDataWritingOptions, NSDictionary, NSError, NSFileManager, NSFilePosixPermissions,
    NSURL,
};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

pub(super) fn invoke(
    context: &FileToolContext,
    arguments: &Value,
    editing: bool,
    cancel: &CancellationToken,
) -> ToolResult<Value> {
    autoreleasepool(|_| {
        source::execute(
            &mut FoundationFiles {
                context,
                manager: NSFileManager::defaultManager(),
            },
            arguments,
            editing,
            cancel,
        )
    })
}

struct FoundationFiles<'a> {
    context: &'a FileToolContext,
    manager: Retained<NSFileManager>,
}
impl source::Files for FoundationFiles<'_> {
    type Path = Retained<NSURL>;
    fn resolve(&mut self, value: &Value, existing: bool) -> ToolResult<Self::Path> {
        // Source path is required for both tools, unlike optional read-only paths.
        if value.is_null() {
            return Err(ToolError::failure("invalid_params", "Invalid path"));
        }
        if existing {
            return resolve_path(self.context, value, &self.manager);
        }
        // Write never redirects a missing relative path to another root.
        let mut primary_only = self.context.clone();
        primary_only.roots.truncate(1);
        resolve_path(&primary_only, value, &self.manager)
    }
    fn path(&self, path: &Self::Path) -> String {
        path.path().expect("resolved file URL").to_string()
    }
    fn read_text(&mut self, path: &Self::Path) -> ToolResult<Option<String>> {
        let bytes = acquire_resolved(&self.path(path))?;
        decode_utf8(&bytes)
    }
    fn replace_once(&self, text: &str, old: &str, new: &str) -> ToolResult<String> {
        // Swift String.components(separatedBy:) uses this Foundation operation,
        // including its non-overlapping and Unicode matching behavior.
        let parts = foundation_string(text).componentsSeparatedByString(&foundation_string(old));
        if parts.count() != 2 {
            return Err(ToolError::failure(
                "edit_match",
                format!(
                    "oldText must match exactly once; found {} matches",
                    parts.count() - 1
                ),
            ));
        }
        Ok(format!(
            "{}{new}{}",
            parts.objectAtIndex(0),
            parts.objectAtIndex(1)
        ))
    }
    fn write(&mut self, path: &Self::Path, content: &str) -> ToolResult<bool> {
        let parent = path
            .URLByDeletingLastPathComponent()
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid path"))?;
        // SAFETY: nil attributes requests default Foundation permissions, as Swift.
        unsafe {
            self.manager
                .createDirectoryAtURL_withIntermediateDirectories_attributes_error(
                    &parent, true, None,
                )
        }
        .map_err(native_error)?;
        let path_string = path.path().expect("resolved file URL");
        let attributes = self.manager.attributesOfItemAtPath_error(&path_string).ok();
        NSData::with_bytes(content.as_bytes())
            .writeToURL_options_error(path, NSDataWritingOptions::Atomic)
            .map_err(native_error)?;
        // The original captures only POSIX permissions and restores them after
        // atomic replacement. A restoration error is not evidence of no write.
        // SAFETY: Foundation's exported key is an immutable NSString constant.
        let key = unsafe { NSFilePosixPermissions };
        if let Some(permissions) = attributes
            .as_ref()
            .and_then(|attributes| attributes.objectForKey(key))
        {
            let keep = NSDictionary::from_slices(&[key], &[&*permissions]);
            // SAFETY: the value was obtained for this exact attribute key from Foundation.
            unsafe {
                self.manager
                    .setAttributes_ofItemAtPath_error(&keep, &path_string)
            }
            .map_err(native_error)?;
        }
        Ok(attributes.is_some())
    }
}
fn native_error(error: Retained<NSError>) -> ToolError {
    ToolError::Native {
        domain: error.domain().to_string(),
        code: error.code() as i64,
        message: error.localizedDescription().to_string(),
    }
}

#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;
