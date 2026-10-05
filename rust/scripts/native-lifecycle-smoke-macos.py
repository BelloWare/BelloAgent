#!/usr/bin/env python3
"""Own-window lifecycle only; no screenshots, desktop/input/IME/updater parity.

Use only after review on a standard, free public macos-26 Actions job:
  cargo build --locked -p bello-agent-app --features native-lifecycle-smoke
  python3 scripts/native-lifecycle-smoke-macos.py /absolute/path/to/bello-agent
Portable harness tests: python3 scripts/native-lifecycle-smoke-macos.py --self-test
No build, download, signing, security-setting change or artifact upload is done here.
"""
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import unittest

PREFIX = "BELLO_NATIVE_LIFECYCLE "
EXPECTED = ["environment_ready", "window_observed", "close_requested", "window_closed", "app_quitting"]
MAX_LOG_BYTES = 128 * 1024
NATIVE_FAILURES = {"marker_order", "log_write", "duplicate_install", "no_gui_session", "no_display",
                   "no_metal_device", "unexpected_remaining_window", "window_not_ready",
                   "unexpected_window_count", "unexpected_window", "no_content_view", "unexpected_gpui_window_count",
                   "unexpected_visible_window", "native_identity_mismatch", "app_unavailable"}
HARNESS_FAILURES = {"watchdog_timeout", "unclean_exit", "excessive_log", "missing_or_unordered_lifecycle",
                    "requires_reviewed_public_macos26_job", "missing_executable"}


COUNTS_PATTERN = re.compile(
    r"BELLO_NATIVE_WINDOW_COUNTS total=([0-9]{1,3}) expected=([0-9]{1,3}) gpui=([0-9]{1,3}) "
    r"panels=([0-9]{1,3}) visible=([0-9]{1,3}) hidden=([0-9]{1,3}) main=([0-9]{1,3}) "
    r"key=([0-9]{1,3}) matched_active=([01])"
)


def safe_diagnostics(log):
    result = []
    for line in log[:MAX_LOG_BYTES].decode("utf-8", errors="replace").splitlines():
        match = COUNTS_PATTERN.fullmatch(line)
        if match:
            counts = [int(value) for value in match.groups()]
            total, expected, gpui, panels, visible, hidden, main, key, _ = counts
            if (total <= 64 and visible + hidden == total
                    and all(value <= total for value in (expected, gpui, panels, visible, hidden, main, key))):
                result.append(line)
    return result[-8:]


def validate_result(returncode, log, timed_out=False):
    if timed_out:
        raise RuntimeError("watchdog_timeout")
    if len(log) > MAX_LOG_BYTES:
        raise RuntimeError("excessive_log")
    markers = [line[len(PREFIX):] for line in log.decode("utf-8", errors="replace").splitlines() if line.startswith(PREFIX)]
    for marker in markers:
        if marker.startswith("failure:") and marker[8:] in NATIVE_FAILURES:
            raise RuntimeError("native_" + marker[8:])
    if returncode != 0:
        raise RuntimeError("unclean_exit")
    if markers != EXPECTED:
        raise RuntimeError("missing_or_unordered_lifecycle")
    return markers


def isolated_environment(root, runner_temp):
    # Never inherit provider, proxy, credentials, DYLD, Git or user configuration.
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(root / "home"),
        "TMPDIR": str(root / "tmp") + "/",
        "LANG": "en_US.UTF-8",
        "RUNNER_TEMP": str(runner_temp),
        "BELLO_NATIVE_SMOKE_ROOT": str(root),
        "BELLO_NATIVE_LIFECYCLE_SMOKE": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    }


