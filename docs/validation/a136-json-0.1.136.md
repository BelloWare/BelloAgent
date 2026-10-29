# 0.1.136 PERF-1 phase B: helper JSON parsing

Implementer: Codex. Reviewer/merge owner: the lead. Branch `dev/a136-json`,
based on `6d38ddd435339bd6d1d71f71d42eb59be695b5f7` (phase A plus `dev/next`).
All generated data, builds, logs and profiles live under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json` (`PI_BUILD_ROOT`).
Round 1 changes only the parser. Round 2, below, covers opening progress,
cancellation and checkpoint refresh. Journal formats and JSON encoding stay unchanged.

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
| 50k exchanges | cold open | 1 / 1 | 57140.7 → 23443.3 | 56.870 → 22.991 | 5305.7 → 5355.3 | 2.91 → 3.26 |
| 50k exchanges | checkpoint open | 3 / 3 | 27.2 → 20.6 | 0.026 → 0.019 | 7.4 → 6.6 | 2.91 → 2.65 |
| 50k exchanges | first older page | 3 / 3 | 52138.1 → 17570.2 | 52.793 → 18.161 | 3243.0 → 3320.2 | 2.91 → 2.65 |
| 50k exchanges | next position page | 3 / 3 | 615.5 → 664.4 | 0.888 → 0.963 | 3243.0 → 3320.2 | 2.91 → 2.65 |

The missing 50k-exchange cells were added at the start of round 2, using
`6d38ddd4` versus the unchanged `d8d0ad32` helper, before any round-2 code.
The warm cells have three trials because next-page differences are within
20%. Raw commands, load samples and results: `round2/run-round1-extra.py`,
`round2/round1-exchanges-summary.json`, and `perf/json-{before,after}-{cold,prepare,warm}-50k-exchanges-*`.
The baseline detached worktree, scratch build and bundle were deleted after
these trials. The round-1 bundle remains separate for this round's comparisons.

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

## Round 2 — progress-aware opening (item 4)

The lead accepted `d8d0ad32`. Before this round, `origin/dev/next` was merged
as `a62cc25b`, bringing `efc85e72` and its synthetic gateway parent-death
cleanup. No release or other stream's branch was changed.

### Contract and ownership

The app's hello opts into `commandProgress: true`. The helper advertises
`command-progress-v1` and `open-cancel-v1`; neither is a required handshake
capability. Only an opted-in connection receives the new frame:

```json
{"v":1,"kind":"command.progress","hostEpoch":"epoch","commandId":"command","completed":1048576,"total":8388608}
```

`completed` and `total` are bounded nonnegative integer byte counts, with a
positive, fixed total. Opening reports the journal validation and replay
passes against twice the captured file size. A checkpoint can skip its
validated prefix. Whole-journal history reads report their captured replay
prefix. Shared history readers subscribe to the worker's actual progress;
a reader does not own the shared worker or manufacture timer events. Work
updates check the clock only after 64 KiB of advancement and emit at most
once per 250 ms. Waiting on a runtime gate or a writer lock emits nothing.

The supervisor starts its existing 30-second deadline when a command is
dispatched. A same-connection, same-epoch, same-command observation renews
it only if completion strictly increases under the original bound. Invalid,
repeated, regressing, foreign and post-cancel observations do not renew it.
The timeout's generation also fences an already-enqueued old timer. Old
helpers keep the fixed deadline; old apps receive no new frame kind.

A cancellable open carries the existing `readToken` control identity. The
helper accepts `read.cancel` for that exact open and checks cancellation in
journal validation, checkpoint row loading, replay, and before publication.
The cancellation handler reaches the detached construction task. An open's
runtime remains unpublished until configuration and snapshot work finish;
errors close it. Shutdown awaits opening workers as well as loaded sessions,
so its completion also follows writer-lock release.

The app's shared `sessionOpenings` task is cancelled only by Cancel or the
existing teardown paths. A selection change leaves it alive. A separate
`sessionClosings` fence waits for the physical reply before withdrawing an
unadopted runtime. `session.close(openingCommandId:)` can withdraw the newly
created runtime belonging to that open, including durable recovered queued
input, until a subsequent open claims it. It cannot stop newly active work.
Older helpers use ordinary close after their late reply. Retry waits for
this cleanup, and a cancelled first open can resume its own canonical
journal even if the path had not yet been published in the chat record.

### What the user sees

After the existing short opening threshold (150 ms), the conversation canvas
shows “Opening chat…” with determinate percentage and a PiKit Cancel button.
Before the first observation, or with an old helper, it says “Preparing the
saved conversation…”. Cancel changes this to “Cancelling opening…” while the
worker releases its writer, then “Opening cancelled” with Retry. A real
failure shows its error with Retry. The transcript's independent opening
page/fill state is untouched.

The pending-send failure path is preserved. Cancel returns the unsent text
to the composer and shows **“Opening cancelled. Your message was not sent.”**
It removes the undispatched send intent and its sending placeholder, and
does not mark the message's outcome uncertain. A failed open likewise
returns the draft and shows the actual error. Retry only opens the chat;
it does not resend that draft. The tests check the durable intent store as
well as the composer, including cancellation after the helper has already
replied and disconnection before adoption.

### Failing-first and mutation evidence

Before implementation, `OpeningProgressTests` ran two cases and failed three
assertions: a pre-cancelled replay still opened and the two new capabilities
were absent (`round2/item4-helper-failing-first.log`). The app's fake-clock
80-second advancing open failed with the original acknowledgment timeout
(`round2/item4-app-failing-first-2.log`: one test, one failure).

The first Debug app build exposed the existing unconditional Debug skip in
`LongChatPerformanceTests.swift` as an unreachable-code warning promoted to
an error. That unrelated source is unchanged. Focused Debug commands set
`SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`; the new performance test uses a complete
compile-time Release/Debug branch and does not add that warning.

Removing detached-worker cancellation made all four validation/replay
cancellation points continue to 100%, failing four assertions in one test
(`round2/item4-mutation-cancel.log`). The production handler was restored;
the subsequent 39-case helper run passed 38 and skipped one optional case.

### Scope

Besides the assigned supervisor/opening/replay files, the opening UI needs
small integration changes in `ConversationPane.swift`, `SessionDisplay.swift`
and the opening test seam in `WorkspaceModel.swift`. The shared history-work
progress hook is in `HistoryReadWait.swift` and `SessionHistoryFill.swift`. Two observer lines in `SessionOlderRows.swift`
forward the background preparation replay to a waiting full-history reader.
`HostService.swift` changes are restricted to frame negotiation/delivery,
opening construction/publication and opening cleanup. No changes to
`SessionReads.swift`, source-description selection, app history/paging,
opening fill, Find, transcript rows or `NEXT-RELEASE.md`.

The background preparation regression also failed before forwarding was
added (`item4-preparation-failing-first.log`: one test, one assertion), then
passed. Final focused helper run: **100 executed, 97 passed, 3 skipped,
0 failures** (`item4-helper-final.log`). The classes were OpeningProgress,
HostService, HostDispatch, HistoryReadCancellation, HistoryFill,
JournalCheckpoint, OlderRows, ReplayParity, DurableReplay, JournalPromotion,
MailboxCutPersistence and SubagentCoordinator.

All three supervisor mutations were compiled separately and caught by their
specific fake-clock tests: renew on repeated completion, ignore host epoch,
and ignore command identity. Each produced one expected failed assertion.
Dropping detached cancellation was the fourth caught mutation. Mutation
runners, logs and JSON results are in `round2/item4-{app,helper}-mutation*`.
After restoring the supervisor, all **12 new app tests passed** again.

A preliminary app run staged empty helper directories while an independent
helper bundle rebuild was in progress; its 12 tests failed before reaching
their intended checks. Staging was rerun after the helper finished, and all
12 passed. Subsequent helper staging and app builds are sequential.

### Release app checks and gallery

The isolated Release test host and bundled helper were built sequentially.
The helper embedded in the test host and the measurement bundle both hash to
`9f64dc2bc0d55b97f2b34a389556e086716d05f34d5a1dd3fe11c7775efd0030`.
The app checks passed **92 tests, zero failures**:

| Class | Passed |
|---|---:|
| OpeningDeadlineTests | 9 |
| WorkspaceOpeningProgressTests | 3 |
| WorkspaceConcurrencyTests | 12 |
| TabHostTests | 17 |
| CostLimitOpeningTests | 1 |
| HostSupervisorTests (alone) | 12 |
| FinishedChatOpeningTests (alone, opt-in, one round) | 1 |
| SubagentOpeningTests (alone) | 15 |
| FreshPresentationTests (alone) | 21 |
| OpeningProgressGalleryTests (alone) | 1 |

The first FinishedChatOpening invocation omitted its opt-in variable and
skipped; it is not counted above. Two attempts to run that probe through
the timing wrapper were aborted at load 4.09 and 4.94. Those discarded
attempts supply no timing evidence. The remaining serial app classes and
gallery then ran as functional checks under the shared lock. Their load
samples are retained in `round2/item4-functional-release.json`; no speed
figures from those functional runs are used. The required cold-open,
reporting-cost and cancellation measurements retain the load-at-most-4 gate.

Gallery output: `/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json/round2/gallery/`.
All **20 PNGs were opened and inspected**: readable labels, visible actions,
correct disabled Cancel during unwind, and no clipping at either width.
The filenames are `opening-<state>-<width>-<theme>.png`, with each combination
of state `progress`, `legacy`, `cancelling`, `cancelled`, `failure`; width
`840`, `320`; and theme `light`, `dark`. The view uses PiKit ProgressBar and
Button, shell text components, and existing typography/spacing/color tokens.

Raw app evidence: `perf/json-item4-app-affected-1.*`,
`perf/json-item4-HostSupervisorTests-1.*`, and
`round2/item4-functional-<Class>.log`. No full app or helper suite was run.

### Production deadline, reporting cost, cancellation

These are fresh helper opens of fresh APFS journal clones without metadata,
using the actual Release `HostSupervisor` and its default **30-second**
inactivity deadline. No 180-second override is used. The `quiet` control
opts out of progress in hello; `progress` opts in. Three trials per cell,
interleaved in alternating order. Each numeric column is its own median;
footprint is the helper process's lifetime peak. This measures helper/IPC
reporting through the supervisor, without the conversation canvas mounted.

| Fixture | Reporting | Trials | Open ms | CPU s | Peak MiB | Max 1-min load |
|---|---|---:|---:|---:|---:|---:|
| 200k | quiet | 3 | 10217.5 | 10.138 | 2854.3 | 3.82 |
| 200k | progress | 3 | 10227.4 | 10.145 | 2824.3 | 2.92 |
| 50k-exchanges | quiet | 3 | 20420.7 | 20.161 | 5403.9 | 2.96 |
| 50k-exchanges | progress | 3 | 20075.3 | 19.834 | 5406.3 | 2.92 |

Reporting changes the median by **+0.10%** at 200k and **−1.69%** at
50k exchanges, within the observed variation. It has no measurable added
cost in this sample. The 200k quiet/progress wall ranges are 10,089–10,500 /
10,088–10,331 ms; the exchange ranges are 20,417–21,866 / 19,466–20,480 ms.

The app received 39–40 progress observations per 200k open and 74–77 per
50k-exchange open. App-observed median cadence is 250.40 / 250.47 ms;
p95 is 254.19 / 255.16 ms; maximum is 261.42 / 265.26 ms. Delivery jitter
can make received intervals slightly shorter than the helper's 250 ms
emission interval. The fake-clock unit test pins the emission limit itself.

Cancel was sent at the first observation at or above 65% of total work,
after validation and during replay of the 50k-exchange journal. All three
trials received cancellation, waited for physical command settlement, and
successfully acquired the journal's exclusive writer lock. Cancel-to-stopped
and-lock-released latency: **127.70 / 128.60 / 141.24 ms** (minimum / median /
maximum). Maximum observed load was 2.92. Median total time from open to
cancellation completion was 7,903.0 ms, helper CPU 7.717 s, peak 2,403.1 MiB.

One initial successful probe was rejected by the standard wrapper's unrelated
`PERF136` page-row logging check: this opening-only test emits `OPENING136`.
`round2/opening-run.py` applies the standard wrapper unchanged except for
validating this test's own marker: one result, production deadline 30,
expected mode, positive elapsed time, advancing bounded progress (or none
for the opt-out control), and positive cancellation latency when cancelling.
XCTest still asserts cancellation and actual lock release. The clone, artifact,
lock and load checks are unchanged. That initial rejected probe is excluded.
Two later cold trials were aborted at load 7.18 and 4.36 and rerun successfully.

Accepted timing ledger (start / end / peak one-minute load):

| Raw trial | Load |
|---|---:|
| json-item4-200k-progress-r1-1 | 2.90 / 2.76 / 2.91 |
| json-item4-200k-progress-r2-2 | 2.92 / 2.50 / 2.92 |
| json-item4-200k-progress-r3-1 | 2.54 / 2.51 / 2.54 |
| json-item4-200k-quiet-r1-2 | 2.97 / 2.89 / 2.97 |
| json-item4-200k-quiet-r2-1 | 2.50 / 3.82 / 3.82 |
| json-item4-200k-quiet-r3-1 | 2.82 / 3.16 / 3.16 |
| json-item4-50k-exchanges-cancel-r1-1 | 2.52 / 2.60 / 2.60 |
| json-item4-50k-exchanges-cancel-r2-1 | 2.60 / 2.74 / 2.74 |
| json-item4-50k-exchanges-cancel-r3-1 | 2.74 / 2.85 / 2.92 |
| json-item4-50k-exchanges-progress-r1-1 | 2.73 / 2.75 / 2.79 |
| json-item4-50k-exchanges-progress-r2-2 | 2.92 / 2.52 / 2.92 |
| json-item4-50k-exchanges-progress-r3-1 | 2.67 / 2.48 / 2.67 |
| json-item4-50k-exchanges-quiet-r1-1 | 2.76 / 2.73 / 2.96 |
| json-item4-50k-exchanges-quiet-r2-1 | 2.72 / 2.82 / 2.82 |
| json-item4-50k-exchanges-quiet-r3-1 | 2.51 / 2.67 / 2.95 |

Raw per-observation counts/timestamps, CPU and footprint are retained in
`perf/json-item4-*.{log,json}` and `round2/item4-release-summary.json`.

### Release wire gates

| Suite | Passed | Failures | Start / end / peak 1-min load |
|---|---:|---:|---:|
| wire | 41 | 0 | 2.85 / 2.07 / 2.85 |
| concurrent | 4 | 0 | 2.07 / 1.92 / 2.07 |
| acceptance | 3 | 0 | 1.92 / 1.76 / 1.92 |
| opening | 4 | 0 | 1.76 / 2.19 / 2.27 |

The four new wire cases cover old-app opt-out, cold-open and checkpoint
history progress, cancel followed by lock release/no runtime, and EOF during
open followed by writer release. Raw logs are `round2/item4-release-*.log`;
commands and two-second load samples are in `round2/item4-wire-gates.json`.
A process inventory after app checks found **zero UI gateways from this
worktree** (`round2/item4-gateway-check.json`).

### Round-2 item-4 commands

All commands export the same root and run in `wt-a136-json`:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
python3 "$PI_BUILD_ROOT/round2/run-round1-extra.py"
python3 "$PI_BUILD_ROOT/run-when-quiet.py" python3 scripts/build-bundle.py
python3 "$PI_BUILD_ROOT/run-when-quiet.py" xcodebuild build-for-testing   -project PiApp.xcodeproj -scheme PiApp -configuration Release   -destination platform=macOS,arch=arm64 -jobs 2   -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES   CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO   PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2
```

