//! Synthetic native file/UTF-8 checks. Full file source remains authoritative.
use super::*;
use crate::tools::read::invoke_with_processor;
use serde_json::json;
use tokio_util::sync::CancellationToken;

#[test]
fn foundation_bom_and_invalid_utf8_are_preserved_as_native_semantics() {
    let temp = tempfile::tempdir().unwrap();
    let context = FileToolContext {
        cwd: temp.path().into(),
        roots: vec![temp.path().into()],
        home: temp.path().into(),
    };
    for bytes in [
        b"\xef\xbb\xbfa\n".as_slice(),
        b"a\r\nb\rc\n".as_slice(),
        b"\xff\xfe".as_slice(),
    ] {
        std::fs::write(temp.path().join("input"), bytes).unwrap();
        let expected = decode_utf8(bytes).unwrap();
        let result = invoke_with_processor(
            &context,
            &json!({"path":"input"}),
            &CancellationToken::new(),
            |_, _, _| panic!("unexpected image"),
        );
        if let Some(expected) = expected {
            let result = result.unwrap();
            assert_eq!(result["content"][0]["text"], expected);
        } else {
            assert_eq!(result.unwrap_err().code(), Some("binary_file"));
        }
    }
}

#[test]
fn foundation_resolves_unique_extra_root_and_source_regular_file_error() {
    let temp = tempfile::tempdir().unwrap();
    let first = temp.path().join("first");
    let second = temp.path().join("second");
    std::fs::create_dir(&first).unwrap();
    std::fs::create_dir(&second).unwrap();
    std::fs::write(second.join("only"), "extra-root").unwrap();
    let context = FileToolContext {
        cwd: first.clone(),
        roots: vec![first, second.clone()],
        home: temp.path().into(),
    };
    let result = invoke_with_processor(
        &context,
        &json!({"path":"only"}),
        &CancellationToken::new(),
        |_, _, _| panic!("unexpected image"),
    )
    .unwrap();
    assert_eq!(result["content"][0]["text"], "extra-root");
    assert_eq!(
        std::path::Path::new(result["stats"]["path"].as_str().unwrap())
            .canonicalize()
            .unwrap(),
        second.join("only").canonicalize().unwrap()
    );
    assert_eq!(
        acquire(&context, &json!({"path":"."})).unwrap_err().code(),
        Some("not_regular_file")
    );
}
