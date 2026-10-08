//! Source write/edit body, running on independent bounded workers.
//! Native filesystem/string behavior is macOS Foundation only. Linux fixtures
//! exercise this same ordering with a deliberately synthetic temporary adapter.
use super::{FileToolContext, ToolError, ToolResult};
#[cfg(any(target_os = "macos", test))]
use super::{check_cancelled, result_text};
use serde_json::Value;
#[cfg(any(target_os = "macos", test))]
use serde_json::json;
use tokio_util::sync::CancellationToken;

#[cfg(target_os = "macos")]
mod macos;

pub(super) fn invoke(
    context: &FileToolContext,
    arguments: &Value,
    editing: bool,
    cancellation: &CancellationToken,
) -> ToolResult<Value> {
    #[cfg(target_os = "macos")]
    {
        macos::invoke(context, arguments, editing, cancellation)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (context, arguments, editing, cancellation);
        Err(ToolError::failure(
            "tool_unavailable",
            "Write and edit require macOS Foundation",
        ))
    }
}

#[cfg(any(target_os = "macos", test))]
pub(super) mod source {
    use super::*;
    use unicode_normalization::UnicodeNormalization;

    pub const FILE_BYTES: usize = 16 * 1024 * 1024;
    pub const EDIT_BYTES: usize = 4 * 1024 * 1024;

    /// The adapter keeps native identities local. `write` includes parent
    /// creation, attribute capture, atomic replacement and permission restore,
    /// in that exact order; errors after replacement may have side effects.
    pub trait Files {
        type Path;
        fn resolve(&mut self, value: &Value, existing: bool) -> ToolResult<Self::Path>;
        fn path(&self, path: &Self::Path) -> String;
        fn read_text(&mut self, path: &Self::Path) -> ToolResult<Option<String>>;
        fn replace_once(&self, text: &str, old: &str, new: &str) -> ToolResult<String>;
        fn write(&mut self, path: &Self::Path, content: &str) -> ToolResult<bool>;
    }

    pub fn execute(
        files: &mut impl Files,
        arguments: &Value,
        editing: bool,
        cancellation: &CancellationToken,
    ) -> ToolResult<Value> {
        check_cancelled(cancellation)?;
        let path = files.resolve(&arguments["path"], editing)?;
        let (previous, value) = if editing {
            let old = arguments["oldText"]
                .as_str()
                .filter(|text| !text.is_empty() && text.len() <= EDIT_BYTES)
                .ok_or_else(|| ToolError::failure("invalid_params", "Invalid oldText"))?;
            // Keep the source guard's short circuit: invalid newText must not
            // read a file, but file acquisition errors precede non-text errors.
            let new = arguments["newText"]
                .as_str()
                .filter(|text| text.len() <= EDIT_BYTES)
                .ok_or_else(invalid_edit)?;
            let previous = files.read_text(&path)?.ok_or_else(invalid_edit)?;
            let value = files.replace_once(&previous, old, new)?;
            (previous, value)
        } else {
            let content = arguments["content"]
                .as_str()
                .filter(|text| text.len() <= FILE_BYTES)
                .ok_or_else(|| {
                    ToolError::failure("tool_arguments", "Content must be text below 16 MiB")
                })?;
            let previous = files.read_text(&path).ok().flatten().unwrap_or_default();
            (previous, content.to_owned())
        };
        // Swift performs no cancellation check between this point and returning
        // the result. The Controller still records cancellation as unknown when
        // it cannot retain the result; no rollback or compare-and-swap is claimed.
        check_cancelled(cancellation)?;
        let existed = files.write(&path, &value)?;
        let (added, removed) = line_diff_stats(&previous, &value);
        let path = files.path(&path);
        let mut result = result_text(
            format!(
                "{} {path} (+{added} -{removed})",
                if editing { "Edited" } else { "Wrote" }
            ),
            false,
        );
        result["stats"] = json!({"path":path,"added":added,"removed":removed});
        if let Some((first, last)) = existed.then(|| changed_lines(&previous, &value)).flatten() {
            result["stats"]["line"] = json!(first);
            result["stats"]["lastLine"] = json!(last);
        }
        Ok(result)
    }

    fn invalid_edit() -> ToolError {
        ToolError::failure("tool_arguments", "Invalid edit or non-text file")
    }

    fn lines(text: &str) -> impl Iterator<Item = &str> + Clone {
        text.split('\n')
            .take(if text.is_empty() { 0 } else { usize::MAX })
    }

    /// Swift String equality is canonically equivalent, but the viewer below
    /// compares UTF-8 bytes. Do not conflate those two source contracts.
    pub fn line_diff_stats(old: &str, new: &str) -> (usize, usize) {
        let a = lines(old);
        let b = lines(new);
        let old_count = a.clone().count();
        let new_count = b.clone().count();
        let prefix = a
            .clone()
            .zip(b.clone())
            .take_while(|(a, b)| a.nfc().eq(b.nfc()))
            .count();
        let suffix = old
            .rsplit('\n')
            .take(old_count - prefix)
            .zip(new.rsplit('\n').take(new_count - prefix))
            .take_while(|(a, b)| a.nfc().eq(b.nfc()))
            .count();
        (new_count - prefix - suffix, old_count - prefix - suffix)
    }

    pub fn changed_lines(old: &str, new: &str) -> Option<(usize, usize)> {
        let a = old.as_bytes();
        let b = new.as_bytes();
        let prefix = a.iter().zip(b).take_while(|(a, b)| a == b).count();
        if prefix == a.len() && prefix == b.len() {
            return None;
        }
        let suffix = a
            .iter()
            .rev()
            .take(a.len() - prefix)
            .zip(b.iter().rev().take(b.len() - prefix))
            .take_while(|(a, b)| a == b)
            .count();
        let end = b.len() - suffix;
        let through = if end > prefix { end - 1 } else { prefix };
        let mut line = 1;
        let mut first = 1;
        for index in 0..through {
            if index == prefix {
                first = line;
            }
            if b[index] == b'\n' || (b[index] == b'\r' && b.get(index + 1) != Some(&b'\n')) {
                line += 1;
            }
        }
        if prefix == through {
            first = line;
        }
        Some((first, line))
    }
}

#[cfg(all(test, not(target_os = "macos")))]
pub(super) mod synthetic;

#[cfg(test)]
#[path = "edit/tests.rs"]
mod tests;
