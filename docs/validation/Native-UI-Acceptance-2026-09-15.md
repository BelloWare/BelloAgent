# Native Mac UI acceptance — 2026-09-15

These are actual CUA interactions with the SwiftUI/AppKit workspace, native
composers and WKWebView transcript. Requests went through the packaged Swift
helper to `fixtures/native/ui-gateway.py`, a deterministic loopback server. No
production Keychain item, real LiteLLM deployment or paid model was accessed.

The opt-in window is implemented only in the XCTest bundle by
`NativeUIAcceptanceTests.swift`. It injects the test bundle's `MemoryVaultStorage`
and displays a permanent **SYNTHETIC LOOPBACK FIXTURE** banner. The production app
has no fixture startup switch or unsigned-vault fallback. The harness creates
two synthetic connections, explicitly selects portable reasoning replay, and
retains encrypted request bodies under its scratch directory. The ordinary test
suite skips this interactive test unless its explicit environment variable is
set.

## Environment and commands

- macOS 14.8, Apple silicon, Xcode 16.1, Swift 6.0.2.
- Branch `master`; first UI build used `c125595` plus the in-progress native
  dashboard/routing source. The second build used `5b22d8b` plus the interactive
  harness and final native UI edits. Both used the staged optimized Swift helper,
  not Node/Pi. The second pass included `timingVersion: 2` and model provenance.
- Separate derived data: `$PI_BUILD_ROOT/ui-xcode`. Logs and synthetic data remain
  in the session scratch directory, not the downloadable output folder.

```sh
# PI_BUILD_ROOT must already contain the current staged bundle. Do not rebuild
# that staging directory concurrently with the embed-runtime build phase.
xcodegen generate
export PI_APP_UI_ACCEPTANCE_ROOT="$(mktemp -d "$PI_BUILD_ROOT/ui-fixture.XXXXXX")"
export TEST_RUNNER_PI_APP_UI_ACCEPTANCE_ROOT="$PI_APP_UI_ACCEPTANCE_ROOT"
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/ui-xcode" \
  -only-testing:PiAppTests/NativeUIAcceptanceTests CODE_SIGNING_ALLOWED=NO
```

Use CUA on the `ui-xcode/Build/Products/Debug/PiApp.app` path; multiple historical
Pi App bundles have the same bundle identifier. The test writes `ready.txt` with
the loopback address. Complete the GUI exercises below, including at least one
request through each API, then create `$PI_APP_UI_ACCEPTANCE_ROOT/finish` from
another shell. The test stops its helper/server and saves `captures.json` and
`verification.json`. Use a fresh directory on each invocation. No sleep or
automatic timeout is interpreted as successful UI acceptance.

## Observed GUI results

The first pass completed one interactive XCTest in 467.250 seconds
(`ui-acceptance-build-4.log`): 14 fixture requests, 10 Responses and 4 Messages,
with 2 cancelled connections.

| Workflow | Observed result |
| --- | --- |
| Native composer | Pasted `中文🙂 café` intact; Shift-Return added a newline; selected-word replacement worked; Undo removed its grouped edit and Redo restored it; Return submitted the native draft. CUA's simulated `typeText` did not enter non-ASCII characters reliably, so Unicode was verified using paste. |
| Responses and Messages | Each connection sent text and completed a native `read` tool round trip. The transcript displayed the exact synthetic README contents and final assistant reply. |
| Streaming and scrolling | A 100-section Markdown response streamed while a Unicode draft remained editable. Scrolling up kept the viewport away from the bottom as the response grew; the scroll fraction decreased from about 0.546 to 0.122 rather than jumping to 1.0. |
| Independent side | Opened while the parent streamed; partial assistant output was absent from the side snapshot. The side sent and completed independent questions while the parent still streamed and had queued work. Its composer remained enabled with read-only tools. |
| Side keep/handoff | Edited Bring Back text was inserted into the parent draft without sending. Keep created a separate saved read-only sidebar chat; closing the panel preserved that chat. |
| Queue and steering | Normal Return while busy queued a follow-up; explicit Steer created a separately labeled steering entry. Stop paused both. Remove deleted the follow-up. Resume delivered the remaining steering once. |
| Helper loss/recovery | The test-only Stop Fixture Helper action stopped the real child process. UI showed `interrupted`, an uncertain-outcome notice and the paused pending follow-up. Explicit Resume reopened the helper and delivered the pending input once. |
| Search/copy | Native search found `paragraph 99` in the full retained 100-section response. Copy Range for message 1 reported 10 UTF-8 bytes; normal Paste inserted that exact message into the composer. |
| Every-message Requests | The Messages tool-result Requests button opened two related attempts. Inspector showed original 809-byte SSE, redacted authentication headers, eight retained event offsets and four message relationships. After helper exit, the same original response body remained readable from native storage. |

