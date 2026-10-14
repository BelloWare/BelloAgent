import XCTest
@testable import FileFinder

final class FolderBrowserTests: XCTestCase {
    func testBreadcrumbsRespectProjectBoundaryAndHome() {
        let home = URL(fileURLWithPath: "/fixture/home")
        let root = home.appendingPathComponent("Project")
        let path = FileBreadcrumb.path(to: root.appendingPathComponent("Sources/UI/File.swift"), project: ("Project", root), home: home)
        XCTAssertEqual(path.map(\.title), ["Project", "Sources", "UI", "File.swift"])
        XCTAssertEqual(path.map(\.url), [root, root.appendingPathComponent("Sources"), root.appendingPathComponent("Sources/UI"), root.appendingPathComponent("Sources/UI/File.swift")])
        XCTAssertEqual(path.map(\.isDirectory), [true, true, true, false])
        XCTAssertEqual(FileBreadcrumb.path(to: root, project: ("Project", root), home: home).map(\.title), ["Project"])
        XCTAssertEqual(FileBreadcrumb.path(to: home.appendingPathComponent("Project-other/a.txt"), project: ("Project", root), home: home).map(\.title), ["~", "Project-other", "a.txt"])
        XCTAssertEqual(FileBreadcrumb.path(to: URL(fileURLWithPath: "/outside/a.txt"), home: home).map(\.title), ["/", "outside", "a.txt"])
    }

    func testLongPathCollapsesMiddleButKeepsEveryAncestorReachable() {
        let crumbs = FileBreadcrumb.path(to: URL(fileURLWithPath: "/p/one/two/three/file.swift"), project: ("Project", URL(fileURLWithPath: "/p")))
        let collapsed = FileBreadcrumb.collapsed(crumbs, width: 160, measure: { _ in 55 })
        XCTAssertEqual(collapsed.map(\.title), ["Project", "…", "file.swift"])
        XCTAssertEqual(collapsed[1].ancestors.map(\.title), ["one", "two", "three"])
        XCTAssertEqual(FileBreadcrumb.collapsed(crumbs, width: 900, measure: { _ in 55 }), crumbs)
        XCTAssertEqual(FileBreadcrumb.collapsed(crumbs, width: 40, measure: { _ in 55 }).last?.url, crumbs.last?.url)
    }

