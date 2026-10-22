# EDIT-1: editing a message on screen starts at once — 0.1.131

Workstream: `dev/a131-edit`, based on `dev/next` `a9f34673`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a131-edit`.
Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-edit`
(text logs under `evidence/`; no named result bundle).

Generated fixtures and loopback services only: the synthetic gateway
(`fixtures/native/ui-gateway.py`), the workstream's packaged helper, scratch
stores and `MemoryVaultStorage`. No installed app, real preferences, real
chats, Keychain, live capture or paid provider. No wire schema, helper source,
permission, capture, tool, vault or data boundary changed.

## The report

Owner, 2026-10-22: "when I try to edit a message, sometimes it just takes so,
so long to load. Even though that message is right there, you know, it still
takes very long. Even though I can see the message, it still takes very long
to load."

## Reproduction

`MessageEditLatencyTests.testEditingAQuestionOnScreenInALongChat` (opt-in,
`PI_EDIT_LATENCY_TURNS`; serial lane). It writes a long chat through the
packaged helper and the synthetic gateway — questions, replies of
`PI_EDIT_LATENCY_REPLY_KB` KB, a compaction every 25 turns, four short turns at
the end — then launches a fresh model over that state, as a relaunch does,
shows the chat in the real window (`WorkspaceRootView`), and presses the
**Edit pill of an earlier question on screen** (`TranscriptPillButton`, the
row's own action path: `TranscriptActions.edit` → `editMessage`). Each case is
timed from the press to the composer showing that question under the
"Editing an earlier message" banner with an editable field, and to the
complete original being read. A test seam (`WorkspaceModel.messageEditStep`)
stamps each step of the preparation, so the log says what the composer waited
on. `testWritingTheLongChat` writes the chat alone, with no window, for a run
that needs no lock; `PI_APP_UI_FIXTURE_NO_CAPTURES=1` (new, in the gateway)
keeps the gateway from holding and rewriting every request of a chat of
hundreds of turns.

Release build-for-testing (`-configuration Release`, `ENABLE_TESTABILITY=YES`),
run through its `.xctestrun` under the full-lane lock with "perf" in its owner
line, each try started at a one-minute load of at most 3 (4 for the unfixed
run), sampled every 10 s and at the end; a try that went above 4 was redone.
The chats: 600 turns with 40 KB replies and a compaction every 25, **103 MB**
of journal (`PI_EDIT_LATENCY_TURNS=600`), and 1,500 such turns, **259 MB**
(`PI_EDIT_LATENCY_TURNS=1500`, written in 198 s, `evidence/write-large-release.log`).

Before the fix (`a9f34673`; `evidence/before-long-release.log`, load 2.44 at
the start, peak 2.53, 2.48 at the end):

| Case | Composer shows the question | Original read |
| --- | ---: | ---: |
| Helper does not hold the chat (the app reads the journal) | 441 ms ¹ | 441 ms |
| Helper holds the chat, opened from its metadata file | **3,907 ms** | 3,907 ms |
| The same, second edit (every row loaded) | 22 ms | 22 ms |
| During a run (chat opened from its metadata file) | **3,941 ms** | 3,941 ms |
| After a run | **3,950 ms** | 3,950 ms |
| A draft write pending at the press | **3,948 ms** | 3,948 ms |
| Typing while it loads | **never** (the press dropped at 3,961 ms) | — |

The read alone: `session.edit.prepare` 3,911 ms on a chat opened from its
metadata file and 5 ms with every row loaded; a fresh history reader's
`editTarget` 437 ms. ¹ The unfixed harness stopped looking as the read ended;
the composer took the question in that same pass. A first run at load 7.9
(`evidence/before-long-release-first-run-load7.9.log`, superseded) gave 5.7 s
and 4.4 s for the same two.

After the fix, the same chat (`evidence/after-long-release.log`, load 2.96 at
the start, peak 3.39) and a **259 MB** one, 1,500 turns
(`evidence/after-large-release.log`, try 3: load 3.00, peak 3.44; tries 1–2
ended at 4.1–4.7 and were redone, as were three earlier tries of each chat
kept in `evidence/after-*-load-above-4/`):

| Case | 103 MB: composer shows the question | 103 MB: original read | 259 MB: composer | 259 MB: original read |
| --- | ---: | ---: | ---: | ---: |
| Helper does not hold the chat | **23 ms** | 486 ms | **20 ms** | 1,114 ms |
| Helper holds the chat, opened from its metadata file | **22 ms** | 3,916 ms | **22 ms** | 10,584 ms |
| The same, second edit | 13 ms | 21 ms | 13 ms | 33 ms |
| During a run | **14 ms** | 3,964 ms | **14 ms** | 10,656 ms |
| After a run | **14 ms** | 3,946 ms | **13 ms** | 10,874 ms |
| A draft write pending at the press | **12 ms** | 3,942 ms | **12 ms** | 10,828 ms |
| Typing while it loads | **19 ms**, typing kept | 3,957 ms | **17 ms**, typing kept | 10,874 ms |

"Composer shows the question" is from the press through the first layout and
display pass that has the question in the field under the banner, editable.
"Original read" is the same read the composer used to wait for, unchanged and
now behind it: Send waits for it. `session.edit.prepare` alone took 3,916 ms
and 10,677 ms on a chat opened from its metadata file (4 ms and 12 ms with
every row loaded); a fresh history reader's `editTarget` 425 ms and 1,065 ms.
There was no unfixed run on the 259 MB chat (its build was replaced before the
chat was written); its "original read" column is what that build would have
waited for, as the 103 MB rows show.

## What the edit waited on

The composer took the message only once `editMessage` had read its
complete original: its text, the images and skills it was sent with, and the
timeline and text digest Send is checked against (`sourceTimeline`,
`sourceTextDigest`). Every step was timed (`evidence/before-long-release.log`):

- **The helper's read.** A chat open in the helper — usually: selecting a chat
  opens it there for the context pill 180 ms later unless a reading of it
  still stands, and focusing or typing in the composer opens it (`prewarm`) —
  is read with `session.edit.prepare`, which calls
  `AgentSession.loadFullHistory()`. A chat the helper opened from its journal
  metadata file (`<id>.jsonl.meta`, written at every compaction) holds only
  its latest rows (`partialHistory`), so its first edit replays the whole
  journal and builds every row: **3.9 s** for the request alone in the
  103 MB chat, and as long from the press to the composer. The second edit,
  with every row loaded: 22 ms. That is the owner's "sometimes": the first edit
  after the helper opened the chat — after each launch, after the project's
  helper stopped when idle (120 s by default, `idleGraceSeconds`), and after
  the chat's display was let go of among more than eight
  (`releaseUnreadDisplays`): each opens it from the metadata file again.
- **The app's read** when the helper does not hold the chat:
  `HistoryReader.editTarget` indexes the whole journal (`whole: true`),
  0.44 s for the 103 MB chat.
- **Typing while it loads dropped the edit.** The original was taken only over
  the draft the press saw (`view.savedDraft == draft`); a keystroke in those
  4 s made the press end with nothing at all.
- **Not the cause:** a pending draft write (3.9 s, the same as without one), a
  run going on (3.9 s, the same), the helper's command queue (one request).
  `prepareToolOutputUse` waits for a tool-output recycling sweep already under
  way; none was in these runs (the harness notes one at the press), and that
  wait now also sits behind the composer.
- Queued messages are not affected: `queue.edit.begin` and `queue.read` answer
  from the helper's in-memory queue, never the journal.

## The fix

`WorkspaceEditing.swift`, with the edit's state in `SessionDisplay.swift`
and `MetadataStore.swift` and its restore in `WorkspaceDrafts.swift`:

- **At the press**, a question on screen goes into the composer at once: its
  row is its whole text (`editOpening`: a user row of the timeline shown, not
  streaming, not cut, not an earlier version, not an image-only message's
  "Image"/"3 images" label, within the submission limit). The helper's display
  row for a user message is `displayText ?? text`, the text
  `session.edit.prepare` returns, so no new helper command is needed. The
  draft it held is set aside for Cancel as before, the banner shows, the field
  takes typing and has the focus, and the edit is saved with the draft.
- **Behind it**, the complete original is read exactly as before (helper or
  journal, the same `.messageEdit` tool-output producer), and Send waits for it
  (`editPreparing`: "Loading the complete original input…", now beside the
  banner's spinner in the banner's own colour rather than as a refusal; Send
  pressed meanwhile says so and sends nothing, and that notice goes when the
  original is read).
- **When it arrives**, the text is taken only if the composer is untouched;
  what was typed stays, and if the original reads differently from its row the
  banner says to review it. The original's images and skills come first, then
  any added meanwhile. Send's checks and the missing-image and unrecorded-input
  reviews are set as before.
- A read the helper refused because rows were written while it loaded the
  whole history (`edit_changed` or `history_changed`, as during a run) is made
  again, up to three tries: the next finds every row loaded.
- A read that fails leaves the question and the typing in the composer and
  holds Send ("The complete original input could not be loaded. Cancel, or
  choose Edit on the message again."); Edit reads it again.
- **Durability.** While the original is unread the saved edit carries
  `MessageEditDraft.inputPending = true` (a new optional field; older drafts
  decode without it as read). A restart restores the edit with what was typed
  and reads the original again before Send takes it (`resumeEditPreparation`,
  from `adoptDraftBaseline` and `restoreConflictedDraft`). Send itself
  (`sendEdit`), its captured intent and every 0.1.130 capture path are
  unchanged. (An older app, after a downgrade, ignores the field and restores
  such an edit without its checks, as it restores drafts saved before the
  checks existed.)
- **Unchanged:** an off-screen message (no row), a row that is not the whole
  question, and a chat whose saved draft is not read yet
  (`selectionMetadataLoaded`) wait for the original as before. The last keeps
  the set-aside draft the chat's own.

## Tests

New: `MessageEditStartTests` (parallel lane; seven cases against the read
seam `editTargetRead`, one through the packaged helper and the synthetic
gateway), `MessageEditGalleryTests` (serial: focus), and the opt-in
`MessageEditLatencyTests` above.

| Test | Holds |
| --- | --- |
| `testAQuestionOnScreenIsInTheComposerAtOnceAndTypingKeepsWhenItsOriginalArrives` | At the press, before any read: the question in the composer (`ComposerInputView`'s field), the banner, an editable field; Send says it waits and sends nothing; typing stays when the original's image, skill and checks arrive; the wait's notice goes; Cancel gives the set-aside draft back. |
| `testCancelWhileTheOriginalLoadsGivesBackTheDraftAndALateReadChangesNothing` | Cancel during the read; the late read changes nothing. |
| `testAnOriginalThatCannotBeReadKeepsTheTypingAndHoldsSend` | A failed read keeps the question and typing, holds Send, is saved for a restart; Edit reads it again. |
| `testAReadThatMetRowsWrittenMeanwhileIsMadeAgain` | `edit_changed` from the helper is read again. |
| `testAnOriginalUnlikeItsRowReplacesItUntilTypedIn` | An original unlike its row is taken whole while untouched; once typed in, the typing stays and the banner says to review. |
| `testARowThatIsNotTheWholeQuestionWaitsForItsOriginal` | An image-only label, a cut row and a chat whose saved draft is unread still wait (kept behaviour; passes before and after). |
| `testAnEditSavedWhileItsOriginalLoadedReadsItAgainAfterARestart` | Saved mid-read, relaunched on the same store: the edit and typing come back, the original is read again, Send waits for it, Cancel gives the set-aside draft back. |
| `testEditingAQuestionOnScreenThroughThePackagedHelper` | A chat with a compaction, opened again from its metadata file: the question is in the composer at once, typing goes in while the helper loads the history, and Send's `turn.edit` is accepted against the checks the read gave. |

**Failing first** (`evidence/failing-first.log`): the eight cases against the
production sources of `a9f34673` (the fix reverted; a test-only shim gave the
two new properties the tests read a constant value): **8 tests, 7 failed, 38
failures (1 unexpected, a wait that timed out)**. Excerpts:

```text
XCTAssertEqual failed: ("nil") is not equal to ("Optional("u2")") - The composer takes the question from its row at once
XCTAssertNotNil failed - The edit banner shows while the original loads
XCTAssertEqual failed: ("An unsent draft Also check the tests.") is not equal to ("Why does the parser read the stream twice? …")
failed - The original is asked for again
XCTAssertEqual failed: ("nil") is not equal to ("Optional("q2")")
XCTAssertEqual failed: ("Optional("The last question")") is not equal to ("Optional("The question, edited")")
```

The last two are the packaged-helper case: the press left the composer as it
was, the typing went into the ordinary draft, so the read's result was
dropped and Send had no edit to send. The eighth case is the kept fallback and
passes on both.

**With the fix** (`evidence/fixed-start-4.log`): 8 tests, 0 failures.

**Mutations** (`evidence/mutation-*.log`; each reverted, then the class
passed again):

| Mutation | Result |
| --- | --- |
| m1: no immediate entry (`opening = nil`) | 6 tests failed, 36 failures |
| m2: the original's text replaces the typing | 4 tests failed, 5 failures |
| m3: no second read after `edit_changed` | the retry test failed |
| m4: no resume after a restart (`adoptDraftBaseline`) | the restart test failed |
| m5: a failed read does not hold Send | the failure test failed |

**Classes covering the change** (Debug; rules.md: what the change touches,
nothing broader):

- Parallel lane, `evidence/focused-parallel-final.log` (the final build; the
  run before the stale-notice line, `evidence/focused-parallel.log`, counted
  the same): `MessageEditStartTests`,
  `HistoricalEditBookkeepingTests`, `SendBookkeepingTests`,
  `SkillRefreshTests`, `ToolOutputProducerTests`,
  `SubmissionPersistenceTests`, `DraftConcurrencyTests`, `DraftLoadingTests`,
  `DraftOrderingTests`, `DraftSizeTests`, `DraftMarkTests`,
  `RecoveredDraftTests`, `WorkspaceDurabilityTests`, `WorkspaceRaceTests`,
  `ComposerImportSubmissionTests`, `ContextAndSkillPolicyTests`,
  `HardeningTests`, `ImageFormatImportTests`, `PastedAttachmentTests`,
  `QueuedAttachmentLimitTests`, `ReportNavigationTests`, `SideTests`: **374
  tests, 373 passed, 0 failed, 1 skipped** (`ImageFormatImportTests.testMeasureConvertedPhotos`,
  an opt-in measurement).
- Serial lane, under the lock, `evidence/focused-serial.log`
  (`-parallel-testing-enabled NO`): `ConversationPaneTests` (85),
  `HistoricalEditFocusTests` (1), `HistoricalEditingTests` (5),
  `HistoryEdgeTests` (16), `MessageDetailTests` (10), `MessageEditGalleryTests`
  (1), `MessageVersionTranscriptTests` (8), `QueueEditInteractionTests` (17),
  `SubagentNavigationTests` (7): **150 tests, 0 failures**.
- `HistoryEdgeTests`, `MessageVersionTranscriptTests` (serial) and
  `SkillRefreshTests` (parallel) edit through the packaged helper on chats
  opened with `select`, whose saved draft is read: the composer takes the
  question at once there as well, and their edits still send and settle.
- Gallery (`TEST_RUNNER_PI_APP_EDIT_GALLERY`, eight PNGs, looked at): the edit
  banner while the original loads and once it is read, at 920 pt and 420 pt,
  light and dark. Loading: the question in the field with the caret at its
  end, "Loading the complete original input…" in the banner's secondary ink
  beside its spinner, Resend disabled. Read: no spinner, the usual notice,
  Resend enabled. The banner stays inside the composer and off the field in
  every scene.
- The gateway's own tests (`python3 -m unittest scripts/tests/test_ui_gateway.py`,
  `evidence/python-ui-gateway.log`): 25 tests, OK; captures stay on by default.
- Not run, as rules.md asks: the full native lanes, the helper suite and the
  wire, concurrent and acceptance suites (no helper or wire change).

## Known, and needs owner decision

- **Needs owner decision: an edit opened during a run.** Its original is read
  while the run goes on, so Send's timeline check (`sourceTimeline`, the digest
  of every row on the timeline) is the run's timeline at that moment. Once the
  run has added its rows, Send is refused: "The selected branch changed. Select
  the message again." The question and the typing stay in the composer, and
  choosing Edit again reads the original over the typing. This was so before
  the fix too (the read was the same, only in front of the composer); a probe
  through the packaged helper confirmed it (`evidence/probe-edit-during-run.log`).
  Kept as it is (the conservative choice). Options:
  1. Keep it: the reader chooses Edit again after the run.
  2. Read the original's checks again when the run ends while the edit is
     open, so Send takes the timeline the reader now sees.
  3. At Send, when only rows after the edited message changed, read the
     checks again and send, with the banner saying the newer replies are left.
- **Send still waits for the whole journal once.** The first read of a chat the
  helper opened from its metadata file still replays its journal (3.9 s at
  103 MB, 10.7 s at 259 MB); it is behind the composer now, and Send waits for
  it. A
  read that needs only the edited row (the helper keeping what Send checks in
  the metadata file, say) is a helper change, not made here. On a journal whose
  replay passes the app's 30 s acknowledgement timeout the read fails, Send is
  held with "could not be loaded", and choosing Edit again joins the helper's
  load still under way (`fullHistoryLoad`).
- The read for a chat the helper does not hold indexes the whole journal on the
  shared history reader (0.4 s at 103 MB, 1.1 s at 259 MB); that chat's page
  reads wait behind it, as before.
- A tool-output recycling sweep under way still holds the read
  (`prepareToolOutputUse`), as before, now behind the composer.
- Not changed: queued-message edits (in-memory, never slow), Send
  (`sendEdit`), the wire contract and the helper.
