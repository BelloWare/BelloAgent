//! Swift source decoding through a synchronous, length-delimited Objective-C ABI.
use objc2::{msg_send, rc::autoreleasepool, runtime::AnyClass};

const INPUT_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub(super) enum DecodeError {
    InputLimit,
    MissingClass,
    Contract,
    Allocation,
    InvalidOutput,
}

pub(super) fn decode(bytes: &[u8]) -> Result<Option<String>, DecodeError> {
    if bytes.len() > INPUT_LIMIT {
        return Err(DecodeError::InputLimit);
    }
    autoreleasepool(|_| {
        let class =
            AnyClass::get(c"BelloAgentRustSourceUTF8Decoder").ok_or(DecodeError::MissingClass)?;
        decode_using(bytes.len(), |output, capacity, written| {
            // SAFETY: the public generated ObjC header specifies these exact
            // pointer/NSUInteger/Int32 types. Input is immutable and live, the
            // output is null for a capacity query or has `capacity` writable
            // bytes, and written is a live NSUInteger. Swift retains no pointer.
            unsafe {
                msg_send![class, decodeInput: bytes.as_ptr(), length: bytes.len(),
                    output: output, capacity: capacity, written: written as *mut usize]
            }
        })
    })
}

fn decode_using(
    input_len: usize,
    mut call: impl FnMut(*mut u8, usize, &mut usize) -> i32,
) -> Result<Option<String>, DecodeError> {
    let maximum = input_len
        .checked_mul(3)
        .filter(|_| input_len <= INPUT_LIMIT)
        .ok_or(DecodeError::InputLimit)?;
    let mut required = usize::MAX;
    match call(std::ptr::null_mut(), 0, &mut required) {
        1 if required == 0 => return Ok(None),
        0 if required == 0 => return Ok(Some(String::new())),
        2 if required > 0 && required <= maximum => {}
        _ => return Err(DecodeError::Contract),
    }
    let mut bytes = Vec::<u8>::new();
    bytes
        .try_reserve_exact(required)
        .map_err(|_| DecodeError::Allocation)?;
    bytes.resize(required, 0);
    let mut written = usize::MAX;
    if call(bytes.as_mut_ptr(), required, &mut written) != 0 || written != required {
        // Partial output is discarded without conversion or exposure to callers.
        return Err(DecodeError::Contract);
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| DecodeError::InvalidOutput)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cases() -> Vec<(&'static str, Vec<u8>)> {
        vec![
            ("empty", vec![]),
            ("bom", vec![0xef, 0xbb, 0xbf]),
            ("single", "\u{feff}needle".as_bytes().to_vec()),
            ("double", "\u{feff}\u{feff}needle".as_bytes().to_vec()),
            ("interior", "a\u{feff}needle".as_bytes().to_vec()),
            ("nul", "\u{feff}\0a".as_bytes().to_vec()),
            ("invalid", vec![0xef, 0xbb, 0xbf, 0xff]),
            ("truncated", vec![0xe2, 0x82]),
            ("overlong", vec![0xc0, 0x80]),
            ("surrogate", vec![0xed, 0xa0, 0x80]),
            ("unicode", "\u{feff}é e\u{301} 🦀\r\n".as_bytes().to_vec()),
            ("bom15", format!("\u{feff}{}", "a".repeat(12)).into_bytes()),
            ("bom16", format!("\u{feff}{}", "a".repeat(13)).into_bytes()),
            ("bom32", format!("\u{feff}{}", "a".repeat(29)).into_bytes()),
        ]
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// The bundle runner compares this exact compiled adapter to a separately
    /// compiled source oracle. This test itself assumes no host BOM policy.
    #[test]
    fn bundle_receipt() {
        let rows: Vec<_> = cases()
            .into_iter()
            .map(|(name, input)| {
                let output = decode(&input).expect("linked source decoder");
                json!({"case":name,"input":hex(&input),"output":output.map(|s|hex(s.as_bytes()))})
            })
            .collect();
        println!(
            "BELLO_UTF8_RECEIPT:{}",
            serde_json::to_string(&rows).unwrap()
        );
    }

    #[test]
    fn pointer_capacity_and_invalid_input_never_write_partial_output() {
        let class = AnyClass::get(c"BelloAgentRustSourceUTF8Decoder").unwrap();
        let mut output = [0xa5u8; 8];
        for (input, len, capacity, status, count) in [
            (b"a".as_ptr(), 1usize, 0usize, 2i32, 1usize),
            (b"\xff".as_ptr(), 1, 8, 1, 0),
            (std::ptr::null(), 1, 8, 3, 0),
            (std::ptr::null(), INPUT_LIMIT + 1, 8, 3, 0),
            (std::ptr::null(), 0, 8, 0, 0),
        ] {
            let mut written = usize::MAX;
            // SAFETY: invalid/null inputs are rejected before dereference; all
            // otherwise accepted input/output ranges are the live arrays above.
            let actual: i32 = unsafe {
                msg_send![class, decodeInput: input, length: len,
                    output: output.as_mut_ptr(), capacity: capacity,
                    written: &mut written as *mut usize]
            };
            assert_eq!((actual, written), (status, count));
            assert_eq!(output, [0xa5; 8]);
        }
    }

    #[test]
    fn contract_failure_cannot_become_binary_rejection_or_partial_text() {
        for bad_status in [1, 2, 3, -1] {
            let result = decode_using(1, |output, _, written| {
                *written = 1;
                if output.is_null() {
                    2
                } else {
                    // SAFETY: decode_using owns at least one writable byte.
                    unsafe { output.write(b'a') };
                    bad_status
                }
            });
            assert_eq!(result, Err(DecodeError::Contract));
        }
        assert_eq!(
            decode_using(1, |_, _, length| {
                *length = 4;
                2
            }),
            Err(DecodeError::Contract)
        );
        assert_eq!(
            decode_using(1, |_, _, length| {
                *length = 1;
                1
            }),
            Err(DecodeError::Contract)
        );
        assert_eq!(
            decode_using(1, |output, _, length| {
                *length = 1;
                if output.is_null() {
                    2
                } else {
                    // SAFETY: the callback receives one writable output byte.
                    unsafe { output.write(0xff) };
                    0
                }
            }),
            Err(DecodeError::InvalidOutput)
        );
    }

    #[test]
    fn maximum_input_is_bounded_before_bridge_call() {
        let bytes = vec![b'a'; INPUT_LIMIT];
        assert_eq!(decode(&bytes).unwrap().unwrap().as_bytes(), bytes);
        assert_eq!(
            decode_using(INPUT_LIMIT + 1, |_, _, _| panic!("oversize reached Swift")),
            Err(DecodeError::InputLimit)
        );
    }
}
