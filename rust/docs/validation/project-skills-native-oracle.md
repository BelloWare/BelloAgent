# Project skill source oracle

This gate compares project discovery and explicit selections with actual checked-in
Swift source. A portable Rust test is useful but does not establish native Swift
or macOS UI parity.

## Apple CI recipe

Run on a macOS worker with the Xcode command line tools and the repository's pinned
Rust toolchain. From `rust/`:

```sh
CARGO_BUILD_JOBS=1 cargo test -p bello-agent-core --test project_skills_native -- --nocapture
```

No native-authority feature, app startup, production credential, owner computer,
service spend or network provider request is needed. This test runs automatically
as an integration test under `cargo test -p bello-agent-core` on macOS. Linux
compiles an empty target and must not be reported as executing the Apple gate.
The parent integrator owns any shared CI workflow edit.

The test assembles and compiles these checked-in implementations unchanged:

- `JSON.swift`, `JSONParser.swift`, `ProviderFailure.swift`, `Support.swift`
- `TextPreviews.swift`, `MetadataYAML.swift`, complete `Resources.swift`
- `SessionContext.swift`'s contiguous request-instructions, selection-policy and
  user-message-expansion declarations, placed in a minimal type container
- `CompactionPlanner.swift`'s contiguous `groups` and `source` implementations,
  actual `ReplayGroup` and `damaged` declarations; only the inert message-field
  carrier is fixture-defined

The driver only creates call inputs and collects outputs. A moved extraction
marker fails explicitly. The compiler and oracle subprocesses have 120-second
wall-clock deadlines and isolated process groups; their failures include stderr.
All resource files and both implementations' home/codex paths are disposable,
explicit temporary fixtures. Resource fixtures are created under the repository's
`rust/target/project-skills-native-fixtures`, outside Darwin's `/var` alias on CI.
Foundation can strip `/private` from existing paths even after Rust canonicalizes
them. Skill discovery now uses Foundation's source spelling for new descriptor
IDs/paths, visited-parent base directories and source roots while retaining a
separate canonical filesystem target for reads, race checks and deduplication.
The `/var/tmp` matrix strictly compares all skill fields, IDs, recorded metadata
and expanded bytes across Swift/Rust and both aliases. It includes leaf-file,
directory and skill-root symlinks, plus multiple workspace roots. The driver
passes source-canonical roots as production does; it no longer relies on raw URL
construction to conceal a root-spelling difference. There is no normalization of
skill output to obtain equality.

Full resource instructions remain a separate known source-compatibility gap:
Rust's existing instruction roots/chunk paths use filesystem canonical spelling.
The non-alias metadata matrix retains its full instruction equality assertion;
alias cases report the exact instruction strings/equality separately while gating
all skill outputs. This change does not alter global instruction/authority path
normalization or claim resource-prompt parity. Run with `--nocapture` to retain
those diagnostics. Passing execution of the strengthened Apple gate is still
required; Linux neither executes Foundation nor establishes this native result.
Compiler scratch files still use the temporary directory. No process home or real
workspace content is discovered.

## Compared outputs

Generated LF/CRLF, quoted/block description, 1,024/1,025 grapheme, duplicate key,
unclosed frontmatter, mandatory policy, dependency and traversal vectors compare:

- Canonical identity, ordered source paths and duplicate-name ordering
- Full-source content hash and exact source metadata hash
- Effective policy, reasons, typed dependency facts, stripped body
- Fresh selection acceptance, exact expansion and metadata-only recorded envelope
- Stable request selection policy and literal unselected slash text
- Stale fresh selection rejection, body-only delivery acceptance with retained
  bytes, and metadata-change delivery revocation
- Darwin legacy canonical-ID delivery acceptance without changing frozen bytes;
  stale unsubmitted legacy-ID selections and duplicate old/new target selections
  are rejected

The same compiled oracle also compares sorted protected message IDs with Rust's
`compaction::protected_input_ids`, the helper used by the real planner. Generated
cases cover an answered latest skill-bearing user message; multiple selected rows
in the current task followed by answered unselected steering; a new answered or
unanswered unselected task that releases older selected carriers; and legacy
answered/unanswered input without task provenance. The source rule protects the
latest user message when unanswered or skill-bearing, plus all selected rows in
the current task. It does not protect the newest historical selected row forever
once a new unselected task has started.

The portable suite separately covers FIFO, 256 KiB/64 KiB/2 MiB limits, 32
metadata dependencies, eight selections, 16 KiB arguments, 512 skills, depth 12,
5,000 visited nodes, scope separation, cancellation and redacted diagnostics.

## Deliberate Rust differences

The resource revision is a local SHA256 of the prompt and Rust's typed body-free
catalog serialization. Scope, dependency configuration and scan completeness are
separate fields. Rust includes `sourceCharacters` and omits empty optional arrays;
its full catalog revision is therefore not claimed equal to Swift's revision.
The individual content and metadata hashes and selected user expansion are compared.

Rust refuses duplicate keys in JSON-style YAML scalar objects, trailing commas in
such scalars and combined YAML/JSON container depth 16 or greater. Swift's generic
JSON parser keeps the first duplicate key, accepts a trailing comma and has a larger
JSON-specific nesting bound. These stricter fail-closed cases have portable tests
and are not included among the native equality vectors. Unknown mandatory policies,
ordinary YAML mapping duplicate keys, anchors and invalid policy types fail closed
in both implementations.

Canonical aliases to one skill are deduplicated by canonical file identity in
Rust, including a direct-file alias to a directory's `SKILL.md`; this is a safety
strengthening of source traversal bookkeeping. Canonical symlink identity is not
filesystem containment. Rust's bounded reads also detect observable replacement,
size and timestamp races; neither implementation supplies a multi-file filesystem
transaction.

Only queued delivery may look up an old canonical-path-derived ID. The private
lookup comes from current discovery, requires the retained path to equal that
exact canonical path and the ID to hash it, and requires one unambiguous current
target. Two retained IDs cannot authorize one skill. Metadata, effective policy,
dependency and controller scope checks remain in force. Fresh selection never
uses this compatibility lookup: an old unsubmitted chip must be refreshed and
explicitly reselected. No frozen body, historical path/baseDir/ID, recorded field,
receipt, expanded text, Retry record or schema version is rewritten.

`FrozenSkill.bodyHash` is a Rust-only persistence integrity field over the exact
stripped body. It does not replace the source content or metadata hashes. Neither
skill selection nor dependency presence grants tools or executes installation.

## Evidence status

The strengthened native harness is implemented but its actual macOS execution is
still pending. Portable tests are not evidence that Swift and Foundation output
match on Apple hardware.

A Linux-hosted `aarch64-apple-darwin` metadata check compiled the exact new
`project_resources/source_path.rs` unchanged against the installed Apple Rust
standard library and cached official objc2 0.6.4 / objc2-foundation 0.3.2 bindings.
The isolated checker supplied only a lightweight Result/error adapter. This
establishes the helper's native method/type usage, not whole-core compilation,
linking, filesystem behavior or native runtime parity.

The attempted full-core offline Apple cross-check stopped before reaching the
changed core code: ring's C build script invoked host `cc`, which rejects Darwin
`-arch` and `-mmacosx-version-min` flags. No Mac SDK or cross-C toolchain was
installed to work around it. The full core and strengthened Swift oracle still
require the real Apple CI worker described above.

Native UI, VoiceOver, IME and production signing/Keychain/authority remain separate
acceptance gates. The full resource-instruction spelling gap also remains separate
from this bounded skill identity correction.
