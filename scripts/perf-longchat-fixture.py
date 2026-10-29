#!/usr/bin/env python3
"""Seeded, streaming PERF-1 journals. Generated content only; no user files.

--messages counts user/assistant/tool-result messages (whole turns may exceed it).
--exchanges counts human questions and final answers, including intervening tools.
The native helper makes the .meta checkpoint on its first open; do not invent it.
"""
import argparse
import base64
import hashlib
import json
import random
import struct
import zlib
from pathlib import Path


def png(seed):
    rng = random.Random(seed)
    width, height = 320, 180
    pixels = b"".join(b"\0" + rng.randbytes(width * 3) for _ in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return base64.b64encode(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
                            chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")).decode()


def generate(directory, *, messages=None, exchanges=None, seed=136, compact_every=128):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "chat.jsonl"
    if path.exists():
        raise ValueError(f"Refusing to replace {path}")
    rng = random.Random(seed)
    digest = hashlib.sha256()
    counts = dict(messages=0, exchanges=0, user=0, assistant=0, toolResult=0, thinking=0,
                  images=0, compactions=0, subagent=0, records=0, toolCalls=0)
    sizes = []
    parent = None
    last = None
    recent_turns = []
    with path.open("wb") as out:
        def add(id, **fields):
            nonlocal parent
            value = dict(id=id, parentId=parent, timestamp="2026-10-01T00:00:00Z", **fields)
            line = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"
            out.write(line); digest.update(line)
            parent = id
            counts["records"] += 1
        add("long", type="session", version=3)
        parent = None
        binding = dict(api="openai-responses", model="fixture", provider="litellm",
                       endpointSHA256=hashlib.sha256(b"http://127.0.0.1:1/v1/responses").hexdigest())
        add("native", type="custom", customType="pi-app.native.v1", data=dict(version=1, binding=binding))
        while counts["messages"] < (messages or 2**63) and counts["exchanges"] < (exchanges or 2**63):
            turn = counts["exchanges"]
            started_ms = counts["messages"] * 1500
            ids = []
            def message(id, role, content, **fields):
                nonlocal last
                stamp = 1790812800000 + counts["messages"] * 1500
                add(id, type="message", message=dict(role=role, content=content, timestamp=stamp,
                    nativeTurn=f"u{turn}", nativeTaskRoot=f"u{turn}", nativeTaskExecution=f"e{turn}", **fields))
                counts[role] += 1; counts["messages"] += 1
                ids.append(id); last = id
            question = f"Question {turn}: fix the parser in module {turn % 17}; preserve Unicode offsets and show the tests."
            if turn % 19 == 4:
                question += " Keep Δoffset, café, 中文, and 👩🏽‍💻 intact."
            content = [{"type": "text", "text": question}]
            if turn % 173 == 12:
                content.append(dict(type="image", mimeType="image/png", data=png(seed ^ turn))); counts["images"] += 1
            message(f"u{turn}", "user", content)
            mix = rng.random()
            calls = 0 if mix < .45 else rng.randint(1, 5) if mix < .95 else rng.randint(20, 30)
            for step in range(calls):
                call = f"c{turn}_{step}"
                thinking = f"Check boundary {step}, then compare the byte and character indexes. " * rng.randint(2, 16)
                tool = "read" if step % 3 else "bash"
                args = {"path": f"Sources/Module{turn % 17}/Parser.swift"} if tool == "read" else {"command": "rg -n 'parse' Sources"}
                message(f"a{turn}_{step}", "assistant", [dict(type="thinking", thinking=thinking),
                    dict(type="text", text=f"Checking caller {step}."), dict(type="toolCall", id=call, name=tool, arguments=args)])
                counts["thinking"] += 1; counts["toolCalls"] += 1
                pick = rng.random()
                length = rng.randint(400, 4000) if pick < .85 else rng.randint(8000, 32000) if pick < .98 else rng.randint(64000, 160000)
                line = f"Sources/Module{turn % 17}/Parser.swift:42: let token = parse(input, at: {step}) // generated diagnostic\n"
                output = (line * (length // len(line) + 1))[:length]
                sizes.append(len(output))
                message(f"r{turn}_{step}", "toolResult", [dict(type="text", text=output)], toolCallId=call, toolName=tool)
            if turn % 97 == 23:
                event = dict(event_id=f"event{turn}", family_sequence=turn, type="MESSAGE", sender="/root/audit", recipient="/root",
                             turn=1, text="The generated regression passes; keep the bounds check.")
                envelope = "Message Type: MESSAGE\nTask name: /root\nSender: /root/audit\nPayload:\n  " + event["text"]
                message(f"agent{turn}", "user", envelope, kind="agent_message", inputLane="agent",
                        nativeAgentDelivery=dict(version=2, eventIds=[event["event_id"]], events=[event]))
                counts["subagent"] += 1
            sections = 35 if turn % 113 == 41 else rng.randint(1, 3)
            answer = "\n\n".join(f"## Finding {turn}.{s}\n\nThe parser now keeps **Unicode offsets** through nested blocks. " +
                "The generated fixture checks empty input, early returns, and repeated calls. " * rng.randint(1, 4) +
                f"\n\n- Bounds checked before slicing.\n- Existing callers keep their behavior.\n\n```swift\n" +
                "\n".join(f"let value{i} = parse(input, at: {i}) // fixture {turn}" for i in range(rng.randint(4, 18))) + "\n```"
                for s in range(sections))
            # A sparse query steps across the entire journal without hundreds of thousands of matches.
            if turn % 251 == 0:
                answer += f"\n\nperfneedle checkpoint {turn}."
            message(f"a{turn}_z", "assistant", [dict(type="text", text=answer)], nativeModelMs=1200)
            ended_ms = counts["messages"] * 1500
            add(f"terminal{turn}", type="custom", customType="pi-app.task-terminal.v1",
                data=dict(rootID=f"u{turn}", executionID=f"e{turn}", anchorSourceID=f"u{turn}",
                    startedAt=started_ms, endedAt=ended_ms, startedAtUnixMs=1790812800000+started_ms,
                    endedAtUnixMs=1790812800000+ended_ms, outcome="completed", phase="terminal", lastSourceID=last,
                    issuedCalls=calls, preparingCalls=0, replies=calls+1, modelMs=1200*(calls+1), toolMs=50*calls))
            add(f"state{turn}", type="custom", customType="pi-app.native.state.v1",
                data=dict(active=False, runStatus="idle", queue=[], steering=[], queuePaused=False))
            counts["exchanges"] += 1
            recent_turns.append(ids); recent_turns = recent_turns[-2:]
            if counts["exchanges"] % compact_every == 0:
                kept = [id for group in recent_turns for id in group]
                add(f"compact{turn}", type="compaction", summary="Generated summary: parser fixes and their tests. " * 40,
                    nativeKeptIDs=kept, tokensBefore=80000)
                counts["compactions"] += 1
        # Checkpoint close to the tail, as after a real compaction; keep two whole turns.
        kept = [id for group in recent_turns for id in group]
        add("compact-final", type="compaction", summary="Generated final context summary. " * 40,
            nativeKeptIDs=kept, tokensBefore=80000)
        counts["compactions"] += 1
    sizes.sort()
    manifest = dict(version=2, seed=seed, requestedMessages=messages, requestedExchanges=exchanges,
                    compactEvery=compact_every, **counts, bytes=path.stat().st_size, mib=path.stat().st_size / 1048576,
                    sha256=digest.hexdigest(), firstID="u0", lastMessageID=last, lastID="compact-final",
                    toolOutputBytes={str(p): sizes[min(len(sizes)-1, int((len(sizes)-1)*p))] if sizes else 0 for p in (.5, .95, .99, 1)})
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--messages", type=int)
    group.add_argument("--exchanges", type=int)
    parser.add_argument("--seed", type=int, default=136)
    parser.add_argument("--compact-every", type=int, default=128)
    args = parser.parse_args()
    if (args.messages or args.exchanges or 0) < 2 or args.compact_every < 1:
        parser.error("Use at least two messages/exchanges and a positive compaction interval")
    print(json.dumps(generate(args.directory, messages=args.messages, exchanges=args.exchanges,
                              seed=args.seed, compact_every=args.compact_every), sort_keys=True))
