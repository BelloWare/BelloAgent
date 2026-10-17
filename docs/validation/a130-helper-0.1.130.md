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
