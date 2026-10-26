import XCTest
@testable import PiApp

final class EditHistoryReaderTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var started = false, ended = false
        var entered: Bool { lock.withLock { started } }
        var released: Bool { lock.withLock { ended } }
        func wait() {
            lock.withLock { started = true }
            _ = semaphore.wait(timeout: .now() + 5)
            lock.withLock { ended = true }
        }
        func release() { semaphore.signal() }
    }

    func testAnEditIndexScanDoesNotHoldAnotherChatsHistoryRead() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("edit-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat.jsonl")
        try Data("{\"type\":\"session\",\"id\":\"chat\",\"version\":3}\n{\"type\":\"message\",\"id\":\"u\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"question\"}}\n".utf8).write(to: path)
        let other = root.appendingPathComponent("other.jsonl")
        try FileManager.default.copyItem(at: path, to: other)
        let reader = HistoryReader(indexDirectory: root), gate = Gate()
        await reader.observeEditRead { gate.wait() }
        let edit = Task { try await reader.editTarget(path: path.path, id: "u") }
        defer { gate.release() }
        for _ in 0..<1000 where !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.entered)
        let page = try await reader.read(path: other.path)
        XCTAssertFalse(gate.released, "Another chat must read while the edit scan is still held")
        XCTAssertEqual(page.messages.first?.text, "question")
        gate.release()
        let target = try await edit.value
        XCTAssertEqual(target["text"]?.string, "question")
        await reader.releaseIndexes()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(HistoryOffsetIndex.filePrefix) }, "Quit releases the edit workers' private offset indexes too")
    }
}
