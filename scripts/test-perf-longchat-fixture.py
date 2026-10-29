#!/usr/bin/env python3
"""Small fixture contract checks; large journals belong only in PI_BUILD_ROOT."""
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("perf-longchat-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class LongChatFixtureTests(unittest.TestCase):
    def test_seed_chain_turns_and_compactions(self):
        with tempfile.TemporaryDirectory(dir=os.environ["PI_BUILD_ROOT"]) as scratch:
            root = Path(scratch)
            a = fixture.generate(root / "a", exchanges=180, seed=136, compact_every=32)
            b = fixture.generate(root / "b", exchanges=180, seed=136, compact_every=32)
            self.assertEqual(a, b)
            data = (root / "a/chat.jsonl").read_bytes()
            self.assertEqual(data, (root / "b/chat.jsonl").read_bytes())
            self.assertEqual(a["sha256"], hashlib.sha256(data).hexdigest())
            records = [json.loads(line) for line in data.splitlines()]
            self.assertEqual(records[0]["type"], "session")
            previous = None; ids = set(); roles = {}; calls = set(); results = set()
            for record in records[1:]:
                self.assertEqual(record["parentId"], previous)
                self.assertNotIn(record["id"], ids)
                previous = record["id"]; ids.add(previous)
                if record["type"] == "message":
                    message = record["message"]; roles[record["id"]] = message["role"]
                    for block in message["content"] if isinstance(message["content"], list) else []:
                        if block["type"] == "toolCall":
                            calls.add(block["id"])
                    if message["role"] == "toolResult":
                        self.assertIn(message["toolCallId"], calls); results.add(message["toolCallId"])
                if record["type"] == "compaction":
                    self.assertTrue(set(record["nativeKeptIDs"]).issubset(roles))
                    self.assertEqual(roles[record["nativeKeptIDs"][0]], "user")
            self.assertEqual(calls, results)
            self.assertEqual(len(roles), a["messages"])
            self.assertEqual(a["exchanges"], 180)
            for key in ("images", "subagent", "thinking", "compactions"):
                self.assertGreater(a[key], 0)
            self.assertGreater(a["toolOutputBytes"]["0.99"], 64000)
            self.assertFalse(Path(str(root / "a/chat.jsonl") + ".meta").exists())

    def test_message_target_keeps_the_last_turn_whole(self):
        with tempfile.TemporaryDirectory(dir=os.environ["PI_BUILD_ROOT"]) as scratch:
            root = Path(scratch)
            a = fixture.generate(root / "a", messages=500, seed=7)
            b = fixture.generate(root / "b", messages=500, seed=8)
            self.assertGreaterEqual(a["messages"], 500)
            self.assertLess(a["messages"], 565)
            self.assertNotEqual(a["sha256"], b["sha256"])
            with self.assertRaises(ValueError):
                fixture.generate(root / "a", messages=500)


if __name__ == "__main__":
    unittest.main()
