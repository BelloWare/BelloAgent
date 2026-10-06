//! Source-exact Foundation regex matching and bounded file reads for Grep.
//!
//! Everything Objective-C stays on the existing blocking worker and inside its
//! autorelease pool. In particular, candidates retain the enumerator's original
//! NSURLs so later directory checks observe Foundation's prefetched resources.

use super::super::{FileToolContext, ToolError, ToolResult, bounded_int, check_cancelled};
use super::source::{FILE_BYTES, Matcher, Options, ReadResult, Reader, RegexFactory, execute};
use crate::tools::find::{
    macos::{FoundationScanner, resolve_path},
    source::Candidate,
};
use objc2::{
    AnyThread, msg_send,
    rc::{Retained, autoreleasepool},
};
use objc2_foundation::{
    NSArray, NSData, NSError, NSFileHandle, NSFileManager, NSMatchingOptions, NSNumber, NSRange,
    NSRegularExpression, NSRegularExpressionOptions, NSString, NSURL, NSURLIsDirectoryKey,
    NSURLResourceKey, NSUTF8StringEncoding,
};
use serde_json::Value;
use std::mem::MaybeUninit;
use tokio_util::sync::CancellationToken;

pub(super) fn invoke(
    context: &FileToolContext,
    arguments: &Value,
    cancellation: &CancellationToken,
) -> ToolResult<Value> {
    autoreleasepool(|_| {
        check_cancelled(cancellation)?;
        let manager = NSFileManager::defaultManager();
        // Preserve source argument order and the shared multi-root resolver.
        let root = resolve_path(context, &arguments["path"], &manager)?;
        let pattern = arguments["pattern"]
            .as_str()
            .filter(|text| !text.is_empty() && text.len() <= 4096)
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid pattern"))?;
        let limit = bounded_int(&arguments["limit"], 100, 2000)?;
        let mut scanner = FoundationScanner::new(&manager, &root, cancellation)?;
        let mut reader = FoundationReader::new();
        let mut factory = FoundationRegexFactory;
        // execute collects and caps the scan before asking the factory to
        // compile, including when the supplied regex is invalid.
        execute(
            &mut scanner,
            &mut reader,
            &mut factory,
            Options {
                pattern,
                literal: arguments["literal"].as_bool() == Some(true),
                ignore_case: arguments["ignoreCase"].as_bool() == Some(true),
                limit,
            },
            cancellation,
        )
    })
}

struct FoundationReader {
    directory_keys: Retained<NSArray<NSURLResourceKey>>,
}

impl FoundationReader {
    fn new() -> Self {
        Self {
            // SAFETY: this immutable Foundation constant is available on every
            // supported macOS version.
            directory_keys: NSArray::from_slice(&[unsafe { NSURLIsDirectoryKey }]),
        }
    }
}

impl Reader<Retained<NSURL>> for FoundationReader {
    fn read(&mut self, candidate: &Candidate<Retained<NSURL>>) -> ReadResult {
        let is_directory = candidate
            .resource
            .resourceValuesForKeys_error(&self.directory_keys)
            .ok()
            .and_then(|values| values.objectForKey(&self.directory_keys.objectAtIndex(0)))
            .and_then(|value| value.downcast::<NSNumber>().ok())
            .is_some_and(|value| value.boolValue());
        if is_directory {
            return ReadResult::Directory;
        }
        // A resource lookup failure falls through to readBounded, while any
        // open/type/size/read/decode failure silently skips this candidate.
        match read_bounded_utf8(&candidate.path) {
            Some(text) => ReadResult::Text(text),
            None => ReadResult::Skipped,
        }
    }
}

/// Mirror Support.readBounded, including nonblocking opens for special files,
/// descriptor metadata, one bounded Foundation read, and Foundation UTF-8
/// decoding (including its BOM handling). No path-based stat/read race is added.
fn read_bounded_utf8(path: &str) -> Option<String> {
    // Swift's implicit C-string bridge preserves embedded NUL bytes; POSIX open
    // observes their prefix. CString::new would reject a source-valid argument.
    let mut path = path.as_bytes().to_vec();
    path.push(0);
    // SAFETY: the NUL-terminated buffer stays alive for open; no creation flag
    // is supplied, so no variadic mode argument is required.
    let descriptor = unsafe {
        libc::open(
            path.as_ptr().cast(),
            libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return None;
    }
    let handle = ClosingFileHandle(NSFileHandle::initWithFileDescriptor_closeOnDealloc(
        NSFileHandle::alloc(),
        descriptor,
        true,
    ));
    let mut info = MaybeUninit::<libc::stat>::zeroed();
    // SAFETY: the descriptor is owned by the live FileHandle, and info is a
    // correctly sized, aligned output buffer for this synchronous fstat call.
    if unsafe { libc::fstat(descriptor, info.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: successful fstat initialized the complete stat output.
    let info = unsafe { info.assume_init() };
    if info.st_mode & libc::S_IFMT != libc::S_IFREG || info.st_size > FILE_BYTES as libc::off_t {
        return None;
    }
    let mut error: Option<Retained<NSError>> = None;
    // SAFETY: this is NSFileHandle's readDataUpToLength:error: selector, with a
    // live handle, NSUInteger bound, and autoreleasing NSError out parameter.
    // Spell its nullable data result explicitly: the source maps nil without
    // an error to empty Data, which the generated non-null binding cannot do.
    let data: Option<Retained<NSData>> =
        unsafe { msg_send![&*handle.0, readDataUpToLength: FILE_BYTES + 1, error: &mut error] };
    if error.is_some() {
        return None;
    }
    let Some(data) = data else {
        return Some(String::new());
    };
    if data.length() > FILE_BYTES {
        return None;
    }
    NSString::initWithData_encoding(NSString::alloc(), &data, NSUTF8StringEncoding)
        .map(|text| text.to_string())
}

/// Match the source's explicit deferred close on every return path. Foundation
/// also owns the descriptor, providing the source's close-on-deallocation guard.
struct ClosingFileHandle(Retained<NSFileHandle>);

impl Drop for ClosingFileHandle {
    fn drop(&mut self) {
        let _ = self.0.closeAndReturnError();
    }
}

struct FoundationRegexFactory;

impl RegexFactory for FoundationRegexFactory {
    type Matcher = FoundationMatcher;

    fn compile(
        &mut self,
        pattern: &str,
        literal: bool,
        ignore_case: bool,
    ) -> ToolResult<Self::Matcher> {
        let pattern = NSString::from_str(pattern);
        let pattern = if literal {
            NSRegularExpression::escapedPatternForString(&pattern)
        } else {
            pattern
        };
        let options = if ignore_case {
            NSRegularExpressionOptions::CaseInsensitive
        } else {
            NSRegularExpressionOptions::empty()
        };
        NSRegularExpression::initWithPattern_options_error(
            NSRegularExpression::alloc(),
            &pattern,
            options,
        )
        .map(FoundationMatcher)
        .map_err(|error| ToolError::Native {
            domain: error.domain().to_string(),
            code: error.code() as i64,
            message: error.localizedDescription().to_string(),
        })
    }
}

struct FoundationMatcher(Retained<NSRegularExpression>);

impl Matcher for FoundationMatcher {
    fn is_match(&mut self, line: &str) -> bool {
        let line = NSString::from_str(line);
        self.0
            .firstMatchInString_options_range(
                &line,
                NSMatchingOptions::empty(),
                NSRange::new(0, line.length()),
            )
            .is_some()
    }
}
