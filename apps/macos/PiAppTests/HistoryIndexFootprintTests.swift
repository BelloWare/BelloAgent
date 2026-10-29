import XCTest
import Darwin
@testable import PiApp

/// A cold index build's memory stays flat in the journal's size: neither the
/// chunks it reads nor tables of every record accumulate while it runs.
final class HistoryIndexFootprintTests: XCTestCase {
    /// The process's physical footprint now (`proc_pid_rusage`).
    private static func footprint() -> UInt64 {
        var value = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
        return status == 0 ? value.ri_phys_footprint : 0
    }
    /// Samples the footprint on its own thread until stopped: the highest seen.
    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0, running = true
        func start() {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let now = HistoryIndexFootprintTests.footprint()
                    lock.withLock { peak = max(peak, now) }
                    usleep(2_000)
                }
            }
            thread.start()
        }
        func stop() -> UInt64 { lock.withLock { running = false; return peak } }
    }
    /// How far the footprint rose above where it started while `body` ran.
    private func growth(_ body: () async throws -> Void) async throws -> UInt64 {
        let start = Self.footprint(), sampler = PeakSampler()
        sampler.start()
        try await body()
        let peak = max(sampler.stop(), Self.footprint())
        return peak > start ? peak - start : 0
    }
    /// A generated native journal of user/assistant turns with real-length
    /// (UUID) ids, `payload` bytes of reply text each, and a compaction every
    /// 200 rows as a chat's context is compacted.
    private func journal(rows: Int, payload: Int) throws -> (path: String, bytes: Int, directory: URL) {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("history-footprint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chat.jsonl")
        var data = Data(#"{"id":"footprint","timestamp":"t","type":"session","version":3}"#.utf8) + Data([10])
        data += Data(#"{"customType":"pi-app.native.v1","data":{"version":1},"id":"native","parentId":null,"timestamp":"t","type":"custom"}"#.utf8) + Data([10])
        let text = String(repeating: "Generated reply text for the footprint check. ", count: max(1, payload / 46)).prefix(payload)
        var parent = "native", context: [String] = []
        for row in 0..<rows {
            let id = UUID().uuidString
            if row > 0, row % 200 == 0 {
                let kept = context.suffix(2).map { "\"\($0)\"" }.joined(separator: ",")
                data += Data(#"{"id":"\#(id)","nativeKeptIDs":[\#(kept)],"parentId":"\#(parent)","summary":"S","timestamp":"t","tokensBefore":1,"type":"compaction"}"#.utf8) + Data([10])
                context = Array(context.suffix(2)) + [id]
            } else {
                let role = row % 2 == 0 ? "user" : "assistant"
                data += Data(#"{"id":"\#(id)","message":{"content":[{"text":"\#(role == "user" ? "Question" : text)","type":"text"}],"role":"\#(role)"},"parentId":"\#(parent)","timestamp":"t","type":"message"}"#.utf8) + Data([10])
                context.append(id)
            }
            parent = id
        }
        try data.write(to: url)
        return (url.path, data.count, root)
    }

    func testColdIndexFootprintDoesNotHoldTheJournalItReads() async throws {
        let journal = try journal(rows: 3_000, payload: 64 * 1024)
        XCTAssertGreaterThan(journal.bytes, 90 << 20)
        let reader = HistoryReader(indexDirectory: journal.directory)
        let rose = try await growth { _ = try await reader.window(path: journal.path, start: true) }
        print("HISTFOOTPRINT large bytes=\(journal.bytes) growth=\(rose)")
        // The page itself holds a few megabytes of decoded rows.
        XCTAssertLessThan(rose, UInt64(journal.bytes / 3), "Indexing must not keep the chunks it read: \(rose) bytes for a \(journal.bytes)-byte journal")
        await reader.releaseIndexes()
    }

    func testColdIndexFootprintDoesNotGrowWithTheRecordCount() async throws {
        let journal = try journal(rows: 160_000, payload: 0)
        let reader = HistoryReader(indexDirectory: journal.directory)
        let rose = try await growth { _ = try await reader.window(path: journal.path, start: true) }
        print("HISTFOOTPRINT records bytes=\(journal.bytes) growth=\(rose)")
        // A build's page cache is bounded (32 MiB), whatever the journal's size.
        XCTAssertLessThan(rose, 64 << 20, "Indexing must not keep a table of every record in memory: \(rose) bytes for 160,000 records")
        await reader.releaseIndexes()
    }
}
