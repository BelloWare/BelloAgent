use super::MutationOutcome;

#[cfg(target_os = "macos")]
use security_framework_sys::base::{
    errSecDuplicateItem as DUPLICATE_ITEM, errSecSuccess as SUCCESS,
};
// Portable fixtures for the same public OSStatus values; no native calls.
#[cfg(not(target_os = "macos"))]
const SUCCESS: i32 = 0;
#[cfg(not(target_os = "macos"))]
const DUPLICATE_ITEM: i32 = -25299;

#[derive(Clone, Copy)]
pub(super) enum Mutation {
    Add,
    Update,
}

pub(super) fn mutation_outcome(status: i32, mutation: Mutation) -> MutationOutcome {
    match status {
        SUCCESS => MutationOutcome::Confirmed,
        DUPLICATE_ITEM if matches!(mutation, Mutation::Add) => MutationOutcome::Conflict,
        // SecItemUpdate's legacy repair path can rename/delete an item before
        // returning even an authentication, missing-item, or read-only error.
        // Error descriptions do not prove that no mutation occurred. Treat all
        // failed updates, and every add failure except duplicate, as uncertain.
        // https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp
        _ => MutationOutcome::Unconfirmed,
    }
}
