import XCTest
@testable import PiApp

final class HostTransportTests: XCTestCase {
    func testCaptureAcknowledgmentDoesNotConsumeAnOrdinaryCommandSlot() async throws {
        let started = expectation(description: "Child started"), echoed = expectation(description: "Control plus 32 commands")
        echoed.expectedFulfillmentCount = 33
        let exited = expectation(description: "Child exited")
        let transport = HostTransport { event in
            switch event {
            case .frame(let frame):
                if frame["phase"]?.string == "started" { started.fulfill() }
                else { echoed.fulfill() }
            case .exited: exited.fulfill()
            case .failed(let message): XCTFail(message)
            }
        }
        transport.start(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "printf '{\"phase\":\"started\"}\\n'; /bin/sleep 0.3; exec /bin/cat"],
                        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ["PATH": "/usr/bin:/bin"])
        defer { transport.stop() }
        await fulfillment(of: [started], timeout: 2)
        // Keep the exempt control frame pending until the fixture starts
        // reading, then fill every normal slot while it is still in flight.
        transport.send(["kind": .string("capture.ack"), "padding": .string(String(repeating: "x", count: 900_000))])
        for index in 0..<32 { transport.send(["method": .string("session.snapshot"), "number": .number(Double(index))]) }
        await fulfillment(of: [echoed], timeout: 5)
        transport.stop(); await fulfillment(of: [exited], timeout: 2)
    }

    func testBackpressuredInputStillDeliversOutputAndStopsAnUnresponsiveChild() async throws {
        let started = expectation(description: "Child started"), replied = expectation(description: "Output while stdin is full")
        let exited = expectation(description: "Forced shutdown completed")
        let transport = HostTransport { event in
            switch event {
            case .frame(let frame):
                if frame["phase"]?.string == "started" { started.fulfill() }
                if frame["phase"]?.string == "reply" { replied.fulfill() }
            case .exited: exited.fulfill()
            case .failed: break
            }
        }
        // The fixture never reads stdin, ignores TERM, and has its own finite
        // lifetime even if shutdown regresses. No gateway or app state is used.
        transport.start(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "trap '' TERM; printf '{\"phase\":\"started\"}\\n'; /bin/sleep 0.2; printf '{\"phase\":\"reply\"}\\n'; exec /bin/sleep 8"],
                        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ["PATH": "/usr/bin:/bin"])
        defer { transport.stop() }
        await fulfillment(of: [started], timeout: 2)
        transport.send(["payload": .string(String(repeating: "x", count: 900_000))])
        await fulfillment(of: [replied], timeout: 2)
        transport.stop()
        await fulfillment(of: [exited], timeout: 6.5)
    }

    func testFailedSpawnProducesAnExitSoTheSupervisorCanReleaseOwnership() async {
        let failed = expectation(description: "Spawn failure"), exited = expectation(description: "Failed connection ended")
        failed.assertForOverFulfill = true; exited.assertForOverFulfill = true
        let transport = HostTransport { event in
            if case .failed = event { failed.fulfill() }
            if case .exited = event { exited.fulfill() }
        }
        transport.start(executable: URL(fileURLWithPath: "/nonexistent-bello-host-" + UUID().uuidString),
                        arguments: [], cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:])
        transport.send(["v": .number(1), "kind": .string("hello")])
        await fulfillment(of: [failed, exited], timeout: 2, enforceOrder: true)
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// A helper that dies in the middle of a frame, and one that speaks
    /// nonsense, must both end as an explicit interruption rather than a hang
    /// or a partially applied frame.
    func testTruncatedAndMalformedOutputEndTheConnectionExplicitly() async throws {
        for (name, script) in [("EOF mid-frame", "printf '{\"kind\":\"rep'"), ("malformed frame", "printf 'not json at all\\n'; /bin/sleep 5")] {
            let failed = expectation(description: "\(name) reported"), exited = expectation(description: "\(name) ended")
            failed.assertForOverFulfill = false
            let transport = HostTransport { event in
                switch event {
                case .failed: failed.fulfill()
                case .exited: exited.fulfill()
                case .frame(let frame): XCTFail("A \(name) must not be delivered: \(frame)")
                }
            }
            transport.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ["PATH": "/usr/bin:/bin"])
            await fulfillment(of: [failed, exited], timeout: 8)
            transport.stop()
        }
    }

    /// A helper that floods stdout must be drained without losing frames and
    /// without the reader thread waiting on the parsing queue.
    func testAFloodingHelperIsDrainedWithoutLosingFrames() async throws {
        let received = expectation(description: "Every flooded frame arrived")
        received.expectedFulfillmentCount = 2000
        received.assertForOverFulfill = false
        let exited = expectation(description: "Flooding child exited")
        let transport = HostTransport { event in
            switch event {
            case .frame(let frame): if frame["n"]?.number != nil { received.fulfill() }
            case .exited: exited.fulfill()
            case .failed(let message): XCTFail(message)
            }
        }
        transport.start(executable: URL(fileURLWithPath: "/usr/bin/awk"),
                        arguments: ["BEGIN { for (i = 0; i < 2000; i++) printf \"{\\\"n\\\":%d,\\\"pad\\\":\\\"%s\\\"}\\n\", i, sprintf(\"%400s\", \"\") }"],
                        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ["PATH": "/usr/bin:/bin"])
        await fulfillment(of: [received], timeout: 20)
        transport.stop()
        await fulfillment(of: [exited], timeout: 8)
    }

    func testPartialNonblockingWritesKeepLargeFramesOrdered() async throws {
        let received = expectation(description: "Both echoed frames arrived"); received.expectedFulfillmentCount = 2
        let exited = expectation(description: "Echo process exited")
        let first = String(repeating: "🌍", count: 150_000), second = String(repeating: "b", count: 200_000)
        let order = ReceivedFrameOrder()
        let transport = HostTransport { event in
            switch event {
            case .frame(let frame):
                let number = frame["number"]?.number
                XCTAssertEqual(frame["payload"]?.string, number == 1 ? first : second)
                XCTAssertTrue(number == 1 || number == 2)
                if let number { order.append(number) }
                received.fulfill()
            case .exited: exited.fulfill()
            case .failed(let message): XCTFail(message)
            }
        }
        transport.start(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ["PATH": "/usr/bin:/bin"])
        transport.send(["number": .number(1), "payload": .string(first)])
        transport.send(["number": .number(2), "payload": .string(second)])
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(order.values, [1, 2], "Partial writes cannot interleave or reorder command frames")
        transport.stop()
        await fulfillment(of: [exited], timeout: 2)
    }
}

private final class ReceivedFrameOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; received.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return received }
}
