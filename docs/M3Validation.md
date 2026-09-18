# M3 — Skills and instruction compatibility

Validated on macOS 14.8 / arm64 with the pinned Pi 0.85.1 and Node 24.21.0.
M0–M2's provider, persistence and raw-capture checks continue to pass.

## Automated evidence

- 88 host tests pass, including nine new discovery/policy/Pi integration cases.
- 18 native tests pass, including direct command origin, quoted/code/history
  rejection, structured hash/argument persistence, keyboard completion and IME.
- TypeScript strict type checking passes. Native compilation uses Swift 6.
- Both real Pi adapters receive one frozen explicit expansion and one resolved
  instruction chain through a tool round trip. Changing AGENTS in the fixture
  tool leaves the current loop unchanged; the next submitted turn gets a new
  resource revision. A later quoted slash example grants no new skill.
- A queued skill is disabled before execution: no second HTTP request occurs,
  remaining work pauses, and the original command intent stays recoverable with
  a visible resource preflight error. The source SKILL.md is unchanged.
- Fixtures cover duplicate names, reserved names, symlink aliases/cycles,
  linked-worktree `.git` files, no-repository cwd-only discovery, unreadable
  higher-priority guidance, empty overrides, fallbacks, canonical instruction
  deduplication, a UTF-8 boundary, file/depth limits, malformed YAML/TOML, custom
  tags/aliases, conflicting policy, changed selection hashes and missing MCP tools.

## Native application walkthrough

The app's Discovery Settings selected a separate synthetic Codex home. The
instruction inspector showed global then project guidance, 145 of 32768 source
bytes, canonical paths and both hashes. No Git root was present; only the chosen
working directory supplied project guidance.

The native picker showed `m3-check` as Explicit only. A separate skill declaring
`mcp:synthetic-unavailable` displayed that dependency and disabled Select for Draft.
Typing `/m3-check` directly and pressing Tab created a chip with its canonical
path and content hash; an empty composer with that chip could be submitted.

A read-only Pi models.json reference routed the turn to the loopback fixture.
The completed request's native exact-body inspector showed global guidance,
project guidance and `M3_NATIVE_EXPLICIT_SOURCE` each once. The explicit-only
skill's discovery description was absent. Its recorded grant matched the chip.

- Session: `ED675B53-34F1-43B3-A0D8-86371A935C4D`
- Turn: `6A2065BF-07BA-4F81-9007-D3CDC150131F`
- HTTP attempt: `40edee3f-a777-427d-9b78-b0ad34eb5d91`
- Resource revision:
  `feadec4865d8651c873f8b70819520a7c692026ca29423297754f7ce86f355eb`
- Request: 9730 retained/observed bytes, full SHA-256
  `24ae7e66da55cdf50720e9ce942f84069b37acc20f809cf2115f45f53aedd58f`
- Response: 22410 retained/observed bytes, full SHA-256
  `a3a6eddb26e276fe26f6afff467542f6df9c7192194eceba16094efc8a2ca7a8`

The walkthrough found a stale inspector selection after changing the discovery
home. Refresh now resets a removed selection, reloads the selected source after
an explicit refresh, and labels missing dependencies directly in catalog rows.
Slash suggestion accessibility preserves individual button labels in a group.
Resource-only hosts also enter the configured idle-unload grace when the
inspector closes; source inspection alone does not keep a workspace alive forever.

## Explicit compatibility decisions

See [Compatibility.md](Compatibility.md) for the exact public Pi seams and
discovery limits. The app never uses a second Pi autodiscovery path. Files are
read in place, with one instruction chain supplied through the resource loader.
YAML/TOML parsing is bounded and does not evaluate scripts or shell expressions.

Source changes do not mutate an active turn. Queued explicit skill content stays
frozen, while restrictions are checked again before execution. Fresh instruction
discovery occurs at the next turn boundary. Persistent history records earlier
grants; it cannot create new grants. Pasted and restored slash-looking text stays
plain text unless the user explicitly chooses a picker item or types a new
leading slash. Built-ins reserve `/side`, `/debug` and `/compact`; conflicting
skill names remain available by canonical picker selection.

M4 still must implement independent side snapshots and their resource/tool
policy. M5 still must complete product-wide acceptance, performance,
accessibility and the final signed release/update proof.
