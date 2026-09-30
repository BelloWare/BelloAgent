import XCTest
@testable import FileFinder

/// How fast finding is, on a project of 100,000 files and one of 500,000,
/// and one of 100,000 named in many scripts: making the index, and each
/// keystroke of a few queries typed a character at a time. Opt-in (`FINDER_PERF=1`), and for numbers that mean anything,
/// a release build (`swift test -c release -Xswiftc -enable-testing`).
final class FileFinderPerformanceTests: XCTestCase {
    private func corpus(_ count: Int, scripts: Bool = false) -> [String] {
        var generator = SplitMix(seed: 11)
        let folders = ["Sources", "Tests", "apps", "packages", "node_modules", "vendor", "docs", "build", "lib", "src", "internal", "Views",
                       "Models", "Services", "Components", "utils", "fixtures", "generated", "platform", "Resources"]
        let stems = ["Main", "App", "View", "Model", "Controller", "Service", "Manager", "Helper", "Store", "Client", "Parser", "Reader",
                     "Writer", "Cache", "Index", "Table", "Panel", "Sheet", "Window", "Session", "Transcript", "File", "Tab", "Git"]
            + (scripts ? ["Café", "Résumé", "Überblick", "Задача", "文档说明", "한글문서", "日本語", "Cafe\u{301}"] : [])
        let kinds = [".swift", ".ts", ".tsx", ".js", ".json", ".md", ".py", ".c", ".h", ".m"]
        func pick(_ values: [String]) -> String { values[Int(generator.next() % UInt64(values.count))] }
        return (0..<count).map { number in
            let depth = 1 + Int(generator.next() % 6)
            let folder = (0..<depth).map { _ in pick(folders) + (generator.next() % 3 == 0 ? String(generator.next() % 40) : "") }.joined(separator: "/")
            return folder + "/" + pick(stems) + pick(stems) + (generator.next() % 4 == 0 ? String(number % 997) : "") + pick(kinds)
        }
    }

    private func measure(_ count: Int, scripts: Bool = false) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FINDER_PERF"] == "1", "set FINDER_PERF=1 to measure")
        let paths = corpus(count, scripts: scripts)
        let clock = ContinuousClock()
        let started = clock.now
        let made = index(paths)
        let foreign = (0..<made.count).filter { !made.ascii[$0] }.count
        let building = clock.now - started
        var keystrokes: [Double] = []
        for query in ["transcriptview", "sources/main", "gitpanel", "ftv", "readme", "controller.swift", "zzzz"] + (scripts ? ["café", "文档", "задача"] : []) {
            for length in 1...query.count {
                let typed = String(query.prefix(length))
                let start = clock.now
                _ = FileFinderSearch.search(FileFinderQuery(typed), in: made)
                let elapsed = clock.now - start
                keystrokes.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
            }
        }
        keystrokes.sort()
        let median = keystrokes[keystrokes.count / 2], p95 = keystrokes[Int(Double(keystrokes.count) * 0.95)], worst = keystrokes.last ?? 0
        let bytes = made.bytes.count + made.folded.count + made.masks.count * 8 + made.ends.count * 4 * 3 + made.count * 3
        print(String(format: "FINDER-PERF %d files (%d not ASCII): index made in %.0f ms, %.1f MB; per keystroke median %.2f ms, p95 %.2f ms, worst %.2f ms (%d keystrokes)",
                     count, foreign, Double(building.components.attoseconds) / 1e15 + Double(building.components.seconds) * 1_000,
                     Double(bytes) / 1_048_576, median, p95, worst, keystrokes.count))
    }

    func testOneHundredThousandFiles() throws { try measure(100_000) }
    func testHalfAMillionFiles() throws { try measure(500_000) }
    func testOneHundredThousandFilesInManyScripts() throws { try measure(100_000, scripts: true) }
}
