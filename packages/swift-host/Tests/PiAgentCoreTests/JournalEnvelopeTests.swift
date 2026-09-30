import XCTest
@testable import PiAgentCore

/// A fork copies each record's bytes as they were written, with only its
/// envelope new (`JournalEnvelope`), and falls back to parsing and encoding
/// the record for anything the scan does not read plainly. What a fork's
/// journal holds is the source's records, each the same but for its parent,
/// its time and a queued edit's run state, as when every record was parsed
/// and encoded again.
final class JournalEnvelopeTests: XCTestCase {
    private func line(_ text: String) -> Data { Data(text.utf8) }
    private func rewritten(_ text: String, id: String = "r1", parent: String? = "p2", time: String = "2026-09-30T00:00:00Z") -> String? {
        JournalEnvelope.rewritten(line(text), id: id, parentID: parent, timestamp: time).map { String(decoding: $0, as: UTF8.self) }
    }

    func testOnlyTheParentAndTimeChangeAndEveryOtherByteStays() throws {
        let original = #"{"id":"r1","message":{"content":"a \"quoted\" ,\"parentId\":\"x\" text 🙂","role":"user"},"parentId":"p1","timestamp":"2026-01-01T00:00:00Z","type":"message"}"#
        XCTAssertEqual(rewritten(original),
                       #"{"id":"r1","message":{"content":"a \"quoted\" ,\"parentId\":\"x\" text 🙂","role":"user"},"parentId":"p2","timestamp":"2026-09-30T00:00:00Z","type":"message"}"#,
                       "a key named inside the content is content")
        XCTAssertEqual(rewritten(#"{"id":"r1","parentId":null,"timestamp":"t","type":"custom"}"#, parent: nil),
                       #"{"id":"r1","parentId":null,"timestamp":"2026-09-30T00:00:00Z","type":"custom"}"#)
        XCTAssertEqual(rewritten(#"{"id":"r1","parentId":null,"timestamp":"t","type":"custom"}"#),
                       #"{"id":"r1","parentId":"p2","timestamp":"2026-09-30T00:00:00Z","type":"custom"}"#)
        // Written in another order, with space between: kept as it is.
        XCTAssertEqual(rewritten(#" { "type" : "message", "timestamp":"t" , "parentId": "p1", "id":"r1", "data":[1, {"a":null}] } "#),
                       #" { "type" : "message", "timestamp":"2026-09-30T00:00:00Z" , "parentId": "p2", "id":"r1", "data":[1, {"a":null}] } "#)
    }

    func testAnythingNotPlainIsLeftToTheParser() {
        for (text, why) in [
            (#"{"id":"r2","parentId":"p1","timestamp":"t"}"#, "another record's id"),
            (#"{"id":"r1","timestamp":"t"}"#, "no parent"),
            (#"{"id":"r1","parentId":"p1"}"#, "no time"),
            (#"{"id":"r1","parentId":"p1","timestamp":"t","nativeState":{"queue":[]}}"#, "a run state the copy leaves out"),
            (#"{"i\"# + "u0064" + #"":"r1","parentId":"p1","timestamp":"t"}"#, "an escaped key"),
            (#"{"id":"r1","id":"r1","parentId":"p1","timestamp":"t"}"#, "a key written twice"),
            (#"{"id":"r\"# + "u0031" + #"","parentId":"p1","timestamp":"t"}"#, "an escaped id"),
            (#"{"id":"r1","parentId":7,"timestamp":"t"}"#, "a parent that is not a string"),
            (#"{"id":"r1","parentId":"p1","timestamp":"t"} {}"#, "more than one value"),
            (#"{"id":"r1","parentId":"p1","timestamp":"t","data":{"a":[1}}"#, "unbalanced"),
            (#"{"id":"r1","parentId":"p1","timestamp":"t","data":"a"#, "unfinished"),
            (#"["id","r1"]"#, "not an object"),
        ] {
            XCTAssertNil(rewritten(text), why)
        }
        // A bare value is passed over, not checked: the fork's replay parses
        // every line it writes, and a record that is not JSON fails there, as
        // it failed when the copy parsed it.
        XCTAssertNotNil(rewritten(#"{"id":"r1","parentId":"p1","timestamp":"t","data":nullx}"#))
    }

    func testATimeThatIsNotUTF8IsLeftToTheParser() {
        var bytes = Data(#"{"id":"r1","parentId":"p1","timestamp":"t"#.utf8); bytes.append(0xFF); bytes.append(Data(#""}"#.utf8))
        XCTAssertNil(JournalEnvelope.rewritten(bytes, id: "r1", parentID: "p2", timestamp: "now"), "decoding would repair it unseen")
    }

    /// What the syntax check takes, the parser takes: for each line, a true
    /// answer means `JSON.parse` succeeds. A false one only means ask it.
    func testTheSyntaxCheckTakesNothingTheParserRefuses() {
        let control = "{\"a\":\"" + String(UnicodeScalar(1)) + "\"}"
        let lines = [
            #"{}"#, #"[]"#, #"{"a":1,"b":[true,false,null],"c":{"d":"e"}}"#, #" {"a" : [ 1 , 2 ] } "#, #"{"a":1,}"#, #"[1,2,]"#,
            #"{"a":-0.5,"b":123456789012345,"c":0}"#, #"{"a":"tab\tnew\nquote\"slash\/back\\"}"#, #"{"a":1}{"#, #"{"a":01}"#, #"{"a":1.}"#,
            #"{"a":1e5}"#, #"{"a":1234567890123456}"#, #"{"a":"é"}"#, #"{"a":"\"# + "u00e9" + #""}"#, #"{"a":fals}"#, #"{"a":nul}"#,
            #"{"a":"x"#, #"{"a" 1}"#, #"{,}"#, #"[,]"#, #"{"a":1,,"b":2}"#, #"{"a":[1,2}"#, #""plain""#, #"-"#, #"{"a":-}"#,
            #"{"a":"\x"}"#, control, "", " ", #"{"a":1} x"#, #"{"a":{"b":{"c":[[[[]]]]}}}"#,
        ]
        for text in lines {
            let line = Data(text.utf8)
            if JSONSyntax.plainlyValid(line) { XCTAssertNoThrow(try JSON.parse(line), "taken, so the parser takes it: \(text)") }
        }
        XCTAssertTrue(JSONSyntax.plainlyValid(Data(#"{"customType":"pi-app.native.state.v1","data":{"active":false,"queue":[]},"id":"s","parentId":"p","timestamp":"t","type":"custom"}"#.utf8)))
        for text in [#"{"a":fals}"#, #"{"a":1e5}"#, #"{"a":"é"}"#, #"{"a":01}"#, #"{"a":1234567890123456}"#, control] {
            XCTAssertFalse(JSONSyntax.plainlyValid(Data(text.utf8)), "left to the parser: \(text)")
        }
    }

    /// A run-state record a fork leaves out is still checked: a malformed one,
    /// which the chat's own open never reads once a later one supersedes it,
    /// fails the fork, as it did when the fork parsed every record.
    func testAMalformedRecordTheForkLeavesOutStillFailsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), state = root.appendingPathComponent("state"), path = state.appendingPathComponent("damaged.jsonl")
        do {
            let journal = try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: true)
            try journal.append(["type": "message", "message": ["role": "user", "content": "a question"]], id: "q")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": "an answer"]], id: "a")
            let tail = try XCTUnwrap(journal.head)
            let file = try FileHandle(forWritingTo: path); try file.seekToEnd()
            try file.write(contentsOf: Data((#"{"customType":"pi-app.native.state.v1","data":{"active":fals},"id":"s1","parentId":""# + tail + #"","timestamp":"t","type":"custom"}"# + "\n").utf8))
            try file.close()
        }
        do {
            let journal = try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: false)
            try journal.append(["type": "custom", "customType": "pi-app.native.state.v1", "data": ["active": false, "queue": [], "steering": [], "commands": [], "queuePaused": false]], id: "s2")
        }
        let chat = try AgentSession(id: "damaged", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: Resources(cwd: root, home: root),
                                    client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
        do { _ = try await chat.fork(to: "fork"); XCTFail("A malformed record fails the fork") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("fork_fork.jsonl").path), "and leaves no fork")
        await chat.close()
    }

    // MARK: What a fork's journal holds

    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], resume: String? = nil) throws -> AgentSession {
            try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                             client: ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume, autoCompaction: false)
        }
    }
    private func records(_ path: String) throws -> [JSON] {
        let reader = try JournalRecordReader(URL(fileURLWithPath: path)); _ = try reader.next()
        var all: [JSON] = []
        while let record = try reader.next() { all.append(record) }
        return all
    }
    private func send(_ session: AgentSession, _ id: String, _ text: String) async throws {
        _ = try await session.submit(Submission(commandID: id, turnID: id, text: text), steer: false)
        try await eventually { !(await session.isRunning) }
    }

    /// The source's records, each as a fork holds it, and in order: those a
    /// fork leaves out are gone, each other one is the same record with a new
    /// parent (the one before it in the fork) and a new time, and a queued
    /// edit's run state is left out of its branch record.
    func testAForkHoldsTheSourcesRecordsAsTheyWere() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile(), resources: Resources(cwd: root, home: root), traces: TraceStore())
        let source = try chat.session("source", replies: [
            toolReply(["first", "second"]), answer("after the tools"), answer("answer two"), answer("Summary of everything so far."),
            answer("the original answer"), answer("the edited answer"), answer("the last answer"),
        ])
        try await send(source, "u1", "please use the tools")
        try await send(source, "u2", "question two")
        try await source.compact(commandID: "compact")
        try await eventually { !(await source.isRunning) }
        try await send(source, "u3", "the original question")
        _ = try await source.edit(fromMessageID: "u3", input: Submission(commandID: "u3b", turnID: "u3b", text: "the edited question"))
        try await eventually { !(await source.isRunning) }
        try await send(source, "u4", "the last question")
        // A record written by hand in another order and with an escape in its
        // content: copied as it is, not normalized.
        let snapshot = await source.snapshot()
        let sourcePath = try XCTUnwrap(snapshot["path"].text)
        await source.close()
        do {
            let journal = try SessionJournal(url: URL(fileURLWithPath: sourcePath), id: "source", cwd: root, binding: chat.profile.binding, create: false)
            let tail = try XCTUnwrap(journal.head)
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: sourcePath)); try file.seekToEnd()
            try file.write(contentsOf: Data((#"{"type":"custom","customType":"fixture.note","data":{"text":"a \"note\"\n"},"timestamp":"2026-01-01T00:00:00Z","parentId":""# + tail + #"","id":"note-1"}"# + "\n").utf8))
            try file.close()
        }
        let reopened = try chat.session("source", resume: sourcePath)
        let result = try await reopened.fork(to: "fork")
        let forkPath = try XCTUnwrap(result["path"].text)
        await reopened.close()

        let left: Set<String> = [JournalRecordKind.marker, JournalRecordKind.state, JournalRecordKind.sideOrigin, JournalRecordKind.forkOrigin, JournalRecordKind.contextRecovery, SessionSpend.recordType]
        let expected = try records(sourcePath).filter { !left.contains($0["customType"].text ?? "") }
        let copied = try records(forkPath)
        // The fork's own marker first, and its context, origin, spend and run state last.
        XCTAssertEqual(copied.first?["customType"].text, JournalRecordKind.marker)
        XCTAssertEqual(copied.suffix(4).map { $0["customType"].text ?? "" }, [JournalRecordKind.context, JournalRecordKind.forkOrigin, SessionSpend.recordType, JournalRecordKind.state])
        let body = Array(copied.dropFirst().dropLast(4))
        XCTAssertEqual(body.count, expected.count)
        var parent = copied.first?["id"].text
        for (made, was) in zip(body, expected) {
            XCTAssertEqual(made.removing(["parentId", "timestamp"]), was.removing(["parentId", "timestamp", "nativeState"]), "record \(was["id"].text ?? "")")
            XCTAssertEqual(made["parentId"].text, parent, "each record's parent is the one before it")
            XCTAssertNotNil(made["timestamp"].text)
            parent = made["id"].text
        }
        XCTAssertTrue(expected.contains { $0["type"].text == "branch" }, "the edit's branch record is copied")
        // The hand-written record keeps its bytes: its key order and escapes.
        let text = try String(contentsOfFile: forkPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"{"type":"custom","customType":"fixture.note","data":{"text":"a \"note\"\n"},"timestamp":""#), "copied as written")
    }
}
