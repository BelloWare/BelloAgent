# Sub-agent steering — app phase 5 validation

Worktree `wt-steer-ui`, branch `dev/subagents-steer-ui`, build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-steer-ui`. macOS arm64,
Xcode 16.1, isolated `com.belloware.PiAppTests.Host`. Generated fixtures and
loopback only; no installed app, owner preferences, Keychain or paid calls.
Text logs under `$PI_BUILD_ROOT/logs` are the evidence; automatic result bundles
are pruned by `scripts/test-macos.sh`. No named result bundles.

## Step 1 — typed presentation and turn ordering

Based on helper `43f9e0d9`. Live and journal readers preserve
`nativeAgentDelivery`; agent inputs have their own attributed native row and do
not create human task roots. V3 control receipts use the native sub-agent card;
accepted background starts remain live. Capture summaries advance by child turn
and revision, without reviving old terminal turns.

- `step1-red.log`: background card and typed-author regressions fail on baseline.
  The capture test initially lacked its SQLite fixture table; corrected before
  `step1-red-capture.log`, which reproduces the permanent-terminal failure.
- `step1-green.log`: 16 passes, 0 failures across
  `SubagentSteeringPresentationTests`, `SubagentTranscriptTests`,
  `SubagentCaptureTests` (bash-array selection).
- `step1-mutation.log`: restoring the permanent terminal guard, dropping live
  authorship and treating a background receipt as an ordinary status each fails
  its regression. All three mutations restored.

V3 execution remains hidden behind the helper's existing single switch.