    func testListingFoldersFirstAlphabeticalDimmedAndNoSpecialFiles() async throws {
        let root = try fixture()
        try folder("Zoo", at: root); try folder("alpha", at: root)
        try file("z.txt", at: root); try file("A.txt", at: root); try file(".hidden", at: root)
        try file("ignore.log", at: root); try file(".gitignore", at: root, text: "*.log\n")
        try folder(".git", at: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let result = try await FolderDirectory.read(root, relativeTo: root, environment: Self.environment(root))
        XCTAssertEqual(result.entries.map(\.name), ["alpha", "Zoo", ".gitignore", ".hidden", "A.txt", "ignore.log", "z.txt"])
        XCTAssertTrue(result.entries.first { $0.name == "ignore.log" }?.isDimmed == true)
        XCTAssertTrue(result.entries.first { $0.name == ".hidden" }?.isDimmed == true)
    }

    @MainActor func testLazyLoadRevealSelectionAndSiblings() async throws {
        let root = try fixture(); try folder("Sources/UI", at: root); try folder("Untouched", at: root)
        try file("Sources/UI/current.swift", at: root); try file("Sources/UI/sibling.swift", at: root)
        let calls = ReadCalls()
        let browser = FolderBrowser(reader: { url, base in await calls.record(url); return try await FolderDirectory.read(url, relativeTo: base, environment: Self.environment(root)) })
        let target = root.appendingPathComponent("Sources/UI/current.swift")
        browser.show(file: target, projectRoot: root, home: root)
        try await until { browser.rows.contains { $0.url == target } }
        XCTAssertEqual(browser.selectedURL, target)
        XCTAssertTrue(browser.expanded.contains(FileBreadcrumb.normalized(root.appendingPathComponent("Sources/UI"))))
        XCTAssertTrue(browser.rows.contains { $0.url.lastPathComponent == "sibling.swift" })
        let reads = await calls.urls
        XCTAssertFalse(reads.contains(root.appendingPathComponent("Untouched")))
        browser.expand(root.appendingPathComponent("Untouched"))
        try await until { browser.snapshot(root.appendingPathComponent("Untouched")) != nil }
        browser.stop()
    }

    @MainActor func testParentNavigationStopsAtHomeAndProjectsStayRooted() async throws {
        let root = try fixture(); try folder("one/two", at: root); try file("one/two/file", at: root)
        let file = root.appendingPathComponent("one/two/file")
        let browser = FolderBrowser(reader: { url, base in try await FolderDirectory.read(url, relativeTo: base, environment: Self.environment(root)) })
        browser.show(file: file, projectRoot: nil, home: root)
        XCTAssertEqual(browser.root?.path, file.deletingLastPathComponent().path); XCTAssertTrue(browser.canGoUp)
        browser.goUp(); XCTAssertEqual(browser.root?.path, root.appendingPathComponent("one").path)
        browser.goUp(); XCTAssertEqual(browser.root, root); XCTAssertFalse(browser.canGoUp)
        browser.goUp(); XCTAssertEqual(browser.root, root)
        browser.show(file: file, projectRoot: root, home: root)
        XCTAssertEqual(browser.root, root); XCTAssertFalse(browser.canGoUp)
        browser.stop()
    }

    @MainActor func testSupersededReadsAreCancelledAndCannotPublish() async throws {
        let root = try fixture(); let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        let gate = CancellationGate()
        let browser = FolderBrowser(reader: { url, _ in
            if url == old { return try await gate.read() }
            return FolderDirectory(entries: [.init(url: new.appendingPathComponent("fresh"), isDirectory: false)])
        })
        browser.show(file: old.appendingPathComponent("stale"), projectRoot: nil, home: root)
        try await until { await gate.entered }
        browser.show(file: new.appendingPathComponent("fresh"), projectRoot: nil, home: root)
        try await until { await gate.cancelled }
        try await until { browser.rows.contains { $0.url.lastPathComponent == "fresh" } }
        XCTAssertNil(browser.snapshot(old)); XCTAssertEqual(browser.root, new)
        browser.stop()
    }

    @MainActor func testLargeFolderCapsRowsButStillRevealsFileAndShowsMore() async throws {
        let root = try fixture()
        for n in 0..<12 { try file(String(format: "%02d.txt", n), at: root) }
        let browser = FolderBrowser(pageSize: 4, reader: { url, base in try await FolderDirectory.read(url, relativeTo: base, environment: Self.environment(root)) })
        let target = root.appendingPathComponent("11.txt")
        browser.show(file: target, projectRoot: root, home: root)
        try await until { browser.snapshot(root) != nil }
        XCTAssertEqual(browser.visibleEntries(in: root).count, 4)
        XCTAssertTrue(browser.visibleEntries(in: root).contains { $0.url == target })
        XCTAssertEqual(browser.remaining(in: root), 8)
        XCTAssertEqual(browser.selectedURL, target)
        browser.showMore(in: root)
        XCTAssertEqual(browser.visibleEntries(in: root).count, 8)
        XCTAssertEqual(browser.remaining(in: root), 4)
        browser.stop()
    }

    @MainActor func testCollapseCancelsDescendantReadAndReopeningRefreshes() async throws {
        let root = try fixture(); try folder("child", at: root)
        let gate = CancellationGate()
        let browser = FolderBrowser(reader: { url, base in
            if url.lastPathComponent == "child" { return try await gate.read() }
            return try await FolderDirectory.read(url, relativeTo: base, environment: Self.environment(root))
        })
        browser.show(file: root.appendingPathComponent("new.txt"), projectRoot: root, home: root)
        try await until { browser.snapshot(root) != nil }
        browser.expand(root.appendingPathComponent("child")); try await until { await gate.entered }
        browser.collapse(root.appendingPathComponent("child")); try await until { await gate.cancelled }
        try file("new.txt", at: root)
        browser.show(file: root.appendingPathComponent("new.txt"), projectRoot: root, home: root)
        try await until { browser.snapshot(root)?.entries.contains { $0.name == "new.txt" } == true }
        browser.stop()
    }

    @MainActor func testCancelledReaderThatReturnsSuccessCannotRestoreOldDirectory() async throws {
        let root = try fixture(), old = root.appendingPathComponent("old"), fresh = root.appendingPathComponent("fresh")
        let gate = SuccessfulStaleRead()
        let browser = FolderBrowser(reader: { url, _ in
            if url == old { return await gate.read() }
            return FolderDirectory(entries: [.init(url: fresh.appendingPathComponent("new.txt"), isDirectory: false)])
        })
        browser.show(file: old.appendingPathComponent("old.txt"), projectRoot: nil, home: root)
        try await until { await gate.entered }
        let obsolete = browser.pendingRead(in: old)
        browser.show(file: fresh.appendingPathComponent("new.txt"), projectRoot: nil, home: root)
        try await until { browser.snapshot(fresh) != nil }
        await gate.release()
        try await until { await gate.returned }
        await obsolete?.value
        XCTAssertNil(browser.snapshot(old))
        XCTAssertEqual(browser.selectedURL?.lastPathComponent, "new.txt")
        browser.stop()
    }

    func testRepositoryIgnoreRulesKeepTrackedIgnoredFilesAndDimIgnoredParent() async throws {
        let root = try fixture(); try folder("ignored", at: root)
        try file(".gitignore", at: root, text: "ignored/\n*.log\n")
        try file("tracked.log", at: root); try file("untracked.log", at: root); try file("ignored/a.txt", at: root)
        let env = Self.environment(root)
        _ = try await FinderProcess.git(["init", "-q"], in: root.path, limit: 4096, environment: env)
        _ = try await FinderProcess.git(["add", "-f", "tracked.log"], in: root.path, limit: 4096, environment: env)
        let listing = try await FolderDirectory.read(root, relativeTo: root, environment: env)
        XCTAssertFalse(try XCTUnwrap(listing.entries.first { $0.name == "tracked.log" }).isDimmed)
        XCTAssertTrue(try XCTUnwrap(listing.entries.first { $0.name == "untracked.log" }).isDimmed)
        XCTAssertTrue(try XCTUnwrap(listing.entries.first { $0.name == "ignored" }).isDimmed)
        let ignored = try await FolderDirectory.read(root.appendingPathComponent("ignored"), relativeTo: root, environment: env)
        XCTAssertTrue(try XCTUnwrap(ignored.entries.first).isDimmed)
    }

    func testNonRepositoryIgnoredParentStaysDimmedOnDirectEntry() async throws {
        let root = try fixture(); try folder("ignored/child", at: root)
        try file(".gitignore", at: root, text: "ignored/\n")
        try file("ignored/child/a.txt", at: root)
        let listing = try await FolderDirectory.read(root.appendingPathComponent("ignored/child"), relativeTo: root, environment: Self.environment(root))
        XCTAssertTrue(try XCTUnwrap(listing.entries.first).isDimmed)
    }

    @MainActor func testReaderRunsOffMainAndIndependentBranchesFinish() async throws {
        let root = try fixture(); let calls = ReadCalls()
        let browser = FolderBrowser(reader: { url, _ in
            XCTAssertFalse(Thread.isMainThread, "Directory providers must never run on the UI thread")
            await calls.record(url)
            return FolderDirectory(entries: [])
        })
        browser.show(file: root.appendingPathComponent("a.txt"), projectRoot: root, home: root)
        browser.expand(root.appendingPathComponent("one")); browser.expand(root.appendingPathComponent("two"))
        try await until { browser.snapshot(root.appendingPathComponent("one")) != nil && browser.snapshot(root.appendingPathComponent("two")) != nil }
        let urls = await calls.urls
        XCTAssertEqual(Set(urls).count, 3)
        browser.stop()
    }

    @MainActor func testGoingUpRestartsCancelledExpandedSiblingRead() async throws {
        let root = try fixture(), folder = root.appendingPathComponent("one"), child = root.appendingPathComponent("one/child")
        let gate = CancellationGate()
        let browser = FolderBrowser(reader: { url, _ in
            if url == child { return try await gate.read() }
            return FolderDirectory(entries: [])
        })
        browser.show(file: folder.appendingPathComponent("file.txt"), projectRoot: nil, home: root)
        browser.expand(child)
        try await until { await gate.entered }
        browser.goUp()
        XCTAssertTrue(browser.isLoading(child), "The expanded sibling must not remain stuck on Loading after Up cancels its first read")
        browser.stop()
    }

    func testReadCapWarningSurvivesAnOversizedIgnoreFile() async throws {
        let root = try fixture()
        for index in 0..<10 { try file("file-\(index)", at: root) }
        try file(".gitignore", at: root, text: String(repeating: "x", count: FileListing.ignoreFileLimit + 1))
        let listing = try await FolderDirectory.read(root, relativeTo: root, environment: Self.environment(root), limits: .init(files: 4, pathBytes: 4096))
        XCTAssertLessThanOrEqual(listing.entries.count, 4)
        XCTAssertTrue(listing.warning?.contains("entries") == true)
        XCTAssertTrue(listing.warning?.contains("ignore file") == true)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-browser-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return FileBreadcrumb.normalized(root)
    }
    private func folder(_ path: String, at root: URL) throws { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
    private func file(_ path: String, at root: URL, text: String = "fixture") throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    private nonisolated static func environment(_ root: URL) -> [String: String] { ["PATH": "/usr/bin:/bin", "HOME": root.path, "XDG_CONFIG_HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"] }
    @MainActor private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Folder operation did not complete"); throw CancellationError()
    }
}

private actor ReadCalls { var urls: [URL] = []; func record(_ url: URL) { urls.append(url) } }
private actor CancellationGate {
    var entered = false, cancelled = false
    func read() async throws -> FolderDirectory {
        entered = true
        do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
        return FolderDirectory(entries: [])
    }
}

private actor SuccessfulStaleRead {
    var entered = false, returned = false
    private var continuation: CheckedContinuation<Void, Never>?
    func read() async -> FolderDirectory {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
        return FolderDirectory(entries: [])
    }
    func release() { continuation?.resume(); continuation = nil }
}
