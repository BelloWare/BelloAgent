//! PiImage.swift's inline-image adapter. Native objects never leave the read
//! worker; the public result contains only owned Rust bytes/strings.
//!
//! Bounded deviation from Swift: image metadata must describe at most 16 Mi
//! pixels before any full-frame decode (64 MiB at RGBA8). This is a pixel budget,
//! not a whole-process or native allocation cap: decoder/color-space storage,
//! copied input, conversion output and framework allocations are additional.
//! Synchronous ImageIO/CoreGraphics work is not forcibly interruptible; every
//! stage checks cancellation before and after and discards late results.

#[cfg(not(target_os = "macos"))]
use super::ToolError;
use super::{ToolResult, check_cancelled, read::ImageResult};
use tokio_util::sync::CancellationToken;

#[cfg(target_os = "macos")]
#[path = "read_image/macos.rs"]
mod macos;

pub(super) fn process(
    bytes: &[u8],
    mime_type: &str,
    cancellation: &CancellationToken,
) -> ToolResult<ImageResult> {
    check_cancelled(cancellation)?;
    #[cfg(target_os = "macos")]
    {
        macos::process(bytes, mime_type, cancellation)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (bytes, mime_type);
        Err(ToolError::failure(
            "tool_unavailable",
            "Native read image processing requires macOS",
        ))
    }
}

#[cfg(any(target_os = "macos", test))]
mod policy {
    pub(super) const MAX_AXIS: usize = 2000;
    pub(super) const MAX_BYTES: usize = 4_718_592;
    pub(super) const MAX_DECODED_PIXELS: usize = 16 * 1024 * 1024;
    pub(super) const QUALITIES: [u8; 5] = [80, 85, 70, 55, 40];
    pub(super) const RESIZE_FAILURE: &str =
        "[Image omitted: could not be resized below the inline image size limit.]";
    pub(super) const CONVERSION_FAILURE: &str =
        "[Image omitted: could not be converted to a supported inline image format.]";

    pub(super) fn fits(byte_count: usize, byte_limit: usize) -> bool {
        byte_count
            .checked_add(2)
            .and_then(|n| n.checked_div(3))
            .and_then(|n| n.checked_mul(4))
            .is_some_and(|n| n < byte_limit)
    }

    pub(super) fn checked_size(width: i64, height: i64) -> Option<(usize, usize)> {
        let width = usize::try_from(width).ok()?;
        let height = usize::try_from(height).ok()?;
        let pixels = width.checked_mul(height)?;
        (width > 0 && height > 0 && pixels <= MAX_DECODED_PIXELS).then_some((width, height))
    }

    pub(super) fn target_size(mut width: usize, mut height: usize) -> (usize, usize) {
        // Inputs passed the pixel bound, so products are exact in f64 and usize.
        // Swift rounds positive halfway values away from zero, as Rust round does.
        if width > MAX_AXIS {
            height = ((height * MAX_AXIS) as f64 / width as f64).round() as usize;
            width = MAX_AXIS;
        }
        if height > MAX_AXIS {
            width = ((width * MAX_AXIS) as f64 / height as f64).round() as usize;
            height = MAX_AXIS;
        }
        (width.max(1), height.max(1))
    }

    pub(super) fn next_size(width: usize, height: usize) -> Option<(usize, usize)> {
        if width == 1 && height == 1 {
            return None;
        }
        Some(((width * 3 / 4).max(1), (height * 3 / 4).max(1)))
    }

    pub(super) fn resize_hint(original: (usize, usize), displayed: (usize, usize)) -> String {
        let scale = original.0 as f64 / displayed.0 as f64;
        format!(
            "[Image: original {}x{}, displayed at {}x{}. Multiply coordinates by {scale:.2} to map to original image.]",
            original.0, original.1, displayed.0, displayed.1
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{policy::*, *};

    #[test]
    fn strict_base64_limit_and_overflow() {
        assert!(fits(MAX_BYTES / 4 * 3 - 3, MAX_BYTES));
        for count in MAX_BYTES / 4 * 3 - 2..=MAX_BYTES / 4 * 3 {
            assert!(!fits(count, MAX_BYTES));
        }
        assert!(!fits(usize::MAX, MAX_BYTES));
        assert!(fits(0, MAX_BYTES));
    }

    #[test]
    fn predecode_budget_checks_zero_negative_and_overflow() {
        assert_eq!(checked_size(4096, 4096), Some((4096, 4096)));
        assert_eq!(checked_size(4097, 4096), None);
        assert_eq!(checked_size(0, 1), None);
        assert_eq!(checked_size(-1, 1), None);
        assert_eq!(checked_size(i64::MAX, i64::MAX), None);
    }

    #[test]
    fn swift_rounding_sequential_axes_and_quarter_shrink() {
        assert_eq!(target_size(4000, 2001), (2000, 1001));
        assert_eq!(target_size(3000, 4000), (1500, 2000));
        assert_eq!(target_size(16000, 1), (2000, 1));
        assert_eq!(next_size(2000, 1001), Some((1500, 750)));
        assert_eq!(next_size(1, 2), Some((1, 1)));
        assert_eq!(next_size(1, 1), None);
        assert_eq!(QUALITIES, [80, 85, 70, 55, 40]);
        assert_eq!(
            resize_hint((3000, 4000), (1500, 2000)),
            "[Image: original 3000x4000, displayed at 1500x2000. Multiply coordinates by 2.00 to map to original image.]"
        );
        assert!(RESIZE_FAILURE.contains("resized"));
        assert!(CONVERSION_FAILURE.contains("converted"));
    }

    #[test]
    fn cancellation_precedes_native_or_platform_work() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        assert!(matches!(
            process(b"GIF", "image/gif", &cancellation),
            Err(super::super::ToolError::Cancelled)
        ));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn unsupported_platform_never_substitutes_a_different_resampler() {
        let error = process(b"GIF", "image/gif", &CancellationToken::new())
            .err()
            .unwrap();
        assert_eq!(error.code(), Some("tool_unavailable"));
    }
}
