import XCTest
import AppKit
@testable import PiApp

/// No transcript row needs the SwiftUI host any more: a large, realistic page
/// planned with every presentation and every message kind the planner makes
/// (and the rows other planners hand over directly) draws every item natively.
final class TranscriptNativeEverywhereTests: XCTestCase {
    typealias P = TranscriptNativeRowParityTests
    typealias W = TranscriptNativeWorkParityTests

    /// A page of every kind of row: a chronological response with every part,
    /// a legacy reply, a task's aggregate, replies outside any task, and every
    /// marker row, finished and still running.
    static func messages(running: Bool) -> (messages: [TranscriptMessage], lifecycle: TaskPresentationProjection) {
        let card = W.tool("c1", "bash", input: W.json(["command": "swift test"]), output: "ok", duration: 900)
        let read = W.tool("r1", "read", input: W.json(["path": "README.md"]), output: "# Fixture", duration: 40, path: "README.md")
        let many = (1...9).map { W.tool("m\($0)", "bash", input: W.json(["command": "echo \($0)"]), output: "\($0)", duration: 30) }
        var timeline = ResponseTimeline()
        timeline.segments = [P.segment("s-think", "reasoningSummary", "Planning the change."),
                             P.segment("s-args", "toolArguments", W.json(["command": "swift test"]), name: "bash", call: "c1"),
                             P.segment("s-call", "toolCall", "", call: "c1"),
                             P.segment("s-opaque", "opaque", "provider item"),
                             P.segment("s-status", "status", "Retrying"),
                             P.segment("s-text", "text", "The tests **pass**."),
                             P.segment("s-refusal", "refusal", "I won't do that part.")]
        timeline.terminal = running ? nil : "completed"
        var rows: [TranscriptMessage] = []
        func message(_ id: String, _ role: String, _ text: String, root: String? = nil) -> TranscriptMessage {
            var message = TranscriptMessage(id: id, role: role, text: text)
            message.at = 1_790_000_000_000; message.taskRootID = root; message.taskExecutionID = root.map { "e-" + $0 }
            message.state = "complete"
            return message
        }
        // A task with a chronological response.
        rows.append(message("u1", "user", "Run the tests.", root: "u1"))
        var chronological = message("a1", "assistant", "The tests **pass**.", root: "u1")
        chronological.responseTimeline = timeline; chronological.tools = [card]; chronological.thinking = "Planning the change."
        chronological.accounting = P.totals(); chronological.modelMs = 4_200
        if running { chronological.state = "streaming" }
        rows.append(chronological)
        // A task with a legacy reply and its tool's result.
        rows.append(message("u2", "user", "Read it.", root: "u2"))
        var legacy = message("a2", "assistant", "It says hello.", root: "u2")
        legacy.thinking = "Reading."; legacy.tools = [read] + many; legacy.accounting = P.totals(); legacy.stopReason = "length"
        rows.append(legacy)
        var result = message("tr1", "tool", "a result nobody called", root: "u2"); result.toolCallID = "unknown"
        rows.append(result)
        // A finished task whose work folds behind its line above its answer.
        rows.append(message("u3", "user", "Tidy up.", root: "u3"))
        var working = message("a5", "assistant", "", root: "u3"); working.tools = [read]
        rows.append(working)
        rows.append(message("a6", "assistant", "Tidied.", root: "u3"))
        rows.append(message("u4", "user", "Thanks.", root: "u4"))
        // Replies outside any task.
        var loose = message("a3", "assistant", "A reply outside any task."); loose.accounting = P.totals()
        rows.append(loose)
        var looseWork = message("a4", "assistant", ""); looseWork.tools = [read]; looseWork.thinking = "Hm."
        rows.append(looseWork)
        rows.append(message("t9", "tool", "A tool's words outside any task."))
        var system = message("sys", "system", "Model switched."); rows.append(system)
        system.id = "sys2"; system.accounting = P.totals(); rows.append(system)
        // Every marker row.
        for (kind, text) in [("compaction", "## Kept"), ("branch", ""), ("versionBanner", "Earlier version"), ("failure", "It failed."),
                             ("notice", "Retrying in 3 s"), ("toolResult", "result text"), ("requestInfo", "")] {
            var marker = message("k-" + kind, kind == "toolResult" ? "tool" : kind == "requestInfo" ? "assistant" : "system", text)
            marker.kind = kind; marker.detail = "Detail of \(kind)"
            if kind == "requestInfo" { marker.accounting = P.totals() }
            rows.append(marker)
        }
        var limit = message("k-cost", "system", "Cost limit reached."); limit.kind = "failure"; limit.failureCode = SessionDisplay.costLimitCode
        rows.append(limit)
        var execution = message("k-exec", "assistant", "Local execution"); execution.kind = "execution"
        var stages = ResponseTimeline(); stages.segments = [P.segment("x1", "text", "Compacted.")]
        execution.responseTimeline = stages
        rows.append(execution)
        var done = TaskPresentationRecord(rootID: "u2", executionID: "e-u2", startedAt: 10)
        done.outcome = "completed"; done.phase = "terminal"; done.endedAt = 20; done.lastSourceID = "tr1"; done.replies = 1
        var first = TaskPresentationRecord(rootID: "u1", executionID: "e-u1", startedAt: 1)
        first.lastSourceID = "a1"; first.replies = 1
        if running { first.phase = "model" } else { first.outcome = "completed"; first.phase = "terminal"; first.endedAt = 9 }
        var tidy = TaskPresentationRecord(rootID: "u3", executionID: "e-u3", startedAt: 30)
        tidy.outcome = "completed"; tidy.phase = "terminal"; tidy.endedAt = 40; tidy.lastSourceID = "a6"; tidy.replies = 2
        let projection = TaskPresentationProjection(sessionID: "s", epoch: "e", timeline: "root", sequence: 1, sourceRevision: "1",
                                                    active: running ? first : nil, recent: running ? [done, tidy] : [first, done, tidy])
        return (rows, projection)
    }

