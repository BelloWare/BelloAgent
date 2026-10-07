use super::{source::*, *};
use std::cell::RefCell;

struct Fixture {
    events: RefCell<Vec<&'static str>>,
    previous: Option<String>,
    missing: bool,
    exists: bool,
    after_read_cancel: Option<CancellationToken>,
    written: Option<String>,
    write_failure: bool,
}
impl Default for Fixture {
    fn default() -> Self {
        Self {
            events: RefCell::new(vec![]),
            previous: Some("old\n".into()),
            missing: false,
            exists: true,
            after_read_cancel: None,
            written: None,
            write_failure: false,
        }
    }
}
impl Files for Fixture {
    type Path = String;
    fn resolve(&mut self, value: &Value, existing: bool) -> ToolResult<String> {
        self.events.borrow_mut().push(if existing {
            "resolve-existing"
        } else {
            "resolve-primary"
        });
        value
            .as_str()
            .filter(|p| !p.is_empty() && p.len() <= 4096)
            .map(str::to_owned)
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid path"))
    }
    fn path(&self, path: &String) -> String {
        path.clone()
    }
    fn read_text(&mut self, _: &String) -> ToolResult<Option<String>> {
        self.events.borrow_mut().push("read");
        if let Some(cancel) = &self.after_read_cancel {
            cancel.cancel();
        }
        if self.missing {
            return Err(ToolError::failure(
                "file_unavailable",
                "Cannot open fixture",
            ));
        }
        Ok(self.previous.clone())
    }
    fn replace_once(&self, text: &str, old: &str, new: &str) -> ToolResult<String> {
        self.events.borrow_mut().push("replace");
        let parts: Vec<_> = text.split(old).collect();
        if parts.len() != 2 {
            return Err(ToolError::failure(
                "edit_match",
                format!(
                    "oldText must match exactly once; found {} matches",
                    parts.len() - 1
                ),
            ));
        }
        Ok(format!("{}{new}{}", parts[0], parts[1]))
    }
    fn write(&mut self, _: &String, text: &str) -> ToolResult<bool> {
        self.events.borrow_mut().extend([
            "parents",
            "attributes",
            "atomic-write",
            "restore-permissions",
        ]);
        self.written = Some(text.into());
        if self.write_failure {
            return Err(ToolError::Io(std::io::Error::other(
                "permission restore failed",
            )));
        }
        Ok(self.exists)
    }
}
fn run(f: &mut Fixture, arguments: Value, edit: bool) -> ToolResult<Value> {
    execute(f, &arguments, edit, &CancellationToken::new())
}

#[test]
fn source_error_and_side_effect_order() {
    let mut f = Fixture::default();
    assert_eq!(
        run(&mut f, json!({"path":null,"content":false}), false)
            .unwrap_err()
            .code(),
        Some("invalid_params")
    );
    assert_eq!(*f.events.borrow(), ["resolve-primary"]);
    f.events.borrow_mut().clear();
    assert_eq!(
        run(&mut f, json!({"path":"x","content":false}), false)
            .unwrap_err()
            .code(),
        Some("tool_arguments")
    );
    assert_eq!(*f.events.borrow(), ["resolve-primary"]);
    f.events.borrow_mut().clear();
    assert_eq!(
        run(
            &mut f,
            json!({"path":"x","oldText":"old","newText":null}),
            true
        )
        .unwrap_err()
        .code(),
        Some("tool_arguments")
    );
    assert_eq!(*f.events.borrow(), ["resolve-existing"]);
    f.events.borrow_mut().clear();
    f.missing = true;
    assert_eq!(
        run(
            &mut f,
            json!({"path":"x","oldText":"old","newText":"new"}),
            true
        )
        .unwrap_err()
        .code(),
        Some("file_unavailable")
    );
    assert!(f.written.is_none());
    let result = run(&mut f, json!({"path":"x","content":"new"}), false).unwrap();
    assert_eq!(result["stats"]["added"], 1);
    assert_eq!(result["stats"]["removed"], 0);
    assert_eq!(f.written.as_deref(), Some("new"));
}
#[test]
fn ambiguous_missing_and_empty_old_never_mutate() {
    for (text, old, code, matches) in [
        ("aa", "a", "edit_match", "2"),
        ("aa", "b", "edit_match", "0"),
        ("aa", "", "invalid_params", ""),
    ] {
        let mut f = Fixture {
            previous: Some(text.into()),
            ..Fixture::default()
        };
        let error = run(&mut f, json!({"path":"x","oldText":old,"newText":""}), true).unwrap_err();
        assert_eq!(error.code(), Some(code));
        assert!(error.to_string().contains(matches));
        assert!(f.written.is_none());
    }
}
#[test]
fn byte_limits_are_inclusive_and_final_edit_can_exceed_read_bound() {
    let mut f = Fixture::default();
    assert!(
        run(
            &mut f,
            json!({"path":"x","content":"x".repeat(FILE_BYTES)}),
            false
        )
        .is_ok()
    );
    assert!(
        run(
            &mut f,
            json!({"path":"x","content":"x".repeat(FILE_BYTES+1)}),
            false
        )
        .is_err()
    );
    f.previous = Some(format!("{}!", "x".repeat(FILE_BYTES - 1)));
    assert!(
        run(
            &mut f,
            json!({"path":"x","oldText":"!","newText":"y".repeat(EDIT_BYTES)}),
            true
        )
        .is_ok()
    );
    assert_eq!(
        f.written.as_ref().unwrap().len(),
        FILE_BYTES - 1 + EDIT_BYTES
    );
}
#[test]
fn cancellation_before_mutation_and_postwrite_failure_are_distinct() {
    let token = CancellationToken::new();
    let mut f = Fixture {
        after_read_cancel: Some(token.clone()),
        ..Fixture::default()
    };
    assert!(matches!(
        execute(&mut f, &json!({"path":"x","content":"new"}), false, &token),
        Err(ToolError::Cancelled)
    ));
    assert!(f.written.is_none());
    let mut f = Fixture {
        write_failure: true,
        ..Fixture::default()
    };
    assert!(run(&mut f, json!({"path":"x","content":"new"}), false).is_err());
    assert_eq!(f.written.as_deref(), Some("new"));
}
#[test]
fn source_stats_unicode_line_endings_deletion_and_noop() {
    assert_eq!(line_diff_stats("", "a\n"), (2, 0));
    assert_eq!(line_diff_stats("é\nx", "e\u{301}\ny"), (1, 1));
    assert_eq!(changed_lines("same", "same"), None);
    assert_eq!(changed_lines("a\r\nb\rc\n", "a\r\nB\rC\n"), Some((2, 3)));
    assert_eq!(changed_lines("a\nb\nc", "a\nc"), Some((2, 2)));
    assert_eq!(changed_lines("abc", ""), Some((1, 1)));
    assert_eq!(changed_lines("a", "a\n"), Some((1, 1)));
    let mut f = Fixture {
        exists: false,
        ..Fixture::default()
    };
    assert!(
        run(&mut f, json!({"path":"x","content":"new"}), false).unwrap()["stats"]
            .get("line")
            .is_none()
    );
    f.exists = true;
    assert_eq!(
        run(&mut f, json!({"path":"x","content":"old\n"}), false).unwrap()["stats"],
        json!({"path":"x","added":0,"removed":0})
    );
}
