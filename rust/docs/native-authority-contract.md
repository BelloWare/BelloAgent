# Native project-authority storage contract

This checkpoint adds an opt-in macOS backend for the separate Rust configuration
vault. It follows `apps/macos/PiApp/Storage/KeychainVaultStorage.swift` and the
2 MiB envelope limit in `ConfigurationVault.swift`. The portable envelope,
draft-retention, project confirmation, and host admission contracts still apply.

## Composition and approved identity

`native-authority` is nondefault. `ProjectAuthority::with_native_storage()` is the
only production composition boundary; on unsupported platforms it returns
`Unavailable`. Construction is side-effect free. `ProjectAuthority::new()` and
`Default` remain unavailable on every platform, including with all features
enabled. The app's nondefault `native-authority` feature and explicit
`--native-authority` flag now select this boundary; see
[the host composition contract](native-authority-host.md). Neither enabling a
feature nor saved metadata selects it automatically, and tests use fake storage.
The existing synchronous storage interface is called through the host's existing
background path; this change adds no queue, timeout, cancellation, or worker
architecture.

The fixed identity is recorded in `packaging/macos/native-authority-identity.json`
and matched by fake-only tests:

- Bundle and Application Support namespace: `com.belloware.BelloAgentRust`
- Keychain service: `com.belloware.BelloAgentRust.configuration`
- Account: `vault-v1`
- Developer ID Application team: `43TXHV3TM3`
- Lock: the user-domain Application Support URL plus
  `com.belloware.BelloAgentRust/configuration.lock`

The dynamic code requirement is:

```text
anchor apple generic and identifier "com.belloware.BelloAgentRust" and certificate leaf[subject.OU] = "43TXHV3TM3" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
```

Each read and replace validates `SecCodeCopySelf` against that requirement with
`kSecCSStrictValidate`. Replace repeats the identity check during its locked
read, matching Swift's `replace` calling `read`. Identity failures are `Unsigned`
and occur before Keychain reads/writes or lock-file creation. No certificate
discovery, signing, source-vault import, account migration, entitlement changes,
or credential access is part of preparing this code.

## Query, ownership, and read behavior

Every read/update/add creates a new local `LAContext`, sets
`interactionNotAllowed = true`, and puts it under
`kSecUseAuthenticationContext`. Every top-level storage operation has an
autorelease pool. All Objective-C and Core Foundation owners remain on that
operation's thread and leave scope before the pool drains. The adapter is
stateless; there are no unsafe `Send`/`Sync` implementations or shared contexts.