The second pass completed one interactive XCTest in 280.488 seconds
(`ui-acceptance-final.log`). It made 5 GUI-driven requests through both APIs and
verified **10 retained bodies** against the server's actual request/response
bytes. Completed bodies matched exactly; the interrupted response was checked as
an original byte prefix.

| Dashboard / routing workflow | Observed result |
| --- | --- |
| Durable counts and samples | Four successful tool-cycle requests appeared with four observed samples for each metric and visible p50/p99 values. No legacy records were included. |
| Filters | Messages + requested alias `ui-fixture` + No resolved model reduced the result to two requests and two samples. |
| Exact drill-down | A row's Inspect button opened its exact attempt, including distinct dispatch/content/model-terminal/HTTP-end timestamps and `timingVersion: 2`. |
| Alias provenance | Inspector retained `message_start.message.model = ui-fixture` as evidence, kept `requestedAlias = ui-fixture`, and correctly displayed `status = unreported` / no effective model. The explicit portable replay policy was visible. |
| Cancellation and nulls | After cancellation, the default Completed view counted 5 total / 4 completed / 1 cancelled while showing 4 successful latency samples. Selecting All statuses showed 5 TTFT / 4 streaming / 5 HTTP samples; the cancelled row's streaming duration was `—`, not an invented zero. |

The final pass used the staged helper containing the `31c1d7b` restored-tool
correction and the current native dashboard/inspector source. It completed one
interactive XCTest in **233.079 seconds** (`ui-acceptance-releasecheck.log`),
made **5 requests**, and verified **10 retained bodies** exactly. Both APIs again
completed read-tool round trips. After helper shutdown and a new native send,
the historical read summary remained **completed** instead of reverting to
prepared. Message links displayed **Retained 6 message links**, correcting the
unit. Dashboard showed five retained dispatched requests and five samples after
helper reopen. The final compressed synthetic dashboard screenshot is
`pi-app-native-preview.jpg` in the session output folder (139,589 bytes).

## Corrections found and remaining limits

The first build attempts exposed concurrent-source snapshot/link problems and
Swift comma-declared `@State` fields; these were fixed before the passing UI
runs. CUA found a message-link footer incorrectly labeled in bytes and restored
tool summaries incorrectly returning to `prepared`; the final pass above verified
both corrections after targeted source fixes and regression tests. Dashboard
status wording was also reported for clarification about its time series.

This harness hosts the real workspace view, but the application's global menu
commands belong to its separate test application model. Pane menus were used;
global keyboard menu routing was not certified by this harness. Actual language
IME candidate composition was not exercised: existing native marked-text tests
cover the Enter guard, and Unicode paste is separately verified above.

This is an initial GUI acceptance pass, not the entire handoff matrix. Numeric
input-to-paint/process-tree performance, model/tool-phase stress at maximum
limits, all Skills/MCP native panels, full OS application relaunch, signed-vault
identity isolation, a deployed authorized LiteLLM contract, release signing and
complete signed DMG size remain distinct gates. The independent core,
executable, storage and packaged-helper suites cover additional cases; do not
substitute this manual test for those suites or for external acceptance.
