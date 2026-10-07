# Candidate 4 — final focused acceptance

The immutable candidate completed its focused Linux cloud GUI smoke and closed
normally at **2026-10-07 10:52:53 UTC**. The desktop was released to Box immediately.

- Binary SHA-256:
  `3b482b903851c68695e771dc16b43642e5e1b21636c5579981991012d206c7aa`
- Binary size: **125,750,432 bytes**.
- Exact 172-file build-input digest:
  `5651aedc79af217f3c4d0d47e13c8f98625e5d6084cd9aba21c2671ea70ac87c`
- [Post-GUI verification](post-gui-verification.json): zero changed build inputs;
  immutable binary hash still matches.
- Full app synthetic suite: **501 passed, 0 failed, 3 intentionally ignored**.
- Full app default suite: **408 passed, 0 failed, 1 intentionally ignored**.
- **44 focused MCP tests** included; strict all-target default/synthetic Clippy and
  workspace formatting passed. [Exact manifest](source-binary-manifest.json).

This candidate adds the independently reviewed canonical outcome-file OS writer
lease to candidate 3. It excludes competing catalogs/sessions while permitting
same-workspace manager reuse/rebind and retaining ownership through physical
settlement. No Inspector UI source changed. The broader candidate 3 GUI matrix
remains evidence for its exact binary; it was not relabeled as candidate 4.

## Focused actual GUI result

A fresh disposable project was configured through the real GUI: fixed fake
connection, explicit project trust, saved connection selection, ordinary Editing
chat, and explicit MCP config trust/save/apply. Setup sent zero gateway requests.
No authority, configuration, saved chat or tool transcript was seeded.

1. **Discovery passed:** List Tools returned the fixture descriptors after
   initialize/initialized/list. No tools-call had occurred.
   [Screenshot 03](03-discovery-no-invocation.jpg).
2. **Inspector invocation passed:** one explicit echo confirmation yielded one
   normalized result and an empty pending outcome ledger.
   [Screenshot 04](04-inspector-result-settled.jpg).
3. **Model continuation passed:** the real saved Controller invoked `mcp`, rendered
   the completed tool card/result, then received the provider continuation.
   [Screenshot 05](05-model-mcp-continuation.jpg).
4. **Joined retirement/reopen passed:** after the completed response, a saved
   `second-fixture` route fork was explicitly selected. The same chat was retired,
   reopened and rebound. A new `after reopen fixture` prompt immediately received
   a normal response on that new route, retaining the earlier tool transcript.
   [Screenshot 06](06-retired-reopened-new-prompt.jpg).
5. **Normal close passed:** the app closed through its native window control.
   No follow-up MCP request or automatic replay occurred.

The [sanitized gateway log](gateway-records.jsonl) contains **9 rows and exactly
2 echo calls**: one Inspector invocation and one model-driven invocation. It also
contains the actual model continuation and the later normal provider response on
`second-fixture`. The final [saved-state summary](gui-state-summary.json) has the
same chat `829bb301-3d31-4de3-90bb-c46602983f75`, eight messages, idle state,
`queue_paused=false`, no pending message and an empty project outcome ledger.

## Separate prior-process observation

Before the fresh run, the same binary opened the prior supplemental saved chat.
Its four existing transcript messages displayed unchanged
([screenshot 01](01-saved-chat-reopened.jpg)), but its synthetic in-memory vault
had disappeared with the prior process. The bound project UUID therefore could
not resolve. Projects correctly refused trust/rebind after Reload
([screenshot 02](02-memory-only-authority-fails-closed.jpg)); the gateway received
zero requests and the original session remained byte-for-byte unchanged.

This is the existing memory-only synthetic authority boundary. It is **not** a
cross-process authority recovery pass, nor an OS writer-lease failure. The window
was closed normally, and the focused functional smoke used a fresh disposable
fixture. No catalog/authority seeding or identity bypass was used.

The [screenshot manifest](screenshots-manifest.json) records the six original CUA
image payloads without crop, edit or re-encoding. Native production credentials,
storage and tools remain disabled; macOS, Keychain, real endpoints and paid services
remain outside this acceptance scope.
