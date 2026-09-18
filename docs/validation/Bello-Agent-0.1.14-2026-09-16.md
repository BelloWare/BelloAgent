# Bello Agent 0.1.14 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.14/build 18**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 14:00:20 UTC.**
Release source: `2542f31b3992fa1011008c0f317917eb2fcea105`. Website: `d4ba4e3411d17a6bc0d1f8a11cb04bcd43a85781`.
Feature commits: `797dc53` (catalog sources), `f11093c` (automatic context).

## Changed behavior

Version 0.1.14 calculates prepared context automatically when a safe idle
chat opens, using the local helper without sending a model request or executing
tools. Matching estimates are reused; cancelled or changed inputs cannot publish
stale results. Unsent chats retain their allocated journal across helper eviction.

Catalog lists now resolve independently of preserved request connections.
New same-authority default-model forks keep catalog linkage; older chats can
choose a saved custom catalog through **Catalog source…** in the model picker.
Refresh reloads saved bindings, requests HTTP revalidation and displays its
successful update time. Changing the list preserves the chat's request route,
credentials, selected model and effort. Legacy lookalike connections are not
automatically merged because their records contain no reliable lineage.

Context activation has a 180 ms debounce and a five-minute input-bound cache.
Only the focused eligible chat starts local work; no model request or tool/MCP
execution is needed. Active-context membership is replayed across branches,
compaction and explicit context records before accepting retained tool results.
Pending work, damaged history, untrusted projects and legacy/imported sessions
remain explicit inspection/recovery paths.

Catalog sources are validated flat references. All picker/effort/descriptor and
mini-model recommendation consumers resolve the same source. Gateway/API/key/
header differences prevent implicit fork linkage; explicit source selection is
allowed and uses that source's own credential-origin rules. External catalogs
remain anonymous. A follower editing its URL cannot take over unrelated sources.
Credential-only saves retain prior behavior. The provided refresh handler was
not independently reproduced as a pointer-event failure on the owner's MacBook;
the release addresses verified state/source behavior and adds HTTP revalidation.

## Focused acceptance

**98 unique focused native tests passed with zero failures.** The catalog/
configuration run passed 71 cases in 9.523 seconds; the final context/workspace
run passed 34 cases in 2.144 seconds, including seven repeated catalog-source
cases with strengthened credential assertions. Counts are not added twice.
The packaged-helper fixture verifies automatic calculation, no model request,
no message/queue changes, durable unsent journal paths and unchanged bytes after
helper reopening. Local catalogs verify refresh, metadata and credential scope.
Unchanged provider/transcript/capture evidence is reused from 0.1.13 and earlier
records. Installation/update rehearsals were skipped; the owner will test on
their own MacBook.

| Suite | Unique cases | Final suite seconds |
| --- | ---: | ---: |
| CatalogSource | 7 | 0.301 |
| ConfigurationVault | 13 | 0.064 |
| ModelCatalogEndpoint | 19 | 7.863 |
| ModelSwitch | 15 | 0.533 |
| ReleaseConfiguration | 4 | 0.013 |
| SettingsSave | 6 | 0.179 |
| TitleGeneration | 7 | 0.436 |
| AutomaticContext | 5 | 1.200 |
| ContextAndSkillPolicy | 8 | 0.269 |
| Workspace | 14 | 0.373 |

The first new context-test compile failed because selected SessionDisplay was
optional; test unwraps were corrected before the successful final run. No product
failure was hidden. Review also found and corrected a catalog follower takeover
and a global-journal versus active-context tool-pair safety mismatch before release.
Native picker rendering is covered by existing local fixtures; no physical click
or end-to-end hover gesture is claimed. No full gallery, deployed gateway,
installation/update/relaunch or signed owner/update rehearsal was run.
Full-text body search remains deferred. No production keys were used in fixtures.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.14.dmg](https://belloware.com/assets/BelloAgent-0.1.14.dmg).
- Size: **7,135,182 bytes (6.80 MiB)**.
- SHA-256: `d7d6a198f26f87a7d044b206ab38009843c1d40b4cb70290142e42f708b380a2`.
- App notarization: `1f708ed6-4f0d-4da8-b11e-e70344d506f7` (accepted).
- DMG notarization: `0a9b79c6-3b1a-4f1f-85c1-4796a38db2fd` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Product/download, home, legacy
redirect, sitemap and unchanged icon pass. Canonical/legacy feeds are identical;
the downloaded archive matches SHA-256 and Sparkle Ed25519 verification.
The selected icon is unchanged, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/context-catalog-014`. Logs: `catalog-native.log`, `context-native-final.log`,
`release.log`, `publish.log`, `public.log`, `pages.log`, `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.q9WMZN`. The unrelated Claude review
`docs/Code-Review-2026-09-16.md` was preserved unmodified and uncommitted.
Publication used a clean temporary source worktree. The later documentation-only
commit records completed checks; the packaged source SHA above remains exact.

Cloudflare build `325b0ace-4d29-4be7-9a0e-9c8570386fcc` completed successfully
at 2026-09-16 13:59:13 UTC; public verification followed at 14:00:20 UTC.
The page still served 0.1.13 during deployment; the final verification was run
after completion. A Python urllib availability probe returned HTTP 403; the
standard curl-based public verification passed.
