# Manual synthetic transcript benchmark

This is a developer measurement tool, not an app feature. Normal CI compiles the
ignored GPUI test, runs two small Rust validation tests and the Python parser tests,
and does **not** run timing measurements. The app's production behavior is unchanged.

## Prerequisites and commands

Use Python 3.11+ (standard library only), the repository's Rust toolchain and the
same native build prerequisites as the app. Run from the repository root. The tool
supports only the unoptimized default Cargo test profile with debug assertions and
overflow checks enabled. Custom compiler flags/wrappers, cross targets and unsupported
Cargo profile overrides fail rather than being mislabeled as a matching build.
Cargo compilation uses at most four jobs. Every run first executes
`cargo clean --package bello-agent-app --package bello-agent-core` in its requested checkout, removing only
those two packages' generated artifacts. Third-party caches, source files, retained
measurement evidence and copied QA executables outside Cargo's target remain intact.
Do not run other app builds concurrently in that shared target.

Start with a small CLI-validation run:

```sh
python3 rust/scripts/transcript_benchmark.py run \
  --output ../audit-evidence/transcript-generic-a \
  --totals 100 --mode generic
```

Run the primary old/new renderer comparison matrix with identical full-draw scopes:

```sh
python3 rust/scripts/transcript_benchmark.py run \
  --output ../audit-evidence/transcript-generic-a-full \
  --totals 100,1000,10000 --mode generic
```

Optional `--mode cached` adds implementation-dependent construction probes and remains
the CLI default. Pass the mode explicitly for audited comparisons.

Outputs must be new directories. Existing files/directories are never overwritten.
Use a workspace sibling or a directory under `rust/target`; output under source,
benchmark, script, asset or Git directories is rejected. Keep builds, UI automation
and other heavy work idle during a run. A full matrix can take several minutes.
Fixtures and results are retained locally; they are not uploaded or automatically
backed up by this command.

After measuring another checkout with the **same harness, mode, compiler/profile,
payloads and matrix**, compare the full draw routes:

```sh
python3 rust/scripts/transcript_benchmark.py compare \
  --baseline ../audit-evidence/transcript-generic-a-full/results.json \
  --candidate ../audit-evidence/transcript-generic-b-full/results.json \
  --output ../audit-evidence/transcript-comparison
```

Changing application source is the purpose of a comparison. Changing the benchmark
Rust file or runner, measurement mode, compiler/profile fingerprint, payload/window,
or case set is rejected. A changed harness needs separately reviewed compatibility;
the tool does not guess that equal labels or byte counts mean equal workloads.

Run inexpensive validation independently:

```sh
python3 -m unittest discover -s rust/scripts -p 'test_transcript_benchmark.py' -v
cd rust
cargo test --locked -p bello-agent-app transcript_benchmark
```

The latter skips `manual_transcript_benchmark`. The runner requires successful
package-scoped cleaning, then discovers the actual test
executable from successful Cargo JSON output, requires the app artifact's `fresh`
field to be strictly `false`, and checks that its resolved `target.src_path` is the
requested checkout's app `main.rs`. It also requires exactly one freshly compiled
core library artifact at that checkout's `src/lib.rs`. The core dependency profile
has `test=false`; it is validated and included in the compiler/profile identity
separately from the app test's `test=true` profile. It invokes the exact executable with
`--exact --ignored --nocapture --test-threads=1`; it verifies binary and source hashes
again afterward. Invoking the ignored test directly without its strict runner-created
configuration is unsupported.

## Workloads and measurement scopes

The matrix uses 100, 1,000 and 10,000 synthetic messages, default 100 revealed and all
revealed, and two fixed payload families: short text and multiline Unicode text with
reasoning on alternating assistant rows. The window is 1280×840 with the default
sidebar. Fixtures have no configured provider and a local invalid Git marker that
prevents ancestor repository discovery. They never load a user project or session.
Fixture creation, validation, serialization and disk checks are outside timing.

- `generic` measures complete ordinary root-notification and explicit forced-refresh
  draws. Root-notification timing includes the context update, notification/observer
  and deferred effects, synchronous draw and arena cleanup. Forced-refresh timing
  excludes the preceding `Window::refresh()` request and measures `draw().clear()`
  only. Compare the same route across runs; the two routes have different boundaries.
  Generic mode **does not disable caching** or recreate older code and has no child probes.
- `cached` adds observed child render counts, parent conversation composition and
  returned-child-element construction/destruction. Parent composition does not include
  child rows. `direct_child_element_*` bypasses the cache but constructs only the
  returned element: eager rows in the old renderer, a deferred list shell in the
  visible-row renderer. Row work deferred until list layout is outside that probe.
  No clone-byte totals or heap-allocation estimates are inferred. These probes cannot
  establish equivalent row-construction cost and never replace the full-draw routes.
- Stable notification counts are observations, not a hardcoded success claim. A cache
  hit is reported only when the observed child count is zero. Forced-refresh probes
  must demonstrate at least one child render. App regression tests separately enforce
  the current expected warm-cache behavior.

Construction probes use seven warmups and 31 measured samples. Draw routes use three
warmups and up to 21 measured samples, with a 45-second per-route budget checked only
after a completed sample. A slow sample is never truncated. Budget-exhausted short
series are valid only when explicitly labeled; sparse p95 values are usually observed
maxima and do not establish a reliable tail estimate. Medians use the midpoint for an
even sample count; p95 uses nearest rank. Raw nanosecond samples are retained.