The raw command files retain every filter and environment variable:
`round2/item4-release-measure.py` for the initial 42-test batch and standalone
HostSupervisorTests; `round2/item4-functional-release.py` for the remaining
serial classes and gallery; `round2/item4-release-timings.py` for the 15
accepted cold/control/cancel trials, using `round2/opening-run.py`; and
`round2/item4-wire-gates.py` for 41 / 4 / 3 / 4 wire cases. Each app invocation
uses this checked, isolated manifest and runs one serial class at a time:

```sh
python3 scripts/check-test-host.py   "$PI_BUILD_ROOT/release/Build/Products/PiApp_macosx15.1-arm64.xctestrun"
xcodebuild test-without-building   -xctestrun "$PI_BUILD_ROOT/release/Build/Products/PiApp_macosx15.1-arm64.xctestrun"   -derivedDataPath "$PI_BUILD_ROOT/release" -destination platform=macOS,arch=arm64   -parallel-testing-enabled NO -collect-test-diagnostics never   -only-testing:PiAppTests/<Class>
```

For each timing cell the wrapper receives `--label json-item4-<fixture>-<mode>-r<N>
--start-load 3 --attempts 5 --fixture "$PI_BUILD_ROOT/fixtures/<fixture>/chat.jsonl"`
and `TEST_RUNNER_PI_OPENING_PROBE=quiet|progress|cancel`. Gallery uses
`TEST_RUNNER_PI_APP_OPENING_GALLERY="$PI_BUILD_ROOT/round2/gallery"`.
FinishedChatOpening's functional check uses `TEST_RUNNER_PI_OPEN_PROBE=1`
and `TEST_RUNNER_PI_OPEN_PROBE_ROUNDS=1`.

