# Manual context compaction: source and recovery contract

This is the Rust manual-compaction workflow for an explicitly configured,
static-instruction Controller. It is not automatic compaction, production resource
composition, a tokenization service, or full Swift compaction/Inspector parity.
All validation requests use disposable numeric-loopback fixtures and fake keys.

## Source specification

- `SessionCompaction.swift`: stop/join an active turn; keep its partial output and
  queued/held inputs; distinguish a later Stop while winding down; freeze the
  active context and configuration; validate then durably adopt one checkpoint.
- `CompactionPlanner.swift`: complete assistant/tool occurrence groups; a bounded
  recent tail; retain the latest unanswered input; replace the previous summary
  rather than stack it; choose the first boundary satisfying fit and progress.
- `CompactionSourceBuilder.swift`, `ResponsesInput.swift`, `Providers.swift`:
  intact ordinary provider input followed by the exact checkpoint instruction;
  JSON-escaped optional focus; complete zero-based retained/replaced ranges;
  `tool_choice: none`, `truncation: disabled`, and source summary wrappers.
- `SessionSummarizer.swift`: require unambiguous completed, nonempty text. Reject
  incomplete/exhausted/refused/unsupported output and all returned tool calls.
  There is no tool-dispatch continuation on this path.
- `RequestContext.swift`: UTF-16 character/4 estimates, per-provider-item overhead,
  fixed image allowance, projected instruction/tool schema costs and safety margin.
- `SessionReplay.swift`: a recovered operation without a terminal receipt is
  explicitly interrupted, not falsely described as a user cancellation or success.
- `ConversationPane.swift`: the conversation Actions menu's `Compact Now` label.

The Rust app currently has neither selected-skill carriers nor permission-note
messages. The planner must not invent those source inputs. Adding them later also
requires extending protected-input selection before compaction may replace them.

## Request and replay invariants

A request uses the current connection defaults, never a stopped turn's remembered
model. Instructions, definitions, full source context and the configuration owner
are frozen for the operation. The summary allowance is
`min(16384, model output ceiling or 16384, context window / 4)`; it does not reuse
the ordinary response's output budget. The compatibility setting may still omit
the wire cap; that remains a local reserve, not an enforced provider limit.

The model sees all active source input and one request-local instruction. No
flattening, excerpted substitute history, synthetic user goal, summary pad or
second repair request is introduced. Existing images require declared image
support; compaction refuses to replace them with the ordinary text-only model's
image placeholders. Complete tool groups are indivisible and an incomplete group
is rejected before dispatch.

The maximum-allowance candidate must fit beside normal output reserves. Its soft
visible-text candidate must reduce the projected input estimate. After the actual
response, the actual summary and retained messages must pass the same fit and
positive-reduction checks before adoption. Counts are explicitly character-based
estimates, not provider-reported usage, exact tokenization or cost. Conversation
Context occupancy remains unavailable; a newly prepared Inspector request uses
exactly the same compacted replay path as the next dispatch.

Boundary search projects each complete group once and updates the retained cost
with scalar subtraction, preserving the source's first-valid-cut choice. It does
not rebuild every remaining suffix for every cut. Preparation checks cancellation
through backwards estimation, group projection, cut search and boundary creation.
An already-impossible intact-history request is rejected before cut search.
Reference tests compare selection against full rebuilt provider requests; no
performance claim is inferred from these algorithmic or correctness checks.

## Actor and durability behavior

- Admission reserves one joined compaction worker. The previous worker can settle
  and preserve partial output before preparation. A later Stop cancels compaction
  even during that predecessor join, with zero summary requests.
- While that join is pending, commands that could activate a new turn are refused
  before mutation. New submissions may still append to the durable queue. A
  cancelled preparation durably pauses the queue and consumes its Stop flag, so
  one later explicit Resume can deliver accepted inputs normally.
- During the summary, ordinary typing and queue ownership remain intact. Queued
  appends do not invalidate the frozen replay snapshot. Successful compaction
  resumes the queue only when it was not already paused and no held edit blocks it.
- Configuration changes, retirement, cancellation and uncertain storage prevent
  candidate adoption. No mutex crosses model I/O or a worker join. Retirement
  retains writer ownership until the preparation/provider worker has joined.
- Partial text/reasoning uses the existing synced, generation-scoped stream
  journal. Completed provider usage is retained as reported. Invalid summaries
  remain non-replayable progress; their text is never silently promoted to context.
- Checkpoint adoption is one existing atomic snapshot transaction. Before-rename
  failure cannot publish the candidate. After-rename uncertainty fences later
  mutation/inspection until validated reopen; no success is acknowledged from
  merely readable bytes.

Snapshot v5 adds optional per-message checkpoint references and optional current
and prior terminal-operation receipts. The complete chronological transcript is
retained. Each checkpoint must name its exact ordered active source and valid
ordered retained IDs. Replay reconstructs `[latest summary] + retained rows + new
rows`; it does not reread files or execute historical tools. Existing v1–4 inputs
remain readable under their existing migration rules; idle v2–4 opening does not
rewrite bytes. Compaction fields in an older declared version fail closed. The
same v5 boundary also covers the independently implemented edit-tool statistics.
All existing snapshot/journal/request byte bounds and read-content budgets remain.

Interrupted reopen retains original context, partial progress, queued submissions
and held edits, pauses delivery and records the missing terminal receipt. It never
restarts a summary or an ordinary turn automatically. Prior failed/cancelled
operation receipts remain retained when a later manual attempt begins.

## Visible behavior and current limits

The existing Actions icon exposes Compact Now. Menu open, dismissal or rejected
admission does not rewrite/materialize the composer. A stale menu cannot act on a
newly selected/replaced chat. Archived, shutdown and uncertainty gates still apply.
The run footer and transcript distinguish compaction, retained failed/partial
attempts and a durably adopted checkpoint. Full original rows remain available.

During compaction the read-only Inspector explicitly asks for Refresh after
settlement rather than falsely presenting an ordinary turn as the active summary
request. After settlement and reopen it displays the actual compacted next request;
Copy remains an immutable snapshot and inspection sends nothing.

Dynamic synthetic-resource Controllers currently refuse manual compaction before
admission. Connecting their resource resolution/revision rechecks is separate
work. The ordinary static-option/CLI path and saved synthetic Connections (with
static instructions and tools disabled) remain supported. Production native
vault/trust/tool defaults are unchanged.

Automatic/context-rejection compaction, compatible reported-usage anchors,
source retry-settings/physical-attempt tracking, cost-limit enforcement,
selected-skill protection, richer request captures and native macOS menu/IME/
accessibility acceptance remain separate gates. This slice makes one explicit
summary HTTP attempt; it does not silently retry or claim a measured speedup.

## Focused checks

From `rust/` with the configured Rust 1.99 environment:

```
cargo test --locked -p bello-agent-core --lib compaction
cargo test --locked -p bello-agent-app --features synthetic-authority compaction_actions::
cargo clippy --locked -p bello-agent-core --all-targets --features synthetic-authority -- -D warnings
```

Planner/loopback tests cover exact intact input, escaped focus, caps and image
policy, complete tool groups, invalid summaries, two successive checkpoints,
full-request reference selection, deterministic cancellation, active Stop/partial
preservation, queued/held input, pending Retry/Resume fencing, exact late-submission
identity, configuration changes, uncertain writes, interrupted reopen and actual
Inspector/next-dispatch equality. Fake-platform menu tests are distinct from an
actual desktop pass and native macOS acceptance. Final execution results and exact
published CI must be recorded for the frozen candidate, not inferred from this list.
