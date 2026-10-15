# Queued-message editing — 0.1.128

Date: 2026-10-15. Branch: `dev/a128-queue-edit`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-queue-edit`.
Build root and evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-queue-edit`.

## Root causes

1. `WorkspaceResources.composerMoved` parsed slash completion during queued
   editing. A trailing slash token opened the completion list; its Return
   handler consumed the key even with no candidate. Choosing a skill could
   also add a new chip that the text-only queued-save validator refused.
   An ordinary running-chat Save button worked in the initial reproduction;
   the failure was not a blanket helper refusal.
2. A confirmed `queue.edit.save` restored the parked composer draft but left
   the app's queue preview unchanged until another snapshot arrived. An
   already decoding snapshot could also replace newly acknowledged text
   with the old preview: hold adoption checked the edit revision, while
   queue-row publication did not.
3. Snapshot tool/preflight notices replaced the explanation when a queued
   edit had ended. Saving unchanged text after another caller cancelled or
   removed the edit also discarded that text as “unchanged,” although Save
   had failed. The draft must remain available in that case.
4. The banner offered only Cancel and a Return hint. Save was represented
   by the composer's icon button, which made the action harder to find.

The existing helper preserves the queued identity, lane, position, frozen
inputs and durable edit outcome. No helper code, tool definitions, model
input, permissions, capture policy, vault behavior, wire or journal format
changed. Existing journals remain readable.

## Changes and decisions

- Queued editing uses the existing normal composer with a custom Pi Save
  button in its banner. The icon button, banner Save, Return, keypad Enter
  and ⌘Return all reach the originating composer's queued-save route.
  The banner describes the shortcuts and retention of original inputs.
  It adds no Return key equivalent that could steal input from the editor.
- Completion parsing, completion-key handling and skill selection refuse
  queued-edit mode. Slash text is saved literally; it is not transformed
  into commands or new skill grants. Original helper-side images and skills
  remain attached, including for empty-text image/skill messages.
- Only a fresh Save acknowledgement updates its existing app row. The preview stays
  bounded, preserves steering presentation, and advances its text identity
  when a change lies beyond the visible preview. A newer snapshot wins over
  a late acknowledgement, and an acknowledgement never recreates a row.
  Queue snapshots older than the adopted edit revision are rejected and a
  fresh snapshot is requested. Retried Save and saved-status acknowledgements
  also request a current snapshot instead of reflecting historical text.
  Receipt settlement remains independent.
- Queued-edit explanations survive routine snapshot refresh. When a stopped
  run still reports a preflight explanation, both explanations remain visible.
  A failed Save after the edit ended preserves even unchanged text, ahead
  of the parked draft, and reports the helper's cancellation/removal reason.
  Save or Cancel still waits for confirmation before restoring the parked
  text, image attachments and skill chips.
- No new persistence field was needed. Existing queued-edit draft records
  recover the rewrite, pending operation and parked draft on relaunch.
  Notice text is presentation state, and normal accepted submission or a
  new/completed edit clears it.
- The real side-chat fixture exposed an unrelated synthetic-gateway
  validator limitation: it required `oneOf` to be the only schema key.
  Current `subagent_start` effort variants also carry shared object fields.
  The fixture now validates both the shared object and exactly one branch;
  nonempty single-branch unions are also accepted. Empty/malformed branches,
  violated root constraints and ambiguous branch matches remain rejected.
  This changes fixture validation only, not the helper's offered tools.

No new transcript-length work was added to view layout. Preview work runs
on Save; queue-row work is bounded by the existing 64-item queue limit.

## Reproduction and validation

The native interaction class mounts `ConversationPaneView`, clicks the real
`QueueRowView` Edit button, types through `ComposerTextView.insertText`, and
uses the packaged helper against the synthetic loopback gateway. Keys go
through `window.performKeyEquivalent`, then the installed application menu
and `window.sendEvent`; the tests do not call `keyDown` directly. Menu tests
verify the real Conversation binding and its enabled key-window route with
and without composer focus. The test host's activation policy is refreshed
before taking the key window because foreground activation was intermittent
on the shared Mac.

Initial failing-first runs are in `logs/red-1.log` and `logs/red-2.log`.
They reproduced slash completion consuming Return, the missing banner Save,
the stale preview after acknowledgement and the erased failure explanation.
The baseline ordinary running Save passed. Initial key-window fixture
failures are separate from those product regressions. Further fixture
diagnostics found an invalid generated PNG (replaced with a valid generated
bitmap) and the gateway schema restriction described above. The ordinary
composer already rejects an oversized paste; that protection is retained
and tested, rather than bypassed to manufacture a helper rejection.

