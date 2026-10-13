import XCTest
@testable import FileView

final class FileOpeningTests: XCTestCase {
    @MainActor func testAFIFOWithoutAWriterFailsWithoutWaitingForOne() async throws {
        let root = scratchRoot("file-fifo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)
        let document = FileDocument(url: URL(fileURLWithPath: path)), linked = FileDocument(url: link)
        defer {
            document.close(); linked.close()
            // A regressed blocking open must not leave a worker hung after the test.
            let writer = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { close(writer) }
        }
        try await eventually("reject the FIFO without a writer", timeout: .seconds(2)) { document.status != .indexing && linked.status != .indexing }
        XCTAssertEqual(document.status, .failed("Only regular files can be opened."))
        XCTAssertEqual(linked.status, .failed("Only regular files can be opened."))
    }

    @MainActor func testADirectoryIsRejectedAndARegularFileStillOpens() async throws {
        let root = scratchRoot("file-kind")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = FileDocument(url: root)
        defer { directory.close() }
        try await eventually("reject the directory") { directory.status != .indexing }
        XCTAssertEqual(directory.status, .failed("Only regular files can be opened."))
        let path = root.appendingPathComponent("regular.txt")
        try Data("read me\n".utf8).write(to: path)
        let regular = FileDocument(url: path)
        defer { regular.close() }
        try await eventually("read the regular file") { regular.status != .indexing }
        XCTAssertEqual(regular.status, .ready)
        let bytes = try FileBytes(path: path.path)
        XCTAssertEqual(fcntl(bytes.descriptor, F_GETFL) & O_NONBLOCK, 0)
    }
}
