//! Original Swift text Read results on disposable same-filesystem inputs.
#![cfg(target_os = "macos")]
use bello_agent_core::{
    provider::ToolCall,
    tools::{Capability, NativeTools, ToolError},
};
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;
const TOOLS: &str = include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Tools.swift");
const SUPPORT: &str =
    include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Support.swift");
fn section<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
    let tail = &source[source.find(start).expect("Swift start marker moved")..];
    &tail[..tail.find(end).expect("Swift end marker moved")]
}
fn line<'a>(source: &'a str, start: &str) -> &'a str {
    source
        .lines()
        .find(|line| line.trim_start().starts_with(start))
        .expect("Swift declaration moved")
        .trim()
}
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
        section(SUPPORT, "public struct AgentError:", "/// Error codes"),
        section(SUPPORT, "func required(", "/// Letters, digits"),
        section(SUPPORT, "func canonical(", "/// System-accelerated"),
        section(SUPPORT, "func boundedInt(", "func nowMS("),
        line(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/TextPreviews.swift"),
            "func preview(",
        ),
        line(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/ChatMessage.swift"),
            "func textBlock(",
        ),
        line(TOOLS, "func resultText("),
        line(TOOLS, "func objectSchema("),
        section(TOOLS, "func lineDiffStats(", "func objectSchema("),
        section(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Resources.swift"),
            "func workspaceRoots(",
            "public actor Resources",
        ),
    ]
    .join("\n");
    let context = section(
        TOOLS,
        "private struct FileToolContext:",
        "    func invoke(_ call: ToolCall, cancellation:",
    );
    let acquire = section(
        TOOLS,
        "            let file=try path(p[\"path\"],existing:true), data=try readBounded",
        "            // Pi's read tool:",
    );
    let text = section(
        TOOLS,
        "            guard let text=String(data:data,encoding:.utf8)",
        "        case \"ls\":",
    );
    let cancellation = section(
        include_str!(
            "../../../../packages/swift-host/Sources/PiAgentCore/BlockingWorkExecutor.swift"
        ),
        "final class BlockingWorkCancellation:",
        "/// Bounds both blocking",
    );
    let mut result = include_str!("fixtures/read_text_oracle.swift").to_owned();
    for (name, value) in [
        ("VALUES", values.as_str()),
        ("CONTEXT", context),
        ("ACQUIRE", acquire),
        ("TEXT", text),
        ("CANCELLATION", cancellation),
    ] {
        let marker = format!("/* SOURCE_{name} */");
        assert_eq!(result.matches(&marker).count(), 1);
        result = result.replace(&marker, value);
    }
    assert!(!result.contains("/* SOURCE_"));
    result
}
fn bounded(command: &mut Command, directory: &Path, seconds: u64) -> Vec<u8> {
    let out = directory.join("stdout");
    let err = directory.join("stderr");
    command
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(File::create(&out).unwrap())
        .stderr(File::create(&err).unwrap())
        .process_group(0);
    let mut child = command.spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            // SAFETY: only this disposable command's isolated process group.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            child.wait().unwrap();
            panic!("Mutation oracle command timed out");
        }
        thread::sleep(Duration::from_millis(20));
    };
    assert!(
        status.success(),
        "{}",
        String::from_utf8_lossy(&fs::read(err).unwrap())
    );
    assert!(fs::metadata(&out).unwrap().len() <= 1024 * 1024);
    fs::read(out).unwrap()
}
fn native_result(result: Result<Value, ToolError>) -> Value {
    match result {
        Ok(value) => json!({"result":value}),
        Err(ToolError::Failure { code, message }) => {
            json!({"error":{"code":code,"message":message}})
        }
        Err(ToolError::Native { domain, code, .. }) => {
            json!({"nativeError":{"domain":domain,"code":code}})
        }
        Err(error) => panic!("unexpected native mutation error: {error}"),
    }
}
#[tokio::test]
async fn native_text_read_matches_current_swift_source() {
    let temp = tempfile::tempdir().unwrap();
    let directory = temp.path();
    let oracle = directory.join("oracle");
    let swift = directory.join("oracle.swift");
    fs::write(&swift, oracle_source()).unwrap();
    bounded(
        Command::new("/usr/bin/xcrun")
            .args(["swiftc", "-swift-version", "5", "-module-cache-path"])
            .arg(directory.join("cache"))
            .arg(&swift)
            .arg("-o")
            .arg(&oracle),
        directory,
        120,
    );
    let root = directory.join("project");
    fs::create_dir(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    let tools = NativeTools::new(root.clone(), [], root.clone(), [Capability::Read]).unwrap();
    let limit = 16 * 1024 * 1024;
    let mut exact = "\u{feff}needle\n".as_bytes().to_vec();
    exact.resize(limit, b'a');
    let mut over = exact.clone();
    over.push(b'a');
    let inputs = vec![
        ("empty", vec![]),
        ("bom", "\u{feff}".as_bytes().to_vec()),
        ("single", "\u{feff}needle".as_bytes().to_vec()),
        ("double", "\u{feff}\u{feff}needle".as_bytes().to_vec()),
        ("interior", "a\u{feff}needle".as_bytes().to_vec()),
        ("nul", "\u{feff}\0needle\0".as_bytes().to_vec()),
        ("invalid", vec![0xef, 0xbb, 0xbf, 0xff]),
        ("truncated", vec![0xe2, 0x82]),
        (
            "unicode",
            "\u{feff}é e\u{301} 🦀\r\nnext\r".as_bytes().to_vec(),
        ),
        (
            "long",
            format!("\u{feff}{}", "a".repeat(32770)).into_bytes(),
        ),
        ("exact", exact),
        ("over", over),
    ];
    for (name, bytes) in inputs {
        fs::write(root.join("file"), bytes).unwrap();
        for arguments in [
            json!({"path":"file"}),
            json!({"path":"file","offset":2,"limit":1}),
        ] {
            let request = directory.join("request.json");
            fs::write(
                &request,
                serde_json::to_vec(&json!({"root":root,"arguments":arguments})).unwrap(),
            )
            .unwrap();
            let expected: Value = serde_json::from_slice(&bounded(
                Command::new(&oracle).arg(&request),
                directory,
                30,
            ))
            .unwrap();
            let actual = native_result(
                tools
                    .invoke(
                        &ToolCall {
                            id: name.into(),
                            name: "read".into(),
                            arguments: arguments.clone(),
                        },
                        CancellationToken::new(),
                    )
                    .await,
            );
            assert_eq!(actual, expected, "{name}: {arguments}");
        }
    }
}
