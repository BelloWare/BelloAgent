# Project MCP validation — 2026-10-07

## Final candidate 4 — focused writer-lease acceptance

[Candidate 4 passed the final focused GUI smoke](candidate-4-accepted/README.md)
at **10:52 UTC**, after the independently reviewed canonical outcome-file OS
writer-lease correction. Its immutable binary SHA-256 is
`3b482b903851c68695e771dc16b43642e5e1b21636c5579981991012d206c7aa`;
the exact 172-input digest is
`5651aedc79af217f3c4d0d47e13c8f98625e5d6084cd9aba21c2671ea70ac87c`.
[Post-GUI verification](candidate-4-accepted/post-gui-verification.json) confirms
unchanged source and binary bytes.

Actual fresh GUI setup, discovery, confirmed Inspector invocation, model MCP
invocation/continuation, joined saved-route retirement/reopen and a new prompt
all passed. The gateway recorded exactly two echo calls and no replay. Full app
checks were repeated: **501 synthetic / 408 default passed**, strict Clippy and
formatting passed. Prior-process transcript recovery and expected memory-only
vault authority refusal are documented separately, without claiming persistent
authority recovery.

The broader candidate 3 matrix below remains accepted for its exact binary.
Candidate 4 received only the agreed focused smoke; no earlier screenshot was
relabelled as candidate 4. The desktop was released to Box after normal close.

## Candidate 3 — accepted broad matrix

[Candidate 3](candidate-3-accepted/source-binary-manifest.json) completed the bounded
actual Linux cloud desktop matrix at **10:11 UTC**. Both fixture windows were
closed normally, and the desktop was released to the next validation owner.

- Immutable binary SHA-256:
  `06dd2ebdddfc51dc0dcab9a6d474ae16984c4e573c709d995b9c05892919c262`
- Exact 172-file build-input digest:
  `64ff67beddd5fae983601834ff110c8aff330fe756a0b19ae2a383c4f2c33ea7`
- [Post-GUI verification](candidate-3-accepted/post-gui-verification.json) found
  **zero changed build inputs** and the same immutable binary hash.
- Synthetic app suite: **501 passed, 0 failed, 3 intentionally ignored**.
- Default app suite: **408 passed, 0 failed, 1 intentionally ignored**.
- **44 focused MCP tests** are included in those suites. Formatting and strict
  default/synthetic all-target app Clippy passed.
- [Core, CI, independent review and LOC details](core-validation.md).

Candidate 3 includes the explicit `allowedTools:null` rejection, truthful
Inspector-owned cancellation affordance, and reviewed completed-chat late-tail
retirement repair. The build began on `50da4e9` plus those reviewed source changes;
the retirement repair was subsequently published separately as `33c79e2`.
The build-input manifests, rather than the earlier HEAD alone, identify its bytes.

## Actual GUI matrix

The ordinary run started in a fresh disposable project with **no saved MCP config,
connection, chat or injected tool transcript**. Settings, project trust, connection
selection, MCP configuration and every invocation were completed through the real
GUI and existing saved-ID runtime. The gateway bound only numeric `127.0.0.1`; the
only credentials were the documented fixed synthetic fixture values.

| Case | Observed result | Original screenshot |
| --- | --- | --- |
| Explicit null allowlist | `allowedTools:null` refused before save; dirty draft retained; no MCP request | [01](candidate-3-accepted/01-null-allowlist-rejected.jpg) |
| Trust/save/apply | Header-free config saved; masked replacement cleared; only header-presence metadata returned | [02](candidate-3-accepted/02-saved-header-free-config.jpg) |
| List and describe | Initialize/initialized/list only; visible schema, zero tool calls | [03](candidate-3-accepted/03-described-schema-no-invoke.jpg) |
| One-shot confirmation | Cancel sent nothing; repeated confirmation produced exactly one echo invocation | [04](candidate-3-accepted/04-one-shot-confirmation.jpg), [05](candidate-3-accepted/05-exactly-one-result.jpg) |
| Retained result reload | Durable receipt displayed; no re-execution and no unknown marker | [06](candidate-3-accepted/06-durable-result-reload.jpg) |
| Model-driven MCP | Real saved Controller `mcp` tool card, normalized result, then provider continuation | [07](candidate-3-accepted/07-model-mcp-continuation.jpg) |
| Completed-chat retirement | Saved route fork selected, same chat retired/reopened; new prompt immediately answered on `second-fixture` | [08](candidate-3-accepted/08-retired-reopened-new-prompt.jpg) |
| Disconnect outcome | Exactly one uncertain call, project unknown banner, further invocation disabled | [09](candidate-3-accepted/09-unknown-quarantine.jpg) |
| Cross-chat quarantine | A second genuine saved chat saw the same project-wide unknown state; no replay | [10](candidate-3-accepted/10-project-wide-unknown.jpg) |
| Exact acknowledgment | Cancel kept the exact marker; explicit acknowledgment removed it, with gateway count unchanged at 11 | [11](candidate-3-accepted/11-acknowledgment-confirmation.jpg) |
| Local in-flight Cancel | Exactly one slow call; visible Cancel settled as interrupted with an unknown outcome and no retry | [12](candidate-3-accepted/12-local-cancel-unknown.jpg) |
| Retained composer | Original chat history and unsent draft survived Inspector and cross-chat navigation | [13](candidate-3-accepted/13-retained-original-draft.jpg) |

