#!/usr/bin/env python3
"""Synthetic loopback gateway for the opt-in native UI XCTest window.

No credentials, outbound networking, or real model calls. Prompts containing
"slow", "large", or "read fixture" exercise streaming and a local read tool.
"stress markdown" streams 1 MiB; "stress tool" runs the harness's 50 MiB
synthetic stdout producer. Both stay local and use only deterministic data.
"owner billing sample" returns a validated final Responses JSON response with
the owner's usage/header billing shape, using synthetic IDs and visible text.

PI_APP_UI_FIXTURE_MODEL selects the exact accepted request alias (default:
ui-fixture). Any configured non-default alias exercises synthetic routing:
Responses resolves to fixture-responses-model, Messages to fixture-messages-model.
The catalog also advertises fixture-fast, with its own 16,000-token output limit.
The fixture contract's X-Fixture-Model header agrees with each API's body model.
Use routing.modelHeader="x-fixture-model" with an explicit synthetic fixture
reference in the native profile; these are not claimed LiteLLM header semantics.
"""
import base64
import http.server
import json
import os
import threading
import time
import uuid
from pathlib import Path
from litellm_contract import FixtureContractError, require, validate_request


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


class Gateway(http.server.BaseHTTPRequestHandler):
    records = []
    lock = threading.Lock()
    historical_tool_schemas = {
        "bash": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "number"}},
                 "required": ["command"], "additionalProperties": False}
    }

    @classmethod
    def checkpoint(cls):
        # Preserve independently observed wire data even if the UI harness
        # exits before its final GET. Never recover this from the native archive.
        with cls.lock:
            temporary = Path("captures.json.tmp")
            temporary.write_bytes(encode(cls.records))
            temporary.replace("captures.json")

    def log_message(self, *_):
        pass

    @staticmethod
    def catalog():
        return {"version": 1, "models": [
            {"id": os.environ.get("PI_APP_UI_FIXTURE_MODEL", "ui-fixture"), "name": "Fixture router", "description": "Synthetic loopback route used by the UI harness.",
             "contextWindow": 2_000_000, "maxOutputTokens": 300_000, "reasoning": ["low", "medium", "high"], "order": 1},
            {"id": "fixture-fast", "name": "Fixture fast", "description": "Synthetic route with a smaller context and output limit.",
             "contextWindow": 128_000, "maxOutputTokens": 16_000, "reasoning": [], "order": 2},
            {"id": "fixture-legacy", "name": "Fixture legacy", "contextWindow": 32_000, "deprecated": True},
        ]}

    def do_GET(self):
        if self.path == "/catalog":
            body = encode(self.catalog())
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path != "/captures":
            self.send_error(404)
            return
        with self.lock:
            data = encode(self.records)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path not in ("/v1/responses", "/v1/messages"):
            self.send_error(404)
            return
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        expected_model = os.environ.get("PI_APP_UI_FIXTURE_MODEL", "ui-fixture")
        try:
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise FixtureContractError("request body must be an object")
            requested_model = body.get("model")
            limits = {expected_model: 300_000, "fixture-fast": 16_000}
            if requested_model not in limits:
                raise FixtureContractError("model alias is not an active fixture catalog entry")
            connection_test = self.headers.get("x-session-id", "").startswith("connection-test-")
            if connection_test:
                require(self.path == "/v1/responses", "connection tests use Responses")
                require(type(body.get("max_output_tokens")) is int and 0 < body["max_output_tokens"] <= 256,
                        "connection test output must be between 1 and 256 tokens")
                require(body.get("instructions") == "This is a connection test. Reply briefly with OK.",
                        "connection test instructions must exclude workspace resources")
                require(body.get("input") == [{"type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": "Reply with OK to confirm this connection."}]}],
                    "connection test must contain only its fixed short prompt")
                require(body.get("tools", []) == [], "connection test tools must be empty")
                require(body.get("metadata") == {"session_id": self.headers.get("x-session-id")},
                        "connection test metadata must name only its session")
                require(body.get("disable_fallbacks") is True, "requests must opt out of gateway fallback models")
                require(set(body) <= {"model", "stream", "store", "instructions", "input", "metadata", "disable_fallbacks",
                                      "max_output_tokens", "tools", "temperature", "top_p"},
                        "connection test contains unrelated request settings")
            if requested_model == "fixture-fast" and any(name in body for name in ("reasoning", "thinking", "output_config")):
                raise FixtureContractError("fixture-fast does not accept reasoning parameters")
            # The mini model also serves utility requests (titles, suggestions) that ask for far less output
            # than the catalog allows, so its limit is a ceiling; the conversation model's limit must match exactly.
            limit_name = "max_output_tokens" if self.path.endswith("responses") else "max_tokens"
            if requested_model == "fixture-fast" and not connection_test:
                require(type(body.get(limit_name)) is int and 0 < body[limit_name] <= limits["fixture-fast"], "fixture-fast output limit must stay within its catalog ceiling")
            contract = validate_request("POST", self.path, self.headers, body,
                                        api_key="synthetic-loopback-only-key", model=requested_model,
                                        max_output_tokens=body["max_output_tokens"] if connection_test else (None if requested_model == "fixture-fast" else limits[requested_model]), native_items="portable",
                                        historical_tool_schemas=self.historical_tool_schemas)
        except (ValueError, FixtureContractError) as error:
            # Validation failures expose only a fixed contract explanation, not
            # header values. A malformed request never receives a canned success.
            self.send_error(400, str(error))
            return
        responses = self.path.endswith("responses")
        resolved_model = ("fixture-fast-responses" if responses else "fixture-fast-messages") if requested_model == "fixture-fast" else (
            ("fixture-responses-model" if responses else "fixture-messages-model") if expected_model != "ui-fixture" else expected_model)
        history = body.get("input", []) if responses else body.get("messages", [])
        # A Messages tool-result user block is not a new user prompt. Use the
        # validated semantic history for response choice on both APIs.
        prompt = contract["latest_text"]
        owner_billing = responses and "owner billing sample" in prompt.lower()
        if owner_billing:
            resolved_model = "gpt-5.4-mini"
        last = history[-1] if history else {}
        tool_result = last.get("type") == "function_call_output" if responses else any(block.get("type") == "tool_result" for block in last.get("content", []) if isinstance(block, dict))
        stress_markdown = "stress markdown" in prompt.lower()
        stress_tool = "stress tool" in prompt.lower()
        secondary_read = "read secondary fixture" in prompt.lower()
        tool_name = "bash" if stress_tool else "read"
        call_tool = tool_name in contract["tool_names"] and ("read fixture" in prompt.lower() or secondary_read or stress_tool) and not tool_result
        tool_arguments = {"command": "/usr/bin/python3 -u stress-output.py", "timeout": 60} if stress_tool else {"path": "SECONDARY.md" if secondary_read else "README.md"}
        text = "Fixture reply: " + (prompt or "Tool result received.") + "\n\nUnicode: 中文🙂 café."
        if connection_test:
            text = "OK"
        if "EXPLICIT-FIXTURE-SELECTED" in json.dumps(body) and "skill fixture" in prompt.lower():
            text += "\n\nEXPLICIT-FIXTURE-SELECTED: the selected skill reached the request."
        if tool_result:
            result_id = next(reversed(contract["results"]))
            result_text = contract["results"][result_id]
            completed_tool = contract["calls"][result_id]["name"]
            if completed_tool == "read" and "Synthetic UI fixture file: read-tool round trip verified." not in result_text:
                self.send_error(400, "read tool result did not contain the fixture file")
                return
            if secondary_read and "SECONDARY-WORKSPACE-ROOT-VERIFIED" not in result_text:
                self.send_error(400, "read tool did not resolve the second workspace folder")
                return
            if completed_tool == "bash" and "SYNTHETIC-TOOL-OUTPUT" not in result_text:
                self.send_error(400, "bash tool result did not contain the synthetic output")
                return
            text = ("Fixture read completed. The native helper returned the local README contents." if completed_tool == "read"
                    else "Fixture bash completed. The native helper returned the synthetic tool output.")
            if secondary_read:
                text = "Fixture read completed. SECONDARY-WORKSPACE-ROOT-VERIFIED: the file came from the added workspace folder."
        if stress_markdown:
            paragraph = "\n\n### Synthetic stress section\n" + "**bold** `code` stable scroll anchor. " * 30
            text = (paragraph * (1_048_576 // len(paragraph) + 1))[:1_048_576]
        elif "large" in prompt.lower():
            text += "\n\n" + "\n\n".join(f"### Section {i}\nSynthetic searchable paragraph {i}: **bold**, `code`, 中文🙂, and stable scroll anchors." for i in range(1, 101))
        elif "slow" in prompt.lower():
            text += "\n\n" + " ".join(f"stream-{i:02d}" for i in range(1, 81))
        chunk_size = 1024 if stress_markdown else 36
        chunks = [text[i:i + chunk_size] for i in range(0, len(text), chunk_size)]
        request_id = uuid.uuid4().hex
        record = {"id": request_id, "path": self.path, "request": base64.b64encode(raw).decode(), "response": "", "cancelled": False,
                  "contractValidated": True, "toolCalls": len(contract["calls"]), "toolResults": len(contract["results"]),
                  "sessionID": self.headers.get("x-session-id"), "turnID": self.headers.get("x-turn-id"), "model": requested_model,
                  "secondaryRootVerified": secondary_read and tool_result, "resolvedModel": resolved_model,
                  "ownerBillingSample": owner_billing, "connectionTest": connection_test}
        with self.lock:
            self.records.append(record)
        if owner_billing:
            # Request validation and tool-result validation above must finish
            # before this scenario can return a success. No owner IDs or opaque
            # reasoning payloads are retained in the synthetic fixture.
            response = encode({"id": "resp_fixture_" + request_id, "object": "response", "status": "completed",
                               "model": requested_model, "router_model_name": resolved_model,
                               "output": [{"id": "msg_fixture_" + request_id, "type": "message", "role": "assistant", "status": "completed",
                                           "content": [{"type": "output_text", "text": "Synthetic billing sample: 38 input tokens and 302 output tokens, including 253 reasoning tokens. Reasoning cost is part of output cost.", "annotations": []}]}],
                               "usage": {"input_tokens": 38, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
                                         "output_tokens": 302, "output_tokens_details": {"reasoning_tokens": 253}, "total_tokens": 340, "cost": None}})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Request-Id", "ui-fixture-" + request_id)
            self.send_header("X-Fixture-Model", resolved_model)
            self.send_header("X-LiteLLM-Model-Name", "openai/" + resolved_model)
            self.send_header("X-LiteLLM-Response-Cost", "0.0013875")
            self.send_header("X-LiteLLM-Response-Cost-Input", "0.0000285")
            self.send_header("X-LiteLLM-Response-Cost-Output", "0.001359")
            self.send_header("X-LiteLLM-Response-Cost-Reasoning", "0.0011385")
            self.send_header("X-Fixture-Cache", "false")
            self.end_headers()
            try:
                self.wfile.write(response)
                self.wfile.flush()
                with self.lock:
                    record["response"] = base64.b64encode(response).decode()
            except (BrokenPipeError, ConnectionResetError):
                with self.lock:
                    record["cancelled"] = True
            finally:
                self.checkpoint()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("X-Request-Id", "ui-fixture-" + request_id)
        self.send_header("X-Fixture-Model", resolved_model)
        self.send_header("X-LiteLLM-Response-Cost", "0")  # Pre-stream placeholder, never final billing.
        self.send_header("X-Fixture-Cache", "true" if "cache hit" in prompt.lower() else "false")
        self.end_headers()
        received = bytearray()

        def emit(event):
            data = b"data: " + encode(event) + b"\n\n"
            self.wfile.write(data)
            self.wfile.flush()
            received.extend(data)
            with self.lock:
                record["response"] = base64.b64encode(received).decode()

        try:
            if responses:
                if call_tool:
                    output = [{"type": "function_call", "id": "fc_" + request_id, "call_id": "call_" + request_id, "name": tool_name, "arguments": encode(tool_arguments).decode()}]
                    emit({"type": "response.output_item.added", "output_index": 0, "item": {**output[0], "arguments": ""}})
                    emit({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": output[0]["arguments"]})
                else:
                    for chunk in chunks:
                        emit({"type": "response.output_text.delta", "delta": chunk})
                        time.sleep(0.025 if stress_markdown else 0.8 if "slow" in prompt.lower() else 0.035 if "large" in prompt.lower() else 0.03)
                    output = [{"type": "message", "id": "msg_" + request_id, "role": "assistant", "content": [{"type": "output_text", "text": text, "annotations": []}], "status": "completed"}]
                emit({"type": "response.completed", "response": {"id": "resp_" + request_id, "model": resolved_model, "status": "completed", "output": output, "usage": {"input_tokens": 30, "input_tokens_details": {"cached_tokens": 10}, "output_tokens": len(text) // 4 + 1, "cost": 0 if "cache hit" in prompt.lower() else 0.00125}}})
            else:
                emit({"type": "message_start", "message": {"id": "msg_" + request_id, "model": resolved_model, "type": "message", "role": "assistant", "content": [], "usage": {"input_tokens": 20, "cache_read_input_tokens": 10, "output_tokens": 0}}})
                block = {"type": "tool_use", "id": "call_" + request_id, "name": tool_name, "input": {}} if call_tool else {"type": "text", "text": ""}
                emit({"type": "content_block_start", "index": 0, "content_block": block})
                if call_tool:
                    emit({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": encode(tool_arguments).decode()}})
                else:
                    for chunk in chunks:
                        emit({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": chunk}})
                        time.sleep(0.025 if stress_markdown else 0.8 if "slow" in prompt.lower() else 0.035 if "large" in prompt.lower() else 0.03)
                emit({"type": "content_block_stop", "index": 0})
                emit({"type": "message_delta", "delta": {"stop_reason": "tool_use" if call_tool else "end_turn"}, "usage": {"output_tokens": len(text) // 4 + 1, "cost": 0 if "cache hit" in prompt.lower() else 0.00125}})
                emit({"type": "message_stop"})
        except (BrokenPipeError, ConnectionResetError):
            with self.lock:
                record["cancelled"] = True
        finally:
            self.checkpoint()


if __name__ == "__main__":
    previous = Path("captures.json")
    if previous.exists():
        Gateway.records = json.loads(previous.read_text())
    # A native journal binds the endpoint as well as the API and model. Keep
    # that endpoint stable across actual app/fixture process relaunches.
    port_file = Path("gateway-port.txt")
    port = int(port_file.read_text()) if port_file.exists() else 0
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Gateway)
    port_file.write_text(str(server.server_port))
    print(json.dumps({"port": server.server_port}), flush=True)
    server.serve_forever()
