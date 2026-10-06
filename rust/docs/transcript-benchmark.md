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
Cargo compilation uses at most four jobs.

Start with a small CLI-validation run:

```sh
python3 rust/scripts/transcript_benchmark.py run \
  --output ../audit-evidence/transcript-generic-a \
  --totals 100 --mode generic
```

Run the complete synthetic matrix with cache probes:

```sh
python3 rust/scripts/transcript_benchmark.py run \
  --output ../audit-evidence/transcript-cached-a \
  --totals 100,1000,10000 --mode cached
```

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
  --baseline ../audit-evidence/transcript-cached-a/results.json \
  --candidate ../audit-evidence/transcript-cached-b/results.json \
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

The latter skips `manual_transcript_benchmark`. The runner discovers the actual test
executable from successful Cargo JSON output and invokes that exact executable with
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
  direct child construction/destruction. Parent composition does not include child
  rows. Direct child construction bypasses the cache but does not perform layout or
  painting. Neither replaces the full-draw measurement.
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

Exact revealed row membership, complete session/workspace state, composer text and
revision, and fixture file bytes are checked before/after. These invariants do not
replace real Copy, scrolling, IME or desktop interaction tests.

## Evidence and compatibility

`raw.json` retains only recognized synthetic records. `results.json` adds validated
summaries and allowlisted provenance; `summary.csv` is a compact view. A failed run
writes only a failure category and safe schema reason, without raw subprocess logs
or environment values. It never produces a valid comparison from a partial run.
The parser rejects duplicate/missing cases, incomplete terminal records, invalid or
nonfinite timings, malformed counts, unsupported profiles and mismatched comparisons.

Provenance includes source-file hashes, sanitized compiler/target identity, the actual
Cargo artifact profile and test fingerprint, and the test executable hash. Cargo
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
