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

This is a distinct missing sanitizer in a different function, rather than JSON escape matching in response bodies. At the original handoff it was left for the lead under the instruction to report other bugs instead of expanding this workstream. The owner subsequently assigned it; the follow-up below resolves it. No real credential was used.

## Decisions and remaining work

No original assigned finding rejected. No owner decision or UX change is required for these fixes. The SSE event-type issue was unresolved at the original handoff and is now addressed below. The lead retains merge and full native-gate responsibility. The original workstream created no DerivedData or clone folders; its helper builds, logs and scratch probe occupied about 557 MiB in its assigned build root.

## Follow-up — capture metadata credentials

Owner-assigned follow-up on `dev/a130-helper`, after the original branch was merged and this worktree fast-forwarded to `5c52621c`. All evidence for this section is in `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/sse-metadata/`. The same build root was reused. Generated credentials and an ephemeral loopback gateway only.

### Confirmed fixes and failing-first evidence

The first run added four regressions without changing production code: all four failed, with 30 assertion failures and no unexpected errors (`failing-first.log`). Each test exercises memory and persist modes.

1. **SSE event types — confirmed and fixed.** `CredentialCaptureTests.testSSEEventTypesMaskCredentialsBeforePreviewInMemoryAndPersistedPages` feeds 130 real SSE events one byte at a time, including an exact credential, a credential crossing the 128-byte preview boundary, normal names, and both full and final partial persistence pages. Before the fix: `XCTAssertEqual failed: Optional("sk-generated-event-secret") ... Optional("[sha256:dc4ac548…]") - memory, event 0`, with the same failure in persist mode; event 1 retained `xxxxxxxx…sk-g`. `TraceStore.event()` now fingerprints a credential-bearing name before previewing it. The test checks original parser input, event counts, offsets, memory pages, persistent pages and length-preserving response masking.
2. **Request/response header names — confirmed sweep instance, fixed.** `testCapturedRequestAndResponseHeaderNamesCannotEchoCredentials` reproduced a key embedded in a valid custom header name. The value was protected, but the dictionary key was retained and delivered unchanged: `XCTAssertFalse failed - memory` and `... - persist`; the expected fingerprinted header was missing. Both header capture methods now fingerprint credential-bearing normalized names. Tests also cover masked header values, oversized values, ordinary readable headers, `Retry-After`, and unchanged wire headers.
3. **Gateway cache provenance — confirmed sweep instance, fixed.** `testGatewayCacheHeaderSourceCannotEchoCredentials` uses an accepted routing contract with the generated credential embedded in `cacheHeader`. The cache observation was safe but `gateway.cache.source` retained `header:x-cache-sk-generated-cache-value`: `XCTAssertEqual failed: Optional("header:x-cache-sk-generated-cache-value") ... Optional("[sha256:f709f328…]")` in both modes. Capture now applies the existing recursive metadata sanitizer to gateway metadata; the cache hit observation remains intact.
4. **Raw usage metadata — confirmed sweep instance, fixed.** `testCapturedRawUsageSanitizesNestedCredentialValuesAndFieldNames` passes a real `ProviderAccumulator` result to capture. Normalized usage retains arbitrary provider fields under `usage.raw`; a nested credential value and object key both escaped body masking. Before the fix: `XCTAssertEqual failed: Optional("sk-generated-usage-value") ... Optional("[sha256:21fa0a45…]")` and the fingerprinted key was missing in both modes. Capture sanitizes its usage copy, and the recursive sanitizer now handles object keys as well as values. Numeric accounting, ordinary fields and the original provider result are unchanged.

All 17 `CredentialCaptureTests` then passed (`fixed.log`). No new source files were added, so project regeneration was unnecessary. No UI changed.

### Remaining metadata sweep

- **SSE `id` and `retry`:** `Transport.swift` retains only `event`, `data`, and numeric byte offsets in `SSEEvent`. ID/retry text is not separately indexed; its response bytes pass through the masker.
- **HTTP IDs and retry headers:** header values already use credential checks. Routing/gateway call IDs and gateway versions already reject credential-bearing values. Normal retry behavior and provider parsing remain unchanged.
- **Error metadata:** provider HTTP/stream errors use fixed local error codes and typed `ProviderFailure`; `ProviderClient.safeFailure` sanitizes provider message/code/type text before it reaches operation diagnostics. Summary outcomes allowlist status/reason fields. Transport outcomes and recorder failure messages are local constants; the recorder returns only an acknowledgment boolean. No additional error-path fix was needed.
- **Other structured metadata:** routing identity already uses the sanitizer. Usage was the arbitrary provider object that bypassed it and is fixed above. Request scopes, message links and attempt IDs are helper-owned correlation identities and remain unchanged.

`testLoopbackErrorIDsAndRetryFieldsDoNotEscapeCaptureMasking` verifies both HTTP 401 and SSE error responses in both capture modes. The generated gateway echoes a synthetic key in SSE ID/retry fields, provider error message/code/type/object keys, `Retry-After`, request ID, gateway call ID and gateway version. It checks sanitized error text and operation metadata, masked retained response bytes, metadata packets, and the absence of ID/retry fields from event indices. All four loopback scenarios pass.

### Mutation checks

Each mutation ran alone, rebuilt the helper test executable, failed its targeted regression as expected, and restored the fixed file in a `finally` block. `mutations.log` records all seven; `capture.log` is the successful restored-source run.

| Mutation log | Regression | Result |
| --- | --- | --- |
| `mutation-event-sanitizer.log` | `testSSEEventTypesMaskCredentialsBeforePreviewInMemoryAndPersistedPages` | 1 failed test; 3 assertions |
| `mutation-event-preview-order.log` | same; sanitize after clipping | 1 failed test; 1 assertion |
| `mutation-request-header-name.log` | `testCapturedRequestAndResponseHeaderNamesCannotEchoCredentials` | 1 failed test; 8 assertions |
| `mutation-response-header-names.log` | same; restore all three original response-name returns | 1 failed test; 10 assertions |
| `mutation-gateway-source.log` | `testGatewayCacheHeaderSourceCannotEchoCredentials` | 1 failed test; 4 assertions |
| `mutation-usage-sanitizer.log` | `testCapturedRawUsageSanitizesNestedCredentialValuesAndFieldNames` | 1 failed test; 8 assertions |
| `mutation-metadata-field-names.log` | same; retain original object keys | 1 failed test; 6 assertions |

### Follow-up validation commands

Run from this worktree, serially; logs are separate from the original workstream's evidence:

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
# Failing first, before production edits:
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'CredentialCaptureTests/test(SSEEventTypesMask|CapturedRequestAndResponseHeaderNames|GatewayCacheHeaderSource|CapturedRawUsage)'
# Fixed credential class:
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '^PiAgentCoreTests.CredentialCaptureTests/'
# Each mutation used the same swift command, --filter CredentialCaptureTests/<regression> from the table.
python3 "$BUILD/metadata-mutations.py"
# Restored capture and adjacent classes:
export PI_BUILD_ROOT="$BUILD" SWIFT_BACKTRACE='enable=yes,interactive=no,threads=all'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '^PiAgentCoreTests.(CredentialCaptureTests|CaptureTraceTests|CaptureConcurrencyTests|CaptureDrainTests|TraceBufferPerformanceTests|GatewayTelemetryTests|RoutingTests|ProviderStreamErrorTests|ProviderStreamingTests|ProviderMediaTypeTests|HTTPIngressTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
git diff --check
```

| Suite / log | Result | Duration |
| --- | --- | ---: |
| Fixed credential class, `fixed.log` | 17 passed, 0 failed | 2.496 s |
| Restored capture and adjacent classes, `capture.log` | 62 passed, 0 failed | 14.327 s |
| Isolated helper measurements, `helper-cost.log` | 5 passed, 0 failed | 3.698 s |
| Remaining full helper suite, `helper.log` | 1,026 executed: 1,019 passed, 7 skipped, 0 failed | 391.526 s |
| Release bundle, `bundle.log` | passed | 74.186 s |
| Release wire, `wire.log` | 36 passed, 0 failed | 33.255 s |
| Release concurrent, `concurrent.log` | 4 passed, 0 failed | 24.933 s |
| Release acceptance, `acceptance.log` | 3 passed, 0 failed | 3.458 s |

Full helper total: **1,031 executed, 1,024 passed, 7 skipped, 0 failed**. The seven skips are the same existing opt-in checks: one each in `ForkCloneTests`, `ForkPerformanceTests`, and `HistoryReadCancellationTests`, plus four in `SessionOpenPerformanceTests`. There were no unrelated failures. `results.json` retains exact runner commands and elapsed times; `git diff --check` passed.

At this handoff no capture finding remained unresolved. The round-2 review below subsequently identified and corrected schema regressions in this implementation. The lead retains review, merge and full native-gate responsibility. This follow-up created no DerivedData, clone folders or xcresult bundles.

## Round 2 — fixed schema preservation

Review base: `5de98929`. Fetched `origin/dev/next` and reviewed the complete branch diff against `5c52621c5db150bf6b1372eb47015c028301983c`, including the preceding capture-metadata commit and this correction. Build root remains `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper`; new evidence is under `logs/metadata-schema/`. Generated credentials, temporary journals and loopback fixtures only.

### Review finding — confirmed and fixed

The recursive key sanitizer changed helper-owned keys whenever a configured header value matched them, including substrings. `X-Region: status` or `X-Region: us` renamed routing `status`; `X-Region: effectiveModel` renamed the effective-model field. The identity saved on the assistant message then failed the unchanged pinned-route replay guard, both immediately and after reopening its journal. Off mode was affected too because identity metadata is independent of body-capture mode.

`RoutingTests.testConfiguredHeaderMatchingSchemaKeysKeepsPinnedReplayAfterReopen` exercises those three header values in Off, memory and persist modes. It obtains identity from the real `TraceStore`, attaches opaque provider reasoning and the real replay binding, verifies replay, writes a generated `SessionJournal`, reopens it and verifies replay again. It also checks the monitoring identity status.

Failing-first excerpt (`failing-first-complete.log`, before any production fix):

```text
RoutingTests.swift:19: XCTAssertEqual failed: ("nil") is not equal to ("Optional(\"reported\")") - status, off
RoutingTests.swift:20: XCTAssertEqual failed: threw error "AgentError(code: \"opaque_route_changed\", ...)" - status, off
RoutingTests.swift:35: XCTAssertEqual failed: threw error "AgentError(code: \"opaque_route_changed\", ...)" - status, off
```

The ordinary `metadata(_:)` entry point again preserves fixed keys, including keys nested in arrays and objects. Its unary signature is retained for existing context-preview callers. Only `usage.raw` opts into recursive key sanitization via `includingKeys: true`; HTTP header dictionaries continue to sanitize their provider/configuration-controlled names. String credential masking and the original SSE/header/provenance/raw-usage regressions remain covered.

### Adversarial self-review findings — fixed

The whole-branch review found two additional consequences of applying the sanitizer to helper-owned accounting structures:

- **Normalized usage:** besides keys such as `status`, `input`, `output` and `raw`, fixed status values such as `reported`, `unreported` and `invalid` were fingerprinted when a configured header matched them. `testConfiguredHeaderMatchingUsageSchemaPreservesNormalizedAccounting` failed before the fix. It covers eight header values × three capture modes × completed/cancelled/failed outcomes, checks live and settled metadata and emitted packets, and still requires nested raw provider keys/values to be sanitized. Capture now copies normalized accounting unchanged and sanitizes only a present `raw` member.
- **Gateway accounting:** the broad gateway sanitizer also changed fixed keys and status values such as `reported` and `hit`. `testConfiguredHeaderMatchingGatewaySchemaPreservesReportedAccounting` failed before the fix across seven header values × three capture modes × JSON/SSE observations. Capture now sanitizes only `gateway.cache.source`, the configuration-derived provenance string that needed protection. Fixed cost/cache schema and status values remain intact. Other provider strings in gateway telemetry already pass credential-exclusion checks at ingestion.

For example, before the fix, normalized `status.input` became `[sha256:8e752bb9…]` for `X-Region: reported`, and gateway `cost.status`/`cache.status` lost their literal status values. All three new tests failed in the complete baseline: 321 recorded failures, including 18 thrown `opaque_route_changed` errors that XCTest labels unexpected. Those throws are the reproduced defect, not unrelated test failures. The initial baseline stopped the usage matrix early when its `raw` key vanished; replacing that unwrap with a nonthrowing assertion allowed the complete baseline to exercise every configured value.

### Whole-branch condition audit

Reviewed `git diff origin/dev/next --` after the corrections, not only the final patch. The table enumerates every production condition whose inputs or result changed in this branch; the existing capture/lifecycle conditions around them were also traced.

| Changed operation / condition | States taking the different path; intended result and checks |
| --- | --- |
| Request-header name passed to `metadataText` | A normalized name containing a known credential is fingerprinted; other names are identical. Existing ordinary/configured/sensitive-header and value-mask decisions are unchanged. Wire headers are never modified. The header regression covers normal and credential-bearing names. |
| All three response-header return paths | A matching name is fingerprinted whether its value is allowed, masked, or omitted for size/control limits. The `safe` and size/control predicates themselves are unchanged. The existing header regression checks all three return paths and `Retry-After`. |
| SSE name sanitized before its 128-byte preview | Matching names become a complete fingerprint even when the credential crosses the preview boundary; nonmatching names retain the original preview. Original SSE parsing, byte offsets, event counts, the 128-event persistence threshold, and mode checks are unchanged. The one-byte-feed regression checks full and tail pages. |
| Fixed-schema `metadata(_:)` delegates with `includingKeys: false` | Keys always retain their protocol spelling even if a credential equals a key or a substring. This restores `origin/dev/next` behavior for routing identity, monitoring and context-preview body/source schemas. Existing string-value masking is preserved. The pinned-replay regression catches the reviewed failure. |
| Provider dictionaries opt into `includingKeys: true` | Only `usage.raw` enters this path. Matching keys and string values are fingerprinted recursively through arrays and objects; nonmatches and number/bool/null nodes retain their original behavior. The prior raw-usage regression checks nested keys and values, and the provider-key mutation proves this protection remains active. |
| `TraceStore.usage` trace lookup and `raw` presence | Missing attempt IDs remain no-ops, equivalent to the old optional assignment. With a trace, normalized fields are copied unchanged. An absent raw member stays absent; explicit null remains null; a supplied raw value is sanitized separately. No fixed accounting keys or status enums pass through credential matching. The new usage matrix covers running and terminal states. |
| Gateway cache source is a string / contains a credential | Missing/null provenance remains missing/null. A normal source remains identical; a credential-bearing source becomes a fingerprint. The rest of the typed gateway object stays unchanged, including cost/cache statuses and numeric observations. The existing cache-source leak test and new JSON/SSE schema test cover both sides. |

State review:

| State | Evidence / invariant |
| --- | --- |
| Streaming and nonstreaming | Gateway regression covers both; original bytes still reach provider parsing. The SSE and body-mask regressions retain their offsets and paging checks. |
| Idle and paused | Sanitization reads per-attempt metadata and changes no run, queue, resume, tool or budget state. The focused run includes `ContextPreviewTests`, `ContextScopeTests` and all `CostLimitTests`, covering idle/active previews and held/reopened cost pauses. |
| Off / memory / persist | New regressions cover all three modes. Off retains its existing metadata-only policy; body retention is not enabled. Memory retains helper copies; persist keeps existing acknowledgment, paging and eviction behavior. |
| Restart | The pinned-replay regression reopens nine generated journals. This correction preserves newly written identity metadata; it does not rewrite existing journals or archives. |
| Cancellation / failure | The usage matrix checks both outcomes and completed requests. Existing capture-tail/drain tests cover masked-tail flush and rejected/late acknowledgments. |
| Concurrent sibling work | Credentials remain frozen per trace, the key-sanitization flag is a call-local value, and there is no new shared state or suspension inside a metadata update. Capture concurrency/drain tests and the Release concurrent suite check sibling isolation and ordered delivery. |

No additional unintended state change was found in the branch diff after fixing schema keys and the two accounting cases above. Scope, capture ownership, body modes, tool/permission boundaries and provider dispatch remain unchanged.

### Round-2 mutation and validation evidence

All 25 tests in `CredentialCaptureTests` and `RoutingTests` passed after the fix (`fixed-complete.log`). An earlier fixed-build attempt failed to compile because a defaulted second parameter cannot be passed as the existing unary `sources.map(credentials.metadata)` function reference; retaining the unary overload corrected it, and no test was omitted.

Each mutation rebuilt and ran its targeted test, then restored the fixed source in `finally` (`schema-mutations.py`, `mutations.log`):

| Mutation log | Changed behavior | Expected failure |
| --- | --- | --- |
| `mutation-fixed-schema-keys.log` | Make the ordinary sanitizer rewrite keys again | Pinned-replay regression: 1 failed test, 30 recorded failures including 18 `opaque_route_changed` throws |
| `mutation-normalized-usage-values.log` | Sanitize normalized usage strings while keeping fixed keys | Usage-schema regression: 1 failed test, 70 assertions |
| `mutation-gateway-status-values.log` | Sanitize all gateway strings while keeping fixed keys | Gateway-schema regression: 1 failed test, 66 assertions |
| `mutation-provider-keys.log` | Disable raw provider key sanitization | Existing nested raw-usage leak regression: 1 failed test, 6 assertions |

Commands, run serially from this worktree:

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
# Before production changes; initial and complete baseline logs are retained:
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'testConfiguredHeaderMatching'
# Fixed classes before mutation:
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '^PiAgentCoreTests.(CredentialCaptureTests|RoutingTests)/'
# Each mutation uses swift test with --filter Class/test from the table above:
python3 "$BUILD/schema-mutations.py"
export PI_BUILD_ROOT="$BUILD" SWIFT_BACKTRACE='enable=yes,interactive=no,threads=all'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '^PiAgentCoreTests.(CredentialCaptureTests|CaptureTraceTests|CaptureConcurrencyTests|CaptureDrainTests|TraceBufferPerformanceTests|GatewayTelemetryTests|RoutingTests|ProviderStreamErrorTests|ProviderStreamingTests|ProviderMediaTypeTests|HTTPIngressTests|ContextPreviewTests|ContextScopeTests|DecodeSpanTests|CostLimitTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
git diff --check
```

