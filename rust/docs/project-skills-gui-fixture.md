# Project-only skill picker: generated GUI acceptance recipe

This is a recipe, not an executed GUI acceptance report. Use the normal saved
connection/project/chat route with explicit synthetic authority. The ordinary
native startup/signing/Keychain gates remain unchanged. Do not use real files,
credentials, owner accounts, paid services, or the owner's computer.

## Prepare without opening a desktop

From the repository root, with a new disposable root:

```sh
python3 rust/fixtures/skills_workflow_fixture.py init \
  --root /workspace/shared/agent-skills-gui-fixture --port 47887
python3 rust/fixtures/test_skills_workflow_fixture.py
bash -n rust/fixtures/launch_skills_gui.sh
```

Initialization refuses any existing root. It creates:

- Two `/review` descriptors at different canonical paths, `a-review` and
  `b-review`, with explicit-only policy and distinct generated body markers
- One inspectable `unavailable` skill whose invalid policy must fail closed
- Project-only `AGENTS.md`, no home skills or configuration import
- The exact generated one-pixel GIF admitted by the existing Linux attachment
  fixture. This does not claim ImageIO/native image parity
- A saved-connection seed profile with UUID identity, explicit text/image inputs,
  a numeric-loopback endpoint, and no custom headers
- Separate disposable home/config/data/cache/state directories and chooser portal
  descriptors based on the existing accepted cloud fixture
- A generated baseline manifest, screenshots directory, request evidence directory,
  and mutation/checkpoint evidence destinations

The generator never starts a provider, opens a desktop, installs dependencies,
automatically trusts a project, or sends a message. The gateway never makes an
outbound request. Five headless tests cover generated identity/overwrite refusal,
body-only versus policy mutation, structural request observations, controlled
failure/hold/tool responses with header-free logging, and binary/source sealing.

## Freeze the build before GUI work

After final source/tests are settled, build the debug app with
`--features synthetic-authority` using the assigned warm target and one build job.
Do not use a cold target or overlap another owner's heavy link. Then:

```sh
python3 rust/fixtures/skills_workflow_fixture.py seal \
  --root /workspace/shared/agent-skills-gui-fixture \
  --binary /path/to/final/debug/bello-agent \
  --source-root /workspace/shared/agent-skills-stage \
  --source-id 'verified base commit plus final source-manifest identity'
```

`seal` copies the binary to a SHA-named read-only executable under `bin/` and
records its exact SHA-256, source-file hashes (including Cargo manifests/lock,
fixtures, and branding asset), generated-source hashes and canonical selection
IDs. The source ID argument is a label supplied by the integrator; it is not
independently verified by the script. Do not seal or launch after a later source
change without rebuilding and recording a new manifest.

## Start only after desktop ownership is assigned

Keep the gateway running separately so request/control state survives an app
restart:

```sh
python3 rust/fixtures/skills_workflow_fixture.py serve \
  --root /workspace/shared/agent-skills-gui-fixture
```

In the assigned cloud desktop's terminal, with `DISPLAY` set for that desktop:

```sh
bash rust/fixtures/launch_skills_gui.sh \
  /workspace/shared/agent-skills-gui-fixture \
  /workspace/shared/agent-skills-gui-fixture/bin/bello-agent-skills-EXACT_SHA_PREFIX \
  /workspace/scratch/8b6fda578834/build-environment
```

The launcher verifies the sealed binary, starts only already provisioned chooser
portals in an isolated D-Bus session, verifies the matching loopback gateway,
sets disposable home/XDG directories, and uses:

```text
--synthetic-connections --synthetic-attachment-fixture PROFILE
--project GENERATED_PROJECT --session GENERATED_STATE/session.json
```

The fixture flag keeps its existing name because it seeds the same normal saved
text/image connection; it is not a separate skill runtime. Select the saved
fixture connection and trust/select the generated project through the app UI.
Synthetic authority is deliberately in-memory; after a process restart, repeat
any required UI trust/connection selection rather than treating it as native
persistent authority. Do not pass a real key or use the legacy `--profile` route.

## Deterministic provider controls

Use numeric loopback directly with proxying disabled. `/status` reports request
count, queued actions and held request IDs. Controls act on subsequent requests,
never by parsing a user slash command:

```sh
curl --noproxy '*' http://127.0.0.1:47887/status
curl --noproxy '*' -H 'Content-Type: application/json' \
  -d '{"enqueue":[{"mode":"hold","seconds":120}]}' \
  http://127.0.0.1:47887/control
curl --noproxy '*' -H 'Content-Type: application/json' \
  -d '{"release":"all"}' http://127.0.0.1:47887/control
```

Modes: `complete` (default), `fail` (503), `hold` (partial output until release),
`tool` (one real `ls` call), `hold-tool` (release into one `ls` call), and `large`
(generated answer text for useful compaction). Holds have an explicit 1–300-second
safety ceiling, logged if reached. Queue at most 32 controls. Release a specific
numeric request ID instead of `all` when testing simultaneous chats. Tool controls
refuse to fabricate `ls` when the request does not actually expose it. Follow-on
tool requests default to an ordinary answer unless another control was queued.

