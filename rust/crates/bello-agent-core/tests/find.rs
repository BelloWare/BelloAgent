//! macOS native Find against the checked-in Swift implementation, on the same
//! disposable filesystem fixtures. This suite never reads a real workspace or
//! home, enumerates `/`, creates a mount, or enables a provider/app tool.
#![cfg(target_os = "macos")]

use bello_agent_core::{
    provider::ToolCall,
    tools::{Capability, NativeTools, ToolError},
};
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    os::unix::{fs::symlink, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

const SOURCE_TOOLS: &str =
    include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Tools.swift");
const SOURCE_SUPPORT: &str =
    include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Support.swift");
const NORMAL_NOTE: &str =
    "\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]";
const LIMITED_NOTE: &str = "\n[Search limited; narrow the path/pattern. Large/binary files and .git/node_modules/.build are skipped.]";

fn section<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
    let offset = source.find(start).expect("Swift oracle start marker moved");
    let tail = &source[offset..];
    &tail[..tail.find(end).expect("Swift oracle end marker moved")]
}

fn line<'a>(source: &'a str, start: &str) -> &'a str {
    source
        .lines()
        .find(|line| line.trim_start().starts_with(start))
        .expect("Swift oracle declaration moved")
        .trim()
}

/// Extract source at test-build time, rather than committing a frozen copy of
/// its behavior. Marker failures deliberately require review after source edits.
fn oracle_source() -> String {
    let values = [
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/JSON.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/JSONParser.swift"),
        include_str!("../../../../packages/swift-host/Sources/PiAgentCore/ProviderFailure.swift"),
        section(
            include_str!(
                "../../../../packages/swift-host/Sources/PiAgentCore/ModelInterface.swift"
            ),
            "public struct ToolDefinition:",
            "public struct ModelTerminalOutcome:",
        ),
    ]
    .join("\n");
    let support = [
        section(
            SOURCE_SUPPORT,
            "public struct AgentError:",
            "/// Error codes",
        ),
        section(SOURCE_SUPPORT, "func required(", "/// Letters, digits"),
        section(SOURCE_SUPPORT, "func boundedInt(", "func nowMS("),
        section(SOURCE_SUPPORT, "func canonical(", "/// System-accelerated"),
        line(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/TextPreviews.swift"),
            "func preview(",
        ),
        line(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/ChatMessage.swift"),
            "func textBlock(",
        ),
        line(SOURCE_TOOLS, "func resultText("),
        line(SOURCE_TOOLS, "func objectSchema("),
        section(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Resources.swift"),
            "func workspaceRoots(",
            "public actor Resources",
        ),
    ]
    .join("\n");
    let context = section(
        SOURCE_TOOLS,
        "private struct FileToolContext:",
        "    func invoke(_ call: ToolCall, cancellation:",
    );
    let find = section(
        SOURCE_TOOLS,
        "        case \"find\", \"grep\":",
        "        default: throw AgentError(\"tool_unavailable\", \"Unsupported file tool\")",
    );
    let native_invoke = section(
        SOURCE_TOOLS,
        "    public func invoke(_ call: ToolCall, readOnly: Bool, onUpdate:",
        "        if [\"read\", \"ls\", \"find\", \"grep\"].contains(call.name)",
    );
    let validation = &native_invoke[native_invoke.find("        let p=call.arguments").unwrap()..];
    let definition = line(SOURCE_TOOLS, "ToolDefinition(\"find\",").trim_end_matches(',');
    let mut source = include_str!("fixtures/find_oracle.swift").to_owned();
    for (marker, replacement) in [
        ("VALUES", values.as_str()),
        ("SUPPORT", support.as_str()),
        (
            "CANCELLATION",
            section(
                include_str!(
                    "../../../../packages/swift-host/Sources/PiAgentCore/BlockingWorkExecutor.swift"
                ),
                "final class BlockingWorkCancellation:",
                "/// Bounds both blocking",
            ),
        ),
        (
            "COERCION",
            section(
                include_str!(
                    "../../../../packages/swift-host/Sources/PiAgentCore/PiProviderRules.swift"
                ),
                "    static func coerceArguments(",
                "    /// EXTENDED_THINKING_LEVELS.",
            ),
        ),
        ("CONTEXT", context),
        ("FIND", find),
        ("VALIDATION", validation),
        ("DEFINITION", definition),
    ] {
        let marker = format!("/* SOURCE_{marker} */");
        assert_eq!(source.matches(&marker).count(), 1);
        source = source.replace(&marker, replacement);
    }
    assert!(!source.contains("/* SOURCE_"));
    source
}

