//! Test-only Linux temporary-file adapter. This is never compiled into a library
//! without cfg(test), never offered by production constructors, and makes no
//! Foundation Unicode/path/atomic-write claim. End-to-end fixtures use ASCII.
use super::{FileToolContext, ToolError, ToolResult, source};
use serde_json::Value;
use std::{io::Write, path::PathBuf};
use tokio_util::sync::CancellationToken;

pub(in crate::tools) fn invoke(
    context: &FileToolContext,
    args: &Value,
    editing: bool,
    cancel: &CancellationToken,
) -> ToolResult<Value> {
    source::execute(&mut TemporaryFiles(context), args, editing, cancel)
}
struct TemporaryFiles<'a>(&'a FileToolContext);
impl source::Files for TemporaryFiles<'_> {
    type Path = PathBuf;
    fn resolve(&mut self, value: &Value, existing: bool) -> ToolResult<PathBuf> {
        if value.is_null() {
            return Err(ToolError::failure("invalid_params", "Invalid path"));
        }
        let mut context = self.0.clone();
        if !existing {
            context.roots.truncate(1);
        }
        context.path(value)
    }
    fn path(&self, path: &PathBuf) -> String {
        path.to_string_lossy().into_owned()
    }
    fn read_text(&mut self, path: &PathBuf) -> ToolResult<Option<String>> {
        let bytes = crate::tools::read::read_bounded(path)?;
        Ok(String::from_utf8(bytes).ok())
    }
    fn replace_once(&self, text: &str, old: &str, new: &str) -> ToolResult<String> {
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
    fn write(&mut self, path: &PathBuf, content: &str) -> ToolResult<bool> {
        let parent = path.parent().unwrap();
        std::fs::create_dir_all(parent)?;
        let attributes = std::fs::metadata(path).ok();
        let mut pending = tempfile::NamedTempFile::new_in(parent)?;
        pending.write_all(content.as_bytes())?;
        pending.persist(path).map_err(|error| error.error)?;
        if let Some(attributes) = &attributes {
            std::fs::set_permissions(path, attributes.permissions())?;
        }
        Ok(attributes.is_some())
    }
}
