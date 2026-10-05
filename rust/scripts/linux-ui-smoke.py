#!/usr/bin/env python3
"""Real X11 window captures of synthetic data, never a macOS/parity/FPS test.
Run only inside a fresh CI Xvfb server (see rust.yml). No application logs or
session/config contents are copied to the artifact directory.
"""
import argparse
import datetime
import json
import os
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
            project = root / "SyntheticProject"
            project.mkdir()
            (project / "fixture.txt").write_text("Synthetic UI fixture. No user data.\n")

            def launch(extra_env=None, extra_args=()):
                log = tempfile.TemporaryFile()
                process = subprocess.Popen([str(binary), *extra_args], cwd=project,
                                           env=env | (extra_env or {}), stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=log)
                processes.append((process, log))
                return process

            def window(process, title):
                def find():
                    if process.poll() is not None:
                        raise RuntimeError(f"Application exited before capture ({process.returncode})")
                    result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid",
                                             str(process.pid), "--name", title],
                                            capture_output=True, text=True, timeout=5)
                    return result.stdout.splitlines()[0] if result.returncode == 0 else None
                ident = wait_for(find, f"visible {title} window")
                command("xdotool", "windowactivate", "--sync", ident)
                return ident

            def capture(process, ident, name, expected):
                path = output / f"{name}.png"
                def rendered():
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
                # Native window activation alone does not focus a GPUI editor.
                # Click the composer in our explicitly fixed 1280x840 fixture.
                command("xdotool", "mousemove", "--sync", "--window", ident, "400", "740")
                command("xdotool", "click", "1")
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