struct SwiftOracle {
    directory: TempDir,
    executable: PathBuf,
}

impl SwiftOracle {
    fn compile() -> Self {
        let directory = TempDir::new().unwrap();
        let source = directory.path().join("main.swift");
        let executable = directory.path().join("find-oracle");
        fs::write(&source, oracle_source()).unwrap();
        let mut command = Command::new("/usr/bin/xcrun");
        command
            .args(["swiftc", "-swift-version", "5", "-module-cache-path"])
            .arg(directory.path().join("module-cache"))
            .arg(&source)
            .arg("-o")
            .arg(&executable);
        bounded_command(&mut command, directory.path(), Duration::from_secs(120));
        Self {
            directory,
            executable,
        }
    }

    fn run(&self, context: &Context, cases: &[Case]) -> Value {
        let directory = tempfile::tempdir_in(self.directory.path()).unwrap();
        let input = directory.path().join("requests.json");
        fs::write(
            &input,
            serde_json::to_vec(&json!({
                "cwd": context.cwd,
                "roots": context.roots,
                "cases": cases.iter().map(|case| json!({
                    "arguments": case.arguments,
                    "cancelled": case.cancelled,
                })).collect::<Vec<_>>()
            }))
            .unwrap(),
        )
        .unwrap();
        let mut command = Command::new(&self.executable);
        command.arg(&input);
        let output = bounded_command(&mut command, directory.path(), Duration::from_secs(30));
        serde_json::from_slice(&output).expect("Swift oracle must return JSON")
    }
}

/// File-backed output cannot deadlock on a full pipe. The deadline kills the
/// entire compiler/oracle process group, then reaps its direct child. These are
/// fixture process deadlines, not timing assumptions about native cancellation.
fn bounded_command(command: &mut Command, directory: &Path, limit: Duration) -> Vec<u8> {
    let stdout = directory.join("stdout");
    let stderr = directory.join("stderr");
    command
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(File::create(&stdout).unwrap())
        .stderr(File::create(&stderr).unwrap())
        .process_group(0);
    let mut child = command
        .spawn()
        .expect("macOS Find oracle requires Xcode swiftc");
    let deadline = Instant::now() + limit;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            unsafe extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            // SAFETY: process_group(0) gave this live child its own group; the
            // negative PID targets only that group, never the test runner.
            unsafe { kill(-(child.id() as i32), 9) };
            child.wait().unwrap();
            panic!("Find oracle command exceeded {limit:?}: {command:?}");
        }
        thread::sleep(Duration::from_millis(20));
    };
    assert!(
        fs::metadata(&stdout).unwrap().len() <= 4 * 1024 * 1024,
        "Find oracle output exceeded fixture bound"
    );
    assert!(
        status.success(),
        "Find oracle command failed: {command:?}\n{}",
        String::from_utf8_lossy(&fs::read(&stderr).unwrap())
    );
    fs::read(stdout).unwrap()
}

struct Context {
    cwd: PathBuf,
    roots: Vec<PathBuf>,
    home: PathBuf,
}

impl Context {
    fn new(cwd: &Path) -> Self {
        Self {
            cwd: fs::canonicalize(cwd).unwrap(),
            roots: Vec::new(),
            home: fs::canonicalize(cwd).unwrap(),
        }
    }

    fn tools(&self) -> NativeTools {
        NativeTools::new(
            self.cwd.clone(),
            self.roots.clone(),
            self.home.clone(),
            [Capability::Find],
        )
        .unwrap()
    }
}

struct Case {
    label: String,
    arguments: Value,
    cancelled: bool,
}

fn case(label: impl Into<String>, arguments: Value) -> Case {
    Case {
        label: label.into(),
        arguments,
        cancelled: false,
    }
}

fn call(arguments: Value) -> ToolCall {
    ToolCall {
        id: "fixture-find".into(),
        name: "find".into(),
        arguments,
    }
}

