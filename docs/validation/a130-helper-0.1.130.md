# Helper fixes for 0.1.130

Workstream: `dev/a130-helper`, base `141666ca479184d10a9791754d4c91df456599d8`. Generated fixtures and loopback services only; no installed-app launch, real preferences, chats, credentials, Keychain, paid provider, release, tag, or publication. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper`. Text evidence is under its `logs/` directory.

## Findings

### helper-agents-io-1 — confirmed and fixed

`ResponseMasker` recognized only literal credentials and two encoder spellings. A JSON response containing `Rejected \u0073k-test-secret` therefore preserved a usable credential in memory and persistent capture packets.

The masker now matches each credential's Unicode scalars against literal UTF-8, JSON short escapes, and case-insensitive UTF-16 hexadecimal escapes, including surrogate pairs. It masks the original byte spans, retains enough suffix bytes for the longest escaped spelling, and keeps overlapping matches against the original input. Parsing still receives the unmodified provider bytes. No capture mode, credential source, permissions, or archive ownership changed.

Regression: `CredentialCaptureTests.testJSONEscapeEquivalentCredentialsAreMaskedAtEveryCaptureSplit`. Three generated credentials cover partial/mixed Unicode escapes, escaped slash/quote/backslash/newline, and a surrogate pair. Every two-chunk byte split and one-byte feeds run in both memory and persist modes, with padding that forces output before EOF. Checks include JSON decoding, exact expected bytes, contiguous durable offsets, masking metadata, and unchanged byte counts. `testJSONEscapeMaskingLeavesMalformedAndUnrelatedEscapesUnchanged` covers invalid hex and malformed/nonmatching surrogate sequences.

Failing first (`failing-first.log`):

```text
XCTAssertFalse failed - memory, split 0, \u0073k-test-secret
XCTAssertEqual failed: ("Optional(0)") is not equal to ("Optional(1)")
XCTAssertEqual failed: ("Optional(true)") is not equal to ("Optional(false)")
```

Nearby sweep: mixed slash/short-escape/Unicode spellings use the same matcher. Request bodies originate from the local encoder and already match that encoder's spelling; parsed identity/gateway metadata is sanitized after decoding. Response headers do not undergo JSON decoding. A separate raw SSE event-index issue is recorded below; no additional production path was enabled.

Mutation evidence: disabling escaped matching failed the regression (1 test, 2,150 assertion failures; `mutation-capture-decoding.log`). Keeping decoded matching but shortening the retained suffix to literal credential length also failed (1 test, 312 assertion failures; `mutation-capture-suffix.log`). Both mutations were reverted, and all 12 capture tests passed again.

### helper-agents-io-2 — confirmed and fixed

A successful `subagent_start(mode: wait, timeout_ms: 0)` returned an operation ID as `wait.wait_id` while its acceptance record lacked `waitTargets`. Status rejected that ID both live and after journal replay.

New start-with-wait acceptance records persist the singleton accepted turn target. Status derives that target from an older accepted start when its saved target list is absent. This uses the parent's already accepted operation and turn; it grants no execution or cross-family access. Existing wait operations retain their frozen target lists. Older starts did not persist the mode, so the compatibility lookup accepts a saved start's operation ID without trying to infer its former mode.

Regressions: `AgentSteeringCommandTests.testStartWithWaitIDListsItsAcceptedTurnBeforeAndAfterReopen` executes the actual start tool batch, checks its returned wait ID and saved target, then lists the original child and turn live and after reopening. `testLegacyStartWithWaitIDListsItsAcceptedTurnAfterReopen` removes the optional targets from the generated journal before reopening to cover the released record shape.

Failing first (`failing-first.log`):

```text
Returned wait ID must remain usable: AgentError(code: "subagent_scope", message: "Unknown wait", ...)
```

The current-format test failed both lookups; the legacy test failed its reopened lookup. Nearby sweep: explicit `subagent_wait` already persists its target list; the wait helper and crash-recovered tool receipt already derive singleton start targets. No other unusable returned ID was found.

Mutation evidence: removing the singleton target at acceptance failed the saved-target assertion (1 test, 1 failure; `mutation-wait-acceptance.log`). Removing the compatibility fallback failed the older-journal lookup with `Unknown wait` (1 test, 1 failure; `mutation-wait-legacy.log`). Both mutations were reverted, and all 5 command tests passed again.

### helper-sessions-1 — confirmed and fixed

Reopen preserved cost-held calls correctly but assigned the entire unfinished context to the side/fork boundary. A newly submitted side then failed with `compact_unsafe` when resumed.

After ordinary recovery, reopen indexes the active context's results by owning assistant occurrence and stops the copied boundary before the first incomplete batch. The parent's context and held calls remain intact. This preserves earlier complete batches even when a provider reuses a call ID. Changes in `Sessions.swift` are confined to boundary reconstruction; `AgentFamilyRecovery.swift`, `stop()`, and `SessionCost.swift` are untouched.

Regression: extended `CostLimitTests.testHeldToolCallsSurviveARelaunchAndRunFirstOnResume`. A $0.06 tool reply crosses a $0.05 limit, the parent reopens, the limit rises, and a side is created/submitted before family Resume. The side answers, only the parent invokes the held tool, and the parent's resumed request contains its result.

Failing first (`failing-first-side.log`, final isolated run):

```text
XCTAssertEqual failed: ("Optional("error")") is not equal to ("Optional("idle")") - "An assistant/tool batch is incomplete; inspect its effects before compacting"
XCTAssertEqual failed: ("Optional("Side question")") is not equal to ("Optional("Side answer")")
XCTAssertEqual failed: ("0") is not equal to ("1")
Executed 1 test, with 3 failures (0 unexpected)
```

Fixture adjustment: binding a side activates accounted family requests, so the reopened parent and side use the existing `AccountedAgentScript`. The initial legacy billing client remains responsible for the crossing reply. An initial fixture-only unsupported-client error was removed before the isolated failing-first run above.

Nearby confirmed instance: both whole-chat fork paths consume the same reopened boundary. `testReopenedHeldBatchKeepsCompletePrefixForSidesAndForks` checks a previously completed batch, a later held call reusing its ID, unchanged side-origin cutoff/revision, retained parent held calls, and the reopened fork's complete prefix. The boundary fix covers this instance without modifying fork persistence.

Mutation evidence: restoring `boundary=context` failed both the end-to-end side regression and the separate side/fork-prefix regression (2 tests, 8 assertion failures; `mutation-side-boundary.log`). The fork retained the unfinished batch, and `omittedIncompleteEntries` was 0 instead of 1. Restoring the fix passed all 23 cost-limit tests.

### helper-sessions-2 — confirmed and fixed

`completeWithRetries()` measured cancelled and failed requests, but `run()` transferred those durations into turn/session totals only after validating a successful reply. Counters now settle once when `completeWithRetries()` exits on any outcome. Its existing per-attempt measurement still excludes retry backoff; the successful assistant row retains its own request duration.

Regressions: `RetryTests.testStoppedRequestKeepsModelTimeAcrossReopen` and `testNonretryableRequestKeepsModelTimeAcrossReopen`. A generated client streams a partial response, remains in the request for at least 100 ms, then separately receives Stop or returns HTTP 401. Tests compare turn/session counters exactly to the measured request duration and the reopened cumulative counter. The existing successful-retry test also checks exact once-only accounting and exclusion of backoff.

Failing first (`failing-first.log`):

```text
testNonretryableRequestKeepsModelTimeAcrossReopen: Optional(0.0) != Optional(111.88370835781097)
testStoppedRequestKeepsModelTimeAcrossReopen: Optional(0.0) != Optional(111.54520833492279)
```

Each failed all three turn/session/reopened comparisons. Nearby sweep: summary requests already use unconditional duration settlement in `SessionSummarizer.summaryReply`; overflow recovery and invalid successful-reply exits now retain ordinary request time through the same corrected path. No second timing counter fix was needed.

Mutation evidence: removing unconditional counter settlement failed both regressions' turn/session/reopened comparisons (2 tests, 6 assertion failures; `mutation-request-timing.log`), with measured durations of 109.96 ms and 109.61 ms but recorded totals of zero. Restoring the fix passed all 12 retry tests.

## Validation commands and results

All commands ran from the worktree root. No source files were added or removed, so project regeneration is unnecessary. No UI changed, so no native gallery or focus-changing run is needed.

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'CredentialCaptureTests/testJSONEscapeEquivalentCredentialsAreMaskedAtEveryCaptureSplit|AgentSteeringCommandTests/test.*StartWithWaitID|CostLimitTests/testHeldToolCallsSurviveARelaunchAndRunFirstOnResume|RetryTests/test(Stopped|Nonretryable)RequestKeepsModelTimeAcrossReopen'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter CostLimitTests/testHeldToolCallsSurviveARelaunchAndRunFirstOnResume
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'PiAgentCoreTests\.(CredentialCaptureTests|AgentSteeringCommandTests|CostLimitTests|RetryTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter 'PiAgentCoreTests\.(CaptureTraceTests|CaptureConcurrencyTests|CaptureDrainTests|TraceBufferPerformanceTests|AgentFamilyRecoveryTests|AgentMailboxPolicyTests|AgentSteeringLegacyTests|AgentSteeringRetryTests|RetryRecoveryTests|FamilyLimitPauseTests|ContinueRunTests|ForkPointTests|ForkReplayHandoffTests|SideForkTests|AcceptanceTests|SteeringAndFollowUpTests|IncompleteRetryTests|CompactionBudgetTests|CompactionPiTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
```

