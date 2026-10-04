# Journal candidate — independent review log

## Initial candidate, 04:37 UTC: timing withheld

No benchmark was run against the initial journal candidate because review found a
checkpoint-admission blocker. Initial relevant SHA-256 values:

- `session.rs`: `8c1ba6e266a3e9d3f7444abb1cdeb65101f1dee2df03387ae86780d53a992e10`
- `stream_journal.rs`: `7d5853089615a2e2d3f6fb352075ecb14a56863d773cdcb65925de9309e6adca`
- `runtime.rs`: `3e58a6f40c2a4916f1229e319f86506a570b8f22065e808a9790b7a63a77ded3`
- `provider.rs`: `bad7c10b91900412b857d890cc78dd97eaad9560b443f2e01acd3d3b2f6553e5`

### Blocker: accepted journal growth could exceed checkpoint recovery limit

`append_delta` bounded each record to 16 MiB and each generation journal to 512 MiB,
but did not bound the resulting encoded Session to the 256 MiB snapshot limit.
A near-limit valid checkpoint could therefore accept, fsync and publish more
streamed content than a future checkpoint could contain. Terminal checkpointing
would fail; reopen would replay the journal and then fail while checkpointing the
same oversized result. Original data would remain on disk, but a session containing
acknowledged streamed content could no longer open normally.

This was reported before timing and accepted as an admission bug. The proposed
repair is an exact incremental encoded-checkpoint-size invariant checked before
any journal write, with separate recovery/error metadata headroom while a turn or
edit is active. It needs escape/counter-boundary equivalence tests and proof that
an over-limit delta creates/appends nothing and leaves memory/revision unchanged.
Results for a repaired candidate belong in a separate section with fresh hashes.

### Additional first-create error edge

In the initial candidate, `self.journal` became `Some` before `file.metadata()?`.
If metadata inspection failed, the error was ordinary I/O and the handle remained
installed. A later direct append would see `created == false` and skip the
first-create parent-directory fsync. Track completion of durable creation
independently, or poison/reset that failed setup before allowing another append.
This is an error-path concern, not evidence that the happy-path fixture loses data.

### Ordering and format observations

- Append -> file fsync -> first-create directory fsync -> in-memory mutation ->
  publication preserves the intended happy-path durability order.
- Durable checkpoints rotate generation before optional cleanup of the old
  journal. Before-rename failure retains the old generation; uncertain
  post-rename state keeps both recovery possibilities and blocks new writes.
- Recovery validates record version/session/generation/sequence and active reply,
  ignores an incomplete final line, retains that old journal, then pauses the run.
- The earlier directory-open-after-rename uncertainty gap is separately mapped to
  `PersistenceUncertain` in this candidate.
- Session checkpoint schema changes from v1 to v2, adding stream generation and
  sequence; the private JSONL record schema starts at v1. Rust v1 migration is
  explicit. Swift journals remain unsupported.
- The unchanged benchmark's `Session::new()` now seeds schema v2 and a random
  generation UUID. Retained text/row dimensions remain deterministic, but raw seed
  bytes and SHA-256 are no longer identical to the schema-v1 buffered fixture.
- The existing standalone `store` mode calls `transact(delta)`, so it remains a
  full-checkpoint control and must not be described as a direct-journal benchmark.
  The unchanged `Controller` mode exercises the journal through the real callback.

## Revised admission candidate, 04:48 UTC: remaining hold-admission hole

The incremental size cache and first-create metadata-failure poisoning addressed
the initial findings. Review of the next candidate found that metadata headroom
was reserved only for a running turn or a newly acquired edit. A subsequent queue
submission while the same idle/paused edit remained held could consume the reserve
and again leave insufficient space for the recovery notice on reopen.

The needed distinction is admission versus recovery: every newly accepted command
whose resulting session still has a held edit should preserve the headroom; the
recovery checkpoint itself is allowed to consume it. This second finding was also
reported before benchmarking. No timing result is associated with this candidate.

## Final candidate, 04:57 UTC: reviewed and measured

Final session source SHA-256:
`bf61d21dfddb94cca56d67cfe92df61d26d48a8e753c3b21b41f6c56a095df1c`.
The explicit admission/recovery write context fixes the held-edit hole. The
incremental delta-size invariant and first-create metadata poisoning remain in
place. Independent review found no remaining release blocker in the inspected
scope; all 41 release core tests passed. Sources remained unchanged during all
12 primary and two stress runs. See [JOURNAL-2026-10-04.md](JOURNAL-2026-10-04.md)
for exact hashes, schema differences, measurements, and disclosed limitations.
