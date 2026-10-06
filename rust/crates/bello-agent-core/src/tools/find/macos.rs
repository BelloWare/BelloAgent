//! Foundation's URL resolver and directory enumerator for native `find`.
//!
//! This entry point is called only inside the existing blocking worker. All
//! Objective-C objects, including the enumerator and its block, are created and
//! destroyed inside the autorelease pool; only Rust values leave the worker.

use super::super::{FileToolContext, ToolError, ToolResult, bounded_int, check_cancelled};
use super::{Candidate, ScanControl, Scanner, execute};
use block2::RcBlock;
use objc2::{
    rc::{Retained, autoreleasepool},
    runtime::Bool,
};
use objc2_foundation::{
    NSArray, NSDirectoryEnumerationOptions, NSDirectoryEnumerator, NSError, NSFileManager,
    NSNumber, NSString, NSURL, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLResourceKey,
};
use serde_json::Value;
use std::{collections::BTreeSet, path::Path, ptr::NonNull};
use tokio_util::sync::CancellationToken;
use unicode_normalization::UnicodeNormalization;

pub(super) fn invoke(
    context: &FileToolContext,
    arguments: &Value,
    cancellation: &CancellationToken,
) -> ToolResult<Value> {
    autoreleasepool(|_| {
        check_cancelled(cancellation)?;
        let manager = NSFileManager::defaultManager();
        // Source order matters: resolving a path may consult other roots or
        // expand a named user's home, even when the pattern or limit is invalid.
        let root = resolve_path(context, &arguments["path"], &manager)?;
        let pattern = arguments["pattern"]
            .as_str()
            .filter(|text| !text.is_empty() && text.len() <= 4096)
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid pattern"))?;
        let limit = bounded_int(&arguments["limit"], 100, 2000)?;
        let mut scanner = FoundationScanner::new(&manager, &root, cancellation)?;
        execute(&mut scanner, pattern, limit, cancellation)
    })
}

fn invalid_path() -> ToolError {
    ToolError::failure("invalid_params", "Invalid path")
}

fn native_path(path: &Path) -> ToolResult<Retained<NSString>> {
    path.to_str()
        .map(NSString::from_str)
        .ok_or_else(invalid_path)
}

fn url_path(url: &NSURL) -> ToolResult<Retained<NSString>> {
    url.path().ok_or_else(invalid_path)
}

/// Swift canonical(_:): file URL, standardizedFileURL, resolvingSymlinksInPath.
/// Foundation handles missing suffixes, aliases and symlink/parent ordering.
fn canonical(path: &NSString) -> ToolResult<Retained<NSURL>> {
    NSURL::fileURLWithPath(path)
        .URLByStandardizingPath()
        .and_then(|url| url.URLByResolvingSymlinksInPath())
        .ok_or_else(invalid_path)
}

fn appended(root: &NSURL, component: &NSString) -> ToolResult<Retained<NSURL>> {
    let appended = root
        .URLByAppendingPathComponent(component)
        .ok_or_else(invalid_path)?;
    canonical(&*url_path(&appended)?)
}

fn effective_roots(context: &FileToolContext) -> ToolResult<Vec<Retained<NSURL>>> {
    // Resources.workspaceRoots uses URL.path and Swift Set<String> equality.
    // NativeTools' shared Rust context only removes byte-identical PathBufs;
    // restore the source's canonical Unicode equality for Find alone. Preserve
    // the first spelling, including the primary root, for actual resolution.
    let mut seen = BTreeSet::new();
    let mut roots = Vec::new();
    for root in &context.roots {
        let url = NSURL::fileURLWithPath(&*native_path(root)?);
        let key: String = url_path(&url)?.to_string().nfc().collect();
        if seen.insert(key) {
            roots.push(url);
        }
    }
    Ok(roots)
}

fn resolve_path(
    context: &FileToolContext,
    value: &Value,
    manager: &NSFileManager,
) -> ToolResult<Retained<NSURL>> {
    if value.is_null() {
        // FileToolContext.path(nil, optional: true) returns its existing cwd URL.
        return Ok(NSURL::fileURLWithPath(&*native_path(&context.cwd)?));
    }
    let text = value
        .as_str()
        .filter(|text| !text.is_empty() && text.len() <= 4096)
        .ok_or_else(invalid_path)?;
    if text == "~" || text.starts_with("~/") {
        // Bare/current-user tilde uses the injected home, never ambient HOME.
        // Preserve separators for Foundation instead of using PathBuf::join,
        // which interprets a second leading slash as a new absolute path.
        let home = native_path(&context.home)?;
        return canonical(&NSString::from_str(&format!("{home}{}", &text[1..])));
    }
    let text = NSString::from_str(text);
    if value.as_str().is_some_and(|text| text.starts_with('~')) {
        // The named-user lookup occurs only during this explicit invocation.
        return canonical(&text.stringByExpandingTildeInPath());
    }
    if value.as_str().is_some_and(|text| text.starts_with('/')) {
        return canonical(&text);
    }
    let cwd = NSURL::fileURLWithPath(&*native_path(&context.cwd)?);
    let primary = appended(&cwd, &text)?;
    let roots = effective_roots(context)?;
    if roots.len() <= 1 || manager.fileExistsAtPath(&*url_path(&primary)?) {
        return Ok(primary);
    }
    // As in Swift, inspect every extra root. Exactly one existing candidate
    // wins; zero or multiple candidates keep the primary even if it is missing.
    let mut elsewhere = Vec::new();
    for root in roots.iter().skip(1) {
        let candidate = appended(root, &text)?;
        if manager.fileExistsAtPath(&*url_path(&candidate)?) {
            elsewhere.push(candidate);
        }
    }
    Ok(if elsewhere.len() == 1 {
        elsewhere.pop().expect("one existing extra-root candidate")
    } else {
        primary
    })
}