`QueueEditInteractionTests`: **13 passed**, zero failures
(`logs/interaction-final.log`). Coverage includes:

- Running follow-up and running steering edits; idle queues held after Stop.
- The composer button, banner Save/Cancel, Return, ⌘Return, keypad Enter and
  the installed main-menu binding; no extra message or steer on Save.
- Image/skill-only queued input; the same identities/order/lane; restoration
  of the entire parked draft after both Save and Cancel.
- Side-pane Save with the parent's global focus deliberately selected, and
  the parent of a live generated sub-agent.
- Removal while editing; cancellation followed by delivery before Save;
  preservation of exact rewritten or unchanged text with an explanation.
- Relaunch with an edit in progress; restored parked draft; saved metadata
  and a second helper reopen confirming the replacement in its journal.
- Immediate queue publication while the next snapshot is deliberately held;
  the native composer's existing size limit and subsequent valid Save.

Gateway failing-first evidence is in `logs/gateway-red.log` and
`logs/gateway-root-red.log`. The final complete Python gateway class passed
**22 tests**, zero failures (`logs/gateway-final.log`).

Two production guard mutations were caught:

- Replaced the `composerMoved` queued-edit guard with an earlier-message
  edit check. The native slash/Return test failed on the completion list
  becoming visible (`logs/mutation-completion.log`: one test, one failure).
- Allowed every nonnegative queue snapshot revision. The real snapshot
  application test accepted the old snapshot and lost the acknowledged
  preview (`logs/mutation-revision.log`: five tests, two failed assertions
  in the stale-snapshot test).

Both guards were restored. The complete interaction class passed again
(13/13, `logs/interaction-restored.log`), and all five presentation tests
passed in `logs/affected-parallel.log`.

