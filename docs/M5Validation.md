# M5 local acceptance and release evidence

Updated 2026-09-15. M0–M4 functional evidence remains in their validation
files. All F01–F10 implementation areas have automated or native walkthrough
evidence below. The measured performance targets pass on this VM. VoiceOver
speech/caption output could not be observed through the remote controls; that
manual accessibility check remains open. Final 0.1.0 signing evidence is recorded
below. The public feed still serves the verified
0.0.2 dummy until a large-installer download destination is supplied.

## Environment and method

macOS 14.8, arm64 VirtualMac2,1, Apple M3 Max (Virtual), 16 GiB RAM; Xcode
16.1 / Swift 6. Release (`-O`) app, Developer ID signatures, actual bundled
Node 24.21.0 and patched Pi 0.85.1. Synthetic loopback fixtures use both actual
Pi provider adapters, without paid model traffic. Normal app state is isolated
from benchmarks using the opt-in BenchmarkStateRoot/BenchmarkOutput defaults.
BenchmarkOutput, BenchmarkStateRoot and the temporary idleGraceSeconds value
were removed after measurements. Original Light appearance and VoiceOver Off
were restored; the existing caption-panel preference was left unchanged.

`scripts/prepare-native-benchmark.py` creates 100 different Pi v3 histories,
10,000 messages / 4,839,995 bytes each. `native-benchmark-server.mts` serves
1 MiB Markdown answers, two simultaneous streams, and 11 requests containing
16 MiB unknown SSE records with ten actual Pi read-tool round trips.
`measure-app.py` samples native + descendant Node + newly created WebKit RSS
and CPU. Unrelated fixture/browser processes are excluded by a pre-launch PID
baseline. No browser work occurs during measurements. RSS sums can count shared
pages twice; one-second samples may miss shorter peaks.

Native edit timing starts at the NSEvent timestamp and ends after NSTextView
draw; Send is excluded. Main/side tests use 240 individual key events per
composer, with both Stop buttons visibly active (480 events per API run). Batched automation `typeText`
was unsuitable for latency measurements because it queued events faster than
they were delivered. Coalesced draws retain the oldest pending event timestamp.
Foreground timing starts at the oldest unsent Pi content delta, with calibrated
host/native monotonic clocks. The final visible-paint value ends at a WebKit
post-frame task, mapped using the best of five clock round trips and including
that WebKit uncertainty. The original native acknowledgment measurement remains
separate. Final host uncertainty was 0.1375 ms; WebKit at most 0.1359 ms. This
does not measure physical display scanout. The
renderer has at most two unpainted snapshots and one conflated dirty marker.
Completed and active previews remain bounded; latency samples cover actual
changes within those previews, not the undelivered remainder of truncated text.

## Recorded performance

| Scenario | Evidence | Status |
| --- | --- | --- |
| Cold native shell | 0.53–0.68 s across instrumented Release candidates | <2 s |
| 100 large archives | p50 196.39 ms, p95 236.17 ms, p99 246.29 ms; first cold WebKit viewport 962.95 ms | All 99 selections after the first ≤246.29 ms; no Node |
| History memory plateau | Mean 375.84 MiB, peak 416.61 MiB; last 30 samples mean 414.20 MiB | One reused main webview after 100 different 10,000-message histories |
| Two Messages streams, final 384 MiB heap | 73 active-window samples / 75.33 s: mean 776.39 MiB, peak 796.27 MiB | Within 800 MiB sustained / 1 GiB peak |
| Two Responses streams, final 384 MiB heap | 73 samples / 75.40 s: mean 720.73 MiB, peak 810.23 MiB | Within the same budget |
| Messages native typing | 480 draws/events: p50 2.29 ms, p95 6.61 ms, p99 8.20 ms | <50 / 100 ms |
| Responses native typing | 480 draws/events: p50 2.29 ms, p95 6.22 ms, p99 7.54 ms | <50 / 100 ms |
| Messages visible paint | 126 changed snapshots: p50 36.46 ms, p95 48.15 ms, p99 58.94 ms | <75 ms p95 |
| Responses visible paint | 124 changed snapshots: p50 36.71 ms, p95 50.02 ms, p99 52.21 ms | <75 ms p95 |
| Native acknowledgment upper measurement | Messages p95 48.02 ms; Responses p95 50.65 ms | Reported separately from visible paint |
| Forty large native turns | 20 per API; 133,248,880 raw response bytes; 289 samples: mean 635.58 MiB, peak 752.81 MiB; last 60 mean 684.58, last 30 mean 698.23, final 675.42 MiB | Plateau with the intermediate 512 MiB heap; every turn completed in one native/host lifetime |
| Native capture exhaustion | 11 Messages requests / ten read-tool calls, >176 MiB raw traffic; peak 989.89 MiB, settles near 590 MiB | Original full-capture scenario passes the 1 GiB peak budget; older bodies visibly evicted |
| Final post-stream idle | 67.02 s, aggregate CPU 0.0448% of one core; mean 610.51 MiB RSS | <1% CPU |
| Final recording overhead, Responses | 1 MiB turns, four warmups + 24 alternating Off/Memory runs; median overhead 2.28% | ≤5%, 384 MiB heap |
| Final recording overhead, Messages | Same method; −2.09% (measurement noise) | ≤5%, 384 MiB heap |

