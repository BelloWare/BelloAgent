//! Disposable macOS process-result comparisons against the checked-in Swift
//! ShellRun, ManagedChild and invocation validation. This is not an ownership
//! parity claim: Swift's delayed group escalation is deliberately unmodified.
//! No provider, production authority, user configuration or MCP transport runs.
#![cfg(target_os = "macos")]

use bello_agent_core::{
    provider::ToolCall,
    tools::{Capability, NativeTools, ToolError, bash::Environment},
};
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    io,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

const TOOLS: &str = include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Tools.swift");
const MCP: &str = include_str!("../../../../packages/swift-host/Sources/PiAgentCore/MCP.swift");
const SUPPORT: &str =
    include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Support.swift");
const WORKER_REQUEST: &str = "BELLO_BASH_SOURCE_ORACLE_REQUEST";
const SAFE_PATH: &str = "/usr/bin:/bin";

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
        section(SUPPORT, "func boundedInt(", "/// The time as every record"),
        line(
            include_str!("../../../../packages/swift-host/Sources/PiAgentCore/ChatMessage.swift"),
            "func textBlock(",
        ),
        line(TOOLS, "func resultText("),
        line(TOOLS, "func objectSchema("),
        section(
            MCP,
            "final class ManagedChild:",
            "public protocol MCPTransport:",
        ),
        section(TOOLS, "final class ShellRun:", "public actor NativeTools:"),
    ]
    .join("\n");
    let definition = line(TOOLS, "ToolDefinition(\"bash\"").trim_end_matches(',');
    let validation = section(
        TOOLS,
        "        let p=call.arguments",
        "        if [\"read\", \"ls\", \"find\", \"grep\"].contains(call.name)",
    );
    let invocation = section(
        TOOLS,
        "        case \"bash\":",
        "        case \"write\", \"edit\":",
    );
    format!(
        r#"import Foundation
import Darwin
{values}
private func invoke(_ call: ToolCall, cwd: URL, outputs: URL) async throws -> JSON {{
    try Task.checkCancellation()
    let s: JSON = ["type":"string"], n: JSON = ["type":"integer","minimum":1]
    let definition = {definition}
    let onUpdate: @Sendable (JSON) async -> Void = {{ _ in }}
{validation}
    switch call.name {{
{invocation}
    default: throw AgentError("tool_unavailable", "Unsupported tool")
    }}
}}
@main enum BashSourceOracle {{
    static func main() async {{
        do {{
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            precondition(bytes.count <= 1024 * 1024)
            let request = try JSON.parse(bytes)
            let cwd = URL(fileURLWithPath: request["root"].text!)
            let outputs = URL(fileURLWithPath: request["outputs"].text!)
            var response: JSON
            do {{
                response = ["result": try await invoke(ToolCall(id:"fixture", name:"bash", arguments:request["arguments"]), cwd:cwd, outputs:outputs)]
            }} catch let error as AgentError {{ response = ["error":error.json] }}
            catch {{
                let native = error as NSError
                response = ["nativeError":["domain":JSON(native.domain),"code":JSON(native.code)]]
            }}
            try response.data().write(to: URL(fileURLWithPath: request["response"].text!))
        }} catch {{
            FileHandle.standardError.write(Data("Bash source oracle failed: \(error)\n".utf8))
            exit(1)
        }}
    }}
}}
"#,
    )
}

/// There is exactly one wait owner. WNOWAIT reserves the leader's identity
/// until all signalling has finished; stdout/stderr are files, never pipes.
struct OwnedChild(Option<Child>);

