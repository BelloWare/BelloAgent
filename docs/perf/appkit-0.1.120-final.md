# AppKit final Release measurements, 0.1.120

Production source: `70812d5fee0087ba493a3436033cf37fa32f93dc`.
The unchanged baseline is `e59e41a7f8e6da1b7422392f3c61e62531204ad8`;
its app and `bello-views` production sources match `v0.1.119`.
Both builds use Release optimization and `ENABLE_TESTABILITY=YES` on the
same arm64 macOS 14.8 host, Xcode 16.1 and 2x display.

`scripts/perf-transcript.sh DD OUT 3 122 4` runs all five groups three
times, then one draw-report soak: 16 invocations per build. Every individual
baseline and final log contains `TEST EXECUTE SUCCEEDED`; all four final
soak reports are present. There are no concurrent builds, tests, profiling,
source reviews or image processing during the final measurements. Each
invocation waits for one-minute load below four. Baseline starts span
1.63–3.01; final starts span 1.50–2.56. Fixtures and seed
`1790822043708` are unchanged. Baseline ran 2026-10-05 20:28–20:42 UTC;
final ran 23:36–23:51 UTC. The passing baseline is reused, rather than
claimed to have run immediately before the final build.

Values separated by slashes are rounds 1/2/3. Times are milliseconds unless
specified. These are observed samples, not hard input-latency guarantees.

| Measurement | 0.1.119 baseline | Final AppKit |
|---|---:|---:|
| Typing, median per key | 4.0 / 4.2 / 3.8 | 1.9 / 2.0 / 1.8 |
| Typing, p90 per key | 6.1 / 5.7 / 4.9 | 2.2 / 2.3 / 2.1 |
| Typing, maximum per key | 9.7 / 9.5 / 7.9 | 10.8 / 9.9 / 10.5 |
| Main-window switch, median work | 55.0 / 51.0 / 48.0 | 52.0 / 48.6 / 50.3 |
| Main-window switch, maximum work | 99.1 / 106.0 / 93.3 | 71.2 / 66.8 / 77.8 |
| Main-window switch, median to ready | 64.1 / 59.6 / 57.8 | 64.3 / 59.9 / 59.5 |
| Main-window switch, maximum to ready | 103.1 / 109.4 / 100.4 | 78.4 / 76.2 / 83.3 |
| First open, median of all nine fixture samples | 239.9 | 108.4 |
| First open, range of all nine samples | 174.7–309.8 | 66.6–126.4 |
| Reopen, median of all nine fixture samples | 154.2 | 60.2 |
| Reopen, range of all nine samples | 142.5–176.6 | 52.9–75.2 |
| Streaming, main-thread busy time (seconds) | 3.43 / 3.60 / 3.47 | 1.82 / 1.84 / 1.94 |
| Streaming, main-thread busy share | 28% / 29% / 28% | 15% / 15% / 16% |
| Rich-row scroll, p95 | 17.221 / 16.161 / 17.761 | 7.420 / 8.887 / 8.448 |
| Rich-row scroll, p99 | 50.759 / 45.706 / 49.866 | 21.959 / 24.707 / 21.979 |
| One 88 KB Markdown answer scroll, p95 | 0.702 / 0.576 / 1.270 | 0.338 / 0.368 / 0.202 |

Typical typing, opening/reopening, streaming and scrolling improve. The
whole-window switch median is broadly unchanged: median of the three work
medians is 51.0 versus 50.3, and readiness is 59.6 versus 59.9. Maximum
switch samples improve. Typing maxima remain slightly higher than the
baseline, despite much lower typical and p90 work. The earlier candidate's
15–17 ms peaks were investigated and reduced by the composer/footer repair;
this final record does not claim every measurement is better. Typing probes
include deferred main-thread activity during each 30 ms suspension.

The three requested 122-second switch-focused soaks finish whole cycles.
Baseline runs last 123 seconds each with six launches, 140 selections and
31 switches; final runs last 146 seconds each with seven launches, 171
selections and 35 switches. Raw action totals therefore have different
durations. All have zero pauses over 250 ms, zero idle-row jumps and zero
slow/missing launches. Final main-thread answers over 100 ms are 1/2/1,
with maxima 114/119/123 ms, versus baseline 11/10/11 with maxima
135/129/136 ms. The final 60-second draw-report run also passes: three
launches, 69 selections, 16 switches, two answers over 100 ms (maximum
105 ms), zero stalls/jumps/slow launches.

Final short-soak peak footprints are 139/140/142 MB versus baseline
254/258/264 MB. Growth per cycle is 6.21/7.51/7.03 MB versus
8.76/8.64/7.85 MB. These samples do not establish bounded long-run memory.
At final reports, 1/4/4 models and all seven windows remain alive, with
zero closed views; baseline retains two models and six windows, also zero
closed views. The draw report retains three models/three windows/zero
views. These lifetime observations are recorded rather than described as
zero retention. The actual mixed-action hour soak is a separate release
check and is recorded in the validation record.

Raw evidence under `/Users/admin/Library/Caches/BelloAgentNext`:
`perf-2be1/baseline`, `perf-70812/final`,
`logs/native-final-70812-performance-driver.log`,
`logs/native-final-70812-performance-metadata.json` and the preserved
`logs/final-performance-baseline-raw.json`. The final optimized build passes
all 15 affected Git/frozen-frame/render checks; its executable has no direct
SwiftUI or Charts links. See the [integration record](../validation/AppKit-integration-0.1.120-2026-10-05.md).
