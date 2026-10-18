# 0.1.130 security boundaries

Workstream `dev/a130-security`, based on `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. Worktree `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security`; build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. macOS 14.8 (23J21), Apple Git 2.39.5, Xcode 16.1. Generated repositories and ephemeral loopback servers only; no installed-app launch, real credentials, Keychain, live capture, paid calls, release, tag, or upstream integration.

## Fixed instances and policy

1. **SECURITY-BOUNDARIES-1a (P0), folder tree/menu and Quick Open:** FileFinder now passes `-c core.fsmonitor=false` on every Git query. Its `check-ignore` and `ls-files` load repository indexes even when a FileTab has no trusted project. Native reproduction opens an absolute file-tool link outside configured projects and awaits its folder rows.
2. **SECURITY-BOUNDARIES-1b, Git status/index queries:** GitService's read-only launcher disables fsmonitor as well. This includes the changes panel, ignored-path listing, snapshots, preflight and file blame, including configuration brought in through `includeIf`/`include`.
3. **SECURITY-BOUNDARIES-1c, executable content filters:** status, working diffs and blame can invoke `filter.<name>.clean`/`process` even with `--no-ext-diff --no-textconv`. Read-only Git now runs under a macOS process sandbox; only the selected system Git and its Git children may execute, no network is allowed, and writes are confined to a per-query private temporary directory and `/dev/null`. Checking configuration before a later Git invocation would leave a race and is deliberately not the security boundary. Git sometimes returns success after an optional filter fails; those diagnostics now fail the query instead of presenting unconverted data as a successful comparison.
4. **SECURITY-BOUNDARIES-1d, working/staged/untracked diff textconv:** these paths now explicitly pass `--no-textconv`; commit name/stat queries also explicitly disable textconv and external diff. Historical/stash/hunk diff paths already passed these switches. The sandbox still protects against changes to attributes or configuration during a query.
5. **SECURITY-BOUNDARIES-1e, implicit promisor fetch:** object/history reads in partial clones could invoke a configured remote helper, SSH command or credential helper. All read-only Git processes prohibit network and non-Git executables, and set `GIT_NO_LAZY_FETCH=1` (defence in depth; the sandbox also covers the older Apple Git used here).
6. **SECURITY-BOUNDARIES-1f, sparse-index folder queries:** even `ls-files` and `check-ignore` can expand a sparse index and fetch a missing tree. Both wrote a remote marker with fsmonitor disabled. FileFinder now uses the same shared `GitProcessSafety` target as GitView; a static command-option fix alone was insufficient.
7. **SECURITY-BOUNDARIES-1g, untrusted manual writes:** the app previously offered Changes mutations without consulting project trust. A host-supplied admission check now covers both GitController write entry points, including trust revoked after a review. Read-only Changes browsing remains available; already dispatched trusted writes retain their existing lifetime.
8. **SECURITY-BOUNDARIES-1h, signature verification:** `log.showSignature=true` can invoke repository-configured `gpg.program` during ordinary history and commit-detail reads. The shared launcher disables signature display and confines executable children. A generated commit carrying a dummy signature exercises both read APIs.
9. **SECURITY-BOUNDARIES-2, completion and test webhooks:** the URLSession delegate refuses every redirect. The original 3xx is a non-transient delivery failure; neither payload nor custom headers reach a redirected endpoint, and the redirect is not retried. Same-origin redirects also require the user to configure the final URL, matching the existing discovery/helper policy.

10. **SECURITY-BOUNDARIES-2b, Git HTTP redirects:** a trusted Fetch still forwarded a configured `http.extraHeader` to a different loopback port before Git rejected the response. GitService now passes `-c http.followRedirects=false` for its Git commands, covering fetch/pull/push and their HTTP exchanges. A native generated-repository test checks all five redirect codes and proves the private header reaches only the configured source.

**Rule for user actions:** only explicit mutating Git operations in a trusted project opt out of read-only confinement: Stage/Unstage/Discard, branch switch/create/rename/delete, stash create/apply/pop/drop/store, fetch/pull/push, commit/amend/reword and hunk publication. Their normal hooks, content filters, signing and selected transports remain available; Bello-launched Git HTTP requests refuse redirects. Every preparatory/background read stays confined. Direct post-rewrite execution remains limited to the existing explicit Reword action. The library's host still owns project trust; the change does not grant trust or widen tools.

**Needs owner decision:** Git HTTP redirects now fail, including same-origin redirects; configure the final remote URL. This is the conservative choice because repository/global `http.extraHeader` values otherwise reach a redirected origin. Also, untrusted projects may browse confined Git data but are refused when a write is admitted, with the existing notice area saying to trust the project first. This is the conservative interpretation of the requested trusted-project exception. Also, read-only inspection that needs an executable clean/process filter now fails visibly, rather than running that program or showing a misleading raw comparison. The conservative policy is implemented. Read-only textconv is disabled, so ordinary textual diffs use repository bytes. The macOS `sandbox-exec` boundary is fail-closed if unavailable; this machine validates macOS 14.8. No new entitlement, preference, production bypass, or permission broker is added. Minimum/current macOS packaging compatibility remains for the lead's release gate.

## Subprocess sweep

Scope: all production process launch sites in `apps/macos/PiApp`, `packages/bello-views/Sources` and `packages/swift-host/Sources`, plus all callers of their launchers. “Programs” below includes commands selected by repository config, attributes and included configuration. All Git stdout is piped; reads additionally force `--no-pager`. Config includes can supply all listed settings but do not themselves execute commands.

| Launcher / operation | Command(s) | Working directory and trust | Repository-controlled execution paths and disposition |
| --- | --- | --- | --- |
| FileFinder tool availability | `/usr/bin/xcode-select -p` | Inherited app directory; no repository lookup | Xcode selection only, no Git config/hook/filter/pager/editor/transport. |
| FileFinder repository detection | `git rev-parse --show-toplevel` | Arbitrary browsed folder, outside projects allowed; also nested repositories | Reads local/included config; no object/index conversion. fsmonitor disabled at the launcher; shared read-only confinement also applies. |
| Quick Open recursive listing | `git ls-files -z --cached --others --exclude-standard` | Project folders and nested repositories/submodules; nested repos need not be independently trusted | Index can invoke fsmonitor (fixed). No clean/smudge/process conversion, diff driver, hook or editor is requested. Sparse-index expansion can invoke a promisor transport: now confined. |
| Folder tree and breadcrumb menus | `git check-ignore -z --stdin`, repository detection | Arbitrary folder reached from a file card, including absent/untrusted project | Index fsmonitor (fixed); ignore decisions are data. No diff/conversion, hooks or editor. Sparse-index missing-tree transport is now confined. Shared FolderDirectory covers both tree and menu. |
| Non-repository ignore fallback | `git config --path --get core.excludesFile` | Walked folder, outside projects allowed | Reads global/local includes as data; uses configured ignore file without executing programs. |
| Git read-only tool resolution | `/usr/bin/xcrun --find git` | `/`, clean environment, once per process | Selects developer Git; no repository-controlled PATH, cwd, `DEVELOPER_DIR`, or config. |
| Git root/state/index | `rev-parse`, `symbolic-ref`, `status --porcelain=v2`, `ls-files` | Selected project root; public library root can be arbitrary. File blame also uses this service | fsmonitor disabled. Status clean/process filters and submodule Git children are confined. No repository scripts, hooks, network or repository writes. |
| Git history and branch catalog | `log`, `show`, `for-each-ref`, `rev-list`, `merge-base`, `reflog show`, `branch --list`, `remote`, `worktree list`, `check-ref-format` | Project/repository root | Textconv/external diff disabled for patches/stats; signature display disabled. Missing-object fetch, SSH/credential/remote helpers blocked; pager forced off, no editor. Includes and branch config still read as data. |
| Changes panel and file history diffs | `diff` (working, cached, no-index), `show` | Project root; no-index untracked path under the same root | External diff/difftool and textconv disabled; clean/process conversions confined and failures surfaced. No smudge requested. All config/includes remain behind the process boundary. |
| File viewer blame | `blame --no-textconv --contents -`, `log`, `rev-parse` | The file's repository; outside configured projects can be viewed | Content filters, fsmonitor and missing objects covered. No file bytes are handed to helper/model by this path. |
| Stash inspection | `stash list`, `diff`, `show`, `ls-tree`, `rev-parse`, `config --get extensions.refStorage` | Project root | Internal Git child for `stash list` allowed; configured external programs are not. Textconv/external diff disabled; implicit remote access blocked. |
| Commit preview and hunk review | status/index reads; `diff --check`, `check-attr`, `cat-file`, `ls-tree`; raw `diff --no-index` in private scratch | Project root or generated temporary patch directory | No commit hooks during preflight. Filters/driver/fsmonitor/lazy-fetch confined. Hunk content-attribute refusal is retained. Raw diff uses isolated config and no external driver/textconv. |
| Watchers, Files and folder menus | FSEvents/vnode callbacks -> launchers above; GitWatcher reads `.git`/`commondir` metadata directly | Watched repository/file roots; folder browser may be outside projects | No additional subprocess launcher. Refresh queries inherit the same policy. |
| Reword identity and configuration reads | `var GIT_COMMITTER_IDENT`, `config --get commit.gpgSign`, `config --path --get core.hooksPath`, `rev-parse --git-path hooks` | Project/repository root, before an explicit trusted write | Identity, signing choice and hook path are data reads, still confined. Only the later admitted mutation may execute the configured signer/hook. |
| Explicit Git mutations | `add`, `restore`, `reset`, `rm`, `clean`, `switch`, `branch -m/-d/-D`, mutating `stash`, `fetch`, `pull`, `push`, `commit`, reword plumbing (`read-tree`, `write-tree`, `interpret-trailers`, `commit-tree`, `update-ref`, `hook run`), hunk `hash-object -w --no-filters`/`update-index` | Trusted project chosen through existing UI | Normal fsmonitor, hooks/core.hooksPath, clean/smudge/process, SSH/credential/remote helpers, signing and includes retained where Git uses them. Git HTTP redirects are disabled; no automatic/background mutation is newly authorized. |
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
| Explicit Git fetch/pull/push | Git protocol body, credential-helper results, configured HTTP headers | `http.followRedirects=false` on every GitService command; read-only Git also has no network access | `GitRepositoryPermissionTests.testGitFetchNeverForwardsPrivateHeadersAcrossOrigins`: two ports, 301/302/303/307/308, real system Git, zero sink requests. |
| Update checks outside Sparkle | None found | Sparkle owns the appcast update path; no separate app/helper HTTP updater | Source enumeration of URLRequest/URLSession/HTTPStream and launch sites. |

No other production HTTP client was found in these targets. Browser/external-link opening and intentionally configured stdio MCP/bash processes are separate user-authorized execution surfaces, not another internal HTTP transport.

## Regression and mutation evidence

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

## Validation commands

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

## Adversarial self-review

- Enumerated every production process constructor, exec/fork path, URLSession/URLRequest constructor, HTTPStream caller, and every GitService/FinderProcess call. The tables distinguish automatic reads from explicit shell/MCP/tool capabilities and trusted Git mutations. Source inventories are `source-boundary-sweep.txt` and `git-callsite-sweep.txt`.
- Tried configuration indirection, nested repository children, optional clean and process filters, textconv, missing blobs and sparse trees. Static config scanning cannot close a concurrent config/attributes replacement race; execution/network/write restrictions are inherited by Git children instead. Git's allowed executable paths are resolved from a clean `/`-cwd system-tool lookup, never a repository PATH or `DEVELOPER_DIR`.
- Reviewed every `readOnly: false` call: each belongs to an explicit write, including reword hooks and hunk index publication. The sole production GitController is created by ChangesTab with a live trust/root check. Both controller admission paths check it; preflight and automatic refresh remain confined. Trusted-action tests prove that normal hooks and filters still run where allowed.
- Considered a configured driver selecting the allowed Git binary itself: child Git remains denied network and writes outside private scratch, and cannot exec a shell/helper. Read failures have no unsandboxed fallback. Global/included ignore/config data remain readable.
- Checked URLSession and Git HTTP redirect handling, all redirect codes, POST preservation, custom headers, same-origin redirects, pooled task delegates, MCP initialization, and retry classification. Refusal occurs before a redirected request; original 3xx is not retried as a transient delivery failure.
- Checked cancellation/deadlines, output caps, scratch cleanup, native file boundaries and the existing blame refusal. The test-only shell aliases used for drain/cancellation/timing probes and synthetic competing stash writers now explicitly opt into execution; no production bypass or environment switch was introduced.

The policy choices requiring owner confirmation are called out above. The lead still owns integration, separate read-only review, and the merged full release gate. No unrelated product fix is included.

## Unrelated validation failure

The final native selection hit `FilePreviewRefreshTests.testSiblingNotificationsLetTheActivePreviewPublish` at `apps/macos/PiAppTests/FilePreviewRefreshTests.swift:25`: after repeated sibling-folder notifications and release of the first image decode, the queued metadata recheck did not enter its test gate within 10 seconds (one failed case, two assertions). The preview-refresh test and production preview implementation are unchanged on this branch, and this image-only path does not invoke Git. Evidence: `native-file-git-final.log`. The unchanged class passes **2/2 in isolation** (`native-FilePreviewRefreshTests.log`). This is consistent with a fixture-order dependency: `WorkspaceModel.swift:557` installs a weak-model `FileTab.resolveProject` closure whose fallback is `.removed`, whereas this standalone fixture expects a nil project to mean `.none`. That cause is an inference, not a fix on this branch; the combined-run failure remains for the lead to triage. The production preview behavior and assertion are unchanged.

## Final validation counts

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
