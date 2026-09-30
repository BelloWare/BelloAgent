import XCTest
@testable import FileFinder

/// Ignore files outside a repository are read and matched as git reads and
/// matches them: wildmatch's own cases, and a folder of every kind of pattern
/// walked and compared with what `git check-ignore` says of the same folder.
final class FileIgnoreTests: XCTestCase {
    private func matches(_ text: String, _ pattern: String, pathname: Bool = true) -> Bool {
        Wildmatch.match(Array(pattern.utf8)[...], Array(text.utf8)[...], pathname: pathname)
    }

    func testWildmatchMatchesAsGitsDoes() {
        // From git's t3070-wildmatch, with WM_PATHNAME.
        let cases: [(String, String, Bool)] = [
            ("foo", "foo", true), ("foo", "bar", false), ("foo", "???", true), ("foo", "??", false),
            ("foo", "*", true), ("foo", "f*", true), ("foo", "*f", false), ("foo", "*foo*", true),
            ("foobar", "*ob*a*r*", true), ("aaaaaaabababab", "*ab", true), ("foo*", "foo\\*", true), ("foobar", "foo\\*bar", false),
            ("ball", "*[al]?", true), ("ten", "[ten]", false), ("ten", "t[a-g]n", true), ("ton", "t[!a-g]n", true),
            ("ton", "t[^a-g]n", true), ("a]b", "a[]]b", true), ("a-b", "a[]-]b", true), ("aab", "a[]-]b", false),
            ("aab", "a[]a-]b", true), ("]", "]", true),
            ("foo/baz/bar", "foo*bar", false), ("foo/baz/bar", "foo**bar", false), ("foobazbar", "foo**bar", true),
            ("foo/baz/bar", "foo/**/bar", true), ("foo/b/a/z/bar", "foo/**/bar", true), ("foo/bar", "foo/**/bar", true),
            ("foo/bar", "foo/**/**/bar", true), ("foo/bar", "foo?bar", false), ("foo/bar", "foo[/]bar", false),
            ("foo", "**/foo", true), ("bar/baz/foo", "**/foo", true), ("bar/baz/foo", "*/foo", false),
            ("deep/foo/bar/baz", "**/bar/*", true), ("deep/foo/bar/baz/", "**/bar/*", false), ("deep/foo/bar/baz/", "**/bar/**", true),
            ("deep/foo/bar", "**/bar/*", false), ("foo/bar/baz/x", "*/bar/**", true), ("deep/foo/bar/baz/x", "*/bar/**", false),
            ("1", "[[:digit:]]", true), ("a", "[[:digit:]]", false), ("a", "[[:alpha:]]", true), ("-", "[[:punct:]]", true),
        ]
        for (text, pattern, expected) in cases {
            XCTAssertEqual(matches(text, pattern), expected, "\(text) against \(pattern)")
        }
        XCTAssertTrue(matches("x/y", "x*y", pathname: false), "without WM_PATHNAME a star crosses a slash")
    }

    func testPatternLinesAreReadAsGitReadsThem() throws {
        XCTAssertNil(IgnorePattern(line: Array("# a comment".utf8)))
        XCTAssertNil(IgnorePattern(line: []))
        XCTAssertEqual(IgnorePattern(line: Array("trail   ".utf8))?.bytes, Array("trail".utf8))
        XCTAssertEqual(IgnorePattern(line: Array("spaced\\ ".utf8))?.bytes, Array("spaced\\ ".utf8), "an escaped space stays")
        XCTAssertEqual(IgnorePattern(line: Array("crlf\r".utf8))?.bytes, Array("crlf".utf8))
        let negated = try XCTUnwrap(IgnorePattern(line: Array("!keep/".utf8)))
        XCTAssertTrue(negated.negated); XCTAssertTrue(negated.directoryOnly); XCTAssertTrue(negated.basenameOnly)
        XCTAssertFalse(try XCTUnwrap(IgnorePattern(line: Array("a/b".utf8))).basenameOnly)
        XCTAssertFalse(try XCTUnwrap(IgnorePattern(line: Array("\\!bang".utf8))).negated)
    }

