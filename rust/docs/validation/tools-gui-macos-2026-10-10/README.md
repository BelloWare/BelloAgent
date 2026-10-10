# Tools in the macOS app: GUI acceptance (2026-10-10)

The first run of the saved-chat tool runtime in the GPUI app on macOS (this Mac,
macOS 14.8), driven through the ordinary UI. It used the fake-vault fixture
build, which composes saved chats with the same tool-capable factory that
native-authority chats now use, so no signing, Keychain item or real key was
involved: `cargo build -p bello-agent-app --features synthetic-authority`
(debug, `c505c227` plus the footer fix below), launched with
`--synthetic-connections --synthetic-attachment-fixture profile.json` and a
scratch HOME, TMPDIR and project.

The provider was `tools-gateway.py` on numeric loopback: a keyword in the
latest message chooses a fixed, harmless sequence of tool calls (one per round
trip, then a closing message); prompt text is never executed, nothing left the
Mac. Its bash commands are those of `rust/fixtures/bash_workflow_fixture.py`.

## Steps and results

| Step | Result |
|---|---|
| Choose the fixture connection in the composer picker | refused until the project is trusted ("Trust and bind this saved project…"), as designed |
| Projects → Create Project → Create Project | "Trusted" |
| Choose the connection again | starter card: connection name, model, "Fixture tool runtime"; footer notice "Next turn uses Synthetic attachment fixture." (`09`) |
| Request tools | Editing chat by default: read, ls, find, grep, write, edit, bash, mcp offered; the project's AGENTS.md in the instructions |
| `LIST_PROJECT` → ls | card with the listing (AGENTS.md, open-me.txt), then the reply (`10`) |
| `WRITE_EDIT` → write, edit, read | "Created notes.txt", "Edited notes.txt +1 −1", read with numbered lines; the file on disk reads `first line` / `edited line` (`11`) |
| `BASH_LIVE` → bash | output grows in the card while Running (`12`), then Completed, exit code 0, 2 s, tool time counted (`13`) |
| Open the image picker (NSOpenPanel), cancel, then `BASH_AFTER_PICKER` | bash runs normally after the system panel (`15`): the child-process contract (default SIGCHLD, sole reaper) holds beside GPUI's pickers |
| `BASH_FAIL` | Failed in red, stderr shown, exit code 7 (`16`) |
| `BASH_STOP`, then Stop mid-run | "Stopped"; the card reads Outcome unknown, "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay."; the chat pauses with Retry; no bash process left (`20`) |

## Found and fixed

The new footer notice did not shrink: with a run's progress label beside it,
the footer row wrapped ("Capture off" dropped to a second line, `12`), which
moved the composer, and its Stop button, by a row while the run went on. A
first Stop click landed where the button had been and the command ran its full
10 s. The notice now takes the room the row leaves and is cut with "…", as
Swift's `FooterNotice` is; `native_mode_choosing_in_the_picker_binds_the_connection`
checks that a very long notice leaves the footer's bounds unchanged in a
1000-pt window (it fails with the old layout).

The Projects sheet and its save notice still said "Native production tools
remain disabled"; they now say what each mode offers.

## Not covered

The signed native-authority app (its Keychain vault) with tools; MCP and skills
in the GUI; find/grep through the GUI; write/edit outside the project folder;
bash timeouts and very large output in the GUI (covered by core tests);
VoiceOver on tool cards. Swift draws tool calls as compact work rows; Rust
still draws bordered cards.
