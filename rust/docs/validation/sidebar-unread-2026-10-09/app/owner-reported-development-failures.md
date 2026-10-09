# Owner-reported development failures

This is a retrospective implementation-owner summary, **not raw test output**.
The original failing logs for the four cases below were overwritten when their
log filenames were reused for corrected runs. They are unavailable as preserved
raw files in this evidence directory. Counts, names and diagnoses below come
from tool results observed during development. No old failure was rerun and no
raw output has been reconstructed.

The common published base was
`464222b4b72ccb684d501a6301be1f1479591554`. Development used an uncommitted shared
worktree. Where no exact failing postimage was archived, that limit is stated.
Final r5 evidence must not be described as the original failing output.

## 1. Initial focused admission/draft regression

- Observed result: **22 passed, 1 failed**, in a 23-test default App
  `sidebar_read_state::tests` run.
- Failing test:
  `send_retry_command_and_resume_routes_stop_at_failed_baseline`.
- Observed failure: the Send route's composer was empty instead of the captured
  Unicode draft `preserve 日本語` after a read-state uncertainty fence prevented
  dispatch.
- Cause: the submission completion path treated a proven pre-dispatch catalog/
  baseline failure like uncertain actor acceptance. It could retain the cleared
  composer and schedule a later empty draft save.
- Fix: carry `dispatch_started` explicitly. When dispatch never began, restore
  and merge captured input with newer typing while retaining catalog/read-state
  uncertainty and recovery fences. Uncertain acceptance after actor dispatch
  keeps its existing handling. Regression coverage was strengthened to check
  delayed durable draft saving and newer Unicode typing; a later synthetic
  after-rename test exercises actual catalog uncertainty.
- Source checkpoint: pre-first-freeze mutable worktree on the common base; no
  exact immutable failing source postimage was saved.
- Overwritten filename: `read-state-tests.log`. Its current contents are a later
  **29-passed** focused run, not this failing run. Final full r5 suites cover the
  subsequent additions too.

## 2. First full default App aggregate

- Observed result: **566 passed, 4 failed, 1 ignored**.
- Source checkpoint: first source-freeze manifest
  `303454a03596ad15c77afdb6aa011a4815c2420134ccae5f24e73db2c35838c4`
  on the common base, before the subsequent fixes/Arc-fence revisions.
- Failures and fixes:
  1. `chat_organization::tests::archive_waits_for_real_generic_retry_failure_without_erasing_that_error`
     expected the Controller's missing-connection error. Its unregistered pending
     fixture now stopped earlier at the required baseline gate. The fixture was
     explicitly registered so the test still exercises the intended Controller
     failure and archive ordering; the production baseline fence was retained.
  2. `queue_actions::tests::queue_resume_completion_keeps_original_chat_and_close_barrier`
     and
     `queue_actions::tests::queue_resume_failure_preserves_marked_draft_focus_and_rejects_duplicate_click`
     expected the existing Resume error prefix. Baseline failures had bypassed
     that prefix. The Resume path now wraps both baseline and actor failures with
     the same explanatory prefix while preserving uncertainty propagation.
  3. `sidebar_actions::tests::sidebar_copy_id_rejects_stale_token_project_window_shutdown_and_removed_record`
     expected the existing missing-chat Copy notice. The new broad identity guard
     suppressed it. Missing targets again reach Copy's existing explanatory
     handler, while a reused ID at a different path is still rejected.
- Overwritten filename: `default-workspace-tests.log`. Its current contents are
  a later passing workspace run. A subsequent default App run recorded
  **570 passed, 1 ignored**; later added tests account for higher final counts.

## 3. Cached-child reveal regression

- Observed result: **0 passed, 1 failed**, with 574 other tests filtered out.
- Failing test:
  `transcript_view_tests::unread_geometry_repaints_cached_child_on_late_observation_and_surface_reveal`.
- Observed failure: closing the covering surface did not force fresh transcript
  geometry, despite the test requiring a real child repaint.
- Cause: child notification issued during parent render could be absorbed by the
  current draw, allowing GPUI to reuse the cached child's paint.
- Fix: defer reveal invalidation until after parent render, then recheck exact
  workspace, window, selected chat and Controller identity. Accepted attention
  changes and relevant completed saves also request child proof. Unchanged
  parent redraws retain caching. The same regression subsequently passed.
- Source checkpoint: mutable post-r4/pre-r5 worktree; the direct-notify failing
  form has no separately archived exact postimage.
- Overwritten filename: `cache-proof-test.log`. Its current contents are the
  corrected **1-passed** run.

## 4. r4 strict lint failure

- Observed result: strict default workspace Clippy exited **101** on one
  `unused_mut` diagnostic in the new height-only resize test. This was a lint
  failure, not a test failure count.
- Source checkpoint: pre-lint r4 manifest
  `9f3b9bfd21b1ae2eb034eb58753e028bfa3233db6c78ecdb3ff24a708d5d750f`.
- Location: `transcript_view_tests.rs`, local `visual` binding in
  `unread_reply_end_rechecks_current_geometry_after_height_only_resize`.
- Fix: remove the unnecessary `mut`; no production behavior changed.
- Overwritten filename: `r4-default-clippy.log`. Its current contents are the
  corrected passing strict run.

## Final evidence separation

Final r5 source manifest:
`2f4acc3d00ce73fbc7145f652df10181aaca9b51640065e17052cfecaa4ca87a`.
The `r5-*` logs record format, strict default/all-feature checks, **575 default
App tests passed with 1 ignored**, **720 all-feature App tests passed with
3 ignored**, an explicit package clean, and an ordinary default build. Their
source/binary binding is in the separate r5 `SEAL.json`. These corrected gates do
not restore the missing original raw failure logs or establish native/desktop
acceptance by themselves.
