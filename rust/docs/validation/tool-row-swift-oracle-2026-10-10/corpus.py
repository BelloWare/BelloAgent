#!/usr/bin/env python3
"""Writes corpus.json: tool calls crossing every rule the row model reads.

Inputs are compact JSON with sorted keys, as the Rust side serializes its
parsed arguments, so the fallback that shows a raw document reads the same.
"""
import json

STATES = ["completed", "failed", "cancelled", "unknown", "running", "prepared", "preparing", "recorded"]


def args(**values):
    return json.dumps(values, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


tools = []


def add(name, input, state="completed", output="", duration=None, **extra):
    tool = {"id": f"call-{len(tools)}", "name": name, "state": state, "input": input, "output": output,
            "durationMs": duration, "truncated": False}
    tool.update({k: v for k, v in extra.items() if v is not None})
    tools.append(tool)


# Every state for one call of each kind.
kinds = [
    ("bash", args(command="npm test")),
    ("read", args(path="/Users/me/project/src/main.rs")),
    ("write", args(path="/Users/me/project/notes.md", content="hello\nworld")),
    ("edit", args(path="src/lib.rs", oldText="a", newText="b")),
    ("ls", args(path="/tmp/a/b")),
    ("find", args(pattern="*.swift")),
    ("grep", args(pattern="TODO", path=".")),
    ("mcp", args(action="invoke", server="github", tool="search")),
    ("web_fetch", args(url="https://example.com")),
]
for name, input in kinds:
    for state in STATES:
        add(name, input, state, output="", duration=1234)
        add(name, input, state, output="  first line of output  \nsecond\nthird", duration=40)

# Paths: resolved, argument, short, deep, empty, missing, trailing slash.
for name in ["read", "write", "edit", "ls"]:
    for input in [args(path="a.txt"), args(path="a/b.txt"), args(path="/a/b/c.txt"), args(path="/a/b/c/"),
                  args(path=""), args(), args(path="//x//y//z"), args(path="日本/語/ファイル.txt")]:
        add(name, input)
        add(name, input, path="/resolved/deep/dir/file.swift")
        add(name, input, path="")
        add(name, input, state="running", path="/resolved/r.swift")
        add(name, input, state="failed", output="ENOENT: no such file\nstack", path="/resolved/f.swift")

# Change counts and the outcome-unknown suffix.
for added, removed in [(None, None), (3, 1), (5, None), (None, 2), (0, 0), (12, 0)]:
    for state in ["completed", "unknown", "failed", "running"]:
        add("write", args(path="/p/q/new.txt", content="x"), state, added=added, removed=removed)
        add("edit", args(path="/p/q/old.txt", oldText="x", newText="y"), state, added=added, removed=removed)
        add("bash", args(command="make"), state, added=added, removed=removed)

# Durations either side of every unit boundary.
for ms in [None, 0, 10, 49, 49.9, 50, 94, 95, 949, 950, 990, 999, 1000, 9949, 9950, 59400, 59500, 60000,
           61000, 119_500, 3_599_000, 3_600_000, 3_660_000, 7_200_000, 86_400_000]:
    for state in ["completed", "failed", "running", "unknown", "cancelled"]:
        add("bash", args(command="sleep 1"), state, duration=ms)

# Commands: heredocs, blank, missing, long, unicode, raw text.
long = "echo " + "abcdefghij" * 12
for input in [args(command="cat <<'EOF'\nline one\nEOF"), args(command=""), args(command="   "), args(),
              args(command="  padded command  "), args(command=long), args(command="é" * 95),
              args(command="é" * 100), args(command="👩‍👩‍👧" * 100), args(command="\nleading newline"),
              args(command="crlf\r\nnext"), args(command=7), args(cmd="ls")]:
    add("bash", input)
    add("bash", input, "failed", output=long + "\nmore")

# Searches and MCP actions.
for input in [args(pattern=""), args(pattern="a|b"), args(), args(pattern=None)]:
    add("find", input); add("grep", input, "failed", output="bad regex")
for input in [args(action="list"), args(action="list", server="linear"), args(action="describe"),
              args(action="describe", targets=["a"]), args(action="describe", targets=["a", "b", "c"]),
              args(action="invoke"), args(action="invoke", server="s"), args(action="invoke", tool="t"),
              args(server="s", tool="t"), args(action="", server="", tool=""), args(action="list", server=3)]:
    add("mcp", input)

# Failures: the output's first line replaces the summary, bounded.
for output in ["", "\n", "   ", "one", "  spaced  \nnext", long, "x" * 96, "x" * 97, "\n\nafter blanks", "\ttab\tline\n"]:
    add("bash", args(command="false"), "failed", output=output)
    add("read", args(path="/a/b/c.txt"), "failed", output=output)

# Reads that open at their lines.
for input in [args(path="/x/y/z.txt"), args(offset=10, path="/x/y/z.txt"), args(limit=5, path="/x/y/z.txt"),
              args(offset=0, path="/x/y/z.txt"), args(offset=2.5, path="/x/y/z.txt"), args(offset=True, path="/x/y/z.txt"),
              args(offset=None, path="/x/y/z.txt"), args(offset=10_000_001, path="/x/y/z.txt"), args(offset="3", path="/x/y/z.txt")]:
    for output in ["", "a\nb\nc", "a\nb\n[Truncated. 900 total lines; read another range.]", "Read image file [image/png]", "one"]:
        add("read", input, output=output)
    add("read", input, output="a\nb", line=40, lastLine=41)
    add("read", input, output="a\nb", line=7)
    add("read", input, output="a\nb", line=0)
    add("read", input, "running")
    add("read", input, "running", inputTruncated=True)
add("write", args(path="/w/x.txt"), inputTruncated=True)
add("edit", args(path="/w/x.txt"), line=3, lastLine=1)
add("edit", args(path="/w/x.txt"), line=3, lastLine=9)
add("edit", args(path="/w/x.txt"), "failed", line=3, lastLine=9)

# Raw, non-JSON arguments.
add("bash", "not json at all")

# Work summaries.
def row(id, states, count=None, truncated=None):
    message = {"id": id, "role": "assistant", "text": "",
               "tools": [{"id": f"{id}-{i}", "name": "bash", "state": s, "input": "{}", "output": "",
                          "durationMs": None, "truncated": False} for i, s in enumerate(states)]}
    if count is not None:
        message["toolCallCount"] = count
    if truncated is not None:
        message["truncated"] = truncated
    return message


summaries = []
for reasoned in [False, True]:
    for rows in [[], [row("a", [])], [row("a", ["completed"])], [row("a", ["completed", "completed"])],
                 [row("a", ["failed", "cancelled", "skipped", "unknown", "recorded", "interrupted", "running"])],
                 [row("a", ["preparing"])], [row("a", ["completed", "preparing"])],
                 [row("a", ["completed"], count=5)], [row("a", ["completed"], truncated=True)],
                 [row("a", ["completed"]), row("b", ["failed", "failed"])], [row("a", ["completed"]), row("a", ["failed"])],
                 [row("a", ["completed"], count=0)], [row("a", ["failed"], count=-1, truncated=True)]]:
        summaries.append({"reasoned": reasoned, "rows": rows})

print(json.dumps({"tools": tools, "summaries": summaries}, indent=1, ensure_ascii=False, sort_keys=True))