    /// Rows other planners hand over as they are: a reply block, a body that
    /// is not the assistant's, a summary without its turn, an empty block.
    static var handMade: [TranscriptItem] {
        var reply = P.block("reply:x", .reply, message: P.reply("x", text: "Words.", accounting: P.totals()))
        reply.turn = TranscriptNativeTurnParityTests.turn()
        let summary = P.block("summary:none", .summary)
        let empty = P.block("empty", .reply)
        // Messages standing as rows of their own: a reply outside any block,
        // and messages of a kind no row knows, which read as plain messages.
        var custom: [TranscriptItem] = []
        for role in ["assistant", "user", "system", "tool"] {
            var message = TranscriptMessage(id: "custom-" + role, role: role, text: "A \(role) message of its own kind.")
            message.kind = "custom"
            custom.append(.message(message))
        }
        let alone = TranscriptItem.message(TranscriptMessage(id: "alone", role: "assistant", text: "A reply on its own."))
        return [.block(reply), .block(summary), .block(empty), alone] + custom
    }

    @MainActor func testEveryPlannedRowIsDrawnNatively() throws {
        XCTAssertTrue(TranscriptRowRenderer.native)
        var items: [TranscriptItem] = Self.handMade
        for running in [false, true] {
            let (messages, lifecycle) = Self.messages(running: running)
            for display in TranscriptDisplayMode.allCases {
                items += TaskTranscriptPlan.items(messages, lifecycle: lifecycle, display: display)
            }
        }
        var kinds = Set<String>()
        var hosted: [String] = []
        for item in items {
            let label: String
            switch item {
            case .message(let message): label = "message \(message.role)/\(message.kind ?? "-")"
            case .block(let block): label = "block \(block.presentation)/\(block.part?.part.kind ?? "-")/\(block.message?.role ?? "-")"
            }
            kinds.insert(label)
            let inputs = TranscriptRowInputs(item: item, fresh: false, actions: TranscriptActions(), width: 600, environment: TranscriptRowEnvironment())
            let content = TranscriptRowRenderer.content(for: item, inputs: inputs)
            // Drawn by no native row: through SwiftUI's reference row, or as nothing.
            if content is TranscriptHostedRowContent || content is TranscriptNativeEmptyRow { hosted.append(label + " (" + item.id + ")") }
        }
        // The page really holds every presentation and kind.
        for presentation in ["turnFold", "response", "timeline", "work", "body", "summary", "reply"] {
            XCTAssertTrue(kinds.contains { $0.hasPrefix("block \(presentation)/") }, "the page has a \(presentation) block: \(kinds.sorted())")
        }
        for kind in ["compaction", "branch", "versionBanner", "failure", "notice", "toolResult", "requestInfo", "execution"] {
            XCTAssertTrue(kinds.contains { $0.hasSuffix("/\(kind)") }, "the page has a \(kind) row")
        }
        XCTAssertTrue(hosted.isEmpty, "drawn by no native row: \(Set(hosted).sorted())")
    }