```sh
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test   --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify"   -j 2 --filter 'OpeningProgressTests|HostServiceTests|HostDispatchTests|HistoryReadCancellationTests|HistoryFillTests|JournalCheckpointTests|OlderRowsTests|ReplayParityTests|DurableReplayTests|JournalPromotionTests|MailboxCutPersistenceTests|SubagentCoordinatorTests'
python3 "$PI_BUILD_ROOT/round2/item4-app-mutations.py"
python3 "$PI_BUILD_ROOT/round2/item4-helper-mutation.py"
HOST="$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
python3 scripts/test-opening-progress.py --binary "$HOST"   --fixture "$PI_BUILD_ROOT/fixtures/50k-exchanges/chat.jsonl"
```

Wire commands above execute inside the lock/load wrapper. The temporary
baseline worktree and baseline bundle from the missing round-1 cell were
removed. Item 4 has no unresolved functional failure. The optional replay/
encoding optimizations are not included in this item.

## Round 2 — bounded checkpoint refresh (item 10)

### Measure-first decision

Before item-10 implementation, the unchanged round-1 parser helper opened
real helper-created checkpoints followed by generated ordinary durable turns.
Each turn contains user text, an assistant tool call, a 32 KiB tool result,
assistant final text, and a settled state record. The crossing case compacts
halfway through 50 MiB and retains two turns. The journals and metadata are
APFS clones below this stream's build root; no phase-A fixture is modified.

| Base fixture | Suffix MiB | Crosses compaction | Open ms | CPU s | Peak MiB |
|---|---:|---|---:|---:|---:|
| 50k | 10.03 | no | 106.7 | 0.104 | 48.8 |
| 50k | 50.03 | no | 630.7 | 0.629 | 224.4 |
| 50k | 200.03 | no | 1962.3 | 1.970 | 858.1 |
| 50k | 50.03 | yes | 501.2 | 0.482 | 219.5 |
| 50k exchanges | 10.03 | no | 221.2 | 0.213 | 52.0 |
| 50k exchanges | 50.03 | no | 511.4 | 0.512 | 221.3 |
| 50k exchanges | 200.03 | no | 2099.5 | 2.107 | 867.5 |
| 50k exchanges | 50.03 | yes | 567.3 | 0.562 | 213.2 |

All eight trials exited zero with accepted load (maximum 2.31). Raw evidence:
`round2/suffix-probe.py`, `round2/run-suffix-matrix.py`,
`round2/item10-baseline-summary.json`, and `perf/json-round1-suffix-*`.
The 200 MiB suffix takes about two seconds, so the requested implementation
condition is met. The 10 MiB case alone would not justify it.

### Change and bounds

After a settled state is durably flushed, a session schedules one utility
worker after 8 MiB or 60 seconds of new journal data. Scheduling captures a
fixed flushed prefix and the kept replay's value; it does not serialize live
state on the session actor. A later settled turn coalesces into the next
worker. Replay yields between 32 MiB batches and checks cancellation at each
record. Close/unload cancel and join the worker before releasing the journal.

The checkpoint is derived only from journal replay. Its final record must
be the exact settled state at the captured prefix, with no delivering input,
unresolved command receipts or unresolved accounted request. Incomplete cut
preparations/projections are refused. Complete receipts, cuts, family state,
accounting, context and edit lineage are retained without truncation. The
context must fit within the last 32,768 visible rows; otherwise refresh is
skipped. A conservative counting Encoder bounds metadata work before JSON
construction; the final encoded metadata is independently capped at 8 MiB.
Oversized/unsafe prefixes keep the previous checkpoint.

Encoding and temporary-file writes happen off the session actor. The actor
checks journal identity, marker, generation and prefix ordering before the
existing atomic rename. A newer compaction/edit checkpoint cannot be replaced
by an older background result. The checkpoint format and canonical JSON
encoder are unchanged. Long opening replays also publish validated settled
prefixes at 64 MiB/60-second intervals, and a remaining eligible suffix at
EOF. Full history-reader replays do not write metadata.

### Tests and mutations

The first test failed before implementation: a settled suffix did not advance
the checkpoint before close (one test, two recorded failures including the
poll timeout; `round2/item10-failing-first.log`). The crash-copy test copies
the journal and cache while the writer is still alive, then verifies that the
copy reopens from the newer checkpoint with the completed command and a
journal-only row absent from the live projection.

Eight new tests passed (`round2/item10-new-tests.log`). They cover crash-copy reopen, failed replacement and
temporary cleanup, exact settled-prefix eligibility, complete and partial
cuts with family/accounting/receipt parity, metadata/context limits, long
replay publication, inherited edit lineage, and the time threshold.
The affected helper run executed 120 tests: 118 passed, two optional cases
skipped, no failures (`round2/item10-helper-affected.log`).

Both required mutations failed their targeted test: removing turn-end
scheduling produced the missing-refresh timeout (one test, two failures),
and dropping exact durable-prefix coverage accepted an unsettled tail (one
test, one assertion). Sources were restored before the affected run.
Raw scripts/results: `round2/item10-mutations.py`, `item10-mutations.json`,
and `item10-mutation-{scheduling,durable-prefix}.log`.

An intermediate compile was discarded because a test source changed while
Swift was still building it. The subsequent complete build and eight-test
run passed (`item10-new-tests.log`); no result from the interrupted build is
counted as validation.

### Release suffix comparison

Three accepted trials per cell, interleaved before/after by round. Both
helpers use the round-1 parser. “Before” is `d8d0ad32`; “after” includes
items 4 and 10. Each trial starts from a fresh APFS clone of the same warm
checkpoint and generated suffix. The first helper exits; a second, fresh
helper measures the checkpoint actually left by that open. CPU and peak
footprint therefore belong to each process separately.

The initial open includes replay and checkpoint publication:

| Base | Suffix MiB | Crosses compaction | Wall ms before → after | CPU s before → after | Peak MiB before → after | Max 1-min load before → after |
|---|---:|---|---:|---:|---:|---:|
| 50k | 10 | no | 148.5 → 145.4 | 0.134 → 0.141 | 50.1 → 50.9 | 2.79 → 2.71 |
| 50k | 50 | no | 559.8 → 573.0 | 0.558 → 0.570 | 218.7 → 223.0 | 2.88 → 2.71 |
| 50k | 200 | no | 2125.8 → 2533.0 | 2.130 → 2.522 | 859.9 → 864.4 | 2.88 → 2.89 |
| 50k | 50 | yes | 468.1 → 502.2 | 0.465 → 0.498 | 210.8 → 212.4 | 2.81 → 2.98 |
| 50k-exchanges | 10 | no | 142.2 → 168.0 | 0.140 → 0.161 | 49.3 → 50.5 | 2.67 → 2.98 |
| 50k-exchanges | 50 | no | 585.0 → 562.6 | 0.579 → 0.562 | 225.2 → 222.2 | 2.67 → 2.98 |
| 50k-exchanges | 200 | no | 2055.5 → 2583.3 | 2.062 → 2.581 | 877.3 → 859.1 | 2.69 → 3.06 |
| 50k-exchanges | 50 | yes | 439.0 → 562.0 | 0.432 → 0.561 | 210.7 → 214.9 | 2.71 → 2.80 |

A fresh-process reopen using the resulting checkpoint:

| Base | Suffix MiB | Crosses compaction | Wall ms before → after | CPU s before → after | Peak MiB before → after | Max 1-min load before → after |
|---|---:|---|---:|---:|---:|---:|
| 50k | 10 | no | 132.0 → 110.7 | 0.130 → 0.109 | 49.6 → 46.4 | 2.79 → 2.71 |
| 50k | 50 | no | 507.1 → 427.2 | 0.506 → 0.426 | 218.9 → 197.5 | 2.88 → 2.71 |
| 50k | 200 | no | 2135.6 → 1767.3 | 2.145 → 1.773 | 858.0 → 725.5 | 2.88 → 2.89 |
| 50k | 50 | yes | 250.3 → 223.1 | 0.249 → 0.221 | 113.6 → 102.2 | 2.81 → 2.98 |
| 50k-exchanges | 10 | no | 137.6 → 116.2 | 0.136 → 0.114 | 49.6 → 46.1 | 2.67 → 2.98 |
| 50k-exchanges | 50 | no | 481.8 → 426.0 | 0.482 → 0.425 | 220.5 → 198.3 | 2.67 → 2.98 |
| 50k-exchanges | 200 | no | 2175.2 → 1730.6 | 2.181 → 1.741 | 846.2 → 724.4 | 2.69 → 3.06 |
| 50k-exchanges | 50 | yes | 258.3 → 238.4 | 0.258 → 0.237 | 115.1 → 103.3 | 2.71 → 2.80 |

These 48 trial pairs (96 opens) all passed at load ≤3.06. The 200 MiB
subsequent reopen improves by 17–20%, with peak footprint lower by 14–15%.
Its first replay pays 19–26% to build the newer caches. The crossing case
already publishes an ordinary compaction checkpoint before this change;
its additional refresh benefit is correspondingly smaller. The 10 MiB
initial-open difference is small in absolute terms and varies across trials.