The clock measures synchronous **CPU-work elapsed wall time**, not hardware cycles.
GPUI's test platform uses `NoopTextSystem`, empty assets and test windows. These results
exclude native font shaping, rasterization, compositor/display presentation and real
input latency. Debug/test instrumentation and shared-host scheduling affect numbers.
Repeated payloads favor warm caches. This is not a native macOS frame-budget or
scrolling-smoothness test, even when the runner itself is launched on macOS.

Every reveal case explicitly reaches logical top outside timing by dispatching a
positive 1,000,000,000-pixel wheel delta through the actual viewport input handler.
A 24-pixel downward wheel must move the first expected message's actual bounds by
24 pixels; a final upward wheel must restore identical top geometry. This proves
reachability without replacing a scroll handle, resetting list state, or relying on
an initial offset. The first expected message must be horizontally inside the
viewport and intersect its top. A tall first row can legitimately hide the next row,
so no second-row debug selector is required. With no earlier-message
control the first begins at the viewport top (0.01-pixel tolerance); with that control
it must begin within 64 pixels. Preparation fails rather than retrying or silently
accepting a different scroll position. Timed draws must preserve the same geometry.

The complete ordered suffix of IDs in the parent's logical transcript input,
complete session/workspace state, composer text and revision, and fixture file bytes
are checked before/after. `logical_input_rows_*` and
`logical_input_payload_utf8_bytes` describe that input, not materialized trees or
allocation bytes. GPUI retains debug selectors from earlier draws, so their total
count is deliberately never interpreted as current row cardinality. App regression
tests independently prove actual renderer projection completeness and materialized
row bounds. These checks do not replace native Copy, scrolling, IME or desktop tests.

## Evidence and compatibility

Schema 3 and method `logical-top-full-draw-v3-fresh-first-party-build` require fresh app/core
compilation as well as the logical-input/viewport checks replacing the original
all-row-selector and clone-byte assumptions. Schema-1 and schema-2 reports are
rejected and must be remeasured;
changing their labels is not an adapter. Metadata, case, completion and report
schema errors, unsupported method versions, and profile/method-source mismatches
fail closed. The fixed synthetic payload version remains `transcript-v1`.

The same harness and runner can be copied unchanged onto baseline `467c410` and the
visible-row candidate, which share the transcript child and common GPUI input APIs.
Use the same compiler/profile, explicit mode and full matrix in both, keep targets
and dependency caches out of source copies, and retain source manifests for the
actual adapted bytes. The baseline is an adapted checkout, not an unmodified
committed-source measurement. Copy only the benchmark/runner/tests/documentation;
never backport product APIs to make the harness compile. Main comparisons use the
existing full-draw routes in explicit `--mode generic`; the timer boundaries,
warmups, budgets and payloads are unchanged. No render-specific conditional API is
compiled into this common harness. Comparisons also require matching actual viewport
and first-message geometry within 0.01 pixels, rather than accepting different
visible positions under equal workload labels.

`raw.json` retains only recognized synthetic records. `results.json` adds validated
summaries and allowlisted provenance; `summary.csv` is a compact view. A failed run
writes only a failure category and safe schema reason, without raw subprocess logs
or environment values. It never produces a valid comparison from a partial run.
The parser rejects duplicate/missing cases, incomplete terminal records, invalid or
nonfinite timings, malformed counts, unsupported profiles and mismatched comparisons.

Provenance includes source-file hashes, sanitized compiler/target identity, the actual
Cargo artifact profile and test fingerprint, and the test executable hash. It also
records the exact package-clean command, successful cleanup, strictly non-fresh
Cargo app/core artifacts, their validated app-test/core-dependency profiles, and
verified checkout source paths (without storing that private
absolute path). Reports missing this proof are rejected. If relevant first-party source manifests (`rust/crates/`) differ, paired comparison requires different executable hashes; identical
source self-comparisons remain valid.

A shared Cargo target can reuse a different checkout's executable when copied source
mtimes predate its fingerprint. A source manifest and Cargo's reported source path
alone do not prove which source was compiled. Earlier affected measurements are
invalidated and retained for diagnosis; they must not be used for performance claims.
This runner forces fresh app/core compilation while reusing third-party dependencies. Cargo
configuration contents, credential-derived configuration hashes, raw environment and
absolute workspace paths are not stored. Known unsupported overrides are rejected;
this is a reproducibility check, not an attestation against a malicious toolchain.
`source.commit` is checkout HEAD only: relevant uncommitted/untracked source is included
in the manifest, whose hashes describe the bytes actually measured. A local validation
run on an uncommitted harness must not be described as an exact committed-source run.

The earlier `0beb423` baseline and cached comparison used an isolated direct-rustc
harness with four codegen units. This portable Cargo tool uses a different provenance
schema and may use a different Cargo profile/codegen setup. It does not import those
old reports or promise to compile directly against a revision without the transcript
child. Historical reproduction requires an explicit reviewed source/probe adapter and
matching profiles. Keep the earlier full 12-case evidence distinct from validation
pilots of this new CLI.