- Failing first: all six new/extended regression tests failed. The isolated side run above removed fixture-only failures.
- Focused classes: 52 passed, 0 failed (`focused-final.log`), before mutation checks.
- Restored focused classes: 52 passed, 0 failed (`focused-restored.log`): `CredentialCaptureTests` 12, `AgentSteeringCommandTests` 5, `CostLimitTests` 23, `RetryTests` 12.
- An earlier broader substring filter also included `AgentSteeringRetryTests` and `IncompleteRetryTests`: 75 passed, 0 failed (`focused.log`, before the final two added sweep tests).
- Full helper: 1,026 executed, 1,019 passed, 7 skipped, 0 failed. This is the five `StreamingCostTests` run alone (3.659 s, `helper-cost.log`) plus the remaining 1,021 tests (7 skipped, 0 failed, 406.878 s, `helper.log`). The seven skips are existing opt-in fixture-writer/performance tests: one `ForkCloneTests`, one `ForkPerformanceTests`, one `HistoryReadCancellationTests`, and four `SessionOpenPerformanceTests`. The long legacy side-budget matrix buffered output; a read-only process sample showed active journal/recovery work, and the run completed normally without interruption.
- Release bundle: passed (104.33 s, `bundle.log`).
- Release wire: 36 passed, 0 failed (33.596 s, `wire.log`).
- Release concurrent: 4 passed, 0 failed (28.434 s, `concurrent.log`).
- Release acceptance: 3 passed, 0 failed (3.480 s, `acceptance.log`).
- Adjacent focused classes: 152 passed, 0 failed (25.019 s, `focused-related.log`), using the explicit class filter above. `git diff --check` also passed.

