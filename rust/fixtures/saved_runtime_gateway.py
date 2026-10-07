#!/usr/bin/env python3
"""Disposable numeric-loopback saved runtime UI fixture. No external requests.

Only sanitized contract facts are recorded. Credentials and custom header bytes
are never logged. A first `list fixture` request asks the app to execute real ls;
`stall fixture` retains a partial response until Stop closes the connection.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=47831)
parser.add_argument("--log", required=True)
args = parser.parse_args()
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 <= size <= 32 * 1024 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(size))
        inputs = body.get("input", [])
        last_user = ""
        for item in inputs:
            if item.get("role") == "user":
                content = item.get("content", "")
                last_user = content if isinstance(content, str) else " ".join(part.get("text", "") for part in content)
        last_tool = bool(inputs and inputs[-1].get("type") == "function_call_output")
        tool_names = [tool.get("name") for tool in body.get("tools", [])]
        wants_tool = "list fixture" in last_user.lower() and not last_tool
        stalls = "stall fixture" in last_user.lower()
        with lock, open(args.log, "a", encoding="utf-8") as output:
            output.write(json.dumps({
                "model": body.get("model"), "tools": tool_names,
                "tool_result": last_tool, "request_kind": "stall" if stalls else "ls" if wants_tool else "answer",
                "fixture_authorization": self.headers.get("Authorization") == "Bearer synthetic-project-fixture-only",
                "custom_header_present": self.headers.get("x-fixture") is not None,
            }) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if wants_tool:
                assert "ls" in tool_names, "the UI must offer the actual saved-runtime capability"
                output = [{"type": "function_call", "id": "fixture-call", "call_id": "fixture-ls", "name": "ls", "arguments": '{"path":"."}'}]
                self.event({"type": "response.completed", "response": {"status": "completed", "output": output}})
            else:
                text = "Local fixture: " + ("real project ls result received; saved runtime continued." if last_tool else "partial response retained; press Stop." if stalls else "saved connection request received. No paid service contacted.")
                self.event({"type": "response.output_text.delta", "delta": text})
                if stalls:
                    for _ in range(240):
                        time.sleep(0.25)
                        self.wfile.write(b": fixture wait\n\n")
                        self.wfile.flush()
                self.event({"type": "response.completed", "response": {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}]}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()

    def log_message(self, fmt, *values):
        print("fixture:", fmt % values, flush=True)


if __name__ == "__main__":
    print(f"Saved runtime fixture on http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
