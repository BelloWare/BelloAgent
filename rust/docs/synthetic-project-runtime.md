# Synthetic project runtime and instruction delivery

This is an explicit `synthetic-authority` validation path. It joins saved-project
identity, current memory-only authority, an explicitly saved chat mode, instruction
resources and the real Controller/provider/tool loop. There is no app caller or
UI switch. Production constructors, default authority and tool options are
unchanged. Native Keychain/signing interaction and external provider access are
not part of this path.

## Binding and admission

`SyntheticProjectRuntime::confirm` accepts a synthetic storage control, never an
arbitrary native adapter. It requires the catalog's existing SavedProject UUID,
original primary root, current authority envelope and trusted project. The original `open_chat` requires an explicitly saved ReadOnly record; the separate
`open_editing_chat` requires a saved Editing record without changing it. Both
require exact journal identity,
explicit fixture home/capabilities, and matching instruction roots. Archived,
unbound, moved, untrusted or changed records are refused. The fixture host uses
a fixed fake credential and rejects custom headers.

Each confirmation owns a revocable generation handle. Full authority/catalog
checks occur outside the actor mutex; cheap atomic generation checks fence the
actual admission boundary. Failed confirmation is sticky for that controller.
There is no duplicate host registry: existing owners retire and join controllers
before reopening the same writer. Already admitted reads can settle truthfully;
revocation prevents new admission and continuation. Owners use existing Stop and
retirement for cancellation/join. This is point-in-time confirmation, not a
filesystem sandbox or an atomic lease against another authority writer.

Fixture endpoints must be numeric loopback addresses. The synthetic HTTP client
explicitly disables environment proxies and redirects; the ordinary client is
unchanged. No process home, Codex settings or skill catalog is inferred.

Existing-only journal opening holds the writer lock, validates regular files
through nonblocking descriptors, bounds the checkpoint read, and rejects an
unexpected ID before migration, stream replay, synchronization or recovery
writes. Missing files are not created. The ordinary open/materialization path
retains its existing semantics. Shared inspection opens are nonblocking on
Linux/macOS so a replaced FIFO cannot strand a read before type validation.

## Source resource lifetimes

The source references are `Resources.swift`, `SessionQueue.swift`,
`SessionRun.swift` and `SessionContext.swift`. Only explicitly supplied fixture
instruction paths/settings are used. Skills remain empty and unsupported;
submission schema is unchanged. Prompt framing, the untrusted-data warning,
stable selection policy and empty-catalog revision match the source subset.

Resources resolve before a queued input is committed as delivered. Preparation
runs outside the actor through the bounded blocking executor, then rechecks the
exact candidate, payload, edit hold, Stop/retirement and admission generation.
An unrelated appended input does not invalidate the captured candidate. Errors
preserve pending/retry input and make no provider request. Resume/Retry cannot
start a duplicate worker while preparation is reserved.

A successful delivery installs an in-memory applied snapshot after its
checkpoint succeeds. Active tool continuations and same-controller Retry use
that snapshot. A later delivery refreshes it; a reopened controller resolves
fresh resources before Retry. Nothing stores a complete resource snapshot in a
queued submission or journal. Steering uses its captured batch identity;
late arrivals wait for a later boundary. If steering preparation fails,
completed tool results are still recorded truthfully and input remains pending.

The read-only snapshot getter supports verification. There is no context
Inspector UI, request token-count claim, selected-skill expansion or production
resource discovery in this checkpoint.

## Validation boundary

Focused Linux tests exercise real disposable loopback requests and ls results,
source instruction precedence/framing/revisions, retry/reopen lifetimes,
Stop/edit/retirement/preparation races, stale authority and generations, default
disabled behavior, and journal identity/type failures. Separate subprocess tests
bound FIFO rejection and prove that a configured local proxy receives no
synthetic request. Existing recovery, inspection and tool lifecycle regressions
remain part of the affected check set. Exact macOS CI and production native
interaction are distinct gates; no new desktop acceptance is claimed.


## Explicit write/edit validation path

The later write/edit checkpoint adds only `open_editing_chat` to this synthetic
host. Main 0.1.121 runs these calls concurrently across controllers, retaining
pre-effect trust/catalog checks and bounded physical worker ownership even if
the caller is dropped. There is no workspace or same-file mutation lock.
Public read-only tool constructors still reject mutation capabilities. Paths
remain resolution context, not a sandbox. Defaults and production composition are
unchanged; Linux actual file mutations exist only in cfg(test) temporary adapters.
See [write/edit contracts](native-edit-contract.md) for source limits, the connected
2 MiB argument safety bound, v5 receipts, outcome/recovery and card limitations.