async fn compare(oracle: &SwiftOracle, context: &Context, cases: Vec<Case>) -> Vec<Value> {
    let source = oracle.run(context, &cases);
    let native = context.tools();
    assert_eq!(
        serde_json::to_value(&native.definitions()[0]).unwrap(),
        source["definition"]
    );
    let expected = source["cases"].as_array().unwrap();
    assert_eq!(expected.len(), cases.len());
    let mut outcomes = Vec::new();
    for (case, expected) in cases.into_iter().zip(expected) {
        let call = call(case.arguments);
        assert_eq!(
            native.prepare_call(&call).arguments,
            expected["prepared"],
            "source preparation: {}",
            case.label,
        );
        let cancellation = CancellationToken::new();
        if case.cancelled {
            cancellation.cancel();
        }
        let result = tokio::time::timeout(
            Duration::from_secs(30),
            native.invoke_prepared(&call, cancellation),
        )
        .await
        .unwrap_or_else(|_| panic!("native Find did not finish: {}", case.label));
        let outcome = match result {
            Ok(value) => json!({"result": value}),
            Err(ToolError::Cancelled) => json!({"cancelled": true}),
            Err(ToolError::Failure { code, message }) => {
                json!({"error": {"code": code, "message": message}})
            }
            Err(error) => panic!("unexpected native failure for {}: {error}", case.label),
        };
        assert_eq!(
            outcome, expected["outcome"],
            "source result: {}",
            case.label
        );
        outcomes.push(outcome);
    }
    outcomes
}

fn mkdir(path: impl AsRef<Path>) {
    fs::create_dir_all(path).unwrap();
}

fn touch(path: impl AsRef<Path>) {
    fs::write(path, []).unwrap();
}

fn text(outcome: &Value) -> &str {
    outcome["result"]["content"][0]["text"].as_str().unwrap()
}

#[tokio::test]
async fn native_find_matches_the_current_swift_source_on_macos() {
    // One compilation serves every source-comparison batch in this test. The
    // executable, module cache, requests, logs, and fixtures are all removed
    // when their TempDirs drop, including on assertion failure.
    let oracle = SwiftOracle::compile();
    basic_and_glob_fixtures(&oracle).await;
    path_resolution_fixtures(&oracle).await;
    preparation_and_failure_fixtures(&oracle).await;
    unicode_and_preview_fixtures(&oracle).await;
    scan_boundary_fixture(&oracle).await;
}

