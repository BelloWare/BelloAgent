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

## Older versions

A version before 0.1.111 reads `commands` in the newest record as the whole
list. It still reads the queue, the run and the newest receipts correctly,
because those are whole in every record. It only lacks the receipts of older
commands, which it needs just to recognise one of those commands if it were
sent again.
