use super::*;
use crate::tools::ToolError;

struct FixtureScanner {
    root: Candidate,
    directory: bool,
    entries: Vec<Candidate>,
    visited: Vec<(String, ScanControl)>,
    scans: usize,
    cancel_before: Option<(usize, CancellationToken)>,
    cancel_after_scan: Option<CancellationToken>,
    stop_before: Option<usize>,
}

impl FixtureScanner {
    fn directory(root: &str, paths: &[&str]) -> Self {
        Self {
            root: candidate(root),
            directory: true,
            entries: paths.iter().map(|path| candidate(path)).collect(),
            visited: Vec::new(),
            scans: 0,
            cancel_before: None,
            cancel_after_scan: None,
            stop_before: None,
        }
    }

    fn file(path: &str) -> Self {
        Self {
            directory: false,
            ..Self::directory(path, &[])
        }
    }

    fn find(&mut self, pattern: &str, limit: usize) -> Value {
        execute(self, pattern, limit, &CancellationToken::new()).unwrap()
    }
}

impl Scanner for FixtureScanner {
    fn root(&self) -> &Candidate {
        &self.root
    }

    fn is_directory(&self) -> bool {
        self.directory
    }

    fn scan(
        &mut self,
        visit: &mut dyn FnMut(Candidate) -> ToolResult<ScanControl>,
    ) -> ToolResult<()> {
        self.scans += 1;
        let mut skipped_prefix: Option<String> = None;
        for (index, entry) in self.entries.iter().enumerate() {
            if self.stop_before == Some(index) {
                break;
            }
            if let Some((cancel_at, cancellation)) = &self.cancel_before
                && index == *cancel_at
            {
                cancellation.cancel();
            }
            if skipped_prefix
                .as_ref()
                .is_some_and(|prefix| entry.path.starts_with(prefix))
            {
                continue;
            }
            skipped_prefix = None;
            let control = visit(entry.clone())?;
            self.visited.push((entry.path.clone(), control));
            match control {
                ScanControl::Continue => {}
                ScanControl::SkipDescendants => {
                    skipped_prefix = Some(format!("{}/", entry.path));
                }
                ScanControl::Stop => break,
            }
        }
        if let Some(cancellation) = &self.cancel_after_scan {
            cancellation.cancel();
        }
        Ok(())
    }
}

fn candidate(path: &str) -> Candidate {
    Candidate {
        path: path.to_owned(),
        basename: path.rsplit('/').next().unwrap_or("").to_owned(),
        is_symbolic_link: false,
    }
}

fn text(value: &Value) -> &str {
    value["content"][0]["text"].as_str().unwrap()
}

#[test]
fn exact_envelope_and_misleading_source_footers_are_preserved() {
    let mut empty = FixtureScanner::directory("/fixture", &[]);
    assert_eq!(
        empty.find("*", 100),
        serde_json::json!({
            "content": [{"type": "text", "text": "\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]"}],
            "isError": false
        })
    );
    let mut one = FixtureScanner::file("/fixture/file.bin");
    let result = one.find("*", 100);
    assert_eq!(text(&result), format!("file.bin{COMPLETE_FOOTER}"));
    assert!(result.get("stats").is_none());
    assert_eq!(one.scans, 0);
    assert_eq!(
        text(&one.find("*", 1)),
        "file.bin\n[Search limited; narrow the path/pattern. Large/binary files and .git/node_modules/.build are skipped.]"
    );
}

#[test]
fn directory_and_special_file_candidates_are_not_filtered_or_suffixed() {
    let mut scanner = FixtureScanner::directory(
        "/fixture",
        &[
            "/fixture/dir",
            "/fixture/dir/file.bin",
            "/fixture/large.dat",
            "/fixture/fifo",
            "/fixture/.hidden",
        ],
    );
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!(".hidden\ndir\ndir/file.bin\nfifo\nlarge.dat{COMPLETE_FOOTER}")
    );
}

#[test]
fn native_fnmatch_flags_zero_matches_relative_or_basename() {
    let mut scanner = FixtureScanner::directory(
        "/fixture",
        &[
            "/fixture/nested/deeper/README.md",
            "/fixture/nested/.hidden",
            "/fixture/root.md",
        ],
    );
    assert_eq!(
        text(&scanner.find("README.md", 100)),
        format!("nested/deeper/README.md{COMPLETE_FOOTER}")
    );
    assert_eq!(
        text(&scanner.find("nested/*", 100)),
        format!("nested/.hidden\nnested/deeper/README.md{COMPLETE_FOOTER}")
    );
    assert!(glob_matches("*", ".hidden"));
    assert!(glob_matches("[ab]?", "az"));
    assert!(glob_matches(r"literal\*", "literal*"));
    assert!(!glob_matches(r"literal\*", "literalX"));
    // Malformed brackets differ between Darwin and glibc. Preserve the native
    // result used by Swift instead of imposing the Linux fixture's behavior.
    #[cfg(target_os = "macos")]
    assert!(!glob_matches("[", "["));
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    assert!(glob_matches("[", "["));
    assert!(!glob_matches("README.md", "readme.md"));
}

