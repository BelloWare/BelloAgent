# Connections workflow validation — 2026-10-07

This evidence covers the explicitly synthetic, tools-disabled Connections slice
in [the workflow contract](../../connection-settings.md). It is not production
Keychain/signing, native macOS interaction or complete Swift Settings acceptance.

## Exact candidate

Rust 1.99.0, Linux debug app, `synthetic-authority` feature. Binary SHA256:
`fb7b194157070851a0018f1a38e2603b10ead9b68953a9ca7443bfe27a12b942`.

The [110-input Rust/Cargo manifest](source-sha256.txt) has SHA256
`35f458dcc838ad25e19faab176d75240f7caef6824a5809774e0fca4b663815f`.
Production source matches the frozen app used for the successful build and actual
desktop run. The manifest also covers tests; two integration-fixture expressions
received formatting-only changes afterward, followed by their focused suite.
Unregistered future Read-tool source is excluded.
Screenshots are original JPEG captures; no pixels were altered.

## Automated gates

- Complete default workspace: 669 passed, one existing manual benchmark ignored
  (340 app + 228 core unit + 101 core integration tests).
- Complete synthetic app: 397 passed, one existing manual benchmark ignored.
- Complete synthetic core: 292 unit + 101 integration tests passed.
- Strict all-target default workspace and synthetic app/core Clippy passed;
  default core Clippy, synthetic app all-target check, formatting and build passed.
- 34 focused Connections app tests: 19 view and 15 integrated coordinator cases.
  The core has 25 new owned vault/configuration/loopback regressions; catalog v6
  adds five connection-identity cases plus updated existing version fixtures.

Reviews found and repaired macro/import, delayed editor acknowledgment, stale
configuration confirmation, immutable synthetic-resource provenance, secret-bearing
metadata, legacy route inheritance, post-write switch recovery, late loader,
Pin/materialization, and close-before-dirty-notification issues. The delayed-edit
negative control failed before repair and passed after it. New deterministic
regressions cover the identified identity/lifecycle races rather than relaxing
assertions. Broad app tests also caught a new selector overflowing a narrow split
pane; bounded labels and toolbar wrapping fixed it with reachability checks intact.

The integrated deletion fixtures perform actual loopback requests: one completed
response, a stalled second stream, accepted queued input, explicit deletion or
injected definite Conflict, observed socket closure/retirement, disconnected durable
history/queue recovery, real queue-detail/removal, and same-ID explicit reselection.
Exactly two requests occur through those sequences; no implicit queued replay.

Exact published-commit Linux/macOS CI is a subsequent gate, not inferred from these
local results. Both workflows explicitly run the new core suites; Linux additionally
executes Connections GPUI tests. The macOS job compiles all app test targets while
native permissions, Keychain and IME remain separately gated.

## Actual Linux desktop workflow

The immutable candidate ran in the cloud Linux desktop with Mesa software Vulkan,
1180×812 app content, isolated fixture project/config/data directories, the existing
numeric-loopback gateway and fixed fake key. No paid or external provider was used.

1. Opened Settings from the existing sidebar button. Entered `fixture a` and only
   the fixed synthetic key. Done asked about unsaved edits; Keep Editing retained
   both fields. Save All closed Settings and produced zero gateway POST requests.
2. New Chat took the newly saved route. An explicit `fixture one` submission
   streamed a real fixture response, producing the first and only POST so far.
3. Reopened Settings: the saved key replacement field was blank, not revealed.
   Edited the first name, opened a second tab, filled its fixed key, and switched
   back and forth. Each tab retained its independent unsaved edits.
4. Set the second model to `second-fixture`. Save All saved both tabs; the current
   chat retained its first route and complete history. No additional POST occurred.
5. Opened the Connection picker and selected the second route with Down/Enter.
   The catalog persisted its explicit ID in v6 and the UI changed model. History
   remained; selecting did not send or replay it.
6. Changed the saved second model to `third-fixture` with blank key/header fields.
   Save created a third connection, retained the original second route, and left
   the visible fork explanation. [Actual fork result](04-route-fork-retains-original.jpg).
7. Explicitly selected the third route, then submitted `fixture two`. The second
   fixture response completed. Durable user/assistant models were, in order,
   `local-test-fixture`, `local-test-fixture`, `third-fixture`, `third-fixture`.
8. Typed `retain draft` without submitting. Reviewed Delete's consequences and
   explicitly deleted only the current synthetic fork. Settings returned to two
   saved connections; the current chat became disconnected without losing its
   four durable messages or composer text. [Actual disconnected result](05-deleted-route-retains-history-draft.jpg).
9. Closed the app normally with Ctrl-W. The draft remained in the catalog, app log
   was empty, and the gateway still showed exactly two POST requests, both from
   the explicit submissions above. The fixture gateway was stopped on app exit.

## Limits

This manual pass used ASCII native key input; native paste/type-text support was
unavailable, and interactive Unicode/IME was not verified. Some immediate captures
showed the previous frame; a subsequent screenshot verified the new presentation.
No input-to-photon, hardware rendering or native accessibility claim is inferred.
Manual deletion was idle; actual active-stream cancellation and queued recovery
are covered by the distinct loopback integration tests described above.

The synthetic vault is memory-only. Restart loses fixture connections while
retained catalog IDs remain unavailable, never silently rebound. The coarse shared
editor memory limits and unsupported workflow sections are documented separately.
