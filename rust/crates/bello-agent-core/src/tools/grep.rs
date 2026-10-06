//! The source Grep loop with Foundation-only regular expression evaluation.
//!
//! Tests inject readers and matchers to exercise ordering, limits and output.
//! They do not substitute a Rust regex dialect for NSRegularExpression.

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
            "Native grep requires macOS Foundation",
        ))
    }
}

#[cfg(any(target_os = "macos", all(test, unix)))]
pub(in crate::tools) mod source {
    use super::*;
    use crate::tools::find::source::{
        Candidate, Scanned, Scanner, collect_candidates, preview, relative_path, search_result,
        sort_candidates,
    };

    #[cfg(target_os = "macos")]
    pub(in crate::tools) const FILE_BYTES: usize = 2 * 1024 * 1024;
    const LINE_BYTES: usize = 1000;

    pub(in crate::tools) struct Options<'a> {
        pub pattern: &'a str,
        pub literal: bool,
        pub ignore_case: bool,
        pub limit: usize,
    }

    pub(in crate::tools) enum ReadResult {
        Directory,
        Text(String),
        Skipped,
    }

    /// Inspect the original candidate's cached resource values first. Unless
    /// isDirectory is true, attempt source readBounded(maximum: FILE_BYTES) and
    /// strict Foundation UTF-8 decoding. All read/decoding failures are Skipped.
    /// A directory resource lookup failure still attempts to read the contents.
    pub(in crate::tools) trait Reader<Resource> {
        fn read(&mut self, candidate: &Candidate<Resource>) -> ReadResult;
    }

    pub(in crate::tools) trait RegexFactory {
        type Matcher: Matcher;

        fn compile(
            &mut self,
            pattern: &str,
            literal: bool,
            ignore_case: bool,
        ) -> ToolResult<Self::Matcher>;
    }

    pub(in crate::tools) trait Matcher {
        /// One synchronous firstMatch across the line's full UTF-16 range.
        /// Cancellation remains cooperative between calls, never thread kill.
        fn is_match(&mut self, line: &str) -> bool;
    }

    pub(in crate::tools) fn execute<S: Scanner>(
        scanner: &mut S,
        reader: &mut impl Reader<S::Resource>,
        factory: &mut impl RegexFactory,
        options: Options<'_>,
        cancellation: &CancellationToken,
    ) -> ToolResult<Value> {
        let Scanned {
            root,
            mut candidates,
            scan_truncated,
        } = collect_candidates(scanner, cancellation)?;
        // Source constructs the expression even with no candidates, only after
        // enumeration has completed or reached its cap, and before sorting.
        let mut matcher = factory.compile(options.pattern, options.literal, options.ignore_case)?;
        sort_candidates(&mut candidates);
        let mut hits = Vec::new();
        for candidate in candidates {
            check_cancelled(cancellation)?;
            let relative = relative_path(&candidate, &root);
            match reader.read(&candidate) {
                ReadResult::Directory => {}
                // Source guard/continue bypasses the outer limit check. At
                // limit zero, unreadable candidates therefore do not stop it.
                ReadResult::Skipped => continue,
                ReadResult::Text(text) => {
                    // Swift components(separatedBy: "\n") preserves CR and the
                    // final empty component, including one line for empty text.
                    for (index, line) in text.split('\n').enumerate() {
                        check_cancelled(cancellation)?;
                        if matcher.is_match(line) {
                            hits.push(format!(
                                "{relative}:{}: {}",
                                index + 1,
                                preview(line, LINE_BYTES)
                            ));
                        }
                        if hits.len() >= options.limit {
                            break;
                        }
                    }
                }
            }
            // Directories also reach this check, even without a regex call.
            if hits.len() >= options.limit {
                break;
            }
        }
        Ok(search_result(hits, options.limit, scan_truncated))
    }

    #[cfg(test)]
    mod tests {
        include!("grep/tests.rs");
    }
}
