# Command receipts in the journal

Since 0.1.111 a chat's run-state records usually carry only the command
receipts that changed, not all of them. This keeps long chat files several
times smaller. The code is `CommandReceipts`
(`packages/swift-host/Sources/PiAgentCore/CommandReceipts.swift`).

## What the receipts are

The helper keeps a receipt for each of the chat's last 128 commands, one per
turn: `{"commandId", "turnId", "status", "state"}`. A receipt lets a command
sent again after a crash be recognised instead of run twice, and the app reads
each command's outcome from it (for example, whether a message that was
waiting in the queue was delivered).

The receipts are saved in the chat's run-state records
(`pi-app.native.state.v1`), together with the queue, the steering lane and
the run's status. The helper writes one several times a turn. Until 0.1.110,
every record repeated all 128 receipts, about 18 KB with the app's IDs,
although usually only one had changed. In a test chat the helper wrote over
1,000 turns, those copies were 53 MB of a 71 MB file.

## The format

A run-state record is one of two kinds:

- **Whole:** `commands` is the complete list, as before.
- **Changes:** `data.commandsDelta` is `true`, and `commands` holds only the
  receipts added or changed since the record before it. Applying them in
  order gives the list: a receipt replaces the one for its turn or joins the
  end, and the oldest drop off past 128.

Every other field (`active`, `queue`, `steering`, `runStatus`, errors,
timing, the task shown) is whole in both kinds.

The helper writes a whole list:

- in the first run-state record after the chat is opened;
- after a run-state write that failed, since the journal may or may not
  hold it;
- after 64 records of changes, so that rebuilding the list never reads far
  back;
- whenever the changes would not rebuild the list exactly (for example,
  when a receipt was taken back after a failed send).

An edit's branch record (`nativeState`) and a kept side's new journal also
hold whole lists.

## Reading it

A replay keeps the newest record with a whole list and the records of changes
after it, and rebuilds the list once, at the end. A record that looks like
changes but holds a whole list starts the list again. The journal's metadata
file ([Journal-Metadata-File.md](Journal-Metadata-File.md)) carries the whole
list as it stood at its checkpoint, under `commands` in `helper`. A metadata
file without that list, over a record of changes, is not used: the journal is
replayed in full and the file written again.

Journals written before 0.1.111 hold whole lists only, and open as they
always did.

## Slimming journals written before 0.1.111

Those journals still hold every whole list they were written with. Once per
chat, the app has the chat's helper write the journal again without them
(`JournalSlimming`,
`packages/swift-host/Sources/PiAgentCore/JournalSlimming.swift`, through the
helper command `journal.slim`):

- **What goes.** Only standalone run-state records go, except the one the
  chat's run state comes from. That one stays, with its receipts written
  whole. An edit's record keeps the state it carries. A record after one that
  went names the record before it as its parent, so the journal is still one
  chain, and no id changes. An edit that recorded the journal's head
  (`sourceJournalHead`) as a record that went names that same parent instead;
  nothing reads that field to replay.
- **Checking.** The copy is written beside the journal, and both are replayed
  in full. The copy takes the journal's place only when every row, the model
  context, edited messages' versions, spend, receipts, queue and run state,
  task records, request links, compaction state and the chat's origin all come
  out the same. The original then goes to the Trash, and the metadata file is
  written for the new journal as a full open writes it.
- **Safety.** The journal's own lock is held throughout, so no session opens
  it meanwhile. The helper refuses a chat it has open, and an open of a chat
  being slimmed waits for it. Anything that fails leaves the journal as it
  was, with nothing sent to the Trash. A copy left behind by an app that
  quit mid-way is removed by a later slimming once it is an hour old.
- **When.** The app asks about each chat once, about 20 seconds after launch
  and only while nothing is going on. It skips chats open in the helper or on
  screen, imported chats and background tasks, and journals under 2 MiB. The
  helper leaves a journal whose run-state records would free less than 1 MiB.
  The answer is kept in the app's store (`journal-slim`). A chat that was
  open or locked is asked about again at a later launch.

A 1,000-turn synthetic chat written in the old format took 71.0 MB. Slimmed,
it takes 13.6 MB, and a full open went from about 500 ms to about 400 ms
(Release). Slimming it took 2.8 s, both replays included.

## Older versions

A version before 0.1.111 reads `commands` in the newest record as the whole
list. It still reads the queue, the run and the newest receipts correctly,
because those are whole in every record. It only lacks the receipts of older
commands, which it needs just to recognise one of those commands if it were
sent again.
