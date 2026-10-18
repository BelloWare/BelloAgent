# 0.1.130 security boundaries

Workstream `dev/a130-security`, based on `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. Worktree `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security`; build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. macOS 14.8 (23J21), Apple Git 2.39.5, Xcode 16.1. Generated repositories and ephemeral loopback servers only; no installed-app launch, real credentials, Keychain, live capture, paid calls, release, tag, or upstream integration.

## Fixed instances and policy

The owner decisions below supersede the initial `fc82085a` policies. Earlier evidence is retained under the initial-validation headings; the review follow-up at the end records the new implementation and results.

1. **SECURITY-BOUNDARIES-1a (P0), folder tree/menu and Quick Open:** outside/untrusted folders retain the confined Git launcher and `core.fsmonitor=false`. Trusted folders use fresh Git scope/origin metadata to override local/worktree programs, preserving global/system fsmonitor.
2. **SECURITY-BOUNDARIES-1b, Git status/index queries:** the same policy covers Changes, ignored paths, snapshots, preflight and blame. Status/diff inventory initialized submodules so inherited command-line overrides cover their local programs too.
3. **SECURITY-BOUNDARIES-1c, executable content filters:** trusted reads run without an execution sandbox. Local/worktree clean/smudge/process commands are neutralised; matching user-owned settings are restored from global/system scope. Repository attributes may select global filters, including required conversions. Outside/untrusted reads retain the execution/network/write sandbox and surface failed conversions.
4. **SECURITY-BOUNDARIES-1d, textconv:** working/staged/untracked/history/stash/hunk diffs and commit statistics retain their no-textconv/no-external-diff switches. Trusted configuration overrides also cover local diff drivers.
5. **SECURITY-BOUNDARIES-1e, implicit promisor fetch:** every read sets `GIT_NO_LAZY_FETCH=1` and `GIT_ALLOW_PROTOCOL=`; the latter also defeats per-protocol config allowances. Outside/untrusted queries additionally have no network or non-Git executables.
6. **SECURITY-BOUNDARIES-1f, sparse-index folder queries:** FileFinder uses the same launcher; missing sparse trees cannot start a remote helper. Metadata inventory uses `ls-files --stage --sparse` under confinement.
7. **SECURITY-BOUNDARIES-1g, untrusted manual writes:** both controller write admissions retain the live trust/root check and existing trust notice, including revocation after review. Already dispatched trusted writes retain their existing lifetime.
8. **SECURITY-BOUNDARIES-1h, signature verification:** ordinary history/commit details retain disabled signature display. Trusted reads also override local `gpg.program` and `gpg.<format>.program` settings.
9. **SECURITY-BOUNDARIES-2, webhooks:** all redirects remain refused. Original 3xx responses fail permanently without forwarding payloads/headers or retrying.
10. **SECURITY-BOUNDARIES-2b, Git redirects and the review P1:** Git follows `initial` redirects for remotes without extra headers. Git resolves effective remote URLs and URL-matched `http.extraHeader`; protected URLs receive `followRedirects=false`, including existing URL-scoped redirect settings. Generic refusal alone was bypassable. A refused redirect reports that `http.extraHeader` requires the final remote URL.

### Owner decisions (verbatim)

> 1. Background/read-only Git in TRUSTED projects: programs configured in the user's global or system Git config may run (e.g. Git LFS clean/smudge/process filters, a global fsmonitor), but programs configured inside the repository (local `.git/config`, worktree config, and any include/includeIf files resolved from local config) never run during Bello's background reads. Detect origins with `git config --show-scope --show-origin` (or equivalent) and neutralise local/worktree-scoped program settings with `-c` overrides (filters, fsmonitor, textconv/diff drivers, gpg.program and signature display, sshCommand, credential helpers, pager/editor, remote helpers/lazy fetch). Repository `.gitattributes` choosing a globally configured filter is fine. Keep fsmonitor/lazy-fetch/textconv defences where they do not break this. UNTRUSTED or outside-project folders: fully confined as you implemented (sandbox allowed there). Do NOT sandbox trusted-project reads if that blocks global programs like git-lfs. Test: a trusted LFS-style repo whose global-scope filter runs (fixture global config via GIT_CONFIG_GLOBAL in the test env, never the real ~/.gitconfig) and whose local-scope hostile filter/fsmonitor/hook does not.
>
> 2. Git HTTP redirects: follow redirects as Git normally does (`initial`), but refuse redirects (and fail with a clear message) for remotes that have an `http.extraHeader` configured at any scope, including URL-scoped `http.<url>.extraHeader`; when refusing, also override any URL-scoped `http.<url>.followRedirects` (the review finding below). Renamed-repo style same-host redirects without extra headers keep working.
>
> 3. Git writes in untrusted projects: refused with the trust notice, as you implemented (keep).
>
> Webhooks refusing all redirects: keep.

**Explicit writes:** Stage/Unstage/Discard, branch mutations, stash mutations, fetch/pull/push, commit/amend/reword and hunk publication retain normal hooks, filters, signing and transports after trusted admission. Reword's hook-path query remains a confined data query and returns the actual configured path. Read overrides never reach a later write. No new entitlement, preference, helper capability or production test bypass is added. Minimum/current macOS packaging compatibility remains part of the lead's release gate.

## Subprocess sweep

Scope: all production process launch sites in `apps/macos/PiApp`, `packages/bello-views/Sources` and `packages/swift-host/Sources`, plus all callers of their launchers. “Programs” below includes commands selected by repository config, attributes and included configuration. All Git stdout is piped; reads additionally force `--no-pager`. Config includes can supply all listed settings but do not themselves execute commands.

| Launcher / operation | Command(s) | Working directory and trust | Repository-controlled execution paths and disposition |
| --- | --- | --- | --- |
| FileFinder tool availability | `/usr/bin/xcode-select -p` | Inherited app directory; no repository lookup | Xcode selection only, no Git config/hook/filter/pager/editor/transport. |
| FileFinder repository detection | `git rev-parse --show-toplevel` | Arbitrary browsed folder, outside projects allowed; also nested repositories | Reads local/included config; no object/index conversion. Local fsmonitor is overridden; global/system fsmonitor is allowed only in trusted folders. Outside/untrusted paths remain confined. |
| Quick Open recursive listing | `git ls-files -z --cached --others --exclude-standard` | Project folders and nested repositories/submodules; nested repos need not be independently trusted | Index can invoke fsmonitor (fixed). No clean/smudge/process conversion, diff driver, hook or editor is requested. Sparse-index expansion cannot fetch: lazy-fetch/protocol guards apply in both trust states. |
| Folder tree and breadcrumb menus | `git check-ignore -z --stdin`, repository detection | Arbitrary folder reached from a file card, including absent/untrusted project | Index fsmonitor (fixed); ignore decisions are data. No diff/conversion, hooks or editor. Sparse-index missing-tree transport is disabled in both trust states. Shared FolderDirectory covers both tree and menu. |
| Non-repository ignore fallback | `git config --path --get core.excludesFile` | Walked folder, outside projects allowed | Reads global/local includes as data; uses configured ignore file without executing programs. |
| Scope/origin and redirect inventory | `config --null --list --includes --show-scope --show-origin`, a second `--name-only` inventory, `ls-files --stage --sparse -z`, `remote get-url --all [--push]`, `ls-remote --get-url`, `config --get-urlmatch http.extraHeader` | Selected repository and initialized submodules; inventory itself always confined, including trusted projects | Fixed data queries only. No index monitor or transport may execute while identifying config. Scope is inherited through includes; origin/name records must match between inventories. Remote aliases, push URLs, `insteadOf` and URL-specific header matching are resolved by Git. |
| Git read-only tool resolution | `/usr/bin/xcrun --find git` | `/`, clean environment, once per process | Selects developer Git; no repository-controlled PATH, cwd, `DEVELOPER_DIR`, or config. |
| Git root/state/index | `rev-parse`, `symbolic-ref`, `status --porcelain=v2`, `ls-files` | Selected project root; public library root can be arbitrary. File blame also uses this service | Local/worktree fsmonitor and filters, including submodule programs, are overridden. Global/system programs run only for trusted reads. Optional index locks and implicit Git transports remain disabled. |
| Git history and branch catalog | `log`, `show`, `for-each-ref`, `rev-list`, `merge-base`, `reflog show`, `branch --list`, `remote`, `worktree list`, `check-ref-format` | Project/repository root | Textconv/external diff disabled for patches/stats; signature display disabled. Missing-object fetch, SSH/credential/remote helpers blocked; pager forced off, no editor. Includes and branch config still read as data. |
| Changes panel and file history diffs | `diff` (working, cached, no-index), `show` | Project root; no-index untracked path under the same root | External diff/difftool and textconv disabled; trusted global/system clean/process conversions remain available; local/worktree commands are overridden. Outside/untrusted conversions remain confined. No smudge requested. |
| File viewer blame | `blame --no-textconv --contents -`, `log`, `rev-parse` | The file's repository; outside configured projects can be viewed | Content filters, fsmonitor and missing objects covered. No file bytes are handed to helper/model by this path. |
| Stash inspection | `stash list`, `diff`, `show`, `ls-tree`, `rev-parse`, `config --get extensions.refStorage` | Project root | Internal Git child for `stash list` is allowed; local program settings are overridden in trusted reads, and outside/untrusted reads stay confined. Textconv/external diff disabled; implicit remote access blocked. |
| Commit preview and hunk review | status/index reads; `diff --check`, `check-attr`, `cat-file`, `ls-tree`; raw `diff --no-index` in private scratch | Project root or generated temporary patch directory | No commit hooks during preflight. Filters/driver/fsmonitor use the trust/scope policy; implicit fetch is disabled. Hunk content-attribute refusal is retained. Raw diff uses isolated config and no external driver/textconv. |
| Watchers, Files and folder menus | FSEvents/vnode callbacks -> launchers above; GitWatcher reads `.git`/`commondir` metadata directly | Watched repository/file roots; folder browser may be outside projects | No additional subprocess launcher. Refresh queries inherit the same policy. |
| Reword identity and configuration reads | `var GIT_COMMITTER_IDENT`, `config --get commit.gpgSign`, `config --path --get core.hooksPath`, `rev-parse --git-path hooks` | Project/repository root, before an explicit trusted write | Hook/signing configuration is read as data under confinement; identity reads follow the same trust/scope policy. Only the later admitted mutation may execute the configured signer/hook. |
| Explicit Git mutations | `add`, `restore`, `reset`, `rm`, `clean`, `switch`, `branch -m/-d/-D`, mutating `stash`, `fetch`, `pull`, `push`, `commit`, reword plumbing (`read-tree`, `write-tree`, `interpret-trailers`, `commit-tree`, `update-ref`, `hook run`), hunk `hash-object -w --no-filters`/`update-index` | Trusted project chosen through existing UI | Normal fsmonitor, hooks/core.hooksPath, clean/smudge/process, SSH/credential/remote helpers, signing and includes retained where Git uses them. Git HTTP redirects use `initial` unless effective extra headers require refusal; no automatic/background mutation is newly authorized. |
| Reword post-rewrite | Resolved `core.hooksPath/post-rewrite`, argv `amend`, stdin old/new hashes | Explicit Reword in trusted project | Existing intentional hook execution retained; hook path read itself is confined. |
| App helper launcher | Bundled `pi-native-host` via HostTransport | Trusted project/session cwd, or a generated temporary directory for ConnectionProbe | Fixed app helper, no repository-selected executable. Context/read/find/grep tools use native filesystem code, no hidden Git subprocess. |
| Terminal | Configured login shell via `forkpty`/`execve` | Selected workspace path; TerminalRegistry itself does not check project trust | Intentional shell execution through the terminal UI; login-shell configuration and user commands may invoke Git with normal config. Not a Bello background/read-only query. |
| Helper bash tool | `/bin/bash --noprofile --norc -c <authorized tool command>` via ManagedChild | Bound workspace cwd | Existing bash-tool permissions govern execution. Can intentionally run Git and its configured programs; no permission or environment widening. |
| Helper MCP stdio | Explicit enabled server command/args via ManagedChild | Bound workspace cwd | User-configured executable capability, including its own config/tool behavior, under existing MCP gates. Not an implicit file-viewer or Git query. |

## Outbound HTTP sweep

| Path | Data sent | Redirect boundary | Loopback evidence |
| --- | --- | --- | --- |
| WorkspaceWebhooks completion / Send Test | Rendered URL, custom headers, token/chat/request/reply body | New session delegate rejects all 3xx; original response fails permanently | `WebhookTests.testRedirectsNeverForwardWebhookPayloads`: two ports plus same-origin target, 301/302/303/307/308, no second request, no retry. |
| ModelCatalogEndpoint.fetch | GET; optional Bearer key only when initial scheme/host/effective port match the gateway | Existing per-task `RefuseCatalogRedirects`, rejects 3xx | Existing ModelCatalogEndpointTests two-server redirect test, rerun. |
| GatewayModelDiscovery.models | GET models, Bearer gateway key | Existing per-task `RefuseModelDiscoveryRedirects`, rejects 3xx | Existing GatewayModelDiscoveryTests two-server and same-origin refusal tests, rerun alone. |
| ProviderClient (main/side/subagent/title/summary/compaction) | POST model requests, messages/tool context/images, Authorization and configured headers | Existing HTTPStream delegate rejects all redirects; pooled tasks explicitly set that delegate | New HTTPRedirectTests covers pooled and unpooled streams across all five redirect codes, preserving original status and zero sink requests. |
| ConnectionProbe | Synthetic model probe with configured credentials | Uses ProviderClient/HTTPStream above | Same transport coverage; no separate networking launcher. |
| MCP HTTP | JSON-RPC POST initialize/list/invoke/notifications/server replies; configured headers and MCP session/protocol headers | Existing unpooled HTTPStream delegate refuses redirects | New HTTPRedirectTests exercises real MCPManager setup for 307 and 308 across two ports; no RPC/header reaches sink. |
| Explicit Git fetch/pull/push | Git protocol body, credential-helper results, configured HTTP headers | Per-URL refusal when effective extra headers exist; otherwise `initial`. Existing URL-scoped redirect overrides are neutralised too. Git read transports are disabled. | `GitRepositoryPermissionTests.testGitFetchNeverForwardsPrivateHeadersAcrossOrigins`: two ports, 301/302/303/307/308, real system Git, zero sink requests. Review tests add URL-scoped overrides, all config scopes and a successful same-host rename. |
| Update checks outside Sparkle | None found | Sparkle owns the appcast update path; no separate app/helper HTTP updater | Source enumeration of URLRequest/URLSession/HTTPStream and launch sites. |

No other production HTTP client was found in these targets. Browser/external-link opening and intentionally configured stdio MCP/bash processes are separate user-authorized execution surfaces, not another internal HTTP transport.

## Initial regression and mutation evidence (`fc82085a`)

Text logs are in the build root's `logs/`; no named result bundle was requested. All test commands use this workstream's build root. Initial fixture compile corrections (optional URL/async XCTest autoclosure) were corrected before counting regression failures. Interrupted mixed-lane build attempts are not counted as validation; serial-lane classes are rerun individually.

- Before: FileFinder hostile monitor test failed 3 marker assertions in 1 test (two folder boundaries and Quick Open); native outside-project FileTab test failed 1/1 at the marker assertion after rows appeared.
- Before: webhook redirect test failed 20 assertions in 1 test: each code followed a redirect; cross-origin sinks received requests, and same-origin targets were followed. The 307/308 source request contains the generated private body and synthetic secret header.
- Before: generated clean-filter status and partial-clone object reads both wrote markers. The final expanded hostile fixture is rerun against the original implementation below to include includeIf and every read API.
- Sparse-index follow-up before confinement (fsmonitor already disabled): 1 test failed 2 marker assertions, one each for folder listing and Quick Open (`finder-sparse-before.log`).

The expanded Git baseline ran all seven new cases against the original five launcher/service files from `6fc551e1`: **6 cases failed, 20 assertions failed; 1 positive mutation case passed**. Restoring the fixes passed **7/7**. Reverting those same implementation files a second time reproduced **20 failed assertions**; all fixed bytes were restored. Logs: `security-original-baseline.log`, `security-restored-pass.log`, `security-original-mutation.log`. The failures name each operation: folder and Quick Open; clean/process × status/diff/blame; nested-submodule monitor; missing-blob remote; and status/working/staged/untracked/blame/ignored/snapshot/preflight in the combined fixture. `includeIf` loads an included config which supplies every hook/filter/driver. The marker is checked and removed after each operation, so an earlier failure cannot mask the next one.

| Instance | Failing regression / mutation oracle |
| --- | --- |
| 1a | `FolderBrowserTests.testListingsNeverRunRepositoryFSMonitor`; native `FileFolderTests.testOutsideProjectFolderDoesNotExecuteRepositoryMonitor` confirms the actual outside-project FileTab path and breadcrumb menu. |
| 1b | `GitRepositorySecurityTests.testReadOnlyQueriesNeverRunRepositoryPrograms`, `testNestedSubmoduleStatusKeepsGitChildrenButNeverRunsTheirMonitor`. |
| 1c | `testContentReadsNeverRunCleanOrProcessFilters`: all six combinations wrote markers before the fix. Existing `GitBlameTests.testAFilterThatChangesTheLinesIsRefused` also catches misleading fallback after an optional filter is blocked. |
| 1d | Combined fixture's untracked diff wrote the `driver` marker before the fix; working/staged paths share the explicit no-textconv options and confined launcher. |
| 1e | `testObjectReadsNeverStartPromisorRemotePrograms`: missing blob invoked the generated `ext::` remote before confinement. |
| 1f | `FolderBrowserTests.testSparseIndexListingsNeverStartPromisorRemotePrograms`: missing sparse tree invoked the remote through both listing APIs even with fsmonitor disabled. |
| 1g | `GitRepositoryPermissionTests.testOnlyATrustedProjectsExplicitWritesCanRunRepositoryHooks`: original and trust-check mutation each fail **6 assertions**; the fixed case passes. It checks untrusted refusal, trusted hook compatibility, and revocation before a reviewed write. |
| 1h | `testHistoryNeverRunsRepositorySignatureVerifier`: generated signed commit and marker-writing GPG program; history and commit-detail checks. |
| 2b | `testGitFetchNeverForwardsPrivateHeadersAcrossOrigins`: generated repository and private HTTP header, all five redirect codes. |
| 2 | `WebhookTests.testRedirectsNeverForwardWebhookPayloads`: original and delegate-removal mutation each fail **20 assertions**, fixed passes. Both ports and all five redirect codes are exercised, as is same-origin refusal. |

The native mutation run removes the webhook delegate and the app's trust predicate: **2 cases / 26 failed assertions** (`native-boundaries-mutation.log`); restoration passes the entire WebhookTests class and permission case, **19/19** (`native-boundaries-final.log`). Existing helper redirect protection was also mutation-tested: changing its redirect callback to accept the new request fails both new tests with **24 assertions**; restoring the original helper passes **2/2** (`http-helper-mutation.log`, `http-helper-restored.log`). Git HTTP redirects fail **5 assertions in 1 case** before the fix and again when the setting is mutated back to Git's `initial` redirect policy. The fixed permission/HTTP class passes **2/2** (`git-http-before.log`, `git-http-fixed.log`, `git-http-mutation.log`); the setting is restored before final verification. No helper production source remains changed.

The signature follow-up reruns the entire six-case GitRepositorySecurityTests class against original/fixed/original launchers: **17 failed assertions / 6 passed cases / 17 failed assertions**, with both history and commit-detail reads naming `signature-verifier` in the failed marker assertions. Logs: `signature-original-baseline.log`, `signature-restored-pass.log`, `signature-original-mutation.log`.

An intermediate full views run exposed the optional-filter fallback described in 1c; the final launcher now refuses that fallback. The first complete views run executed 321 cases (3 opt-in skips) and failed 7 assertions in 2 existing stash-race tests: their synthetic competing writes called the now-read-only `branchCommand`. Those two setup writes now explicitly use `readOnly: false`; the loss-prevention assertions are unchanged (`views-first-full.log`). The native cancellation fixture `GitOperationSafetyTests.testEditingTheDraftCancelsAnInFlightPreflightRead` also expected an executable content filter to start; the confined launcher correctly prevented that marker. Its wait now occupies the existing process queue with explicit synthetic commands, then checks draft-edit invalidation and unchanged file/index/HEAD; production confinement stays enabled. The initial run failed one assertion at line 291, recorded in `native-file-git-final.log`; the whole class is rerun after this test-only adaptation. Initial fixture-only corrections included updating the model's live `workspaces` array for trust changes and deferring scratch removal until SQLite teardown. Interrupted build/test attempts are not counted as final passes.

## Initial validation commands (`fc82085a`)

All commands run from this worktree. `B` below is `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. The native focus/gallery runs hold `/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`, write an identifying owner, and release it in `finally`, including on failure. Serial-lane classes run alone; no named xcresult bundle is requested. Xcode's ordinary temporary result directories are not the evidence; the text logs are.

