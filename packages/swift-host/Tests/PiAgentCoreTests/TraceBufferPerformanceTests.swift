import XCTest
@testable import PiAgentCore

private actor TraceBufferSink {
    var bodies: [String: Data] = [:]
    var packets = 0
    func accept(_ packet: JSON) -> Bool {
        guard packet["type"].text == "bytes", packet["body"].text == "response",
              let id = packet["attemptId"].text, let bytes = Data(base64Encoded: packet["bytes"].text ?? "") else { return true }
        guard packet["offset"].int == (bodies[id]?.count ?? 0) else { return false }
        bodies[id, default: Data()].append(bytes); packets += 1
        return true
    }
    func body(_ id: String) -> Data { bodies[id] ?? Data() }
}

final class TraceBufferPerformanceTests: XCTestCase {
    func testGrowingBuffersPreserveEveryByteEventAndInspectorSnapshot() async throws {
        let profile = try fixtureProfile()
        let chunk = Data((0..<32_768).map { UInt8(65 + $0 % 26) })
        for mode in ["memory", "persist"] {
            for megabytes in [1, 2, 4, 8] {
                var samples: [Double] = []
                for _ in 0..<3 {
                    let sink = TraceBufferSink(), traces = TraceStore(sink: { await sink.accept($0) })
                    _ = try await traces.command("debug.mode", session: "buffer", params: ["mode": JSON(mode)])
                    let id = await traces.begin(session: "buffer", turn: "turn", profile: profile, purpose: "turn", body: Data(), headers: [:])
                    let chunks = megabytes * 1_048_576 / chunk.count
                    await traces.append(id, data: chunk)
                    let snapshot = try await traces.command("debug.body", session: "buffer", params: ["attemptId": JSON(id), "body": "response"])
                    let started = ProcessInfo.processInfo.systemUptime
                    for index in 1..<chunks {
                        await traces.append(id, data: chunk)
                        await traces.event(id, SSEEvent(event: "delta", data: "", start: index * chunk.count, end: (index + 1) * chunk.count))
                    }
                    samples.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    await traces.transport(id, observation: ["transportOutcome": "eof", "responseObservedBytes": JSON(chunks * chunk.count)])
                    await traces.finish(id, outcome: "completed", modelOutcome: "completed")
                    let expected = Data(repeating: 0, count: 0) + (0..<chunks).reduce(into: Data()) { data, _ in data.append(chunk) }
                    let detail = try await traces.command("debug.attempt", session: "buffer", params: ["attemptId": JSON(id)])
                    XCTAssertEqual(detail["responseHash"]["sha256"].text, sha256(expected))
                    XCTAssertEqual(detail["rawEventIndexCount"].int, chunks - 1)
                    XCTAssertEqual(Data(base64Encoded: snapshot["bytes"].text ?? ""), chunk, "A retained inspector snapshot is immutable")
                    if mode == "persist" { let recorded = await sink.body(id); XCTAssertEqual(recorded, expected) }
                }
                let sorted = samples.sorted()
                print("PERF trace-buffer mode=\(mode) MiB=\(megabytes) samples=3 medianMs=\(sorted[1]) maxMs=\(sorted[2])")
            }
        }
    }

    func testTwentyAttemptsTrimWithoutLosingDurableBytesOrLeakingAccounting() async throws {
        let sink = TraceBufferSink(), traces = TraceStore(memoryLimit: 1_048_576, sink: { await sink.accept($0) })
        let profile = try fixtureProfile(), chunk = Data(repeating: 0x61, count: 32_768)
        var ids: [String] = []
        for index in 0..<20 {
            let session = "s\(index)"
            _ = try await traces.command("debug.mode", session: session, params: ["mode": "persist"])
            ids.append(await traces.begin(session: session, turn: "t", profile: profile, purpose: "turn", body: Data(), headers: [:]))
        }
        for _ in 0..<8 { for id in ids { await traces.append(id, data: chunk) } }
        for (index, id) in ids.enumerated() {
            await traces.finish(id, outcome: "cancelled", modelOutcome: "interrupted")
            let data = await sink.body(id)
            XCTAssertEqual(data, Data(repeating: 0x61, count: 8 * chunk.count))
            let list = try await traces.command("debug.list", session: "s\(index)", params: [:])
            XCTAssertLessThanOrEqual(list["workspaceRetainedBytes"].int ?? .max, 1_048_576)
            _ = try await traces.command("debug.clear", session: "s\(index)", params: [:])
        }
        let empty = try await traces.command("debug.list", session: "s0", params: [:])
        XCTAssertEqual(empty["workspaceRetainedBytes"].int, 0)
    }
}
