#!/usr/bin/env python3
"""Create a helper-owned checkpoint and measure real session.open/history IPC.

Only accepts journals below PI_BUILD_ROOT. The cold source is preserved; a
clone in warm/ is opened by the real helper, which writes its own checkpoint.
Run timing trials through perf-longchat-run.py. No provider requests are sent.
"""
import argparse
import base64
import ctypes
import json
import os
import resource
import shutil
import subprocess
import time
from pathlib import Path
from native_host_client import HostPeer


LIBSYSTEM = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def usage(pid):
    # rusage_info_v4: UUID followed by 35 uint64 fields (sys/resource.h).
    # CPU counters are Mach ticks on arm64, not nanoseconds.
    value = ctypes.create_string_buffer(16 + 35 * 8)
    if LIBSYSTEM.proc_pid_rusage(pid, 4, ctypes.byref(value)):
        return {}
    fields = (ctypes.c_uint64 * 35).from_buffer(value, 16)
    clock = Timebase(); LIBSYSTEM.mach_timebase_info(ctypes.byref(clock))
    seconds = clock.numer / clock.denom / 1e9
    return dict(userSeconds=fields[0] * seconds, systemSeconds=fields[1] * seconds,
                footprintMiB=fields[7] / 1048576, peakFootprintMiB=fields[28] / 1048576,
                diskReadMiB=fields[16] / 1048576)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--cold", action="store_true")
    args = parser.parse_args()
    root = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    fixture = args.fixture.resolve()
    assert root in fixture.parents
    source = fixture / "chat.jsonl"
    manifest = json.loads((fixture / "manifest.json").read_text())
    expected_rows = manifest["messages"] + manifest["compactions"]
    directory = fixture / ("warm" if args.prepare or not args.cold else "cold-helper")
    directory.mkdir(exist_ok=True)
    journal = directory / "chat.jsonl"
    if args.prepare or args.cold or not journal.exists():
        journal.unlink(missing_ok=True)
        Path(str(journal) + ".meta").unlink(missing_ok=True)
        if subprocess.run(["cp", "-c", str(source), str(journal)], capture_output=True).returncode:
            shutil.copyfile(source, journal)
    profile = dict(id="fixture", revision="1", providerId="litellm", modelId="fixture", api="openai-responses",
                   baseUrl="http://127.0.0.1:1/v1", contextWindow=100000, maxOutputTokens=4096,
                   reasoning=True, thinkingLevel="default", routing=dict(replayPolicy="portable"))
    cpu0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    peer = HostPeer(root / "bundle/Helpers/pi-native-host", directory, home=directory / "home")
    pidfile = os.environ.get("TEST_RUNNER_PI_PERF_PID_FILE")
    if pidfile:
        Path(pidfile).write_text(json.dumps(dict(helper=peer.process.pid)))
    try:
        peer.epoch = peer.hello(20, displayTransfers=True)["hostEpoch"]
        def command(method, params=None, session=None):
            before = usage(peer.process.pid)
            started = time.monotonic()
            id = peer.post(method, params, session)
            while True:
                frame = peer.next_frame(timeout=600)
                if frame.get("commandId") == id:
                    assert frame["ok"], frame
                    result = frame.get("result", {})
                    transferred = 0
                    if result.get("_displayTransfer") == 1:
                        marker = result
                        data = bytearray()
                        while len(data) < marker["bytes"]:
                            part = command("display.result.read", dict(id=marker["id"], offset=len(data)))
                            assert part["offset"] == len(data)
                            data.extend(base64.b64decode(part["data"], validate=True))
                        assert len(data) == marker["bytes"]
                        transferred = len(data)
                        result = json.loads(data)
                    elapsed = (time.monotonic()-started)*1000
                    after = usage(peer.process.pid)
                    print("PERF136_HELPER " + json.dumps(dict(method=method, ms=elapsed,
                          replyBytes=len(peer.encode(frame)), transferredBytes=transferred, pid=peer.process.pid,
                          usage=after, cpuDeltaSeconds=sum(after.get(k, 0)-before.get(k, 0) for k in ["userSeconds", "systemSeconds"]))), flush=True)
                    return result
        command("workspace.open", dict(cwd=str(directory), directory=str(directory), mcp=dict(servers={})))
        if os.environ.get("TEST_RUNNER_PI_PERF_PROFILE_PAUSE"):
            time.sleep(1)
        command("session.open", dict(profile=profile, apiKey="synthetic-only", path=str(journal), connectionTest=True), "long")
        checkpoint = Path(str(journal) + ".meta")
        assert checkpoint.exists(), "The helper did not create a checkpoint"
        metadata = json.loads(checkpoint.read_text())
        assert metadata["rowsBefore"] + len(metadata["rows"]) == expected_rows, "Checkpoint omitted fixture rows"
        print("PERF136_CHECKPOINT " + json.dumps(dict(bytes=checkpoint.stat().st_size, rows=len(metadata["rows"]),
                                                   rowsBefore=metadata["rowsBefore"], version=metadata["version"])), flush=True)
        if not args.prepare:
            first = command("session.history", dict(version=2, opening=True), "long")
            assert first.get("total") == expected_rows, "Helper opened an incomplete fixture"
            print("PERF136_HELPER_PAGE " + json.dumps(dict(total=first.get("total"), rows=len(first.get("messages", [])))), flush=True)
            command("session.history", dict(version=2, edge="start"), "long")
            command("session.history", dict(version=2, position=2500), "long")
        command("session.close", session="long")
    finally:
        peer.close(wait=15)
    cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    print("PERF136_HELPER_USAGE " + json.dumps(dict(userSeconds=cpu.ru_utime-cpu0.ru_utime,
        systemSeconds=cpu.ru_stime-cpu0.ru_stime, peakRSSMiB=cpu.ru_maxrss/1048576)), flush=True)
    if args.cold:
        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