The final ordinary log contains **12 gateway rows: 2 echo calls (one Inspector,
one model-driven), 1 uncertain call and 1 slow call**. The remaining rows are
provider/discovery traffic. The uncertain marker was explicitly acknowledged;
the later canceled slow marker was deliberately retained. Closing the app did not
acknowledge or retry it. Both ordinary saved chats ended idle, unpaused, with no
pending chat messages.

Connections also correctly refused a stale whole-envelope save after the MCP
configuration changed. Its model draft remained visible. Explicit Discard and
Reload installed the fresh baseline; re-entering/saving `second-fixture` then
created the intended route fork. No request was sent by save or route selection.

## Separate genuine ReadOnly control

The ordinary source default remains Editing. A separate disposable fixture used
only the reviewed `seed_mcp_readonly.rs` support helper to create one genuine saved
ReadOnly record through SessionStore/WorkspaceStore. It seeded **no authority,
connection, credential, MCP configuration, tool result or alternate runtime**.
All profile/trust/configuration actions still occurred in the actual GUI.

| Case | Observed result | Original screenshot |
| --- | --- | --- |
| ReadOnly discovery | List worked; selected echo Invoke stayed disabled | [14](candidate-3-accepted/14-readonly-discovery-invoke-disabled.jpg) |
| Enable Editing question | Cancel retained saved ReadOnly and composer draft; explicit confirmation applied only to that saved chat | [15](candidate-3-accepted/15-enable-editing-confirmation.jpg) |
| Separate invocation | After joined retirement/persist/reopen, one additional confirmation produced exactly one echo call | [16](candidate-3-accepted/16-editing-one-shot-result.jpg) |
| Identity/draft/history | Same chat `7a10ba76-50d2-4071-aadc-1545ffacc4ae`, original completed history and draft retained | [17](candidate-3-accepted/17-mode-preserved-draft-history.jpg) |
| Next prompt | Sending that preserved draft immediately produced the normal provider response, rather than a paused queue | [18](candidate-3-accepted/18-mode-reopened-new-prompt.jpg) |

The supplemental gateway log contains **6 rows and exactly 1 echo invocation**.
The saved chat ended Editing, idle and unpaused, with its four transcript messages
and no queued message. Neither mode confirmation nor its cancellation invoked MCP.

## Evidence and limits

- [Screenshot hashes](candidate-3-accepted/screenshots-manifest.json): 18 original
  CUA image payloads, no cropping, editing or re-encoding.
- [Ordinary gateway facts](candidate-3-accepted/ordinary-gateway-records.jsonl) and
  [ReadOnly gateway facts](candidate-3-accepted/readonly-gateway-records.jsonl):
  sanitized method/tool/count/boolean facts only, no headers or raw request bodies.
- [Final saved-state summary](candidate-3-accepted/gui-state-summary.json): fixture
  identities, idle/queue state, retained drafts, bounded receipts and outcome ledger.
- [Source before](candidate-3-accepted/source-before-build.json),
  [source after](candidate-3-accepted/source-after-build.json),
  [synthetic tests](candidate-3-accepted/app-synthetic-test.log),
  [default tests](candidate-3-accepted/app-default-test.log), and strict Clippy logs.

[Candidate 1](candidate-1-preliminary/README.md) remains **preliminary**. It provides
supplemental visual evidence for the masked trust/draft/close flow, but predates the
null allowlist, cancellation-affordance and retirement corrections. Candidate 2
was built but never launched; it is not GUI acceptance evidence. No prior binary
was silently replaced or relabeled.

Final manual scope was bounded to the matrix above. Active-project save refusal,
header blank-preserve/clear, stale callback and external-config reapply variations
remain covered by focused automated tests; they were not all repeated manually on
candidate 3. The broader recipe is guidance, not a claim that every recipe step
was executed on every candidate.

These results establish the synthetic Linux workflow only. Native production
credentials/storage/tools remain disabled. No macOS keyboard/IME/accessibility,
Keychain, signing, production endpoint, paid service or cross-process native-vault
acceptance is claimed. The synthetic vault is memory-only; Inspector/Controller
reopen is meaningful here, while a whole-process restart does not retain that vault.