Affected native classes use `PI_BUILD_ROOT=<the root above>
scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. The lane listing
comes from `python3 scripts/test-lanes.py list`; each serial class ran
alone. The final selected runs passed **201 tests**, with **one skip** and
**zero failures** (202 executed across 15 classes):

| Class | Passed | Skipped |
| --- | ---: | ---: |
| QueueEditInteractionTests | 13 | 0 |
| QueuedEditPresentationTests | 5 | 0 |
| ConversationPaneTests | 81 | 0 |
| ComposerSubmissionTests | 6 | 1 |
| InlineSkillTests | 8 | 0 |
| WorkspaceRefreshLifecycleTests | 26 | 0 |
| QueuedAttachmentLimitTests | 2 | 0 |
| ComposerAttachmentDestinationTests | 2 | 0 |
| ComposerImportSubmissionTests | 11 | 0 |
| DraftMarkTests | 5 | 0 |
| RecoveredDraftTests | 13 | 0 |
| ShellComposerTests | 5 | 0 |
| ComposerBarLayoutTests | 7 | 0 |
| ShellParityTests | 16 | 0 |
| QueuePanelGalleryTests | 1 | 0 |

Logs: `interaction-restored.log`, `affected-parallel.log`,
`conversation-pane.log`, `shell-composer.log`, `composer-layout.log`,
`shell-parity.log` and `gallery.log`, all under `logs/` in the build root.
`affected-results.json` records the invocations' exit codes. The existing
ComposerSubmission menu check skips because an ordinary test host installs
no Conversation menu; the new serial interaction test explicitly installs
the real menu and verifies that route without skipping.

The **one full native parallel lane passed: 2,520 passed, 37 skipped, zero
failures** (2,557 total; 591.3 seconds). Four workers limited resource
contention on the shared Mac. The command and lane inventory are in
`logs/full-parallel-command.json` and `logs/test-lanes.txt`; the console is
`logs/full-parallel.log`, and the authoritative result summary exported with
`xcresulttool get test-results summary` is `logs/full-parallel-summary.json`.
No second full lane was run. Helper package tests were not needed because
no Swift helper source changed; the native interaction and conversation
classes exercised the packaged helper and its durable queue journal.

## Gallery

Standalone `QueuePanelGalleryTests` passed (one test, 22 generated captures;
`logs/gallery.log`). Output folder: `build-queue-edit/gallery/` under the
absolute build root above. It checks Save's enabled state and VoiceOver
label, button containment, queue bounds and separation from the editor.

Visually inspected all six editing captures:

- `queue-5-editing-light.png`, `queue-5-editing-dark.png` — 920 × 600 points.
- `queue-5-editing-wide-light.png`, `queue-5-editing-wide-dark.png` — 1240 × 600.
- `queue-5-editing-narrow-light.png`, `queue-5-editing-narrow-dark.png` — 420 × 600.

Save and Cancel are readable and visible in both appearances; the detail
wraps in the narrow pane without covering the editor or moving controls
outside the banner. Existing held/restart, collapsed, terminal, long-draft
and queue-limit scenes remain in the same gallery.

## Scope and handoff

Only generated fixture data, in-memory vaults, isolated native test hosts and
loopback requests were used. No installed app launch, `xctrace --launch`, real
preferences, Keychain or paid-provider requests were used. Build products,
logs and gallery files stay in this stream's build root. No named result
bundle was requested; the test script keeps only its newest automatic bundle.

No queue-edit blocker remains from the requested scenarios. The lead's
independent Codex review and integration into `dev/next` remain
separate. This stream pushes only `dev/a128-queue-edit`; it does not merge,
publish a release or push `dev/next`.

## Lead review round 1

Both P2 findings reproduced before production changes on 2026-10-15.

1. Retried `queue.edit.save` and settled `queue.edit.status` replies carry
   the helper's **current** edit revision, not the historical outcome's
   revision. The old revision-only guard therefore accepted old text at
   revision 5 over a newer rewrite already displayed at revision 4.
   Immediate reflection now requires a fresh `outcome: saved` reply without
   `repeated: true`. Historical acknowledgements leave the row and presented
   revision intact and request a current queue snapshot. Fresh saves still
   publish immediately; existing stale-snapshot and missing-row guards stay.
2. `cancelByIdentity` settles restart recovery through `finishRecord`, which
   retained an earlier cancellation failure when no changed rewrite needed
   preservation. Snapshot notice handling then republished that obsolete
   warning. Matching recovery settlement now clears the retained notice
   before preserving any changed rewrite, so `keepRewrite` can provide the
   correct explanation. Begin-only reconciliation publishes its existing
   “not opened for rewriting” explanation after settlement clears old state.

Six new behavioral tests cover the findings. Two presentation tests exercise
the historical acknowledgement guard. Four native interaction tests use
the real queue-row Edit/Cancel Edit buttons and composer Save button, the
packaged helper and generated loopback gateway. The historical-save cases
create an actual newer helper rewrite, display its snapshot, advance the
revision with an unrelated held edit, and settle the older Save by retry or status. The
cancellation cases simulate a lost request or lost response, then recover
through retry or status with no draft, an unchanged rewrite and a changed
rewrite. They verify the warning before and after snapshots, the preserved
text, released hold and persisted draft without a recovery record.

Failing-first evidence, under `build-queue-edit/logs/review-1/`:

- `red-presentation.log`: 7 tests; the 2 new cases failed with 4 assertions.
- `red-interaction.log`: 17 tests; the 4 new cases failed with 10 assertions.
- `green-interaction.log`: all 17 passed after the fixes.

Mutation checks used the production code, one change at a time:

- Removing the fresh-acknowledgement guard caused both new presentation
  cases to fail again (4 assertions): `mutation-acknowledgement.log`.
- Removing the recovery notice clear caused both cancellation interaction
  cases to fail again (6 assertions): `mutation-recovery-notice.log`.

Both production files were restored byte-for-byte before final validation.
No helper, wire, journal, model-input, permission, capture or vault changes
were needed. These fixes add no layout work or new UI geometry. The six
previously inspected light/dark editing captures remain at the gallery
paths above; this review round does not regenerate the unchanged gallery.

Final affected-class validation: **131 passed, zero failures, zero skips**.

| Class | Passed | Log in `logs/review-1/` |
| --- | ---: | --- |
| QueuedEditPresentationTests | 7 | `affected-parallel.log` |
| WorkspaceRefreshLifecycleTests | 26 | `affected-parallel.log` |
| ConversationPaneTests | 81 | `conversation-pane.log` |
| QueueEditInteractionTests | 17 | `interaction-restored.log` |

All ran with `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-queue-edit`
through `scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. The two
parallel classes ran together with two workers. Each serial class ran alone
with parallel testing disabled. Exported `*-summary.json` files and
`final-results.json` record the final result totals. No additional full
native lane was run, following the lead's affected-class-only instruction.
No helper source changed, so helper package tests were not rerun.

Both review items are addressed. Follow-up lead review and integration remain
separate; only `dev/a128-queue-edit` is committed and pushed.
