"""The UI gateway validates preserved history and checkpoints independent bytes."""
import base64
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures/native"
sys.path.insert(0, str(FIXTURES))
spec = importlib.util.spec_from_file_location("ui_gateway", FIXTURES / "ui-gateway.py")
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class UIGatewayTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("PI_APP_UI_FIXTURE_MODEL", None)
        self.previous = Path.cwd()
        self.folder = tempfile.TemporaryDirectory(prefix="pi-ui-gateway-")
        os.chdir(self.folder.name)
        gateway.Gateway.records = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), gateway.Gateway)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        os.chdir(self.previous)
        self.folder.cleanup()

    def request(self, responses=True, prompt="side history probe"):
        key = "synthetic-loopback-only-key"
        headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json", "Accept": "text/event-stream",
                   "x-session-id": "synthetic-session", "x-turn-id": "synthetic-turn"}
        if responses:
            headers.update({"session_id": "synthetic-session", "x-client-request-id": "synthetic-session"})
        schema = {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
        arguments = {"command": "echo synthetic", "timeout": 60}
        if responses:
            body = {"model": "ui-fixture", "stream": True, "max_output_tokens": 300_000, "metadata": {"session_id": "synthetic-session"},
                    "prompt_cache_key": "synthetic-session", "store": False,
                    "tools": [{"type": "function", "name": "read", "description": "Read fixture", "parameters": schema}],
                    "input": [{"role": "developer", "content": "Synthetic instructions"},
                              {"type": "function_call", "call_id": "known-bash", "name": "bash", "arguments": json.dumps(arguments)},
                              {"type": "function_call_output", "call_id": "known-bash", "output": "SYNTHETIC-TOOL-OUTPUT"},
                              {"role": "user", "content": [{"type": "input_text", "text": prompt}]}]}
        else:
            headers.update({"x-api-key": key, "anthropic-version": "2023-06-01"})
            body = {"model": "ui-fixture", "stream": True, "max_tokens": 300_000, "system": "Synthetic instructions",
                    "tools": [{"name": "read", "description": "Read fixture", "input_schema": schema}],
                    "messages": [{"role": "assistant", "content": [{"type": "tool_use", "id": "known-bash", "name": "bash", "input": arguments}]},
                                 {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "known-bash", "is_error": False, "content": "SYNTHETIC-TOOL-OUTPUT"}]},
                                 {"role": "user", "content": [{"type": "text", "text": prompt}]}]}
        return "/v1/responses" if responses else "/v1/messages", headers, body

    def send(self, path, headers, body, include_headers=False):
        raw = json.dumps(body, separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request("POST", path, body=raw, headers=headers)
        response = connection.getresponse()
        status, received = response.status, response.read()
        response_headers = {name.lower(): value for name, value in response.getheaders()}
        connection.close()
        result = (status, raw, received)
        return result + (response_headers,) if include_headers else result

    def model_in_stream(self, received, responses):
        events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
        if responses:
            return next(event["response"]["model"] for event in events if event["type"] == "response.completed")
        return next(event["message"]["model"] for event in events if event["type"] == "message_start")

    def test_default_model_preserves_existing_fixture_behavior(self):
        for responses in (True, False):
            with self.subTest(responses=responses):
                path, headers, body = self.request(responses)
                status, _, received, response_headers = self.send(path, headers, body, include_headers=True)
                self.assertEqual(status, 200)
                self.assertEqual(self.model_in_stream(received, responses), "ui-fixture")
                self.assertEqual(response_headers["x-fixture-model"], "ui-fixture")

    def test_responses_stream_has_indexed_items_before_deltas(self):
        path, headers, body = self.request(prompt="stream preview")
        status, _, received = self.send(path, headers, body)
        self.assertEqual(status, 200)
        events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
        self.assertEqual(events[0]["type"], "response.created")
        self.assertEqual(events[0]["response"]["status"], "in_progress")
        item = next(e["item"] for e in events if e["type"] == "response.output_item.added")
        deltas = [e for e in events if e["type"] == "response.output_text.delta"]
        self.assertTrue(deltas)
        for delta in deltas:
            self.assertEqual(delta["item_id"], item["id"])
            self.assertEqual(delta["output_index"], 0)
            self.assertEqual(delta["content_index"], 0)
        completed = events[-1]["response"]
        self.assertEqual("".join(e["delta"] for e in deltas), completed["output"][0]["content"][0]["text"])
    def summary_request(self, limit=13_107):
        path, headers, _ = self.request()
        conversation = "<conversation>\n[User]: bulk 400 slow large read fixture\n</conversation>\n\nSummarize the conversation above."
        # Pi's summary request: its system prompt leads the input, then one
        # message of conversation text; no prompt cache key, so none of pi's
        # session affinity headers either.
        headers = {name: value for name, value in headers.items() if name not in ("session_id", "x-client-request-id")}
        body = {"model": "ui-fixture", "stream": True, "store": False, "max_output_tokens": limit,
                "metadata": {"session_id": headers["x-session-id"]},
                "input": [{"role": "system", "content": "You are a context summarization assistant. Summarize faithfully."},
                          {"role": "user", "content": [{"type": "input_text", "text": conversation}]}]}
        return path, headers, body

    def test_summary_request_streams_a_summary_within_its_own_cap(self):
        os.environ["PI_APP_UI_FIXTURE_SUMMARY_DELAY"] = "0"
        path, headers, body = self.summary_request()
        status, _, received = self.send(path, headers, body)
        self.assertEqual(status, 200)
        events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
        deltas = [e["delta"] for e in events if e["type"] == "response.output_text.delta"]
        self.assertGreater(len(deltas), 10, "the summary arrives a delta at a time")
        text = events[-1]["response"]["output"][0]["content"][0]["text"]
        self.assertEqual("".join(deltas), text)
        self.assertTrue(text.startswith("## Goal"), "keywords in the summarized conversation are not answered")
        path, headers, body = self.summary_request(limit=300_001)
        status, _, _ = self.send(path, headers, body)
        self.assertEqual(status, 400, "a summary's cap stays within the model's ceiling")

    def test_bulk_reply_and_lenient_limit(self):
        path, headers, body = self.request(prompt="bulk 64 history")
        body["max_output_tokens"] = 60_000
        status, _, _ = self.send(path, headers, body)
        self.assertEqual(status, 400, "a conversation request carries the catalog ceiling unless the scene asks otherwise")
        os.environ["PI_APP_UI_FIXTURE_LENIENT_LIMIT"] = "1"
        os.environ["PI_APP_UI_FIXTURE_REAL_USAGE"] = "1"
        status, raw, received = self.send(path, headers, body)
        self.assertEqual(status, 200)
        events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
        completed = events[-1]["response"]
        self.assertGreaterEqual(len(completed["output"][0]["content"][0]["text"]), 64 * 1024)
        self.assertEqual(completed["usage"]["input_tokens"], len(raw) // 4)

    def connection_probe(self, model="ui-fixture", limit=256):
        path, headers, _ = self.request()
        headers["x-session-id"] = "connection-test-synthetic"
        headers.update({"session_id": headers["x-session-id"], "x-client-request-id": headers["x-session-id"]})
        body = {"model": model, "stream": True, "store": False, "max_output_tokens": limit, "disable_fallbacks": True,
                "metadata": {"session_id": headers["x-session-id"]}, "prompt_cache_key": headers["x-session-id"],
                "input": [{"role": "system", "content": "This is a connection test. Reply briefly with OK."},
                          {"role": "user", "content": [{"type": "input_text", "text": "Reply with OK to confirm this connection."}]}]}
        return path, headers, body

    def test_connection_ping_uses_selected_model_and_captures_small_tool_free_request(self):
        for model, limit in (("ui-fixture", 256), ("fixture-fast", 32)):
            with self.subTest(model=model, limit=limit):
                path, headers, body = self.connection_probe(model, limit)
                status, raw, received = self.send(path, headers, body)
                self.assertEqual(status, 200)
                events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
                response = next(event["response"] for event in events if event["type"] == "response.completed")
                self.assertEqual(response["output"][0]["content"][0]["text"], "OK")
                record = json.loads(Path("captures.json").read_bytes())[-1]
                self.assertEqual(base64.b64decode(record["request"]), raw)
                self.assertIs(json.loads(raw)["disable_fallbacks"], True)
                self.assertEqual(base64.b64decode(record["response"]), received)
                self.assertEqual(record["model"], model)
                self.assertTrue(record["connectionTest"])
                self.assertEqual(record["toolCalls"], 0)
                self.assertEqual(record["toolResults"], 0)

    def test_connection_ping_rejects_changed_prompt_resources_tools_auth_and_limits(self):
        for malformed in ("auth", "model", "limit", "zero", "instructions", "history", "tools", "metadata", "fallbacks_missing", "fallbacks_false", "reasoning"):
            with self.subTest(malformed=malformed):
                path, headers, body = self.connection_probe()
                if malformed == "auth":
                    headers["Authorization"] = "Bearer incorrect-key"
                elif malformed == "model":
                    body["model"] = "unknown"
                elif malformed == "limit":
                    body["max_output_tokens"] = 257
                elif malformed == "zero":
                    body["max_output_tokens"] = 0
                elif malformed == "instructions":
                    body["input"][0]["content"] += " Workspace AGENTS content"
                elif malformed == "history":
                    body["input"].append({"role": "user", "content": [{"type": "input_text", "text": "private file"}]})
                elif malformed == "tools":
                    body["tools"] = [{"type": "function", "name": "read"}]
                elif malformed == "metadata":
                    body["metadata"]["session_id"] = "different-session"
                elif malformed == "fallbacks_missing":
                    body.pop("disable_fallbacks")
                elif malformed == "fallbacks_false":
                    body["disable_fallbacks"] = False
                else:
                    body["reasoning"] = {"effort": "high"}
                self.assertEqual(self.send(path, headers, body)[0], 400)
        self.assertEqual(gateway.Gateway.records, [])

    def test_owner_billing_sample_has_exact_json_usage_headers_and_capture(self):
        with patch.dict(os.environ, {"PI_APP_UI_FIXTURE_MODEL": "auto-router"}):
            path, headers, body = self.request(prompt="owner billing sample")
            body["model"] = "auto-router"
            status, raw, received, response_headers = self.send(path, headers, body, include_headers=True)
        self.assertEqual(status, 200)
        self.assertEqual(response_headers["content-type"], "application/json")
        response = json.loads(received)
        self.assertEqual(response["model"], "auto-router")
        self.assertEqual(response["router_model_name"], "gpt-5.4-mini")
        self.assertEqual(response_headers["x-fixture-model"], "gpt-5.4-mini")
        self.assertEqual(response_headers["x-litellm-model-name"], "openai/gpt-5.4-mini")
        self.assertEqual(response["usage"], {"input_tokens": 38, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
                                            "output_tokens": 302, "output_tokens_details": {"reasoning_tokens": 253}, "total_tokens": 340, "cost": None})
        for name, expected in (("", "0.0013875"), ("-input", "0.0000285"), ("-output", "0.001359"), ("-reasoning", "0.0011385")):
            self.assertEqual(response_headers["x-litellm-response-cost" + name], expected)
        # A Content-Length client can finish before the server checkpoints the
        # successful write. Wait for that independent observation, not a copy
        # manufactured from the response received in this test.
        deadline = time.monotonic() + 2
        while not Path("captures.json").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        record = json.loads(Path("captures.json").read_bytes())[-1]
        self.assertEqual(base64.b64decode(record["request"]), raw)
        self.assertEqual(base64.b64decode(record["response"]), received)
        self.assertEqual(record["resolvedModel"], "gpt-5.4-mini")
        self.assertTrue(record["ownerBillingSample"])
        self.assertTrue(record["contractValidated"])

    def test_owner_billing_sample_cannot_bypass_request_validation(self):
        for malformed in ("authentication", "model", "limit", "tool history"):
            with self.subTest(malformed=malformed):
                path, headers, body = self.request(prompt="owner billing sample")
                if malformed == "authentication":
                    headers["Authorization"] = "Bearer wrong-fixture-key"
                elif malformed == "model":
                    body["model"] = "gpt-5.4-mini"
                elif malformed == "limit":
                    body["max_output_tokens"] = 900
                else:
                    body["input"][0]["name"] = "unknown"
                self.assertEqual(self.send(path, headers, body)[0], 400)
        self.assertEqual(gateway.Gateway.records, [])

    def test_configured_auto_router_accepts_alias_and_reports_consistent_resolved_model(self):
        with patch.dict(os.environ, {"PI_APP_UI_FIXTURE_MODEL": "auto-router"}):
            for responses, resolved in ((True, "fixture-responses-model"), (False, "fixture-messages-model")):
                with self.subTest(responses=responses):
                    path, headers, body = self.request(responses)
                    body["model"] = "auto-router"
                    status, raw, received, response_headers = self.send(path, headers, body, include_headers=True)
                    self.assertEqual(status, 200)
                    self.assertEqual(self.model_in_stream(received, responses), resolved)
                    self.assertEqual(response_headers["x-fixture-model"], resolved)
                    self.assertNotEqual(resolved, body["model"])
                    record = json.loads(Path("captures.json").read_bytes())[-1]
                    self.assertEqual(base64.b64decode(record["request"]), raw)
                    self.assertEqual(base64.b64decode(record["response"]), received)
                    self.assertTrue(record["contractValidated"])

    def test_configured_auto_router_rejects_other_aliases_and_resolved_model_requests(self):
        with patch.dict(os.environ, {"PI_APP_UI_FIXTURE_MODEL": "auto-router"}):
            for responses in (True, False):
                for wrong_model in ("ui-fixture", "another-router", "fixture-responses-model", "fixture-messages-model"):
                    with self.subTest(responses=responses, wrong_model=wrong_model):
                        path, headers, body = self.request(responses)
                        body["model"] = wrong_model
                        self.assertEqual(self.send(path, headers, body)[0], 400)
        self.assertEqual(gateway.Gateway.records, [])

    def test_catalog_describes_the_configured_route_and_smaller_model(self):
        with patch.dict(os.environ, {"PI_APP_UI_FIXTURE_MODEL": "auto-router"}):
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
            connection.request("GET", "/catalog")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            models = json.loads(response.read())["models"]
            connection.close()
        self.assertEqual(models[0]["id"], "auto-router")
        self.assertEqual(models[1]["maxOutputTokens"], 16_000)
        self.assertEqual(models[1]["contextWindow"], 128_000)
        self.assertEqual(models[1]["reasoning"], [])
        self.assertTrue(models[2]["deprecated"])

    def test_smaller_model_rejects_inherited_limits_and_reasoning_on_both_apis(self):
        for responses in (True, False):
            with self.subTest(responses=responses):
                path, headers, body = self.request(responses, prompt="catalog selection probe")
                body["model"] = "fixture-fast"
                self.assertEqual(self.send(path, headers, body)[0], 400)
                body["max_output_tokens" if responses else "max_tokens"] = 16_000
                effort = "reasoning" if responses else "thinking"
                body[effort] = {"effort": "high"} if responses else {"type": "enabled", "budget_tokens": 8192}
                self.assertEqual(self.send(path, headers, body)[0], 400)
                del body[effort]
                status, raw, received, response_headers = self.send(path, headers, body, include_headers=True)
                self.assertEqual(status, 200)
                resolved = "fixture-fast-responses" if responses else "fixture-fast-messages"
                self.assertEqual(self.model_in_stream(received, responses), resolved)
                self.assertEqual(response_headers["x-fixture-model"], resolved)
                record = json.loads(Path("captures.json").read_bytes())[-1]
                self.assertEqual(base64.b64decode(record["request"]), raw)
                self.assertEqual(base64.b64decode(record["response"]), received)
                self.assertEqual(record["sessionID"], "synthetic-session")
                self.assertEqual(record["turnID"], "synthetic-turn")

    def test_deprecated_catalog_model_is_not_a_callable_route(self):
        for responses in (True, False):
            path, headers, body = self.request(responses)
            body["model"] = "fixture-legacy"
            self.assertEqual(self.send(path, headers, body)[0], 400)
        self.assertEqual(gateway.Gateway.records, [])

    def test_secondary_folder_round_trip_requires_the_actual_file_result(self):
        for responses in (True, False):
            with self.subTest(responses=responses):
                path, headers, body = self.request(responses, prompt="read secondary fixture")
                status, _, received = self.send(path, headers, body)
                self.assertEqual(status, 200)
                events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
                wrong_result = "Synthetic UI fixture file: read-tool round trip verified."
                if responses:
                    call = next(event["response"]["output"][0] for event in events if event["type"] == "response.completed")
                    self.assertEqual(json.loads(call["arguments"]), {"path": "SECONDARY.md"})
                    result = {"type": "function_call_output", "call_id": call["call_id"], "output": wrong_result}
                    body["input"] += [call, result]
                else:
                    call = next(event["content_block"] for event in events if event["type"] == "content_block_start")
                    arguments = next(event["delta"]["partial_json"] for event in events if event["type"] == "content_block_delta")
                    call["input"] = json.loads(arguments)
                    self.assertEqual(call["input"], {"path": "SECONDARY.md"})
                    result = {"type": "tool_result", "tool_use_id": call["id"], "is_error": False, "content": wrong_result}
                    body["messages"] += [{"role": "assistant", "content": [call]}, {"role": "user", "content": [result]}]
                self.assertEqual(self.send(path, headers, body)[0], 400)
                result["output" if responses else "content"] += "\nSECONDARY-WORKSPACE-ROOT-VERIFIED"
                status, raw, received = self.send(path, headers, body)
                self.assertEqual(status, 200)
                events = [json.loads(line[6:]) for line in received.splitlines() if line.startswith(b"data: ")]
                chunks = [event.get("delta", "") for event in events if event["type"] == "response.output_text.delta"] if responses else [
                    event["delta"].get("text", "") for event in events if event["type"] == "content_block_delta"]
                self.assertIn("SECONDARY-WORKSPACE-ROOT-VERIFIED", "".join(chunks))
                record = json.loads(Path("captures.json").read_bytes())[-1]
                self.assertTrue(record["secondaryRootVerified"])
                self.assertEqual(base64.b64decode(record["request"]), raw)
                self.assertEqual(base64.b64decode(record["response"]), received)

    def test_completed_editing_history_remains_valid_in_read_only_side(self):
        for responses in (True, False):
            with self.subTest(responses=responses):
                path, headers, body = self.request(responses)
                status, raw, received = self.send(path, headers, body)
                self.assertEqual(status, 200)
                self.assertIn(b"Fixture reply: side history probe", received)
                record = json.loads(Path("captures.json").read_bytes())[-1]
                self.assertEqual(base64.b64decode(record["request"]), raw)
                self.assertEqual(base64.b64decode(record["response"]), received)
                self.assertTrue(record["contractValidated"])

    def test_historical_schema_does_not_advertise_or_invoke_bash(self):
        path, headers, body = self.request(prompt="stress tool")
        status, _, received = self.send(path, headers, body)
        self.assertEqual(status, 200)
        self.assertNotIn(b"function_call", received)
        self.assertEqual([tool["name"] for tool in body["tools"]], ["read"])

    def test_cancelled_stream_checkpoints_an_independent_prefix(self):
        path, headers, body = self.request(prompt="slow cancellation")
        raw = json.dumps(body, separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request("POST", path, body=raw, headers=headers)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        received = response.read(80)
        response.close()
        connection.close()
        deadline = time.monotonic() + 5
        while not Path("captures.json").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        record = json.loads(Path("captures.json").read_bytes())[-1]
        self.assertTrue(record["cancelled"])
        self.assertEqual(base64.b64decode(record["request"]), raw)
        self.assertTrue(base64.b64decode(record["response"]).startswith(received))

    def test_unknown_malformed_and_unpaired_history_still_fails(self):
        for responses in (True, False):
            for corruption in ("unknown", "wrong argument", "unpaired"):
                with self.subTest(responses=responses, corruption=corruption):
                    path, headers, body = self.request(responses)
                    history = body["input" if responses else "messages"]
                    call = history[0] if responses else history[0]["content"][0]
                    if corruption == "unknown":
                        call["name"] = "unknown-tool"
                    elif corruption == "wrong argument":
                        call["arguments" if responses else "input"] = json.dumps({"command": 7}) if responses else {"command": 7}
                    else:
                        history.pop(1)
                    self.assertEqual(self.send(path, headers, body)[0], 400)
        self.assertEqual(gateway.Gateway.records, [])


if __name__ == "__main__":
    unittest.main()
