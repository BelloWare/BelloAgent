//! Bounded regular-file acquisition and source read dispatch. All acquisition
//! happens on the existing file worker. A processor owns native image objects
//! only for the duration of this worker job; no decoder objects cross threads.
use super::{
    FileToolContext, ToolError, ToolResult, check_cancelled, read_image_sniff, read_text,
    result_text,
};
use serde_json::{Value, json};
#[cfg(not(target_os = "macos"))]
use std::{fs::OpenOptions, io::Read, path::Path};
use tokio_util::sync::CancellationToken;

#[cfg(target_os = "macos")]
#[path = "read/macos.rs"]
mod macos;

pub(super) const FILE_BYTES: usize = 16 * 1024 * 1024;

/// A successful omission is a source-visible non-error text result. It is
/// distinct from cancellation and platform unavailability, which remain errors.
#[cfg_attr(not(any(target_os = "macos", test)), allow(dead_code))]
pub(super) enum ImageResult {
    Image {
        data: String,
        mime_type: String,
        hints: Vec<String>,
    },
    Omitted(String),
}

pub(super) fn invoke_with_processor(
    context: &FileToolContext,
    arguments: &Value,
    cancellation: &CancellationToken,
    process: impl FnOnce(&[u8], &str, &CancellationToken) -> ToolResult<ImageResult>,
) -> ToolResult<Value> {
    check_cancelled(cancellation)?;
    // Unlike ls/search, read's path is required even when the JSON key exists.
    if arguments["path"].is_null() {
        return Err(ToolError::failure("invalid_params", "Invalid path"));
    }
    #[cfg(target_os = "macos")]
    let (path, bytes) = macos::acquire(context, arguments)?;
    #[cfg(not(target_os = "macos"))]
    let (path, bytes) = {
        let path = context.path(&arguments["path"])?;
        let bytes = read_bounded(&path)?;
        (path.to_string_lossy().into_owned(), bytes)
    };
    check_cancelled(cancellation)?;
    if let Some(mime_type) = read_image_sniff::sniff(&bytes) {
        let image = process(&bytes, mime_type, cancellation)?;
        check_cancelled(cancellation)?;
        let mut result = match image {
            ImageResult::Image {
                data,
                mime_type,
                hints,
            } => {
                let note = std::iter::once(format!("Read image file [{mime_type}]"))
                    .chain(hints)
                    .collect::<Vec<_>>()
                    .join("\n");
                json!({"content":[{"type":"text","text":note},{"type":"image","data":data,"mimeType":mime_type}],"isError":false})
            }
            ImageResult::Omitted(reason) => {
                result_text(format!("Read image file [{mime_type}]\n{reason}"), false)
            }
        };
        result["stats"] = json!({"path":path.as_str()});
        return Ok(result);
    }
    #[cfg(target_os = "macos")]
    let text = macos::decode_utf8(&bytes);
    #[cfg(not(target_os = "macos"))]
    let text = std::str::from_utf8(&bytes).ok().map(str::to_owned);
    let text = text.ok_or_else(|| ToolError::failure(
        "binary_file", "read accepts UTF-8 text and images (jpg, png, gif, webp, bmp); other binary contents are not decoded",
    ))?;
    read_text::render(&text, &path, arguments)
}

