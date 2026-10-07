# Saved runtime native cloud UI acceptance — 2026-10-07

## Exact candidate and scope

This behavioral matrix used the immutable Linux GPUI candidate with SHA-256
`b4c8274fab1fc25c23cc8e17e13dfc28c6762ad86823dfa1dccbe2340a89213d`
(121,184,200 bytes). The full source/manifests and assets were hashed immediately
before building and checked unchanged afterward. See
[behavioral-source-binary-manifest.json](behavioral-source-binary-manifest.json).
The app launched with `--synthetic-connections`, a disposable explicit project,
isolated HOME/config/data directories and a fixed fake credential. No Mac,
Keychain, real credential, paid provider or external endpoint was used.

The earlier complete secure-input matrix used another exact candidate and remains
separately attributed in [secure-inputs-2026-10-07](../secure-inputs-2026-10-07/).
The only production change between that candidate and this one was the
capability-aware Projects completion notice. This matrix exercised the corrected
notice through actual Projects clicks.

## Observed outcomes

1. Settings Save, project trust and explicit saved-connection selection each left
   the provider request count at zero. The pending chat had no checkpoint.
2. The native composer sent `list fixture`. The actual saved-runtime factory
   advertised and executed `ls`, returned `runtime-proof.txt` from the disposable
   project, durably retained its tool result and sent one continuation. This is
   the rendered result of real Controller execution, not injected transcript rows.
3. Context Inspector showed the applied `local-test-fixture` model, context limit
   32,000, output budget 4,096 and the actual request replay. Opening it sent nothing.
4. A second unsent chat retained `retained new draft` while the first conversation
   was selected again. Switching views sent nothing and preserved tool history.
5. Changing the saved model to `second-fixture` created a second connection. The
   original chat stayed on its original route until the explicit connection picker
   selected the new one. The existing session ID and tool history stayed the same;
   selection itself sent no request.
6. A real `stall fixture` SSE request on `second-fixture` produced partial text.
   A follow-up was queued, then Stop preserved the partial output and paused queue.
7. Deleting that fake route retained the persisted history, partial output and
   queued input. Send, Retry and Resume were visibly disabled. Enter with a new
   draft and clicking disabled Resume neither consumed the draft nor sent a request.
8. Context Inspector then explicitly showed `No connection configured for context
   preview`, rather than a stale request from the deleted route.
9. The disconnected queue item could be removed without destroying the new draft.
   Explicitly selecting the remaining saved route reopened the same history and
   retained the draft. The queue remained paused. Sending then explicitly pressing
   Resume dispatched only the retained draft on the original route.
10. The unrelated unsent draft survived all of these changes. Closing the idle app
    completed normally. The final v7 catalog held one `checkpoint-required` chat
    with history and one `pending` chat with the retained draft and no checkpoint.

Exactly four HTTP requests were observed: `ls`, its continuation, the later stalled
request on the selected second route, and explicit recovery Resume on the original
route. Every authorization check matched the known fake credential. The
[boolean-only gateway log](behavioral-gateway-records.jsonl) contains no credential
or custom-header value. No queued tool or completed historical tool reexecuted.

## Original images

All images are the original CUA `image/jpeg` result bytes, with no edits, crops,
reconstruction or overlays. [screenshots-manifest.json](screenshots-manifest.json)
records every original hash and byte count.

- [01](01-trusted-fixture-notice.jpg): actual trusted-project completion notice
- [02](02-real-ls-and-continuation.jpg): actual `ls` result and continuation
- [03](03-actual-context-inspector.jpg): applied Context Inspector request
- [04](04-route-fork-no-send.jpg): route fork preserves earlier chat bindings
- [05](05-explicit-switch-retains-history.jpg): explicit switch preserves history
- [06](06-stop-preserves-partial-and-queue.jpg): Stop preserves partial text/queue
- [07](07-deleted-route-inert-history.jpg): deleted route retains an inert draft
- [08](08-disconnected-context-unavailable.jpg): Context is visibly unavailable
- [09](09-explicit-recovery-with-draft.jpg): explicit reconnect preserves draft
- [10](10-independent-pending-draft.jpg): unrelated pending draft remains intact

