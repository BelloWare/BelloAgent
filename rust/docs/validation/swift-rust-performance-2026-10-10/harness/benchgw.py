#!/usr/bin/env python3
"""Deterministic loopback Responses gateway for Swift-vs-Rust benchmarks.

No model, no external requests, no credentials: any bearer value is accepted and
never logged. Every streamed reply is generated from a fixed seed so both apps
receive byte-identical deltas at the same schedule.

Environment:
  BENCH_PORT          listening port (default 47900)
  BENCH_REPLY_CHARS   characters in a streamed reply (default 96000)
  BENCH_CHUNK_CHARS   characters per output_text.delta (default 32)
  BENCH_DELAY_MS      delay between deltas in ms (default 20 -> 50 Hz)
  BENCH_LOG           JSONL file for request records (timestamps only)
"""
import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("BENCH_PORT", "47900"))
REPLY_CHARS = int(os.environ.get("BENCH_REPLY_CHARS", "96000"))
CHUNK = int(os.environ.get("BENCH_CHUNK_CHARS", "32"))
DELAY = float(os.environ.get("BENCH_DELAY_MS", "20")) / 1000.0
LOG = os.environ.get("BENCH_LOG")


def reply_text(chars):
    parts, i = [], 0
    while sum(len(p) for p in parts) < chars:
        parts.append(
            f"## Finding {i}\n\nThe parser in module {i % 17} reads the token stream twice when **a nested block** "
            f"closes early, so `parse(input:)` returns a shorter tree than the caller expects. This paragraph is long "
            f"enough to wrap across the pane at its usual width.\n\n- The first pass keeps the offsets.\n"
            f"- The second pass loses them after a nested block.\n\n```swift\n"
            + "\n".join(f"    let value{j} = compute({i}, {j}) // step {j} of the pass" for j in range(8 + i % 12))
            + "\n```\n\n")
        i += 1
    return "".join(parts)[:chars]


TEXT = reply_text(REPLY_CHARS)


class Gateway(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def record(self, value):
        if LOG:
            with open(LOG, "a") as stream:
                stream.write(json.dumps(value) + "\n")

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models") or self.path == "/catalog":
            body = json.dumps({"object": "list", "data": [{"id": "bench-model", "object": "model"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(size) if size else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        started = time.time()
        rid = uuid.uuid4().hex
        model = body.get("model", "bench-model")
        if not self.path.endswith("/responses"):
            self.send_error(404)
            return
        if not body.get("stream", False):
            text = "Bench reply."
            response = json.dumps({"id": "resp_" + rid, "object": "response", "status": "completed", "model": model,
                                   "output": [{"id": "msg_" + rid, "type": "message", "role": "assistant", "status": "completed",
                                               "content": [{"type": "output_text", "text": text, "annotations": []}]}],
                                   "usage": {"input_tokens": len(raw) // 4, "output_tokens": 3, "total_tokens": len(raw) // 4 + 3}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
            self.record({"id": rid, "stream": False, "requestBytes": len(raw), "start": started, "end": time.time()})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        item = "msg_" + rid
        sent = 0
        cancelled = False

        def emit(event):
            self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
            self.wfile.flush()

        try:
            emit({"type": "response.created", "response": {"id": "resp_" + rid, "object": "response", "model": model, "status": "in_progress", "output": []}})
            emit({"type": "response.output_item.added", "output_index": 0, "item": {"id": item, "type": "message", "role": "assistant", "status": "in_progress", "content": []}})
            emit({"type": "response.content_part.added", "output_index": 0, "item_id": item, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}})
            next_at = time.monotonic()
            for offset in range(0, len(TEXT), CHUNK):
                next_at += DELAY
                pause = next_at - time.monotonic()
                if pause > 0:
                    time.sleep(pause)
                emit({"type": "response.output_text.delta", "output_index": 0, "item_id": item, "content_index": 0, "delta": TEXT[offset:offset + CHUNK]})
                sent += 1
            emit({"type": "response.output_text.done", "output_index": 0, "item_id": item, "content_index": 0, "text": TEXT})
            output = [{"type": "message", "id": item, "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": TEXT, "annotations": []}]}]
            emit({"type": "response.output_item.done", "output_index": 0, "item": output[0]})
            emit({"type": "response.completed", "response": {"id": "resp_" + rid, "object": "response", "model": model, "status": "completed", "output": output,
                                                              "usage": {"input_tokens": len(raw) // 4, "output_tokens": len(TEXT) // 4, "total_tokens": len(raw) // 4 + len(TEXT) // 4}}})
        except (BrokenPipeError, ConnectionResetError):
            cancelled = True
        self.record({"id": rid, "stream": True, "requestBytes": len(raw), "deltas": sent, "cancelled": cancelled, "start": started, "end": time.time()})
        self.close_connection = True


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Gateway)
    print(json.dumps({"port": server.server_port, "replyChars": len(TEXT), "chunk": CHUNK, "delayMs": DELAY * 1000}), flush=True)
    server.serve_forever()
