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
them; this would also change skill IDs and exact expansions. The fixture placement
preserves all exact assertions without normalizing IDs or text. A separately
labeled `/var/tmp` characterization creates both spellings of the same disposable
target, verifies Rust identity/expansion stability across aliases, and verifies
that each implementation's reported ID hashes its reported path. Full-source and
metadata hashes, body and policy must still match. It reports path-derived ID and
expanded-text equality separately rather than asserting cross-language parity.
The observed Foundation-versus-Rust spelling difference is a source-compatibility
gap for path-derived identity and retained text. Its exact runner result remains
unverified until the Apple test executes; run with `--nocapture` to retain it.
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

`FrozenSkill.bodyHash` is a Rust-only persistence integrity field over the exact
stripped body. It does not replace the source content or metadata hashes. Neither
skill selection nor dependency presence grants tools or executes installation.

## Evidence status

The harness is implemented. An actual passing macOS run must be recorded before
claiming the Apple source gate passed. Native UI, VoiceOver, IME and production
signing/Keychain/authority remain separate acceptance gates.
