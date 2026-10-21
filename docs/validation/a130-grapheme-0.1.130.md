# Grapheme-boundary paths and credentials · 0.1.130

Workstream: `dev/a130-grapheme`, based on `f80e83cb` (dev/next).
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-grapheme`.
Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-grapheme`
(text logs under `evidence/`).

Swift `String` operations work on extended grapheme clusters. An ASCII delimiter
followed by a combining mark (U+0301), ZWJ (U+200D) or variation selector
(U+FE0F) is one `Character`, so `hasPrefix`, `contains`, `firstIndex(of:)`,
`split` and `dropFirst(count)` disagree with the filesystem, Git and the byte
maskers. This branch fixes GRAPHEME-1, GRAPHEME-3 and GRAPHEME-6 from the hunt
report. `packages/bello-views` is untouched (another workstream owns it).

## Decisions and boundaries

- Credential detection and path containment now find the delimiter as a byte.
  The previous `String` comparison is kept only as an additional match
  (canonically equivalent spellings), so nothing matched before stops matching:
  credential detection, journal-scope checks and project ownership can only
  match more, never less.
- Ownership compares canonical paths (`FileTab.key(for:)`, standardized and
  symlink-resolved). Measured on this Mac: Foundation's file-URL
  canonicalization yields the decomposed form, and the on-disk case for
  existing paths, on both sides of every ownership comparison, so the byte
  comparison is exact. The closest owning root is chosen by UTF-8 length.
- `FileProjectState.none` stays readable ("outside any project"): the fix is
  that a file in an untrusted root is no longer mistaken for one outside every
  project.
- No owner decision was needed. No wire schema, capture mode, permission,
  vault, UI layout or visible copy changed; gallery regeneration is not
  applicable. No installed app, real preferences, chats, Keychain, credentials
  or paid provider was used; fixtures are generated temporary files, Git
  repositories, in-memory vaults and a loopback Python gateway.

## GRAPHEME-1 — confirmed and fixed (credential boundary)

Trace confirmed. `CaptureCredentials.contains` used `String.contains`
(non-literal matching): `"sk-fixture-secret=\u{301}".contains("sk-fixture-secret=")`
is false (also for U+FE0F). For U+200D the answer depends on the string's
storage: false for a native Swift string, true for an NSString-bridged one.
Routing admission (`RoutingIdentity.add`), `metadataText`, `metadata`,
request/response header capture and the gateway telemetry all go through it.

Fix (`CaptureCredentials.swift`):

- `contains` searches the UTF-8 bytes of each configured credential (precomputed
  `literals`), then keeps the old `String` match as an extra.
- Sweep, same file: the Authorization scheme split now ends at the first space
  byte (a key beginning with a combining mark joined that space into one
  Character, so the whole `"Bearer <key>"` became the credential and the bare key
  was neither hashed in request bodies nor masked in responses or metadata);
  sensitive header-name parts split at `-` bytes (`x-secret-\u{301}v` lost its
  `secret` part).
- Reviewed, unchanged: `ResponseMasker` and `requestBody` were already byte
  based; `masked(_:)` only shows a suffix of a configured token (no matching);
  `comparableModel` and the routing-contract header checks only refuse or
  conflict; `Providers.safeFailure` reuses the byte-based `requestBody`.
- URLSession decodes response header bytes as Latin-1 (`=` then `U+00CC U+0081`,
  measured with a loopback server), so a header echo cannot end inside a cluster
  end to end; header paths are covered at unit level.

Regressions (`CredentialCaptureTests`):

- `testGatewayModelEchoEndingInsideAGraphemeClusterIsMaskedInEveryCaptureSurface`:
  a generated loopback gateway echoes the key `sk-fixture-secret=` plus U+0301,
  U+200D or U+FE0F as `response.model` and `router_model_name`, in raw and
  `\u`-escaped JSON, streamed (SSE) and not, in memory and persist modes (24
  variants) through the real `ProviderClient`. Byte searches for the key cover
  the reply's journal `providerIdentity`, `latest`, `debug.list`, `debug.attempt`,
  `identity`, `monitoring`, raw events, request/response bodies and every emitted
  packet (decoded byte pages included). Identity must be `incomplete` with no
  effective model; the body masker's redaction count stays positive.
