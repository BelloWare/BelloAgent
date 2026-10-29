#!/usr/bin/env python3
"""Run one Release measurement under the shared quiet-window lock.

Records start/end and sampled peak vm.loadavg; retries load-contaminated runs.
--profile samples only PIDs written by the isolated fixture to its pid file.
Build outside this wrapper, after checking the shared lock. Never launch an app here.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import signal
import shutil
import subprocess
import time
from pathlib import Path

LOCK = Path("/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock")


def load():
    raw = subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()
    return raw, float(raw.split()[1])


def quiet_start(limit):
    # A build/test started before our lock may become CPU-heavy after a low
    # load sample. Let it finish before claiming the measurement window.
    processes = subprocess.check_output(["ps", "-axo", "pid=,stat=,comm="], text=True)
    builds = {"xcodebuild", "swift-frontend", "swift-build", "swift-test"}
    busy = [parts[0] for line in processes.splitlines()
            if len(parts := line.strip().split(None, 2)) == 3
            and not parts[1].startswith("Z") and Path(parts[2]).name in builds]
    if busy:
        print("Waiting for existing build/test PIDs: " + ", ".join(busy), flush=True)
        return False
    if load()[1] > limit:
        print(f"Waiting for one-minute load <= {limit}", flush=True)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--no-trace", action="store_true", help="Control run with test-host span logging disabled")
    parser.add_argument("--profile-after", default="", help="Start sampling after this marker appears in the trial log")
    parser.add_argument("--fixture", type=Path, help="Clone this generated journal afresh for every attempt")
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--start-load", type=float, default=3.0, help="Leave headroom below the mandatory peak limit of 4")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    out = root / "perf"; out.mkdir(parents=True, exist_ok=True)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A command is required")
    artifacts = {}
    def artifact(label, path):
        if path.is_file():
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            artifacts[label] = dict(path=str(path), bytes=path.stat().st_size, sha256=digest)
    artifact("helper", root / "bundle/Helpers/pi-native-host")
    if "-xctestrun" in command:
        if "-derivedDataPath" not in command:
            command.extend(["-derivedDataPath", str(root / "release")])
        manifest_path = Path(command[command.index("-xctestrun") + 1]).resolve()
        assert root in manifest_path.parents, "Use only this lane's DerivedData"
        spec = importlib.util.spec_from_file_location("test_host_guard", Path(__file__).with_name("check-test-host.py"))
        guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
        guard.validate(manifest_path)
        manifest = plistlib.loads(manifest_path.read_bytes())
        scratch = root / "scratch"; scratch.mkdir(exist_ok=True)
        for target in guard.test_targets(manifest):
            host = Path(target["TestHostPath"].replace("__TESTROOT__", str(manifest_path.parent)))
            app = next(p for p in (host, *host.parents) if p.suffix == ".app")
            assert root in app.resolve().parents, "The isolated test host must be under PI_BUILD_ROOT"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            artifact("host", app / "Contents/MacOS" / info["CFBundleExecutable"])
            bundle = Path(target["TestBundlePath"].replace("__TESTHOST__", str(app)).replace("__TESTROOT__", str(manifest_path.parent)))
            assert root in bundle.resolve().parents, "The test bundle must be under PI_BUILD_ROOT"
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            artifact("tests", bundle / "Contents/MacOS" / info["CFBundleExecutable"])
            target.setdefault("EnvironmentVariables", {})["TMPDIR"] = str(scratch) + "/"
            target["EnvironmentVariables"]["TEST_RUNNER_PI_PERF_TRACE"] = "0" if args.no_trace else "1"
            target.setdefault("TestingEnvironmentVariables", {})["TMPDIR"] = str(scratch) + "/"
    def interrupted(sig, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    def fixture_hosts():
        executable = artifacts.get("host", {}).get("path")
        if not executable:
            return set()
        listing = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
        return {int(parts[0]) for line in listing.splitlines()
                if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable}
    existing = [int(p.stem.rsplit("-", 1)[1]) for p in out.glob(args.label + "-*.json")
                if p.stem.rsplit("-", 1)[1].isdigit()]
    first_attempt = max(existing, default=0) + 1
    for attempt in range(first_attempt, first_attempt + args.attempts):
        while True:
            # Let the previous run/build cool without excluding other lanes.
            while not quiet_start(args.start_load):
                time.sleep(20)
            try:
                LOCK.mkdir(); break
            except FileExistsError:
                print("Waiting for full-lane lock", flush=True); time.sleep(60)
        token = f"a136-perf pid={os.getpid()} {time.strftime('%Y-%m-%dT%H:%M:%S%z')}"
        (LOCK / "owner").write_text(token + "\n")
        child = None; samples = []; peak = 0.0; ticks = []
        name = f"{args.label}-{attempt}"
        pidfile = out / f"{name}.pids.json"
        pidfile.unlink(missing_ok=True)
        env = dict(os.environ, TEST_RUNNER_PI_PERF_PID_FILE=str(pidfile), TEST_RUNNER_PI_PERF_TRACE="0" if args.no_trace else "1",
                   TEST_RUNNER_PI_PERF_OUTPUT=str(out / name), TEST_RUNNER_PI_PERF_ROOT=str(root),
                   TEST_RUNNER_PI_APP_SCRATCH_ROOT=str(root / "scratch"), TMPDIR=str(root / "scratch") + "/")
        (root / "scratch").mkdir(exist_ok=True)
        fixture_copy = out / f"{name}-fixture"
        if args.profile:
            env["TEST_RUNNER_PI_PERF_PROFILE_PAUSE"] = "1"
        record = dict(label=args.label, attempt=attempt, command=command, artifacts=artifacts, profile=args.profile, profileAfter=args.profile_after,
                      startLoadLimit=args.start_load, traceEnabled=not args.no_trace,
                      environment={k: v for k, v in env.items() if k.startswith(("TEST_RUNNER_", "PI_BUILD_ROOT"))})
        try:
            if "-xctestrun" in command:
                # A queued control must not change a running trial's trace
                # environment while waiting for the shared measurement lane.
                manifest_path.write_bytes(plistlib.dumps(manifest))
            if args.fixture:
                source = args.fixture.resolve()
                assert root in source.parents, "Only generated journals under PI_BUILD_ROOT are allowed"
                fixture_copy.mkdir()
                target = fixture_copy / "chat.jsonl"
                if subprocess.run(["cp", "-c", str(source), str(target)], capture_output=True).returncode:
                    shutil.copyfile(source, target)
                metadata = Path(str(source) + ".meta")
                if metadata.exists():
                    shutil.copyfile(metadata, Path(str(target) + ".meta"))
                env["TEST_RUNNER_PI_PERF_JOURNAL"] = str(target)
                fixture_manifest_path = source.parent / "manifest.json"
                if not fixture_manifest_path.exists():
                    fixture_manifest_path = source.parent.parent / "manifest.json"
                if fixture_manifest_path.exists():
                    facts = json.loads(fixture_manifest_path.read_text())
                    env["TEST_RUNNER_PI_PERF_EXPECTED_ROWS"] = str(facts["messages"] + facts["compactions"])
                    env["TEST_RUNNER_PI_PERF_EXPECTED_MATCHES"] = str((facts["exchanges"] + 250) // 251)
                    record["fixtureManifest"] = facts
                record["fixture"] = str(source)
                record["environment"] = {k: v for k, v in env.items() if k.startswith(("TEST_RUNNER_", "PI_BUILD_ROOT"))}
            raw, peak = load()
            record.update(start=time.strftime('%Y-%m-%dT%H:%M:%S%z'), startLoad=raw)
            ticks = []; sampled = set(); index_peak = 0
            print(f"{name} start load {raw}", flush=True)
            with (out / f"{name}.log").open("w") as log, (out / f"{name}.log").open() as watched:
                previous_hosts = fixture_hosts()
                child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
                last_load = 0
                last_host_lookup = 0
                marker_seen, marker_tail = not args.profile_after, ""
                while child.poll() is None:
                    # Existing focused classes do not write the PERF-1 PID
                    # file. Recognize only a newly launched, guard-validated
                    # executable in this build root for cleanup/profiling.
                    if not pidfile.exists() and time.monotonic() - last_host_lookup >= .5:
                        last_host_lookup = time.monotonic()
                        hosts = fixture_hosts() - previous_hosts
                        if len(hosts) == 1:
                            pid = next(iter(hosts))
                            try:
                                with pidfile.open("x") as stream:
                                    json.dump(dict(host=pid), stream)
                                record["discoveredTestHostPID"] = pid
                            except FileExistsError:
                                pass  # The opt-in test supplied its own PIDs.
                    if time.monotonic() - last_load >= 2:
                        raw, value = load(); peak = max(peak, value)
                        ticks.append([time.time(), value]); last_load = time.monotonic()
                        index_bytes = 0
                        try:
                            owned = json.loads(pidfile.read_text()).values()
                        except (FileNotFoundError, ValueError):
                            owned = []
                        for pid in owned:
                            for index in (root / "scratch").glob(f"bello-history-p{pid}-*.sqlite"):
                                try:
                                    index_bytes += index.stat().st_size
                                except FileNotFoundError:
                                    pass
                        index_peak = max(index_peak, index_bytes)
                        if value > 4:
                            record["loadAbort"] = True
                            processes = []
                            for line in subprocess.check_output(["ps", "-axo", "pid=,%cpu=,comm="], text=True).splitlines():
                                parts = line.strip().split(None, 2)
                                if len(parts) == 3 and float(parts[1]) >= 5:
                                    processes.append(dict(pid=int(parts[0]), cpu=float(parts[1]), executable=Path(parts[2]).name))
                            record["loadAbortProcesses"] = sorted(processes, key=lambda p: p["cpu"], reverse=True)[:20]
                            child.terminate()
                            try:
                                child.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                child.kill(); child.wait()
                            break
                    if args.profile and not marker_seen:
                        marker_tail += watched.read()
                        marker_seen = args.profile_after in marker_tail
                        marker_tail = marker_tail[-max(1, len(args.profile_after)):]
                    if args.profile and marker_seen and pidfile.exists():
                        try:
                            pids = json.loads(pidfile.read_text())
                        except (ValueError, OSError):
                            pids = {}
                        for kind, pid in pids.items():
                            if pid > 0 and pid not in sampled:
                                sampled.add(pid)
                                samples.append(subprocess.Popen(["sample", str(pid), "10", "10", "-file", str(out / f"{name}-{kind}.sample.txt")],
                                                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    time.sleep(.1)
            raw, value = load(); peak = max(peak, value)
            record.update(end=time.strftime('%Y-%m-%dT%H:%M:%S%z'), endLoad=raw, peakLoad=peak,
                          loadSamples=ticks, indexPeakBytes=index_peak, exit=child.returncode, validLoad=peak <= 4)
            if "xcodebuild" in Path(command[0]).name:
                transcript = (out / f"{name}.log").read_text(errors="replace")
                counts = re.findall(r"Executed (\d+) tests?", transcript)
                record["executedTests"] = max(map(int, counts), default=0)
                if not record["executedTests"] or " skipped (" in transcript:
                    record["exit"] = record["exit"] or 3
                if "TEST_RUNNER_PI_PERF_EXPECTED_ROWS" in env:
                    opened = [json.loads(line[len("PERF136 "):]) for line in transcript.splitlines() if line.startswith("PERF136 {")]
                    opened = [event for event in opened if event.get("event") == "open"]
                    record["rowCountVerified"] = bool(opened) and all(event["positionsTotal"] == int(env["TEST_RUNNER_PI_PERF_EXPECTED_ROWS"]) for event in opened)
                    if not record["rowCountVerified"]:
                        record["exit"] = record["exit"] or 3
            print(f"{name} exit={child.returncode} end load {raw} peak={peak}", flush=True)
        except BaseException as error:
            raw, value = load()
            record.update(end=time.strftime('%Y-%m-%dT%H:%M:%S%z'), endLoad=raw,
                          peakLoad=max(record.get("peakLoad", 0), value, locals().get("peak", 0)),
                          loadSamples=locals().get("ticks", []), validLoad=False, exit=130,
                          aborted=type(error).__name__)
            raise
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
            try:
                owned_pids = json.loads(pidfile.read_text()).values()
            except (OSError, ValueError):
                owned_pids = []
            if record.get("aborted") or record.get("loadAbort"):
                # XCTest can leave its launched host behind after xcodebuild
                # exits. Only stop this attempt's fixture-owned processes.
                for pid in owned_pids:
                    process = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
                    if process.stdout.strip().startswith(str(root) + "/"):
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
            for sample in samples:
                try:
                    sample.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    sample.kill(); sample.wait()
            try:
                for pid in owned_pids:
                    if subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode != 0:
                        for index in (root / "scratch").glob(f"bello-history-p{pid}-*.sqlite"):
                            index.unlink(missing_ok=True)
            finally:
                if (LOCK / "owner").read_text().strip() == token:
                    (LOCK / "owner").unlink(); LOCK.rmdir()
            (out / f"{name}.json").write_text(json.dumps(record, indent=2) + "\n")
            if fixture_copy.exists():
                shutil.rmtree(fixture_copy)
        if record.get("validLoad"):
            return record["exit"]
        print("Discarded timing: one-minute load exceeded 4; retrying", flush=True)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
