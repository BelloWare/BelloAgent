# Ephemeral per-call terminal cards

This slice publishes normalized native and MCP outcomes independently while other
calls in the same batch remain active. Bash keeps its streaming updates. Generic
App cards consume the same LiveToolView; a terminal card is execution/display
state, never proof that its result has reached a durable checkpoint.

The existing join_all barrier and original-call-order canonical settlement remain
unchanged. MCP Tickets remain pending until the batch checkpoint succeeds, and
uncertain checkpoint outcomes retain the existing no-replay behavior. Live state
is absent from serialized sessions and from reopened sessions.

## Fixed display budget

Only the first 16 calls in each active assistant batch are admitted to ephemeral
cards. This is a stable source-order admission window, not a completion-order
cache: later calls still execute and commit normally, but display Awaiting until
their canonical results arrive. Each admitted preview is at most 98,304 UTF-8
bytes, for at most 1,572,864 preview bytes across the collection (plus bounded
card metadata). No card is evicted within the active batch. Previous-batch cards
are pruned on admission of the next batch, and stale identities fail the active
assistant/worker/configuration/Stop fences before they can reinsert anything.

Terminal previews contain canonical result text and short retained image MIME
descriptors. They never copy image base64 or binary data. Terminal outcomes are
immutable: delayed streaming and repeated terminal updates cannot revive them.

Batch wall time, per-call duration and cumulative timing remain a separate,
deferred schema/presentation slice. These tests make no performance claim.