#[cfg(not(target_os = "macos"))]
fn read_bounded(path: &Path) -> ToolResult<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    // Rust's Unix OpenOptions sets CLOEXEC; NONBLOCK prevents FIFO open hangs.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        const O_NONBLOCK: i32 = 0x800;
        #[cfg(target_os = "macos")]
        const O_NONBLOCK: i32 = 0x4;
        options.custom_flags(O_NONBLOCK);
    }
    // Other targets must not silently perform blocking opens of special files.
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    return Err(ToolError::failure(
        "tool_unavailable",
        "Bounded read requires a supported nonblocking file adapter",
    ));
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        let file = options.open(path).map_err(|_| {
            ToolError::failure(
                "file_unavailable",
                format!("Cannot open {}", path.display()),
            )
        })?;
        let metadata = file.metadata().map_err(|_| {
            ToolError::failure("not_regular_file", "Only regular files can be read")
        })?;
        if !metadata.is_file() {
            return Err(ToolError::failure(
                "not_regular_file",
                "Only regular files can be read",
            ));
        }
        if metadata.len() > FILE_BYTES as u64 {
            return Err(ToolError::failure(
                "file_too_large",
                "File exceeds the supported size limit",
            ));
        }
        let mut bytes = Vec::new();
        file.take(FILE_BYTES as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > FILE_BYTES {
            return Err(ToolError::failure(
                "file_too_large",
                "File exceeds the supported size limit",
            ));
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, FileToolContext) {
        let temp = tempfile::tempdir().unwrap();
        let context = FileToolContext {
            cwd: temp.path().into(),
            roots: vec![temp.path().into()],
            home: temp.path().into(),
        };
        (temp, context)
    }
    fn invoke(context: &FileToolContext, args: Value) -> ToolResult<Value> {
        invoke_with_processor(context, &args, &CancellationToken::new(), |_, _, _| {
            panic!("unexpected image")
        })
    }
    #[test]
    fn acquisition_and_binary_errors_precede_bad_paging() {
        let (temp, context) = fixture();
        assert_eq!(
            invoke(&context, json!({"path":"missing","offset":-1}))
                .unwrap_err()
                .code(),
            Some("file_unavailable")
        );
        assert_eq!(
            invoke(&context, json!({"path":".","offset":-1}))
                .unwrap_err()
                .code(),
            Some("not_regular_file")
        );
        std::fs::write(temp.path().join("binary"), [0xff]).unwrap();
        assert_eq!(
            invoke(&context, json!({"path":"binary","offset":-1}))
                .unwrap_err()
                .code(),
            Some("binary_file")
        );
        assert_eq!(
            invoke(&context, json!({"path":null})).unwrap_err().code(),
            Some("invalid_params")
        );
    }
    #[test]
    fn image_processing_precedes_and_ignores_bad_paging() {
        let (temp, context) = fixture();
        std::fs::write(temp.path().join("image"), b"GIF").unwrap();
        let result = invoke_with_processor(
            &context,
            &json!({"path":"image","offset":-1,"limit":0}),
            &CancellationToken::new(),
            |bytes, mime, _| {
                assert_eq!(bytes, b"GIF");
                assert_eq!(mime, "image/gif");
                Ok(ImageResult::Omitted(
                    "[Image omitted: fixture failure.]".into(),
                ))
            },
        )
        .unwrap();
        assert_eq!(result["isError"], false);
        assert_eq!(
            result["content"][0]["text"],
            "Read image file [image/gif]\n[Image omitted: fixture failure.]"
        );
    }
    #[test]
    fn cancellation_after_native_processing_does_not_publish_image() {
        let (temp, context) = fixture();
        std::fs::write(temp.path().join("image"), b"GIF").unwrap();
        let token = CancellationToken::new();
        let result =
            invoke_with_processor(&context, &json!({"path":"image"}), &token, |_, _, token| {
                token.cancel();
                Ok(ImageResult::Image {
                    data: "R0lG".into(),
                    mime_type: "image/gif".into(),
                    hints: vec![],
                })
            });
        assert!(matches!(result, Err(ToolError::Cancelled)));
    }
    #[test]
    fn metadata_bound_rejects_sparse_oversize_file() {
        let (temp, context) = fixture();
        std::fs::File::create(temp.path().join("large"))
            .unwrap()
            .set_len(FILE_BYTES as u64 + 1)
            .unwrap();
        assert_eq!(
            invoke(&context, json!({"path":"large","limit":-1}))
                .unwrap_err()
                .code(),
            Some("file_too_large")
        );
    }
    #[test]
    fn actual_image_content_and_processed_mime_are_preserved() {
        let (temp, context) = fixture();
        std::fs::write(temp.path().join("image"), b"GIF").unwrap();
        let result = invoke_with_processor(
            &context,
            &json!({"path":"image"}),
            &CancellationToken::new(),
            |_, _, _| {
                Ok(ImageResult::Image {
                    data: "YWJj".into(),
                    mime_type: "image/png".into(),
                    hints: vec!["hint".into()],
                })
            },
        )
        .unwrap();
        assert_eq!(
            result["content"],
            json!([{"type":"text","text":"Read image file [image/png]\nhint"},{"type":"image","data":"YWJj","mimeType":"image/png"}])
        );
    }
    #[test]
    #[cfg(unix)]
    fn fifo_open_is_nonblocking_in_bounded_subprocess() {
        const CHILD: &str = "BELLO_READ_FIFO_TEST_CHILD";
        if let Some(path) = std::env::var_os(CHILD) {
            let path = std::path::PathBuf::from(path);
            let root = path.parent().unwrap().to_path_buf();
            let context = FileToolContext {
                cwd: root.clone(),
                roots: vec![root.clone()],
                home: root,
            };
            assert_eq!(
                invoke(&context, json!({"path":path.to_str().unwrap()}))
                    .unwrap_err()
                    .code(),
                Some("not_regular_file")
            );
            return;
        }
        let temp = tempfile::tempdir().unwrap();
        let fifo = temp.path().join("fifo");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let test_name = std::thread::current().name().unwrap().to_owned();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", &test_name, "--nocapture"])
            .env(CHILD, &fifo)
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if std::time::Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("read hung opening a FIFO");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
}