| Suite / log | Result | Duration |
| --- | --- | ---: |
| Fixed credential and routing classes, `fixed-complete.log` | 25 passed, 0 failed | 2.629 s |
| Restored capture and adjacent classes, `capture.log` | 101 passed, 0 failed | 20.798 s |
| Isolated helper measurements, `helper-cost.log` | 5 passed, 0 failed | 3.824 s |
| Remaining full helper suite, `helper.log` | 1,029 executed: 1,022 passed, 7 skipped, 0 failed | 396.624 s |
| Release bundle, `bundle.log` | passed | 65.766 s |
| Release wire, `wire.log` | 36 passed, 0 failed | 33.435 s |
| Release concurrent, `concurrent.log` | 4 passed, 0 failed | 25.916 s |
| Release acceptance, `acceptance.log` | 3 passed, 0 failed | 3.497 s |

Full helper total: **1,034 executed, 1,027 passed, 7 skipped, 0 failed**. The seven skips remain the existing opt-in checks: one each in `ForkCloneTests`, `ForkPerformanceTests`, and `HistoryReadCancellationTests`, plus four in `SessionOpenPerformanceTests`. There were no unrelated failures. All four mutations failed as intended before restoration. `results.json` retains exact runner commands and elapsed times; `git diff --check` passed.

No round-2 finding remains unresolved. The lead retains review, merge and full native-gate responsibility. This correction adds no files or UI changes and created no DerivedData, clone folders or xcresult bundles.

## Round 2 hunt

Base: `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1` (the merged worktree supplied for this hunt). Changes stay on `dev/a130-helper`. Evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/round2-hunt/`; all generated data, scripted clients and loopback traffic. No installed app, real user data, credentials, preferences, Keychain or paid calls. No files were added to the project and no UI layout changed.

### Findings and failing-first evidence

All six hunt findings and the separately assigned host-actor disk issue were confirmed. None was rejected.

| Finding | Reproduction and pre-fix evidence | Minimal correction / nearby sweep |
| --- | --- | --- |
| **helper-sessions-3 — confirmed + fixed** | `RetryTests.testRetryRejectsAnUnloadedSessionBeforeProviderOrToolWork`: fail a scripted request, unload successfully, Retry. Before the fix: `An unloaded runtime must reject Retry`; provider requests **3 instead of 1**, and the recording tool ran (`initial-failing-first.log`). `testHostRetryCannotOvertakeUnloadBeforeRegistryRemoval` holds the close path after unload but before registry removal: `Concurrent Retry was accepted after unload` (`host-retry-failing-first.log`). | Check `closed` before Retry changes state or launches. Existing managed-session authority check retains precedence. Submission, Continue, configuration and compaction already reject closed sessions. A separate real instance in `resumeQueue()` is described below. |
| **helper-sessions-4 — confirmed + fixed** | Extended `testStoppedRequestKeepsModelTimeAcrossReopen`, `testNonretryableRequestKeepsModelTimeAcrossReopen`, and `testModelTimeCountsRequestsNotTheBackoffBetweenThem`. Stop/failure: task `modelMs` **0 vs ~111 ms**, live and after reopen. Automatic retry counted only the winning request. These three tests produced five baseline assertions (`initial-failing-first.log`); retry now also checks its reopened task receipt. | Add the already-measured request-attempt total when `completeWithRetries` settles on every outcome. Remove the separate assistant-row addition, preventing successful-attempt double counting. Backoff remains excluded. No other task model-time accumulator was found. |
| **helper-sessions-5 — confirmed + fixed** | Extended `ToolOutcomeTests.testAnImageOnlyResultReachesTheModelAsPiSendsIt`. Live output was `[image/png result, 3000 bytes]`; reopened output was empty (`second-failing-first-complete.log`). | Reconstructed cards prefer `displayText ?? text`. This covers both the in-memory history index and paged result pairing; text-only/legacy results retain their fallback. Model-facing image content is unchanged. No other result-card reconstruction used the wrong field. |
| **HELPER-AGENTS-IO-1 — confirmed + fixed** | `RequestContextTests.testOutputRoomClampsBeforeSubtractingAnEnormousUsage` and `PiContextSessionTests.testMalformedUsageSnapshotAndReopenRemainSafe` each terminate with **signal 5, Swift runtime failure: arithmetic overflow**, at `PiContext.outputRoom` (`output-room-failing-first.log`, `usage-session-failing-first.log`). Profile 2048/128 and total `9223372036854774784`, as reported. `testInvalidRawCountsCannotOverrideNormalizedUsage` also reproduces invalid cached/read-write counts: raw baselines override validated components (three assertions). | Check remaining room before subtraction. Build Pi-shaped usage from validated components, retaining raw observations only as evidence. Invalid totals fall back to valid parts; the reproduced reply now anchors **2** tokens and snapshots/reopens safely. Nearby arithmetic already uses checked addition or bounded profile fields. An existing test deliberately preferred an inconsistent raw total; its expected value changes from 70,500 to the validated 70,000, as explicitly requested in this hunt. |
| **HELPER-AGENTS-IO-2 — confirmed + fixed** | Added `reported` to `RoutingTests.testConfiguredHeaderMatchingSchemaKeysKeepsPinnedReplayAfterReopen`. Off, memory and persist each fingerprinted `status`, producing **12 assertions including 6 `opaque_route_changed` throws**, immediately and after journal reopen (`initial-failing-first.log`). The wider routing/preview sweep produced **48 assertions** (`metadata-sweep-failing-first-complete.log`). | `RoutingIdentity.captured` masks only observed/configured strings. Fixed keys, status/policy/kind values, boundary text and fixed provenance survive. The same method serves identity, monitoring and archive metadata. The nearby preview/source/tool-schema cases and complete fixed-value inventory are below. |
| **HELPER-AGENTS-IO-3 — confirmed + fixed** | `NativeToolTests.testRetainedTwentyMiBShellLogCanBeReadInSmallPages` runs generated `awk` output: **20 MiB, 1,048,576 short UTF-8 lines**. Both offset 1 and offset 1,048,557 with limit 20 threw `file_too_large` (`second-failing-first-complete.log`). | Text reads stream bounded chunks and retain at most the existing 32 KiB preview, rather than loading a whole file before paging. The scan still counts total lines and validates UTF-8. Image reads retain their 16 MiB bound and existing processing. Read-only callers can page the retained log. Other bounded reads are whole-resource/edit/image reads, not advertised log paging. |
| **Host portable/inspect/recover disk work — confirmed + fixed** | `HostServiceTests.testPortablePreviewAndRecoveryDoNotBlockAnotherChatsSnapshot` creates a **12,000-message journal** and holds each disk path with a barrier. All three sibling snapshot expectations timed out at **1 second** before the fix (`second-failing-first-complete.log`). | Portable preview, import inspection and recovery run in detached workers, capturing only immutable parameters and the authorized directory. The original validation, atomic no-overwrite recovery link, incomplete-tail handling and source checks stay in the worker. Existing open/rebind/mirror paths already detach blocking disk work. |

Additional confirmed nearby instance: **closed queue resume**. `RetryTests.testQueueResumeRejectsClosedRuntimeWithQueuedWork` closes a running session with a queued message, then calls Resume Queue. Before the fix it accepted the resume, made **3 provider requests instead of 1**, and invoked a tool (`queue-resume-failing-first.log`, three assertions). The same closed guard now rejects this before state changes. Ordinary unload requires empty queues, but `close()` legitimately preserves queued work for a future reopened runtime.

Baseline test corrections are retained, not concealed: the first image assertion mistakenly expected base64 length 4,000 rather than decoded length 3,000; the corrected baseline still failed on the reopened card. The first host Retry fixture omitted required retry settings; the corrected host fixture reproduced acceptance after unload. A shadowed, already-unwrapped directory caused an intermediate worker compile error, and the first inventory fixture exceeded Swift's expression type-checking limit; both were corrected before executing their tests. None is counted as a product reproduction.

### Credential sanitizer inventory and additional regressions

`testRoutingFixedValuesAndKeysSurviveMatchingCredentials` checks routing schema/values in all three capture modes. `testEveryFixedMetadataLabelSurvivesAnEqualConfiguredCredential` recursively enumerates the fixed strings and keys in representative structures and sets the configured header equal to each. It covers every routing status and policy, fixed JSON/SSE source label, model/group/deployment kinds, source provenance labels, request discriminators, schema types, native and parent/child/legacy delegation tool definitions, normalized accounting and operation metadata. `testHelperToolSchemasKeepTheirNamesLabelsAndDescriptions` enumerates every string/key in the actual native/MCP wrapper tool definitions through a real context preview.

| Sanitized structure | Helper-owned fields/values preserved | Data still sanitized |
| --- | --- | --- |
| Routing identity | All schema keys; `status` = `reported`, `unreported`, `incomplete`, `conflict`; `replayPolicy` = `ask`, `portable`, `pinned`; evidence `kind` = `model`, `group`, `deployment`; numeric omitted-evidence count; fixed boundary explanation. Fixed sources: `header:x-litellm-model-name`, `header:x-litellm-model-group`, `body.model`, `body.router_model_name`, and `response.created` / `response.in_progress` / `response.completed` / `response.incomplete` / `response.failed` + `.response.model` / `.response.router_model_name`. Legacy Messages source labels are unreachable for new requests, which Profile rejects. | Requested alias, effective/reported models, contract reference, evidence values, and provenance strings assembled from configured header names. Credential exclusion at ingestion remains active. |
| Normalized usage | `input`, `output`, `cacheRead`, `cacheWrite`, `reasoning`, `total`, `inputIncludingCache`, `status`, `raw` keys; `reported`, `unreported`, `invalid`, `overflow` accounting statuses; all numbers/nulls. | Only `usage.raw` recursively masks arbitrary provider keys and string values. It contains no helper-generated labels. |
| Gateway accounting | Cost/cache/component keys; `reported`, `unreported`, `invalid`, `conflict`, `hit`, `miss`; component names (`input`, `output`, `reasoning`, `toolUsage`, `classifier`, `original`, `discount`, `margin`); fixed cost-header/body/SSE provenance and boundary explanation; numeric observations. | Configured cache-source provenance. Provider cost/call-ID/version/cache strings retain their existing ingestion validation and credential exclusion. No generic whole-gateway sanitizer is introduced. |
| Context source records | `scope` = `global`, `project`, `approved additional`; `state` = `included`, `truncated`; reason `Selected by Codex precedence`; hash, byte counts, truncation flag and schema keys. | Source `path` and included instruction `text`. |
| Prepared request protocol | Schema keys; input `type` = `message`, `function_call`, `function_call_output`, `reasoning`, `input_text`, `output_text`, `input_image`, `summary_text`, `refusal`; roles `system`, `developer`, `user`, `assistant`; status `completed`; phases `commentary`, `final_answer`; image detail / summary `auto`; include `reasoning.encrypted_content`; function-definition type `function`; JSON Schema types `object`, `array`, `string`, `number`, `integer`, `boolean`, `null`, including type unions. | Model/configuration fields, free-form instructions and message/tool payloads, provider IDs/opaque content, unknown protocol values and configuration-supplied request fields. The live provider request is never modified. |
| Helper tool definitions | Exact frozen helper definition name, description and schema: native read/list/find/grep/write/edit/bash; MCP wrapper; parent steering controls, child report, and legacy subagent wrapper. The inventory walks their property names, required names, enums, descriptions, defaults and composition branches instead of maintaining a duplicate string list. | Offered model names in `properties.model.enum`, including conditional composition variants. A request-body override must match the actual helper name/description/schema to use this preservation path. Additional override fields remain masked; changed schemas use the ordinary provider/configuration-data sanitizer. |
| Operation/outer capture metadata | Existing operation kinds, phases, reasons, allowance-source labels, request/outcome/capture-mode labels, schema keys, counts and timestamps pass through unchanged. They never enter the recursive credential sanitizer. | Existing provider-error handling masks provider text before it reaches error metadata. No new whole-operation sanitizer is added. |
| HTTP dictionaries, SSE event name, requested model | HTTP names and event names are transport/provider/configuration dictionaries and strings, not helper routing/accounting schemas. Existing framing, error/omission notices, offsets and counts remain intact. | Header names/values, SSE event type and configured requested model retain existing masking. Event ID and retry data remain in the byte-masked response, not an unfiltered metadata copy. |

The sweep confirmed context source/preview corruption as well as routing corruption. `ContextPreviewTests.testPreviewProtocolAndSourceLabelsSurviveMatchingCredentials` failed on 12 fixed fields before the fix and still requires an equal credential in free text to be fingerprinted. `testHelperToolSchemasKeepTheirNamesLabelsAndDescriptions` initially failed 15 assertions. The inventory caught a type-union omission (two assertions, `metadata-inventory-first-complete.log`), which is fixed.

Adversarial testing of the new definition-preservation path also caught overly broad trust of extra request-body fields. `tool-override-failing-first.log` records six assertions where an added `configurationEcho` survived. The final path restores only the matched helper fields from the actual definition; extra fields and configured model enums are explicitly tested for masking. This was corrected before the final validation run.

The final inventory expansion also exercises actual invalid/conflicting gateway states, overflow usage, operation phases/reasons, and a configured schema property name equal to the credential. Restoring the old unmasked schema-key behavior fails the latter assertion (`mutation-configured-schema-keys.log`); helper-owned schema keys still pass unchanged. This expansion changes tests only, after the full-suite binary was built, and is rerun as the complete credential-capture class after the mutation is restored.

### Adversarial review of every changed condition

Reviewed the complete new production diff against the supplied base, including the nearby fixes, not just the original reported lines.

| Changed condition / operation | States now taking a different path; intended result |
| --- | --- |
| Retry closed guard | A closed ordinary runtime throws `session_closed` before changing submission, retry flags or launching. Open idle/error/paused/busy and cost-paused paths retain their original checks. Managed-session authority rejection retains precedence. The host unload barrier proves a retained stale actor reference is insufficient authority. |
| Queue Resume closed guard | Closed runtimes reject even with durable queued messages. Open queues, held edits and cost pauses retain their existing behavior. Future work belongs to the reopened runtime and its journal. |
| Task model-duration settlement / removed row addition | Failed, stopped, retried and overflow-recovery request durations now enter the active task once. Successful requests are no longer counted again when their row is appended. Backoff adds nothing. Automatic compaction contributes measured requests to its active task; utility/manual work without an active task creates none. Tool timing and row-level winning-request duration are unchanged. |
| Tool result display fallback | A persisted `displayText` now supplies card output (including explicitly empty display text); absent values keep `text`. Both cached and paged results use this same reconstruction. Held calls without results keep their existing held-card path. |
| Raw usage object present | Uses validated normalized components, not rejected raw values. Valid readings preserve Pi's cache accounting; absent/invalid totals use valid parts, invalid cache components contribute zero, checked summation still rejects overflow. Raw evidence stays available. Without raw, the previous normalized-only path is unchanged. |
| Output room | Unknown/nonpositive windows still return `Int.max`. Windows no larger than safety reserve, or request counts at/above remaining room, return one before subtraction. Smaller nonnegative counts retain their old result. Defensive negative inputs clamp to zero; counters only produce nonnegative inputs. Saved extreme counts can no longer trap this calculation. |
| Routing nullable identity / selected data fields | Absent identity remains null. Fixed fields bypass text matching; only actual data fields enter it. A provenance string is sanitized only when it matches a configured metadata-header source; built-in header/body/SSE sources stay fixed. These changes apply identically to identity, monitoring, snapshots and persisted capture. |
| Source path/text presence | Only present path/text fields are sanitized; fixed labels, hash and counters are retained. Missing optional text remains absent. No resource authority, selection or contents on disk change. |
| Preview recognized item discriminator | Only known role/type/status/phase/detail values retain their literal spelling. Unknown values still follow credential matching. Arrays in content/output/summary recurse; string payloads still mask. Other fields keep existing sanitization. |
| Preview function definition match | Exact helper name, description and schema restore only their helper fields; extra fields remain sanitized. Nonfunction/unknown/changed definitions remain data. Only configured model enums are masked within matched helper schemas, recursively through composition branches. Definitions offered to the actual model never change. |
| Preview schema node / enum / collection | Known scalar and union type values are preserved. Object property/definition dictionaries and schema combinators recurse only when their JSON shape matches; unknown/string payloads keep masking. Rewritten keys are confined to provider/configuration-supplied schema dictionaries, not matched helper definitions or fixed JSON Schema vocabulary. |
| Preview include/summary | Only the exact fixed encrypted-reasoning include and `auto` summary token bypass masking. Other configuration values keep their prior treatment. |
| File open / regular-file check | Keeps nonblocking open, regular-file-only checks and descriptor cleanup. It no longer rejects large text just for total size. Negative/invalid file size is refused. Captured initial size bounds the scan so an append cannot extend it indefinitely. |
| Image detection and bound | The same first 4,100-byte sniffer chooses image handling. Images still reject above 16 MiB and use the same processing/hints. Text uses streaming. Invalid text-page arguments are now rejected before scanning the rest of a nonimage file; image argument behavior remains unchanged. |
| UTF-8 chunk boundary | Complete scalars validate immediately; at most three trailing bytes carry into the next chunk. Invalid bytes anywhere in the scanned file, or an incomplete final scalar, still reject `binary_file`, even outside the requested page. Cancellation is checked each chunk. |
| Text selection / retention | Only the requested LF line interval enters the existing 32 KiB output bound; the final separator of a bounded line selection is excluded. All scanned lines still count toward the existing hint. CR, LF, CRLF, trailing empty lines, offsets beyond EOF and byte cuts retain viewer statistics, checked against the prior algorithm. |
| Text truncation / final shown line | A later line or byte-bound cut still emits the total-lines hint. A complete selection ending in LF includes the trailing empty viewer line; a byte cut ends on the line it cut. Empty selections have no line range. |
| Detached journal operations | Admitted preview/import/recover calls suspend the host while immutable captured inputs perform disk work. Unrelated snapshots/Stop can proceed. Existing destination no-overwrite link and source integrity checks still decide success. There is no late session-registry mutation. Concurrent recoveries cannot replace an existing destination. |
| Test seams | Nil in production. The async unload seam exposes the exact post-unload/pre-removal race; the synchronous disk seam runs inside the disk worker. Neither grants permissions or enables a production path. |

State sweep: streaming and ordinary replies, idle/paused/cost-held sessions, Off/memory/persist capture, restart, terminal failure/cancellation and concurrent siblings were checked against these conditions. Capture credentials stay immutable per trace; no global masking state was added. Original journal/capture data are not rewritten or migrated. Preserved historical zero task totals are not retroactively invented. No additional unresolved product issue was found in this new diff.

### Round 2 hunt validation

The final production diff was reviewed against fetched `origin/dev/next` at the supplied base and compared byte-for-byte with the source diff used for validation. The lead retains merge and full native-gate responsibility.

All **17** final mutations failed as intended; the scripts restore each source file in `finally` before continuing. `mutation-results.json` and `inventory-final-results.json` retain the exact per-test commands and exit codes.

| Mutation / log suffix | Failing checks |
| --- | --- |
| `mutation-retry-closed.log` | Executed 2 tests, with 4 failures (0 unexpected) |
| `mutation-queue-closed.log` | Executed 1 test, with 3 failures (0 unexpected) |
| `mutation-task-attempt-time.log` | Executed 3 tests, with 6 failures (0 unexpected) |
| `mutation-task-double-count.log` | Executed 1 test, with 2 failures (0 unexpected) |
| `mutation-tool-image-display.log` | Executed 1 test, with 1 failure (0 unexpected) |
| `mutation-output-room.log` | Arithmetic trap (signal 5) |
| `mutation-raw-usage.log` | Executed 2 tests, with 5 failures (0 unexpected) |
| `mutation-routing-enums.log` | Executed 1 test, with 12 failures (6 unexpected) |
| `mutation-preview-enums.log` | Executed 1 test, with 9 failures (0 unexpected) |
| `mutation-source-labels.log` | Executed 1 test, with 3 failures (0 unexpected) |
| `mutation-schema-union.log` | Executed 1 test, with 2 failures (0 unexpected) |
| `mutation-large-log-pages.log` | Executed 1 test, with 2 failures (0 unexpected) |
| `mutation-host-disk-workers.log` | Executed 1 test, with 3 failures (0 unexpected) |
| `mutation-helper-definitions.log` | Executed 1 test, with 12 failures (0 unexpected) |
| `mutation-helper-model-enums.log` | Executed 1 test, with 4 failures (0 unexpected) |
| `mutation-helper-extra-fields.log` | Executed 1 test, with 7 failures (0 unexpected) |
| `mutation-configured-schema-keys.log` | Executed 1 test, with 1 failure (0 unexpected) |

Commands (serial, from this worktree):

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
export PI_BUILD_ROOT="$BUILD" SWIFT_BACKTRACE='enable=yes,interactive=no,threads=all'
# Baseline runner: the reproduction filters are recorded in baselines.log / hunt-baselines.py.
python3 "$BUILD/hunt-baselines.py"
# Each mutation rebuilds its exact targeted tests; expected failures are required.
python3 "$BUILD/hunt-mutations.py"
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter '^PiAgentCoreTests.(CredentialCaptureTests|CaptureTraceTests|CaptureConcurrencyTests|CaptureDrainTests|TraceBufferPerformanceTests|GatewayTelemetryTests|RoutingTests|ProviderStreamErrorTests|ProviderStreamingTests|ProviderMediaTypeTests|HTTPIngressTests|ContextPreviewTests|ContextScopeTests|DecodeSpanTests|CostLimitTests|RetryTests|RetryRecoveryTests|ToolOutcomeTests|TaskPresentationTests|NativeToolTests|PiReadImageTests|ToolLineTests|RequestContextTests|PiContextSessionTests|HostServiceTests|SessionRecoverTests|HostDispatchTests|BlockingWorkTests|SessionSettlementTests|ContinueRunTests|CompactionTaskRegressionTests|TitleTaskTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
# Final test-only inventory expansion (production source unchanged):
# Runs the class, mutates the schema-key sanitizer, restores it, and runs the class again.
python3 "$BUILD/hunt-final-inventory.py"
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter CredentialCaptureTests
git diff --check
```


