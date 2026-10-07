#!/usr/bin/env python3
"""Disposable saved-runtime Responses + MCP GUI fixture, numeric loopback only.

No outbound connections, real credentials or state outside the explicitly chosen
JSONL log. Requests are logged as bounded protocol facts; no header, credential,
argument, model-input or result content is recorded. MCP `uncertain` deliberately
drops after accepting its one invocation; `slow` waits for Cancel/Stop.
"""
import argparse
import json
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=47881)
parser.add_argument("--log", required=True)
args = parser.parse_args()
lock = threading.Lock()


def record(kind, **facts):
    with lock, open(args.log, "a", encoding="utf-8") as output:
        output.write(json.dumps({"kind": kind, **facts}, ensure_ascii=True) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 4 * 1024 * 1024:
                self.send_error(413)
                return
            request = json.loads(self.rfile.read(length))
            if self.path == "/v1/responses":
                self.provider(request)
            elif self.path == "/mcp":
                self.mcp(request)
            else:
                self.send_error(404)
        except (ValueError, TypeError, KeyError):
            self.send_error(400)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True

    def json_response(self, response):
        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def mcp(self, request):
        method = request.get("method")
        parameters = request.get("params", {})
        tool = parameters.get("name") if method == "tools/call" else None
        record("mcp", method=method if method in {"initialize", "notifications/initialized", "tools/list", "tools/call"} else "other",
               tool=tool if tool in {"echo", "uncertain", "slow"} else None,
               fixture_header=self.headers.get("x-fixture") == "synthetic-header-fixture-only")
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "numeric-loopback-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "description": description,
                                 "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "additionalProperties": False}}
                                for name, description in [("echo", "Return one bounded fixture response."),
                                                          ("uncertain", "Deliberately disconnect after receiving one invocation. Check the project-wide unknown warning."),
                                                          ("slow", "Wait for Cancel or Stop; effects may be unknown.")]]}
        elif method == "tools/call":
            if tool == "uncertain":
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            if tool == "slow":
                time.sleep(15)
            result = {"content": [{"type": "text", "text": "MCP loopback fixture result: one invocation completed."}], "isError": False}
        else:
            self.json_response({"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture method"}})
            return
        self.json_response({"jsonrpc": "2.0", "id": request.get("id"), "result": result})

    def provider(self, request):
        inputs = request.get("input", [])
        last_user = ""
        for item in inputs:
            if item.get("role") == "user":
                content = item.get("content", "")
                last_user = content if isinstance(content, str) else " ".join(part.get("text", "") for part in content)
        result_received = bool(inputs and inputs[-1].get("type") == "function_call_output")
        lower = last_user.lower()
        wants_mcp = "mcp fixture" in lower and not result_received
        action = "invoke" if "invoke" in lower else "describe" if "describe" in lower else "list"
        tool = "uncertain" if "uncertain" in lower else "slow" if "slow" in lower else "echo"
        names = [entry.get("name") for entry in request.get("tools", [])]
        record("provider", request_kind="mcp_" + action if wants_mcp else "continuation" if result_received else "answer",
               offers_mcp="mcp" in names, tool_result=result_received,
               fixture_model=request.get("model") if request.get("model") in {"local-test-fixture", "second-fixture"} else "other",
               fixture_authorization=self.headers.get("Authorization") == "Bearer synthetic-project-fixture-only")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        if wants_mcp:
            if "mcp" not in names:
                text = "The saved runtime did not advertise MCP. Verify the selected saved connection and trusted project."
                output = [{"type": "message", "content": [{"type": "output_text", "text": text}]}]
            else:
                parameters = {"action": action}
                if action == "list":
                    parameters["server"] = "fixture"
                elif action == "describe":
                    parameters["targets"] = [{"server": "fixture", "tool": tool}]
                else:
                    parameters.update(server="fixture", tool=tool, arguments={"text": "model-driven fixture"})
                call = uuid.uuid4().hex
                output = [{"type": "function_call", "id": "fixture-item-" + call,
                           "call_id": "fixture-call-" + call, "name": "mcp", "arguments": json.dumps(parameters)}]
        else:
            text = "Saved runtime continued after the actual MCP tool result. No tool was replayed." if result_received else "Saved connection ready. No paid provider contacted."
            self.event({"type": "response.output_text.delta", "delta": text})
            output = [{"type": "message", "content": [{"type": "output_text", "text": text}]}]
        self.event({"type": "response.completed", "response": {"status": "completed", "output": output}})

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    print(f"Fixture ready at http://127.0.0.1:{args.port}; no outbound network", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
