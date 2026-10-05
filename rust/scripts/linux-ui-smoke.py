#!/usr/bin/env python3
"""Real X11 window captures of synthetic data, never a macOS/parity/FPS test.
Run only inside a fresh CI Xvfb server (see rust.yml). No application logs or
session/config contents are copied to the artifact directory.
"""
import argparse
import datetime
import json
import os
import re
import signal
from pathlib import Path
import subprocess
import tempfile
import time


def command(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=20, **kwargs).stdout.strip()


def wait_for(predicate, description, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.3)
    raise RuntimeError(f"Timed out: {description}")

MAX_DIAGNOSTIC_BYTES = 128 * 1024


class BoundedCapture:
    """A capped private memory prefix backed by a small, nonblocking pipe."""
    def __init__(self, stream, limit):
        self.stream = stream
        self.limit = limit
        self.data = bytearray()
        self.exceeded = False
        self.eof = False
        os.set_blocking(stream.fileno(), False)

    def read_available(self):
        while not self.eof and not self.exceeded:
            try:
                chunk = os.read(self.stream.fileno(), min(4096, self.limit - len(self.data) + 1))
            except BlockingIOError:
                break
            if not chunk:
                self.eof = True
                break
            remaining = self.limit - len(self.data)
            self.data.extend(chunk[:remaining])
            if len(chunk) > remaining:
                self.exceeded = True
        return bytes(self.data)

    def close(self):
        self.stream.close()


def kill_fixture_group(process):
    # Every captured process is created in its own session. Never signal a shared
    # desktop/process group, and don't leave a noisy helper holding the pipe open.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def bounded_probe(*args):
    """Bound private output in memory and in 4KiB pipes; no temporary log files."""
    try:
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   bufsize=0, pipesize=4096, start_new_session=True)
    except OSError:
        return "unavailable", "", ""
    stdout = BoundedCapture(process.stdout, 4096)
    stderr = BoundedCapture(process.stderr, 4096)
    deadline = time.monotonic() + 2
    status = None
    try:
        while True:
            stdout.read_available()
            stderr.read_available()
            if stdout.exceeded or stderr.exceeded:
                status = "output_limit"
                kill_fixture_group(process)
                break
            if process.poll() is not None and stdout.eof and stderr.eof:
                status = process.returncode
                break
            if time.monotonic() >= deadline:
                status = "timeout"
                kill_fixture_group(process)
                break
            time.sleep(0.01)
        process.wait(timeout=2)
        return (status, bytes(stdout.data).decode("utf-8", "replace"),
                bytes(stderr.data).decode("utf-8", "replace"))
    finally:
        if process.poll() is None:
            kill_fixture_group(process)
            process.wait(timeout=2)
        stdout.close()
        stderr.close()


def diagnostic_log_flags(raw):
    """Allowlisted categories only, never paths, payloads or arbitrary log text."""
    text = raw[:MAX_DIAGNOSTIC_BYTES].lower()
    patterns = {
        "rust_panic": b"panicked at",
        "app_window_creation_error": b"cannot open bello box",
        "mentions_vulkan": b"vulkan",
        "mentions_x11": b"x11",
        "mentions_font": b"font",
        "mentions_permission_denied": b"permission denied",
    }
    return [name for name, pattern in patterns.items() if pattern in text]


def startup_diagnostics(process, log, title):
    raw = log.read_available()
    # Stop a noisy process before spending time on the bounded X11 queries.
    if log.exceeded:
        kill_fixture_group(process)
        process.wait(timeout=2)
    status = process.poll()
    result = {
        "child_alive": status is None,
        "child_exit_code": status,
        "private_log_bytes_capped": len(raw),
        "private_log_exceeded_limit": log.exceeded,
        "private_log_categories": diagnostic_log_flags(raw),
    }
    wm_status, wm_output, _ = bounded_probe("xprop", "-root", "_NET_SUPPORTING_WM_CHECK")
    result["x11_query_status"] = wm_status
    result["wm_query_status"] = wm_status
    result["wm_registered"] = bool(re.search(r"window id # 0x[1-9a-fA-F][0-9a-fA-F]*", wm_output))
    for label, options in (
        ("own_windows", []),
        ("own_visible_windows", ["--onlyvisible"]),
        ("own_expected_visible_windows", ["--onlyvisible", "--name", title]),
    ):
        code, output, _ = bounded_probe("xdotool", "search", "--all", "--limit", "64",
                                         "--pid", str(process.pid), *options)
        result[label + "_query_status"] = code
        result[label + "_count_capped"] = (
            min(64, sum(line.isdigit() for line in output.splitlines())) if code == 0 else (0 if code == 1 else None))
    markers = {"window_created", "startup_initialized", "render_callback"}
    for marker in markers:
        result[marker + "_marker"] = False
    for line in raw.splitlines():
        try:
            event = json.loads(line)
            if isinstance(event, dict) and event.get("event") in markers:
                result[event["event"] + "_marker"] = True
        except (ValueError, TypeError, RecursionError):
            pass
    return result