impl OwnedChild {
    fn exited(&mut self) -> io::Result<bool> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        loop {
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.0.as_ref().expect("child was reaped").id(),
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result == 0 {
                return Ok(unsafe { info.si_pid() } != 0);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                // Losing wait ownership forbids even cleanup-by-numeric-PID.
                self.0.take();
                return Err(error);
            }
        }
    }

    fn kill_owned_group(&mut self) -> io::Result<()> {
        self.exited()?;
        let pid = self.0.as_ref().expect("owned child").id() as libc::pid_t;
        assert!(pid > 1 && pid != unsafe { libc::getpgrp() });
        if unsafe { libc::kill(-pid, libc::SIGKILL) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
        Ok(())
    }

    fn reap(&mut self) -> ExitStatus {
        // Remove all signalling access before the PID can be reused.
        self.0.take().expect("owned child").wait().unwrap()
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.0.is_some() && self.kill_owned_group().is_ok() {
            self.reap();
        }
    }
}

fn bounded(command: &mut Command, root: &Path, seconds: u64, request: Option<&Path>) {
    // WNOWAIT is meaningful only without automatic or external SIGCHLD reaping.
    // This integration executable installs no signal handlers or other waiters.
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { libc::sigaction(libc::SIGCHLD, std::ptr::null(), &mut action) },
        0
    );
    assert_eq!(action.sa_sigaction, libc::SIG_DFL);
    assert_eq!(action.sa_flags & libc::SA_NOCLDWAIT, 0);
    let stdout = root.join("runner.stdout");
    let stderr = root.join("runner.stderr");
    command
        .current_dir(root)
        .env_clear()
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", SAFE_PATH)
        .env("LANG", "C")
        .stdin(Stdio::null())
        .stdout(File::create(stdout).unwrap())
        .stderr(File::create(&stderr).unwrap())
        .process_group(0);
    if let Some(request) = request {
        command.env(WORKER_REQUEST, request);
    }
    let mut child = OwnedChild(Some(command.spawn().unwrap()));
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if child.exited().unwrap() {
            let status = child.reap();
            assert!(
                status.success(),
                "{}",
                String::from_utf8_lossy(&fs::read(stderr).unwrap())
            );
            return;
        }
        assert!(
            Instant::now() < deadline,
            "Bash oracle child exceeded {seconds}s; owned cleanup follows"
        );
        thread::sleep(Duration::from_millis(10));
    }
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
        Err(error) => panic!("unexpected native bash error: {error}"),
    }
}

// A separate test-process invocation also bounds the native side if its worker
// regresses. No shell script, PID file, timer or unowned numeric cleanup is used.
#[test]
fn native_bash_source_worker() {
    let Some(request) = std::env::var_os(WORKER_REQUEST) else {
        return;
    };
    let request: Value = serde_json::from_slice(&fs::read(request).unwrap()).unwrap();
    let root = PathBuf::from(request["root"].as_str().unwrap());
    let tools = NativeTools::new(root.clone(), [], root.join("home"), [Capability::Bash])
        .unwrap()
        .with_shell_environment(Environment {
            home: root.join("home"),
            temporary: root.join("tmp"),
            path: SAFE_PATH.into(),
            lang: "C".into(),
        })
        .with_shell_output(PathBuf::from(request["outputs"].as_str().unwrap()));
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    let result = runtime.block_on(tools.invoke(
        &ToolCall {
            id: "fixture".into(),
            name: "bash".into(),
            arguments: request["arguments"].clone(),
        },
        CancellationToken::new(),
    ));
    fs::write(
        request["response"].as_str().unwrap(),
        serde_json::to_vec(&native_result(result)).unwrap(),
    )
    .unwrap();
}

fn text(value: &Value) -> &str {
    value["result"]["content"][0]["text"].as_str().unwrap()
}

