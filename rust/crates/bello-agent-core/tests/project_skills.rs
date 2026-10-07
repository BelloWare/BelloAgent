use bello_agent_core::{
    Error, instructions,
    project_resources::{CATALOG_PAGE_SIZE, ProjectResourceSource, ResourceScope},
    skills::{self, DependencySnapshot, SkillIntent, SkillPolicy},
};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tokio_util::sync::CancellationToken;

// The executor can have its own /tmp/.git or /workspace/.git markers. Each
// integration fixture has an explicit local repository boundary; never remove
// or alter those environment markers. The actual outside-repository algorithm
// is covered by instructions::tests using repository_chain_by without I/O.
fn isolated_project() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    fs::write(temp.path().join(".git"), "disposable fixture boundary").unwrap();
    temp
}
fn put(path: &Path, text: impl AsRef<[u8]>) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}
fn skill(name: &str, body: &str) -> String {
    format!(
        "---\nname: {name}\ndescription: Review code\ndisable-model-invocation: true\n---\n{body}"
    )
}
fn source(roots: Vec<PathBuf>) -> ProjectResourceSource {
    ProjectResourceSource::new(
        ResourceScope {
            project_id: "project".into(),
            roots,
            chat_id: "chat".into(),
            controller_id: "controller".into(),
            connection_generation: 1,
            configuration_generation: 1,
            tool_mode: "read-only".into(),
            policy_revision: "project-picker-v1".into(),
            mcp_configuration_revision: "none".into(),
        },
        DependencySnapshot::new(vec!["ls".into()], vec![], "none").unwrap(),
    )
    .unwrap()
}
fn discover(root: &Path) -> bello_agent_core::project_resources::ProjectResourceSnapshot {
    source(vec![root.to_owned()])
        .discover(&CancellationToken::new())
        .unwrap()
}
#[test]
fn project_roots_and_ancestors_are_ordered_deduplicated_and_home_free() {
    let temp = isolated_project();
    let p = temp.path();
    put(&p.join("AGENTS.md"), "outside");
    put(
        &p.join(".agents/skills/outside/SKILL.md"),
        skill("outside", "outside"),
    );
    put(&p.join("repo/.git"), "fixture");
    put(&p.join("repo/AGENTS.md"), "ROOT");
    put(&p.join("repo/a/AGENTS.md"), "A");
    put(&p.join("repo/a/AGENTS.override.md"), "OVERRIDE");
    put(&p.join("repo/b/AGENTS.md"), "B");
    put(
        &p.join("repo/.agents/skills/shared/SKILL.md"),
        skill("shared", "Shared"),
    );
    put(&p.join("repo/a/.agents/skills/a/SKILL.md"), skill("a", "A"));
    put(&p.join("repo/b/.agents/skills/b/SKILL.md"), skill("b", "B"));
    let s = source(vec![p.join("repo/a"), p.join("repo/b"), p.join("repo/a")])
        .discover(&CancellationToken::new())
        .unwrap();
    assert_eq!(s.roots.len(), 2);
    assert_eq!(s.sources.len(), 3);
    assert_eq!(
        s.skills.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["a", "b", "shared"]
    );
    assert_eq!(
        s.sources
            .iter()
            .map(|s| s.text.as_deref().unwrap())
            .collect::<Vec<_>>(),
        ["ROOT", "OVERRIDE", "B"]
    );
    assert!(!s.prompt.contains("outside"));
    assert!(s.instructions.ends_with(skills::SELECTION_POLICY));
    let project =
        instructions::discover_project(&[p.join("repo/a")], 32768, &CancellationToken::new())
            .unwrap();
    assert!(project.codex_home.as_os_str().is_empty());
}
#[test]
fn selected_repository_root_excludes_parent_skills() {
    let temp = isolated_project();
    put(
        &temp.path().join(".agents/skills/parent/SKILL.md"),
        skill("parent", "Parent"),
    );
    let child = temp.path().join("child");
    fs::create_dir(&child).unwrap();
    put(&child.join(".git"), "nested fixture boundary");
    put(
        &child.join(".agents/skills/local/SKILL.md"),
        skill("local", "Local"),
    );
    let s = discover(&child);
    assert_eq!(s.skills.len(), 1);
    assert_eq!(s.skills[0].name, "local");
}
#[test]
fn sorted_duplicate_names_leaf_rule_plain_markdown_and_symlink_identity() {
    let temp = isolated_project();
    let p = temp.path();
    put(
        &p.join(".agents/skills/z/SKILL.md"),
        skill("duplicate", "Z"),
    );
    put(
        &p.join(".agents/skills/a/SKILL.md"),
        skill("duplicate", "A"),
    );
    put(
        &p.join(".agents/skills/a/nested/SKILL.md"),
        skill("hidden", "Must not descend into a skill"),
    );
    put(&p.join(".agents/skills/plain.md"), skill("plain", "Plain"));
    put(
        &p.join(".agents/skills/ignored.MD"),
        skill("ignored", "Wrong extension"),
    );
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(p.join(".agents/skills"), p.join(".agents/skills/loop"))
            .unwrap();
        std::os::unix::fs::symlink(p.join(".agents/skills/a"), p.join(".agents/skills/alias"))
            .unwrap();
    }
    let s = discover(p);
    assert!(!s.partial);
    assert_eq!(s.skills.len(), 3);
    assert_eq!(
        s.skills.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["duplicate", "duplicate", "plain"]
    );
    assert!(s.skills[0].path < s.skills[1].path);
    assert_ne!(s.skills[0].id, s.skills[1].id);
}
#[test]
fn exact_raw_metadata_hash_crlf_and_frozen_expansion() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    let full = "---\r\nname: review\r\ndescription: Review code\r\ndisable-model-invocation: true\r\n---\r\nOriginal body\r\n";
    let meta = "policy:\r\n  allow_implicit_invocation: false\r\n";
    put(&file, full);
    put(&file.parent().unwrap().join("agents/openai.yaml"), meta);
    let s = discover(temp.path());
    let d = &s.skills[0];
    assert_eq!(d.policy, SkillPolicy::ExplicitOnly);
    assert_eq!(
        d.content_hash,
        "512315962f0dfb7d6e64d48d6a02a19a0532f6d9942eb8543344bf57e2852f5f"
    );
    assert_eq!(
        d.metadata_hash,
        "dd15bcbd25371750ce79268238d08c2ab1d4615047c40d93a8f1b0748fb5743d"
    );
    let frozen = s
        .freeze(&[d.selection("quoted \"args\"\n/run is literal".into())])
        .unwrap();
    assert_eq!(frozen[0].body, "Original body\n");
    assert_eq!(
        frozen[0].body_hash,
        "94dc13df6a6469537f4a5a9d5a56083202a0dc410ee84444d9193aa78ef73336"
    );
    let expanded = skills::user_message_text("raw", &frozen, "turn-1").unwrap();
    assert!(
        expanded.starts_with("Explicit user skill selection \"review\", turn turn-1, source \"")
    );
    assert!(expanded.ends_with(&format!("Current explicit selection IDs: {}\n\nraw", d.id)));
    assert!(expanded.contains("Skill arguments: quoted \"args\"\n/run is literal"));
}
#[test]
fn body_change_rejects_fresh_selection_but_keeps_accepted_body_on_delivery() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    put(&file, skill("review", "OLD BODY"));
    let source = source(vec![temp.path().into()]);
    let initial = source.discover(&CancellationToken::new()).unwrap();
    let selected = initial.skills[0].selection("arguments".into());
    let frozen = source
        .freeze(std::slice::from_ref(&selected), &CancellationToken::new())
        .unwrap();
    put(&file, skill("review", "NEW BODY"));
    assert!(
        source
            .freeze(&[selected], &CancellationToken::new())
            .is_err()
    );
    let current = source
        .validate_delivery(&frozen, &CancellationToken::new())
        .unwrap();
    assert_eq!(current.skills[0].metadata_hash, frozen[0].metadata_hash);
    assert_ne!(current.skills[0].content_hash, frozen[0].content_hash);
    assert_eq!(frozen[0].body, "OLD BODY");
    put(
        &file,
        skill("review", "NEW BODY").replace("description: Review code", "description: Changed"),
    );
    assert!(
        source
            .validate_delivery(&frozen, &CancellationToken::new())
            .is_err()
    );
    fs::remove_file(&file).unwrap();
    assert!(
        source
            .validate_delivery(&frozen, &CancellationToken::new())
            .is_err()
    );
    assert!(
        skills::user_message_text("", &frozen, "retry")
            .unwrap()
            .contains("OLD BODY")
    );
}
#[test]
fn metadata_policy_revocation_and_dependency_presence_fail_closed() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    put(&file, skill("review", "Body"));
    let metadata = file.parent().unwrap().join("agents/openai.yaml");
    put(
        &metadata,
        "dependencies:\n  tools:\n    - type: builtin\n      value: ls\n    - type: mcp\n      value: docs\n",
    );
    let s = discover(temp.path());
    let d = &s.skills[0];
    assert_eq!(d.policy, SkillPolicy::ExplicitOnly);
    assert_eq!(d.missing_dependencies(&s.dependencies).len(), 1);
    assert!(!d.selectable(&s.dependencies));
    assert!(s.freeze(&[d.selection(String::new())]).is_err());
    let mut enabled = source(vec![temp.path().into()]);
    enabled.dependencies =
        DependencySnapshot::new(vec!["ls".into()], vec!["docs".into()], "enabled").unwrap();
    let current = enabled.discover(&CancellationToken::new()).unwrap();
    let frozen = current
        .freeze(&[current.skills[0].selection(String::new())])
        .unwrap();
    assert!(
        source(vec![temp.path().into()])
            .validate_delivery(&frozen, &CancellationToken::new())
            .is_err()
    );
    put(
        &metadata,
        "policy:\n  allow_implicit_invocation: false\n  unknown_mandatory: true\n",
    );
    let revoked = enabled.discover(&CancellationToken::new()).unwrap();
    assert_eq!(revoked.skills[0].policy, SkillPolicy::NeedsAttention);
    assert!(revoked.validate_delivery(&frozen).is_err());
}
#[test]
fn malformed_frontmatter_and_metadata_are_inspectable_but_unselectable() {
    let cases = [
        "name: review\nname: duplicate\ndescription: valid",
        "name: review\ndescription: valid\ndisable-model-invocation: 'true'",
        "name: review\ndescription:\n  nested: wrong",
        "name: review\ndescription: &alias",
        "name: review\tdescription: tabs",
    ];
    for front in cases {
        let temp = isolated_project();
        put(
            &temp.path().join(".agents/skills/review/SKILL.md"),
            format!("---\n{front}\n---\nBody"),
        );
        let s = discover(temp.path());
        assert_eq!(s.skills.len(), 1);
        assert_eq!(s.skills[0].policy, SkillPolicy::NeedsAttention);
        assert!(!s.skills[0].reasons.is_empty());
        assert!(s.freeze(&[s.skills[0].selection(String::new())]).is_err());
    }
    for metadata in [
        "policy: false",
        "policy:\n  allow_implicit_invocation: 'false'",
        "dependencies: []",
        "dependencies:\n  tools: wrong",
        "dependencies:\n  tools:\n    - type: 1\n      value: ls",
        "policy: {\"allow_implicit_invocation\":true,\"allow_implicit_invocation\":false}",
    ] {
        let temp = isolated_project();
        let base = temp.path().join(".agents/skills/review");
        put(&base.join("SKILL.md"), skill("review", "Body"));
        put(&base.join("agents/openai.yaml"), metadata);
        assert_eq!(
            discover(temp.path()).skills[0].policy,
            SkillPolicy::NeedsAttention
        );
    }
}
#[test]
fn swift_grapheme_description_count_instead_of_byte_or_scalar_count() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    let grapheme = "👩🏽‍💻";
    let description = grapheme.repeat(1024);
    put(
        &file,
        format!("---\nname: review\ndescription: '{description}'\n---\nBody"),
    );
    let s = discover(temp.path());
    assert_eq!(s.skills[0].policy, SkillPolicy::ImplicitAllowed);
    s.skills[0].chip(String::new()).validate().unwrap();
    put(
        &file,
        format!("---\nname: review\ndescription: '{description}{grapheme}'\n---\nBody"),
    );
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::NeedsAttention
    );
}
#[test]
fn empty_freeze_does_not_scan_missing_roots_or_cancelled_work() {
    let temp = isolated_project();
    let root = temp.path().join("does-not-exist");
    let s = source(vec![root]);
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(s.freeze(&[], &cancel).unwrap().is_empty());
    assert!(matches!(s.discover(&cancel), Err(Error::Cancelled)));
}
#[test]
fn full_file_aggregate_and_selection_argument_bounds() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    let header = skill("review", "");
    let full = header.clone() + &"x".repeat(skills::MAX_SKILL_FILE_BYTES - header.len());
    put(&file, &full);
    let s = discover(temp.path());
    assert!(!s.partial);
    let mut selected = s.skills[0].selection("x".repeat(skills::MAX_SKILL_ARGUMENT_BYTES));
    s.freeze(&[selected.clone()]).unwrap();
    selected.arguments.push('x');
    assert!(s.freeze(&[selected]).is_err());
    put(&file, full + "x");
    let partial = discover(temp.path());
    assert!(partial.partial);
    assert!(partial.skills.is_empty());
    for n in 0..9 {
        let header = skill(&format!("s{n}"), "");
        put(
            &temp.path().join(format!(".agents/skills/{n:02}/SKILL.md")),
            header.clone() + &"x".repeat(skills::MAX_SKILL_FILE_BYTES - header.len()),
        );
    }
    fs::remove_file(file).unwrap();
    let aggregate = discover(temp.path());
    assert!(aggregate.partial);
    assert_eq!(aggregate.skills.len(), 8);
    let selections = aggregate
        .skills
        .iter()
        .map(|s| s.selection(String::new()))
        .collect::<Vec<_>>();
    assert_eq!(aggregate.freeze(&selections).unwrap().len(), 8);
    let mut duplicate = selections.clone();
    duplicate.push(selections[0].clone());
    assert!(aggregate.freeze(&duplicate).is_err());
}
#[test]
fn catalog_pages_are_revision_bound_and_partial_is_not_proof_of_removal() {
    let temp = isolated_project();
    for n in 0..34 {
        put(
            &temp.path().join(format!(".agents/skills/{n:02}/SKILL.md")),
            skill(&format!("s{n:02}"), "body"),
        );
    }
    let s = discover(temp.path());
    let page = s.page(0, &s.revision).unwrap();
    assert_eq!(page.skills.len(), CATALOG_PAGE_SIZE);
    assert_eq!(page.next, Some(32));
    assert_eq!(s.page(32, &s.revision).unwrap().skills.len(), 2);
    assert!(s.page(1, &s.revision).is_err());
    assert!(s.page(0, "stale").is_err());
    assert!(s.page(64, &s.revision).is_err());
    put(
        &temp.path().join(".agents/skills/zz-invalid/SKILL.md"),
        [0xff],
    );
    let partial = discover(temp.path());
    assert!(partial.partial);
    assert_eq!(partial.skills.len(), 34);
    assert_eq!(s.revision, partial.revision);
    assert!(partial.skills[0].selectable(&partial.dependencies));
}
#[test]
fn depth_and_count_boundaries_are_deterministic() {
    let temp = isolated_project();
    let base = temp.path().join(".agents/skills");
    let mut path = base.clone();
    for _ in 0..12 {
        path = path.join("nested");
    }
    put(&path.join("SKILL.md"), skill("at_limit", "Body"));
    let s = discover(temp.path());
    assert_eq!(s.skills.len(), 1);
    assert!(!s.partial);
    fs::remove_file(path.join("SKILL.md")).unwrap();
    put(&path.join("nested/SKILL.md"), skill("too_deep", "Body"));
    let s = discover(temp.path());
    assert!(s.partial);
    assert!(s.skills.is_empty());
    fs::remove_dir_all(base).unwrap();
    for n in 0..513 {
        put(
            &temp.path().join(format!(".agents/skills/{n:03}/SKILL.md")),
            skill(&format!("s{n:03}"), "body"),
        );
    }
    let s = discover(temp.path());
    assert_eq!(s.skills.len(), 512);
    assert!(s.partial);
}
#[cfg(unix)]
#[test]
fn nonregular_sources_are_refused_without_blocking() {
    let temp = isolated_project();
    let file = temp.path().join(".agents/skills/review/SKILL.md");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let status = std::process::Command::new("mkfifo")
        .arg(&file)
        .status()
        .unwrap();
    assert!(status.success());
    let s = discover(temp.path());
    assert!(s.partial);
    assert!(s.skills.is_empty());
}
#[test]
fn recovery_keeps_conflicting_variants_and_debug_is_redacted() {
    let temp = isolated_project();
    put(
        &temp.path().join(".agents/skills/review/SKILL.md"),
        skill("review", "SECRET BODY"),
    );
    let s = discover(temp.path());
    let captured = s.skills[0].chip("SECRET ARGS".into());
    let newer = s.skills[0].chip("NEW ARGS".into());
    let recovered = skills::restore_chips(
        std::slice::from_ref(&captured),
        &[captured.clone(), newer.clone()],
    )
    .unwrap();
    assert_eq!(recovered, [captured, newer]);
    skills::validate_chips(&recovered, 16).unwrap();
    assert!(
        skills::validate_selections(
            &recovered
                .iter()
                .map(|s| s.selection.clone())
                .collect::<Vec<_>>()
        )
        .is_err()
    );
    let frozen = s
        .freeze(&[s.skills[0].selection("SECRET ARGS".into())])
        .unwrap();
    let output = format!(
        "{s:?} {:?} {:?} {:?}",
        s.scope,
        frozen,
        frozen[0].recorded()
    );
    for secret in ["SECRET BODY", "SECRET ARGS", temp.path().to_str().unwrap()] {
        assert!(!output.contains(secret));
    }
    let mut corrupt = frozen[0].clone();
    corrupt.body.push('x');
    assert!(corrupt.validate().is_err());
    let mut selection = s.skills[0].selection(String::new());
    selection.intent = SkillIntent::LeadingCommand;
    assert_eq!(
        s.freeze(&[selection]).unwrap()[0].selection().intent,
        SkillIntent::Picker
    );
}
#[test]
fn metadata_bytes_and_dependency_count_boundaries() {
    let temp = isolated_project();
    let base = temp.path().join(".agents/skills/review");
    let file = base.join("SKILL.md");
    let front = "name: review\ndescription: Review code\nunused: ";
    let maximum = format!("{}{}", front, "x".repeat(65_536 - front.len()));
    put(&file, format!("---\n{maximum}\n---\nBody"));
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::ImplicitAllowed
    );
    put(&file, format!("---\n{maximum}x\n---\nBody"));
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::NeedsAttention
    );
    put(&file, skill("review", "Body"));
    let metadata = base.join("agents/openai.yaml");
    let prefix = "policy:\n  allow_implicit_invocation: false\n# ";
    let maximum = format!("{prefix}{}", "x".repeat(65_536 - prefix.len()));
    put(&metadata, &maximum);
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::ExplicitOnly
    );
    put(&metadata, maximum + "x");
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::NeedsAttention
    );
    let mut deps = "dependencies:\n  tools:\n".to_owned();
    for _ in 0..32 {
        deps.push_str("    - type: tool\n      value: ls\n");
    }
    put(&metadata, &deps);
    let s = discover(temp.path());
    assert_eq!(s.skills[0].dependencies.len(), 32);
    assert!(s.skills[0].selectable(&s.dependencies));
    deps.push_str("    - type: tool\n      value: ls\n");
    put(&metadata, &deps);
    assert_eq!(
        discover(temp.path()).skills[0].policy,
        SkillPolicy::NeedsAttention
    );
}
#[test]
fn visited_node_bound_counts_skill_root_and_empty_directories() {
    let temp = isolated_project();
    let root = temp.path().join(".agents/skills");
    fs::create_dir_all(&root).unwrap();
    for n in 0..4999 {
        fs::create_dir(root.join(format!("{n:04}"))).unwrap();
    }
    assert!(!discover(temp.path()).partial);
    fs::create_dir(root.join("4999")).unwrap();
    assert!(discover(temp.path()).partial);
}
#[test]
fn source_preview_is_bounded_utf8_and_never_catalog_body_metadata() {
    let temp = isolated_project();
    let body = "🙂".repeat(4097);
    put(
        &temp.path().join(".agents/skills/review/SKILL.md"),
        skill("review", &body),
    );
    let s = discover(temp.path());
    let id = &s.skills[0].id;
    assert_eq!(s.skills[0].source_characters, 8194);
    let first = s.source_preview(id, 0).unwrap();
    assert_eq!(first.text.len(), 8192);
    assert_eq!(first.next, Some(8192));
    let second = s.source_preview(id, first.next.unwrap()).unwrap();
    assert_eq!(second.text.len(), 8192);
    assert_eq!(
        s.source_preview(id, second.next.unwrap()).unwrap().text,
        "🙂"
    );
    assert!(s.source_preview(id, 1).is_err());
    assert!(
        !serde_json::to_string(&s.skills[0])
            .unwrap()
            .contains("body")
    );
    assert!(!format!("{first:?}").contains('🙂'));
}
#[test]
fn content_revision_is_separate_from_scope_and_dependency_state() {
    let temp = isolated_project();
    put(
        &temp.path().join(".agents/skills/review/SKILL.md"),
        skill("review", "Body"),
    );
    let original = source(vec![temp.path().into()]);
    let first = original.discover(&CancellationToken::new()).unwrap();
    let mut changed = original.clone();
    changed.scope.chat_id = "another-chat".into();
    changed.scope.configuration_generation += 1;
    changed.dependencies =
        DependencySnapshot::new(vec!["ls".into(), "read".into()], vec![], "changed").unwrap();
    let next = changed.discover(&CancellationToken::new()).unwrap();
    assert_ne!(first.scope, next.scope);
    assert_ne!(first.dependencies.revision, next.dependencies.revision);
    assert_eq!(first.revision, next.revision);
}
