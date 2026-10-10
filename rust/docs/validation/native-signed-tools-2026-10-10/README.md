# Tools in the signed native app: acceptance (2026-10-10)

The signed native-authority app ran the project's tools through its own
Keychain vault, on this Mac (macOS 14.8), with the owner's approval for exactly
this: a local Developer ID signature (team 43TXHV3TM3, bundle
`com.belloware.BelloAgentRust`), one test Keychain item for the Rust app only
holding a fake key, deleted afterwards, and read/write/edit/bash in a scratch
project against a loopback fake provider. Nothing was notarized or published;
the Swift app's Keychain items were never read; tools touched only the scratch
project.

## Build

`cargo build --locked --release -p bello-agent-app --features native-authority`
at `45586fda`, bundled and signed as in `native-signed-acceptance-2026-10-10`
(hardened runtime, not timestamped); the vault's exact code requirement was
satisfied. Binary SHA-256 `8ff004d9184c1d70e199d1fe9afd272b0b944f28ba7303eba1271990851fa6aa`.
Launched as `bello-agent --native-authority --project <scratch>/project
--session <scratch>/state/session.json`, so the workspace and chats stayed in
the scratch folder. Provider: `../tools-gui-macos-2026-10-10/tools-gateway.py`
on 127.0.0.1:47921 (fixed tool calls by keyword; nothing left the Mac).

## Steps and results

| Step | Result |
|---|---|
| Settings → new connection: name, loopback URL, fake key (masked), model `tools-fixture`; Save All | the test item `com.belloware.BelloAgentRust.configuration` / `vault-v1` created with its lock file; no Keychain prompt. Settings states what native chats offer (`02`) |
| Projects → Create Project → Create Project | "Rust Keychain vault · experimental"; the sheet says chats in a trusted project offer its tools by their mode (`06`) |
| Choose the connection in the composer picker | starter card "Loopback tools test · tools-fixture · Editing tools"; footer notice "Next turn uses Loopback tools test." (`10`) |
| Tools offered | read, ls, find, grep, write, edit, bash, mcp; the project's AGENTS.md in the instructions |
| `LIST_PROJECT` → ls | the project's listing (`11`) |
| `WRITE_EDIT` → write, edit, read | notes.txt created and edited; on disk `first line` / `edited line` (`12`) |
| `BASH_LIVE` | output grows while Running (`13`), Completed, exit code 0 (`14`); the footer stays one row beside the run's progress label |
| Projects → Add Folders… (system open panel), cancel, then `BASH_AFTER_PICKER` | bash runs normally after the panel (`15`) |
| `BASH_FAIL` | Failed, stderr, exit code 7 (`16`) |
| `BASH_STOP`, Stop on the first click | "Stopped"; Outcome unknown, "Tool interrupted… No automatic replay."; the chat pauses with Retry; no bash process left (`18`) |

The image picker was not available: a connection saved through native Settings
is text-only, so attaching images is disabled (the folder picker served as the
system-panel check).

## Cleanup

The test item was deleted (`security delete-generic-password`) and confirmed
absent. Removed, after checking each held only this run's state: the support
folder (the empty `configuration.lock`), the app's saved window state and its
preferences plist (open-panel geometry). The app and provider were stopped.

## Not covered

Locked or denied Keychain, MCP servers and skills in the signed app, find/grep
through the GUI, images, notarization and Gatekeeper on a clean Mac, VoiceOver
on tool cards. Tool calls are still drawn as bordered cards, not Swift's work
rows.
