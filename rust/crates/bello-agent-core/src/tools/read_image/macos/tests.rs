//! Synthetic images only. The oracle compiles the checked-in Swift PiImage
//! implementation, without its unrelated JSON normalization extension.
use super::*;
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn result_json(result: ImageResult) -> Value {
    match result {
        ImageResult::Image {
            data,
            mime_type,
            hints,
        } => json!({"data":data,"mimeType":mime_type,"hints":hints}),
        ImageResult::Omitted(message) => json!({"omitted":message}),
    }
}

// A minimal uncompressed 24-bit BMP with asymmetric deterministic pixels; no
// fixture depends on a third-party codec, input file, display or permission.
fn bmp(width: u32, height: u32, noise: bool) -> Vec<u8> {
    let stride = (width as usize * 3 + 3) & !3;
    let total = 54 + stride * height as usize;
    let mut bytes = vec![0; total];
    bytes[..2].copy_from_slice(b"BM");
    bytes[2..6].copy_from_slice(&(total as u32).to_le_bytes());
    bytes[10..14].copy_from_slice(&54_u32.to_le_bytes());
    bytes[14..18].copy_from_slice(&40_u32.to_le_bytes());
    bytes[18..22].copy_from_slice(&width.to_le_bytes());
    bytes[22..26].copy_from_slice(&height.to_le_bytes());
    bytes[26..28].copy_from_slice(&1_u16.to_le_bytes());
    bytes[28..30].copy_from_slice(&24_u16.to_le_bytes());
    let mut seed = 0xa572_39bd_u32;
    for y in 0..height as usize {
        for x in 0..width as usize {
            let pixel = &mut bytes[54 + y * stride + x * 3..][..3];
            if noise {
                for channel in pixel {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    *channel = seed as u8;
                }
            } else {
                pixel.copy_from_slice(&[
                    (x % 251) as u8,
                    (y % 241) as u8,
                    ((x / 13 + y / 7) % 239) as u8,
                ]);
            }
        }
    }
    bytes
}

fn converted(bytes: &[u8], format: &str, orientation: Option<i64>) -> Vec<u8> {
    let token = CancellationToken::new();
    let source = source(bytes, &token).unwrap().unwrap();
    let size = size(&source, &token).unwrap().unwrap();
    let image = oriented(&source, size, &token).unwrap().unwrap();
    let data = CFMutableData::new(None, 0).unwrap();
    let kind = CFString::from_str(format);
    let destination = unsafe { CGImageDestination::with_data(&data, &kind, 1, None) }.unwrap();
    let options = orientation.map(|orientation| {
        let number = CFNumber::new_i64(orientation);
        CFDictionary::<CFString, CFType>::from_slices(
            &[unsafe { kCGImagePropertyOrientation }],
            &[&number],
        )
    });
    unsafe {
        destination.add_image(&image, options.as_ref().map(|options| options.as_opaque()));
        assert!(destination.finalize());
    }
    data.to_vec()
}

fn animated_gif(width: u32, height: u32) -> Vec<u8> {
    let token = CancellationToken::new();
    let output = CFMutableData::new(None, 0).unwrap();
    let format = CFString::from_str("com.compuserve.gif");
    let destination = unsafe { CGImageDestination::with_data(&output, &format, 2, None) }.unwrap();
    for noise in [false, true] {
        let bytes = bmp(width, height, noise);
        let source = source(&bytes, &token).unwrap().unwrap();
        let dimensions = size(&source, &token).unwrap().unwrap();
        let image = oriented(&source, dimensions, &token).unwrap().unwrap();
        unsafe {
            destination.add_image(&image, None);
        }
    }
    assert!(unsafe { destination.finalize() });
    let bytes = output.to_vec();
    let source = source(&bytes, &token).unwrap().unwrap();
    assert_eq!(unsafe { source.count() }, 2);
    bytes
}

fn bounded_command(command: &mut Command, directory: &Path, limit: Duration) -> Vec<u8> {
    let stdout = directory.join("stdout");
    let stderr = directory.join("stderr");
    command
        .stdin(Stdio::null())
        .stdout(File::create(&stdout).unwrap())
        .stderr(File::create(&stderr).unwrap())
        .process_group(0);
    let mut child = command
        .spawn()
        .expect("Apple image oracle process must start");
    let deadline = Instant::now() + limit;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            // This child owns a fresh process group; kill compiler descendants
            // as well as the direct child rather than leave native work behind.
            if let Ok(group) = i32::try_from(child.id()) {
                unsafe {
                    libc::kill(-group, libc::SIGKILL);
                }
            }
            let _ = child.kill();
            let _ = child.wait();
            panic!("Apple image oracle exceeded {limit:?}");
        }
        thread::sleep(Duration::from_millis(20));
    };
    if !status.success()
        && let Ok(group) = i32::try_from(child.id())
    {
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
    assert!(
        status.success(),
        "Apple image oracle failed: {}",
        fs::read_to_string(stderr).unwrap()
    );
    fs::read(stdout).unwrap()
}

