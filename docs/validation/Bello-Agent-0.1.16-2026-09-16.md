# Bello Agent 0.1.16 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.16/build 20**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 14:59:06 UTC.**
Release source: `f680fc8cc4ac77a7efdd007cc319ced2bedf319f`. Website: `d501b2a2f5f7c3100a53a0805b6295f311a0f1fc`.

## Changed behavior

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

Tool summaries retain running/error/aborted status while details remain collapsed.
User-opened disclosures stay open across completion and output updates; remounted
rows return to the default collapsed state. Copy/request actions remain available.
The weighted average covers all eligible retained completed requests; the chart
remains bounded to 128 samples, with missing measurements and coverage explicit.
Failed runs retain a bounded sanitized error in their journal. HTTP JSON and SSE
failures preserve useful provider messages/codes while masking known credential
echoes before truncation. Queue pause is independent of Error, and reopening,
removing a queued item or cancellation cannot silently retry failed work.

## Focused acceptance

**74 unique focused native tests passed**, with
1 optional capture skip and zero failures. The initial native run executed
75 cases (74 passed, one skipped); the final Stop run rebuilt the app and repeated
five follow-up cases. Repeated cases are counted once. **115 unique helper tests,
27 transcript tests and 9 WebKit disclosure checks passed**; TypeScript passed.
Loopback HTTP 429/SSE failure fixtures verify useful errors, credential masking,
no automatic retry and exact captured bytes. Native coverage includes retained
errors, weighted timing and actual wide/narrow footer rendering with OCR.
No manual Stop click, screenshot gallery or full interactive gateway run is claimed.
Installation/update rehearsals were skipped by owner instruction.

| Log | Passed executions | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `native.log` | 74 | 1 | 0 |
| `stop-native.log` | 5 | 0 | 0 |
| `helper-errors.log` | 113 | 0 | 0 |
| `helper-errors-integration.log` | 3 | 0 | 0 |

Across repeated logs, native cases total **74 unique passes plus
1 optional skip**, and helper cases total **115 unique passes**.
The native optional screenshot capture skipped because its opt-in environment was
not forwarded to the test runner. The wide/narrow/missing-value footer OCR test
still ran and passed. No saved screenshot gallery or manual screenshot inspection
is claimed. The final Stop run validates compilation and existing session-scoped
follow-up/cancellation behavior; it does not establish a physical Stop-button click.

Transcript: **27 passed**, zero failures. Actual WKWebView disclosure fixture:
**9 checks passed**, using programmatic summary activation and measured layout:

- Running call and retained result start collapsed.
- Both summary toggles reveal details.
- WebKit lays out tool input/output only after expansion.
- Manual expansion survives completion and output update.
- Expanded result displays current output.
- Manual collapse survives a running update.
- Collapsed results remain compact after updates.
- Disclosure indicator is visible.
- Restored rows also default to collapsed.

The helper's 113-case run was followed by two new actual HTTP error tests and a
repeat of the existing connection-probe test after its shared loopback fixture
changed. Tests assert one attempt, no automatic retry, failed outcomes and HTTP
status, exact wire/capture bytes, and masking of both API-key and custom-header
credential echoes in displayed errors. Fixtures use synthetic credentials only.
TypeScript `npm run typecheck` exited 0. Unchanged broader UI/catalog/accounting,
performance and prior interactive evidence is reused from existing versioned
records. No full gallery, deployed LiteLLM, installation, Sparkle update/relaunch
or signed owner/update rehearsal was performed.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.16.dmg](https://belloware.com/assets/BelloAgent-0.1.16.dmg).
- Size: **7,167,470 bytes (6.84 MiB)**.
- SHA-256: `33335dc999e633db7e395ae688daddb0044dfea53c143052a8d46bbf0bba4cbb`.
- App notarization: `1b38c78d-9ac2-45fa-a27c-40aca770dce2` (accepted).
- DMG notarization: `d67a9801-5adc-4721-8a7c-c5988605d887` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Product/download, home, legacy
redirect, sitemap and unchanged icon pass. Canonical/legacy feeds are identical;
the downloaded archive matches SHA-256 and Sparkle Ed25519 verification.
Bundle ID, Keychain ownership, saved history, selected icon and updater identity
are preserved.

Cloudflare build `fb45035f-c542-4189-973b-48c5f435a7f3` completed successfully at 2026-09-16T14:58:31Z.

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/tool-results-016`. Logs: `native.log`, `stop-native.log`, `helper-errors.log`,
`helper-errors-integration.log`, `transcript.log`, `webkit.log`, `typecheck.log`,
`release.log`, `publish.log`, `public.log`, `pages.log`, `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.AqLbmP`.
The unrelated Claude review `docs/Code-Review-2026-09-16.md` remains untouched.
Publication uses a clean temporary source worktree. This later documentation-only
commit records completed checks; the packaged source SHA above remains exact.
