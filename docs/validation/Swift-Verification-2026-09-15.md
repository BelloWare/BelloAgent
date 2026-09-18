# Swift verification — publication pass, 2026-09-15

Environment observed: Linux x86_64; Swift 6.2.1 (swift-6.2.1-RELEASE), target x86_64-unknown-linux-gnu.

Recovered source: the 28-file payload in pi-app-swift-handoff.zip matched its SHA-256 manifest. The native-core Git tree is `e0c71ba565006ea020b3c3a60ee30312a198b8b1`; the core-test blob is `1988ca5c6d832a8527752215803bd9e336d1a9f3`; the black-box test script blob is `0f677497350b141516bebe36db18b426b2708ec6`. Documentation corrections do not change that tested source.

## Unit/debug build

Command from the recovered payload root:

```sh
swift test --package-path packages/swift-host
```

Observed XCTest result:

```text
Test Suite 'CoreTests' passed at 2026-09-15 09:35:05.787
Executed 22 tests, with 0 failures (0 unexpected) in 2.724 (2.724) seconds
Test Suite 'debug.xctest' passed
Executed 22 tests, with 0 failures (0 unexpected)
Test Suite 'All tests' passed
Executed 22 tests, with 0 failures (0 unexpected)
```

The debug helper was compiled as part of this command. The additional Swift Testing footer of zero tests is expected for an XCTest suite; it does not negate the 22 executed XCTest cases.

## Executable integration

```sh
python3 scripts/test-native-host.py packages/swift-host/.build/debug/pi-native-host
```

Observed results:

```text
test_cancellation_keeps_queued_message_paused ... ok
test_command_identity_is_not_replayed ... ok
test_connection_test_exposes_no_tools ... ok
test_http_error_and_incomplete_stream_are_not_completed ... ok
test_mcp_stdio_and_http_schema_batch_single_invocation ... ok
test_messages_real_stream_and_max_tokens ... ok
test_responses_real_stream_tool_roundtrip_and_capture ... ok
test_side_keep_and_resume ... ok
Ran 8 tests in 3.783s
OK
```

These use local HTTP fixtures and a stdio child process. There were no live provider calls or release side effects.

## Not performed here

- Optimized release rebuild/retest in this publication pass (older reports exist in the recovery archive).
- macOS/Xcode typechecking, native UI tests, Darwin process-group acceptance.
- Signed-app Keychain access-control validation.
- Real LiteLLM configuration/auto-router/provider acceptance.
- macOS signing/notarization, release publication, DMG build/size measurement.
- F13–F17 feature tests: those features are still pending, as documented.

Passing these tests is evidence for the tested native subset only, not completion of every owner requirement.
