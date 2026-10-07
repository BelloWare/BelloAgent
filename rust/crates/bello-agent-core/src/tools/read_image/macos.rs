//! Source-exact ImageIO thumbnail orientation and CoreGraphics High resampling.
//! No portable image implementation is substituted for Apple's pixel pipeline.

use super::{ImageResult, ToolResult, check_cancelled, policy::*};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use objc2::rc::autoreleasepool;
use objc2_core_foundation::{
    CFBoolean, CFData, CFDictionary, CFMutableData, CFNumber, CFRetained, CFString, CFType,
    CGPoint, CGRect, CGSize,
};
use objc2_core_graphics::{
    CGBitmapContextCreate, CGBitmapContextCreateImage, CGColorSpace, CGContext, CGImage,
    CGImageAlphaInfo, CGInterpolationQuality, kCGColorSpaceSRGB,
};
use objc2_image_io::{
    CGImageDestination, CGImageSource, kCGImageDestinationLossyCompressionQuality,
    kCGImagePropertyOrientation, kCGImagePropertyPixelHeight, kCGImagePropertyPixelWidth,
    kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform,
    kCGImageSourceShouldCacheImmediately, kCGImageSourceThumbnailMaxPixelSize,
};
use std::ptr;
use tokio_util::sync::CancellationToken;

fn stage<T>(token: &CancellationToken, operation: impl FnOnce() -> T) -> ToolResult<T> {
    check_cancelled(token)?;
    let result = operation();
    check_cancelled(token)?;
    Ok(result)
}

#[derive(Clone, Copy)]
struct Size {
    raw: (usize, usize),
    upright: (usize, usize),
}

fn number(properties: &CFDictionary, key: &CFString) -> Option<i64> {
    // ImageIO property dictionaries contain CFString keys and CFType values.
    // A runtime CFNumber downcast avoids assuming a malformed value's type.
    let properties = unsafe { properties.cast_unchecked::<CFString, CFType>() };
    properties.get(key)?.downcast::<CFNumber>().ok()?.as_i64()
}

fn source(
    bytes: &[u8],
    token: &CancellationToken,
) -> ToolResult<Option<CFRetained<CGImageSource>>> {
    let Some(len) = isize::try_from(bytes.len()).ok() else {
        return Ok(None);
    };
    // CFDataCreate copies the input; no borrowed Rust buffer/callback escapes.
    let Some(data) = stage(token, || unsafe { CFData::new(None, bytes.as_ptr(), len) })? else {
        return Ok(None);
    };
    stage(token, || unsafe { CGImageSource::with_data(&data, None) })
}

fn size(source: &CGImageSource, token: &CancellationToken) -> ToolResult<Option<Size>> {
    if stage(token, || unsafe { source.count() })? == 0 {
        return Ok(None);
    }
    let Some(properties) = stage(token, || unsafe { source.properties_at_index(0, None) })? else {
        return Ok(None);
    };
    let result = (|| {
        let (width, height) = checked_size(
            number(&properties, unsafe { kCGImagePropertyPixelWidth })?,
            number(&properties, unsafe { kCGImagePropertyPixelHeight })?,
        )?;
        let orientation = number(&properties, unsafe { kCGImagePropertyOrientation }).unwrap_or(1);
        Some(Size {
            raw: (width, height),
            upright: if (5..=8).contains(&orientation) {
                (height, width)
            } else {
                (width, height)
            },
        })
    })();
    check_cancelled(token)?;
    Ok(result)
}

fn oriented(
    source: &CGImageSource,
    size: Size,
    token: &CancellationToken,
) -> ToolResult<Option<CFRetained<CGImage>>> {
    let maximum = CFNumber::new_i64(size.raw.0.max(size.raw.1) as i64);
    let yes = CFBoolean::new(true);
    let options = CFDictionary::<CFString, CFType>::from_slices(
        &unsafe {
            [
                kCGImageSourceCreateThumbnailFromImageAlways,
                kCGImageSourceCreateThumbnailWithTransform,
                kCGImageSourceThumbnailMaxPixelSize,
                kCGImageSourceShouldCacheImmediately,
            ]
        },
        &[yes, yes, &maximum, yes],
    );
    let image = stage(token, || unsafe {
        source.thumbnail_at_index(0, Some(options.as_opaque()))
    })?;
    // Do not allow a decoder's unexpected dimensions past the metadata budget.
    Ok(image.filter(|image| {
        let width = CGImage::width(Some(image));
        let height = CGImage::height(Some(image));
        (width, height) == size.upright
            && width
                .checked_mul(height)
                .is_some_and(|pixels| pixels <= MAX_DECODED_PIXELS)
    }))
}

fn scale(
    image: &CFRetained<CGImage>,
    target: (usize, usize),
    token: &CancellationToken,
) -> ToolResult<Option<CFRetained<CGImage>>> {
    check_cancelled(token)?;
    if (CGImage::width(Some(image)), CGImage::height(Some(image))) == target {
        return Ok(Some(image.clone()));
    }
    let Some(color) = stage(token, || {
        CGColorSpace::with_name(Some(unsafe { kCGColorSpaceSRGB }))
            .or_else(CGColorSpace::new_device_rgb)
    })?
    else {
        return Ok(None);
    };
    let Some(context) = stage(token, || unsafe {
        CGBitmapContextCreate(
            ptr::null_mut(),
            target.0,
            target.1,
            8,
            0,
            Some(&color),
            CGImageAlphaInfo::PremultipliedLast.0,
        )
    })?
    else {
        return Ok(None);
    };
    let context = Some(&*context);
    stage(token, || {
        CGContext::set_interpolation_quality(context, CGInterpolationQuality::High)
    })?;
    stage(token, || {
        CGContext::draw_image(
            context,
            CGRect {
                origin: CGPoint { x: 0., y: 0. },
                size: CGSize {
                    width: target.0 as f64,
                    height: target.1 as f64,
                },
            },
            Some(image),
        )
    })?;
    stage(token, || CGBitmapContextCreateImage(context))
}

