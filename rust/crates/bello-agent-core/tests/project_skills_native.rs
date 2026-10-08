//! Apple-only oracle against actual checked-in Swift behavior. All files are
//! generated disposable fixtures, and both implementations read the same paths.
#![cfg(target_os = "macos")]
use bello_agent_core::{
    Message,
    compaction::protected_input_ids,
    instructions::{self, InstructionOptions, InstructionSource},
    project_resources::{ProjectResourceSource, ResourceScope},
    skills::{self, DependencySnapshot},
    tool_content::ContentBlock,
    user_content::UserContent,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

const ARGUMENTS: &str = "literal \"args\"\n/never-a-command";
const RAW: &str = "Raw /review stays literal";
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}
fn skill(name: &str, description: &str, body: &str) -> String {
    format!(
        "---\nname: {name}\ndescription: '{description}'\ndisable-model-invocation: true\n---\n{body}"
    )
}
fn source(root: &Path) -> ProjectResourceSource {
    ProjectResourceSource::new(
        ResourceScope {
            project_id: "fixture".into(),
            roots: vec![fs::canonicalize(root).unwrap()],
            chat_id: "chat".into(),
            controller_id: "controller".into(),
            connection_generation: 1,
            configuration_generation: 1,
            tool_mode: "read-only".into(),
            policy_revision: "project-picker-v1".into(),
            mcp_configuration_revision: "fixture".into(),
        },
        DependencySnapshot::new(vec!["ls".into()], vec!["docs".into()], "fixture").unwrap(),
    )
    .unwrap()
}
fn swift_source() -> String {
    let sources = [
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/JSON.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/JSONParser.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/ProviderFailure.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Support.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/TextPreviews.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/MetadataYAML.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Resources.swift"),
    ];
    let mut result = sources.join("\n");
    let context =
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/SessionContext.swift");
    let marker = "    static func requestInstructions(_ prompt: String) -> String {";
    let offset = context
        .find(marker)
        .expect("Swift SessionContext oracle marker moved; review source");
    result.push_str("\nenum AgentSession {\n");
    result.push_str(&context[offset..]);
    // Only this field carrier is fixture-defined. The complete groups/source
    // algorithms, ReplayGroup and error factory below are checked-in source.
    result.push_str(include_str!("fixtures/project_compaction_rows.swift"));
    let planner =
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/CompactionPlanner.swift");
    result.push_str(source_section(
        planner,
        "struct ReplayGroup: Sendable {",
        "/// Pi's CompactionPreparation",
    ));
    result.push_str(source_section(
        planner,
        "enum CompactionPlanner {",
        "    /// findCutPoint:",
    ));
    result.push_str(
        planner
            .lines()
            .find(|line| line.trim_start().starts_with("static func damaged("))
            .expect("Swift compaction damaged marker moved; review source"),
    );
    result.push_str("\n}\n");
    result.push_str(include_str!("fixtures/project_skills_oracle.swift"));
    result
}
fn source_section<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
    let start = source
        .find(start)
        .expect("Swift compaction start marker moved; review source");
    let tail = &source[start..];
    &tail[..tail
        .find(end)
        .expect("Swift compaction end marker moved; review source")]
}
fn bounded(command: &mut Command, directory: &Path) -> Vec<u8> {
    use std::os::unix::process::CommandExt;
    let out = directory.join("stdout");
    let err = directory.join("stderr");
    command
        .stdin(Stdio::null())
        .stdout(fs::File::create(&out).unwrap())
        .stderr(fs::File::create(&err).unwrap())
        .process_group(0);
    let mut child = command.spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(
                status.success(),
                "Native project skills oracle failed: {}",
                fs::read_to_string(&err).unwrap()
            );
            return fs::read(out).unwrap();
        }
        if Instant::now() >= deadline {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.kill();
            let _ = child.wait();
            panic!("Native project skills oracle timed out");
        }
        thread::sleep(Duration::from_millis(20));
    }
}
fn body(
    snapshot: &bello_agent_core::project_resources::ProjectResourceSnapshot,
    id: &str,
) -> String {
    let mut result = String::new();
    let mut offset = 0;
    loop {
        let page = snapshot.source_preview(id, offset).unwrap();
        result.push_str(&page.text);
        if let Some(next) = page.next {
            offset = next;
        } else {
            return result;
        }
    }
}
fn rust_result(item: &Value) -> Value {
    let mut source = source(Path::new(item["cwd"].as_str().unwrap()));
    if let Some(roots) = item["roots"].as_array() {
        source.scope.roots.extend(
            roots
                .iter()
                .map(|root| fs::canonicalize(root.as_str().unwrap()).unwrap()),
        );
    }
    if let Some(limit) = item["instructionLimit"].as_u64() {
        source = source.with_instruction_limit(limit as usize).unwrap();
    }
    let snapshot = source.discover(&CancellationToken::new()).unwrap();
    // The prompt/source spelling must not replace canonical authority roots.
    for root in &snapshot.roots {
        assert_eq!(root, &fs::canonicalize(root).unwrap());
    }
    let catalog=snapshot.skills.iter().map(|d|json!({"id":d.id,"name":d.name,"path":d.path,"baseDir":d.base_dir,"sourceRoot":d.source_root,"scope":d.scope,"description":d.description,"contentHash":d.content_hash,"metadataHash":d.metadata_hash,"policy":d.policy,"reasons":d.reasons,"dependencies":d.dependencies,"body":body(&snapshot,&d.id)})).collect::<Vec<_>>();
    let selections = snapshot
        .skills
        .iter()
        .map(|d| d.selection(ARGUMENTS.into()))
        .collect::<Vec<_>>();
    let mut result = json!({"case":item["case"],"skills":catalog,"prompt":snapshot.prompt,"instructions":snapshot.instructions,"sources":source_metadata(&snapshot.sources),"diagnostics":snapshot.diagnostics,"includedBytes":snapshot.included_bytes,"unselected":skills::user_message_text("/review",&[],"next-turn").unwrap()});
    match source.freeze(&selections, &CancellationToken::new()) {
        Ok(frozen) => {
            result["freezeAccepted"] = json!(true);
            result["expanded"] =
                json!(skills::user_message_text(RAW, &frozen, "fixture-turn").unwrap());
            result["recorded"]=json!(frozen.iter().map(|s|json!({"id":s.id,"contentHash":s.content_hash,"metadataHash":s.metadata_hash,"arguments":s.arguments,"intent":"picker","name":s.name,"path":s.path,"description":s.description,"scope":s.scope,"policy":s.policy})).collect::<Vec<_>>());
            if let Some(replacement) = item["bodyReplacement"].as_str() {
                let path = Path::new(&snapshot.skills[0].path);
                let original = fs::read(path).unwrap();
                fs::write(path, replacement).unwrap();
                result["staleFreshAccepted"] = json!(
                    source
                        .freeze(&selections, &CancellationToken::new())
                        .is_ok()
                );
                result["bodyDeliveryAccepted"] = json!(
                    source
                        .validate_delivery(&frozen, &CancellationToken::new())
                        .is_ok()
                );
                result["retainedExpansion"] =
                    json!(skills::user_message_text(RAW, &frozen, "fixture-turn").unwrap());
                if let Some(revoked) = item["metadataReplacement"].as_str() {
                    fs::write(path, revoked).unwrap();
                    result["metadataDeliveryAccepted"] = json!(
                        source
                            .validate_delivery(&frozen, &CancellationToken::new())
                            .is_ok()
                    );
                }
                fs::write(path, original).unwrap();
            }
        }
        Err(_) => result["freezeAccepted"] = json!(false),
    }
    result
}
fn compaction_cases() -> Vec<Value> {
    let selected =
        |id: &str, root: &str| json!({"id":id,"role":"user","taskRoot":root,"selected":true});
    let unselected = |id: &str, root: &str| json!({"id":id,"role":"user","taskRoot":root});
    let answer = |id: &str| json!({"id":id,"role":"assistant"});
    vec![
        json!({"case":"answered-latest-selected","taskRoot":"u1","messages":[selected("u1","u1"),answer("a1")]}),
        json!({"case":"selected-current-task-with-later-unselected-steering","taskRoot":"u1","messages":[selected("u1","u1"),answer("a1"),selected("u2","u1"),answer("a2"),unselected("u3","u1"),answer("a3")]}),
        json!({"case":"new-answered-unselected-task-releases-prior-selections","taskRoot":"u2","messages":[selected("u1","u1"),answer("a1"),unselected("u2","u2"),answer("a2")]}),
        json!({"case":"new-unanswered-unselected-task-protects-only-itself","taskRoot":"u2","messages":[selected("u1","u1"),answer("a1"),unselected("u2","u2")]}),
        json!({"case":"legacy-unanswered","messages":[{"id":"legacy-user","role":"user"}]}),
        json!({"case":"legacy-answered","messages":[{"id":"legacy-user","role":"user"},answer("legacy-answer")]}),
    ]
}
fn rust_compaction_result(item: &Value, frozen: &[skills::FrozenSkill]) -> Value {
    let messages = item["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let id = row["id"].as_str().unwrap();
            let selected = row["selected"].as_bool() == Some(true);
            let text = "fixture row";
            let user_content = selected.then(|| {
                let content = UserContent {
                    skills: frozen.iter().map(|skill| skill.recorded()).collect(),
                    attachments: Vec::new(),
                    blocks: vec![ContentBlock::Text {
                        text: skills::user_message_text(text, frozen, id).unwrap(),
                    }],
                };
                content.validate().unwrap();
                std::sync::Arc::new(content)
            });
            Message {
                task_root_id: row["taskRoot"].as_str().map(str::to_owned),
                user_content,
                id: id.into(),
                role: row["role"].as_str().unwrap().into(),
                text: text.into(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "complete".into(),
                usage: Value::Null,
                model: None,
                tool_record: None,
                compaction: None,
            }
        })
        .collect::<Vec<_>>();
    json!({"case":item["case"], "protectedIDs":protected_input_ids(&messages).unwrap()})
}
#[test]
fn project_skill_catalog_hashes_policy_freeze_and_expansion_match_checked_in_swift() {
    // Exact source results, including /var and /private/var presentation paths,
    // instruction headers, source metadata, diagnostics and retained skill bytes.
    // Nothing is removed or path-normalized before comparison.
    let fixtures =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/project-skills-native-fixtures");
    fs::create_dir_all(&fixtures).unwrap();
    let fixture = tempfile::tempdir_in(fixtures).unwrap();
    let fixture_root = fs::canonicalize(fixture.path()).unwrap();
    let home = fixture_root.join("empty-home");
    fs::create_dir(&home).unwrap();
    let vectors: Vec<(&str, String, Option<String>)> = vec![
  ("lf",skill("review","Review files","Original body"),None),
  ("crlf",skill("review","Review files","Original body\n").replace('\n',"\r\n"),Some("policy:\r\n  allow_implicit_invocation: false\r\n".into())),
  ("block","---\nname: review\ndescription: >-\n  Review the code\n  carefully\n---\nBody".into(),None),
  ("quoted","---\nname: review\ndescription: \"Quote \\\"me\\\" # literal\" # comment\n---\nBody".into(),None),
  ("grapheme",skill("review",&"👩🏽‍💻".repeat(1024),"Body"),None),
  ("grapheme-over",skill("review",&"👩🏽‍💻".repeat(1025),"Body"),None),
  ("duplicates","---\nname: review\nname: again\ndescription: Duplicate\n---\nBody".into(),None),
  ("unclosed","---\nname: review\ndescription: Unclosed\nBody".into(),None),
  ("bad-policy",skill("review","Review","Body"),Some("policy:\n  allow_implicit_invocation: false\n  mandatory_unknown: true\n".into())),
  ("bad-type",skill("review","Review","Body"),Some("policy:\n  allow_implicit_invocation: 'false'\n".into())),
  ("dependencies",skill("review","Review","Body"),Some("dependencies:\n  tools:\n    - type: builtin\n      value: ls\n    - type: mcp\n      value: docs\n".into())),
  ("missing-dependency",skill("review","Review","Body"),Some("dependencies:\n  tools:\n    - type: tool\n      value: bash\n".into())),
  ("bad-dependencies",skill("review","Review","Body"),Some("dependencies:\n  tools: false\n".into())),
 ];
    let mut cases = Vec::new();
    for (name, full, metadata) in vectors {
        let cwd = fixture_root.join(name);
        put(&cwd.join(".git"), "disposable oracle repository boundary");
        let base = cwd.join(".agents/skills/review");
        put(&base.join("SKILL.md"), &full);
        if let Some(metadata) = metadata {
            put(&base.join("agents/openai.yaml"), &metadata);
        }
        let mut case = json!({"case":name,"cwd":cwd,"home":home});
        if name == "lf" {
            case["bodyReplacement"] = json!(skill("review", "Review files", "Changed body"));
            case["metadataReplacement"] =
                json!(skill("review", "Changed description", "Changed body"));
        }
        cases.push(case);
    }
    // Deterministic duplicate names, directory leaf behavior and plain .md support.
    let cwd = fixture_root.join("tree");
    put(&cwd.join(".git"), "disposable oracle repository boundary");
    put(
        &cwd.join(".agents/skills/z/SKILL.md"),
        &skill("same", "Second path", "Z"),
    );
    put(
        &cwd.join(".agents/skills/a/SKILL.md"),
        &skill("same", "First path", "A"),
    );
    put(
        &cwd.join(".agents/skills/a/nested/SKILL.md"),
        &skill("hidden", "Leaf child", "Must not appear"),
    );
    put(
        &cwd.join(".agents/skills/plain.md"),
        &skill("plain", "Plain file", "P"),
    );
    cases.push(json!({"case":"tree","cwd":cwd,"home":home}));
    add_symlink_cases(&mut cases, &fixture_root, &home);
    let build = tempfile::tempdir().unwrap();
    let src = build.path().join("oracle.swift");
    let executable = build.path().join("project-skills-oracle");
    let input = build.path().join("fixtures.json");
    fs::write(&src, swift_source()).unwrap();
    let compaction = compaction_cases();
    let alias_fixture = tempfile::tempdir_in("/var/tmp").unwrap();
    let alias_cwd = fs::canonicalize(alias_fixture.path()).unwrap();
    let alias_spelling = Path::new("/").join(alias_cwd.strip_prefix("/private").unwrap());
    assert_ne!(alias_cwd, alias_spelling);
    assert_eq!(fs::canonicalize(&alias_spelling).unwrap(), alias_cwd);
    put(
        &alias_cwd.join(".git"),
        "disposable alias repository boundary",
    );
    put(
        &alias_cwd.join("AGENTS.md"),
        "Alias instructions keep literal /private/example and /var/example text.",
    );
    put(
        &alias_cwd.join(".agents/skills/review/SKILL.md"),
        &skill("review", "Alias parity", "Alias body"),
    );
    let alias_case = json!({"case":"darwin-alias","cwd":alias_cwd,"home":home});
    let mut other_alias = alias_case.clone();
    other_alias["cwd"] = json!(alias_spelling);
    let mut alias_cases = vec![alias_case.clone(), other_alias.clone()];
    add_symlink_cases(&mut alias_cases, &alias_cwd, &home);
    let primary = alias_cwd.join("multi-primary");
    let secondary = alias_cwd.join("multi-secondary");
    for root in [&primary, &secondary] {
        put(&root.join(".git"), "fixture boundary");
        put(
            &root.join("AGENTS.md"),
            "Root instructions /private/body stays literal. 🙂汉字🙂",
        );
        put(
            &root.join(".agents/skills/review/SKILL.md"),
            &skill("review", "Multiple roots", "Root body"),
        );
    }
    put(
        &secondary.join(".agents/skills/implicit/SKILL.md"),
        "---\nname: implicit\ndescription: 'Implicit /private/reference'\n---\nImplicit body",
    );
    alias_cases.push(json!({"case":"darwin-production-multiple-roots","cwd":primary,"roots":[secondary, darwin_alias(&primary), darwin_alias(&secondary)],"home":home,"instructionLimit":64}));
    add_nested_instruction_cases(&mut alias_cases, &alias_cwd, &home);
    let mut zero_alias = alias_case.clone();
    zero_alias["case"] = json!("darwin-zero-budget-full-prompt");
    zero_alias["instructionLimit"] = json!(0);
    alias_cases.push(zero_alias);
    let instruction_cases = instruction_cases(&alias_cwd, &home);
    let mut oracle_cases = cases.clone();
    oracle_cases.extend(alias_cases.iter().cloned());
    fs::write(
        &input,
        serde_json::to_vec(
            &json!({"cases":oracle_cases,"compaction":compaction,"instructions":instruction_cases}),
        )
        .unwrap(),
    )
    .unwrap();
    bounded(
        Command::new("/usr/bin/xcrun")
            .args([
                "swiftc",
                "-swift-version",
                "5",
                "-parse-as-library",
                "-module-cache-path",
            ])
            .arg(build.path().join("cache"))
            .arg(src)
            .arg("-o")
            .arg(&executable),
        build.path(),
    );
    let expected: Value =
        serde_json::from_slice(&bounded(Command::new(executable).arg(input), build.path()))
            .unwrap();
    for (index, item) in cases.iter().enumerate() {
        assert_eq!(
            rust_result(item),
            expected["skills"][index],
            "source oracle case {}",
            item["case"]
        );
    }
    for (offset, item) in alias_cases.iter().enumerate() {
        let actual = rust_result(item);
        assert_project_fixture_coverage(item, &actual);
        assert_eq!(
            actual,
            expected["skills"][cases.len() + offset],
            "strict Darwin resource/skill source oracle {}",
            item["case"]
        );
    }
    for (index, item) in instruction_cases.iter().enumerate() {
        let actual = rust_instruction_result(item);
        assert_instruction_fixture_coverage(item, &actual);
        assert_eq!(
            actual, expected["instructions"][index],
            "strict Darwin instruction source oracle {}",
            item["case"]
        );
    }
    let alias_rust = rust_result(&alias_case);
    assert_eq!(alias_rust, rust_result(&other_alias));
    let alias_swift = &expected["skills"][cases.len()];
    for field in ["id", "path", "baseDir", "contentHash", "metadataHash"] {
        assert_eq!(
            alias_swift["skills"][0][field],
            expected["skills"][cases.len() + 1]["skills"][0][field]
        );
    }
    for value in [&alias_rust, alias_swift] {
        let descriptor = &value["skills"][0];
        let path = descriptor["path"].as_str().unwrap();
        assert_eq!(
            fs::canonicalize(path).unwrap(),
            alias_cwd.join(".agents/skills/review/SKILL.md")
        );
        assert_eq!(descriptor["id"], format!("{:x}", Sha256::digest(path)));
        assert_eq!(value["freezeAccepted"], true);
        assert!(value["expanded"].as_str().unwrap().contains("Alias body"));
    }
    for field in ["contentHash", "metadataHash", "body", "policy"] {
        assert_eq!(
            alias_rust["skills"][0][field],
            alias_swift["skills"][0][field]
        );
    }
    assert_eq!(alias_rust["skills"], alias_swift["skills"]);
    assert_eq!(alias_rust["expanded"], alias_swift["expanded"]);
    assert_eq!(alias_rust["recorded"], alias_swift["recorded"]);
    let alias_source = source(&alias_cwd);
    let snapshot = alias_source.discover(&CancellationToken::new()).unwrap();
    let fresh = snapshot
        .freeze(&[snapshot.skills[0].selection(ARGUMENTS.into())])
        .unwrap();
    let mut legacy = fresh.clone();
    legacy[0].path = alias_cwd
        .join(".agents/skills/review/SKILL.md")
        .to_str()
        .unwrap()
        .into();
    legacy[0].id = format!("{:x}", Sha256::digest(&legacy[0].path));
    legacy[0].base_dir = alias_cwd
        .join(".agents/skills/review")
        .to_str()
        .unwrap()
        .into();
    assert_ne!(fresh[0].id, legacy[0].id);
    let legacy_bytes = serde_json::to_vec(&legacy).unwrap();
    let legacy_expanded = skills::user_message_text(RAW, &legacy, "fixture-turn").unwrap();
    assert!(
        alias_source
            .freeze(&[legacy[0].selection()], &CancellationToken::new())
            .is_err()
    );
    alias_source
        .validate_delivery(&legacy, &CancellationToken::new())
        .unwrap();
    assert_eq!(serde_json::to_vec(&legacy).unwrap(), legacy_bytes);
    assert_eq!(
        skills::user_message_text(RAW, &legacy, "fixture-turn").unwrap(),
        legacy_expanded
    );
    assert!(
        snapshot
            .validate_delivery(&[legacy[0].clone(), fresh[0].clone()])
            .is_err()
    );
    eprintln!(
        "Strict Darwin alias skill parity: {}",
        json!({"sameFilesystemTarget":true,"rustStableAcrossAliases":true,
            "rustPath":alias_rust["skills"][0]["path"],"swiftPath":alias_swift["skills"][0]["path"],
            "pathDerivedIDsEqual":alias_rust["skills"][0]["id"]==alias_swift["skills"][0]["id"],
            "expandedTextEqual":alias_rust["expanded"]==alias_swift["expanded"]})
    );
    let compaction_source = source(&fixture_root.join("lf"));
    let snapshot = compaction_source
        .discover(&CancellationToken::new())
        .unwrap();
    let frozen = snapshot
        .freeze(&[snapshot.skills[0].selection(ARGUMENTS.into())])
        .unwrap();
    for (index, item) in compaction.iter().enumerate() {
        assert_eq!(
            rust_compaction_result(item, &frozen),
            expected["compaction"][index],
            "compaction source oracle case {}",
            item["case"]
        );
    }
}

