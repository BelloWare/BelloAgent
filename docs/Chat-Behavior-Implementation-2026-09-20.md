# Chat behavior implementation — 0.1.63

Implements the uploaded Implementation-Plan.md plus the owner's follow-ups for
Copy Turn Info and drag-and-drop session ordering. Starting source:
`123c102fd6d961c81424171522b04a2ee284676f` (0.1.62). The owner explicitly requested
publication, superseding the plan's generic no-publication boilerplate. No
subagents were used. Install/update rehearsals remain skipped by owner policy.

## Changes and evidence

- **C, keyboard intent (`7a21308`).** Native Return/keypad Return queues while
  running; Command-Return steers, falling back to normal send only when already
  idle. Shift inserts a newline, IME keeps marked text, and Option/Control stay
  native. Completion selection and explicit-only skill permission remain
  separate. A stale running state produces `not_running` without losing the
  draft. The real-helper keyboard fixture checks durable lanes, rapid repeats,
  newer edits and focus changes. Buttons share the same intent path.
- **A, logical tool counts (`1ae5c57`, `2ad6552`).** Whole assistant content is
  counted before the 32-card display cap; native/Codable/history paths retain the
  optional count. Repeated paths and reused provider IDs in distinct replies are
  separate calls; provisional argument deltas and duplicate rows are not. Legacy
  incomplete history says “at least”; missing outcomes do not imply a successful
  file change. Expandable per-call details remain. Copy Turn Info includes
  clocks, model/tool duration, usage, model reports and per-request coverage.
- **B, request usage (`3d4addc`).** Typed dispatch-bound observations cover
  supported Responses lifecycle objects and JSON. Session/turn/attempt/purpose,
  fingerprint, sequence and generation checks reject stale/wrong-scope data.
  Missing/invalid fields are not zero; cumulative snapshots are not summed.
  Missing final fields retain their interim provenance. The context ring uses
  reported input against dispatch capacity, never input plus output/cache.
  Awaiting requests retain their estimate; the inspector separates current,
  previous and prepared-next-request information. Compaction/branch/profile
  changes invalidate current observations. Footer updates do not publish a
  transcript change or depend on capture aggregation.
- **D, stable Markdown (`648ebb6`).** Two failing native reproductions first
  established early interpretation of unfinished syntax and the eight-block
  container replacement. A retained state controller now tracks source ranges,
  revisions, generations and provisional tails. Foundation remains the canonical
  parser, including terminal document-level reference resolution. Known code
  fences retain native owners across growth/closure/finalization. Unfinished
  inline/list/quote syntax is deliberately literal; confirmed tables stay rich.
  Existing paragraph/code hosts and native selection survive compatible changes;
  Foundation source positions remap literal inline selection when formatting
  settles. The caret is a nonselectable overlay. Each pane has one leading plus
  trailing presentation job at 30 Hz, with immediate first content, tool and
  terminal boundaries. Raw state/capture/tool execution are not batched. Live
  preview bounds, full retained-content access and exact geometry remain.
- **Session ordering (`2fac026`).** A native row drag displays a before/after
  insertion indicator. Whole marked selections keep relative order. Atomic
  metadata ranks and organization revisions survive restart and stale background
  writes, preserve running drafts and parent/child relationships, and reject
  mixed-group selections without partial rank writes. Ordering is within a
  project/topic, parent and pinned group; existing topic-header drops move whole
  branches between groups. New sessions appear above manually ordered peers.
- **Additional transport bug (`b05fcc0`).** The full fixture suite exposed a
  missing consumer acknowledgement in HTTP MCP after 0.1.62's ingress batching.
  JSON could wait forever for EOF and multi-batch SSE could stop after its first
  chunk. Both paths now acknowledge bytes with `defer`, including errors and
  early returns. Actual loopback tests cover stdio+HTTP and large JSON/SSE.

## Validation method and limits

The full helper selection passed **228 tests**. The final request-aware gateway
suite passed **26 tests in 18.102 s**, using the staged production helper. It
checks the owner's usage/cost samples, exact capture, auth replacement, streaming,
tools, cancellation, compaction, history/replay and MCP. The observation scenario
sees 1,000/2,000/3,000 request inputs during three tool rounds with capture off,
in-memory capture and a rejecting recorder, and separately checks a final-only
usage route. This is a deterministic local gateway, not a claim about a deployed
LiteLLM route. No external live gateway or real credentials were used.

The optimized native selection passed **176 tests** in 231.039 s, including the
combined 20-session/two-pane workload, composer/helper queue integration, request
context, topic ordering and full streaming-stress suite.

The final explicit Debug actor-check selection passed **26 tests** in 4.853 s;
other unchanged relevant suites passed in the earlier 79-test selection. Its one
remaining failure was an idle-reclamation fixture boundary: it stopped waiting
at exactly 40 hosts while requiring fewer than 40. The wait condition now includes
40; the strict memory assertion is unchanged. The final selection rechecks
native viewport ownership, formatted text selection, preview/canonical source,
copy, pasteboard ordering, restart persistence and one-job presentation limits.

The older full gateway script had two stale assumptions about the cumulative
usage object predating nullable status fields: exact shape and summing all values.
It now asserts the status fields and sums input/output explicitly. No numeric
expectation, raw-capture assertion or sample coverage was weakened.

Release measurements, combined UI/gateway results, signing and publication are
recorded in the [release validation](validation/Bello-Agent-0.1.63-2026-09-20.md).
The rich-stream comparison disables only presentation coalescing in the benchmark
after the page mounts and asserts each displayed prefix, so every one of the
same 134 input deltas (64-byte chunks) incurs its actual layout cost. Production
coalescing is covered separately by native burst/terminal tests and the combined
workload. Short-answer comparison uses the prior SwiftUI-stack container versus
persistent-native container in the same optimized process. It is a container-cost
comparison, not a second historical executable or physical frame-rate evidence.
The matched rich-stream run passed: 20.7 ms mean / 40.54 ms max versus the earlier
23.2 / 48.9 ms baseline. Benchmark commit `a0800aa` sets its override after native
mounting and asserts every measured prefix; an earlier coalesced result is excluded.

This does not solve all cold giant-row layout or scrolling costs recorded in the
0.1.61/0.1.62 reviews. Incomplete syntax can intentionally change formatting when
settled, and canonical structural changes may replace the affected view type;
unrelated settled blocks and compatible native selection owners remain. No
physical trackpad, external-display or VoiceOver result is claimed. Live previews
are still bounded, never advertised as the complete authoritative response.
