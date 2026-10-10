//! The selection record and loadImages are extracted from immutable checked-in
//! Swift source, alongside the existing full PiImage native oracle.
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn bounded(command: &mut Command, directory: &Path) -> Vec<u8> {
    use std::os::unix::process::CommandExt;
    let out = directory.join("stdout");
    let err = directory.join("stderr");
    command
        .stdin(Stdio::null())
        .stdout(std::fs::File::create(&out).unwrap())
        .stderr(std::fs::File::create(&err).unwrap())
        .process_group(0);
    let mut child = command.spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(
                status.success(),
                "Swift attachment oracle failed: {}",
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
            panic!("Swift attachment oracle timed out");
        }
        thread::sleep(Duration::from_millis(20));
    }
}
fn section<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
    let (_, tail) = source.split_once(start).unwrap();
    let end = tail.find(end).unwrap();
    // Include the start marker exactly; source range is a contiguous behavior body.
    let offset = source.len() - tail.len() - start.len();
    &source[offset..offset + start.len() + end]
}
fn oracle(paths: &[String]) -> Value {
    let selection = include_str!("../../../../apps/macos/PiApp/Composer/Attachments.swift");
    let support = include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Support.swift");
    let tools = include_str!("../../../../packages/swift-host/Sources/PiAgentCore/Tools.swift");
    let mut code = String::from("import Foundation\nimport Darwin\nimport CryptoKit\n");
    code.push_str(include_str!(
        "../../../../packages/swift-host/Sources/PiAgentCore/JSON.swift"
    ));
    code.push_str("\ntypealias WireValue=JSON\nenum HostError: Error { case failure(String) }\nstruct AgentError: Error { let code:String;let message:String;init(_ code:String,_ message:String){self.code=code;self.message=message} }\nenum JSONByteParser {static func parse(_ bytes:Data)throws->JSON{try JSONDecoder().decode(JSON.self,from:bytes)}}\nfunc textBlock(_ text:String)->JSON{[\"type\":\"text\",\"text\":JSON(text)]}\n");
    code.push_str(selection.split_once("extension WorkspaceModel").unwrap().0);
    code.push_str(section(support, "func required(", "/// Letters"));
    code.push_str(section(support, "func boundedInt(", "func nowMS"));
    code.push_str(section(
        support,
        "func canonical(",
        "/// System-accelerated",
    ));
    code.push_str(section(
        support,
        "public func sha256(",
        "/// Kept available",
    ));
    code.push_str(include_str!(
        "../../../../packages/swift-host/Sources/PiAgentCore/PiImage.swift"
    ));
    code.push_str("\nfunc loadImages");
    code.push_str(tools.split_once("func loadImages").unwrap().1);
    code.push_str(r#"
let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let results:[JSON]=paths.map { path in
    do {
        let record=try AttachmentRecord.inspect(URL(fileURLWithPath:path))
        var value=record.wire;value["id"] = .null
        do {return ["record":value,"content":.array(try loadImages([record.wire]))]}
        catch let error as AgentError {return ["record":value,"deliveryError":JSON(error.code)]}
        catch {return ["record":value,"deliveryError":"other"]}
    } catch {return ["selectionError":true]}
}
FileHandle.standardOutput.write(try JSON.array(results).data())
"#);
    let d = tempfile::tempdir().unwrap();
    let src = d.path().join("main.swift");
    let exe = d.path().join("attachment-oracle");
    let input = d.path().join("input.json");
    fs::write(&src, code).unwrap();
    fs::write(&input, serde_json::to_vec(paths).unwrap()).unwrap();
    bounded(
        Command::new("/usr/bin/xcrun")
            .args(["swiftc", "-swift-version", "5", "-module-cache-path"])
            .arg(d.path().join("cache"))
            .arg(src)
            .arg("-o")
            .arg(&exe),
        d.path(),
    );
    serde_json::from_slice(&bounded(Command::new(exe).arg(input), d.path())).unwrap()
}
#[test]
fn selected_metadata_and_ordered_loaded_images_match_checked_in_swift() {
    let d = tempfile::tempdir().unwrap();
    let cases=[
        ("fixture.gif",STANDARD.decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==").unwrap()),
        ("fixture.webp",STANDARD.decode("UklGRkgAAABXRUJQVlA4TDsAAAAvAkAAAC9AEEBS/hLDDLHNGgTZNuMaxPw1TnAFbdswLcNCeONPYfMf8A95yKSeZSAQoIwVD3wS0f8YLwA=").unwrap()),
        ("loose.gif",b"GIF8xx".to_vec()),("truncated.png",b"\x89PNG\r\n\x1a\n".to_vec()),
        ("empty.png",vec![]),("text.png",b"ordinary text".to_vec()),
    ];
    let mut paths: Vec<_> = cases
        .iter()
        .map(|(name, bytes)| {
            let path = d.path().join(name);
            fs::write(&path, bytes).unwrap();
            path.to_str().unwrap().to_owned()
        })
        .collect();
    // Exercise source symlink resolution, including a distinct same-byte file:
    // canonical path comparison must not become content-only equivalence.
    let duplicate = d.path().join("same-bytes.gif");
    fs::copy(&paths[0], &duplicate).unwrap();
    paths.push(duplicate.to_str().unwrap().to_owned());
    let alias = d.path().join("alias.gif");
    std::os::unix::fs::symlink(&paths[0], &alias).unwrap();
    paths.push(alias.to_str().unwrap().to_owned());
    let expected = oracle(&paths);
    for (index, path) in paths.iter().enumerate() {
        match AttachmentRecord::inspect(Path::new(path)) {
            Err(_) => assert_eq!(expected[index]["selectionError"], true),
            Ok(record) => {
                let mut metadata = serde_json::to_value(&record).unwrap();
                metadata["id"] = Value::Null;
                let mut expected_metadata = expected[index]["record"].clone();
                // Foundation may preserve Darwin's /var spelling while Rust
                // resolves it to /private/var. Require the same existing target,
                // rather than deleting the path assertion or rewriting prefixes.
                expected_metadata["path"] = json!(
                    Path::new(expected_metadata["path"].as_str().unwrap())
                        .canonicalize()
                        .unwrap()
                        .to_str()
                        .unwrap()
                );
                assert_eq!(metadata, expected_metadata);
                let loaded = load(
                    &[record],
                    &CancellationToken::new(),
                    crate::tools::attachment_images::process,
                );
                if let Ok(blocks) = loaded {
                    assert_eq!(
                        serde_json::to_value(blocks).unwrap(),
                        expected[index]["content"]
                    );
                } else {
                    assert_eq!(
                        expected[index]["deliveryError"],
                        json!("invalid_attachment")
                    );
                }
            }
        }
    }
}
