#!/usr/bin/env python3
"""Seeds a session with tool calls of every kind: seed.py template.json out.json"""
import json
import sys

template = json.load(open(sys.argv[1]))
binding = {"profile_id": "bench-gateway", "api": "openai-responses", "provider": "litellm",
           "model": "bench-model", "endpoint_sha256": "0" * 64}


def message(id, role, text="", reasoning="", record=None):
    m = {"id": id, "role": role, "text": text, "reasoning": reasoning, "replay_eligible": True,
         "state": "completed", "usage": None, "model": "bench-model" if role == "assistant" else None}
    if record:
        m["tool_record"] = record
    return m


def reply(id, text, reasoning, calls):
    return message(id, "assistant", text, reasoning, {
        "kind": "assistant", "completion": "complete", "tool_batch_timing": {"wall_us": 5000000}, "binding": binding, "provider_items": [],
        "calls": [{"id": c[0], "name": c[1], "arguments": c[2]} for c in calls]})


def result(id, owner, call, text, outcome="completed", us=None, stats=None):
    record = {"kind": "result", "assistant_id": owner, "call_id": call, "is_error": outcome != "completed",
              "outcome": outcome}
    if us is not None:
        record["duration_us"] = us
    if stats is not None or outcome == "completed":
        record["content"] = {"blocks": [{"type": "text", "text": text}]}
        if stats:
            record["content"]["stats"] = stats
    return message(id, "toolResult", text, record=record)


messages = [
    message("u1", "user", "Fix the parser bug in module 3 and run the tests."),
    reply("a1", "I'll look at the parser first.", "**Planning** the fix: read the parser, find the nested block case, then edit.", [
        ("c1", "read", {"path": "/Users/me/project/Sources/Parser/Parser.swift", "offset": 40, "limit": 20}),
        ("c2", "bash", {"command": "rg -n 'nestedBlock' Sources"}),
        ("c3", "ls", {"path": "/Users/me/project/Sources/Parser"}),
        ("c4", "grep", {"pattern": "closeBlock", "path": "Sources"}),
    ]),
    result("r1", "a1", "c1", "\n".join(f"    let value{i} = compute({i})" for i in range(20)), us=12_000,
           stats={"path": "/Users/me/project/Sources/Parser/Parser.swift", "line": 40, "lastLine": 59}),
    result("r2", "a1", "c2", "Sources/Parser/Parser.swift:48:    case .nestedBlock:\nSources/Parser/Lexer.swift:12: nestedBlock", us=180_000),
    result("r3", "a1", "c3", "Parser.swift\nLexer.swift\nToken.swift", us=3_000),
    result("r4", "a1", "c4", "Sources/Parser/Parser.swift:61: closeBlock()", us=94_000),
    reply("a2", "", "", [
        ("c5", "edit", {"path": "/Users/me/project/Sources/Parser/Parser.swift",
                        "oldText": "case .nestedBlock:\n    return parse(input)",
                        "newText": "case .nestedBlock:\n    offsets.keep()\n    return parse(input)"}),
        ("c6", "bash", {"command": "swift test --filter ParserTests"}),
        ("c7", "bash", {"command": "swift build -c release 2>&1 | tail -20"}),
        ("c8", "write", {"path": "/Users/me/project/NOTES.md", "content": "Parser fix notes\n"}),
    ]),
    result("r5", "a2", "c5", "Edited", us=8_000,
           stats={"path": "/Users/me/project/Sources/Parser/Parser.swift", "line": 48, "lastLine": 50, "added": 1, "removed": 0}),
    result("r6", "a2", "c6", "error: no tests matched 'ParserTests'\nexit 1", outcome="failed", us=4_200_000),
    result("r7", "a2", "c7", "", outcome="unknown", us=61_000_000),
    result("r8", "a2", "c8", "", outcome="not-executed"),
    message("a3", "assistant", "The parser now keeps its offsets when a nested block closes early. The focused test run did not match any tests, so I left the build to you."),
    message("u2", "user", "Thanks. What does `closeBlock` do?"),
    message("a4", "assistant", "It pops the current block off the stack and records where it ended."),
]
template["messages"] = messages
template["title"] = "Work rows"
json.dump(template, open(sys.argv[2], "w"), indent=1)