Refresh cannot make an un-compacted 200 MiB model context cheap: the existing
checkpoint format still names journal-backed rows that must be read and
decoded (`SessionCheckpointing.swift`, `loadCheckpoint`). The remaining
~1.7 seconds includes loading this context and its metadata; those two costs
have not been isolated here. Context is never discarded
to meet a presentation budget. One 200 MiB case leaves about 8 MiB after its
last 64 MiB replay publication, because the remaining suffix falls just below
the 8 MiB refresh threshold. Metadata is 1.81 MiB for 21,187 rows in that case.
No journal format, history source selection, or `SessionReads.swift` change
is included.

Raw medians, ranges, every start/end/peak load and helper hash are retained in
`round2/item10-release-summary.json`, backed by
`perf/json-item10-{before,after}-*.{log,json}`. Before helper SHA-256:
`719e68a5320f2c420aeaaa3ac3f0bfff5ef02dd25823375a107932e537d71146`;
after production helper:
`185036cde8f344fcb901709f49202a3c7ff7309396eb6a265a34744708027693`.

### Item-10 commands

The shared `perf` lane and two-second load sampler wrap every timing command;
`--start-load 3 --attempts 5` rejects and retries any run above load 4. Build
and focused-test commands use `run-when-quiet.py` before starting. The
mutation driver also holds the shared lane while changing sources.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
xcodegen generate --quiet
python3 "$PI_BUILD_ROOT/round2/run-suffix-matrix.py"
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  -j 2 --filter CheckpointRefreshTests
python3 "$PI_BUILD_ROOT/round2/item10-mutations.py"
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  -j 2 --filter 'CheckpointRefreshTests|JournalCheckpointTests|DurableReplayTests|ReplayParityTests|MailboxCutPersistenceTests|JournalSlimmingTests|JournalPromotionTests|ForkAtReplyTests|EditRecoveryTests|SessionSettlementTests|SubagentAccountingTests|SubagentRecoveryTests|SubagentCoordinatorTests|OpeningProgressTests'
python3 "$PI_BUILD_ROOT/run-when-quiet.py" python3 scripts/build-bundle.py
python3 "$PI_BUILD_ROOT/round2/item10-release-measure.py"
python3 "$PI_BUILD_ROOT/round2/summarize-item10.py"
```

The matrix driver selects the appropriate helper in this stream's bundle,
runs three rounds of each fixture/suffix combination, and restores the final
helper even on failure. Each measurement uses:

```sh
PYTHONPATH="$PWD/scripts" python3 scripts/perf-longchat-run.py \
  --label json-item10-<variant>-<fixture>-<MiB>-<cross>-r<N> \
  --start-load 3 --attempts 5 -- \
  python3 "$PI_BUILD_ROOT/round2/suffix-refresh-probe.py" <fixture> <MiB> [cross]
```

The matrix finished all 48 accepted trials before its first turn-end harness
failed. An initial standalone-driver compile needed `-parse-as-library`;
a later executable used disabled access control against non-testable whole
module objects and hit a compiler-deleted internal accessor. Neither attempt
is a product failure or accepted timing. The corrected driver uses an
optimized Release core built with `-enable-testing` and `@testable import`;
it copies the measurement body in `CheckpointRefreshPerformanceTests`.
The standalone driver links only the Release core, avoiding unrelated
test classes that reference DEBUG-only probes (`SideOriginIndexTests` /
`SideOriginReadProbe`). Production suffix/cold measurements use the normal bundle
without test visibility.

```sh
python3 "$PI_BUILD_ROOT/round2/item10-cost-build-testable.py"
```

That script builds the core with `swift build --configuration release
--arch arm64 --product pi-native-host -j 2 -Xswiftc -Osize
-Xswiftc -enable-testing --scratch-path "$PI_BUILD_ROOT/swift-refresh-benchmark"`,
links `round2/refresh-cost-driver.swift` with those core objects, then runs the
turn-end probe under `perf-longchat-run.py`. It next invokes
`round2/item10-final-cold.py`, which stages the final production helper into
the same isolated item-4 Release test app, checks the test-host manifest,
and repeats the production-default 30-second cold/cancel probes three times
per cell with `round2/opening-run.py`. No app implementation changed in item 10.
The exact executable arguments and environment are retained in those scripts
and each measurement JSON file.

### Turn-end cost

The synchronous work added immediately after the durable state flush was
measured over 2 × 500 disabled and 2 × 500 eligible scheduling calls. The
same flushed 12 MiB journal suffix is eligible each time; worker cancellation
and joining occur outside the timed interval. This isolates the work on the
session actor, rather than measuring the asynchronous replay as a turn stall.
The crash-copy test separately verifies that the worker completes and
publishes real durable state.

| Scheduling | Samples per block | Median ms, blocks 1 / 2 | p95 ms, blocks 1 / 2 | Max ms, blocks 1 / 2 |
|---|---:|---:|---:|---:|
| below threshold | 500 | 0.001250 / 0.001417 | 0.001500 / 0.001709 | 0.056500 / 0.005041 |
| eligible refresh | 500 | 0.011583 / 0.013250 | 0.041958 / 0.040000 | 0.174292 / 0.092375 |

Added median scheduling work is about 0.010–0.012 ms; the background task
performs replay, encoding and file staging. Start/end/peak one-minute load
was 2.05 / 2.05 / 2.05. Raw result:
`perf/json-item10-turn-end-testable-1.{log,json}`. The wrapper's helper hash
identifies the bundle present during the run; the actual command is the
standalone optimized testable-core driver, whose artifact/build details are
in `round2/item10-cost-artifacts.json`.

### Cold-open follow-up

The first non-interleaved comparison against the earlier item-4 medians
appeared to add 2.2 seconds (200k) / 7.5 seconds (50k exchanges). It was not
used to attribute an implementation regression: a fresh item-4 control also
slowed to 13.0 seconds at 200k, versus its earlier 10.2-second median. The
final comparison therefore alternates item-4 and item-10 helpers on the same
Release app, three rounds per fixture. Earlier accepted observations remain
in `perf/json-item10-{200k,50k-exchanges}-*`; a load-4.95 observation was
rejected. The remaining old sequence was stopped while waiting for a quiet
window and replaced by the paired sequence.

A separate accepted Release profile of the final helper's cold 50k-exchange
open recorded 24,140 ms wall / 23.173 CPU s at maximum load 3.22. In its first
10 seconds, checkpoint publication appeared in 9 of 728 active opening
observations (5 capture, 3 encode/stage, 1 rename). This is sampling evidence,
not an isolated duration or a substitute for the paired timing comparison.
Raw evidence: `perf/json-item10-publish-profile-1-helper.sample.txt` and
`perf/json-item10-publish-profile-1.{log,json}`. The exact profile command was:

```sh
python3 scripts/perf-longchat-run.py --label json-item10-publish-profile \
  --profile --start-load 3 --attempts 5 -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/50k-exchanges" --cold
