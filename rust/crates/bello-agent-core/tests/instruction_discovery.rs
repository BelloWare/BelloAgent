use bello_agent_core::instructions::{
    DEFAULT_INSTRUCTION_BYTES, InstructionOptions, MAX_INSTRUCTION_BYTES, discover,
};
use std::{fs, path::Path};
fn put(path: &Path, text: impl AsRef<[u8]>) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}
fn options(root: &Path) -> InstructionOptions {
    fs::create_dir_all(root.join("project")).unwrap();
    put(&root.join("project/.git"), "isolated fixture");
    InstructionOptions {
        roots: vec![root.join("project")],
        codex_home: root.join("codex"),
        limit: DEFAULT_INSTRUCTION_BYTES,
        fallback_names: vec![],
        additional_paths: vec![],
    }
}
#[test]
fn instructions_precedence_repository_chains_and_shared_ancestors() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    put(&root.join("AGENTS.md"), "OUTSIDE");
    put(&root.join("codex/AGENTS.md"), "GLOBAL");
    put(&root.join("project/.git"), "gitdir: fixture");
    put(&root.join("project/AGENTS.md"), "ROOT");
    put(&root.join("project/a/AGENTS.md"), "IGNORED");
    put(&root.join("project/a/AGENTS.override.md"), "OVERRIDE");
    put(&root.join("project/b/FALLBACK.md"), "FALLBACK");
    o.roots = vec![
        root.join("project/a"),
        root.join("project/b"),
        root.join("project/a"),
    ];
    o.fallback_names = vec!["FALLBACK.md".into()];
    let s = discover(&o).unwrap();
    assert_eq!(
        s.sources
            .iter()
            .map(|s| s.text.as_deref().unwrap())
            .collect::<Vec<_>>(),
        vec!["GLOBAL", "ROOT", "OVERRIDE", "FALLBACK"]
    );
    assert_eq!(s.roots.len(), 2);
    assert_eq!(
        s.repository_root,
        fs::canonicalize(root.join("project")).unwrap()
    );
    assert!(!s.instructions.contains("OUTSIDE"));
    assert!(!s.instructions.contains("IGNORED"));
    assert_eq!(s.sources[0].scope, "global");
    assert_eq!(s.sources[1].scope, "project");
}
#[test]
fn instructions_blank_override_and_global_fallback_exclusion() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    put(&root.join("AGENTS.md"), "PARENT");
    put(&root.join("project/AGENTS.override.md"), " \n\t");
    put(&root.join("project/AGENTS.md"), "LOCAL");
    put(
        &root.join("codex/fallback"),
        "GLOBAL FALLBACK MUST NOT LOAD",
    );
    o.fallback_names = vec!["fallback".into()];
    let s = discover(&o).unwrap();
    assert_eq!(s.sources.len(), 1);
    assert_eq!(s.sources[0].text.as_deref(), Some("LOCAL"));
    assert!(!s.instructions.contains("PARENT"));
    assert_eq!(
        s.repository_root,
        fs::canonicalize(root.join("project")).unwrap()
    );
}
#[test]
fn instructions_budget_utf8_diagnostics_and_source_identity() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    o.limit = 8;
    put(&root.join("codex/AGENTS.md"), "🙂汉字🙂");
    put(&root.join("project/AGENTS.md"), "XYZ");
    let s = discover(&o).unwrap();
    assert_eq!(s.included_bytes, 8);
    assert_eq!(s.sources[0].text.as_deref(), Some("🙂汉"));
    assert_eq!(s.sources[0].included_bytes, 7);
    assert_eq!(s.sources[1].text.as_deref(), Some("X"));
    assert_eq!(s.diagnostics.len(), 2);
    assert!(
        s.sources
            .iter()
            .all(|s| s.truncated && s.state == "truncated")
    );
    o.limit = 0;
    let zero = discover(&o).unwrap();
    assert!(zero.instructions.is_empty());
    assert_eq!(zero.sources.len(), 2);
    assert_eq!(s.sources[0].hash, zero.sources[0].hash);
    assert_eq!(zero.diagnostics.len(), 2);
    // A later discovery must neither mutate a frozen result nor reuse stale bytes.
    put(&root.join("codex/AGENTS.md"), "NEW");
    let changed = discover(&o).unwrap();
    assert_ne!(changed.sources[0].hash, s.sources[0].hash);
    assert_eq!(s.sources[0].text.as_deref(), Some("🙂汉"));
}
#[test]
fn instructions_additional_paths_preserve_source_metadata_and_empty_files() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    o.limit = 3;
    put(&root.join("extra"), "ABCDE");
    put(&root.join("empty"), "");
    o.additional_paths = vec![root.join("extra"), root.join("missing"), root.join("empty")];
    let s = discover(&o).unwrap();
    assert_eq!(s.included_bytes, 3);
    assert_eq!(s.sources.len(), 2);
    assert!(s.instructions.ends_with("\nABC"));
    assert!(s.diagnostics.is_empty());
    assert!(s.sources[0].truncated);
    assert!(s.sources[0].text.is_none());
    assert!(s.sources[0].reason.is_none());
    assert_eq!(s.sources[1].bytes, 0);
    assert!(!s.sources[1].truncated);
}
#[test]
fn instructions_invalid_oversized_and_nonregular_files_fail_closed() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    let file = root.join("project/AGENTS.md");
    put(&file, [0xff]);
    assert!(discover(&o).is_err());
    put(&file, vec![b'a'; 1024 * 1024 + 1]);
    assert!(discover(&o).is_err());
    fs::remove_file(&file).unwrap();
    fs::create_dir(&file).unwrap();
    assert!(discover(&o).is_err());
    fs::remove_dir(&file).unwrap();
    o.limit = MAX_INSTRUCTION_BYTES + 1;
    assert!(discover(&o).is_err());
    o.limit = 1;
    for name in ["", ".", "..", "../AGENTS.md", "nested/file"] {
        o.fallback_names = vec![name.into()];
        assert!(discover(&o).is_err());
    }
    o.fallback_names.clear();
    o.roots.clear();
    assert!(discover(&o).is_err());
}
#[cfg(unix)]
#[test]
fn instructions_symlinks_are_resolution_context_not_a_sandbox() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    put(&root.join("outside"), "OUTSIDE");
    symlink(root.join("outside"), root.join("project/AGENTS.md")).unwrap();
    symlink(root.join("project"), root.join("alias")).unwrap();
    o.roots.push(root.join("alias"));
    let s = discover(&o).unwrap();
    assert_eq!(s.roots.len(), 1);
    assert_eq!(
        s.sources[0].path,
        fs::canonicalize(root.join("outside")).unwrap()
    );
    assert!(s.instructions.ends_with("OUTSIDE"));
}

