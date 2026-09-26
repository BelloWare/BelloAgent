import XCTest
@testable import PiApp

final class LongJournalHistoryTests: XCTestCase {
    func testLongJournalBrowsesAndReadsMessagesBeyondTheOld128MiBCeiling() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("long.jsonl")
        FileManager.default.createFile(atPath:path.path,contents:nil)
        let writer=try FileHandle(forWritingTo:path); defer { try? writer.close() }
        try writer.write(contentsOf:Data("{\"type\":\"session\",\"id\":\"long\",\"version\":3}\n{\"type\":\"custom\",\"customType\":\"pi-app.native.v1\",\"id\":\"marker\",\"parentId\":null}\n".utf8))
        var parent="marker"
        func message(_ id:String, role:String, text:String) throws {
            let record:[String:Any] = ["id":id,"parentId":parent,"type":"message","message":["role":role,"content":text]]
            var bytes=try JSONSerialization.data(withJSONObject:record); bytes.append(10)
            try writer.write(contentsOf:bytes); parent=id
        }
        try message("first-user",role:"user",text:"The first question")
        try message("first-answer",role:"assistant",text:"The first answer")
        let payload=Data(repeating:120,count:1024*1024)
        for index in 0..<129 {
            let id="padding-\(index)"
            try writer.write(contentsOf:Data("{\"type\":\"custom\",\"id\":\"\(id)\",\"parentId\":\"\(parent)\",\"data\":\"".utf8))
            try writer.write(contentsOf:payload); try writer.write(contentsOf:Data("\"}\n".utf8)); parent=id
        }
        try message("last-user",role:"user",text:"Continue this same thread")
        try message("last-answer",role:"assistant",text:"The latest answer beyond 128 MiB")
        try writer.synchronize()
        XCTAssertGreaterThan(try writer.offset(),134_217_728)
        let reader=HistoryReader()
        let latest=try await reader.window(path:path.path)
        XCTAssertNil(latest.notice); XCTAssertNil(latest.limitNotice)
        XCTAssertEqual(latest.messages.map(\.id),["first-user","first-answer","last-user","last-answer"])
        XCTAssertEqual(latest.total,4)
        let first=try await reader.message(path:path.path,id:"first-answer",field:"text",offset:0)
        let last=try await reader.message(path:path.path,id:"last-answer",field:"text",offset:0)
        XCTAssertEqual(first.0,"The first answer"); XCTAssertEqual(last.0,"The latest answer beyond 128 MiB")
        // Also cover direct lookup without a warm offset index.
        let cold=try await HistoryReader().message(path:path.path,id:"last-answer",field:"text",offset:0)
        XCTAssertEqual(cold.0,last.0)
        try await reader.validateIdentity(path:path.path,id:"long")
        let safe=try await reader.allowsAutomaticContext(path:path.path,id:"long")
        XCTAssertTrue(safe)
    }
}