python3 "$PI_BUILD_ROOT/round2/item10-cold-paired.py"
```

No cadence or correctness rule was relaxed to improve a timing result.

Final paired comparison, production 30-second inactivity deadline, negotiated
progress enabled, three accepted trials per cell:

| Fixture | Wall ms item 4 → item 10 | CPU s item 4 → item 10 | Peak MiB item 4 → item 10 | Max 1-min load item 4 → item 10 |
|---|---:|---:|---:|---:|
| 200k | 10730.5 → 10283.0 | 10.659 → 10.194 | 2859.3 → 2838.2 | 2.73 → 2.99 |
| 50k-exchanges | 19774.0 → 20376.6 | 19.524 → 20.114 | 5373.8 → 5380.3 | 2.93 → 2.85 |

The median changes are −4.2% at 200k and +3.0% at 50k exchanges.
The 200k change lies inside the control run range; the 50k-exchange result
shows a modest cost for checkpoint publication, rather than the earlier
apparent 7.5-second regression. No further tuning was made on noisy data.

Final-helper progress observations:

| Fixture | Frames per trial | Cadence median / p95 / max ms |
|---|---|---:|
| 200k | 43 / 40 / 40 | 250.43 / 260.30 / 282.09 |
| 50k-exchanges | 78 / 78 / 77 | 250.47 / 256.43 / 294.95 |

Final-helper mid-replay cancellation at 50k exchanges: **116.76 ms median**, 114.93–122.65 ms range, from app Cancel to worker settlement and successful writer-lock acquisition. Peak one-minute load 2.73. The three cancellation trials all passed; cancellation still reaches the detached replay after adding checkpoint publication.

Accepted final timing ledger (start / end / peak one-minute load):

| Raw trial | Load |
|---|---:|
| json-item10-cold-after-200k-progress-r1-2 | 2.98 / 2.83 / 2.99 |
| json-item10-cold-after-200k-progress-r2-1 | 2.56 / 2.39 / 2.56 |
| json-item10-cold-after-200k-progress-r3-1 | 2.17 / 2.54 / 2.64 |
| json-item10-cold-after-50k-exchanges-cancel-r1-1 | 2.73 / 2.56 / 2.73 |
| json-item10-cold-after-50k-exchanges-cancel-r2-1 | 2.32 / 2.34 / 2.45 |
| json-item10-cold-after-50k-exchanges-cancel-r3-1 | 2.62 / 2.67 / 2.73 |
| json-item10-cold-after-50k-exchanges-progress-r1-1 | 2.83 / 2.73 / 2.85 |
| json-item10-cold-after-50k-exchanges-progress-r2-1 | 2.39 / 2.34 / 2.39 |
| json-item10-cold-after-50k-exchanges-progress-r3-1 | 2.54 / 2.62 / 2.64 |
| json-item10-cold-before-200k-progress-r1-1 | 2.70 / 2.73 / 2.73 |
| json-item10-cold-before-200k-progress-r2-1 | 2.34 / 2.34 / 2.37 |
| json-item10-cold-before-200k-progress-r3-1 | 2.34 / 2.35 / 2.35 |
| json-item10-cold-before-50k-exchanges-progress-r1-1 | 2.73 / 2.93 / 2.93 |
| json-item10-cold-before-50k-exchanges-progress-r2-1 | 2.34 / 2.26 / 2.34 |
| json-item10-cold-before-50k-exchanges-progress-r3-1 | 2.35 / 2.17 / 2.41 |

Rejected paired trials: `json-item10-cold-after-200k-progress-r1-1.json` (peak load 27.71). They are excluded from the medians. Raw observations, ranges, load samples and artifact hashes are in `round2/item10-cold-summary.json` and `perf/json-item10-cold-*`.

The item-4 comparison helper SHA-256 is
`9f64dc2bc0d55b97f2b34a389556e086716d05f34d5a1dd3fe11c7775efd0030`;
the final helper is the `185036cd…` production bundle listed above. Both
use the same checked isolated Release app and test bundle. The paired
comparison is the evidence for item-10 cold-opening cost; the earlier
non-interleaved observations are retained only as the investigation trail.

### Handoff

Item 10 changes helper checkpoint/replay files only. `JournalCheckpoint.swift`
is also compiled into the app; its existing encoding and atomic replacement
contract are preserved. No other stream's files were edited for this item.
The new focused tests and both mutations pass, and the final Release helper
passes the actual-supervisor opening/cancellation probes. Item-4 wire gates
remain 41 / 4 / 3 plus four new cases; item 10 adds no wire contract change.

The remaining limitation is the cost of loading a large retained model
context: a 200 MiB suffix still reopens in about 1.7 seconds after refresh.
The metadata/row limits deliberately skip oversized snapshots and retain
the previous checkpoint. The measure-first results exceeded the requested
0.5-second cutoff, so the implementation branch of item 10 was taken; no
owner product decision is needed. The optional task/reply encoding changes
were deferred because their fixture-wide equality proof is additional work.

Per-trial APFS clones were removed by the measurement runners. Superseded
round-1/item-4/item-10 comparison bundles and the temporary testable-core
scratch directory were removed after the final trials; the final bundle,
raw evidence, benchmark driver, fixture sources and all 20 gallery PNGs
remain under `PI_BUILD_ROOT`.

## Round 3 — review findings (2026-10-29)

### F3 — session.open configuration coverage

Ran all ten requested helper classes against `d59aed3f`, whose opening path is
unchanged from accepted item 4. This exercises side budget binding and recovery,
cost limits, family pauses, context preview, capture draining, sub-agent recovery
and policy/effort, and host runtime ownership. No implementation change was
needed for this finding.

| Class | Passed |
| --- | ---: |
| SideBudgetTests | 35 |
| SideBudgetCrashMatrixTests | 9 |
| SideBudgetReplayTests | 8 |
| CostLimitTests | 23 |
| FamilyLimitPauseTests | 112 |
| ContextPreviewTests | 8 |
| CaptureDrainTests | 6 |
| SubagentRecoveryTests | 17 |
| SubagentPolicyEffortTests | 25 |
| HostServiceTests | 10 |
| **Total** | **253** |

Zero failures and zero skipped XCTest cases. The separate Swift Testing runner's
zero-test footer is not the XCTest count. These Debug timings are not performance
evidence. Raw output: `$PI_BUILD_ROOT/round3/f3-helper.log`.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --jobs 2 --filter 'PiAgentCoreTests\.(SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetReplayTests|CostLimitTests|FamilyLimitPauseTests|ContextPreviewTests|CaptureDrainTests|SubagentRecoveryTests|SubagentPolicyEffortTests|HostServiceTests)' \
  > "$PI_BUILD_ROOT/round3/f3-helper.log" 2>&1
```

The wrapper waited while the other stream held a `perf` quiet window. No full
suite was run. F3 requests coverage of an accepted change, rather than a new
behavior, so it adds no failing-first test or mutation.

### F1 — opening progress without hiding the conversation

Restored `ConversationPaneView.coversTranscript` to its pre-item-4 rule. Helper
opening never independently covers the transcript. A waiting action owns a
reference-counted interest in the shared open; selection's automatic preview,
typing prewarm, budget dependencies and background work remain silent. An
explicit context Inspector can join the automatic preview before `open()` is
called, so `WorkspaceContextPreview.swift` has a five-line interest scope too.
This is the only extra opening call site touched; the history/fill state is
unchanged. `ConversationPane.swift` only changes opening view selection,
visibility and overlay layout.

After 150 ms, waiting actions show a 60-point strip above the composer, with
“Opening chat…”, the observed percentage when available, a thin PiKit ProgressBar
and PiKit Cancel. The transcript frame is unchanged. When its existing loading
cover is independently due, the same view fills that cover. The view disappears
when the action settles. Removed the standalone opening Retry: the audited user
openers already report through their action's failure surface, and background
openers deliberately report nothing. Repeating the action retries.

A cancelled send returns its unsent draft and shows the existing inline notice,
“Opening cancelled. Your message was not sent.” A failed send returns the draft
and shows the actual error through that same notice. Rows stay visible, and the
composer is editable. No failure or cancelled opening panel remains. Selecting
another chat still does not cancel a shared opening.

Failing first: the four new pane tests ran against the unchanged `a2154990` app
sources (`git diff a2154990 d59aed3f -- apps` is empty). All four failed, with six
assertion failures: an automatic preview covered rows, a waiting send produced a
474-point cover, and cancelled/failed sends left Retry panels visible. Fixed:
all seven tests pass, adding shared-preview joining, the pre-existing empty
loading cover, and no flash for quick opens. Mutation: restored the helper check
at the start of `coversTranscript`; three tests failed with five assertions,
including the 474-point cover. Restored source and reran the class successfully.

| App class, each run separately | Passed |
| --- | ---: |
| OpeningPaneTests | 7 |
| ConversationPaneTests | 85 |
| FreshPresentationTests | 21 |
| WorkspaceOpeningProgressTests | 3 |
| HostSupervisorTests | 12 |
| AutomaticContextTests | 13 |
| PreparedContextLifecycleTests | 6 |
| WorkspaceConcurrencyTests | 12 |
| **Functional total** | **159** |
| OpeningProgressGalleryTests | 1 |

No failed or skipped final tests. Existing ConversationPaneTests teardown emits
SQLite “vnode unlinked while in use” warnings for its synthetic scratch folders;
all 85 cases pass. The new pane fixture uses the awaited workspace teardown.

The real-pane gallery produced **24 images, all opened and visually inspected**:
`$PI_BUILD_ROOT/round3/gallery/pane-opening-{pending,progress,cancelling,cancelled,failure,cover}-{840,320}-{light,dark}.png`.
Rows and the composer are visible in the five non-cover scenes; the sixth is the
empty-chat loading cover. Labels, percentage, progress track and controls fit
both widths in both themes. The gallery ran with the shared focus lock and the
parent-lifetime-fixed test gateway from the round-2 merge.

Raw evidence: `round3/f1-failing-first.log`, `f1-fixed.log`, `f1-mutation.log`,
`f1-<Class>.log`, `f1-gallery.log`, all below `$PI_BUILD_ROOT`. Commands:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
xcodegen generate --quiet
# Repeat with the original sources, the mutation, and the restored sources.
python3 "$PI_BUILD_ROOT/round3/locked.py" 'F1 affected OpeningPaneTests' \
  xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination platform=macOS,arch=arm64 -jobs 2 \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=NO 'OTHER_SWIFT_FLAGS=$(inherited) -j2' \
  -parallel-testing-enabled NO -only-testing:PiAppTests/OpeningPaneTests
# Every other functional class in the table is a separate invocation:
python3 "$PI_BUILD_ROOT/round3/locked.py" 'F1 affected <Class>' \
  xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
  -destination platform=macOS,arch=arm64 -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  -parallel-testing-enabled NO -only-testing:PiAppTests/<Class>