    /// The transcript is AppKit through and through: no source file under
    /// apps/macos/PiApp/Transcript imports SwiftUI, in any form an import
    /// takes (`import`, `internal import`, `@_spi(…) import`, `import struct
    /// SwiftUI.…`), or names it. (Without an import, and with nothing in the
    /// app re-exporting it, no SwiftUI type is in scope there.)
    func testNoTranscriptFileUsesSwiftUI() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PiApp/Transcript")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 40, "the transcript's sources are where this test looks")
        // Comments and string literals go first, as the compiler reads the
        // file, so neither a comment between the words of an import nor one
        // naming SwiftUI decides anything; then the words of an import may
        // stand on separate lines.
        let importing = #"\bimport\s+((struct|class|enum|protocol|typealias|func|var|let)\s+)?SwiftUI\b"#
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = Self.code(of: source)
            if code.range(of: importing, options: .regularExpression) != nil || code.contains("SwiftUI.") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "SwiftUI in Transcript/: \(offenders.sorted().joined(separator: ", "))")
        // Nothing in the app hands SwiftUI to every file of the module.
        let app = folder.deletingLastPathComponent()
        let all = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in all {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(source.range(of: #"@_exported\s+import\s+SwiftUI"#, options: .regularExpression), "\(file.lastPathComponent) re-exports SwiftUI")
        }
    }

    /// The guard reads code as the compiler does: an import behind or
    /// between comments counts, words in a comment or a string do not.
    func testTheGuardReadsCodeAsTheCompilerDoes() {
        let importing = #"\bimport\s+((struct|class|enum|protocol|typealias|func|var|let)\s+)?SwiftUI\b"#
        func imports(_ source: String) -> Bool { Self.code(of: source).range(of: importing, options: .regularExpression) != nil }
        XCTAssertTrue(imports("// /*\nimport SwiftUI\n// */\n"))
        XCTAssertTrue(imports("import /* UI */\n  SwiftUI\n"))
        XCTAssertTrue(imports("/* a /* nested */ comment */ internal import SwiftUI"))
        XCTAssertTrue(imports("let s = \"// not a comment\"\nimport SwiftUI"))
        XCTAssertTrue(imports("let r = #\"a \" quote\"#\nimport struct SwiftUI.Color"))
        XCTAssertTrue(imports("let s = #\"\\#\"#\"#\nimport SwiftUI"))
        XCTAssertFalse(imports("// import SwiftUI"))
        XCTAssertFalse(imports("/* import SwiftUI */"))
        XCTAssertFalse(imports("let s = \"import SwiftUI\""))
        XCTAssertFalse(imports("let s = \"\"\"\nimport SwiftUI\n\"\"\""))
    }

    /// `source` as the compiler reads its code: comments (line comments, and
    /// block comments, nested) and the contents of string literals (plain,
    /// multi-line and raw) left out.
    static func code(of source: String) -> String {
        let text = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        func at(_ offset: Int) -> Unicode.Scalar? { index + offset < text.count ? text[index + offset] : nil }
        while index < text.count {
            let scalar = text[index]
            if scalar == "/", at(1) == "/" {
                while index < text.count, text[index] != "\n" { index += 1 }
            } else if scalar == "/", at(1) == "*" {
                var depth = 0
                repeat {
                    if at(0) == "/", at(1) == "*" { depth += 1; index += 2 }
                    else if at(0) == "*", at(1) == "/" { depth -= 1; index += 2 }
                    else { index += 1 }
                } while depth > 0 && index < text.count
                out.append(" ")
            } else if scalar == "#" || scalar == "\"" {
                // A string literal: its hashes, then one or three quotes.
                var hashes = 0
                while at(hashes) == "#" { hashes += 1 }
                guard at(hashes) == "\"" else { out.append(scalar); index += 1; continue }
                let triple = at(hashes + 1) == "\"" && at(hashes + 2) == "\""
                index += hashes + (triple ? 3 : 1)
                let quotes = triple ? 3 : 1
                while index < text.count {
                    // An escape: a backslash and the literal's hashes, then the escaped character.
                    if text[index] == "\\", (0..<hashes).allSatisfy({ at(1 + $0) == "#" }) { index += 2 + hashes; continue }
                    if (0..<quotes).allSatisfy({ at($0) == "\"" }), (0..<hashes).allSatisfy({ at(quotes + $0) == "#" }) {
                        index += quotes + hashes; break
                    }
                    index += 1
                }
                out.append(contentsOf: "\"\"".unicodeScalars)
            } else {
                out.append(scalar); index += 1
            }
        }
        return String(out)
    }
}
