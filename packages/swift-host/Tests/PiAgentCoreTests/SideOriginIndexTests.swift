import XCTest
@testable import PiAgentCore

final class SideOriginIndexTests: HelperTestCase {
    func testColdOpenWithTwoHundredLongSavedSidesBoundsUnrelatedDiscovery() async throws {
        let root = canonical(try temporaryDirectory().path); defer { try? FileManager.default.removeItem(at:root) }
        for id in ["main","unrelated"] { let value = try session(id,root:root); await value.close() }
        let template = root.appendingPathComponent("template.jsonl")
        do {
            let writer = try SessionJournal(url:template,id:"template",cwd:root,binding:fixtureProfile().binding,create:true)
            for n in 0..<600 {
                try writer.append(["type":"message","message":ChatMessage(role:n % 2 == 0 ? "user" : "assistant",content:[["type":"text","text":JSON(String(repeating:"Generated long history. ",count:90))]]).pi],id:"m\(n)",flush:false)
            }
        }
        let original = try Data(contentsOf:template), newline = try XCTUnwrap(original.firstIndex(of:10))
        for n in 0..<200 {
            let id = String(format:"saved-%03d",n), file = root.appendingPathComponent("side_" + id + ".jsonl")
            var header = try JSON.parse(original.prefix(newline)); header["id"] = JSON(id)
            var data = try header.data(); data.append(original[newline...]); try data.write(to:file)
            let writer = try SessionJournal(url:file,id:id,cwd:root,binding:fixtureProfile().binding,create:false)
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":["parentSessionId":JSON(n == 0 ? "main" : "other-\(n)"),"relationship":"side"]])
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":["usd":0.25,"reported":1,"unreported":0]])
        }
        var decoded = 0, bytes = 0
        SideOriginReadProbe.observe { _, count, records in
            bytes += count; decoded += records
        }
        defer { SideOriginReadProbe.observe(nil) }
        for id in ["unrelated","main","unrelated"] {
            SideOriginIndex.resetMemory(); decoded = 0; bytes = 0
            let start = ContinuousClock.now
            let value = try session(id,root:root,resume:true)
            let spend = await value.spend
            print("SIDE-ORIGIN-PERF \(id) elapsed=\(start.duration(to:.now)) decoded=\(decoded) bytes=\(bytes) fixtureBytes=\(original.count * 200)")
            XCTAssertEqual(spend.usd,id == "main" ? 0.25 : 0)
            XCTAssertLessThanOrEqual(decoded,400,"Only each side's header and origin may be decoded")
            XCTAssertLessThanOrEqual(bytes,200 * 65536,"Discovery cannot walk inherited message history")
            XCTAssertGreaterThan(decoded,0,"The probe must observe actual cold discovery work")
            await value.close()
        }
    }