async fn basic_and_glob_fixtures(oracle: &SwiftOracle) {
    let fixture = TempDir::new().unwrap();
    let root = fixture.path().join("workspace");
    mkdir(root.join("nested/deeper"));
    for name in [
        ".hidden",
        "alpha.txt",
        "binary.bin",
        "large.bin",
        "literal[",
        "star*",
        "true",
        "0",
    ] {
        touch(root.join(name));
    }
    fs::write(root.join("binary.bin"), [0, 255, 254, 128]).unwrap();
    File::create(root.join("large.bin"))
        .unwrap()
        .set_len(2 * 1024 * 1024 + 1)
        .unwrap();
    touch(root.join("nested/deeper/alpha.txt"));
    touch(root.join("nested/deeper/back\\slash"));
    for name in [".git", "node_modules", ".build"] {
        mkdir(root.join(name));
        touch(root.join(name).join("never-seen.txt"));
        // Source excludes these names regardless of file type or depth.
        touch(root.join("nested").join(name));
    }
    let outside = fixture.path().join("outside");
    mkdir(&outside);
    touch(outside.join("outside.txt"));
    symlink(root.join("alpha.txt"), root.join("file-link")).unwrap();
    symlink(&outside, root.join("directory-link")).unwrap();
    symlink(fixture.path().join("missing"), root.join("dangling-link")).unwrap();
    let patterns = [
        "*",
        "*.txt",
        "nested/*",
        "nested/deeper/*",
        ".*",
        "binary.bin",
        "large.bin",
        "*link*",
        "literal[",
        "[",
        "[!a]*",
        "[[:alpha:]]*",
        "star\\*",
        "back\\\\slash",
        "a?pha.txt",
        "ALPHA.TXT",
        "alpha.txt\0never-matched",
        "\0*",
    ];
    let mut cases = patterns
        .iter()
        .map(|pattern| case(format!("glob {pattern:?}"), json!({"pattern":pattern})))
        .collect::<Vec<_>>();
    cases.extend([
        case(
            "limit zero matching first candidate",
            json!({"pattern":"*", "limit":0}),
        ),
        case(
            "limit zero nonmatching first candidate",
            json!({"pattern":"never", "limit":0}),
        ),
        case(
            "exact limit still appends limited note",
            json!({"pattern":"binary.bin", "limit":1}),
        ),
        case(
            "positive limit without any match",
            json!({"pattern":"never", "limit":1}),
        ),
        case(
            "file root is a single candidate",
            json!({"path":"binary.bin", "pattern":"*"}),
        ),
        case(
            "explicit skipped-name file is a candidate",
            json!({"path":"nested/.git", "pattern":"*"}),
        ),
        case(
            "explicit skipped-name directory can be searched",
            json!({"path":".git", "pattern":"*"}),
        ),
        case(
            "explicit directory symlink resolves before enumeration",
            json!({"path":"directory-link", "pattern":"*"}),
        ),
        case(
            "explicit file symlink resolves to target basename",
            json!({"path":"file-link", "pattern":"*"}),
        ),
        case(
            "dangling search root fails",
            json!({"path":"dangling-link", "pattern":"*"}),
        ),
    ]);
    let results = compare(oracle, &Context::new(&root), cases).await;
    let all = text(&results[0]);
    assert!(
        all.contains("binary.bin") && all.contains("large.bin") && all.contains("nested/deeper\n")
    );
    assert!(
        !all.contains("never-seen") && !all.contains("outside.txt") && !all.contains("file-link")
    );
    assert!(all.ends_with(NORMAL_NOTE));
    assert!(text(&results[patterns.len()]).ends_with(LIMITED_NOTE));
    assert_eq!(text(&results[patterns.len() + 1]), LIMITED_NOTE);
    let empty = fixture.path().join("empty");
    mkdir(&empty);
    let results = compare(
        oracle,
        &Context::new(&empty),
        vec![
            case("empty default limit", json!({"pattern":"*"})),
            case("empty zero limit", json!({"pattern":"*", "limit":0})),
        ],
    )
    .await;
    assert_eq!(text(&results[0]), NORMAL_NOTE);
    assert_eq!(text(&results[1]), LIMITED_NOTE);
}

async fn path_resolution_fixtures(oracle: &SwiftOracle) {
    let fixture = TempDir::new().unwrap();
    let primary = fixture.path().join("primary");
    let second = fixture.path().join("second");
    let third = fixture.path().join("third");
    for base in [&primary, &second, &third] {
        mkdir(base);
    }
    mkdir(second.join("only"));
    touch(second.join("only/secondary"));
    mkdir(primary.join("both"));
    mkdir(second.join("both"));
    touch(primary.join("both/primary"));
    touch(second.join("both/secondary"));
    mkdir(second.join("ambiguous"));
    mkdir(third.join("ambiguous"));
    touch(primary.join("file-wins"));
    mkdir(second.join("file-wins"));
    touch(second.join("file-wins/secondary"));
    mkdir(second.join("real/child"));
    touch(second.join("real/parent-marker"));
    symlink(second.join("real/child"), primary.join("link")).unwrap();
    let mut context = Context::new(&primary);
    context.roots = vec![second.clone(), third, second.clone()];
    let results = compare(
        oracle,
        &context,
        vec![
            case(
                "unique fallback with duplicate roots",
                json!({"path":"only", "pattern":"*"}),
            ),
            case(
                "primary takes precedence",
                json!({"path":"both", "pattern":"*"}),
            ),
            case(
                "ambiguous fallback remains missing primary",
                json!({"path":"ambiguous", "pattern":"*"}),
            ),
            case(
                "primary file wins over secondary directory",
                json!({"path":"file-wins", "pattern":"*"}),
            ),
            case(
                "absolute path within fixture",
                json!({"path":second.join("only"), "pattern":"*"}),
            ),
            case(
                "parent path within fixture",
                json!({"path":"../second/only", "pattern":"*"}),
            ),
            case(
                "symlink then parent follows Foundation",
                json!({"path":"link/..", "pattern":"*"}),
            ),
            case(
                "dot and repeated separators",
                json!({"path":"./both//.", "pattern":"*"}),
            ),
            case(
                "explicit directory trailing separator",
                json!({"path":"both/", "pattern":"*"}),
            ),
            case("missing path", json!({"path":"missing", "pattern":"*"})),
            case(
                "missing suffix after symlink",
                json!({"path":"link/missing", "pattern":"*"}),
            ),
            case("null optional path", json!({"path":null, "pattern":"*"})),
        ],
    )
    .await;
    assert_eq!(text(&results[0]), format!("secondary{NORMAL_NOTE}"));
    assert_eq!(text(&results[1]), format!("primary{NORMAL_NOTE}"));
    assert_eq!(results[2]["error"]["code"], "missing_path");
    assert_eq!(text(&results[3]), format!("file-wins{NORMAL_NOTE}"));

    let composed = fixture.path().join("café");
    let decomposed = fixture.path().join("cafe\u{301}");
    mkdir(composed.join("unique"));
    touch(composed.join("unique/from-secondary"));
    // APFS/HFS+ treat these spellings as aliases, but Swift's Set<String>
    // deduplicates them before filesystem lookup regardless of that behavior.
    // A bytewise Rust root set must not invent two fallback candidates.
    context.roots = vec![composed, decomposed];
    let results = compare(
        oracle,
        &context,
        vec![case(
            "canonically equivalent extra roots remain a unique fallback",
            json!({"path":"unique", "pattern":"*"}),
        )],
    )
    .await;
    assert_eq!(text(&results[0]), format!("from-secondary{NORMAL_NOTE}"));
}