The final native timing/paired-stream code is commit `f144c8d`; version 0.0.3
(build 3) was used for these instrumented candidates. 0.1.0 changes the version
and release message, with the same tested application behavior and runtime pins.
History/capture-exhaustion tests predate the last native scheduling/heap changes;
the report does not represent every scenario as a single execution of one build.

Earlier results are retained as failed measurements, not averaged into the final
ones. Initial repeated turns exceeded the peak budget (1,074.42 MiB after twelve
Responses turns). A 512 MiB old-space bound fixed the forty-turn plateau, but a
later warm paired Messages run still averaged 842.62 MiB. The final manifest uses
384 MiB old space / 8 MiB semi-space. Both final paired runs meet the original
800 MiB budget. These are heap settings, not an RSS cap or silent capture limit.

Earlier native typing p95 values ranged roughly 48–64 ms, and acknowledged paint
p95 reached 91 ms in a late candidate (over one second before the main layout
fixes). Draft/metric publication isolation, bounded frame conflation and immediate
native edit redraw address real work. Automation event-dispatch delay also varied
substantially (roughly 20 versus 40 individual events/second); the lower final
numbers are not attributed solely to the heap change. A real-machine/VoiceOver
follow-up remains useful; no universal framework memory/battery claim is made.

The host overhead benchmark measures incremental body retention against Off;
both modes still perform metadata/transport observation. With final heap flags,
both Pi adapters repeat large turns through capture-budget exhaustion: Responses
41 captures / 11 evictions, Messages 77 / 12. Retained bytes are respectively
131,834,760 and 131,196,910. All newest request/response hashes match independent
fixture bytes; normalized model output remains the full 1 MiB. Both also exercise
two simultaneous sessions and an actual 50 MiB bash output file, checking Pi's
model-facing truncation independently of UI previews. Standalone process RSS
includes its in-process fixture and must not substitute for native/WebKit/Node
aggregate measurements.

The forty-turn native run completed before macOS recorded a normal app exit
following Dock interaction, with launchd status 0 and no new crash report. Five
later native turns occurred after restart and are excluded from that continuous
run. The exact-body exhaustion proof above and final host suite are independent.

`report-native-benchmark.py` uses total observation counts, not retained-array
length differences. If a bounded array rolls over, it labels the result
`retained-tail`. All final input/paint samples are fully retained. Lower-level
snapshot timing may have partial coverage and is not used for the acceptance
percentiles. Memory windows end at the fixture's final completion, excluding
later idle samples. No build or other app automation runs during each timed phase.

## Functional and security checks

- 115 host tests, 34 native tests and 11 script tests (nine release/signature,
  two benchmark-report cases) pass; strict TypeScript and Swift warnings-as-errors
  pass. A native test starts the bundled Node through HostSupervisor and verifies
  the actual V8 arguments/heap limit. The pinned
  Anthropic CR/LF parser defect and exact source hashes are documented in
  Compatibility.md. One-byte stream tests preserve raw transport equality.
- Native Search and Copy Conversation finds message 124 in a 10,000-message
  unloaded archive and copies the selected 167-byte readable range. The host
  routes work on both APIs without another provider request. Search results
  can load an older bounded transcript page. Revision changes reject a mixed
  copy before the clipboard changes. Opaque signatures/image bytes are omitted
  explicitly; larger copies require explicit ranges beyond 8 MiB.
- Actual capture exhaustion: newest Messages response 16,781,373 bytes,
  SHA-256 `70f63b025fb9245e0d44cbb1ee59cb3a0ee4a05c171e5bd6acaf649f041bfee1`;
  newest request 12,264 bytes,
  SHA-256 `827bb86edc5f0d1a56b6177a196bba61fcfa331ab4574d4b55bc40cdba264ca8`.
  Both match the independent server. Inspector retains 117,615,279 body bytes;
  older entries report `evicted` / `workspace-memory-budget`. A large unknown
  event exceeds the bounded semantic observer, but its exact raw bytes remain
  complete; observer coverage and raw-body completeness are separate.
- Capture Off survives a full native/host restart. The first new request
  observes 12,444 request bytes / 2,079,620 response bytes but retains zero;
  both bodies report `disabled` / `capture-off-at-dispatch` in the inspector.
