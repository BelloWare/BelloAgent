# Independent unread core/catalog review

Reviewed shared candidate at HEAD 464222b4b72ccb684d501a6301be1f1479591554 plus uncommitted core/catalog changes. Source identity is in source-sha256.txt. No production edits, Cargo execution or remote writes performed during source review.

## Source verdict

No blocking defect found in the reviewed core/catalog scope. App lifecycle, UI geometry and native acceptance remain separate gates.

- Output classification uses authoritative Session validation, receipt ownership and retained row identity. Empty completed/incomplete successes count; nonempty interrupted/context-rejected partials count; streaming placeholders and receipt-owned utility summaries/progress do not. Typed tool-assistant records require Complete and the production completed/replay=true or interrupted/replay=false shapes. Unknown/contradictory representations and duplicate/bad IDs fail closed.
- Acceptance is recorded only after SessionStore write success, before installing next memory state. Journal tokens and live publications do not advance read evidence. A retained terminal plus cumulative failure sequence survives Retry/start coalescence. Uncertain stores return Unknown; display fatal errors are not fabricated accepted failures. Direct final capture remains available after worker join/retirement.
- Reducer baselines first known history, delays busy-run increments until retained terminal, consumes failures once per generation, preserves manual state on visibility, and clears failure/manual according to explicit-opening semantics. Rollback changes baseline without adding replies and conservatively retains abandoned obligations. Counter/revision growth is checked.
- Automatic obligation and advanced observed baseline are fields of one durable read-state mutation. Grace is presentation-only, preventing a baseline-only persistence hole.
- Catalog v12 rejects any new-key presence under v1-v11, rejects future versions, validates registered identities and read metadata, and serializes through the existing narrow catalog mutation. No-op returns before transact; workspace/chat/path/per-chat revision CAS precedes mutation. Uncertainty fences no-ops too. Existing activity, organization, drafts, intents, cancellation receipts and mode/connection fields are not replaced by a read receipt.

## Evidence status

Read complete immutable bd4e6ebb1fcf235a6d96701e8e56d620fd0864c0 handoff, Swift 6319e368c6ddb7c3ef18605e78f23b1a5b69e63a WorkspaceReadState and relevant SessionRun, and shared implementation contract. Checked production typed admission/finish, context-recovery and compaction validators.

All six hashes in /workspace/shared/unread-core-validation/source-sha256.txt match reviewed files. The existing final-focused.log confirms 27 passing core observation tests; final-clippy.log confirms successful strict core all-target Clippy. Earlier typed-fixture-failure.log is an earlier failing test fixture, superseded by the checked final run; it is not hidden or reinterpreted as passing.

Catalog owner's reported 12 reducer / 9 catalog / 85 workspace / 7 integration results have no discoverable saved logs. They are owner reports only until independently rerun. Independent reruns are authorized but waiting behind QR and first App checks in the shared Cargo lane.

## Deliberate limits

Historical tool/timeline-only failed stream content discarded by Session::delta cannot be reconstructed from retained Rust rows. The accepted failure accumulator is Controller-lifetime state; abrupt crash before catalog flush can lose a historical failure occurrence, especially after Retry clears run state. Stronger guarantees require separately reviewed durable session event/content markers. No full Swift parity, native macOS Dock/focus/occlusion/accessibility acceptance, performance or feature-completion percentage is inferred.

## Independent executed gates (03:28 UTC)

After QR and first App gates released the shared Cargo lane, independently ran and saved raw output for:

- cargo test --locked -p bello-agent-core --lib read_observation -- --nocapture: 27/27 PASS.
- cargo test --locked -p bello-agent-core --lib workspace_read_state -- --nocapture: 12/12 PASS.
- cargo test --locked -p bello-agent-core --lib workspace::read_catalog_tests -- --nocapture: 9/9 PASS.
- cargo test --locked -p bello-agent-core --lib workspace:: -- --nocapture: 85/85 PASS (includes catalog/activity/topics suites; totals overlap).
- cargo test --locked -p bello-agent-core --test sidebar_organization -- --nocapture: 7/7 PASS.

Pre-run source hashes are in pretest-source-sha256.txt relative to rust/. These independently establish the previously owner-reported catalog gates. Lane released after successful completion. Strict Clippy remains verified by the existing matching-hash owner log; it was not redundantly rerun here.

## Separate App boundary review

Found one blocking exclusion defect: unloaded registered CheckpointRequired rows remained manually markable even when their checkpoint was missing and sidebar scan showed Unavailable. The App owner confirmed and fixed this: unloaded eligibility now requires matching non-Unknown scanner evidence; action execution rechecks the captured filesystem identity off the UI thread, then operation/workspace/navigation/read-revision/current-record-path identities before mutation. Loaded persistent actors retain precedence. Source fix reviewed; deletion and same-bytes/same-mtime inode-replacement tests reported passed, raw App log verification pending.

Otherwise inspected one-writer scheduling and bounded retries, clone-before-fsync/exact-revision receipt merge, admission registration/path/Controller/known-history gates, native evidence and exact authoritative acknowledgement generation/revision/target after painted reply-end bounds, and post-join direct capture plus full dirty-map flush. No further blocker found in that scope. This is not full App or native acceptance.

## App fix evidence and synthetic test support review (03:30 UTC)

Inspected saved App logs at rust/docs/validation/sidebar-unread-2026-10-09/app/read-state-tests.log (25/25 PASS including unloaded_manual_action_rechecks_missing_and_replaced_checkpoint_after_scan) and reply-geometry-tests.log (2/2 PASS). The original missing-unloaded finding is resolved in reviewed source and verified regression output. App source hashes are in app-reviewed-sha256.txt; no App Cargo was run by this reviewer.

After independent core reruns, root authorized a narrowly scoped synthetic-authority-only one-shot real AfterRename test hook. Exact delta retained as synthetic-fault-reviewed.patch; changed workspace.rs SHA256 ff9f127e79c4c34fadfc10031fa2cadcb4adb21b572d2a843ef4726cd3ac4e7f. Reviewed feature gates, no-op placement, prior-fault restoration, unchanged default test fault behavior and unchanged uncertainty fence. No blocker. The new App regression verifies renamed disk baseline versus unchanged memory, Unicode draft and newer typing preservation, no submission intent/session dispatch, and lasting uncertainty fences. Execution result pending tester. final-review-core-sha256.txt rebinds the reviewed source; earlier independent default test hashes remain separate and are not misrepresented as testing this later support delta.

## Final scoped verdict (03:31 UTC)

PASS: no remaining blocking core/catalog defect found; the one App exclusion defect found in the extended review is fixed and its regression passed. Verified the tester's raw hook-core-default-clippy.log and hook-core-all-features-clippy.log: both strict core all-target checks completed successfully. Verified real-uncertainty-test.log: real_after_rename_baseline_uncertainty_preserves_input_and_blocks_dispatch passed 1/1 with synthetic-authority. All 12 final core hashes and 11 extended-review App hashes still match. git diff --check passed.

Evidence is intentionally layered: independent reviewer reran core/reducer/catalog/workspace/integration; original owners/tester ran App/geometry/synthetic uncertainty and strict Clippy, whose raw logs and matching sources were independently inspected here. Full aggregate App/workspace gates and authorized real desktop/native macOS interaction remain outstanding parent-owned gates. No runtime native parity or crash-durable historical failure guarantee is claimed.
