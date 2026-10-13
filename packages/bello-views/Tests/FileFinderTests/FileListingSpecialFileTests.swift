import XCTest
@testable import FileFinder

final class FileListingSpecialFileTests: XCTestCase {
    @MainActor func testAFIFOIgnoreFileIsSkippedWithoutWaitingForAWriter() async throws {
        let root = scratchRoot("finder-fifo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".gitignore").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer {
            let writer = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { close(writer) }
        }
        var rejected = false
        let task = Task {
            rejected = await Task.detached { FileListing.contents(of: path, limit: 1_024, following: false) == .missing }.value
        }
        defer { task.cancel() }
        try await eventually("skip the FIFO ignore file", timeout: .seconds(2)) { rejected }
    }
}