```sh
xcodegen generate --quiet
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitRepositorySecurityTests|FolderBrowserTests/testListingsNeverRunRepositoryFSMonitor|FolderBrowserTests/testSparseIndexListingsNeverStartPromisorRemotePrograms'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --filter HTTPRedirectTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/WebhookTests -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/ModelCatalogEndpointTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/GatewayModelDiscoveryTests
```

The final full bello-views run passes **319 tests, 3 opt-in skips, 0 failures** (322 executed, 509.5 seconds), including all FileFinder and GitView classes and the new signature test (`views-final.log`). The three skips are explicitly enabled 100,000/500,000-file performance measurements.

`StreamingCostTests` runs alone as in the release verifier. The full helper result is **1,036 executed, 1,029 passed, 7 opt-in skips, 0 failed** (1,031/7/0 plus 5/0/0); logs `helper-full.log`, `helper-cost.log`. Skips are the fork-fixture writer and six explicitly enabled large-history/performance measurements. Native HTTP discovery/webhook verification passes **42/42** (WebhookTests 18, WebhookExchangeTests 5, ModelCatalogEndpointTests 19), plus GatewayModelDiscoveryTests **9/9** alone; logs `native-http-after.log`, `native-gateway.log`.

The final native focus run uses the following exact selection (one host, under the shared lock):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileBlameTests \
  -only-testing:PiAppTests/FileTabTests \
  -only-testing:PiAppTests/FileHiddenReadTests \
  -only-testing:PiAppTests/FilePageReadTests \
  -only-testing:PiAppTests/FilePreviewRefreshTests \
  -only-testing:PiAppTests/FileReviewStateTests \
  -only-testing:PiAppTests/GitBranchesInteractionTests \
  -only-testing:PiAppTests/GitChangelistReadTests \
  -only-testing:PiAppTests/GitCommitBrowsingTests \
  -only-testing:PiAppTests/GitConfirmationSheetTests \
  -only-testing:PiAppTests/GitDiscardQuestionTests \
  -only-testing:PiAppTests/GitHistoryFilterTests \
  -only-testing:PiAppTests/GitHunkReviewTests \
  -only-testing:PiAppTests/GitIntegratedHistoryTests \
  -only-testing:PiAppTests/GitOperationSafetyTests \
  -only-testing:PiAppTests/GitPanelAuditTests \
  -only-testing:PiAppTests/GitPanelDiffCaptureTests \
  -only-testing:PiAppTests/GitPanelLayoutTests \
  -only-testing:PiAppTests/GitPanelRedrawTests \
  -only-testing:PiAppTests/GitPanelShownTests \
  -only-testing:PiAppTests/GitPanelWidthTests \
  -only-testing:PiAppTests/GitPathBoundaryTests \
  -only-testing:PiAppTests/GitRenameTests \
  -only-testing:PiAppTests/GitToolTests \
  -only-testing:PiAppTests/QuickOpenPlacementTests \
  -only-testing:PiAppTests/ChangesTabTests \
  -only-testing:PiAppTests/WebhookTests \
  -only-testing:PiAppTests/GitRepositoryPermissionTests