fn add_symlink_cases(cases: &mut Vec<Value>, parent: &Path, home: &Path) {
    use std::os::unix::fs::symlink;
    for kind in ["leaf-link", "directory-link", "skill-root-link"] {
        let cwd = parent.join(kind);
        let external = parent.join(format!("{kind}-external"));
        put(&cwd.join(".git"), "fixture boundary");
        if kind == "leaf-link" {
            put(
                &external.join("linked-instructions.txt"),
                "Linked instruction body: /private/literal must not be rewritten.",
            );
            symlink(
                external.join("linked-instructions.txt"),
                cwd.join("AGENTS.md"),
            )
            .unwrap();
        } else {
            put(
                &cwd.join("AGENTS.md"),
                "Ordinary instructions /private/literal.",
            );
            if kind == "directory-link" {
                put(
                    &cwd.join("AGENTS.override.md"),
                    "Override instructions /private/literal.",
                );
            }
        }
        put(
            &external.join("SKILL.md"),
            &skill("review", "Symlink semantics", "Linked body"),
        );
        put(
            &external.join("agents/openai.yaml"),
            "policy:\n  allow_implicit_invocation: true\n",
        );
        let root = cwd.join(".agents/skills");
        match kind {
            "leaf-link" => {
                let base = root.join("review");
                // Leaf file links retain the visited parent for metadata and
                // relative references; the canonical target's parent differs.
                put(
                    &base.join("agents/openai.yaml"),
                    "dependencies:\n  tools:\n    - type: builtin\n      value: ls\n",
                );
                symlink(external.join("SKILL.md"), base.join("SKILL.md")).unwrap();
            }
            "directory-link" => {
                fs::create_dir_all(&root).unwrap();
                symlink(&external, root.join("review")).unwrap();
            }
            _ => {
                fs::create_dir_all(root.parent().unwrap()).unwrap();
                symlink(&external, &root).unwrap();
            }
        }
        cases.push(json!({"case":kind,"cwd":cwd,"home":home}));
    }
}