async fn preparation_and_failure_fixtures(oracle: &SwiftOracle) {
    let fixture = TempDir::new().unwrap();
    mkdir(fixture.path().join("true"));
    touch(fixture.path().join("true/true"));
    touch(fixture.path().join("0"));
    let mut cases = vec![
        case(
            "boolean pattern and path plus hexadecimal limit",
            json!({"pattern":true, "path":true, "limit":"\u{feff}0x10\u{a0}"}),
        ),
        case("number pattern stringification", json!({"pattern":-0.0})),
        case(
            "optional nulls removed",
            json!({"pattern":"*", "path":null, "limit":null}),
        ),
        case(
            "required null becomes empty string",
            json!({"pattern":null}),
        ),
        case("required pattern absent", json!({})),
        case(
            "extra key rejected",
            json!({"pattern":"*", "ignoreCase":true}),
        ),
        case("non-object arguments", json!([])),
        case("empty path rejected", json!({"pattern":"*", "path":""})),
        case(
            "oversize multibyte pattern",
            json!({"pattern":"é".repeat(2049)}),
        ),
        case(
            "exact pattern byte bound",
            json!({"pattern":"é".repeat(2048)}),
        ),
        case(
            "oversize multibyte path",
            json!({"pattern":"*", "path":"é".repeat(2049)}),
        ),
        case(
            "path failure precedes invalid pattern",
            json!({"path":[], "pattern":[], "limit":-1}),
        ),
        case(
            "pattern failure precedes invalid limit",
            json!({"pattern":[], "limit":-1}),
        ),
        case(
            "invalid limit precedes missing path",
            json!({"path":"missing", "pattern":"*", "limit":-1}),
        ),
        case(
            "missing path precedes malformed glob matching",
            json!({"path":"missing", "pattern":"["}),
        ),
    ];
    for limit in [
        json!(false),
        json!(true),
        json!("2.0"),
        json!("0o10"),
        json!("0B11"),
        json!(0),
        json!(2000),
        json!(2001),
        json!(-1),
        json!(1.5),
        json!(""),
        json!("1e9999"),
        json!([]),
        json!({}),
    ] {
        cases.push(case(
            format!("prepared limit {limit}"),
            json!({"pattern":"*", "limit":limit}),
        ));
    }
    let mut cancelled = case(
        "cancellation before argument validation",
        json!({"unsupported":true}),
    );
    cancelled.cancelled = true;
    cases.push(cancelled);
    let mut cancelled = case(
        "cancellation before filesystem work",
        json!({"pattern":"*"}),
    );
    cancelled.cancelled = true;
    cases.push(cancelled);
    compare(oracle, &Context::new(fixture.path()), cases).await;
}

