#!/usr/bin/env python3
"""Numeric-loopback catalog/Responses fixture. Logs contract facts, no secrets.

Run a second instance on another port for the external-origin catalog case.
/catalog returns 170 searchable synthetic rows; /fail, /malformed, /redirect,
/delayed exercise refresh, parser, redirect and stale-result boundaries. No tools
are requested, and POST is accepted only at the explicit Responses route.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from pathlib import Path


def models():
    return {"version": 1, "models": [
        {"id": f"fixture-model-{i:03}", "name": f"Fixture model {i:03}",
         "description": "Disposable loopback catalog entry; no paid service.",
         "contextWindow": 32000, "maxOutputTokens": 8192 if i == 169 else 1024,
         "reasoning": ["low"], "input": ["text", "image"],
         "deprecated": i == 2, "order": i} for i in range(170)]}


def serve(port, log, mode_file=None):
    lock = threading.Lock()

    def record(value):
        with lock, open(log, "a", encoding="utf-8") as out:
            out.write(json.dumps(value, sort_keys=True) + "\n")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def facts(self, method, kind):
            return {"method": method, "kind": kind,
                    "fixture_authorization": self.headers.get("Authorization") == "Bearer synthetic-project-fixture-only",
                    "any_authorization": self.headers.get("Authorization") is not None,
                    "custom_header_present": self.headers.get("X-Fixture") is not None,
                    "accept_json": self.headers.get("Accept") == "application/json",
                    "no_cache": self.headers.get("Cache-Control") == "no-cache"}

        def do_GET(self):
            kind = urlsplit(self.path).path.removeprefix("/")
            if kind not in {"catalog", "fail", "malformed", "redirect", "delayed"}:
                kind = "unknown"
            record(self.facts("GET", kind))
            if kind == "delayed":
                time.sleep(3)
            if kind == "redirect":
                self.send_response(302)
                self.send_header("Location", "/catalog")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            forced_failure = mode_file is not None and Path(mode_file).exists() and Path(mode_file).read_text().strip() == "fail"
            status = 503 if kind == "fail" or (kind == "catalog" and forced_failure) else 404 if kind == "unknown" else 200
            body = b"not valid catalog JSON" if kind == "malformed" else json.dumps(models()).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                record({"method": "CANCELLED", "kind": kind})
            self.close_connection = True

        def do_POST(self):
            if self.path != "/v1/responses":
                self.send_error(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 32 * 1024 * 1024:
                self.send_error(413)
                return
            try:
                body = json.loads(self.rfile.read(size))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self.send_error(400)
                return
            facts = self.facts("POST", "responses")
            facts.update(model=body.get("model"), max_output_tokens=body.get("max_output_tokens"), reasoning=body.get("reasoning"), tools=len(body.get("tools", [])))
            record(facts)
            event = {"type": "response.completed", "response": {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Local catalog fixture request completed. No paid service contacted."}]}]}}
            payload = ("data: " + json.dumps(event) + "\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True

        def log_message(self, *_):
            pass  # URLs, headers and response bodies are never logged.

    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--mode-file")
    args = parser.parse_args()
    serve(args.port, args.log, args.mode_file)
