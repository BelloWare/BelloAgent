# 0.1.130 security boundaries

Workstream `dev/a130-security`, based on `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`; rounds 7 and 8 integrate the explicitly requested `origin/dev/next` merges. Worktree `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security`; build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. macOS 14.8 (23J21), Apple Git 2.39.5, Xcode 16.1. Generated repositories and ephemeral loopback servers only; no installed-app launch, real credentials, Keychain, live capture, paid calls, release or tag.

## Fixed instances and policy

The owner decisions below supersede the initial `fc82085a` policies. Earlier evidence is retained under the initial-validation headings; the review follow-up at the end records the new implementation and results.

1. **SECURITY-BOUNDARIES-1a (P0), folder tree/menu and Quick Open:** outside/untrusted folders retain the confined Git launcher and `core.fsmonitor=false`. Trusted folders use stamp-checked, cached Git scope/origin metadata to override local/worktree programs, preserving global/system fsmonitor.
2. **SECURITY-BOUNDARIES-1b, Git status/index queries:** the same policy covers Changes, ignored paths, snapshots, preflight and blame. Every read forces non-recursive submodule output; explicitly opening a submodule applies its own global/system policy. Parent status still reports changed gitlink IDs, without inspecting child worktree dirtiness.
3. **SECURITY-BOUNDARIES-1c, executable content filters:** trusted reads with proven static configuration and exactly representable overrides run without an execution sandbox. Local/worktree clean/smudge/process commands are neutralised; matching user-owned settings are restored from global/system scope. Repository attributes may select global filters, including required conversions. Dynamic/non-regular includes, unrepresentable override text and invalid UTF-8 metadata force the same execution/network/write sandbox used outside/untrusted projects, and failed conversions are surfaced.
4. **SECURITY-BOUNDARIES-1d, textconv:** working/staged/untracked/history/stash/hunk diffs and commit statistics retain their no-textconv/no-external-diff switches. Trusted configuration overrides also cover local diff drivers.
5. **SECURITY-BOUNDARIES-1e, implicit promisor fetch:** every read sets `GIT_NO_LAZY_FETCH=1` and `GIT_ALLOW_PROTOCOL=`; the latter also defeats per-protocol config allowances. Outside/untrusted queries additionally have no network or non-Git executables.
6. **SECURITY-BOUNDARIES-1f, sparse-index folder queries:** FileFinder uses the same launcher; missing sparse trees cannot start a remote helper. Metadata inventory uses `ls-files --stage --sparse` under confinement.
7. **SECURITY-BOUNDARIES-1g, untrusted manual writes:** both controller write admissions retain the live trust/root check and existing trust notice, including revocation after review. Already dispatched trusted writes retain their existing lifetime.
8. **SECURITY-BOUNDARIES-1h, signature verification:** ordinary history/commit details retain disabled signature display. Trusted reads also override local `gpg.program` and `gpg.<format>.program` settings.
9. **SECURITY-BOUNDARIES-2, webhooks:** all redirects remain refused. Original 3xx responses fail permanently without forwarding payloads/headers or retrying.
10. **SECURITY-BOUNDARIES-2b, Git redirects:** any effective `http.extraHeader` key, at any scope or URL scope and with any value, refuses redirects for every Bello network Git command in that repository. The key test is case-insensitive and uses Git's NUL-delimited scope/origin/name inventory. Both generic and every existing URL-scoped `followRedirects` key receive `false`; header-free inventories retain Git’s `initial` default, preserving existing redirect settings instead of replacing stricter child settings. This is the owner's requested conservative superset of the former per-remote rule: an unrelated or empty header key also refuses redirects. Populated and recursively stored submodule inventories retain the same conservative coverage for recursively dispatched network operations. Directory discovery, stored config and include stamps invalidate parent policies; uninspectable reachable configuration refuses network launch. Git alone resolves remotes, rewrites and legacy definitions; Bello no longer enumerates or emulates them. The failure message identifies the repository-wide `http.extraHeader` policy.

### Owner decisions (verbatim)

> 1. Background/read-only Git in TRUSTED projects: programs configured in the user's global or system Git config may run (e.g. Git LFS clean/smudge/process filters, a global fsmonitor), but programs configured inside the repository (local `.git/config`, worktree config, and any include/includeIf files resolved from local config) never run during Bello's background reads. Detect origins with `git config --show-scope --show-origin` (or equivalent) and neutralise local/worktree-scoped program settings with `-c` overrides (filters, fsmonitor, textconv/diff drivers, gpg.program and signature display, sshCommand, credential helpers, pager/editor, remote helpers/lazy fetch). Repository `.gitattributes` choosing a globally configured filter is fine. Keep fsmonitor/lazy-fetch/textconv defences where they do not break this. UNTRUSTED or outside-project folders: fully confined as you implemented (sandbox allowed there). Do NOT sandbox trusted-project reads if that blocks global programs like git-lfs. Test: a trusted LFS-style repo whose global-scope filter runs (fixture global config via GIT_CONFIG_GLOBAL in the test env, never the real ~/.gitconfig) and whose local-scope hostile filter/fsmonitor/hook does not.
>
> 2. Git HTTP redirects: follow redirects as Git normally does (`initial`), but refuse redirects (and fail with a clear message) for remotes that have an `http.extraHeader` configured at any scope, including URL-scoped `http.<url>.extraHeader`; when refusing, also override any URL-scoped `http.<url>.followRedirects` (the review finding below). Renamed-repo style same-host redirects without extra headers keep working.
>
> 3. Git writes in untrusted projects: refused with the trust notice, as you implemented (keep).
>
> Webhooks refusing all redirects: keep.

Round-4 rules (verbatim; supersede the earlier recursive-submodule implementation):

> 1. The inventory cache is an optimisation that must fail closed: reuse it only when it can prove nothing relevant changed. Key it on repository identity (resolved toplevel, gitdir, commondir, worktree) plus discovery stamps for the queried directory and every ancestor up to the toplevel/filesystem root where a .git could appear, every config file Git actually reads, and every include target resolved with Git's own pathname rules (~, ~user, relative, gitdir:/onbranch: conditions) — whether or not the file exists yet. If any include cannot be resolved exactly, or any stamp cannot be read, do not cache (run the inventory every time for that repository). Keep the latency budget for the normal case and re-measure.
>
> 2. Bello's own read-only Git commands never spawn child Git processes that could run repository-configured programs: force non-recursive submodule output on every read path (e.g. `-c diff.submodule=short` / `--submodule=short`, `--ignore-submodules` where content is not shown) for show/log/diff/status/blame alike; audit every read command for other child-spawning options.

Round-5 rule (verbatim; qualifies permission for unconfined trusted reads):

