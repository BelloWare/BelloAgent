# Models and Settings parity: 2026-10-11

Workstream A (`work/models-settings`). Swift 0.1.122 (`6319e368`) is the spec.

## 1. Per-chat model and reasoning effort

What matches Swift:

- **Choices and their words.** `bello-agent-core/src/model_choice.rs` ports
  `ThinkingLevel` (raw values, labels, pill labels such as "Effort · connection
  default" and "Effort · model decides"), `TurnOverrides.normalizedModel` and
  `normalizedThinkingLevel`, `applyModelChoice` (`ModelChoice::choosing_model`:
  a chosen model keeps only an effort its catalog offers) and
  `ModelSwitchPills.offeredLevels` (ModelCatalog.swift, ModelSwitchControls.swift).
- **Saving.** A choice is saved for the chat and becomes its connection's
  next-chat default in one atomic file write, as `MetadataStore.saveChatModelChoice`
  commits both together. Choosing an unchanged option still updates the default.
  New chats start from the remembered default (`ChatModelDefaults` in
  `newChat`); the first send keeps that choice with the chat. The file is
  `chats/chat-models.json` beside every saved chat. An unreadable file is
  reported and never overwritten.
- **Sending.** The composer puts the chat's choice on each submission;
  `model_choice::capture` (both submit paths in `runtime.rs` and
  `attachment_runtime.rs`) sends it, or the connection's own model and effort
  when nothing was chosen. A chosen model keeps the existing image rules: the
  composer asks `supports_image_attachments_for(choice)`, and attachment
  preparation checks the effective profile of the chosen model.
- **The pills** (`model_picker_view.rs`): cpu and brain icons in the accent
  while a choice is in force, 12-point medium words, a spinner while the
  catalog loads, 170/110-point model and 176-point effort word widths, Swift's
  help text on the model pill.
- **The model list** (`CatalogModelPickerView.swift`): 390 points wide, 16-point
  padding and 12-point gaps; "Model catalog"/"Bello model catalog", the source
  name and its host and path (never the query); spinner and Refresh;
  search over id, name and description; "Use connection default · <model>";
  "Refresh failed · showing the last list"; rows with check or cpu mark, name,
  Mini/Images/Deprecated tags, id, description, "400K ctx" and "up to 8,192
  output", on the accent wash when chosen, at most 340 points at 68 a row;
  "Loading models…"/"No models are listed by this connection."/"No matching
  models."; the not-listed note; "N models", "Updated h:mm:ss AM", "Enter
  alias…"/"Hide alias field", the alias field and Use; the included-catalog note.
- **The effort list**: "Reasoning effort", the offered levels with a check on
  the current one, and Swift's two notes. Arrows, Return and Escape work.
- **Listing and Refresh.** Opening a list reads the chat's catalog only when it
  is not fresh (5 minutes; 30 seconds after a failure), sharing a native
  source's cached list. Refresh first reloads the saved connections, then always
  fetches, with Swift's fixed refresh error words. A newer saved revision or a
  changed source makes a list stale; another source's rows are never shown.
- **Connection switch** (`WorkspaceConnectionSwitch.swift`): a chat's model
  choice survives only when the new connection's catalog lists it (or the list
  is not known); the effort is rechecked; the footer says "Next turn uses
  <name> with its default model." when the model was dropped. Not remembered
  for new chats.

How it was checked: `model_choice_tests.rs` (core), `model_picker_tests.rs`, and
`model_picker_workflow_tests.rs` (six GPUI tests against a loopback gateway:
list, Refresh, failed Refresh, choose, effort, on-disk store, the POST body's
`model`, new-chat defaults, alias entry, drawn list geometry and clicks,
Escape, backdrop toggle, Settings taking over, stale revision, switch rules,
a failed save). Only loopback fixtures are contacted.

Still different:

- Swift lists the target catalog before deciding a switch; Rust decides from a
  list already read this session (an unread list keeps the choice).
- No "Catalog source…" chooser or "This chat uses its original model list"
  repair notice yet.
- Rows are laid out eagerly, not lazily; very long catalogs cost more to open.
- The pills keep Rust's chevron glyph, not `chevron.up.chevron.down`.
- Context preview and manual compaction still use the connection's model.
- As in Swift, an effort on a connection whose model is not marked as
  reasoning is saved and shown but not sent.

## 2. Settings sections

What matches Swift (`ProfileSettings.swift`, `SettingsWindowContent.swift`):

- Four sections down the left, 210 points wide, in Swift's order and words,
  the open one highlighted with its icon in the accent, a warning dot on a
  section with unsaved edits. The open section is kept between openings.
- **Chats & notifications**: the Transcript card ("Finished turns", Normal /
  Compact, Swift's detail and footer) and the Notifications card (task
  completion sound with Preview; macOS only, as before).
- **Transcript display API** (`app_settings.rs`): `TranscriptDisplayMode`
  (`Normal`, `Compact`; Compact when nothing was saved, Swift's `fallback`),
  `transcript_display(cx)` and `observe_transcript_display(cx, f)`. Stored as
  `{"transcriptView": "normal"|"compact"}` in `app-settings.json`.
- Save All saves the edited preferences before the connection tabs and closes;
  Cancel and Discard drop them; closing with an unsaved preference asks
  first; Reload asks too.
- **Usage & capture** and **App** say plainly that this preview has nothing to
  set there (no capture, dashboard, cost limits, helper runtime or updates
  exist in Rust). No control is shown that would do nothing.

How it was checked: `app_settings_tests.rs`, `settings_sections_tests.rs`
(draft, Save All, Cancel, the close question, discard; drawn sections and
clicks), and the existing Settings, sound and controller suites.

Still different:

- The transcript does not yet read the mode: `transcript_*.rs` belongs to the
  transcript workstream, which should call `transcript_display` and
  `observe_transcript_display` when it merges.
- The section rows are drawn in GPUI, not with Swift's selection glide.
- Connection-only controls (Delete, Discard) appear only on Connections.

## 3. Chat titles

`bello-agent-core/src/title_generation.rs` ports `TitleGenerationPlan`
(mini model choice, budgets, effort, prompt), `title(from:)` and
`titles(from:limit:)`; `title_runtime.rs` adds `Controller::request_title`, one
request on the chat's own connection outside its history. The catalog parser
now keeps the `mini` flag, and the model list shows the Mini tag.

Checked against Swift by `title-oracle/`: `extract.py` copies the unchanged
`WireValue`, `ThinkingLevel`, `TurnOverrides`, `ModelDescriptor` and
`TitleGenerationPlan` declarations from the Swift checkout; with
`swift-src/stubs.swift` and `swift-src/main.swift`,

```sh
python3 extract.py <swift-checkout>
swiftc -O -module-name TitleOracle -o oracle swift-src/*.swift
./oracle cases.json > swift-titles.json
```

`title_generation::tests::plans_titles_and_suggestions_match_the_swift_oracle`
matches all 10 plans (prompts byte for byte, including JSON quoting of control
characters and non-ASCII) and 20 replies' titles and suggestion lists. A
loopback test sends a title request and checks the body (mini model, effort,
no history or instructions) and that the chat is untouched.

Not wired into the app: automatic titles need Swift's edited/generated title
flags in the workspace catalog, a mini model choice in Settings and the
Background requests page, none of which exist in Rust yet.
