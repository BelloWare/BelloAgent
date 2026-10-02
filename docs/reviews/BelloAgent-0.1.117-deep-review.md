# BelloAgent 0.1.117 deep code review

Reviewed 1 October 2026. Scope: high-confidence bugs and performance improvements that preserve the existing interface and intended behavior.

## Summary

The highest-priority fixes are selected-file Git operations that can change unselected files, a connection-switch race that can send to the previous gateway, and an accepted-message durability gap. The two performance recommendations remove provable redundant work in file syntax coloring and Markdown completion; no speculative timing improvement is claimed.

This report contains ten distinct findings, ranked by impact and reachability. All have high confidence in the identified source-level defect. The Git behavior was reproduced with real Git commands. The Swift findings were traced through their current callers, persistence/recovery paths and tests, with small portable models where useful. They have not been executed in the native app.

### Reviewed version

- Repository: [BelloWare/BelloAgent](https://github.com/BelloWare/BelloAgent)
- Pinned review commit: [f084047cf3ab86d6fabeef2f2a1baa2829c082df](https://github.com/BelloWare/BelloAgent/commit/f084047cf3ab86d6fabeef2f2a1baa2829c082df)
- Release: 0.1.117, build 121
- The annotated v0.1.117 tag resolves to 3fdb62b561a32755ccecad16a02302dab0d891dc. The review commit differs from it only in four release-documentation files, so the findings apply to the tagged product source
- Compared relevant paths against v0.1.116, whose tag resolves to 166c254ea2d534b9aeb8d8673ade2db43e64fd8b. This is a review of the current codebase, not just newly introduced regressions

### Priority list

P1 means prioritize because of data loss or incorrect destination. P2 means substantive correctness, interoperability or performance work for the next development cycle. These are review priorities, not exploitability scores.

| Rank | Priority | Improvement | Main consequence |
| --- | --- | --- | --- |
| 1 | P1 | Make selected Git paths literal | Discard/delete/commit can affect unselected files |
| 2 | P1 | Serialize connection switching against session opens | A new turn can use the old gateway while the interface names the new one |
| 3 | P1 | Keep in-flight queue delivery durable | Accepted text can disappear from resumable history after a helper crash |
| 4 | P1 | Preserve the entire pending-side draft | Closing a side or quitting drops selected images and skills |
| 5 | P2 | Rebind existing journals when switching connections | A routine endpoint/model switch makes the next open fail |
| 6 | P2 | Page capture garbage collection | A large valid archive can get stuck failing cleanup and subsequent maintenance |
| 7 | P2 | Give nested code fences unique identities | One fence can display or copy another fence's code |
| 8 | P2 | Bound and share syntax-state reads | Small visible lines repeatedly materialize a huge preceding line |
| 9 | P2 | Make terminal Markdown matching linear | Reply completion performs quadratic work on the UI actor |
| 10 | P2 | Accept empty MCP SSE priming events | A standards-compliant HTTP MCP server can fail initialization or calls |

## Method and verification limits

Reviewed helper lifecycle, queueing, replay, branching and compaction; tool/process/MCP and transport code; app storage and capture maintenance; workspace lifecycle and connection management; transcript parsing, rendering and selection; and FileView, FileFinder, GitView, tab/watch/trust paths. Findings were checked against the surrounding implementation and relevant tests. The two connection findings and two rendering findings also received independent counterexample checks.

Work was cloud-only and read-only. No source changes, pushes, issues or PR comments were made. The checkout remained clean. No credentials, production gateways or user data were used.

Executed verification:

- Twelve isolated Git cases using Git 2.52.0 on Linux: six current argument forms and the same six with literal pathspecs. Current forms affected both the selected bracketed path and its matching neighbor; literal forms affected only the selected path
- Portable state/algorithm models for both queue lanes, nested code identity sharing, terminal Markdown candidate counts and syntax-prefix read sizes
- A SQLite row-boundary/garbage-collection model and an SSE empty-event model, described with their findings
- Six existing Python tests passed: the four CheckNextTests and two VerifyReleaseTests. These use isolated/stubbed build commands and verify release-script behavior, not Swift correctness

Swift, Xcode and AppKit are unavailable in this environment. Native compilation, app integration/UI tests, timing/RSS measurements, VoiceOver and real-gateway checks were not run. Regression tests below are proposed acceptance checks, not claimed passes. Existing published release-gate results are historical evidence only. The documented graphics/font-cache soak pauses are not re-reported as a new finding, and neither performance finding is claimed to explain those pauses.

## 1 Make selected Git paths literal

**Impact:** Discard and Delete Untracked File can destroy changes in files the user did not select. Stage, Unstage and Commit Checked can also include other files. Ordinary bracketed route names such as app/[id]/page.tsx are enough; malicious input is unnecessary.

**Evidence:** [GitService.discard][git-discard] passes concrete row paths directly after `--` to `git restore` and `git clean`. The [shared process arguments][git-execute] do not enable literal pathspecs. Git still interprets pattern syntax after `--`. [Stage, Unstage and both commit forms][git-commit] have the same problem. The [single-row actions][git-actions] pass exactly the selected row, so this is a mismatch between the user's selection and what Git operates on.

**Reproduction, actually executed with Git:** Create tracked app/[id]/page.tsx and app/i/page.tsx, modify both, then run the argument sequence used by the app:

```sh
git restore --staged --worktree -- 'app/[id]/page.tsx'
```

Both files return to their committed content. Quoting prevents shell expansion but does not prevent Git pathspec matching. The same selection staged, unstaged and committed both files. With both files untracked, `git clean -f -- 'app/[id]/page.tsx'` deleted both. NUL-delimited `--pathspec-from-file` also matched both; NUL protects separators, not pattern semantics.

**UX-preserving fix:** Enable `--literal-pathspecs` for operations whose inputs are concrete file rows, including the pathspec-file route. Audit diff and single-file history consistently. All six reproduced operations behaved correctly with the global literal option. Preserve existing confirmation text, file selection and layout.

**Regression acceptance:** Through GitService, exercise bracket, star, question-mark and leading-colon filenames. Assert every unselected file's working-tree/index contents remain unchanged after discard/delete/stage/unstage and only selected files enter the commit. Include the long-list pathspec-file branch and renamed paths. This defect also exists in 0.1.116; the current release's package move did not remove it.

## 2 Serialize connection switching against new session opens

**Impact:** After switching a chat from connection A to B, a stale open can leave the helper using A while the app displays B. Subsequent conversation content may be sent to the wrong configured gateway.

**Evidence:** [setConnection][connection-switch] makes its final idle/opening check at line 42, then awaits session.close and the metadata write without claiming a per-chat switching/loading/closing state. [open][host-open] validates the supplied ChatRecord but can reuse any loaded session with that ID. [ConnectionLease][connection-lease] checks profile existence and deletion generation, not the chat's current binding. The helper's [existing-session path][helper-open] likewise returns the existing session without comparing the requested profile.

**Concrete actor interleaving:**

1. A saved chat is idle on A. Start a switch to B and let session.close finish
2. Suspend the switch at its metadata write. The in-memory chat still names A and `opened` is now empty
3. Let prewarm/open capture that old A record; hold its credential read
4. Finish the switch, so the in-memory chat and connection pill now name B
5. Release the old open. A still exists, so its lease passes; it opens the old A-bound journal and sets `opened`
6. A later `open(current B)` hits the loaded-session fast path and uses A

This is source-proven scheduling, not an executed native race. [The existing concurrency test][connection-test] covers the opposite order, an open already in progress before the switch checks its blocker.

**UX-preserving fix:** Serialize the entire close/rebind/metadata operation with opens for that chat. Tie each opening and loaded-session entry to a chat binding/generation, revalidate it after awaits, and reject or close stale opens. Have send, prewarm and automatic context use the same gate. Existing controls can keep their current behavior; no new confirmation or navigation is needed.

**Regression acceptance:** Add deterministic gates at the metadata and credential reads and run the reverse interleaving above. Assert no A session remains after B commits and that the next actual request reaches B. Also test automatic context, a send, two quick switches, cancellation and failed writes. This is distinct from finding 5: synchronization alone does not make a B profile compatible with an A-bound journal.

## 3 Keep accepted queue delivery durable until the user record is appended

**Impact:** An accepted follow-up or steering message can disappear from the queue and visible history after a helper crash. Its text remains in an older journal state for forensic recovery, but normal replay does not recover it.

**Evidence:** [startFollowUp][queue-followup] removes the submission before awaiting delivery; [drainSteering][queue-steering] does the same. [deliver][queue-deliver] awaits tool/resource validation before appending the user message. Another queue operation can run during those awaits and [persist the reduced queue][queue-mutators]. [savedState][queue-state] contains the current queues, not the in-flight local submission. [Reopening][queue-reopen] restores the latest queue state. The app is not a guaranteed fallback: [receipt settlement][queue-app-intent] clears the original pending text once even a queued receipt is observed.

**Reproduction schedule:** Queue A and B behind a run. When A is removed for delivery, pause its capability/resource validation. Remove B, which durably saves the now-empty queue. Crash before A's user message is appended. Reopen the journal: A has neither a queue payload nor a user record, only an ID/status receipt. A portable state model reproduced this schedule for both lanes; it did not execute Swift.

**UX-preserving fix:** Persist an explicit in-flight-delivery payload, or retain the selected submission durably until its user-message append succeeds. Prevent edits/removals of the claimed item while allowing the remaining queue controls to work. On recovery restore undelivered work paused, and use delivered-message IDs to avoid duplication if the append succeeded before a later checkpoint failed. Adding fsync alone cannot repair a state record that omits the payload.

**Regression acceptance:** Extend the existing HeldQueueDeliveryTools gate in QueueEditingTests. Hold delivery, mutate another queue item, copy the journal as a crash snapshot before releasing the gate, then reopen the copy. Assert A survives exactly once and no request is automatically replayed. Run for follow-up and steering, including both one-at-a-time and all modes. Retain the existing append-succeeded/checkpoint-failed tests, which cover the other side of the boundary.

## 4 Preserve images and skills when moving an unsent side draft

**Impact:** Closing an unsent side, replacing it with another side, quitting, or preparing an update can lose its selected images and skills. A skill-only draft can vanish entirely.

**Evidence:** A [new empty side][side-create] exists only in memory. [discardPendingSide][side-discard] reads just the text, removes the side display, and appends only that text to its parent. The [quit/update transfer][side-transfer] also moves only text and skips the draft if the trimmed text is empty. [flushDrafts][draft-flush] excludes ephemeral sides, while normal [savedDraft][saved-draft] includes images and skills. [Submission][send-guard] explicitly accepts skills without text. There is no later persistence path for the discarded chips.

**Reproduction:** Open an unsent side, type text, add an image and select a skill, then close it. The parent gets the text but neither chip. Repeat with only a selected skill: the side disappears and no draft is transferred. The same loss follows quit/update for a pending side. This is a direct data-flow finding; native interaction was not run.

**UX-preserving fix:** Transfer a full DraftRecord through one shared merge path, preserving text order, attachment identities and skill selections. Clear/remove the side only once the parent owns that complete draft. Keep existing side-closing behavior and parent placement. Propagate storage failures rather than treating an unread parent draft as empty. If merged chip counts exceed submission limits, preserve the inputs for review instead of silently dropping them.

**Regression acceptance:** Cover text+image+skill, image-only and skill-only drafts; an already-populated parent; duplicate chips; replacing the pending side; quit and update; and parent metadata that has not loaded. Inject a parent-read/write failure and verify all original draft fields remain recoverable.

## 5 Safely rebind the journal before completing a connection switch

**Impact:** For an existing chat, switching to a connection with a different endpoint or default model succeeds in the app's metadata and announces the new connection, but the next helper open rejects its saved journal.

**Evidence:** [setConnection][connection-switch] changes the profile/model while keeping the journal path. [WorkspaceHosts][host-path] sends the target profile with that old path. The helper's [Profile.binding][profile-binding] includes API, provider, default model and the endpoint hash. [AgentSession initialization][session-journal-open] opens the old journal against the new binding; [SessionJournal][journal-binding] requires exact equality and throws `legacy_session` on a mismatch. Its checkpoint fast path enforces the same condition. No portable rebind is performed on this switch path.

**Reproduction:** Send on A, wait until idle, switch to B whose endpoint or default model differs, and send again. The next open reaches the incompatible-binding rejection. A second profile that changes only credentials while keeping the same binding does not trigger this case. [The existing switch test][model-switch-test] uses a chat with no journal path; it does not complete a real reopen/send on the changed binding.

**UX-preserving fix:** Prepare a supported portable rebind to the destination before committing the chat's new connection, preserving displayed history, versions, drafts and provenance. Keep opaque provider state subject to the existing replay compatibility rules. Do not simply remove the binding check. If preparation fails, leave the original connection and journal usable rather than committing a switch that cannot open.

**Regression acceptance:** Use two synthetic gateways with different endpoints/default models, create a real A journal, switch to B, then send and reopen again. Verify B receives the request, portable context and visible history are retained, incompatible opaque state is not forwarded, and a failed migration leaves A intact. Include checkpoint-backed and full-replay journals.

## 6 Page capture garbage collection instead of applying a query result ceiling

**Impact:** A valid large capture archive can fail cleanup with a misleading quota-full error even when its byte quota allows the data. Clearing a large session can leave its unreferenced chunk files in place and make later maintenance repeatedly fail.

**Evidence:** [CaptureDatabase.rows][capture-row-limit] throws on row 100,002. [collectGarbage][capture-gc] first materializes every unreferenced chunk through that method before deleting any files; startup also materializes every referenced chunk into a set. [clear/evict][capture-clear] removes references before calling garbage collection. Thus clearing a session with more than 100,001 distinct chunks commits the reference removals, then throws before deleting any of those chunk files or rows. The same oversized orphan selection remains on subsequent cleanup attempts.

[New capture admission][capture-begin] calls reconcile, and [reconciliation][capture-reconcile] only advances its maintenance deadline after successful garbage collection. A failed clear does not itself reset an existing future deadline, so repeated admission failures begin when maintenance is next due or after reopen/configure, rather than necessarily immediately. Startup also repeats the scan. Some direct database-backed reads can still work because the database is assigned before startup cleanup; this is not a claim that every archive API is disabled.

**Reachability and reproduction:** The [chunker][capture-chunker] caps each chunk at 32 KiB, and [configured storage][capture-quota] supports up to 10 GiB or an [unlimited byte quota][capture-unlimited]. Retention duration remains independently limited. A session retaining over 3.1 GiB of non-deduplicating content across many completed requests necessarily exceeds 100,001 chunks while remaining within supported storage. Construct one session with 100,002 valid distinct chunks and references, then clear it. Use fewer than 100,001 completed, unleased requests with many chunks per request, so the earlier attempt-ID query does not mask the garbage-collection failure. A SQLite model using the same selection and row guard confirms the threshold: 100,001 rows return; 100,002 throw before the deletion loop starts. This models the algorithm, not native PayloadArchive execution.

**UX-preserving fix:** Stream maintenance rows or process bounded keyset batches, with deletion ordering and retryability preserved. For orphan-file validation, avoid building a full capped result set; use bounded lookup or a streaming index. Keep byte quotas, retention rules and integrity checks unchanged. Do not just raise the arbitrary row ceiling or delete records before safely accounting for their files.

**Regression acceptance:** Create >100,001 distinct retained chunks under the allowed byte quota. Verify reopen, clear, retention expiry and subsequent capture begin all succeed; unrelated referenced files stay intact. Inject deletion failure mid-batch and verify the next pass finishes safely. Assert bounded query/batch memory independently of total archive size.

## 7 Give nested code fences collision-free cache identities

**Impact:** Two fences inside nested blockquotes can share the same copy payload. When the fences use the same language/font size and the second code extends the first, the first fence's displayed text is also mutated into the second fence's text.

**Evidence:** [Quote recursion][quote-identity] sets the component to 1000+childIndex at every nesting level, discarding its ancestor component. The outer first code child and a nested quote's first code child get the same full identity. [highlighted][code-sharing] reuses the resulting MarkdownCodeMark and overwrites its code. Its append branch also mutates the same NSMutableAttributedString. [Paragraph construction][code-paragraph] retains those references, and [Copy][code-copy] reads the mark. The parser [preserves nested quote hierarchy][quote-parser].

**Minimal fixture:**

~~~~markdown
> ```swift
> let value = 1
> ```
>
> > ```swift
> > let value = 10
> > ```
~~~~

The equivalent direct-builder tree is `quote([code("let value = 1"), quote([code("let value = 10")])])`. Both leaves receive the same component 1000, source offset, generation and segment. The executed reference-sharing model shows both paragraph and Copy values becoming `let value = 10`. With unrelated code strings, Copy still aliases even when visible text does not. Foundation parsing/rendering was not executed here; the direct-builder collision is unconditional for this tree.

**UX-preserving fix:** Use the full typed child path, or another collision-free stable leaf identity, within the top-level block. Preserve a genuinely identical fence's identity across streaming appends so selections and incremental coloring remain stable. Copying the attributed string alone does not fix the shared Copy mark.

**Regression acceptance:** Test the direct-builder tree and full Markdown fixture. Assert distinct code marks, correct visible strings, hover/accessibility Copy values, and stable outer selection while the nested fence streams. Include a non-prefix pair and deeper quote/list combinations.

## 8 Bound and reuse lexical state reads for large files

**Impact:** Opening an otherwise supported large source file can trigger huge repeated reads and allocations just to color short visible lines. The off-main-actor work is still unbounded and can create unnecessary memory pressure and delay coloring.

**Evidence:** [FileSyntaxReader.tokens][syntax-prefix] loads the full prefix from the current 128-line checkpoint to each requested line. [The line-length guard and loader][syntax-load] limit only the line being colored, not the preceding lines fetched to establish lexical state. [FileDocument.fetch][file-fetch] then reads and decodes the requested whole range. [SyntaxHighlighter.resume][syntax-scalars] builds an array of every Unicode scalar even with collect=false.

**Concrete supported input:** A .js file with a single 64 MiB ASCII block-comment line followed by forty short `const value = 1;` lines. The huge line's own coloring is skipped, but coloring zero-based line 1 fetches all of line 0. Lines 2–40 each independently request another prefix starting at line 0. The source-level range model totals at least 2,684,367,820 bytes of prefix text requested for those forty short lines, before scalar-array work. This is aggregate redundant work, not a measured peak-memory or latency figure. FileDocument supports long lines; its normal paging cache does not cap this explicit fetch.

**UX-preserving fix:** Advance lexical state through bounded chunks, including within long lines, and share/cache state across successive lines instead of rereading each block prefix. Coalesce work and cancel obsolete requests when the document changes or the tab stops needing them. Preserve final syntax colors and existing file-view controls; avoid introducing a new whole-file read or truncating visible content.

**Regression acceptance:** Add the long-first-line fixture and a long line inside a preceding checkpoint block. Instrument maximum bytes per read, maximum lexer input and cumulative repeated-prefix work. Assert bounded chunk sizes and near-single-pass state work, then verify multiline comments/strings still color correctly. Native latency/RSS measurements should follow implementation; none are claimed here. This path was introduced in 0.1.117.

## 9 Replace quadratic terminal Markdown identity matching

**Impact:** Finishing a reply with many small Markdown blocks performs avoidable quadratic work on the UI actor, even when its final source is identical to the streamed source.

**Evidence:** [StreamingMarkdownState.update][markdown-finalize] maps every canonical block to `records.first`, starting the search at index zero every time. Its used-ID set excludes matches but does not avoid visiting already-used records. For matching ordered offsets, block k visits k records. [NativeMarkdownContainer.read][markdown-mainactor] calls this synchronously on the main actor. The streaming-to-finished flag change enters this branch even if the source bytes are unchanged.

**Operation-count reproduction:** Stream n separate `a` paragraphs, then finalize the same source. The reduced loop model gives:

| Blocks | Source bytes | Candidate visits |
| ---: | ---: | ---: |
| 120 | 358 | 7,260 |
| 1,150 | 3,448 | 661,825 |
| 4,096 | 12,286 | 8,390,656 |

The count is n(n+1)/2. This small source is not excluded by the transcript's page policy. It is not a native timing benchmark. Fresh parses with no retained records, and terminal replacements that clear the prior records, do not incur this same matching case.

**UX-preserving fix:** Keep the necessary canonical parse, but match candidates with an ordered cursor or position index. Preserve exact-offset matching, containing-range/same-container fence matching, uniqueness, terminal replacement rules and selection identity. No text, formatting or scrolling behavior needs to change.

**Regression acceptance:** Instrument candidate visits for stream→finish with the sizes above and assert linear growth. Assert stable IDs and canonical block equality. Preserve tests for late reference definitions, code-fence source offsets, selections, duplicate identities and terminal replacement. Current large-reply streaming tests constrain live appends, not this terminal matching pass.

## 10 Ignore valid empty MCP SSE priming events before JSON parsing

**Impact:** A compatible Streamable HTTP MCP server can fail initialization, tool listing or tool calls solely because it sends the protocol's empty opening SSE event.

**Evidence:** [HTTPMCP][mcp-events] parses every emitted SSE data string as JSON. [SSEParser][sse-parser] emits an empty string for an event containing `data:` followed by a blank line. The [MCP 2025-11-25 transport specification][mcp-spec], which the client [explicitly offers][mcp-version], recommends an initial event with an ID and empty data to prime resumability. That event is transport control information, not a JSON-RPC payload.

**Minimal response:** Send Content-Type: text/event-stream, then the following priming event before the ordinary matching JSON-RPC response:

```text
id: prime-1
data:

```

The parser produces an event with data=""; HTTPMCP immediately attempts JSON parsing and throws before consuming the valid response that follows. An empty-event algorithm model confirmed this at all 131 possible two-packet splits of its fixture; a comment-only heartbeat was correctly ignored. Native URLSession execution was not run.

**UX-preserving fix:** Recognize empty SSE priming/control events at the MCP adapter and continue awaiting the matching JSON-RPC response. Keep malformed nonempty JSON as an error and preserve the no-automatic-invocation-replay policy. This fix does not require reconnecting or replaying a request.

**Regression acceptance:** With a loopback fixture, return the priming event followed by valid initialize, tools/list and tools/call results, including bytes split across arbitrary chunk boundaries. Assert success and no duplicate tool invocation. Include comments/keepalives, notification interleaving, malformed nonempty JSON and EOF without a response.

## Suggested implementation order

1. Fix literal Git paths, then protect connection routing and accepted/draft data
2. Implement and test journal rebinding together with connection-switch serialization, while keeping their distinct regression cases
3. Fix capture cleanup and nested-code identities
4. Add bounded-work tests before changing file syntax and Markdown matching
5. Add the MCP transport interoperability fixture

Each change can retain the present UX. The target is correct destinations, preserved work, exact displayed/copied content, and less internal work for the same output. No redesign, additional feature, speculative optimization or already-accepted release exception is included in the ten findings.

<!-- source-references -->
[git-discard]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/bello-views/Sources/GitView/GitService.swift#L580-L586
[git-execute]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/bello-views/Sources/GitView/GitService.swift#L158-L168
[git-commit]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/bello-views/Sources/GitView/GitService.swift#L588-L623
[git-actions]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Git/GitPanel.swift#L480-L487
[connection-switch]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceConnectionSwitch.swift#L26-L74
[host-open]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceHosts.swift#L159-L188
[connection-lease]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceConfiguration.swift#L5-L20
[helper-open]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/HostService.swift#L324-L338
[connection-test]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiAppTests/WorkspaceConcurrencyTests.swift#L181-L207
[model-switch-test]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiAppTests/ModelSwitchTests.swift#L96-L115
[queue-followup]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L167-L178
[queue-steering]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L141-L163
[queue-deliver]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L121-L139
[queue-mutators]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionQueue.swift#L28-L49
[queue-state]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionPersistence.swift#L360-L365
[queue-reopen]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/Sessions.swift#L284-L313
[queue-app-intent]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceRefresh.swift#L374-L383
[side-create]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceSides.swift#L106-L116
[side-discard]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceSides.swift#L196-L203
[side-transfer]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceDrafts.swift#L76-L94
[draft-flush]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceDrafts.swift#L53-L73
[saved-draft]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/SessionDisplay.swift#L550-L556
[send-guard]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceRun.swift#L36-L49
[host-path]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Workspaces/WorkspaceHosts.swift#L200-L223
[profile-binding]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/Profile.swift#L60-L62
[session-journal-open]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/Sessions.swift#L266-L275
[journal-binding]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/SessionJournal.swift#L123-L140
[capture-row-limit]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/CaptureDatabase.swift#L118-L138
[capture-gc]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive.swift#L698-L715
[capture-clear]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive.swift#L623-L636
[capture-begin]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive.swift#L165-L185
[capture-reconcile]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive.swift#L657-L695
[capture-chunker]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/CaptureArchive/CaptureChunks.swift#L4-L26
[capture-quota]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/ConfigurationVault.swift#L147-L151
[capture-unlimited]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Storage/ConfigurationVault.swift#L38-L41
[quote-identity]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/MarkdownTextDocument.swift#L226-L238
[code-sharing]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/MarkdownTextDocument.swift#L299-L319
[code-paragraph]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/MarkdownTextDocument.swift#L276-L294
[code-copy]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/NativeMarkdownSurface.swift#L969-L974
[quote-parser]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/TranscriptMarkdown.swift#L272-L292
[syntax-prefix]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Files/FileSyntax.swift#L11-L34
[syntax-load]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Files/FileSyntax.swift#L74-L94
[file-fetch]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/bello-views/Sources/FileView/FileDocument.swift#L1003-L1047
[syntax-scalars]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/SyntaxHighlighter.swift#L29-L37
[markdown-finalize]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/StreamingMarkdownState.swift#L85-L124
[markdown-mainactor]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/apps/macos/PiApp/Transcript/NativeMarkdownSurface.swift#L365-L380
[mcp-events]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/MCP.swift#L297-L327
[mcp-version]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/MCP.swift#L450-L453
[sse-parser]: https://github.com/BelloWare/BelloAgent/blob/f084047cf3ab86d6fabeef2f2a1baa2829c082df/packages/swift-host/Sources/PiAgentCore/Transport.swift#L12-L35
[mcp-spec]: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server
