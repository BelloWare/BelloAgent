# Session references — 2026-09-19

Released: Bello Agent 0.1.54/build 58.

Session context menus and the main/side conversation “…” menus share Copy
Session ID and Copy Session Reference actions. The action resolves the clicked
session at copy time, independently of whichever chat has focus. It does not
start a helper, load history, select a chat or create an export.

The reference uses the authoritative `ChatRecord.path`, including imported
originals and durable side/fork files. No path is guessed for pending chats.
The app session ID is labeled explicitly because imported histories can have
a different original ID in their file header. Parent identity is included for
side conversations.

The actual journal is newline-delimited JSON. It includes retained messages,
tool results and edit/compaction metadata. Previous edited-away replies remain
in the journal; it is not a projection of the current model context. Streamed
output becomes inspectable after the helper saves it. Unsaved drafts are not
included. The copied reference explains those distinctions and provides a
shell-quoted `cat --` command. It does not copy conversation content or credentials.

## Validation

Focused checks and distribution evidence are recorded in the
[0.1.54 acceptance record](validation/Bello-Agent-0.1.54-2026-09-19.md).
The helper, journal format, gateway, tools and transcript rendering are unchanged;
their existing acceptance evidence is reused. No install/update rehearsal is
required under the standing owner workflow.
