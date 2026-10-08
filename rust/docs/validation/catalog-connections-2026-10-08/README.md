# Catalog-assisted Connections validation — 2026-10-08

This directory records a bounded Rust migration checkpoint, not production remote
catalog readiness or full Swift parity. It contains original validation records
and screenshots; no executable or Cargo target artifacts are included.

## Candidate and authority boundary

The final source snapshot is **r4**, based on
`6eee1d06776b18b55b45f0f8adbbe6204c3cb328`. The
[source manifest](review-r4/manifest.json) records the exact preimage and final
SHA-256 of each of the 18 changed source/document/workflow files. The containing
Git commit supplies those afterimages. [evidence-files.json](evidence-files.json)
indexes the records in this directory, preserving their original byte hashes.

The feature covers bundled or exclusive custom catalog selection, bounded search
and paging, manual aliases, retained metadata, Save CAS/route forks, saved route
selection/New Chat, and explicit later chat submission. The existing catalog bytes
are embedded directly. Selecting or refreshing a model never sends or saves.
Output budget and model ceiling remain distinct; choosing a model never raises the
budget. Catalog image labels do not grant attachment capability, and source links
do not change request routing.

The opt-in native connection-only host, AuthorityMode, native asynchronous
preparation/navigation fences and native-only/combined CI jobs are preserved.
Catalog controls and intents remain Fixture-only. Production remote catalogs are
rejected; no foreground native Keychain catalog preparation is admitted. Default
startup, vault and tool gates are retained. Every GUI launch used only
`--synthetic-connections`, two numeric-loopback fixtures and fixed synthetic data.
No real credentials or paid provider were used. Onboarding, probes, mini-models,
per-chat overrides, source-selector UI and live catalog image capability remain
deferred. Native macOS secure input/IME/accessibility, Keychain and signing
acceptance are not established by this Linux fixture evidence.

## Final corrected checks

The [validation index](notice-repair/corrected-r4/validation-manifest.json) binds
checks, source hashes, mutation results, executable provenance, LOC and GUI records.

- Formatting passed.
- Five canonical strict all-target Clippy configurations passed: default workspace,
  synthetic workspace, core all-features, native-only App, and combined App.
  Their logs are under [notice-repair/corrected-r4](notice-repair/corrected-r4/).
- [94 focused combined App tests](notice-repair/corrected-r4/focused-app-combined-restored.log)
  and [48 focused native-only App tests](notice-repair/corrected-r4/focused-app-native-restored.log)
  passed after exact restoration from both mutations.
- The [59 earlier focused core all-features tests](focused-core-all-features.log)
  apply to [110 hash-identical core/manifests/bundle inputs](notice-repair/corrected-r4/core-inputs-unchanged.json).
  They were not rerun for the App-only notice repair.

These are **focused suites, not the original full suites**. The App copy excludes
41 unrelated test/helper modules; the core copy excludes 63 unrelated test modules
in 40 files. Exact substitutions and byte-reconstruction evidence are retained in
[App provenance](notice-repair/corrected-r4/restored-harness-provenance.json) and
[core provenance](core-focused-provenance/). Production declarations and required
test-support hooks remain exact. App harness codegen-units 256 and package-only
GPUI codegen-units 256 bounded compiler memory without changing shipping manifests.
Original reproduction scripts retain their original container paths; they document
the performed commands and exclusions, rather than providing a portable one-command
runner. The source/tests themselves are in the repository.

The notice repair assigns a successful catalog Choose notice to its draft. Cancel
and confirmed discard clear that discarded draft's notice; discarding a different
draft leaves the selected draft's notice intact. Ordinary Save/runtime notices
revoke draft ownership, including non-error recovery warnings. CAS error notices
and uncertain admission blocks remain intact.

Two [corrected negative controls](notice-repair/corrected-r4/negative-control-results.json)
were detected by actual assertions:

1. Disabling owned-notice clearing failed only the catalog discard/clean-reopen
   notice test.
2. Omitting notice ownership reset failed both the error and non-error recovery
   warning-retention tests. Each starts with a real successful Browse/Choose before
   the replacement notice, so it exercises the ownership handoff.

Unconfirmed Save may commit. The regression snapshots bytes immediately after that
failure, then proves Cancel/reopen adds no mutation and uncertainty still blocks
admission. Conflict additionally proves the pre-Save bytes remain unchanged.

## Executable provenance and actual GUI

### Final r4 repair recheck

Final executable SHA-256:
`dc9ded02d04c2a1e7bae42d9a921237b2cffb89233585066a7ac47d5929020b7`.
The [before-input record](gui-r4/source-before.json) and
[build manifest](gui-r4/source-and-binary-manifest.json) contain 198 identical
before/after/current inputs, with source digest
`b7c9fff1ff486987106e15d709a1a47246da2d6d15bd4fd0c4dd15c4d1c3e654`.
Explicit core/App package cleanup and actual compilation are recorded in
[cleanup](gui-r4/build-package-clean.log) and [build](gui-r4/build.log) logs.
Features were `native-authority,synthetic-authority`; the launch mode remained
synthetic only. The executable itself is deliberately omitted.

