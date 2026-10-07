#!/usr/bin/env python3
"""Local-only manual compaction UI fixture; no model or external requests.
First summary completes. The second summary streams partial text then waits,
so Stop/reopen can be exercised. Ordinary turns return labelled synthetic
history large enough to make another compaction useful. No token/cost usage is
invented or reported. Logs contain synthetic request bodies, never credentials.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=47841)
parser.add_argument("--log", type=Path, required=True)
args = parser.parse_args()
lock = threading.Lock()
summary_count = 0

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        global summary_count
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 32 * 1024 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(length))
        is_summary = body.get("tool_choice") == "none"
        with lock:
            if is_summary:
                summary_count += 1
            ordinal = summary_count
            with args.log.open("a", encoding="utf-8") as log:
                log.write(json.dumps({"summary": is_summary, "body": body}) + "\n")
        if is_summary:
            text = ("Local compaction fixture checkpoint.\n"
                    "## Objective and constraints\nValidate manual compaction using synthetic history and loopback only.\n"
                    "## Progress and evidence\nThe fixture received intact history and a checkpoint instruction.\n"
                    "## Decisions and uncertainty\nNo AI service was contacted; no token usage or cost is reported.\n"
                    "## Next steps and references\nInspect the next request, preserve the draft, and continue the fixture.")
        else:
            text = "Local continuation fixture evidence; no AI service was contacted.\n" * 700
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if is_summary and ordinal > 1:
                self.event({"type": "response.output_text.delta", "delta": "Partial local checkpoint evidence retained if stopped."})
                time.sleep(30)
            else:
                self.event({"type": "response.output_text.delta", "delta": text})
                time.sleep(0.3)
            self.event({"type": "response.completed", "response": {"status": "completed", "output": [{"type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": text}]}]}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()

    def log_message(self, *_):
        pass

print(f"Local-only compaction fixture on 127.0.0.1:{args.port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
