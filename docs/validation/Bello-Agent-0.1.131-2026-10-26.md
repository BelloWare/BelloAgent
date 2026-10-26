# Bello Agent 0.1.131 — no family communication limit for sub-agents

Status: **released and verified 2026-10-26.** Marketing version 0.1.131, build 135. Previous public release: 0.1.130/build 134. A helper-only hotfix of 0.1.130, cut from `main`; the work planned as 0.1.131 on `dev/next` ships as 0.1.132.

## Owner request

On 2026-10-26 the owner asked what "Family communication limit reached; a new user task or explicit Resume is required" means, then: "nah, remove that limit! and now, release a new version asap, no need to do through review", then "stop all things, release this change asap!" and "you do validation if needed, don't dive too deep, we need to release asap".

## Change

Base `48d05d30` (the 0.1.130 record on `main`), branch `dev/hotfix-0.1.131`.

- Since 0.1.126 the helper paused a chat and its sub-agents with `coordination_limit` once, within one authorization epoch (from the owner's message or Resume to the next), the family reached 64 child turns, 8 follow-ups for one child, 256 two-way messages, 32 messages for one child, or 32 parent continuations for sub-agent reports (`AgentMailboxPolicy.validate`, and the continuation check when delivering reports in `AgentSteeringMessaging`). All of these caps are removed. A family is never paused for how much it communicates; every report delivery to a running parent still counts as a continuation (the counter is kept, nothing reads it).
- Unchanged: the backpressure that rejects a single tool call without pausing anything (64 pending messages per child; 4 pending reports per child and 64 per family; the report rate limit), the request-budget hold when accepted input cannot fit the parent's context (also reported as `coordination_limit`, so the app's "Coordination paused" row and Resume stay), and the chat's cost limit, which still pauses a family that spends past it.
- `docs/design/subagents-steering.md` notes the removal where it specified the caps.
- No app code changed.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1. At the owner's request ("don't dive too deep"), only the helper checks were run: no full gate, no soak, no review rounds, no live test.

- `AgentMailboxPolicyTests` and `AgentSteeringReviewFixTests`: 10/0. The three tests that asserted the caps now assert there are none: 300 alternating parent/child messages, 100 replacement starts (also after a state round trip), and starts and sends after 500 continuations are all accepted.
- Helper suite (`swift test`, StreamingCostTests excluded as in the gate): 1,184 tests, 8 skipped, 0 failures.
- `scripts/test-subagent-streaming.py --steering --modes loop` against the Release helper: passed. Its parent replaces its child after every result; it now runs past the old cap to 41 child conversations and 41 parent deliveries (0.1.130 paused at 32 with `coordination_limit`) and ends without that error. Only writing its JSON summary failed, because `$PI_BUILD_ROOT/logs` did not exist.
- Wire 40, concurrent 4 and acceptance 3 against the Release helper: passed.

## Known

- Nothing bounds how long a family may keep its sub-agents working except the chat's cost limit ($25 unless changed in Settings or on the chat) and Stop; a chat set to No limit can loop until stopped.
- The release gate and soak were not rerun; the app is 0.1.130's apart from its version and the helper inside it.

## Release

- Release commit `275b442c` ("Release Bello Agent 0.1.131"), tag `v0.1.131`, on `main` (the merge `ed7ee31b` of `dev/hotfix-0.1.131`, fix `6a35f555`).
- `BelloAgent-0.1.131.dmg`, sha256 `c39f83add7486023f83b54f6e5418552b7dace57386d93077feb2f0cff593568`, 16,703,964 bytes; Developer ID signed and notarized (app submission `f8978880-14d4-490f-91dd-513d35059544`, DMG submission `3ed73c19-241b-4882-91d3-9f28d8f420fc`, both Accepted), stapled.
- `validate-release.py --previous-build 134`: passed (0.1.131 build 135, Ed25519 signature verified).
- Website commit `d8e39cb` (belloware.com `main`).
- `verify-published.py`: the public DMG matches, and the Bello Agent and legacy Pi App feeds are byte-identical (on the third try, after the site deployed).
