# Bello Agent 0.1.108 — long chats open fast, images from the model catalog, webhook Send Test

Status: candidate; publication pending.
Starting main: `c72bcf24282c0768bac6ab6d19f8a694ee89ad6a` (0.1.107's verified record).

## Changes

1. **A long chat opens in about half a second** (`8f2d878`). A 600-turn, 41 MB
   chat took 12.7 s to open in a Release build; it now takes about 0.5 s.
   - The helper reads JSON with its own byte parser (`JSONParser.swift`)
     instead of `Codable`, which tried each kind of value in turn and threw for
     every miss. It accepts and refuses what `JSONDecoder` did: the first of a
     repeated key, a trailing comma, a byte-order mark and UTF-16/32, numbers
     too small for a double refused. Invalid UTF-8 and bad escapes are now
     errors, where `JSONDecoder` aborted the whole helper.
   - The chain check reads each record's id, parent and kind with a structural
     scan (`JournalLineScan.swift`); a line it cannot read plainly is parsed in
     full.
   - The replay parses only the newest run-state snapshot, written several
     times a turn and most of a long journal; identities are checked byte by
     byte instead of with a regex.
2. **The model catalog can say which models take images** (`bb47dba`,
   `e7773b7`). A catalog entry may list `input`, pi's kinds
   (`["text", "image"]`). A chat whose model (its own choice or its
   connection's) lists `image` takes attached, pasted and dropped images, as a
   chat on a connection that declares `input` under Model capabilities always
   did; the catalog is read live, so an updated catalog needs no model
   re-selection.
   - When only the catalog says so, the app sends `input` with each turn,
     steer, retry, edit, compaction and context preview; the helper applies it
     to the turn's profile like the other per-turn choices, keeps it across a
     queued restart, and accepts and sends the images.
   - Pickers and first-run setup mark such models "Images"; when neither the
     catalog nor the connection says so, the message names both places to
     declare it. `docs/Model-Catalog.md` describes the field.
   - The attach button follows the catalog in a view of its own, which holds
     the chat's id rather than its page.
3. **Webhook: Send Test and one retry** (`b95ab97`). Settings' webhook group
   has a Send Test: the webhook as typed, before it is saved, filled from a
   sample chat with sample parameters, so no mini model is asked. A finished
   chat's webhook, which nobody is watching, is sent once more 4 s later after
   a network failure, 429 or 5xx; another 4xx is not asked again, and
   interactive sends answer at once.
4. **First-run setup shows one path** (`5c81490`). While setup filled the
   window, the sidebar also said "Add a project to start chatting" with its own
   Add Project button, beside setup's last step, which adds the project. The
   sidebar's prompt now waits until setup is done.
5. **The pane-retention flake is fixed** (`2679e00`, test only). The test's
   project was set on the model and not saved in the vault, so it went when
   the model read its configuration mid-test; "Project unavailable" then
   replaced the composer, and SwiftUI kept the displaced composer with the
   chat. The project and connection are now saved, and the whole-window test
   allows no retained chat beyond the model's eight, where it allowed one.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `2679e00`, dev/next's tip:
  serial lane 213 executed, 7 skipped, 0 failures; parallel lane 1,443 passed,
  16 skipped, 0 failures; gallery **128 screenshots, 0 failures**; helper 471,
  1 skipped (the opt-in performance test); wire 32; concurrent 4; acceptance 2;
  Python 66; all passed in 14 min 44 s.
  `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`,
  which failed in the 0.1.105, 0.1.106 and 0.1.107 gates, passed in the
  parallel lane.
- dev/next branched from `f8f05e8`, 0.1.107's release branch, before 0.1.107's
  release commits, so the merge into main adds only those (0.1.107's version
  fields and records). The merged `apps/macos`, `packages/swift-host` and
  `scripts` trees equal the gated `2679e00`'s.
- **Development evidence on `dev/next`** (Debug builds, before the gate): the
  full app suite ran 1,672 tests, 0 failures, 23 skipped (1,055 s); the full
  helper suite 471 tests, 0 failures, 1 skipped (the opt-in performance test).
  `ConversationPaneRetentionTests` passed 8 of 8 alone and the class 8 of 8;
  before the fix, 4 of 6 and 6 of 8 runs failed.
- `JSONParseTests` (9, helper): documents, edge cases, random and damaged
  documents and other encodings read as `Codable` read them; invalid UTF-8 is
  refused, not a crash; the structural scan reads a record's own fields, leaves
  what it cannot read plainly to the parser, and agrees with the parser.
  `SessionOpenPerformanceTests.testOpeningALongChat` times the long chat and is
  opt-in, so the gate skips it.
- `PiImageTests` (2, helper): a turn that says its model takes images sends
  them; a turn's `input` is pi's kinds, each once.
- `CatalogImageInputTests` (2): the catalog's `input` is read as its efforts
  are; a chat on a model the catalog lists with images takes them.
- `WebhookTests`: Send Test sends the webhook as typed with a sample chat; a
  finished chat's webhook is sent once more after a server error.
- `OnboardingTests.testTheSidebarOffersNoProjectWhileSetupIsOnScreen`.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