fn swift_oracle(cases: &[Value]) -> Value {
    // Include the actual behavior source rather than a hand-copied Swift oracle.
    let swift =
        include_str!("../../../../../../../packages/swift-host/Sources/PiAgentCore/PiImage.swift");
    let marker = "    /// normalizeToolResultImages:";
    assert_eq!(swift.matches(marker).count(), 1);
    let mut swift = swift.split_once(marker).unwrap().0.to_owned();
    // The test-only limit seam exercises the otherwise hard-to-reach JPEG
    // quality/quarter-shrink paths. The default remains the source constant.
    assert_eq!(swift.matches("static let maxBytes = 4_718_592").count(), 1);
    swift = swift.replace(
        "static let maxBytes = 4_718_592",
        "static var maxBytes = 4_718_592",
    );
    swift.push_str("}\n");
    swift.push_str(r#"
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let results: [[String: Any]] = cases.map { item in
    PiImage.maxBytes = item["byteLimit"] as? Int ?? 4_718_592
    let bytes = Data(base64Encoded: item["data"] as! String)!
    switch PiImage.process(bytes, mimeType: item["mimeType"] as! String) {
    case .success(let image): return ["data": image.data, "mimeType": image.mimeType, "hints": image.hints]
    case .failure(let failure): return ["omitted": failure.message]
    }
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
"#);
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("main.swift");
    let executable = directory.path().join("image-oracle");
    let input = directory.path().join("input.json");
    fs::write(&source, swift).unwrap();
    fs::write(&input, serde_json::to_vec(cases).unwrap()).unwrap();
    let mut compile = Command::new("/usr/bin/xcrun");
    compile
        .args(["swiftc", "-swift-version", "5", "-module-cache-path"])
        .arg(directory.path().join("module-cache"))
        .arg(source)
        .arg("-o")
        .arg(&executable);
    bounded_command(&mut compile, directory.path(), Duration::from_secs(120));
    let mut run = Command::new(executable);
    run.arg(input);
    serde_json::from_slice(&bounded_command(
        &mut run,
        directory.path(),
        Duration::from_secs(120),
    ))
    .unwrap()
}

#[test]
fn native_pipeline_matches_checked_in_swift_image_oracle() {
    let mut fixtures = vec![
        ("image/gif", b"GIF".to_vec()),
        ("image/jpeg", vec![0xff, 0xd8, 0xff, 0xe0]),
        ("image/bmp", bmp(7, 5, false)),
        ("image/bmp", bmp(2001, 33, false)),
        ("image/bmp", bmp(31, 2001, false)),
        // A synthetic 3×2 RGB lossless WebP (generated once with libwebp).
        ("image/webp", STANDARD.decode("UklGRkgAAABXRUJQVlA4TDsAAAAvAkAAAC9AEEBS/hLDDLHNGgTZNuMaxPw1TnAFbdswLcNCeONPYfMf8A95yKSeZSAQoIwVD3wS0f8YLwA=").unwrap()),
    ];
    fixtures.push(("image/gif", animated_gif(17, 11)));
    fixtures.push(("image/gif", animated_gif(2001, 31)));
    let small = bmp(11, 7, false);
    for (mime, format) in [
        ("image/png", "public.png"),
        ("image/jpeg", "public.jpeg"),
        ("image/gif", "com.compuserve.gif"),
    ] {
        fixtures.push((mime, converted(&small, format, None)));
    }
    // All EXIF orientations, swapped axes and a non-square resize.
    let large = bmp(2001, 73, false);
    for orientation in 1..=8 {
        fixtures.push((
            "image/jpeg",
            converted(&large, "public.jpeg", Some(orientation)),
        ));
    }
    // Oversized noisy PNG forces the PNG→JPEG candidate selection at 2000².
    let noisy = bmp(2000, 2000, true);
    fixtures.push(("image/png", converted(&noisy, "public.png", None)));
    // Byte limit can trigger resampling without changing displayed dimensions.
    let mut padded = converted(&small, "public.png", None);
    padded.resize(MAX_BYTES / 4 * 3, 0);
    fixtures.push(("image/png", padded));
    let mut requests: Vec<Value> = fixtures
        .iter()
        .map(|(mime, bytes)| json!({"data":STANDARD.encode(bytes),"mimeType":mime}))
        .collect();
    let probe = converted(&bmp(200, 200, true), "public.png", None);
    let token = CancellationToken::new();
    let source = source(&probe, &token).unwrap().unwrap();
    let dimensions = size(&source, &token).unwrap().unwrap();
    let image = oriented(&source, dimensions, &token).unwrap().unwrap();
    let mut forced_encodings = Vec::new();
    for quality in [80, 70, 55, 40] {
        let encoding = encode(&image, Some(quality), &token).unwrap().unwrap();
        let limit = STANDARD.encode(&encoding).len() + 1;
        // Prove this synthetic input rejects every earlier source candidate.
        for earlier in std::iter::once(None).chain(QUALITIES.into_iter().map(Some)) {
            if earlier == Some(quality) {
                break;
            }
            let bytes = encode(&image, earlier, &token).unwrap().unwrap();
            assert!(!fits(bytes.len(), limit));
        }
        forced_encodings.push((requests.len(), STANDARD.encode(encoding)));
        requests
            .push(json!({"data":STANDARD.encode(&probe),"mimeType":"image/png","byteLimit":limit}));
    }
    // Force several quarter-size iterations, then complete exhaustion at 1×1.
    requests.push(json!({"data":STANDARD.encode(&probe),"mimeType":"image/png","byteLimit":2_048}));
    requests.push(json!({"data":STANDARD.encode(&probe),"mimeType":"image/png","byteLimit":1}));
    let expected = swift_oracle(&requests);
    for (index, request) in requests.iter().enumerate() {
        let bytes = STANDARD.decode(request["data"].as_str().unwrap()).unwrap();
        let mime = request["mimeType"].as_str().unwrap();
        let limit = request["byteLimit"]
            .as_u64()
            .map(|n| n as usize)
            .unwrap_or(MAX_BYTES);
        let actual = result_json(
            autoreleasepool(|_| process_in_pool(&bytes, mime, &CancellationToken::new(), limit))
                .unwrap(),
        );
        // Avoid printing multi-megabyte data or weakening exact byte equality.
        assert_eq!(
            actual["mimeType"], expected[index]["mimeType"],
            "fixture {index}"
        );
        assert_eq!(actual["hints"], expected[index]["hints"], "fixture {index}");
        assert_eq!(
            actual["omitted"], expected[index]["omitted"],
            "fixture {index}"
        );
        assert!(
            actual["data"] == expected[index]["data"],
            "encoded bytes differ for fixture {index} ({mime})"
        );
        if let Some(encoded) = actual["data"].as_str() {
            assert!(encoded.len() < limit);
        }
        if let Some((_, bytes)) = forced_encodings
            .iter()
            .find(|(fixture, _)| *fixture == index)
        {
            assert!(
                actual["data"].as_str() == Some(bytes),
                "candidate order changed for fixture {index}"
            );
        }
    }
}

#[test]
fn supported_under_limit_data_is_preserved_byte_for_byte() {
    let bytes = converted(&bmp(9, 13, false), "public.jpeg", Some(6));
    let output = result_json(process(&bytes, "image/jpg", &CancellationToken::new()).unwrap());
    assert_eq!(output["data"], STANDARD.encode(&bytes));
    assert_eq!(output["mimeType"], "image/jpeg");
    assert_eq!(output["hints"], json!([]));
    let bytes = animated_gif(17, 11);
    let output = result_json(process(&bytes, "image/gif", &CancellationToken::new()).unwrap());
    assert_eq!(output["data"], STANDARD.encode(&bytes));
    assert_eq!(output["mimeType"], "image/gif");
    assert_eq!(output["hints"], json!([]));
}

#[test]
fn metadata_budget_rejects_bomb_before_full_decode() {
    let mut bytes = bmp(1, 1, false);
    bytes[18..22].copy_from_slice(&100_000_u32.to_le_bytes());
    bytes[22..26].copy_from_slice(&100_000_u32.to_le_bytes());
    let token = CancellationToken::new();
    // A mere omission would also pass if ImageIO rejected this intentionally
    // truncated file before reaching our guard. Require readable, excessive
    // native metadata first, then prove our checked size rejects that metadata.
    let source = source(&bytes, &token)
        .unwrap()
        .expect("ImageIO must expose the synthetic BMP header");
    assert!(unsafe { source.count() } > 0);
    let properties = unsafe { source.properties_at_index(0, None) }
        .expect("ImageIO must expose the synthetic BMP dimensions");
    assert_eq!(
        number(&properties, unsafe { kCGImagePropertyPixelWidth }),
        Some(100_000)
    );
    assert_eq!(
        number(&properties, unsafe { kCGImagePropertyPixelHeight }),
        Some(100_000)
    );
    assert!(size(&source, &token).unwrap().is_none());
    // process_in_pool requires this validated Size before calling oriented(),
    // so the over-budget metadata cannot reach the full-frame thumbnail decode.
    let output = result_json(process(&bytes, "image/bmp", &token).unwrap());
    assert_eq!(output, json!({"omitted":CONVERSION_FAILURE}));
}

#[test]
fn cancellation_after_synchronous_stage_drops_its_result() {
    use std::cell::Cell;
    struct Owner<'a>(&'a Cell<bool>);
    impl Drop for Owner<'_> {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }
    let token = CancellationToken::new();
    let dropped = Cell::new(false);
    let result = stage(&token, || {
        token.cancel();
        Owner(&dropped)
    });
    assert!(matches!(result, Err(crate::tools::ToolError::Cancelled)));
    assert!(dropped.get());
    let called = Cell::new(false);
    let _ = stage(&token, || called.set(true));
    assert!(!called.get());
}