fn retained(directory: &Path) -> PathBuf {
    assert_eq!(
        fs::metadata(directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    let entries: Vec<_> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(entries.len(), 1, "exactly one retained run");
    let path = if entries[0].is_dir() {
        assert_eq!(
            fs::metadata(&entries[0]).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let logs: Vec<_> = fs::read_dir(&entries[0])
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(logs.len(), 1);
        logs[0].clone()
    } else {
        entries[0].clone()
    };
    assert!(fs::metadata(&path).unwrap().is_file());
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    path
}

fn normalized(mut value: Value, retained: &Path) -> Value {
    let normalized = text(&value).replace(retained.to_str().unwrap(), "<retained-output>");
    value["result"]["content"][0]["text"] = json!(normalized);
    value
}

fn sorted_lines(bytes: &[u8]) -> Vec<&str> {
    let mut lines: Vec<_> = std::str::from_utf8(bytes).unwrap().lines().collect();
    lines.sort_unstable();
    lines
}

#[test]
fn native_bash_results_match_current_swift_source() {
    let work = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(work.path()).unwrap();
    for name in ["home", "tmp"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    let source = root.join("BashSourceOracle.swift");
    let oracle = root.join("bash-source-oracle");
    fs::write(&source, oracle_source()).unwrap();
    bounded(
        Command::new("/usr/bin/xcrun")
            .args([
                "swiftc",
                "-swift-version",
                "5",
                "-parse-as-library",
                "-module-cache-path",
            ])
            .arg(root.join("module-cache"))
            .arg(&source)
            .arg("-o")
            .arg(&oracle),
        &root,
        120,
        None,
    );
    let malformed = vec![0xff; 40_000];
    fs::write(root.join("malformed.bin"), &malformed).unwrap();
    let mut boundary = vec![b'x'; 32_767];
    boundary.extend_from_slice("€tail".as_bytes());
    fs::write(root.join("boundary.bin"), &boundary).unwrap();
    let small_invalid = [b'a', 0xff, 0xc0, 0xaf, 0xe2, b'(', 0xa1, 0, b'z'];
    fs::write(root.join("small-invalid.bin"), small_invalid).unwrap();

    // NativeToolTests.swift motivates the two-pipe, inherited-output and
    // deadline cases. Keep all commands finite and confined to this fixture.
    // For timeout, Bash AND its pipe-holding child ignore TERM and remain alive
    // until Swift's one-second escalation. Never exercise its post-reap timer
    // race here. Rust's owned-leader timeout-after-exit tests cover that boundary.
    let cases = [
        (
            "success",
            json!({"command":"printf 'hello\\n'","timeout":10}),
        ),
        (
            "nonzero",
            json!({"command":"printf failure; exit 7","timeout":10}),
        ),
        (
            "both-pipes",
            json!({"command":"printf 'stdout-one\\nstdout-two\\n'; printf 'stderr-one\\nstderr-two\\n' >&2; exit 7","timeout":10}),
        ),
        (
            "environment",
            json!({"command":"printf '%s\\n' \"$HOME\" \"$TMPDIR\" \"$PATH\" \"$LANG\"; test -z \"${BASH_ENV-}${ENV-}${AWS_ACCESS_KEY_ID-}\"","timeout":10}),
        ),
        (
            "small-invalid",
            json!({"command":"/bin/cat small-invalid.bin","timeout":10}),
        ),
        (
            "malformed",
            json!({"command":"/bin/cat malformed.bin","timeout":10}),
        ),
        (
            "boundary",
            json!({"command":"/bin/cat boundary.bin","timeout":10}),
        ),
        (
            "held-pipes",
            json!({"command":"/bin/sleep 5 & printf held; exit 0","timeout":10}),
        ),
        (
            "timeout",
            json!({"command":"trap '' TERM; printf started; /bin/sleep 8 & wait","timeout":1}),
        ),
        ("missing-command", json!({"timeout":1})),
        ("empty-command", json!({"command":""})),
        (
            "extra-argument",
            json!({"command":"printf unused","extra":1}),
        ),
        (
            "zero-timeout",
            json!({"command":"printf unused","timeout":0}),
        ),
        (
            "bad-timeout",
            json!({"command":"printf unused","timeout":601}),
        ),
        ("nonobject", json!([])),
    ];
    for (name, arguments) in cases {
        let mut results = Vec::new();
        let mut outputs = Vec::new();
        for native in [false, true] {
            let side = if native { "rust" } else { "swift" };
            let output = root.join(format!("{name}-{side}-output"));
            let response = root.join(format!("{name}-{side}-response.json"));
            let request_path = root.join(format!("{name}-{side}-request.json"));
            let request =
                json!({"root":root,"outputs":output,"response":response,"arguments":arguments});
            fs::write(&request_path, serde_json::to_vec(&request).unwrap()).unwrap();
            let mut command = if native {
                let mut command = Command::new(std::env::current_exe().unwrap());
                command.args([
                    "--exact",
                    "native_bash_source_worker",
                    "--test-threads=1",
                    "--nocapture",
                ]);
                command
            } else {
                let mut command = Command::new(&oracle);
                command.arg(&request_path);
                command
            };
            bounded(
                &mut command,
                &root,
                15,
                native.then_some(request_path.as_path()),
            );
            assert!(fs::metadata(&response).unwrap().len() <= 1024 * 1024);
            let value: Value = serde_json::from_slice(&fs::read(response).unwrap()).unwrap();
            if value.get("result").is_some() {
                let path = retained(&output);
                outputs.push(fs::read(&path).unwrap());
                results.push(normalized(value, &path));
            } else {
                assert!(
                    !output.exists(),
                    "validation must precede output creation: {name}"
                );
                results.push(value);
            }
        }
        let validation_case = matches!(
            name,
            "missing-command"
                | "empty-command"
                | "extra-argument"
                | "zero-timeout"
                | "bad-timeout"
                | "nonobject"
        );
        assert_eq!(
            outputs.len(),
            if validation_case { 0 } else { 2 },
            "result kind: {name}"
        );
        for result in &results {
            if validation_case {
                assert!(
                    result["error"]["code"].is_string(),
                    "expected argument error: {name}"
                );
            } else {
                assert_eq!(
                    result["result"]["isError"],
                    matches!(name, "nonzero" | "both-pipes" | "timeout")
                );
            }
        }
        if name == "both-pipes" {
            let expected = ["stderr-one", "stderr-two", "stdout-one", "stdout-two"];
            for (result, raw) in results.iter().zip(&outputs) {
                assert_eq!(result["result"]["isError"], true);
                let preview = text(result).strip_suffix("\nExit code: 7").unwrap();
                assert_eq!(sorted_lines(preview.as_bytes()), expected);
                assert_eq!(sorted_lines(raw), expected);
            }
        } else {
            assert_eq!(results[0], results[1], "source result: {name}");
            if !outputs.is_empty() {
                assert_eq!(outputs[0], outputs[1], "raw output: {name}");
            }
        }
        match name {
            "success" => assert_eq!(text(&results[0]), "hello\n\nExit code: 0"),
            "nonzero" => assert_eq!(text(&results[0]), "failure\nExit code: 7"),
            "small-invalid" => assert_eq!(outputs[0], small_invalid),
            "malformed" => {
                assert_eq!(outputs[0], malformed);
                assert!(text(&results[0]).starts_with(&"\u{fffd}".repeat(32_768)));
                assert!(
                    text(&results[0])
                        .contains("Retained 40000 of 40000 bytes at <retained-output>")
                );
            }
            "boundary" => {
                assert_eq!(outputs[0], boundary);
                assert!(
                    text(&results[0])
                        .starts_with(&format!("{}\u{fffd}\nExit code: 0", "x".repeat(32_767)))
                );
            }
            "held-pipes" => {
                assert_eq!(results[0]["result"]["isError"], false);
                assert!(
                    text(&results[0]).starts_with("held\nExit code: 0\nNote: a background process")
                );
            }
            "timeout" => {
                assert_eq!(results[0]["result"]["isError"], true);
                assert!(text(&results[0]).starts_with("Command timed out after 1 seconds"));
                assert!(text(&results[0]).ends_with("started\nExit code: 9"));
            }
            _ => {}
        }
    }
}
