# Actual interactive context-rejection recovery: PASS

Validated the sealed ordinary all-feature debug binary via official CUA mouse and native keyboard events on the cloud Linux desktop. No debug-state injection, seeded session/catalog, user Mac, native credentials or paid service was used. The normal UI created and trusted the fixture project and selected its saved loopback connection before Send.

## Observed workflow
1. Explicit Send “Build synthetic long history” produced the actual synthetic warmup response and provider-reported 20 input / 12000 output.
2. Explicit Send “Continue the synthetic task” produced a structured context rejection (HTTP 200 JSON error envelope), retained the failed attempt and dispatched exactly one summary request.
3. While the server held the summary, the UI visibly showed Context rejected · Summarizing… and the retained failed-attempt row. The durable receipt recorded summarizing, one summary attempt and zero retries. Reported usage was 131 (partial) input / 12000 (partial) output.
4. After explicit fixture release, one automatic retry completed. Screenshot 08 shows the retained failed attempt, retained summary response, durably adopted checkpoint and final original-task continuation labeled Retried after compaction.
5. The terminal durable receipt is completed, with one summary and one retry, resolved_reply_id matching retry_reply_id; the session is idle, with no pending work or error. Exactly four physical requests were recorded including warmup.

## Evidence and truthful usage
Original unmodified screenshots 01–08, request-1.json through request-4.json, warmup/held/final session snapshots, public fixture profile and gateway, source SHA-256 manifest and VALIDATION.json are alongside this report. Request 3 includes intact long history; request 4 includes the adopted summary plus retained original continuation without the replaced long history. Checkpoint estimates 13622 → 605 are estimates, not reported usage. Final reported usage is 281 input and 12030 (partial) output; rejected request output is unknown, not zero. Cost remains n/a.

## Limitations and startup correction
The initial fixture profile lacked required explicit text/image capabilities, so the normal constructor refused startup before session/catalog creation. Original failure logs are preserved under initial-profile-failure. The fixture owner corrected only the public profile declaration; the same sealed binary then launched. Paste APIs were unavailable, so text was entered using official native key events. The fast retrying intermediate state was not separately captured; physical request 4, terminal receipt and visible final response establish completion. No Stop scenario or full-process reopen was performed. This is synthetic cloud Linux interactive evidence, not native macOS, security, performance or production-provider acceptance.