// Marshal the typed Rust fields into Resources.swift's source JSON schema.
// This only names fields/omits fields Swift does not expose for approved extras;
// no path, instruction, diagnostic, hash or body is transformed.
fn source_metadata(sources: &[InstructionSource]) -> Vec<Value> {
    sources
        .iter()
        .map(|source| {
            assert_eq!(source.truncated, source.included_bytes < source.bytes);
            let mut value = json!({
                "path":source.path, "scope":source.scope, "hash":source.hash,
                "bytes":source.bytes, "includedBytes":source.included_bytes, "state":source.state
            });
            if source.scope == "approved additional" {
                assert!(source.reason.is_none() && source.text.is_none());
            } else {
                value["truncated"] = json!(source.truncated);
                value["reason"] = json!(source.reason.as_ref().unwrap());
                value["text"] = json!(source.text.as_ref().unwrap());
            }
            value
        })
        .collect()
}

fn darwin_alias(path: &Path) -> PathBuf {
    let canonical = fs::canonicalize(path).unwrap();
    let alias = Path::new("/").join(canonical.strip_prefix("/private").unwrap());
    assert_ne!(alias, canonical);
    assert_eq!(fs::canonicalize(&alias).unwrap(), canonical);
    alias
}

fn add_nested_instruction_cases(cases: &mut Vec<Value>, parent: &Path, home: &Path) {
    use std::os::unix::fs::symlink;
    let repository = parent.join("shared-instructions");
    let primary = repository.join("nested/primary");
    let secondary = repository.join("nested/secondary");
    put(
        &repository.join(".git"),
        "shared ancestor repository boundary",
    );
    put(&repository.join("AGENTS.md"), "Shared root /private/body.");
    put(
        &repository.join("nested/AGENTS.md"),
        "Shared ancestor /private/body.",
    );
    put(&primary.join("AGENTS.md"), "MUST NOT WIN OVER OVERRIDE");
    put(
        &primary.join("AGENTS.override.md"),
        "Primary override 🙂汉字.",
    );
    let target = parent.join("outside-repository/leaf-body.txt");
    put(&target, "Secondary leaf target /private/unchanged.");
    fs::create_dir_all(&secondary).unwrap();
    symlink(&target, secondary.join("AGENTS.md")).unwrap();
    put(
        &repository.join(".agents/skills/implicit/SKILL.md"),
        "---\nname: implicit\ndescription: 'Shared implicit /private/literal'\n---\nOne shared skill",
    );
    let roots = vec![
        secondary.clone(),
        darwin_alias(&primary),
        darwin_alias(&secondary),
    ];
    cases.push(json!({"case":"darwin-shared-ancestors-and-root-aliases","cwd":primary,"roots":roots,"home":home}));
    cases.push(json!({"case":"darwin-shared-ancestors-truncated","cwd":darwin_alias(&primary),"roots":roots,"home":home,"instructionLimit":60}));
}

