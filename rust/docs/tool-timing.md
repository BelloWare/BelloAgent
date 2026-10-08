# Tool timing: bounded completed observations

Specification: BelloAgent main `f4f80ddda3c27fac9e266896f69b725a06242e8f`,
`SessionTools.swift` 64–75, 133–151, 170–229; `Support.swift` monotonic `nowMS`;
`TelemetryValues.swift` `ObservedDuration`; `Sessions.swift` retained timing load.
`SessionTaskPresentation.swift` sums individual tool rows for task presentation.
This slice deliberately does not implement that different task metric or model time.

## Meaning and boundaries

A call captures a monotonic start before argument preparation. Once its explicit
wrapper-entry boundary is crossed, its terminal observation includes preparation,
admission/queue wait, execution, normalization and bounded retention. Cancellation
before wrapper entry has no duration. A result-record construction/retention failure leaves its fallback row unmeasured,
matching Swift; an ordinary invoked tool/transport error with a valid retained row
can still carry elapsed time. Batch wall remains measured across such fallbacks.
Duration does not prove a remote effect:
MCP rejection or a source-proven unprocessed HTTP 404 can have an observation.
`McpError.not_executed` remains effect-certainty metadata and is never a clock gate.

Native calls adopt the original start only after explicit authority/cancellation
admission. MCP calls check cancellation before entering the existing manager
wrapper. Subsequent discovery/admission/retry failures retain elapsed observation;
this does not change any outcome, ticket, lease, retry or quarantine rule.

Batch wall time surrounds the concurrent join and per-call normalization/display
publication. It ends before ordered result extraction, steering/image preparation
and durable checkpoint I/O. It is never the sum or maximum of individual times.
The immutable completed batch travels through both ordinary/image and synthetic
resource settlement. The image validation projection owns a clone and cannot
increment the authoritative session; the real result transaction charges once.

## Durable schema 9

Checked integer microseconds avoid floating-point NaN/infinity and unchecked
`u128` conversion. Overflow in elapsed conversion or cumulative addition is unknown,
never saturation. This is a conservative integer range, not a performance claim.

- `ResultRecord.duration_us`: optional terminal wrapper observation.
- `AssistantRecord.tool_batch_timing.wall_us`: one completed batch observation;
  null wall means unknown. An observed owner requires its full ordered result set.
- `Session.tool_timing.total_us`: cumulative completed batch wall time.
  New, proven-new sessions start at zero. Legacy missing envelopes stay unknown;
  unknown totals remain unknown after later measured work.
- `LiveToolView.duration_us`: ephemeral only, bound to the existing assistant/call/
  worker/configuration/Stop identity. First 16 source-order cards and existing UTF-8
  preview limits are unchanged. Terminal updates are immutable.

Read and inspection reject any timing field presence under versions 1–8, including
null/empty fields. Clean legacy reads are byte-preserving. Real timing-bearing
mutations promote to version 9. No timing-only checkpoint or redraw timer exists.
Before-rename failure exposes no new committed total; uncertain commits keep the
existing fence. Recovery records unknown elapsed time without clocks restarted or
history inferred from timestamps, per-call sums or maxima. Retry never recounts.
Provider replay does not include timing metadata.

## Presentation and acceptance

Terminal rows use the source duration formatting and 50 ms visibility threshold.
A session badge explicitly says “Tool time” and represents completed batch wall
observations only. Legacy/unknown time is not displayed as zero. Running rows do
not animate a fabricated clock. Canonical results override ephemeral durations,
including when the canonical result has unknown duration after recovery.

Synthetic fixtures and loopback tests validate contracts. Native macOS interactive
GUI/input, TCC/AX/Keychain/signing, performance and release acceptance remain separate.