#[test]
fn c_strings_preserve_embedded_nul_truncation() {
    assert!(glob_matches("file\0ignored-pattern", "file"));
    assert!(glob_matches("file", "file\0ignored-name"));
    assert!(glob_matches("file\0ignored", "file\0also-ignored"));
    assert!(!glob_matches("file\0*", "file-other"));
    let mut scanner = FixtureScanner::file("/fixture/file");
    assert_eq!(
        text(&scanner.find("file\0different", 100)),
        format!("file{COMPLETE_FOOTER}")
    );
}

#[test]
fn zero_limit_visits_only_the_first_sorted_candidate() {
    let mut empty = FixtureScanner::directory("/fixture", &[]);
    assert_eq!(text(&empty.find("*", 0)), LIMITED_FOOTER);
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/z", "/fixture/a"]);
    assert_eq!(
        text(&scanner.find("a", 0)),
        format!("a{LIMITED_FOOTER}")
    );
    assert_eq!(text(&scanner.find("z", 0)), LIMITED_FOOTER);
    assert_eq!(
        text(&scanner.find("*", 0)),
        format!("a{LIMITED_FOOTER}")
    );
}

#[test]
fn exact_hit_limit_is_limited_even_when_no_more_matches_exist() {
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/a", "/fixture/b"]);
    assert_eq!(
        text(&scanner.find("*", 2)),
        format!("a\nb{LIMITED_FOOTER}")
    );
    assert_eq!(
        text(&scanner.find("a", 1)),
        format!("a{LIMITED_FOOTER}")
    );
    assert_eq!(
        text(&scanner.find("a", 2)),
        format!("a{COMPLETE_FOOTER}")
    );
}

#[test]
fn sort_uses_normalized_full_paths_and_retains_original_spelling() {
    let mut scanner = FixtureScanner::directory(
        "/fixture",
        &[
            "/fixture/e\u{301}",
            "/fixture/é",
            "/fixture/z",
            "/fixture/a/z",
            "/fixture/Z/a",
        ],
    );
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!("Z/a\na/z\nz\ne\u{301}\né{COMPLETE_FOOTER}")
    );
    // Normalization is for sort/equality only, never for fnmatch.
    assert_eq!(
        text(&scanner.find("é", 100)),
        format!("é{COMPLETE_FOOTER}")
    );
}

#[test]
fn excluded_names_and_symlinks_request_skip_descendants() {
    let mut scanner = FixtureScanner::directory(
        "/fixture",
        &[
            "/fixture/.git",
            "/fixture/.git/config",
            "/fixture/node_modules",
            "/fixture/node_modules/pkg",
            "/fixture/.build",
            "/fixture/.build/output",
            "/fixture/link",
            "/fixture/link/target",
            "/fixture/broken-link",
            "/fixture/.github",
            "/fixture/file",
        ],
    );
    scanner.entries[6].is_symbolic_link = true;
    scanner.entries[8].is_symbolic_link = true;
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!(".github\nfile{COMPLETE_FOOTER}")
    );
    assert_eq!(scanner.visited.len(), 7);
    assert!(
        scanner.visited[..5]
            .iter()
            .all(|(_, control)| *control == ScanControl::SkipDescendants)
    );
    for name in [".git", "node_modules", ".build"] {
        let mut file = FixtureScanner::file(&format!("/fixture/{name}"));
        assert_eq!(
            text(&file.find("*", 100)),
            format!("{name}{COMPLETE_FOOTER}")
        );
        assert_eq!(file.scans, 0);
    }
}

#[test]
fn candidate_cap_applies_before_sort_and_excludes_skipped_events() {
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/.git"]);
    scanner.entries.extend(
        (0..CANDIDATE_LIMIT).map(|index| candidate(&format!("/fixture/z-{index:05}"))),
    );
    scanner.entries.push(candidate("/fixture/a-needle"));
    assert_eq!(text(&scanner.find("a-*", 100)), LIMITED_FOOTER);
    assert_eq!(scanner.visited.len(), CANDIDATE_LIMIT + 1);
    assert_eq!(scanner.visited[0].1, ScanControl::SkipDescendants);
    assert_eq!(scanner.visited.last().unwrap().1, ScanControl::Stop);
    assert_eq!(
        scanner.visited.last().unwrap().0,
        "/fixture/z-19999"
    );
}

