"""Harness logic tests; real subprocess bounds, not desktop interaction evidence."""
import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("smoke", Path(__file__).with_name("linux-ui-smoke.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class HarnessTests(unittest.TestCase):
    def test_ocr_resamples_only_temporary_copy(self):
        with patch.object(smoke, "command", side_effect=["", "Tools unavailable"]) as command:
            text = smoke.visible_text(Path("evidence.png"), Path("scratch.png"))
        self.assertEqual(text, "tools unavailable")
        self.assertEqual(command.call_args_list[0].args,
                         ("convert", "evidence.png", "-resize", "200%", "scratch.png"))
        self.assertEqual(command.call_args_list[1].args,
                         ("tesseract", "scratch.png", "stdout", "--psm", "11"))

    def test_poll_returns_actual_value(self):
        self.assertEqual(smoke.wait_for(lambda: "window-id", "window"), "window-id")

    def test_deadline_fails_instead_of_claiming_success(self):
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            smoke.wait_for(lambda: False, "not rendered", seconds=0)

    def test_crashed_app_produces_failed_sanitized_report(self):
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root) / "fake-binary"
            binary.touch()
            output = Path(root) / "evidence"
            process = Mock()
            process.poll.return_value = 1
            capture = Mock(exceeded=False)
            with patch("sys.argv", ["smoke", "box", str(binary), str(output)]), \
                    patch.object(smoke, "command", side_effect=["a" * 40, ""]), \
                    patch.object(smoke.subprocess, "Popen", return_value=process), \
                    patch.object(smoke, "BoundedCapture", return_value=capture), \
                    patch.object(smoke, "startup_diagnostics", return_value={"child_alive": False}):
                with self.assertRaisesRegex(RuntimeError, "exited before capture"):
                    smoke.main()
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["checks"], [])
            self.assertEqual(report["failure"], "RuntimeError")
            self.assertNotIn(root, json.dumps(report))
            self.assertEqual(sorted(p.name for p in output.iterdir()), ["report.json"])

    def test_existing_evidence_is_never_reused(self):
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root) / "fake-binary"
            binary.touch()
            with patch("sys.argv", ["smoke", "agent", str(binary), root]):
                with self.assertRaises(FileExistsError):
                    smoke.main()

    def test_log_categories_never_emit_private_text(self):
        flags = smoke.diagnostic_log_flags(b"/private/secret token=secret123 panicked at Vulkan X11 FONT permission denied")
        self.assertEqual(flags, ["rust_panic", "mentions_vulkan", "mentions_x11",
                                 "mentions_font", "mentions_permission_denied"])
        self.assertNotIn("secret", json.dumps(flags))
        self.assertEqual(smoke.diagnostic_log_flags(b"x" * smoke.MAX_DIAGNOSTIC_BYTES + b"panicked at"), [])

    def test_actual_noisy_probe_is_killed_without_temporary_storage(self):
        with patch.object(smoke.tempfile, "TemporaryFile", side_effect=AssertionError("no disk capture")):
            status, out, err = smoke.bounded_probe(
                sys.executable, "-c", "import os,time; os.write(1,b'x'*1048576); time.sleep(30)")
        self.assertEqual(status, "output_limit")
        self.assertEqual(len(out), 4096)
        self.assertLessEqual(len(err), 4096)

    def test_probe_preserves_small_stdout_stderr_and_exit(self):
        status, out, err = smoke.bounded_probe(
            sys.executable, "-c", "import sys; print('out'); print('err',file=sys.stderr); sys.exit(3)")
        self.assertEqual((status, out, err), (3, "out\n", "err\n"))

    def test_probe_timeout_kills_real_process(self):
        with patch.object(smoke.time, "monotonic", side_effect=[0, 3]):
            status, _, _ = smoke.bounded_probe(sys.executable, "-c", "import time; time.sleep(30)")
        self.assertEqual(status, "timeout")

    def test_noisy_app_storage_is_bounded_and_stops_before_diagnostics(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import os,time; os.write(1,b'x'*1048576); time.sleep(30)"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0, pipesize=4096, start_new_session=True)
        capture = smoke.BoundedCapture(process.stdout, 128)
        try:
            self.assertEqual(fcntl.fcntl(process.stdout.fileno(), fcntl.F_GETPIPE_SZ), 4096)
            smoke.wait_for(lambda: (capture.read_available(), capture.exceeded)[1], "noise", seconds=2)
            self.assertEqual(len(capture.data), 128)
            def query(*args):
                self.assertIsNotNone(process.poll(), "noisy child must stop before diagnostic probes")
                return "unavailable", "", ""
            with patch.object(smoke, "bounded_probe", side_effect=query):
                result = smoke.startup_diagnostics(process, capture, "expected")
            self.assertTrue(result["private_log_exceeded_limit"])
            self.assertEqual(result["private_log_bytes_capped"], 128)
        finally:
            if process.poll() is None:
                smoke.kill_fixture_group(process)
                process.wait(timeout=2)
            capture.close()

    def test_startup_diagnostics_are_numeric_or_allowlisted(self):
        capture = Mock(exceeded=False)
        capture.read_available.return_value = b'{"event":"window_created","private":"secret"}\n{"event":"startup_initialized"}\n{"event":"render_callback"}\nprivate-secret Vulkan'
        process = Mock(pid=123)
        process.poll.return_value = None
        replies = [(0, "_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x123", ""),
                   (0, "101\n102", ""), (0, "102", ""), (1, "", "private-error")]
        with patch.object(smoke, "bounded_probe", side_effect=replies) as probe:
            result = smoke.startup_diagnostics(process, capture, "^Bello Box$")
        self.assertTrue(result["child_alive"])
        self.assertTrue(result["wm_registered"])
        self.assertTrue(result["window_created_marker"])
        self.assertTrue(result["startup_initialized_marker"])
        self.assertTrue(result["render_callback_marker"])
        self.assertEqual(result["own_windows_count_capped"], 2)
        self.assertEqual(result["own_visible_windows_count_capped"], 1)
        self.assertEqual(result["own_expected_visible_windows_count_capped"], 0)
        self.assertNotIn("secret", json.dumps(result))
        self.assertIn("--all", probe.call_args_list[-1].args)
        self.assertIn("--pid", probe.call_args_list[-1].args)

    def test_probe_failure_status_does_not_claim_zero_windows(self):
        capture = Mock(exceeded=False)
        capture.read_available.return_value = b""
        process = Mock(pid=123)
        process.poll.return_value = 3
        with patch.object(smoke, "bounded_probe", return_value=("unavailable", "", "")):
            result = smoke.startup_diagnostics(process, capture, "expected")
        self.assertFalse(result["child_alive"])
        self.assertEqual(result["child_exit_code"], 3)
        self.assertIsNone(result["own_windows_count_capped"])
        self.assertFalse(result["window_created_marker"])


if __name__ == "__main__":
    unittest.main()
