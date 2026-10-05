"""Harness logic tests, not desktop interaction evidence."""
import importlib.util
import json
from pathlib import Path
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
            with patch("sys.argv", ["smoke", "box", str(binary), str(output)]), \
                    patch.object(smoke, "command", side_effect=["a" * 40, ""]), \
                    patch.object(smoke.subprocess, "Popen", return_value=process):
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


if __name__ == "__main__":
    unittest.main()
