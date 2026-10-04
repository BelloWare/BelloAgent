#!/usr/bin/env python3
"""Local HTTP/SSE test fixture. No model, external requests, or paid services.
Run: python3 rust/fixtures/gateway.py
Use fixtures/profile.json and any explicit fake credential. Responses identify
this server as a test fixture so screenshots cannot be mistaken for AI output.
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if size > 32 * 1024 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(size))
        text = "Local test fixture: the Rust app sent a real HTTP request and rendered this SSE response. No AI service was contacted."
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for word in text.split(" "):
                self.event({"type": "response.output_text.delta", "delta": word + " "})
                time.sleep(0.14)
            self.event({"type": "response.completed", "response": {"status": "completed", "model": body.get("model"), "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}], "usage": {"input_tokens": 16, "output_tokens": 28}}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True
    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()
    def log_message(self, format, *args):
        # Never log credentials or request headers.
        print("fixture:", format % args, flush=True)

if __name__ == "__main__":
    print("Local test-only fixture on http://127.0.0.1:47831", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 47831), Handler).serve_forever()
