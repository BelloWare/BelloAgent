use super::*;
use crate::tools::edit::source::Files;
use serde_json::json;
use std::os::unix::fs::{MetadataExt, PermissionsExt};

fn fixture() -> (tempfile::TempDir, FileToolContext) {
    let root = tempfile::tempdir().unwrap();
    let context = FileToolContext {
        cwd: root.path().into(),
        roots: vec![root.path().into()],
        home: root.path().into(),
    };
    (root, context)
}
fn call(context: &FileToolContext, args: Value, edit: bool) -> ToolResult<Value> {
    invoke(context, &args, edit, &CancellationToken::new())
}

#[test]
fn atomic_write_creates_parents_preserves_mode_and_breaks_hardlink_identity() {
    let (root, context) = fixture();
    let path = root.path().join("nested/file");
    let result = call(
        &context,
        json!({"path":"nested/file","content":"a\r\nb\n"}),
        false,
    )
    .unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "a\r\nb\n");
    assert_eq!(result["stats"]["added"], 3);
    assert!(result["stats"].get("line").is_none());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o751)).unwrap();
    let alias = root.path().join("hardlink");
    std::fs::hard_link(&path, &alias).unwrap();
    let inode = std::fs::metadata(&path).unwrap().ino();
    let result = call(
        &context,
        json!({"path":"nested/file","oldText":"b","newText":"B"}),
        true,
    )
    .unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "a\r\nB\n");
    assert_eq!(std::fs::read_to_string(&alias).unwrap(), "a\r\nb\n");
    assert_ne!(std::fs::metadata(&path).unwrap().ino(), inode);
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o751
    );
    assert_eq!(result["stats"]["line"], 2);
    assert_eq!(result["stats"]["lastLine"], 2);
}

#[test]
fn edit_resolves_secondary_root_but_write_keeps_primary_and_symlink_target() {
    let (root, mut context) = fixture();
    let primary = root.path().join("primary");
    let extra = root.path().join("extra");
    std::fs::create_dir(&primary).unwrap();
    std::fs::create_dir(&extra).unwrap();
    context.cwd = primary.clone();
    context.roots = vec![primary.clone(), extra.clone()];
    std::fs::write(extra.join("file"), "old").unwrap();
    call(
        &context,
        json!({"path":"file","oldText":"old","newText":"edited"}),
        true,
    )
    .unwrap();
    assert_eq!(
        std::fs::read_to_string(extra.join("file")).unwrap(),
        "edited"
    );
    call(&context, json!({"path":"file","content":"primary"}), false).unwrap();
    assert_eq!(
        std::fs::read_to_string(primary.join("file")).unwrap(),
        "primary"
    );
    assert_eq!(
        std::fs::read_to_string(extra.join("file")).unwrap(),
        "edited"
    );
    std::os::unix::fs::symlink(extra.join("file"), primary.join("link")).unwrap();
    call(&context, json!({"path":"link","content":"target"}), false).unwrap();
    assert!(primary.join("link").is_symlink());
    assert_eq!(
        std::fs::read_to_string(extra.join("file")).unwrap(),
        "target"
    );
}

#[test]
fn utf8_bom_nontext_and_native_components_match_foundation() {
    let (root, context) = fixture();
    for text in ["é", "e\u{301}", "aaaa", "é\ne\u{301}"] {
        std::fs::write(root.path().join("file"), format!("\u{feff}{text}")).unwrap();
        for old in ["é", "e\u{301}", "aa"] {
            std::fs::write(root.path().join("file"), format!("\u{feff}{text}")).unwrap();
            let native = FoundationFiles {
                context: &context,
                manager: NSFileManager::defaultManager(),
            };
            let decoded = decode_utf8(format!("\u{feff}{text}").as_bytes())
                .unwrap()
                .unwrap();
            let expected = native.replace_once(&decoded, old, "new");
            let actual = call(
                &context,
                json!({"path":"file","oldText":old,"newText":"new"}),
                true,
            );
            match expected {
                Ok(expected) => {
                    actual.unwrap();
                    assert_eq!(
                        std::fs::read_to_string(root.path().join("file")).unwrap(),
                        expected
                    );
                }
                Err(expected) => {
                    assert_eq!(actual.unwrap_err().to_string(), expected.to_string());
                }
            }
        }
    }
    std::fs::write(root.path().join("file"), [255]).unwrap();
    assert_eq!(
        call(
            &context,
            json!({"path":"file","oldText":"a","newText":"b"}),
            true
        )
        .unwrap_err()
        .code(),
        Some("tool_arguments")
    );
    let result = call(&context, json!({"path":"file","content":"text"}), false).unwrap();
    assert_eq!(result["stats"]["removed"], 0);
}
