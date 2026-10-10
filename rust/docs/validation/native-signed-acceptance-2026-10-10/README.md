# Signed native-authority acceptance (2026-10-10)

The first run of the Rust app's native Keychain vault under the approved
signing identity, on this Mac (macOS 14.8, Apple M3 Max VM), with the owner's
approval for exactly this: a local Developer ID signature and one test Keychain
item for the Rust app only, holding a fake key, deleted afterwards. Nothing was
notarized or published; the Swift app's Keychain items were never read.

## Build and signature

```sh
cargo build --locked --release -p bello-agent-app --features native-authority
# Bello Agent Rust.app/Contents/{Info.plist (packaging/macos/Info.plist.in), MacOS/bello-agent}
codesign --force --sign <Developer ID Application, team 43TXHV3TM3> \
  --options runtime --timestamp=none "Bello Agent Rust.app"
codesign --verify -R='anchor apple generic and identifier "com.belloware.BelloAgentRust" and certificate leaf[subject.OU] = "43TXHV3TM3" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "Bello Agent Rust.app"
```

Signed with no key-access prompt; `Identifier=com.belloware.BelloAgentRust`,
`TeamIdentifier=43TXHV3TM3`, hardened runtime; valid on disk, satisfies its
designated requirement and the exact requirement the vault checks
(`packaging/macos/native-authority-identity.json`). Not timestamped, not
notarized (Gatekeeper would refuse it on another Mac).

## Run

`bello-agent --native-authority --project <scratch> --session <scratch>` with a
loopback gateway (`harness/benchgw.py`, port 47911) as the endpoint.

| Step | Result |
|---|---|
| Launch, vault read with no item | no prompt; "No connection" (`screens/01`) |
| New connection: loopback URL, fake key, `bench-model` | key field masked while typed (`02`) |
| Save All | login-keychain generic password `com.belloware.BelloAgentRust.configuration` / `vault-v1` created; `~/Library/Application Support/com.belloware.BelloAgentRust/configuration.lock` (0600, empty); no SecurityAgent prompt |
| Quit and relaunch | "Connections · 1 saved", read back with no prompt; the saved key is not shown (`03`) |
| Choose the connection in the composer's picker | **failed before the fix below**; after it, the chat asked for project trust as designed |
| Create Project (trust) | "Trusted · Rust Keychain vault", no prompt (`04`) |
| Choose the connection again | "Next turn uses the selected saved connection…" (`05`) |
| Send "Hello from the signed app" | the reply streamed from the loopback endpoint through the saved connection, Markdown drawn (`06`); stopped with Stop |

Cleanup: the test item was deleted (`security delete-generic-password`, then
confirmed absent) and the support folder (holding only the empty lock) removed.

## Found and fixed

In native mode, choosing a connection in the composer's picker did nothing and
left the picker up: `select_connection` asks `advance_navigation`, whose project
gate counts an open picker as a blocking project action, so every choice made in
the picker was dropped. Tests called `select_connection` with the picker closed
and never met the gate. The picker now closes first
(`connection_settings_controller.rs`), and
`native_mode_choosing_in_the_picker_binds_the_connection` chooses through the
open picker by pointer and by keyboard.

## Not covered

Locked or denied Keychain states, a second user, IME and VoiceOver in the
secure field, Connections editing beyond one save, connection deletion, tools
(still unavailable in native mode), notarization and Gatekeeper on a clean Mac.
Two presentation nits: the "Next turn uses…" notice is drawn in the error
banner's red, and the connection chip shows the connection's id, not its name.
