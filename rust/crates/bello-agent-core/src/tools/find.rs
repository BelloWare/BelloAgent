//! The source Find loop, separated from Foundation's directory enumerator.
//!
//! Production traversal is deliberately macOS-only. Unix unit fixtures exercise
//! the pure loop and the platform fnmatch without presenting Linux traversal as
//! Foundation parity.

use super::{FileToolContext, ToolResult, check_cancelled};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

#[cfg(target_os = "macos")]
mod macos;

pub(super) fn invoke(
    context: &FileToolContext,
    arguments: &Value,
    cancellation: &CancellationToken,
) -> ToolResult<Value> {
    check_cancelled(cancellation)?;
    #[cfg(target_os = "macos")]
    {
        macos::invoke(context, arguments, cancellation)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (context, arguments);
        Err(super::ToolError::failure(
            "tool_unavailable",
            "Native find requires macOS Foundation",
        ))
    }
}

#[cfg(target_os = "macos")]
use self::source::{Candidate, ScanControl, Scanner, execute};

#[cfg(any(target_os = "macos", all(test, unix)))]
mod source {
    use super::*;
    use crate::tools::result_text;
    use std::ffi::{c_char, c_int};
    use unicode_normalization::UnicodeNormalization;
    use unicode_segmentation::UnicodeSegmentation;

    const CANDIDATE_LIMIT: usize = 20_000;
    const OUTPUT_BYTES: usize = 32_768;
    const LIMITED_FOOTER: &str = "\n[Search limited; narrow the path/pattern. Large/binary files and .git/node_modules/.build are skipped.]";
    const COMPLETE_FOOTER: &str =
        "\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]";

    /// Foundation supplies its URL.path and lastPathComponent without Rust
    /// filesystem/path conversions. Directories and special files are entries,
    /// too; Find never reads candidate contents or filters by file type.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub(super) struct Candidate {
        pub path: String,
        pub basename: String,
        pub is_symbolic_link: bool,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum ScanControl {
        Continue,
        SkipDescendants,
        Stop,
    }

    /// The adapter preserves enumeration order and obeys every visitor result.
    /// A native enumeration error ends scanning silently, as the source's
    /// errorHandler returning false does. Construction errors are reported
    /// before this interface is entered.
    pub(super) trait Scanner {
        fn root(&self) -> &Candidate;
        fn is_directory(&self) -> bool;
        fn scan(
            &mut self,
            visit: &mut dyn FnMut(Candidate) -> ToolResult<ScanControl>,
        ) -> ToolResult<()>;
    }

    pub(super) fn execute(
        scanner: &mut impl Scanner,
        pattern: &str,
        limit: usize,
        cancellation: &CancellationToken,
    ) -> ToolResult<Value> {
        check_cancelled(cancellation)?;
        let root = scanner.root().clone();
        let mut candidates = Vec::new();
        let mut scan_truncated = false;
        if scanner.is_directory() {
            scanner.scan(&mut |candidate| {
                check_cancelled(cancellation)?;
                if matches!(
                    candidate.basename.as_str(),
                    ".git" | "node_modules" | ".build"
                ) || candidate.is_symbolic_link
                {
                    return Ok(ScanControl::SkipDescendants);
                }
                candidates.push(candidate);
                // The cap precedes sorting and matching. Reaching exactly the
                // cap marks the scan limited even when this was its last entry.
                if candidates.len() >= CANDIDATE_LIMIT {
                    scan_truncated = true;
                    Ok(ScanControl::Stop)
                } else {
                    Ok(ScanControl::Continue)
                }
            })?;
        } else {
            // A selected file is not subject to the traversal exclusions.
            candidates.push(root.clone());
        }
        // Swift String.< compares canonically normalized Unicode scalars. Sort
        // full paths stably and keep each original spelling for matching/output.
        candidates.sort_by_cached_key(|candidate| candidate.path.nfc().collect::<String>());
        let mut hits = Vec::new();
        for candidate in candidates {
            check_cancelled(cancellation)?;
            let relative = relative_path(&candidate, &root);
            if glob_matches(pattern, relative) || glob_matches(pattern, &candidate.basename) {
                hits.push(relative.to_owned());
            }
            // Source checks after visiting a candidate, including a nonmatch.
            // With limit zero, only the first sorted candidate is considered.
            if hits.len() >= limit {
                break;
            }
        }
        let output = hits.join("\n");
        let limited = hits.len() >= limit || scan_truncated || output.len() > OUTPUT_BYTES;
        let mut text = preview(&output, OUTPUT_BYTES);
        text.push_str(if limited {
            LIMITED_FOOTER
        } else {
            COMPLETE_FOOTER
        });
        Ok(result_text(text, false))
    }

    fn relative_path<'a>(candidate: &'a Candidate, root: &Candidate) -> &'a str {
        let path = candidate.path.as_str();
        let root_path = root.path.as_str();
        let normalized_path: String = path.nfc().collect();
        let normalized_root: String = root_path.nfc().collect();
        let prefix = if root_path.ends_with('/') {
            root_path.to_owned()
        } else {
            format!("{root_path}/")
        };
        let within = normalized_path == normalized_root || swift_has_prefix(path, &prefix);
        if within && path != root_path {
            // Swift count/dropFirst operate on extended grapheme clusters, not
            // bytes or scalars. In particular root "/" drops TWO characters.
            let count = root_path.graphemes(true).count() + 1;
            path.grapheme_indices(true)
                .nth(count)
                .map_or("", |(offset, _)| &path[offset..])
        } else {
            &candidate.basename
        }
    }

    fn swift_has_prefix(text: &str, prefix: &str) -> bool {
        let mut text = text.graphemes(true);
        prefix
            .graphemes(true)
            .all(|prefix| text.next().is_some_and(|part| part.nfc().eq(prefix.nfc())))
    }

    fn preview(text: &str, bytes: usize) -> String {
        // String(decoding: UTF8.prefix(bytes), as: UTF8.self) is lossy. Swift
        // then trims actual U+FFFD at BOTH ends, even without byte truncation.
        String::from_utf8_lossy(&text.as_bytes()[..text.len().min(bytes)])
            .trim_matches('\u{fffd}')
            .to_owned()
    }

    unsafe extern "C" {
        fn fnmatch(pattern: *const c_char, name: *const c_char, flags: c_int) -> c_int;
    }

    fn glob_matches(pattern: &str, name: &str) -> bool {
        // Swift's implicit C-string bridge keeps embedded NUL bytes. fnmatch
        // observes the prefix before the first NUL; CString::new would reject it.
        let mut pattern = pattern.as_bytes().to_vec();
        let mut name = name.as_bytes().to_vec();
        pattern.push(0);
        name.push(0);
        // SAFETY: Both buffers remain alive and NUL-terminated for this call.
        // Flags are source-exact: '*' may match '/' and leading '.'.
        unsafe { fnmatch(pattern.as_ptr().cast(), name.as_ptr().cast(), 0) == 0 }
    }

    #[cfg(test)]
    mod tests {
        include!("find/tests.rs");
    }
}
