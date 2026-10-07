//! PiImage.swift sniff's first-4,100-byte recognition, not decoder validation.
//! In particular, malformed GIF/JPEG data may be recognized and subsequently
//! produce the source's explicit image-omission result rather than binary_file.

pub(super) fn sniff(bytes: &[u8]) -> Option<&'static str> {
    let b = &bytes[..bytes.len().min(4_100)];
    let ascii = |offset: usize, text: &[u8]| b.get(offset..offset + text.len()) == Some(text);
    let u16le = |o: usize| {
        b.get(o..o + 2)
            .map_or(0, |v| u16::from_le_bytes(v.try_into().unwrap()) as u64)
    };
    let u32le = |o: usize| {
        b.get(o..o + 4)
            .map_or(0, |v| u32::from_le_bytes(v.try_into().unwrap()) as u64)
    };
    let u32be = |o: usize| {
        b.get(o..o + 4)
            .map_or(0, |v| u32::from_be_bytes(v.try_into().unwrap()) as u64)
    };
    if b.starts_with(&[0xff, 0xd8, 0xff]) {
        return if b.get(3) == Some(&0xf7) {
            None
        } else {
            Some("image/jpeg")
        };
    }
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        if b.len() < 16 || u32be(8) != 13 || !ascii(12, b"IHDR") {
            return None;
        }
        let mut offset = 8;
        while offset + 8 <= b.len() {
            if ascii(offset + 4, b"acTL") {
                return None;
            }
            if ascii(offset + 4, b"IDAT") {
                break;
            }
            let next = offset as u64 + 12 + u32be(offset);
            if next <= offset as u64 || next > b.len() as u64 {
                break;
            }
            offset = next as usize;
        }
        return Some("image/png");
    }
    if ascii(0, b"GIF") {
        return Some("image/gif");
    }
    if ascii(0, b"RIFF") && ascii(8, b"WEBP") {
        return Some("image/webp");
    }
    if ascii(0, b"BM") && b.len() >= 26 {
        let size = u32le(2);
        let pixels = u32le(10);
        let header = u32le(14);
        if (size != 0 && size < 26) || pixels < 14 + header || (size != 0 && pixels >= size) {
            return None;
        }
        let (planes, bits) = if header == 12 {
            (u16le(22), u16le(24))
        } else if (40..=124).contains(&header) && b.len() >= 30 {
            (u16le(26), u16le(28))
        } else {
            return None;
        };
        return if planes == 1 && [1, 4, 8, 16, 24, 32].contains(&bits) {
            Some("image/bmp")
        } else {
            None
        };
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_recognition_is_not_extension_or_decode_validation() {
        for (bytes, expected) in [
            (&b"GIF"[..], Some("image/gif")),
            (&b"GIF89a"[..], Some("image/gif")),
            (&b"RIFF1234WEBP"[..], Some("image/webp")),
            (&[0xff, 0xd8, 0xff][..], Some("image/jpeg")),
            (&[0xff, 0xd8, 0xff, 0xf7][..], None),
            (&b"not an image"[..], None),
        ] {
            assert_eq!(sniff(bytes), expected);
        }
    }
    fn png() -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        bytes.extend_from_slice(&13u32.to_be_bytes());
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&[0; 17]);
        bytes
    }
    #[test]
    fn png_actl_before_idat_is_rejected_but_after_idat_is_not_examined() {
        let mut bytes = png();
        assert_eq!(sniff(&bytes), Some("image/png"));
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes.extend_from_slice(b"acTL");
        assert_eq!(sniff(&bytes), None);
        bytes[37..41].copy_from_slice(b"IDAT");
        bytes.extend_from_slice(&[0; 4]);
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes.extend_from_slice(b"acTL");
        assert_eq!(sniff(&bytes), Some("image/png"));
        bytes[8..12].copy_from_slice(&12u32.to_be_bytes());
        assert_eq!(sniff(&bytes), None);
    }
    #[test]
    fn bmp_header_planes_bits_and_offsets_match_source() {
        let mut bytes = vec![0; 30];
        bytes[..2].copy_from_slice(b"BM");
        bytes[10..14].copy_from_slice(&54u32.to_le_bytes());
        bytes[14..18].copy_from_slice(&40u32.to_le_bytes());
        bytes[26..28].copy_from_slice(&1u16.to_le_bytes());
        bytes[28..30].copy_from_slice(&24u16.to_le_bytes());
        assert_eq!(sniff(&bytes), Some("image/bmp"));
        bytes[2..6].copy_from_slice(&54u32.to_le_bytes());
        assert_eq!(sniff(&bytes), None);
        bytes[2..6].copy_from_slice(&55u32.to_le_bytes());
        assert_eq!(sniff(&bytes), Some("image/bmp"));
        bytes[26] = 2;
        assert_eq!(sniff(&bytes), None);
    }
}