#[test]
fn instructions_preview_matches_swift_replacement_character_trimming() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut o = options(root);
    put(&root.join("project/AGENTS.md"), "\u{fffd}A\u{fffd}");
    o.limit = 7;
    let s = discover(&o).unwrap();
    assert_eq!(s.sources[0].text.as_deref(), Some("A"));
    assert_eq!(s.included_bytes, 1);
    assert!(s.sources[0].truncated);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn instructions_fifo_and_device_rejected_without_reading() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let o = options(root);
    let file = root.join("project/AGENTS.md");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(&file)
            .status()
            .unwrap()
            .success()
    );
    assert!(discover(&o).unwrap_err().to_string().contains("regular"));
    fs::remove_file(&file).unwrap();
    symlink("/dev/null", &file).unwrap();
    assert!(discover(&o).unwrap_err().to_string().contains("regular"));
}

#[test]
fn instructions_foundation_blank_override_skips_zero_width_space_but_not_bom() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let o = options(root);
    put(&root.join("project/AGENTS.md"), "FALLBACK");
    put(
        &root.join("project/AGENTS.override.md"),
        "\u{200b}\u{0085}\u{2028}\u{3000}",
    );
    assert_eq!(
        discover(&o).unwrap().sources[0].text.as_deref(),
        Some("FALLBACK")
    );
    put(&root.join("project/AGENTS.override.md"), "\u{feff}");
    assert_eq!(
        discover(&o).unwrap().sources[0].text.as_deref(),
        Some("\u{feff}")
    );
}
