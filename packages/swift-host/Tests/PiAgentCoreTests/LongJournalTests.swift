import XCTest
@testable import PiAgentCore

final class LongJournalTests: XCTestCase {
    private let oldLimit = 128 * 1024 * 1024

    /// Real bytes beyond the old ceiling, not a small injected limit. Unknown
    /// metadata stands in for old presentation snapshots: it must be preserved
    /// in a fork, but need not be retained in a reopened chat's memory/context.
    private func largeJournal(_ root: URL, profile: Profile) throws -> URL {
        let path = root.appendingPathComponent("state/long.jsonl")
        var parent: String
        do {
            let journal = try SessionJournal(url: path, id: "long", cwd: root, binding: profile.binding, create: true)
            try journal.append(["type":"message","message":["role":"user","content":"Original question"]], id:"old-user")
            try journal.append(["type":"message","message":["role":"assistant","content":"Original answer"]], id:"old-answer")
            parent = try XCTUnwrap(journal.head)
        }
        let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
        try file.seekToEnd()
        let payload = Data(repeating: 120, count: 1024 * 1024)
        for index in 0..<127 {
            let id = "padding-\(index)"
            try file.write(contentsOf: Data("{\"type\":\"custom\",\"customType\":\"fixture.padding\",\"id\":\"\(id)\",\"parentId\":\"\(parent)\",\"data\":\"".utf8))
            try file.write(contentsOf: payload); try file.write(contentsOf: Data("\"}\n".utf8)); parent = id
        }
        try file.synchronize(); try file.close()
        XCTAssertLessThan(try JournalRecordReader(path).size, UInt64(oldLimit))
        do {
            let journal = try SessionJournal(url: path, id: "long", cwd: root, binding: profile.binding, create: false)
            try journal.append(["type":"custom","customType":"fixture.padding","data":JSON(String(repeating:"y",count:2*1024*1024))], id:"crossed-limit")
        }
        XCTAssertGreaterThan(try JournalRecordReader(path).size, UInt64(oldLimit))
        return path
    }