> General rule to apply (not only for /dev/stdin): a trusted read may run without confinement only if the inventory can prove that the final command reads exactly the configuration bytes it inspected. Any include (direct or conditional, at any depth) that resolves to something other than a regular file — character/block devices, FIFOs, sockets, /dev/*, /dev/fd/*, process-substitution style paths, or anything whose content can depend on the command's own stdin/arguments/environment — makes that repository's reads fall back to the untrusted confinement (sandbox) for that query; never run them unconfined. Also make sure no read command feeds attacker-influenced data on stdin while repository config could reference stdin (blame/check-ignore/etc.): prefer passing paths as arguments with `--` where Git supports it.

Round-6 rules (verbatim; replace per-remote resolution and strengthen cache validity):

> A. Redirect protection (replaces per-remote resolution): if the repository's effective configuration contains ANY `http.extraHeader` key at all (any scope, any URL-scoped variant, any value — query Git with NUL-delimited output and a case-insensitive key match), then every Bello-launched network Git command in that repository runs with redirects refused for all URLs (override `http.followRedirects=false` AND every URL-scoped `http.<url>.followRedirects` present). Only when Git reports no extraHeader key at all do redirects follow Git's normal `initial` behaviour. This is a conservative superset of the owner's rule ("refuse redirects for remotes with an http.extraHeader configured"); record it as such. Remove the remote/default/pushurl resolution code that is no longer needed (keep it only if something else depends on it).
>
> B. Inventory cache validity: reuse only when every component of every configuration origin's resolution chain is unchanged — stamp each symlink in the chain (lstat) and its final target, plus the repository path's own realpath chain that gitdir:/onbranch conditions depend on; if any component cannot be stamped, do not cache.

Round-7 rule (verbatim; qualifies generated overrides):

> Rule (fail closed): any value Bello writes into a generated Git configuration override (subsection names, values, condition patterns) must round-trip exactly under Git's own parsing; if a path or value contains anything that cannot be represented safely (control characters, newlines, NUL, invalid UTF-8, unsupported escapes), that repository's reads run under the untrusted confinement instead of trusted-unconfined. Use separate subsection and value encoders and verify each generated override by asking Git to read it back (e.g. `git config --get-regexp` / `--show-origin` on a scratch config) in tests.

Round-8 rule (verbatim; includes stored repositories and preserves stricter child policies):

> Fix so a generated override is never weaker than any reachable repository's own policy: inventory stored module repositories under the common dir's `modules/` (recursively) as well as populated ones, and if any repository whose config cannot be inventoried could be reached, fail closed (emit the strict value or confine).

**Explicit writes:** Stage/Unstage/Discard, branch mutations, stash mutations, fetch/pull/push, commit/amend/reword and hunk publication retain normal hooks, filters, signing and transports after trusted admission. Reword's hook-path query remains a confined data query and returns the actual configured path. Read overrides never reach a later write. No new entitlement, preference, helper capability or production test bypass is added. Minimum/current macOS packaging compatibility remains part of the lead's release gate.

## Subprocess sweep

Scope: all production process launch sites in `apps/macos/PiApp`, `packages/bello-views/Sources` and `packages/swift-host/Sources`, plus all callers of their launchers. “Programs” below includes commands selected by repository config, attributes and included configuration. All Git stdout is piped; reads additionally force `--no-pager`. Config includes can supply all listed settings but do not themselves execute commands.

| Launcher / operation | Command(s) | Working directory and trust | Repository-controlled execution paths and disposition |
| --- | --- | --- | --- |
| FileFinder tool availability | `/usr/bin/xcode-select -p` | Inherited app directory; no repository lookup | Xcode selection only, no Git config/hook/filter/pager/editor/transport. |
| FileFinder repository detection | `git rev-parse --show-toplevel` | Arbitrary browsed folder, outside projects allowed; also nested repositories | Reads local/included config; no object/index conversion. Local fsmonitor is overridden; global/system fsmonitor is allowed only in trusted folders. Outside/untrusted paths remain confined. |
| Quick Open recursive listing | `git ls-files -z --cached --others --exclude-standard` | Project folders and nested repositories/submodules; nested repos need not be independently trusted | Index can invoke fsmonitor (fixed). No clean/smudge/process conversion, diff driver, hook or editor is requested. Sparse-index expansion cannot fetch: lazy-fetch/protocol guards apply in both trust states. |
| Folder tree and breadcrumb menus | `git check-ignore -- <bounded paths>`, repository detection | Arbitrary folder reached from a file card, including absent/untrusted project | Index fsmonitor (fixed); ignore decisions are data. No diff/conversion, hooks or editor. Paths never enter stdin; C-quoted output preserves control characters and unusual filenames. Sparse-index missing-tree transport is disabled in both trust states. Shared FolderDirectory covers both tree and menu. |
| Non-repository ignore fallback | `git config --path --get core.excludesFile` | Walked folder, outside projects allowed | Reads global/local includes as data; uses configured ignore file without executing programs. |
| Scope/origin and redirect inventory | `config --null --list --includes --show-scope --show-origin`, a second `--name-only` inventory and final config-data verification, `config --type=path --get-regexp` for include targets, `config --system --no-includes --list --show-origin` to locate the selected Git's default system root, `ls-files --stage --sparse --full-name -z`, `rev-parse --absolute-git-dir/--git-common-dir/--show-toplevel/--git-path`, `symbolic-ref --no-recurse` for onbranch dependencies | Selected repository, populated submodules and recursive common-dir `modules/` repositories; inventory itself always confined, including trusted projects | Fixed data queries only. No index monitor or transport may execute while identifying config. Scope is inherited through includes; origin/name records must match between inventories. Header-key presence alone protects every destination; no remote or URL-match probes remain. Reuse requires resolved identity, discovery/config/include/index/HEAD stamps and every symlink/component/final target in their resolution chains. Missing components are watched for creation; unreadable, unresolvable or cyclic chains cannot be cached. |
| Git read-only tool resolution | `/usr/bin/xcrun --find git` | `/`, clean environment, once per process | Selects developer Git; no repository-controlled PATH, cwd, `DEVELOPER_DIR`, or config. |
| Git root/state/index | `rev-parse`, `symbolic-ref`, `status --porcelain=v2`, `ls-files` | Selected project root; public library root can be arbitrary. File blame also uses this service | Local/worktree fsmonitor and filters, including submodule programs, are overridden. Global/system programs run only for trusted reads. Optional index locks and implicit Git transports remain disabled. |
| Git history and branch catalog | `log`, `show`, `for-each-ref`, `rev-list`, `merge-base`, `reflog show`, `branch --list`, `remote`, `worktree list`, `check-ref-format` | Project/repository root | Textconv/external diff disabled for patches/stats; signature display disabled. Missing-object fetch, SSH/credential/remote helpers blocked; pager forced off, no editor. Includes and branch config still read as data. |
| Changes panel and file history diffs | `diff` (working, cached, no-index), `show` | Project root; no-index untracked path under the same root | External diff/difftool and textconv disabled; trusted global/system clean/process conversions remain available; local/worktree commands are overridden. Outside/untrusted conversions remain confined. No smudge requested. |
| File viewer blame | `blame --no-textconv --contents <private snapshot> -- <path>`, `log`, `rev-parse` | The file's repository; outside configured projects can be viewed | Content filters, fsmonitor and missing objects covered. The displayed bytes remain in a private snapshot until the query completes; stdin is empty, including when config references it. No file bytes are handed to helper/model by this path. |
| Stash inspection | `stash list`, `diff`, `show`, `ls-tree`, `rev-parse`, `config --get extensions.refStorage` | Project root | Internal Git child for `stash list` is allowed; local program settings are overridden in trusted reads, and outside/untrusted reads stay confined. Textconv/external diff disabled; implicit remote access blocked. |
| Commit preview and hunk review | status/index reads; `diff --check`, `check-attr`, `cat-file`, `ls-tree`; raw `diff --no-index` in private scratch | Project root or generated temporary patch directory | No commit hooks during preflight. Filters/driver/fsmonitor use the trust/scope policy; implicit fetch is disabled. Hunk content-attribute refusal is retained. Raw diff uses isolated config and no external driver/textconv. |
| Watchers, Files and folder menus | FSEvents/vnode callbacks -> launchers above; GitWatcher reads `.git`/`commondir` metadata directly | Watched repository/file roots; folder browser may be outside projects | No additional subprocess launcher. Refresh queries inherit the same policy. |
| Reword identity and configuration reads | `var GIT_COMMITTER_IDENT`, `config --get commit.gpgSign`, `config --path --get core.hooksPath`, `rev-parse --git-path hooks` | Project/repository root, before an explicit trusted write | Hook/signing configuration is read as data under confinement; identity reads follow the same trust/scope policy. Only the later admitted mutation may execute the configured signer/hook. |
| Explicit Git mutations | `add`, `restore`, `reset`, `rm`, `clean`, `switch`, `branch -m/-d/-D`, mutating `stash`, `fetch`, `pull`, `push`, `commit`, reword plumbing (`read-tree`, `write-tree`, `interpret-trailers`, `commit-tree`, `update-ref`, `hook run`), hunk `hash-object -w --no-filters`/`update-index` | Trusted project chosen through existing UI | Normal fsmonitor, hooks/core.hooksPath, clean/smudge/process, SSH/credential/remote helpers, signing and includes retained where Git uses them. Git HTTP redirects retain the configured policy (default `initial`) only when no effective extraHeader key exists; no automatic/background mutation is newly authorized. |
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
| Explicit Git fetch/pull/push | Git protocol body, credential-helper results, configured HTTP headers | Repository-wide refusal when any effective extraHeader key exists; otherwise the configured policy (default `initial`). Existing URL-scoped redirect overrides are neutralised too. Git read transports are disabled. | `GitRepositoryPermissionTests.testGitFetchNeverForwardsPrivateHeadersAcrossOrigins`: two ports, 301/302/303/307/308, real system Git, zero sink requests. Review tests add URL-scoped overrides, all config scopes and a successful same-host rename. |
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

At round 2, trusted reads resolved current project trust at admission, read Git scope/origin metadata afresh, and override local/worktree program settings (including local includes and initialized submodules). A global/system clean filter actually transforms fixture working bytes back into the indexed representation; status/diff complete and the diff is empty, while local filter/fsmonitor/hook markers remain absent. Global fsmonitor also runs through real folder and Quick Open listings, then stops being eligible when trust is revoked. Fixture configuration is supplied through `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`, never the real user config. Optional locks, implicit Git transports, textconv and automatic signature display remain disabled. Trusted Git can locate normal Homebrew-installed programs such as git-lfs; outside/untrusted reads retain the original sandbox.

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
- Exercised local, worktree, global and system scopes; local includeIf/include chains; two same-named global/local filter settings; nested submodule monitors and filters; required global conversion; and trust revocation. The trusted policy is the owner-requested per-invocation origin/override policy; the untrusted policy remains an execution sandbox. No cache of program authority was introduced in round 2; the round-3 cache and its invalidation rules are documented below.
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


## Round 3: push destinations, wildcard scopes, submodule values, cancellation and caching

**Restart notice, 2026-10-20:** the laptop interrupted the earlier round-3 run. All round-3 results below this heading through the previous final-validation section are historical and superseded; they do not count as completion evidence. Fresh rebuild, regression, mutation, latency and native results are recorded in the post-restart section below. Round-1/round-2 records retain their original scope.

The four review findings and the lead’s performance finding are confirmed. They are addressed on `dev/a130-security` without merging or fast-forwarding to `dev/next`. The benchmark baseline is `origin/dev/next` at `77ca6cb12b4a21537abe7f69e2bec0b657c0f001` (fetched on 2026-10-18). The owner policies quoted above still apply; there are no outstanding security policy decisions.

### Decisions and implementation

- Literal push defaults (`remote.pushDefault`, `branch.<name>.pushRemote`, and `branch.<name>.remote`) apply `pushInsteadOf` to the original literal before falling back to fetch URL rewriting. Named and legacy remotes use Git’s `remote get-url --push --all`, preserving explicit `pushurl` semantics and multiple URLs. Equal-length rewrite ties follow Git’s base ordering. Both fetch and push destinations remain protected even when configuration supplies `http.followRedirects=false` that the ordinary-redirect policy would otherwise replace with `initial`.
- Wildcard HTTP scopes remain configuration patterns. Only concrete destination URLs enter `config --get-urlmatch`; Git performs wildcard, host, port and path matching. Exact protected destinations override URL-scoped redirect settings. Tests include an unrelated wildcard scope that permits a real rename fetch and a matching wildcard scope that refuses a redirect with a private header.
- Each trusted repository has its own private conditional include, selected by a private `[includeIf "gitdir:<exact gitdir>"]` file supplied through command-scope `-c include.path=...`. Child Git processes re-evaluate the condition in their own gitdir. Parent restoration values are never broadcast into children. Overrides use only that repository’s local/worktree program keys and its own global/system values. The files are private, retained through the invocation, and deleted when their cache/invocation owners release them. Repositories with no local program settings need no private override file.
- `GitInvocation` owns one cancellation handle and absolute deadline across admission, inventory, cache waits and the eventual command, shared by GitService and FileFinder. Metadata probes adopt the handle before launch, check it while draining output, and reap their process on every exit. Already-cancelled reads start no inventory. A cancelled cache builder wakes waiters; a cancelled waiter cannot kill another read’s inventory.
- A bounded, shared cache coalesces cold builds and retains config entries, initialized submodule lists, per-repository overrides and protected destinations. Warm reads perform stamp checks and launch no config/index inventories. Stamps cover every reported file origin, missing includes/default global/system/worktree configs, `.gitmodules`, gitdir/commondir metadata, HEAD, indexes (including `GIT_INDEX_FILE`), submodule `.git` pointers and legacy remote definitions. Stamps include device, inode, mode, size, nanosecond mtime and ctime, for both symlinks and targets. `/dev/null` uses its stable device identity; other nonregular inputs are not treated as cacheable configuration. Validation checks cancellation/deadline between stamps. Watcher events invalidate matching inventories; normal working-file saves retain them. Resolver changes and workspace trust/root changes clear the cache. An inventory whose inputs changed during construction is refused instead of caching old entries under new stamps.

Git URL rewriting is checked against the installed Git and its [documented push rules](https://git-scm.com/docs/git-config#Documentation/git-config.txt-urlltbasegtpushInsteadOf). The policy remains confined for untrusted/outside-project reads, and explicit untrusted writes still use the existing trust notice. Webhook redirect handling and helper/wire behavior are unchanged in this round.

### Regression and mutation evidence

All logs below are text under `$B/logs`, where `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`.

The final six regression fixtures were run against the original round-2 production sources from `6a7c0004`, with only a DEBUG inventory counter added: **6 tests failed, 12 assertions/errors** (`round3-original-confirmed.log`). Each source byte was restored in `finally`. The original submodule fixture initially missed Git’s conversion path; the final fixture verifies the conditional global config directly and uses equal-sized edits to force content conversion. The original policy then reports `clean filter 'foo' failed` in the child. This corrected fixture is used for the recorded original-source and mutation results.

Additional failing-first checks: trust/watcher invalidation **2 tests / 2 assertions** (`round3-invalidation-first.log`); legacy default remote push rewriting **1 test / 2 assertions**, including a request at the second origin (`round3-legacy-before.log`). A deliberate edit between config enumeration and metadata collection proves the cold-cache race by producing the hostile marker when the construction-stability guard is removed.

| Mutation | Oracle | Text log |
| --- | --- | --- |
| Ignore literal `pushInsteadOf` | Default/branch/upstream aliases send a request to the second origin | `round3-mutation-push.log` |
| Query HTTP wildcard scopes as destination URLs | Valid unrelated wildcard makes fetch fail | `round3-mutation-wildcard.log` |
| Restore parent-derived values into all submodules | Required child-global filter fails and its allowed marker is missing | `round3-mutation-submodule.log` |
| Give inventory a separate cancellation handle/deadline | Cancelled/timed reads and cancelled cache rebuilds exceed their deadline | `round3-mutation-deadline-cancel.log` |
| Bypass cache reuse | Warm read starts new metadata processes | `round3-mutation-cache.log` |
| Ignore cached file stamps | Included/global/system/worktree changes reuse stale metadata | `round3-mutation-stamps.log` |
| Keep cache when trust resolver changes | Re-trusted read reuses pre-revocation inventory | `round3-mutation-trust.log` |
| Accept edits during a cold inventory | Hostile fsmonitor marker appears and stale inventory remains warm | `round3-mutation-inventory-race.log` |
| Omit default legacy remote | Legacy `origin` forwards a private-header request after redirect | `round3-mutation-legacy.log` |

### Latency measurement

**Superseded in round 4:** SwiftPM reused a build plan when switching package paths in the same scratch directory. These archived numbers do not establish a baseline comparison; the clean-build, source-verified round-4 measurement below replaces them.

Generated fixture: 50,000 tracked ordinary files plus 20 initialized submodules, one modified tracked file, private fixture HOME/global/system config, no network. The same `GitInventoryPerformanceTests` source is used verbatim in an exported baseline package and this worktree. Both use the same SwiftPM scratch root, system Git, machine and shared full-lane lock. The benchmark calls real `GitService.status` and complete `GitController.refresh(automatic: true)` with Changes selected, including selected diff and the normal branch/stash/ignore/history reads. Warm-up precedes the measured samples; cache inventory is outside steady-state samples. Baseline source export and generated fixtures are removed after validation.

| Lane (25 samples per operation) | Status median / p95 (ms) | Changes median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| `origin/dev/next` `77ca6cb1` | 251.95 / 282.88 | 891.15 / 919.73 | baseline |
| Security branch, first run | 251.32 / 258.80 | 875.03 / 886.66 | status −0.25%; Changes −1.81% |
| Security branch, repeat | 252.95 / 258.96 | 871.60 / 893.22 | status +0.40%; Changes −2.19% |

Archived logs: `round3-perf-{branch,baseline,branch-repeat}.log`; full samples are printed in each log. The intended baseline definition did not force SwiftPM to regenerate its cached build plan, so the earlier performance conclusion is withdrawn.

The first benchmark harness raced the controller’s automatic initial refresh, producing 25 counter assertions. It is excluded (`round3-perf-branch-before-harness.log`). The corrected harness calls `setShown(true)`, waits for a completed initial refresh and selected diff, and asserts one completed refresh for every measured sample.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
# Each benchmark holds full-lane.lock and releases it in finally.
BELLO_GIT_INVENTORY_BENCHMARK="$B/round3-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK="$B/round3-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
  swift test --package-path "$B/round3-baseline/packages/bello-views" --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
# Repeat the first command after the baseline, under the same lock.
```

### Additional adversarial review and nearby instances

- Legacy `.git/remotes`/`.git/branches` defaults were absent from the original destination set. The generated legacy `origin` reproduces forwarding before the fix and under mutation (**1 test / 2 assertions** each). Git now resolves that default with push semantics, and legacy files/directories are part of the stamp inventory.
- Git-normalized equivalent URL scopes (uppercase remote scheme, lowercase configured redirect scope) defeated byte-order sorting of command-line overrides. The second server receives a request before the fix (**1 test / 1 assertion**, `round3-equivalent-before.log`). Refusal entries now follow every ordinary redirect entry; mutation reproduces the leak (`round3-mutation-equivalent.log`).
- Embedding a gitdir containing `=` directly into a `-c` key broke valid repository paths. The metacharacter fixture fails first (**1 test / 1 assertion**, `round3-path-before.log`). Conditional scope names are now quoted inside the private include file; command-line keys are fixed. The fixture includes equals, wildcard characters, a backslash and a newline. Mutation fails again (`round3-mutation-path.log`).
- Stamp checks for `/dev/null` caused unnecessary inventories and false construction failures because devfs timestamps advance. The fixture waits across a clock tick, writes generated diagnostics through its own handle, and requires no new inventory (**1 test / 1 assertion** before and under mutation, `round3-null-before.log`, `round3-mutation-null.log`). A borrowed singleton FileHandle was initially closed by earlier tests; the final fixture owns its handle.
- Initial wall-clock construction checks caused false invalidations in the first full run (**348 executed, 4 skipped, 20 failed assertions/errors**, `round3-views-before-stability-fix.log`). The final implementation rechecks actual config data and file stamps rather than comparing timestamps with `Date`. The cold-inventory race still fails under mutation of the final guard (`round3-mutation-inventory-race-final.log`).
- Finder cancellation/deadline coverage uses the real cached launcher and a generated FIFO include. Both paths fail when Finder supplies an independent invocation (`round3-mutation-finder-cancel.log`). Alternate-index coverage changes only `GIT_INDEX_FILE` in place; removing its stamp fails (`round3-mutation-alternate-index.log`). HEAD and `.gitmodules` changes also force new inventory.
- Reviewed cache coalescing, cancelled builders/waiters, empty global configs, missing includes, linked gitdirs, inherited conditional overrides, encoding guards, private file permissions/lifetime, trust changes and watcher invalidation. In-progress cache entries are not evicted by the size bound. Program authority still comes from Git’s scope, including the scope inherited by includes. All automatic reads retain no-lazy-fetch/no-protocol and textconv/signature protections. No production UI layout or helper/wire behavior changed.

### Final round-3 validation

Commands use this worktree and build root. The full package run is:

```sh
xcodegen generate --quiet
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
# Investigate the two timed-out classes separately while holding full-lane.lock:
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter GitCommitScopeTests
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter GitRepositoryStateTests
```

The full package run executed **353 tests: 347 passed, 4 skipped, 2 failed tests (3 assertions/errors)** (`round3-views-full.log`). Failures were the generated commit-hook reword timing out and a slow/failed repository-switch wait. Other tests in that run also showed 30–40 second stalls; no security/inventory test failed. The four skips are the existing three opt-in scale tests plus the new opt-in benchmark (run explicitly above). The laptop restarted before the remaining validation finished. The post-restart results below supersede this interrupted run.

## Round 3 post-restart validation (2026-10-20)

The surviving diff was inspected. The worktree remains on `dev/a130-security` at round-2 parent `6a7c0004`; no merge or fast-forward was performed. Both owned SwiftPM and native build-product directories were deleted before fresh validation. Logs use the distinct `round3-resume-` prefix. The new baseline is `origin/dev/next` at `28dbfb3090068e61ea308fa51b8d1db37b22013b`, fetched after restart.

Fresh original-source verification restored the round-2 production files temporarily (only a DEBUG query counter added): **6 tests failed with 12 assertions/errors** (`round3-resume-original.log`). These reproduce all five assigned findings. Restoring the fixes gives **18/18 passing** inventory/Finder regressions (`round3-resume-fixed-inventory.log`). Each mutation is restored before the next check.

Fresh mutations all fail at their intended assertions (no compile failures):

| Mutation | Tests / failed assertions | Text log |
| --- | ---: | --- |
| alternate-index | 1 / 1 | `round3-resume-mutation-alternate-index.log` |
| cache | 1 / 1 | `round3-resume-mutation-cache.log` |
| deadline-cancel | 3 / 3 | `round3-resume-mutation-deadline-cancel.log` |
| equivalent | 1 / 1 | `round3-resume-mutation-equivalent.log` |
| finder-cancel | 1 / 2 | `round3-resume-mutation-finder-cancel.log` |
| inventory-race | 1 / 1 | `round3-resume-mutation-inventory-race.log` |
| legacy | 1 / 2 | `round3-resume-mutation-legacy.log` |
| null | 1 / 1 | `round3-resume-mutation-null.log` |
| path | 1 / 1 | `round3-resume-mutation-path.log` |
| push | 1 / 3 | `round3-resume-mutation-push.log` |
| stamps | 2 / 4 | `round3-resume-mutation-stamps.log` |
| submodule | 1 / 2 | `round3-resume-mutation-submodule.log` |
| trust | 1 / 1 | `round3-resume-mutation-trust.log` |
| wildcard | 1 / 3 | `round3-resume-mutation-wildcard.log` |

After restoring every mutation, **52/52 tests pass** (`round3-resume-restored.log`: `GitInventoryTests`, `FolderBrowserTests`, `GitSafetyTests`). `xcodegen generate --quiet` and `git diff --check` also pass. The original-source selection and the per-mutation selectors are recorded below; all use `--package-path packages/bello-views --scratch-path "$B/views-tests"`.

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitInventoryTests/testCancellingRead|GitInventoryTests/testInventoryShares|GitInventoryTests/testPushDestinations|GitInventoryTests/testSubmodule|GitInventoryTests/testWarmReads|GitInventoryTests/testWildcard'
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitInventoryTests|FolderBrowserTests/testTrustedFinderInventory'
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitInventoryTests|FolderBrowserTests|GitSafetyTests|GitRedirectTests'
```

The last selector contains an unmatched `GitRedirectTests` alternative; the actual `GitHTTPRedirectTests` class is covered by the fresh full-package run. Mutation selectors are the named methods for push, wildcard, submodule, warm-read reuse, trust, legacy, conditional-policy paths, `/dev/null`, equivalent URLs, alternate index and cold-config edits; deadline/cancel selects all three inventory deadline/cancellation tests, stamp mutation selects warm-read and global/system/worktree tests, and Finder cancellation selects its new method.

### Fresh latency measurement

**Superseded in round 4:** the post-restart baseline log also shows a reused build plan. These numbers are retained as historical evidence only, not a validated comparison.

The generated fixture was deleted and rebuilt after restart: 50,000 ordinary tracked files and 20 initialized submodules. All three runs held the shared full-lane lock continuously, reused the same scratch directory and identical benchmark source, and took 25 warmed samples per operation. The baseline export has no production changes; its test target alone defines `BELLO_GIT_BENCHMARK_BASELINE`.

| Lane | Status median / p95 (ms) | Changes median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| baseline | 247.26 / 254.79 | 863.69 / 888.57 | baseline |
| branch | 250.38 / 259.03 | 866.91 / 880.23 | status +1.26%; Changes +0.37% |
| branch-repeat | 250.47 / 259.52 | 880.22 / 902.83 | status +1.30%; Changes +1.91% |

Archived logs: `round3-resume-perf-{branch,baseline,branch-repeat}.log`; all individual samples are retained. Exact commands are the latency commands above with the same paths and 25 samples, intended to compare against baseline `28dbfb3090068e61ea308fa51b8d1db37b22013b`. The clean-build round-4 comparison replaces this unverified result.

### Post-restart adversarial self-review

Reviewed the complete security branch plus the new round-3 diff, including production call sites and the nearby patterns exposed by the review. The shared Finder/GitService launchers cover all background Git entry points; the added metadata subprocesses remain confined and adopt the same invocation before launching. Cancellation is checked before cold work, between stamp checks, during cache waits, and while reading subprocess output. The builder checks cancellation again before publishing its completed result; cancellation of a waiting caller does not stop another caller's builder.

Push review covered literal defaults, named/default remotes, branch precedence, explicit push URLs, fetch versus push rewrites, legacy defaults, mixed-case/helper URLs, wildcard scopes, and Git-normalized equivalent URL keys. Program restoration is conditioned on each actual gitdir and uses that repository's own global/system entries. Private files are retained through the invocation and have 0700 directory / 0600 file permissions. Configuration origins, missing includes, symlinks, explicit indexes, HEAD, worktree/global/system changes, watcher invalidation and trust eviction were checked against the new tests and mutations. The cold-construction race, legacy origin, equivalent scopes, metacharacter paths and `/dev/null` cache behavior are covered by fresh mutations, not just the interrupted logs.

No additional production UI layout or helper/wire behavior changed in round 3. Webhooks still refuse every redirect and preserve permanent 3xx failure handling. No new unresolved finding or owner-policy question was identified in this review. Fresh full-suite and native execution results are recorded below.

### Fresh full-package result

`swift test --package-path packages/bello-views --scratch-path "$B/views-tests"` passed under the shared lock: **353 executed, 349 passed, 4 skipped, 0 failures**, 558.6 seconds (`round3-resume-views-full.log`). The four skips are three existing opt-in scale tests and the benchmark, which was run explicitly three times above. `GitCommitScopeTests` and `GitRepositoryStateTests`, which had timed out in the interrupted run, both pass in this fresh full run. No isolated-rerun substitution is needed.

The native product directory was removed before this validation cycle. Native commands use `PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO` with the class selections below. Every native/focus run acquires `full-lane.lock` and releases its own lock in `finally`. Serial-lane classes run alone.

### Fresh native and gallery results

**41 classes: 375 executed, 373 passed, 2 skipped, 0 failures.** The skips are the existing opt-in commit-browsing and diff-capture cases. Every selected class was rerun after restart; no interrupted-run result is included.

| Native class | Passed | Skipped | Fresh text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round3-resume-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round3-resume-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `round3-resume-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round3-resume-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `round3-resume-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round3-resume-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round3-resume-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round3-resume-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `round3-resume-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round3-resume-native-file-git.log` |
| FileTabTests | 16 | 0 | `round3-resume-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round3-resume-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `round3-resume-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round3-resume-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round3-resume-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `round3-resume-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round3-resume-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `round3-resume-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round3-resume-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round3-resume-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `round3-resume-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round3-resume-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round3-resume-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `round3-resume-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round3-resume-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round3-resume-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `round3-resume-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `round3-resume-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round3-resume-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `round3-resume-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round3-resume-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round3-resume-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round3-resume-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `round3-resume-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `round3-resume-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round3-resume-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round3-resume-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `round3-resume-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round3-resume-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round3-resume-native-boundaries.log` |
| WorkspaceTests | 17 | 0 | `round3-resume-native-boundaries.log` |

Exact native selections (each run holds the shared lock):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitRepositoryPermissionTests \
  -only-testing:PiAppTests/WebhookTests \
  -only-testing:PiAppTests/WebhookExchangeTests \
  -only-testing:PiAppTests/WorkspaceTests
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
for class in FilePreviewRefreshTests GitOperationSafetyTests FileFolderTests FileFindTabTests QuickOpenTests GitWorkingTreeWatcherTests GitPanelTimingTests CrashAuditRegressionTests GitRepositorySwitchTests ChangesTabFrameTests GitDiffTableTests GitPanelNarrowParityTests; do
  PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/$class
done
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/round3-resume-gallery" PI_BUILD_ROOT="$B" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Gallery: **112 regenerated PNGs**. Inspected `http-redirect` and `untrusted` scenes in both light and dark appearances at 920×600 and 310×600. The notices remain visible in the existing toolbar, using its existing ellipsis at constrained widths; the file list, commit controls and scrollable diff keep their existing layouts. Gallery assertions also cover 1180×780 and 700×640. Images remain under `$B/round3-resume-gallery`.

The generated benchmark index was independently counted: **50,001 ordinary entries (including `.gitmodules`) plus 20 gitlinks** (`round3-resume-fixture-counts.log`). The generated large repository and exported baseline package were removed after the runs; text logs and gallery images remain. No helper or wire production behavior changed in round 3, so their conditional reruns were not needed.

All five assigned round-3 findings are resolved. Fresh original-source failures, 14 mutation checks, restored focused runs, full package, native and gallery validation are complete. The earlier interrupted round-3 logs are excluded from these results. No unresolved security finding or owner decision remains.

## Round 4: non-recursive reads and fail-closed inventory reuse

The three P1 findings against `d38dc1b317f66c7617cc200d485fe629e1859515` are confirmed. This section supersedes round 3's conclusions about historical submodule reads and completeness of cache dependencies. The saved work from the tooling interruption was inspected and continued; final evidence below uses the completed round-4 diff.

### Implementation and nearby sweep

All `GitReadProcess` invocations force `diff.submodule=short`, `diff.ignoreSubmodules=dirty`, `submodule.recurse=false` and `status.submoduleSummary=false`. `show`, `log` and `diff` additionally receive `--submodule=short --ignore-submodules=dirty`; `status` receives `--ignore-submodules=dirty`. Parent status retains changed gitlink IDs, and historical patches contain the short gitlink representation. Dirty/untracked files inside a submodule are inspected only when that repository is opened explicitly, with its own global/system program settings. This follows the new owner rule; no UI layout changes.

The inline renderer launches another Git diff, while dirty-submodule inspection is separately gated by `ignore_dirty_submodules`; disabling both avoids relying on inherited flags in child repositories. [Git submodule renderer](https://raw.githubusercontent.com/git/git/v2.39.5/submodule.c), [Git worktree diff implementation](https://raw.githubusercontent.com/git/git/v2.39.5/diff-lib.c).

| Read family | Child-program audit |
| --- | --- |
| History `show` / `log`, working/staged/no-index/stash diffs | Short submodules and explicit dirty-submodule suppression; existing no-ext-diff/no-textconv and signature guards remain. |
| Status, preflight, snapshots | No child worktree inspection or summary process; gitlink ID changes remain visible. |
| Blame | Existing `--no-textconv`, file-only content input, shared submodule defaults, local program overrides and transport guards. |
| `ls-files`, `check-ignore`, `check-attr` | No `--recurse-submodules` caller; shared non-recursive defaults, fsmonitor scope policy, sparse-index/lazy-fetch confinement. |
| `rev-parse`, `symbolic-ref`, `for-each-ref`, `rev-list`, `merge-base`, `branch --list`, `remote`, `worktree list`, `check-ref-format`, `var` | Fixed data/format arguments; no signature, filter, editor, hook, recursive fetch or executable format requested. |
| `cat-file`, `ls-tree` | Raw blob/commit/type/tree reads, never `--filters` or `--textconv`; missing-object transport remains disabled. |
| `stash list`, `reflog show` | Fixed metadata format. Any internal Git log remains in the same repository and inherits its command-scope policy and short-submodule settings. |
| Metadata probes | Always confined, including new path-expansion/system-origin/symbolic-ref probes; same invocation cancellation and deadline. |

The inventory lookup includes the queried directory and complete environment; the stored key additionally includes resolved toplevel, gitdir, commondir and effective worktree. A warm lookup validates discovery and dependency stamps before returning that identity's inventory. Non-repository folders and unresolved worktree identities do not enter the cache. Discovery covers every queried-directory ancestor through the filesystem root, including `.git`, bare-repository markers and directory identity. The cache generation prevents an in-flight build from repopulating after trust/watcher invalidation.

Include expansion uses Git's `config --type=path` output with matching scope/origin/key records. Relative origins resolve against Git's effective setup directory, and relative include targets retain literal symlink/`..` traversal. Active and inactive conditional targets are stamped even when absent. The selected Git's system-config root is discovered rather than guessed; an empty/unrecognized result disables reuse. An unknown user expansion, unreadable stamp, symlink loop or unsupported file kind disables caching instead of treating it as unchanged absence. Only `ENOENT`/`ENOTDIR` represent known absence.

Git resolves conditional patterns relative to the including file's real path, and `onbranch` follows symbolic HEAD references. Consequently, the dependency set includes literal path-ancestor identities and the complete symbolic HEAD chain, captured before each link is read. Duplicate stamps are collapsed to keep warm validation small. [Git include and condition implementation](https://raw.githubusercontent.com/git/git/v2.39.5/config.c), [Git pathname expansion](https://raw.githubusercontent.com/git/git/v2.39.5/path.c).

| Fixed instance | Fixture / failure before the fix |
| --- | --- |
| 1p: historical child diff execution | `diff.submodule=diff`; child-local textconv writes a marker during `commitDiffFiles`, `show` and patch-producing `log`. The expanded fixture also checks diff/status/blame/ls-files/stash and retained gitlink changes. |
| 1q: changed discovery | Warm a plain folder before `git init`, then add hostile fsmonitor; separately warm a deep folder and create a repository in its parent below the old toplevel. Both ran the monitor. |
| 1r: `~user` / unresolved includes | Populate a previously absent named-user include pointing into the generated temp fixture; monitor ran. An inactive include naming a nonexistent fixture account incorrectly reused the old inventory. |
| 1s: relative origins from deep cwd | Populate an existing empty `.git/late-include` while querying `deep/nested`; no directory timestamp changes, monitor ran. |
| 1t: symlink/`..` include | Populate the actual external include after warming; lexical path normalization watched a different file and monitor ran. |
| 1t: conditional origin symlink | Retarget an origin directory between hardlinks of the same config inode; a relative `gitdir:` condition activates and monitor ran. |
| 1u: unreadable stamps / publication | Revoke access to an absent inactive-include target; original cache treated the failed stat as unchanged absence. A separate mutation verifies no publication across an in-flight trust invalidation. |
| 1v: symbolic HEAD chain | Retarget `refs/heads/alias` while keeping `.git/HEAD` byte-identical; `onbranch:main` activates and monitor ran. |
| 1w: private hunk-index churn | Creating a real `GitIndexSnapshot.copyForGit()` file invalidated a warm inventory and interrupted a concurrent cold inventory despite unchanged config/index/HEAD. |
| 1x: incomplete nested gitdir | A nested `.git` directory already names an absent external `commondir`. Moving a prepared common directory into place leaves `.git` unchanged, but changes discovery and ran its local monitor through the stale parent policy. |
| 1y: common-directory validity | Removing a common directory's `objects` or `refs` makes Git discover the parent repository. The old inventory missed the validity change and could run the parent's local monitor. |
| 1z: hunk-review cache scope | Each private `GIT_INDEX_FILE` split the scoped-config cache, adding seven inventory processes on every repeated review of the same file. |

All repositories, programs, includes and payloads are generated fixtures. The `~user` fixture obtains the current account's home pathname only to traverse back to its generated temporary file; it never reads/writes that account's real Git configuration. Positive tests retain a required conditional global filter when the child is explicitly opened and assert no parent-triggered child filter.

### Failing-first and mutations

`round4-original-complete.log` runs the initial ten regression fixtures against the committed round-3 production sources: **9 failed, 1 passed, 18 failed assertions**. The passing case is the positive `onbranch`/`gitdir`/`gitdir/i` target-creation sweep. Earlier fixture iterations and a mutation that initially exceeded Swift's expression type-checking limit are superseded by these compilable runs. The two additional conditional-cache bypasses also independently failed before their fixes (`round4-conditional-before.log`: 2 tests, 2 marker failures).

| Mutation, each restored afterward | Failed assertions |
| --- | ---: |
| Remove shared non-recursive arguments | 6 |
| Remove discovery stamps and permit unresolved identity caching | 2 |
| Remove Git's `--type=path` expansion | 1 |
| Resolve config origins against the queried deep directory | 2 |
| Lexically normalize include paths | 2 |
| Cache an unresolved inactive include | 2 |
| Treat unreadable stamps/symlink loops as usable | 4 |
| Omit symbolic HEAD-chain stamps | 1 |
| Omit config/include ancestor identities | 1 |
| Republish a build after trust-generation invalidation | 1 |

All **10 mutations** are killed by assertion failures, with **22 failed assertions** total. Logs: `round4-mutation-{recursive-reads,discovery,git-path-expansion,relative-origin,symlink-dotdot,unresolved-include,unreadable-stamp,symbolic-branch,origin-parents,trust-generation}.log`.

Exact focused/original/mutation command form:

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter GitInventoryTests
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests|GitRepositorySecurityTests'
```

Original/mutation runs select the corresponding `GitInventoryTests/test…` methods in the fixture table. The original-source run omits assertions on the newly added internal `cacheable` property so that the old implementation compiles; marker, result and query-count assertions are identical. All modified source bytes are restored in `finally` before the passing focused/full/native runs.

Original-source filter:

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter \
  'GitInventoryTests/testHistoricalSubmodule|GitInventoryTests/testRepositoryCreation|GitInventoryTests/testNamedUserInclude|GitInventoryTests/testRelativeInclude|GitInventoryTests/testIncludePaths|GitInventoryTests/testConditionalIncludes|GitInventoryTests/testUnresolvableInactive|GitInventoryTests/testUnreadableDiscovery|GitInventoryTests/testOnBranchInclude|GitInventoryTests/testConditionalIncludeObserves'
```

Each mutation used the same command with one corresponding filter: `GitInventoryTests/testHistoricalSubmodule`, `testRepositoryCreation`, `testNamedUserInclude`, `testRelativeInclude`, `testIncludePaths`, `testUnresolvableInactive`, `testUnreadableDiscovery`, `testOnBranchInclude`, `testConditionalIncludeObserves`, or `testTrustChangeDuring` (each with the `GitInventoryTests/` prefix).

The earlier `GitRepositorySecurityTests` submodule case expected recursive dirty-child status. Its two assertions failed after implementing the new owner policy (`round4-focused-restored.log`). It now asserts the staged gitlink remains visible and child worktree dirtiness is not inspected; the updated case fails against the old launcher (**1 test, 1 failed assertion**, `round4-submodule-policy-original.log`). Final restored focused validation: **40/40 passed** — `GitInventoryTests` 28/28 and `GitRepositorySecurityTests` 12/12 (`round4-focused-final.log`).

### Adversarial self-review

Reviewed the whole branch's shared launchers, trust resolver/write admissions, config scope restoration, URL redirect resolution, webhook delegate, watcher invalidation and invocation cancellation, then reviewed every round-4 production/test change. The conditional origin and symbolic-branch bypasses above were found during this review, reproduced and fixed before the full validation run.

The review checked absent-to-present discovery, nested gitdirs, worktree/common-dir identities, missing and inactive includes, named-user expansion, relative origins, symlink/`..` traversal, hardlinked origins, symbolic HEAD chains, unreadable metadata, default and explicit global/system roots, `/dev/null`, cold-build config races, warm reuse, invalidation during construction, cancellation and shared deadlines. Cache misses retain complete scoped inventory checks; failed proofs never authorize reuse. Metadata subprocesses remain confined and cancellation-aware.

Every production read caller was re-enumerated (`round4-final-read-sweep.txt`). No caller requests recursive submodules, filtered `cat-file`, a difftool, pager/editor, hook, signature verifier or transport. Explicit trusted mutations retain their prior behavior, including normal hooks. Per-repository global programs remain permitted only through that repository's own trusted read policy. Private-header URL protection and all-redirect webhook refusal remain intact and are covered again by the package/native suites. No helper or wire production behavior changed in round 4, so their conditional full-suite reruns are not required.

### Initial full package validation (before the final metadata refinement)

Under the shared full-lane lock:

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
```

**364 executed, 360 passed, 4 skipped, 0 failures**, 588.1 seconds (`round4-views-full.log`). The skips are the three existing opt-in scale cases and the benchmark, which runs separately. Both touched security classes and the existing folder, cancellation, redirect, history, patch, branch, stash and watcher cases pass in this complete run.

### Latency harness correction

The first round-4 comparison (`round4-perf-*.log`) is excluded: switching `--package-path` while reusing the scratch directory let SwiftPM retain the branch's build plan for the baseline. The earlier round-3 comparisons used the same harness and are explicitly superseded above. The originally reported round-4 medians are withdrawn.

The corrected comparison deletes only this workstream's `views-tests` products before **each** variant, then rebuilds the baseline and branch from their actual source directories. The benchmark prints a compile-time baseline/branch marker and `#filePath`; the harness verifies the compiled `GitView.build/sources` paths and records their GitService source hash. Baseline production source is checked byte-for-byte against the pinned `origin/dev/next` commit. The shared lock covers all builds and samples. No second DerivedData tree is created.

### Initial verified latency results (before the final metadata refinement)

Pinned baseline: `origin/dev/next` **fa18c41ed6f148ed84d85d80751395eac9044614**. Identical benchmark source and generated fixture: **50,001 ordinary tracked entries (including `.gitmodules`) and 20 initialized submodules** (`round4-fixture-counts.log`). Each variant takes 25 warmed samples per operation, with the shared lock held continuously across the three clean builds/runs.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| baseline | 251.50 / 265.61 | 912.74 / 939.39 | baseline |
| branch | 170.04 / 182.53 | 812.08 / 834.59 | status -32.39%; Changes -11.03% |
| branch-repeat | 171.99 / 181.01 | 821.22 / 830.96 | status -31.61%; Changes -10.03% |

Both branch runs are within the 5% budget. The authorized non-recursive policy also avoids child worktree inspection, so the measurement includes that workload reduction. This is the actual service/controller refresh through selected-diff publication, without display rendering. Logs: `round4-verified-perf-{branch,baseline,branch-repeat}.log`; source-path/hash proof: `round4-verified-build-{branch,baseline,branch-repeat}.json`. All three benchmark executions pass (1/1 each).

These initial controller-only Changes figures precede the final metadata refinement. The final comparison additionally includes the selected file's hunk review and supersedes these figures as panel-cost evidence.

Compiled GitService source SHA-256:

- baseline: `c7a555aeb616ca9dc9dfb2667f2ae20ff0aa279de97974e15266f91b629fd368`
- branch: `b8dcb30254961101b938f5fc1dbbcafeb9f2018b7845e843d3bd10bc70f703e7`

Exact measurement sequence, under one shared lock; `views-tests` contains only this workstream's SwiftPM products:

```sh
for package in packages/bello-views "$B/round4-baseline/packages/bello-views" packages/bello-views; do
  rm -rf "$B/views-tests"
  BELLO_GIT_INVENTORY_BENCHMARK="$B/round4-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
    swift test --package-path "$package" --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
done
```

The export comes from `git archive` of the pinned baseline; only its test target gains `BELLO_GIT_BENCHMARK_BASELINE`, and the identical benchmark test is copied in. Each run asserts its compile-time marker and compiled source paths, and records the source hash; baseline source bytes are checked against the pinned commit. This replaces every earlier unverified baseline comparison in this record.

### Native gallery investigation and final metadata refinement

The first native run passed all 40 non-gallery classes (**374 executed, 372 passed, 2 skipped**). The gallery then failed **1 test / 1 assertion** at `GitSafetyGalleryTests.swift:52`: its Fetch notice reported that the configuration inventory changed instead of the expected `http.extraHeader` refusal. The failure happened before the fetch subprocess launched. It is preserved in `round4-gallery-first.log`; the corresponding eight redirect images are in `$B/round4-gallery-failed`.

Two diagnostic reruns reproduced the same failure (**1 test / 1 assertion each**, `round4-gallery-diagnostic.log` and `round4-gallery-diagnostic-2.log`). The second records identical config bytes and the same `.git` device/inode/mode, while its size changed from 320 to 352 bytes. The directory listing gained `bello-hunk-B9BFC4B7-8DB2-48EC-A87A-BE19D1BB305C`. This is the private index created by `GitService.patchReview` through `GitIndexSnapshot.copyForGit`; the gallery's selected diff overlaps the transport inventory. A generated command-line control confirms the metadata probes alone leave the directory unchanged (`round4-directory-control.log`). All temporary diagnostics were removed.

Git directory discovery now watches directory identity rather than unrelated child-file timestamps. Actual config/include/index/HEAD files keep their full stamps. The gitdir and common directory additionally watch `objects` and `refs` identities, because removing those can make Git fall back to an ancestor. An unrecognized `.git` or `commondir` candidate below the selected toplevel disables cache retention: its external target can become valid without changing the candidate itself. Ordinary hunk-review files neither authorize repository programs nor invalidate a proven inventory.

The accompanying adversarial sweep reproduced two further discovery bypasses: activating an incomplete gitdir through its external common directory, and invalidating a known common directory so Git selects a parent with a local fsmonitor. The three new regression cases failed **3/3, with 6 assertions** before this refinement (`round4-metadata-before.log`), including marker executions; restoration passes **3/3** (`round4-metadata-fixed.log`).

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests/testPrivateIndexes|GitInventoryTests/testIncompleteGitDirectory|GitInventoryTests/testCommonDirectoryValidity'
```

All original mutations were repeated against the final source, alongside four new ones:

| Final mutation | Failed assertions |
| --- | ---: |
| Recursive reads | 9 |
| Discovery / missing identity | 2 |
| Git pathname expansion | 1 |
| Relative origins | 2 |
| Symlink / `..` semantics | 2 |
| Unresolved includes | 2 |
| Unreadable stamps | 4 |
| Symbolic HEAD chain | 1 |
| Origin ancestors | 1 |
| Trust generation | 1 |
| Restore `.git` child-timestamp invalidation | 2 |
| Cache unrecognized repository candidates | 1 |
| Omit common-directory validity markers | 4 |
| Split scoped config by each private index | 1 |

**14/14 mutations are killed, 33 failed assertions.** Logs are `round4-final-mutation-<name>.log`; the four additional names are `private-index`, `unrecognized-directory`, `common-validity`, and `private-index-scope`. Each uses the focused command above with the corresponding single test name; all source bytes are restored afterward. Final restored focused validation is **44/44 passed** (`GitInventoryTests` 32, `GitRepositorySecurityTests` 12; `round4-final-focused-restored.log`). The final validation below repeats the package, native, gallery and verified latency runs after this refinement; earlier measurements remain identified as preliminary evidence.

### Hunk-review cache scope

The follow-up performance check found that the private index pathname also split the configuration cache. With the fixture's repository trusted and its raw-diff scratch folder outside that trust, a second `patchReview` increased inventory queries from **14 to 21**: **1 test / 1 failed assertion** (`round4-hunk-scope-before.log`). The earlier blanket-trust fixture also counted five irrelevant scratch-folder probes and is superseded by this project-scoped fixture.

Since every read is non-recursive, its program policy depends on scoped configuration rather than which private index supplies the content. `GitReadProcess` removes `GIT_INDEX_FILE` only from the inventory environment; the launched Git process retains the original environment. Transport inventories still use their actual index for submodule destinations. The alternate-index test now checks that transport dependency directly and verifies a read sees a staged change present only in the alternate index while leaving the normal index unchanged. Both focused cases pass (**2/2**, `round4-hunk-scope-fixed.log`).

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests/testHunkReadsReuse|GitInventoryTests/testHeadGitmodules'
```

The final benchmark uses project-scoped trust and includes `patchReview` after selected-diff publication, on both the baseline and branch. It still excludes display rendering; it now covers the extra private-index work automatically requested by the native Changes panel. The final clean-build proof also records the `GitProcessSafety` source paths and `GitConfiguration.swift` hash where that target exists. All mutations and affected suites are repeated after this last change.

### Validation tooling interruption

The final package run completed successfully before the tooling interruption (368 executed, 4 skips, 0 failures). Its final source hashes are unchanged. The interruption terminated the benchmark coordinator during the repeat's test launch after two completed measurements; no failed test was reported. The exited coordinator's own lock was verified by owner/PID and released. Those partial comparison logs are retained as `round4-interrupted-verified-*` and excluded from the final latency table. The full three-variant comparison was restarted under one lock, followed by all affected native classes and the gallery; all completed successfully below.

### Final round-4 package and latency validation

Full package: **368 executed, 364 passed, 4 skipped, 0 failures** (`round4-final-views-full.log`). The three opt-in scale cases remain skipped; the fourth skip is the benchmark run explicitly below. This repeats every FileFinder/GitView test after the final metadata and hunk-cache changes.

```sh
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
```

The final baseline is pinned `origin/dev/next` **fa18c41ed6f148ed84d85d80751395eac9044614**. Each clean build uses the identical benchmark and the same generated **50,001 ordinary tracked entries plus 20 initialized submodules**, with **25 warmed samples** per operation. Changes includes controller refresh, selected-diff publication and the selected file's hunk review. The shared lock covers all three builds and measurements.

| Final variant | Status median / p95 (ms) | Changes including hunk review median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| baseline | 250.92 / 266.56 | 2178.80 / 3028.77 | baseline |
| branch | 175.19 / 182.05 | 2058.24 / 2220.26 | status -30.18%; Changes -5.53% |
| branch-repeat | 164.93 / 174.83 | 2061.51 / 2096.07 | status -34.27%; Changes -5.38% |

Both branch runs satisfy the 5% budget. All three benchmark executions pass (1/1 each). This final table supersedes the earlier controller-only Changes measurements. Text logs: `round4-final-verified-perf-{branch,baseline,branch-repeat}.log`; verified source-path/hash records: `round4-final-verified-build-{branch,baseline,branch-repeat}.json`. The final GitConfiguration source SHA-256 is `04ee3349680ef2fe3e99c5b5fafea7b92ea2540996106cc3d983b21b8f669652`.

The exact clean-build sequence is the same three-variant shell loop recorded above, using the final expanded benchmark. Each variant removes only this workstream's `views-tests` products before building, verifies its compile-time marker and compiled source paths, and checks the baseline GitService bytes against the pinned commit. No additional DerivedData copy is used.

### Final round-4 native validation

**41 classes: 375 executed, 373 passed, 2 skipped, 0 failures.** The skips are the existing opt-in commit-browsing and diff-capture cases. All runs use this workstream's build root and hold the shared lock; serial-lane classes run alone. The host confirms isolated test defaults and `PiAppTests-Home` under this build root in its text logs.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round4-final-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round4-final-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `round4-final-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round4-final-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `round4-final-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round4-final-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round4-final-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round4-final-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `round4-final-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round4-final-native-file-git.log` |
| FileTabTests | 16 | 0 | `round4-final-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round4-final-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `round4-final-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round4-final-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round4-final-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `round4-final-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round4-final-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `round4-final-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round4-final-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round4-final-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `round4-final-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round4-final-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round4-final-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `round4-final-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round4-final-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round4-final-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `round4-final-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `round4-final-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round4-final-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `round4-final-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round4-final-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round4-final-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round4-final-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `round4-final-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `round4-final-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round4-final-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round4-final-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `round4-final-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round4-final-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round4-final-native-boundaries.log` |
| WorkspaceTests | 17 | 0 | `round4-final-native-boundaries.log` |

Exact command prefix: `PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO`. Each selected class adds `-only-testing:PiAppTests/<Class>`. Selections:

- Boundary batch: `GitRepositoryPermissionTests WebhookTests WebhookExchangeTests WorkspaceTests`.
- File/Git batch: `FileBlameTests FileTabTests FileHiddenReadTests FilePageReadTests FileReviewStateTests GitBranchesInteractionTests GitChangelistReadTests GitCommitBrowsingTests GitConfirmationSheetTests GitDiscardQuestionTests GitHistoryFilterTests GitHunkReviewTests GitIntegratedHistoryTests GitPanelAuditTests GitPanelDiffCaptureTests GitPanelLayoutTests GitPanelRedrawTests GitPanelShownTests GitPanelWidthTests GitPathBoundaryTests GitRenameTests GitToolTests QuickOpenPlacementTests ChangesTabTests`.
- Each alone: `FilePreviewRefreshTests GitOperationSafetyTests FileFolderTests FileFindTabTests QuickOpenTests GitWorkingTreeWatcherTests GitPanelTimingTests CrashAuditRegressionTests GitRepositorySwitchTests ChangesTabFrameTests GitDiffTableTests GitPanelNarrowParityTests`.

Gallery command:

```sh
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/round4-final-gallery" PI_BUILD_ROOT="$B" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Gallery regenerated **112 PNGs** under `$B/round4-final-gallery`.

### Final gallery inspection and adversarial review

Visually inspected eight final PNGs: `http-redirect-{light,dark}-{920x600,310x600}.png` and `untrusted-{light,dark}-{920x600,310x600}.png`. Both themes show the expected redirect refusal or trust notice. The narrow layout retains the notice in its row with the existing ellipsis; normal-width scenes retain the file list and diff. The gallery test also checks the complete notice text, including `http.extraHeader`, so the earlier transient inventory error cannot pass. Image hashes are recorded in `round4-final-gallery-inspection.json`.

The final adversarial review rechecked all changed production code after the metadata and private-index fixes: short submodule output on every read launcher; discovery fallback through nested/external gitdirs; conditional and absent include targets; symbolic branches and origin ancestors; unreadable dependency handling; cache publication across trust invalidation; cancellation/deadline propagation; and preservation of the actual index supplied to a hunk command. The scope-specific global-program and private-header redirect tests pass in the final complete suites. No additional unresolved finding was identified. No helper or wire source changed in this round.

All four final production-source hashes match `round4-final-source-hashes.json` after validation, and the first native build log confirms compilation from this worktree's GitProcessSafety sources. `git diff --check` passes. The completed generated large-repository fixture and baseline export were removed; text logs, source-proof JSON and gallery PNGs remain under this workstream's build root. No native Clone directory remained. Default XCTest result bundles were deleted after recording their text results; no named result bundle was requested. Every lock owned by this workstream was released.

Round 4 is complete: the three review findings and separately listed discovery/performance instances are fixed, with failing-first evidence, 14 killed mutations, 44 passing focused tests, the full package/native validation and a source-verified latency comparison within budget. No owner decision remains for this workstream. The branch is ready for the lead's review and merge; no merge or fast-forward to `dev/next` was performed.

## Round 5: process-dependent configuration and stdin isolation

The review P1 is **confirmed** against round-4 commit `1fbd0dca6f1021b66f280e08c30c7da5bd5f42c3`. The old inventory saw empty stdin, while blame handed the viewed bytes to the actual Git process. An include of `/dev/stdin` or `/dev/fd/0` interpreted those bytes as config and ran the fixture fsmonitor. Disabling cache reuse did not prevent execution. A generated FIFO also supplied benign inventory bytes and hostile command bytes, demonstrating the same mismatch independently of blame.

### Fixed instances and adjacent sweep

| Instance | Change | Boundary/compatibility |
| --- | --- | --- |
| 1aa: dynamic config sources | Trusted launch now requires a separate `permitsUnconfinedRead` proof. An uncacheable inventory is no longer sufficient permission. Stream/device failures in metadata select the existing sandbox. | Applies at every scope, including global/system includes. Ordinary static global filters and fsmonitor remain allowed. Dynamic sources never enter the inventory cache. |
| 1aa: nested/inactive sources | Git expands include paths; the inventory also parses inactive conditional include branches with `config --file <path> --no-includes`, recursively inspecting their include targets. File type, resolved path ancestors, absent targets and pre-read stamps are checked. Unresolved or excessive include graphs use confinement. | No handwritten `~`, named-user or conditional pathname expansion. `/dev`, `/dev/fd`, `/proc`, FIFOs, sockets, devices, dangling links and unreadable types cannot authorize an unconfined read. |
| 1aa: metadata consuming live streams | Metadata processes add a sandbox rule permitting regular-file/directory reads and the null device, while denying reads from other vnode types. | A FIFO cannot block inventory or feed it a different first payload. The final confined command can still read a valid FIFO producer under its normal cancellation/deadline. |
| 1ab: blame stdin | The displayed bytes are written into a private 0700 snapshot directory, passed using `--contents <snapshot> -- <path>`, and removed on return/cancellation. | Preserves the displayed snapshot even if the underlying file changes. Neither config nor blame shares an attacker-influenced stdin. |
| 1ac: folder stdin | `check-ignore` takes bounded batches after `--`; its C-quoted output is decoded. | Same tracked-file/ignore semantics, including leading options, Unicode, quotes, backslashes and every Git control-byte escape. No filename bytes enter config stdin. |

The selected empty **root** configuration `/dev/null` remains a stable, known-empty source (used by isolated fixtures); this exception never applies to an **include** directive, including `include.path=/dev/null`. Existing repository discovery, include/ancestor stamps, byte confirmation, trust invalidation and read deadlines remain in force. Metadata failures caused by dynamic sources are caught only at the read launcher; cancellation, timeout and malformed override errors are not swallowed. Explicit transport writes still require a successful header inventory before starting.

The stdin sweep found only two production read-payload callers, blame and folder ignore queries; both are fixed. The remaining actual payload call is the explicitly admitted `post-rewrite` hook's old/new hashes (`readOnly: false`), unchanged. Generic optional-input plumbing has no remaining production read caller. Evidence: `round5-stdin-sweep.txt` and `round5-launcher-sweep.txt`.

Git's argument and stdin forms of `check-ignore` call the same path matching routine. Its implementation rejects `-z` without `--stdin` and writes C-quoted paths in argument mode, which is why the decoder is required. [Git check-ignore implementation](https://raw.githubusercontent.com/git/git/v2.39.5/builtin/check-ignore.c). Include path expansion and relative-origin handling continue to use Git's parser. [Git config implementation](https://raw.githubusercontent.com/git/git/v2.39.5/config.c).

### Failing-first and mutation evidence

All six regressions ran with the four changed production files temporarily restored byte-for-byte from `1fbd0dca`; tests remained new. **6 tests failed, 48 assertions failed, 0 unexpected failures.** Every fixture program only creates its generated marker and emits a fixture fsmonitor token. `round5-before-all-six.log` is the complete authoritative baseline; earlier four-case reproductions remain in `round5-before{,-complete}.log`.

Representative baseline assertions (the `XCTAssertFalse` checks the marker file):

```text
testStdinIncludesCannotExecuteBlameContents: XCTAssertFalse failed - /dev/stdin
testStdinIncludesCannotExecuteBlameContents: XCTAssertFalse failed - /dev/fd/0
testFIFOIncludeUsesConfinementForChangingContent: XCTAssertEqual failed: ("8") is not equal to ("0") - Inventory must not consume a live config stream
testFIFOIncludeUsesConfinementForChangingContent: XCTAssertFalse failed
```

| Regression | Failing assertions before the fix | Fixed behavior |
| --- | ---: | --- |
| `testStdinIncludesCannotExecuteBlameContents` | 4 | Both stdin/fd0 includes preserve two displayed blame lines; no marker. |
| `testDynamicIncludeSourcesAlwaysUseConfinement` | 8 | Direct, alias, nested, active/inactive conditional, null-device and missing-descriptor targets select sandbox-exec. Valid inputs read successfully. |
| `testFIFOIncludeUsesConfinementForChangingContent` | 3 | Inventory consumes zero stream payloads; final status reads the hostile fixture under confinement, succeeds and creates no marker. |
| `testWarmRegularIncludeRetargetedToStdinLosesExecutionPermission` | 2 | A static trusted read runs the fixture global monitor; retargeting the include to stdin removes execution permission and still permits status. |
| `testSocketIncludeUsesConfinementEvenWhenInactive` | 1 | A generated inactive socket include selects confinement; status succeeds. |
| `testStdinIncludesDoNotConsumeFolderPaths` | 30 | Both includes produce an unwarned listing with all 14 unusual ignored names dimmed and the tracked README visible. |

The nonexistent descriptor `/dev/fd/999` selects confinement but retains Git's expected status 128: there is no readable source to make that malformed repository succeed. All valid stdin, FIFO, inactive socket and alias fixtures succeed under confinement.

| Mutation | Selected tests | Failed assertions |
| --- | ---: | ---: |
| Ignore `permitsUnconfinedRead` and authorize any completed inventory | 2 | 3 |
| Allow metadata to consume non-regular streams | 1 | 1 |
| Restore blame's `--contents -` and stdin payload | 1 | 2 |
| Restore folder `check-ignore --stdin` | 1 | 30 |
| Skip recursive include-target inspection | 2 | 3 |
| Accept every configuration source type | 1 | 2 |

**All 6 mutations killed, 41 failed assertions, 0 unexpected failures.** Production bytes were restored after every mutation, including on runner errors. Logs: `round5-mutation-{permission-gate,metadata-stream,blame-stdin,folder-stdin,include-depth,source-kind}.log`; machine-readable totals in `round5-mutations.json`. The harness initially mistook XCTest's `failed -` text for an absent assertion; it was corrected and the complete sequence rerun. This was a harness check, not a surviving mutation.

Focused surrounding validation passed **81/81**: FolderBrowserTests 19, GitBlameTests 13, GitInventoryTests 37, GitRepositorySecurityTests 12 (`round5-focused-fixed.log`). This includes allowed global programs, blocked local programs, non-recursive history, discovery/include invalidation, cancellation and timeouts. Two preliminary build-only errors are retained: an incremental linker mismatch after changing the public initializer signature (`round5-fixed-initial.log`, corrected by preserving that signature), and the socket fixture needing `Darwin.bind` qualification (`round5-focused.log`). Neither run executed tests.

Exact focused command (all full/focused package runs use the generated home and empty root global config):

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
env CFFIXED_USER_HOME="$B/round5-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests|GitRepositorySecurityTests|GitBlameTests|FolderBrowserTests'
```

The failing-first six-case selection is:

```text
GitInventoryTests/testStdinIncludes|GitInventoryTests/testDynamicIncludeSources|GitInventoryTests/testFIFOInclude|GitInventoryTests/testWarmRegularIncludeRetargeted|GitInventoryTests/testSocketInclude|FolderBrowserTests/testStdinIncludes
```

Mutation commands use the same `swift test` prefix and the corresponding case(s) in the table; exact selections and restoration are recorded in `$B/round5-mutations.py`.

### Self-review correction: Unicode include paths

The first complete package run passed **374 executed / 370 passed / 4 skipped / 0 failures**, but the source review found a compatibility edge in the newly added per-file parser. Foundation would rewrite a composed Unicode filename when passing `--file`; the existing byte-preservation guard correctly refused that argument, but the new traversal propagated the failure even when Git had already safely reported the file's complete scoped contents.

`testUnicodeIncludePathsKeepReadPolicy` reproduced **1 failed test / 2 failed assertions** on that implementation (`round5-unicode-before.log`): an active, regular global include containing a permitted fixture monitor failed, and an unseen inactive Unicode include containing a nested stdin include failed instead of selecting confinement. Both cases now pass. The inventory reuses the complete include expansion for files already reported as origins; only unseen conditional branches need another parse. If such a path cannot be passed unchanged, the read uses confinement. This also avoids redundant metadata processes for active includes.

Two additional mutations independently remove known-origin reuse and the unrepresentable-path fallback. The first produces **2 failed assertions**; the second produces **1** (`round5-mutation-unicode-{known-origin,unresolved}.log`). All six earlier mutations were repeated after this correction. Final total: **8 mutations killed / 44 failed assertions / 0 unexpected failures**.

The preliminary package log is retained as `round5-pre-unicode-final-views-full.log`. The performance coordinator was stopped while waiting for another workstream's lock; no measurement had started and no foreign lock was touched. Final package, benchmark and native validation are restarted with the corrected source and the seventh regression. The final results below supersede that preliminary package run.

### Adversarial source review

Reviewed the complete branch's production diff and the round-5 changes (`round5-reviewed-branch.diff`, `round5-reviewed-source.diff`), then re-enumerated every Git launcher and stdin caller. The review checked direct/nested/inactive includes, resolved-device aliases, missing descriptors, non-regular roots, immutable empty root config versus null-device includes, cold and warm inventories, regular-file retargeting, byte-preserving include parsing, and the distinction between permission to execute and permission to cache.

The regular-file restriction is installed before any inventory subprocess starts. Every metadata subprocess still adopts the originating invocation; the final confined process shares its deadline and cancellation handle. The fallback catches only the dedicated confinement-required result. Valid static global/system programs retain their positive tests; local/worktree programs retain their negative tests. The snapshot lifetime spans the asynchronous blame call and all exits remove its private directory. Folder batches retain their existing count/byte limits and decode Git's quoting without interpreting paths as shell input.

The nearby sweep found no other production read that feeds repository-controlled stdin. Non-recursive read flags, lazy-fetch prevention, private-header redirects, live trust checks for writes, and webhook redirect refusal are unchanged. No helper/wire production or test file changed in round 5, so the conditional helper/wire/concurrent/acceptance reruns are not required for this round. No additional unresolved finding or owner-policy question was identified.

### Final round-5 validation and latency

Full bello-views package: **375 executed, 371 passed, 4 skipped, 0 failures** (`round5-final-views-full.log`). The skips are the existing opt-in scale/benchmark cases; the benchmark is explicitly executed below. The full run follows all mutation restorations, and all six changed source/test hashes match `round5-tested-source-hashes.json`.

The final focused rerun also passed **82/82**: FolderBrowserTests 19, GitBlameTests 13, GitInventoryTests 38, GitRepositorySecurityTests 12 (`round5-final-focused.log`). This includes all seven round-5 regressions after all eight mutations were restored.

```sh
env CFFIXED_USER_HOME="$B/round5-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
```

The full package run, performance runs and native/gallery runs each hold the shared full-lane lock. The initial package run waited for the panel workstream to release it; no other workstream's lock or build products were changed.

The freshly fetched baseline is pinned `origin/dev/next` **3249aa24c32ae29c83da6537dddf23f1fd6a6594**. Its package is exported with `git archive`, without checking out or integrating that branch. The same generated fixture contains **50,001 ordinary tracked entries plus 20 initialized submodules**; there is one changed tracked file. Each variant takes **25 warmed samples** of status and a complete Changes refresh including selected diff and hunk review.

| Variant | Status median / p95 (ms) | Changes including hunk review median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| baseline | 252.85 / 263.75 | 2171.18 / 2209.41 | baseline |
| branch | 166.53 / 173.82 | 2023.26 / 2085.86 | status -34.14%; Changes -6.81% |
| branch-repeat | 165.76 / 173.65 | 1940.07 / 1960.53 | status -34.45%; Changes -10.64% |

Both branch runs meet the 5% budget. All three benchmark executions pass (1/1 each). Text logs: `round5-final-verified-perf-{branch,baseline,branch-repeat}.log`; source-proof records: `round5-final-verified-build-{branch,baseline,branch-repeat}.json`. Before each build, only this workstream's `views-tests` products are removed. Each run verifies the compile-time variant marker, actual compiled source paths, and GitService bytes/hash; the baseline GitService must exactly match its pinned commit. The branch also verifies its GitProcessSafety source paths and GitConfiguration hash. The baseline receives the identical benchmark source and only a test-target `BELLO_GIT_BENCHMARK_BASELINE` define.

Exact measurement command, executed for branch, baseline, then branch again after the per-variant clean:

```sh
env CFFIXED_USER_HOME="$B/round5-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  BELLO_GIT_INVENTORY_BENCHMARK="$B/round5-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
  swift test --package-path "$PACKAGE" --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
```

`PACKAGE` is this worktree's `packages/bello-views`, then `$B/round5-baseline/packages/bello-views`, then the worktree package again. `$B/round5-final-performance.py` records the exact export/build-proof sequence.

Native: **41 classes, 375 executed, 373 passed, 2 skipped, 0 failures**. The skips remain the opt-in commit-browsing and diff-capture cases. Every invocation uses `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1 PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO`, with `-only-testing:PiAppTests/<Class>` for each selected class. The host uses the generated `PiAppTests-Home`; the extra variables keep direct test Git subprocesses off the real global/system config too. The class batches and serial-alone selections are identical to the explicit round-4 list above; fresh round-5 evidence follows.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round5-final-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round5-final-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `round5-final-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round5-final-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `round5-final-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round5-final-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round5-final-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round5-final-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `round5-final-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round5-final-native-file-git.log` |
| FileTabTests | 16 | 0 | `round5-final-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round5-final-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `round5-final-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round5-final-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round5-final-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `round5-final-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round5-final-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `round5-final-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round5-final-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round5-final-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `round5-final-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round5-final-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round5-final-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `round5-final-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round5-final-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round5-final-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `round5-final-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `round5-final-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round5-final-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `round5-final-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round5-final-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round5-final-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round5-final-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `round5-final-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `round5-final-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round5-final-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round5-final-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `round5-final-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round5-final-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round5-final-native-boundaries.log` |
| WorkspaceTests | 17 | 0 | `round5-final-native-boundaries.log` |

Gallery regenerated **112 PNGs**, using:

```sh
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/round5-final-gallery" PI_BUILD_ROOT="$B" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1 \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Visually inspected the eight `http-redirect-{light,dark}-{920x600,310x600}.png` and `untrusted-{light,dark}-{920x600,310x600}.png` scenes. Both themes retain the expected redirect refusal or trust notice; narrow notices use the existing ellipsis, and the file list/diff remain available. The gallery also asserts the complete notice text. The image hashes are in `round5-final-gallery-inspection.json`.

Final source review and hash checks match the tested bytes after all mutations and the Unicode correction. `git diff --check` passes. The fixture index was independently counted before cleanup: 50,001 ordinary entries and 20 submodules (`round5-fixture-counts.json`). The generated baseline export, large fixture and default XCTest result bundle were removed; no native Clone directories remained. Text logs, source-proof records and gallery PNGs are retained under this workstream's build root. All locks owned by this workstream were released; another workstream's subsequent lock was left untouched.

Round 5 is complete: the review P1 and separately recorded stdin/Unicode instances are fixed, with seven failing-first regressions, eight killed mutations, 82 passing focused tests, complete package/native/gallery validation, and three source-verified measurements within budget. No unresolved finding or owner decision remains in this workstream. No merge or fast-forward to `dev/next` was performed.


## Round 6 — origin chains and repository-wide redirect refusal

The three review P1s are confirmed. Failing-first tests ran against unchanged round-5 production sources (`67e25bab3396e1aadee582e617fd492304b8c3da`) with only regression tests added: **3 tests, 10 failed assertions** (`logs/round6-failing-first.log`). All fixtures are generated; HTTP receivers bind loopback and configured programs only create the fixture marker.

| Finding | Failing-first evidence | Fix |
| --- | --- | --- |
| Symlink inside a config origin's target chain | `testConditionalIncludeObservesSymlinksInsideOriginTarget`: external/config → current/config; current switches between directories with hardlinked config files. Git activates the relative `gitdir:./.git` include; query count stays 9 and fsmonitor creates the marker (2 assertions). | Stamp the full component walk, including `lstat` of each symlink, its recursively expanded target and final file. Apply the same walk to repository/discovery/config/include/index/HEAD dependencies, preserve the queried repository spelling, and disable caching for incomplete chains. Directory stamps retain identity-only comparisons so ordinary working-file saves do not invalidate inventories. |
| Newline-only extraHeader after a private value | `testNewlineOnlyHeaderDoesNotPermitRedirects`: a second value of `"\n"` causes the old URL-match/value check to allow a 307. The second receiver gets a request (2 assertions). | NUL-delimited inventory key presence, without interpreting header values, protects every URL. |
| URL-less legacy default remote | `testURLLessLegacyDefaultRemoteCannotForwardHeaders`: the sole configured `backup` has only a fetch refspec; `.git/remotes/backup` supplies its URL. Fetch, pull and push each reach the second receiver after a 308 (6 assertions). | Remove remote/default/pushurl/pushInsteadOf resolution, its per-command memo and legacy-definition stamps. All network commands use the same cached repository-wide refusal decision. |

Additional policy coverage checks case-varied keys, empty reset values, newline values, unrelated and wildcard HTTP scopes, restoration of `initial` after removing every header key, all configured scope types, URL-scoped refusal overrides, alternative HTTP/helper URL forms, and existing push/default rewrite fixtures. Header-free same-host renamed-repository redirects remain a real successful smart-HTTP fetch.

Primary-source review: Git resolves a relative `gitdir:` condition against the origin's realpath ([config.c](https://github.com/git/git/blob/v2.39.5/config.c#L213-L223)); only a genuinely empty value clears previous extra headers ([http.c](https://github.com/git/git/blob/v2.39.5/http.c#L363-L369)); configured default selection includes URL-less remote names ([remote.c](https://github.com/git/git/blob/v2.39.5/remote.c#L508-L520)). The new redirect decision does not reproduce any of these remote/header resolution algorithms.

Development validation caught a buffer-pointer error in the first implementation of symlink reading (SIGSEGV before assertions, including after a clean build). `readlink` now receives the array's explicitly scoped mutable byte buffer. The passing runs below supersede those failed development attempts; their logs remain `round6-fixed.log` and `round6-focused.log`.

### Round-6 mutations and adversarial self-review

| Mutation | Regression selection | Failed assertions |
| --- | --- | ---: |
| Stop resolution at the first symlink instead of walking its target | Nested origin-target symlink retarget | 2 |
| Inspect only the last header value and treat LF as empty | Newline-only header after a private value | 2 |
| Require a configured `remote.*.url` before enabling protection | URL-less legacy default fetch/pull/push | 6 |
| Override only generic followRedirects | Equivalent URL scopes and the five HTTP redirect statuses | 6 |
| Ignore URL-scoped extraHeader keys | Empty/case-varied/unrelated/wildcard key-presence matrix | 4 |
| Resolve submodule checkout paths before inventory | Retargeted submodule checkout alias | 2 |

**6 mutations killed, 22 failed assertions, no unexpected test failures.** Production sources were restored in `finally` after each case. Logs: `round6-mutation-{omit-target-chain,newline-value-clear,require-remote-url,omit-url-overrides,omit-scoped-headers,resolve-submodule-before-inventory}.log`; structured evidence `round6-mutations.json` under the build root's `logs/`.

Adversarial source review covered the complete new diff and adjacent launch/cache paths. Every supported network Git launch (fetch/pull/push) reaches the shared repository-wide decision. No `get-urlmatch`, remote enumeration, literal push rewrite, legacy-default selection, or value-trimming redirect probe remains in production. All URL-scoped redirect keys get the same refusal, so their relative specificity, spelling or argument ordering cannot re-enable redirects. Byte-distinct keys remain `Data` values; unrepresentable override arguments still fail closed.

Every cached dependency now contributes its resolution walk before publication, including discovery ancestors, the original queried path, resolved worktree/gitdir/commondir, config origins, expanded includes, symbolic HEAD dependencies and submodules. The walk records symlink metadata with `lstat`, visits intermediate target components before `..`, and stamps final targets even when they are hardlinks. A link retarget therefore invalidates reuse independently of final file identity. Missing components retain absence stamps; unreadable components, invalid link bytes, readlink failures and link-depth exhaustion prevent caching. The same walk checks dynamic include sources before permitting unconfined reads. Existing cache-generation, watcher, cancellation/deadline and static-config confirmation checks remain in force; the new per-dependency walk also checks the invocation deadline.

The neighboring read launchers still force short/non-recursive submodule output, prevent lazy fetch, and supply no attacker-controlled stdin. Trusted global/system programs remain allowed for proven static config; local/worktree programs remain masked. Explicit writes retain the trust notice and normal hooks; webhooks retain all-redirect refusal. No helper or wire behavior changed in round 6, so helper/wire/concurrent/acceptance reruns are not applicable. No additional unresolved finding or owner-policy question emerged from this review.


The self-review found one additional instance of the resolution-chain issue in the same inventory constructor: a gitlink's checkout path was resolved before constructing its child inventory. `testSubmoduleAliasRetargetRechecksConfiguration` retargets an initialized submodule alias from a header-free fixture to a fixture with an extraHeader. Before the fix, the parent reused the old child policy (query count remained 14), producing **2 failed assertions** (`round6-submodule-failing-first.log`). Keeping the original child path fixes both assertions (`round6-submodule-fixed.log`, **1/1 passed**); restoring early resolution kills the additional mutation. Aliased checkouts whose discovery cannot be proven from the original spelling conservatively bypass caching; normal initialized submodules retain caching. The original five mutation cases were repeated after this change. Final failing-first total: **4 regressions / 12 failed assertions**.

Exact focused/failing-first commands (run from this worktree; each run writes a separate text log under `$B/logs`):

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
# Original three regressions against round-5 production sources:
env CFFIXED_USER_HOME="$B/round6-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests.testConditionalIncludeObservesSymlinksInsideOriginTarget|GitInventoryTests.testNewlineOnlyHeaderDoesNotPermitRedirects|GitInventoryTests.testURLLessLegacyDefaultRemoteCannotForwardHeaders'
# Adjacent submodule regression, separately before and after its one-line fix:
env CFFIXED_USER_HOME="$B/round6-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter GitInventoryTests/testSubmoduleAliasRetargetRechecksConfiguration
# Focused five-class run:
env CFFIXED_USER_HOME="$B/round6-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests|GitHTTPRedirectTests|GitRepositorySecurityTests|GitBlameTests|FolderBrowserTests'
# All six mutations, restored after each invocation:
python3 "$B/round6-mutations.py"
```

### Final round-6 validation and latency

Full bello-views package: **380 executed, 376 passed, 4 skipped, 0 failures** (`round6-final-views-full.log`). The skips are the existing opt-in scale/benchmark cases; the benchmark is explicitly executed below. The full run follows all mutation restorations, and all five changed source/test hashes match `round6-tested-source-hashes.json`.

The focused run passed **91/91** before mutation checks: FolderBrowserTests 19, GitBlameTests 13, GitInventoryTests 42, GitHTTPRedirectTests 5, GitRepositorySecurityTests 12 (`round6-focused-fixed.log`). The complete package run above repeats every affected class after restoring all mutations.

```sh
env CFFIXED_USER_HOME="$B/round6-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
```

The full package run, performance runs and native/gallery runs each hold the shared full-lane lock. The package run waited for the Git/files, panel and workspace workstreams to release it; no other workstream's lock or build products were changed.

The freshly fetched baseline is pinned `origin/dev/next` **649ea623291c9417443d61d3bb55314d8a2f5d9a**. Its package is exported with `git archive`, without checking out or integrating that branch. The same generated fixture contains **50,001 ordinary tracked entries plus 20 initialized submodules**; there is one changed tracked file. Each variant takes **25 warmed samples** of status and a complete Changes refresh including selected diff and hunk review.

| Variant | Status median / p95 (ms) | Changes including hunk review median / p95 (ms) | Median versus baseline |
| --- | ---: | ---: | --- |
| baseline | 251.09 / 266.63 | 2173.09 / 2199.57 | baseline |
| branch | 173.05 / 186.08 | 2040.34 / 2071.70 | status -31.08%; Changes -6.11% |
| branch-repeat | 172.16 / 183.24 | 2023.54 / 2071.11 | status -31.43%; Changes -6.88% |

Both branch runs meet the 5% budget. All three benchmark executions pass (1/1 each). Text logs: `round6-final-verified-perf-{branch,baseline,branch-repeat}.log`; source-proof records: `round6-final-verified-build-{branch,baseline,branch-repeat}.json`. Before each build, only this workstream's `views-tests` products are removed. Each run verifies the compile-time variant marker, actual compiled source paths, and GitService bytes/hash; the baseline GitService must exactly match its pinned commit. The branch also verifies its GitProcessSafety source paths and GitConfiguration hash. The baseline receives the identical benchmark source and only a test-target `BELLO_GIT_BENCHMARK_BASELINE` define.

Exact measurement command, executed for branch, baseline, then branch again after the per-variant clean:

```sh
env CFFIXED_USER_HOME="$B/round6-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  BELLO_GIT_INVENTORY_BENCHMARK="$B/round6-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
  swift test --package-path "$PACKAGE" --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
```

`PACKAGE` is this worktree's `packages/bello-views`, then `$B/round6-baseline/packages/bello-views`, then the worktree package again. `$B/round6-final-performance.py` records the exact export/build-proof sequence.

Native: **41 classes, 375 executed, 373 passed, 2 skipped, 0 failures**. The skips remain the opt-in commit-browsing and diff-capture cases. Every invocation uses `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1 PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO`, with `-only-testing:PiAppTests/<Class>` for each selected class. The host uses the generated `PiAppTests-Home`; the extra variables keep direct test Git subprocesses off the real global/system config too. The class batches and serial-alone selections are identical to the explicit round-4 list above; fresh round-6 evidence follows.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round6-final-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round6-final-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `round6-final-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round6-final-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `round6-final-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round6-final-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round6-final-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round6-final-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `round6-final-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round6-final-native-file-git.log` |
| FileTabTests | 16 | 0 | `round6-final-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round6-final-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `round6-final-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round6-final-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round6-final-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `round6-final-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round6-final-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `round6-final-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round6-final-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round6-final-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `round6-final-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round6-final-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round6-final-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `round6-final-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round6-final-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round6-final-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `round6-final-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `round6-final-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round6-final-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `round6-final-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round6-final-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round6-final-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round6-final-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `round6-final-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `round6-final-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round6-final-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round6-final-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `round6-final-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round6-final-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round6-final-native-boundaries.log` |
| WorkspaceTests | 17 | 0 | `round6-final-native-boundaries.log` |

Gallery regenerated **112 PNGs**, using:

```sh
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/round6-final-gallery" PI_BUILD_ROOT="$B" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1 \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Visually inspected eight fresh images: `http-redirect-{light,dark}-{920x600,310x600}.png` and `untrusted-{light,dark}-{700x640,310x600}.png`. The redirect refusal and trust notice remain visible in both themes, with the existing ellipsis when space is limited. File rows and commit controls remain available. The gallery also asserts the full redirect notice, including `http.extraHeader`. Image hashes are recorded in `round6-final-gallery-inspection.json`.

Extended lock contention delayed the native runs. Only idle lock waiters were restarted; no active test was interrupted. The orchestration traces in `round6-package-performance-native-batches.log` and `round6-idle-lock-waiter.log` are those intentional waiter exits; the per-suite logs above contain the actual test results.

Final adversarial review and source-hash checks confirm the committed implementation is the restored, tested code. The generated fixture's index was independently counted before cleanup: **50,001 ordinary entries and 20 submodules** (`round6-fixture-counts.json`). The generated baseline export, large fixture and default XCTest result bundle were removed; no Clone directories remained (`round6-cleanup.json`). Text logs, source-proof records and gallery images remain under this workstream's build root. Every lock owned by this workstream was released; other workstreams' locks and build products were left untouched.

Round 6 resolves all three review findings plus the adjacent submodule-alias instance: four failing-first regressions, six killed mutations, full package/native/gallery validation and three source-verified latency measurements within budget. No unresolved security finding or owner-policy question remains. No helper/wire behavior changed, and no merge or fast-forward to `dev/next` was performed.

## Round 7 — generated override encoding and upstream integration

The P1 against `b8fd59e5470beac6506dbc19d0b0942374a38716` is confirmed. The old shared encoder emitted value escapes inside subsection names. Git's subsection grammar removes the backslash from `\n`, `\t` and `\b` instead of interpreting the corresponding control character, so the generated condition did not match the repository. Newline, tab and backspace path fixtures each executed their local fsmonitor marker on both consecutive reads. [Git config syntax](https://git-scm.com/docs/git-config/2.39.0#_syntax), [Git's subsection parser](https://github.com/git/git/blob/v2.39.5/config.c#L864-L898).

### Fix and nearby sweep

`GitReadOverrides` now has separate subsection and value encoders. Both conservatively accept printable text only, escaping quotes and backslashes without producing any other escape sequence. Control characters, including NUL, refuse override construction. Glob metacharacters in the actual Git-reported gitdir are escaped before subsection encoding. Tests ask Git to parse both scratch files, compare every key/value byte and duplicate credential-helper entry, and verify the conditional include's effective values and origins.

`GitReadProcess` constructs the overrides inside the confinement decision. A representation failure therefore selects the same sandbox as an untrusted read. It cannot leave an unconfined launch prepared or turn that fallback into an uncaught override error. Invalid UTF-8 config/metadata, unrepresentable override separators and arguments Foundation would rewrite use this same fallback. Trusted global/system programs with representable settings retain their existing behavior; unsafe restored values select confinement as required by the new owner rule. Network Git inventory failures still prevent the network command from launching.

The sweep covers all generated Git config in the app/shared views: the conditional file, its included program-value file, the condition's glob escaping, multi-valued credential helpers, local/worktree scope restoration, metadata decoding and the final include argument. The two encoders are the only production writer for these files. Background commands still use the non-recursive read policy, and the existing dynamic-include and cache checks remain in place.

### Failing-first evidence

All programs are generated marker writers and all config is fixture-owned. The final comparison restores all three round-6 production files before running the exact final regression selection, then restores the fix in `finally`.

| Regression | Round-6 result |
| --- | --- |
| Newline, tab, backspace, CR and DEL repository paths, two reads each | 16 failed assertions; newline/tab/backspace executed the marker |
| Control characters in restored global values | 8 failed assertions |
| Unsafe generated subsection/value text, including NUL | 12 failed assertions |
| Invalid UTF-8 local key and include-path bytes | 2 failed assertions |
| Existing invalid-key/separator/Unicode cases updated to require confinement | 5 failed assertions |
| Quote/backslash/glob paths and Git parser round-trips | Both positive-control tests passed |

**9 tests, 43 failed assertions, 0 unexpected failures** against round 6 (`round7-failing-first-clean.log`); **9/9 passed** with the fix (`round7-fixed-focused.log`). These are seven failing regressions and two passing controls. Earlier development runs are retained separately; their parser assertion incorrectly used Foundation's `/var/...` spelling instead of Git's `/private/var/...` gitdir. The corrected test obtains the directory from `git rev-parse --absolute-git-dir`, as production does. Those development counts are excluded above.

This Mac's APFS refuses an attempted raw non-UTF-8 repository filename (`repository-ff`, suffix byte `ff`) with **errno 92 / EILSEQ**, before a repository can be created. `round7-invalid-filename.json` records the generated-path attempt. No successful raw-byte filename fixture is claimed. Invalid UTF-8 bytes in a local program subsection and an included pathname are tested through the real inventory instead; both select confinement and leave the local fsmonitor marker absent. NUL rejection is tested directly at the generated-override boundary.

### Mutation checks

| Mutation | Selected tests | Failed assertions |
| --- | ---: | ---: |
| Restore the old shared encoder | 3 | 36 |
| Allow control characters in generated values | 2 | 14 |
| Construct overrides outside the confinement fallback | 2 | 14 |
| Omit subsection backslash escaping | 2 | 6 |
| Reject invalid UTF-8 instead of selecting confinement | 1 | 2 |

**5 mutations killed, 72 failed assertions, 0 unexpected failures.** The script restores production bytes after each mutation and again in its outer `finally`. Evidence: `round7-mutation-{old-shared-encoder,allow-control-values,override-outside-fallback,unescaped-subsection-backslash,reject-instead-of-confine-utf8}.log` and `round7-mutations.json`.

Exact regression/mutation commands, with `$B` still the workstream build root:

The initial scripts ran with `HEAD=b8fd59e5470beac6506dbc19d0b0942374a38716`; that is their original-code baseline, not the later merge commit. The additional scalar mutation script pins `afffdcfe71bbcc30fc977caa278c277eab3f40a8` explicitly.

```sh
python3 "$B/round7-original-and-fixed.py"
# The script runs original and restored production with:
env CFFIXED_USER_HOME="$B/round7-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests.test(ControlCharacters|QuotedGitdir|GeneratedOverrides|UnsafeGenerated|InvalidConfigBytes)|GitRepositorySecurityTests.test(InvalidUTF8|EqualsCannot|CanonicallyEquivalent)'
python3 "$B/round7-mutations.py"
```

After restoring all mutations, the affected package classes passed **98/98**: `GitInventoryTests` 49, `GitRepositorySecurityTests` 12, `GitHTTPRedirectTests` 5, `GitBlameTests` 13 and `FolderBrowserTests` 19 (`round7-focused-restored.log`). Exact command:

```sh
env CFFIXED_USER_HOME="$B/round7-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests|GitRepositorySecurityTests|GitHTTPRedirectTests|GitBlameTests|FolderBrowserTests'
```

Adversarial review checked both encoder grammars, literal backslashes/quotes and glob characters, duplicate settings, partial-file cleanup on encoding failure, strict UTF-8 decoding, the fallback's placement, retained override lifetimes and the network/read distinction. A throwing override never assigns the unconfined options, and the process's executable is selected only after that decision. No new process, permission or production test bypass was introduced. Normal cached reads add no config subprocess. The additional scalar-level review below found and fixed two adjacent instances before final validation.

### Merge and validation scope

Committed the round-7 fix as `afffdcfe71bbcc30fc977caa278c277eab3f40a8`, then fetched and merged `origin/dev/next` at `649ea623291c9417443d61d3bb55314d8a2f5d9a` with `git -c commit.gpgsign=false merge --no-ff --no-commit origin/dev/next`, as explicitly requested for this round. No rebase, fast-forward or published-history rewrite was used. The only conflict was the adjacent additions under `## 0.1.130` in `NEXT-RELEASE.md`; both sets of entries were retained. Upstream's completed cost-pause entry supersedes its old unresolved entry. `WorkspaceModel` retains upstream's sidebar/resource/producer changes together with this branch's trust resolution and configuration invalidation.

Ran `xcodegen generate --quiet` after integration. The five fixed implementation/test file hashes still match the restored pre-merge test run. `round7-merged-tested-sources.json` records 1,399 implementation, test, fixture, script and project input hashes before the merged validation. The final review compares these hashes again; validation-only prose changes do not alter the tested inputs.

Merged validation uses this workstream's existing `views-tests`, `swift-tests`, `swift-host` and `native-tests` build roots. The full package, three large-repository measurements, helper build/tests and loopback wire suites ran sequentially under the shared full-lane lock. The native portion was stopped after its active command completed when the scalar-level review found the adjacent cases below; no active test was interrupted, and the lock was released in `finally`. The affected package, native and latency checks are rerun on the final code. Because integration imports upstream helper changes, the helper and wire suites are included even though the round-7 security fix itself only changes shared views. Test configuration excludes the user's global/system Git settings, and the native test scheme and wire harness use isolated fixture homes. No installed app, real preferences/chats, Keychain, live capture or provider request is used.

### Initial merged latency measurement (before the scalar sweep)

The generated index contains **50,001 ordinary entries (50,000 files plus `.gitmodules`) and 20 gitlinks**, independently counted in `round7-fixture-counts.json`. Each variant uses 25 warm status samples and 25 Changes refresh samples, including selected-file hunk review. Baseline is the fetched merge parent `649ea623291c9417443d61d3bb55314d8a2f5d9a`. The same benchmark source is copied into its package export; its compile-time baseline define selects the original service interface.

`views-tests` is deleted between variants to prevent SwiftPM from reusing a build plan from the other source directory. Each result checks the test's compile-time source marker and the compiled `GitService.swift` source path; the baseline implementation bytes are compared to the pinned Git commit. The branch builds also verify their compiled GitProcessSafety source. Evidence: `round7-merged-build-{branch,baseline,branch-repeat}.json`, `round7-merged-perf-*.log`, `round7-merged-performance.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 256.27 / 266.88 | 2180.03 / 3366.36 | — |
| branch | 166.09 / 177.74 | 2053.03 / 2886.88 | -35.19% / -5.83% |
| branch-repeat | 172.19 / 184.14 | 2075.03 / 2705.80 | -32.81% / -4.82% |

Both source-verified branch measurements meet the approximately 5% latency budget. The baseline and both branch samples run consecutively under this workstream's full-lane lock.

Exact per-variant command (`$PACKAGE` is the branch's `packages/bello-views`, the exported `$B/round7-baseline/packages/bello-views`, then the branch again):

```sh
env CFFIXED_USER_HOME="$B/round7-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  BELLO_GIT_INVENTORY_BENCHMARK="$B/round7-large-fixture" BELLO_GIT_BENCHMARK_SAMPLES=25 \
  swift test --package-path "$PACKAGE" --scratch-path "$B/views-tests" --filter GitInventoryPerformanceTests
```

### Adversarial scalar sweep — two adjacent encoding instances

While the merged validation ran, a scalar-level review found two additional instances in the same override writer:

- `GitInventoryCache.swift`, gitdir pattern construction: Swift `Character` iteration groups a combining mark with the preceding bracket/backslash. Testing that combined character against the ASCII glob-punctuation string misses the punctuation. A generated `checkout[\u{0301}x]fixture` repository and a backslash-plus-combining-mark repository both executed their local fsmonitor markers because the resulting condition failed to match.
- `GitInventoryCache.swift`, both subsection and value encoders: Foundation's default `replacingOccurrences` also skips quote/backslash punctuation followed by a combining mark. Git therefore reads different bytes or refuses the generated config. This violates the owner's exact-round-trip rule even though each scalar is individually representable.

All three escaping loops now inspect Unicode scalars, escaping the exact ASCII punctuation while retaining the following combining scalars unchanged. The separate subsection/value encoders and their control-character confinement checks remain. This is a minimal correction inside the same writer; it adds no subprocess or cache lookup.

`testCombiningMarksInGitdirKeepLocalProgramsDisabled` covers bracket, backslash, quote, asterisk, question-mark and closing-bracket clusters, using two real status reads for each generated marker fixture. `testCombiningMarksInOverridesRoundTripThroughGitParsing` asks Git to parse scratch subsections/values and their effective conditional origins for quote/backslash clusters.

The two new tests fail against the initial round-7 fix (`afffdcfe`): **20 failed assertions, 0 unexpected failures** (`round7-combining-failing-first.log`), including four marker assertions on bracket/backslash paths. The other failures expose malformed or changed config bytes. After the scalar fix, the **8 encoding tests pass** (`round7-combining-fixed.log`). The independent generated Git probe is retained in `round7-combining-probe.json`.

| Additional mutation | Selected tests | Failed assertions |
| --- | ---: | ---: |
| Restore Character-based glob escaping | 2 | 4 |
| Restore Foundation replacement in the subsection encoder | 2 | 10 |
| Restore Foundation replacement in the value encoder | 2 | 8 |

**3 additional mutations killed, 22 failed assertions, 0 unexpected failures**. `round7-combining-mutations.py` restores the source after each mutation and in its outer `finally`; **8/8 pass after restoration** (`round7-combining-restored.log`). Together with the earlier checks, round 7 kills eight mutations. Commands:

```sh
env CFFIXED_USER_HOME="$B/round7-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests.testCombiningMarks'
python3 "$B/round7-combining-mutations.py"
# Fixed/restored selection:
env CFFIXED_USER_HOME="$B/round7-views-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  swift test --package-path packages/bello-views --scratch-path "$B/views-tests" \
  --filter 'GitInventoryTests.test(CombiningMarks|ControlCharacters|QuotedGitdir|GeneratedOverrides|UnsafeGenerated|InvalidConfigBytes)'
```

The first merged run's full package, latency, helper, wire and completed native results remain recorded as intermediate evidence. Its driver was deliberately paused while the active FileFindTabTests command finished successfully, then stopped before another command began; `round7-driver-stop.json` and the normal `TEST SUCCEEDED` text in `round7-merged-native-FileFindTabTests.log` distinguish that orchestration stop from a test failure. The full helper and wire evidence remains final because only the override writer and its package tests changed afterward. `round7-final-tested-sources.json` freezes the final 1,399 inputs; only those two files differ from the earlier input record.

### Final scalar-fix latency measurement

The same 50,001-entry/20-submodule fixture, 25 samples per operation, clean builds and pinned baseline were used again after the scalar fix, under the full-lane lock. Compiled-source proof is in `round7-final-build-*.json`; measurements are in `round7-final-performance.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 254.36 / 262.49 | 2189.28 / 2217.35 | — |
| branch | 174.81 / 183.74 | 2060.54 / 2094.60 | -31.27% / -5.88% |
| branch-repeat | 173.80 / 185.33 | 2071.37 / 2811.38 | -31.67% / -5.39% |

Both final branch runs meet the approximately 5% median budget. The per-variant command is the same as the earlier latency block; all three final logs carry the `round7-final-perf-` prefix. Changes p95 varied from 2,094.60 ms on the first branch run to 2,811.38 ms on the repeat, versus 2,217.35 ms baseline. The budget verdict uses median latency; the table and raw samples retain that tail variability.

### Final merged validation

Every command below uses `$B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. The complete sequential invocation record (including arguments, extra environment, elapsed time and exit status) is `round7-final-validation.json`; unchanged helper/wire commands are in `round7-merged-validation.json`. The final lock acquisition/release and phase order are in `round7-final-orchestration.log`. All suite commands exited zero. Counts distinguish passed tests from opt-in skips.

| Suite | Passed | Skipped | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| bello-views full | 384 | 4 | 0 | `round7-final-views.log` |
| Helper StreamingCostTests, alone | 5 | 0 | 0 | `round7-merged-helper-cost.log` |
| Helper, excluding the separate cost class | 1139 | 7 | 0 | `round7-merged-helper.log` |
| wire against Release helper | 40 | 0 | 0 | `round7-merged-wire.log` |
| concurrent against Release helper | 4 | 0 | 0 | `round7-merged-concurrent.log` |
| acceptance against Release helper | 3 | 0 | 0 | `round7-merged-acceptance.log` |
| Native, 41 classes including safety gallery | 373 | 2 | 0 | `round7-final-native-*.log` |
| Source-verified latency variants | 3 | 0 | 0 | `round7-final-perf-*.log` |

The four package skips are the three opt-in FileFinder measurements and the separately executed inventory benchmark. The seven helper skips are opt-in fixture export/large-history measurements. The native skips are the existing opt-in large-history and diff-capture measurements, not security regressions. The helper's buffered progress log paused during the 2,640-scenario side-budget deletion/crash matrix; a read-only sample confirmed active fixture work, and the suite completed normally without interruption (`round7-helper-progress-sample.txt`). Release/staged-helper hashes are recorded in `round7-merged-release-helper.json`.

Exact package/helper/wire commands:

```sh
export PI_BUILD_ROOT="$B" CFFIXED_USER_HOME="$B/round7-views-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1
swift test --package-path packages/bello-views --scratch-path "$B/views-tests"
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path "$B/swift-tests" --build-tests
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build --skip StreamingCostTests
HOST="$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$HOST"
python3 scripts/test-concurrent-native-host.py "$HOST"
python3 scripts/test-native-acceptance.py "$HOST"
```

Native runs use `scripts/test-macos.sh -parallel-testing-enabled NO` and one `-only-testing:PiAppTests/<Class>` argument for each selected class. The four boundary classes share one focused run. The 24 file/Git classes run with `-parallel-testing-enabled YES -parallel-testing-worker-count 4`, after checking that none belongs to the repository’s serial lane. Every serial class is invoked alone. The default, automatically named result bundle supplies supplementary summary/test JSON for accurate parallel-run counts; no named result bundle is created or retained. Exact batch membership and commands are also in the invocation JSON.

| Native class | Passed | Skipped | Log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round7-final-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round7-final-native-file-git.log` |
| CrashAuditRegressionTests | 12 | 0 | `round7-final-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round7-final-native-file-git.log` |
| FileFindTabTests | 16 | 0 | `round7-final-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round7-final-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round7-final-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round7-final-native-file-git.log` |
| FilePreviewRefreshTests | 2 | 0 | `round7-final-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round7-final-native-file-git.log` |
| FileTabTests | 16 | 0 | `round7-final-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round7-final-native-file-git.log` |
| GitChangelistReadTests | 2 | 0 | `round7-final-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round7-final-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round7-final-native-file-git.log` |
| GitDiffTableTests | 19 | 0 | `round7-final-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round7-final-native-file-git.log` |
| GitHistoryFilterTests | 14 | 0 | `round7-final-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round7-final-native-file-git.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round7-final-native-file-git.log` |
| GitOperationSafetyTests | 12 | 0 | `round7-final-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round7-final-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round7-final-native-file-git.log` |
| GitPanelLayoutTests | 4 | 0 | `round7-final-native-file-git.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round7-final-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round7-final-native-file-git.log` |
| GitPanelShownTests | 13 | 0 | `round7-final-native-file-git.log` |
| GitPanelTimingTests | 4 | 0 | `round7-final-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round7-final-native-file-git.log` |
| GitPathBoundaryTests | 5 | 0 | `round7-final-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round7-final-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round7-final-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round7-final-native-GitRepositorySwitchTests.log` |
| GitSafetyGalleryTests | 1 | 0 | `round7-final-native-GitSafetyGalleryTests.log` |
| GitToolTests | 5 | 0 | `round7-final-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round7-final-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round7-final-native-file-git.log` |
| QuickOpenTests | 17 | 0 | `round7-final-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round7-final-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round7-final-native-boundaries.log` |
| WorkspaceTests | 17 | 0 | `round7-final-native-boundaries.log` |

The gallery command is:

```sh
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY="$B/round7-final-gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Regenerated **112 PNGs** and visually inspected eight fresh redirect/trust-notice images: `http-redirect-{light,dark}-{920x600,310x600}.png` and `untrusted-{light,dark}-{700x640,310x600}.png`. Both notices remain visible in normal and narrow layouts in both themes, with the existing ellipsis in limited space. File rows and commit controls remain usable. The gallery asserts the complete redirect notice including `http.extraHeader`; image hashes and dimensions are in `round7-final-gallery-inspection.json`.

The final adversarial review rechecked the merged trust resolver, all generated condition/subsection/value sites, strict byte decoding, quote/backslash/glob parsing, duplicate credential-helper values, failed-policy cleanup and lifetime, and confinement before executable selection. The full merged run retains all prior cache/redirect/submodule/cancellation regressions. The project was regenerated, both merge sides were preserved, and all 1,399 recorded implementation/test/fixture/script/project inputs remained unchanged through validation (`round7-final-source-verification.json`). No new finding emerged.

All eight round-7 mutations were killed, and the final scalar-based fix passed the complete merged package and native validation. No unresolved security finding or owner-policy decision remains. The sole fixture limitation is APFS refusing a raw non-UTF-8 filename with EILSEQ; invalid config/include bytes and confinement are tested as documented above. The lead's full merged release gate remains separate.

Removed the generated large repository, exported baseline package and final default XCTest result bundle after recording their evidence. No Clone directories remained. Text logs, JSON records and the 112 gallery PNGs remain under this workstream’s build root (`round7-cleanup.json`). The final validation driver released its own full-lane lock; other workstreams’ locks and build products were untouched. Final log scans found no failed or retried-failed test cases, and `git diff --check HEAD` passed.

## Round 8: stored modules and exact path terminators — 2026-10-20

Both findings are confirmed against `82597596486dbdac7357a1259f354bc509d8bc03`. Generated repositories use fixture-only global config and programs that create a marker file. No live remote, user config, credentials or installed app is involved.

The configuration inventory walks every common directory's `modules/`, including grouping directories, deinitialized repositories and nested modules. Stored repositories are queried with explicit Git directory/worktree metadata context, without scanning a nonexistent checkout's index. Git still evaluates scopes, origins and conditional includes. Populated repositories already inventoried are deduplicated. Directory stamps are captured **before** enumeration, include their resolution chains and join child config/include stamps in the parent cache; adding a module or editing its config invalidates the policy. Enumeration errors, malformed repositories and dynamic/non-regular config fail closed, before network launch. Reads retain their existing confinement fallback; cancellation/deadline checks apply during traversal and every query. No override is restored from a parent's global values into its child.

The redirect policy remains the round-6 conservative superset: any extraHeader key in the parent or any populated/stored descendant requires `false` for both generic and all inventoried URL-scoped redirect settings. Missing checkouts never remove this protection. Unverifiable config refuses the network command. Read-only commands remain nonrecursive and retain both `GIT_NO_LAZY_FETCH=1` and empty `GIT_ALLOW_PROTOCOL`, including partial-clone/sparse-index queries; inventory itself remains confined.

| Fixed instance | Regression |
| --- | --- |
| Deinitialized stored module's private-header policy | `GitInventoryTests.testDeinitializedSubmoduleKeepsRedirectRefusal`: real `submodule add/deinit`, grouped module name, own false and URL-scoped true; Git reads back strict effective URL policy. |
| Nested stored module with no checkout | `testNestedStoredSubmoduleKeepsRedirectRefusal`: nested `modules/` config; same parent and inherited policy assertions and absent program marker. |
| Stored module creation/config edit after cache warmup | `testNewStoredModuleInvalidatesWarmInventory` plus both deinitialized tests; watch absent module roots and included child stamps. |
| Reachable config cannot be proved static | `testUninspectableStoredConfigCannotRelaxRedirects`: direct and inactive conditional stdin includes both refuse policy construction/launch. |
| Trusted repository name ends in CR | `testTrustedRepositoryPathEndingInCarriageReturn`: repositoryRoot and status still work, local program marker absent. |
| FileFinder Git root and excludes-file outputs | `FileListingTests.testGitPathsKeepTrailingCarriageReturn`: strip only the LF terminator; retain the actual CR. |
| Stash common-dir and hunk index outputs | `testStashCommonDirectoryKeepsTrailingCarriageReturn`, `testPatchIndexKeepsTrailingCarriageReturn`: stash contents and hunk review remain readable. |

The package sweep also changed xcrun/xcode-select path termination and the inventory's symbolic-HEAD output to byte-level LF removal. Existing `GitService.Output.path` already did this correctly. Remaining whitespace trimming is for non-path hashes, refs (Git forbids control bytes), messages, diagnostics, counts or user input. No UI layout changed.

Fixture corrections before final evidence: `/var` vs `/private/var` is compared using Git's own returned spelling; a literal CR in the ignore path is quoted in the generated config because Git's config setter strips a terminal CR; an explicitly supplied GIT_DIR tests CR in a common-dir path because Git's gitfile parser itself strips CRLF. The first dynamic-source mutation survived because its direct include failed earlier; the final fixture adds an inactive conditional source and kills the actual redirect-guard mutation. These preliminary fixture runs are retained and are not counted as final validation.

Adversarial review also reproduced an indeterminate stored-module context when root config is supplied through a relative HOME/XDG_CONFIG_HOME/GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM path. The metadata-only context cannot prove how a later child command resolves that cwd-dependent root. Such contexts now fail closed; absolute fixture/user roots retain the normal policy. `testStoredModuleRelativeConfigRootsFailClosed` failed before this guard and after removing it, and passes restored.

Final pre-merge regression evidence: the eight finalized tests against round 7 failed **20 assertions, 0 unexpected** (`round8-failing-first-final-fixtures.log`). All eight pass with the fix (`round8-restored-focused.log`). Seven independent mutations were killed: skip stored inventory (2 tests/9 assertions), omit discovery stamps (1/2), omit static-config guard (1/1), retain the LF after CR (1/2), trim FileFinder paths (1/2), trim stash common-dir (1/1), trim hunk index (1/1). The additional relative-root guard mutation fails 1/1. Total **8 mutations killed**, with exact commands and counts in `round8-mutations.json` and `round8-relative-config-{before,fixed,mutation,restored}.log`. Text evidence is under the workstream build root's `logs/`.

### Requested upstream integration

Fetched `origin/dev/next` twice; the merged revision is `688f8751a936cf8982c26b2e5a4dcb4b046578aa`. The merge has parents `64b5bec5` (round-8 fix) and that upstream revision; no rebase or history rewrite. The only conflict is NEXT-RELEASE, resolved by retaining both sides' entries. The generated project auto-merged and is regenerated before validation. At this published upstream revision, `FileFolderTests.swift` contains neither `installStandaloneFileResolver` nor `testFixtureOwnsInheritedHooks`; therefore there was no conflict in that file and no such upstream content to retain. The existing fsmonitor marker test is preserved. This is a discrepancy from the expected conflict, not an omitted resolution.

The round-8 “never weaker” rule also applies when a child has an explicit redirect refusal without headers. `testStoredModuleDoesNotWeakenHeaderFreeRedirectPolicy` failed four assertions with the generated initial override, then passed after preserving existing settings. Removing the guard reproduces all four failures (`round8-header-free-{before,fixed,mutation,restored}.log`). With no headers and no configured redirect key anywhere, the generated value remains `initial`; if any repository has an existing redirect setting, no override is emitted and Git keeps each repository's own policy. This applies the new rule without parsing boolean values or emulating Git's precedence. Header presence still forces false everywhere. Total round-8 mutations: **9 killed**.

The fetched upstream's focus-aware lane classifier moves additional file/Git classes into the serial lane. Validation reads that classification and runs every such class alone; remaining classes share the focused parallel batch. Waiting drivers were stopped before acquiring the shared lock to adapt scheduling and finish the header-free regression; no test run was interrupted.

### Adversarial metadata-environment check

The first complete merged sequence passed (views 394/4 skips; native 373/2; helper 1,144/7; wire 40; concurrent 4; acceptance 3; all zero failures). Its benchmark medians were 174.04/176.31 ms status and 2,078.84/2,066.73 ms Changes versus 254.44/2,175.17 ms baseline. Those package/native/latency results are superseded below after a further check of the new stored-repository context.

A direct Foundation Process probe showed composed UTF-8 in GIT_DIR is decomposed in envp (`round8-env-probe.log`). A generated stored module with a Git-active conditional include confirmed the impact: raw Git sees its fixture header, while the metadata context omitted it and allowed an unconfined read. `testStoredModuleEnvironmentCannotRewriteGitdirConditions` failed **2 assertions, 0 unexpected** before the guard (`round8-module-env-before.log`). Stored-directory values now pass the existing byte-round-trip check before deduplication or envp construction; failure selects confinement for reads and prevents network launch. Deduplication compares UTF-8 bytes rather than Swift canonical-equivalence equality. The test passes fixed; removing the check reproduces both failures, and restoration passes (`round8-module-env-{fixed,mutation,restored}.log`). Total round-8 mutations: **10 killed**.

The full views package, all selected native classes and all benchmark variants are rerun after this final guard. The fresh round-8 helper and wire results remain applicable: only GitConfiguration.swift and GitInventoryTests.swift changed after their run, and all helper/wire sources, fixtures, scripts and project files match the recorded hashes. No test was interrupted; the first driver completed and released its lock before the final production edit.

The same adversarial check confirmed that resolving a stored symlink before deduplication can also discard Git-active conditional headers. `testStoredModuleAliasKeepsItsOwnConditionalHeaders` proves that raw Git reads a fixture header through the stored alias while the populated spelling has none. The old resolved-path deduplication failed **2 assertions**; comparing the actual absolute Git-directory spelling byte-for-byte passes. Restoring resolved-path deduplication reproduces both failures (`round8-module-alias-{before,fixed,mutation,restored}.log`). No new override is broadcast between the two contexts. Total round-8 mutations: **11 killed**. The verification driver had not acquired the lock or started a test when this final deduplication correction was made.

### Final merged validation

All runs below are fresh round-8 runs on the merged sources. Both validation sequences held the shared lock, including the large-repository benchmarks and native focus classes, and each driver released it in `finally`. No named xcresult bundle was requested; text logs and supplementary JSON are the evidence. No UI layout was changed by this security round, so the existing gallery was not regenerated. The lead's full merged release gate remains separate.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| bello-views (full) | 396 | 4 | 0 |
| Helper streaming cost (alone) | 5 | 0 | 0 |
| Helper (excluding streaming cost) | 1139 | 7 | 0 |
| Wire | 40 | 0 | 0 |
| Concurrent host | 4 | 0 | 0 |
| Acceptance | 3 | 0 | 0 |
| Native file/Git/security (40 classes) | 373 | 2 | 0 |
| Benchmark variants | 3 | 0 | 0 |

Package skips are the three opt-in FileFinder performance cases and the inventory benchmark run separately below. Helper skips are its seven opt-in performance/fixture-export checks. Native skips are the existing opt-in large history/diff capture cases. The helper and wire suites were rerun as requested despite no round-8 helper changes. Full counts are in `round8-verified-suite-counts.json`; exact invocations, environment overrides and elapsed times are in `round8-verified-validation.json` and, for unchanged helper/wire inputs, `round8-final-validation.json`.

Commands used the following common environment (all paths belong to this workstream):

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
export PI_BUILD_ROOT="$B" CFFIXED_USER_HOME="$B/round8-views-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1
```

Exact test/build commands (extra per-invocation environment precedes each command):

```sh
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round8-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round8-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round8-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round8-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/FilePageReadTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitConfirmationSheetTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiscardQuestionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelDiffCaptureTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelLayoutTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelRedrawTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelShownTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelWidthTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenPlacementTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
```

| Native class | Passed | Skipped | Log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `round8-verified-native-ChangesTabFrameTests.log` |
| ChangesTabTests | 8 | 0 | `round8-verified-native-ChangesTabTests.log` |
| CrashAuditRegressionTests | 12 | 0 | `round8-verified-native-CrashAuditRegressionTests.log` |
| FileBlameTests | 10 | 0 | `round8-verified-native-FileBlameTests.log` |
| FileFindTabTests | 16 | 0 | `round8-verified-native-FileFindTabTests.log` |
| FileFolderTests | 20 | 0 | `round8-verified-native-FileFolderTests.log` |
| FileHiddenReadTests | 5 | 0 | `round8-verified-native-file-git.log` |
| FilePageReadTests | 3 | 0 | `round8-verified-native-file-git.log` |
| FilePreviewRefreshTests | 3 | 0 | `round8-verified-native-FilePreviewRefreshTests.log` |
| FileReviewStateTests | 20 | 0 | `round8-verified-native-FileReviewStateTests.log` |
| FileTabTests | 16 | 0 | `round8-verified-native-file-git.log` |
| GitBranchesInteractionTests | 20 | 0 | `round8-verified-native-GitBranchesInteractionTests.log` |
| GitChangelistReadTests | 2 | 0 | `round8-verified-native-file-git.log` |
| GitCommitBrowsingTests | 3 | 1 | `round8-verified-native-file-git.log` |
| GitConfirmationSheetTests | 7 | 0 | `round8-verified-native-GitConfirmationSheetTests.log` |
| GitDiffTableTests | 19 | 0 | `round8-verified-native-GitDiffTableTests.log` |
| GitDiscardQuestionTests | 2 | 0 | `round8-verified-native-GitDiscardQuestionTests.log` |
| GitHistoryFilterTests | 14 | 0 | `round8-verified-native-file-git.log` |
| GitHunkReviewTests | 9 | 0 | `round8-verified-native-GitHunkReviewTests.log` |
| GitIntegratedHistoryTests | 10 | 0 | `round8-verified-native-GitIntegratedHistoryTests.log` |
| GitOperationSafetyTests | 12 | 0 | `round8-verified-native-GitOperationSafetyTests.log` |
| GitPanelAuditTests | 8 | 0 | `round8-verified-native-file-git.log` |
| GitPanelDiffCaptureTests | 0 | 1 | `round8-verified-native-GitPanelDiffCaptureTests.log` |
| GitPanelLayoutTests | 4 | 0 | `round8-verified-native-GitPanelLayoutTests.log` |
| GitPanelNarrowParityTests | 8 | 0 | `round8-verified-native-GitPanelNarrowParityTests.log` |
| GitPanelRedrawTests | 4 | 0 | `round8-verified-native-GitPanelRedrawTests.log` |
| GitPanelShownTests | 13 | 0 | `round8-verified-native-GitPanelShownTests.log` |
| GitPanelTimingTests | 4 | 0 | `round8-verified-native-GitPanelTimingTests.log` |
| GitPanelWidthTests | 3 | 0 | `round8-verified-native-GitPanelWidthTests.log` |
| GitPathBoundaryTests | 5 | 0 | `round8-verified-native-file-git.log` |
| GitRenameTests | 6 | 0 | `round8-verified-native-file-git.log` |
| GitRepositoryPermissionTests | 4 | 0 | `round8-verified-native-boundaries.log` |
| GitRepositorySwitchTests | 17 | 0 | `round8-verified-native-GitRepositorySwitchTests.log` |
| GitToolTests | 5 | 0 | `round8-verified-native-file-git.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `round8-verified-native-GitWorkingTreeWatcherTests.log` |
| QuickOpenPlacementTests | 1 | 0 | `round8-verified-native-QuickOpenPlacementTests.log` |
| QuickOpenTests | 17 | 0 | `round8-verified-native-QuickOpenTests.log` |
| WebhookExchangeTests | 5 | 0 | `round8-verified-native-boundaries.log` |
| WebhookTests | 18 | 0 | `round8-verified-native-WebhookTests.log` |
| WorkspaceTests | 17 | 0 | `round8-verified-native-boundaries.log` |

### Latency after stored-module inventory

Pinned baseline `688f8751a936cf8982c26b2e5a4dcb4b046578aa` (`origin/dev/next` at merge), the same generated 50,000-file/20-submodule fixture, 25 samples per operation, under the shared lock. The benchmark source is identical for baseline and branch; the baseline compile flag selects its pre-isolation API. Each variant rebuilds the same scratch directory from clean products. Compiler source lists and source hashes are retained in `round8-verified-build-*.json` to rule out a stale SwiftPM plan; samples are in `round8-verified-perf-*.log` and summaries in `round8-verified-performance.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 253.93 / 271.13 | 2143.11 / 2162.88 | — |
| branch | 167.17 / 175.08 | 1990.37 / 2004.13 | -34.17% / -7.13% |
| branch-repeat | 165.44 / 171.29 | 1985.30 / 2002.80 | -34.85% / -7.36% |

Both branch medians remain within the approximately 5% budget. The table retains p95 variability rather than implying every sample improved.

Final adversarial review rechecked every stored-module traversal exit, grouping and nested layouts, missing checkouts, global/system/worktree/include scopes, directory stamps captured before enumeration, symlink-chain invalidation, cancellation/deadline propagation, private-index handling, dynamic-source refusal, strict inherited generic/URL-scoped policies, and preservation of header-free child settings. Read paths still force non-recursive submodule output and block implicit transports; all fetch/pull/push entry points use the same redirect preflight. No further finding emerged. All eleven round-8 mutations were detected. Every recorded implementation/test/fixture/script/project input remained unchanged through validation (`round8-verified-source-verification.json`).

The only integration discrepancy is the anticipated FileFolder resolver setup/test being absent from the fetched upstream, as documented above; the marker test remains intact. No unresolved finding in the round-8 fix or owner-policy decision remains.

Removed the generated large repository, exported baseline package, temporary byte-probe compiler cache and default XCTest result bundles after extracting evidence. No Clone directories remain. Text logs and JSON evidence are retained (`round8-cleanup.json`). Both validation drivers released their own shared lock; other workstreams’ locks and build products were untouched.

## Round 9: byte-delimited Git parsing — 2026-10-21

The five findings are confirmed against `7ee344e2824b1de07b74c3f148e0a0e595c0fc85`. A shared UTF-8 delimiter implementation now separates Git syntax from user-facing Unicode text. Every GitProcessSafety prefix/suffix, separator, config-key case comparison and path-component parser uses bytes or Unicode scalars. Generated override parsing guards missing/invalid fields rather than force-unwrapping. Existing control-character and exact-byte representability failures still select confinement; ZWJ is included in Foundation's control-character set and retains that conservative policy. No global program setting is silently rewritten.

The sweep covers all of GitProcessSafety and the Git path/config/output readers in GitView and FileFinder. It also fixes adjacent instances that feed subsequent reads or mutations. No new Git behavior, transport permission or trust exception is introduced.

| Entry points / fixed instances | Byte delimiters and coverage |
| --- | --- |
| Program-key classification, credential resets and required-filter defaults | `.` boundaries for filter, alias, pager, diff, difftool, gpg, credential and remote families; real `git config` validates keys and reads effective neutralised values back. |
| Redirect-key inventory | HTTP section/subsection `.` boundaries, case-insensitive ASCII key comparison, `=` override separator; any header-key presence still refuses all redirects. |
| Origin and active/inactive include resolution | `file:`, absolute `/`, final parent `/`, NUL/name/LF records; actual Git-reported origins and rev-parse paths determine expectations. Both relative-include sites stamp the real missing target. |
| Config/discovery resolution and invalidation | Original paths and readlink targets split on slash bytes; symlinks before a leading combining mark remain in the chain. Hardlinked config retarget tests still change the policy. |
| Conditional branch inventory | `includeif.onbranch:` and `refs/` prefixes; a symbolic alias change with unchanged HEAD rechecks the newly active include. |
| Generated overrides | First `=`, first/last `.`, subsection quote/backslash and glob punctuation; Git reads every representable generated config back exactly. Missing/invalid fields and unsupported control scalars throw confinement, never trap. |
| Git root, branch, history, stash and submodule metadata | LF/NUL/space/comma/tab/colon, ref prefixes, stash selector punctuation and ASCII whitespace; output path/ref terminators remove exactly one LF. User text search remains Unicode-aware. |
| Status, name-status, numstat and blame | NUL records, space/tab fields, byte status codes and blame metadata keys; generated real Git outputs preserve literal path/author/subject bytes. |
| Display/raw patch and C-quoted path parsing | `diff --git`, `a/`, `b/`, `--- `, `+++ `, `@@`, comma/space, quote/backslash, line `+`/`-`/space/note prefixes, LF/CRLF. Hunk data remains raw bytes. |
| Hunk working-file traversal | Every `/` component is opened separately with the existing no-follow checks; a separator plus combining mark cannot hide a symlink inside an openat path. |
| Watcher gitfiles, common dirs, refs and ignored paths | `gitdir: `, `/private`, relative/absolute `/`, LF/CRLF, directory-prefix separators; state notifications and ignored-directory coverage retain exact components. |
| FileFinder breadcrumbs, hidden names and ignore fallback | Root `/`, hidden `.`, relative path slices use UTF-8 counts; ignore patterns were already byte-based and remain so. |

The table-driven fixtures place U+0301, U+200D, U+FE0F and a regional-indicator pair beside relevant delimiters. Generated-config cases additionally cover `. / : = " \ [ ] * ?`, space, TAB, LF and NUL; real Git accepts and reads back representable cases, while unsupported encodings select confinement. File and program fixtures only write marker files inside generated temporary directories. The matrix verifies both local-program suppression and allowed global fsmonitor execution.

Before-fix evidence: the initial four-test selection produced 29 failed assertions; its marker-only program test initially passed, as explained in the fixture audit below. The isolated restored-value test trapped at the old `GitInventoryCache.swift:203` with signal 5. After correcting fixture expectations, the finalized broad replay on round 8 executed **13 tests with 135 failed assertions, 0 unexpected** (`round9-before-final-fixtures.log`). Both the direct restored-value case and the real global-value restoration case independently reproduced the same trap (`round9-before-value.log`, `round9-before-global-value.log`). Exact commands and exit statuses are in `round9-before.json` under this workstream's build root.

Fixture corrections are retained in the preliminary logs: path assertions now use Git's own absolute spelling rather than Foundation's `/var` alias; fixture C-quoting uses scalar escapes rather than grapheme-sensitive replacement; fsmonitor readback uses the scratch config directly so the confined inventory's own false override does not mask the value being tested; ZWJ cases accept the existing control-character confinement. None of those preliminary results is counted as final validation.

#### Mutation checks and adversarial self-review

Each mutation restored one Character-based boundary (or the original generated-option parser), then rebuilt and ran its regression; all **16 mutations were detected**. Per-command records are in `$B/logs/round9-mutations-through-quoting.json` and `round9-mutations.json`; the final fixed matrix is rerun after restoring sources.

| Mutated boundary | Result |
| --- | --- |
| program-prefix | Executed 2 tests, with 43 failures (0 unexpected) in 7.883 (7.884) seconds |
| active-include-parent | Executed 1 test, with 7 failures (0 unexpected) in 12.202 (12.203) seconds |
| inactive-include-parent | Executed 1 test, with 5 failures (0 unexpected) in 9.524 (9.525) seconds |
| original-path-chain | Executed 2 tests, with 9 failures (0 unexpected) in 4.303 (4.305) seconds |
| readlink-chain | Executed 1 test, with 3 failures (0 unexpected) in 0.220 (0.221) seconds |
| onbranch-prefix | Executed 1 test, with 6 failures (0 unexpected) in 4.518 (4.519) seconds |
| override-parser-trap | Signal 5: restored forced unwrap |
| header-prefix | Executed 1 test, with 6 failures (0 unexpected) in 5.721 (5.722) seconds |
| origin-prefix | Executed 1 test, with 3 failures (0 unexpected) in 5.610 (5.612) seconds |
| shared-field-split | Executed 2 tests, with 9 failures (0 unexpected) in 6.468 (6.470) seconds |
| shared-prefix-removal | Executed 2 tests, with 21 failures (0 unexpected) in 5.952 (5.953) seconds |
| quoted-path-parser | Executed 1 test, with 15 failures (0 unexpected) in 0.230 (0.231) seconds |
| working-file-symlink | Executed 1 test, with 3 failures (0 unexpected) in 0.226 (0.227) seconds |
| watcher-metadata | Executed 1 test, with 6 failures (0 unexpected) in 0.216 (0.217) seconds |
| folder-ignore-paths | Executed 1 test, with 6 failures (0 unexpected) in 0.847 (0.848) seconds |
| breadcrumb-boundary | Executed 1 test, with 6 failures (0 unexpected) in 0.909 (0.910) seconds |

Two preliminary mutation attempts survived and are retained as evidence: replacing only program-prefix checks did not fail the marker-only selection, so the final check restores the original classifier and additionally verifies effective Git configuration; the original quoted-path selection did not place a scalar immediately after its opening/closing quote, so that test was extended before repeating the mutation (15 failed assertions). No compile failure was counted as a detected mutation.

Self-review followed inventory input through config classification, both include expansions, original/readlink component walks, branch dependencies, override emission, and the command/fallback boundary. Remaining `split`/index/prefix operations in GitProcessSafety are on bytes, arrays or Unicode scalars. Generated options reject malformed separators rather than force-unwrapping. GitView/FileFinder now share the byte operations for protocol and path boundaries; user-entered search grammar and human-facing messages remain character-aware. Raw invalid UTF-8 and unsupported controls retain the existing confinement policy. No real preferences, credentials, user repositories, or remote services were used by fixtures.

After restoring every mutation, the finalized matrix passed **16/16**, with no failures (`round9-matrix-restored-after-mutations.log`). All production files were byte-compared with the pre-mutation backup before committing.

#### Upstream integration

Fetched and merged `origin/dev/next` at `f80e83cbb61866b6d222cc45e9b111aa96037d45` (includes `6f7310af`) using a merge commit, without rebasing or changing upstream history. Conflict resolution retains all release entries, `FileFolderTests.setUp` with `installStandaloneFileResolver(self)`, `testFixtureOwnsInheritedHooks`, and the outside-project fsmonitor marker test. GitWatcher retains discovery retries and inventory invalidation; GitService retains upstream status-owned grouping, pair batching and bounded untracked counts. Regenerated the Xcode project.

The merge introduced another instance of the same byte-delimiter class in untracked-count snapshots: a tracked directory `.gitattributes` was missed when the following path component began with an extender. The generated four-scalar matrix first failed **3 assertions**, then passed after converting all new snapshot path splits/prefixes and avoiding a parsed-array subscript (`round9-merged-counts-before.log`, `round9-merged-counts-fixed.log`). Its preliminary untracked-attributes fixture passed because those attributes were copied as a separate status row; the final fixture tracks that file to exercise parent traversal.

Adversarial merge review also found that upstream preview arguments put `--ignore-submodules=none` after Bello’s forced read flags. The expanded historical-submodule fixture demonstrated the marker file being written by the child during preview. Read policy now places its final options before the command’s operand terminator. The existing upstream dirty-only submodule assertion conflicted with the owner’s round-4 non-recursive policy (two assertions failed before resolution); it now expects no child-worktree inspection, while retaining checks for staged gitlink changes and configured ignores. This preserves the existing owner decision rather than introducing a new policy.

Both merged-code mutations were detected: restoring the snapshot parser failed 3 assertions, and restoring the old read-option placement failed the child-program assertion (`round9-merge-mutation-*.log`). The restored integration selection passed 19 tests. A subsequent terminator audit added explicit-branch history to the delimiter matrix and caught that the first placement fix put flags after `--end-of-options`: two tests failed with Git’s option-order error (`round9-option-terminator-before.log`). The final placement recognizes both `--` and `--end-of-options`; its focused rerun and full-suite evidence follow below.

The final integration focus passed **9/9** (`round9-final-integration-focused.log`). Restoring the single-terminator lookup then failed both explicit-branch tests; restoring the fix passed **2/2** (`round9-terminator-checks.json`). In total the round detected 16 initial mutations plus the count, precedence and terminator mutations.

#### Final fixture audit and first complete package run

The first complete merged package run executed **448 tests: 442 passed, 4 skipped, 2 failed** (`round9-final-views-initial.log`). Both failures were new upstream batching fixtures: `GIT_TRACE2_EVENT` targeted `.git/count-trace.json`, which the untrusted sandbox correctly refused to write. The tracing-only generated service now explicitly uses `trusted: true`; its empty fixture global/system configuration is unchanged. Both tests pass and measure four Git invocations each for 653 and 512 rows. No production confinement was relaxed.

The marker audit also established why the preliminary prefix-only mutation survived: changing `base\n` to a longer file allowed Git status to decide from size without invoking its filter. The final fixture uses equal-size `edit\n`, positively checks that ordinary Git invokes the generated marker program, removes the marker, then runs Bello’s read. Restoring only the old prefix checks now fails **3 marker assertions** (U+0301, U+200D and U+FE0F), both in the failing-first replay and the repeated mutation; the fixed test passes. ZWJ follows the existing control-character confinement policy and may refuse a content-filter comparison; the fixture verifies sandbox selection and absence of the marker rather than requiring unconfined success. An initial strengthened-fixture run stopped at that expected refusal and is retained as `round9-equal-size-marker-fixed-initial.log`. Final fixture checks pass **3/3** (`round9-final-fixture-checks.json`). The full package and remaining validation are rerun below after these test-only corrections.

#### Final validation on the merged result

All commands below ran after the final fixture corrections. `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`; common environment: `PI_BUILD_ROOT=$B CFFIXED_USER_HOME=$B/round9-views-home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1`. The shared full-lane lock covered this sequence, including every benchmark and native/gallery run, and was released in the driver’s `finally` block. Detailed command/status/duration records: `$B/logs/round9-final-validation.json`; toolchain: Apple Git 2.39.5, Swift 6.0.2, Xcode 16.1, macOS 14.8.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| views | 444 | 4 | 0 |
| helper-cost | 5 | 0 | 0 |
| helper | 1157 | 7 | 0 |
| wire | 40 | 0 | 0 |
| concurrent | 4 | 0 | 0 |
| acceptance | 3 | 0 | 0 |
| Native (41 classes, including gallery) | 380 | 2 | 0 |

Exact commands (extra environment shown where set):

```sh
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round9-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round9-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round9-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round9-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/FilePageReadTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitConfirmationSheetTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiscardQuestionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelDiffCaptureTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelLayoutTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelRedrawTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelShownTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelWidthTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenPlacementTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round9-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Native class results (each serial-lane class ran alone):

| Class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChangesTabFrameTests | 8 | 0 | 0 |
| ChangesTabTests | 9 | 0 | 0 |
| CrashAuditRegressionTests | 12 | 0 | 0 |
| FileBlameTests | 10 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FileFolderTests | 21 | 0 | 0 |
| FileHiddenReadTests | 5 | 0 | 0 |
| FilePageReadTests | 3 | 0 | 0 |
| FilePreviewRefreshTests | 3 | 0 | 0 |
| FileReviewStateTests | 21 | 0 | 0 |
| FileTabTests | 17 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| GitChangelistReadTests | 2 | 0 | 0 |
| GitCommitBrowsingTests | 3 | 1 | 0 |
| GitConfirmationSheetTests | 7 | 0 | 0 |
| GitDiffTableTests | 19 | 0 | 0 |
| GitDiscardQuestionTests | 2 | 0 | 0 |
| GitHistoryFilterTests | 14 | 0 | 0 |
| GitHunkReviewTests | 9 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| GitOperationSafetyTests | 12 | 0 | 0 |
| GitPanelAuditTests | 8 | 0 | 0 |
| GitPanelDiffCaptureTests | 0 | 1 | 0 |
| GitPanelLayoutTests | 4 | 0 | 0 |
| GitPanelNarrowParityTests | 8 | 0 | 0 |
| GitPanelRedrawTests | 4 | 0 | 0 |
| GitPanelShownTests | 13 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitPanelWidthTests | 3 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRenameTests | 6 | 0 | 0 |
| GitRepositoryPermissionTests | 4 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitSafetyGalleryTests | 1 | 0 | 0 |
| GitToolTests | 5 | 0 | 0 |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 |
| QuickOpenPlacementTests | 1 | 0 | 0 |
| QuickOpenTests | 17 | 0 | 0 |
| WebhookExchangeTests | 5 | 0 | 0 |
| WebhookTests | 18 | 0 | 0 |
| WorkspaceTests | 17 | 0 | 0 |

#### Large-repository latency

Compared with `origin/dev/next` at `f80e83cbb61866b6d222cc45e9b111aa96037d45`, using the same generated 50,000-file / 20-submodule repository and 25 samples per operation. Each variant rebuilt the same scratch directory from clean products; compiler input lists and source hashes are retained in `round9-final-build-*.json`. Baseline uses the identical benchmark source with its pre-isolation API compile flag. Raw samples: `round9-final-perf-*.log`; measured summaries: `round9-final-performance.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 249.788 / 260.985 | 2172.462 / 2222.164 | — |
| branch | 172.778 / 183.739 | 2078.539 / 2105.712 | -30.83% / -4.32% |
| branch-repeat | 168.722 / 180.434 | 2022.002 / 2097.959 | -32.45% / -6.93% |

Both branch measurements meet the approximately 5% steady-state budget. The post-merge adversarial sweep rechecked every GitProcessSafety parser and its GitView/FileFinder consumers, including newly merged snapshot paths and display-option ordering. The broad delimiter matrix, positive marker control, mutation replays, full package run, native checks and generated loopback suites are recorded above. No unresolved finding remains from this round.

The benchmark fixture contained **50,021 tracked entries: 50,001 regular files and 20 gitlinks** (`round9-large-fixture-counts.json`). Final implementation and test inputs are committed at `b318a621ae99a9b6abdd6f5333f8e4e3ff19f562`; only this validation record changed after that run began.

Skipped checks are explicit opt-in measurements or captures: three Finder performance tests and the separately executed Git inventory benchmark in the package run; seven helper fixture-generation/performance cases; the native real-repository commit-browsing benchmark and optional diff-pane capture. The helper total, combining the separately run cost class and remaining suite, is **1,162 passed, 7 skipped, 0 failed**.

The enabled `GitSafetyGalleryTests` run passed and regenerated **112 PNGs** in `$B/round9-gallery`. Visually inspected `untrusted-light-1180x780.png`, `untrusted-dark-310x600.png`, `http-redirect-dark-1180x780.png`, `http-redirect-light-310x600.png`, `amend-checked-dark-310x600-sheet.png`, `preflight-failure-light-700x640-sheet.png`, `conflict-light-920x600.png`, and `commit-box-dark-700x640.png`. Trust/redirect notices, file rows, diff presentation and sheet actions remain legible in the sampled light/dark and narrow layouts; narrow notices retain their existing ellipsis behavior. No new visual regression was observed.

Removed only this workstream’s generated large fixture, exported baseline and final default XCTest result bundle after extracting the text/JSON evidence. No Clone directories remain under its native build root. The 112 gallery images, text logs and JSON records are retained; cleanup details are in `$B/logs/round9-cleanup.json`. The validation driver released its own full-lane lock on completion. Other workstreams’ locks and build products were untouched.

## Round 10: canonical trust boundaries and snapshot context — 2026-10-21

Both review findings are confirmed against `6fbe70bcf1c382c70ab96d09e0da92106afe2aec`. Project containment now compares canonical UTF-8 bytes with an exact root or slash boundary. The longest root is measured in bytes, and an equally specific untrusted alias cannot be displaced by a trusted one. This uses `GitBytes`; it does not depend on the separate `dev/a130-grapheme` branch's `CanonicalPath.swift`. Canonicalization and boundary semantics are intentionally the same so the lead can unify the helpers.

Snapshot count reads keep their private working directory and bounded copied content. Their trust lookup and configuration inventory use the source repository; the captured Git directory is supplied both to the actual command and its inventory environment. This also prevents a later change to the source `.git` entry from selecting a different inventory than the command's captured directory. The existing invocation carries cancellation and its deadline through inventory and execution. Trusted global/system filters remain allowed, local program settings remain neutralized, and untrusted source projects remain confined.

| Sweep location | Decision / coverage |
| --- | --- |
| `WorkspaceModel.swift` trust resolver | Canonicalize query and roots, compare byte containment, choose the longest byte root, preserve denial at equal specificity. This was the file's only Character-based path-prefix check. |
| `WorkspaceTabs.swift` project ownership and folder roots | Canonicalize both sides (including symlink aliases), use the same containment and byte length, and preserve an equally specific denial. Absolute tool-card paths use a byte prefix. |
| `ReplyFileResolver.swift` project selection | The same canonical boundary and longest-root denial rule applies before a file link can be offered; absolute path selection uses bytes. |
| `WorkspaceChanges.swift`, `FileReviewState.swift`, `FileBlame.swift` | Ancestor/descendant checks use canonical byte containment; relative Git filenames drop byte counts, so the leading scalar is preserved. |
| `ChangesTab.swift`, `SessionFloatingPanel.swift` | Existing permission checks re-read project trust and exact configured root membership; there is no Character prefix in those checks. |
| `GitService.swift` temporary no-index counts | The only read command using a different cwd plus explicit `--git-dir`/`--work-tree` now carries source trust and inventory. Other read entry points use their repository cwd. |

Adjacent paths outside this round's Git trust/context changes remain for the app grapheme workstream: `QuickOpen.swift:373–375` can omit a marked recent-path component; `FileTabViews.swift:223` can miss home-path abbreviation. `WorkspaceFolders.swift` absolute-input validation and `FileRecentState.read` reject an initial slash followed by a mark; these fail closed and do not grant Git execution. No changes were made to those separate display/input paths.

The generated nested-project matrix covers U+0301, U+200D, U+FE0F and a regional-indicator pair, canonical symlink aliases, sibling boundaries, trust revocation and equally specific denials. The global fsmonitor program only creates a fixture marker. A second generated fixture uses a test-only `GIT_CONFIG_GLOBAL`, a conditional global clean filter, a competing local filter, and marker files under `.git`: trusted counts must be shown and only the global marker may be written; revoked trust permits neither marker. A positive Git `hash-object` check confirms the global filter is active.

Initial failing-first runs: the original nested-trust regression produced **13 failed assertions**, including marker execution; the first snapshot selection produced **4 failed assertions**. Adding a positive control exposed that the conditional-include fixture needed Git's reported gitdir spelling instead of a Foundation `/var` alias. After that fixture correction, the finalized snapshot regression failed **5 assertions** on the old implementation and passed after the context fix (`round10-counts-confirmed-before.log`, `round10-counts-fixed.log`). The earlier fixture logs are retained and are not counted as final validation. Native sweep replays and mutations follow below.

#### Failing-first replays and mutation checks

The finalized native tests replayed the six app files from `6fbe70bc`: nested trust/ownership produced **22 failed assertions**, including the marker file, and blame/history produced **4 failed assertions**. Both passed with the fixes restored. The first native attempt had a compile-only test error (`WorkspaceModel.error` is optional); the fixture expectation was corrected to `nil`, and that attempt is not counted as test evidence. Its original log remains in `round10-trust-final-before-compile-initial.log`.

Each mutation was run separately, then restored before the next. These are assertion failures from executed tests, not build errors:

| Mutation | Failed assertions |
| --- | ---: |
| `mutation-WorkspaceModel` | 10 |
| `mutation-WorkspaceTabs` | 9 |
| `mutation-ReplyFileResolver` | 3 |
| `mutation-WorkspaceChanges` | 1 |
| `mutation-FileReviewState` | 1 |
| `mutation-FileBlame` | 2 |
| `mutation-snapshot-trust` | 5 |
| `mutation-snapshot-inventory` | 2 |
| `mutation-containment` | 7 |

The six app mutations restore the corresponding file from round 9. The snapshot trust mutation resolves trust from scratch instead of source; the inventory mutation drops the source inventory and captured `GIT_DIR` while retaining trust, and the test detects the local marker file. The containment mutation substitutes Character-based `hasPrefix`. After all nine mutations, **9 package tests and both native regression selections passed**. The driver verified restoration and released its own full-lane lock. Logs and exact per-run commands/statuses: `$B/logs/round10-focused-checks.json` and `round10-<selection>.log`.

Focused environment: `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`, `PI_BUILD_ROOT=$B CFFIXED_USER_HOME=$B/round10-home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1`. Commands (replayed for the corresponding source variants):

```sh
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests/testNestedProjectTrustKeepsBytePathBoundaries
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests/testMarkedPathComponentsKeepBlameAndHistoryInTheirRepository
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryTests/testSnapshotCountsKeepSourceTrustAndProgramInventory
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitByteParsingTests/testCanonicalContainmentUsesBytesAndBoundaries
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter 'GitInventoryTests/testSnapshotCountsKeepSourceTrustAndProgramInventory|GitByteParsingTests'
```

Adversarial self-review checked canonical aliases, exact-root and sibling boundaries, byte-length precedence, equally specific denials, trust changes after a warm inventory, and marked components in blame/history. For counts it checked that the temporary cwd remains private, the captured gitdir is shared by inventory and command, conditional global filters still match, local programs remain masked, and the original cancellation/deadline reaches the inventory. The only source-context override is the internal untracked-count invocation. No additional in-scope issue was found.

Integration: after committing the round-10 fixes as `a7b1b354`, fetched and merged `origin/dev/next` at `78729efa25784800ef1f12f41bdc1fb39b08cacd` with a merge commit, without rebasing. The merge was automatic; both release-entry sets and both WorkspaceModel changes are retained. Regenerated the project with `xcodegen generate --quiet`. `FileFolderTests` still contains `installStandaloneFileResolver(self)`, `testFixtureOwnsInheritedHooks`, and the fsmonitor marker regression. The merged result is the input to the validation below.

#### Final validation on the merged result

All commands below ran after the final round-10 fixes and mutation restorations. `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`; common environment: `PI_BUILD_ROOT=$B CFFIXED_USER_HOME=$B/round10-views-home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1`. The helper, loopback and package fixture suites ran first without changing app focus; package performance captures were disabled. The shared lock covered the subsequent benchmark and native/gallery sequence, and was released in the driver’s `finally` block. Detailed command/status/duration records: `$B/logs/round10-final-validation.json`; toolchain: Apple Git 2.39.5, Swift 6.0.2, Xcode 16.1, macOS 14.8.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| views | 446 | 4 | 0 |
| helper-cost | 5 | 0 | 0 |
| helper | 1157 | 7 | 0 |
| wire | 40 | 0 | 0 |
| concurrent | 4 | 0 | 0 |
| acceptance | 3 | 0 | 0 |
| Native (45 classes, including gallery) | 417 | 2 | 0 |

Exact commands (extra environment shown where set):

```sh
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/FilePageReadTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitConfirmationSheetTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiscardQuestionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelDiffCaptureTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelLayoutTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelRedrawTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelShownTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelWidthTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenPlacementTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ReplyFileLinkTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-session-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelGalleryTests
TEST_RUNNER_PI_FILE_REVIEW_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-file-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewGalleryTests
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round10-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

Native class results (each serial-lane class ran alone):

| Class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChangesTabFrameTests | 8 | 0 | 0 |
| ChangesTabTests | 9 | 0 | 0 |
| CrashAuditRegressionTests | 12 | 0 | 0 |
| FileBlameTests | 10 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FileFolderTests | 21 | 0 | 0 |
| FileHiddenReadTests | 5 | 0 | 0 |
| FilePageReadTests | 3 | 0 | 0 |
| FilePreviewRefreshTests | 3 | 0 | 0 |
| FileReviewGalleryTests | 1 | 0 | 0 |
| FileReviewStateTests | 22 | 0 | 0 |
| FileTabTests | 17 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| GitChangelistReadTests | 2 | 0 | 0 |
| GitCommitBrowsingTests | 3 | 1 | 0 |
| GitConfirmationSheetTests | 7 | 0 | 0 |
| GitDiffTableTests | 19 | 0 | 0 |
| GitDiscardQuestionTests | 2 | 0 | 0 |
| GitHistoryFilterTests | 14 | 0 | 0 |
| GitHunkReviewTests | 9 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| GitOperationSafetyTests | 12 | 0 | 0 |
| GitPanelAuditTests | 8 | 0 | 0 |
| GitPanelDiffCaptureTests | 0 | 1 | 0 |
| GitPanelLayoutTests | 4 | 0 | 0 |
| GitPanelNarrowParityTests | 8 | 0 | 0 |
| GitPanelRedrawTests | 4 | 0 | 0 |
| GitPanelShownTests | 13 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitPanelWidthTests | 3 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRenameTests | 6 | 0 | 0 |
| GitRepositoryPermissionTests | 5 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitSafetyGalleryTests | 1 | 0 | 0 |
| GitToolTests | 5 | 0 | 0 |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 |
| QuickOpenPlacementTests | 1 | 0 | 0 |
| QuickOpenTests | 17 | 0 | 0 |
| ReplyFileLinkTests | 4 | 0 | 0 |
| SessionPanelGalleryTests | 1 | 0 | 0 |
| SessionPanelTests | 29 | 0 | 0 |
| WebhookExchangeTests | 5 | 0 | 0 |
| WebhookTests | 18 | 0 | 0 |
| WorkspaceTests | 17 | 0 | 0 |

#### Large-repository latency

Compared with `origin/dev/next` at `78729efa25784800ef1f12f41bdc1fb39b08cacd`, using the same generated 50,000-file / 20-submodule repository and 25 samples per operation. Each variant rebuilt the same scratch directory from clean products; compiler input lists and source hashes are retained in `round10-final-build-*.json`. Baseline uses the identical benchmark source with its pre-isolation API compile flag. Raw samples: `round10-final-perf-*.log`; measured summaries: `round10-final-performance.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 260.171 / 272.541 | 2187.597 / 2215.576 | — |
| branch | 173.302 / 180.483 | 2043.806 / 2082.438 | -33.39% / -6.57% |
| branch-repeat | 172.176 / 182.651 | 2047.543 / 2086.832 | -33.82% / -6.40% |

Both branch measurements meet the approximately 5% steady-state budget. The adversarial sweep rechecked canonical trust selection, symlink aliases and sibling boundaries, source-versus-scratch context, retained Git directory selection, local/global program settings, trust revocation, and the existing invocation cancellation/deadline. The marker controls, source replays, mutation runs and full suites are recorded above. No unresolved finding remains from this round.

The measured fixture contained **50,021 tracked entries: 50,001 regular files and 20 gitlinks** (`round10-large-fixture-counts.json`). Final implementation and test inputs are committed at `6664f331fe328513a335fdd5b6d32df3e7982ff0`; only this validation record changed after that run began. All final commands exited successfully. The helper total, including its separately executed cost class, is **1,162 passed, 7 skipped, 0 failed**.

Skipped cases are explicit opt-ins: three Finder measurements and the separately executed Git inventory benchmark in the package run; seven helper fixture-generation/performance cases; the native real-repository commit-browsing benchmark and optional diff-pane capture. All three enabled galleries passed. Wait-only driver restarts while other workstreams held the shared lock did not interrupt tests; completed helper and loopback results were retained before the package run. No final test was retried or left failing.

Regenerated **158 PNGs**: 112 Git-safety scenes, 24 file-review scenes and 22 floating-panel scenes. Inspected `round10-gallery/untrusted-light-1180x780.png`, `untrusted-dark-310x600.png`, and `http-redirect-dark-1180x780.png`; `round10-file-gallery/history-light-1240x800.png`, `history-dark-420x600.png`, and `back-light-420x600.png`; and `round10-session-gallery/diff-1440x900-light.png`, `diff-classification-1440x900-dark.png`, and `pill-960x700-light.png`. Counts and binary labels, history navigation, restored selection, and trust/redirect notices remain legible in the sampled light/dark and narrow layouts. Existing notice ellipsis and horizontal file scrolling remain visible. No new visual regression was observed.

Removed only this workstream's generated benchmark repository, exported baseline and final default XCTest result bundle after extracting text/JSON evidence. No Clone files remain under its native build root. The 158 gallery images, command logs, mutation evidence, source hashes and JSON counts are retained under `$B`; cleanup details are in `$B/logs/round10-cleanup.json`. The validation driver released its own lock. Other workstreams' locks and build products were untouched. Both assigned findings are resolved; the adjacent display/input cases noted in the sweep remain for the separate app grapheme workstream.


## Round 11: stored-module entry types — 2026-10-21

Both reported regressions are confirmed. All fixtures are generated in temporary directories with isolated `HOME` and `GIT_CONFIG_GLOBAL`; configured fixture programs only create a marker file. No real preferences, chats, Keychain items or external provider requests are used.

The walk now checks entry types with `lstat`, follows a symlink with `stat`, and stamps the original spelling plus the existing full resolution chain. Ordinary files and links to ordinary files are skipped. A directory becomes a repository candidate only with a file `HEAD` and a file `config`/`commondir`, or an `objects`/`refs` directory layout for a valid repository without config. Confined Git still validates and inventories each candidate. A directory named `HEAD`, `config` or `commondir` is a grouping component, while an isolated ordinary config/commondir file does not make its containing group a repository.

Directory symlinks are **followed and inventoried**, because Git can follow them and their spelled path can activate distinct conditional includes. Dangling targets are stamped; creating the target later invalidates the parent inventory. Symlink cycles retain the existing depth/deadline refusal. Failed metadata reads or directory enumeration still select confinement for reads and refuse network commands. Skipping an unreadable candidate is never treated as a successful inventory. This preserves the existing redirect policy and does not introduce a new trust or redirect decision.

### Regression and mutation evidence

Logs and exact command JSON are under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/logs/round11-*`. The initial pre-fix run on `49bc6308` executed four new tests: the grouping-directory, ordinary-file and symlink-file layouts failed; the unreadable-directory control passed. The first restored run passed all four. The wider sweep added ordinary files named config/commondir in grouping directories and a valid bare module without config whose global conditional header must still be inventoried.

| Fixture | Required result |
| --- | --- |
| Real deinitialized submodules named `group/config`, `group/HEAD`, `group/commondir` | Inventory reaches the child policy; trusted status stays unconfined; raw Git and GitService fetch/pull/push succeed. |
| `.DS_Store` and stray files at three levels; ordinary group config/commondir files | Files are skipped; the nested module remains inventoried and operations succeed. |
| File symlink, initially dangling directory symlink, later target creation | File link is skipped; the new directory's header forces redirect refusal without touching the link; operations succeed. |
| Cyclic module-directory symlink | Inventory refuses rather than omit reachable configuration. |
| Valid module and grouping directory chmod 000 | Fixture first proves enumeration really fails; inventory refuses; status runs in the sandbox; all three network commands refuse. |
| Bare module without config, with a global gitdir conditional header | Git's own query confirms the header; the parent inventory also protects it. |

The configless fixture uses Git's returned absolute common directory for the condition; a preliminary fixture used macOS's `/var` alias while stored discovery used `/private/var`, so that condition was corrected before final evidence. A mutation that merely swallowed enumeration errors did not bypass the earlier unreadable-marker check; the stronger mutation that skips unreadable child directories is rejected by the test. This confirms both checks rather than relying on the first mutation as coverage.

The complete replay of the five fixtures against `49bc6308` has **3 failed cases / 10 failed assertions, 2 passed** (`round11-before-complete.log`); restoring the fix has **5 passed, 0 failed** (`round11-restored.log`). The extra pre-fix controls (unreadable and configless repositories) pass because the fix must retain those behaviors.

| Mutation | Selected test cases / failed assertions |
| --- | ---: |
| Restore existence-only marker classification | 1 / 3 |
| Enumerate ordinary files as directories | 1 / 3 |
| Skip module symlinks without inspecting their targets | 1 / 2 |
| Skip unreadable candidate directories | 1 / 8 |
| Omit a valid repository without config | 1 / 1 |

Each mutation compiles and fails the intended test; production code is restored after each run. `round11-mutations.json` and per-command JSON retain statuses and arguments. Commands use `swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryTests/<test name>`; the complete replay/restored selector contains all five table cases. The untouched unreadability guards also reject the weaker enumeration-only mutation before directory listing.

The adversarial review checks marker kinds, configless repositories, ordinary file names at grouping levels, readable and dangling symlinks, target activation, cyclic paths, unreadable metadata/directories, scope preservation, invalidation stamps, invocation cancellation, and the shared fetch/pull/push admission path. The type change neither skips a Git-recognizable repository nor treats a failed read as absence. No UI or helper production change is introduced by this fix.

Final merged validation and command counts follow below.


### Upstream integration and final-run boundary

The initial type fix and evidence are committed at `1b23564e`. The pre-integration full `GitInventoryTests` class passed **77/77** (`round11-inventory.log`). Published `origin/dev/next` was first merged at `5cb9d2d5` (merge `c8a9f82b`); the `NEXT-RELEASE.md` conflict keeps both sides' entries. The async XCTest fix then became available at `d6cd317a` and was merged as `5f31cb0d`. `FolderBrowserTests` retains every inserted security regression and derives from `ViewsTestCase`. `GitByteParsingTests`, `GitHTTPRedirectTests`, `GitInventoryPerformanceTests`, `GitInventoryTests`, and `GitRepositorySecurityTests` now use the same base. The only remaining direct XCTestCase subclass in the views package is the intended support base itself.

`FileFolderTests` retains its `installStandaloneFileResolver(self)` setup, `testFixtureOwnsInheritedHooks`, and the fsmonitor marker regression. The generated project was regenerated. Before final suites, upstream's additional fixture-readiness fix `547181491ed0846b8f498b5c03d188b4df88f519` was integrated as well; that revision is the pinned performance baseline. A preliminary helper run was stopped for this last integration and its logs are preserved as `round11-pre-last-merge-*`; none of those results count toward final validation. Final suites restart after the integration correction below, with source changes frozen for their duration.


The merged helper guard also found this branch's earlier `HTTPRedirectTests` still deriving from XCTestCase (`round11-before-helper-base-helper.log`, `IssueRecordingTests`, 1 failed assertion naming that class). It now derives from `HelperTestCase`, with no production-helper change. The selected redirect and recording classes pass **3/3**; reverting that base produces **1 failed recording test / 1 assertion, 2 passed**, and restoring it passes **3/3** (`round11-helper-base-{fixed,mutation,restored}.log`). The incomplete full-helper attempt is preserved and excluded from final counts; the full suite is rebuilt and rerun after this integration correction. All views classes and helper classes are now covered by their upstream inheritance guards.

### Final merged validation

All final commands ran from the assigned worktree against `321a9f57`, after merging upstream through `54718149`. `$B` below is `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. The final driver, source manifests, exact commands, exit statuses, durations and text logs are retained under `$B/logs/round11-final-*`.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| bello-views | 452 | 4 | 0 |
| Native focused classes (25) | 275 | 1 | 0 |
| Helper (cost class plus remaining suite) | 1171 | 8 | 0 |
| Release-helper wire | 40 | 0 | 0 |
| Release-helper concurrent | 4 | 0 | 0 |
| Release-helper acceptance | 3 | 0 | 0 |

The eight helper skips are opt-in fixture-writing/performance measurements, including the merged image measurement. The views skips are three Finder benchmarks and the inventory benchmark executed separately below. The native commit-browsing benchmark is an opt-in skip; the Git-safety gallery is enabled.

Exact final commands (common environment):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
export CFFIXED_USER_HOME="$PI_BUILD_ROOT/round11-views-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round11-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round11-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round11-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round11-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ReplyFileLinkTests
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round11-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

The shared full-lane lock covers all native/focus work and each benchmark. Each serial-lane native class runs alone; parallel-capable classes run only in the explicit group. The views and helper suites use their existing dedicated scratch directories; no second DerivedData copy is created.

| Native class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChangesTabTests | 9 | 0 | 0 |
| CrashAuditRegressionTests | 12 | 0 | 0 |
| FileBlameTests | 10 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FileFolderTests | 21 | 0 | 0 |
| FileReviewStateTests | 22 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| GitChangelistReadTests | 2 | 0 | 0 |
| GitCommitBrowsingTests | 3 | 1 | 0 |
| GitHistoryFilterTests | 14 | 0 | 0 |
| GitHunkReviewTests | 9 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| GitOperationSafetyTests | 12 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRepositoryPermissionTests | 5 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitSafetyGalleryTests | 1 | 0 | 0 |
| GitToolTests | 5 | 0 | 0 |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 |
| QuickOpenTests | 17 | 0 | 0 |
| ReplyFileLinkTests | 4 | 0 | 0 |
| WebhookExchangeTests | 5 | 0 | 0 |
| WebhookTests | 18 | 0 | 0 |
| WorkspaceTests | 17 | 0 | 0 |

### Latency after entry-type validation

Generated fixture: **50,001 regular tracked files and 20 submodules**, 50,021 index entries. Baseline is pinned `origin/dev/next` at `547181491ed0846b8f498b5c03d188b4df88f519`. Each variant rebuilds the same package scratch directory from clean products, verifies compiler input paths/source hashes, warms up, and records 25 samples per operation. The baseline uses the identical benchmark source and the pre-isolation API flag. Raw samples and source provenance are in `round11-final-perf-*.log` and `round11-final-build-*.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 258.556 / 267.287 | 2186.430 / 2579.896 | — |
| branch | 174.026 / 183.311 | 2077.947 / 2151.778 | -32.69% / -4.96% |
| branch-repeat | 171.536 / 180.420 | 2053.166 / 2100.586 | -33.66% / -6.10% |

Both branch measurements meet the approximately 5% steady-state latency budget. No required suite remains failing. The two assigned traversal findings are resolved; the conservative refusal for unreadable candidates and cyclic module aliases is intentional. The earlier helper inheritance failure and its correction remain documented above; a read-only stack sample during the long helper crash-recovery matrix confirmed active fixture work, and that uninterrupted final suite subsequently passed.


Regenerated **112 Git-safety PNGs** and inspected `round11-gallery/untrusted-light-1180x780.png`, `untrusted-dark-310x600.png`, and `http-redirect-dark-1180x780.png`. The trust/redirect notices, file rows and controls remain legible in the sampled light, dark and narrow layouts; existing notice ellipsis and scrolling are retained. No new visual regression was observed. `round11-gallery-images.json` lists all outputs.

Removed this workstream's generated large-repository fixture, exported baseline and the final default XCTest result bundle after saving text/JSON evidence. No clone folders remained in its native build root; compiler objects for tests with Clone in their name were retained. The 112 gallery images, raw samples, compiler input/source hashes, command results and mutation logs remain under `$B`. Cleanup is recorded in `round11-cleanup.json`; the validation driver released only its own lock, as recorded in `round11-lock.txt`. Other workstreams' locks and build products were untouched. There are no unresolved assigned findings.


## Round 12: asynchronous Git trust resolution — 2026-10-21

The review is confirmed. The main-actor trust callback previously canonicalized
both the query and every configured project root before the Git workers started.
A generated blocking-path fixture stopped the main-actor heartbeat, delayed an
unrelated local Git read until the path was released, and allowed a global marker
file program after trust was revoked during resolution.

### Implementation and cache decision

- The callback snapshots only root strings, trust flags and `workspacesRevision`
  on the main actor. `WorkspaceRecord.roots` is just `[path] + paths`; this snapshot
  performs no filesystem work. Canonicalization runs on a dedicated concurrent
  Dispatch queue, outside the main actor and Swift's cooperative executor.
- Every root must resolve before a trusted result can be returned. A project on a
  slow volume could be a symlink into the queried repository, so it is never
  excluded using lexical path guesses. After at most 250 ms, incomplete resolution
  selects confinement for that read; an unrelated local repository remains readable.
  The Git invocation's shorter deadline and cancellation take precedence.
- Pending lookups for identical path bytes and workspace revision are coalesced, with at most 64 outstanding
  filesystem calls per resolver. Unwanted queued lookups are skipped. A kernel path
  call that is already blocked cannot be forcibly interrupted; callers stop waiting
  promptly and it holds neither the main actor nor a Swift cooperative thread.
- Completed canonical roots are deliberately **not** cached by workspace revision:
  symlinks can retarget without any workspace edit. A new regression retargets a
  denied project alias without changing the revision and verifies the next read is
  denied. Only pending path work is shared; no trust decision is cached there.
- After resolution, the callback rechecks the revision and shutdown state before
  granting trust. Replacement of the entire resolver also invalidates an in-flight
  result. Existing byte-aware canonical containment, most-specific-root selection,
  equal-specificity denial and source-repository context for count snapshots remain.
- `GitService` and `FinderProcess` place trust lookup inside their cancellation
  handlers and pass the same `GitInvocation` through lookup, inventory and execution.
  Trust resolution cannot reset the command deadline or retain a process slot after
  its cancelled read completes.

### Failing-first and focused evidence

All fixtures use temporary directories, isolated global Git configuration and
marker file programs. `B` is
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`.
The wrapper `B/round12-run.py` records exact commands, statuses and elapsed times
in `B/logs/round12-*.json`; native runs acquire and release the shared lane lock.

- `PI_BUILD_ROOT=$B scripts/test-macos.sh -parallel-testing-enabled NO
  -only-testing:PiAppTests/GitRepositoryPermissionTests/testSlowTrustPathDoesNotBlockMainActorOrOtherGitReads
  -only-testing:PiAppTests/GitRepositoryPermissionTests/testTrustRevokedDuringPathResolutionConfinesTheRead`
  before the fix: **2 cases failed, 3 assertions** (`round12-failing-first.log`).
  The heartbeat stayed at zero and the global marker file was present.
- The complete native `GitRepositoryPermissionTests` class after the fix:
  **9 passed, 0 failures** (`round12-fixed-native-2.log`). This also covers the
  shared timeout/cancellation, coalescing, unchanged-revision symlink retargeting,
  nested byte boundaries, global programs and trusted explicit writes.
- `swift test --package-path packages/bello-views --scratch-path $B/views-tests
  --filter 'GitInventoryTests/testTrustCallback|GitInventoryTests/testReplacingTrustCallback|FolderBrowserTests/testFinderTrustCallback'`:
  **3 passed, 0 failures** (`round12-focused-views.log`).
- The first native build identified a missing `Sendable` annotation on the
  lock-protected pending-path object. It was corrected before the 9-case pass;
  `round12-fixed-native.log` is build-failure evidence, not a test result.

### Mutation and adversarial review

| Mutation | Focused fixture | Result |
| --- | --- | --- |
| Canonicalize on the main actor again | Native slow-path/heartbeat fixture | 1 case failed, 2 assertions |
| Omit workspace revision revalidation | Native revoke-during-resolution marker fixture | 1 case failed, 1 assertion |
| Give the callback a fresh invocation instead of the read's deadline/cancellation | GitInventory + FolderBrowser callback fixtures | 2 cases failed, 6 assertions |
| Omit resolver replacement revalidation | GitInventory callback replacement fixture | 1 case failed, 1 assertion |

Logs: `round12-mutation-main-actor.log`,
`round12-mutation-workspace-revision-2.log`, `round12-mutation-invocation.log`,
`round12-mutation-resolver-revision.log`. The first workspace-revision mutation
left an unused local, which the app's warnings-as-errors build rejected; that
attempt is excluded and the compiling mutation was rerun. All mutations restored.

Adversarial self-review checked both callers, the source-repository override,
callback replacement, revocation/shutdown during suspension, cancellation before
lookup, shorter invocation deadlines, symlink retargeting without revisions and
late worker completions. The main actor handles only immutable string snapshots;
all pending-path mutable state is lock-protected, no lock spans a filesystem call,
and abandoned work cannot publish a trust grant. The 250 ms admission check also
rejects late completions if its timer was delayed by scheduling. No UI was changed.


### Upstream integration

Merged `origin/dev/next` at `f6ac5cfd6937d9cd11eb1db55947c55ef4ade15c`
with a merge commit, preserving both sides. Canonical file-path helpers retain
our equal-specificity trust-denial rule and canonical folder aliases. Watcher
configuration invalidation is combined with upstream's event timestamps and
indexed ignore checks; a configuration change uses an unknown change batch so a
later ignore scan cannot discard it. `FileFolderTests` retains its standalone
resolver setup, inherited-hook ownership test and fsmonitor marker test.
`xcodegen generate --quiet` regenerated the project. Two package fixtures needed
upstream's new watcher callback/timestamp arguments; the initial integrated
build log (`round12-merged-views.log`) records those compile errors, corrected
before final validation. All views security fixtures continue to use `ViewsTestCase`.


### Additional adversarial revision check

Self-review of overlapping requests found that a new workspace revision could
join a path lookup started under an older revision. The pending-work key now
includes the revision as well as the literal path bytes. This also preserves the
64-call bound across revisions: an old blocked call still occupies its slot until
it returns, and new work confines if capacity is unavailable.

A fixture resolves an alias before pausing, retargets it into a trusted parent,
revokes that project's trust, and starts another read before releasing either
lookup. Before the correction, `testNewWorkspaceRevisionDoesNotReusePendingCanonicalPaths`
failed because only one lookup ran instead of the required two
(`round12-revision-coalescing-first.log`: 1 case, 1 failed assertion). With the
revision key, the full native permission class passed **10/10**
(`round12-revision-coalescing-fixed.log`). Removing the revision key again made
the new case fail while the nested byte-boundary control passed
(`round12-mutation-coalescing-revision.log`: 1 passed case, 1 failed case,
1 assertion). Both results remained confined in the mutation run; the regression
specifically detects the incorrect reuse rather than claiming observed program
execution in that additional fixture. The original marker-file revocation test
separately verifies the confinement outcome.

The ongoing native batch was deliberately stopped for this app-only correction;
the owned lock was released and its partial/completed native logs were moved to
`round12-pre-revision-native-*`, excluded from the final totals. All 27 native
classes are rerun on the final app source. The completed views, helper, protocol
and benchmark results remain valid: no package or helper source changed in this
correction, which is checked with `git diff 1caa160f HEAD -- packages`.

### Final merged validation

All final commands ran from the assigned worktree after merging upstream through `f6ac5cfd`. Package/helper/protocol/benchmark checks ran at `1caa160f`; all native checks ran at `9483ea94`. The latter changes only app trust lookup and its native fixture/documentation: `git diff 1caa160f 9483ea94 -- packages` is empty. `$B` below is `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. The final driver, source manifests, exact commands, exit statuses, durations and text logs are retained under `$B/logs/round12-final-*`.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| bello-views | 457 | 4 | 0 |
| Native focused classes (27) | 349 | 1 | 0 |
| Helper (cost class plus remaining suite) | 1181 | 8 | 0 |
| Release-helper wire | 40 | 0 | 0 |
| Release-helper concurrent | 4 | 0 | 0 |
| Release-helper acceptance | 3 | 0 | 0 |

The eight helper skips are opt-in fixture-writing/performance measurements, including the merged image measurement. The views skips are three Finder benchmarks and the inventory benchmark executed separately below. The native commit-browsing benchmark is an opt-in skip; the Git-safety gallery is enabled.

Exact final commands (common environment):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
export CFFIXED_USER_HOME="$PI_BUILD_ROOT/round12-views-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round12-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round12-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round12-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round12-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ReplyFileLinkTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChatFileLinkTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round12-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

The shared full-lane lock covers all native/focus work and each benchmark. Each serial-lane native class runs alone; parallel-capable classes run only in the explicit group. The views and helper suites use their existing dedicated scratch directories; no second DerivedData copy is created.

| Native class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChangesTabTests | 9 | 0 | 0 |
| ChatFileLinkTests | 8 | 0 | 0 |
| CrashAuditRegressionTests | 12 | 0 | 0 |
| FileBlameTests | 12 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FileFolderTests | 21 | 0 | 0 |
| FileReviewStateTests | 24 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| GitChangelistReadTests | 2 | 0 | 0 |
| GitCommitBrowsingTests | 3 | 1 | 0 |
| GitHistoryFilterTests | 14 | 0 | 0 |
| GitHunkReviewTests | 9 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| GitOperationSafetyTests | 12 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRepositoryPermissionTests | 10 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitSafetyGalleryTests | 1 | 0 | 0 |
| GitToolTests | 5 | 0 | 0 |
| GitWorkingTreeWatcherTests | 43 | 0 | 0 |
| QuickOpenTests | 17 | 0 | 0 |
| ReplyFileLinkTests | 5 | 0 | 0 |
| SessionPanelTests | 30 | 0 | 0 |
| WebhookExchangeTests | 5 | 0 | 0 |
| WebhookTests | 18 | 0 | 0 |
| WorkspaceTests | 17 | 0 | 0 |

### Latency after asynchronous trust resolution

Generated fixture: **50,001 regular tracked files and 20 submodules**, 50,021 index entries. Baseline is pinned `origin/dev/next` at `f6ac5cfd6937d9cd11eb1db55947c55ef4ade15c`. Each variant rebuilds the same package scratch directory from clean products, verifies compiler input paths/source hashes, warms up, and records 25 samples per operation. The baseline uses the identical benchmark source and the pre-isolation API flag. Raw samples and source provenance are in `round12-final-perf-*.log` and `round12-final-build-*.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 260.591 / 268.965 | 2183.442 / 2192.964 | — |
| branch | 173.428 / 183.374 | 2067.956 / 2115.205 | -33.45% / -5.29% |
| branch-repeat | 175.365 / 186.375 | 2067.069 / 2110.623 | -32.70% / -5.33% |

Both branch measurements meet the approximately 5% steady-state latency budget. The benchmark measures the complete shared Git status/Changes pipeline; the native blocking-path fixtures separately exercise the app workspace resolver and its main-actor heartbeat. No required suite remains failing. The assigned trust-resolution finding is resolved; incomplete path resolution deliberately selects confinement. No product decision is outstanding.


### Gallery inspection and cleanup

The regenerated safety gallery contains **112 PNGs** in `$B/round12-gallery`.
Inspected `untrusted-light-1180x780.png`, `untrusted-dark-310x600.png`, and
`http-redirect-dark-1180x780.png`: light/dark notices, narrow scrolling and the
existing ellipsis behavior remain intact; no new layout issue was observed.
No UI change was required for this round.

The shared lock was held for benchmark/native runs and released on completion
(and before the app-only follow-up). The final native run held it from
16:35:32 through 16:51:36 +0800. Generated large-repository and exported-baseline
folders were deleted. The last automatic Xcode result was extracted to JSON and
deleted; text logs and gallery PNGs remain. No clone folders remained. Cleanup
left 21,440,000,000 bytes free. No installed app, real preferences, chats,
Keychain or paid provider calls were used.


## Round 13 — Unicode inventory inputs select confinement (2026-10-21)

### Decision and implementation

The P2 review is confirmed. A byte-written NFC `refs/heads/café` in HEAD is a
valid Git symbolic reference. With an `includeIf.onbranch:` directive, the
inventory passes that name back through Foundation's argument conversion,
which decomposes it. The byte-preservation guard formerly threw `Failure`,
bypassing the read fallback.

Keep the existing byte check and select `ConfinementRequired` for every input
it cannot preserve. The eventual status/log/rev-parse command reads HEAD itself
and succeeds in the sandbox, without re-encoding the ref as an argument. NFD,
leading-combining-mark and emoji refs remain unconfined when representable;
NFC also remains unconfined when no onbranch lookup is needed. No new ref-name
resolution code or subprocess is introduced. A failed inventory is not cached.

The same guard now rejects embedded NUL before NSString conversion (which
otherwise raises an Objective-C exception). Redirect override separator errors
also use `ConfinementRequired`; network writes propagate that error and never
launch, so this does not relax redirect protection. Local marker programs do
not run in any matrix case. Global/system program policy is unchanged.

### Failure sweep

All explicit `Failure` throws in `Sources/GitProcessSafety` were inspected.
Repository metadata's invalid UTF-8, malformed include lookups, unsupported
config encodings and generated override controls already select confinement.
Normalized lookup arguments, values, keys and redirect scopes now do likewise.
`GitInventoryMemo` and `GitInventoryCache` rethrow errors without changing their
classification; `GitReadProcess` catches only `ConfinementRequired`.

The remaining hard failures deliberately retain their existing behavior:

| Site | Retained reason |
| --- | --- |
| `GitConfiguration.inventory`: submodule depth/cycle guard | Bounded traversal exceeded; not a text-representation failure. |
| `GitConfiguration.init`: mismatched name/value origin passes | Config changed between queries; do not use a torn inventory. |
| `GitConfiguration.init`: nonzero `ls-files` status | Index/submodule inventory command failed; no normalization conversion occurs here. Invalid UTF-8 in its output already confines. |
| `GitConfiguration.init`: final inventory/stamp comparison | Concurrent config/identity mutation; stop rather than apply partial safety data. |
| `GitConfiguration.query`: output limit | Resource limit; do not restart work after exhausting its allowance. |
| `GitInvocation.check`: deadline | A timed-out read must stop, not restart under confinement. Cancellation stays `CancellationError`. |
| `GitReadProcess.init`: argument limit | Protect Foundation's process argument limit, including final caller arguments. |
| `GitReadProcess.git`: system Git lookup | No safe executable was found; confinement cannot supply one. |

### Failing-first and mutation evidence

Commands use `$B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`
and the existing `views-tests` scratch directory, isolated HOME/config, and
fixture-only marker programs. Exact commands, exit codes and elapsed times are
recorded in `$B/logs/round13-*.json`, with paired text logs.

```
swift test --package-path packages/bello-views --scratch-path "$B/views-tests" --filter 'GitInventoryTests.testUnicodeSymbolicRefsKeepDiscoveryStatusAndHistoryReadable|GitInventoryTests.testInventoryLookupRepresentationErrorsRequireConfinement|GitInventoryTests.testRedirectOverrideRepresentationErrorsRemainClosed'
```

| Check | Executed | Assertion failures | Result |
| --- | ---: | ---: | --- |
| Failing first on production source 403b437b (`failing-first-final`) | 3 | 11 | Expected failure: NFC discovery/status/history; lookup/redirect error classifications; NUL exception. |
| Fixed (`fixed`) | 3 | 0 | Pass. |
| Restore hard normalization error (`mutation-normalization`) | 2 | 8 | Expected failure. |
| Remove pre-conversion NUL guard (`mutation-nul`) | 1 | 1 | Expected failure: Foundation exception. |
| Restore hard redirect separator error (`mutation-redirect`) | 1 | 1 | Expected failure. |

The branch matrix covers four byte spellings (NFC café, NFD café, leading
U+0301 and a woman-technologist emoji with ZWJ), with and without an onbranch
include. It compares HEAD's exact bytes to real Git output, checks the selected
executable, runs status/log, then tests GitService discovery/status/history.
The lookup table covers ref, include path, config key, config value and NUL
inputs. Redirect cases cover an equals sign, NFC scope and invalid literal
newline config; the last is rejected during inventory before override creation.

Two preliminary fixture runs were corrected before the final failing-first
run: the expected root initially used /var rather than Git's /private/var;
the newline config case initially expected rejection only in redirectOptions
although Git already rejects it during inventory. Those preliminary assertion
counts are not used as regression evidence. All mutations were restored.

### Integration and final validation

Merged `origin/dev/next` at `a515d752bc25305301c0346ae2879d4078f7950c`
with merge commit `4bc3245874e3c093bd4a764cdc996ea2c5fcf24e`; no rebase or
upstream write. The merge was clean and retained both NEXT entries, the
workspace2 changes, the asynchronous/revision-checked Git trust resolver,
`FileFolderTests.setUp` / `testFixtureOwnsInheritedHooks` / fsmonitor fixture,
and all ViewsTestCase bases. `xcodegen generate --quiet` completed.

### Adversarial self-review

- Checked the complete production diff against 403b437b: two exception
  classifications and one early NUL guard, with no permission widening,
  subprocess changes, config parser emulation or cache retention changes.
- Traced both paths from the shared guard. Inventory/override representation
  failures reach GitReadProcess's specific confinement catch; it does not catch
  cancellation, deadline or consistency failures. Network redirect inventory
  errors propagate before `Process.run`, so invalid scopes cannot fall back to
  unprotected network execution.
- Confirmed exact bytes in the NFC fixture originate in HEAD, not a normalized
  Process argument. Git's `symbolic-ref --no-recurse HEAD` verifies those bytes.
  Both read executables and the service outputs are checked, and the local
  marker file remains absent. Representable cases explicitly assert `git`,
  guarding against a blanket sandbox workaround.
- Checked invalid UTF-8 output and metadata guards, inactive include-path
  probes, generated override encoders, cache error propagation and all eight
  retained Failure sites. The NUL test independently detects the pre-conversion
  exception; it is not treated as an ordinary Swift error.
- Checked that a failed cold inventory publishes no cached value and that the
  normal cached-read path gains no subprocess. Normal-case performance is
  remeasured below. Existing nonrecursive submodule, static-config, trust
  revision and redirect/header protections are unchanged.
- Compared merge inputs: the only WorkspaceModel addition is upstream's
  run-action admission state. The package, Git trust worker, permission tests
  and FileFolder fixtures were unchanged by integration. Four upstream
  workspace test classes are included in the native rerun for integration
  coverage, in addition to the Git/trust/file/webhook classes.

No additional in-scope defect was found. Evidence for the diff/throw-site and
source-restoration checks is `$B/logs/round13-adversarial-review.json`.
Final fresh suite results follow below.

### Final merged validation

All final commands ran freshly from the assigned worktree at merged commit `4bc3245874e3c093bd4a764cdc996ea2c5fcf24e`, incorporating upstream through `a515d752`. Only this validation record changed during the runs. `$B` below is `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security`. The final driver, source manifests, exact commands, exit statuses, durations and text logs are retained under `$B/logs/round13-final-*`.

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| bello-views | 460 | 4 | 0 |
| Native focused classes (31) | 512 | 1 | 0 |
| Helper (cost class plus remaining suite) | 1181 | 8 | 0 |
| Release-helper wire | 40 | 0 | 0 |
| Release-helper concurrent | 4 | 0 | 0 |
| Release-helper acceptance | 3 | 0 | 0 |

The eight helper skips are opt-in fixture-writing/performance measurements, including the merged image measurement. The views skips are three Finder benchmarks and the inventory benchmark executed separately below. The native commit-browsing benchmark is an opt-in skip; the Git-safety gallery is enabled.

Exact final commands (common environment):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security
export CFFIXED_USER_HOME="$PI_BUILD_ROOT/round13-views-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TEST_RUNNER_GIT_CONFIG_GLOBAL=/dev/null TEST_RUNNER_GIT_CONFIG_NOSYSTEM=1
swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests
python3 scripts/build-bundle.py
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-tests --skip-build --skip StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/swift-host/arm64-apple-macosx/release/pi-native-host
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round13-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round13-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round13-baseline/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
BELLO_GIT_INVENTORY_BENCHMARK=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round13-large-fixture BELLO_GIT_BENCHMARK_SAMPLES=25 swift test --package-path /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-security/packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/views-tests --filter GitInventoryPerformanceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookExchangeTests -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositoryPermissionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WebhookTests
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitToolTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileBlameTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFindTabTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CrashAuditRegressionTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ReplyFileLinkTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChatFileLinkTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarSideClickTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceConcurrencyTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests
TEST_RUNNER_PI_APP_GIT_SAFETY_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-security/round13-gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitSafetyGalleryTests
```

The shared full-lane lock covers all native/focus work and each benchmark. Each serial-lane native class runs alone; parallel-capable classes run only in the explicit group. The views and helper suites use their existing dedicated scratch directories; no second DerivedData copy is created.

| Native class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChangesTabTests | 9 | 0 | 0 |
| ChatFileLinkTests | 8 | 0 | 0 |
| CrashAuditRegressionTests | 12 | 0 | 0 |
| FileBlameTests | 12 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FileFolderTests | 21 | 0 | 0 |
| FileReviewStateTests | 24 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| GitChangelistReadTests | 2 | 0 | 0 |
| GitCommitBrowsingTests | 3 | 1 | 0 |
| GitHistoryFilterTests | 14 | 0 | 0 |
| GitHunkReviewTests | 9 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| GitOperationSafetyTests | 12 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRepositoryPermissionTests | 10 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitSafetyGalleryTests | 1 | 0 | 0 |
| GitToolTests | 5 | 0 | 0 |
| GitWorkingTreeWatcherTests | 43 | 0 | 0 |
| QuickOpenTests | 17 | 0 | 0 |
| ReplyFileLinkTests | 5 | 0 | 0 |
| SessionPanelTests | 30 | 0 | 0 |
| SidebarSideClickTests | 5 | 0 | 0 |
| SubmissionPersistenceTests | 81 | 0 | 0 |
| WebhookExchangeTests | 5 | 0 | 0 |
| WebhookTests | 18 | 0 | 0 |
| WorkspaceConcurrencyTests | 12 | 0 | 0 |
| WorkspaceRaceTests | 65 | 0 | 0 |
| WorkspaceTests | 17 | 0 | 0 |

### Latency after representation fallback

Generated fixture: **50,001 regular tracked files and 20 submodules**, 50,021 index entries. Baseline is pinned `origin/dev/next` at `a515d752bc25305301c0346ae2879d4078f7950c`. Each variant rebuilds the same package scratch directory from clean products, verifies compiler input paths/source hashes, warms up, and records 25 samples per operation. The baseline uses the identical benchmark source and the pre-isolation API flag. Raw samples and source provenance are in `round13-final-perf-*.log` and `round13-final-build-*.json`.

| Variant | Status median / p95 (ms) | Changes median / p95 (ms) | Median change vs baseline (status / Changes) |
| --- | ---: | ---: | ---: |
| baseline | 263.384 / 271.620 | 2181.754 / 2195.437 | — |
| branch | 174.337 / 186.799 | 2079.763 / 2119.279 | -33.81% / -4.67% |
| branch-repeat | 174.868 / 185.031 | 2074.211 / 2106.644 | -33.61% / -4.93% |

Both branch measurements meet the approximately 5% steady-state latency budget. The benchmark measures the complete shared Git status/Changes pipeline; the native blocking-path fixtures separately exercise the app workspace resolver and its main-actor heartbeat. No required suite remains failing. The assigned Unicode-ref finding is resolved; inventory inputs that cannot be represented byte-for-byte deliberately select confinement. No product decision is outstanding.


### Gallery inspection and cleanup

The regenerated safety gallery contains **112 PNGs** in `$B/round13-gallery`.
Inspected `untrusted-light-1180x780.png`, `untrusted-dark-310x600.png`, and
`http-redirect-dark-1180x780.png`: light/dark trust and redirect notices,
narrow scrolling and existing ellipsis behavior remain intact. No new layout
issue was observed; no UI change was required for this round.

The shared lock covered benchmark/native/focus work from 17:41:31 through
18:05:11 +0800 and was released on completion. Generated large-repository and
exported-baseline folders were deleted. The last automatic Xcode result was
extracted to JSON and deleted; text logs, source provenance and gallery PNGs
remain. No clone folders remained. Cleanup left 21,332,209,664 bytes free.
No installed app, real preferences, chats, Keychain or paid provider calls were
used. The final source remains the tested merged commit; only release and validation
documentation changed after validation.
