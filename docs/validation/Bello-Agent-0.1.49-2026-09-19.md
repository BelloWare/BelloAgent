# Bello Agent 0.1.49 acceptance

Date: 2026-09-19 (Asia/Singapore). Branch: `main` in `BelloWare/BelloAgent`.
Version **0.1.49/build 53**. Environment: macOS 14.8 arm64,
Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

**Public release verified at 2026-09-18 18:10:02 UTC.**
Release source: `b59a34a63bc4f174fddb2cd5c4ae5068ba6c834d` (local `main` commit under the
owner's source-push policy). Website: `69520c61e62bc4e4b3152296ced8ebfbee6c72d8`.
Later documentation commits do not change the packaged source.

## Review and changed behavior

Claude's 0.1.48 work, child processes and website deployment finished before
this review started. Its completed baseline was
`ef49e00a130665df2b6e4ffc686b4209ad8e6217`.
The [review findings](../Deep-Review-2026-09-19.md) describe the confirmed
failures and regression coverage in detail.

This release fixes queue-removal crashes across suspended delivery, retry
ordering, interrupted tools with reused call IDs, incompatible live session
bindings, and prepared output limits that differed from dispatch. Native fixes
cover transcript positioning, stale JSON selection callbacks, numeric traps,
blocked helper/terminal shutdown, callbacks from retired connections, terminal
actor isolation, damaged captures and cancelled exports. Connection deletion
revokes already-suspended operations while preserving drafts. Concurrent context
previews share a readable snapshot. Metadata handles close on failed
initialization, explicit close and deallocation.

## Acceptance checks

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Complete native suite (498 cases) | 491 | 7 | 0 |
| Swift helper suite | 170 | 0 | 0 |
| Python release/fixture checks | 52 | 0 | 0 |
| Local HTTP/SSE/MCP gateway checks against the Release helper | 24 | 0 | 0 |

The final native run completed at 2026-09-18 18:01:11 UTC. The preceding
68-case focused pass is included in the complete suite and is not counted
again. The final Debug tests and Release app build both compile with Swift 6
strict concurrency. No runtime actor-isolation or null-SQLite-handle warnings
occurred in the final native run. The seven opt-in visual/interactive tests
were skipped; no full gallery or performance matrix was repeated.

Verification found additional defects before publication: a terminal's final
exit callback could be lost after its owner was released, rejected connection
sends could skip durable draft saving, and automatic context preparation could
replace the inspector's revision during startup. These were fixed and covered
by the passing final run. Test compilation also caught SDK pointer/Sendable
issues, corrected without disabling strict checking. An intermediate focused
run passed but could not finish its Xcode result bundle; the final complete run
uses a dedicated temporary directory and saved `native-final.xcresult` normally.

Synthetic local fixtures verify requests, streamed responses, tools,
cancellation, compaction and byte capture. No deployed LiteLLM or production
credentials were used. Installation and actual Sparkle update/relaunch
rehearsals remain skipped under the owner's standing instruction.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.49.dmg](https://belloware.com/assets/BelloAgent-0.1.49.dmg).
- Size: **7,222,143 bytes (6.89 MiB)**.
- SHA-256: `e10cf9b7e2df730192801124b942e51138b92c269ebcb25e891c8d2628938aae`.
- App notarization: `ae90b3f0-a91e-48cc-96da-f55875220c24` (accepted).
- DMG notarization: `5f9a9ab9-9bcd-47ec-a17e-6bee11396f82` (accepted).

Developer ID signing, hardened runtime for executable code, notarization,
stapling and Gatekeeper validation pass. The existing Clipboard-style signing
and ordinary Keychain approach is retained. A transient DMG timestamp-service
failure succeeded on retry; no unsigned or untimestamped fallback was used.
The packaged helper/catalog smoke and version/build/feed validators pass.
Bundle ID `com.belloware.PiApp`, history locations, icon and Sparkle signing
identity remain unchanged.

The website commit was pushed and Cloudflare's `Workers Builds: belloware`
check 105708597599 completed successfully. The public feed initially
served 0.1.48 during deployment. `scripts/verify-published.py` then confirmed
the exact staged canonical and legacy feed bytes, downloaded DMG SHA-256 and
Sparkle Ed25519 signature. The product page's 0.1.49 download was also checked.
The same signed DMG was copied to the session outbox for download.


## Evidence

Scratch review root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/review-post-claude-20260919`.
Final logs: `native-final.log`, `native-final.xcresult`,
`native-focused-after.log`, `helper/full-after.log`, `python-tests.log`,
`native-host-tests.log`, and `release-build-final.log`. Earlier failing logs
are retained alongside the corrected runs. The helper and native UI audit
subdirectories retain the queue fatal-signal and numeric/scroll reproductions.

Stable build/release root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.
Both production dSYMs are retained beside the versioned release artifacts.

Distribution evidence: `release.log`, `publish.log`, `public-verification.log`,
`cloudflare-check.json`, `artifacts.json`, `public-product.json`,
`build/release.S4AAjk/` and `build/releases/0.1.49/` under the roots above.
