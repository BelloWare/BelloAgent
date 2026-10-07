#!/usr/bin/env python3
"""Disposable saved-runtime Bash GUI fixture. Fixed commands; loopback only.

Initialization never edits an existing directory, trusts a project, starts an app,
changes its mode, or discovers credentials. The operator explicitly selects the
fixture connection/project and Editing mode through the ordinary app workflow.
"""
import argparse
import hashlib
import json
import shutil
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

COMMANDS = {
    "BASH_LIVE": ("for i in 1 2 3 4 5 6; do printf 'live fixture %s\\n' \"$i\"; sleep 0.4; done", 10),
    "BASH_STOP": ("printf 'stop fixture started\\n'; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'still running\\n'; sleep 1; done", 20),
    "BASH_FAIL": ("printf 'generated stderr\\n' >&2; exit 7", 3),
    "BASH_TIMEOUT": ("sleep 4 & exit 0", 1),
    "BASH_MALFORMED": ("head -c 32768 /dev/zero | tr '\\0' '\\377'; exit 3", 3),
}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_root(path):
    if path.is_symlink():
        raise ValueError("Fixture root must not be a symbolic link")
    root = path.resolve(strict=True)
    marker = root / "fixture.json"
    if marker.is_symlink() or marker.stat().st_size > 8192:
        raise ValueError("Unsafe marker")
    value = json.loads(marker.read_text())
    if value.get("kind") != "generated-bash-workflow-v1":
        raise ValueError("Not a generated Bash fixture")
    uuid.UUID(value["id"])
    if not 1024 <= value["port"] <= 65535:
        raise ValueError("Bad fixture port")
    return root, value


def initialize(args):
    root = args.root.absolute()
    if root.exists() or root.is_symlink():
        raise ValueError("Choose a new fixture directory")
    if not 1024 <= args.port <= 65535:
        raise ValueError("Use an unprivileged port")
    root.mkdir(parents=True, mode=0o700)
    for name in ["project", "state", "evidence/requests", "evidence/screenshots", "home", "tmp", "config", "data", "cache", "bin"]:
        (root / name).mkdir(parents=True, mode=0o700)
    marker = {"kind": "generated-bash-workflow-v1", "id": str(uuid.uuid4()), "port": args.port}
    write_json(root / "fixture.json", marker)
    write_json(root / "profile.json", {"id": str(uuid.uuid4()), "api": "openai-responses", "providerId": "litellm", "baseUrl": f"http://127.0.0.1:{args.port}", "modelId": "bash-fixture", "contextWindow": 32000, "maxOutputTokens": 4096, "input": ["text", "image"]})
    (root / "project/AGENTS.md").write_text("Generated disposable Bash acceptance project. Fixed fixture commands only.\n")
    (root / "project/open-me.txt").write_text("Generated file-open compatibility check.\n")
    print(json.dumps({"root": str(root), **marker}, sort_keys=True))


def serve(args):
    root, marker = load_root(args.root)
    lock = threading.Lock()
    state = {"requests": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.respond({"fixture_id": marker["id"], "requests": state["requests"]})

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
            if self.path != "/v1/responses":
                self.respond({"error": "unsupported fixture path"}, 404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 32 * 1024 * 1024:
                self.respond({"error": "bounded request required"}, 413)
                return
            raw = self.rfile.read(length)
            body = json.loads(raw)
            with lock:
                state["requests"] += 1
                index = state["requests"]
                (root / f"evidence/requests/{index:04}.json").write_bytes(raw)
            inputs = body.get("input", [])
            users = [i for i, item in enumerate(inputs) if item.get("role") == "user"]
            last_user = users[-1] if users else -1
            content = inputs[last_user].get("content", []) if users else []
            text = content if isinstance(content, str) else "\n".join(p.get("text", "") for p in content)
            kind = next((key for key in COMMANDS if key in text), None)
            results = [item for item in inputs[last_user + 1:] if item.get("type") == "function_call_output"]
            offered = any(tool.get("name") == "bash" for tool in body.get("tools", []))
            if kind and offered and not results:
                command, timeout = COMMANDS[kind]
                output = [{"type": "function_call", "call_id": "reused-fixture-call", "name": "bash", "arguments": json.dumps({"command": command, "timeout": timeout})}]
            else:
                answer = "Generated fixture completed. No external provider was contacted."
                if kind and not offered:
                    answer = "Bash was not offered. Select the trusted saved chat's Editing mode to run this fixture."
                output = [{"type": "message", "content": [{"type": "output_text", "text": answer}]}]
            self.respond({"status": "completed", "output": output, "usage": {}})

    server = ThreadingHTTPServer(("127.0.0.1", marker["port"]), Handler)
    server.daemon_threads = True
    print(json.dumps({"listening": f"127.0.0.1:{marker['port']}", "fixture_id": marker["id"]}), flush=True)
    server.serve_forever()


def seal(args):
    root, marker = load_root(args.root)
    source = args.binary.resolve(strict=True)
    if not source.is_file():
        raise ValueError("Expected an existing build artifact")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    target = root / "bin" / ("bello-agent-bash-" + digest[:16])
    if target.exists():
        raise ValueError("This artifact is already sealed")
    shutil.copyfile(source, target)
    target.chmod(0o700)
    assert hashlib.sha256(target.read_bytes()).hexdigest() == digest
    write_json(root / "evidence/sealed-build.json", {"fixture_id": marker["id"], "binary": str(target), "binary_sha256": digest})
    print(json.dumps({"binary": str(target), "sha256": digest}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="operation", required=True)
    for name, callback in [("init", initialize), ("serve", serve), ("seal", seal)]:
        command = sub.add_parser(name)
        command.add_argument("--root", type=Path, required=True)
        command.set_defaults(callback=callback)
        if name == "init":
            command.add_argument("--port", type=int, required=True)
        if name == "seal":
            command.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    args.callback(args)


if __name__ == "__main__":
    main()