```

Each serial class is then selected alone, under that lock:

```sh
for C in FileFolderTests FileFindTabTests QuickOpenTests GitWorkingTreeWatcherTests GitPanelTimingTests CrashAuditRegressionTests GitRepositorySwitchTests ChangesTabFrameTests GitDiffTableTests GitPanelNarrowParityTests; do
  PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO "-only-testing:PiAppTests/$C"
done
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/gallery" PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

The corrected cancellation fixture and the preview class are also rerun separately:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests
```

Each native command first runs `PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py`, through `test-macos.sh`, to obtain the Release helper. The three Python suites use only generated fixtures and loopback services.

The gallery passes **1/1** and writes **104 PNGs** under `$B/gallery`. The new `untrusted` scene is captured at 1180×780, 920×600, 700×640 and 310×600 in light/dark appearances. Inspected the new scene at 1180×780 and 310×600 in both themes: the trust notice is readable, with the existing narrow ellipsis and full-text tooltip (`GitPanel.swift:663`); the controls and list remain in their established layout.

## Initial adversarial self-review (`fc82085a`)

- Enumerated every production process constructor, exec/fork path, URLSession/URLRequest constructor, HTTPStream caller, and every GitService/FinderProcess call. The tables distinguish automatic reads from explicit shell/MCP/tool capabilities and trusted Git mutations. Source inventories are `source-boundary-sweep.txt` and `git-callsite-sweep.txt`.
- Tried configuration indirection, nested repository children, optional clean and process filters, textconv, missing blobs and sparse trees. Static config scanning cannot close a concurrent config/attributes replacement race; execution/network/write restrictions are inherited by Git children instead. Git's allowed executable paths are resolved from a clean `/`-cwd system-tool lookup, never a repository PATH or `DEVELOPER_DIR`.
- Reviewed every `readOnly: false` call: each belongs to an explicit write, including reword hooks and hunk index publication. The sole production GitController is created by ChangesTab with a live trust/root check. Both controller admission paths check it; preflight and automatic refresh remain confined. Trusted-action tests prove that normal hooks and filters still run where allowed.
- Considered a configured driver selecting the allowed Git binary itself: child Git remains denied network and writes outside private scratch, and cannot exec a shell/helper. Read failures have no unsandboxed fallback. Global/included ignore/config data remain readable.
- Checked URLSession and Git HTTP redirect handling, all redirect codes, POST preservation, custom headers, same-origin redirects, pooled task delegates, MCP initialization, and retry classification. Refusal occurs before a redirected request; original 3xx is not retried as a transient delivery failure.
- Checked cancellation/deadlines, output caps, scratch cleanup, native file boundaries and the existing blame refusal. The test-only shell aliases used for drain/cancellation/timing probes and synthetic competing stash writers now explicitly opt into execution; no production bypass or environment switch was introduced.

The owner has resolved the initial policy questions as quoted above. The lead owns integration, separate read-only review and the merged full release gate. No unrelated product fix is included.

## Initial unrelated validation failure

The final native selection hit `FilePreviewRefreshTests.testSiblingNotificationsLetTheActivePreviewPublish` at `apps/macos/PiAppTests/FilePreviewRefreshTests.swift:25`: after repeated sibling-folder notifications and release of the first image decode, the queued metadata recheck did not enter its test gate within 10 seconds (one failed case, two assertions). The preview-refresh test and production preview implementation are unchanged on this branch, and this image-only path does not invoke Git. Evidence: `native-file-git-final.log`. The unchanged class passes **2/2 in isolation** (`native-FilePreviewRefreshTests.log`). This is consistent with a fixture-order dependency: `WorkspaceModel.swift:557` installs a weak-model `FileTab.resolveProject` closure whose fallback is `.removed`, whereas this standalone fixture expects a nil project to mean `.none`. That cause is an inference, not a fix on this branch; the combined-run failure remains for the lead to triage. The production preview behavior and assertion are unchanged.

## Initial final validation counts (`fc82085a`)

| Suite / final selection | Passed | Skipped | Failed | Text evidence |
| --- | ---: | ---: | ---: | --- |
| Full bello-views | 319 | 3 | 0 | `views-final.log` |
| Full helper, including isolated StreamingCostTests | 1,029 | 7 | 0 | `helper-full.log`, `helper-cost.log` |
| Native, latest result of each of 42 affected classes | 382 | 2 | 0 | Class table below; repeated classes counted once |
| Release helper wire | 36 | 0 | 0 | `test-native-host.py.log` |
| Release helper concurrent | 4 | 0 | 0 | `test-concurrent-native-host.py.log` |
| Release helper acceptance | 3 | 0 | 0 | `test-native-acceptance.py.log` |

The first combined native selection executed 214 cases: **210 passed, 2 skipped, 2 cases failed (3 assertions)**. The obsolete filter-based cancellation fixture is adapted and its complete class passes **12/12**. The unchanged preview class passes **2/2** alone, as recorded above. Seven serial selections initially stopped at a test-only compile error (the inherited `eventually` method shadowed the async global helper); after qualifying `PiAppTests.eventually`, every one of those classes was rerun and passed. Their first build logs are retained as `native-<Class>.first.log`. No failed/aborted build is counted as a passing test run. The two final native skips are opt-in real-repository browsing measurements and the separate diff-pane capture; the changed trust scene was rendered and inspected through the enabled safety gallery.

| Native class | Passed | Skipped | Log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `native-file-git-final.log` |
| CrashAuditRegressionTests | 12 | 0 | `native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `native-file-git-final.log` |
| FileFindTabTests | 16 | 0 | `native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `native-file-git-final.log` |
| FilePageReadTests | 3 | 0 | `native-file-git-final.log` |
| FilePreviewRefreshTests | 2 | 0 | `native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `native-file-git-final.log` |
| FileTabTests | 16 | 0 | `native-file-git-final.log` |
| GatewayModelDiscoveryTests | 9 | 0 | `native-gateway.log` |
| GitBranchesInteractionTests | 20 | 0 | `native-file-git-final.log` |
| GitChangelistReadTests | 2 | 0 | `native-file-git-final.log` |
| GitCommitBrowsingTests | 3 | 1 | `native-file-git-final.log` |
| GitConfirmationSheetTests | 7 | 0 | `native-file-git-final.log` |
| GitDiffTableTests | 19 | 0 | `native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `native-file-git-final.log` |
| GitHistoryFilterTests | 14 | 0 | `native-file-git-final.log` |
| GitHunkReviewTests | 9 | 0 | `native-file-git-final.log` |
| GitIntegratedHistoryTests | 10 | 0 | `native-file-git-final.log` |
| GitOperationSafetyTests | 12 | 0 | `native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `native-file-git-final.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `native-file-git-final.log` |
| GitPanelLayoutTests | 4 | 0 | `native-file-git-final.log` |
| GitPanelNarrowParityTests | 8 | 0 | `native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `native-file-git-final.log` |
| GitPanelShownTests | 13 | 0 | `native-file-git-final.log` |
| GitPanelTimingTests | 4 | 0 | `native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `native-file-git-final.log` |
| GitPathBoundaryTests | 5 | 0 | `native-file-git-final.log` |
| GitRenameTests | 6 | 0 | `native-file-git-final.log` |
| GitRepositoryPermissionTests | 2 | 0 | `native-file-git-final.log` |
| GitRepositorySwitchTests | 17 | 0 | `native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `native-file-git-final.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `native-GitWorkingTreeWatcherTests.log` |
| ModelCatalogEndpointTests | 19 | 0 | `native-http-after.log` |
| QuickOpenPlacementTests | 1 | 0 | `native-file-git-final.log` |
| QuickOpenTests | 17 | 0 | `native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `native-http-after.log` |
| WebhookTests | 18 | 0 | `native-http-after.log` |