fn rust_instruction_result(item: &Value) -> Value {
    let paths = |field: &str| {
        item[field]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| PathBuf::from(value.as_str().unwrap()))
            .collect::<Vec<_>>()
    };
    let options = InstructionOptions {
        roots: paths("roots"),
        codex_home: PathBuf::from(item["codexHome"].as_str().unwrap()),
        limit: item["limit"].as_u64().unwrap() as usize,
        fallback_names: item["fallbackNames"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect(),
        additional_paths: paths("additionalPaths"),
    };
    let snapshot = instructions::discover(&options).unwrap();
    let mut canonical_roots = Vec::new();
    for root in &options.roots {
        let root = fs::canonicalize(root).unwrap();
        if !canonical_roots.contains(&root) {
            canonical_roots.push(root);
        }
    }
    assert_eq!(snapshot.roots, canonical_roots);
    for (display, canonical) in snapshot.prompt_roots.iter().zip(&snapshot.roots) {
        assert_eq!(&fs::canonicalize(display).unwrap(), canonical);
    }
    assert_eq!(snapshot.prompt_roots.len(), snapshot.roots.len());
    json!({
        "case":item["case"], "instructions":snapshot.instructions,
        "promptRoots":snapshot.prompt_roots, "sources":source_metadata(&snapshot.sources),
        "diagnostics":snapshot.diagnostics, "includedBytes":snapshot.included_bytes,
        "limit":snapshot.limit
    })
}