TEST_RUNNER_PI_APP_OPENING_GALLERY="$PI_BUILD_ROOT/round3/gallery" \
  python3 "$PI_BUILD_ROOT/round3/locked.py" 'F1 gallery' \
  xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
  -destination platform=macOS,arch=arm64 -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  -parallel-testing-enabled NO -only-testing:PiAppTests/OpeningProgressGalleryTests
```

`locked.py` acquires the shared lane by atomic directory creation, writes this
stream's owner, waits in 60-second intervals for another owner, and releases
only its own lock in `finally`. Functional/gallery runs claim no timing results.

### F4 — retain a runtime when its late close is refused

Cancellation cleanup now distinguishes an acknowledged close or missing runtime
from a refusal. A still-current helper that refuses the late close keeps the
session in `opened`; its configuration generation and profile bookkeeping are
not retired. Host identity and connection are checked again after the reply.
A small `openingAdoptions` set ensures the next action still takes the complete
opening/adoption path, including durable path registration and configuration.
It cannot incorrectly take the already-open fast path merely because cleanup
retained ownership. Successful adoption, actual unload and disconnect clear it.

Failing first: `testRefusedLateCloseKeepsTheRuntimeTracked` received a real
supervisor `session_busy` reply to the late, command-keyed close. The original
code failed three assertions: runtime ownership lost, profile revision lost,
and configuration generation incorrectly retired. Fixed: the four
`WorkspaceOpeningProgressTests` pass, including the new assertion that the next
user action enters normal adoption. Mutation: disabled the retained-runtime
branch; the same test failed four assertions. Restored and reran successfully.

| Separately run final app class | Passed |
| --- | ---: |
| WorkspaceOpeningProgressTests | 4 |
| OpeningPaneTests | 7 |
| WorkspaceConcurrencyTests | 12 |
| TabHostTests | 17 |
| **Total** | **40** |

Raw logs are `$PI_BUILD_ROOT/round3/f4-{failing-first,fixed,mutation,restored}.log`
and `f4-{OpeningPaneTests,WorkspaceConcurrencyTests,TabHostTests}.log`.
Commands use the F1 `xcodebuild test` invocation with
`-only-testing:PiAppTests/WorkspaceOpeningProgressTests/testRefusedLateCloseKeepsTheRuntimeTracked`
for failing-first/mutation, then the whole class for the fixed/restored runs.
The three other classes use the F1 `test-without-building` invocation, one class
per shared-lane lock. No gallery regeneration is needed for this ownership-only
change; the F1 images depict the unchanged presentation.

### F2 — deferred EOF refresh and checkpoint parity

Removed EOF capture/publication from the replay loop. The fully replayed consumer
is already adopted as `durable`. Wire opens schedule refresh after the successful
reply has reached stdout, checking that the same command still owns the adopted
runtime. The frame writer supplies a completion fence; merely queueing its bytes
is not delivery. Synchronous test readers use an immediate fence. Direct service calls schedule after adoption because
they have no wire reply to prepare. The utility worker starts at the durable byte
position, reads no journal suffix at a settled EOF, then captures, stages and
atomically replaces the checkpoint. The existing guards still exclude active
streams, unsettled receipts, partial cuts, uncommitted work and oversized state.
A cache failure keeps the previous checkpoint. Scheduling is constant work on
the session actor.

Intermediate publication is retained for long replays: at least 512 MiB of
known unreplayed bytes, or 60 seconds elapsed. Only then do the existing
64 MiB / 60-second intervals apply, with the 8 MiB minimum, 8 MiB metadata
budget and 32,768-row bound. The cheap byte/state-prefix checks precede clock
reads. The final record is explicitly excluded even when an interval is due:
EOF work belongs to the adopted runtime's utility worker.

The first candidate left intermediate work synchronous. Two accepted cold-open
pairs at 200k measured 10,022.3 → 10,521.2 ms, **+4.98%**, so that candidate did
not meet the requested cost limit. Its evidence is retained in
`$PI_BUILD_ROOT/round3/preliminary-cold`; one additional load-contaminated
attempt was rejected. The remaining matrix was stopped before changing code.

Intermediate capture, encoding and staging now run on one utility worker too.
The opening thread freezes only the visible suffix containing the bounded
context, its row spans and checkpoint state. It drops full history and the full
span dictionary before handing off, avoiding a copy of those collections on the
next replay append. A busy worker coalesces another request. EOF or cancellation
fences off publication without waiting for capture/encoding. The fence and
atomic rename share a lock, so an old worker cannot overwrite a newer adopted
checkpoint. The worker owns no journal claim or writer lock, reads no journal,
and removes its staging file on failure or cancellation. Its last published
byte position prevents a duplicate write by the initializer. Existing
context-boundary checkpoint behavior is retained. `CommandReceipts.Base` gains
only `Sendable` conformance so the frozen replay is checked as a value snapshot.

The utility-worker candidate met the cold-open target (+0.90% at 200k and
−1.02% at 50k exchanges), but a complete suffix matrix still showed initial-open
overhead in several cells: for example 557.0 → 636.7 ms at 50k + 50 MiB.
The blocked-reply test confirmed that EOF publication could precede reply
handoff. Scheduling now follows `finish`, so capture cannot compete with reply
encoding. The continuation checks the opening command's ownership again and
supports a session ID in either the frame or params. This candidate's full
matrix and artifact evidence are in `round3/pre-reply-refresh`. A second
candidate deferred until writer handoff, but the writer queues asynchronously.
Its matrix (`round3/pre-writer-fence`) still had two initial suffix cells above
noise. The final implementation schedules only after the writer queue completes
the reply. The small `PiHost/Main.swift` change supplies that completion fence;
it changes no frame bytes. Final results below use adjacent before/after pairs
per cell.

Failing first:

- Construction with a generated 10 MiB suffix changed the checkpoint from
  byte 48,442 to 10,549,596 before returning. The new test failed on the reviewed
  implementation, then passed after deferral, including production-host
  scheduling after adoption.
- With reduced test-only interval thresholds, the last settled record was
  published as an intermediate checkpoint at byte 2,111, equal to EOF. The new
  interval test failed, then passed with the explicit EOF exclusion. It also
  checks the already-published byte position used to prevent a duplicate write.
- With the intermediate executor still synchronous, a deliberately blocked
  capture prevented replay from returning: the new test failed its 200 ms
  continuation expectation. The utility executor passes. The test also stops
  while capture is blocked, releases it, and verifies that the old checkpoint
  survives and no staging file remains. A second request while busy is coalesced.
- Holding the opening reply's output callback still allowed the checkpoint to
  advance from byte 48,463 to 10,549,617 before reply handoff. The new wire-order
  test failed, then passed after moving scheduling past `finish`. The final
  test covers both supported locations of the session ID.
- Queuing that reply behind a blocked asynchronous writer still allowed both
  checkpoints to advance before delivery (two failed assertions). Waiting for
  the writer-completion fence passes the same test. The test holds the actual
  delivery queue, not the service output callback.

The generated parity corpus contains **20 journals, 107 settled-state prefixes**
(four variants of live parent, two forks, bound side, and family/cut history).
It generates actual turns through `ScriptClient`, tools, edits/branches,
compactions, task terminal records, command receipt deltas, forks at an earlier
reply and at the end, and kept sides bound to their parent's budget. Additional
journal records cover family operations/turn terminals, mail and delivery,
cut preparations/commits/projections, settled and not-dispatched accounting,
context recovery, failed compaction evidence, real model rebinds, and v4/v5
promoted journals. All data and credentials are synthetic.

At each prefix, the test opens an actual journal writer, validates and loads
the checkpoint, and runs the production replay path to that exact EOF. It
compares refreshed checkpoints captured from both a cold replay and the old
context-anchored replay, plus bounded worker snapshots from each, against cold
replay and against that old checkpoint. Snapshotting must preserve eligibility.
It checks visible rows with their exact lazy-prefix offset (`rowsBefore`),
context, byte-identical next Responses request, versions, spend and accounting,
run state/receipts, family/mail/cuts, task evidence, origins, compaction/recovery,
reply counts, ordinal and lineage from the whole timeline. A checkpoint must
actually be used; fallback to cold replay does not pass the test.

Result: **76 refreshed prefixes, 31 refused (empty or unresolved), 683
comparisons, zero differences**. Eight earliest prefixes have no old context
checkpoint yet; four refresh successfully and compare against cold replay,
and four have empty context and refuse capture. Every later prefix also gets
the old-checkpoint comparison. The corpus prints generator version, variants,
journal count and all prefix/comparison counts.

| Mutation, independently compiled and run | Failing assertions |
| --- | ---: |
| Drop captured accounting | 64 |
| Add one to `rowsBefore` | 1,120 |
| Take lineage from the checkpoint's loaded rows | 72 |
| Restore synchronous EOF publication | 1 |
| Run the intermediate worker synchronously | 1 continuation-timeout failure |
| Schedule EOF refresh before wire reply handoff | 2 |
| Bypass the asynchronous writer-completion fence | 2 |

Both reply-order mutations exercise frame-ID and params-ID commands. All seven
mutations were caught. Restored refresh/parity classes: 12 tests
passed, including the production worker and its stop fence.
Raw logs: `$PI_BUILD_ROOT/round3/f2-{failing-first,eof-interval-failing-first,parity,restored,final-refresh}.log`
and `f2-mutation-{accounting,rows-before,lineage,eof,worker,reply,writer}.log`.
The worker's failing-first and fixed logs are `f2-worker-{failing-first,fixed}.log`;
the worker mutation driver is `f2-worker-mutation.py`. Reply ordering uses
`f2-reply-{failing-first,fixed}.log` and `f2-reply-mutation.py`. The asynchronous
writer fence uses `f2-writer-{failing-first,fixed}.log` and
`f2-writer-mutation.py`.

Affected helper coverage: **321 executed, 319 passed, two skipped**, zero
failures. The skips are `JournalPromotionTests`' two env-gated fault harness
entry points; its three ordinary cases pass. The 253 F3 cases were included
again and passed on the deferred-publication implementation.

| Other affected helper class | Passed |
| --- | ---: |
| CheckpointRefreshTests | 11 |
| CheckpointRefreshParityTests | 1 |
| OpeningProgressTests | 7 |
| JournalCheckpointTests | 8 |
| JournalPromotionTests | 3 |
| DurableReplayTests | 5 |
| MailboxCutPersistenceTests | 8 |
| EditRecoveryTests | 4 |
| ForkAtReplyTests | 5 |
| OlderRowsTests | 4 |
| JournalSlimmingTests | 10 |

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-json
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --jobs 2 --filter 'PiAgentCoreTests\.(CheckpointRefreshTests|CheckpointRefreshParityTests|OpeningProgressTests|JournalCheckpointTests|JournalPromotionTests|DurableReplayTests|MailboxCutPersistenceTests|EditRecoveryTests|ForkAtReplyTests|OlderRowsTests|JournalSlimmingTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetReplayTests|CostLimitTests|FamilyLimitPauseTests|ContextPreviewTests|CaptureDrainTests|SubagentRecoveryTests|SubagentPolicyEffortTests|HostServiceTests)/' \
  > "$PI_BUILD_ROOT/round3/f2-affected-helper.log" 2>&1
# Each mutation uses this same command with the matching focused class/method;
# f2-mutations.py restores source in finally, then reruns both classes.
python3 "$PI_BUILD_ROOT/round3/f2-mutations.py"
python3 "$PI_BUILD_ROOT/round3/f2-worker-mutation.py"
python3 "$PI_BUILD_ROOT/round3/f2-reply-mutation.py"
python3 "$PI_BUILD_ROOT/round3/f2-writer-mutation.py"
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift test \
  --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --jobs 2 --filter 'CheckpointRefreshTests|CheckpointRefreshParityTests' \
  > "$PI_BUILD_ROOT/round3/f2-final-refresh.log" 2>&1
```