All mutation edits were restored, `git diff --check` is clean, and generated project metadata includes the new native regression class. Both owned full-lane runs released their lock in `finally`; no other owner’s lock was removed. No cloned test-host directories remain in this build root.


## Review follow-up: owner policies and URL-scoped redirect P1

The review P1 is confirmed. The previous generic `-c http.followRedirects=false` was overridden by matching URL-scoped config. The new two-server regression failed for all five redirect codes, and the previous blanket refusal also broke the positive same-host rename test: **2 tests, 11 failed assertions/errors** (`review-http-before.log`). The initial trusted-filter test failed **2 assertions in 1 test** because its fixture global filter could not run (`review-trusted-before.log`). The owner’s untrusted-write and webhook policies already matched the implementation; their admission/delegate logic remains unchanged and their native classes are rerun.

Trusted reads now resolve current project trust at admission, read Git scope/origin metadata afresh, and override local/worktree program settings (including local includes and initialized submodules). A global/system clean filter actually transforms fixture working bytes back into the indexed representation; status/diff complete and the diff is empty, while local filter/fsmonitor/hook markers remain absent. Global fsmonitor also runs through real folder and Quick Open listings, then stops being eligible when trust is revoked. Fixture configuration is supplied through `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`, never the real user config. Optional locks, implicit Git transports, textconv and automatic signature display remain disabled. Trusted Git can locate normal Homebrew-installed programs such as git-lfs; outside/untrusted reads retain the original sandbox.