fn instruction_cases(parent: &Path, home: &Path) -> Vec<Value> {
    use std::os::unix::fs::symlink;
    let base = parent.join("instruction-only");
    let project = base.join("project");
    let global = base.join("global-target");
    let global_alias = base.join("global-alias");
    let target = base.join("outside/global-body.txt");
    let extra = base.join("outside/additional-body.txt");
    let extra_alias = base.join("additional-alias.md");
    put(
        &project.join(".git"),
        "instruction-only repository boundary",
    );
    put(&project.join("AGENTS.override.md"), "  \n\t");
    put(
        &project.join("AGENTS.md"),
        "Project /private/literal remains unchanged.",
    );
    put(
        &target,
        "Global /private/literal remains unchanged. 🙂汉字🙂",
    );
    put(
        &extra,
        "Additional /private/literal remains unchanged. 🙂汉字🙂",
    );
    put(&base.join("empty.md"), "");
    put(&base.join("whitespace.md"), " \n\t");
    fs::create_dir_all(&global).unwrap();
    symlink(&target, global.join("AGENTS.md")).unwrap();
    symlink(&global, &global_alias).unwrap();
    symlink(&extra, &extra_alias).unwrap();
    let additional = vec![
        extra_alias.clone(),
        base.join("missing.md"),
        base.join("empty.md"),
        base.join("whitespace.md"),
    ];
    let mut cases = Vec::new();
    let before_additional =
        fs::read(&target).unwrap().len() + fs::read(project.join("AGENTS.md")).unwrap().len();
    for limit in [32768, 45, 0, before_additional + 5] {
        cases.push(json!({
            "case":format!("global-and-additional-leaf-symlinks-{limit}"),
            "roots":[project,darwin_alias(&project)], "codexHome":global_alias,
            "additionalPaths":additional, "fallbackNames":[], "limit":limit,"home":home
        }));
    }
    let global_override = base.join("global-override");
    put(
        &global_override.join("AGENTS.md"),
        "GLOBAL ORDINARY MUST NOT WIN",
    );
    symlink(&target, global_override.join("AGENTS.override.md")).unwrap();
    cases.push(json!({"case":"global-override-leaf-precedence","roots":[project],"codexHome":global_override,"additionalPaths":[],"fallbackNames":[],"limit":32768,"home":home}));
    let fallback_project = base.join("fallback-project");
    put(&fallback_project.join(".git"), "fallback fixture");
    put(
        &fallback_project.join("AGENTS.override.md"),
        "\u{200b}\u{0085}\u{2028}\u{3000}",
    );
    put(&fallback_project.join("AGENTS.md"), " \n\t");
    put(
        &fallback_project.join("FALLBACK.md"),
        "Fallback /private/body",
    );
    let fallback_global = base.join("fallback-global");
    put(
        &fallback_global.join("FALLBACK.md"),
        "GLOBAL FALLBACK MUST NOT LOAD",
    );
    cases.push(json!({"case":"empty-ordinary-and-global-fallback-exclusion","roots":[fallback_project],"codexHome":fallback_global,"additionalPaths":[],"fallbackNames":["FALLBACK.md"],"limit":32768,"home":home}));
    // Missing optional paths below an existing directory symlink must not change
    // the canonical access/dedup rules or manufacture a source/diagnostic.
    cases.push(json!({"case":"missing-optional-through-directory-link","roots":[project],"codexHome":global_alias.join("missing/codex"),"additionalPaths":[global_alias.join("missing/extra.md"),base.join("empty.md")],"fallbackNames":[],"limit":32768,"home":home}));
    let unicode_project = base.join("unicode-project");
    put(&unicode_project.join(".git"), "unicode fixture");
    put(
        &unicode_project.join("AGENTS.md"),
        "🙂汉字🙂 /private/literal",
    );
    for limit in [0, 1, 3, 4, 5, 7, 8, 10, 11, 14, 32768] {
        cases.push(json!({"case":format!("unicode-budget-{limit}"),"roots":[unicode_project],"codexHome":base.join("missing-codex"),"additionalPaths":[],"fallbackNames":[],"limit":limit,"home":home}));
    }
    cases
}