    /// A folder with every kind of pattern, nested ignore files among them,
    /// walked: exactly the files git would not ignore.
    func testAWalkIgnoresWhatGitIgnores() async throws {
        let root = scratchRoot("finder-ignore")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try TestGit(root)
        let project = root.appendingPathComponent("project")
        try git.initialize(project)
        try write("\u{FEFF}# a comment\n\n*.log\n!keep.log\n/build\ndocs/*.tmp\n**/cache/\nout/**\na/**/z.txt\ntrailing.txt   \n"
                  + "spaced\\ \n\\#hash.txt\n\\!bang.txt\n[abc].c\n[!x]y.c\n[a-c]range.c\nfile[[:digit:]].txt\n?.q\ntmp*\nx**y\n"
                  + "ignored-dir/\n!ignored-dir/back.txt\nsub/deep/\ncrlf.txt\r\nlast-line-without-newline.txt", ".gitignore", in: project)
        try write("!*.log\nlocal.txt\n/anchored.txt\n", "pkg/.gitignore", in: project)
        try write("*.log\n!important.log\n", "pkg/inner/.gitignore", in: project)
        let files = [
            "app.log", "keep.log", "build/x.txt", "src/build/y.txt", "docs/a.tmp", "docs/deeper/b.tmp", "cache/c.txt", "src/cache/d.txt",
            "cachefile", "out/e.txt", "out/f/g.txt", "a/z.txt", "a/b/c/z.txt", "b/a/z.txt", "trailing.txt", "spaced ", "spaced",
            "#hash.txt", "!bang.txt", "a.c", "b.c", "d.c", "xy.c", "zy.c", "arange.c", "drange.c", "file1.txt", "filex.txt", "a.q",
            "ab.q", "tmpfile", "tmp/inside.txt", "xy", "x1y", "x/y", "ignored-dir/back.txt", "ignored-dir/other.txt", "sub/deep/h.txt",
            "other/sub/deep/h.txt", "crlf.txt", "last-line-without-newline.txt", "pkg/app.log", "pkg/local.txt", "pkg/anchored.txt",
            "pkg/x/anchored.txt", "pkg/inner/y.log", "pkg/inner/important.log", "pkg/inner/local.txt", "README.md", "src/main.swift",
            "linked/a.txt",
        ]
        for file in files { try write("x", file, in: project) }
        // A link named .gitignore: git does not follow it, so what it names
        // is not the folder's rules.
        try write("*.txt\n", "elsewhere-rules", in: root)
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("linked/.gitignore").path,
                                                   withDestinationPath: root.appendingPathComponent("elsewhere-rules").path)
        // What git ignores of the same files.
        let input = Data(files.joined(separator: "\0").utf8)
        let ignored = try git.run(["check-ignore", "--no-index", "-z", "--stdin"], in: project, input: input, allowFailure: true)
        let ignoredByGit = Set(ignored.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(ignoredByGit.contains("app.log") && !ignoredByGit.contains("keep.log"), "git read the file: \(ignoredByGit.sorted())")
        // As git reads them: 32 of these files are ignored.
        XCTAssertEqual(ignoredByGit.sorted(), ["!bang.txt", "#hash.txt", "a.c", "a.q", "a/b/c/z.txt", "a/z.txt", "app.log", "arange.c", "b.c",
                                               "build/x.txt", "cache/c.txt", "crlf.txt", "docs/a.tmp", "file1.txt", "ignored-dir/back.txt",
                                               "ignored-dir/other.txt", "last-line-without-newline.txt", "out/e.txt", "out/f/g.txt",
                                               "pkg/anchored.txt", "pkg/inner/local.txt", "pkg/inner/y.log", "pkg/local.txt", "spaced ",
                                               "src/cache/d.txt", "sub/deep/h.txt", "tmp/inside.txt", "tmpfile", "trailing.txt", "x1y", "xy", "zy.c"])
        var listing = FolderListing()
        try FileListing.walk(project.path, global: nil, limits: FileListingLimits(), into: &listing)
        let walked = Set(paths(listing))
        let kept = Set(files).subtracting(ignoredByGit).union([".gitignore", "pkg/.gitignore", "pkg/inner/.gitignore", "linked/.gitignore"])
        XCTAssertEqual(walked.subtracting(kept).sorted(), [], "listed, though git ignores them")
        XCTAssertEqual(kept.subtracting(walked).sorted(), [], "ignored, though git does not")
    }

    /// The user's global ignore file is the last word: any `.gitignore` in
    /// the folder decides before it.
    func testTheGlobalIgnoreFileAppliesLast() async throws {
        let root = scratchRoot("finder-global")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try TestGit(root)
        try write("*.orig\n.DS_Store\n", ".config/git/ignore", in: git.home)
        let folder = root.appendingPathComponent("plain")
        try write("!wanted.orig\n", ".gitignore", in: folder)
        for file in ["a.orig", "wanted.orig", ".DS_Store", "kept.txt"] { try write("x", file, in: folder) }
        let global = try await FileListing.globalIgnoreFile(in: folder.path, environment: git.environment)
        XCTAssertNotNil(global)
        var listing = FolderListing()
        try FileListing.walk(folder.path, global: global, limits: FileListingLimits(), into: &listing)
        XCTAssertEqual(paths(listing), [".gitignore", "kept.txt", "wanted.orig"])
    }
}