- Last-window close refuses to hide active/unkept work; Quit explicitly offers
  stop/discard. The update barrier rejects new work, drains accepted native
  persistence, quiesces actual host lanes, and waits for process exit before
  Sparkle installation. Unit tests cover busy rejection and unsent drafts.
- Exact local main-document/origin/view identity checks reject remote/file
  navigation tricks. No executable Markdown URLs, raw HTML, or remote images.
  Code highlighting uses escaped output from six pinned bundled grammars,
  deferred execution, bounded cache/block sizes, and no auto-detection/network.
- Native menus expose core actions and Cmd-F opens full-history search.
  Native/side composer labels, message roles and tool states are visible in
  the accessibility tree. VoiceOver was enabled for bounded-page inspection;
  speech/caption output could not be observed through the remote control tool,
  even with VoiceOver running and the caption preference enabled. This remains
  an open manual accessibility check; AX labels alone are not claimed as proof
  of spoken navigation. Both system
  appearances were inspected and original Light/VoiceOver Off restored.
- npm audit reports one low-severity development-only tsx/esbuild Windows
  development-server advisory (GHSA-g7r4-m6w7-qqqr). The app has no development
  server and ships on macOS; the pinned build esbuild is 0.28.2. No automatic
  dependency upgrade was applied to conceal the lockfile finding.

## F01–F10 acceptance map

| Requirement | Evidence |
| --- | --- |
| F01 Native workspace/composers/sessions | M1 durable intent/queue/recovery tests; M4 independent Stop/Keep/Undo native walkthrough; M5 draft isolation, anchors, last-window and update barrier tests |
| F02 Both provider APIs | M0 exact fixture matrix; M2 profile/endpoint/max_tokens/image/continuation checks; final packaged provider smoke test |
| F03 Streaming presentation | Unicode/CRLF/unfinished Markdown/tool-card tests; bounded safe highlighting; native full-history search/copy and corrected Latest/sidebar walkthrough |
| F04 Context usage | Pi-owned context/compaction, stale/post-compaction/cache/capacity tests in M0/M2; independent native footers |
| F05 Side conversations | M4 public Pi context equality after compaction, actual read-only tool guard, cancellation, immutable parent, atomic Keep and bring-back |
| F06 Skills | M3 discovery, disabled versus explicit-only, frozen content/policy, ambiguity/symlink/dependency tests and actual serialized request |
| F07 AGENTS | M3 root-to-cwd chain, overrides/fallbacks/limits/source hash/provenance and next-turn refresh |
| F08 Timing/rate | M0/M2 fake clocks and actual HTTP content observation, retry/partial/usage semantics; missing tokenizer remains unavailable |
| F09 Exact inspection | Raw transport byte equality on both APIs, native reveal/export/retention failures, capture Off restart, large unknown-event retention and quota eviction |
| F10 Reliability/security/performance | M1 crash/no-replay; M4 tool policy; M5 origin/render/queue/update tests and measurements above; VoiceOver spoken-navigation check remains open |

## Packaging and remaining release checks

0.1.0 (build 4) is a signed, notarized preview for macOS 14+ on Apple Silicon.
Application source commit: `298aa11`. It is not an accessibility certification.
The installer contains no benchmark state or credential files.

- Developer ID: `Zhaofeng Wang (43TXHV3TM3)`; bundle `com.belloware.PiApp`.
- Apple accepted app notarization `c13e8a2c-73f5-40f2-a4e9-024aedc2068d`
  and DMG notarization `6346dbe0-bb76-45ee-b049-828dfdf385e4`.
  Both were stapled. Strict nested code-signature checks, Gatekeeper, ticket
  validation and independent Sparkle Ed25519 verification pass.
- `PiApp-0.1.0.dmg`: 192,893,874 bytes (183.96 MiB), SHA-256
  `c1e069494962ea9641ccabe97ed361ea72e7211af985712a3d8d48432cac7b5f`.
- The final signed bundle's smoke test runs its bundled Node 24.21.0 / Pi 0.85.1
  against both actual provider adapters: two requests per API, tool continuation,
  and exact request/response equality. EOF exits 0 with zero stderr bytes.
  The packaged manifest supplies the verified 384 MiB old-space / 8 MiB
  semi-space settings; the application does not depend on a system Node install.
- The final version's 115 host, 34 native and 11 script tests pass, as do strict
  TypeScript and Swift warnings-as-errors. Publication is separate from this
  successful build/signing result: the production feed was checked after
  packaging and still advertises only 0.0.2 (build 2).

The belloware.com feed must not advertise an unavailable 184 MiB installer.
An owner-selected large-binary download destination is still required; the
release tools verify its full downloaded bytes and Ed25519 signature before
publishing the feed. `restage-appcast.sh` can change that staging destination
without rebuilding or changing the signed installer. The verified public
0.0.1 → 0.0.2 update rehearsal remains intact in M0/ImplementationStatus evidence.