## Required observed cases

Capture each screen/action sequence and pair it with actual request/checkpoint
facts. A planned case, a simulated GPUI test, and a real GUI observation are
separate evidence categories.

1. Open Skills, inspect the failed-policy entry, filter, and select both `/review`
   entries by their visible canonical paths. Edit literal arguments separately,
   Cancel once, save once, remove/re-add a chip, and confirm order. No provider
   request may occur from these actions. Check keyboard Tab/Enter/Escape and the
   920×600 minimum layout.
2. Send a skill-only turn. Verify raw display text remains empty, recorded uses
   retain ordered IDs/hashes/arguments, and provider content contains expansions
   before the selection-ID line. Ordinary Copy must copy only raw typed text.
   Paste `/review` in a later turn with no selected chips; it must stay text.
3. Select a skill plus `fixtures/generated.gif`. Verify ordered expanded text then
   image in the exact provider request and retained user content. Use only this
   generated image on Linux; other image processors remain a native gate.
4. Put an ordinary response on `hold`. Queue a selected alpha skill, then perform
   the body-only mutation below after queue acceptance. Release the active
   response. The queued request must retain `SKILL_ALPHA_BODY_V1` and its original
   hashes while current resource discovery can observe V2. Do not reselect it.
5. Repeat with a queued selection and then a policy mutation. Release. The queue
   must pause with captured input intact and no request for that pending item.
   Inspect the queued details. Begin a text edit, verify ordinary draft chips are
   parked, Cancel, then save an empty rewrite when the queued skill remains.
   Remove the revoked pending item explicitly; restoring a file is not reselecting.
6. Deliver a beta-selected turn with `hold`, then Stop. Delete beta only after its
   user content was delivered. Retry must replay retained bytes without opening
   that source and without adding another user row. Inspect after reopen, repeating
   required synthetic trust through the normal UI.
7. Refresh discovery and switch chats while the real loading state is visible.
   A late result may update the originating background catalog, never select in or
   focus the new chat. If the small fixture finishes before navigation, do not
   report this race as GUI-executed; deterministic GPUI coverage is separate.
8. Idle Context includes explicitly selected draft expansions and literal
   arguments without sending/checkpoint mutation. Edit a chip after preparation:
   the inspector must retain its captured snapshot and Copy that immutable JSON
   until explicit Refresh. Active Context excludes new draft/queued selections.
9. Generate sufficient older ordinary history with `large`, then selected inputs
   and steering through `hold-tool`. Compact via the UI. Compare pre/post user
   rows and provider replay: protected selected-input carriers keep their order,
   original selection metadata, retained expansions, and actual task roots.
   A summary never becomes a new explicit selection.

Generated-source changes are limited to known fixture paths and recorded with
before/after hashes:

```sh
python3 rust/fixtures/skills_workflow_fixture.py mutate --root ROOT --skill alpha --change body
python3 rust/fixtures/skills_workflow_fixture.py mutate --root ROOT --skill alpha --change policy
python3 rust/fixtures/skills_workflow_fixture.py mutate --root ROOT --skill beta --change delete
python3 rust/fixtures/skills_workflow_fixture.py mutate --root ROOT --skill alpha --change restore
```

`body` changes only the post-frontmatter body marker to V2; metadata bytes remain
unchanged. `policy` deliberately changes the policy to an invalid type, requiring
Needs attention/fail-closed behavior. `delete` removes that generated `SKILL.md`.
`restore` restores the generated V1 source and explicit policy.

## Evidence and truthful completion

`evidence/requests.jsonl` has structural facts, hashes, request IDs and lifecycle
outcomes; it never records headers, credentials, image payloads or raw captions.
`evidence/requests/request-NNNN.json` contains exact bounded request bodies for
this generated fixture only. Selection-line IDs and body markers in those files
are text observations, not proof of authorization; compare them with recorded
skill metadata and task-root provenance in the checkpoints.

After stopping or at each important boundary:

```sh
python3 rust/fixtures/skills_workflow_fixture.py inspect --root ROOT
```

The command hashes actual state JSON, reports snapshot/catalog versions, pending
and receipt counts, and recorded user selection/content facts. Original
checkpoints remain in `state/`; exact requests remain in the evidence directory.
Save numbered screenshots under `evidence/screenshots/`, record the exact
click/keyboard sequence, and retain gateway/control/mutation logs. Never replace
an uncertain outcome with an assumed success.

Describe validated scope as project-only picker-selected skills through the
normal saved-runtime path with synthetic authority. This fixture does not prove
production enablement, owner-Mac UI/VoiceOver/IME/sheet ownership, implicit-loading
parity, native authentication/signing, or unexecuted GUI cases.
