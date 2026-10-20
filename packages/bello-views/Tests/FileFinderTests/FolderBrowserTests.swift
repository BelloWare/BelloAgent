import XCTest
@testable import FileFinder
import GitProcessSafety
import Darwin

final class FolderBrowserTests: XCTestCase {
    @MainActor func testStdinIncludesDoNotConsumeFolderPaths() async throws {
        let root = try fixture(), git = try TestGit(fixture())
        try git.run(["init", "-q"], in: root)
        let names = ["ordinary.tmp", "-option.tmp", "space name.tmp", "line\nbreak.tmp", "tab\tname.tmp", "quote\"name.tmp", "back\\slash.tmp",
                     "café.tmp", "bell\u{7}.tmp", "backspace\u{8}.tmp", "vertical\u{b}.tmp", "form\u{c}.tmp", "carriage\r.tmp", "delete\u{7f}.tmp"]
        for name in names { try file(name, at: root) }
        try file(".gitignore", at: root, text: "*.tmp\n")
        try file("README", at: root); try git.run(["add", "README"], in: root)
        let previous = GitReadProcess.resolveTrust
        GitReadProcess.resolveTrust = { $0 == root.path }
        defer { GitReadProcess.resolveTrust = previous }
        for source in ["/dev/stdin", "/dev/fd/0"] {
            try git.run(["config", "include.path", source], in: root)
            let listing = try await FolderDirectory.read(root, relativeTo: root, environment: git.environment)
            XCTAssertNil(listing.warning, source)
            for name in names { XCTAssertEqual(listing.entries.first { $0.name == name }?.isDimmed, true, name) }
            XCTAssertEqual(listing.entries.first { $0.name == "README" }?.isDimmed, false)
        }
    }

    @MainActor func testTrustedFinderInventorySharesCancellationAndDeadline() async throws {
        let previous = GitReadProcess.resolveTrust
        GitReadProcess.resolveTrust = { _ in true }
        defer { GitReadProcess.resolveTrust = previous }
        for cancel in [false, true] {
            let root = try fixture(), git = try TestGit(fixture())
            try file("README", at: root); try git.run(["init", "-q"], in: root); try git.run(["add", "README"], in: root)
            _ = try await FinderProcess.git(["ls-files", "-z"], in: root.path, limit: 4096, environment: git.environment)
            let fifo = root.appendingPathComponent(".git/slow-config")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            try git.run(["config", "include.path", fifo.path], in: root)
            let descriptor = open(fifo.path, O_RDWR | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { try? FileManager.default.removeItem(at: fifo); close(descriptor) }
            let start = ProcessInfo.processInfo.systemUptime
            let task = Task { try await FinderProcess.git(["ls-files", "-z"], in: root.path, limit: 4096, timeout: cancel ? 20 : 0.15, environment: git.environment) }
            if cancel { try await Task.sleep(for: .milliseconds(100)); task.cancel() }
            do { _ = try await task.value; XCTFail("Obsolete listing completed") }
            catch { if cancel { XCTAssertTrue(error is CancellationError, "\(error)") } }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.7)
        }
    }

