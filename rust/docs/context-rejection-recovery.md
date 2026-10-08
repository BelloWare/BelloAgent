# Bounded context-rejection recovery

Specification: Swift `ProviderFailure.swift`, `PiProviderRules.swift`,
`SessionRun.swift`, `SessionCompaction.swift` and `CompactionPlanner.swift` at
`f4f80ddda3c27fac9e266896f69b725a06242e8f`. This slice starts from Rust Topics
`3a566ae58ee334c3b317a47ce099306c0d6535b5`.

## Connected workflow

An actual structured model rejection may consume one recovery opportunity:
retained rejected attempt → one summary request → durable checkpoint → one
retried model request. Recovery runs inside the existing physical turn worker,
with its original cancellation token, writer ownership and joined tool/MCP
history. It never calls the public manual-compaction lifecycle or re-enters a
completed tool batch. The manual command shares only the single-summary-request
and candidate-validation primitive; its Stop/join/queue behavior is unchanged.

The summary receives intact replay history. If that history plus summary reserves
cannot fit, no summary is sent. No truncation, model switch, summary repair,
transport retry or fallback is introduced. The recovery retained-tail target is
at most half the current replay message estimate, as in Swift. Estimates remain
estimates; they are never substituted for provider-reported usage.

The App identifies preparing, summarizing and retrying states, the retained failed
attempt, and an adopted checkpoint. A summary error retains the original rejection
and a specific safe failure in the run error. Cancellation takes precedence.

## Durable logical-request boundary

The initial failed assistant reply ID names the consumed logical model request.
The receipt separately records its original Submission ID, SHA-256 request
fingerprint, progress row, summary checkpoint, automatic-retry reply and actual
retry Submission. The fingerprint is forensic evidence, not a reset condition.
Creating a checkpoint, progress row, new automatic-retry reply or explicit Retry
never restores consumption.

An unresolved receipt blocks another summary for that same original or retry
Submission, including after process reopen. Only a durably accepted completed
model response establishes `resolved_reply_id`. This also covers an explicit
Retry that later succeeds: the original failed recovery remains historical, while
a subsequent genuinely new tool continuation can recover under its new failed
reply identity. Empty/incomplete/disabled-tool responses cannot establish this
boundary. Valid tool replies establish it atomically with their tool checkpoint.

One captured eligible steering item is prepared after checkpoint adoption using
ordinary image/skill/resource preparation and is appended exactly once during
retry admission. Follow-ups and held edits remain queued. This slice deliberately
keeps steering within the already-consumed automatic retry: a repeated rejection
cannot use that steering to create an unbounded recovery loop. This is stricter
than Swift's reset-on-delivered-input behavior.

Receipt phases are Preparing, Summarizing, RetryReady, Retrying and terminal
Completed/Failed/Cancelled/Interrupted. Consumption, summary admission, adoption
and retry admission are separate atomic storage checkpoints. Uncertain writes
fence further HTTP and mutations. Reopen interrupts a running receipt, keeps any
adopted checkpoint authoritative, pauses input and retains the original retry
identity; it never starts network or tools automatically.

Recovery metadata promotes snapshots to version 10 only when first introduced.
Fresh snapshots remain version 9; unchanged old reads retain their existing
behavior (including the pre-existing v1 migration). New fields under older
versions are presence-rejected even when empty/null. Receipt deserialization and
admission are bounded to 256 entries; exhaustion refuses automatic recovery.
References, chronology, phase/progress agreement and accepted-response resolution
are validated on load and mutation. No history is silently pruned.

## Classification and privacy

HTTP and actual JSON/SSE rejection envelopes retain a typed category, status,
physical attempt UUID, safe display text and optional reported usage. Structured
authentication, rate-limit, request-body-size and invalid-output-limit evidence
veto context classification. Explicit context codes and a restricted set of
source-derived prompt/context phrases may qualify otherwise unclassified provider
rejections. This intentionally excludes Swift's vague “too many tokens” and
“exceeds the limit” fallbacks. Assistant/tool content, incomplete streams, local
validation and transport errors do not qualify.

The existing credential/URL redaction runs before failures escape the provider.
Rejected-request, rejected-summary and rejected-retry envelopes preserve reported
usage when present and unknown otherwise. A successful summary observation stays
on its non-replay progress row, including when candidate validation fails. No cost
or cumulative pricing dashboard is implied.

## Binding and preserved gates

Before summary dispatch, adoption and retry admission, recovery checks certain
storage, worker/configuration identity, Stop/suspension/retirement, authority and
saved project resources/dependencies. Effective model and reasoning overrides are
retained. Historical source rows must match the checkpoint exactly. The legacy
synthetic dynamic-resource constructor retains its explicit automatic-compaction
refusal until equivalent snapshot integration is implemented.

Production tools, native trust/vault/capture and credential gates are unchanged.
Threshold automation, successful-reply usage overflow, side/fork behavior and cost
controls remain separate work. Synthetic loopback/GPUI tests and startup smoke do
not establish actual interactive GUI or native macOS/TCC/AX/Keychain/signing,
performance or release acceptance.

## Validation and source accounting

[Frozen local validation](validation/context-rejection-recovery-2026-10-08/README.md)
records the approved Core r3/App r2 hashes, successful 480/665 core unit suites,
127 integration tests per configuration, 619 App passes with 3 existing native
ignores, strict gates and the synthetic regression matrix. Independent source
accounting is 49,366 production/68,888 support/1,192 benchmark Rust lines; shared
workbench code is counted only under BelloBox. LOC is not a completion estimate.
