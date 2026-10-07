# Project-only explicit-picker skills checkpoint

Status: implemented and portable/actual-cloud-GUI validated on 2026-10-07.
Publication and the new Apple source oracle are pending the exact published
checkpoint. This is not native macOS UI or production-startup acceptance.

## Implemented path

Project `.agents/skills` discovery, bounded frontmatter and `agents/openai.yaml`,
policy/dependency snapshots and explicit picker arguments now feed the normal
`SavedRuntimeFactory` resource/input preparation. Metadata stays body-free in
picker descriptors. Acceptance captures ordered selections and frozen bodies;
delivery rechecks metadata/policy/dependencies and typed resource scope while
retaining the accepted body. Full-source content hash, exact source metadata hash
and persistence-only stripped-body hash are distinct.

Skill-only, skill-plus-image and ordinary messages use one retained `UserContent`
projection. Stop/Resume, held queue edits, receipts, Retry, saved-factory close/open,
Context and task-aware compaction preserve the same recorded input. Arguments are
literal. Pasted slash text never selects or executes a skill. Dependencies describe
availability, not tool grants or permission to run scripts or install anything.
Home/configuration/credential discovery is absent from this slice.

The new skill-bearing serialized `UserContent` ceiling is 32 MiB, counted with a
bounded exact writer. Legacy image-only content remains 20 MiB. The final provider
request remains 32 MiB and snapshots 256 MiB. Raw composer text remains 256 KiB;
derived skill expansion has a separately bounded 10 MiB text allowance. Limits
reject input before dequeue; they do not truncate frozen skill bodies.

Schema versions are snapshot 8 and catalog 9. Older versions reject even empty
new fields. New deliveries record task roots; legacy rootless history remains
readable. Once provenance is adopted, missing/noncontiguous roots fail closed.
Compaction follows Swift: protect the latest user row when unanswered or selected,
plus every selected row in the current task. A later unselected task releases
older selected carriers. Repeated/new-task regressions exercise this distinction.

## Portable and regression evidence

The [machine-readable record](project-skills-2026-10-07/portable-validation.json)
contains exact log hashes and checkpoint attribution.

- Core default: 360 unit + 125 integration = 485 passing.
- Core all features after the authoritative MCP admission correction: 509 unit
  + 125 integration = 634 passing. Two nested subprocess result lines are repeats.
- Final post-socket app: synthetic 549 passing / 3 ignored; default 432 passing /
  1 ignored. Both explicitly compiled the isolated skill source after package-only
  core/app cleanup. Both all-target Clippy modes pass with warnings denied.
- Core all-target Clippy in default/all-feature modes and workspace fmt pass.
- Three isolated mutation controls fail their intended assertions: delivery scope,
  queued metadata revocation and current-task carrier protection. The restored
  all-feature suite and Clippy pass; no compile-error substitute is counted.
- Existing UI harness 12, benchmark parser 42 and skill fixture 5 self-tests pass.
- Independent source review covered scope/admission fences, physical worker
  retirement, durable receipt uncertainty, version rejection, ordered replay,
  stale picker callbacks and task-root compaction. Reported findings were fixed.

No shared target artifact alone establishes source identity. A short app-lane
handoff conflict occurred after both skill test runs and before Clippy; Cargo
serialized the commands. All relevant logs name the correct staging root. The
default skills test executable was copied and hashed; the synthetic executable
was replaced by the other owner's subsequent compile, so only its completed
root-verified log is retained. The actual GUI binary was separately immutable.

## Actual GUI observations

The [curated evidence package](project-skills-2026-10-07/gui/README.md) contains
unchanged app screenshots, generated requests/checkpoints and an offline verifier
that works after relocation. No binary is bundled; its exact identity metadata
is retained. Original launch and offline checks verified the binary bytes.

Candidate 2 binary SHA256:
`19588b1d3652f622b3be5d8a73dc4c339b2ae95e81d63529cc3331738fdda586`.
Its build source is the MCP-inclusive `a890af0` baseline plus skills, manifest
`9aaf4c1572c4d5460ba80e10f1c74addc060284211b383df75c9589061ca8482`.
Later socket fixtures, native-oracle fixture/characterization and LOC evidence
edits change no runtime/build production source and are recorded separately.

Observed through normal saved profile/project trust/UI with generated loopback:

1. Skill-only queued Alpha V1 delivered its frozen body after source changed to
   V2. A separate policy change paused and retained the queued selection without
   another provider request.
2. Active Context excluded draft and queued input and remained an immutable
   captured snapshot after the chat changed.
3. Held queue editing parked the ordinary skill draft; Cancel restored it;
   empty raw-text Save preserved the skill-only held identity and body.
4. Explicit removal/Resume, Stop, source deletion and Retry preserved exact
   historical input without an extra user row.
5. Beta initial plus Alpha promoted steering ran the genuine saved-runtime `ls`.
   A large continuation was compacted through normal Compact Now with one summary
   attempt, reducing the estimate from 9,869 to 965 tokens. Both exact original
   carriers remained protected in task order; a real subsequent request replayed
   summary, Beta, Alpha and fresh plain input, each carrier once.
6. Separate normal saved MCP setup invoked `echo` once. Reload recovered the
   durable output with `outcomeUnknown: false`; `tools/call` stayed 0 → 1 → 1.
   This is saved MCP configuration/result reload, not chat-controller replacement.

Candidate 1's earlier same-name picker, invalid-policy inspection, literal
arguments, cancel/remove/reselect, idle Context, literal slash and skill-plus-image
GUI results retain their original pre-MCP-fix binary attribution. They are not
relabeled candidate 2. Latest-binary cold-open preserved prior synthetic history
and failed closed when in-memory synthetic authority reset. Positive disk close/
open is portable saved-factory evidence. Raw clipboard Copy and adversarial late
callback/recovery cases remain GPUI/portable coverage, not actual-GUI claims.

All validation windows/services closed normally; final queues were idle and
fixture bridges retired. Desktop was explicitly released at 15:09 UTC.

## Apple and publication gates

The [native oracle](project-skills-native-oracle.md) compiles actual checked-in
Swift resource/selection and compaction source with inert generated carriers.
Its main matrix retains exact paths, IDs, hashes and expansion assertions. A
separate Darwin alias characterization verifies same-file targets and stable
Rust identity while reporting the Swift/Rust path-derived ID/text distinction.
That distinction is a source-compatibility gap, not an accepted parity shortcut.
Neither the new oracle nor its alias characterization has executed on Linux.

Baseline `110cde32753930599b2e10d76388bcffcf23624e` passed Linux and Apple CI, but
does not contain this skills slice. The new exact published commit must pass its
own CI before claiming the Apple skill gate. Native UI, VoiceOver, IME, signing,
Keychain/authority and ordinary production startup remain separate closed gates.

The [LOC ledger](loc-project-skills-2026-10-07-delta.json) and
[summary](loc-project-skills-2026-10-07-summary.md) bind source accounting to the
final Rust manifest and preserve immutable prior baselines. Source volume is not
feature parity, a completion percentage or performance. Root owns publication
and must verify remote commit/tree and rerun the ledger against that revision.
