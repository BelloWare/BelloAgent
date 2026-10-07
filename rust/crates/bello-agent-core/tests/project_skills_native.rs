//! Apple-only oracle against actual checked-in Swift behavior. All files are
//! generated disposable fixtures, and both implementations read the same paths.
#![cfg(target_os = "macos")]
use bello_agent_core::{
    Message,
    compaction::protected_input_ids,
    project_resources::{ProjectResourceSource, ResourceScope},
    skills::{self, DependencySnapshot},
    tool_content::ContentBlock,
    user_content::UserContent,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::Path,
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
    let snapshot = source.discover(&CancellationToken::new()).unwrap();
    let catalog=snapshot.skills.iter().map(|d|json!({"id":d.id,"name":d.name,"path":d.path,"baseDir":d.base_dir,"sourceRoot":d.source_root,"scope":d.scope,"description":d.description,"contentHash":d.content_hash,"metadataHash":d.metadata_hash,"policy":d.policy,"reasons":d.reasons,"dependencies":d.dependencies,"body":body(&snapshot,&d.id)})).collect::<Vec<_>>();
    let selections = snapshot
        .skills
        .iter()
        .map(|d| d.selection(ARGUMENTS.into()))
        .collect::<Vec<_>>();
    let mut result = json!({"case":item["case"],"skills":catalog,"instructions":snapshot.instructions,"unselected":skills::user_message_text("/review",&[],"next-turn").unwrap()});
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
    // The metadata matrix also checks exact resource instructions. The /var
    // cases below independently gate every skill field and retained byte while
    // reporting the still-separate resource-prompt spelling difference.
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
            &root.join(".agents/skills/review/SKILL.md"),
            &skill("review", "Multiple roots", "Root body"),
        );
    }
    alias_cases.push(json!({"case":"darwin-production-multiple-roots","cwd":primary,"roots":[secondary],"home":home}));
    let mut oracle_cases = cases.clone();
    oracle_cases.extend(alias_cases.iter().cloned());
    fs::write(
        &input,
        serde_json::to_vec(&json!({"cases":oracle_cases,"compaction":compaction})).unwrap(),
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
    // No ID/path/baseDir/sourceRoot/hash/body/expansion normalization. Only the
    // unrelated full resource instructions are reported separately below.
    for (offset, item) in alias_cases.iter().enumerate() {
        let actual = rust_result(item);
        let expected = &expected["skills"][cases.len() + offset];
        let mut actual_selection = actual.clone();
        let mut expected_selection = expected.clone();
        actual_selection
            .as_object_mut()
            .unwrap()
            .remove("instructions");
        expected_selection
            .as_object_mut()
            .unwrap()
            .remove("instructions");
        assert_eq!(
            actual_selection, expected_selection,
            "strict Darwin skill source oracle {}",
            item["case"]
        );
        eprintln!(
            "Separate resource-instruction spelling (not a skill parity assertion): {}",
            json!({
                "case":item["case"],"equal":actual["instructions"]==expected["instructions"],
                "rust":actual["instructions"],"swift":expected["instructions"]
            })
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