HTTP transport inventories both generic and URL-scoped settings, including included/worktree settings and initialized submodule repositories. Git expands remote URLs (including non-origin defaults, push URLs, literal branch remotes and `insteadOf`); URL-matched extra headers determine refusal. HTTP schemes are recognised case-insensitively, and Git's `helper::address` form is checked using the address passed to the helper. Every existing matching URL-scoped redirect setting is overridden, and protected remote URLs receive an explicit refusal. Unrelated header scopes do not disable an ordinary remote’s redirects. A real empty-repository fetch succeeds through a same-host rename redirect. All 301/302/303/307/308 private-header cases are refused with the clear `http.extraHeader` message. This follows Git’s [scope and URL matching rules](https://git-scm.com/docs/git-config).

### Nearby inventory issues found and fixed before publishing

| Separate instance | Failing-first evidence | Fix and oracle |
| --- | --- | --- |
| 1i: invalid UTF-8 filter name | `review-utf8-before.log`: 1 test, 2 failures; the marker program ran | Reject lossy configuration decoding before a trusted command can start. |
| 1j: `=` in a local filter name | `review-equals-before.log`: 1 test, 2 failures; `-c` split at the wrong separator and the marker ran | Reject local program keys that cannot be represented as safe command-line overrides. Global-only settings need no override. |
| 1k: canonically equivalent Unicode filter names | `review-unicode-before.log`: 1 test, 1 failure; one filter was left executable | Preserve byte-distinct names in inventory sets; refuse safety arguments macOS Foundation would normalise. |
| 2c: canonically equivalent Unicode remote names | `review-http-unicode-before.log`: 1 test, 1 failure; the other origin received a request | Preserve remote/URL keys as bytes and reject lookups/overrides Foundation cannot pass unchanged, before sending headers. Both remote selections are exercised. |
| 2d: mixed-case HTTP URL schemes | `review-http-forms-before.log`: `HTTP` and `hTtP` each reached the other origin (4 failed assertions) | Recognise the HTTP scheme case-insensitively before querying effective headers. |
| 2e: explicit transport-helper addresses | The same log: `http::http`, `https::http` and `ftp::http` each reached the other origin (6 failed assertions) | Check the HTTP address passed to the helper, rather than treating its transport prefix as the URL scheme. |

