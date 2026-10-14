import XCTest
@testable import GitView

final class GitPatchTests: XCTestCase {
    func testRawHunksKeepCRLFAndMissingFinalNewline() throws {
        let raw = Data("diff --git a/file b/file\nindex 111..222 100644\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\r\n+new\r\n@@ -12 +12 @@\n-last\n\\ No newline at end of file\n+end\n\\ No newline at end of file\n".utf8)
        let patch = try GitPatch(raw: raw, path: "file")
        XCTAssertEqual(patch.raw, raw)
        XCTAssertEqual(patch.hunks.count, 2)
        let before = Data(("old\r\n" + (2...11).map { "line \($0)\r\n" }.joined() + "last").utf8)
        let first = try patch.applying(hunk: 0, to: before, reverse: false)
        XCTAssertEqual(first, Data(("new\r\n" + (2...11).map { "line \($0)\r\n" }.joined() + "last").utf8))
        XCTAssertEqual(try patch.applying(hunk: 0, to: first, reverse: true), before)
        XCTAssertEqual(try patch.applying(hunk: 1, to: before, reverse: false).suffix(3), Data("end".utf8))
    }

    func testNoOffsetOrContextFallback() throws {
        let raw = Data("diff --git a/file b/file\nindex 111..222 100644\n--- a/file\n+++ b/file\n@@ -2 +2 @@\n-old\n+new\n".utf8)
        let patch = try GitPatch(raw: raw, path: "file")
        XCTAssertThrowsError(try patch.applying(hunk: 0, to: Data("extra\nline\nold\n".utf8), reverse: false))
    }

    func testIncompleteAndUnsupportedPatchesAreRejected() {
        let header = "diff --git a/file b/file\nindex 111..222 100644\n--- a/file\n+++ b/file\n"
        for body in ["@@ -1,2 +1,2 @@\n-old\n+new\n", "@@ -1 +1 @@\n-old\n+new", "Binary files differ\n", "old mode 100644\nnew mode 100755\n"] {
            XCTAssertThrowsError(try GitPatch(raw: Data((header + body).utf8), path: "file"))
        }
        XCTAssertThrowsError(try GitPatch(raw: Data((header + "@@ -1 +1 @@\n-old\n+new\n").utf8), path: "other"))
    }
}
