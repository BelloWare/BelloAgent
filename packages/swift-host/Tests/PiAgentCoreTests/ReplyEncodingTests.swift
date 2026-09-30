import Foundation
import XCTest
@testable import PiAgentCore

/// A command's reply is encoded once (`NativeHostService.boundedReply`): the
/// bytes checked against the frame limit are the bytes written, and a retry
/// writes them again. They are the bytes the helper always wrote.
final class ReplyEncodingTests: XCTestCase {
    private func encoded(_ output: HostOutput, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard case .encoded(let bytes) = output else { XCTFail("The reply was left for the writer to encode", file: file, line: line); return Data() }
        return bytes
    }
    private func frame(_ id: String, _ result: Result<JSON, AgentError>) throws -> Data {
        try NativeHostService.replyFrame(epoch: "E", id, result).data()
    }

    /// A literal frame, not the encoder's own output, so a change of encoder
    /// shows: sorted keys, slashes as they are, Unicode as UTF-8, escapes for
    /// quotes, backslashes and control characters, and whole numbers without
    /// a fraction.
    func testAReplyIsWrittenAsItAlwaysWas() {
        let value: JSON = ["path": "a/b", "text": JSON("🌍 \"q\" \\ \n\u{0001}"), "n": 2.5, "count": 3, "negative": -1, "flag": true, "none": .null]
        let written = encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(value), transfer: nil))
        XCTAssertEqual(String(decoding: written, as: UTF8.self),
                       #"{"commandId":"c","hostEpoch":"E","kind":"reply","ok":true,"result":{"count":3,"flag":true,"n":2.5,"negative":-1,"none":null,"path":"a/b","text":"🌍 \"q\" \\ \n\u0001"},"v":1}"#)
    }

    /// Success and failure alike: what is written is the encoding of the
    /// frame, as the writer used to make it.
    func testEveryReplyIsTheEncodingOfItsFrame() throws {
        let failure = AgentError("session_missing", "No such session")
        XCTAssertEqual(encoded(NativeHostService.boundedReply(epoch: "E", "a", .success(["ok": true]), transfer: nil)), try frame("a", .success(["ok": true])))
        XCTAssertEqual(encoded(NativeHostService.boundedReply(epoch: "E", "b", .failure(failure), transfer: nil)), try frame("b", .failure(failure)))
    }

    /// The limit is 1 MiB of frame, before its newline: a reply of exactly
    /// that size is written whole; one byte more becomes the error, or a
    /// display transfer for a reader that takes them.
    func testTheLimitIsOneMebibyteOfFrameBeforeItsNewline() throws {
        let overhead = try frame("c", .success(["text": ""])).count
        let fits: JSON = ["text": JSON(String(repeating: "x", count: HostProtocol.frameBytes - overhead))]
        let exact = encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(fits), transfer: nil))
        XCTAssertEqual(exact.count, HostProtocol.frameBytes)
        XCTAssertEqual(exact, try frame("c", .success(fits)))

        let over: JSON = ["text": JSON(String(repeating: "x", count: HostProtocol.frameBytes - overhead + 1))]
        let refused = encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(over), transfer: nil))
        XCTAssertEqual(refused, try frame("c", .failure(AgentError("reply_limit", "Result exceeds the IPC frame limit; request a smaller range"))))

        var transfers = DisplayResultTransfers(), handed: Data?
        let moved = encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(over), transfer: { data in handed = data; return try transfers.insert(data) }))
        XCTAssertEqual(handed, try over.data(), "the transfer holds the whole result")
        let marker = try JSON.parse(moved)["result"]
        XCTAssertEqual(marker["_displayTransfer"].int, 1)
        XCTAssertEqual(marker["bytes"].int, try over.data().count)
        XCTAssertEqual(moved, try frame("c", .success(marker)))
    }

    /// A number JSON cannot hold does not encode. As before, the reply
    /// becomes an error, with or without display transfers, and the helper
    /// goes on: it is not left for the writer, which would stop the helper.
    func testAReplyThatDoesNotEncodeBecomesAnErrorAsBefore() throws {
        let unencodable: JSON = ["ratio": .number(.infinity)]
        XCTAssertEqual(encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(unencodable), transfer: nil)),
                       try frame("c", .failure(AgentError("reply_limit", "Result exceeds the IPC frame limit; request a smaller range"))))
        var transferred = false
        XCTAssertEqual(encoded(NativeHostService.boundedReply(epoch: "E", "c", .success(unencodable), transfer: { _ in transferred = true; return [:] })),
                       try frame("c", .failure(AgentError("display_failed", "Could not prepare the complete display result"))))
        XCTAssertFalse(transferred, "nothing that did not encode is handed to a transfer")
    }

    /// A mutation's reply is kept for an identical retry of its command, and
    /// the retry is answered with the very bytes first written.
    func testARetriedMutationIsAnsweredWithTheSameBytes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let written = WrittenReplies(), host = NativeHostService(output: { written.add($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1]); let epoch = await host.epoch
        let open: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": "open", "method": "workspace.open",
                          "params": ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)]]
        await host.receive(open)
        let first = try await written.next()
        await host.receive(open)
        let again = try await written.next()
        XCTAssertEqual(again, first)
        XCTAssertEqual(try JSON.parse(first)["commandId"].text, "open")
        await host.shutdown()
    }
}

/// The encoded replies a service writes, in order.
private final class WrittenReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Data] = []
    func add(_ output: HostOutput) {
        guard case .encoded(let bytes) = output else { return }
        lock.lock(); replies.append(bytes); lock.unlock()
    }
    func next(timeout: Double = 10) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let reply = replies.isEmpty ? nil : replies.removeFirst(); lock.unlock()
            if let reply { return reply }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AgentError("timeout", "No reply was written")
    }
}