    @MainActor func testTrustedListingsUseGlobalMonitorButNeverLocalMonitor() async throws {
        let root = try fixture(), git = try TestGit(fixture())
        try file("README", at: root)
        try git.run(["init", "-q"], in: root); try git.run(["add", "README"], in: root)
        for name in ["global", "local"] {
            try file(".git/\(name)-monitor", at: root, text: "#!/bin/sh\n: > '\(root.path)/\(name)-ran'\nprintf 'token\\000'\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/\(name)-monitor").path)
        }
        let global = root.appendingPathComponent(".git/global-config")
        try Data("[core]\nfsmonitor = \(root.path)/.git/global-monitor\n".utf8).write(to: global)
        var env = Self.environment(root); env["GIT_CONFIG_GLOBAL"] = global.path
        try git.run(["config", "core.fsmonitor", root.path + "/.git/local-monitor"], in: root)
        let previous = GitReadProcess.resolveTrust
        GitReadProcess.resolveTrust = { $0 == root.path }
        defer { GitReadProcess.resolveTrust = previous }
        for operation in ["folder", "quick open"] {
            if operation == "folder" {
                let listing = try await FolderDirectory.read(root, relativeTo: root, environment: env)
                XCTAssertTrue(listing.entries.contains { $0.name == "README" })
            } else {
                let listing = try await FileListing.list(root.path, limits: .init(), environment: env)
                XCTAssertTrue(paths(listing).contains("README"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("global-ran").path), operation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-ran").path), operation)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("global-ran"))
        }
        GitReadProcess.resolveTrust = { _ in false }
        _ = try await FolderDirectory.read(root, relativeTo: root, environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("global-ran").path), "Revoked trust restores confinement")
    }

    func testListingsNeverRunRepositoryFSMonitor() async throws {
        let root = try fixture(), env = Self.environment(root), git = try TestGit(fixture())
        try file("README", at: root)
        for arguments in [["init", "-q"], ["add", "README"]] {
            try git.run(arguments, in: root)
        }
        let marker = root.appendingPathComponent("ran"), hook = root.appendingPathComponent("monitor")
        try file("monitor", at: root, text: "#!/bin/sh\n: > '\(marker.path)'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git.run(["config", "core.fsmonitor", hook.path], in: root)
        for boundary in [root, root.deletingLastPathComponent()] {
            let listing = try await FolderDirectory.read(root, relativeTo: boundary, environment: env)
            XCTAssertTrue(listing.entries.contains { $0.name == "README" })
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Folder listing, project boundary: \(String(describing: boundary))")
            try? FileManager.default.removeItem(at: marker)
        }
        let listing = try await FileListing.list(root.path, limits: .init(), environment: env)
        XCTAssertTrue((0..<listing.count).contains { String(decoding: listing.path($0), as: UTF8.self) == "README" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Quick Open listing")
    }

    func testSparseIndexListingsNeverStartPromisorRemotePrograms() async throws {
        let root = try fixture(), git = try TestGit(fixture())
        try folder("kept", at: root); try folder("omitted", at: root)
        try file("kept/README", at: root); try file("omitted/hidden", at: root)
        try git.run(["init", "-q"], in: root); try git.run(["add", "."], in: root)
        try git.run(["-c", "commit.gpgsign=false", "commit", "-qm", "Sparse fixture"], in: root)
        let oid = String(decoding: try git.run(["rev-parse", "HEAD:omitted"], in: root), as: UTF8.self).trimmingCharacters(in: .newlines)
        try git.run(["sparse-checkout", "init", "--cone", "--sparse-index"], in: root)
        try git.run(["sparse-checkout", "set", "kept"], in: root)
        let marker = root.appendingPathComponent("ran"), remote = root.appendingPathComponent(".git/remote")
        try file(".git/remote", at: root, text: "#!/bin/sh\n: > '\(marker.path)'\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remote.path)
        for (key, value) in [("extensions.partialClone", "origin"), ("remote.origin.promisor", "true"),
                             ("remote.origin.url", "ext::" + remote.path), ("protocol.ext.allow", "always")] {
            try git.run(["config", key, value], in: root)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2)))
        for operation in ["folder", "quick open"] {
            if operation == "folder" {
                let listing = try await FolderDirectory.read(root, relativeTo: root, environment: git.environment)
                XCTAssertTrue(listing.entries.contains { $0.name == "kept" })
            } else {
                let listing = try await FileListing.list(root.path, limits: .init(), environment: git.environment)
                XCTAssertTrue(paths(listing).contains("kept/README"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), operation)
            try? FileManager.default.removeItem(at: marker)
        }
    }

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
        let git = try TestGit(fixture())
        try git.run(["init", "-q"], in: root)
        try git.run(["add", "-f", "tracked.log"], in: root)
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
