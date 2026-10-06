//! Instruction-discovery subset of PiAgentCore/Resources.swift.
//!
//! Disconnected groundwork: this does not read environment variables, parse
//! Codex settings, discover skills, grant trust, or send instructions to a model.
//! The caller supplies already-resolved paths and settings. A later resource
//! layer must freeze the complete request (including skills) before admission.
use crate::{Result, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
};

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
    if options.limit > MAX_INSTRUCTION_BYTES || options.roots.is_empty() {
        return Err(invalid(
            "Invalid instruction limit or missing workspace root",
        ));
    }
    let all_paths = options
        .roots
        .iter()
        .chain(std::iter::once(&options.codex_home))
        .chain(&options.additional_paths);
    if all_paths
        .clone()
        .any(|p| !p.is_absolute() || p.to_str().is_none())
    {
        return Err(invalid("Instruction paths must be absolute UTF-8 paths"));
    }
    if options
        .fallback_names
        .iter()
        .any(|name| name.is_empty() || name.contains('/') || name == "." || name == "..")
    {
        return Err(invalid("Fallbacks must be filenames"));
    }
    let codex_home = canonical_path(&options.codex_home)?;
    let additional_paths = options
        .additional_paths
        .iter()
        .map(|p| canonical_path(p))
        .collect::<Result<Vec<_>>>()?;
    let mut roots = vec![];
    for root in &options.roots {
        let root = fs::canonicalize(root)?;
        if !root.is_dir() {
            return Err(invalid("Workspace root is not a directory"));
        }
        if !roots.contains(&root) {
            roots.push(root);
        }
    }
    let mut seen = HashSet::new();
    let mut directories = vec![];
    for root in &roots {
        for directory in repository_chain(root) {
            if seen.insert(directory.clone()) {
                directories.push(directory);
            }
        }
    }
    let mut snapshot = InstructionSnapshot {
        repository_root: directories[0].clone(),
        roots,
        codex_home: codex_home.clone(),
        limit: options.limit,
        included_bytes: 0,
        sources: vec![],
        diagnostics: vec![],
        instructions: String::new(),
    };
    let mut chunks = vec![];
    let names = ["AGENTS.override.md", "AGENTS.md"]
        .into_iter()
        .chain(options.fallback_names.iter().map(String::as_str))
        .collect::<Vec<_>>();
    for directory in std::iter::once(&codex_home).chain(&directories) {
        // Swift tests directory equality, rather than the iteration position.
        let global = directory == &codex_home;
        for name in names.iter().take(if global { 2 } else { names.len() }) {
            let path = directory.join(name);
            let Some(text) = string_file(&path)? else {
                continue;
            };
            if text.chars().all(source_whitespace) {
                continue;
            }
            let included = preview(&text, options.limit.saturating_sub(snapshot.included_bytes));
            let count = included.len();
            snapshot.included_bytes += count;
            let truncated = count < text.len();
            snapshot.sources.push(InstructionSource {
                path: fs::canonicalize(&path)?,
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
                chunks.push(format!("Instructions from {}:\n{included}", path.display()));
            }
            if truncated {
                snapshot
                    .diagnostics
                    .push(format!("Instruction budget reached at {}", path.display()));
            }
            break;
        }
    }
    for path in &additional_paths {
        if let Some(text) = string_file(path)? {
            let included = preview(&text, options.limit.saturating_sub(snapshot.included_bytes));
            snapshot.included_bytes += included.len();
            if !included.is_empty() {
                chunks.push(format!(
                    "Additional approved instructions from {}:\n{included}",
                    path.display()
                ));
            }
            let truncated = included.len() < text.len();
            snapshot.sources.push(InstructionSource {
                path: fs::canonicalize(path)?,
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

fn repository_chain(root: &Path) -> Vec<PathBuf> {
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

fn canonical_path(path: &Path) -> Result<PathBuf> {
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

fn string_file(path: &Path) -> Result<Option<String>> {
    // Source's fileExists skips missing paths (including dangling symlinks).
    if !path.exists() {
        return Ok(None);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    // Match Support.readBounded's nonblocking open, followed by descriptor-based
    // regular-file validation, including replacement races and symlink targets.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        const O_NONBLOCK: i32 = 0x800;
        #[cfg(target_os = "macos")]
        const O_NONBLOCK: i32 = 0x4;
        options.custom_flags(O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(invalid("Only regular files can be read"));
    }
    if metadata.len() > FILE_LIMIT as u64 {
        return Err(invalid("File exceeds the supported size limit"));
    }
    let mut bytes = vec![];
    file.take(FILE_LIMIT as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > FILE_LIMIT {
        return Err(invalid("File exceeds the supported size limit"));
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| invalid("Resource is not valid UTF-8"))
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
