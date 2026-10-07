#!/usr/bin/env python3
"""Headless/no-cost fixture tests. No desktop process is launched."""
import contextlib
import http.client
import io
import json
import tempfile
import threading
import time
import types
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
import skills_workflow_fixture as fixture


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "generated"
        self.args = types.SimpleNamespace(root=self.root, port=47887)
        with contextlib.redirect_stdout(io.StringIO()):
            fixture.initialize(self.args)

    def tearDown(self):
        self.temp.cleanup()

    def mutate(self, change):
        with contextlib.redirect_stdout(io.StringIO()):
            fixture.mutate(types.SimpleNamespace(root=self.root, skill="alpha", change=change))

    def test_generated_identity_and_explicit_policy_without_overwrite(self):
        _, marker = fixture.root_for(self.root)
        self.assertEqual(marker["port"], 47887)
        facts = fixture.source_facts(self.root)
        skills = [item for item in facts if item["selection_id"]]
        self.assertEqual(len(skills), 3)
        self.assertEqual(len({item["selection_id"] for item in skills}), 3)
        for name in ["a-review", "b-review"]:
            text = (self.root / "project/.agents/skills" / name / "SKILL.md").read_text()
            self.assertIn("name: review\n", text)
            self.assertIn("disable-model-invocation: true\n", text)
        self.assertEqual((self.root / "fixtures/generated.gif").read_bytes(), fixture.base64.b64decode(fixture.GIF))
        with self.assertRaises(ValueError):
            fixture.initialize(self.args)

    def test_body_only_mutation_keeps_frontmatter_metadata_and_canonical_id(self):
        skill = self.root / "project/.agents/skills/a-review"
        original = (skill / "SKILL.md").read_text()
        metadata = (skill / "agents/openai.yaml").read_bytes()
        self.mutate("body")
        changed = (skill / "SKILL.md").read_text()
        self.assertEqual(original.split("---")[:2], changed.split("---")[:2])
        self.assertNotEqual(original, changed)
        self.assertEqual(metadata, (skill / "agents/openai.yaml").read_bytes())
        self.mutate("policy")
        self.assertIn("invalid", (skill / "agents/openai.yaml").read_text())
        self.mutate("delete")
        self.assertFalse((skill / "SKILL.md").exists())
        self.mutate("restore")
        self.assertEqual((skill / "SKILL.md").read_text(), original)
        self.assertEqual((skill / "agents/openai.yaml").read_bytes(), metadata)
        self.assertEqual(len((self.root / "evidence/mutations.jsonl").read_text().splitlines()), 4)

    def test_structural_log_separates_raw_slashes_and_explicit_ids(self):
        body = {"input": [{"role": "user", "content": [{"type": "input_text", "text": "/review"}]},
                          {"role": "user", "content": [{"type": "input_text", "text": "SKILL_ALPHA_BODY_V1\n\nCurrent explicit selection IDs: one, two\n\nunique-generated-caption"},
                                                        {"type": "input_image", "image_url": "data:image/gif;base64," + fixture.GIF}]}]}
        facts = fixture.request_facts(body)
        self.assertEqual(facts["users"][0]["selection_line_ids"], [])
        self.assertEqual(facts["users"][1]["selection_line_ids"], ["one", "two"])
        self.assertEqual(facts["users"][1]["fixture_markers"], ["SKILL_ALPHA_BODY_V1"])
        self.assertNotIn("unique-generated-caption", json.dumps(facts))
        self.assertNotIn(fixture.GIF, json.dumps(facts))

    def test_controlled_fail_hold_tool_and_request_capture_never_log_headers(self):
        root, marker = fixture.root_for(self.root)
        state = fixture.FixtureState(root, marker)
        server = ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler_for(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_port
        def request(path, value):
            client = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
            client.request("POST", path, json.dumps(value).encode(), {"Content-Type": "application/json", "Authorization": "Bearer fake-header-never-log"})
            response = client.getresponse()
            result = response.status, response.read()
            client.close()
            return result
        try:
            status, _ = request("/control", {"enqueue": [{"mode": "fail"}, {"mode": "hold-tool", "seconds": 5}]})
            self.assertEqual(status, 200)
            body = {"model": "generated", "tools": [{"name": "ls"}], "input": [{"role": "user", "content": [{"type": "input_text", "text": "unique-generated-caption"}]}]}
            self.assertEqual(request("/v1/responses", body)[0], 503)
            output = []
            pending = threading.Thread(target=lambda: output.append(request("/v1/responses", body)))
            pending.start()
            deadline = time.monotonic() + 3
            while not state.status()["held_requests"]:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            self.assertEqual(request("/control", {"release": "all"})[0], 200)
            pending.join(timeout=3)
            self.assertFalse(pending.is_alive())
            self.assertEqual(output[0][0], 200)
            self.assertIn(b'"name": "ls"', output[0][1])
            self.assertEqual(request("/control", {"enqueue": [{"mode": "external"}]})[0], 400)
            logged = (self.root / "evidence/requests.jsonl").read_text()
            self.assertNotIn("fake-header-never-log", logged)
            self.assertNotIn("unique-generated-caption", logged)
            for path in (self.root / "evidence/requests").glob("*.json"):
                self.assertEqual(json.loads(path.read_text()), body)
                self.assertNotIn("fake-header-never-log", path.read_text())
        finally:
            for event in list(state.held.values()):
                event.set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_seal_records_exact_binary_and_source_manifest(self):
        source = Path(self.temp.name) / "source"
        (source / "rust/crates/example").mkdir(parents=True)
        (source / "rust/crates/example/main.rs").write_text("fn main() {}\n")
        binary = Path(self.temp.name) / "fixture-binary"
        binary.write_bytes(b"generated-test-not-executed")
        with contextlib.redirect_stdout(io.StringIO()):
            fixture.seal(types.SimpleNamespace(root=self.root, binary=binary, source_root=source, source_id="generated-unit-fixture"))
        value = json.loads((self.root / "evidence/sealed-build.json").read_text())
        self.assertEqual(value["binary_sha256"], fixture.digest(binary.read_bytes()))
        self.assertEqual(Path(value["binary"]).read_bytes(), binary.read_bytes())
        self.assertEqual(len(value["source_files"]), 1)


if __name__ == "__main__":
    unittest.main()
