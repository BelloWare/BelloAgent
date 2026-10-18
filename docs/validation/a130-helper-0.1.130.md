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
