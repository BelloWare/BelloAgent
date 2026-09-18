# Bello Agent 0.1.19 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.19/build 23**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 16:58:48 UTC.**
Release source: `9b94e4df711d66ed35b7168fbceca669009e368e`. Website: `d37b88540c453ee808f930eb3bfe9525b8d01810`.

## Changed behavior

Version 0.1.19 completes a deeper review of Claude's recent changes and the
Settings-to-existing-chat catalog flow. It fixes clock-correction write loss,
quit and side recovery failures, non-atomic handoffs, false transcript paint/read
acknowledgements, command replay after ledger eviction and duplicated queued
messages after a partial journal commit. Response capture masks known credential
echoes across streaming boundaries and labels that transformation. Archive
maintenance avoids repeated whole-store sweeps; partial cache observations keep
paired sample coverage. Existing catalog lineage and explicit repair remain.
Unavailable live-export bodies cannot be misrepresented as empty captured files.
See the [review and remaining limits](../Deep-Review-2026-09-17.md).

Claude's eight commits through `c40f89d` were reviewed and retained. The repository
session had finished, with no child processes, before concurrent editing began.
The review covers actual native persistence, helper mutation/queue recovery,
transcript acknowledgement and failure delivery, catalog authority, request
accounting and archive maintenance. The [review](../Deep-Review-2026-09-17.md)
records each confirmed failure and the explicit limits; it is not a claim that
every possible defect was eliminated.

The catalog checks retain the [0.1.18 diagnosis](../Issue-Stale-Chat-Model-Catalog.md):
new same-authority profile forks already inherit catalog lineage, and older
unbound chats have an explicit repair action. Settings save, existing-chat
refresh, mounted picker replacement rows, source choice and restart are covered.
Independent saved request connections and credentials are never silently merged.

## Acceptance checks

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
**29 transcript tests, TypeScript checking and 10 dependency-cache tests pass.**
Four native tests exercise the packaged React page in WKWebView, including
render rejection and recovery. Local HTTP/SSE fixtures validate requests, tools,
cancellation, compaction and capture; no deployed LiteLLM was used. No full
screenshot gallery or Release performance matrix was run. Installation/update
rehearsals were skipped by owner instruction.

| Log | Passed executions | Skipped | Failed cases |
| --- | ---: | ---: | ---: |
| `native.log` | 391 | 6 | 1 |
| `native-final.log` | 54 | 0 | 0 |
| `native-export.log` | 9 | 0 | 0 |
| `swift-host-tests.log` | 138 | 0 | 0 |
| `queue-regression-after.log` | 12 | 0 | 0 |

Native results are reconciled by case identity in ordered `native.log` and
`native-final.log` and `native-export.log`, with `native-results.json` matching
the parsed totals: **394 unique passes, six skips, zero unresolved failures**. The broad run's
one accounting-scale case failed two assertions because its expected value
omitted the new paired sample field. The independent expectation was corrected;
the 54-case rerun includes that case and an added incomplete-capture regression.
The final nine-case export/release-configuration run adds a live-export regression
covering six unavailable states and a valid zero-byte complete capture. Missing
or omitted bodies stay absent from the export instead of creating an empty apparent original.

The helper's full 138-case run passed before the last queue checkpoint fix.
Both new follow-up/steering recovery fixtures failed against the prior behavior
in `queue-regression-before.log`, then passed with the fix in the 12-case
`queue-regression-after.log`. Combining the passing runs yields **140 unique
helper cases**, not 150. No pre-fix failed fixture is represented as passing.

Four native tests load the actual packaged React page in WKWebView. They exercise
injected DOM rendering failure, rejected input and reload through the native
content-process-termination callback. This is not an OS-induced process crash.
The 100,000-attempt / 300,100-link fixture preserves accounting; Debug timings
were 615.668 ms for its 101-message page, 56.579 ms for session totals and
62.737 ms for one message. These observations do not establish a Release UI
performance budget.

## Limits and preserved contracts

Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, full screenshot gallery, full Release performance matrix,
installation or actual Sparkle update/relaunch rehearsal was used. Optional
native visual/interactive captures remain explicitly skipped. Current context
counts remain estimates with the [documented provenance](../Context-Accounting.md).

Known response credential echoes are replaced only in the captured copy, across
stream boundaries, with same-length masking and explicit transformation metadata.
Parser input remains original; unconsumed error/cancel tails remain incomplete.
Historical capture files are not rewritten. Request authentication remains masked
and request-body known credential literals remain labeled SHA-256 transformations.

The broader bounded-history scroll-anchor redesign and the archive's finite
100,000-record limit remain. Trusted editing tools run with the user's account
permissions and are not an OS filesystem sandbox. Full-text captured-body search
remains deferred. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.19.dmg](https://belloware.com/assets/BelloAgent-0.1.19.dmg).
- Size: **7,288,456 bytes (6.95 MiB)**.
- SHA-256: `281e067d89759688af85390c0df5a37486b6a0620f76fe6ee6bb6e6e4bd3c0cf`.
- App notarization: `bb463770-8ebe-401c-ba8c-143924466030` (accepted).
- DMG notarization: `06dcc5be-5701-4594-b882-090356943458` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass.
The release validator and packaged helper/catalog smoke pass. Public
product/download, homepage discovery, legacy redirect, sitemap and unchanged icon
pass. Canonical and legacy appcasts are byte-identical, and both downloaded feeds
and the downloaded DMG exactly match the staged files. The DMG SHA-256 and Sparkle
Ed25519 signature are verified. Bundle ID `com.belloware.PiApp`, Keychain ownership,
history locations and updater signing identity remain unchanged.

Cloudflare build `47afe2f5-facc-4799-a629-76320bf673bc` completed successfully at 2026-09-16T16:58:03Z.

The recorded Cloudflare check has status `completed`, conclusion `success` and
`head_sha` equal to the exact website commit above. Release evidence was complete
before this acceptance record was written; a subsequent documentation commit
does not change the packaged source SHA.

Scratch evidence: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/deep-review-019`. Files: `native.log`, `native-final.log`, `native-export.log`,
`native-results.json`, `swift-host-tests.log`, `queue-regression-before.log`,
`queue-regression-after.log`, `transcript-tests.log`, `typecheck.log`,
`dependencies-test.log`, `release.log`, `publish.log`, `public.log`, `pages.log`,
`deployment.json` and `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.P8nhnJ`.
Historical [0.1.18 evidence](Bello-Agent-0.1.18-2026-09-16.md) remains unchanged.
