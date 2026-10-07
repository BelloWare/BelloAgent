//! Picker metadata and bounded attachment acquisition. Metadata can survive file
//! deletion; selection, acceptance and delivery read/recheck files.
//! No image bytes belong in a catalog draft.
use crate::{Error, Result, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Read,
    path::Path,
};
use tokio_util::sync::CancellationToken;

pub const MAX_ATTACHMENTS: usize = 4;
pub const MAX_FILE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_TOTAL_BYTES: usize = 16 * 1024 * 1024;
/// Failed Send may restore four captured selections ahead of four newer ones.
/// Such a draft stays recoverable/removable but cannot be submitted unchanged.
pub const MAX_RECOVERED_ATTACHMENTS: usize = 8;
pub const IMAGES_UNSUPPORTED: &str = "Selected model does not declare image support";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttachmentRecord {
    pub id: String,
    pub path: String,
    pub sha256: String,
    pub bytes: usize,
    pub mime_type: String,
}
impl AttachmentRecord {
    /// Selection has its own deliberately loose GIF8 recognition, unlike delivery.
    pub fn inspect(path: &Path) -> Result<Self> {
        let cancel = CancellationToken::new();
        let canonical = fs::canonicalize(path)?;
        let path = canonical
            .to_str()
            .ok_or_else(|| invalid("Image path is not UTF-8"))?;
        let data = acquire(&canonical, &cancel)?;
        let mime_type = signature(&data, false)
            .ok_or_else(|| invalid("Supported image formats are PNG, JPEG, GIF and WebP"))?;
        let record = Self {
            id: uuid::Uuid::new_v4().to_string(),
            path: path.into(),
            sha256: digest(&data),
            bytes: data.len(),
            mime_type: mime_type.into(),
        };
        record.validate()?;
        Ok(record)
    }
    pub fn validate(&self) -> Result<()> {
        if uuid::Uuid::parse_str(&self.id).is_err()
            || !Path::new(&self.path).is_absolute()
            || self.path.len() > 65_536
            || self.path.contains('\0')
            || self.bytes == 0
            || self.bytes > MAX_FILE_BYTES
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !["image/png", "image/jpeg", "image/gif", "image/webp"]
                .contains(&self.mime_type.as_str())
        {
            return Err(invalid("Invalid retained image attachment metadata"));
        }
        Ok(())
    }
    pub fn filename(&self) -> &str {
        Path::new(&self.path)
            .file_name()
            .and_then(|p| p.to_str())
            .unwrap_or(&self.path)
    }
}

pub fn validate_selection(records: &[AttachmentRecord]) -> Result<()> {
    validate_records(records, MAX_ATTACHMENTS)?;
    if records.iter().map(|r| r.bytes).sum::<usize>() > MAX_TOTAL_BYTES {
        return Err(invalid(
            "A submission supports four images and 16 MiB in total",
        ));
    }
    Ok(())
}
pub fn validate_draft(records: &[AttachmentRecord]) -> Result<()> {
    validate_records(records, MAX_RECOVERED_ATTACHMENTS)
}
fn validate_records(records: &[AttachmentRecord], maximum: usize) -> Result<()> {
    if records.len() > maximum {
        return Err(invalid("Too many retained image attachments"));
    }
    let mut ids = std::collections::HashSet::new();
    for record in records {
        record.validate()?;
        if !ids.insert(&record.id) {
            return Err(invalid("Duplicate image attachment identity"));
        }
    }
    Ok(())
}
/// Source restoration deduplicates complete records, not paths or hashes.
pub fn restore(
    captured: &[AttachmentRecord],
    newer: &[AttachmentRecord],
) -> Result<Vec<AttachmentRecord>> {
    let mut records = captured.to_vec();
    records.extend(
        newer
            .iter()
            .filter(|record| !captured.contains(record))
            .cloned(),
    );
    validate_draft(&records)?;
    Ok(records)
}