The initial Unicode-remote fixture used Process to create its names, which normalised both to the same name. It was corrected to write two distinct config byte sequences directly; both actual remote selections are now checked. The standalone generated-argument probe (`review-argv-unicode.log`) confirms that this Mac’s Foundation decomposes both argv and environment text. Configuration that cannot be checked or overridden faithfully now fails with a configuration error; it never falls through to an unprotected command. Global programs themselves remain user-authorised code, not sandboxed code.

The final compatibility probe exposed an overly broad version of the encoding guard: a global-only filter named `fixture=global` and a Unicode global fsmonitor path were refused (**1 test, 3 failures**, `review-global-only-before.log`). Only local/worktree program keys now acquire overrides or their encoding restrictions. In particular, the inventory probe’s command-scoped fsmonitor guard is not mistaken for a local program. The global filter and monitor both execute successfully with their original config bytes (**1/1**, `review-global-only-restored.log`); the expanded focused selection passes **33/33** (`review-global-only-fixed.log`).

### Follow-up mutations

| Mutation | Expected failing result | Text log |
| --- | --- | --- |
| Confine trusted reads again | 2 tests / 10 assertions: global/system conversion and global monitor no longer work | `review-global-mutation.log` |
| Remove local/worktree program overrides | 3 tests / 21 assertions: hostile programs execute, including included config | `review-local-mutation.log` |
| Remove both lazy-fetch and protocol guards | 1 test / 1 assertion: missing-object read starts fixture remote | `review-lazy-mutation.log` |
| Retain only generic redirect refusal | 3 tests / 16 assertions: URL-scoped settings forward private headers | `review-url-mutation.log` |
| Restore the pre-byte-check inventory | 4 tests / 6 assertions: all four inventory edge cases reproduce | `review-bytes-mutation.log` |
| Replace ordinary `initial` redirects with blanket refusal | 1 test / 1 error: same-host rename fetch fails | `review-rename-mutation.log` |
| Treat command-scoped probe settings as local programs | 1 test / 3 assertions: the global-only monitor/filter fixture fails | `review-global-scope-mutation.log` |
| Apply override-key restrictions to global-only settings | 1 test / 3 assertions: the global-only monitor/filter fixture fails | `review-global-key-mutation.log` |
| Recognise only plain lowercase HTTP URLs again | 1 test / 10 assertions: five alternate URL forms reach the other origin | `review-http-forms-mutation.log` |

