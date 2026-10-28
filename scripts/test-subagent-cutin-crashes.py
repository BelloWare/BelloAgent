#!/usr/bin/env python3
"""Fault hooks live only in a generated source copy under PI_BUILD_ROOT."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
POINTS = [f'{name}-{edge}' for name in ('preparation','owner-commit','recipient-commit','prefix','call-result','delivery-prepare','delivery-row','delivery-ack','delivery-mirror','continuation-admit','continuation-dispatch','drain-cost') for edge in ('before','synced')]
POINTS += [f'{who}-promotion-{edge}' for who in ('owner','recipient') for edge in ('copy','renamed')]
POINTS += ['draining']
HOOK = r'''
import Foundation
import Darwin
enum CutinFixtureBarrier {
    static let lock = NSLock()
    static var attempts: Set<String> = []
    static func hit(_ point: String) {
        guard ProcessInfo.processInfo.environment["PI_CUTIN_CRASH_POINT"] == point,
              let file = ProcessInfo.processInfo.environment["PI_CUTIN_BARRIER_FILE"] else { return }
        try! Data(point.utf8).write(to:URL(fileURLWithPath:file),options:.atomic)
        raise(SIGSTOP)
    }
    static func record(_ row: JSON, url: URL, edge: String, observe: (String) -> Void = { hit($0) }) {
        let owner = url.lastPathComponent == "parent.jsonl", kind = row["customType"].text, data = row["data"], message = row["message"]
        if kind == JournalRecordKind.agentCutPrepared { observe("preparation-" + edge) }
        if kind == JournalRecordKind.agentCutCommitted {
            lock.lock(); attempts.insert(data["attemptId"].text!); lock.unlock()
            observe((owner ? "owner-commit-" : "recipient-commit-") + edge)
        }
        if !message["nativeMailboxCut"].isNull { observe("prefix-" + edge) }
        if !message["nativeAgentCallCancellation"].isNull { observe("call-result-" + edge) }
        if message["nativeAgentDelivery"]["events"].list.contains(where:{ $0["type"].text == "MESSAGE" }) { observe("delivery-row-" + edge) }
        if kind == JournalRecordKind.agentDelivery, data["eventIDs"].list.count == 1,
           data["payload"].text?.contains("MAIL-1") == true {
            observe((owner ? data["committed"].flag == true ? "delivery-ack-" : "delivery-prepare-" : "delivery-mirror-") + edge)
        }
        if kind == JournalRecordKind.budgetAttempt, data["scope"]["agentDeliveryIDs"].list.count > 1 {
            observe((data["state"].text == "admitted" ? "continuation-admit-" : "continuation-dispatch-") + edge)
        }
        lock.lock(); let draining = attempts.contains(data["attemptId"].text ?? ""); lock.unlock()
        if owner, kind == JournalRecordKind.cost, draining { observe("drain-cost-" + edge) }
    }
    static func fail(_ row: JSON, url: URL, edge: String) throws {
        var failed = false
        record(row,url:url,edge:edge) { point in
            if ProcessInfo.processInfo.environment["PI_CUTIN_FAILURE"] == point,
               let file = ProcessInfo.processInfo.environment["PI_CUTIN_BARRIER_FILE"] {
                try! Data(point.utf8).write(to:URL(fileURLWithPath:file),options:.atomic); failed = true
            }
        }
        if failed { throw AgentError("fixture_write_failure","Generated cut-in journal failure") }
    }
}
'''

def prepare():
    source = BUILD/'cutin-crash-source'; source.mkdir(exist_ok=True)
    shutil.copy2(ROOT/'packages/swift-host/Package.swift',source)
    shutil.copytree(ROOT/'packages/swift-host/Sources',source/'Sources',dirs_exist_ok=True)
    (source/'Tests/PiAgentCoreTests').mkdir(parents=True,exist_ok=True)
    (source/'Tests/PiAgentCoreTests/Placeholder.swift').write_text('import XCTest\n')
    core = source/'Sources/PiAgentCore'; (core/'CutinFixtureBarrier.swift').write_text(HOOK)
    p = core/'SessionJournal.swift'; text = p.read_text()
    text = text.replace('    private var unsynced = false','    private var unsynced = false\n    private var fixturePending: [JSON] = []')
    text = text.replace('        try beforeAppend(v)','        CutinFixtureBarrier.record(v,url:url,edge:"before")\n        try CutinFixtureBarrier.fail(v,url:url,edge:"write")\n        try beforeAppend(v)')
    text = text.replace('        lastAppend=(bytes, data.count - 1); lastAppendLine=data.dropLast()','        lastAppend=(bytes, data.count - 1); lastAppendLine=data.dropLast()\n        fixturePending.append(v)')
    text = text.replace('        lastAppend=(bytes, line.count); lastAppendLine=line','        lastAppend=(bytes, line.count); lastAppendLine=line\n        fixturePending.append(try JSON.parse(line))')
    text = text.replace('        unsynced=false; synchronizations += 1','        unsynced=false; synchronizations += 1\n        let pending = fixturePending; fixturePending.removeAll()\n        for row in pending { CutinFixtureBarrier.record(row,url:url,edge:"synced") }')
    text = text.replace('do { try beforeSynchronize(); try handle.synchronize() }','do { for row in fixturePending { try CutinFixtureBarrier.fail(row,url:url,edge:"sync") }; try beforeSynchronize(); try handle.synchronize() }')
    text = text.replace('        try copy.synchronize()','        try copy.synchronize()\n        if marker == JournalRecordKind.cutinMarker { CutinFixtureBarrier.hit((managedChild ? "recipient" : "owner") + "-promotion-copy") }')
    text = text.replace('            try handle.close(); handle = try FileHandle(forWritingTo:url); try handle.seekToEnd()','            if marker == JournalRecordKind.cutinMarker { CutinFixtureBarrier.hit((managedChild ? "recipient" : "owner") + "-promotion-renamed") }\n            try handle.close(); handle = try FileHandle(forWritingTo:url); try handle.seekToEnd()')
    p.write_text(text)
    p = core/'Providers.swift'; text = p.read_text().replace('delivery.resolve(.success(committed))','delivery.resolve(.success(committed))\n                                CutinFixtureBarrier.hit("draining")'); p.write_text(text)
    return source

def build():
    source = prepare()
    with (BUILD/'logs/cutin-crash-build.log').open('w') as log:
        subprocess.run(['swift','build','--package-path',str(source),'--scratch-path',str(BUILD/'cutin-crash-build'),'-j','4','--product','pi-native-host'],stdout=log,stderr=subprocess.STDOUT,check=True)
    return BUILD/'cutin-crash-build/debug/pi-native-host'

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('recovery'); parser.add_argument('--skip-build',action='store_true'); parser.add_argument('--points',nargs='+',choices=POINTS)
    args = parser.parse_args()
    binary = BUILD/'cutin-crash-build/debug/pi-native-host' if args.skip_build else build()
    spec = importlib.util.spec_from_file_location('cutin',ROOT/'scripts/test-subagent-cutin.py'); cutin = importlib.util.module_from_spec(spec); spec.loader.exec_module(cutin)
    for point in args.points or POINTS: cutin.run(str(binary),'terminal_race' if point.startswith('drain-cost') else 'reasoning',crash_point=point,recovery=args.recovery)