pub(crate) fn cancelled(cancel: &CancellationToken) -> Result<()> {
    if cancel.is_cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
/// A descriptor prevents path replacement from changing the file being read.
/// Metadata is checked both on the descriptor and final canonical path.
fn acquire(path: &Path, cancel: &CancellationToken) -> Result<Vec<u8>> {
    cancelled(cancel)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        const O_NONBLOCK: i32 = 0x800;
        #[cfg(target_os = "macos")]
        const O_NONBLOCK: i32 = 0x4;
        // std opens Unix descriptors CLOEXEC. NONBLOCK rejects a FIFO promptly.
        options.custom_flags(O_NONBLOCK);
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    return Err(invalid(
        "Image acquisition requires a supported nonblocking file adapter",
    ));
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        let mut file = options.open(path)?;
        let before = file.metadata()?;
        if !before.is_file() || before.len() == 0 || before.len() > MAX_FILE_BYTES as u64 {
            return Err(invalid("Select a regular image file up to 8 MiB"));
        }
        let mut result = Vec::with_capacity(before.len() as usize);
        let mut chunk = [0u8; 65_536];
        loop {
            cancelled(cancel)?;
            let maximum = (before.len() as usize + 1 - result.len()).min(chunk.len());
            let count = file.read(&mut chunk[..maximum])?;
            if count == 0 {
                break;
            }
            if count > (before.len() as usize).saturating_sub(result.len()) {
                return Err(invalid("Image changed during selection"));
            }
            result.extend_from_slice(&chunk[..count]);
        }
        let after = file.metadata()?;
        let current = fs::metadata(path)?;
        use std::os::unix::fs::MetadataExt;
        let unchanged = |m: &std::fs::Metadata| {
            m.is_file()
                && m.len() == before.len()
                && m.modified().ok() == before.modified().ok()
                && m.dev() == before.dev()
                && m.ino() == before.ino()
        };
        if result.len() != before.len() as usize || !unchanged(&after) || !unchanged(&current) {
            return Err(invalid("Image changed; select it again"));
        }
        cancelled(cancel)?;
        Ok(result)
    }
}
fn digest(data: &[u8]) -> String {
    let mut hash = Sha256::new();
    for chunk in data.chunks(65_536) {
        hash.update(chunk);
    }
    format!("{:x}", hash.finalize())
}
fn signature(data: &[u8], strict: bool) -> Option<&'static str> {
    let b = &data[..data.len().min(12)];
    if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if b.starts_with(&[255, 216, 255]) {
        Some("image/jpeg")
    } else if (!strict && b.starts_with(b"GIF8"))
        || b.starts_with(b"GIF87a")
        || b.starts_with(b"GIF89a")
    {
        Some("image/gif")
    } else if b.len() == 12 && &b[..4] == b"RIFF" && &b[8..] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

pub(crate) fn load(
    records: &[AttachmentRecord],
    cancel: &CancellationToken,
    mut process: impl FnMut(
        &[u8],
        &str,
        &CancellationToken,
    ) -> Result<Vec<crate::tool_content::ContentBlock>>,
) -> Result<Vec<crate::tool_content::ContentBlock>> {
    validate_selection(records)?;
    let mut blocks = Vec::new();
    for record in records {
        cancelled(cancel)?;
        let path = fs::canonicalize(&record.path)?;
        let bytes = acquire(&path, cancel)?;
        if bytes.len() != record.bytes || digest(&bytes) != record.sha256 {
            return Err(invalid("Selected image changed; select it again"));
        }
        let mime = signature(&bytes, true).ok_or_else(|| invalid("Unsupported image signature"))?;
        if mime != record.mime_type {
            return Err(invalid("MIME type and image signature differ"));
        }
        blocks.extend(process(&bytes, mime, cancel)?);
        cancelled(cancel)?;
    }
    Ok(blocks)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_gif_prefix_is_deliberately_looser_than_delivery() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("loose.gif");
        fs::write(&path, b"GIF8xx").unwrap();
        let record = AttachmentRecord::inspect(&path).unwrap();
        assert_eq!(record.mime_type, "image/gif");
        assert!(
            load(&[record], &CancellationToken::new(), |_, _, _| panic!(
                "must reject signature"
            ))
            .is_err()
        );
    }
    #[test]
    fn changed_missing_empty_directory_and_limits_are_rejected() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("image.png");
        for bytes in [&b""[..], &b"not an image"[..]] {
            fs::write(&path, bytes).unwrap();
            assert!(AttachmentRecord::inspect(&path).is_err());
        }
        assert!(AttachmentRecord::inspect(d.path()).is_err());
        fs::write(&path, b"\x89PNG\r\n\x1a\noriginal").unwrap();
        let record = AttachmentRecord::inspect(&path).unwrap();
        fs::write(&path, b"\x89PNG\r\n\x1a\nchanged!").unwrap();
        assert!(
            load(
                std::slice::from_ref(&record),
                &CancellationToken::new(),
                |_, _, _| panic!("digest must fail")
            )
            .is_err()
        );
        fs::remove_file(path).unwrap();
        assert!(
            load(&[record], &CancellationToken::new(), |_, _, _| panic!(
                "missing must fail"
            ))
            .is_err()
        );
    }
    #[test]
    fn cancelled_inspection_delivery_never_calls_processor() {
        let cancel = CancellationToken::new();
        cancel.cancel();
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("image.gif");
        fs::write(&path, b"GIF89a").unwrap();
        let record = AttachmentRecord::inspect(&path).unwrap();
        assert!(matches!(
            load(&[record], &cancel, |_, _, _| panic!("cancelled")),
            Err(Error::Cancelled)
        ));
    }
}

