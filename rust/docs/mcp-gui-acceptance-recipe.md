# MCP immutable cloud GUI acceptance recipe

Use only the copied immutable candidate whose source and SHA-256 manifest were
verified before launch. Do not run a mutable Cargo output path during acceptance.
No Mac, real credentials, external endpoint, paid service or native vault is used.

This is the broader repeatable recipe. The exact executed final scope and omitted
manual variations are recorded in [the acceptance report](validation/mcp-2026-10-07/README.md).
Do not infer that every item below was repeated on every candidate.

## Launch

Create a disposable directory with `home`, `config`, `data`, `project`, and `evidence`
subdirectories. Put a harmless `fixture.txt` inside the project. Source the existing
cloud `build-environment/gui-env.sh` in the desktop terminal, then set isolated
`HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `DISPLAY=:0`,
`BELLO_TEST_APPEARANCE=light`, and `BELLO_TEST_WINDOW_SIZE=1180x840`; unset
`WAYLAND_DISPLAY`. Keep launch scripts in `/workspace` because shell and desktop
have separate `/tmp` namespaces.

Run the bundled fixture in the same cloud computer:

```sh
python3 rust/fixtures/mcp_project_gateway.py --port 47881 --log "$qa/records.jsonl"
"$qa/bello-agent-mcp-immutable" --synthetic-connections \
  --project "$qa/project" --session "$qa/data/session.json"
```

Use a shell trap to stop only this fixture's PID afterward. The gateway binds
`127.0.0.1`, makes no outbound connections, and logs only sanitized method/count/
boolean facts. Preserve original CUA screenshot bytes and a source/binary manifest.

## Fresh ordinary-chat vertical

1. In Connections save one explicit fixture profile:
   - URL `http://127.0.0.1:47881`, model `local-test-fixture`
   - API key `synthetic-project-fixture-only`
   - context 32000, output budget 4096
2. Save/trust the current project through Projects; explicitly select the saved
   connection. These steps should leave the gateway request count at zero.
3. Send `hello fixture` once to materialize a genuine saved chat. Its existing
   ordinary-chat mode remains Editing; no mode/catalog seed is needed.
4. Open MCP. Verify original project UUID/path and the fixture/native-unavailable
   notices. Edit this header-free configuration in the general editor:

```json
{"servers":{"fixture":{"transport":"http","url":"http://127.0.0.1:47881/mcp","allowedTools":["echo","uncertain","slow"],"timeoutSeconds":10}}}
```

5. Select `fixture` under masked header replacements and enter:
   `{"X-Fixture":"synthetic-header-fixture-only"}`. Verify only masks appear.
   Cancel the trust question once, close with Keep Draft, and reopen. The exact
   draft should remain; no MCP request should have appeared.
6. Review and confirm Trust, Save and Apply. Listing servers is metadata only;
   explicitly List Tools, select `echo`, then Describe Selected. The gateway must
   show initialize/initialized/tools-list but zero tools-call.
7. Enter `{"text":"one shot"}`. Cancel Invoke Once once; calls remain zero.
   Confirm once, including a repeated-click attempt. Verify exactly one tools-call,
   bounded readable result and no unknown warning. Close/reopen Inspector.
8. From the composer send `mcp fixture invoke`. Verify the actual model-driven
   `mcp` tool card, durable tool result and provider continuation. This must use
   the saved factory/runtime, not injected transcript rows. Then inspect Context
   to check truthful tool-result replay without generating another call.
9. After a completed response, edit the saved connection's model to `second-fixture`,
   save the forked route, explicitly select it for the same saved chat, and send
   `after reopen fixture`. Verify the same chat ID/history, an immediate provider
   response on `second-fixture`, and no silently paused empty queue. This exercises
   completed-chat retirement/reopen against the repaired candidate.
10. Select `uncertain`, confirm one invocation, and observe the project-wide unknown
   warning. Closing/reopening the Inspector and changing chats must not replay it.
   Attempt another Invoke: it must stay blocked. Cancel acknowledgment once, then
   explicitly acknowledge after inspecting the gateway call count. No request is
   sent by acknowledgment.
11. Select `slow`, invoke, then Cancel Operation. Verify a settled honest unknown
    warning and no automatic retry. Preserve a composer draft and another unsent
    chat during this matrix.
12. Change a configuration draft while a model response or queued message remains
    active: save must refuse before changing the vault. After work is truly idle,
    explicit save must work. Header replacement blank must preserve values; `{}`
    must clear them, confirmed via the gateway's boolean-only header check.

## Separate saved ReadOnly control case

The normal source defaults are Editing, so only this supplemental case may use a
reviewed synthetic ReadOnly saved record. Do not seed MCP configuration or tool
results. Open that genuine record in the same saved-runtime route, inspect its
ReadOnly label, and verify Invoke is disabled while discovery works. Cancel Enable
Editing once and verify it stays ReadOnly. Confirm the source-backed question,
verify its mode changes only after close/persist/reopen, and ensure the same chat
ID, composer draft and history survive. Send `after editing fixture` and verify an
immediate provider response after the completed chat was retired/reopened, rather
than a silently paused queue. Only then explicitly invoke a tool.

Synthetic authority is deliberately memory-only. UI Close/reopen and Controller
reopen are meaningful here; restarting the whole process cannot be presented as
native persistent-credential acceptance.
