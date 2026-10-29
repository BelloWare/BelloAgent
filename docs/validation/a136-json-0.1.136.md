# 0.1.136 PERF-1 phase B: helper JSON parsing

Implementer: Codex. Reviewer/merge owner: the lead. Branch `dev/a136-json`,
based on `6d38ddd435339bd6d1d71f71d42eb59be695b5f7` (phase A plus `dev/next`).
All generated data, builds, logs and profiles live under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json` (`PI_BUILD_ROOT`).
No app, journal format, encoder, replay or history caller changes.

## Change and compatibility

`JSONByteParser` keeps one UTF-8 scratch array per document, reused between
escaped strings. It copies raw runs into that array, writes each decoded
escape directly as UTF-8, then constructs the string once. Its initial
plain-string scan passes the already-scanned prefix to the escape reader;
it no longer scans that prefix again. Unescaped strings retain their existing
path. The returned `String` owns its storage independently of the scratch
array.

The old parser validated each raw run before processing the next escape.
Simply deferring validation would change the reason for inputs with more
than one fault. On a syntax failure the new parser validates the completed
runs already in the buffer before propagating that failure. The unfinished
run stays out of this check: a raw control or missing closing quote used to
win over invalid UTF-8 in that run. Escapes emit complete Unicode scalars,
so concatenating them cannot repair an invalid run. Successful non-ASCII
strings validate once; ASCII strings retain the existing ASCII path.

The next profile attributed 250 of 781 observations to object work (excluding
nested value readers), versus nine to numbers. Nonempty objects now reserve
four members and merge one member at a time with `CollectionOfOne`, avoiding
successive tiny-table allocations and the separate lookup before assignment.
The merge keeps the original value and key bytes on duplicates. Empty objects
still use the shared empty dictionary. Number and whitespace code is unchanged.

Surrogate pairing, unknown escapes, raw controls, BOM/UTF-16/UTF-32 detection,
the 512-container bound, first-value-wins keys, trailing commas and number
conversion/underflow/leading-zero rules remain intact. `JSON.data()` and
encoding are untouched.

## Differential proof

`ReferenceJSONByteParser.swift` is the parser from `6d38ddd4`, copied verbatim
except for its type name and the test-target import/header. Undoing those
changes reproduces the original file byte for byte. It must remain frozen.
Comparisons require identical error code/reason or identical JSON; successful
strings and keys additionally compare UTF-8 bytes, and doubles compare bit
patterns (including negative zero).

| Corpus | Documents | Accepted | Refused |
|---|---:|---:|---:|
| Seeded byte fuzz, seed `177256278154989` (`0xA136B17E5EED`) | 1,000,000 | 238,519 | 761,481 |
| String/document boundaries, all 65,536 BMP escapes | 67,218 | 63,680 | 3,538 |
| UTF-8/BOM/UTF-16/32, invalid and truncated units | 258 | 33 | 225 |
| Generated 10k journal, every line | 12,481 | 12,481 | 0 |
| Eight committed native journal/frame/metadata fixtures | 159 | 159 | 0 |
| Distinct literal candidates from 175 existing helper test files | 181 | 96 | 85 |

Zero disagreements. The generated fixture has 10,009 messages, 12,481
records, 35,255,431 bytes, SHA-256
`e3c7220c8318b85c9955f7709c87fcdcbc3f3221e7376f89d280143a942cd92e`.
The literal collector covers raw one-hash strings and ordinary
JSON-compatible Swift string literals. Rejected candidates include intentional
damage and incomplete JSON fragments. Computed/interpolated test fixtures
are exercised by their actual helper tests, rather than evaluated as source
by the collector.

Coverage includes every JSON escape, surrogate pairs and lone halves,
high-surrogate/non-Unicode escape combinations, short/bad-hex escapes,
all raw control bytes, overlong UTF-8, encoded surrogates, above-U+10FFFF
values, truncated sequences, stray continuation bytes, long ASCII/non-ASCII
runs, empty and MiB strings, buffer-size boundaries, 511–514 levels of arrays
and objects, long mantissas, subnormal/underflow/overflow numbers, signed zero,
whitespace variants and all legacy encoding detection paths. The seeded
generator also includes rare deep, MiB and long-number documents. Default
fuzz count is 20,000; `PI_JSON_FUZZ_COUNT` enables the million-document run
without imposing it on the ordinary test gate. Seed and accepted/refused
counts print in every run.

The first test-only collector assertion assumed more than 100 accepted
literals; it found 96. The minimum now guards against an empty/broken scan
at 50. This was a corpus-size assertion failure, not a parser disagreement.

## Mutation proof

Each mutation was applied alone, compiled, and failed
`JSONParserDifferentialTests/testStringAndDocumentBoundaries` with one
differential assertion. The original optimized file was restored afterwards;
all six applicable differential cases pass again (the opt-in microbenchmark
skips). Raw logs: `logs/mutation-*.log`, `logs/mutation-final-restored.log`;
machine-readable results and the runner: `mutations.json`, `run-mutations.py`.

| Mutation | Observed discrepancy | Result |
|---|---|---|
| Accept lone low surrogate as U+FFFD | `unpaired surrogate` → accepted | Caught |
| Repair escaped strings instead of validating UTF-8 | `invalid UTF-8` → accepted | Caught |
| Decode `\/` as backslash | Different successful string bytes | Caught |
| Decode `\b` as tab | Different successful string bytes | Caught |
| Keep last repeated key | Different successful JSON value | Caught |
| Remove escaped-string raw-control guard | `control character in a string` → `invalid UTF-8` on a multiply damaged run | Caught |
| Remove failure-path completed-run validation | `invalid UTF-8` → `unknown escape` | Caught |

## Existing helper tests

`logs/helper-final.log`: **117 executed, 114 passed, 3 skipped, 0 failures**.

| Class | Passed | Skipped |
|---|---:|---:|
| JSONParseTests | 6 | 0 |
| JSONParserDifferentialTests | 6 | 1 (opt-in Release benchmark) |
| OlderRowsTests | 4 | 0 |
| JournalCheckpointTests | 8 | 0 |
| JournalSlimmingTests | 10 | 0 |
| JournalPromotionTests | 3 | 2 (fault-harness entry points) |
| ForkAtReplyTests | 5 | 0 |
| EditRecoveryTests | 4 | 0 |
| MailboxCutPersistenceTests | 8 | 0 |
| SubagentCoordinatorTests | 23 | 0 |
| ToolInputDisplayTests | 9 | 0 |
| CredentialCaptureTests | 28 | 0 |

## Release measurements

Measured on the same Apple M3 Max (Virtual), macOS 14.8, Xcode 16.1 /
Swift 6.0.2 host, using arm64 Release helpers with `-Osize`. All 34
end-to-end trials (17 before, 17 after), the two final throughput trials and
three final profiles completed below one-minute load 4; no timing trial was
rejected. Start/end/peak loads are recorded below and in each `perf/*.json`.
The shared Mac's long compilation interval was waited out before the final
measurements; its high load is not included in any timing result.

### Throughput

The 50k fixture contains 63,252 lines (178,792,883 bytes excluding LF);
18,383 are tool-result lines (129,254,992 bytes). Three passes per corpus.

| Corpus | Before MiB/s | After MiB/s | Speedup |
|---|---:|---:|---:|
| All lines | 36.722 | 326.964 | 8.90× |
| Tool-output lines | 29.863 | 428.296 | 14.34× |

Final microbenchmark load, start / end / peak: before **2.85 / 2.37 / 2.85**;
after **2.37 / 2.24 / 2.37**. Checksums agree: 988,641 and 275,745.
`perf/json-final-micro-{reference,optimized}-1.log` contains the exact byte
counts and elapsed seconds. The preliminary string-only result was
36.228 → 266.816 MiB/s for all lines and 29.984 → 392.995 MiB/s for tools;
that exploratory binary used `-enable-testing`, as noted under Commands.

### Helper IPC

Wall time includes the complete command response and any display-transfer
reads. CPU is the helper process's user + system delta, including those
reads. Footprint is the process's cumulative peak at that operation, not an
allocation delta. For repeated cells each numeric column is its own median.
`cold` means a fresh helper opening a cloned journal with no checkpoint;
filesystem caches were not purged. Each warm helper opens its own prepared
checkpoint, requests the opening page, then `edge="start"`, then
`position=2500`. Every run checks the full expected row count.

All warm cells have three trials because the first next-page differences
were within 20%; 50k cold also has three to check its footprint variation.
The other cold speedups are large and use one accepted trial per variant.

| Fixture | Operation | Trials before / after | Wall ms, before → after | CPU s, before → after | Peak footprint MiB, before → after | Max 1-min load, before → after |
|---|---|---:|---:|---:|---:|---:|
| 10k | cold open | 1 / 1 | 1225.4 → 407.8 | 1.221 → 0.405 | 135.3 → 133.2 | 2.62 → 2.24 |
| 10k | checkpoint open | 3 / 3 | 11.3 → 11.8 | 0.010 → 0.011 | 5.6 → 6.1 | 2.65 → 2.24 |
| 10k | first older page | 3 / 3 | 1602.2 → 841.6 | 1.676 → 0.831 | 97.6 → 103.1 | 2.65 → 2.24 |
| 10k | next position page | 3 / 3 | 645.8 → 507.8 | 0.615 → 0.472 | 97.6 → 103.1 | 2.65 → 2.24 |
| 50k | cold open | 3 / 3 | 6460.7 → 2237.6 | 6.445 → 2.225 | 664.2 → 692.6 | 2.65 → 2.43 |
| 50k | checkpoint open | 3 / 3 | 27.6 → 21.7 | 0.026 → 0.020 | 6.7 → 6.8 | 2.65 → 2.19 |
| 50k | first older page | 3 / 3 | 6760.1 → 2414.2 | 6.909 → 2.467 | 459.0 → 472.1 | 2.65 → 2.19 |
| 50k | next position page | 3 / 3 | 560.3 → 520.7 | 0.552 → 0.485 | 459.0 → 472.1 | 2.65 → 2.19 |
| 200k | cold open | 1 / 1 | 26483.6 → 9534.3 | 26.401 → 9.461 | 2810.7 → 2807.8 | 2.45 → 2.12 |
| 200k | checkpoint open | 3 / 3 | 35.0 → 24.8 | 0.033 → 0.023 | 7.9 → 7.8 | 2.65 → 2.43 |
| 200k | first older page | 3 / 3 | 25702.5 → 8609.5 | 26.265 → 8.990 | 1703.7 → 1773.9 | 2.65 → 2.43 |
| 200k | next position page | 3 / 3 | 577.9 → 504.1 | 0.576 → 0.477 | 1703.7 → 1773.9 | 2.65 → 2.43 |

The 10k checkpoint open is essentially unchanged (11.3 → 11.8 ms).
The repeated next-page medians remain roughly half a second; the profile
below explains that remaining cost. Peak footprint is modestly higher in
several repeated cells (50k cold: 664.2 → 692.6 MiB; 200k warm:
1,703.7 → 1,773.9 MiB). The 200k cold peak remains about 2,808 MiB.
This change has no app/first-paint or persistent-index measurements.

### Profiles and work left for the lead

Profiles use `sample <fixture-pid> 10 10` separately from timing trials.
Counts below are sampled stack observations, not wall-time percentages.
Raw profiles, `profile-summary.py`, `profile-attribution.py`, their summaries,
and helper dSYM are retained in the build root.

- **Parser follow-up:** nearest parser-function attribution, excluding nested
  parser callees: string-only profile, 781 observations: escaped strings 318,
  plain strings 122, objects 250, numbers 9. Final profile, 779 observations:
  escaped strings 372, plain strings 123, objects 167, numbers 8, whitespace 2.
  The dictionary change follows the measured object cost. There is no evidence
  here for replacing `Double(_:)` or complicating whitespace scanning.
- **Cold replay still does substantial non-parser work:** the active opening
  worker has 804 observations. Parsing accounts for 184 (185 across all
  threads); escaped strings account for 86. `JSON.data()` has 117 observations
  across the process, including 91 at `SessionReplay.swift:185`: the task
  terminal record's JSON is encoded for `JSONDecoder` to construct
  `TaskPresentationRecord`. `ChatMessage.init(id:pi:)` has 97, and
  `JournalLineScan` 63. These counts overlap where a caller contains another.
  Locations were resolved with the matching dSYM. These callers and encoding
  remain unchanged.
- **Warm page cost is now dominated by encoding:** after building the index,
  a separate 50k probe reads positions 3500, 4500, …, 22500. Its sample has
  749 work observations after excluding 7,652 work-queue sleeps, 816 Mach
  message waits and 798 stdin reads. `JSON.data()` contains **612** of these;
  parser frames contain **22**, and `storedRow` contains **39** (overlapping).
  Encoding callers: **381** at `HostService.swift:181` (encode the bounded
  reply), **110** at `HostService.swift:184` (encode the result for transfer
  after the envelope exceeds the frame limit), **108** at
  `SessionReads.swift:104` (encode each row to weigh the page), eight through
  `JSON.encoded()` and five through `ChatMessage.init`. This is the remaining
  measured cost to consider in the lead's paging/publication work. The
  encoder's canonical bytes, digest/checkpoint consumers, framing and callers
  were not changed.
- The app, whole-journal replay/index policy and publication work stay with
  the lead's other workstream. The unrelated full Release test-target build
  issue is described under Commands; it does not affect the production helper
  build, the standalone Release benchmark or the required wire gates.

Profile load, start / end / peak: final micro **2.14 / 2.68 / 2.74**;
cold helper **2.10 / 2.14 / 2.17**; warm pages **2.39 / 2.61 / 2.61**.
The preliminary micro profile was **2.42 / 2.58 / 2.69**.

### Release wire contract

| Suite | Passed | Failures | Start / end / peak 1-min load |
|---|---:|---:|---:|
| Wire | 41 | 0 | 2.74 / 2.44 / 2.74 |
| Concurrent | 4 | 0 | 2.44 / 2.07 / 2.44 |
| Acceptance | 3 | 0 | 2.07 / 2.07 / 2.07 |

Exact commands match `verify-release.sh`; `run-wire-gates.py` holds the
shared lock with `perf` in its owner for each suite and records load every
two seconds. Raw evidence: `logs/release-{wire,concurrent,acceptance}.log`,
`wire-gates.json`. All checks use generated data and loopback fixtures.

### End-to-end quiet-window ledger

Each entry is start / end / observed peak one-minute load. All exits are zero.
The three-value raw `vm.loadavg` strings and two-second samples are retained
in the corresponding `perf/<trial>.json`; their helper hashes were checked
against `evidence-info.json` for every before/after trial.

| Trial | Start / end / peak |
|---|---:|
| json-after-cold-10k-1 | 2.24 / 2.24 / 2.24 |
| json-after-cold-200k-1 | 2.12 / 2.03 / 2.12 |
| json-after-cold-50k-1 | 2.24 / 2.22 / 2.24 |
| json-after-cold-50k-2 | 2.08 / 2.07 / 2.08 |
| json-after-cold-50k-3 | 2.43 / 2.39 / 2.43 |
| json-after-prepare-10k-1 | 2.24 / 2.24 / 2.24 |
| json-after-prepare-200k-1 | 2.03 / 1.94 / 2.03 |
| json-after-prepare-50k-1 | 2.22 / 2.12 / 2.22 |
| json-after-warm-10k-1 | 2.24 / 2.24 / 2.24 |
| json-after-warm-10k-2 | 2.19 / 2.19 / 2.19 |
| json-after-warm-10k-3 | 2.07 / 2.07 / 2.07 |
| json-after-warm-200k-1 | 1.94 / 2.10 / 2.11 |
| json-after-warm-200k-2 | 2.17 / 2.08 / 2.17 |
| json-after-warm-200k-3 | 2.14 / 2.43 / 2.43 |
| json-after-warm-50k-1 | 2.12 / 2.12 / 2.12 |
| json-after-warm-50k-2 | 2.19 / 2.17 / 2.19 |
| json-after-warm-50k-3 | 2.07 / 2.14 / 2.14 |
| json-before-cold-10k-1 | 2.58 / 2.62 / 2.62 |
| json-before-cold-200k-1 | 2.41 / 2.45 / 2.45 |
| json-before-cold-50k-1 | 2.65 / 2.52 / 2.65 |
| json-before-cold-50k-2 | 2.59 / 2.49 / 2.62 |
| json-before-cold-50k-3 | 2.31 / 2.19 / 2.31 |
| json-before-prepare-10k-1 | 2.62 / 2.62 / 2.62 |
| json-before-prepare-200k-1 | 2.45 / 2.22 / 2.45 |
| json-before-prepare-50k-1 | 2.52 / 2.44 / 2.52 |
| json-before-warm-10k-1 | 2.62 / 2.65 / 2.65 |
| json-before-warm-10k-2 | 2.58 / 2.58 / 2.58 |
| json-before-warm-10k-3 | 2.49 / 2.49 / 2.49 |
| json-before-warm-200k-1 | 2.22 / 2.06 / 2.28 |
| json-before-warm-200k-2 | 2.65 / 2.59 / 2.65 |
| json-before-warm-200k-3 | 2.56 / 2.31 / 2.56 |
| json-before-warm-50k-1 | 2.44 / 2.41 / 2.44 |
| json-before-warm-50k-2 | 2.58 / 2.65 / 2.65 |
| json-before-warm-50k-3 | 2.49 / 2.56 / 2.61 |

The detached baseline worktree, baseline bundle/dSYM and baseline scratch
build were removed after the repeats. The final optimized bundle and raw
results remain in `PI_BUILD_ROOT`. No raw evidence is committed to the repo.


## Commands and reproducibility

Run from this worktree in zsh. `run-when-quiet.py` is a small evidence-side
wrapper: check `full-lane.lock/owner`, and while it names `perf`/`soak`, wait
60 seconds before retrying. The benchmark/matrix runner owns the shared lock
with `perf` in its owner, samples `vm.loadavg` every two seconds, and rejects
and retries any trial exceeding one-minute load 4. The start threshold is 3.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
mkdir -p "$PI_BUILD_ROOT/fixtures" "$PI_BUILD_ROOT/logs" "$PI_BUILD_ROOT/scratch"
cp -c -R /Users/admin/Library/Caches/BelloSwiftWork/build-a136-perf/fixtures/{10k,50k,200k} "$PI_BUILD_ROOT/fixtures/"
python3 scripts/perf-longchat-fixture.py "$PI_BUILD_ROOT/fixtures/10k-differential" --messages 10000
xcodegen generate --quiet

PI_JSON_FIXTURE_JOURNAL="$PI_BUILD_ROOT/fixtures/10k-differential/chat.jsonl" \
PI_JSON_FUZZ_COUNT=1000000 TMPDIR="$PI_BUILD_ROOT/scratch/" \
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --jobs 2 --filter 'JSONParserDifferentialTests|JSONParseTests|OlderRowsTests|JournalCheckpointTests|JournalSlimmingTests|JournalPromotionTests|ForkAtReplyTests|EditRecoveryTests|MailboxCutPersistenceTests|SubagentCoordinatorTests|ToolInputDisplayTests|CredentialCaptureTests'
python3 "$PI_BUILD_ROOT/run-mutations.py"
PI_JSON_FIXTURE_JOURNAL="$PI_BUILD_ROOT/fixtures/10k-differential/chat.jsonl" \
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --jobs 2 --filter JSONParserDifferentialTests
```

The detached baseline and its bundle were under the same build root. The
manual build uses the same Release/arm64/`-Osize` settings as `build-bundle.py`;
that script refuses a source worktree nested under its build root, hence the
explicit baseline invocation. Before trials, its stripped executable was
installed at the runner's fixed `bundle/Helpers/pi-native-host` path.

```sh
git worktree add --detach "$PI_BUILD_ROOT/before-source" 6d38ddd4
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift build \
  --package-path "$PI_BUILD_ROOT/before-source/packages/swift-host" \
  --scratch-path "$PI_BUILD_ROOT/swift-before" -c release --arch arm64 \
  --jobs 2 --product pi-native-host -Xswiftc -Osize
mkdir -p "$PI_BUILD_ROOT/bundle-before/Helpers" "$PI_BUILD_ROOT/bundle/Helpers"
cp "$PI_BUILD_ROOT/swift-before/arm64-apple-macosx/release/pi-native-host" "$PI_BUILD_ROOT/bundle-before/Helpers/"
xcrun dsymutil "$PI_BUILD_ROOT/bundle-before/Helpers/pi-native-host" -o "$PI_BUILD_ROOT/before.dSYM"
xcrun strip -S "$PI_BUILD_ROOT/bundle-before/Helpers/pi-native-host"
cp "$PI_BUILD_ROOT/bundle-before/Helpers/pi-native-host" "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 "$PI_BUILD_ROOT/run-helper-matrix.py" before

# Final production helper, after restoring every mutation.
python3 "$PI_BUILD_ROOT/run-when-quiet.py" python3 scripts/build-bundle.py
python3 "$PI_BUILD_ROOT/run-helper-matrix.py" after
```

`run-helper-matrix.py before|after` runs exactly these commands for each of
`10k`, `50k`, `200k`, in that order, substituting the variant and size:

```sh
python3 scripts/perf-longchat-run.py --label "json-$VARIANT-cold-$SIZE" \
  --start-load 3.0 --attempts 5 -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/$SIZE" --cold
python3 scripts/perf-longchat-run.py --label "json-$VARIANT-prepare-$SIZE" \
  --start-load 3.0 --attempts 5 -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/$SIZE" --prepare
python3 scripts/perf-longchat-run.py --label "json-$VARIANT-warm-$SIZE" \
  --start-load 3.0 --attempts 5 -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/$SIZE"
```

The microbenchmark preloads the 50k journal, filters tool-result lines with
its frozen parser outside the timer, and parses each selected line three
complete times. It consumes each JSON object's member count and prints a
checksum, line count, byte count, seconds and MiB/s. Both parsers use the same
executable and optimization mode; the optimized path is the production
`JSON.parse` linked from the actual Release helper objects. The reference is
compiled verbatim with `-Osize` and whole-module optimization. Newline framing
bytes are excluded from the throughput denominator.

```sh
BIN="$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release"
TMPDIR="$PI_BUILD_ROOT/scratch/" python3 "$PI_BUILD_ROOT/run-when-quiet.py" \
  swiftc -Osize -whole-module-optimization -emit-executable \
  -module-name JSONParserBenchmarkDriver -target arm64-apple-macosx13.0 \
  -DJSON_PARSER_BENCHMARK_MAIN -I "$BIN/Modules" \
  packages/swift-host/Tests/PiAgentCoreTests/{ReferenceJSONByteParser,JSONParserBenchmark}.swift \
  "$BIN"/PiAgentCore.build/*.o -o "$PI_BUILD_ROOT/json-benchmark"
for parser in reference optimized; do
  PI_JSON_BENCHMARK_JOURNAL="$PI_BUILD_ROOT/fixtures/50k/chat.jsonl" \
  PI_JSON_BENCHMARK_PARSER="$parser" \
  python3 scripts/perf-longchat-run.py --label "json-final-micro-$parser" \
    --attempts 5 -- "$PI_BUILD_ROOT/json-benchmark"
done
python3 scripts/perf-longchat-run.py --label json-final-helper-profile \
  --profile --attempts 5 -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/200k" --cold
PI_JSON_BENCHMARK_JOURNAL="$PI_BUILD_ROOT/fixtures/50k/chat.jsonl" \
PI_JSON_BENCHMARK_ITERATIONS=50 python3 scripts/perf-longchat-run.py \
  --label json-final-micro-profile --profile --profile-after JSON_BENCHMARK_START \
  --attempts 5 -- "$PI_BUILD_ROOT/json-benchmark"
```

The exploratory string-only microbenchmark used the same standalone driver
linked to the Release module built with `-enable-testing`; its raw labels are
`json-micro-*`. The final measurements above use the production bundle build.
An attempted Release build of the entire helper test target first lacked
`-enable-testing`, then exposed the existing DEBUG-only `SideOriginReadProbe`
references in `SideOriginIndexTests.swift:25` (and later lines), whose probe
is guarded in `Sources/PiAgentCore/SideOriginReadProbe.swift:5`. This unrelated
Release-test compilation issue was not changed. The standalone benchmark
avoids it; helper tests run in their supported Debug configuration.


Page repeats and the remaining-page profile:

```sh
# Saves the optimized helper, installs each variant in turn, runs two more
# warm trials at each size plus two more 50k cold trials, and restores it.
python3 "$PI_BUILD_ROOT/repeat-pages.py"
# profile-pages.py is a measurement-only copy of perf-longchat-helper.py:
# after its existing page calls, print PERF136_NEXT_PAGE_PROFILE and loop
# command("session.history", dict(version=2, position=position), "long")
# for position in range(3500, 23500, 1000). No production caller is edited.
PYTHONPATH="$PWD/scripts" python3 scripts/perf-longchat-run.py \
  --label json-final-page-profile --profile \
  --profile-after PERF136_NEXT_PAGE_PROFILE --attempts 5 -- \
  python3 "$PI_BUILD_ROOT/profile-pages.py" "$PI_BUILD_ROOT/fixtures/50k"

python3 "$PI_BUILD_ROOT/run-wire-gates.py"
# The three commands executed inside that lock/load wrapper:
HOST="$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"

git diff --check
```

Artifact SHA-256 (full metadata in `evidence-info.json`):

- Baseline helper: `11346bc51ea83a860d7eae44b3ab52bb240ba40b294f223cdb56c643d3580178`.
- Final bundled helper: `719e68a5320f2c420aeaaa3ac3f0bfff5ef02dd25823375a107932e537d71146`.
- Final benchmark: `c2b67910ed965f1962eb48f47d9d1e37f6ed43d8d354d616a3ef687198a0f738`.

`xcodegen generate --quiet` leaves the project unchanged; `git diff --check`
passes. There are no parser disagreements or remaining requested checks.
The lead reviews and merges this branch; `NEXT-RELEASE.md` is untouched.
