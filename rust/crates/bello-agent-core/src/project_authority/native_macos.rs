//! Real framework boundary. No test calls this adapter, including ignored tests.
//! All foreign values are operation-local; the adapter itself is a zero-sized
//! Rust value with ordinary automatic Send/Sync, never an unsafe implementation.
use super::super::{AuthorityError, AuthorityResult};
use super::{
    ACCOUNT, BUNDLE_ID, MAX_BYTES, MutationOutcome, NativeApi, REQUIREMENT, SERVICE,
    file_lock::FileLock,
    status::{Mutation, mutation_outcome},
};
use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    boolean::CFBoolean,
    data::CFData,
    dictionary::CFMutableDictionary,
    string::{CFString, CFStringRef},
};
use objc2::rc::{Retained, autoreleasepool};
use objc2_foundation::{NSFileManager, NSSearchPathDirectory, NSSearchPathDomainMask};
use objc2_local_authentication::LAContext;
use security_framework::os::macos::code_signing::{Flags, SecCode, SecRequirement};
use security_framework_sys::{
    base::{errSecItemNotFound, errSecSuccess},
    item::{
        kSecAttrAccount, kSecAttrLabel, kSecAttrService, kSecClass, kSecClassGenericPassword,
        kSecMatchLimit, kSecReturnData, kSecUseAuthenticationContext, kSecValueData,
    },
    keychain_item::{SecItemAdd, SecItemCopyMatching, SecItemUpdate},
};
use std::{path::PathBuf, ptr};

// Not exported by security-framework-sys 2.17.0. Apple's SecItem.h declares
// `extern const CFStringRef kSecMatchLimitOne`; this is a string constant, NOT
// the CFNumber 1 used by some higher-level wrappers.
// https://github.com/apple-oss-distributions/Security/blob/main/keychain/headers/SecItem.h
unsafe extern "C" {
    static kSecMatchLimitOne: CFStringRef;
}

pub(super) struct SecurityApi;

impl NativeApi for SecurityApi {
    type Lock = FileLock;

    fn pool<T>(&self, operation: impl FnOnce() -> T) -> T {
        autoreleasepool(|_| operation())
    }

    fn validate_identity(&self) -> AuthorityResult<()> {
        let code = SecCode::for_self(Flags::NONE).map_err(|_| AuthorityError::Unsigned)?;
        let requirement: SecRequirement =
            REQUIREMENT.parse().map_err(|_| AuthorityError::Unsigned)?;
        code.check_validity(Flags::STRICT_VALIDATE, &requirement)
            .map_err(|_| AuthorityError::Unsigned)
    }

    fn acquire_lock(&self) -> AuthorityResult<Self::Lock> {
        // Resolve through Foundation's user-domain Application Support URL as
        // in Swift. No HOME, current-directory, or temporary-path fallback.
        let directories = NSFileManager::defaultManager().URLsForDirectory_inDomains(
            NSSearchPathDirectory::ApplicationSupportDirectory,
            NSSearchPathDomainMask::UserDomainMask,
        );
        let path = directories
            .firstObject()
            .and_then(|url| url.path())
            .ok_or(AuthorityError::LockUnavailable)?;
        let path = PathBuf::from(path.to_string())
            .join(BUNDLE_ID)
            .join("configuration.lock");
        FileLock::acquire(&path)
    }

