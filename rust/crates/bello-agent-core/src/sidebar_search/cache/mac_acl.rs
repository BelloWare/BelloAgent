//! Darwin extended-security admission through the official libc fgetattrlist
//! binding. Format constants/layout come from Apple's bsd/sys/kauth.h and
//! bsd/vfs/vfs_attrlist.c; no handwritten external function declarations.
use super::{CacheError, Result};

/// Accept absent ACLs or deny-only ACLs. Deny-only entries cannot expand access;
/// this permits macOS's normal home-directory delete-denial ACL. All allow/audit/
/// unknown entries, malformed/truncated buffers and unsupported reads fail closed.
fn admit(bytes: &[u8]) -> Result<()> {
    fn number(bytes: &[u8], offset: usize) -> Result<u32> {
        let value: [u8; 4] = bytes
            .get(offset..offset + 4)
            .ok_or(CacheError::UnsafeLocation)?
            .try_into()
            .map_err(|_| CacheError::UnsafeLocation)?;
        Ok(u32::from_ne_bytes(value))
    }
    let size = number(bytes, 0)? as usize;
    if !(12..=bytes.len()).contains(&size) {
        return Err(CacheError::UnsafeLocation);
    }
    let offset = number(bytes, 4)? as i32;
    let length = number(bytes, 8)? as usize;
    // Exactly one requested variable attribute: fixed u32 length + reference,
    // followed immediately by its payload. Apple's pack_variable2 uses offset8
    // even for absent ACLs. Native receipts must confirm this before acceptance.
    if offset != 8
        || size
            != 12usize
                .checked_add(length)
                .ok_or(CacheError::UnsafeLocation)?
    {
        return Err(CacheError::UnsafeLocation);
    }
    if length == 0 {
        return Ok(());
    }
    let start = 12usize;
    let end = size;
    if length < 44 {
        return Err(CacheError::UnsafeLocation);
    }
    let acl = &bytes[start..end];
    if number(acl, 0)? != 0x012cc16d {
        return Err(CacheError::UnsafeLocation);
    }
    // Private low16 + DEFER_INHERIT/NO_INHERIT are documented header flags.
    if number(acl, 40)? & !0x0003_ffff != 0 || acl[4..36].iter().any(|b| *b != 0) {
        return Err(CacheError::UnsafeLocation);
    }
    let count = number(acl, 36)?;
    if count == u32::MAX {
        return (length == 44)
            .then_some(())
            .ok_or(CacheError::UnsafeLocation);
    }
    if count > 128 || length != 44 + count as usize * 24 {
        return Err(CacheError::UnsafeLocation);
    }
    for entry in 0..count as usize {
        let flags = number(acl, 44 + 24 * entry + 16)?;
        let rights = number(acl, 44 + 24 * entry + 20)?;
        // Vnode rights1..13, SYNCHRONIZE20 and generic rights21..24 only.
        if flags & 0xf != 2 || flags & !0x1ff != 0 || rights & !0x01f0_3ffe != 0 {
            return Err(CacheError::UnsafeLocation);
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
pub(super) fn check(file: &std::fs::File) -> Result<()> {
    use std::os::fd::AsRawFd;
    let mut attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: libc::ATTR_CMN_EXTENDED_SECURITY,
        volattr: 0,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    let mut output = [0u64; 1024];
    // SAFETY: owned descriptor, official fixed attrlist structure, 8KiB aligned
    // output, report-full-size catches truncation. No path lookup or mutation.
    let result = unsafe {
        libc::fgetattrlist(
            file.as_raw_fd(),
            (&mut attributes as *mut libc::attrlist).cast(),
            output.as_mut_ptr().cast(),
            std::mem::size_of_val(&output),
            libc::FSOPT_REPORT_FULLSIZE,
        )
    };
    if result != 0 {
        return Err(CacheError::UnsafeLocation);
    }
    // SAFETY: only reads initialized bytes of the aligned fixed output array.
    let bytes = unsafe {
        std::slice::from_raw_parts(output.as_ptr().cast::<u8>(), std::mem::size_of_val(&output))
    };
    admit(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
    }
    fn acl(count: u32) -> Vec<u8> {
        let length = if count == u32::MAX {
            44
        } else {
            44 + count as usize * 24
        };
        let mut bytes = vec![0u8; 12 + length];
        put(&mut bytes, 0, (12 + length) as u32);
        put(&mut bytes, 4, 8);
        put(&mut bytes, 8, length as u32);
        put(&mut bytes, 12, 0x012cc16d);
        put(&mut bytes, 48, count);
        if count != u32::MAX {
            for n in 0..count as usize {
                put(&mut bytes, 12 + 44 + 24 * n + 16, 2);
                put(&mut bytes, 12 + 44 + 24 * n + 20, 1 << 4);
            }
        }
        bytes
    }
    #[test]
    fn native_acl_boundaries_are_strict_and_deny_inheritance_cannot_grant() {
        let mut none = vec![0u8; 12];
        put(&mut none, 0, 12);
        put(&mut none, 4, 8);
        assert!(admit(&none).is_ok());
        for offset in [0u32, 4, 12, u32::MAX, i32::MAX as u32] {
            let mut bad = none.clone();
            put(&mut bad, 4, offset);
            assert!(admit(&bad).is_err());
        }
        for size in [0u32, 8, 13, u32::MAX] {
            let mut bad = none.clone();
            put(&mut bad, 0, size);
            assert!(admit(&bad).is_err());
        }
        assert!(admit(&acl(0)).is_ok());
        assert!(admit(&acl(128)).is_ok());
        assert!(admit(&acl(129)).is_err());
        assert!(admit(&acl(u32::MAX)).is_ok());
        let mut sentinel = acl(u32::MAX);
        sentinel.extend_from_slice(&[0; 4]);
        put(&mut sentinel, 0, 60);
        put(&mut sentinel, 8, 48);
        assert!(admit(&sentinel).is_err());
        let good = acl(1);
        let flag = 12 + 44 + 16;
        for flags in [2u32, 0x12, 0x32, 0x72, 0x1f2] {
            let mut v = good.clone();
            put(&mut v, flag, flags);
            assert!(admit(&v).is_ok());
        }
        for flags in [1u32, 3, 4, 0, 15, 0x8000_0002, 0x202] {
            let mut v = good.clone();
            put(&mut v, flag, flags);
            assert!(admit(&v).is_err());
        }
        for flags in [0u32, 0xffff, 0x10000, 0x20000, 0x3ffff] {
            let mut v = good.clone();
            put(&mut v, 52, flags);
            assert!(admit(&v).is_ok());
        }
        for flags in [0x40000u32, 0x8000_0000] {
            let mut v = good.clone();
            put(&mut v, 52, flags);
            assert!(admit(&v).is_err());
        }
        for rights in [1u32, 1 << 14, 1 << 19, 1 << 25, 1 << 31] {
            let mut v = good.clone();
            put(&mut v, flag + 4, rights);
            assert!(admit(&v).is_err());
        }
        let mut overflow = good.clone();
        put(&mut overflow, 8, u32::MAX);
        assert!(admit(&overflow).is_err());
        assert!(admit(&good[..good.len() - 1]).is_err());
        let mut owner = good.clone();
        owner[16] = 1;
        assert!(admit(&owner).is_err());
    }
}
