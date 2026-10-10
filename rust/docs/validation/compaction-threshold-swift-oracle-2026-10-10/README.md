# Compaction threshold: Rust vs Swift 0.1.122 — 2026-10-10

`swift-src/main.swift` is compiled with every unchanged source of Swift's
`PiAgentCore` module (`packages/swift-host/Sources/PiAgentCore` at
`6319e368`) into one module:

```sh
swiftc -O -module-name PiAgentCore -o oracle swift-src/main.swift PiAgentCore/*.swift
oracle cases.json > swift-thresholds.json
```

Its glue repeats `AgentSession.compactionPlan`, `compactionKeep` and
`compactionThreshold` line for line (no task root) and calls Swift's own
`CompactionPlanner.source/cut/plan`, `ProviderClient.responsesProjection`,
`CompactionSourceBuilder.boundary/instruction`,
`RequestContextCounter.inputTokens/projectedTokens`,
`CompactionPolicy.trigger/summaryTokens` and `RequestContextCount.safetyMargin`.

`cases.json` holds 15 compact case specs (windows 300 to 1,000,000, output
budgets and model output limits, short/long/unanswered/unicode/many-row chats,
one huge input, empty instructions). The Rust test
`compaction::tests::threshold_request_count_and_reserves_match_the_swift_oracle`
expands the same specs and matches every request estimate, safety margin,
summary allowance and threshold, and the one `compact_budget` refusal.

Found by the oracle: Swift names an id-less assistant item `msg_pi_<n>` in the
boundary's `firstRetainedItem`; Rust now does the same.

Source SHA-256: CompactionPlanner.swift b9dcda06…f0397d,
CompactionSourceBuilder.swift bdbf80da…3944, SessionCompaction.swift
c393f2f8…a318, RequestContext.swift d171f6db…a9a9, ResponsesInput.swift
7fc675ca…b2bb, Providers.swift b67f25b3…c46.
