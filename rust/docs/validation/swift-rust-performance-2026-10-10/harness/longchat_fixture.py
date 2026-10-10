#!/usr/bin/env python3
"""Generate one synthetic long conversation in two encodings with identical text:

  <out>/swift-long.jsonl   pi session journal (version 3) read by Swift Bello Agent
  <out>/conversation.json  [{"role": "user"|"assistant", "text": ...}] for the Rust seeder

Content mirrors the Swift LongChatScroll fixture's questions and replies (headings,
paragraphs, lists, Swift code blocks) without tool calls, so both apps render the
same Markdown. Usage: longchat_fixture.py OUT TURNS
"""
import json
import os
import sys

out, turns = sys.argv[1], int(sys.argv[2])
os.makedirs(out, exist_ok=True)


def code(lines, seed):
    return "\n".join(f"    let value{i} = compute({seed}, {i}) // step {i} of the pass" for i in range(lines))


conversation = []
for turn in range(turns):
    question = f"Question {turn}: please look at module {turn % 17} and tell me what changed in the parser."
    if turn % 9 == 4:
        question += "\n\nHere is the failing part:\n\n```swift\n" + code(18 + turn % 20, turn) + "\n```\n\nWhy does it fail?"
    conversation.append({"role": "user", "text": question})
    sections = 40 if turn % 37 == 20 else 1 + turn % 4
    parts = []
    for section in range(sections):
        parts.append(
            f"## Finding {turn}.{section}\n\nThe parser in module {turn % 17} reads the token stream twice when **a nested block** closes early, "
            "so `parse(input:)` returns a shorter tree than the caller expects. This paragraph is long enough to wrap across the pane at its usual width.\n\n"
            "- The first pass keeps the offsets.\n- The second pass loses them after a nested block.\n\n"
            "```swift\n" + code(8 + (turn + section) % 22, turn * 100 + section) + "\n```\n")
    reply = "\n".join(parts) + f"\n\nThat is everything for question {turn}." + (" zephyr checkpoint 42" if turn == turns // 2 else "")
    conversation.append({"role": "assistant", "text": reply})

with open(os.path.join(out, "conversation.json"), "w") as stream:
    json.dump(conversation, stream)

with open(os.path.join(out, "swift-long.jsonl"), "w") as stream:
    stream.write(json.dumps({"type": "session", "version": 3, "id": "long"}) + "\n")
    parent = None
    for index, message in enumerate(conversation):
        turn, kind = divmod(index, 2)
        mid = f"u{turn}" if kind == 0 else f"a{turn}"
        stream.write(json.dumps({"type": "message", "id": mid, "parentId": parent,
                                 "message": {"role": message["role"], "content": message["text"]}}) + "\n")
        parent = mid

chars = sum(len(m["text"]) for m in conversation)
print(json.dumps({"turns": turns, "messages": len(conversation), "characters": chars,
                  "uniqueSearchTerm": "zephyr checkpoint 42"}))