The [final GUI manifest](gui-r4/gui-result-manifest.json) hashes five original
screenshots at light 920×600:

- [Choose](gui-r4/01-selection-notice.png) staged metadata and its success notice.
- [Cancel/reopen](gui-r4/02-cancel-clean-reopen.png) restored a clean form, unknown
  ceiling and no selection notice.
- [Close confirmation](gui-r4/03-close-confirmation.png) followed by
  [Keep Editing](gui-r4/04-keep-editing-preserves.png) preserved staged metadata and
  its notice.
- [Confirmed discard/reopen](gui-r4/05-confirmed-discard-clean.png) removed both.

This final-binary recheck performed no Save, catalog GET or provider POST. The app
log is empty, exit status is 0 and both fixture processes were cleaned up; see
[exit](gui-r4/light/exit-status.txt) and [cleanup](gui-r4/light/cleanup.txt).

### Earlier r2 broader workflow GUI

The broader run is explicitly attributed to the preceding **r2** executable
`f8da05de2ca697e11e4aa0f33c6bbb0d8db800b15c88c7138717c396b631205a`.
Its [build provenance](gui/source-and-binary-manifest.json),
[GUI manifest](gui/observed-gui-manifest.json), 36 original screenshots and sanitized
[light receipts](gui/light-final-receipts.json) are retained separately. This run
found the notice defect; it is not presented as final-binary notice acceptance.

- Light 1180×812: four same-origin GETs, four external GETs and exactly two explicit
  provider POSTs. Dark 920×600: one anonymous external GET and zero POSTs.
- Bundled Choose/Cancel caused zero I/O. Search found entry 169; paging reached
  [page 3/entry 120](gui/21-page-three.png).
- Budget 4096 and ceiling 8192 survived Choose/Save and explicit model-169 POST.
  Choosing model 168 clamped budget/ceiling to 1024. Save created a fork; the
  [old chat kept A/169](gui/15-old-chat-preserved.png) and
  [New Chat used B/168](gui/16-new-chat-new-route.png), with its own explicit POST.
- Catalog same-origin GET carried only the fake bearer. Provider custom headers
  appeared only on explicit POST. Different-port GET was anonymous.
- [Failed same-source refresh](gui/19-failed-refresh-confirmed.png) retained rows;
  [typed-key changes](gui/23-key-change-clears.png) cleared them. Malformed and
  redirect requests did not trigger bundled or `/models` fallback.
- [Dark search](gui/33-dark920-search169.png), keyboard Tab focus, Escape,
  [limits](gui/34-dark920-selected-limits.png) and Cancel/reopen were exercised.
  [Screenshot 35](gui/35-dark920-cancel-notice-defect.png) records the stale notice
  that was subsequently repaired and retested above.

All 41 screenshots are original, unedited bytes. Some r2 screenshots are
intermediate observations; a filename is not a pass assertion. In particular,
18, 20, 26 and 28 should be read with their later confirmed observations and raw
receipts, not as independent proof of their filename's suggested outcome.

No CANCELLED receipt or proven delayed-completion overlap was obtained in actual
GUI. External-vault-revision, rebind and failed-admission races are focused
regression coverage, not GUI timing claims. Heavy compilation caused temporary
multi-minute input/render delay on the shared host; [process evidence](gui/stall-process.txt)
sampled main-thread folio waits, and queued input later settled without restart.
The final notice GUI ran during a quiet interval.

## LOC accounting and historical failures

The [final additive LOC record](notice-repair/corrected-r4/integrated-loc-r4.json)
is based on the [exact 6eee baseline](loc-baseline/BelloAgent-loc.json), counting
nonblank physical owned Rust lines, including comments:

| Category | Delta | Final |
| --- | ---: | ---: |
| Production | +1,384 | 45,529 |
| Tests/test support | +2,206 | 61,764 |
| Benchmarks/examples | 0 | 1,192 |
| Total | +3,590 | 108,485 |

There are no newly reclassified equal lines. The native host's earlier 138
support-to-production generalized lines are inherited once. This inventory is not
a completion, parity or performance measure.

Historical failures are retained and **not counted as passes**:

- [Original full core SIGKILL](prior-failures/old-full-core-sigkill.log): unit test
  executable did not build or execute.
- [Early focused App SIGKILL](prior-failures/old-focused-app-sigkill.log): no tests
  executed; later bounded harness records supersede it.
- [r1 mutable-binding compile error](prior-failures/r1-mut-binding-compile.log):
  corrected before r2, with no production behavior change.
- [First post-GUI GPUI SIGKILL](prior-failures/post-gui-gpui-sigkill.log): the negative
  regression did not execute; package-only GPUI codegen mitigation recovered it.
- [r3 restored 93/94 result](prior-failures/r3-uncertainty-expectation-93-of-94.log):
  one test incorrectly assumed Unconfirmed Save could not commit. The corrected
  r4 byte-boundary assertion and fully passing runs above supersede that result.

Published-commit Linux/macOS CI is a separate gate and is not inferred from these
local focused results. No prior candidate is treated as the final repaired binary.
