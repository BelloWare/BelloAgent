import XCTest
@testable import PiApp

final class CaptureMaintenanceQueryTests: XCTestCase {
    private let eligibleID = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    private enum Shape: String, CaseIterable {
        case dense, sparse
        var eligible: Int { self == .dense ? 100_002 : 1 }
        var other: Int { self == .sparse ? 200_000 : 0 }
    }
    private enum Maintenance: String, CaseIterable {
        case metrics, bodies, quota, clear
        var sql: String {
            switch self {
            case .metrics: PayloadArchive.metricRetentionBatchSQL
            case .bodies: PayloadArchive.bodyRetentionBatchSQL
            case .quota: PayloadArchive.quotaBatchSQL
            case .clear: PayloadArchive.clearBatchSQL
            }
        }
    }
    private func fixture(_ shape: Shape, _ maintenance: Maintenance) async throws -> (URL, CaptureDatabase) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let archive = PayloadArchive(root: folder)
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        try await archive.close()
        let db = try CaptureDatabase(url: folder.appendingPathComponent("requests.sqlite"))
        try db.transaction {
            try db.execute("""
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<?)
            INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,outcome,wall,updated,metadata,metrics_retained)
            SELECT printf('00000000-0000-0000-0000-%012d',i),?, 'workspace','turn','turn','api','model','completed',?,1,x'7b7d',? FROM n
            """, [.integer(Int64(shape == .dense ? shape.eligible - 1 : shape.other)),
                   .text(shape == .sparse && maintenance == .clear ? "other" : "target"),
                   .integer(shape == .sparse && maintenance != .clear ? 1_000 : 1), .integer(1)])
            try db.execute("INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,outcome,wall,updated,metadata) VALUES(?,'target','workspace','turn','turn','api','model','completed',1,1,x'7b7d')", [.text(eligibleID)])
            try db.execute("INSERT INTO bodies(attempt,kind,state,length,storage) SELECT id,'request','complete',1,'plaintext-v2' FROM attempts")
            try db.execute("INSERT INTO chunks(scope,id,length,bytes,storage) VALUES('scope','chunk',1,1,'plaintext-v2')")
            let retained = shape == .sparse && maintenance == .quota ? "id='\(eligibleID)'" : "1"
            try db.execute("INSERT INTO refs(attempt,kind,ordinal,scope,chunk,offset,length) SELECT id,'request',0,'scope','chunk',0,1 FROM attempts WHERE \(retained)")
            if shape == .sparse && maintenance == .quota {
                // Permanent bodyless tombstones precede the sole quota candidate.
                try db.execute("UPDATE attempts SET wall=0,metrics_retained=0 WHERE id!=?", [.text(eligibleID)])
            }
            if shape == .dense {
                try db.execute("UPDATE attempts SET wall=1+CAST(substr(id,25) AS INTEGER)%7 WHERE id!=?", [.text(eligibleID)])
            }
        }
        return (folder, db)
    }
    private func plan(_ db: CaptureDatabase, _ label: String, _ sql: String, _ values: [CaptureSQLValue]) throws {
        let details = try db.rows("EXPLAIN QUERY PLAN " + sql, values).compactMap { $0["detail"]?.string }
        print("PLAN \(label): \(details.joined(separator: " | "))")
        XCTAssertFalse(details.contains { $0.contains("USE TEMP B-TREE") }, label)
    }
    private func pages(_ db: CaptureDatabase, _ shape: Shape, _ maintenance: Maintenance) throws {
        let sql = maintenance.sql
        var after = "", wall = -Double.infinity, count = 0, work = 0, page = 0
        while true {
            var values: [CaptureSQLValue]
            switch maintenance {
            case .clear: values = [.text("target"), .text(after)]
            case .bodies, .metrics: values = [.real(wall), .text(after), .real(10)]
            case .quota: values = [.real(wall), .text(after)]
            }
            values.append(.integer(Int64(PayloadArchive.maintenanceBatch)))
            if page == 0 { try plan(db, "\(maintenance.rawValue)/\(shape.rawValue)", sql, values) }
            let before = db.virtualMachineSteps, rows = try db.rows(sql, values)
            work += db.virtualMachineSteps - before; page += 1; count += rows.count
            XCTAssertLessThanOrEqual(rows.count, PayloadArchive.maintenanceBatch)
            if work >= shape.eligible * 50 + 1_000 || count > shape.eligible { break }
            guard let last = rows.last else { break }
            after = try XCTUnwrap(last["id"]?.string); wall = last["wall"]?.double ?? wall
        }
        print("WORK \(maintenance.rawValue)/\(shape.rawValue): \(work) VM steps, \(count) eligible, \(page) pages")
        XCTAssertEqual(count, shape.eligible)
        XCTAssertLessThan(work, shape.eligible * 50 + 1_000, "\(maintenance.rawValue)/\(shape.rawValue): seek eligible rows, including the final empty page")
    }
    func testEveryMaintenanceSelectorSeeksEligibleRowsInBothArchiveShapes() async throws {
        for maintenance in Maintenance.allCases {
            for shape in Shape.allCases {
                let (folder, db) = try await fixture(shape, maintenance)
                defer { try? FileManager.default.removeItem(at: folder) }
                try pages(db, shape, maintenance)
                if shape == .sparse && [.metrics, .bodies].contains(maintenance) {
                    // Old, already-unavailable rows are a different sparse shape
                    // from future rows: neither may be visited by the selector.
                    if maintenance == .metrics { try db.execute("UPDATE attempts SET metrics_retained=0,wall=0 WHERE id!=?", [.text(eligibleID)]) }
                    else { try db.execute("DELETE FROM refs WHERE attempt!=?", [.text(eligibleID)]) }
                    print("VARIANT \(maintenance.rawValue): already unavailable")
                    try pages(db, shape, maintenance)
                }
                if shape == .sparse && maintenance != .clear {
                    try db.execute("UPDATE attempts SET outcome='running',metrics_retained=1,wall=0 WHERE id!=?", [.text(eligibleID)])
                    if maintenance != .metrics {
                        try db.execute("INSERT OR IGNORE INTO refs(attempt,kind,ordinal,scope,chunk,offset,length) SELECT id,'request',0,'scope','chunk',0,1 FROM attempts")
                    }
                    print("VARIANT \(maintenance.rawValue): running")
                    try pages(db, shape, maintenance)
                }
            }
        }
    }
    func testRetentionDeadlinesSeekTheFirstEligibleRowInBothArchiveShapes() async throws {
        for shape in Shape.allCases {
            let (folder, db) = try await fixture(shape, .bodies)
            defer { try? FileManager.default.removeItem(at: folder) }
            for variant in shape == .sparse ? ["future", "running", "unavailable"] : ["eligible"] {
                if variant == "running" {
                    try db.execute("UPDATE attempts SET outcome='running',wall=0 WHERE id!=?", [.text(eligibleID)])
                } else if variant == "unavailable" {
                    try db.execute("UPDATE attempts SET outcome='completed',metrics_retained=0,wall=0 WHERE id!=?", [.text(eligibleID)])
                    try db.execute("DELETE FROM refs WHERE attempt!=?", [.text(eligibleID)])
                }
                for (name, sql) in [("body-deadline", PayloadArchive.bodyDeadlineSQL), ("metric-deadline", PayloadArchive.metricDeadlineSQL)] {
                    let label = "\(name)/\(shape.rawValue)/\(variant)"
                    try plan(db, label, sql, [])
                    let before = db.virtualMachineSteps, rows = try db.rows(sql)
                    let work = db.virtualMachineSteps - before
                    print("WORK \(label): \(work) VM steps")
                    XCTAssertEqual(rows.first?["wall"]?.double, 1)
                    XCTAssertLessThan(work, 100, "Only the earliest eligible deadline is needed")
                }
            }
        }
    }
    func testExportLeaseMetadataLookupsSeekOnlyTheRequestedIdentitiesInBothArchiveShapes() async throws {
        for shape in Shape.allCases {
            let (folder, db) = try await fixture(shape, .clear)
            defer { try? FileManager.default.removeItem(at: folder) }
            for (name, sql) in [("export-attempt", PayloadArchive.attemptMetadataSQL), ("export-bodies", PayloadArchive.bodyMetadataSQL)] {
                try plan(db, "\(name)/\(shape.rawValue)", sql, [.text(eligibleID)])
                var work = 0
                for index in 0..<shape.eligible {
                    let id = index == 0 ? eligibleID : String(format: "00000000-0000-0000-0000-%012d", index)
                    let before = db.virtualMachineSteps, rows = try db.rows(sql, [.text(id)])
                    let lookup = db.virtualMachineSteps - before; work += lookup
                    XCTAssertEqual(rows.count, 1)
                    XCTAssertLessThan(lookup, 100, "A lease lookup must seek exactly one attempt, not scan other captures")
                    if lookup >= 100 { break }
                }
                print("WORK \(name)/\(shape.rawValue): \(work) VM steps, \(shape.eligible) identities")
                XCTAssertLessThan(work, 100 * shape.eligible + 100)
            }
        }
    }
    func testGarbageCollectionSeeksOnlyUnreferencedChunksInBothArchiveShapes() async throws {
        for shape in Shape.allCases {
            let (folder, db) = try await fixture(.sparse, .quota)
            defer { try? FileManager.default.removeItem(at: folder) }
            try db.transaction {
                try db.execute("DELETE FROM refs")
                try db.execute("DELETE FROM chunks")
                try db.execute("""
                WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<?)
                INSERT INTO chunks(scope,id,length,bytes,storage)
                SELECT 'scope',printf('%064d',i),1,1,'plaintext-v2' FROM n
                """, [.integer(Int64(shape.eligible + shape.other))])
                if shape == .sparse {
                    try db.execute("INSERT INTO refs(attempt,kind,ordinal,scope,chunk,offset,length) SELECT ?,'request',CAST(id AS INTEGER),scope,id,0,1 FROM chunks WHERE CAST(id AS INTEGER)<=?", [.text(eligibleID), .integer(Int64(shape.other))])
                }
            }
            var after: (scope: String, id: String) = ("", ""), work = 0, deletionWork = 0, count = 0
            let sql = PayloadArchive.orphanChunksBatchSQL
            try plan(db, "garbage/\(shape.rawValue)", sql, [.text(""), .text(""), .integer(512)])
            while true {
                let before = db.virtualMachineSteps
                let batch = try db.rows(sql, [.text(after.scope), .text(after.id), .integer(512)])
                work += db.virtualMachineSteps - before; count += batch.count
                guard let last = batch.last else { break }
                let end = (scope: try XCTUnwrap(last["scope"]?.string), id: try XCTUnwrap(last["id"]?.string))
                let bounds: [CaptureSQLValue] = [.text(after.scope), .text(after.id), .text(end.scope), .text(end.id)]
                if after.id.isEmpty { try plan(db, "garbage-delete/\(shape.rawValue)", PayloadArchive.orphanChunksDeleteSQL, bounds) }
                let deleting = db.virtualMachineSteps
                try db.execute(PayloadArchive.orphanChunksDeleteSQL, bounds)
                deletionWork += db.virtualMachineSteps - deleting
                after = end
            }
            print("WORK garbage/\(shape.rawValue): \(work) VM steps, \(count) eligible")
            print("WORK garbage-delete/\(shape.rawValue): \(deletionWork) VM steps, \(count) eligible")
            XCTAssertEqual(count, shape.eligible)
            XCTAssertLessThan(work, shape.eligible * 50 + 1_000, "Cleanup after maintenance must not scan retained chunks")
            XCTAssertLessThan(deletionWork, shape.eligible * 80 + 1_000, "Deleting each batch must also skip retained chunks")
            XCTAssertEqual(try db.rows("SELECT COUNT(*) AS n FROM chunks").first?["n"]?.number, Int64(shape.other))
        }
    }
    func testReferenceEligibilityMigrationIsIdempotentAndTransactional() async throws {
        let (folder, db) = try await fixture(.dense, .bodies)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Restore the previous additive schema with 100,002 retained attempts.
        for trigger in ["refs_added", "refs_removed", "refs_moved"] { try db.execute("DROP TRIGGER \(trigger)") }
        try db.execute("DROP INDEX attempts_retaining_bodies"); try db.execute("DROP INDEX chunks_unreferenced")
        try db.execute("ALTER TABLE attempts DROP COLUMN has_refs"); try db.execute("ALTER TABLE chunks DROP COLUMN has_refs")
        try PayloadArchive.prepareMaintenanceSchema(db)
        XCTAssertEqual(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE has_refs=1").first?["n"]?.number, 100_002)
        XCTAssertEqual(try db.rows("SELECT has_refs FROM chunks").first?["has_refs"]?.number, 1)
        let before = db.virtualMachineSteps
        try PayloadArchive.prepareMaintenanceSchema(db)
        let work = db.virtualMachineSteps - before
        print("WORK second eligibility migration: \(work) VM steps")
        XCTAssertLessThan(work, 2_000, "Reopening must not backfill the archive again")

        let other = "00000000-0000-0000-0000-000000000001"
        try db.execute("DELETE FROM refs WHERE attempt!=?", [.text(eligibleID)])
        try db.execute("INSERT INTO refs VALUES(?,'request',1,'scope','chunk',1,1)", [.text(eligibleID)])
        try db.execute("DELETE FROM refs WHERE attempt=? AND ordinal=0", [.text(eligibleID)])
        XCTAssertEqual(try db.rows("SELECT has_refs FROM attempts WHERE id=?", [.text(eligibleID)]).first?["has_refs"]?.number, 1, "One remaining reference still retains the attempt")
        try db.execute("INSERT INTO chunks(scope,id,length,bytes,storage) VALUES('scope','other',1,1,'plaintext-v2')")
        try db.execute("UPDATE refs SET attempt=?,chunk='other' WHERE attempt=?", [.text(other), .text(eligibleID)])
        XCTAssertEqual(try db.rows("SELECT has_refs FROM attempts WHERE id=?", [.text(eligibleID)]).first?["has_refs"]?.number, 0)
        XCTAssertEqual(try db.rows("SELECT has_refs FROM attempts WHERE id=?", [.text(other)]).first?["has_refs"]?.number, 1)
        XCTAssertEqual(try db.rows("SELECT has_refs FROM chunks WHERE id='chunk'").first?["has_refs"]?.number, 0)
        XCTAssertEqual(try db.rows("SELECT has_refs FROM chunks WHERE id='other'").first?["has_refs"]?.number, 1)
        do {
            try db.transaction {
                try db.execute("DELETE FROM refs")
                XCTAssertEqual(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE has_refs=1").first?["n"]?.number, 0)
                throw CaptureFailure.busy
            }
        } catch CaptureFailure.busy { }
        XCTAssertEqual(try db.rows("SELECT has_refs FROM chunks WHERE id='other'").first?["has_refs"]?.number, 1, "Rollback restores eligibility with the reference")
        try db.execute("DELETE FROM bodies WHERE attempt=?", [.text(other)])
        XCTAssertEqual(try db.rows("SELECT has_refs FROM attempts WHERE id=?", [.text(other)]).first?["has_refs"]?.number, 0)
        XCTAssertEqual(try db.rows("SELECT has_refs FROM chunks WHERE id='other'").first?["has_refs"]?.number, 0, "Cascaded reference deletion clears eligibility")
    }
}
