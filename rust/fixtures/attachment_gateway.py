#!/usr/bin/env python3
"""Disposable numeric-loopback Responses fixture. Never forwards or spends money.
Logs bounded structural facts and hashes, never image data, keys or raw captions.
"""
import argparse
import hashlib
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_REQUEST = 32 * 1024 * 1024
lock = threading.Lock()
count = 0
failed_once = set()
log_path = None


def record(value):
    with lock:
        with log_path.open("a", encoding="utf-8") as output:
            output.write(json.dumps(value, sort_keys=True) + "\n")


def structure(body):
    rows = []
    for item in body.get("input", []):
        if item.get("role") != "user":
            continue
        parts = item.get("content", [])
        if not isinstance(parts, list):
            parts = []
        images = []
        texts = []
        for part in parts:
            if part.get("type") == "input_image":
                value = part.get("image_url", "")
                header, _, data = value.partition(",")
                images.append({"mime": header.split(";")[0].removeprefix("data:"),
                               "base64_bytes": len(data),
                               "sha256": hashlib.sha256(data.encode()).hexdigest()})
            elif part.get("type") == "input_text":
                texts.append(part.get("text", ""))
        rows.append({"types": [part.get("type") for part in parts],
                     "images": images,
                     "text_bytes": sum(len(text.encode()) for text in texts),
                     "text_sha256": hashlib.sha256("\n".join(texts).encode()).hexdigest()})
    return rows


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/status":
            self.send_error(404)
            return
        with lock:
            payload = json.dumps({"requests": count}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        global count
        if not self.path.rstrip("/").endswith("/responses"):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_REQUEST:
                raise ValueError("size")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("object")
            rows = structure(body)
            users = [row for row in body.get("input", []) if row.get("role") == "user"]
            last = users[-1].get("content", []) if users else []
            text = "\n".join(part.get("text", "") for part in last
                             if isinstance(part, dict) and part.get("type") == "input_text")
        except (ValueError, TypeError, AttributeError):
            self.send_error(400, "Invalid bounded fixture request")
            return
        with lock:
            count += 1
            index = count
            identity = hashlib.sha256(json.dumps(rows[-1:] if rows else []).encode()).hexdigest()
            fail = text.startswith("fail once fixture") and identity not in failed_once
            if fail:
                failed_once.add(identity)
        record({"kind": "responses", "request": index, "model": body.get("model"),
                "wire_bytes": length, "users": rows,
                "fixture_action": "fail-once" if fail else "stream" if text.startswith("stream fixture") else "complete"})
        if fail:
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        answer = f"Fixture response {index}: retained image request received."
        try:
            if text.startswith("stream fixture"):
                for _ in range(60):
                    self.wfile.write(b'data: {"type":"response.output_text.delta","delta":"Streaming fixture. "}\n\n')
                    self.wfile.flush()
                    time.sleep(0.5)
            if "Create a concise continuation checkpoint" in text:
                answer = "## Objective and constraints\nExercise the generated image fixture.\n## Progress and evidence\nImages were retained in user history.\n## Decisions and uncertainty\nNo external service was contacted.\n## Next steps and references\nContinue the isolated acceptance checks."
            event = {"type": "response.completed", "response": {"status": "completed",
                     "output": [{"type": "message", "content": [{"type": "output_text", "text": answer}]}]}}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            record({"kind": "client-closed", "request": index})
        finally:
            self.close_connection = True


def main():
    global log_path
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=47883)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    log_path = args.log
    log_path.parent.mkdir(parents=True, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