async fn unicode_and_preview_fixtures(oracle: &SwiftOracle) {
    let fixture = TempDir::new().unwrap();
    // A combining-only suffix of the separator changes Swift hasPrefix's
    // Character boundaries; the ZWJ root exercises count/dropFirst semantics.
    let root = fixture.path().join("é-e\u{301}-👩‍💻");
    mkdir(&root);
    for name in [
        "z.txt",
        "é-one",
        "e\u{301}-two",
        "👨‍👩‍👧‍👦",
        "🇨🇦",
        "\u{301}leading",
        "\u{fffd}trim\u{fffd}",
    ] {
        touch(root.join(name));
    }
    mkdir(root.join("👩🏽‍💻-e\u{301}"));
    touch(root.join("👩🏽‍💻-e\u{301}/\u{301}nested"));
    mkdir(root.join("\u{301}directory"));
    touch(root.join("\u{301}directory/leaf"));
    compare(
        oracle,
        &Context::new(&root),
        vec![
            case(
                "Unicode order and grapheme relative paths",
                json!({"pattern":"*"}),
            ),
            case("decomposed glob", json!({"pattern":"e\u{301}*"})),
            case("composed glob", json!({"pattern":"é*"})),
            case(
                "leading combining basename",
                json!({"pattern":"\u{301}leading"}),
            ),
            case(
                "leading combining directory changes relative prefix boundary",
                json!({"pattern":"leaf"}),
            ),
            case(
                "replacement characters trimmed in singleton preview",
                json!({"path":"\u{fffd}trim\u{fffd}", "pattern":"*"}),
            ),
        ],
    )
    .await;

    let long = fixture.path().join("preview");
    mkdir(&long);
    for index in 0..180 {
        // Each basename stays below filesystem byte limits; the combined
        // output crosses the 32-KiB boundary inside multi-byte text.
        touch(long.join(format!("{index:04}-{}-👩‍💻", "é".repeat(100))));
    }
    let results = compare(
        oracle,
        &Context::new(&long),
        vec![
            case("default result count bound", json!({"pattern":"*"})),
            case("byte preview bound", json!({"pattern":"*", "limit":2000})),
            case(
                "exact total count remains limited",
                json!({"pattern":"*", "limit":180}),
            ),
        ],
    )
    .await;
    assert!(text(&results[0]).ends_with(LIMITED_NOTE));
    let preview = text(&results[1]).strip_suffix(LIMITED_NOTE).unwrap();
    assert!(preview.len() <= 32768 && preview.len() > 32760);
    assert!(!preview.ends_with('\u{fffd}'));
}

async fn scan_boundary_fixture(oracle: &SwiftOracle) {
    let fixture = TempDir::new().unwrap();
    for index in 0..20_000 {
        touch(fixture.path().join(format!("entry-{index:05}")));
    }
    let context = Context::new(fixture.path());
    let results = compare(
        oracle,
        &context,
        vec![case(
            "exactly 20000 candidates mark the scan limited",
            json!({"pattern":"no-match", "limit":2000}),
        )],
    )
    .await;
    assert_eq!(text(&results[0]), LIMITED_NOTE);
    touch(fixture.path().join("entry-20000"));
    // Native Foundation and Swift receive the same unchanged directory. The
    // glob compares a retained subset after the cap and before result limiting.
    compare(
        oracle,
        &context,
        vec![case(
            "Foundation selection before capped scan sorting",
            json!({"pattern":"*199*", "limit":2000}),
        )],
    )
    .await;
}

#[tokio::test]
async fn native_find_is_explicit_and_does_not_expand_an_ls_allowlist() {
    let fixture = TempDir::new().unwrap();
    let root = fs::canonicalize(fixture.path()).unwrap();
    let native = NativeTools::new(root.clone(), [], root.clone(), [Capability::Find]).unwrap();
    assert_eq!(native.capability_ids(), ["find"]);
    let both = NativeTools::new(
        root.clone(),
        [],
        root.clone(),
        [Capability::Find, Capability::Ls],
    )
    .unwrap();
    assert_eq!(both.capability_ids(), ["ls", "find"]);
    let ls = NativeTools::new(root.clone(), [], root, [Capability::Ls]).unwrap();
    assert_eq!(ls.capability_ids(), ["ls"]);
    let error = ls
        .invoke_prepared(&call(json!({"pattern":"*"})), CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("tool_unavailable"));
    assert_eq!(error.to_string(), "Tool find not found");
}
