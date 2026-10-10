#!/usr/bin/env python3
"""Loopback Responses provider for the macOS tools acceptance run.

Fixed, harmless tool calls chosen by a keyword in the latest user message; one
call per round trip, then a closing message. Nothing leaves the Mac, no model
is involved, prompt text is never executed. Usage: tools-gateway.py PORT LOGDIR
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(sys.argv[1])
LOG = Path(sys.argv[2])
LOG.mkdir(parents=True, exist_ok=True)

BASH = {
    # The bash fixture's own commands (rust/fixtures/bash_workflow_fixture.py).
    "BASH_LIVE": ("for i in 1 2 3 4 5 6; do printf 'live fixture %s\\n' \"$i\"; sleep 0.4; done", 10),
    "BASH_STOP": ("printf 'stop fixture started\\n'; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'still running\\n'; sleep 1; done", 20),
    "BASH_FAIL": ("printf 'generated stderr\\n' >&2; exit 7", 3),
    "BASH_AFTER_PICKER": ("printf 'bash after picker\\n'; ls", 10),
}
CALLS = {
    "LIST_PROJECT": [("ls", {"path": "."})],
    "READ_FILE": [("read", {"path": "open-me.txt"})],
    "WRITE_EDIT": [
        ("write", {"path": "notes.txt", "content": "first line\nsecond line\n"}),
        ("edit", {"path": "notes.txt", "oldText": "second line", "newText": "edited line"}),
        ("read", {"path": "notes.txt"}),
    ],
    **{key: [("bash", {"command": command, "timeout": timeout})] for key, (command, timeout) in BASH.items()},
}
lock = threading.Lock()
count = [0]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, value, status=200):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        body = json.loads(raw)
        with lock:
            count[0] += 1
            (LOG / f"{count[0]:04}.json").write_bytes(raw)
        inputs = body.get("input", [])
        users = [i for i, item in enumerate(inputs) if item.get("role") == "user"]
        last = users[-1] if users else -1
        content = inputs[last].get("content", []) if users else []
        text = content if isinstance(content, str) else "\n".join(p.get("text", "") for p in content)
        kind = next((key for key in CALLS if key in text), None)
        done = sum(1 for item in inputs[last + 1:] if item.get("type") == "function_call_output")
        offered = {tool.get("name") for tool in body.get("tools", [])}
        plan = CALLS.get(kind, [])
        if plan and done < len(plan) and plan[done][0] in offered:
            name, arguments = plan[done]
            output = [{"type": "function_call", "call_id": f"{kind.lower()}-{done}", "name": name, "arguments": json.dumps(arguments)}]
        else:
            if plan and done < len(plan):
                answer = f"{plan[done][0]} was not offered (offered: {', '.join(sorted(offered)) or 'none'})."
            else:
                answer = f"Acceptance step {kind or 'none'} finished after {done} tool calls."
            output = [{"type": "message", "content": [{"type": "output_text", "text": answer}]}]
        self.respond({"status": "completed", "output": output, "usage": {}})


server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.daemon_threads = True
print(json.dumps({"listening": f"127.0.0.1:{PORT}"}), flush=True)
server.serve_forever()
