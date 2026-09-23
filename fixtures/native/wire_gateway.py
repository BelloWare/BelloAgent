#!/usr/bin/env python3
"""Synthetic loopback Responses gateway for the app's wire-contract tests.

No credentials, outbound networking or real model calls. The latest user
message picks the reply:

  "wire bash N"       a bash call that sleeps N seconds (to stop mid-run)
  "wire write N"      a write call whose arguments stream in N deltas 15 ms
                      apart, then a pause before the reply completes; the
                      exact argument text is written to
                      wire-write-arguments.txt first
  "wire stream N"     N text deltas, 30 ms apart
  "wire filter"       some text, then an incomplete reply (content_filter)
  "wire early REASON" some text, then an incomplete reply with REASON
  anything else       a short reply in one burst

A round that answers a tool result replies with one short sentence. The
listening port is printed as {"port": N} on the first line of stdout; files
are written to the working directory. With --exit-on-eof the gateway exits
when its stdin closes, so it never outlives the test process that owns it.
"""
import http.server
import json
import os
import pathlib
import sys
import threading
import time
import uuid


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def write_arguments():
    """The write call's arguments: multi-byte text and escapes, byte-exact."""
    lines = [f"line {index:03d} · 中文🙂 café \"quoted\" \\ tab\tend" for index in range(120)]
    return json.dumps({"path": "wire-notes.txt", "content": "\n".join(lines) + "\n"}, ensure_ascii=False)


class Gateway(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/catalog":
            self.send_error(404)
            return
        body = encode({"version": 1, "models": [{"id": "wire-fixture", "name": "Wire fixture", "description": "Synthetic loopback route.",
                                                   "contextWindow": 2_000_000, "maxOutputTokens": 300_000, "reasoning": [], "order": 1}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        items = body.get("input", [])
        prompt = ""
        for item in items:
            if item.get("type") == "message" and item.get("role") == "user":
                content = item.get("content")
                prompt = content if isinstance(content, str) else "".join(
                    part.get("text", "") for part in content or [] if isinstance(part, dict))
        tool_result = bool(items) and items[-1].get("type") == "function_call_output"
        words = prompt.lower().split()
        request_id = uuid.uuid4().hex
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def emit(event):
            self.wfile.write(b"data: " + encode(event) + b"\n\n")
            self.wfile.flush()

        def number(default):
            try:
                return int(words[words.index("wire") + 2])
            except (ValueError, IndexError):
                return default

        response = {"id": "resp_" + request_id, "object": "response", "model": body.get("model"), "status": "in_progress", "output": []}
        usage = {"input_tokens": 12, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 8}
        scenario = words[words.index("wire") + 1] if "wire" in words and words.index("wire") + 1 < len(words) else ""
        try:
            emit({"type": "response.created", "response": response})
            if not tool_result and scenario in ("bash", "write"):
                if scenario == "bash":
                    name, arguments = "bash", json.dumps({"command": f"sleep {number(30)}; echo wire-bash-done"})
                else:
                    name, arguments = "write", write_arguments()
                    pathlib.Path("wire-write-arguments.txt").write_bytes(arguments.encode())
                call = {"type": "function_call", "id": "fc_" + request_id, "call_id": "call_" + request_id,
                        "name": name, "arguments": arguments, "status": "completed"}
                emit({"type": "response.output_item.added", "output_index": 0, "item": {**call, "arguments": "", "status": "in_progress"}})
                # Exactly `count` deltas, cut at code points (never inside one).
                count = min(len(arguments), max(1, number(200))) if scenario == "write" else 1
                cuts = [len(arguments) * index // count for index in range(count + 1)]
                for start, end in zip(cuts, cuts[1:]):
                    emit({"type": "response.function_call_arguments.delta", "output_index": 0, "item_id": call["id"],
                          "delta": arguments[start:end]})
                    if scenario == "write":
                        time.sleep(0.015)
                emit({"type": "response.output_item.done", "output_index": 0, "item": call})
                if scenario == "write":
                    # Long enough for every reader to see the whole call before it runs.
                    time.sleep(1.2)
                emit({"type": "response.completed", "response": {**response, "status": "completed", "output": [call], "usage": usage}})
                return
            item_id = "msg_" + request_id
            if tool_result:
                text = "Tool round finished."
            elif scenario == "stream":
                text = "".join(f"token-{index:03d} " for index in range(number(40)))
            elif scenario in ("filter", "early"):
                text = "Partial answer before the provider stopped."
            else:
                text = "Wire reply."
            emit({"type": "response.output_item.added", "output_index": 0,
                  "item": {"id": item_id, "type": "message", "role": "assistant", "status": "in_progress", "content": []}})
            if scenario == "stream" and not tool_result:
                for index in range(number(40)):
                    emit({"type": "response.output_text.delta", "output_index": 0, "item_id": item_id, "content_index": 0,
                          "delta": f"token-{index:03d} "})
                    time.sleep(0.03)
            else:
                emit({"type": "response.output_text.delta", "output_index": 0, "item_id": item_id, "content_index": 0, "delta": text})
            message = {"id": item_id, "type": "message", "role": "assistant",
                       "status": "incomplete" if scenario in ("filter", "early") and not tool_result else "completed",
                       "content": [{"type": "output_text", "text": text, "annotations": []}]}
            emit({"type": "response.output_item.done", "output_index": 0, "item": message})
            if scenario in ("filter", "early") and not tool_result:
                reason = "content_filter" if scenario == "filter" else (words[words.index("early") + 1] if len(words) > words.index("early") + 1 else "other")
                emit({"type": "response.incomplete", "response": {**response, "status": "incomplete",
                      "incomplete_details": {"reason": reason}, "output": [message], "usage": usage}})
            else:
                emit({"type": "response.completed", "response": {**response, "status": "completed", "output": [message], "usage": usage}})
        except (BrokenPipeError, ConnectionResetError):
            pass


def exit_on_eof():
    sys.stdin.buffer.read()
    os._exit(0)


if __name__ == "__main__":
    if "--exit-on-eof" in sys.argv:
        threading.Thread(target=exit_on_eof, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
    server.daemon_threads = True
    print(json.dumps({"port": server.server_port}), flush=True)
    server.serve_forever()
