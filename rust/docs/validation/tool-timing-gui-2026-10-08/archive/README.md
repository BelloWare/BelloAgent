# A5 generated GUI concurrency fixture

This package prepares a fresh numeric-loopback Responses + MCP server and bounded
generated Bash commands. It does **not** launch BelloAgent, trust a project,
inject a transcript, touch native credentials, change the frozen A5 source or
claim GUI acceptance. Linux's supported saved Editing route offers Bash, ls and
MCP; native write/edit is deliberately not offered on Linux.

## Setup and launch

Use a sealed **debug synthetic-authority** App build whose exact integrated
source was independently verified. Server and App must run in the **same cloud
computer/network namespace**. Do not assume another host's loopback is reachable.
All files must be generated under a new explicitly selected directory.

```sh
fixture=/workspace/shared/a5-gui-fixture
qa=/workspace/shared/a5-gui-fixture/run-001
python3 "$fixture/fixture.py" init --root "$qa" --port 47891 --hold-seconds 90
python3 "$fixture/fixture.py" seal --root "$qa" --binary /ABS/VERIFIED/BUILT/BELLO_AGENT_BINARY
python3 "$fixture/fixture.py" serve --root "$qa" > "$qa/evidence/server.log" 2>&1 &
server_pid=$!
# Stop only this recorded server PID when acceptance is finished.
python3 "$fixture/fixture.py" status --root "$qa"

# Root/operator chooses its already verified cloud DISPLAY explicitly.
DISPLAY="$VERIFIED_CLOUD_DISPLAY" bash "$fixture/launch.sh" "$qa" /workspace/shared/build-recovery/gui-runtime-env.sh
```

Initialization refuses an existing directory. It creates UUID-profile metadata,
project-only text, isolated HOME/XDG/TMP directories and `mcp-config.json`; it
never starts services. Seal copies the supplied binary and records/rechecks its
SHA-256. The launch script only runs when explicitly executed, verifies the copy,
sets isolated paths and unsets proxies. It does not pass `--native-authority`,
legacy `--profile`, real credentials or unsupported flags. The underlying launch
is exactly:

```sh
SEALED_BINARY --synthetic-connections --synthetic-attachment-fixture "$qa/profile.json" --project "$qa/project" --session "$qa/state/session.json"
```

The existing debug fixture route saves a connection named **Synthetic attachment
fixture** with fixed fake key `synthetic-project-fixture-only`. It requires a UUID,
numeric-loopback endpoint and declared text+image inputs. No actual image is sent.
It does **not** trust the project, select the saved connection or save MCP config.

### Verified keyboard route and pointer limitation

Source audit found no opening shortcut/tab-stop for Projects, the saved-connection
pill or MCP Inspector. Their launcher controls are click-only. A reliable pointer
activation is required to open these three surfaces; Ctrl+P is a file picker,
not a command palette. There is no supported MCP config CLI seed. Do not inject
authority or patch production gates to work around pointer failure.

Once each surface is open, keyboard paths are source-verified but remain subject
to visible focus/state checks during actual GUI acceptance:

1. Open Projects with its folder control. On a fresh project with no extras,
   Tab, Enter activates Create Project…; after the draft reset, Tab ×3, Enter
   activates Create Project after the trust warning. Wait for Trusted, Escape.
2. Open the No saved connection composer pill. Enter selects the seeded first
   connection; Up/Down navigate, Escape cancels. Wait for selection to settle.
   Ordinary new chats retain the source's Editing default; do not infer it from
   text or manually seed a mode.
3. Send `A5_HELLO` through the normal composer to materialize a genuine saved chat.
   Receipt must show a provider request and **zero** MCP calls.
4. Open MCP. From initial root focus, Tab ×2 focuses the configuration editor.
   Paste the exact generated `mcp-config.json`, naming server **fixture**.
5. For its one server, from configuration editor Tab ×4 reaches masked header
   input: Review and save → Reload saved → fixture header selector → masked input.
   Enter `{"X-Fixture":"synthetic-header-fixture-only"}` there, never in general
   configuration JSON. Ctrl+S opens review; Shift+Tab selects Trust, save and
   apply; Enter. Verify saved/applied state and masked header presence, Escape.
6. Composer regains prior focus. Enter sends, Shift+Enter inserts a newline.
   **Ctrl+. stops** the active response. Ctrl+Enter is steering, not Stop.

These routes were inspected in `main.rs`, `attachment_fixture.rs`,
`project_manager_view.rs`, `connection_settings_controller.rs`,
`mcp_inspector_view.rs` and `saved_runtime_adapter.rs` from the preserved source.
Synthetic authority is memory-only: restarting the App loses that authority and
cannot count as native persistent-vault acceptance. Closing/reopening the same
chat/controller within the process remains meaningful.