fn assert_project_fixture_coverage(item: &Value, result: &Value) {
    let sources = result["sources"].as_array().unwrap();
    let prompt = result["prompt"].as_str().unwrap();
    match item["case"].as_str().unwrap() {
        "leaf-link" => {
            assert_eq!(sources.len(), 1);
            assert!(
                sources[0]["path"]
                    .as_str()
                    .unwrap()
                    .ends_with("/linked-instructions.txt")
            );
            assert!(prompt.contains("/leaf-link/AGENTS.md:\nLinked instruction body"));
            assert!(!prompt.contains("/linked-instructions.txt:\n"));
            assert!(prompt.contains("/private/literal must not be rewritten."));
        }
        "directory-link" => {
            assert_eq!(sources.len(), 1);
            assert!(
                sources[0]["path"]
                    .as_str()
                    .unwrap()
                    .ends_with("/AGENTS.override.md")
            );
            assert!(prompt.contains("Override instructions /private/literal."));
            assert!(!prompt.contains("Ordinary instructions"));
        }
        "darwin-production-multiple-roots" => {
            assert_eq!(sources.len(), 2);
            assert!(prompt.contains("The workspace has 2 roots;"));
            assert!(prompt.contains("Implicit /private/reference"));
            assert!(!result["diagnostics"].as_array().unwrap().is_empty());
        }
        "darwin-shared-ancestors-and-root-aliases" | "darwin-shared-ancestors-truncated" => {
            assert_eq!(sources.len(), 4);
            assert!(prompt.contains("The workspace has 2 roots;"));
            assert_eq!(result["skills"].as_array().unwrap().len(), 1);
            assert!(prompt.contains("Shared implicit /private/literal"));
            assert!(!prompt.contains("MUST NOT WIN OVER OVERRIDE"));
            if item["instructionLimit"].is_null() {
                assert!(prompt.contains("/nested/secondary/AGENTS.md:\nSecondary leaf target"));
                assert!(!prompt.contains("/outside-repository/leaf-body.txt:\n"));
                assert!(prompt.contains("Secondary leaf target /private/unchanged."));
            } else {
                assert!(!result["diagnostics"].as_array().unwrap().is_empty());
            }
        }
        "darwin-zero-budget-full-prompt" => {
            assert_eq!(sources.len(), 1);
            assert_eq!(result["includedBytes"], 0);
            assert_eq!(result["diagnostics"].as_array().unwrap().len(), 1);
            assert!(!prompt.contains("Instructions from "));
            assert!(prompt.contains("You are a coding assistant in "));
        }
        _ => assert!(!sources.is_empty()),
    }
}