    fn copy_matching(&self) -> AuthorityResult<Option<Vec<u8>>> {
        with_query(|query| {
            // SAFETY: these are Security's process-lifetime CFString constants;
            // the local dictionary retains its values until the call completes.
            unsafe {
                put(
                    query,
                    kSecReturnData,
                    CFBoolean::true_value().as_CFTypeRef(),
                );
                put(query, kSecMatchLimit, kSecMatchLimitOne.cast());
            }
            let mut result: CFTypeRef = ptr::null();
            // SAFETY: query and out-pointer are valid for this synchronous call.
            let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut result) };
            // Copy/Create ownership is balanced on every status branch. Never
            // inspect or format a result as a description, string, or array.
            let result = if result.is_null() {
                None
            } else {
                // SAFETY: a nonnull CopyMatching output is an owned CF object.
                Some(unsafe { CFType::wrap_under_create_rule(result) })
            };
            if status == errSecItemNotFound {
                return Ok(None);
            }
            if status != errSecSuccess {
                return Err(AuthorityError::Denied);
            }
            // downcast_into checks CFGetTypeID == CFDataGetTypeID before the
            // CFData cast. Nil or any other exact CF type is corrupt, not absent.
            let data = result
                .and_then(CFType::downcast_into::<CFData>)
                .ok_or(AuthorityError::Corrupt)?;
            let length = data.len();
            if length < 0 || length as usize > MAX_BYTES {
                return Err(AuthorityError::Corrupt);
            }
            // Bound before allocating/copying into Rust-owned memory.
            Ok(Some(data.bytes().to_vec()))
        })
    }

    fn update(&self, bytes: &[u8]) -> MutationOutcome {
        with_query(|query| {
            let data = CFData::from_buffer(bytes);
            let mut attributes = CFMutableDictionary::new();
            // SAFETY: static key and owned CFData survive the synchronous call.
            unsafe { put(&mut attributes, kSecValueData, data.as_CFTypeRef()) };
            // Do not use a convenience "set password" wrapper: some implement
            // delete/add or retry. The existing item is updated exactly once.
            let status = unsafe {
                SecItemUpdate(
                    query.as_concrete_TypeRef(),
                    attributes.as_concrete_TypeRef(),
                )
            };
            mutation_outcome(status, Mutation::Update)
        })
    }

    fn add(&self, bytes: &[u8]) -> MutationOutcome {
        with_query(|query| {
            let data = CFData::from_buffer(bytes);
            let label = CFString::new("Bello Agent configuration");
            // SAFETY: the dictionary retains data/label for the single add.
            unsafe {
                put(query, kSecValueData, data.as_CFTypeRef());
                put(query, kSecAttrLabel, label.as_CFTypeRef());
            }
            // SAFETY: valid retained dictionary; no result is requested.
            let status = unsafe { SecItemAdd(query.as_concrete_TypeRef(), ptr::null_mut()) };
            mutation_outcome(status, Mutation::Add)
        })
    }
}

fn put(query: &mut CFMutableDictionary, key: CFStringRef, value: CFTypeRef) {
    query.add(&key.cast(), &value);
}

fn with_query<T>(operation: impl FnOnce(&mut CFMutableDictionary) -> T) -> T {
    // SAFETY: a newly initialized context is used only on this operation's
    // thread. Never evaluate authentication, reuse it, or expose it as Send.
    let context = unsafe { LAContext::new() };
    unsafe { context.setInteractionNotAllowed(true) };
    let service = CFString::new(SERVICE);
    let account = CFString::new(ACCOUNT);
    let mut query = CFMutableDictionary::new();
    // SAFETY: Security explicitly accepts an LAContext Objective-C object for
    // this CFDictionary key. Core Foundation collection callbacks retain/release
    // Objective-C objects. The Retained owner and dictionary both stay local.
    unsafe {
        put(&mut query, kSecClass, kSecClassGenericPassword.cast());
        put(&mut query, kSecAttrService, service.as_CFTypeRef());
        put(&mut query, kSecAttrAccount, account.as_CFTypeRef());
        put(
            &mut query,
            kSecUseAuthenticationContext,
            Retained::as_ptr(&context).cast(),
        );
    }
    // The ordinary macOS generic-password Keychain and default trusted-app
    // access policy mirror Swift. No access group/Data Protection/sync option,
    // ACL rewrite, authentication UI retry, or source-service fallback is added.
    operation(&mut query)
}
