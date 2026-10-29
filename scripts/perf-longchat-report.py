#!/usr/bin/env python3
"""Collect all PERF136 evidence and quiet-window decisions without rounding it.

Usage: perf-longchat-report.py <build-root> <output.json>
Raw frame intervals remain under build-root/perf/<trial>/; accepted unprofiled
traces are also embedded here. The output retains every summary, phase trace,
helper measurement and load sample, including
failed or load-invalid trials so they cannot silently become positive evidence.
"""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path


def sample_summary(contents):
    """Inclusive stack observations, deduplicating recursive category frames.

    sample can split one thread across several queue roots. Recognize its
    numeric ID so both main-thread roots contribute to the same denominator.
    Categories overlap; worker observations are not elapsed CPU milliseconds.
    """
    graph = contents.partition("Call graph:\n")[2].partition("Total number in stack")[0]
    nodes = []
    main_ids = set()
    for line in graph.splitlines():
        match = re.match(r"^([ +!|:]*)\b(\d+) (.+)$", line)
        if not match:
            continue
        indent, count, name = len(match[1]), int(match[2]), match[3]
        nodes.append((indent, count, name))
        if name.startswith("Thread_") and ("com.apple.main-thread" in name or ": Main Thread" in name):
            main_ids.add(name.split()[0].rstrip(":"))
    patterns = {
        "idleWait": r"mach_msg2_trap|__psynch_cvwait|__workq_kernreturn|semaphore_wait_trap",
        "plans": r"subagentRecords|scanPlans",
        "indexBuild": r"HistoryReader.buildIndex",
        "pageDecode": r"HistoryReader.decodePage",
        "helperReplay": r"wholeJournalReplay|JournalReplayConsumer.consume",
        "helperHistory": r"AgentSession.historyWindow",
        "storedRow": r"AgentSession.storedRow",
        "escapedString": r"JSONByteParser.escapedString",
        "jsonDecode": r"JSONDecoder.decode<",
        "jsonEncode": r"JSONEncoder.encode<",
        "searchCache": r"SearchCache.store",
        "sqliteStep": r"sqlite3_step",
        "sqlitePrepare": r"sqlite3.*[Pp]repare",
        "rowHost": r"TranscriptRowContainer.host|TranscriptRowRenderer.content|TranscriptNativeMessageRow.apply",
        "rowMeasure": r"TranscriptRowContainer.measure",
        "layoutRows": r"TranscriptNativeDocument.layoutRows",
        "placeRows": r"TranscriptNativeDocument.placeRows",
        "idleScheduler": r"TranscriptIdleScheduler.runReady",
        "pagePublish": r"TranscriptPage.present|TranscriptPage.receive",
        "historyJump": r"jumpToHistoryPosition",
        "nativeUpdate": r"TranscriptNativeDocument.update\(snapshot:",
        "streamAppend": r"NativeMarkdownContainer.appendStreaming",
        "markdownParse": r"StreamingMarkdownState|TranscriptMarkdown.parseLocated",
        "markdown": r"Markdown.*(?:layout|measure)|layout.*Markdown",
        "textKit": r"NSLayoutManager|NSTypesetter|NSATSTypesetter",
        "accounting": r"withAccounting|gatewayAccounting",
        "positions": r"HistoryPositions|TranscriptScrollRoom",
    }
    result = dict(mainObservations=0, allThreadObservations=0,
                  categories={key: dict(main=0, all=0) for key in patterns})
    stack = []
    is_main = False
    for indent, count, name in nodes:
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if name.startswith("Thread_"):
            is_main = name.split()[0].rstrip(":") in main_ids
            result["allThreadObservations"] += count
            if is_main:
                result["mainObservations"] += count
        matched = {key for key, pattern in patterns.items() if re.search(pattern, name)}
        ancestors = set().union(*(entry[1] for entry in stack)) if stack else set()
        for key in matched - ancestors:
            result["categories"][key]["all"] += count
            if is_main:
                result["categories"][key]["main"] += count
        stack.append((indent, matched))
    return result


def distribution(values):
    values = sorted(values)
    if not values:
        return dict(count=0)
    return dict(count=len(values), p50=values[int((len(values)-1)*.5)], p95=values[int((len(values)-1)*.95)],
                max=values[-1], sum=sum(values))


def blank_episodes(raw, ended=None):
    """Observed low-coverage spans, ending at the first nonblank frame.

    A trailing span is censored: the trace never observed coverage return.
    This does not infer what pixels were presented between observations.
    """
    times = raw.get("frameUptimes", [])
    indices = sorted({i for i in raw.get("blankAt", []) if 0 <= i < len(times)})
    groups = []
    for index in indices:
        if groups and index == groups[-1][-1] + 1:
            groups[-1].append(index)
        else:
            groups.append([index])
    result = []
    for group in groups:
        after = group[-1] + 1
        censored = after == len(times)
        end = times[after] if not censored else (ended if ended is not None else times[-1])
        result.append(dict(firstFrame=group[0], blankObservations=len(group),
                           ms=max(0, end - times[group[0]]) * 1000, censored=censored))
    return result


