# Swift chat journals: the import oracle (2026-10-10)

The Rust store will import chats from Swift Bello Agent. Its reader
(`bello_agent_core::swift_journal`) must read a Swift journal exactly as Swift
0.1.122 replays it, so Swift's own code is the oracle twice over: it writes the
journals, and it replays them.

`main.swift` is compiled together with `packages/swift-host/Sources/PiAgentCore`
at `6319e368`, unchanged, as one module (so its internal API is in reach):

```sh
swiftc -O -module-name SwiftImportOracle \
  <pi-app>/packages/swift-host/Sources/PiAgentCore/*.swift main.swift -o oracle
./oracle generate journals            # one journal per scenario
./oracle dump journals/plain.jsonl plain <cwd from plain.meta.json>
```

`generate` drives real `AgentSession`s with a scripted model client and tool
doubles (as Swift's test fixtures do; no network, no credentials, no user data)
and keeps each journal Swift writes: plain turns with Markdown and reasoning; a
tool round with a failing tool; a manual compaction; a historical edit; steering
during a run; a failed request; a fork and its source; edits after a compaction,
of a turn the compaction summarized, and after a tool round; a kept side chat; a
run stopped while the model answers; a chat moved to another connection.

`dump` replays a copy with `AgentSession.replay` (the whole journal, as an open
without a checkpoint) and writes the shown rows (every `ChatMessage` field the
import reads), the model context, the fork or side origin and the newest run
state. `summarize.py` prints them per scenario.

The journals and Swift's replays are `crates/bello-agent-core/tests/data/swift-journal/`;
`swift_journal::tests::journals_replay_as_swift_replays_them` compares Rust's
replay with Swift's for all 14 (rows, context, origin, queue, steering and
pause). Result: identical, with numbers compared as Swift compares them (every
JSON number is a double; `serde_json` otherwise tells 100 from 100.0).

What Rust reproduces: Swift's line reader (newline-terminated records, an
unfinished tail refused, 32 MiB per record), the header and single-chain checks,
the native marker and connection moves, and the replay: message records,
compaction checkpoints (including their source/kept/protected checks, tool-batch
validation and progress-row adoption), historical edits (the version 2 plan,
recomputed and checked against the record, and legacy `keptIds` branches), fork
context records, progress-row updates, and progress rows left without a terminal
receipt. Swift's `JSON` null-literal quirk is kept: an absent `usage`,
`toolStats`, `compaction` or `userInput` decodes as a present null.

Not read (not needed to show or continue a chat): spend, command receipts beyond
the newest state record, task presentations, message versions (an edit's earlier
replies stay in `history`), checkpoint files. A response timeline counts as
terminal when its record names a terminal; Swift also requires it to decode.

## The chat list (`metadata/`)

`bello_agent_core::swift_catalog` reads Swift's `desktop.sqlite` (one table of
JSON records by kind) as the sidebar lists it. `metadata/build.sh` compiles
Swift's own `MetadataStore.swift` and the record types it encodes from
`6319e368`, unchanged (the attachment record is the first 28 lines of
`Attachments.swift`, the struct alone), with `stubs.swift` standing in for app
types named only in code the oracle never runs (title claims, the portable
handoff, error text, money formatting). `metadata-oracle generate OUT` has the
store write three projects, a topic, a draft and chats of every kind (plain,
pinned, archived, in a topic, a kept side, another project, a title request, a
connection test, per-chat overrides with a cost limit, one with no creation
order, one never sent), plus two rows another version could leave (no
workspace; no tool mode). It checkpoints the WAL and keeps a copy of the store
before listing (a listing writes back the orders it fills in), then writes
Swift's `loadChats` result.

Fixtures: `crates/bello-agent-core/tests/data/swift-catalog/`. Rust lists the
same 11 chats in the same order, every decoded field equal, and leaves the same
2 rows unlisted (Swift's synthesized `Codable` needs every non-optional key,
`toolMode` and `imported` included, defaults notwithstanding). The 512 KiB row
limit is checked by the Rust test with a row of its own.