    func testLongThreadContinuesReopensForksExportsAndRecoversBeyond128MiB() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), directory = root.appendingPathComponent("state")
        let path = try largeJournal(root, profile:profile)
        let client = ScriptClient([answer("Still working in the same thread")])
        func session(_ id:String, _ path:String) throws -> AgentSession {
            try AgentSession(id:id,profile:profile,apiKey:"fixture",cwd:root,directory:directory,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path,autoCompaction:false)
        }
        let original = try session("long",path.path)
        _ = try await original.submit(Submission(commandID:"continue",turnID:"continue",text:"Continue the long thread"),steer:false)
        try await eventually { !(await original.isRunning) }
        let originalContext = await original.context
        XCTAssertEqual(originalContext.first?.text,"Original question")
        XCTAssertEqual(originalContext.last?.text,"Still working in the same thread")
        let fork = try await original.fork(to:"copy")
        let forkPath = try XCTUnwrap(fork["path"].text)
        XCTAssertGreaterThan(try JournalRecordReader(URL(fileURLWithPath:forkPath)).size,UInt64(oldLimit))
        let copied = try session("copy",forkPath)
        let copiedContext = await copied.context
        XCTAssertEqual(copiedContext.map(\.id),originalContext.map(\.id))
        await copied.close()
        let historical = try await original.fork(to:"historical",at:"old-answer")
        let earlier = try session("historical",try XCTUnwrap(historical["path"].text))
        let earlierContext = await earlier.context
        XCTAssertEqual(earlierContext.map(\.id),["old-user","old-answer"])
        await earlier.close(); await original.close()
        let reopened = try session("long",path.path)
        let restored = await reopened.context
        XCTAssertEqual(restored.map(\.id),originalContext.map(\.id)); await reopened.close()

        let host = NativeHostService(emit:{ _ in })
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(directory.path),"mcp":["servers":[:]]])
        let portable = try await host.command("session.portable.preview",sessionID:nil,params:["path":JSON(path.path)])
        XCTAssertTrue(portable["text"].text?.contains("Original question") == true)
        XCTAssertTrue(portable["text"].text?.contains("Still working") == true)
        let digest = try JournalRecordReader(path,hash:true)
        while try digest.next() != nil { }
        XCTAssertEqual(portable["sha256"].text,digest.digest)

        let writer = try FileHandle(forWritingTo:path); try writer.seekToEnd()
        let partial = Data("{\"type\":\"message\",\"id\":\"unfinished".utf8)
        try writer.write(contentsOf:partial); try writer.close()
        XCTAssertThrowsError(try session("long",path.path))
        let damagedSize = try JournalRecordReader(path,allowIncompleteTail:true).size
        let recovered = try await host.command("session.recover",sessionID:nil,params:["path":JSON(path.path),"newSessionId":"recovered"])
        XCTAssertEqual(recovered["omittedBytes"].int,partial.count)
        XCTAssertEqual(try JournalRecordReader(path,allowIncompleteTail:true).size,damagedSize,"Recovery preserves the original")
        let recoveredPath = try XCTUnwrap(recovered["sessionFile"].text)
        XCTAssertGreaterThan(try JournalRecordReader(URL(fileURLWithPath:recoveredPath)).size,UInt64(oldLimit))
        let recoveredSession = try session("recovered",recoveredPath)
        let recoveredContext = await recoveredSession.context
        XCTAssertEqual(recoveredContext.map(\.id),originalContext.map(\.id))
        await recoveredSession.close(); await host.shutdown()
    }

    func testCursorHandlesChunkBoundariesAndHashesOriginalBytes() throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("stream.jsonl")
        let records:[JSON]=[["text":"🙂漢é"],["text":JSON(String(repeating:"x",count:200_000))],["last":true]]
        var bytes=Data([10])
        for record in records { bytes.append(try record.data()); bytes.append(contentsOf:[10,10]) }
        try bytes.write(to:path)
        for chunk in [7,65_536] {
            let reader=try JournalRecordReader(path,hash:true,chunkBytes:chunk)
            for record in records { XCTAssertEqual(try reader.next(),record) }
            XCTAssertNil(try reader.next()); XCTAssertEqual(reader.completeBytes,UInt64(bytes.count))
            XCTAssertEqual(reader.digest,sha256(bytes)); XCTAssertTrue(reader.rawLine.isEmpty)
        }
        var fallback=PortableSHA256Context()
        for offset in stride(from:0,to:bytes.count,by:97) { fallback.update(bytes.subdata(in:offset..<min(offset+97,bytes.count))) }
        XCTAssertEqual(fallback.finalize(),sha256(bytes))
    }

    func testCursorRejectsChangedFilesAndPreservesIncompleteTail() throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("stream.jsonl"), original=Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        try original.write(to:path)
        let reader=try JournalRecordReader(path,chunkBytes:1)
        XCTAssertNotNil(try reader.next())
        let writer=try FileHandle(forWritingTo:path); try writer.truncate(atOffset:8); try writer.close()
        XCTAssertThrowsError(try reader.next())
        var damaged=original; damaged.append(Data("{\"tail\":".utf8)); try damaged.write(to:path)
        let strict=try JournalRecordReader(path); _=try strict.next(); _=try strict.next()
        XCTAssertThrowsError(try strict.next())
        let recovering=try JournalRecordReader(path,allowIncompleteTail:true)
        while try recovering.next() != nil { }
        XCTAssertEqual(recovering.completeBytes,UInt64(original.count))
        XCTAssertEqual(try Data(contentsOf:path),damaged)
        XCTAssertThrowsError(try JournalRecordReader(path,expectedBytes:UInt64(original.count)))
    }

    func testRecoverySkipsAnOversizedUnfinishedTailButRejectsACompleteOversizedRecord() throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("tail.jsonl"), prefix=Data("{\"complete\":true}\n".utf8)
        try prefix.write(to:path)
        let file=try FileHandle(forWritingTo:path); defer { try? file.close() }; try file.seekToEnd()
        let block=Data(repeating:32,count:1024*1024)
        for _ in 0..<33 { try file.write(contentsOf:block) }
        let recovery=try JournalRecordReader(path,allowIncompleteTail:true)
        XCTAssertEqual(try recovery.next(),["complete":true]); XCTAssertNil(try recovery.next())
        XCTAssertEqual(recovery.omittedBytes,33*1024*1024); XCTAssertTrue(recovery.rawLine.isEmpty)
        // The same bytes followed by a newline are damage in a complete record,
        // and may not disappear from a recovered copy.
        try file.write(contentsOf:Data([10]))
        let invalid=try JournalRecordReader(path,allowIncompleteTail:true)
        _=try invalid.next(); XCTAssertThrowsError(try invalid.next())
    }

    func testIndividualRecordProtectionDoesNotPoisonTheThread() throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("s.jsonl"), profile=try fixtureProfile()
        let journal=try SessionJournal(url:path,id:"s",cwd:root,binding:profile.binding,create:true)
        let originalHead=journal.head
        XCTAssertThrowsError(try journal.append(["data":JSON(String(repeating:"x",count:JournalRecordReader.maximumRecordBytes))])) {
            XCTAssertEqual(($0 as? AgentError)?.code,"session_record_limit")
        }
        XCTAssertEqual(journal.head,originalHead); XCTAssertFalse(journal.writeOutcomeUncertain)
        try journal.append(["type":"custom","data":"a later small record still works"],id:"next")
        XCTAssertEqual(journal.head,"next")
    }
}
