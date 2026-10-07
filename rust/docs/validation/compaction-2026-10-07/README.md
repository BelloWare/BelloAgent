# Manual compaction validation — 2026-10-07

This validates the bounded [manual compaction workflow](../../manual-compaction.md)
on the actual cloud Linux desktop. It is not native macOS interaction, production
vault/tool enablement, exact token counting, automatic compaction or a performance
comparison. No model service, account credential or paid request was used.

## Exact source and binary

- Rust 1.99.0, Linux debug app, `synthetic-authority` feature; static CLI connection
  and instructions, tools disabled, fake fixture key supplied on stdin.
- Immutable binary SHA256:
  `11de31b56bd93e0a36c40617faca0d19ed907fc6df378f1ef6ebeb96c4a9b1d1`.
- [146-input Rust/Cargo source manifest](source-sha256.txt), SHA256:
  `52f2e30b8c0fcd249c1b249852cb46fabe30bd5e51753c09a27ccf47343f5e9f`.
- The manifest was captured after the successful binary build and compared again
  after the complete desktop/reopen pass: zero changed source inputs. The binary
  was copied before testing; subsequent test links did not replace it.
- [Verification record](verification.json) includes the unchanged screenshot
  hashes and observed durable/request outcomes. The four images are the exact
  JPEG bytes returned by CUA's app screenshot API, without cropping, redrawing,
  annotation or transcoding.

The source includes the independently reviewed write/edit changes sharing snapshot
v5. Screenshots here demonstrate compaction only; Linux does not enable the native
macOS mutation adapter through this workflow.

## Local automated gates

- 26 focused compaction core tests passed: planner/request/replay, full-request
  reference comparison, deterministic cancellation, durable loopback lifecycle,
  pending Retry/Resume race, late accepted queue identity, stale configuration,
  write uncertainty, interrupted reopen and strict historical receipt validation.
- Six app tests passed: four GPUI menu/composer/navigation/gate tests and two pure
  status/retained-error label tests. Synthetic IME events are not native IME proof.
- Combined default workspace: 372 app + 303 core unit + 107 integration tests
  passed; one existing manual benchmark remained ignored.
- Combined synthetic core: 376 unit + 107 integration tests passed. A subprocess's
  one-test output belongs to that suite and is not an additional distinct test.
- Combined transcript suite: 89 passed, with three existing/native platform ignores.
- Strict default and synthetic workspace/all-target Clippy, formatting and the
  synthetic app build passed. Independent compaction and edit reviews completed.

Review caught and corrected pending-compaction Retry activation, a stale Stop flag,
Stop/token-install ordering, retained-tail metadata, and quadratic candidate suffix
rebuilding. The selection now uses additive complete-group costs; a slow full-body
reference checks source-equivalent cuts across Unicode, tools/images, protected
inputs and every initial cut. These are correctness/algorithmic checks, not a
measured speedup. Exact published Linux/macOS CI remains a separate later gate.

## Actual cloud desktop sequence

The frozen app ran on the cloud XFCE desktop with Mesa software Vulkan, 1180×812
content, an isolated project/session/catalog and the committed
[`compaction_gateway.py`](../../../fixtures/compaction_gateway.py). The gateway
listened only on `127.0.0.1:47841`, logged synthetic request bodies without headers,
and reported no invented token or cost usage. The initial Rust v2 session held two
labelled synthetic rows large enough for a useful source-defined retained-tail cut.

1. Typed `draft survives compaction`. Opened Actions, then dismissed with Escape.
   The draft remained and no provider request occurred.
2. Reopened Actions and clicked `Compact Now`. One loopback summary request carried
   intact source history plus the checkpoint instruction, `tool_choice: none`, and
   `truncation: disabled`. Snapshot v5 durably retained both original rows and
   adopted one checkpoint. The recent assistant was retained in replay. The draft
   remained unchanged. [Checkpoint and preserved draft](01-checkpoint-and-draft.jpg).
3. Opened the read-only Context Inspector. It showed the checkpoint wrapper first,
   retained assistant next, and labelled the unsent draft included. It continued to
   state that token count/occupancy were unavailable. Opening and closing Inspector
   added no HTTP request. [Actual compacted request](02-compacted-inspector.jpg).
4. Explicitly sent the preserved draft. The second POST began with the checkpoint,
   retained the recent assistant and included that draft as the final user input.
   The replaced original user row was absent from provider replay but unchanged in
   durable chronological history. The fixture returned labelled synthetic evidence.
5. Clicked Compact Now again. The fixture streamed partial summary text and held
   completion. Typed/submitted `queued while compacting`; it remained in the queue.
   Clicked Stop, then typed `unsent after stop`. The operation became Cancelled;
   partial summary text remained non-replayable, the queue was paused, and no second
   checkpoint was adopted. [Cancelled operation and intact inputs](03-cancelled-queue-draft.jpg).
6. Closed normally with Ctrl-W, then reopened the same immutable app/session.
   `queued while compacting` remained paused, `unsent after stop` was restored, the
   original rows and first checkpoint remained, and the cancelled operation/partial
   evidence was retained. No request or automatic queue delivery occurred on reopen.
   [Reopened queue and draft](04-reopened-queue-draft.jpg).
7. Closed normally again. Both app/Inspector windows were gone, the app log was
   empty, and the fixture gateway was stopped by its launch-script cleanup.

Exactly three POSTs occurred: completed manual summary, explicit ordinary turn,
and cancelled manual summary. Reopen and Inspector did not increase the count.

## Reproduction and limits

Run the committed gateway with a new private log and explicit fixture profile
(`openai-responses`, `litellm`, numeric loopback `/v1`, 65,536 context window and
4,096 normal output reserve). Use only a separate Rust session directory and fake
stdin key. The first summary completes; the second streams partial text and waits
30 seconds for the Stop test. Ordinary replies deliberately create synthetic
history large enough to compact again. No external model is involved.

CUA physical desktop input was used for the actual menu, typing, Stop and close
operations. Bound-window click/scroll delivery did not reliably trigger GPUI here;
physical desktop input did, and subsequent captures verified the resulting state.
Some screenshots initially showed the previous frame, so the saved images were
captured again after the settled state was observed. Native Unicode typing, macOS
menu/IME/accessibility, hardware presentation latency and production authority
remain unverified. The new Actions popup is a GPUI implementation of the source
command, not a claim of AppKit menu pixel/keyboard parity.