| Suite / log | Result | Duration |
| --- | --- | ---: |
| Capture and affected classes, `capture.log` | 220 passed, 0 failed | 55.309 s |
| Isolated streaming-cost class, `helper-cost.log` | 5 passed, 0 failed | 3.963 s |
| Remaining full helper suite, `helper.log` | 1,042 executed: 1,035 passed, 7 skipped, 0 failed | 439.240 s |
| Release bundle, `bundle.log` | passed | 107.077 s |
| Release wire, `wire.log` | 36 passed, 0 failed | 34.273 s |
| Release concurrent, `concurrent.log` | 4 passed, 0 failed | 24.998 s |
| Release acceptance, `acceptance.log` | 3 passed, 0 failed | 3.498 s |
| Final expanded credential class after restoration, `inventory-final.log` | 21 passed, 0 failed | 2.507 s |

Full helper total: **1,047 executed, 1,040 passed, 7 skipped, 0 failed**. The seven existing opt-in skips are one each in `ForkCloneTests`, `ForkPerformanceTests`, and `HistoryReadCancellationTests`, plus four in `SessionOpenPerformanceTests`. No unrelated test failed. Release compilation retains existing Swift 6 actor-initializer warnings in unchanged `Sessions.swift`; the build succeeded. All 17 mutations failed as expected before restoration. The final expanded credential class passed before and after its additional mutation; production source remains identical to the source exercised by the full helper and Release wire suites.

`results.json` and `inventory-final-results.json` preserve exact commands, exit codes and elapsed runner times. `git diff --check` passed. No DerivedData or xcresult bundles were created, and no test clone folders remain in this workstream's build root (about 572 MiB). There is no unresolved finding or owner decision from this hunt. Review, merge and the full native gate remain with the lead.

## PERSISTENCE-COMPAT-2 — shared retained tool-output ownership

