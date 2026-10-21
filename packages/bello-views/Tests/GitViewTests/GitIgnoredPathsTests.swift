import XCTest
@testable import GitView

final class GitIgnoredPathsTests: ViewsTestCase {
    @MainActor func testLargeIgnoreRechecksAvoidScanningEveryDirectory() {
        let relative = (0..<20_000).map { "ignored-\($0)/" }
        let directories = relative.map { "/repo/" + $0 }
        let paths = (0..<4_096).map { "/repo/ignored-\(20_000 - 4_096 + $0)/nested/file.o" }
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: relative, scanStartedAt: 20)
        let changes = GitWatchChanges(paths, receivedAt: 10)

        // Best of three avoids charging a scheduler pause to either matcher.
        // The generous relative bound works in both Debug and Release builds.
        let linear = fastest { paths.allSatisfy { path in directories.contains { path.hasPrefix($0) } } }
        let recheck = fastest { !changes.isInteresting(ignoring: ignored) }
        let filter = fastest { paths.allSatisfy { ignored.covers($0) } }
        print("Ignore matching (4096 paths, 20000 directories): linear=\(linear * 1_000)ms recheck=\(recheck * 1_000)ms filter=\(filter * 1_000)ms")
        XCTAssertLessThan(recheck, linear / 8, "Queued rechecks must not scan the ignored-directory list for every path")
        XCTAssertLessThan(filter, linear / 8, "The FSEvents filter must use the same indexed matcher")
    }

    private func fastest(_ match: () -> Bool) -> Double {
        var fastest = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let matched = match()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            XCTAssertTrue(matched, "Every generated path is ignored; the timed work cannot short-circuit on a miss")
            fastest = min(fastest, elapsed)
        }
        return fastest
    }

    func testDirectoryIndexUsesByteSeparatorsAndPreservesShownAncestors() {
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: ["cache/", "cache/deep/", "source/", "exact.log"], scanStartedAt: 20)
        for path in ["cache", "cache/", "cache/deep/item", "cache/\u{301}item", "exact.log"] {
            XCTAssertTrue(ignored.covers("/repo/" + path), path)
            XCTAssertFalse(GitWatchChanges(["/repo/" + path], receivedAt: 10).isInteresting(ignoring: ignored), path)
        }
        for path in ["cache-other/file", "cach", "cache\u{301}/file", "exact.log/child", "exact.log/"] {
            XCTAssertFalse(ignored.covers("/repo/" + path), path)
        }
        ignored.preserve(root: "/repo", entries: [
            GitStatusEntry(path: "cache/deep", originalPath: "source/\u{301}old",
                           indexState: "R", worktreeState: ".", untracked: false)
        ])
        for path in ["cache", "cache/", "cache/deep", "cache/deep/\u{301}child", "source", "source/\u{301}old/child"] {
            XCTAssertFalse(ignored.covers("/repo/" + path), "Displayed paths stay protected: \(path)")
        }
        XCTAssertTrue(ignored.covers("/repo/cache/other"))
        XCTAssertTrue(ignored.covers("/repo/source/other"))
        ignored.preserve(root: "/repo", entries: [
            GitStatusEntry(path: "cache", originalPath: nil, indexState: "?", worktreeState: "?", untracked: true)
        ])
        XCTAssertFalse(ignored.covers("/repo/cache/deep/child"), "An ignored child must not hide a displayed ancestor")
        ignored.update(root: "/repo", relative: ["replacement/"], scanStartedAt: 30)
        XCTAssertFalse(ignored.covers("/repo/cache/other"), "Publishing replaces the index")
        XCTAssertTrue(ignored.covers("/repo/replacement/file"))

        ignored.update(root: "/\u{301}repo", relative: ["cache/"], scanStartedAt: 40)
        XCTAssertTrue(ignored.covers("/private/\u{301}repo/cache/\u{301}item"), "The private alias also uses byte boundaries")
    }
}