Each mutation used the common command `swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '<filter>'`, sequentially, restoring the fixed source in a `finally` block before moving to the next mutation:

| Mutation log suffix | Filter | Tests failed as expected |
| --- | --- | ---: |
| `capture-decoding`, `capture-suffix` | `CredentialCaptureTests/testJSONEscapeEquivalentCredentialsAreMaskedAtEveryCaptureSplit` | 1 each |
| `wait-acceptance` | `AgentSteeringCommandTests/testStartWithWaitIDListsItsAcceptedTurnBeforeAndAfterReopen` | 1 |
| `wait-legacy` | `AgentSteeringCommandTests/testLegacyStartWithWaitIDListsItsAcceptedTurnAfterReopen` | 1 |
| `side-boundary` | `CostLimitTests/test(HeldToolCallsSurviveARelaunchAndRunFirstOnResume\|ReopenedHeldBatchKeepsCompletePrefixForSidesAndForks)` | 2 |
| `request-timing` | `RetryTests/test(Stopped\|Nonretryable)RequestKeepsModelTimeAcrossReopen` | 2 |

One build attempt was rejected because a source file changed while the compiler was reading inputs; no test executed in that attempt. The subsequent isolated baseline and focused runs completed normally. Further builds and source mutations run sequentially.

## Separate unassigned sweep finding

**SSE event-type metadata can expose a known credential.** At `packages/swift-host/Sources/PiAgentCore/TraceStore.swift:163`, `event()` indexes `event.event` without applying the request's credential sanitizer. `Providers.swift:190` supplies the original parsed event, and `TraceStore.swift:170` sends the index to persistent capture. Scenario: the provider returns `event: sk-generated-event-secret\ndata: {}\n\n` while that generated string is the configured API key. The masked response body is safe, but `debug.raw-events` and the persistent `events` packet retain the key as the event `type`.

Confirmed with the scratch-only `sse-event-probe.swift`, compiled against the same Debug helper objects and using the real `SSEParser`, `TraceStore`, memory mode and an acknowledged persistent sink. No repository source changed for the probe. Evidence: `logs/sse-event-probe.log`:

```text
memory: bodyEcho=false, eventTypeEcho=true, durableEventTypeEcho=false
persist: bodyEcho=false, eventTypeEcho=true, durableEventTypeEcho=true
```

This is a distinct missing sanitizer in a different function, rather than JSON escape matching in response bodies. It is left for the lead under the instruction to report other bugs instead of expanding this workstream. No real credential was used.

## Decisions and remaining work

No assigned finding rejected. No owner decision or UX change is required for these fixes. The separate SSE event-type issue above remains unresolved; no unrelated bug has been fixed. The lead retains merge and full native-gate responsibility. This workstream created no DerivedData or clone folders; its helper builds, logs and scratch probe occupy about 557 MiB in its assigned build root.
