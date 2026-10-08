//! Instruction-discovery subset of PiAgentCore/Resources.swift.
//!
//! The caller supplies resolved paths/settings; discovery reads no environment,
//! Codex settings or skills and grants no trust. Production remains disconnected.
//! Saved runtimes use the explicit project-only entry point. Legacy synthetic
//! fixtures may supply a separate home explicitly; it is never inferred.
use crate::{Error, Result, invalid, project_resources::source_path};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
};
use tokio_util::sync::CancellationToken;

const FILE_LIMIT: usize = 1024 * 1024;
pub const DEFAULT_INSTRUCTION_BYTES: usize = 32768;
pub const MAX_INSTRUCTION_BYTES: usize = 262144;

/// Paths are explicit, canonical absolute paths. They are discovery context,
/// not a filesystem sandbox. No process home/configuration is consulted.
#[derive(Clone, Debug)]
pub struct InstructionOptions {
    pub roots: Vec<PathBuf>,
    pub codex_home: PathBuf,
    pub limit: usize,
    pub fallback_names: Vec<String>,
    pub additional_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstructionSource {
    pub path: PathBuf,
    pub scope: String,
    pub hash: String,
    pub bytes: usize,
    pub included_bytes: usize,
    pub truncated: bool,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    // Swift's approved-additional metadata does not carry the preview text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstructionSnapshot {
    pub roots: Vec<PathBuf>,
    /// Source-compatible spelling captured at discovery, for prompt text only.
    /// Access, deduplication and authority continue to use canonical `roots`.
    pub prompt_roots: Vec<PathBuf>,
    pub repository_root: PathBuf,
    pub codex_home: PathBuf,
    pub limit: usize,
    pub included_bytes: usize,
    pub sources: Vec<InstructionSource>,
    pub diagnostics: Vec<String>,
    /// Only the joined instruction chunks, not the complete resource prompt.
    pub instructions: String,
}

pub fn discover(options: &InstructionOptions) -> Result<InstructionSnapshot> {
    discover_with(
        &options.roots,
        Some(&options.codex_home),
        options.limit,
        &options.fallback_names,
        &options.additional_paths,
        &CancellationToken::new(),
    )
}

/// Project-only discovery. There is no Codex home and no home/config fallback.
pub fn discover_project(
    roots: &[PathBuf],
    limit: usize,
    cancel: &CancellationToken,
) -> Result<InstructionSnapshot> {
    discover_with(roots, None, limit, &[], &[], cancel)
}

fn discover_with(
    root_paths: &[PathBuf],
    home: Option<&PathBuf>,
    limit: usize,
    fallback_names: &[String],
    extra_paths: &[PathBuf],
    cancel: &CancellationToken,
) -> Result<InstructionSnapshot> {
    check_cancel(cancel)?;
    if limit > MAX_INSTRUCTION_BYTES || root_paths.is_empty() {
        return Err(invalid(
            "Invalid instruction limit or missing workspace root",
        ));
    }
    let all_paths = root_paths.iter().chain(home).chain(extra_paths);
    if all_paths
        .clone()
        .any(|p| !p.is_absolute() || p.to_str().is_none())
    {
        return Err(invalid("Instruction paths must be absolute UTF-8 paths"));
    }
    if fallback_names
        .iter()
        .any(|name| name.is_empty() || name.contains('/') || name == "." || name == "..")
    {
        return Err(invalid("Fallbacks must be filenames"));
    }
    let codex_home = home.map(|p| canonical_path(p)).transpose()?;
    let additional_paths = extra_paths
        .iter()
        .map(|p| canonical_path(p))
        .collect::<Result<Vec<_>>>()?;
    let (roots, directories) = project_directories(root_paths, cancel)?;
    let prompt_roots = roots
        .iter()
        .map(|root| {
            check_cancel(cancel)?;
            source_path::existing(root, root)
        })
        .collect::<Result<Vec<_>>>()?;
    let mut snapshot = InstructionSnapshot {
        prompt_roots,
        repository_root: directories[0].clone(),
        roots,
        codex_home: codex_home.clone().unwrap_or_default(),
        limit,
        included_bytes: 0,
        sources: vec![],
        diagnostics: vec![],
        instructions: String::new(),
    };
    let mut chunks = vec![];
    let names = ["AGENTS.override.md", "AGENTS.md"]
        .into_iter()
        .chain(fallback_names.iter().map(String::as_str))
        .collect::<Vec<_>>();
    for directory in codex_home.iter().chain(&directories) {
        check_cancel(cancel)?;
        // Swift tests directory equality, rather than the iteration position.
        let global = codex_home.as_ref() == Some(directory);
        for name in names.iter().take(if global { 2 } else { names.len() }) {
            let path = directory.join(name);
            let Some((text, canonical)) = read_resource_file(&path, FILE_LIMIT, cancel)? else {
                continue;
            };
            if text.chars().all(source_whitespace) {
                continue;
            }
            // Swift appends the locator filename to the resolved directory for
            // headers/diagnostics, but separately resolves the leaf for metadata.
            // Capture presentation after the bounded read, checking its target.
            let locator = source_path::existing(directory, directory)?.join(name);
            let source = source_path::existing(&locator, &canonical)?;
            let included = preview(&text, limit.saturating_sub(snapshot.included_bytes));
            let count = included.len();
            snapshot.included_bytes += count;
            let truncated = count < text.len();
            snapshot.sources.push(InstructionSource {
                path: source,
                scope: if global { "global" } else { "project" }.into(),
                hash: hash(&text),
                bytes: text.len(),
                included_bytes: count,
                truncated,
                state: if truncated { "truncated" } else { "included" }.into(),
                reason: Some("Selected by Codex precedence".into()),
                text: Some(included.clone()),
            });
            if count > 0 {
                chunks.push(format!(
                    "Instructions from {}:\n{included}",
                    locator.display()
                ));
            }
            if truncated {
                snapshot.diagnostics.push(format!(
                    "Instruction budget reached at {}",
                    locator.display()
                ));
            }
            break;
        }
    }
    for path in &additional_paths {
        if let Some((text, canonical)) = read_resource_file(path, FILE_LIMIT, cancel)? {
            let source = source_path::existing(path, &canonical)?;
            let included = preview(&text, limit.saturating_sub(snapshot.included_bytes));
            snapshot.included_bytes += included.len();
            if !included.is_empty() {
                chunks.push(format!(
                    "Additional approved instructions from {}:\n{included}",
                    source.display()
                ));
            }
            let truncated = included.len() < text.len();
            snapshot.sources.push(InstructionSource {
                path: source,
                scope: "approved additional".into(),
                hash: hash(&text),
                bytes: text.len(),
                included_bytes: included.len(),
                truncated,
                state: if truncated { "truncated" } else { "included" }.into(),
                reason: None,
                text: None,
            });
        }
    }
    snapshot.instructions = chunks.join("\n\n");
    Ok(snapshot)
}

pub(crate) fn repository_chain(root: &Path) -> Vec<PathBuf> {
    repository_chain_by(root, |directory| directory.join(".git").exists())
}
fn repository_chain_by(root: &Path, is_repository: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    let mut reversed = vec![];
    for directory in root.ancestors().take_while(|path| path.parent().is_some()) {
        reversed.push(directory.to_path_buf());
        if is_repository(directory) {
            reversed.reverse();
            return reversed;
        }
    }
    // Outside a repository, source deliberately does not walk parent files.
    vec![root.to_path_buf()]
}

pub(crate) fn canonical_path(path: &Path) -> Result<PathBuf> {
    // Foundation resolves existing symlinks even when the final component does
    // not exist. Keep missing optional resource directories discoverable.
    if path.exists() {
        return Ok(fs::canonicalize(path)?);
    }
    let parent = path
        .parent()
        .ok_or_else(|| invalid("Invalid instruction path"))?;
    let name = path
        .file_name()
        .ok_or_else(|| invalid("Invalid instruction path"))?;
    Ok(canonical_path(parent)?.join(name))
}

/// Canonical primary-first roots and repository chains, with shared ancestors
/// visited once. Canonical symlinks are source identity, not containment policy.
pub(crate) fn project_directories(
    root_paths: &[PathBuf],
    cancel: &CancellationToken,
) -> Result<(Vec<PathBuf>, Vec<PathBuf>)> {
    if root_paths.is_empty() || root_paths.len() > 128 {
        return Err(invalid("Invalid project resource roots"));
    }
    let mut roots = Vec::new();
    for root in root_paths {
        check_cancel(cancel)?;
        if !root.is_absolute()
            || root
                .to_str()
                .is_none_or(|v| v.len() > 65_536 || v.contains('\0'))
        {
            return Err(invalid("Resource roots must be absolute UTF-8 paths"));
        }
        let root = fs::canonicalize(root)?;
        if !root.is_dir() {
            return Err(invalid("Workspace root is not a directory"));
        }
        if !roots.contains(&root) {
            roots.push(root);
        }
    }
    let mut seen = HashSet::new();
    let mut directories = Vec::new();
    for root in &roots {
        check_cancel(cancel)?;
        for directory in repository_chain(root) {
            check_cancel(cancel)?;
            if seen.insert(directory.clone()) {
                directories.push(directory);
            }
        }
    }
    Ok((roots, directories))
}
pub(crate) fn check_cancel(cancel: &CancellationToken) -> Result<()> {
    if cancel.is_cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
/// Nonblocking acquisition, descriptor regular-file verification, maximum-plus-
/// one chunked reads, and observable replacement/growth checks. Never opens home
/// or configuration files on its own. Callers supply the exact resource path.
pub(crate) fn read_resource_file(
    path: &Path,
    limit: usize,
    cancel: &CancellationToken,
) -> Result<Option<(String, PathBuf)>> {
    check_cancel(cancel)?;
    let canonical = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        const O_NONBLOCK: i32 = 0x800;
        #[cfg(target_os = "macos")]
        const O_NONBLOCK: i32 = 0x4;
        options.custom_flags(O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(invalid("Only regular resource files can be read"));
    }
    if before.len() > limit as u64 {
        return Err(invalid("Resource file exceeds the supported size limit"));
    }
    let mut bytes = Vec::with_capacity(before.len() as usize);
    let mut chunk = [0u8; 65_536];
    loop {
        check_cancel(cancel)?;
        let maximum = (limit + 1 - bytes.len()).min(chunk.len());
        let count = file.read(&mut chunk[..maximum])?;
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if bytes.len() > limit || bytes.len() > before.len() as usize {
            return Err(invalid("Resource file changed or exceeded its size limit"));
        }
    }
    let unchanged = |current: &fs::Metadata| {
        let same = current.is_file()
            && current.len() == before.len()
            && current.modified().ok() == before.modified().ok();
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            same && current.dev() == before.dev()
                && current.ino() == before.ino()
                && current.ctime() == before.ctime()
                && current.ctime_nsec() == before.ctime_nsec()
        }
        #[cfg(not(unix))]
        {
            same
        }
    };
    if bytes.len() != before.len() as usize
        || !unchanged(&file.metadata()?)
        || !unchanged(&fs::metadata(path)?)
        || fs::canonicalize(path)? != canonical
    {
        return Err(invalid("Resource changed during discovery; refresh"));
    }
    check_cancel(cancel)?;
    let text = String::from_utf8(bytes).map_err(|_| invalid("Resource is not valid UTF-8"))?;
    Ok(Some((text, canonical)))
}

// Foundation CharacterSet.whitespacesAndNewlines includes U+200B, unlike
// Rust's Unicode White_Space property; U+FEFF is deliberately not included.
fn source_whitespace(c: char) -> bool {
    matches!(c, '\u{0009}'..='\u{000d}' | ' ' | '\u{0085}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200b}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}')
}

fn preview(text: &str, limit: usize) -> String {
    // Swift decodes the byte prefix, then trims replacement characters at both
    // ends, including genuine U+FFFD characters. Preserve that exact behavior.
    String::from_utf8_lossy(&text.as_bytes()[..text.len().min(limit)])
        .trim_matches('\u{fffd}')
        .into()
}
fn hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn instructions_outside_repository_never_walk_parent_instructions() {
        let root = Path::new("/fixture/project/nested");
        assert_eq!(
            repository_chain_by(root, |_| false),
            vec![root.to_path_buf()]
        );
        assert_eq!(
            repository_chain_by(root, |path| path == Path::new("/fixture/project")),
            vec![PathBuf::from("/fixture/project"), root.to_path_buf()]
        );
    }
}
