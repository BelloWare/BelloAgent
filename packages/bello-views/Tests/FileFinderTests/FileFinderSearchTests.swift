import XCTest
@testable import FileFinder

/// Finding a file by part of its name: the query's characters in order, case
/// aside; a match in the name before one that needs the folders, a name that
/// is the query first of all, a start of a word or a run of characters over
/// scattered ones; where each character matched; ":N" a line; the best kept
/// the same across the chunks a large index is searched in.
final class FileFinderSearchTests: XCTestCase {
    private func found(_ query: String, in paths: [String], limit: Int = 50) -> [String] {
        FileFinderSearch.search(FileFinderQuery(query), in: index(paths), limit: limit).map(\.path)
    }
    /// The highlighted parts of the first match.
    private func highlighted(_ query: String, in path: String) -> [String] {
        guard let match = FileFinderSearch.search(FileFinderQuery(query), in: index([path])).first else { return [] }
        let bytes = Array(match.path.utf8)
        return match.highlights.map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    func testAQueryFindsItsCharactersInOrderCaseAside() {
        let paths = ["Sources/App/Main.swift", "Sources/Views/MainView.swift", "Tests/AppTests.swift", "README.md"]
        XCTAssertEqual(Set(found("main", in: paths)), ["Sources/App/Main.swift", "Sources/Views/MainView.swift"])
        XCTAssertEqual(found("MAIN", in: paths), found("main", in: paths))
        XCTAssertEqual(found("nmai", in: paths), [], "in order")
        XCTAssertEqual(found("readme", in: paths), ["README.md"])
        XCTAssertEqual(found("", in: paths), [], "nothing typed: nothing searched")
        XCTAssertEqual(found("main swift", in: paths).first, "Sources/App/Main.swift", "spaces are not part of it")
    }

    func testTheBestComeFirst() {
        // The name that is the query, before the name that starts with it,
        // before a match that needs the folders.
        XCTAssertEqual(found("main", in: ["main/Setup.swift", "Sources/Domain/Maintenance.swift", "Sources/App/Main.swift"]),
                       ["Sources/App/Main.swift", "Sources/Domain/Maintenance.swift", "main/Setup.swift"])
        // Starts of words and capitals over characters inside words.
        XCTAssertEqual(found("ft", in: ["Sources/after.swift", "Sources/FileTab.swift"]).first, "Sources/FileTab.swift")
        XCTAssertEqual(found("fts", in: ["Sources/Files/FileTextSource.swift", "Sources/Files/fits.swift"]).first, "Sources/Files/FileTextSource.swift")
        // A run of characters over scattered ones.
        XCTAssertEqual(found("tab", in: ["Sources/TheAppBar.swift", "Sources/TabHost.swift"]).first, "Sources/TabHost.swift")
        // A query naming folders matches across them.
        XCTAssertEqual(found("app/main", in: ["Sources/App/Main.swift", "Sources/Views/MainView.swift"]), ["Sources/App/Main.swift"])
        // A name that is the query, however deep, before a longer name.
        XCTAssertEqual(found("view", in: ["ViewModel.swift", "Sources/Deep/Folder/View.swift"]).first, "Sources/Deep/Folder/View.swift")
        // Otherwise alike: the shorter path, then the one listed first.
        XCTAssertEqual(found("x", in: ["long/folder/x.swift", "x.swift", "b/x.swift", "a/x.swift"]),
                       ["x.swift", "b/x.swift", "a/x.swift", "long/folder/x.swift"])
    }

    func testAQueryEndingInALineAsksForIt() {
        let query = FileFinderQuery("Main.swift:42")
        XCTAssertEqual(query.line, 42)
        XCTAssertEqual(query.text, "Main.swift")
        XCTAssertNil(FileFinderQuery("Main.swift:").line)
        XCTAssertNil(FileFinderQuery("a:0").line)
        XCTAssertEqual(FileFinderSearch.search(query, in: index(["Sources/Main.swift"])).map(\.path), ["Sources/Main.swift"])
    }

    func testTheMatchedCharactersAreSaid() {
        XCTAssertEqual(highlighted("main", in: "Sources/App/Main.swift"), ["Main"])
        XCTAssertEqual(highlighted("ft", in: "Sources/FileTab.swift"), ["F", "T"])
        XCTAssertEqual(highlighted("app/main", in: "Sources/App/Main.swift"), ["App/Main"])
        // Not ASCII: the characters as they are in the path.
        XCTAssertEqual(highlighted("résumé", in: "docs/Résumé.txt"), ["Résumé"])
        XCTAssertEqual(highlighted("i", in: "İstanbul.txt"), ["İ"], "one character folding to two")
        XCTAssertEqual(found("é", in: ["docs/Ã©.txt"]), [], "never a character made of two others' bytes")
        XCTAssertEqual(found("e", in: ["é.txt"]), [], "é is not e")
        XCTAssertEqual(highlighted("e", in: "é-e.txt"), ["e"])
    }

    func testACharacterIsFoundHoweverItIsSpelled() {
        let decomposed = "Docs/Cafe\u{301}.md", composed = "Docs/Caf\u{E9}.txt"
        XCTAssertEqual(Set(found("Caf\u{E9}", in: [decomposed, composed, "Docs/Cafe.swift"])), [decomposed, composed],
                       "é typed or on disk either way, and not e")
        XCTAssertEqual(Set(found("cafe\u{301}", in: [decomposed, composed, "Docs/Cafe.swift"])), [decomposed, composed])
        // The whole character, as it is in the path (Strings compare
        // spellings alike, so their bytes are compared).
        XCTAssertEqual(highlighted("caf\u{E9}", in: decomposed).map { Array($0.utf8) }, [Array("Cafe\u{301}".utf8)])
        XCTAssertEqual(highlighted("CAFE\u{301}", in: composed).map { Array($0.utf8) }, [Array("Caf\u{E9}".utf8)])
        let hangul = "노트/한글.md".decomposedStringWithCanonicalMapping
        XCTAssertEqual(found("한글", in: [hangul]).map { Array($0.utf8) }, [Array(hangul.utf8)])
        XCTAssertEqual(highlighted("글", in: hangul).map { Array($0.utf8) }, [Array("글".decomposedStringWithCanonicalMapping.utf8)])
    }

    func testASearchCanBeStopped() {
        let many = index((0..<40_000).map { "folder\($0 % 97)/file\($0).swift" })
        XCTAssertEqual(FileFinderSearch.search(FileFinderQuery("file"), in: many, cancelled: { true }), [])
        // Stopped part of the way through: nothing, not what was found so far.
        let asked = Counter()
        XCTAssertEqual(FileFinderSearch.search(FileFinderQuery("file"), in: many, cancelled: { asked.next() > 3 }), [])
        XCTAssertEqual(FileFinderSearch.search(FileFinderQuery("file"), in: many).count, 50)
    }

    /// A large index is searched in chunks across cores: what it keeps is
    /// what scoring every file and sorting them all would keep.
    func testTheBestAreTheSameWhateverTheChunks() {
        var generator = SplitMix(seed: 7)
        let words = ["app", "view", "model", "file", "tab", "main", "test", "util", "core", "data", "sync", "user", "Git", "Diff", "x"]
        func word() -> String { words[Int(generator.next() % UInt64(words.count))] }
        let paths = (0..<40_000).map { _ in (0..<(1 + Int(generator.next() % 4))).map { _ in word() + word() }.joined(separator: "/") + ".swift" }
        let all = index(paths)
        for query in ["app", "vm", "filetab", "gd", "core/sync", "tsx", "mainview"] {
            let parsed = FileFinderQuery(query)
            let kept = FileFinderSearch.search(parsed, in: all, limit: 50).map { FileFinderSearch.Scored(file: $0.index, score: $0.score, length: all.foldedRange($0.index).count) }
            var every: [FileFinderSearch.Scored] = []
            all.folded.withUnsafeBufferPointer { folded in
                for file in 0..<all.count {
                    let path = all.foldedRange(file)
                    if let alignment = FileFinderSearch.score(parsed, folded, path: path, nameStart: Int(all.nameStarts[file]), original: all, file: file) {
                        every.append(.init(file: file, score: alignment.score, length: path.count))
                    }
                }
            }
            every.sort(by: FileFinderSearch.TopScores.better)
            XCTAssertEqual(kept.map(\.file), every.prefix(50).map(\.file), query)
            XCTAssertEqual(kept.map(\.score), every.prefix(50).map(\.score), query)
        }
    }
}

/// Counts the times it is asked, from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// A small generator with a seed, so the corpus is the same every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