Release comparison uses a freshly rebuilt **a2154990** helper (item 4) and
the final F2 helper, both arm64 Release with the bundle builder's `-Osize`
and `strip -S` settings. The temporary detached baseline worktree was removed
after building. SHA-256:

- Item 4: `ec30fe26eab44803aaee70c9b96bf0bb9ef7f9a4023960fdc6ee435c24dc5e70`.
- F2: `ac2712d1ac3bfa64623e9a337c135e331c1f439926561c4edda9912fc20cf5b2`.

```sh
git worktree add --detach "$PI_BUILD_ROOT/round3/item4-worktree" a2154990
python3 "$PI_BUILD_ROOT/run-when-quiet.py" swift build \
  --package-path "$PI_BUILD_ROOT/round3/item4-worktree/packages/swift-host" \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --configuration release \
  --arch arm64 --jobs 2 --product pi-native-host -Xswiftc -Osize
mkdir -p "$PI_BUILD_ROOT/bundle-item4/Helpers"
cp "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" \
  "$PI_BUILD_ROOT/bundle-item4/Helpers/pi-native-host"
xcrun strip -S "$PI_BUILD_ROOT/bundle-item4/Helpers/pi-native-host"
git worktree remove "$PI_BUILD_ROOT/round3/item4-worktree"
python3 "$PI_BUILD_ROOT/run-when-quiet.py" python3 scripts/build-bundle.py \
  > "$PI_BUILD_ROOT/round3/f2-final-release-build.log" 2>&1
python3 "$PI_BUILD_ROOT/round3/locked.py" 'round3 Release test host build' \
  xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination platform=macOS,arch=arm64 -jobs 2 \
  -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2 \
  > "$PI_BUILD_ROOT/round3/release-app-build.log" 2>&1
python3 "$PI_BUILD_ROOT/round3/run-release-proof.py" \
  > "$PI_BUILD_ROOT/round3/release-proof.log" 2>&1
# Final worker implementation: mutations, affected classes, Release rebuild,
# then the same wire/cold/suffix driver (the app source did not change).
python3 "$PI_BUILD_ROOT/round3/finish-worker-proof.py" \
  > "$PI_BUILD_ROOT/round3/worker-proof.log" 2>&1
# Final reply-order correction, with the same affected classes and Release gates:
python3 "$PI_BUILD_ROOT/round3/finish-reply-proof.py" \
  > "$PI_BUILD_ROOT/round3/reply-proof.log" 2>&1
# Final asynchronous writer fence, mutations, affected classes and Release proof:
python3 "$PI_BUILD_ROOT/round3/finish-writer-proof.py" \
  > "$PI_BUILD_ROOT/round3/writer-proof.log" 2>&1
# Balance the suffix sample, retaining the first five pairs:
PI_SUFFIX_PAIR_START=6 PI_SUFFIX_PAIR_END=10 \
  python3 "$PI_BUILD_ROOT/round3/suffix-paired.py" \
  > "$PI_BUILD_ROOT/round3/suffix-balanced-proof.log" 2>&1
```

The proof driver runs `wire-gates.py`, `cold-paired.py`, then
`suffix-paired.py`, all retained under `$PI_BUILD_ROOT/round3`. Cold trials
use the isolated Release test host's `OpeningPerformanceTests` through
`round3/opening-run.py`, with `TEST_RUNNER_PI_OPENING_PROBE=progress`,
`--start-load 3 --attempts 5`, the generated fixture, and the production
30-second inactivity deadline. There is no 180-second override. The baseline
and final helper are copied into the same test host; the final helper is
restored in `finally`.

Suffix trials use `round3/perf-run.py --start-load 3 --attempts 5`
to run `python3 "$PI_BUILD_ROOT/round3/suffix-refresh-probe.py" SIZE MB [cross]`.
The probe APFS-clones the original warm journal and checkpoint into this build
root, appends complete ordinary turns, opens, closes, and opens again in a new
helper. Each variant therefore starts with the same original checkpoint.
The final variant waits for the asynchronous EOF checkpoint **after** the first
open reply, records that settlement delay separately, then measures the reopen.
This wait is excluded from initial-open latency and is not hidden in the reopen.
Each clone is deleted in `finally`. Three cold pairs and ten suffix pairs per
cell alternate order. The first five suffix pairs showed broad, bidirectional
initial-open variation. Five additional pairs were specified together, with
reversed order, to balance the sample; every accepted trial is retained. Both round-3 adapters use the standard
`scripts/perf-longchat-run.py` workload, load sampling and cleanup, reserving
the full lane before waiting for starting load at most 3. This prevents another
stream starting a build during that wait. Every owner line contains `perf`;
any trial whose sampled one-minute load exceeds 4 is rejected and repeated.
Raw trial logs and load samples are `$PI_BUILD_ROOT/perf/json-round3-*`;
`round3/summarize-perf.py` produces `round3/perf-summary.json`.

### Final round-3 measurements

Cold entries are medians of three accepted trials per variant; suffix entries use ten. Order alternates. “Before” is item 4 (`a2154990`); “after” is final F2. Peak footprint is the median process peak; load is the highest one-minute sample across those trials.

| Cold fixture | Wall ms, before → after | Change | CPU s, before → after | Peak MiB, before → after | Maximum load, before → after | Progress cadence, median / max ms (after) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 200k | 10167.2 → 9987.4 | -1.77% | 10.105 → 10.008 | 2849.7 → 2823.4 | 2.95 → 3.02 | 250.4 / 272.7 |
| 50k-exchanges | 20641.2 → 19831.1 | -3.92% | 20.259 → 19.834 | 5396.0 → 5370.3 | 3.54 → 3.00 | 250.4 / 281.2 |

