# Bello Agent 0.1.121 — no editing-tool locks

Status: **candidate; publication pending.** Marketing version 0.1.121, build 125. Previous public release: 0.1.120/build 124.

## Owner request

On 2026-10-08 the owner asked to "remove the editing tool locks, so that we don't try to prevent editing requests hitting each other", and to release as soon as possible. Offered three choices, they chose **"Remove everything"**: no locks at all, even two edits of the same file in one reply. This is an approved deviation from pi 0.85.1, which serializes mutations of a file.

## Scope (helper only)

- The shared workspace editing gate is gone: chats no longer take turns to run write, edit, bash or MCP invoke.
- One reply's tool calls all run together; editing calls are no longer run one after another. Results still join the context in call order.
- Edits and writes run on the blocking-work pool like reads, instead of inside the tools actor, so they overlap for real. A call refused because the pool is full (`tool_busy`) is recorded as failed, not unknown.
- MCP invocations no longer share a gate; a configuration change waits for running invocations (cancellably). The last invocation to end clears the outcome marker when no outcome is unknown. The MCP tool's description no longer promises serialization.
- A Stop during argument preparation is recorded as not executed again.
- Known consequence (in the release notes): two concurrent edits of the same file may overwrite each other.

Source: `8b7cd952`, `3d4f0f8a`, `f4b481bc`, `45095073` on `dev/next`. No app code changed.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- Helper suite: **619 executed, 6 skipped, 0 failures**.
- Wire scripts on a fresh Release helper: 34, 4 and 2 tests, all OK.
- App classes that drive tools through the real helper (CostLimit, HistoricalEditing, ResponseChronology, SessionTiming, ToolCallSummary, MCPRemoval): **70 tests, 0 failures**.
- New tests, each failing on the previous code: one reply's edits overlap; edits and writes wait for a worker rather than running in the actor; MCP invocations overlap; the last MCP invocation clears the marker (barrier-ordered); an edit refused for want of a worker failed; stopping some chats mid-edit leaves the others editing.
- Codex (gpt-6.1-sol, xhigh, read-only): four review rounds; findings (actor-serialized edits, the MCP gate, a lost cancellation check, a weakened test, `tool_busy` outcomes, a stale MCP marker, an uncancellable drain, the MCP description, a timing-based test) all fixed; the final round had no findings.
- **Not rerun, by the owner's "ASAP" and because only the helper changed:** the full gate (`verify-release.sh`) and the hour-long soak. The last full gate and soak ran on 0.1.120's code (see its record). The owner's VoiceOver and real-gateway checks remain deferred. Install/update rehearsals skipped under standing policy.

## Publication

Pending.