#[cfg(all(test, target_os = "macos"))]
#[path = "attachment_native_tests.rs"]
mod native_tests;

#[cfg(test)]
mod bounds_tests {
    use super::*;
    #[test]
    fn inclusive_file_count_total_bounds_and_recoverable_eight_image_draft() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("large.png");
        let mut bytes = vec![0; MAX_FILE_BYTES];
        bytes[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        fs::write(&path, &bytes).unwrap();
        let first = AttachmentRecord::inspect(&path).unwrap();
        assert_eq!(first.bytes, MAX_FILE_BYTES);
        bytes.push(0);
        fs::write(&path, &bytes).unwrap();
        assert!(AttachmentRecord::inspect(&path).is_err());
        let make = |n: usize, size: usize| -> Vec<_> {
            (0..n)
                .map(|_| AttachmentRecord {
                    id: uuid::Uuid::new_v4().to_string(),
                    bytes: size,
                    ..first.clone()
                })
                .collect()
        };
        assert!(validate_selection(&make(2, MAX_FILE_BYTES)).is_ok());
        assert!(validate_selection(&make(3, MAX_FILE_BYTES)).is_err());
        assert!(validate_selection(&make(4, 1)).is_ok());
        assert!(validate_selection(&make(5, 1)).is_err());
        let older = make(4, MAX_FILE_BYTES / 2);
        let newer = make(4, MAX_FILE_BYTES / 2);
        let restored = restore(&older, &newer).unwrap();
        assert_eq!(restored.len(), 8);
        assert!(validate_selection(&restored).is_err());
        assert_eq!(&restored[..4], &older);
        assert_eq!(restore(&older, &older).unwrap(), older);
    }
    #[test]
    #[cfg(unix)]
    fn canonical_selection_is_symlink_resolved_and_retargeting_cannot_change_record() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("a.gif");
        let b = d.path().join("b.gif");
        let link = d.path().join("link.gif");
        fs::write(&a, b"GIF89a-first").unwrap();
        fs::write(&b, b"GIF89a-other").unwrap();
        std::os::unix::fs::symlink(&a, &link).unwrap();
        let record = AttachmentRecord::inspect(&link).unwrap();
        assert_eq!(Path::new(&record.path), a.canonicalize().unwrap());
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&b, &link).unwrap();
        let blocks = load(&[record], &CancellationToken::new(), |bytes, _, _| {
            assert_eq!(bytes, b"GIF89a-first");
            Ok(vec![])
        })
        .unwrap();
        assert!(blocks.is_empty());
    }
    #[test]
    #[cfg(unix)]
    fn fifo_is_rejected_in_a_bounded_child() {
        const CHILD: &str = "BELLO_ATTACHMENT_FIFO_CHILD";
        if let Some(path) = std::env::var_os(CHILD) {
            assert!(AttachmentRecord::inspect(Path::new(&path)).is_err());
            return;
        }
        let d = tempfile::tempdir().unwrap();
        let fifo = d.path().join("image.gif");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let test = std::thread::current().name().unwrap().to_owned();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", &test, "--nocapture"])
            .env(CHILD, &fifo)
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if std::time::Instant::now() > end {
                let _ = child.kill();
                let _ = child.wait();
                panic!("FIFO image acquisition blocked");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
}