- `testMetadataSanitizersFindCredentialsEndingInsideAGraphemeCluster`
  (`metadataText`, keyed usage metadata, response headers, routing head/body
  evidence; canonical-equivalence control),
  `testAuthorizationSchemeEndsAtItsSpaceByteBeforeACombiningMark`,
  `testSensitiveHeaderNamePartsEndAtHyphenBytes`.

## GRAPHEME-3 — confirmed and fixed (trust boundary)

Trace confirmed for both paths. With trusted `/proj` and untrusted
`/proj/private`, `hasPrefix("/proj/private/")` fails for
`/proj/private/\u{301}secret.swift`, so the reply resolver and
`projectID(holding:)` picked trusted `/proj`, and the file opened readable.
Without a trusted ancestor (the Files panel symlink case), the canonical opener
found no owner and assigned `.none`, also readable. Files directly in a trusted
root or a second root with such names also lost their project.

Fix: `apps/macos/PiApp/Files/CanonicalPath.swift` (one shared predicate:
`relative(_:in:)`, `isWithin`, `isBelow`), used by:

- `ReplyFileResolver` (owner search; a leading `/` byte is absolute, so
  `"/\u{301}x"` no longer resolves to the chat project's `\u{301}x`),
- `WorkspaceModel.projectID(holding:)` (the canonical opener: chat links,
  Quick Open, Files panel, Changes "Open File"), `openFile(fromChat:)`'s
  absolute check and `containingFolderRoot`,
- sweep: Quick Open recents, file history eligibility/repository-relative path
  and nested-repository choice (`FileReviewState`), blame's working-tree check
  and relative path (`FileBlame`), and Show Change's project folder
  (`WorkspaceChanges`). Before, these refused (failed closed) or lost the file.

Reviewed, unchanged (refusal or display only, no ownership decision):
skill path labels (`SkillDetails`), activity short paths
(`TranscriptActivity`), the tab header's home abbreviation (`FileTabViews`),
branch-rename prefill (`GitRepositoryTools`), absolute-path validation of
project folders, saved recents and fixture/diagnostic environment paths
(`WorkspaceFolders`, `FileRecentState.read`, `ContextDiagnostics`,
`LaunchFixtureVault`, `PerformanceProbe`), UUID result folders
(`MCPInvocationResult`), endpoint validation (`ConfigurationVault`, the user's
own setting) and the reply resolver's `:line` suffix (a missed suffix refuses).

Regressions:

- `ReplyFileLinkTests.testNestedTrustHoldsNamesThatBeginWithACombiningMark`
  (U+0301/U+200D/U+FE0F; relative, `:line` and absolute spellings refused under
  the untrusted nested project; positive control; absolute-link misdirect).
- `ChatFileLinkTests.testANameThatBeginsWithACombiningMarkStaysInTheProjectHoldingIt`
  (canonical opener: nested untrusted, untrusted root without a trusted
  ancestor, own root, second root, folder-tree root, absolute misdirect).
- `SessionPanelTests.testFilesSymlinkToANameThatBeginsWithACombiningMarkKeepsTheDestinationsTrust`
  (the panel-symlink test repeated for U+0301 and U+200D targets through
  pointer, Return and accessibility: unreadable, no document, untrusted reason).
- `FileReviewStateTests.testHistoryFindsNamesThatBeginWithACombiningMark`,
  `FileReviewStateTests.testRecentsKeepNamesThatBeginWithACombiningMark`,
  `FileBlameTests.testAFileWhoseNameBeginsWithACombiningMarkIsInItsWorkingTree`,
  `FileBlameTests.testShowChangeFindsAProjectFolderWhoseNameBeginsWithACombiningMark`.
  The blame test asserts only the app's working-tree decision; blame output
  parsing for such names is bello-views' (see Not fixed).

## GRAPHEME-6 — confirmed and fixed (helper search paths)

Trace confirmed: `within` used `hasPrefix(root + "/")` and the formatter
`dropFirst(root.path.count + 1)`, so `grep`/`find` named
`/proj/\u{301}dir/a.txt` as `a.txt`, and a following `read("a.txt")` read
another file. While reproducing it, a second cause on the same line appeared:
`FileManager`'s enumerator names files below the root's real path
(`/private/var/...`, `/private/tmp/...`, on-disk Unicode form), while
`canonical()` drops `/private` (and decomposes). Every nested file under a
`/var`, `/tmp` or `/etc` root was therefore reported by its bare name too.

Fix: `Support.swift` adds byte-based `relativePath(_:in:)`; `within` accepts
byte containment or the old comparison. `grep`/`find` cut relative paths as
bytes from `realpath(root)` (one call per search), then the canonical root,
then the old last-component fallback. `FileToolContext.path` treats a leading
`/` byte as absolute (`"/\u{301}x"` read the workspace's `\u{301}x`).

Other helper path checks reviewed, unchanged: `read`/`write`/`edit`/`ls` resolve
through `FileToolContext.path` (fixed above) and have no containment check;
`bash` runs in the fixed `cwd`; the `.git`/`node_modules`/`.build` skip compares
URL last components exactly; `~` + mark is not a home path (as in pi);
`workspaceRoots` refuses `/`+mark roots as not absolute (fails closed); the MCP
command's `/` check only searches `PATH`; `ToolOutputOwnership.directory` only
receives identity-validated IDs; the journal-scope `within` callers compare
canonical paths; endpoint validation is the user's own setting.

Regressions (`NativeToolTests`):
`testSearchResultsNameFilesBelowDirectoriesThatBeginWithACombiningMark` (plain,
U+0301, U+200D, U+FE0F directories; absolute and `.` search roots; the returned
path reads the matching file; `find` by bare and directory glob),
`testAnAbsolutePathWhoseFirstNameBeginsWithACombiningMarkIsNotReadFromTheWorkspace`,
`testPathContainmentComparesBytesAtTheSeparator` (including root `/`, where the
old inline cut dropped the first character of every name, and the
canonical-equivalence control).

## Test reliability note

Plain `async` XCTest methods in the helper package can lose assertion failures
recorded after an `await` resumes on another thread: a probe with 40 failing
assertions recorded 34; the same probe as `@MainActor` recorded 40 in 3/3 runs.
The first failing-first run of the loopback test (then not `@MainActor`)
recorded 20–22 of 24 failing variants across reruns although every variant
leaked. The new async helper tests are `@MainActor`. Existing non-isolated
async tests may under-report; not changed here (needs a separate decision).

## Failing first

Unmodified production code, new tests only:

| Suite | Result | Log |
| --- | --- | --- |
| Helper (7 new; the `relativePath` unit test needs the new helper and was set aside) | 6 tests, 6 failed, 293 failures: all 24 loopback variants × 9 surfaces kept the key; the scheme, header-part and absolute-path cases failed; grep/find reported `a.txt` for the plain and every marked row (the plain row from the `/private` cause) and read returned `other` | `failing-first-helper-final.log` (an earlier draft of the search test: `failing-first-helper.log`) |
| `ReplyFileLinkTests` | 5 tests, 1 failed (9 failures: each mark × relative, `:line`, absolute spelling resolved inside the untrusted nested project) | `failing-first-app-ReplyFileLinkTests.log` |
| `ChatFileLinkTests` new test | 36 failures: nested file owned by trusted `w` and read; untrusted root's file had no project and was read; own/second-root files had no project or folder root; `/`+mark opened the project's copy | `failing-first-app-ChatFileLinkTests-*.log` |
| `SessionPanelTests` new test | 30 failures: every route × mark opened the target with project `nil`/`.none`, readable, with a `FileDocument` | `failing-first-app-SessionPanelTests-*.log` |
| `FileReviewStateTests` new tests | history: 0 repository reads, no Changes tab; recents: `[]` | `failing-first-app-FileReviewStateTests-*.log` |
| `FileBlameTests` new tests | blame: "This file is outside its repository's working tree."; Show Change: "This file's repository is not one of ́app's folders." | `failing-first-app-FileBlameTests-*.log` |

The reply resolver's absolute-link assertion passed before the fix only
because the ownership bug failed closed for a marked file directly in the root;
mutation AM2 shows the absolute check is required once ownership is fixed.

## Mutations

Each mutation was applied by a script that always restores the file.

| Mutation | Tests | Result | Log |
| --- | --- | --- | --- |
| M1 `contains` String-only | 2 capture tests | detected, 237 failures | `mutation-M1-contains-string-only.log` |
| M2 scheme split at Character space | Authorization test | detected, 18 failures | `mutation-M2-authorization-character-space.log` |
| M3 header parts split by Character | header test | detected, 3 failures | `mutation-M3-sensitive-header-character-split.log` |
| M4 Character `hasPrefix`/`dropFirst` on the real-path base | search test | detected, 24 failures, marked rows only (plain passes) | `mutation-M4-relative-character-dropFirst.log` |
| M5 no `realpath` base | search test | detected, 32 failures incl. the plain row | `mutation-M5-no-realpath-base.log` |
| M6 `hasPrefix("/")` absolute check | absolute-path test | detected, 3 failures | `mutation-M6-absolute-hasPrefix.log` |
| M7 `within` without bytes | containment test | detected, 3 failures | `mutation-M7-within-character-only.log` |
| AM1 `CanonicalPath.relative` without its byte branch | `ReplyFileLinkTests` | detected, 9 failures | `mutation-AM1-core-character-only-ReplyFileLinkTests.log` |
| AM2 reply resolver `hasPrefix("/")` | `ReplyFileLinkTests` | detected, 3 failures (absolute misdirect) | `mutation-AM2-reply-absolute-hasPrefix-ReplyFileLinkTests.log` |
| AM3 `projectID(holding:)` Character prefix | ChatFileLink and panel-symlink tests | detected, 33 and 30 failures (trusted parent owns, or no owner and readable) | `mutation-AM3-*.log` |
| AM4 chat-link `hasPrefix("/")` + Character `containingFolderRoot` | ChatFileLink test | detected, 9 failures: folder root (lines 261, 263) and absolute misdirect (265) separately | `mutation-AM4-*.log` |
| AM5 Character recents root + history eligibility | recents and history tests | detected, 1 and 2 failures | `mutation-AM5-*.log` |
| AM6 Character nested-repository check | history test | detected, 3 failures: nested history routed to the enclosing repository | `mutation-AM6-*.log` |
| AM7 Character blame working tree + Show Change folder | both FileBlame tests | detected, 1 and 2 failures | `mutation-AM7-*.log` |

## Restored validation

| Suite | Command | Result |
| --- | --- | --- |
| New helper tests | `swift test … --filter <7 tests>` | 7/7 passed (`fixed-helper-focused-final.log`) |
| Full helper suite | `swift build --package-path packages/swift-host --scratch-path <root>/swift-verify --build-tests`; `swift test … --skip-build --skip StreamingCostTests` | 1169 tests, 7 skipped, 0 failures (`helper-full-suite.log`) |
| Wire | `python3 scripts/test-native-host.py <root>/swift-host/arm64-apple-macosx/release/pi-native-host` (helper from `scripts/build-bundle.py`) | 40 OK |
| Concurrent | `python3 scripts/test-concurrent-native-host.py <helper>` | 4 OK |
| Acceptance | `python3 scripts/test-native-acceptance.py <helper>` | 3 OK |
| Parallel-lane app classes | `scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/{ReplyFileLinkTests,FileTabTests,GitCommitBrowsingTests,TranscriptActionsForwardingTests,TranscriptNativeRowParityTests,SidebarFlatTopicsTests,SidebarRecencyTests}` | 89 tests, 3 skipped, 0 failures (`fixed-app-parallel.log`): 5, 17, 4 (1 skipped), 3, 26 (2 skipped), 30, 4 |
| Serial-lane app classes, each alone under the full-lane lock | `scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/<Class>` | ChatFileLinkTests 8, SessionPanelTests 30, FileReviewStateTests 23, FileBlameTests 12, QuickOpenTests 17, FileFolderTests 20, ChangesTabTests 9, FileFindTabTests 16, GitBranchesInteractionTests 20, TabPaneTests 10, AppControlAccessibilityTests 6, SidebarAppearanceTests 6, WorkspaceSplitTests 10: 187 tests, 0 failures (`fixed-app-<Class>.log`) |

The covering classes are every PiAppTests class that calls the changed
functions. Gallery/screenshot classes that only skip without their environment
variable were not run; nothing visual changed. `PI_BUILD_ROOT` was the build
root above for every run; xcodegen regenerated the project for the new file.
After the mutation runs, the tracked diff was compared with a saved snapshot
(identical), and the final helper rebuild reran the seven new helper tests.

## Not fixed (reported)

- `packages/bello-views`: `FileBreadcrumb.contains` (FileFinder) used the same
  Character prefix for the folder-tree anchor; already fixed on
  `dev/a130-security` (`gitHasPrefix`). Blame output parsing for such names is
  also bello-views'.
- Async helper tests losing assertion failures: handed to a separate workstream.
- A tab opened for a file that does not exist yet keeps the ownership computed
  then; case is only canonicalized for existing paths, so a different-case
  spelling of an untrusted folder can be owned by its trusted parent until the
  tab is reopened. Pre-existing, case-only, outside the grapheme class.

## Round 2 — provider-echoed metadata (2026-10-21)

Accepted from round 1's report. `RequestObservation.consume` kept the
provider's `response.model`/`router_model_name` as `effectiveModel` and
`response.id` as `responseID` unmasked. The session publishes the observation
in every snapshot (`requestObservation`, `lastRequestObservation`,
`contextState.currentRequest`/`lastRequest`), and the Inspector reads it for its
context reading (`countedModel`) and "returned …". A gateway echoing the key
there, plainly or with an extender, put it in the Inspector.

Fix:

- `RequestObservation.consume(_:streaming:at:credentials:)` masks the id and
  model with the request's `CaptureCredentials.metadataText` (the byte matching
  from round 1) before the 512-character bound can cut a key apart;
  `ProviderClient` passes the request's credentials at both call sites. A
  credential-bearing model stays reported, as `[sha256:…]`.
- `ProviderClient.safeFailure`: `providerMessage`, which only pi's retry and
  overflow rules read, now masks credentials with same-length asterisks through
  `ResponseMasker` (escaped spellings too) instead of the display fingerprint.
  Found while testing: a fingerprint's hex can spell a status pi retries (this
  fixture key's digest contains `500`), so an auth failure that echoed the key
  was retried three times (2, 4 and 8 s) where pi stops at once. The shown
  message keeps its fingerprint.

Sweep of provider-echoed and response-derived strings that reach the
Inspector, request/capture metadata, exports, notices or errors:

| Value | Where it goes | Status |
| --- | --- | --- |
| Response model, router model, response id (live observation) | snapshots → Inspector context reading, "returned …" | fixed |
| Routing evidence, effective/reported models, contract reference, requested alias | capture metadata, journal `providerIdentity`, Reports, menu-bar activity, turn reports | masked (round-1 bytes) |
| Response/request headers and header names; gateway call id, version, cost and cache sources | capture metadata | masked or refused |
| Raw usage keys and values | capture metadata | masked; replies keep numbers only (`PiContext.usage`); accounting keeps numbers and helper statuses |
| SSE event names; request URL | raw events; capture metadata | masked; fingerprinted when holding a credential |
| HTTP error bodies, failed streams, incomplete reasons, malformed streams | errors, notices, retry notices | `safeFailure` (fingerprint shown, asterisks classified); connection tests show helper text only; transport errors are helper text |
| Request/response bodies, raw events | request log, Inspector Raw/Response, exports | byte maskers |
| Compaction diagnostics | errors | allowlisted fields only |
| Monitoring feed | snapshots | allowlist without model or id; masked telemetry |

Unreachable or not metadata (unchanged): `SessionRun`'s second
incomplete-reason check and `stopReason` see only `max_output_tokens` with
`ProviderClient`, which throws other reasons inside `complete()` through
`safeFailure`. Reply text, reasoning, tool arguments, generated titles and webhook text, and
"Provider item: <type> (opaque)" labels are model output, shown as content by
design. Provider item
ids and encrypted reasoning stay byte-exact for replay and are not shown as
metadata. Catalog model ids are configuration the user picks in Settings
(discovery errors are already fixed text). The observation's `requestedModel`
is the configured alias.

Regressions:

- `CredentialCaptureTests.testRequestObservationsAndErrorsNeverCarryAnEchoedCredential`:
  loopback gateway; streamed, JSON, failed-stream and HTTP 401 responses ×
  plain, U+0301, U+200D, U+FE0F; every `RequestObservation` the session would
  receive (`json` and `monitoring`), the reply's identity, the error's message
  and `providerMessage`, packets and the capture list.
- `CredentialCaptureTests.testAChatPublishesAndPersistsNoEchoedCredential`:
  through `AgentSession`; running and final snapshots, context state, inspected
  context, every file in the chat's state folder, packets.
- `CredentialCaptureTests.testMaskedProviderTextDecidesRetriesAsTheUnmaskedTextWould`.
- `CaptureMacIntegrationTests.testPackagedHelperKeepsEchoedCredentialsOutOfInspectorStateCaptureAndExports`:
  the packaged helper through `WorkspaceModel` (streamed and HTTP 401 × the four
  spellings); snapshots, `SessionDisplay.observeContext` footer state,
  `RequestContextObservation` details and reading, request-log metadata
  (Export Metadata's text), `exportRetained` trace folders, and every file
  under the app's state folder after shutdown.

Failing first, with the round-2 production changes removed:

| Suite | Result | Log |
| --- | --- | --- |
| Helper loopback and chat tests | 2 tests, 9053 failures: every streamed, JSON and failed-stream observation (plain and each extender) held the key; chat snapshots and context state held it; failed and HTTP 401 chats retried three times (116 s) | `r2-failing-first-helper.log` |
| Retry classification test | 5 failures: four retried auth texts, one kept escaped spelling | `r2-failing-first-retry.log` |
| App packaged-helper test | 24 failures, all streamed variants: snapshot, context state, last request, its "returned …" text and context reading; HTTP errors, request log, Export Metadata text, exported traces and kept files were already clean | `r2-failing-first-app-*.log` |

Round-2 mutations (helper mutations ran on a copy of `packages/swift-host`
with its own scratch path, so a queued app run could not build a mutated
helper):

| Mutation | Tests | Result | Log |
| --- | --- | --- | --- |
| R2-M1 effective model unmasked | helper loopback and chat tests | detected, 64 failures | `mutation-R2-M1-model-unmasked.log` |
| R2-M2 response id unmasked | helper loopback and chat tests | detected, 44 failures | `mutation-R2-M2-response-id-unmasked.log` |
| R2-M3 streamed observations consumed without the request's credentials | helper loopback and chat tests | detected, 56 failures | `mutation-R2-M3-stream-call-without-credentials.log` |
| R2-M4 classifier text masked with fingerprints again | retry classification test | detected, 5 failures | `mutation-R2-M4-classifier-fingerprint.log` |

Round-2 validation:

| Suite | Result |
| --- | --- |
| New and related helper classes (`CredentialCaptureTests`, `RequestObservationTests`, `FailurePresentationTests`, `PiParityTests`, `ContextScopeTests`) | 28, 3, 8, 29, 3 tests; 0 failures (`r2-fixed-helper-focused.log`) |
| Full helper suite (`swift test … --skip StreamingCostTests`) | 1172 tests, 7 skipped, 0 failures (`r2-helper-full-suite.log`) |
| Wire / concurrent / acceptance (Release helper from `scripts/build-bundle.py`) | 40 / 4 / 3 OK (`r2-test-native-host.log`, `r2-test-concurrent-native-host.log`, `r2-test-native-acceptance.log`) |
| `CaptureMacIntegrationTests` (serial, alone under the lock; includes the new packaged-helper test) | 3 tests, 0 failures (`r2-fixed-app-CaptureMacIntegrationTests.log`) |
| Parallel-lane Inspector/capture/context classes, one `test-macos.sh` run | 164 tests, 0 failures (`r2-fixed-app-parallel.log`): AutomaticContextTests 11, ContextAndSkillPolicyTests 12, ContextScopeTests 9, DashboardTests 19, GatewayAccountingTests 25, MenuBarMetricsTests 29, PayloadArchiveTests 40, ReportDocumentGeometryTests 3, RequestContextObservationTests 4, RoutingConfigurationTests 2, TraceArchiveTests 10 |
| Serial-lane classes, each alone under the lock | 154 tests, 5 skipped, 0 failures (`r2-fixed-app-<Class>.log`): CaptureDrainTests 7, TurnAccountingTests 13, ConnectionSwitchJournalTests 6, InspectorStorageTests 44 (2 skipped), MessageDetailTests 9, LivePopupTests 15, MonitorParityTests 3, SessionStatsPopoverTests 8 (1 skipped), ReportPageTests 33, WireContractTests 11 (1 skipped), StreamedReplyEndTests 5 (1 skipped) |

The covering app classes are those that read the observation, context state,
`countedModel`, capture metadata or exports, plus the packaged-helper gateway
classes. The app test's own failing-first run (round-2 production changes
removed) is its mutation evidence; the helper mutations isolate each change.
No app source changed in round 2.