Queries use the ordinary macOS generic-password Keychain and default
trusted-application policy. They set only class, the fixed service/account, and
the authentication context, plus the operation's required data/label or read
options. Reads request return-data and Apple's actual `kSecMatchLimitOne`
CFString constant. The locked sys crate lacks that constant, so a narrow extern
declaration matches [Apple's SecItem.h](https://github.com/apple-oss-distributions/Security/blob/main/keychain/headers/SecItem.h).
A numeric match limit is not substituted. No Data Protection/access group,
synchronization, ACL rewrite, UI retry, or alternative service is configured.

Only `errSecItemNotFound` means an absent item. All other failed reads return
`Denied`. A successful result must be nonnull and have exactly CFData's type ID;
other result types are `Corrupt`. The length must be within 2 MiB before bytes
are copied to Rust memory. Empty data remains an existing empty item, which the
unchanged envelope decoder rejects. Foreign results are released on all status
paths. No raw data, opaque fields, API keys, or object descriptions are logged.

This matches the source's LocalAuthentication policy. It does not establish
that every legacy Keychain/default-access-policy configuration is incapable of
showing a prompt. That is a native acceptance gate, not a claim made by fake
tests or by the presence of `interactionNotAllowed` in code.

## Locked whole-byte replacement

Replacement first validates identity and bounds, then creates missing support
directories with requested mode 0700. It opens the lock with create/read/write,
requested mode 0600, `O_CLOEXEC`, and `O_NOFOLLOW`; it never truncates the lock.
Directory/open failures are `LockUnavailable`, distinct from contention. A
nonblocking exclusive `flock` failure is `Busy`, matching the Swift guard. The
RAII guard explicitly unlocks before closing on success, error, and Rust unwind.
Existing directory/file modes and ownership are not rewritten or subjected to
additional policy beyond Swift's behavior.

With the lock held, replacement rereads the item and compares the entire optional
byte sequence to the caller's expected bytes. Semantically identical JSON with
different bytes conflicts. An absent expected item causes one `SecItemAdd` with
the source label, `Bello Agent configuration`. An existing expected item causes
one `SecItemUpdate`. The adapter issues no delete, upsert wrapper, retry,
fallback, rollback, or recovery write. A duplicate add is a conflict; every
failed update is unconfirmed because the framework itself can attempt repairs.

The lock serializes cooperating writers to this separate Rust namespace. The
Keychain does not implement an atomic byte-conditional update. An arbitrary
same-account writer that ignores the lock can race between reread and update.
The default trusted-application policy protects reads; this design is not a
claim of per-application write isolation against such writers.

## Confirmed, rejected, and uncertain writes

The host interprets every save error except `Unconfirmed` as a failure before a
write by this operation. The internal mutation seam therefore distinguishes
confirmed success, a known rejection with no write, and uncertain completion.
Only confirmed success advances a draft baseline. Every error preserves edits;
the adapter does not retry.

`errSecSuccess` confirms completion. `errSecDuplicateItem` for the single-item
add is `Conflict`. Every other status after entering add/update is
`Unconfirmed`, including authentication, interaction, read-only, invalid-input,
missing-item, unavailable-store, I/O, disk-full, allocation, internal, cancellation,
and unknown errors. Identity, read, lock, size, and byte-CAS failures detected
before the mutation call retain their specific errors.

The conservative update rule is necessary because Apple's legacy
`_UpdateKeychainItem` can enter `_ReplaceKeychainItem` after verification failure.
That repair can rename or delete existing data before another fallible create,
so a later authentication or availability error does not prove that no mutation
occurred. See the repair and update-failure paths in
[Apple's SecItem.cpp](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp).
The adapter does not attempt to infer a particular internal path from a status
description. The add path likewise has no unproven rejection allowlist beyond
duplicate-item conflict.

It is unsafe to restore host assumptions as though a possible mutation never
happened. Fake tests specifically model an update that changes bytes and then
returns authentication failure, as well as lost completion after a commit. Both
retain `Unconfirmed`, preserve the old draft baseline, and prevent its silent
overwrite of a subsequently observed revision. The adapter has no asynchronous
timeout that would turn an unfinished native mutation into a known rejection.

## Verification boundary

All feature-gated tests use a fake native API or lock files under temporary test
directories. This holds for normal, all-features, and ignored-test invocations.
No test calls `SecurityApi`, validates a real identity, reads the user's support
directory, accesses Security/Keychain, or prompts the user.

Focused coverage includes identity-before-side-effect ordering, the second
identity check inside the lock, denial/corruption/size handling, exact whole-byte
CAS, absent-versus-empty data, add/update selection and no fallback, draft
preservation across pre-write failures and possible-commit saves, post-update
authentication failure after mutation, conservative status classification, and
packaging identity consistency. Filesystem tests cover
nonblocking contention, `O_NOFOLLOW`, `FD_CLOEXEC`, creation modes, preserving
existing modes/content, and unwind cleanup. An open duplicated file descriptor
survives dropping the lock guard to prove explicit unlock rather than relying on
last-descriptor close.

App host composition is separately implemented without enabling model tools or
project resources. Compilation, fake tests, and static binding review do not
constitute native acceptance. A separately authorized signed-app run must verify the approved
Developer ID identity, denied/locked/wrong-identity behavior, real CFData results,
no-prompt behavior under the intended legacy Keychain policy, two-instance lock
contention, initial-add/existing-update/conflict behavior, and the host's saved
state after completion. No such signing or native access is performed by this
checkpoint.
