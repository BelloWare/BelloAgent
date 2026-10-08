# Agent tool timing: actual cloud GUI observation

Date: 2026-10-08, 21:13–21:25 UTC.
Source: BelloAgent `ca6136b57ee6f3bce84ab67ae0a12559bbfa51ca`, tree `0f5fe28e3249a0526c46bde220c152ad8eb8c0a4`.
All 2,194 tracked source files matched the immutable commit byte-for-byte before build. No repository source or remote writes were made.

## Build and scope

Command: `cargo build --locked -p bello-agent-app --features synthetic-authority`.
This is an ordinary unoptimized debug application with the existing explicit synthetic-authority feature, not a test executable. Build succeeded using the verified isolated Rust 1.99.0 and GPUI prerequisites. Binary SHA-256: `ce913208f021a255603d0ad965b9b356e50d109586e75fe097d9a743512336f4`.

Actual CUA mouse and keyboard interactions ran on the cloud Linux desktop with software Vulkan. The app launched with `--synthetic-connections --synthetic-attachment-fixture PROFILE --project GENERATED_PROJECT --session GENERATED_SESSION`. HOME/XDG/cache/tmp were isolated. The profile and MCP endpoint used numeric loopback `127.0.0.1:47891`, fixed fake credentials, and generated disposable files. No production native tool/vault gates, real credentials, user Mac, paid provider, or personal data were used.

## Passed interactive path

1. Opened Projects, reviewed the generated folder, and explicitly created/trusted the memory-only synthetic project. Screenshot 01 shows Trusted and Memory-only fixture.
2. Loaded the seeded synthetic connection through Settings, closed Settings with Done, reopened the connection picker, and selected the fixture.
3. Typed and sent `A5_HELLO` through the real composer. The loopback server received one request and no tool call; the visible assistant answered normally.
4. Opened MCP Inspector, entered the generated JSON and fixed fake header in its masked field, reviewed the endpoint warning, and explicitly saved/applied. Screenshot 02 shows successful save and no tool invocation.
5. Sent `A5_REVERSE` through the composer. The real client started Bash and MCP; fixture state and the generated Bash entry marker established both entered. Screenshot 03 shows Bash Running and MCP Awaiting result.
6. Released MCP alone through its generated marker, leaving Bash held. Screenshot 04 shows MCP Completed with 12s duration while Bash remains Running. Session Tool time remains 0.0s. The captured durable session at this point contains zero tool result rows and total_us=0; no premature provider continuation occurred.
7. Released Bash. Screenshot 05 shows Bash Completed 38s, MCP Completed 12s, and session Tool time 38s, followed by the model continuation. The fixture recorded exactly one MCP call and one continuation with original Bash→MCP result IDs.
8. Captured schema-9 session: batch wall_us=38,148,589 and session total_us=38,148,589. Individual durations are Bash38,148,498 and MCP12,286,853. Cumulative time is one batch wall observation, not their sum. These are deliberately held fixture durations, not performance benchmarks or speedups.

## Failed reopen / acceptance boundary

The settled window was closed with its native window close control; the process exited0. The same exact binary and saved fixture root were launched again. The app reported `Saved chat is unavailable: The saved project identity and original root disagree` and rendered a blank window (screenshot06). That window was closed cleanly afterward. Memory-only synthetic authority is relevant context and a plausible limitation; this run did not prove the underlying cause.

The durable total remained38,148,589 and the complete fixture request log stayed byte-identical across relaunch. These are persistence/nonexecution observations only. Successful reopened GUI/no-recount acceptance was **not** achieved. Same-process controller retirement/reopen was not exercised. No catalog or authority data was injected or altered to bypass the identity gate.

## Input/setup limitations preserved

- A shell-session fixture server was initially started outside the desktop process namespace. A separate shell status request returned connection refused despite its listening log; it was stopped. The final server and app were launched together in the cloud Terminal, with the wrapper owning server cleanup.
- Some direct clicks required a later screenshot to observe redraw. Project and MCP controls ultimately activated with explicit desktop pointer movement and clicking.
- The fixture README's initial picker route was incomplete: first opening loaded Settings; Done and a second opening reached the populated connection picker.
- Bound app character-key attempts did not insert composer text. Sky desktop `press_key` events did. Sky `type_text` was unavailable for this GPUI X11 window (AT-SPI provider error). No alternative input technology was used.
- Escape did not dismiss connection Settings in the attempted state. A subsequent coordinate intended for the composer instead opened Delete Connection review. Keep dismissed it; the synthetic connection was not deleted. Done then closed Settings.
- Ctrl+Q did not close the settled window in this check. The native window close control did.

This bounded actual GUI timing path does not establish complete candidate acceptance, the separately reported CI MCP Inspector regression, all first-16 limits, cancellation/recovery permutations, native macOS/TCC/AX/Keychain/signing, frame performance, or release readiness. Existing unit/integration evidence is separate.

## Evidence

`source-verification.json` contains the immutable source manifest. `build.log`, `build.exit`, and `build-command.txt` record build conditions. `run-evidence/` preserves original PNG screenshots, real request receipts, operator release log, session snapshots, fixture state, sealed binary identity, app logs, and `verification.json`. `fixture.py`, `launch.sh`, and `fixture-config/` preserve reproduction inputs. Original screenshot bytes were copied without modification.

The cloud desktop was verified free of Agent windows at21:25 UTC. No source/remote edits were made.