    func testOriginCacheInvalidatesAppendRewriteReplacementAndRemoval() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("side_saved.jsonl")
        do {
            let writer = try SessionJournal(url:file,id:"saved",cwd:root,binding:fixtureProfile().binding,create:true)
            XCTAssertNil(try SideBudgetRecovery.readOrigin(file))
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":["parentSessionId":"alpha","relationship":"side"]])
        }
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"alpha","Append invalidates cached absence")
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date)
        let original = try String(contentsOf:file,encoding:.utf8)
        // Same inode, same length and restored mtime: ctime still fences edits.
        let handle = try FileHandle(forWritingTo:file)
        try handle.write(contentsOf:Data(original.replacingOccurrences(of:"alpha",with:"bravo").utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:file.path)
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"bravo")
        // Replacement at the same path/size/stamp must not inherit the old owner.
        try Data(original.replacingOccurrences(of:"alpha",with:"other").utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:file.path)
        SideOriginIndex.resetMemory()
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"other")
        let cache = SideOriginIndex.url(for:file)
        XCTAssertLessThan(try Data(contentsOf:cache).count,4096)
        // A corrupted locator is disposable; its claimed identity is never trusted.
        try Data("{broken cache".utf8).write(to:cache); SideOriginIndex.resetMemory()
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"other")
        try FileManager.default.removeItem(at:file)
        XCTAssertThrowsError(try SideBudgetRecovery.readOrigin(file))
        XCTAssertTrue(try SideBudgetRecovery.savedFamily(owner:"other",directory:root).isEmpty)
    }

    func testOversizedTailDoesNotHideAnEstablishedFamilyOrigin() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("side_saved.jsonl")
        do {
            let writer = try SessionJournal(url:file,id:"saved",cwd:root,binding:fixtureProfile().binding,create:true)
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":["parentSessionId":"main"]])
        }
        let writer = try FileHandle(forWritingTo:file); try writer.seekToEnd()
        try writer.write(contentsOf:Data(repeating:120,count:JournalRecordReader.maximumRecordBytes + 1024)); try writer.close()
        XCTAssertTrue(try SideBudgetRecovery.charges(owner:"unrelated",directory:root).isEmpty)
        XCTAssertThrowsError(try SideBudgetRecovery.charges(owner:"main",directory:root),"Established family damage must still fail closed")
    }

    func testChangedJournalRevalidatesLocatorWithoutWalkingAppendedHistory() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("side_saved.jsonl")
        do {
            let writer = try SessionJournal(url:file,id:"saved",cwd:root,binding:fixtureProfile().binding,create:true)
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":["parentSessionId":"main"]])
            XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"main")
            for _ in 0..<200 { try writer.append(["type":"message","message":ChatMessage(role:"user",content:[["type":"text","text":JSON(String(repeating:"More generated history. ",count:400))]]).pi],flush:false) }
        }
        SideOriginIndex.resetMemory()
        var bytes = 0, decoded = 0
        SideOriginReadProbe.observe { _, count, records in bytes += count; decoded += records }
        defer { SideOriginReadProbe.observe(nil) }
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"main")
        XCTAssertEqual(decoded,2,"A changed stamp requires fresh header/origin validation")
        XCTAssertLessThan(bytes,4096,"An old locator is only an offset hint; validate its records without scanning new messages")
        let first = bytes
        XCTAssertEqual(try SideBudgetRecovery.readOrigin(file)?.parent,"main")
        XCTAssertEqual(bytes,first,"An unchanged in-memory origin needs only file identity/stamp checks")
    }

    func testReleaseUsesOnlyLoadedReaderAncestryAndDeletionDoesNotBlockHostActor() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var fixture = SideBudgetUpgradeFixture(root:root,shape:.current,family:.nestedAgents,usage:.priced,crash:.afterAll)
        try fixture.write(); let host = try await fixture.host()
        _ = try await fixture.open(host,"child")
        var scans = 0
        SideOriginReadProbe.observe(nil,scan:{ _ in scans += 1 })
        let result = try await host.command("session.releaseDependents",sessionID:"main",params:[:])
        SideOriginReadProbe.observe(nil)
        XCTAssertEqual(scans,0,"Unloading cannot enumerate the workspace")
        XCTAssertEqual(result["released"].list,["child"],"Cold direct ancestry still finds a nested side's child")
        let entered = expectation(description:"detached discovery"), gate = DispatchSemaphore(value:0)
        var first = true
        SideOriginReadProbe.observe(nil,scan:{ _ in
            if first { first = false; entered.fulfill(); _ = gate.wait(timeout:.now() + 5) }
        })
        let deletion = Task { try await host.command("session.forget",sessionID:"main",params:[:]) }
        await fulfillment(of:[entered],timeout:5)
        let start = ContinuousClock.now
        _ = try await host.command("runtime.info",sessionID:nil,params:[:])
        let elapsed = start.duration(to:.now)
        gate.signal(); _ = try await deletion.value
        SideOriginReadProbe.observe(nil)
        XCTAssertLessThan(elapsed,.seconds(1),"Discovery I/O must not occupy the host actor")
        await host.shutdown()
    }

    private func session(_ id: String, root: URL, resume: Bool = false) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:resume ? root.appendingPathComponent(id + ".jsonl").path : nil)
    }
}
