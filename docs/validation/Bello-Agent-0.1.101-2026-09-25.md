# Bello Agent 0.1.101 — compaction plan conformance

Status: released and publicly verified, 2026-09-25 14:39:14 UTC.
Starting main SHA: `9f01951` (0.1.100/build 104).
The owner supplied **BelloAgent-Compaction-Plan.md** and explicitly requested a
release. That request supersedes the uploaded document's no-publication clause.
Most of its architecture was already present in 0.1.100; this change closes the
remaining verified gaps without introducing another summarizer or changing UI.

## Changes

- Reserve `max(ordinary output budget, summary allowance + appended instruction)`
  plus the existing safety margin and growth buffer. Large ordinary output
  budgets can no longer be under-reserved by the automatic compaction trigger.
- Use the uploaded checkpoint wording and scale its soft visible target down
  for small inputs/windows. Keep the session's reasoning effort and complete
  typed request prefix; generated summaries are never cut to meet the target.
- Bound the escaped boundary description without silently omitting retained
  ranges. Existing context is preserved if the description cannot be represented.
- Require positive successful terminal evidence. Reject incomplete output items,
  unrecognized non-text output, and hosted/custom tool calls even when a response
  also contains plausible summary text. Reaching the numeric cap with explicit
  completion remains valid.
- Explicitly disable server truncation, reject alternative output-limit fields,
  and label cap-omission compatibility as a local reserve rather than a server cap.

## Plan acceptance coverage

| Cases | Local evidence |
| --- | --- |
| T01–T02 | Full serialized-prefix comparisons preserve instructions, tools, reasoning, images and parent-side cache affinity. HTTP fixtures return write, MCP, hosted search and custom calls despite `none`: one request, zero local executions, no adopted checkpoint. Conflicting sampling fields are rejected. |
| T03–T04 | Complete occurrence-scoped groups, reused call IDs, split turns, previous checkpoints, protected skill/input carriers, manual focus and no-op contexts remain covered by the compaction/replay suites. |
| T05 | Small/large windows, large ordinary reserves, overflowing arithmetic, bounded boundary descriptions, image/wrapper estimates and oversized intact source before dispatch. |
| T06–T07 | Missing/contradictory completion, incomplete output items, long reasoning, complete-at-cap, refusal, empty output, non-reducing summaries, final wrapper and continuation headroom. |
| T08–T10 | Native replay policies, encrypted items, in-flight resource changes, Stop/queue behavior, injected journal failures and cancellation immediately after durable adoption. |
| T11–T14 | Retained-source edit invalidation, transitive restoration/forks, identical bounded retries, one recovery without repeating completed tools, side attribution and late observation isolation. |
| T15 | Deterministic successive-checkpoint and continuation fixtures establish retained evidence and state transitions. They do not establish a live model's semantic summary quality. |
| T16 | Live same-route cache/latency/usage measurements are unrun. Required live gateway environment variables are not configured. Prefix equality does not demonstrate cache hits or performance gains. |

## Validation

- Focused helper checks: `swift test --package-path packages/swift-host
  --scratch-path …/native-master/swift-verify --filter
  'Compaction|EditRecovery|HistoricalEdit|SideFork|PiParity'`: **120 passed**,
  0 failures, 8.083 seconds (after rebuilding). One older automatic-compaction
  fixture sat exactly at the old prompt-size boundary; its synthetic evidence
  now stays above the trigger without weakening production checks.
- `PI_BUILD_ROOT=…/native-master scripts/verify-release.sh`: 11m53s. Serial
  native lane: **207 cases, 7 optional skips, 0 failures**. Parallel lane:
  **1,416 passed, 16 optional skips, 1 failed**. The failure was the terminal
  project-switch keyboard-focus test sharing the window server with other test
  hosts; it passed immediately in isolation. Moved that unchanged test into the
  existing serial class, rebuilt, then reran both affected terminal classes:
  **15 passed**, 0 failures, 7.325s. No production terminal behavior changed.
- Full helper suite: **449 passed**, 0 failures, 62.100s. Native screenshot
  gallery: **112 screenshots**, 0 failures, 269.764s.
- Transport/script checks: `test-native-host.py` **32 passed** (31.824s),
  `test-concurrent-native-host.py` **3 passed** (13.335s),
  `test-native-acceptance.py` **2 passed** (2.580s), Python script suite
  **66 passed** (22.354s), including the deterministic reasoning-gateway rehearsal.
- `scripts/live-compaction-e2e.py`: stopped before dispatch because
  `PI_LIVE_BASE_URL`, `PI_LIVE_API_KEY` and `PI_LIVE_MODEL` are not configured.
  No live request was sent. Live semantic quality, cached usage and latency
  remain unmeasured; deterministic fixtures are not substitutes for those results.
- `git diff --check`: clean before the release gate.
- Installation and updater rehearsals are excluded by the owner's standing policy.

## Publication

Source commit: `a7f8dc4dd9a22b45b47fa968597b1b8002a51c85`; local tag `v0.1.101`.
Website publication commit: `0454bae49e2260df7e86d90ef4383f63db1d2716`.
Cloudflare check `108116512846` completed successfully at 14:38:05 UTC.

- Version **0.1.101**, build **105**, Apple Silicon.
- Developer ID signing, application notarization/stapling and Gatekeeper
  assessment passed. Application submission: `973598ef-9fd4-4062-b571-f2ba6a551434`.
- Installer notarization/stapling and Sparkle Ed25519 validation passed.
  Installer submission: `d982e02c-1694-412b-9000-508e3f993499`.
- `BelloAgent-0.1.101.dmg`: **10,846,708 bytes** (10.34 MiB).
- SHA-256: `f00b69bcba3669a857a021618719f98377a528ff278a783fbc3f1726575b4fe1`.
- Public product page links to the new installer. The canonical and legacy
  feeds are byte-identical; the public download matches the local hash and
  passes signature verification. These checks passed after deployment propagated.
- [Public installer](https://belloware.com/assets/BelloAgent-0.1.101.dmg).

Source commits remain local under the existing release workflow; this request
does not ask to push the source repository.