fn assert_instruction_fixture_coverage(item: &Value, result: &Value) {
    let sources = result["sources"].as_array().unwrap();
    let instructions = result["instructions"].as_str().unwrap();
    let diagnostics = result["diagnostics"].as_array().unwrap();
    let name = item["case"].as_str().unwrap();
    if name.starts_with("global-and-additional-leaf-symlinks-") {
        assert_eq!(sources.len(), 5);
        assert_eq!(result["promptRoots"].as_array().unwrap().len(), 1);
        assert_eq!(sources[0]["scope"], "global");
        assert!(
            sources[0]["path"]
                .as_str()
                .unwrap()
                .ends_with("/outside/global-body.txt")
        );
        assert_eq!(sources[2]["scope"], "approved additional");
        assert!(
            sources[2]["path"]
                .as_str()
                .unwrap()
                .ends_with("/outside/additional-body.txt")
        );
        assert_eq!(sources[3]["bytes"], 0);
        assert_eq!(sources[3]["state"], "included");
        if item["limit"] == 32768 {
            assert!(diagnostics.is_empty());
            assert!(instructions.contains("/global-target/AGENTS.md:\nGlobal /private/literal"));
            assert!(!instructions.contains("/outside/global-body.txt:\n"));
            assert!(
                instructions.contains("/outside/additional-body.txt:\nAdditional /private/literal")
            );
            assert!(!instructions.contains("/additional-alias.md:\n"));
        } else if item["limit"] == 0 {
            assert_eq!(instructions, "");
            assert_eq!(diagnostics.len(), 2);
        } else if item["limit"] != 45 {
            assert!(diagnostics.is_empty());
            assert_eq!(sources[2]["includedBytes"], 5);
            assert_eq!(sources[2]["state"], "truncated");
            assert!(instructions.ends_with("/outside/additional-body.txt:\nAddit"));
        }
    } else if name == "global-override-leaf-precedence" {
        assert_eq!(sources.len(), 2);
        assert!(
            instructions.contains("/global-override/AGENTS.override.md:\nGlobal /private/literal")
        );
        assert!(!instructions.contains("GLOBAL ORDINARY MUST NOT WIN"));
    } else if name == "empty-ordinary-and-global-fallback-exclusion" {
        assert_eq!(sources.len(), 1);
        assert!(
            sources[0]["path"]
                .as_str()
                .unwrap()
                .ends_with("/FALLBACK.md")
        );
        assert!(instructions.ends_with("Fallback /private/body"));
        assert!(!instructions.contains("GLOBAL FALLBACK MUST NOT LOAD"));
    } else if name == "missing-optional-through-directory-link" {
        assert_eq!(sources.len(), 2);
        assert_eq!(sources[1]["scope"], "approved additional");
        assert_eq!(sources[1]["bytes"], 0);
        assert!(diagnostics.is_empty());
    } else {
        assert!(name.starts_with("unicode-budget-"));
        assert_eq!(sources.len(), 1);
        if item["limit"] == 32768 {
            assert!(instructions.ends_with("🙂汉字🙂 /private/literal"));
            assert!(diagnostics.is_empty());
        } else {
            assert_eq!(diagnostics.len(), 1);
        }
    }
}