def visible_text(capture, scratch):
    # Small UI labels are unreliable OCR at 1x. Scale only a disposable OCR
    # input, never the original screenshot delivered as evidence.
    command("convert", str(capture), "-resize", "200%", str(scratch))
    return command("tesseract", str(scratch), "stdout", "--psm", "11").lower()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=["box", "agent"])
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    output = args.output.resolve()
    # Never mix evidence from multiple runs, including previously successful ones.
    output.mkdir(parents=True, exist_ok=False)
    report = {
        "commit": command("git", "rev-parse", "HEAD"),
        "dirty_tree": bool(command("git", "status", "--porcelain")),
        "captured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": "Linux X11 / Xvfb / Mesa lavapipe software Vulkan",
        "scope": "Live window capture and keyboard smoke only; not visual parity, macOS validation, or frame-performance evidence",
        "data": "Synthetic fixtures only; disconnected from model providers",
        "checks": [], "status": "failed",
    }
    processes = []
    try:
        with tempfile.TemporaryDirectory(prefix="bello-ui-fixture-") as root:
            root = Path(root)
            # Preserve HOME per repository guidance. Override each app's explicit
            # Rust storage path, and omit inherited credentials/provider settings.
            env = {key: os.environ[key] for key in
                   ("PATH", "HOME", "DISPLAY", "XAUTHORITY", "LANG", "VK_ICD_FILENAMES")
                   if key in os.environ}
            for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
                path = root / key.lower()
                path.mkdir(mode=0o700)
                env[key] = str(path)
            env["BELLOBOX_CONFIG_DIR"] = str(root / "box-config")
            env["BELLO_TEST_APPEARANCE"] = "light"
            env["BELLO_TEST_WINDOW_SIZE"] = "1280x840"
            env["LIBGL_ALWAYS_SOFTWARE"] = "1"
            # Existing numeric startup telemetry joins the same bounded private pipe.
            env["BELLO_PERF_LOG"] = "/dev/stdout"
            project = root / "SyntheticProject"
            project.mkdir()
            (project / "fixture.txt").write_text("Synthetic UI fixture. No user data.\n")

            def launch(extra_env=None, extra_args=()):
                process = subprocess.Popen([str(binary), *extra_args], cwd=project,
                                           env=env | (extra_env or {}), stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           bufsize=0, pipesize=4096, start_new_session=True)
                log = BoundedCapture(process.stdout, MAX_DIAGNOSTIC_BYTES)
                processes.append((process, log))
                return process

            def window(process, title):
                log = next(log for child, log in processes if child is process)
                def find():
                    log.read_available()
                    if log.exceeded:
                        kill_fixture_group(process)
                        raise RuntimeError("Application startup log exceeded diagnostic limit")
                    if process.poll() is not None:
                        raise RuntimeError(f"Application exited before capture ({process.returncode})")
                    code, output, _ = bounded_probe(
                        "xdotool", "search", "--all", "--limit", "1", "--onlyvisible",
                        "--pid", str(process.pid), "--name", title)
                    return output.splitlines()[0] if code == 0 and output.splitlines() else None
                try:
                    ident = wait_for(find, f"visible {title} window")
                except Exception:
                    report["startup_diagnostics"] = startup_diagnostics(process, log, title)
                    raise
                command("xdotool", "windowactivate", "--sync", ident)
                return ident

            def capture(process, ident, name, expected):
                path = output / f"{name}.png"
                log = next(log for child, log in processes if child is process)
                def rendered():
                    log.read_available()
                    if log.exceeded:
                        kill_fixture_group(process)
                        raise RuntimeError("Application log exceeded diagnostic limit")
                    if process.poll() is not None:
                        raise RuntimeError("Application exited during UI smoke")
                    command("import", "-window", ident, str(path))
                    text = visible_text(path, root / "ocr-only.png")
                    return all(token.lower() in text for token in expected)
                wait_for(rendered, f"{name}: visible text {expected}")
                report["checks"].append({"capture": path.name, "visible_text": expected,
                                         "result": "passed"})

            if args.app == "box":
                process = launch()
                ident = window(process, "^Bello Box$")
                capture(process, ident, "01-home", ["Everything within reach"])
                command("xdotool", "key", "--clearmodifiers", "ctrl+2")
                capture(process, ident, "02-developer-keyboard", ["Inspect", "transform", "build"])
                process.terminate()
                process.wait(timeout=10)
                process = launch({"BELLOBOX_TOOL": "qr", "BELLOBOX_INPUT": "Synthetic UI fixture"})
                ident = window(process, "QR Code")
                capture(process, ident, "03-qr-fixture", ["Encoded text", "Synthetic UI fixture"])
            else:
                process = launch(extra_args=("--project", str(project), "--session", str(root / "session.json")))
                ident = window(process, "^Bello Agent$")
                capture(process, ident, "01-disconnected-shell", ["No connection", "Tools unavailable"])
                # Assert the startup shortcut works before any click. A focus
                # regression must fail visibly, not be hidden by the harness.
                command("xdotool", "key", "--clearmodifiers", "ctrl+p")
                capture(process, ident, "02-file-picker-open", ["Find a file"])
                command("xdotool", "type", "--clearmodifiers", "--delay", "70", "fixture")
                capture(process, ident, "03-file-search-keyboard", ["fixture.txt"])
                command("xdotool", "key", "--clearmodifiers", "Escape")
            report["status"] = "passed"
    except Exception as error:
        # Deliberately exclude raw process output, environment and private paths.
        report["failure"] = type(error).__name__
        raise
    finally:
        for process, log in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            log.close()
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
