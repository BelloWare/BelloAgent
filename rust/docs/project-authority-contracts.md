# Portable project authority contracts

This checkpoint implements the portable envelope/edit/confirmation contract for
an isolated Rust trust store. It does not implement native Keychain access,
signing configuration, a settings window, per-chat tool mode, or tool enablement.
`ProjectAuthority::new()` is unavailable on every production platform; only unit
tests can inject storage. There is no plaintext, unsigned, environment, or source
vault fallback. No user credentials or Keychain items were read or written.

The intended native backend must verify its approved signed application identity
before both reads and writes, use a separate Rust Keychain namespace, and perform
locked whole-byte compare-and-swap. The source's default trusted-application
policy protects Keychain reads; neither it nor a cooperating-writer lock is a
claim of per-application write isolation against arbitrary same-account writers.
Native worker scheduling, denied/locked identity behavior and real Keychain CAS
remain native implementation/acceptance gates.

There is currently no production Rust bundle identifier in the packaging tree.
An unconfigured namespace proposal is `com.belloware.BelloAgentRust`, service
`com.belloware.BelloAgentRust.configuration`, account `vault-v1`. These names are
not applied by code. Bundle/signing identity and actual access require explicit
packaging approval. The Swift vault is neither imported nor rewritten; users
will explicitly trust projects in the separate Rust store.

## Envelope and editing

The Rust envelope requires schema1, a nonnegative signed64-bit revision and a
workspaces array. Only an absent backend item receives an empty fresh envelope;
missing fields in existing bytes, duplicate object keys, duplicate project IDs,
future schemas, oversized content and revision overflow fail closed. The envelope
is bounded to2MiB and1000 projects. Fresh Rust project IDs are UUIDs. Project roots
are absolute UTF-8 paths of at most4096 bytes, primary first, canonicalized and
deduplicated at explicit trust editing, with at most16 distinct roots. Legacy
missing/null additional paths decode as empty without rewriting on read.

A draft has no write side effects until Save. Save checks both the loaded revision
and complete original bytes, then calls the backend's whole-byte CAS. Confirmed
success alone advances the draft baseline. Denied, busy, conflicting, oversized
or unconfirmed writes retain the user's edits and never retry automatically.
An unconfirmed write may have committed; its old draft cannot silently overwrite
a subsequently observed revision.

Opaque fields use the existing serde_json raw_value feature, without a package or
version addition. Untouched raw values retain their spelling, escapes, huge
numbers and nested content. Known project fields are patched narrowly, preserving
unknown fields inside the project too. Unknown project authority fields prevent
confirmation rather than silently weakening a future policy. These snapshots do
not implement full Swift vault schema compatibility or a source-vault writer.

## Admission boundary

A loaded record is configuration data, not execution permission. Confirmation
reloads the backend and requires unchanged bytes, exact current full-record
membership, trusted=true, supported project fields and existing directory roots.
It is only a point-in-time check, not a lease or filesystem sandbox. The host must
still enforce Controller generation/lifecycle, current tool choice, Archive,
queue/held-edit, uncertainty and shutdown fences after asynchronous boundaries.
Root paths resolve tool paths; they do not restrict absolute/parent/tilde/symlink
access in the source tool model. Forgetting a project here only edits a draft;
the host must enforce the source idle/no-chat removal workflow.

## Evidence

Thirteen focused tests and strict core-library Clippy pass. Tests cover fresh
Save/Cancel/reload, default production unavailability, raw opaque preservation,
null/missing additional paths, revision and same-revision-byte conflicts, initial
and existing-item CAS races, failure/unconfirmed draft retention, forged records,
unknown policy, duplicate fields/IDs, capacity and size limits, and root handling.
Removing the whole-byte baseline fence or discarding opaque envelope fields makes
the corresponding assertion fail; both mutations were restored. Independent
read-only review is clear after its missing-field/null-path corrections.