Removing just the protocol guard did not break the missing-object test because the independent lazy-fetch guard still protected it (`review-lazy-single-guard-mutation.log`). Removing both reproduced execution. Every mutation was restored in `finally`. The byte-check restoration passes **32/32** (`review-final-restored.log`), the redirect compatibility restoration passes **4/4** (`review-http-restored.log`), and the global-only restoration passes **1/1**. Intermediate full package runs passed **325 tests, skipped 3** before the byte checks (`review-views-before-byte-guards.log`) and **329 tests, skipped 3** before the final global-only correction (`review-views-before-global-compat.log`); final affected validation is recorded below.

The URL-form sweep ran after a complete package pass of **330 tests, 3 skipped** (`review-views-before-url-forms.log`). Its new regression then failed **10 assertions in 1 test**, passed with the fix, and reproduced all **10 assertions** under mutation. The restored entire HTTP redirect class passes **5/5** (`review-http-forms-fixed.log`, `review-http-forms-restored.log`). The complete package is rerun after that final change; the native permission/webhook selection is also repeated after the final production change.

The first gallery run completed all 112 captures but failed one assertion in the new HTTP scene: the shared `GitSafetyRepository` fixture sets `protocol.allow=never`, so its fetch never reached the loopback endpoint (`review-native-GitSafetyGalleryTests-before-fixture.log`). The scene now permits HTTP only in that generated repository, whose sole remote is the generated loopback server. No production protocol allowance changed. The complete gallery class is rerun; the original failure is not counted as a pass.

### Follow-up adversarial self-review

- Re-enumerated both Git launchers and their callers; no helper or other HTTP production source changed. Fresh inventories are `review-source-boundary-sweep.txt` and `review-git-callsite-sweep.txt`. The added inventory commands are listed separately in the subprocess table. Explicit writes retain their prior hooks, and pure configuration reads still return actual hook paths for Reword.
- Exercised local, worktree, global and system scopes; local includeIf/include chains; two same-named global/local filter settings; nested submodule monitors and filters; required global conversion; and trust revocation. The trusted policy is the owner-requested per-invocation origin/override policy; the untrusted policy remains an execution sandbox. No cache of program authority was introduced.
- Checked every dynamic config/remote key for lossy decoding, delimiter confusion and Unicode equality/argument normalisation. Inventory records use an independent name-only pass to validate record boundaries and detect changed metadata. The four new edge-case regressions fail before execution/network when representation is unsafe.
- Swept redirect handling for generic/URL-scoped headers and redirect settings, non-origin and literal defaults, rewritten URLs, push URLs and initialized submodule config. All Git transport entry points share the policy; webhook refusal and its permanent-failure classification are unchanged.
- The final URL-form sweep confirmed two additional omissions with the real system Git and two loopback servers: mixed-case schemes and explicit helper prefixes. All five forms reached the sink before the fix; they now receive the same URL-matched header policy as ordinary HTTP remotes.
- Configuration probes have bounded output/deadlines and run under confinement. The final argv cap includes program overrides. Generated scratch data is removed after use. The root’s global/system settings are the only source of programs restored over local/worktree settings.
- Checked that safety-key encoding restrictions apply only where an override or lookup is required. Global-only names/paths remain in Git’s original configuration, and the explicit compatibility fixture executes both programs. The normal-redirect positive test has no URL-specific redirect setting that could conceal a broken generic default.

### Follow-up commands and final results

