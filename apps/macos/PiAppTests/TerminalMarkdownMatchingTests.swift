import XCTest
@testable import PiApp

/// A reply that settles keeps its blocks' identities, and finding them costs
/// work that grows with its blocks, not with their square.
final class TerminalMarkdownMatchingTests: XCTestCase {
    /// The matching as it was: for each block, the first prior record whose
    /// identity is not yet given out that starts there, or holds its start in
    /// the same kind of container.
    private func reference(_ canonical: [StreamingMarkdownRecord], prior: [StreamingMarkdownRecord]) -> [MarkdownBlockIdentity] {
        func kind(_ block: MarkdownBlock) -> Int {
            switch block { case .paragraph: 0; case .heading: 1; case .code: 2; case .list: 3; case .quote: 4; case .table: 5 }
        }
        var used = Set<MarkdownBlockIdentity>()
        return canonical.map { value in
            let found = prior.first { !used.contains($0.id) &&
                ($0.id.sourceOffset == value.id.sourceOffset || ($0.range.contains(value.id.sourceOffset) && kind($0.block) == kind(value.block))) }
            var id = found?.id ?? value.id
            while !used.insert(id).inserted { id.component += 1 }
            return id
        }
    }
    private func record(_ offset: Int, _ range: Range<Int>, _ block: MarkdownBlock, component: Int = 0, generation: UInt64 = 7,
                        segment: Int = 0, path: [MarkdownChildStep] = []) -> StreamingMarkdownRecord {
        var id = MarkdownBlockIdentity(generation: generation, sourceOffset: offset, component: component, segment: segment)
        id.path = path
        return StreamingMarkdownRecord(id: id, range: range, block: block, provisional: true)
    }
    private func ids(_ canonical: [StreamingMarkdownRecord], prior: [StreamingMarkdownRecord]) -> [MarkdownBlockIdentity] {
        var visits = 0
        return StreamingMarkdownState.matched(canonical, prior: prior, visits: &visits).map(\.id)
    }
    private let paragraph = MarkdownBlock.paragraph(AttributedString("a")), code = MarkdownBlock.code(language: "swift", code: "x"),
                quote = MarkdownBlock.quote([])

    /// The cases where the order of the two kinds of match decides.
    func testTheFirstMatchingPriorRecordWinsInEachCase() {
        let cases: [(String, [StreamingMarkdownRecord], [StreamingMarkdownRecord])] = [
            ("a record holding the start comes before one starting there",
             [record(3, 0..<5, code), record(4, 5..<9, paragraph)], [record(4, 4..<9, code)]),
            ("one starting there comes before one holding the start",
             [record(4, 0..<2, paragraph), record(1, 2..<9, code)], [record(4, 4..<9, code)]),
            ("an exact start matches across kinds",
             [record(0, 0..<3, quote), record(3, 3..<6, paragraph)], [record(0, 0..<3, code), record(3, 3..<6, code)]),
            ("a used holder gives way to an eligible starter",
             [record(0, 0..<6, code), record(2, 6..<7, paragraph)], [record(0, 0..<2, code), record(2, 2..<7, code)]),
            ("duplicate identities", [record(1, 0..<2, paragraph), record(1, 2..<4, paragraph)], [record(1, 1..<3, paragraph), record(1, 3..<4, paragraph)]),
            ("empty ranges, gaps and shared ends",
             [record(0, 0..<0, paragraph), record(0, 0..<2, paragraph), record(5, 5..<5, code), record(5, 5..<8, code), record(9, 9..<12, quote)],
             [record(0, 0..<5, paragraph), record(5, 5..<9, code), record(8, 8..<10, quote), record(10, 10..<12, quote)]),
            ("decreasing blocks", [record(0, 0..<4, paragraph), record(4, 4..<8, paragraph)], [record(5, 5..<8, paragraph), record(1, 1..<5, paragraph)]),
            ("components, segments and paths",
             [record(2, 0..<4, code, component: 1, segment: 2, path: [.quoteChild(0)]), record(2, 4..<4, code, component: 2)],
             [record(2, 2..<5, code, component: 1), record(2, 5..<6, code, component: 2), record(3, 5..<6, paragraph)]),
            ("a bumped identity takes another record's", [record(0, 0..<1, paragraph), record(0, 1..<2, paragraph, component: 1)],
             [record(0, 0..<1, paragraph), record(0, 1..<2, quote, component: 0), record(1, 1..<2, quote)]),
        ]
        for (name, prior, canonical) in cases {
            XCTAssertEqual(ids(canonical, prior: prior), reference(canonical, prior: prior), name)
        }
    }

    /// Random prior readings and canonical readings, in order and out of it,
    /// match exactly as they did.
    func testRandomReadingsMatchAsTheyDid() {
        var generator = SystemRandomNumberGenerator()
        let blocks = [paragraph, code, quote]
        for round in 0..<4_000 {
            let inOrder = round % 2 == 0
            var prior: [StreamingMarkdownRecord] = [], at = 0
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                let start = inOrder ? at + Int.random(in: 0...2, using: &generator) : Int.random(in: 0...12, using: &generator)
                let end = start + Int.random(in: 0...3, using: &generator); at = end
                let offset = Int.random(in: 0...3, using: &generator) == 0 ? max(0, start - Int.random(in: 0...2, using: &generator)) : start
                prior.append(record(offset, start..<end, blocks.randomElement(using: &generator)!, component: Int.random(in: 0...1, using: &generator)))
            }
            var canonical: [StreamingMarkdownRecord] = [], offset = 0
            for _ in 0..<Int.random(in: 0...10, using: &generator) {
                offset = inOrder ? offset + Int.random(in: 0...3, using: &generator) : Int.random(in: 0...14, using: &generator)
                canonical.append(record(offset, offset..<offset + 1, blocks.randomElement(using: &generator)!, component: Int.random(in: 0...1, using: &generator)))
            }
            XCTAssertEqual(ids(canonical, prior: prior), reference(canonical, prior: prior), "round \(round): \(prior.map { ($0.id.sourceOffset, $0.range) }) / \(canonical.map(\.id.sourceOffset))")
        }
    }

    /// The review's measure: n paragraphs streamed, then the same text
    /// settled. The identities stay, the blocks read as a fresh reading, and
    /// the prior records looked at grow with n (they were n(n+1)/2).
    @MainActor func testSettlingAStreamedReplyLooksAtEachBlockAFewTimes() {
        for count in [120, 1_150, 4_096] {
            let state = StreamingMarkdownState()
            var source = ""
            for index in 0..<count {
                source += index == 0 ? "a" : "\n\na"
                _ = state.update(source, style: .prose, streaming: true, identity: "reply")
            }
            let streamed = state.records.map(\.id)
            XCTAssertEqual(streamed.count, count)
            let before = state.matchVisits
            let settled = state.update(source, style: .prose, streaming: false, identity: "reply")
            let visits = state.matchVisits - before
            XCTAssertEqual(settled.map(\.id), streamed, "\(count): every block keeps its identity")
            XCTAssertEqual(settled.map(\.block), StreamingMarkdownState().update(source, style: .prose, streaming: false).map(\.block), "\(count)")
            XCTAssertLessThanOrEqual(visits, 3 * count, "\(count) blocks looked at \(visits) prior records")
        }
    }
}