def run(binary):
    # The workflow must additionally keep its explicit public-repository guard and
    # runs-on: macos-26. A local/self-hosted run is deliberately unsupported here.
    if (platform.system() != "Darwin" or platform.machine() != "arm64"
            or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("BELLO_NATIVE_PUBLIC_REPOSITORY") != "true"):
        raise RuntimeError("requires_reviewed_public_macos26_job")
    binary = Path(binary).resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError("missing_executable")
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="bello-native-", dir=runner_temp) as temporary:
        root = Path(temporary).resolve(strict=True)
        for name in ("project", "session", "home", "tmp"):
            (root / name).mkdir()
        command = [str(binary), "--project", str(root / "project"), "--session", str(root / "session/default.json")]
        timed_out = False
        # Keep raw diagnostics transient and private; emit only allowlisted markers.
        with (root / "process.log").open("w+b") as log:
            process = subprocess.Popen(command, cwd=root / "project", env=isolated_environment(root, runner_temp),
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                returncode = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                returncode = process.wait()
            log.seek(0)
            output = log.read(MAX_LOG_BYTES + 1)
            for diagnostic in safe_diagnostics(output):
                print(diagnostic, flush=True)
            markers = validate_result(returncode, output, timed_out)
        for marker in markers:
            print(PREFIX + marker)
        print("PASS: native own-window lifecycle and clean process exit only")


class HarnessTests(unittest.TestCase):
    def test_ordered_markers_and_clean_exit_required(self):
        good = "\n".join(PREFIX + marker for marker in EXPECTED).encode()
        self.assertEqual(validate_result(0, good), EXPECTED)
        for code, log, timeout in [(1, good, False), (0, good, True), (0, b"", False),
                                   (0, good + b"\n" + PREFIX.encode() + b"window_closed", False),
                                   (0, good.replace(b"window_observed", b"close_requested"), False)]:
            with self.assertRaises(RuntimeError):
                validate_result(code, log, timeout)

    def test_no_callbacks_or_partial_markers_count_as_success(self):
        for marker in EXPECTED:
            with self.assertRaises(RuntimeError):
                validate_result(0, (PREFIX + marker).encode())
        with self.assertRaises(RuntimeError):
            validate_result(0, b"window_created\nrender_callback\n")
        with self.assertRaises(RuntimeError):
            validate_result(0, b"x" * (MAX_LOG_BYTES + 1))

    def test_only_known_native_failures_are_reportable(self):
        with self.assertRaisesRegex(RuntimeError, "native_no_display"):
            validate_result(2, (PREFIX + "failure:no_display").encode())
        with self.assertRaisesRegex(RuntimeError, "unclean_exit"):
            validate_result(2, (PREFIX + "failure:/private/unknown").encode())

    def test_window_count_diagnostics_are_bounded_and_never_raw(self):
        safe = "BELLO_NATIVE_WINDOW_COUNTS total=2 expected=1 gpui=1 panels=0 visible=1 hidden=1 main=1 key=1 matched_active=1"
        self.assertEqual(safe_diagnostics((safe + "\nsecret raw title\n" + safe + " title=private").encode()), [safe])
        self.assertEqual(safe_diagnostics((safe.replace("total=2", "total=999")).encode()), [])
        self.assertEqual(safe_diagnostics((safe.replace("visible=1", "visible=0")).encode()), [])
        self.assertEqual(len(safe_diagnostics(((safe + "\n") * 20).encode())), 8)
        good = "\n".join(PREFIX + marker for marker in EXPECTED)
        self.assertEqual(validate_result(0, (safe + "\n" + good).encode()), EXPECTED)
        with self.assertRaises(RuntimeError):
            validate_result(0, safe.encode())

    def test_environment_is_allowlisted(self):
        environment = isolated_environment(Path("/fixture"), Path("/runner"))
        self.assertEqual(environment["HOME"], "/fixture/home")
        self.assertEqual(environment["BELLO_NATIVE_LIFECYCLE_SMOKE"], "1")
        self.assertEqual(set(environment), {"PATH", "HOME", "TMPDIR", "LANG", "RUNNER_TEMP", "BELLO_NATIVE_SMOKE_ROOT",
                                            "BELLO_NATIVE_LIFECYCLE_SMOKE", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT"})


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
    elif len(sys.argv) == 2:
        try:
            run(sys.argv[1])
        except Exception as error:
            # Exceptions may contain local paths or subprocess output. Never echo them.
            known = HARNESS_FAILURES | {"native_" + reason for reason in NATIVE_FAILURES}
            reason = str(error) if isinstance(error, RuntimeError) and str(error) in known else type(error).__name__
            print("FAIL: native lifecycle experiment (" + reason + ")", file=sys.stderr)
            sys.exit(1)
    else:
        print("Usage: native-lifecycle-smoke-macos.py BINARY | --self-test", file=sys.stderr)
        sys.exit(2)
