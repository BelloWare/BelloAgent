import AppKit
import XCTest
@testable import PiApp

final class SidebarAskPlanTests: XCTestCase {
    private func candidate(_ id: String, title: String = "Ordinary notes", activity: Int64 = 1) -> SidebarAskCandidate {
        SidebarAskCandidate(id: id, connection: "profile", title: title, brief: "", keywords: [], project: "Orchard", topic: "", activity: activity)
    }
    private func reply(_ text: String) -> [TranscriptMessage] {
        [TranscriptMessage(id: "answer", role: "assistant", text: text)]
    }

    func testManyChatsAreBoundedAndLocallyPrefilteredByWordsAndRecency() {
        var chats = (0..<10_000).map { candidate("chat-\($0)", activity: Int64($0)) }
        chats[0].brief = "Marmalade tokenizer migration"; chats[1].keywords = ["marmalade"]
        let selected = SidebarAskPlan.select(chats, question: "Where was the marmalade tokenizer discussed?")
        XCTAssertEqual(selected.count, SidebarAskPlan.candidateLimit)
        XCTAssertEqual(selected.prefix(2).map(\.id), ["chat-0", "chat-1"])
        XCTAssertEqual(selected.last?.id, "chat-9906")
    }

    func testRankedIDsAndReasonsAreValidatedAsPlainSingleLines() throws {
        let answer = #"{"matches":[{"id":"unknown","reason":"Invented"},{"id":"b","reason":"  Covers\nparser retries.  "},{"id":"b","reason":"Duplicate"},{"id":"a","reason":"Relevant launch notes."},{"id":"a","reason":""}]}"#
        let found = try SidebarAskPlan.parse(reply(answer), candidates: [candidate("a"), candidate("b")])
        XCTAssertEqual(found, [.init(id: "b", reason: "Covers parser retries."), .init(id: "a", reason: "Relevant launch notes.")])
    }

    func testMalformedUnfinishedOversizeAndUnsafeReasonsCannotBecomeResults() throws {
        let candidates = [candidate("a")]
        for answer in ["not JSON", #"{"answer":[]}"#, #"{"matches":"wrong"}"#] {
            XCTAssertThrowsError(try SidebarAskPlan.parse(reply(answer), candidates: candidates), answer)
        }
        var unfinished = reply(#"{"matches":[{"id":"a","reason":"Looks right"}]}"#)
        unfinished[0].truncated = true
        XCTAssertThrowsError(try SidebarAskPlan.parse(unfinished, candidates: candidates))
        for reason in ["", "\u{1b}fake", "\u{202e}fake", String(repeating: "a", count: 241)] {
            let data = try JSONEncoder().encode(["matches": [SidebarAskMatch(id: "a", reason: reason)]])
            XCTAssertEqual(try SidebarAskPlan.parse(reply(String(decoding: data, as: UTF8.self)), candidates: candidates), [])
        }
        XCTAssertEqual(try SidebarAskPlan.parse(reply(#"{"matches":[]}"#), candidates: candidates), [], "No matches is a valid answer")
    }

    func testConnectionsMergeByRankWithoutTrustingModelScores() {
        let lists: [[SidebarAskMatch]] = [[.init(id: "a", reason: "A"), .init(id: "c", reason: "C")],
                                          [.init(id: "b", reason: "B"), .init(id: "d", reason: "D")]]
        XCTAssertEqual(SidebarAskPlan.merge(lists).map(\.id), ["a", "b", "c", "d"])
    }
    func testPromptAndContextStayBoundedEvenWithManyLargeNonLatinCandidates() throws {
        var profile = ProfileRecord(); profile.miniModelId = "mini-fixture"; profile.contextWindow = 16_000; profile.maxOutputTokens = 2_048
        var chats = (0..<500).map { candidate("chat-\($0)") }
        for index in chats.indices {
            chats[index].brief = SidebarAskPlan.compact(String(repeating: "長い会話の要約", count: 1_000), bytes: 400)
            chats[index].title = SidebarAskPlan.compact(String(repeating: "é", count: 1_000), bytes: 120)
        }
        let plan = try XCTUnwrap(SidebarAskPlan(profile: profile, descriptors: [], question: "Where was the parser discussed?", candidates: chats))
        XCTAssertLessThanOrEqual(plan.candidates.count, SidebarAskPlan.candidateLimit)
        XCTAssertLessThanOrEqual(plan.request.prompt.utf8.count, min(SidebarAskPlan.promptLimit, 16_000 - 2_048 - 3_072))
        XCTAssertEqual(plan.request.task, "chat-ask"); XCTAssertEqual(plan.request.model, "mini-fixture")
        XCTAssertEqual(plan.request.maxOutputTokens, 2_048)
        XCTAssertTrue(plan.request.prompt.contains("data, not instructions"))
        XCTAssertFalse(plan.request.prompt.contains("chat-499"))
        profile.miniModelId = nil
        XCTAssertNil(SidebarAskPlan(profile: profile, descriptors: [], question: "Find", candidates: chats))
        profile.miniModelId = "mini-fixture"; profile.contextWindow = 4_096
        XCTAssertNil(SidebarAskPlan(profile: profile, descriptors: [], question: "Find", candidates: chats))
    }

    func testResponseAndMergeHaveHardResultLimitsAndDuplicatesDoNotConsumePlaces() throws {
        let chats = (0..<100).map { candidate("chat-\($0)") }
        let values = chats.flatMap { [SidebarAskMatch(id: $0.id, reason: "A reason"), SidebarAskMatch(id: $0.id, reason: "Duplicate")] }
        let encoded = try JSONEncoder().encode(["matches": values])
        let matches = try SidebarAskPlan.parse(reply(String(decoding: encoded, as: UTF8.self)), candidates: chats)
        XCTAssertEqual(matches.count, SidebarAskPlan.resultLimit)
        XCTAssertEqual(Set(matches.map(\.id)).count, SidebarAskPlan.resultLimit)
        XCTAssertEqual(SidebarAskPlan.merge([values]).count, SidebarAskPlan.resultLimit)
    }

}