Confirmed and fixed; final validation passed. Worktree/branch: `wt-a130-helper` / `dev/a130-helper`; supplied and fetched base `33e2cdc8` (`origin/dev/next`). Text evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/persistence-compat-2/`. All fixtures are generated; the native test uses the packaged test helper and loopback gateway, MemoryVault and isolated app data. No installed app, user data, real preferences, Keychain or paid provider is used.

Regression: `SubagentDeletionTests.testDeletingSourceKeepsCloneAndCopyForksFullToolOutputUntilLastReference` runs a real bash tool producing 5,000 lines and a sentinel beyond its 32 KiB preview. The short fork identity exercises byte cloning; the longer identity forces the copy fallback. It checks their distinct copied row shapes, deletes the source through `deleteSubagentFamily`, reads each journal's full-output reference, deletes one fork, relaunches, then deletes the last fork and checks reclamation.

Before any production edit, `native-failing-first.log` recorded both missing files:

```text
fork lost its full output after source deletion: ... Code=260 ... no such file
copy-fork-with-an-identity-longer-than-the-source-uuid lost its full output after source deletion: ... Code=260 ... no such file
XCTAssertTrue failed - The other fork still references the original bytes
Executed 1 test, with 5 failures (0 unexpected)
```

Three of those were the product failures above; two were fixture assertions comparing path spellings through a shortened display row. The fixture now reads the saved JSONL result and follows its actual advertised path, accepting macOS's `/var` and `/private/var` aliases. Earlier fixture bring-up failures (throwing assertion placement, copy-row slice and normalized transcript role) are not counted as bug evidence. A repeat using the corrected fixture and the original deletion source, plus the actual fix mutation, is recorded below.

Decision: use existing complete journals and saved/live drafts as durable references, rather than copying log contents on each fork. Every log still has one physical owner/path and one physical file. Clone/copy journal bytes and offsets remain unchanged; no per-fork output copies or journal migration is introduced. Each deleted owner gains one small, durable `tool-output-deleted-workspace` metadata record beside its permanent `session-deleted` tombstone. The validated workspace is recorded transactionally before removing journals; both records are required for later reclamation. Old pending deletion manifests acquire this scope when they resume; completed legacy tombstones without workspace evidence leave files untouched. Deleting an owner removes unreferenced files but preserves files referenced by any remaining journal/metadata draft; deleting the last referrer or relaunching revisits tombstoned owners. Only the app's own `Workspaces/*/Sessions/tool-output/<deleted-id>` is eligible. Old flat UUID files and unknown filenames remain untouched. Invalid/unreadable/changing reference evidence defers cleanup, without producing extra copies.

Sweep:

- Bash `.log` (up to 64 MiB) and oversized non-bash/MCP `.txt` (up to 16 MiB): same defect, shared ownership covers both. Read-only `read` pages remain usable. Short/crash-left output with no references is reclaimed normally.
- Clone, copy fallback, reply fork, kept side and published recovered copies: their complete journal bodies contain inherited paths, including old branches. All native journals are scanned, including unlisted files and other workspaces. No dependence on the current transcript page or active context.
- Portable handoff: copied text may contain output paths before a new journal exists. Metadata drafts, handoff and pending/displaced draft structures plus live drafts retain these files.
- Registered imported external JSONL: metadata supplies its exact journal path. It keeps referenced native logs while registered. Removing an import preserves its external source; unregistered external originals are outside app ownership.
- Accepted user images and MCP/read image results: bytes are in message image blocks; fork/side/copy replays those bytes. Native input retains original attachment paths for editing. Clipboard images use global PastedImages reference cleanup, not per-source deletion; project/selected images remain external files that deletion never removes.
- Resource/skill source paths, cwd, file-tool paths: source deletion never removes project/configuration files. Resource/skill snapshots retain the selected bytes. No permissions broadened.
- Captures: attempts/lineage are logical references, not owned body paths in a chat clone. Clearing source capture/retention intentionally can remove old HTTP bodies; HTTP archives are not needed for model replay. Explicit exported capture artifacts contain their own body bytes. No capture policy/ownership change here.
- Journal checkpoint/origin/promotion/stream sidecars: owned by each journal; a completed fork has its own journal and replay checkpoint, so removing the source's derived files does not remove the copied conversation.
- Needs owner decision: conversation Export is explicitly Markdown text, not a bundle. External exports (`apps/macos/PiApp/Inspector/ConversationContentView.swift:174`) can contain a now-stale full-output path after all registered references are gone. Preserve current text-only behavior; bundling resources needs separate scope/retention/UX policy.
- Separate pre-existing alias limitation: importing the exact original native journal path registers a read-only reference, not a copy. Deleting that source can remove the imported alias's journal itself (`apps/macos/PiApp/Workspaces/WorkspaceChatLifecycle.swift:147`; `WorkspaceSubagentDeletion.swift:351`). Import remains a reference to the selected original; changing it to copying requires an owner decision.

### Adversarial self-review

The review found and corrected an additional **workspace-scope error**. The first implementation selected tombstoned session IDs across all projects. An unlisted journal in another project can have the same ID, and its short output need not have a path in its result. Extending `testDeleteFindsAnUnregisteredChildAndPreventsRediscoveryAndStaleWrites` failed before the correction (`native-scope-failing-first.log`, 1 test / 1 failure):

```text
XCTAssertTrue failed - A matching session ID in another project is not deletion authority
```

The final implementation records the workspace from the validated deletion manifest and selects only that workspace's physical owner directory. A conflicting rescope is rejected, and an old unscoped tombstone authorizes no reclamation. The regression passes with the fix and fails again when the workspace lookup is replaced by a match in any workspace (`mutation-workspace-deletion-scope.log`).

The review also narrowed deleted-record exclusion to known chat/command metadata, so an unknown record whose kind/ID resembles a deleted chat still retains its references. The synthetic `future:original` row exercises this. A first helper check exposed an overly strict Foundation URL equality check between `/var` and `/private/var`; directory traversal now checks each enumerated component with `lstat`, retaining symlink rejection without rejecting legitimate macOS aliases. This and fixture-only URL comparisons were corrected before final validation.

| Changed condition / operation | States that change path; intended behavior |
| --- | --- |
| Remember workspace before file removal | A validated pending deletion persists its scope before removing any journal. Matching existing scope is idempotent; a different scope or missing/wrong tombstone throws. Ordinary opens, live owners and imports do not write deletion authority. |
| Read scoped deletion owners | Only a workspace marker joined to a permanent tombstone grants authority; missing/legacy markers retain files. Complete SQLite queries have no chat-list cap. Corrupt values and database failures retain the deletion intent. |
| Inventory workspace/owner selection | Only the recorded workspace and owner ID are eligible, including an owner deleted before its last fork. Equal IDs elsewhere are not authority. Live owners and older flat output files remain outside cleanup. |
| Missing/invalid directory | ENOENT means there is nothing there; I/O failure or a symlink/non-directory rejects cleanup. Every child is traversed from the app root; no metadata path supplies a deletion destination. |
| Output entry kind/name | Regular `.log`/`.txt` files may be reclaimed; unknown names are retained. A symlink/nonregular entry rejects the inventory. No output contents are copied or rewritten. |
| Reference matching | Decode each JSON record before matching paths, preserving slash/Unicode escape equivalents. Strings, keys, arrays and old branches all count. Case/suffix collisions may conservatively retain an extra file; they cannot authorize removing a file outside the scoped inventory. |
| Bounded journal scan | Each read stops at the initial file size, using 64 KiB chunks and at most one 32 MiB JSONL record. Empty lines are tolerated. Oversized, malformed, missing, unreadable or changing journals keep all candidate files; cancellation throws instead of returning deletion proof. |
| Descriptor/identity checks | `O_NOFOLLOW` and regular-file checks prevent following a journal symlink/FIFO. Device/inode checks fence replacement between inspection and open; size/mtime/ctime checks invalidate modified or replaced files. |
| All references found | Scanning can stop only when every candidate file is already retained. Remaining unread journals cannot make any of those files eligible for removal. |
| Metadata ownership exclusion | Only known deleted chat/draft/handoff/side-keep rows and their command namespaces are ignored. Retained side-keep rows use their decoded chat identity. Unknown/future rows remain references. Explicit imported paths are scanned even when missing; absent default paths for unsent chats are not invented. |
| Recheck after suspension | Journal and directory stamps detect writes/replacements/newly published files; the SQLite token detects changed drafts/imports/metadata. An obsolete scan defers output cleanup. Disk scans/rechecks run off the main actor. |
| Live drafts | After the async scan, surviving displays' saved and displaced edit/queue drafts add references before recycling. Deleted members' draft state does not retain their discarded output. |
| Recycle selection | Referenced files remain readable at their original paths. Only unused files are recycled within a shared directory; an entirely unreferenced directory is recycled whole. Unknown files prevent whole-directory recycling. |
| Startup / incomplete deletion | With no pending intent, startup still revisits scoped tombstoned owners. During a deletion, journal/capture cleanup precedes reference scanning; metadata/intents clear afterward. Interrupted cleanup retains durable authority and can retry without a deleted source journal. |
| Capture / runtime state | Off/memory/persist capture, permission grants, tool policy and accounting are untouched. Existing unload/runtime gates still prevent a source fork/side publication from escaping normal deletion. Streaming/paused/idle survivors are read from durable journals, and changes defer cleanup. Cancellation before recycling preserves files. Concurrent unrelated work receives no new global gate. |

Additional scope boundary from the code sweep: `packages/swift-host/Sources/PiAgentCore/HostService.swift:529` dispatches recovery off the host actor, and `recoverCopy` (line 1008) checks its already-open descriptor's size before publication; `JournalRecordReader.checkUnchanged` (line 115) does not check whether the source path still exists. An overlapping recovery that already opened a journal may therefore publish after source deletion; its hidden staging file is not a published chat in the reference inventory. This concurrency scenario was **not reproduced here** and is a separate follow-up to investigate, not a claim that the new tests cover pending recovery. Completed, published recovered copies are covered by the journal scan. The native fork and copy-fork paths in this finding share the existing runtime gate with deletion and are both exercised.

### Regression and mutation evidence

| Evidence | Result |
| --- | --- |
| Corrected fixture with original deletion source, `native-corrected-original-deleter.log` | 1 test, 3 intended failures: both fork paths lose the advertised file, and the remaining fork cannot retain it. |
| Final scoped fix, `native-scoped-fixed.log` | 12 deletion tests passed. |
| Remove reference protection, `mutation-final-unconditional-output-deletion.log` | 1 test, 3 intended failures; source bytes restored afterward. |
| Remove restart reclamation, `mutation-native-relaunch-reclamation.log` | 1 test, 3 intended failures; restored. |
| Scan raw JSON instead of decoded strings, `mutation-undecoded-journal-paths.log` | 18 tests, 3 failures (one is the now-missing file read throwing); restored. |
| Ignore directory publication stamps, `mutation-directory-publication-check.log` | 18 tests, 1 intended failure; restored. |
| Drop workspace restriction, `mutation-workspace-deletion-scope.log` | 1 test, 1 intended failure; restored. |
| Helper class after restoration, `helper-mutations-restored.log` | 18 tests passed. |

`testToolOutputReferencesKeepOnlySharedFilesAndReleaseTheLastReference` covers both retained shell logs and oversized MCP/tool text, JSON escape equivalents across read chunks, historical side records, unused-file cleanup and real read-only `read` paging of the sentinel. `testToolOutputReferencesFailClosedAndDetectConcurrentPublication` covers torn/missing journals, replacement/publication and cancellation. `testToolOutputInventoryRejectsSymlinksAndKeepsUnknownFiles` verifies boundaries. `testOutputRetentionIncludesUnlistedSidesImportedHistoryAndUnsentDrafts` covers other projects, registered external originals, saved/live displaced drafts, unknown metadata, legacy unscoped tombstones, conflicting scope and last-reference cleanup without a pending deletion intent.

### Final validation

Commands, from this worktree (all native runs held the shared full-lane lock with guaranteed release; no focus/gallery operation ran outside it):

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
export PI_BUILD_ROOT="$BUILD"
# The scripts record exact mutation commands, exit codes and runner durations.
python3 "$BUILD/persistence-helper-mutations.py"
python3 "$BUILD/persistence-native-checks.py"
python3 "$BUILD/persistence-native-final.py"
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter NativeToolTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter '^PiAgentCoreTests.(NativeToolTests|ToolOutcomeTests|ToolRecordingFailureTests|ForkCloneTests|ForkPointTests|ForkReplayHandoffTests|SubagentForkTests|JournalCloneTests|SessionRecoverTests|HostServiceTests|PiReadImageTests)/'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests \
  -only-testing:PiAppTests/SideBudgetIntegrationTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/ForkCloneReaderTests
python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
git diff --check
```

| Final suite / log | Executed | Passed | Skipped | Failed | Test duration |
| --- | ---: | ---: | ---: | ---: | ---: |
| Helper affected classes, `helper-affected.log` | 77 | 76 | 1 | 0 | 17.346 s |
| Isolated streaming-cost class, `helper-cost.log` | 5 | 5 | 0 | 0 | 3.681 s |
| Remaining full helper, `helper-full.log` | 1,045 | 1,038 | 7 | 0 | 384.895 s |
| Native affected classes, `native-final-scoped.log` | 66 | 66 | 0 | 0 | 17.092 s |
| Release wire, `wire.log` | 36 | 36 | 0 | 0 | 33.168 s |
| Release concurrent, `concurrent.log` | 4 | 4 | 0 | 0 | 25.955 s |
| Release acceptance, `acceptance.log` | 3 | 3 | 0 | 0 | 3.537 s |

Full helper total: **1,050 executed, 1,043 passed, 7 skipped, 0 failed**. The opt-in skips remain one each in `ForkCloneTests`, `ForkPerformanceTests`, and `HistoryReadCancellationTests`, plus four in `SessionOpenPerformanceTests`. Native breakdown: `SubagentDeletionTests` **12/12**, `FamilyDeletionTests` **10/10**, `BudgetOwnerUnloadTests` **7/7**, `SideBudgetIntegrationTests` **18/18**, `MetadataDurabilityTests` **10/10**, `PastedAttachmentTests` **8/8**, `ForkCloneReaderTests` **1/1**. `LifecycleHelperTests` itself was not mixed into a parallel lane; the new regression reuses its fixture without opening a window. No UI presentation changed, so no gallery scene was required.

The Release bundle succeeded (61.88 s compiler time / 63.488 s runner time). Existing Swift 6 actor-initializer warnings in unchanged `Sessions.swift` remain; there were no unrelated test failures. Every intentional mutation failed and was restored. Final production source matches the reviewed patch byte-for-byte, and `git diff --check` passed. The full helper and native suites were rerun after the workspace-scope correction, not just the new tests.

`helper-mutations.json`, `helper-results.json`, `native-scoped-results.json` and `wire-results.json` preserve exact commands/statuses/times. Only this build root was used (one native DerivedData tree, about 1.3 GiB; helper debug/release trees about 425/100 MiB). No native clone directories or generated task fixture folders remain. The early fixture crash left one synthetic gateway; its exact PID, command and fixture cwd were verified before terminating it and removing that fixture. No named result bundles were requested; text logs are the evidence. Review, merge and the full native gate remain with the lead.

Unresolved scope notes are the text-only export decision, imported-original alias behavior, and the unverified overlapping-recovery scenario above. The assigned clone/copy-fork deletion regression is fixed, including last-reference reclamation after reopening.

## Persistence review follow-up

Continued from `941dcfab` on `dev/a130-helper`, without merging or fast-forwarding. All four requested items are **confirmed and fixed**. The import decision below supersedes the earlier native-journal alias limitation; the recovery race is now reproduced rather than speculative. Text-only exports retain the earlier **needs owner decision** note.

### Findings and failing-first evidence

Evidence directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/persistence-review/`. Fixtures use generated journals, scratch storage, MemoryVault and loopback services. The initial app changes only made the import/deletion entry points awaitable/testable; ownership and cleanup behavior remained original for `native-failing-first.log`. The recovery barrier likewise precedes the fix.

| Item | Reproduction and failing-first excerpt | Fix and mutation |
| --- | --- | --- |
| Overlapping global recycling | `SubagentDeletionTests.testOverlappingWorkspaceDeletionsSerializeSharedOutputRecycling` holds the first recycler while a second workspace finishes its journal phase. **1 test, 3 failures:** `“deleted-b” couldn’t be removed`, peak recyclers `2` instead of `1`, and pending deletion intents remain. | Queue the entire inventory/reference-check/recycle pass across awaits. Every waiter scans afresh after its predecessor settles. Removing the predecessor wait produces the same **3 failures** in `mutation-sweep-serialization.log`. |
| Startup cleanup on the restore critical path | `LaunchSelectionTests.testRetainedOutputCleanupWaitsUntilRememberedChatIsRestored` holds recycling of a completed tombstone's unreferenced log. **1 test, 3 failures:** `Orphan collection must not block launch`, selected chat `nil` instead of `b2`, and restore cannot finish while collection is held. | Empty-intent replay does no opportunistic work. Schedule it beside pasted-image cleanup after remembered selection/restoration; cancel it during shutdown. Reinstating the awaited empty-intent cleanup produces the same **3 failures** in `mutation-launch-cleanup.log`. Pending deletion recovery still completes before reopening. |
| Native-journal import alias | `WorkspaceDurabilityTests.testImportingOwnedJournalSelectsExistingChatAndRefusesAnotherProject` imports a native owner's symlink and hard link, including an owner outside the loaded sidebar and a record with no saved path. It then tries another project and an unregistered native path/case alias. **1 test, 12 failures:** selected ID is a new UUID instead of `chat-parent`, imported duplicates are saved, and another project receives no refusal. | Search all durable native records by canonical path or device/inode, select the existing same-project owner, and refuse another project. An app-owned path without a recoverable record is refused; filesystem directory relationship handles aliases/case spelling. Removing these guards reproduces **12 failures**; removing physical-identity matching produces **8 failures** (`mutation-import-alias.log`, `mutation-import-physical-alias.log`). An independent external copy with the same journal header remains importable and byte-for-byte unchanged. |
| Recovery publishing after source deletion | `SessionRecoverTests.testRecoveryRefusesSourceRemovedOrReplacedBeforePublication` pauses a completed copy, moves the source to fixture Trash, and separately replaces it with identical bytes under a different inode. **1 test, 4 failures:** `Recovery published after its source was deleted` / `replaced`, with a published destination in both cases. | Check the source path's regular-file type, device, inode and size against the still-open reader immediately before publication. Check again after linking and withdraw the new destination if deletion/replacement won between those operations. Bypassing the path check reproduces **4 failures** (`mutation-recovery-identity.log`). Staging files are removed on refusal. |

The combined native failing-first run executed **3 tests with 18 intended assertion failures**. All four focused native regressions, including the added queue-failure/cancellation test, pass after restoring every mutation. `testFailedAndCancelledSweepsDoNotStrandLaterCleanup` puts a cancelled waiter behind a held, failing recycler and verifies the subsequent pass still collects the orphan, without recycling in the cancelled pass or retaining the queue tail.

### Decisions, nearby sweep and adversarial review

The original durable-reference ownership approach remains: one physical output file, retained while surviving journals or drafts reference it. The fixes serialize collection rather than duplicate logs or disregard missing-file errors. This keeps retryable deletion failures meaningful. Only collection is queued; distinct families' journal removal and unrelated host commands do not acquire this queue.

Owner decision applied: importing an app-owned native journal opens its existing chat, including an existing managed/background reader through its normal selection path. It never creates another ChatRecord for that native file. Another project gets an explicit notice. Missing/unlisted native metadata cannot justify a new alias: such a file is refused with a clear notice. The lookup has no sidebar/list cap, recognizes symlinks and hard links, and supplies the default native path for an unnamed record. Existing external imported originals retain their read-only behavior. This does not migrate aliases already registered by older builds.

Reviewed the new production diff condition by condition, including idle/streaming/paused survivors, restart, cancellation, concurrent sibling work and Off/memory/persistent capture:

| Changed condition / decision | States and intended behavior |
| --- | --- |
| Empty versus nonempty deletion intents | Empty means no awaited sweep during launch. Nonempty still repairs and completes durable deletions before selection; each collection goes through the same queue. |
| `archiveOpen`, cleanup task nil, shutdown flag | Only a live model with an opened archive schedules its one opportunistic launch pass. Repeated scheduling and shutdown do not create work. Cleanup errors retain files silently; actual deletion errors still retain/report the intent. |
| Existing queued predecessor | A second workspace or opportunistic pass waits through asynchronous recycling, including an unsuccessful predecessor, then inventories current state. A first pass starts immediately. The mutation demonstrates why actor isolation alone was insufficient. |
| Cancellation and queue-tail identity | A cancelled pass cannot enter the scan/recycler. Cancelling a waiter does not cancel its predecessor. An older caller cannot clear a newer tail; the last completed caller clears it. The generated failure/cancellation test verifies progress afterward. |
| Source regular-file check during import | Missing/unreadable/nonregular files cannot be registered. Regular external files retain ordinary import behavior. This lookup runs on MetadataStore's actor, not the main actor. |
| Native versus imported records; default versus stored path | Only native records can be selected as owners. Existing imported metadata does not become writable native authority. An unnamed native record resolves to its own default journal, not the chooser's alias path. Deleted records are excluded by the existing complete durable graph query. |
| Canonical path or device/inode match; duplicate owner | Canonical aliases and physical hard links identify one owner; unrelated copies, even with the same header ID, do not. Two native owners for one file refuse rather than choose nondeterministically. |
| Same project; listed versus unlisted owner | Same project selects that ID; an omitted sidebar row is added to the in-memory list without another durable record. A listed row only fills an absent path. Another project refuses before creating anything. |
| App-owned directory exists; filesystem relationship | Fresh storage without a Workspaces directory permits an external import. A native path under existing app storage without a known owner refuses, including case aliases; an independent outside file remains eligible. No lexical prefix assumption grants an alias. |
| Recovery descriptor and path identity | The old size check still applies. Missing path, symlink/nonregular replacement, different device/inode or changed size now refuse with `session_damaged`. An unchanged regular source continues normally, including incomplete-tail recovery and preserved tool-output references. |
| Post-link check and rollback | If deletion/replacement wins during publication, withdraw the newly linked copy and fail. Once a valid copy is published, surviving-journal inventories can see its references. No existing destination is overwritten. |
| Nullable recovery test callback | Only the generated test installs the barrier; ordinary requests have no callback. Disk work remains detached, so another chat's snapshot remains responsive. |
| Existing permission/capture/run-state boundaries | No tool execution, vault access, capture policy or model admission is added. Streaming/paused/idle surviving references use the existing conservative scan/stamp checks. Closed/running-family deletion gates, restart tombstones, fork/side runtime gates and capture Off/memory/persist behavior remain in place. |

Self-review specifically checked hard-link and case aliases, metadata outside the sidebar window, unnamed records, cancelled queued work, failed predecessors and the check/link interval. Those cases are covered by the final implementation/tests. Normal deletion, pending-intent replay, earlier-deletion retry and launch cleanup all converge on the serialized pass. Pasted-image cleanup and journal-slimming scheduling already run after restoration; pasted-image unlinking has no asynchronous recycler gap. Fork and side publication still share the runtime gate with `session.forget`; native import no longer creates an independent alias. Portable preview/import inspection publish text, not a native journal; text-only portability remains the earlier owner-decision boundary.

**Separate pre-existing bug found by the nearby sweep (not changed under the scope rule):** `packages/swift-host/Sources/PiAgentCore/JournalSlimming.swift:120` can rename its prepared copy back over a source deleted during `discard(kept)`. `HostService.swift` registers `slimming[id]`, but `session.forget` does not wait for it. The generated `testDeletionDuringDiscardMustNotRepublishSource` uses the existing discard seam to remove the source and retained hard link; slimming reports success and recreates the source. `slimming-deletion-probe.log`: **1 test, 2 failures**, `Deleting the source must win over background slimming` and `Slimming republished the deleted source`. The function predates these commits and is outside the assigned recovery function. The probe was removed from the test source after recording it; the unchanged `JournalSlimmingTests` then passed **8/8**. Reproduction body is retained in `slimming-deletion-probe.swift.txt`:

```swift
func testDeletionDuringDiscardMustNotRepublishSource() async throws {
    let fixture = try chat(), path = try await journal(fixture, turns: 2)
    try rewriteWhole(path)
    let source = URL(fileURLWithPath: path)
    let result = try JournalSlimming.slim(url: source, id: "slim", minimumSaving: 0, discard: { kept in
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: kept)
    })
    XCTAssertFalse(result.slimmed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
}
```

### Final validation

All commands ran from this worktree with `BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper`. `native-mutations.json`, `native-final-results.json`, `notice-results.json`, `helper-results.json` and `wire-results.json` record exact selections, exit statuses and durations.

```sh
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'SessionRecoverTests|HostServiceTests|NativeToolTests|JournalStreamingTests|ForkCloneTests'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --filter LongJournalTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter JournalSlimmingTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentDeletionTests -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/BudgetOwnerUnloadTests -only-testing:PiAppTests/SideBudgetIntegrationTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/PastedAttachmentTests -only-testing:PiAppTests/ForkCloneReaderTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/ConversationPaneTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceDurabilityTests
TEST_RUNNER_PI_APP_CHAT_DELETION_GALLERY="$BUILD/logs/persistence-review/gallery" PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChatDeletionGalleryTests
# test-macos.sh builds/stages this Release helper via python3 scripts/build-bundle.py.
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
git diff --check
```

The affected helper filter executes HostServiceTests **7**, SessionRecoverTests **3**, NativeToolTests **18**, and ForkCloneTests **14** (one opt-in skip); there is no class named JournalStreamingTests, so the separate LongJournalTests run covers the actual cursor/large-history class.

| Final suite / log | Executed | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: | ---: |
| Affected helper, `helper-affected.log` | 42 | 41 | 1 | 0 |
| Large-journal recovery/cursor, `helper-long-journals.log` | 5 | 5 | 0 | 0 |
| Existing slimming class after probe restoration, `helper-slimming-restored.log` | 8 | 8 | 0 | 0 |
| Isolated streaming cost, `helper-cost.log` | 5 | 5 | 0 | 0 |
| Remaining full helper, `helper-full.log` | 1,046 | 1,039 | 7 | 0 |
| Native affected classes, `native-affected.log` | 178 | 178 | 0 | 0 |
| Serial lifecycle, `native-lifecycle.log` | 11 | 11 | 0 | 0 |
| Final notice-copy rerun, `native-import-final.log` | 8 | 8 | 0 | 0 |
| Final light/dark/narrow galleries, `native-gallery-final.log` | 2 | 2 | 0 | 0 |
| Release wire, `wire.log` | 36 | 36 | 0 | 0 |
| Release concurrent, `concurrent.log` | 4 | 4 | 0 | 0 |
| Release acceptance, `acceptance.log` | 3 | 3 | 0 | 0 |

Full helper total: **1,051 executed, 1,044 passed, 7 skipped, 0 failed**. The same seven opt-in benchmark skips listed above remain. Native affected breakdown: BudgetOwnerUnload **7**, ConversationPane **81**, FamilyDeletion **10**, ForkCloneReader **1**, LaunchSelection **21**, MetadataDurability **10**, PastedAttachment **8**, SideBudgetIntegration **18**, SubagentDeletion **14**, WorkspaceDurability **8**.

The final native coverage comprises **191 distinct passing tests**, with the 8-test import class rerun after shortening the notices. Lifecycle ran alone, including native recovery and recovered-side scenarios. Gallery ran alone with its environment enabled: **24 PNGs** regenerated (16 existing deletion scenes plus 8 import-refusal scenes). All eight changed notice images were inspected in light/dark at 720 and 320 points. The initial narrow captures truncated the longer notices; self-review shortened only their wording, then reran WorkspaceDurabilityTests **8/8** and ChatDeletionGalleryTests **2/2**. Final images show the complete refusal and next step, with visible Copy/Dismiss controls. Initial captures remain in `gallery-before-copy-review/`; final captures are in `gallery/`.

The native fixture bring-up first caught two test-only compile mistakes (`waitFor` scope and a redundant `try`); both were corrected before the failing-first run. One earlier Release build rejected a source timestamp change during a mutation build (`native-build-overlap.log`); it was rerun after restoration. These were build/setup failures, not regression evidence. The final native failing-first log contains actual executed assertion failures. Subsequent builds/mutations were kept sequential. No unrelated final-suite failure has occurred.

The three headless native regressions and their mutation runs create no windows or activation calls; they used the permitted focused lane after checking the test host's launch guard. Full affected native tests, LifecycleHelperTests alone, and gallery capture took the shared full-lane lock and released only their own lock. No installed app, real preferences, reader data, Keychain, live capture, paid endpoint or named result bundle was used. Source matched the adversarial-review diff after mutation restoration; the subsequent two notice strings received the visual review/reruns above. One own DerivedData tree was used (1.4 GiB); helper debug/release trees were 427/100 MiB. No native clone directories remain. `git diff --check` passed. Only `dev/a130-helper` is committed/pushed; the lead owns merge and the full gate.

## Round 6 review — transient output ownership and deletion

Continued from `4edba932` on `dev/a130-helper`; no merge, rebase or fast-forward. All three review findings and the previously recorded slimming/deletion race are **confirmed and fixed**. This section supersedes the earlier unresolved slimming note. Fixtures use isolated metadata, generated journals/output and loopback helpers only.

### Findings and regression evidence

| Finding | Reproduction against the previous implementation | Fix and mutation evidence |
| --- | --- | --- |
| In-flight side draft transfer | `SubagentDeletionTests.testSideDraftTransferKeepsOutputWhileParentIsUnloaded` stops after the side composer is cleared and before the unloaded parent's metadata read. Collection removes the only output file. `native-before.txt`: **2 failed assertions**, including `The transfer owns the draft after its composer is cleared`. | Register the transfer before it can clear its old holder; retain the registration through save/rollback. `mutation-producer-registry.txt` restores collection without producer fencing: the side test fails with the same **2 assertions**. |
| Independently retained copies | `SubagentDeletionTests.testRetainedExternalCopySurvivesAnotherCopyWithSameIDBeingDeleted` dismisses an external copy's keep intent, then tombstones another copy with that ID. The original implementation removes its output. `native-before.txt`: **1 failed assertion**, `A tombstone for a chat ID does not delete independently retained copies`. | Keep and dismissed-retention rows own their particular journal paths, irrespective of a same-ID tombstone. The nearby pending-keep case is included too. Restoring decoded-ID exclusion gives **2 failed assertions**, one for each copy (`mutation-retained-copy-id.txt`). |
| Unlisted native side ancestry | `WorkspaceDurabilityTests.testImportingUnlistedArchivedSideRetainsBudgetAncestorsBeforeSelection` imports an archived native side whose parent is stored but unlisted. `import-before.txt`: **3 failed assertions**: missing parent, false `deletionNeedsAncestorRepair`, and the side incorrectly owning its budget. No helper is running. | Retain the ancestor chain before inserting/selecting the owner, and re-read ownership if the chat generation changed during that await. Omitting ancestor loading reproduces all **3 failures** (`mutation-import-ancestors.txt`). |
| Slimming resurrects a deleted source | The retained `JournalSlimmingTests.testDeletionDuringDiscardMustNotRepublishSource` probe is now permanent. `slimming-before.txt`: **1 test, 2 failures**, `Deleting the source must win over background slimming` and `Slimming republished the deleted source`. `HostServiceTests.testForgetWaitsForSlimmingWithoutBlockingAnotherChat` also fails first: **1 failure**, `Deletion cannot proceed while slimming can still publish` (`forget-before.txt`). | Forget awaits that ID's existing slimming task outside the runtime gate. Slimming rechecks the source's file identity after discard and atomically exchanges existing names; an absent destination cannot be recreated in the check/publication interval. Reverting publication to the old rename reproduces **2 failures**; removing the forget wait reproduces **1** (`mutation-slimming-publication.txt`, `mutation-forget-wait.txt`). `testReplacementDuringDiscardMustNotBeOverwritten` also preserves a replacement source and removes prepared leftovers. Removing only the source identity check fails both assertions (`mutation-slimming-source-identity.txt`); restored helper classes pass **18/18** (`helper-final-restored.txt`). |

The first import fixture omitted its generated Sessions directory; that setup error is recorded in `native-before.txt` and is **not** regression evidence. After fixing the fixture, `import-before.txt` shows the three actual assertions above. The initial fixed focused run passed **8/8** (`native-focused-final.txt`).

### Producer rule and sweep

The collector and reference producers share one MainActor registry across projects. Registration is synchronous and precedes removing a previous holder or scheduling a transferring task. A producer waits for the already queued collection task before reading/publishing; collection never waits on producers, so there is no producer/collector wait cycle. An active producer conservatively retains **all** candidate output, including references in bytes not decoded yet. Collection checks both membership and a generation before scanning and again immediately before handing files to the asynchronous recycler. The serialized collector remains held until that recycler returns. A later producer cannot pass its admission wait during that interval.

The last producer schedules a fresh deferred collection after publication/rollback. Cancellation and errors release registrations using `defer`; sheet work releases only after its reader returns and its completion is either delivered or rejected. A file is still stored once under its physical owner. There is no fork/draft duplication or permanent in-memory pin; after restart, surviving journals, draft/command metadata and path-specific keep/retained records are the durable owners. A pending recovery whose source is deleted cannot publish after restart because recovery still checks that source before and after linking its copy.

`ToolOutputProducerTests.testEveryReferenceProducerRegistersBeforeItsFirstSuspension` invokes the real entry point for **each of 19 producer kinds** (the editable sheet registers synchronously for its lifetime), holds it, removes its prior display holder, races collection, and verifies both retained bytes and release on cancellation. `testEveryProducerWaitsThroughAnAlreadySubmittedRecycle` tests all 19 in the opposite order, holding the actual asynchronous recycle callback. The original 18-kind wait mutation produces **36 failed assertions** (`mutation-producer-recycle-wait.txt`). Producer inventory:

| Registered producer | Entry points / lifetime |
| --- | --- |
| Side draft transfer | `moveSideDraft`, including ordinary text and the draft displaced by a queued edit; through parent save or restoration to the side. |
| Debounced draft write | `draftChanged`; captured `savedDraft` through revision reservation, debounce, write or cancellation. |
| Draft flush | `flushDrafts`; through pending write/recovery settlement and all retained draft writes. |
| Draft recovery | `recoverDraft`; through intent withdrawal and merged draft publication. |
| Draft materialization | `materializeChat`; through the pending chat and its initial saved draft. |
| Submission | `send`; registration precedes `acceptSubmission` clearing the composer; through acknowledgement or failed-send recovery. |
| Historical message edit | `editMessage` and `sendEdit`; through reading/replacing the full input and restoring the displaced draft. |
| Queued edit | `queueEditRequest`; covers Begin/Save/Cancel/Remove/status/reorder. The editor/recovery record remains a holder until its acknowledged replacement; deferred draft persistence has its own registration. |
| Side publication | `openSide`'s asynchronous publication/rollback and `publishPendingSide`; includes the initial draft and inherited model boundary. |
| Editable side handoff | `SideHandoffView`; the editable summary owns its references until Cancel, publication, window removal or deallocation. Copy/Insert/Replace wait behind any recycle already in progress, and a dismissed sheet cannot publish afterward. |
| Side close | `closeSide`; through helper keep/close, intent registration and final draft save. |
| Keep request | `performKeepSide`; through writing the durable keep intent and helper reply. A deferred Keep When Finished continues to be owned by that durable intent. |
| Keep registration | `registerKeptSide`; through identity validation and the transaction transferring ownership from intent to chat/draft/receipt. |
| Keep dismissal | `dismissSideKeep`; through the transaction replacing the pending intent with its path-specific retained row. |
| Fork | `createFork`; covers whole/reply forks, clone/copy publication, intent registration and acknowledgement. |
| Recovery publication | `recoverCopy`; from operation acceptance through helper publication, metadata save and selection. |
| Portable handoff | `portableHandoff`; through preview, confirmation and atomic chat/draft/provenance commit. |
| Journal import | `importChat(from:)`; through native-owner selection or external-journal registration. |
| Export/copy | Conversation copy/export plus Inspector metadata, retained-body and redacted-view export; through reads, save/clipboard completion, cancellation or failure. |

Additional race tests:

- Self-review found that an editable **Bring Back** sheet is itself a holder outside `displays`, even though its final transfer is synchronous. `testEditableSideHandoffRetainsOutputUntilDismissed` fails first with **1 assertion**, `The editable handoff is a reference even before it reaches a composer` (`handoff-before.txt`). It now retains the file until dismissal. `testSideHandoffWaitsForRecyclingAndDismissalCancelsPendingInsertion` also checks a queued insertion and cancellation while recycling. The full producer class passed **7/7** after this fix (`handoff-fixed.txt`). Removing its lifetime registration fails **1 assertion**; bypassing its recycle wait fails **3**; allowing publication after dismissal fails **1** (`mutation-handoff-registration.txt`, `mutation-handoff-recycle-wait.txt`, `mutation-handoff-dismissed-publication.txt`).

- `testDisplacedAndQueuedDraftWritesRemainReferencesWithoutTheirDisplay`: both edit variants survive collection while their snapshot is only in a pending write, then remain readable through the committed draft. Disabling the registry loses both variants (**4 assertions**).
- `testProducerArrivingDuringReferenceScanPreventsRecycleUntilPublication`: a recovery producer registers after inventory/scan but before recycling. Removing only the final producer check loses the file (**2 assertions**, `mutation-producer-final-fence.txt`). The released producer publishes its reference, which the fresh scan then retains.
- `testCancelledExportScopeRetainsOutputUntilItsReaderActuallyReturns`: cancelling a sheet does not release an uncancellable in-flight reader prematurely; it releases once the result is discarded. Skipping finalization on cancellation leaves the pin and output stranded (**2 assertions**, `mutation-cancelled-producer-release.txt`).

Self-review extended the retained-copy fixture through `finishFamilyDeletion` and a second collection. This confirmed another instance of ID-only deletion: the metadata cleanup removed a different pending keep, even though collection had preserved its file. `pending-deletion-before.txt` fails **2 assertions**, `Finishing deletion must not drop a different pending copy's ownership` and `The independent pending copy must transfer to durable retained ownership`. Deletion now atomically converts unmatched pending keeps into path-specific retained rows before removing their registration intent. Only an exact, non-nil path in the same workspace proves that the pending copy was the deleted journal. The existing retained-copy test and `testDeletingMatchingPendingCopyReleasesItsOutput` pass **2/2** (`pending-deletion-fixed.txt`); the matching case confirms that ordinary deletion still permits output reclamation. Removing just that durable transfer reproduces **2 failed assertions** (`mutation-pending-deletion-ownership.txt`); the original source was restored before final class validation.

The initial registry mutation yields **27 failed assertions across 6 executed tests**, including the original 18 producer entry points, the transfer, displaced/queued drafts, cancelled export and late publication. These tests run without activating a window or invoking real Trash; their recycler removes only generated fixture paths. The pre-existing clone/copy fork-through-normal-deletion regression remains in the full `SubagentDeletionTests` run.

Other holders examined: synchronous `moveSideDraftHere`/`absorb`, `finishEdit`, `finishQueuedEdit`, `finishRecord`, `openQuotedSide`, the final `bringBack` transfer and lost-side replacement move references between live holders without yielding; their asynchronous draft writes register separately. Metadata transactions transfer pending commands and keep/retained records atomically. Active tool producers have live physical owners and cannot pass family deletion's running-work preflight. Published native journals (including unlisted sides/forks), external imports and retained copies remain in the existing strict inventory. Pasted images/attachments still use their separate reference scanner and synchronous unlink admission; capture payloads retain their existing archive ownership. Completed standalone text exports/clipboard contents remain the earlier **needs owner decision** boundary; this change protects export work in flight and surviving app chats, without creating a new permanent external-export registry.

### Adversarial self-review

Reviewed the entire new diff against `4edba932`, including every added/changed branch and every added suspension:

| Changed condition / suspension | States newly taking the other branch; intended result |
| --- | --- |
| Producer present at scan admission or changed since inventory | Locally held transfer/save/publication now defers collection; no producer and unchanged generation still scans normally. This applies equally to streaming, idle and paused chats and all Off/memory/persist capture modes. |
| Existing serialized collection at producer admission | A producer arriving during scanning/recycling waits for that entire task chain, including failed/cancelled predecessors. Without a predecessor it proceeds immediately. Concurrent sibling/project work has the same reference protection. |
| Last producer + deferred collection | Completion, failure and cancellation now schedule a fresh scan once the registry is empty. Other active producers continue to retain output. Shutdown still forbids scheduling; a missing store clears the deferral instead of spinning. |
| Sheet inactive/cancelled/stale generation | `PayloadTaskScope.finally` runs even when no task is admitted or no completion can be delivered. Existing callers have a no-op finalizer; exports release only after asynchronous work finishes. Normal completion publishes before release. |
| Editable handoff use / existing recycle / retained identity after await | Opening/mounting the editor now retains locally edited paths. Cancel, detach and deallocation release them. With no preceding recycle, Copy/Insert/Replace remain synchronous; otherwise they wait, use the captured text, and require the same still-open handoff before publishing. Closing during that wait cancels the publication. |
| Tombstoned ID on pending/dismissed keep | These specific copies now remain references. Ordinary deleted chat/draft/handoff/command rows retain their existing exclusion. Missing/damaged retained copies fail closed rather than proving their output unreferenced. |
| Pending keep at deletion completion | No intent remains a no-op. An exact non-nil journal path in the same workspace is still removed. A different workspace/path or unknown path now transfers to retained ownership in the same transaction, so there is no unregistered interval and no automatic re-registration of a deleted ID. |
| Native import owner and workspace | Same-project native owners load missing ancestors before exposure; wrong-project owners retain their refusal. Fork provenance does not become budget ancestry; missing/tombstoned ancestors retain existing orphan behavior. Archived imports need no helper. |
| Chat generation changes / owner deleting during ancestor read | Re-read the owner or refuse stale exposure; do not resurrect an entry deleted while ancestry was loading. Stable owned imports select the same chat; external imports keep their existing behavior. |
| Forget with an existing slimming task | Wait for success or failure before allowing deletion, outside the runtime gate. Unrelated snapshots still answer; no slimming task keeps the previous path. Running/paused session admission rules remain unchanged. |
| Source identity after discard; atomic exchange failure | Deleted/replaced sources are not overwritten. Existing unchanged source publishes normally. A missing destination at the exchange returns `source-changed`; other filesystem failures preserve the error/cleanup path. Restart cannot recover a journal recreated by slimming. |

Self-review found the independently editable Bring Back sheet, two additional transfer entry points (materialization and saved-side close), both the collector and deletion-completion variants of pending-keep ID exclusion, the need to revalidate native import after ancestor loading, and cancellation cleanup for export completion scopes; all are covered above. It also moved the new materialization wait **after** reserving its existing project/save ownership, and the draft-recovery wait **before** rechecking acceptance. Thus new awaits cannot reopen the first-send project-choice race or withdraw a submission accepted while waiting. No provider, permission, vault, capture policy or wire schema was changed.

### Validation commands and final results

Evidence directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/persistence-producers/`. Exact selected-class commands are also saved in the `native-*-results.json` files. Mutation commands and selections are in `producers-native-mutations.py`, `producers-helper-mutations.py`, `producers-handoff-mutations.py`, `producers-pending-mutation.py` and `producers-replacement-mutation.py` under the same build root. All helper/native builds use only this workstream's root.

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter JournalSlimmingTests.testDeletionDuringDiscardMustNotRepublishSource
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter JournalSlimmingTests.testReplacementDuringDiscardMustNotBeOverwritten
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter HostServiceTests.testForgetWaitsForSlimmingWithoutBlockingAnotherChat
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter 'JournalSlimmingTests|HostServiceTests'
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ToolOutputProducerTests -only-testing:PiAppTests/SubagentDeletionTests/testSideDraftTransferKeepsOutputWhileParentIsUnloaded -only-testing:PiAppTests/SubagentDeletionTests/testRetainedExternalCopySurvivesAnotherCopyWithSameIDBeingDeleted -only-testing:PiAppTests/WorkspaceDurabilityTests/testImportingUnlistedArchivedSideRetainsBudgetAncestorsBeforeSelection
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
```

Helper validation completed with **1,054 executed: 1,047 passed, 7 skipped, 0 failed**. `StreamingCostTests` ran alone (**5/5**); the remaining suite ran **1,049 tests: 1,042 passed and 7 skipped** (`helper-streaming.txt`, `helper-full.txt`). The existing opt-in benchmark skips are ForkClone (1), ForkPerformance (1), HistoryReadCancellation (1) and SessionOpenPerformance (4). The final source-identity mutation was restored and both affected helper classes rerun: HostService **8/8**, JournalSlimming **10/10**. The Release helper passed wire **36/36**, concurrent **4/4** and acceptance **3/3** (`wire.txt`, `concurrent.txt`, `acceptance.txt`).

The final headless native run passed **114/114**, including the seven producer tests with all 19 kinds, all 16 deletion tests before adding the matching-copy control and the archived native-side ancestry fixture.

Final native coverage is **467 distinct tests executed: 466 passed, 1 skipped, 0 failed** across 40 classes. After the deletion-completion fix, seven affected classes reran **80/80**, including all **17** SubagentDeletion tests; the corrected SideKeep gallery reran **2/2**. Repeated checks are not double-counted.

| Native run | Passed / skipped / failed |
| --- | --- |
| `native-headless.txt` | 114 / 0 / 0 |
| `native-affected.txt` | 178 / 0 / 0 |
| `native-LifecycleHelperTests.txt` | 11 / 0 / 0 |
| `native-QueueEditInteractionTests.txt` | 17 / 0 / 0 |
| `native-PayloadNativeControlTests.txt` | 22 / 0 / 0 |
| `native-PayloadNativeParityTests.txt` | 7 / 0 / 0 |
| `native-InspectorNativeControlTests.txt` | 12 / 0 / 0 |
| `native-InspectorNativeParityTests.txt` | 7 / 0 / 0 |
| `native-InspectorStorageTests.txt` | 15 / 2 / 0 |
| `native-ShellParityTests.txt` | 15 / 0 / 0 |
| `native-deletion-gallery.txt` | 2 / 0 / 0 |
| `native-submission-races.txt` | 61 / 1 / 0 |
| `native-retention-final.txt` | 80 / 0 / 0 |
| `native-side-handoff-gallery-final.txt` | 2 / 0 / 0 |
| `native-inspector-gallery-final.txt` | 17 / 0 / 0 |

Exact native commands (each serial class and gallery was a separate invocation; focus-sensitive invocations held the shared lock through completion):

```sh
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/JournalSlimmingTriggerTests \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/SideBudgetIntegrationTests \
  -only-testing:PiAppTests/ForkCloneReaderTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/HistoricalEditFocusTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/PayloadSearchTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/ConversationPaneTests \
  -only-testing:PiAppTests/PastedAttachmentTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/PayloadNativeControlTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/PayloadNativeParityTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorNativeControlTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorNativeParityTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorStorageTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ShellParityTests
PI_BUILD_ROOT="$BUILD" TEST_RUNNER_PI_APP_CHAT_DELETION_GALLERY="$BUILD/logs/persistence-producers/gallery" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChatDeletionGalleryTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/AutomaticContextTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests
PI_BUILD_ROOT="$BUILD" TEST_RUNNER_PI_APP_SIDE_KEEP_GALLERY="$BUILD/logs/persistence-producers/side-handoff-gallery" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideKeepGalleryTests
PI_BUILD_ROOT="$BUILD" TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$BUILD/logs/persistence-producers/inspector-gallery" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorStorageTests
```

Gallery validation regenerated **70 PNGs**: 24 deletion/import scenes, 14 side-keep/handoff scenes and 32 Inspector storage/toolbar scenes. Inspected all four changed Bring Back scenes in light/dark at 720 and 520 points: summary text wraps, the full output path remains readable, and Copy/Replace/Insert/Cancel remain visible and inside the sheet. Their final SHA-256 hashes match the inspected images. Inspector storage ran again with its gallery environment enabled (**17/17**), replacing its initial two opt-in skips; inspected request/response toolbars in light/dark at 1000 and 485 points. `ShellParityTests` also passed **15/15**, including the existing handoff reference comparison.

The first new handoff gallery reused a notice-specific assertion requiring `accessibilityLabel()`, giving **16 assertion failures in 1 of 2 tests** (`native-side-handoff-gallery.txt`). These existing PiKit text buttons inherit their accessible names through `NSButton.accessibilityTitle()`. The checker now accepts either accessibility naming API; the corrected class passes **2/2** (`native-side-handoff-gallery-final.txt`). No production layout or accessibility code changed for this fixture correction. All other final native runs passed on their first execution.

The final reviewed Swift sources matched their recorded hashes after every mutation was restored and after validation. `git diff --check` passed. The generated project includes the new producer source and regression class (`xcodegen generate --quiet`). One own native build tree (1.4 GiB), one debug helper tree (428 MiB) and one Release helper tree (100 MiB) were used; no clone directories remain. Focused headless regressions did not change app focus. All focus/parity/gallery runs used the shared lane lock and released only their own lock. No installed app, real preferences/chats/Keychain, live capture, paid provider or named result bundle was used.

The remaining native skip is `ComposerSubmissionTests.testTheMenuBarGivesCommandReturnToSendOrSteer`: this test host has no Conversation menu. It is recorded in `native-submission-races.txt`, and no installed application was launched to bypass that isolation.

The earlier completed-external-export ownership question remains **needs owner decision**; in-flight exports are protected here. No new unresolved issue remains in this review scope. Only `dev/a130-helper` is committed/pushed; no merge or fast-forward was performed.

## Round 8 review — export identity and final collection

Base: `9fff7915950f0561c59114fded64ca50580db24a`, on `dev/a130-helper`; no merge or fast-forward. Evidence uses the existing build root, with text logs in `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/round8-review-20261020/`. All fixtures are generated and all helper services are loopback; credentials use `MemoryVaultStorage`.

### Findings and failing-first evidence

The October 18 run was interrupted by a laptop restart during an export mutation. On October 20 the mutation (`isCurrent` returning `true`) was identified and restored before validation. Its logs are superseded: the own native, debug-helper and Release-helper build trees were cleared, and failing-first, fixed, mutation and final suites were rerun from fresh builds. Only the new `round8-review-20261020` evidence counts below.

| Item | Confirmation, regression and fix |
| --- | --- |
| Export selection — **confirmed + fixed** | The real Raw menu action waits behind a collection task; the test changes both request and physical session before releasing it. `testRedactedExportRefusesSelectionChangesAcrossCleanupAndQuestions` fails before the fix at cleanup, literal, preview and save boundaries. `testMetadataExportRefusesSelectionChangesAcrossCleanupAndSave` confirms the nearby metadata instance; `testRetainedExportRefusesSelectionChangesAcrossCleanupAndQuestions` catches the obsolete retained-body dialog. `inspector-failing-first.txt`: **4 tests, 3 failed, 13 assertions**; unchanged-selection export succeeds. Excerpts: `redacted exported a changed selection after cleanup`, `metadata exported a changed selection after save`, and `bodies must refuse a changed selection before opening an export question`. All three export paths now capture their source, physical session, request ID and raw part before the collector await. Redacted export also captures its document/format; metadata captures its text. Identity is checked after collection, dialogs and rendering, and before writing. The manifest uses the captured identity. |
| Final ownership collection — **confirmed + fixed** | Removed the manual second sweep from `testDeletingMatchingPendingCopyReleasesItsOutput`. `ownership-navigation-failing-first.txt`: the matching-keep test fails, `deletion's automatic final output collection`, followed by XCTest reporting the thrown timeout (2 failures). The family deletion defers a fresh cleanup request until after ownership retirement, including error exits after partial metadata cleanup. Setting the existing deferred flag also preserves the request if cleanup is already running. The test now only observes the file disappearing; it never invokes that sweep. The separate `testRetiredKeepReclaimsOutputEvenWhenLaterMetadataCleanupFails` covers an error after the keep row was retired. |
| Imported-index deletion sweep — **confirmed + fixed** | `testDeletingImportedReferenceAutomaticallyReclaimsOutput` drives ordinary Delete, waits for index removal, then checks automatic log reclamation while the external journal remains. `ownership-navigation-failing-first.txt`: `import deletion's automatic output collection` (1 failed test / timeout reported twice). The imported deletion path now also requests collection after retiring its ownership rows. |
| Import/recovery/handoff UI sweep — **confirmed + fixed** | `testImportRecoveryAndHandoffRefuseNavigationDuringCollection` changes chat and page while each real action waits. `ownership-navigation-failing-first.txt`: **1 failed test, 5 assertions**. Import selected `chat-parent` instead of `another-chat` and changed Reports back to Chats; recovery opened a question; portable handoff opened a question and started a helper. Each action now captures navigation/project and its source before waiting, checks it before subsequent preparation/publication, and keeps its original configuration selection. Import and completed recovery/handoff commits do not override newer navigation. |

The October 18 compile typo and passing runs were discarded as evidence after the restart. Fresh commands and final counts are recorded below. The October 20 failing-first ownership run also includes the interrupted-metadata variant, which must reclaim output after the keep row is retired even if a later step fails. Together that run executes **4 tests, all failed, with 11 failures (3 unexpected timeout errors)**.

One October 20 native run was also discarded: stopping its controller after it advanced left a child running, overlapping a second native build in this workstream's build root. `ownership-fixed-overlap-discarded.txt` preserves **36 tests / 3 failures (1 unexpected)**: the clone/copy test could not find a compatible helper bundle, and `testEnumerationFailureKeepsDeletionIntentAndRetriesAfterRepair` had two failed retry assertions. Xcode also reported result-bundle import errors. `self-review-failing-first-overlap-discarded.txt` preserves the overlapping self-review reproduction. Neither is counted as validation. After verifying that no child remained, the waiting controller was stopped and all remaining native builds ran through one serial controller. The self-review reproduction and ownership suite were repeated in isolation; both ownership tests pass there and in the final class run.

The redacted regression was then expanded to cover changing only the raw part or document format, clearing the capture, and closing the Inspector while collection waits. The normal control still writes the original request ID, `sourceView: request` and the expected redacted text. Retained-body export checks identity immediately before starting the archive/helper operation: after the destination is approved, that operation stays bound to the captured request even if navigation changes during its disk work; only its stale completion notice is suppressed.

### Audit of every collector await added in round 7

The 19 producer kinds from the previous section remain registered through their complete asynchronous operation. Navigation-sensitive actions below snapshot before their first suspension; actions explicitly addressed to an ID continue for that original ID rather than consulting a later selection. No collector wait releases the producer early.

| UI/action path | Captured identity and validation after suspension |
| --- | --- |
| Inspector metadata / retained bytes / redacted view | Fixed here: request ID, physical session, raw part, capture revisions, text/body source, document format, archive/workspace and manifest fields. Checks at each collector/dialog/render boundary. Request completion may update metadata without changing the selected identity; frozen metadata remains a valid snapshot. |
| Conversation copy / Markdown export | `source`, source revision, range/total and destination window are captured before waiting. Page reads validate the revision; `PayloadTaskScope` rejects completion after cancellation/replacement. The captured source owns its request identity, not the current composer selection. |
| Editable side handoff | Immutable `session.id`, model, text and lifetime token are captured. After waiting, the token must still match; dismissal/unmount retires it. `bringBack` resolves the original side/parent, and the synchronous transfer cannot read another selected chat. |
| Journal import | Fixed here: URL, requested workspace, profile and navigation/project snapshot. Native-owner lookup retains ancestry and rechecks chat revisions; navigation is rechecked after lookup/read and before selection. An external metadata commit that already started remains registered but cannot select over later navigation. |
| Recovery / portable handoff | Fixed here: source item/path/project, profile, navigation/project snapshot. Checks follow collection, confirmation and helper setup/preview. Recovery already published by the helper is registered under its returned copy identity even if navigation changed; its source is not recreated and selection is not stolen. |
| `send` / `sendEdit` | Captured `Submission` or edit message ID, text, attachments, skills, command/turn IDs, saved draft, original display and archive revision. Connection/archival admission is rechecked before dispatch. Original explicit submissions can continue while another chat is selected; they cannot use that chat's composer. |
| `editMessage` / queued edit commands | Original session/message or turn/edit ID and parameters. Edit generation and saved draft reject stale preparation; queue results check edit/hold identity and revision. `QueueEditFocus` rejects obsolete focus changes. |
| `draftChanged` / recovery / materialization | Captured draft/session/revision token, original intent/display, or pending chat record/project reservation. Canceled debounces, accepted/retired intents and discarded placeholders are rejected by their existing checks. Recovery deliberately merges current typing from the same original display after waiting. |
| `flushDrafts` | Global flush, not a selected-row action. After pending recoveries settle, it inventories the then-current retained displays by their own IDs; it never redirects one draft to another selection. |
| `moveSideDraft` | Original side holder and parent ID captured before waiting. Serial per-side transfer and the parent's saved/loaded state are rechecked after every read/write. It intentionally includes typing accumulated on that same side while collection waits. |
| `openSide` / `publishPendingSide` | Original side ID, parent ID, project, display and initial question/submission draft. Parent lookup/open and returned side ID validate the source; replacement-side checks prevent stale publication/rollback from altering another side. No selected-ID lookup supplies the source after waiting. |
| Keep / close / registration / dismissal | Original side ID/info/display/host or immutable keep issue and path. Durable intent, canonical journal identity and expected-copy transaction validate registration/dismissal; close checks the side ID before removing its panel. Other selected chats are not consulted. |
| Whole/reply fork | Original parent record, parent ID and optional message ID; helper validates that source and returned fork ID. Durable keep registration validates the path/intent. Existing caller navigation guards prevent selection stealing. |

### Adversarial self-review

Reviewed the new diff from `9fff7915` and the prior producer awaits as a hostile reviewer. The sweep findings above were reproduced before fixes. Changed-condition inventory:

| Changed condition / state that now takes the other branch | Intended result |
| --- | --- |
| Export identity no longer matches request/physical session/raw part | Refuse before asking, rendering or writing; never combine the newer body with the older manifest. Covers switching to another child request as well as ordinary chat requests. |
| Relevant capture revision, redacted document ID or format changed | Refuse the stale export. Purged bodies and a different displayed format cannot silently supply or label its bytes. A growing stream that has not replaced the selected document still exports its captured snapshot. Redacted views check only their own body revision; retained-byte/metadata export checks both bodies. |
| Inspector inactive or task cancelled | Release the producer without writing or updating another selection's notice. A save with unchanged identity still succeeds. |
| Import/recovery/handoff navigation revision or selected project changed | Stop preparation before helper work or publication; captured inputs never follow the newly selected chat/project. Source path changed/removed likewise refuses recovery/handoff preparation. |
| Navigation changes after a metadata/publication commit began | Preserve the already-created original copy and its durable references, but do not select it. This avoids creating an unregistered published recovery merely to cancel a UI action. |
| Cleanup is already running when ownership rows retire | The deferred flag records another scan instead of losing the scheduling request to the existing-task guard. A queued scan that starts later sees the retired rows directly; an already-started scan gets another pass. |
| Metadata cleanup throws after retiring keep ownership | The deferred request still runs. A still-present or unreadable ownership row remains conservative and retains output; no damaged reference is interpreted as permission to recycle. |
| Producer is active during that final pass | Existing producer admission defers collection until the last holder releases. Concurrent sibling work remains protected through the entire asynchronous recycler. |
| Shutdown/restart | Shutdown does not start opportunistic work; durable deleted-owner records make restart eligible for the normal post-restoration cleanup. Pending deletion retry still retains its repair proof. |

Off/memory/persist capture selection, streaming/idle/paused conversations, failed/cancelled preparation, restarted ownership and concurrent sibling references retain their existing boundaries. The collector does not infer deletion of retained copies from an ID tombstone, copy files, change quotas, or bypass capture availability. Independent retained copies still survive the automatic post-deletion pass; its previous manual sweep was replaced with awaiting the already-scheduled cleanup.

Self-review additionally reproduced two edge cases in the initial export patch (`self-review-failing-first-isolated.txt`: **2 tests / 3 failures, including 1 unexpected missing-file error**). Restoring both fixes gives **6/6 passing** export regressions and controls in `inspector-fixed.txt`:

- `testMetadataExportNeverWritesAnUnloadedSource`: metadata is empty when export starts, then finishes loading while collection waits. Freezing that empty string wrote a zero-byte file (`An unloaded source must not export an empty metadata file` and a missing `attemptId`). Metadata export now refuses that unavailable snapshot before showing the save panel. Loaded metadata still exports normally.
- `testRedactedExportSurvivesLossOfTheOtherBody`: the response expires while a request export waits. Checking the entire revision dictionary incorrectly cancelled the still-readable request export (missing output file, Cocoa error 260). Redacted export now checks its selected body's revision plus document/format identity. This preserves the approved per-body retirement behavior. Retained-byte export still checks both bodies.

These are additional changed branches: an initially empty metadata snapshot now returns without writing; loss of an unrelated body no longer cancels a valid redacted view. The selected body's loss, navigation, format replacement and cancellation still refuse it. No layout or new control was introduced.

### Mutation checks

Each mutation was compiled and tested independently, then restored before the next mutation. Every failure below is an actual XCTest regression failure, not a compiler/build failure. `mutations-restored.json` confirms restoration; each of the three production files also matched its pre-mutation byte-for-byte backup. The fixed export selection/edge-case tests pass **6/6**, and the isolated ownership/producer/workspace-durability classes pass **36/36** (`inspector-fixed.txt`, `ownership-fixed.txt`).

| Log | Mutation and result |
| --- | --- |
| `mutation-retired-keep.txt` | Remove the family's deferred final cleanup request. Both matching-keep and interrupted-metadata tests fail: **2 tests / 4 failures (2 thrown timeouts)**, `deletion's automatic final output collection`. |
| `mutation-import-reclamation.txt` | Remove the imported-index deletion's final cleanup request. **1 test / 2 failures (1 thrown timeout)**, `import deletion's automatic output collection`. |
| `mutation-navigation.txt` | Weaken the three captured navigation equality checks to `>=`. **1 test / 5 assertions**: stale import selects its chat/page; recovery and handoff ask obsolete questions; handoff starts a helper. |
| `mutation-export-identity.txt` | Make `isCurrent` always return true. All three changed-selection export tests fail: **3 tests / 20 assertions**, including exports after part/format/capture/Inspector changes and obsolete retained-byte destinations. |
| `mutation-unloaded-metadata.txt` | Remove the nonempty metadata-snapshot guard. **1 test / 2 assertions**: empty file and missing `attemptId`. |
| `mutation-other-body.txt` | Compare all capture revisions for a redacted source. **1 test / 1 unexpected missing-file error**: expiry of Response wrongly cancels the Request export. |

All six mutation runs exit 65 as expected. Their exact focused selectors and commands are recorded in `native-wire-results.json`; the command prefix for each is `PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO`, followed by `-only-testing:PiAppTests/<Class>/<test>` for the tests named above. Focus-changing export tests hold the shared lane; headless ownership/navigation tests do not change focus.

### Fresh validation after the restart

All commands run from this worktree, with the following build root. The helper suite follows `verify-release.sh`'s isolated streaming-cost process and remaining-suite split; it covers the complete helper suite once.

```sh
BUILD=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$BUILD/swift-verify" --skip-build --skip StreamingCostTests
```

`helper-streaming-cost.txt`: **5/5 passed**. `helper-full.txt`: **1,049 executed, 1,042 passed, 7 skipped, 0 failures**. Combined: **1,054 executed, 1,047 passed, 7 skipped, 0 failures**. The skips are opt-in fixture/performance probes: `ForkCloneTests.testWriteTheSharedForkFixture`, `ForkPerformanceTests.testForkingAVeryLargeChat`, `HistoryReadCancellationTests.testRapidSupersessionMeasurement`, and the four `SessionOpenPerformanceTests` measurements (`testMemoryOfOneOpenChat`, `testOpeningAKeptJournal`, `testOpeningALongChat`, `testSlimmingAKeptJournal`). `helper-results.json` records both exact commands and successful exit codes.

Release helper and wire validation:

```sh
PI_BUILD_ROOT="$BUILD" python3 scripts/build-bundle.py
HOST="$BUILD/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
```

Release bundle build passed. Wire **36/36**, concurrent wire **4/4**, and acceptance **3/3** passed with no skips or failures (`wire.txt`, `concurrent-wire.txt`, `acceptance.txt`).

Final focused native commands (each focus/gallery run holds the shared lane; serial-lane classes run separately):

```sh
LOGS="$BUILD/logs/round8-review-20261020"
native() { PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO "$@"; }
native -only-testing:PiAppTests/SubagentDeletionTests -only-testing:PiAppTests/ToolOutputProducerTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/SubagentCostTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/SessionOrganizationTests -only-testing:PiAppTests/SubagentDiscoveryTests -only-testing:PiAppTests/DeferredCreationTests
native -only-testing:PiAppTests/LifecycleHelperTests
native -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/WorkspaceFollowupTests -only-testing:PiAppTests/LaunchSelectionTests
native -only-testing:PiAppTests/ConversationPaneTests
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$LOGS/inspector-gallery" native -only-testing:PiAppTests/InspectorStorageTests
native -only-testing:PiAppTests/InspectorNativeControlTests
native -only-testing:PiAppTests/InspectorNativeParityTests
native -only-testing:PiAppTests/CaptureDrainTests
TEST_RUNNER_PI_APP_CHAT_DELETION_GALLERY="$LOGS/deletion-gallery" native -only-testing:PiAppTests/ChatDeletionGalleryTests
```

| Final native log | Passing counts by class |
| --- | --- |
| `native-ownership-final.txt` | SubagentDeletion **19/19**, ToolOutputProducer **8/8**, WorkspaceDurability **9/9**, FamilyDeletion **10/10**, MetadataDurability **10/10**, SubagentCost **11/11**, WorkspaceRace **20/20**, SessionOrganization **9/9**, SubagentDiscovery **15/15**, DeferredCreation **4/4**; **115/115** total. |
| `native-lifecycle-final.txt` | LifecycleHelper **11/11**, run alone. |
| `native-surviving-references-final.txt` | SideKeepRecovery **15/15**, SideKeepOrdering **12/12**, WorkspaceFollowup **9/9**, LaunchSelection **21/21**; **57/57** total. |
| `native-conversation-final.txt` | ConversationPane **81/81**. |
| `native-inspector-final.txt` | InspectorStorage **23/23**, including both opt-in gallery tests. |
| `native-inspector-controls-final.txt` | InspectorNativeControl **12/12**, run alone. |
| `native-inspector-parity-final.txt` | InspectorNativeParity **7/7**, run alone. |
| `native-capture-drain-final.txt` | CaptureDrain **6/6**, run alone. |
| `native-deletion-gallery-final.txt` | ChatDeletionGallery **2/2**, run alone with its gallery environment. |

Final native total: **314/314 passed, no skips or failures**, excluding the earlier focused controls and intentional failing-first/mutation runs. `native-final-summary.json` retains the class counts; `native-wire-results.json` retains exact argument lists, gallery environment variables and exit codes. No code changed after the final runs. `reviewed-source-sha256.json` matches every changed Swift file, and `git diff --check` passes.

Regenerated **56 PNGs**: **32 Inspector** and **24 deletion/import** scenes. Inspected Request and Response toolbars in light/dark at 485- and 1000-point pane widths: part/format selectors, Copy and the capture menu remain visible, and body/status text fits. Also inspected narrow light/dark family deletion sheets at 340 points, a wide family sheet at 1240, narrow import notices at 320 and a wide notice at 720: confirmation controls remain visible, summaries wrap, long side names truncate within their rows, and notices retain Copy/Dismiss. The inspected images match the hashes recorded in `gallery-sha256.json`. No layout or control was changed by this round.

One own native build tree (1.3 GiB), one debug-helper tree (409 MiB), and one Release-helper tree (95 MiB) were used. No clone directories remain. All owned lane locks were released; other workstreams' locks were left alone. No installed app, live/paid provider, real preference/chat/Keychain, or explicit result-bundle path was used. Text logs are the evidence.

No new unresolved round-8 issue remains. The completed-external-export lifetime question was pending in round 8; the lead resolved it in Round 3 hunt below: Markdown stays text-only. In-flight export ownership remains protected. Only `dev/a130-helper` is committed/pushed; no merge, fast-forward, tag, release or history rewrite was performed.


## Round 3 hunt

Base: `fe734912` (the lead's merged/fast-forwarded worktree), branch `dev/a130-helper`, 2026-10-20. The three assigned findings are **confirmed and fixed**. This round uses newly built products and new text logs under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper/logs/round3-hunt`; no earlier-run evidence is counted. All inputs, journals, tools and gateways are generated fixtures. No installed app, real preferences/chats/Keychain, live capture or paid provider was used.

**Lead decision closed:** Markdown export stays text-only. This supersedes the earlier “needs owner decision” notes about completed Markdown exports in this record. Export in flight remains protected; a completed external Markdown file does not acquire permanent ownership of app-managed output. No bundling or permanent external-export registry is added.

### Findings, failing-first evidence and mutations

1. **helper-sessions-6 — automatic compaction task time.** `CompactionTaskRegressionTests.testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen` uses a generated history that triggers automatic compaction, a 150 ms summary and a 50 ms answer. `compaction-failing-first.log` shows the live and reopened task both reporting **53.93 ms versus 208.17 ms** measured for the turn (`XCTAssertEqual failed`). The summary attempt's existing settlement defer now also adds its measured duration to the optional active task. It counts successful, failed and cancelled summary attempts, preserving the existing exclusion of retry backoff. Manual utility work still has no active task to charge; the existing manual-compaction test now asserts that the recent task records are unchanged and no active record appears. Removing this one task increment (`mutation-summary.log`) fails both live/reopened assertions again, **53.51 versus 210.78 ms**. Restored tests pass.

2. **helper-sessions-7 — crash recovery retry time.** `RetryTests.testCrashAfterToolBoundaryPreservesSavedRetryTime` waits for a 150 ms failed request, a 50 ms successful retry and a completed fixture tool, then holds the next request while copying the journal as a crash fixture. Before the fix, `failing-first.log` reports **51.56 ms versus the saved 204.14 ms**. Recovery now preserves the saved aggregate and adds only assistant message durations whose journal spans are after that state record. It does not use the displayed last row as a watermark, which may fall outside a checkpoint's loaded window. `testCrashAddsOnlyRepliesJournaledAfterSavedRetryTime` additionally holds a second tool after its assistant reply was journaled but before another state snapshot; its failing-first result was **106.09 versus 261.15 ms** (`recovery-suffix-failing-first.log`). Both fixtures assert no tool executes in the reopened runtime.

   Three mutations are caught: restoring the old successful-row sum fails both tests (`mutation-recovery-old.log`); removing the byte-offset fence double-counts the earlier successful reply, **263.19 versus 209.37 ms** in the first fixture (`mutation-recovery-no-offset.log`); omitting all suffix reconciliation loses the later reply, **208.79 versus 260.39 ms** (`mutation-recovery-no-suffix.log`). No unrecorded duration is invented for the request still in flight at the crash.

3. **Quadratic legacy timeline canonicalisation.** `ResponseTimelineTests.testFiveThousandLegacyPartsCanonicalizeWithinPagingBudget` took **26,598.70 ms**, failing its 2,000 ms budget before the fix (`failing-first.log`). Each canonical part has a unique output index and is already complete, so the implementation now constructs segments in one pass instead of invoking streaming reconciliation repeatedly. IDs, part metadata, text, completed state, zero revisions, coverage and terminal receipt stay identical. `testCanonicalMatchesOriginalAlgorithmForGeneratedParts` compares the complete value and encoded JSON with the original consume/finish algorithm over empty/single/multipart inputs, repeated call IDs, optional names, Unicode, empty text, all ordinary part kinds and unusual kinds/source IDs. The original algorithm passes this equivalence control before the fix. The final affected run canonicalises 5,000 parts in **2.90 ms** (`final/affected-helper.log`); the final full-suite measurement is **3.42 ms**. Restoring the old loop fails at **25,670.52 ms** (`mutation-canonical.log`).

Representative failing-first output (path prefixes omitted):

```text
CompactionTaskRegressionTests.swift:36: error: -[PiAgentCoreTests.CompactionTaskRegressionTests testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen] : XCTAssertEqual failed: ("Optional(53.93258333392441)") is not equal to ("Optional(208.1676666662097)")
RetryTests.swift:80: error: -[PiAgentCoreTests.RetryTests testCrashAfterToolBoundaryPreservesSavedRetryTime] : XCTAssertEqual failed: ("Optional(51.55520833283663)") is not equal to ("Optional(204.14437499828637)")
RetryTests.swift:95: error: -[PiAgentCoreTests.RetryTests testCrashAddsOnlyRepliesJournaledAfterSavedRetryTime] : XCTAssertEqual failed: ("Optional(106.08820833265781)") is not equal to ("Optional(261.14658333174884)")
ResponseTimelineTests.swift:35: error: -[PiAgentCoreTests.ResponseTimelineTests testFiveThousandLegacyPartsCanonicalizeWithinPagingBudget] : XCTAssertLessThan failed: ("26598.69566666521") is not less than ("2000.0") - One legacy row must not stall history paging
```

The first timing fixture initially used an ephemeral seed without keeping it; its live assertion already reproduced the bug, but reopening had no path. The fixture was corrected to keep its generated journal and rerun before any production edit; `compaction-failing-first.log` is the complete live/reopen evidence.

### Nearby sweep and adversarial self-review

Reviewed the entire new diff against the merged base, including each changed condition and the conditions bypassed by direct canonical construction:

| Change / newly selected states | Intended behavior and evidence |
| --- | --- |
| Summary settlement with an active task | Automatic threshold or overflow compaction, including retries, adoption failure and cancellation, now charges the same measured attempt time to task and turn. Backoff is outside `requestMs`; pre-dispatch cost/Stop guards still run before measurement. No provider, capture, permission or cost-admission condition changes. |
| Summary settlement without an active task | Manual compaction and title/utility work retain the nil optional; no task is created or historical task altered. Manual-compaction control passes. |
| Recovered valid nonterminal task with a saved state source | Preserve its aggregate (including retries and summaries) instead of replacing it with successful-row durations. Terminal receipts, invalid tasks and tasks absent from saved state still take their existing paths. The source offset is read from the replay, including checkpoint replay, not guessed from loaded row position. |
| Reply span after the saved state, kind `message` | Add only that task execution's later journaled reply duration. The existing root/execution filter excludes other tasks. Both crash windows and the no-suffix mutation exercise this. |
| Reply before/equal to state, missing span, or a presentation update | Do not charge it again. Presentation-only updates cannot become a second request. The no-offset mutation proves the saved boundary matters. A state with no comparable source retains its aggregate conservatively; ordinary decoded state/branch/checkpoint paths provide the source. |
| Canonical construction bypasses `consume`/`finish` | Every input index creates a distinct completed segment: no existing part, streamed continuation, terminal correction or duplicate event can occur. Empty input still has canonical coverage and terminal `completed`. The generated equivalence test compares every field and encoded JSON. Live observed timelines still use the unchanged reconciliation path. |

State sweep: idle/manual utility, active streaming/automatic compaction, retries, paused/cancelled requests, reopening, and concurrent sibling tasks retain their existing lifecycle and ownership. Timing belongs to the session actor's active execution; there is no shared counter. Off/memory/persist capture do not participate in either timing fix or canonical reconstruction. No new await or UI action was introduced. No native view or layout code changed, and canonical timeline fields remain identical. Corrected task totals use the existing presentation; native consumer classes are rerun below without changing gallery scenes.

Validation self-review also found that `scripts/test-lanes.py` labels `TranscriptGeometryCacheTests` and `TranscriptTurnFoldTests` parallel even though their fixtures call `makeKeyAndOrderFront` (lines 138 and 590). The preliminary 50-test native run used that classification and lacked the shared focus lock. It is not used as final native evidence: the whole group is repeated under the lock, as is `TranscriptBugRegressionTests` (its `findFixture` opens a key window at line 1047). No other workstream’s lock is removed. The lane classifier’s missing key-window pattern is recorded for the lead rather than changed outside this task.

Other timing producers: `completeWithRetries` already settles turn/session/task together; no other producer or recovery site rebuilds task model time from successful rows. The legacy fallback in `ChatMessage.view`, the native `TranscriptMessage` decoder, and shortened-timeline restoration all call the corrected canonical function. No separate legacy reconstruction loop needed a fix.

**Separate bug found, not fixed under this scope:** `packages/swift-host/Sources/PiAgentCore/ProviderDisplayEvents.swift:80` feeds every terminal provider event through the live `ResponseTimeline.consume` reconciler. A generated JSON response with 1,000/2,000 function-call items took **807.73/3,168.36 ms** (`provider-terminal-sweep.log`; retained fixture in `provider-terminal-probe.txt`). This is the live provider reconciliation path, which must retain observed ordering/corrections; applying the legacy-only shortcut there would be incorrect. Per scope discipline, record it for a separate fix instead of refactoring that reconciler here. The temporary measurement test was removed after the probe.

Self-review caught and fixed a newly introduced actor-initializer capture warning: the recovery reduction now reads a local value copy of the span dictionary, without capturing the session actor. Its inputs and arithmetic are unchanged. The existing unrelated Swift 6 migration warnings remain outside this scope. The suffix-reconciliation test and two extra recovery mutations specifically guard the incorrect alternatives of preserving the aggregate without later work, or adding every reply to it. The final affected-helper build has no warning message absent from the unchanged failing-first baseline. All affected/helper/wire checks are rerun on the final source below; final self-review found no further issue in this diff.

### Validation commands and results

All commands run at the worktree root unless stated otherwise. `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-helper`; `L=$B/logs/round3-hunt`.

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'CompactionTaskRegressionTests.testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen|RetryTests.testCrashAfterToolBoundaryPreservesSavedRetryTime|ResponseTimelineTests.testCanonicalMatchesOriginalAlgorithmForGeneratedParts|ResponseTimelineTests.testFiveThousandLegacyPartsCanonicalizeWithinPagingBudget'
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'CompactionTaskRegressionTests.testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen'
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'RetryTests.testCrashAddsOnlyRepliesJournaledAfterSavedRetryTime'
# Each mutation runs the same swift test prefix with its filter:
# summary: CompactionTaskRegressionTests.testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen
# recovery old / no offset: RetryTests.testCrash
# recovery no suffix: RetryTests.testCrashAddsOnlyRepliesJournaledAfterSavedRetryTime
# canonical: ResponseTimelineTests.testFiveThousandLegacyPartsCanonicalizeWithinPagingBudget
python3 "$B/round3-hunt-mutations.py"
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'CompactionTaskRegressionTests|RetryTests|ResponseTimelineTests|TaskPresentationTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'Compaction|RetryTests|ResponseTimelineTests|TaskPresentationTests|CrashAuditTests|JournalCheckpointTests|JournalCloneTests|JournalSlimmingTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --skip StreamingCostTests
```

- Failing-first: all three assigned regressions fail; generated equivalence control passes. The additional recovery-suffix regression fails separately.
- Mutations: **5/5 caught** by assertions; fixed source restored after each. Repeated all five after the initializer-capture correction: **5/5 caught** again (`final/mutation-*.log`, `python3 "$B/round3-hunt-final-mutations.py"`).
- Focused timing/timeline/task run: **58 passed, 0 failed** (`targeted-fixed.log`; filter also selects IncompleteRetryTests and AgentSteeringRetryTests).
- Expanded affected helper classes: **182 passed, 0 failed**, repeated on final source (`affected-helper.log`, `final/affected-helper.log`), including all compaction, retry, crash, checkpoint, clone and slimming matches.
- Full helper: **1,135 passed, 7 opt-in tests skipped, 0 failed**: isolated `StreamingCostTests` **5/5**, then the remaining suite **1,130 passed / 1,137 discovered**, 7 skipped (`final/streaming-cost.log`, `final/full-helper.log`; the earlier complete pass also passed). The skips are the fork-fixture writer, large-fork benchmark, rapid-scroll measurement and four explicitly configured session open/memory/slimming benchmarks. No unrelated test failed. The final full run also measured the 5,000-part case at **3.42 ms**.
- Preliminary native timeline consumers: **50 passed, 0 failed** (`native-timeline.log`), excluded as final evidence because of the locking correction above. The locked rerun is recorded below.
- Release helper rebuilt successfully after the final-source correction. Wire **40/40**, concurrent **4/4**, acceptance **3/3**, all with **0 failures** (`final/release-helper.log`, `final/wire.log`, `final/concurrent.log`, `final/acceptance.log`).
- Locked native validation: **166 passed, 0 failed**. `TranscriptBugRegressionTests` ran alone: **116/116** (`final/native-transcript-bugs.log`). The repeated timeline group passed **50/50**: ResponseTimelinePresentationTests **13**, TimelineStreamingFastPathTests **2**, TranscriptGeometryCacheTests **7**, TranscriptRowChangeTests **4**, TranscriptTurnFoldTests **24** (`final/native-timeline.log`). `round3-hunt-final-native.py` held the shared full-lane lock across these serial invocations; `final/native-lane.log` records matching acquisition/release. No other workstream’s lock was cleared.

```sh
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
H="$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$H"
python3 scripts/test-concurrent-native-host.py "$H"
python3 scripts/test-native-acceptance.py "$H"
# Holding the shared full-lane lock for the complete native invocation:
PI_BUILD_ROOT="$B" scripts/test-macos.sh \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests \
  -only-testing:PiAppTests/TranscriptGeometryCacheTests \
  -only-testing:PiAppTests/TranscriptRowChangeTests \
  -only-testing:PiAppTests/TranscriptTurnFoldTests
# Alone, holding the shared full-lane lock for this run:
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/TranscriptBugRegressionTests
```


Final source hashes for the six changed Swift files are recorded in `final/source-sha256.json` and match the files being committed. `git diff --check` passes. One existing native build tree and the existing Debug/Release helper trees were reused under this workstream's build root; no extra DerivedData tree was created and no clone folders remain. No explicit result-bundle path was used; text logs are the evidence. No assigned finding remains unresolved. The separate live-provider scaling issue and native lane-classifier gap above are recorded for the lead. Only `dev/a130-helper` is committed/pushed; no merge, fast-forward, release, tag or history rewrite is performed.