#[test]
fn exactly_twenty_thousand_candidates_still_marks_the_scan_limited() {
    let mut scanner = FixtureScanner::directory("/fixture", &[]);
    scanner.entries = (0..CANDIDATE_LIMIT)
        .map(|index| candidate(&format!("/fixture/{index:05}")))
        .collect();
    assert_eq!(text(&scanner.find("absent", 100)), LIMITED_FOOTER);
    assert_eq!(scanner.visited.len(), CANDIDATE_LIMIT);
    assert_eq!(scanner.visited.last().unwrap().1, ScanControl::Stop);
}

#[test]
fn enumeration_error_can_end_with_partial_candidates_without_scan_footer() {
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/a", "/fixture/b"]);
    scanner.stop_before = Some(1);
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!("a{COMPLETE_FOOTER}")
    );
}

#[test]
fn cancellation_is_checked_before_scanning_and_before_skipped_events() {
    let token = CancellationToken::new();
    token.cancel();
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/a"]);
    assert!(matches!(
        execute(&mut scanner, "*", 100, &token),
        Err(ToolError::Cancelled)
    ));
    assert_eq!(scanner.scans, 0);

    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::directory(
        "/fixture",
        &["/fixture/a", "/fixture/.git", "/fixture/b"],
    );
    scanner.cancel_before = Some((1, token.clone()));
    assert!(matches!(
        execute(&mut scanner, "*", 100, &token),
        Err(ToolError::Cancelled)
    ));
    assert_eq!(scanner.visited.len(), 1);
}

#[test]
fn cancellation_after_scanning_is_observed_before_matching() {
    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::directory("/fixture", &["/fixture/a"]);
    scanner.cancel_after_scan = Some(token.clone());
    assert!(matches!(
        execute(&mut scanner, "*", 100, &token),
        Err(ToolError::Cancelled)
    ));
}

#[test]
fn relative_paths_use_swift_graphemes_and_preserve_root_slash_quirk() {
    let root = candidate("/👩‍🚀/e\u{301}");
    assert_eq!(
        relative_path(&candidate("/👩‍🚀/e\u{301}/nested/file"), &root),
        "nested/file"
    );
    assert_eq!(
        relative_path(&candidate("/👩‍🚀/é/nested/file"), &root),
        "nested/file"
    );
    assert_eq!(relative_path(&root, &root), "e\u{301}");
    assert_eq!(
        relative_path(&candidate("/outside/file"), &root),
        "file"
    );
    let mut scanner = FixtureScanner::directory("/", &["/alpha", "/👩‍🚀file", "/é"]);
    assert_eq!(
        text(&scanner.find("alpha", 100)),
        format!("lpha{COMPLETE_FOOTER}")
    );
    assert_eq!(relative_path(&candidate("/👩‍🚀file"), &candidate("/")), "file");
    assert_eq!(relative_path(&candidate("/é"), &candidate("/")), "");
}

#[test]
fn within_prefix_compares_whole_graphemes_with_canonical_equivalence() {
    assert!(swift_has_prefix("/é/file", "/e\u{301}/"));
    assert!(!swift_has_prefix("/fixture/\u{301}name", "/fixture/"));
    assert!(!swift_has_prefix("/fixture-other/file", "/fixture/"));
    assert_eq!(
        relative_path(
            &candidate("/fixture/\u{301}directory/leaf"),
            &candidate("/fixture")
        ),
        "leaf"
    );
}

#[test]
fn byte_preview_is_lossy_and_trims_actual_replacement_characters() {
    assert_eq!(preview("\u{fffd}a\u{fffd}b\u{fffd}", 100), "a\u{fffd}b");
    assert_eq!(preview("aé", 2), "a");
    assert_eq!(preview("\u{fffd}", 2), "");
    let mut scanner = FixtureScanner::file("/fixture/\u{fffd}a\u{fffd}");
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!("a{COMPLETE_FOOTER}")
    );
    let name = format!("{}é", "a".repeat(OUTPUT_BYTES - 1));
    let mut scanner = FixtureScanner::file(&format!("/fixture/{name}"));
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!("{}{LIMITED_FOOTER}", "a".repeat(OUTPUT_BYTES - 1))
    );
    let name = "a".repeat(OUTPUT_BYTES);
    let mut scanner = FixtureScanner::file(&format!("/fixture/{name}"));
    assert_eq!(
        text(&scanner.find("*", 100)),
        format!("{name}{COMPLETE_FOOTER}")
    );
}
