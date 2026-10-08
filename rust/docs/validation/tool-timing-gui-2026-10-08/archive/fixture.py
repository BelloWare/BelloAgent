#!/usr/bin/env python3
"""Generated A5 Responses/MCP/Bash acceptance fixture; numeric loopback only.

No credential discovery, outbound connection, app launch, trust mutation or
transcript injection. All effects stay inside a fresh explicitly generated root.
Server observations are protocol receipts, not proof of client physical reaping.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KIND = "generated-a5-concurrency-v1"
KEY = "synthetic-project-fixture-only"
HEADER = "synthetic-header-fixture-only"
MODES = {"A5_FORWARD", "A5_REVERSE", "A5_STOP"}
MAX_BODY = 2 * 1024 * 1024
MAX_LOG = 8 * 1024 * 1024
MAX_RUNS = 12
RUN = re.compile(r"^r[0-9]{4}$")


def write_json(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    temporary = path.with_name(path.name + ".tmp")
    with open(temporary, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    temporary.chmod(0o600)
    temporary.replace(path)


def load_root(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Root must not be a symlink")
    root = path.resolve(strict=True)
    marker = root / "fixture.json"
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 8192:
        raise ValueError("Invalid generated fixture marker")
    config = json.loads(marker.read_text())
    if config.get("kind") != KIND:
        raise ValueError("Not an A5 generated fixture")
    uuid.UUID(config["id"])
    if not 1024 <= config["port"] <= 65535 or not 5 <= config["hold_seconds"] <= 90:
        raise ValueError("Invalid bounded fixture settings")
    for part in ["project", "project/runs", "state", "evidence"]:
        if (root / part).is_symlink() or not (root / part).is_dir():
            raise ValueError("Unsafe generated fixture directory")
    return root, config


def initialize(root, port, hold_seconds=90):
    root = Path(root).absolute()
    if root.exists() or root.is_symlink():
        raise ValueError("Initialization requires a new directory")
    if not 1024 <= port <= 65535 or not 5 <= hold_seconds <= 90:
        raise ValueError("Use an unprivileged port and 5–90 second holds")
    root.mkdir(parents=True, mode=0o700)
    for part in ["project/runs", "state", "evidence/screenshots", "home", "config", "data", "cache", "tmp", "bin"]:
        (root / part).mkdir(parents=True, mode=0o700)
    config = {"kind": KIND, "id": str(uuid.uuid4()), "port": port, "hold_seconds": hold_seconds}
    write_json(root / "fixture.json", config)
    write_json(root / "profile.json", {"id": str(uuid.uuid4()), "api": "openai-responses", "providerId": "litellm", "modelId": "a5-concurrency-fixture", "baseUrl": f"http://127.0.0.1:{port}", "contextWindow": 32000, "maxOutputTokens": 4096, "input": ["text", "image"]})
    write_json(root / "mcp-config.json", {"servers": {"fixture": {"transport": "http", "url": f"http://127.0.0.1:{port}/mcp", "allowedTools": ["held"], "timeoutSeconds": min(300, hold_seconds + 10)}}})
    (root / "project/AGENTS.md").write_text("Generated disposable concurrency acceptance only. No external service, personal file or real credential.\n")
    (root / "project/fixture.txt").write_text("Generated A5 native ls fixture.\n")
    return config


class State:
    def __init__(self, root):
        self.root, self.config = load_root(root)
        self.lock = threading.RLock()
        self.runs = {}
        self.sequence = 0
        path = self.root / "state/fixture-state.json"
        if path.exists():
            previous = json.loads(path.read_text())
            if previous.get("fixture_id") != self.config["id"]:
                raise ValueError("Mismatched fixture state")
            self.runs = previous["runs"]
            self.sequence = previous["sequence"]
            if len(self.runs) > MAX_RUNS:
                raise ValueError("Too many retained runs")

    def log(self, event, **facts):
        with self.lock:
            path = self.root / "evidence/receipts.jsonl"
            row = json.dumps({"event": event, "at_monotonic": time.monotonic(), **facts}, sort_keys=True) + "\n"
            if (path.stat().st_size if path.exists() else 0) + len(row.encode()) > MAX_LOG:
                raise ValueError("Receipt log reached its bound")
            with open(path, "a", encoding="utf8") as output:
                output.write(row)
                output.flush()

    def save(self):
        write_json(self.root / "state/fixture-state.json", {"fixture_id": self.config["id"], "sequence": self.sequence, "runs": self.runs})

    def run_path(self, run):
        if not isinstance(run, str) or not RUN.fullmatch(run) or run not in self.runs:
            raise ValueError("Unknown run")
        path = self.root / "project/runs" / run
        if path.is_symlink() or not path.is_dir():
            raise ValueError("Unsafe generated run")
        return path

    def new_run(self, mode):
        with self.lock:
            if len(self.runs) >= MAX_RUNS:
                raise ValueError("Fixture permits at most twelve explicit runs")
            self.sequence += 1
            name = f"r{self.sequence:04d}"
            self.runs[name] = {"mode": mode, "mcp_calls": 0, "mcp_entered": False, "mcp_returned": False, "continuations": 0}
            (self.root / "project/runs" / name).mkdir(mode=0o700)
            self.save()
            self.log("run-created", run=name, mode=mode)
            return name

    def snapshot(self, run=None):
        with self.lock:
            result = {}
            for name, value in self.runs.items():
                if run is not None and name != run:
                    continue
                path = self.run_path(name)
                row = dict(value)
                for marker in ["bash-entered", "bash-finished", "bash-release", "mcp-release"]:
                    leaf = path / marker
                    if leaf.is_symlink():
                        raise ValueError("Unsafe marker")
                    row[marker.replace("-", "_")] = leaf.is_file()
                row["both_entered"] = row["bash_entered"] and row["mcp_entered"]
                result[name] = row
            return {"fixture_id": self.config["id"], "runs": result}

    def release(self, run, target):
        if target not in {"bash", "mcp"}:
            raise ValueError("Release target must be bash or mcp")
        with self.lock:
            path = self.run_path(run)
            if not self.snapshot(run)["runs"][run]["both_entered"]:
                raise ValueError("Both calls must enter before either release")
            leaf = path / (target + "-release")
            with open(leaf, "x") as output:
                output.write("release\n")
            self.log("operator-release", run=run, target=target)

    def bash(self, run):
        path = shlex.quote(str(self.run_path(run)))
        iterations = self.config["hold_seconds"] * 5
        # Shell only touches this generated run. Repeated output survives the
        # client's intentionally lossy live-preview updates. Output stays <1KiB.
        command = f"cd {path} || exit 2; "
        if self.runs[run]["mode"] == "A5_STOP":
            command += "trap '' TERM; "
        command += ("printf 'entered\\n' > bash-entered; "
                    "printf 'A5 Bash entered; waiting for explicit release\\n'; ")
        command += (f"i=0; while [ ! -f bash-release ] && [ \"$i\" -lt {iterations} ]; do "
                    "printf .; sleep 0.2; i=$((i+1)); done; "
                    "if [ ! -f bash-release ]; then printf '\\nFixture hold expired\\n'; exit 124; fi; "
                    "printf 'finished\\n' > bash-finished; printf '\\nA5 Bash completed\\n'")
        return command

    def provider(self, request):
        inputs = request.get("input", [])
        if not isinstance(inputs, list):
            raise ValueError("Expected input array")
        last_user = -1
        text = ""
        for index, entry in enumerate(inputs):
            if entry.get("role") == "user":
                last_user = index
                content = entry.get("content", "")
                text = content if isinstance(content, str) else " ".join(p.get("text", "") for p in content if isinstance(p, dict))
        text = text.strip()
        results = [entry for entry in inputs[last_user + 1:] if entry.get("type") == "function_call_output"]
        all_ids = [entry.get("call_id") for entry in inputs if entry.get("type") == "function_call_output"]
        offered = {entry.get("name") for entry in request.get("tools", [])}
        self.log("provider-request", last_user_mode=text if text in MODES | {"A5_HELLO", "A5_AFTER_STOP"} else "other", result_ids=[x[:128] for x in all_ids if isinstance(x, str) and x.startswith("a5-")][:64], offered=sorted(offered & {"mcp", "bash", "ls"}))
        if results:
            ids = [entry.get("call_id") for entry in results]
            with self.lock:
                run = next((name for name in self.runs if f"a5-{name}-bash" in ids or f"a5-{name}-mcp" in ids), None)
            if run:
                expected = [f"a5-{run}-bash", f"a5-{run}-mcp"]
                ordered = ids == expected
                with self.lock:
                    self.runs[run]["continuations"] += 1
                    self.runs[run]["ordered_result_ids"] = ids
                    self.runs[run]["result_order_correct"] = ordered
                    self.save()
                self.log("provider-continuation", run=run, result_ids=ids, original_order=ordered)
                return self.answer("A5 ordered durable results received; no tool replay." if ordered else "A5 RESULT ORDER MISMATCH")
            return self.answer("Retained historical results received. No tools replayed.")
        if text in MODES:
            if not {"bash", "mcp"} <= offered:
                self.log("missing-tool-authority", required=["bash", "mcp"])
                return self.answer("A5 requires the normal saved trusted Editing chat with Bash and MCP. No tool was invoked.")
            run = self.new_run(text)
            output = [
                {"type": "function_call", "call_id": f"a5-{run}-bash", "name": "bash", "arguments": json.dumps({"command": self.bash(run), "timeout": self.config["hold_seconds"] + 5})},
                {"type": "function_call", "call_id": f"a5-{run}-mcp", "name": "mcp", "arguments": json.dumps({"action": "invoke", "server": "fixture", "tool": "held", "arguments": {"run": run}})},
            ]
            return {"status": "completed", "output": output, "usage": {}}
        return self.answer("A5 fixture ready. No tool invocation or automatic replay.")

    @staticmethod
    def answer(text):
        return {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}], "usage": {}}


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, state):
        self.state = state
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(("127.0.0.1", state.config["port"]), Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(False):
            request.sendall(b"HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            self.shutdown_request(request)
            return
        super().process_request(request, address)

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        try:
            if self.path != "/status":
                self.send_json({"error": "not found"}, 404)
            else:
                self.send_json(self.server.state.snapshot())
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_POST(self):
        state = self.server.state
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_BODY:
                self.send_json({"error": "request size"}, 413)
                return
            payload = json.loads(self.rfile.read(size))
            if not isinstance(payload, dict):
                raise ValueError("Expected one object")
            if self.path == "/v1/responses":
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    self.send_json({"error": "fixed fake fixture credential required"}, 401)
                    return
                self.send_json(state.provider(payload))
            elif self.path == "/control/release":
                if self.headers.get("X-A5-Control") != state.config["id"]:
                    self.send_json({"error": "fixture control token required"}, 403)
                    return
                state.release(payload.get("run"), payload.get("target"))
                self.send_json(state.snapshot(payload["run"]))
            elif self.path == "/mcp":
                if self.headers.get("X-Fixture") != HEADER:
                    self.send_json({"error": "fixed fake fixture header required"}, 401)
                    return
                self.mcp(payload)
            else:
                self.send_json({"error": "not found"}, 404)
        except (ValueError, TypeError, KeyError, FileExistsError):
            self.send_json({"error": "invalid generated fixture request"}, 400)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.close_connection = True

    def mcp(self, request):
        state = self.server.state
        method = request.get("method")
        state.log("mcp-method", method=method if method in {"initialize", "notifications/initialized", "tools/list", "tools/call"} else "other")
        if method == "notifications/initialized":
            self.send_json({}, 202)
            return
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "generated-a5", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "held", "description": "Generated bounded explicit-release acceptance call", "inputSchema": {"type": "object", "properties": {"run": {"type": "string"}}, "required": ["run"], "additionalProperties": False}}]}
        elif method == "tools/call":
            params = request.get("params", {})
            if params.get("name") != "held":
                raise ValueError("Unknown generated tool")
            run = params.get("arguments", {}).get("run")
            path = state.run_path(run)
            with state.lock:
                if state.runs[run]["mcp_calls"]:
                    state.log("duplicate-mcp-call-refused", run=run)
                    self.send_json({"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32602, "message": "No fixture replay"}})
                    return
                state.runs[run]["mcp_calls"] = 1
                state.runs[run]["mcp_entered"] = True
                state.save()
            state.log("mcp-entered", run=run)
            deadline = time.monotonic() + state.config["hold_seconds"]
            while not (path / "mcp-release").is_file() and time.monotonic() < deadline:
                readable, _, _ = select.select([self.connection], [], [], 0.05)
                if readable and not self.connection.recv(1, socket.MSG_PEEK):
                    state.log("mcp-peer-closed", run=run, client_physical_ownership_proven=False)
                    return
            released = (path / "mcp-release").is_file()
            result = {"content": [{"type": "text", "text": "A5 MCP completed" if released else "A5 bounded hold expired"}], "isError": not released}
            with state.lock:
                state.runs[run]["mcp_returned"] = True
                state.runs[run]["mcp_expired"] = not released
                state.save()
            state.log("mcp-response-attempt", run=run, released=released, client_durable_retention_proven=False)
        else:
            self.send_json({"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32601, "message": "Unsupported method"}})
            return
        self.send_json({"jsonrpc": "2.0", "id": request.get("id"), "result": result})


def control(root, operation, run=None, target=None):
    _, config = load_root(root)
    connection = http.client.HTTPConnection("127.0.0.1", config["port"], timeout=5)
    if operation == "status":
        connection.request("GET", "/status")
    else:
        connection.request("POST", "/control/release", json.dumps({"run": run, "target": target}), {"Content-Type": "application/json", "X-A5-Control": config["id"]})
    response = connection.getresponse()
    result = json.loads(response.read(MAX_BODY))
    connection.close()
    if response.status != 200:
        raise ValueError(f"Fixture refused operation: HTTP {response.status}")
    return result


def seal(root, binary):
    root, config = load_root(root)
    binary = Path(binary).resolve(strict=True)
    if not binary.is_file():
        raise ValueError("Expected a built App binary")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    destination = root / "bin" / ("bello-agent-a5-" + digest[:16])
    if destination.exists():
        raise ValueError("Already sealed")
    shutil.copyfile(binary, destination)
    destination.chmod(0o700)
    assert hashlib.sha256(destination.read_bytes()).hexdigest() == digest
    receipt = {"fixture_id": config["id"], "binary": str(destination), "binary_sha256": digest}
    write_json(root / "evidence/sealed-build.json", receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ["init", "serve", "status", "release", "seal"]:
        child = commands.add_parser(name)
        child.add_argument("--root", type=Path, required=True)
        if name == "init":
            child.add_argument("--port", type=int, required=True)
            child.add_argument("--hold-seconds", type=int, default=90)
        if name == "release":
            child.add_argument("--run", required=True)
            child.add_argument("--target", choices=["bash", "mcp"], required=True)
        if name == "seal":
            child.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    if args.operation == "init":
        result = initialize(args.root, args.port, args.hold_seconds)
    elif args.operation == "serve":
        state = State(args.root)
        server = BoundedServer(state)
        print(json.dumps({"listening": f"127.0.0.1:{state.config['port']}", "fixture_id": state.config["id"]}), flush=True)
        server.serve_forever()
        return
    elif args.operation == "seal":
        result = seal(args.root, args.binary)
    else:
        result = control(args.root, args.operation, getattr(args, "run", None), getattr(args, "target", None))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
