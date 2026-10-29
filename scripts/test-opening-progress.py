#!/usr/bin/env python3
"""Release wire checks for negotiated journal progress and opening cancellation.

Use only a generated PERF-1 fixture below PI_BUILD_ROOT. No provider calls.
Run under the same full-lane/quiet-window wrapper as the other wire gates.
"""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from native_host_client import HostPeer


class OpeningWireTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="opening-wire-", dir=ROOT / "scratch")
        self.directory = Path(self.temporary.name)
        self.journal = self.directory / "chat.jsonl"
        subprocess.run(["cp", "-c", str(FIXTURE), str(self.journal)], check=True)
        self.peer = HostPeer(BINARY, self.directory, home=self.directory / "home")
        self.profile = dict(id="fixture", revision="1", providerId="litellm", modelId="fixture", api="openai-responses",
                            baseUrl="http://127.0.0.1:1/v1", contextWindow=100000, maxOutputTokens=4096,
                            reasoning=True, thinkingLevel="default", routing=dict(replayPolicy="portable"))

    def tearDown(self):
        self.peer.close(wait=15)
        self.temporary.cleanup()

    def ready(self, progress):
        ready = self.peer.hello(20, displayTransfers=True, commandProgress=progress)
        self.peer.epoch = ready["hostEpoch"]
        self.assertIn("command-progress-v1", ready["capabilities"])
        self.assertIn("open-cancel-v1", ready["capabilities"])
        self.reply(self.peer.post("workspace.open", dict(cwd=str(self.directory), directory=str(self.directory), mcp=dict(servers={}))))

    def open(self):
        self.peer.send(dict(v=1, kind="command", hostEpoch=self.peer.epoch, commandId="opening", readToken="opening-token",
                            method="session.open", sessionId="long", params=dict(profile=self.profile, apiKey="synthetic-only",
                            path=str(self.journal), connectionTest=True)))
        return "opening"

    def reply(self, id):
        progress = []
        while True:
            frame = self.peer.next_frame(timeout=30)
            if frame.get("commandId") != id:
                continue
            self.assertEqual(frame["hostEpoch"], self.peer.epoch)
            if frame["kind"] == "command.progress":
                progress.append(frame)
            elif frame["kind"] == "reply":
                return frame, progress

    def first_progress(self):
        while True:
            frame = self.peer.next_frame(timeout=30)
            if frame.get("commandId") != "opening":
                continue
            self.assertEqual(frame["kind"], "command.progress", "The open finished before cancellation could reach its replay")
            return frame

    def assert_unlocked(self):
        with Path(str(self.journal) + ".lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)

    def assert_advancing(self, progress):
        self.assertGreater(len(progress), 1)
        self.assertEqual(len({p["total"] for p in progress}), 1)
        previous = 0
        for p in progress:
            self.assertGreater(p["completed"], previous)
            self.assertLessEqual(p["completed"], p["total"])
            previous = p["completed"]

    def test_old_app_receives_no_progress(self):
        self.ready(False)
        reply, progress = self.reply(self.open())
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(progress, [])

    def test_open_and_checkpoint_history_report_bounded_work(self):
        self.ready(True)
        reply, progress = self.reply(self.open())
        self.assertTrue(reply["ok"], reply); self.assert_advancing(progress)
        self.reply(self.peer.post("session.close", session="long"))
        self.reply(self.peer.post("session.open", dict(profile=self.profile, apiKey="synthetic-only", path=str(self.journal), connectionTest=True), "long"))
        reply, progress = self.reply(self.peer.post("session.history", dict(version=2, edge="start"), "long"))
        self.assertTrue(reply["ok"], reply); self.assert_advancing(progress)

    def test_cancel_reply_follows_unwind_and_lock_release(self):
        self.ready(True); self.open(); self.first_progress()
        self.peer.send(dict(v=1, kind="read.cancel", hostEpoch=self.peer.epoch, requestId="opening", readToken="opening-token"))
        reply, _ = self.reply("opening")
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["result"]["code"], "command_cancelled")
        self.assert_unlocked()
        status, _ = self.reply(self.peer.post("session.status", session="long"))
        self.assertFalse(status["ok"])
        self.assertEqual(status["result"]["code"], "session_missing")

    def test_disconnect_during_open_releases_the_writer(self):
        self.ready(True); self.open(); self.first_progress()
        self.peer.close(wait=15)
        self.assertEqual(self.peer.process.returncode, 0)
        self.assert_unlocked()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    ROOT = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    BINARY, FIXTURE = args.binary.resolve(), args.fixture.resolve()
    assert ROOT in BINARY.parents and ROOT in FIXTURE.parents
    assert FIXTURE.name == "chat.jsonl" and FIXTURE.stat().st_size > 100 * 1024 * 1024
    (ROOT / "scratch").mkdir(exist_ok=True)
    unittest.main(argv=[__file__, *remaining])