fn encode(
    image: &CGImage,
    quality: Option<u8>,
    token: &CancellationToken,
) -> ToolResult<Option<Vec<u8>>> {
    let Some(output) = stage(token, || CFMutableData::new(None, 0))? else {
        return Ok(None);
    };
    // The fixed identifiers are UTType.png.identifier / UTType.jpeg.identifier.
    let format = CFString::from_str(if quality.is_some() {
        "public.jpeg"
    } else {
        "public.png"
    });
    let Some(destination) = stage(token, || unsafe {
        CGImageDestination::with_data(&output, &format, 1, None)
    })?
    else {
        return Ok(None);
    };
    let options = if let Some(quality) = quality {
        let value = CFNumber::new_f64(f64::from(quality) / 100.);
        CFDictionary::<CFString, CFType>::from_slices(
            &[unsafe { kCGImageDestinationLossyCompressionQuality }],
            &[&value],
        )
    } else {
        CFDictionary::<CFString, CFType>::empty()
    };
    stage(token, || unsafe {
        destination.add_image(image, Some(options.as_opaque()))
    })?;
    if !stage(token, || unsafe { destination.finalize() })? {
        return Ok(None);
    }
    // Finalize is finished. No writer mutates this CFData during its owned copy.
    stage(token, || Some(output.to_vec()))
}

pub(super) fn process(
    bytes: &[u8],
    mime_type: &str,
    token: &CancellationToken,
) -> ToolResult<ImageResult> {
    autoreleasepool(|_| process_in_pool(bytes, mime_type, token, MAX_BYTES))
}

fn process_in_pool(
    bytes: &[u8],
    mime_type: &str,
    token: &CancellationToken,
    byte_limit: usize,
) -> ToolResult<ImageResult> {
    check_cancelled(token)?;
    let base = mime_type
        .split(';')
        .next()
        .unwrap_or(mime_type)
        .trim_matches(char::is_whitespace)
        .to_lowercase();
    let supported = matches!(
        base.as_str(),
        "image/png" | "image/gif" | "image/webp" | "image/jpeg" | "image/jpg"
    );
    let failure = if supported {
        RESIZE_FAILURE
    } else {
        CONVERSION_FAILURE
    };
    let omitted = || ImageResult::Omitted(failure.into());
    let Some(original_source) = source(bytes, token)? else {
        return Ok(omitted());
    };
    let Some(original_size) = size(&original_source, token)? else {
        return Ok(omitted());
    };
    let converted;
    let (bytes, mime, conversion) = if supported {
        (
            bytes,
            if base == "image/jpg" {
                "image/jpeg"
            } else {
                base.as_str()
            },
            None,
        )
    } else {
        let Some(image) = oriented(&original_source, original_size, token)? else {
            return Ok(omitted());
        };
        let Some(png) = encode(&image, None, token)? else {
            return Ok(omitted());
        };
        converted = png;
        (converted.as_slice(), "image/png", Some(base.as_str()))
    };
    // Swift re-reads metadata after conversion, which removes EXIF orientation.
    let Some(source) = source(bytes, token)? else {
        return Ok(ImageResult::Omitted(RESIZE_FAILURE.into()));
    };
    let Some(size) = size(&source, token)? else {
        return Ok(ImageResult::Omitted(RESIZE_FAILURE.into()));
    };
    let original = size.upright;
    if original.0 <= MAX_AXIS && original.1 <= MAX_AXIS && fits(bytes.len(), byte_limit) {
        return finish(bytes, mime, conversion, original, None, token);
    }
    let Some(image) = oriented(&source, size, token)? else {
        return Ok(ImageResult::Omitted(RESIZE_FAILURE.into()));
    };
    let mut target = target_size(original.0, original.1);
    loop {
        if let Some(scaled) = scale(&image, target, token)? {
            for quality in std::iter::once(None).chain(QUALITIES.into_iter().map(Some)) {
                if let Some(encoded) = encode(&scaled, quality, token)?
                    && fits(encoded.len(), byte_limit)
                {
                    return finish(
                        &encoded,
                        if quality.is_some() {
                            "image/jpeg"
                        } else {
                            "image/png"
                        },
                        conversion,
                        original,
                        Some(target),
                        token,
                    );
                }
            }
        }
        let Some(next) = next_size(target.0, target.1) else {
            return Ok(ImageResult::Omitted(RESIZE_FAILURE.into()));
        };
        target = next;
        check_cancelled(token)?;
    }
}

fn finish(
    bytes: &[u8],
    mime: &str,
    conversion: Option<&str>,
    original: (usize, usize),
    resized: Option<(usize, usize)>,
    token: &CancellationToken,
) -> ToolResult<ImageResult> {
    let mut hints = Vec::new();
    if let Some(from) = conversion.filter(|from| *from != mime) {
        hints.push(format!("[Image converted from {from} to {mime}.]"));
    }
    if let Some(displayed) = resized {
        hints.push(resize_hint(original, displayed));
    }
    let data = stage(token, || STANDARD.encode(bytes))?;
    Ok(ImageResult::Image {
        data,
        mime_type: mime.into(),
        hints,
    })
}

#[cfg(test)]
#[path = "macos/tests.rs"]
mod tests;
