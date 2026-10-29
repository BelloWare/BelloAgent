import XCTest
@testable import PiAgentCore

final class JournalPromotionTests: HelperTestCase {
    private func promote(_ journal: SessionJournal, version: Int, child: Bool, clone: (Int32,String) -> Int32 = SessionJournal.cloneFile) throws {
        switch version {
        case 3: try journal.promoteToSteering(managedChild:child,cloneFile:clone)
        case 4: try journal.promoteToCodex(managedChild:child,cloneFile:clone)
        default: try journal.promoteToMailboxCut(managedChild:child,cloneFile:clone)
        }
    }
    func testCloneAndFallbackPreserveEveryByteOutsideTheMarkerAndWriterLock() throws {
        for child in [false,true] {
            for fallback in [false,true] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let path = root.appendingPathComponent("promotion.jsonl")
                do {
                    let journal = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:child)
                    try journal.append(["type":"message","message":ChatMessage(role:"user",content:[textBlock(String(repeating:"Opaque 雪",count:400))]).pi],id:"before",flush:false)
                    for version in 3...5 {
                        let before = try Data(contentsOf:path), check = try XCTUnwrap(journal.markerCheck)
                        var called = 0
                        try promote(journal,version:version,child:child) { source, destination in
                            called += 1
                            do {
                                _ = try SessionJournal(url:path,id:"promotion",cwd:root,binding:nil,create:false)
                                XCTFail("Promotion released the writer lock")
                            } catch { XCTAssertEqual((error as? AgentError)?.code,"session_locked") }
                            if fallback {
                                // A failed clone may have left a partial file.
                                try? Data("abandoned clone".utf8).write(to:URL(fileURLWithPath:destination)); return -1
                            }
                            let result = SessionJournal.cloneFile(source,destination)
                            XCTAssertEqual(result,0,"This APFS fixture must exercise the clone path")
                            return result
                        }
                        XCTAssertEqual(called,1)
                        let after = try Data(contentsOf:path), start = Int(check.offset), end = start + check.length
                        XCTAssertEqual(after.count,before.count)
                        XCTAssertEqual(after.prefix(start),before.prefix(start)); XCTAssertEqual(after.suffix(from:end),before.suffix(from:end))
                        XCTAssertEqual(try JSON.parse(after.subdata(in:start..<end))["customType"].text,"pi-app.native.v\(version)")
                        XCTAssertEqual(journal.head,"before")
                        XCTAssertFalse(FileManager.default.fileExists(atPath:path.appendingPathExtension("promotion").path))
                    }
                    try journal.append(["type":"custom","customType":"fixture"],id:"after")
                }
                let reopened = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:false)
                XCTAssertEqual(reopened.head,"after"); XCTAssertEqual(reopened.markerKind,JournalRecordKind.cutinMarker)
            }
        }
    }
    func testCorruptClonedMarkerFailsBeforeReplacingAnyVersion() throws {
        for version in 3...5 {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let path = root.appendingPathComponent("promotion.jsonl")
            let journal = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:true)
            try journal.append(["type":"custom","customType":"fixture"],id:"before")
            let before = try Data(contentsOf:path), check = try XCTUnwrap(journal.markerCheck)
            XCTAssertThrowsError(try promote(journal,version:version,child:false) { source, destination in
                let result = SessionJournal.cloneFile(source,destination)
                if result == 0 {
                    let file = try? FileHandle(forWritingTo:URL(fileURLWithPath:destination))
                    try? file?.seek(toOffset:check.offset); try? file?.write(contentsOf:Data("!".utf8)); try? file?.close()
                }
                return result
            })
            XCTAssertEqual(try Data(contentsOf:path),before)
            XCTAssertFalse(journal.writeOutcomeUncertain)
            XCTAssertFalse(FileManager.default.fileExists(atPath:path.appendingPathExtension("promotion").path))
            try journal.append(["type":"custom","customType":"fixture"],id:"after")
        }
    }
    func testWrongCloneLengthFailsWithoutChangingSource() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("promotion.jsonl")
        let journal = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:true)
        let before = try Data(contentsOf:path)
        XCTAssertThrowsError(try journal.promoteToMailboxCut(managedChild:false) { _, destination in
            try? Data("wrong size".utf8).write(to:URL(fileURLWithPath:destination)); return 0
        })
        XCTAssertEqual(try Data(contentsOf:path),before)
    }
    // The generated-source crash harness runs these in separate processes.
    // No fault switch is compiled into the production journal.
    func testPromotionFaultFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["PI_PROMOTION_FIXTURE"], let version = env["PI_PROMOTION_VERSION"].flatMap(Int.init) else { throw XCTSkip("Promotion fault harness only") }
        let root = URL(fileURLWithPath:directory), path = root.appendingPathComponent("promotion.jsonl"), child = env["PI_PROMOTION_CHILD"] == "1"
        let journal = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:child)
        try journal.append(["type":"message","message":ChatMessage(role:"user",content:[textBlock(String(repeating:"Generated body 雪 ",count:1000))]).pi],id:"before")
        try Data(contentsOf:path).write(to:root.appendingPathComponent("before.jsonl"))
        try promote(journal,version:version,child:child,clone:env["PI_PROMOTION_COPY"] == "1" ? { _,_ in -1 } : SessionJournal.cloneFile)
    }
    func testReopenPromotionFaultFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["PI_PROMOTION_FIXTURE"], let expected = env["PI_PROMOTION_EXPECTED"] else { throw XCTSkip("Promotion fault harness only") }
        let root = URL(fileURLWithPath:directory), path = root.appendingPathComponent("promotion.jsonl")
        let journal = try SessionJournal(url:path,id:"promotion",cwd:root,binding:fixtureProfile().binding,create:false)
        XCTAssertEqual(journal.markerKind,expected); XCTAssertEqual(journal.head,"before")
        try journal.append(["type":"custom","customType":"fixture"],id:"after")
    }
}
