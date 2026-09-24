"""The live compaction e2e harness (scripts/live-compaction-e2e.py) in its free fixture mode.

The harness bills a real gateway only when the owner runs it. Its fixture mode
drives the release helper against a loopback gateway whose model reasons, so
these tests run it whenever a release helper is built (scripts/build-bundle.py
builds one under $PI_BUILD_ROOT) and skip otherwise. One run must pass; one
with every summary capped at 0.1.90's 13,107 tokens must fail, or the harness
proves nothing. The gateway, the summary prompt parser and the configuration
are checked without a helper.
"""
import argparse
import http.client
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/live-compaction-e2e.py"
sys.path.insert(0, str(ROOT / "fixtures/native"))
import reasoning_gateway  # noqa: E402

spec = importlib.util.spec_from_file_location("live_compaction_e2e", SCRIPT)
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


def release_helper():
    candidates = [pathlib.Path(os.environ["PI_NATIVE_HOST"])] if os.environ.get("PI_NATIVE_HOST") else []
    if os.environ.get("PI_BUILD_ROOT"):
        candidates.append(pathlib.Path(os.environ["PI_BUILD_ROOT"]) / "swift-host/arm64-apple-macosx/release/pi-native-host")
    candidates.append(ROOT / "packages/swift-host/.build/release/pi-native-host")
    return next((path for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)


HELPER = release_helper()


def run_fixture(*extra):
    """One fixture run in a scratch build root: its exit status, output and report."""
    with tempfile.TemporaryDirectory(prefix="pi-live-e2e-test-") as root:
        environment = {name: value for name, value in os.environ.items() if not name.startswith("PI_LIVE_")}
        environment["PI_BUILD_ROOT"] = root
        done = subprocess.run([sys.executable, str(SCRIPT), "--fixture", "--helper", str(HELPER), *extra],
                              env=environment, capture_output=True, text=True, timeout=600)
        reports = sorted(pathlib.Path(root).glob("live-e2e/*/report.json"))
        written = "".join(path.read_text(errors="replace") for path in pathlib.Path(root).rglob("*") if path.is_file())
        return done, json.loads(reports[-1].read_text()) if reports else None, written


@unittest.skipUnless(HELPER, "no release helper is built (scripts/build-bundle.py builds one under $PI_BUILD_ROOT)")
class FixtureRunTests(unittest.TestCase):
    def test_every_scenario_passes_against_a_model_that_reasons(self):
        done, report, written = run_fixture()
        self.assertEqual(done.returncode, 0, done.stdout[-6000:] + done.stderr[-3000:])
        self.assertTrue(report["passed"])
        scenarios = {scenario["scenario"]: scenario for scenario in report["scenarios"]}
        self.assertEqual(list(scenarios), ["compact-now", "mid-run", "over-window"])
        for scenario in report["scenarios"]:
            summaries = [row for row in scenario["requests"] if row["purpose"] == "compaction"]
            self.assertTrue(summaries, scenario["scenario"])
            # Each summary reasoned as a real model does at high effort, and still finished.
            self.assertTrue(all(row["reasoningTokens"] >= 20_000 and row["stopReason"] == "completed" for row in summaries), summaries)
            self.assertTrue(all(row["effectiveMaxOutputTokens"] >= report["contextWindow"] // 4 for row in summaries))
            self.assertEqual([point["phase"] for point in scenario["checkpoints"]], ["completed"])
        self.assertEqual(scenarios["mid-run"]["checkpoints"][0]["reason"], "threshold")
        chunks = [row for row in scenarios["over-window"]["requests"] if row["kind"] in ("history", "history-update")]
        self.assertGreaterEqual(len(chunks), 2, "the history larger than the window is summarized in chained chunks")
        self.assertLess(report["costUSD"], report["costCapUSD"])
        # The fixture's key stands in for a real one: it is never printed or written.
        self.assertNotIn(harness.FIXTURE["key"], done.stdout + done.stderr + written)

    def test_a_summary_capped_at_13107_tokens_fails_every_scenario(self):
        done, report, _ = run_fixture("--fixture-summary-limit", "13107")
        self.assertEqual(done.returncode, 1, done.stdout[-6000:] + done.stderr[-3000:])
        self.assertFalse(report["passed"])
        self.assertEqual(len(report["scenarios"]), 3)
        for scenario in report["scenarios"]:
            failed = {check["name"].split(" (")[0] for check in scenario["checks"] if not check["passed"]}
            self.assertLessEqual({"compaction completed and its summary adopted", "no summary request ended at max_output_tokens",
                                  "every summary request leaves at least 32,000 output tokens", "the run ends idle"}, failed, scenario["scenario"])
            stopped = [row for row in scenario["requests"] if row["purpose"] == "compaction" and row["stopReason"] == "max_output_tokens"]
            self.assertTrue(stopped and all(row["reasoningTokens"] == 13_107 for row in stopped))


def summary_request(limit, effort="high"):
    prompt = "<conversation>\n[User]: Read the notes.\n\n[Assistant]: Done.\n</conversation>\n\nThe messages above are a conversation to summarize."
    body = {"model": "fixture-reasoner", "stream": True, "store": False, "metadata": {"session_id": "gateway-test"},
            "input": [{"role": "developer", "content": "You are a context summarization assistant. Produce the summary."},
                      {"role": "user", "content": [{"type": "input_text", "text": prompt}]}],
            "reasoning": {"effort": effort, "summary": "auto"}}
    if limit is not None:
        body["max_output_tokens"] = limit
    return body


class ReasoningGatewayTests(unittest.TestCase):
    def setUp(self):
        self.gateway = reasoning_gateway.ReasoningGateway(api_key="synthetic-gateway-key", model="fixture-reasoner", window=128_000).start()
        self.addCleanup(self.gateway.stop)

    def post(self, body):
        connection = http.client.HTTPConnection("127.0.0.1", self.gateway.server.server_port, timeout=10)
        connection.request("POST", "/v1/responses", body=json.dumps(body), headers={
            "Authorization": "Bearer synthetic-gateway-key", "Content-Type": "application/json", "Accept": "text/event-stream",
            "x-session-id": "gateway-test", "x-turn-id": "turn-1"})
        response = connection.getresponse()
        data = response.read().decode()
        connection.close()
        return response.status, harness.terminal_event(data.encode())

    def test_reasoning_that_outgrows_the_limit_ends_incomplete_at_max_output_tokens(self):
        status, final = self.post(summary_request(13_107))
        self.assertEqual(status, 200)
        self.assertEqual((final["status"], final["incomplete_details"]["reason"]), ("incomplete", "max_output_tokens"))
        self.assertEqual(final["usage"]["output_tokens"], 13_107)
        self.assertEqual(final["usage"]["output_tokens_details"]["reasoning_tokens"], 13_107)
        self.assertEqual([item["type"] for item in final["output"]], ["reasoning"], "no summary text came out")

    def test_room_for_reasoning_and_the_summary_completes(self):
        for limit in (32_000, None):
            status, final = self.post(summary_request(limit))
            self.assertEqual((status, final["status"]), (200, "completed"))
            self.assertEqual(final["usage"]["output_tokens_details"]["reasoning_tokens"], 20_000)
            text = final["output"][-1]["content"][0]["text"]
            self.assertTrue(text.startswith("## Goal"))
            self.assertGreater(final["usage"]["cost"], 0)

    def test_reasoning_follows_the_effort(self):
        _, low = self.post(summary_request(None, effort="low"))
        _, high = self.post(summary_request(None, effort="high"))
        self.assertLess(low["usage"]["output_tokens_details"]["reasoning_tokens"], high["usage"]["output_tokens_details"]["reasoning_tokens"])

    def test_the_debug_switch_caps_summaries_as_0_1_90_did(self):
        self.gateway.summary_limit = 13_107
        _, final = self.post(summary_request(100_000))
        self.assertEqual(final["status"], "incomplete")
        self.assertEqual(self.gateway.records[-1]["effective_limit"], 13_107)

    def test_a_request_that_breaks_the_wire_contract_is_refused(self):
        body = summary_request(32_000)
        body["stream"] = False
        status, _ = self.post(body)
        self.assertEqual(status, 422)


class SummaryPromptTests(unittest.TestCase):
    def test_the_kind_is_the_prompt_at_the_end_even_when_the_conversation_quotes_another(self):
        quoted = "[Tool result]: This is the PREFIX of a turn that was too large to keep. <previous-summary>"
        cases = {"history": "The messages above are a conversation to summarize.",
                 "history-update": "The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.",
                 "turn-prefix": "This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.",
                 "turn-prefix-update": "The messages above are NEW messages from the same turn prefix, to incorporate into the existing prefix summary "
                                       "provided in <previous-summary> tags.\n\nThis is the PREFIX of a turn that was too large to keep."}
        for kind, tail in cases.items():
            previous = "<previous-summary>\nEarlier summary\n</previous-summary>\n\n" if kind.endswith("update") else ""
            prompt = f"<conversation>\n[User]: hello\n\n{quoted}\n</conversation>\n\n{previous}{tail}"
            parsed, conversation, earlier = reasoning_gateway.parse_summary_prompt(prompt)
            self.assertEqual(parsed, kind)
            self.assertEqual(conversation, f"[User]: hello\n\n{quoted}")
            self.assertEqual(earlier, "Earlier summary" if previous else None)


class ConfigurationTests(unittest.TestCase):
    def arguments(self, **values):
        return argparse.Namespace(**{"fixture": False, "fixture_summary_limit": None, "helper": sys.executable, "scenario": None, "keep": False, **values})

    def environment(self, **values):
        base = {name: value for name, value in os.environ.items() if not name.startswith("PI_LIVE_")}
        return patch.dict(os.environ, {**base, "PI_BUILD_ROOT": tempfile.gettempdir(), **values}, clear=True)

    def test_live_mode_reads_only_the_environment_and_the_catalog(self):
        with self.environment(PI_LIVE_BASE_URL="https://gateway.example/v1", PI_LIVE_API_KEY="sk-synthetic-secret", PI_LIVE_MODEL="kimi-k3"):
            cfg = harness.load_config(self.arguments())
        self.assertEqual((cfg.window, cfg.window_source, cfg.limit, cfg.thinking, cfg.max_cost), (1_048_576, "model catalog", 131_072, "high", 5.0))
        with self.environment(PI_LIVE_BASE_URL="https://gateway.example/v1", PI_LIVE_API_KEY="k" * 20, PI_LIVE_MODEL="unlisted-model"):
            with self.assertRaisesRegex(harness.Failure, "PI_LIVE_CONTEXT_WINDOW"):
                harness.load_config(self.arguments())
        with self.environment(PI_LIVE_BASE_URL="https://gateway.example/v1", PI_LIVE_API_KEY="k" * 20, PI_LIVE_MODEL="unlisted-model",
                              PI_LIVE_CONTEXT_WINDOW="128000", PI_LIVE_THINKING="medium", PI_LIVE_MAX_COST_USD="2.5"):
            cfg = harness.load_config(self.arguments())
        self.assertEqual((cfg.window, cfg.limit, cfg.thinking, cfg.max_cost, cfg.quarter, cfg.threshold), (128_000, None, "medium", 2.5, 32_000, 111_616))
        with self.environment():
            with self.assertRaisesRegex(harness.Failure, "PI_LIVE_BASE_URL"):
                harness.load_config(self.arguments())

    def test_the_key_is_redacted_from_everything_written(self):
        out = harness.Output(["sk-synthetic-secret-123"])
        self.assertEqual(out.redact("Bearer sk-synthetic-secret-123 in a log"), "Bearer [REDACTED] in a log")
        with tempfile.TemporaryDirectory() as folder:
            leaked = pathlib.Path(folder) / "leak.log"
            leaked.write_text("header sk-synthetic-secret-123")
            self.assertEqual(out.scan(pathlib.Path(folder)), ["leak.log"])
            self.assertEqual(leaked.read_text(), "header [REDACTED]")


if __name__ == "__main__":
    unittest.main()