## Deterministic acceptance modes

Each explicit mode sends exactly two calls in original order:
`a5-rNNNN-bash`, then `a5-rNNNN-mcp`. The model never decides arbitrary commands.
The generated Bash only writes markers inside that run's project subdirectory.
MCP initializes/discovers normally and invokes one allowlisted tool `held`.

Use status to discover the actual run ID rather than assuming a number:

```sh
python3 "$fixture/fixture.py" status --root "$qa"
python3 "$fixture/fixture.py" release --root "$qa" --run r0001 --target bash
python3 "$fixture/fixture.py" release --root "$qa" --run r0001 --target mcp
```

Release refuses until **both** the local Bash-entry marker and actual MCP
tools/call receipt exist. All holds expire after 90 seconds; Bash timeout is
95 seconds, output is below 1 KiB, and MCP's configured timeout is 100 seconds.
If a hold expires, record an incomplete acceptance run and use a new explicit
mode; do not call it a concurrency pass.

### A5_FORWARD: first card completes while the other waits

Send exactly `A5_FORWARD`. Wait for `both_entered: true`; save a screenshot of both
in-progress cards and the server receipt. Release **bash only**. Wait for its
client-visible completed card while MCP remains held; capture it. Then release
MCP. The following model request must have the original two IDs in order, and
status must report `result_order_correct: true`. Save the final response and
inspect the client's durable rows. Do not infer durable retention from a server
response attempt or from the Bash marker written just before process exit.

### A5_REVERSE: reverse completion, original model-result order

Send `A5_REVERSE`. Wait for both entries, then release **mcp only**. Its response
receipt should precede Bash completion. Bash stays running until its separate
release. Release Bash; the subsequent model request must still contain Bash→MCP
result IDs. The fixture explicitly flags reversed client result order.

Current Rust immediate live-terminal publication is Bash-specific. Non-Bash
terminal cards remain absent until whole-batch durable retention; Swift 0.1.121
ends each card independently. This A5 candidate is backend concurrency, not full
visual parity. A completed MCP network response is not proof that its client
card has updated or its receipt was retained. Batch wall-time/cumulative-tool-time
accounting is also absent in Rust and deferred; no duration or speedup is claimed.
Record actual GUI observations, and see NEXT-UI-SLICE.md for concrete follow-on
hooks and acceptance requirements.

### A5_STOP: truthful Unknown and no historical replay

Send `A5_STOP`, wait for both entries, then press Ctrl+.; do not release either
call beforehand. The generated Bash ignores TERM and requires the client's
owned escalation/reaping path, but is still bounded by its fixture deadline.
Verify truthful interrupted/Unknown outcomes and retained user draft/history.
The server may observe MCP socket closure; that proves only peer disconnection.

Wait for the actual client to settle, then close/reopen the saved chat using its
normal same-process flow. Send `A5_AFTER_STOP`. It answers without offering new
effects, regardless of historical result rows. Verify `mcp_calls` for the stopped
run remains exactly one, no new run was created and no duplicate-call receipt
appears. If the client tries replay, the fixture rejects it and records the event;
rejection is a detection control, not a passing no-replay result.

Client physical ownership must be established from the sealed client's behavior
and existing deterministic lifecycle tests (retirement cannot release its session
writer or receipt lease before physical work ends). Server `mcp-peer-closed`,
`mcp-response-attempt`, local shell `bash-finished`, or a server-side timeout
cannot independently prove client joining, durable retention or native reaping.

## Evidence, safety bounds and selftests

`evidence/receipts.jsonl` records structural facts and IDs only, never headers,
credentials, arbitrary prompts or result bodies. `state/fixture-state.json`
retains run counts so restarting the fixture cannot silently erase duplicate-call
evidence. At most twelve explicit runs, sixteen HTTP handler threads, 2 MiB per
request and an 8 MiB receipt log are permitted. No redirects/proxies/outbound
requests are implemented; control uses direct numeric-loopback HTTP only.

Keep original CUA screenshot bytes, App log, fixture receipts, saved client state,
fixture source manifest and sealed source/binary hashes together. No screenshots
or interactive acceptance have been produced by this fixture-preparation task.

```sh
cd /workspace/shared/a5-gui-fixture
python3 -m py_compile fixture.py test_fixture.py
bash -n launch.sh
python3 test_fixture.py
```

Selftests exercise fixed authentication, no authority inference, before-both-entry
release rejection, true mixed Bash/MCP overlap, forward/reverse release, ordered
and deliberately reversed provider results, duplicate detection, simulated Stop,
state reload, bounded expiry/output, body/control bounds and binary sealing.
They execute only generated shell commands and direct loopback protocol clients;
they are not BelloAgent GUI or client-lifecycle acceptance.
