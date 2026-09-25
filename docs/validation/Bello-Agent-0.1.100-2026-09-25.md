# Bello Agent 0.1.100 — intact-context compaction

Status: released and publicly verified, 2026-09-25 04:32:16 UTC.
Starting main SHA: `8ae9c5713e1ac74e5471015107257784bf5a0ae3` (0.1.99/build 103).
The owner's revised **Compaction-Implementation-Plan _1_.md**, September 25,
supersedes the former Pi transcript/excerpt path. The owner separately requested
publication, overriding the plan's statement that publication is not required.

## Changes

- `CompactionSourceBuilder`, `ResponsesInput`, `Providers`, `SessionSummarizer`:
  ordinary typed input plus one appended checkpoint instruction; identical leading
  instructions, tools, effective reasoning and cache affinity; final no-tool/cap
  controls; no alternative serialization or summarizer strategy.
- `CompactionPlanner`, `SessionCompaction`, `SessionRun`: plan the retained boundary
  before dispatch, reserve summary generation and growth headroom, validate the
  final wrapped candidate, and adopt only after durable synchronization. No idle
  post-answer compaction or regeneration of an output-limited ordinary answer.
- `RequestContext`, `ChatMessage`: projected request estimates and persisted usage
  binding for matching model/prefix/schema/replay configuration. Ciphertext is
  not treated as text tokens. These remain estimates, not exact provider counts.
- `Sessions`: remember failed automatic source fingerprints. Checkpoints depend on
  every message seen; replaced-source IDs remain separate from retained inputs.
- Explicit skill selections from the current task stay authoritative after later
  steering; an incompatible old usage baseline falls back to an estimate without
  falsely presenting the chat as newly compacted.
- Native request inspector: identify the new continuation instruction while keeping
  historical capture classifications readable. No UI redesign.

## Test coverage

| Plan cases | Evidence |
| --- | --- |
| T01–T03 | Request-shape tests preserve tools/reasoning/images/cache, reject conflicting sampling; real HTTP fixture returns write and MCP calls despite `tool_choice: none`, with zero dispatch and no adopted checkpoint. |
| T04–T05 | Replay-group and split-turn tests cover repeated call IDs, retained results, focused and repeated compaction, and no resurrection of pre-checkpoint messages. |
| T06–T09 | 32K/128K/1M allowances, tiny-window rejection, full-source overflow with zero HTTP calls, actual wrapper counting, incomplete/refused/empty/oversized/tool-calling results, bounded identical transient retries. |
| T10–T11 | Provider/replay tests preserve eligible encrypted items and image values, retain portable/ask/pinned distinctions, and reject unsupported images before summarizing. |
| T12–T13 | Queue/Stop tests, twenty concurrent compactions, injected journal append/sync failures, and cancellation immediately after durable adoption. |
| T14–T16 | Editing seen retained input invalidates its checkpoint; journal restoration/fork tests preserve active context; HTTP recovery fixture proves a mutation runs once, captures all bytes and retains chronological attempt accounting. |

## Synthetic captured shapes

The request-dependent loopback gateway uses synthetic credentials and content.
These files contain request bodies only, with no credential headers:

- [Ordinary request](fixtures/compaction-0.1.100/ordinary.json)
- [Full summary request](fixtures/compaction-0.1.100/summary.json)
- [Next request after adoption](fixtures/compaction-0.1.100/next-request.json)
- [Restored request projection](fixtures/compaction-0.1.100/restored.json)
- [Forked request projection](fixtures/compaction-0.1.100/forked.json)

The integration test compares complete captured HTTP bodies, including request
bodies spanning multiple capture pages. It reopens and forks the journal and
checks that no tools run during restoration. These establish construction and
persistence, not semantic summary quality or real prompt-cache hits.

## Commands and results

- `PI_BUILD_ROOT=…/native-master scripts/verify-release.sh`: the complete gate ran
  in 17m32s. Two native cases and one helper case initially failed: the native
  stress fixture did not leave room for intact-context summarization and expected
  idle post-answer compaction, the manual-command test expected the old focus
  wording, and the context test expected the old heuristic warning. Their fixtures
  and assertions now exercise the new behavior; no production fit or progress
  checks were weakened.
- Final `swift test --package-path packages/swift-host --scratch-path
  …/native-master/swift-verify`: **443 tests passed**, 0 failures, 62.219s. Includes
  the additional in-flight resource-change and steering/skill regressions.
- Rebuilt the native app/tests, then ran `xcodebuild test-without-building
  -parallel-testing-enabled NO` for `CompactionResponsivenessTests`,
  `ManualCompactionTests`, `InspectorSummaryRequestTests` and
  `ReleaseConfigurationTests`: **11 passed**, 0 failures, 22.921s. The long-chat
  fixture performed manual and automatic compaction while its window remained
  responsive. Combined with unchanged passing cases from the complete native
  gate: **1,618 unique native cases passed, 22 optional cases skipped**.
- The full synthetic native gallery passed and produced **112 screenshots**.
  Gallery images stayed in the session scratch directory.
- Final transport/script checks against the rebuilt production helper all passed:
  `scripts/test-native-host.py` (**32**, 31.637s),
  `scripts/test-concurrent-native-host.py` (**3**, 13.126s),
  `scripts/test-native-acceptance.py` (**2**, 2.584s), and
  `PI_BUILD_ROOT=… python3 -m unittest discover -s scripts/tests` (**66**, 21.685s).
  The Python suite includes the three-scenario reasoning-gateway rehearsal and
  the deliberately exhausted 8,192-token summary case, which must fail safely.
- `git diff --check`: clean. Normalized synthetic shape files parse as JSON and
  contain no credential headers. No app installation or updater rehearsal ran.
- Live gateway environment probe: required `PI_LIVE_BASE_URL`, `PI_LIVE_API_KEY`,
  `PI_LIVE_MODEL` are not configured. Real LiteLLM cache-hit/latency/cost comparison
  and repeated-checkpoint semantic quality benchmarking remain **unrun**. No live
  provider performance or quality improvement is claimed.
- Fresh install and updater/relaunch rehearsals are omitted at the owner's request.

## Release provenance

- Version **0.1.100**, build **104**, arm64 macOS 14+.
- Built from source `dd1e8ffa3e60331e09978a42f9df834717d9bfff` on main.
  Native tree `aebcc00c35d566b1dcfdf34f59e07bfac19eb5b5`; helper tree
  `a7856c7ccde96adb12d569ceca9493f57ee0c2a7`. Only provenance documentation
  changed after packaging. Source is committed locally under the existing
  release policy; this request did not separately request a source push.
- Optimized build, packaged helper smoke, Developer ID signing, notarization,
  stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations:
  app `ad3166a4-1439-4659-9d42-9afb2c533518`; installer
  `c1e93612-b816-49c2-9ae2-cc22e0161ed0`.
- Website publication commit: `ed40835730d1e21236009febc639e712da504f1a`, pushed.
- Public verification at **2026-09-25 04:32:16 UTC**: product page advertises
  0.1.100, canonical and legacy feeds match byte-for-byte, downloaded installer
  matches the local SHA-256 and passes Ed25519 verification. Initial reads
  during deployment still served 0.1.99; verification was repeated after rollout.
- Installer: **10,847,251 bytes** (10.34 MiB), SHA-256
  `85ee93b880b9d0d4fe2fcada1b06f101e55d95d7fc5dac7dde7dabd69218db48`.
- [Download Bello Agent 0.1.100](https://belloware.com/assets/BelloAgent-0.1.100.dmg).
