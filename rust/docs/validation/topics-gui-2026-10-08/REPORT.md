# Topics: actual cloud GUI validation

2026-10-08, 22:11–22:17 UTC. Ordinary debug application built with `synthetic-authority` from base `ea2e2ed970cacd13d90e40eed5d1aaa3a565bd1a` plus the frozen 21-file Topics postimages. The GUI worker independently verified all 21 hashes and the local base. Binary SHA-256: `d6c9e4083fedaeb26e0ec3474fd69e3fb410d26d1fa9f7ed3fce54ff05c2c74d`.

## Actual interactive path

The app ran on the cloud Linux desktop with software Vulkan, isolated HOME/XDG/tmp/state and a disposable generated project. Existing explicit synthetic connection fixture admission used only a generated profile and numeric loopback `127.0.0.1:47931`. A held HTTP trap logged unexpected requests. The project and catalog were not seeded or rewritten: Projects → Create Project → explicit review and Create Project produced the visible Trusted / Memory-only fixture state. No connection was selected and no Send was invoked.

Using actual CUA mouse and keyboard inputs:

1. Opened the current-project Topics sheet and created `planning alpha`.
2. Moved the empty unsent New chat into it. This materialized a catalog row/draft, while the chat's session materialization remained pending. No session checkpoint or journal appeared.
3. Renamed the topic to `release notes`.
4. Closed the sheet and collapsed the topic. Its chat disappeared from the sidebar. Filtering by `release` revealed the chat despite collapsed expansion; the persisted expansion was still false at the captured checkpoint.
5. Cleared the filter, expanded the group and entered `unsent topic draft` in the composer without sending.
6. Opened Move for the already-catalogued row, moved it to project top level, then back into the topic. The draft remained visible.
7. Created a second pending chat through the project's plus control and moved it into the same topic.
8. Clicked Delete… and separately confirmed `Delete topic, keep chats`. Both chat IDs survived and returned to project top level. Exact draft objects were unchanged by deletion.
9. Switched back to the first chat and observed its unsent draft restored. Reopened the Topics sheet and observed no remaining topic.
10. Closed the app through the window manager close button. It exited0, with no Agent window remaining. Normal shutdown advanced draft revisions19→20 and1→2; draft text and queued-edit values remained unchanged.

## Evidence and assertions

Eleven original application screenshots are in `evidence/`. Seven catalog snapshots preserve before/after metadata (including initial empty catalog). `verification.json` verifies both chat IDs retained, both top-level, no remaining topics, exact drafts unchanged by deletion, and draft contents unchanged by shutdown. The final state directory contains only `session.workspace.json` and its zero-byte lock file: no session snapshots or journals were created. The loopback trap's `requests.jsonl` remains zero bytes and `listener-ready.json` confirms binding. `profile.json`, `start.sh`, `trap.py`, sealed binary metadata and source checks retain reproduction inputs.

## Limits and actual input issues

- This proves metadata operations on initially unsent and subsequently catalogued pending chats. It does not cover an existing materialized conversation with provider messages or an active tool batch; no provider send was permitted in this run.
- Same-process Topics-sheet close/reopen and chat switching/draft restoration passed. No exposed CloseChat/retire control was found in the context menu (Pin, Archive, Copy Session ID only). Controller retirement/reopen and full-process reopening are not accepted by this run. No hidden action or authority bypass was attempted.
- Initial rendering briefly appeared black before a normal focus click. A bound-window click on the Projects button did not activate it. Desktop pointer movement plus click worked and was used thereafter. Uppercase literal key names yielded lowercase text, so the observed topic name was `planning alpha`; this is preserved in screenshots/catalog, not silently corrected.
- An initial final-verification assertion compared complete draft objects across normal window shutdown and failed because revisions advanced. The retained failure note and final verification distinguish deletion-only equality from shutdown's revision changes.
- This is actual cloud GUI input, separate from synthetic GPUI unit tests or startup smoke. It does not establish macOS/TCC/AX/Keychain/signing, native forced-termination behavior, performance or release acceptance.

No source/build/remote writes, real credentials, user Mac access, paid providers or extra spending occurred. Desktop was released at22:16:54 UTC.