## Reproduction and limitations

Build the synthetic app feature using the repository's documented Linux recipe.
Start `rust/fixtures/saved_runtime_gateway.py --port 47871 --log /absolute/log.jsonl`
from a disposable environment. In the app, save the numeric-loopback URL
`http://127.0.0.1:47871` and the documented fixed fake key, trust only the disposable
project, select the saved connection, and follow the prompts above. `list fixture`
requests real `ls`; `stall fixture` holds SSE output for cancellation checks.

Native X11 input used documented CUA pointer/key methods. Text entry was performed
through per-character X11 keys; the unavailable AT-SPI text-entry path was not
credited as successful. Fresh observations were taken after asynchronous UI
updates. A screenshot immediately after a click can precede the new frame; those
intermediate observations were not treated as action success.

This is Linux software-rendered native UI acceptance, not macOS input, signing,
Keychain or accessibility acceptance. The fixture vault is memory-only. This matrix
proves actor/navigation/rebind reopening inside that lifetime, not persistent
credential restoration across application restarts. Native production startup and
real credentials remain separately gated.

The initial starter badge in image 10 still says `Tools unavailable`; actual CUA
found that old hardcoded label after confirming the tool runtime works. A separate
final capability-backed badge correction and scoped immutable-candidate rerun are
required and documented separately below. The image is preserved as original
evidence rather than altered to match newer source.

## Final capability-backed candidate and scoped rerun

The final immutable candidate is SHA-256
`c4d42b1756269f1335a743d790b09959d6168fea569bd41ceef42855500f9223`
(121,189,264 bytes). Its complete
[final source/binary manifest](final-source-binary-manifest.json) was captured
before build and checked unchanged afterward. Compared with the behavioral
candidate above, the production changes are a nonblocking, no-vault-I/O core
capability presentation query and the centralized starter label. They neither
change dispatch/admission nor grant authority. External authority changes must
still become known through the normal confirmation path; the badge is not a
replacement permission check.

Actual final-candidate CUA repeated Settings Save, Projects trust, New Chat,
real `ls` and continuation, then Projects retrust (retire/join/exact-history
reopen) and one explicit post-reopen Send. Outcomes:

- Inert startup still visibly says `Tools unavailable`.
- A confirmed saved fixture actor with actual implemented definitions says
  `Fixture tool runtime`. The real `ls` result was `scope-proof.txt`.
- The capability-aware Projects completion notice preserves the native gate.
- Save/trust/New Chat did not send. Retrust reopened retained tool history and
  did not send or repeat the historical tool. The subsequent explicit Send worked.
- Exactly three final-scope requests were received: `ls`, its continuation and
  the explicit post-reopen prompt. All used the fixed fake key and `ls` capability;
  no real service was contacted. See [final scoped gateway facts](final-scoped-gateway-records.jsonl).
- The final idle app closed normally and the desktop was released.

The six additional original JPEGs have separate
[final screenshot hashes](final-screenshots-manifest.json):
[11 inert startup](11-final-inert-startup.jpg),
[12 truthful Projects notice](12-final-projects-notice.jpg),
[13 actual fixture badge](13-final-capability-backed-badge.jpg),
[14 real tool result](14-final-real-ls.jpg),
[15 completed project reopen](15-final-project-reopen.jpg), and
[16 explicit post-reopen dispatch](16-final-explicit-send-after-reopen.jpg).
The broad Stop/deletion/reconnection matrix remains attributed to the earlier
exact binary above; it is not relabeled as a full rerun on this final binary.

Final app gates passed: **457 synthetic tests / 3 ignored**, **394 default tests /
1 ignored**, strict all-target app Clippy in both configurations, and formatting.
Core capability-query tests separately cover real definitions, empty/default/
legacy/disconnected/retired/known-revoked states, nonblocking actor/config
contention, uncertainty and absence of vault reads. Native macOS acceptance
remains separately gated and is not claimed here.
