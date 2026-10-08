//! Same-filesystem native write/edit comparisons against extracted current Swift
//! source. Only disposable fixtures; no production authority, provider or UI.
#![cfg(target_os = "macos")]
use bello_agent_core::{
    provider::ToolCall,
    tools::{Capability, NativeTools, ToolError},
};
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        process::CommandExt,
    },
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
    let validation = section(
        TOOLS,
        "        let p=call.arguments",
        "        if [\"read\", \"ls\", \"find\", \"grep\"].contains(call.name)",
    );
    let body = section(
        TOOLS,
        "        case \"write\", \"edit\":",
        "        default: throw AgentError(\"tool_unavailable\", \"Unsupported tool\")",
    );
    let definition =
        |name: &str| line(TOOLS, &format!("ToolDefinition(\"{name}\"")).trim_end_matches(',');
    format!(
        r#"import Foundation
import Darwin
{values}
{context}
}}
private func invoke(_ call: ToolCall, files: FileToolContext) throws -> JSON {{
    try Task.checkCancellation()
    let s: JSON = ["type":"string"]
    let definitions = [{write},{edit}]
    guard let definition = definitions.first(where:{{$0.name == call.name}}) else {{ throw AgentError("tool_unavailable", "Tool \(call.name) not found") }}
{validation}
    switch call.name {{
{body}
    default: throw AgentError("tool_unavailable", "Unsupported tool")
    }}
}}
do {{
    let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
    precondition(data.count <= 40*1024*1024)
    let request = try JSON.parse(data)
    let cwd = URL(fileURLWithPath:request["root"].text!)
    let roots = request["roots"].list.map {{ URL(fileURLWithPath:$0.text!) }}
    let files = FileToolContext(cwd:cwd,roots:workspaceRoots(primary:cwd,additional:roots))
    var response: JSON
    do {{ response = ["result":try invoke(ToolCall(id:"fixture",name:request["name"].text!,arguments:request["arguments"]),files:files)] }}
    catch let error as AgentError {{ response = ["error":error.json] }}
    catch {{ let native=error as NSError; response=["nativeError":["domain":JSON(native.domain),"code":JSON(native.code)]] }}
    FileHandle.standardOutput.write(try response.data())
}} catch {{ FileHandle.standardError.write(Data("Mutation oracle failed: \(error)\n".utf8)); exit(1) }}
"#,
        write = definition("write"),
        edit = definition("edit")
    )
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
async fn native_write_edit_match_current_swift_source_and_file_effects() {
    let work = tempfile::tempdir().unwrap();
    let work = work.path();
    let source = work.join("main.swift");
    let executable = work.join("oracle");
    fs::write(&source, oracle_source()).unwrap();
    bounded(
        Command::new("/usr/bin/xcrun")
            .args(["swiftc", "-swift-version", "5", "-module-cache-path"])
            .arg(work.join("module-cache"))
            .arg(&source)
            .arg("-o")
            .arg(&executable),
        work,
        120,
    );
    let root = work.join("project");
    fs::create_dir(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    let extra = work.join("extra");
    fs::create_dir(&extra).unwrap();
    let extra = fs::canonicalize(extra).unwrap();
    let tools = NativeTools::new(
        root.clone(),
        [extra.clone()],
        root.clone(),
        [Capability::Write, Capability::Edit],
    )
    .unwrap();
    let mut cases = vec![
        ("write", None, json!({"path":"file","content":"hello\n"})),
        (
            "write",
            Some(b"old\n".to_vec()),
            json!({"path":"file","content":"new\n"}),
        ),
        (
            "write",
            Some(b"same".to_vec()),
            json!({"path":"file","content":"same"}),
        ),
        (
            "write",
            Some(vec![255]),
            json!({"path":"file","content":"text"}),
        ),
        (
            "write",
            Some(b"x".to_vec()),
            json!({"path":"file","content":""}),
        ),
        ("write", None, json!({"path":null,"content":false})),
        ("write", None, json!({"path":"file","content":null})),
        (
            "write",
            None,
            json!({"path":"file","content":"x","extra":1}),
        ),
        (
            "edit",
            Some(b"a\r\nb\rc\n".to_vec()),
            json!({"path":"file","oldText":"b\rc","newText":"B\rC"}),
        ),
        (
            "edit",
            Some(b"a\nb\nc".to_vec()),
            json!({"path":"file","oldText":"b\n","newText":""}),
        ),
        (
            "edit",
            Some(b"aaaa".to_vec()),
            json!({"path":"file","oldText":"aa","newText":"x"}),
        ),
        (
            "edit",
            Some(b"aaa".to_vec()),
            json!({"path":"file","oldText":"aa","newText":"x"}),
        ),
        (
            "edit",
            Some(b"old".to_vec()),
            json!({"path":"file","oldText":"missing","newText":"new"}),
        ),
        (
            "edit",
            Some(b"old".to_vec()),
            json!({"path":"file","oldText":"","newText":"new"}),
        ),
        (
            "edit",
            None,
            json!({"path":"file","oldText":"x","newText":false}),
        ),
        (
            "edit",
            None,
            json!({"path":"file","oldText":"x","newText":"y"}),
        ),
        (
            "edit",
            Some(vec![255]),
            json!({"path":"file","oldText":"x","newText":"y"}),
        ),
        (
            "edit",
            Some("\u{feff}é\n".as_bytes().to_vec()),
            json!({"path":"file","oldText":"é","newText":"e\u{301}"}),
        ),
        (
            "edit",
            Some("é\ne\u{301}".as_bytes().to_vec()),
            json!({"path":"file","oldText":"é","newText":"new"}),
        ),
        (
            "edit",
            Some("e\u{301}".as_bytes().to_vec()),
            json!({"path":"file","oldText":"é","newText":"new"}),
        ),
        (
            "edit",
            Some("é".as_bytes().to_vec()),
            json!({"path":"file","oldText":"e\u{301}","newText":"new"}),
        ),
    ];
    for initial in [
        "\u{feff}".as_bytes().to_vec(),
        "\u{feff}needle".as_bytes().to_vec(),
        "\u{feff}\u{feff}needle".as_bytes().to_vec(),
        "a\u{feff}needle".as_bytes().to_vec(),
        "\u{feff}\0needle\0".as_bytes().to_vec(),
        format!("\u{feff}{}needle", "a".repeat(40)).into_bytes(),
        vec![0xef, 0xbb, 0xbf, 0xff],
    ] {
        cases.push((
            "write",
            Some(initial.clone()),
            json!({"path":"file","content":"new"}),
        ));
        cases.push((
            "edit",
            Some(initial),
            json!({"path":"file","oldText":"needle","newText":"new"}),
        ));
    }
    for (index, (name, initial, args)) in cases.into_iter().enumerate() {
        let reset = || {
            let _ = fs::remove_file(root.join("file"));
            if let Some(bytes) = &initial {
                fs::write(root.join("file"), bytes).unwrap();
                fs::set_permissions(root.join("file"), fs::Permissions::from_mode(0o751)).unwrap();
            }
        };
        reset();
        let old_inode = fs::metadata(root.join("file")).ok().map(|m| m.ino());
        let input = work.join("request.json");
        fs::write(
            &input,
            serde_json::to_vec(&json!({"root":root,"roots":[extra],"name":name,"arguments":args}))
                .unwrap(),
        )
        .unwrap();
        let expected: Value =
            serde_json::from_slice(&bounded(Command::new(&executable).arg(&input), work, 30))
                .unwrap();
        let expected_bytes = fs::read(root.join("file")).ok();
        let expected_mode = fs::metadata(root.join("file"))
            .ok()
            .map(|m| m.permissions().mode() & 0o777);
        let source_replaced = old_inode
            .zip(fs::metadata(root.join("file")).ok().map(|m| m.ino()))
            .map(|(a, b)| a != b);
        reset();
        let old_inode = fs::metadata(root.join("file")).ok().map(|m| m.ino());
        let actual = native_result(
            tools
                .invoke(
                    &ToolCall {
                        id: format!("case-{index}"),
                        name: name.into(),
                        arguments: args.clone(),
                    },
                    CancellationToken::new(),
                )
                .await,
        );
        assert_eq!(actual, expected, "case {index}: {name} {args}");
        assert_eq!(
            fs::read(root.join("file")).ok(),
            expected_bytes,
            "case {index} file bytes"
        );
        assert_eq!(
            fs::metadata(root.join("file"))
                .ok()
                .map(|m| m.permissions().mode() & 0o777),
            expected_mode,
            "case {index} mode"
        );
        assert_eq!(
            old_inode
                .zip(fs::metadata(root.join("file")).ok().map(|m| m.ino()))
                .map(|(a, b)| a != b),
            source_replaced,
            "case {index} atomic replacement identity"
        );
    }
}