def collect(root):
    trials = []
    for path in sorted((root / "perf").glob("*.json")):
        meta = json.loads(path.read_text())
        if "command" not in meta:
            continue
        trial = dict(metadata=meta, events=[], traces=[], helper=[], checkpoint=[], helperUsage=[], helperPages=[], sqlite=[], legacyMetrics=[], testResults=[])
        log = path.with_suffix(".log")
        for line in log.read_text(errors="replace").splitlines() if log.exists() else []:
            if line.startswith(("ACCOUNTING_SCALE ", "REFERENCE_SCALE ", "DIRECT_OWNER_SCALE ", "LONGSCROLL ")):
                trial["legacyMetrics"].append(line)
            if "error: -[PiAppTests." in line or re.search(r"Test Case .* (?:passed|failed) \(|Executed \d+ tests?", line):
                trial["testResults"].append(line.strip())
            for prefix, key in [("PERF136 ", "events"), ("PERF136_TRACE ", "traces"),
                                ("PERF136_HELPER ", "helper"), ("PERF136_CHECKPOINT ", "checkpoint"),
                                ("PERF136_HELPER_PAGE ", "helperPages"),
                                ("PERF136_SQLITE ", "sqlite"),
                                ("PERF136_HELPER_USAGE ", "helperUsage")]:
                if line.startswith(prefix):
                    try:
                        trial[key].append(json.loads(line[len(prefix):]))
                    except ValueError:
                        trial.setdefault("malformed", []).append(line)
                    break
        trial["timingEvidence"] = bool(meta.get("validLoad") and meta.get("exit") == 0 and not meta.get("calibrationOnly") and
            not meta["label"].startswith(("probe-", "smoke-")) and
            all(event.get("measurementVersion", 0) >= 2 for event in trial["events"]))
        trial["unprofiledTimingEvidence"] = trial["timingEvidence"] and not meta.get("profile", False)
        trial["activeInput"] = {}
        trial["blankEpisodes"] = {}
        trial["frameTraces"] = {}
        for raw_path in path.with_suffix("").glob("*.json"):
            try:
                raw = json.loads(raw_path.read_text())
            except ValueError:
                continue  # A live trial may still be writing this phase.
            if trial["unprofiledTimingEvidence"]:
                trial["frameTraces"][raw_path.stem] = raw
            ended = next((event["uptime"] for event in trial["events"] if event["event"] == raw_path.stem), None)
            episodes = blank_episodes(raw, ended)
            trial["blankEpisodes"][raw_path.stem] = dict(episodes=episodes,
                completedMS=distribution([x["ms"] for x in episodes if not x["censored"]]),
                observedMaxMS=max((x["ms"] for x in episodes), default=0))
            points = raw.get("inputPoints", [])
            active = {i for i, value in enumerate(points) if value != 0}
            if not active:
                continue
            intervals = [value for i, value in enumerate(raw["intervalMS"]) if i in active]
            trial["activeInput"][raw_path.stem] = dict(observations=len(active),
                blank=len(active.intersection(raw.get("blankAt", []))), intervalsMS=distribution(intervals),
                thresholds={str(limit): sum(v > limit for v in intervals) for limit in [16.7, 33, 50, 100]})
        trial["wheelLoading"] = {}
        switch = next((x["uptime"] for x in trial["events"] if x["event"] == "switch.cached"), None)
        for name in ["wheel.up", "wheel.down"]:
            end = next((x["uptime"] for x in trial["events"] if x["event"] == name), None)
            if switch is None or end is None:
                continue
            spans = [x for x in trial["traces"] if switch <= float(x["start"]) <= end]
            requests = [x for x in spans if x["event"] == "source.window"]
            windows = [x for x in trial["events"] if x["event"] == "window.change" and switch <= x["uptime"] <= end]
            trial["wheelLoading"][name] = dict(requests=len(requests),
                cancelled=sum(x.get("cancelled") == "true" for x in requests),
                returned=sum(int(x.get("returnedRows", 0)) > 0 for x in requests),
                completedMS=distribution([float(x["ms"]) for x in requests if int(x.get("returnedRows", 0)) > 0]),
                decodeReadBytes=sum(int(x.get("readBytes", 0)) for x in spans if x["event"] == "journal.pageDecode"),
                indexMS=distribution([float(x["ms"]) for x in spans if x["event"] == "journal.index"]),
                publications=len(windows), added=sum(x["added"] for x in windows),
                evicted=sum(x["evicted"] for x in windows), readmitted=sum(x["readmitted"] for x in windows))
            switch = end
        trial["profiles"] = {}
        for profile in path.parent.glob(path.stem + "-*.sample.txt"):
            data = profile.read_bytes()
            trial["profiles"][profile.name] = dict(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data),
                summary=sample_summary(data.decode(errors="replace")), text=data.decode(errors="replace"))
        trials.append(trial)
    fixtures = {p.parent.name: json.loads(p.read_text()) for p in sorted((root / "fixtures").glob("*/manifest.json"))
                if not p.parent.name.startswith("smoke")}
    environment = root / "perf/environment.json"
    return dict(version=2, units="milliseconds, seconds, MiB as named; frame thresholds are strict >",
                environment=json.loads(environment.read_text()) if environment.exists() else {}, fixtures=fixtures, trials=trials)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = json.dumps(collect(args.build_root), indent=2, sort_keys=True) + "\n"
    if args.output.suffix == ".gz":
        args.output.write_bytes(gzip.compress(result.encode(), mtime=0))
    else:
        args.output.write_text(result)
