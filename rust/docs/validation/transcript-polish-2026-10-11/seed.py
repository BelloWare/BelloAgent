#!/usr/bin/env python3
"""Seeds the GUI check's session: seed.py template.json out.json

The transcript-structure seed's turns, then a turn that reads 40 lines of a
file and edits 30, so the read window and the diff cap."""
import json, os, sys, runpy
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../transcript-structure-gui-2026-10-10/seed.py")
sys.argv = [base, sys.argv[1], sys.argv[2]]
runpy.run_path(base, run_name="__main__")
data = json.load(open(sys.argv[2]))
binding = {"profile_id": "bench-gateway", "api": "openai-responses", "provider": "litellm", "model": "bench-model", "endpoint_sha256": "0" * 64}
def message(id, role, text="", reasoning="", record=None):
    m = {"id": id, "role": role, "text": text, "reasoning": reasoning, "replay_eligible": True, "state": "completed", "usage": None, "model": "bench-model" if role == "assistant" else None}
    if record: m["tool_record"] = record
    return m
old = "\n".join(f"line {i}" for i in range(30))
new = "\n".join(f"line {i}" if i % 7 else f"line {i} changed" for i in range(30))
read = "\n".join(f"    func step{i}() {{ compute({i}) }}" for i in range(1, 41))
data["messages"] += [
    message("u3", "user", "Show me the long file and widen the edit."),
    message("a5", "assistant", "Reading it now.", "Read, then edit.", {"kind": "assistant", "completion": "complete", "tool_batch_timing": {"wall_us": 2000000}, "binding": binding, "provider_items": [],
        "calls": [{"id": "c9", "name": "read", "arguments": {"path": "/Users/me/project/Sources/Steps.swift", "offset": 995}},
                  {"id": "c10", "name": "edit", "arguments": {"path": "/Users/me/project/Sources/Lines.txt", "oldText": old, "newText": new}}]}),
    message("r9", "toolResult", read, record={"kind": "result", "assistant_id": "a5", "call_id": "c9", "is_error": False, "outcome": "completed", "duration_us": 9000,
        "content": {"blocks": [{"type": "text", "text": read}], "stats": {"path": "/Users/me/project/Sources/Steps.swift", "line": 995, "lastLine": 1034}}}),
    message("r10", "toolResult", "Edited", record={"kind": "result", "assistant_id": "a5", "call_id": "c10", "is_error": False, "outcome": "completed", "duration_us": 9000,
        "content": {"blocks": [{"type": "text", "text": "Edited"}], "stats": {"path": "/Users/me/project/Sources/Lines.txt", "line": 1, "lastLine": 30, "added": 5, "removed": 5}}}),
    message("a6", "assistant", "Both are open above."),
]
json.dump(data, open(sys.argv[2], "w"), indent=1)