Initial open from the original checkpoint plus suffix (nominal suffix sizes in MiB):

| Fixture | Suffix | Wall ms, before → after | Change | CPU s, before → after | Peak MiB, before → after | Maximum load, before → after |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 50k | 10 | 118.4 → 125.4 | +5.88% | 0.115 → 0.122 | 49.4 → 49.1 | 3.00 → 3.00 |
| 50k | 50 | 516.9 → 532.8 | +3.09% | 0.515 → 0.533 | 222.1 → 220.5 | 2.98 → 3.00 |
| 50k | 200 | 1981.9 → 1995.7 | +0.70% | 1.995 → 2.003 | 853.6 → 869.7 | 2.93 → 3.06 |
| 50k | 50 + compaction | 457.4 → 510.7 | +11.66% | 0.453 → 0.508 | 214.6 → 213.3 | 2.93 → 2.95 |
| 50k-exchanges | 10 | 123.2 → 142.2 | +15.40% | 0.121 → 0.141 | 49.5 → 50.0 | 3.25 → 3.11 |
| 50k-exchanges | 50 | 544.8 → 528.8 | -2.94% | 0.545 → 0.529 | 220.8 → 221.5 | 2.97 → 2.97 |
| 50k-exchanges | 200 | 1989.5 → 2085.3 | +4.82% | 1.995 → 2.095 | 849.9 → 852.8 | 3.06 → 3.05 |
| 50k-exchanges | 50 + compaction | 455.2 → 458.2 | +0.66% | 0.454 → 0.458 | 213.8 → 217.2 | 2.92 → 3.00 |

Fresh-helper reopen after the first open (nominal suffix sizes in MiB):

| Fixture | Suffix | Wall ms, before → after | Change | CPU s, before → after | Peak MiB, before → after | Maximum load, before → after |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 50k | 10 | 116.9 → 102.4 | -12.40% | 0.115 → 0.101 | 50.0 → 46.4 | 3.00 → 3.00 |
| 50k | 50 | 508.5 → 420.4 | -17.32% | 0.509 → 0.420 | 220.9 → 195.1 | 2.98 → 3.00 |
| 50k | 200 | 2001.1 → 1799.2 | -10.09% | 2.009 → 1.806 | 862.4 → 731.2 | 2.93 → 3.06 |
| 50k | 50 + compaction | 281.9 → 274.7 | -2.57% | 0.281 → 0.272 | 113.7 → 102.3 | 2.93 → 2.95 |
| 50k-exchanges | 10 | 126.3 → 117.7 | -6.80% | 0.125 → 0.116 | 49.7 → 46.3 | 3.25 → 3.11 |
| 50k-exchanges | 50 | 525.5 → 464.8 | -11.53% | 0.525 → 0.464 | 220.5 → 197.8 | 2.97 → 2.97 |
| 50k-exchanges | 200 | 1988.8 → 1764.2 | -11.29% | 1.999 → 1.771 | 856.9 → 732.6 | 3.06 → 3.05 |
| 50k-exchanges | 50 + compaction | 256.9 → 216.2 | -15.84% | 0.256 → 0.215 | 113.5 → 102.6 | 2.92 → 3.00 |

After-reply checkpoint settlement in final F2 (reported separately from initial-open latency):

| Fixture | Suffix MiB | Delay until EOF checkpoint observed, ms | Helper CPU after reply, s | Peak footprint through settlement, MiB |
| --- | --- | ---: | ---: | ---: |
| 50k | 10 | 20.2 | 0.014 | 49.1 |
| 50k | 50 | 56.9 | 0.050 | 220.5 |
| 50k | 200 | 199.7 | 0.187 | 869.7 |
| 50k | 50 + compaction | 30.5 | 0.029 | 213.3 |
| 50k-exchanges | 10 | 28.6 | 0.022 | 50.0 |
| 50k-exchanges | 50 | 56.4 | 0.052 | 221.5 |
| 50k-exchanges | 200 | 195.3 | 0.183 | 852.8 |
| 50k-exchanges | 50 + compaction | 35.7 | 0.033 | 217.2 |

Initial-open paired variation, retaining all ten accepted pairs per cell. The paired change is the median of each adjacent after/before ratio; the last column is its observed range. These descriptive values do not establish a tight equivalence bound.

| Fixture | Suffix MiB | Median paired change | Paired change range |
| --- | --- | ---: | ---: |
| 50k | 10 | -0.42% | -9.03% to +39.64% |
| 50k | 50 | -3.11% | -13.45% to +27.06% |
| 50k | 200 | +0.39% | -13.46% to +38.10% |
| 50k | 50 + compaction | +1.34% | -18.16% to +37.18% |
| 50k-exchanges | 10 | +11.83% | -12.68% to +38.81% |
| 50k-exchanges | 50 | -2.98% | -17.00% to +18.40% |
| 50k-exchanges | 200 | +1.95% | -6.54% to +45.11% |
| 50k-exchanges | 50 + compaction | -0.66% | -23.00% to +28.42% |

The earlier 19–26% cold-opening regression is absent in this paired sample:
200k changes by −1.77%, and 50k exchanges by −3.92%. These are comparisons
against item 4, not a claimed new cold-replay speedup. Median progress cadence
remains 250.4 ms with the production deadline. Intermediate checkpoint work is
on its bounded utility worker, and its stop fence does not wait for encoding.

The reopen gain is retained in all eight suffix cells (median improvements
2.57–17.32%). Loading the retained model context still costs about 1.8 seconds
for the 200 MiB suffix; this change does not reduce or truncate that context.
EOF publication settles 20–200 ms after the reply in these medians, with its
CPU and footprint explicitly separated above.

**Remaining performance qualification:** the short-suffix initial-open target
is not established as a tight equivalence bound on this shared VM. Median
initial times range from −2.94% to +15.40%; the 10 MiB exchange case is
123.2 → 142.2 ms, and its median paired ratio is +11.83%. The 50k compaction
cell's medians are 457.4 → 510.7 ms, although its median paired ratio is +1.34%.
Seven of eight median paired changes lie between −3.11% and +1.95%, with broad
bidirectional variation. All load-valid observations are retained, including
slow ones. The deterministic blocked-writer test proves that EOF capture and
publication cannot precede reply delivery; it does not prove zero scheduling
or reader-observation cost after that delivery. No further timing-driven code
change is inferred from this variance. The lead should retain this qualification
when deciding whether the initial-open performance target is closed.

There are **172 accepted timing trials**: 12 cold and 160 suffix (each suffix
trial measures both initial open and reopen). Two cold attempts were discarded
and repeated: `json-round3-cold-before-200k-progress-r1-1.json` (load 4.78,
exit 0) and `json-round3-cold-before-50k-exchanges-progress-r2-1.json` (load 6.23,
terminated by the wrapper). Accepted trials have starting load at most 3 and
all sampled one-minute loads at most 4. Every final trial's helper hash was
checked against its baseline/final variant. The final helper was restored to
both the normal bundle and the isolated Release test host.

`round3/final-artifact-audit.json` contains the accepted per-trial start/end/peak
load ledger, variant hashes, rejected attempts and image inventory. The full
CPU/footprint observations and post-reply settlement values are in
`round3/perf-summary.json`. `perf-tables.py` and `final-audit.py` produce the
tables and paired-change ranges above.


Final Release wire gates (the `ac2712d1…` helper):

| Suite | Passed | Start / end / peak one-minute load |
| --- | ---: | ---: |
| wire | 41 | 2.78 / 2.75 / 2.88 |
| concurrent | 4 | 2.75 / 2.50 / 2.75 |
| acceptance | 3 | 2.50 / 2.30 / 2.50 |
| opening | 4 | 2.30 / 2.42 / 2.42 |

Raw commands and two-second load samples: `round3/wire-gates.json`; suite logs: `round3/release-{wire,concurrent,acceptance,opening}.log`. No full helper or app suite was run.

### Round-3 handoff

F1, F3 and F4 are separate commits. F2 changes helper checkpoint/replay work,
opening reply scheduling, and the stdout writer's completion plumbing; no
history-stream source file or `NEXT-RELEASE.md` is edited. The parity proof and
all requested functional/wire gates pass. F1/F4 regressions failed first and
caught their mutations; F2 caught all seven independently compiled mutations.
The remaining item is the initial-suffix performance qualification above,
not a hidden failed test or an omitted timing cell.

All 24 real-pane gallery PNGs remain under `round3/gallery`, opened and
inspected as recorded under F1. Cancel/failure restore the unsent draft and
use the existing inline notice; rows and the composer remain usable. A refused
late close retains ownership and forces normal adoption before the next action.

The final audit found zero gateways from this worktree and zero leftover suffix
fixture directories. The temporary item-4 worktree and comparison bundles were
removed after measurements. The final bundle, isolated test host, generated
fixture sources and raw evidence remain under the assigned build root.