type ErrorHandler = RcBlock<dyn Fn(NonNull<NSURL>, NonNull<NSError>) -> Bool>;

struct FoundationScanner<'a> {
    root: Candidate,
    iterator: Option<Retained<NSDirectoryEnumerator<NSURL>>>,
    symbolic_link_keys: Retained<NSArray<NSURLResourceKey>>,
    // Keep the block alive through enumeration as well as the creation call.
    _error_handler: ErrorHandler,
    cancellation: &'a CancellationToken,
}

impl<'a> FoundationScanner<'a> {
    fn new(
        manager: &NSFileManager,
        root: &NSURL,
        cancellation: &'a CancellationToken,
    ) -> ToolResult<Self> {
        let mut is_directory = Bool::NO;
        // SAFETY: is_directory points to a live, initialized Objective-C Bool
        // for the synchronous call, and no pointer escapes into Rust state.
        if !unsafe { manager.fileExistsAtPath_isDirectory(&*url_path(root)?, &mut is_directory) } {
            return Err(ToolError::failure(
                "missing_path",
                "Search path does not exist",
            ));
        }
        // SAFETY: these immutable NSString constants belong to Foundation and
        // are available on every supported macOS version.
        let (directory_key, symbolic_link_key) =
            unsafe { (NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey) };
        let symbolic_link_keys = NSArray::from_slice(&[symbolic_link_key]);
        let error_handler = RcBlock::new(|_: NonNull<NSURL>, _: NonNull<NSError>| Bool::NO);
        let iterator = if is_directory.as_bool() {
            let keys = NSArray::from_slice(&[directory_key, symbolic_link_key]);
            Some(
                manager
                    .enumeratorAtURL_includingPropertiesForKeys_options_errorHandler(
                        root,
                        Some(&keys),
                        NSDirectoryEnumerationOptions::empty(),
                        Some(&error_handler),
                    )
                    .ok_or_else(|| {
                        ToolError::failure("search_failed", "Cannot enumerate search path")
                    })?,
            )
        } else {
            None
        };
        Ok(Self {
            root: candidate(root, false)?,
            iterator,
            symbolic_link_keys,
            _error_handler: error_handler,
            cancellation,
        })
    }

    fn is_symbolic_link(&self, url: &NSURL) -> bool {
        // Query the enumerated URL itself so Foundation's prefetched resource
        // cache is used. A failed query, absent key or NSNull behaves like the
        // source's (try? resourceValues(...).isSymbolicLink) == true.
        url.resourceValuesForKeys_error(&self.symbolic_link_keys)
            .ok()
            .and_then(|values| values.objectForKey(&self.symbolic_link_keys.objectAtIndex(0)))
            .and_then(|value| value.downcast::<NSNumber>().ok())
            .is_some_and(|value| value.boolValue())
    }
}

fn candidate(url: &NSURL, is_symbolic_link: bool) -> ToolResult<Candidate> {
    Ok(Candidate {
        path: url_path(url)?.to_string(),
        basename: url
            .lastPathComponent()
            .ok_or_else(invalid_path)?
            .to_string(),
        is_symbolic_link,
    })
}

impl Scanner for FoundationScanner<'_> {
    fn root(&self) -> &Candidate {
        &self.root
    }

    fn is_directory(&self) -> bool {
        self.iterator.is_some()
    }

    fn scan(
        &mut self,
        visit: &mut dyn FnMut(Candidate) -> ToolResult<ScanControl>,
    ) -> ToolResult<()> {
        let Some(iterator) = &self.iterator else {
            return Ok(());
        };
        while let Some(url) = iterator.nextObject() {
            check_cancelled(self.cancellation)?;
            let mut entry = candidate(&url, false)?;
            // Source checks excluded basenames before fetching resource values.
            if !matches!(entry.basename.as_str(), ".git" | "node_modules" | ".build") {
                entry.is_symbolic_link = self.is_symbolic_link(&url);
            }
            match visit(entry)? {
                ScanControl::Continue => {}
                ScanControl::SkipDescendants => iterator.skipDescendants(),
                ScanControl::Stop => break,
            }
        }
        // errorHandler returns false, so Foundation ends iteration at the first
        // enumeration error and the source returns the already-collected rows.
        Ok(())
    }
}