All commands use `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. Native commands hold the shared lock only while each run owns it, with cleanup on failure. Serial-lane classes run individually. The prior preview-order failure remains recorded above; its class runs alone here. No helper or wire source changed in this follow-up, so their unchanged full-suite/wire/concurrent/acceptance evidence is the initial record above.

Each package regression/mutation uses `swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter '<selection>'`. Exact selections, paired with the results above:

| Check | Selection |
| --- | --- |
| Initial trusted-filter regression | `GitRepositorySecurityTests/testTrustedReadsKeepGlobalFiltersAndRejectLocalPrograms` |
| Global-program mutation | `GitRepositorySecurityTests/testTrustedReadsKeepGlobalFiltersAndRejectLocalPrograms\|FolderBrowserTests/testTrustedListingsUseGlobalMonitorButNeverLocalMonitor` |
| Local-program mutation | `GitRepositorySecurityTests/testTrustedReadsKeepGlobalFiltersAndRejectLocalPrograms\|GitRepositorySecurityTests/testTrustedReadOnlyQueriesNeverRunRepositoryPrograms\|FolderBrowserTests/testTrustedListingsUseGlobalMonitorButNeverLocalMonitor` |
| Both lazy-fetch checks | `GitRepositorySecurityTests/testObjectReadsNeverStartPromisorRemotePrograms` |
| Redirect regression, generic-only mutation and restoration | `GitHTTPRedirectTests` |
| Byte-safety mutation | `GitRepositorySecurityTests/testInvalidUTF8CannotRenameAProgramOverride\|GitRepositorySecurityTests/testEqualsCannotSplitAProgramOverride\|GitRepositorySecurityTests/testCanonicallyEquivalentFilterNamesStayByteDistinct\|GitHTTPRedirectTests/testCanonicallyEquivalentRemoteNamesBothProtectTheirHeaders` |
| Each byte-safety failing-first run | The corresponding single test from the preceding selection |
| Normal-redirect mutation | `GitHTTPRedirectTests/testGitFetchKeepsSameHostRedirectsWithoutPrivateHeaders` |
| Global-only regression, both mutations and restoration | `GitRepositorySecurityTests/testGlobalOnlyProgramsDoNotAcquireLocalOverrides` |
| Alternate HTTP URL forms, regression and mutation | `GitHTTPRedirectTests/testAlternativeHTTPURLFormsNeverForwardPrivateHeaders` |

```sh
xcodegen generate --quiet
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitRepositorySecurityTests|GitHTTPRedirectTests|FolderBrowserTests'
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitRepositoryPermissionTests \
  -only-testing:PiAppTests/WebhookTests \
  -only-testing:PiAppTests/WebhookExchangeTests
```

The remaining native selections are:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileBlameTests \
  -only-testing:PiAppTests/FileTabTests \
  -only-testing:PiAppTests/FileHiddenReadTests \
  -only-testing:PiAppTests/FilePageReadTests \
  -only-testing:PiAppTests/FileReviewStateTests \
  -only-testing:PiAppTests/GitBranchesInteractionTests \
  -only-testing:PiAppTests/GitChangelistReadTests \
  -only-testing:PiAppTests/GitCommitBrowsingTests \
  -only-testing:PiAppTests/GitConfirmationSheetTests \
  -only-testing:PiAppTests/GitDiscardQuestionTests \
  -only-testing:PiAppTests/GitHistoryFilterTests \
  -only-testing:PiAppTests/GitHunkReviewTests \
  -only-testing:PiAppTests/GitIntegratedHistoryTests \
  -only-testing:PiAppTests/GitPanelAuditTests \
  -only-testing:PiAppTests/GitPanelDiffCaptureTests \
  -only-testing:PiAppTests/GitPanelLayoutTests \
  -only-testing:PiAppTests/GitPanelRedrawTests \
  -only-testing:PiAppTests/GitPanelShownTests \
  -only-testing:PiAppTests/GitPanelWidthTests \
  -only-testing:PiAppTests/GitPathBoundaryTests \
  -only-testing:PiAppTests/GitRenameTests \
  -only-testing:PiAppTests/GitToolTests \
  -only-testing:PiAppTests/QuickOpenPlacementTests \
  -only-testing:PiAppTests/ChangesTabTests
for C in FilePreviewRefreshTests GitOperationSafetyTests FileFolderTests FileFindTabTests QuickOpenTests GitWorkingTreeWatcherTests GitPanelTimingTests CrashAuditRegressionTests GitRepositorySwitchTests ChangesTabFrameTests GitDiffTableTests GitPanelNarrowParityTests; do
  PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO "-only-testing:PiAppTests/$C"
done
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/review-gallery" PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

| Follow-up suite | Passed | Skipped | Failed | Text evidence |
| --- | ---: | ---: | ---: | --- |
| Full bello-views (334 executed) | 331 | 3 | 0 | `review-views-full.log` |
| Native: latest results of all 40 affected classes (358 executed) | 356 | 2 | 0 | Class table below; repeated classes counted once |

The package skips are the three opt-in large-directory benchmarks. Native skips are the opt-in real-repository browsing measurement and separate diff-pane capture. The changed safety gallery is enabled and passes **1/1**, included in the native total. Its **112 PNGs** are under `$B/review-gallery`. Inspected `http-redirect-{light,dark}-{1180x780,310x600}.png`: the red refusal notice is visible in both themes and widths, with the existing toolbar ellipsis and full-text tooltip (`apps/macos/PiApp/Git/GitPanel.swift:663`); controls retain their existing geometry. No production layout change was made.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `review-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `review-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `review-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `review-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `review-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `review-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `review-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `review-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `review-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `review-native-file-git.log` |
| FileTabTests | 16 | 0 | `review-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `review-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `review-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `review-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `review-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `review-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `review-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `review-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `review-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `review-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `review-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `review-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `review-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `review-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `review-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `review-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `review-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `review-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `review-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `review-native-file-git.log` |
| GitRenameTests | 6 | 0 | `review-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `review-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `review-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `review-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `review-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `review-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `review-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `review-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `review-native-boundaries.log` |
| WebhookTests | 18 | 0 | `review-native-boundaries.log` |

All mutations were restored. Final diff checks pass. Every owned native/focus run released the shared lock in `finally`; no other workstream's lock was removed, and no cloned test-host directories remain in this build root. The requested security findings and owner-policy changes are resolved. The initial unrelated combined-run preview timeout remains documented above for integration review; its unchanged class again passes 2/2 alone.
