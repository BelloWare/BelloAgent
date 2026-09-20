import XCTest
@testable import PiApp

final class ReportWorkerPerformanceTests: XCTestCase {
    private func fixture() async throws -> (URL, PayloadArchive, CaptureDatabase, DashboardFilter) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report-worker-" + UUID().uuidString)
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_073_741_824, bodyRetention: 86400, metricRetention: 86400)
        let writer = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        try writer.transaction {
            try writer.execute("""
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000)
            INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,model,outcome,wall,updated,metadata,dispatch,ttft_ms,stream_ms,http_ms,request_ms,output_tokens)
            SELECT printf('%08d',i),'session-'||(i%20),'fixture','turn','turn','openai-responses','router','resolved','completed',1990,1990,x'7b7d',1000,i,20,i+20,i+30,100 FROM n
            """)
        }
        return (root, archive, writer, DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001), bucketCount: 2))
    }
    func testHundredThousandRowsPageWithoutAggregateSortsAndExactPercentiles() async throws {
        let (root, archive, writer, filter) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try await archive.dashboardReader()
        let start = ProcessInfo.processInfo.systemUptime
        let summary = try await archive.dashboard(filter)
        let aggregateMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(summary.selectedRequests, 100_000)
        XCTAssertEqual(summary.ttft.samples, 100_000)
        XCTAssertEqual(summary.ttft.p50, 50_000); XCTAssertEqual(summary.ttft.p99, 99_000)
        let pageStart = ProcessInfo.processInfo.systemUptime
        let pages = try await reader.run { engine in
            let before = engine.db.sorts
            let pages = (try engine.requestPage(filter, offset: 128), try engine.requestPage(filter))
            XCTAssertLessThanOrEqual(engine.db.sorts - before, 2, "Each page may sort its rows, but must not repeat six aggregate percentile sorts")
            return pages
        }
        let pageMS = (ProcessInfo.processInfo.systemUptime - pageStart) * 1000
        XCTAssertEqual(pages.0.requests.count, 128); XCTAssertEqual(pages.1.requests.first?.id, summary.requests.first?.id)
        XCTAssertTrue(Set(pages.0.requests.map(\.id)).isDisjoint(with: Set(pages.1.requests.map(\.id))))
        // A paging engine is limited to count + rows, with no window-function
        // medians, time buckets, or grouped cost aggregates in its SQL path.
        let before = writer.preparations
        for _ in 0..<20 { _ = try writer.rows("SELECT id FROM attempts WHERE id=?", [.text("00000001")]) }
        XCTAssertEqual(writer.preparations - before, 1, "Prepared statements are reused without retaining old bindings")
        let check = try writer.rows("PRAGMA wal_checkpoint(PASSIVE)").first
        XCTAssertEqual(check?["busy"]?.number, 0)
        XCTAssertEqual(check?["log"]?.number, check?["checkpointed"]?.number, "No report transaction remains open between pages")
        print("PERF 100k report aggregateMs=\(aggregateMS) twoRequestPagesMs=\(pageMS)")
    }
    func testCancelledReportReleasesReaderWithoutInterruptingCaptureWriter() async throws {
        let (root, archive, writer, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try await archive.dashboardReader()
        let started = expectation(description: "Reader entered expensive SQL")
        let task = Task {
            try await reader.run { engine in
                started.fulfill()
                return try engine.db.rows("SELECT SUM(a.ttft_ms*b.ttft_ms) FROM attempts a,attempts b")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let start = ProcessInfo.processInfo.systemUptime
        // A second connection must write while a report owns its read snapshot.
        try writer.execute("UPDATE attempts SET output_tokens=101 WHERE id='00000001'")
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let count = try await reader.run { try $0.db.rows("SELECT COUNT(*) AS n FROM attempts").first?["n"]?.number }
        XCTAssertEqual(count, 100_000)
        print("PERF report cancellation plus concurrent writerMs=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
    }
    func testStatementCacheClearsBindingsAfterErrorAndBoundsPreparedQueries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prepared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try CaptureDatabase(url: root.appendingPathComponent("test.sqlite"))
        try db.execute("CREATE TABLE values_test(id INTEGER PRIMARY KEY, value TEXT)")
        try db.execute("INSERT INTO values_test VALUES(?,?)", [.integer(1), .text("original")])
        XCTAssertThrowsError(try db.execute("INSERT INTO values_test VALUES(?,?)", [.integer(1), .text("rejected")]))
        try db.execute("INSERT INTO values_test VALUES(?,?)", [.integer(2), .text("second")])
        XCTAssertEqual(try db.rows("SELECT value FROM values_test WHERE id=?", [.integer(2)]).first?["value"]?.string, "second")
        XCTAssertTrue(try db.rows("SELECT value FROM values_test WHERE id=?").isEmpty, "Missing bindings must not retain the previous row id")
        for index in 0..<200 { _ = try db.rows("SELECT \(index) AS n") }
        XCTAssertEqual(try db.rows("SELECT value FROM values_test WHERE id=1").first?["value"]?.string, "original")
    }
    func testConcurrentArchiveCloseDrainsReaderBeforeReopening() async throws {
        let (root, archive, _, filter) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try await archive.dashboardReader()
        let started = expectation(description: "Reader entered SQL before shutdown")
        let query = Task {
            try await reader.run { engine in
                started.fulfill()
                return try engine.db.rows("SELECT SUM(a.ttft_ms*b.ttft_ms) FROM attempts a,attempts b")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        async let first: Void = archive.close()
        async let second: Void = archive.close()
        _ = try await (first, second)
        do { _ = try await query.value; XCTFail("Shutdown must cancel the in-flight reader") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await reader.run { try $0.requestPage(filter) }; XCTFail("A closed reader cannot reopen its connection") }
        catch { XCTAssertTrue(error is CaptureFailure) }
        try await archive.configure(quota: 1_073_741_824, bodyRetention: 86400, metricRetention: 86400)
        let page = try await archive.requestPage(filter)
        XCTAssertEqual(page.selectedRequests, 100_000)
        try await archive.close()
    }
}
