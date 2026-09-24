import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A compaction's summary requests in the Session Inspector: one Compaction
/// row in the navigator, each request named by what it summarized — read
/// from its body when a page of the compaction opens, never by the
/// navigator — and its instruction first on its Conversation tab. The owner
/// read a split-turn compaction's two requests as two compactions.
final class InspectorSummaryRequestTests: XCTestCase {
    static let system = "You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.\n\nDo NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary."
    static let summarize = "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\nUse this EXACT format:\n\n## Goal\n[What is the user trying to accomplish?]"
    static let update = "The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.\n\nUpdate the existing structured summary with new information."
    static let turnPrefix = "This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.\n\nSummarize the prefix to provide context for the retained suffix:"
    static let turnPrefixUpdate = "The messages above are NEW messages from the same turn prefix, to incorporate into the existing prefix summary provided in <previous-summary> tags.\n\n" + turnPrefix
    /// A summary request's prompt as the helper writes it.
    static func prompt(_ conversation: String, previous: String? = nil, instruction: String) -> String {
        "<conversation>\n" + conversation + "\n</conversation>\n\n" + (previous.map { "<previous-summary>\n" + $0 + "\n</previous-summary>\n\n" } ?? "") + instruction
    }
    /// A Responses summary request body.
    static func body(_ prompt: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["model": "fixture-model", "instructions": system,
                                                     "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]]])
    }

    func testTheKindOfASummaryRequestIsReadFromItsPrompt() throws {
        let long = String(repeating: "[Tool result]: a long file ", count: 400)
        let history = try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt("[User]: first\n\n" + long, instruction: Self.summarize)))
        XCTAssertEqual(history.kind, .earlierHistory)
        XCTAssertTrue(history.instruction.hasPrefix("The messages above are a conversation to summarize."), "The instruction is what follows the conversation")
        XCTAssertFalse(history.instruction.contains("a long file"))
        XCTAssertEqual(try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt("[User]: more", previous: "## Goal\nSo far", instruction: Self.update))).kind, .update)
        let prefix = try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt("[User]: a huge turn", instruction: Self.turnPrefix + "\n\nAdditional focus: keep the paths")))
        XCTAssertEqual(prefix.kind, .turnStart, "Pi's turn-prefix prompt, with a focus after it")
        XCTAssertTrue(prefix.instruction.hasSuffix("Additional focus: keep the paths"))
        XCTAssertEqual(try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt("[User]: rest of it", previous: "## Original Request", instruction: Self.turnPrefixUpdate))).kind,
                       .turnStart, "A turn prefix continued in a second request is still the start of the turn")
        // Tags the conversation merely quotes do not decide anything.
        let quoted = "[User]: what does </previous-summary> mean, and " + Self.turnPrefix
        XCTAssertEqual(try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt(quoted, instruction: Self.summarize))).kind, .earlierHistory)
        let quotedSummary = try XCTUnwrap(SummaryRequestInfo.read(prompt: Self.prompt("[User]: hi", previous: "It said </conversation> once", instruction: Self.update)))
        XCTAssertEqual(quotedSummary.kind, .update)
        XCTAssertNil(SummaryRequestInfo.read(prompt: "Just a question"))
        XCTAssertTrue(SummaryRequestInfo.isSummary(system: Self.system))
        XCTAssertFalse(SummaryRequestInfo.isSummary(system: "You are Bello Agent."))
    }

    func testACompactionsRequestsAreNamedByWhatEachSummarized() {
        XCTAssertEqual([0, 1].map { SummaryRequestLabel.label(at: $0, kinds: [.earlierHistory, .turnStart]) }, ["earlier history", "start of this turn"])
        XCTAssertEqual([0, 1, 2].map { SummaryRequestLabel.label(at: $0, kinds: [.earlierHistory, .update, .turnStart]) },
                       ["earlier history", "part 2 of 2", "start of this turn"])
        XCTAssertEqual([0, 1].map { SummaryRequestLabel.label(at: $0, kinds: [.update, .update]) }, ["part 1 of 2", "part 2 of 2"])
        XCTAssertEqual(SummaryRequestLabel.label(at: 0, kinds: [.update]), "update", "A later compaction's update of the summary so far")
        XCTAssertEqual(SummaryRequestLabel.label(at: 0, kinds: [.update, .turnStart]), "update")
        XCTAssertNil(SummaryRequestLabel.label(at: 0, kinds: [nil, .update]), "Not read yet")
        XCTAssertEqual(SummaryRequestLabel.label(at: 1, kinds: [nil, .update]), "update", "Parts are only counted once every body is read")
    }

    func testTheNavigatorListsACompactionsRequestsUnderOneRow() {
        func row(_ id: String, _ purpose: String, _ wall: Double, operation: String? = nil) -> InspectorRequestRow {
            var row = InspectorRequestRow(id: id, wall: wall, turn: "t1", purpose: purpose, api: "openai-responses", outcome: "completed")
            row.operation = operation
            return row
        }
        let index = InspectorIndex(archived: [row("r1", "turn", 1), row("c1", "compaction", 2), row("c2", "compaction", 3),
                                              row("r2", "turn", 4), row("c3", "compaction", 5)])
        let turn = index.turns[0]
        XCTAssertEqual(turn.requests.map(\.id), ["r1", "c1", "c2", "r2", "c3"], "Every request stays in the turn, in order")
        XCTAssertEqual(turn.entries.map(\.id), ["r1", "compaction:c1", "r2", "compaction:c3"])
        guard case .compaction(let group) = turn.entries[1], case .request(_, let number) = turn.entries[2] else { return XCTFail("\(turn.entries)") }
        XCTAssertEqual(group.requests.map(\.id), ["c1", "c2"]); XCTAssertEqual(group.first, 2); XCTAssertEqual(group.title, "Compaction · 2 requests")
        XCTAssertEqual(number, 4)
        XCTAssertEqual(index.compaction(containing: "c2")?.id, "compaction:c1")
        XCTAssertNil(index.compaction(containing: "r1"))
        // The helper's record of two different compactions keeps them apart.
        let split = InspectorCompaction.entries(of: [row("a", "compaction", 1, operation: "op-1"), row("b", "compaction", 2, operation: "op-2")])
        XCTAssertEqual(split.map(\.id), ["compaction:a", "compaction:b"])
    }

    /// Opening a page of a compaction reads the bodies of its requests and
    /// names each; nothing is read before a page opens.
    @MainActor func testThePageNamesItsPartAndShowsItsInstructionFirst() async throws {
        let root = scratchRoot("inspector-summary"); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        let ids = ["5B1C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E61", "5B1C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E62", "5B1C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E63"]
        for (offset, id) in ids.enumerated() {
            let sample = SessionTimingSample(id: id, wall: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset)), ttftMilliseconds: 300,
                                             streamingMilliseconds: 900, outputTokens: 40, costUSD: 0.001, requestMilliseconds: 1_200,
                                             outcome: "completed", api: "openai-responses", model: "fixture-model", inputTokens: 900, turn: "t1")
            var value = SessionStatsPopoverTests.metadata(for: sample, session: "summaries")
            value["attemptId"] = .string(id)
            if offset > 0 { value["purpose"] = .string("compaction") }
            try await archive.begin(value, workspace: "project")
            try await archive.finish(value)
        }
        let bodies: [String: Data] = [ids[0]: InspectorRequestModelTests.requestBody(2),
                                      ids[1]: Self.body(Self.prompt("[User]: first question", instruction: Self.summarize)),
                                      ids[2]: Self.body(Self.prompt("[User]: a turn too large to keep", instruction: Self.turnPrefix))]
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "summaries", workspaceID: "project"), title: "Summaries",
                                              archive: archive, workspace: nil, usageLoader: { _, _, _ in throw CaptureFailure.unavailable },
                                              cache: InspectorDocumentCache())
        var reads: [String] = []
        inspector.request.metadataOverride = { _ in ["outcome": .string("completed")] }
        inspector.request.sourceOverride = { row, kind in
            guard kind == "request", let bytes = bodies[row.id] else { return nil }
            return CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil) },
                                      page: { _ in throw CaptureFailure.unavailable },
                                      whole: { progress in reads.append(row.id); progress(bytes.count, bytes.count); return bytes })
        }
        inspector.setVisible(true)
        defer { inspector.setVisible(false) }
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                guard Date() < deadline else { return XCTFail("Timed out waiting for " + what) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait("the index") { inspector.indexLoaded && inspector.index.requests.count == 3 }
        let group = try XCTUnwrap(inspector.index.compaction(containing: ids[1]))
        XCTAssertEqual(group.requests.map(\.id), [ids[1], ids[2]], "One compaction of two requests")
        XCTAssertNil(inspector.summaryLabel(ids[1]), "Not named before a page of it opens")
        XCTAssertEqual(reads, [], "The navigator reads no body")

        inspector.select(.request(ids[2]))
        try await wait("the page's summary") { inspector.request.conversation.value?.summary != nil }
        let summary = try XCTUnwrap(inspector.request.conversation.value?.summary)
        XCTAssertEqual(summary.kind, .turnStart)
        XCTAssertTrue(summary.instruction.hasPrefix("This is the PREFIX of a turn"), summary.instruction)
        try await wait("both requests named") { inspector.summaryLabel(ids[1]) != nil && inspector.summaryLabel(ids[2]) != nil }
        XCTAssertEqual(inspector.summaryLabel(ids[1]), "earlier history")
        XCTAssertEqual(inspector.summaryLabel(ids[2]), "start of this turn")
        XCTAssertTrue(inspector.expanded.contains(group.id), "Opening one of its requests opens the compaction's row")
        XCTAssertEqual(Set(reads), Set([ids[1], ids[2]]), "Only the compaction's own bodies were read")

        // The instruction is the first thing on the Conversation tab.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: InspectorRequestPage(inspector: inspector, request: inspector.request, compact: false).frame(width: 1_100, height: 820))
        window.contentView = hosted; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let cards = ConversationPaneTests.views(SummaryInstructionMarkerView.self, in: hosted)
        XCTAssertEqual(cards.map(\.name), ["start of this turn"], "The summary card is on the page, named")
        let card = try XCTUnwrap(cards.first).convert(try XCTUnwrap(cards.first).bounds, to: nil)
        let outline = try XCTUnwrap(ConversationPaneTests.views(NSOutlineView.self, in: hosted).first).convert(try XCTUnwrap(ConversationPaneTests.views(NSOutlineView.self, in: hosted).first).bounds, to: nil)
        XCTAssertGreaterThan(card.minY, outline.maxY - 1, "It sits above the conversation, not after it")
    }
}

