import XCTest
@testable import PiApp

final class HostInboxTests: XCTestCase {
    @MainActor func testTwentyLegalSnapshotRepliesSurviveABusyMainActor() async {
        var delivered: [TransportEvent] = []
        let inbox = HostInbox { delivered += $0 }
        // Enqueue while occupying the main actor, as rendering can do. These
        // are ordinary legal snapshot sizes, well below the 1 MiB frame limit.
        for index in 0..<20 {
            inbox.enqueue(.frame(["kind": .string("reply"), "commandId": .string("command-\(index)"),
                                  "result": .object(["text": .string(String(repeating: "x", count: 150_000))])]))
            for sequence in 0..<3 {
                inbox.enqueue(.frame(["kind": .string("event"), "type": .string("session.changed"),
                                      "sessionId": .string("session-\(index)"), "seq": .number(Double(sequence))]))
            }
        }
        for _ in 0..<100 where delivered.isEmpty { await Task.yield() }
        let frames = delivered.compactMap { event -> [String: WireValue]? in
            if case .frame(let frame) = event { return frame }
            XCTFail("A healthy 20-chat snapshot burst must not fail the host"); return nil
        }
        XCTAssertEqual(frames.filter { $0["kind"]?.string == "reply" }.count, 20)
        let displays = frames.filter { $0["type"]?.string == "session.changed" }
        XCTAssertEqual(displays.count, 20)
        XCTAssertTrue(displays.allSatisfy { $0["seq"]?.number == 2 })
    }

    @MainActor func testControlOverflowStillFailsExplicitlyAtTheFrameBound() async {
        var delivered: [TransportEvent] = []
        let inbox = HostInbox { delivered += $0 }
        for index in 0..<65 { inbox.enqueue(.frame(["kind": .string("reply"), "commandId": .string("\(index)")])) }
        for _ in 0..<100 where delivered.isEmpty { await Task.yield() }
        XCTAssertTrue(delivered.contains { if case .failed = $0 { return true }; return false })
    }
}
