# Session streaming baseline

This harness measures the current Rust `SessionStore` and `Controller`, without
changing their implementation. It performs no real model requests, discovers no
credentials, and uses a literal fake credential only against its own loopback SSE
fixture. It does not launch a GUI or measure rendering/presentation.

## Evidence availability

This public checkpoint includes benchmark source, reproduction/comparison scripts,
aggregate reports, and implementation/source hashes. Historical raw samples,
diagnostic logs, detailed environment records, and their archive are retained
locally and are **not published**. See [the availability note](evidence/README.md).
New runs generate fresh local data; historical aggregate claims cannot be
independently recomputed from this repository alone.

## Run

From the BelloAgent repository root:

```sh
rust/perf/run-session-streaming.sh rust/perf/raw/my-run
```

The script sources `/workspace/shared/rust-toolchain/env.sh`, builds the standalone
`bello-agent-core` example in release mode using the shared release target, and
records source hashes, the executable hash, compiler details, profile, OS,
filesystem types, cgroup limits, exact commands, and every latency sample. By
default it runs three separate processes for each of four cases:

- Real `SessionStore::transact` on the repository's overlay filesystem
- Loopback Responses SSE -> real `Controller` -> `SessionStore` -> watch observer
  on that overlay filesystem
- The same two cases on `/tmp` tmpfs, explicitly a RAM-backed synthetic comparison

Each process starts with a deterministic 100-message transcript containing exactly
100,000 ASCII characters / UTF-8 bytes (100 × 1,000). The initial JSON snapshot has
additional metadata, so it is larger than 100,000 bytes. A finite stream offers
500 × 16-byte text chunks at 100 Hz for a nominal five-second workload. Retained text is deterministic. Initial snapshot SHA-256 values are recorded.
The original v1 fixture had identical seed hashes; v2 adds a random stream
generation UUID, so seed metadata/hashes differ while text dimensions and the timed
harness stay unchanged. UUID values have constant encoded length.

`BENCH_REPEATS=1 BENCH_CHUNKS=20 BENCH_STRACE=0` selects a short smoke run. Otherwise
a separately labelled, three-transaction `strace -f -c` run checks syscall counts.
Its perturbed timings are never pooled into the ordinary measurements. No timing
wait counts state polls: the Controller receiver awaits watch change events, and
fixture generation waits for absolute per-chunk deadlines. Each subprocess has a
finite fixture-derived timeout; a failure is recorded and aborts the script.

The standalone example also accepts explicit dimensions:

```sh
source /workspace/shared/rust-toolchain/env.sh
export BENCH_CLK_TCK=$(getconf CLK_TCK)
export NO_PROXY=127.0.0.1,localhost
/workspace/shared/rust-toolchain/release-target/release/examples/session_streaming_bench \
  store /tmp/new-empty-fixture-directory 100 1000 500 100
```

Choose a new fixture directory. The harness refuses to replace an existing
`session.json`. Its script uses fresh temporary directories and removes those
synthetic sessions after collecting each report. Raw artifacts contain no user
conversations or private credentials.

## What the metrics mean

- **Store transaction latency**: time around the real `transact` call. Includes
  whole-session clone, mutation, serialization, file sync, rename, and directory
  sync. It excludes per-sample file metadata inspection, Controller publication,
  provider parsing, and any GUI work. Direct-store pacing is sequential: if work
  falls behind the offered schedule it catches up rather than dropping chunks;
  scheduled/start/end timestamps expose that backlog.
- **Controller latency**: fixture socket-write start to the first watch snapshot
  observed containing each chunk. Includes socket scheduling, parser, persistence,
  publication and observer scheduling. This is an upper-bound observation of
  publication, not an exact private `publish` timestamp. Watch revisions may
  coalesce; every affected sample records how many chunks shared its observation.
- **Shared-snapshot read**: time to call `snapshot_shared()` and clone its `Arc`.
  This measures neither rebuilding the snapshot nor formatting/layout/rendering.
- **Write growth**: the store case sums the actual resulting snapshot length after
  each successful transaction. Its in-process `/proc/self/io` `wchar`/`syscw`
  counters provide a second, independent write-byte/syscall count. `write_bytes`
  is a Linux accounting counter, not measured physical device traffic; tmpfs
  reports zero block write bytes. The Controller's counters include the loopback
  fixture, HTTP request, and observer process overhead.
- **CPU**: differences in Linux process user/system ticks with `getconf CLK_TCK`.
  Percent is relative to one CPU and includes observer/fixture work for Controller.
  CPU tick granularity and the host's shared scheduling limit interpretation.
- **RSS**: Linux `VmRSS` at interval boundaries and process-lifetime `VmHWM`, in KiB.
  The high-water mark includes seeding/initialization and is not a sampled
  measurement-interval-only peak. No allocator attribution or GPU memory is taken.
- **Durability**: the current fsync calls are executed. The container's actual
  physical backing device and power-loss characteristics are unknown; tmpfs is
  not durable storage. Reopen verifies successful completion content/state, not
  crash or power-loss recovery. Existing core tests remain the failure-contract
  evidence.

Percentiles use nearest rank. Per-case summaries pool equal-sized runs, while raw
per-run distributions remain available. These are local synthetic baselines, not
production SLOs, a Swift-vs-Rust comparison, speedup evidence, or presentation
latency claims.

## Synchronization note

The current Controller publishes `Idle` once when `finish()` commits and again
after committing an exhausted-queue `start_next()` transaction. `shutdown()` in
the short intervening period can request a pause from its still-active worker.
The harness waits for the current implementation's final revision (`chunks + 4`)
through watch events before shutdown and reopen. This is an explicit baseline
assumption to revisit if no-op transaction publication semantics change.

See [BASELINE-2026-10-04.md](BASELINE-2026-10-04.md) for the captured measurements,
source-backed findings, and proposed work. The subsequent independently measured
Vec-buffered candidate is documented in [BUFFERED-2026-10-04.md](BUFFERED-2026-10-04.md).
The harness itself does not patch production code.

## Journal candidate

[JOURNAL-2026-10-04.md](JOURNAL-2026-10-04.md) records the final journal safety review
and buffered-to-journal Controller comparison. The unchanged `store` mode continues
to call `transact(delta)` and is explicitly a non-journal full-checkpoint control.
Use `compare-journal-streaming.py BEFORE AFTER` for a schema-aware comparison; the
earlier `compare-session-streaming.py` intentionally requires byte-identical v1
seeds and is not appropriate across the v1 → v2 format change.
