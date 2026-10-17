# Inspector raw-search intermittent failure (0.1.129)

Branch `dev/a129-flake-inspector`, from `dev/next` 1b4743d5.

## Symptom

`InspectorNativeControlTests.testRawSearchAfterExpandedTextAndResponseKeepsTheInitialHeaderInset` failed once, in the family-delete round-2 gate's serial lane. The wait "The whole system prompt and tool schemas mount before raw search" ran its full 10 s and the test then threw `CancellationError`, for an 11.5 s total. Normal runs of the whole test take about 0.5 s, so this was not a slow mount under load: the mount never happened. The class passed 12/12 in each of five runs alone.

## Cause (test)

`InspectorOutlineView` mounts with empty placeholder content. `update(content:)` only schedules the request document, and the document is applied on a later main-queue turn (`Coordinator.schedule` → `DispatchQueue.main.async` → `show`).

The test's first wait accepted "a mounted outline plus a parsed conversation" as ready. That can become true inside the same layout pass that schedules the document. When it does, `showWhole(.section(.system))` and `showWhole(.section(.tools))` find no section row, because `owners` is still empty, and do nothing. Nothing ever requests the expansions again, so the second wait cannot succeed.

This is not a product bug. A reader cannot press "Show all" on a row that has not been shown yet.

## Evidence

A temporary probe (not committed) repeated the test's setup 40 times. At the moment the first wait returned, it recorded the outline's content key, then whether both expansions mounted within 3 s. Both runs were under the full-lane lock.

| First wait | Content still empty | Expansions never mounted |
| --- | --- | --- |
| Original predicate | 4 of 40 | 4 of 40 |
| Fixed predicate | 0 of 40 | 0 of 40 |

Every lost run was an early return, with key `""` and no expansions; there were no other losses.

## Fix

The first wait now requires the outline to show this request's document: `coordinator.content.key` must start with `<requestID>:request:`. This matches how the test already waits for the response outline. The timeout is unchanged.

After the fix, `InspectorNativeControlTests` passed 12/12, run with the probe under the lock.
