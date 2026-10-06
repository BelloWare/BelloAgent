# Portable project authority contracts

The portable envelope/edit/confirmation contract uses an isolated Rust trust
store. `ProjectAuthority::new()` and `Default` remain unavailable on every
production platform. Unit tests and the explicit, nondefault
`synthetic-authority` feature can construct an in-memory fixture backend; it
never changes default composition.

The separate, optional `native-authority` feature now provides an explicit macOS
storage adapter and approved Rust identity templates. Its constructor is inert
and is not installed in the app. See [the native storage contract](native-authority-contract.md)
for strict identity checks, locked whole-byte CAS, framework repair uncertainty,
foreign ownership and the remaining native acceptance gate. No signing,
certificate discovery, user credential or Keychain access was performed while
preparing or testing this code. There is no plaintext, unsigned, environment or
source-vault fallback.

The approved namespace is `com.belloware.BelloAgentRust`, service
`com.belloware.BelloAgentRust.configuration`, account `vault-v1`, using the
existing source Developer ID team. Repository configuration does not establish
that an installed certificate or signed application exists. Actual signing,
Keychain operations and native interaction validation remain separately
authorized gates. The Swift vault is neither imported nor rewritten; projects
require fresh explicit trust in the separate Rust store. Saved trust alone does
not enable tools.

## Envelope and editing

The Rust envelope requires schema 1, a nonnegative signed 64-bit revision and a
workspaces array. Only an absent backend item receives an empty fresh envelope;
missing fields in existing bytes, duplicate object keys, duplicate project IDs,
future schemas, oversized content and revision overflow fail closed. The envelope
is bounded to 2 MiB and 1000 projects. Fresh Rust project IDs are UUIDs. Project roots
are absolute UTF-8 paths of at most 4096 bytes, primary first, canonicalized and
deduplicated at explicit trust editing, with at most 16 distinct roots. Legacy
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
