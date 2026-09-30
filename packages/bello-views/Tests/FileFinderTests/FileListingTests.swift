import XCTest
@testable import FileFinder

/// A project's files as a finder lists them: in a repository what git lists
/// (tracked, ignored or not, and untracked it does not ignore), only files
/// that are there, another repository inside listed by its own git; outside
/// one a walk; bounded, and saying what it left out; a folder inside another
/// listed on its own; the finder listing again only when asked after a
/// moment, every asker waiting on one listing, and one stopped not kept.
final class FileListingTests: XCTestCase {
    private var root: URL!
    private var git: TestGit!

    override func setUp() async throws {
        root = scratchRoot("finder-listing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        git = try TestGit(root)
    }

    func testARepositoryListsWhatGitListsThatIsThere() async throws {
        try XCTSkipUnless(FileListing.gitAvailable, "git is not installed")
        let repo = root.appendingPathComponent("repo")
        try git.initialize(repo)
        try write("*.log\nbuild/\n", ".gitignore", in: repo)
        try write("tracked", "src/main.swift", in: repo)
        try write("forced", "logs/forced.log", in: repo)
        try write("gone", "gone.txt", in: repo)
        try write("sparse", "outside/sparse.txt", in: repo)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link-to-file").path, withDestinationPath: "src/main.swift")
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link-to-folder").path, withDestinationPath: "src")
        try git.run(["add", ".gitignore", "src", "gone.txt", "outside", "link-to-file", "link-to-folder"], in: repo)
        try git.run(["add", "-f", "logs/forced.log"], in: repo)
        try git.run(["commit", "-q", "-m", "first"], in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try write("untracked", "notes/todo.md", in: repo)
        try write("ignored", "debug.log", in: repo)
        try write("ignored", "build/out.o", in: repo)
        // An unmerged file, listed by git once for each of its stages.
        try write("base", "conflict.txt", in: repo)
        try git.run(["add", "conflict.txt"], in: repo); try git.run(["commit", "-q", "-m", "base"], in: repo)
        try git.run(["checkout", "-q", "-b", "other"], in: repo)
        try write("theirs", "conflict.txt", in: repo); try git.run(["commit", "-q", "-am", "theirs"], in: repo)
        try git.run(["checkout", "-q", "main"], in: repo)
        try write("ours", "conflict.txt", in: repo); try git.run(["commit", "-q", "-am", "ours"], in: repo)
        try git.run(["merge", "-q", "other"], in: repo, allowFailure: true)
        // A file outside a sparse checkout: tracked, and not there.
        try git.run(["sparse-checkout", "set", "--no-cone", "/*", "!/outside/"], in: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("outside/sparse.txt").path))
        let listing = try await FileListing.list(repo.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(Set(paths(listing)), [".gitignore", "conflict.txt", "link-to-file", "logs/forced.log", "notes/todo.md", "src/main.swift"])
        XCTAssertEqual(paths(listing).count, 6, "each file once")
        XCTAssertFalse(listing.truncated)

        // A folder of the repository: its own files, as paths below it.
        let src = try await FileListing.list(repo.appendingPathComponent("src").path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(paths(src), ["main.swift"])
    }

    func testRepositoriesInsideAreListedByTheirOwnGit() async throws {
        try XCTSkipUnless(FileListing.gitAvailable, "git is not installed")
        let library = root.appendingPathComponent("library")
        try git.initialize(library)
        try write("lib", "Lib.swift", in: library)
        try write("*.tmp\n", ".gitignore", in: library)
        try git.run(["add", "."], in: library); try git.run(["commit", "-q", "-m", "lib"], in: library)
        let repo = root.appendingPathComponent("app")
        try git.initialize(repo)
        try write("app", "App.swift", in: repo)
        try git.run(["add", "."], in: repo); try git.run(["commit", "-q", "-m", "app"], in: repo)
        try git.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "vendor/library"], in: repo)
        try git.run(["commit", "-q", "-m", "submodule"], in: repo)
        try write("scratch", "vendor/library/skip.tmp", in: repo)
        // An untracked repository of its own inside.
        let nested = repo.appendingPathComponent("experiments")
        try git.initialize(nested)
        try write("try", "Try.swift", in: nested)
        let listing = try await FileListing.list(repo.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(Set(paths(listing)), [".gitmodules", "App.swift", "vendor/library/.gitignore", "vendor/library/Lib.swift", "experiments/Try.swift"])
        // The submodule a folder of the project of its own: its files are its.
        let index = try await FileFinder.make(FileFinder.distinct([repo.path, repo.appendingPathComponent("vendor/library").path]),
                                              limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(byRoot(index), ["app": [".gitmodules", "App.swift", "experiments/Try.swift"], "library": [".gitignore", "Lib.swift"]])
    }

    func testAFolderOutsideARepositoryIsWalked() async throws {
        let folder = root.appendingPathComponent("plain")
        try write("*.o\n", ".gitignore", in: folder)
        try write("a", "a.c", in: folder)
        try write("o", "a.o", in: folder)
        try write("deep", "one/two/three.txt", in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git-not"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("elsewhere").path, withDestinationPath: root.path)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("alias.c").path, withDestinationPath: "a.c")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        let listing = try await FileListing.list(folder.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(paths(listing), [".gitignore", "a.c", "alias.c", "one/two/three.txt"], "a link to a folder is not followed; a dangling one is no file")
    }

    func testAListingStopsAtItsLimitsAndSaysSo() async throws {
        let folder = root.appendingPathComponent("many")
        for index in 0..<30 { try write("x", String(format: "file-%02d.txt", index), in: folder) }
        let byCount = try await FileListing.list(folder.path, limits: FileListingLimits(files: 10, pathBytes: 1_000_000), environment: git.environment)
        XCTAssertEqual(byCount.count, 10); XCTAssertTrue(byCount.truncated)
        let byBytes = try await FileListing.list(folder.path, limits: FileListingLimits(files: 1_000, pathBytes: 55), environment: git.environment)
        XCTAssertEqual(byBytes.count, 5, "11 bytes a path"); XCTAssertTrue(byBytes.truncated)
        let whole = try await FileListing.list(folder.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(whole.count, 30); XCTAssertFalse(whole.truncated)
    }

    func testAFinderListsEachFolderOnceAndAgainOnlyWhenAsked() async throws {
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let inner = first.appendingPathComponent("inner")
        // The outer folder ignores the inner one; it is the project's all the same.
        try write("inner/\n", ".gitignore", in: first)
        try write("a", "a.txt", in: first)
        try write("b", "inner/b.txt", in: first)
        try write("o", "other/o.txt", in: first)
        try write("c", "c.txt", in: second)
        let finder = FileFinder(roots: [first.path, inner.path, first.appendingPathComponent("other").path, second.path, second.path + "/"],
                                limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(finder.roots.count, 4, "each folder once")
        let latestBefore = await finder.latest
        XCTAssertNil(latestBefore)
        // Asked twice at once: one listing, one index.
        async let one = finder.refreshed(fresh: 60)
        async let two = finder.refreshed(fresh: 60)
        let (a, b) = await (one, two)
        let index = try XCTUnwrap(a)
        XCTAssertTrue(a === b)
        XCTAssertEqual(byRoot(index), ["first": [".gitignore", "a.txt"], "inner": ["b.txt"], "other": ["o.txt"], "second": ["c.txt"]],
                       "a folder inside another lists its files, the other not again")
        // Fresh: asked again, the same.
        try write("d", "d.txt", in: second)
        let again = await finder.refreshed(fresh: 60)
        XCTAssertTrue(again === index)
        // Not fresh any more: listed again.
        let refreshed = await finder.refreshed(fresh: 0)
        let later = try XCTUnwrap(refreshed)
        XCTAssertFalse(later === index)
        XCTAssertEqual(later.count, 6)
    }

    /// Each root's files, by the root's name.
    private func byRoot(_ index: FileFinderIndex) -> [String: [String]] {
        Dictionary(grouping: 0..<index.count) { URL(fileURLWithPath: index.root($0)).lastPathComponent }.mapValues { $0.map(index.path).sorted() }
    }

    func testAFolderInsideARepositoryIsListedOnItsOwnAndItsFilesOnce() async throws {
        try XCTSkipUnless(FileListing.gitAvailable, "git is not installed")
        let repo = root.appendingPathComponent("repo")
        try git.initialize(repo)
        try write("app", "App.swift", in: repo)
        try write("lib", "pkg/Lib.swift", in: repo)
        try git.run(["add", "."], in: repo); try git.run(["commit", "-q", "-m", "first"], in: repo)
        try write("new", "pkg/New.swift", in: repo)
        // A repository inside the inner folder: the inner folder's still.
        let nested = repo.appendingPathComponent("pkg/vendor")
        try git.initialize(nested)
        try write("v", "Vendor.swift", in: nested)
        let pkg = repo.appendingPathComponent("pkg")
        let index = try await FileFinder.make(FileFinder.distinct([repo.path, pkg.path]), limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(byRoot(index), ["repo": ["App.swift"], "pkg": ["Lib.swift", "New.swift", "vendor/Vendor.swift"]])
        // What is in a folder another lists, whichever repository lists it.
        var listing = FolderListing()
        listing.excluded = [Array("pkg/".utf8)]
        XCTAssertTrue(listing.isExcluded([], Array("pkg/Lib.swift".utf8)))
        XCTAssertTrue(listing.isExcluded(Array("pkg/".utf8), Array("Lib.swift".utf8)))
        XCTAssertTrue(listing.isExcluded(Array("pkg/vendor/".utf8), Array("Vendor.swift".utf8)))
        XCTAssertFalse(listing.isExcluded([], Array("pkg".utf8)), "a submodule's entry, without its \"/\": the loop over repositories inside adds one")
        XCTAssertFalse(listing.isExcluded([], Array("pkgs/a.swift".utf8)))
        XCTAssertFalse(listing.isExcluded(Array("app/".utf8), Array("pkg/a.swift".utf8)))
    }

    func testRepositoriesNestedTooDeepAreSaid() async throws {
        try XCTSkipUnless(FileListing.gitAvailable, "git is not installed")
        var folder = root.appendingPathComponent("r0"), expected: [String] = [], prefix = ""
        for depth in 0...(FileListing.nestedDepth + 1) {
            try git.initialize(folder)
            try write("x", "f\(depth).txt", in: folder)
            if depth <= FileListing.nestedDepth { expected.append(prefix + "f\(depth).txt") }
            prefix += "r\(depth + 1)/"
            folder = folder.appendingPathComponent("r\(depth + 1)")
        }
        let listing = try await FileListing.list(root.appendingPathComponent("r0").path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(paths(listing).sorted(), expected.sorted())
        XCTAssertEqual(listing.warnings, ["Repositories nested more than 4 levels deep are not listed."])
    }

    func testWhatAListingCannotReadOrApplyIsSaid() async throws {
        let gone = root.appendingPathComponent("gone")
        let missing = try await FileListing.list(gone.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(missing.count, 0)
        XCTAssertEqual(missing.warnings, ["“\(FileListing.shown(gone.path))” is not there, so no file in it is listed."])
        let locked = root.appendingPathComponent("locked")
        try write("x", "secret.txt", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let unread = try await FileListing.list(locked.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(unread.count, 0)
        XCTAssertEqual(unread.warnings, ["“\(FileListing.shown(locked.path))” could not be read, so no file in it is listed."])
        // Ignore files over a megabyte: not applied, and said.
        let folder = root.appendingPathComponent("plain")
        let filler = String(repeating: "#" + String(repeating: "x", count: 1_000) + "\n", count: 1_100)
        try write("*.txt\n" + filler, ".gitignore", in: folder)
        try write("*.txt\n" + filler, "sub/.gitignore", in: folder)
        try write("*.c\n" + filler, ".config/git/ignore", in: git.home)
        for file in ["a.txt", "b.c", "sub/c.txt"] { try write("x", file, in: folder) }
        let listing = try await FileListing.list(folder.path, limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(paths(listing), [".gitignore", "a.txt", "b.c", "sub/.gitignore", "sub/c.txt"])
        XCTAssertEqual(listing.warnings, [
            "The global ignore file “\(FileListing.shown(git.home.appendingPathComponent(".config/git/ignore").path))” is over 1 MB, so it is not applied.",
            "“.gitignore” is over 1 MB, so it is not applied.",
            "“sub/.gitignore” is over 1 MB, so it is not applied.",
        ])
        // Carried to the index, each once.
        let index = try await FileFinder.make([folder.path, gone.path], limits: FileListingLimits(), environment: git.environment)
        XCTAssertEqual(index.warnings, listing.warnings + missing.warnings)
    }

    func testAFolderOfMoreEntriesThanAListingHoldsStopsIt() async throws {
        let folder = root.appendingPathComponent("crowded")
        try write("*.o\n", ".gitignore", in: folder)
        for index in 0..<30 { try write("", "object-\(index).o", in: folder) }
        let listing = try await FileListing.list(folder.path, limits: FileListingLimits(files: 10, pathBytes: 1_000_000), environment: git.environment)
        XCTAssertTrue(listing.truncated, "not read whole, so not said to be every file")
        XCTAssertLessThanOrEqual(listing.count, 1)
        // Nor more folders waiting to be read than a listing holds files.
        let branching = root.appendingPathComponent("branching")
        for outer in 0..<4 { for inner in 0..<4 { try FileManager.default.createDirectory(at: branching.appendingPathComponent("\(outer)/\(inner)"), withIntermediateDirectories: true) } }
        let branched = try await FileListing.list(branching.path, limits: FileListingLimits(files: 5, pathBytes: 1_000_000), environment: git.environment)
        XCTAssertTrue(branched.truncated)
        let whole = try await FileListing.list(branching.path, limits: FileListingLimits(files: 8, pathBytes: 1_000_000), environment: git.environment)
        XCTAssertFalse(whole.truncated)
        // Nor read on once no longer wanted.
        let wide = root.appendingPathComponent("wide")
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        for index in 0..<4_100 { FileManager.default.createFile(atPath: wide.appendingPathComponent("f\(index)").path, contents: nil) }
        let stopped = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            guard let directory = opendir(wide.path) else { return false }
            do { _ = try FileListing.entries(of: directory, in: wide.path, limits: FileListingLimits()); return false }
            catch { return error is CancellationError }
        }.value
        XCTAssertTrue(stopped)
    }

    func testAListingStoppedMeanwhileIsNotKept() async throws {
        let gate = Gate()
        let finder = FileFinder(roots: [root.path], limits: FileListingLimits(), environment: git.environment) { roots, _, _ in
            await gate.enter()
            return try FileFinderIndex(roots: roots, listings: [FolderListing()], truncated: false)
        }
        async let first = finder.refreshed()
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(10))
        while await !gate.entered {
            guard clock.now < deadline else { return XCTFail("the listing never began") }
            try await Task.sleep(for: .milliseconds(5))
        }
        await finder.cancel()
        await gate.open()
        let stopped = await first
        XCTAssertNil(stopped, "what the stopped listing made is not kept, though it ended")
        let latest = await finder.latest
        XCTAssertNil(latest)
        let next = await finder.refreshed()
        XCTAssertNotNil(next, "the next listing is")
    }

    func testMakingAnIndexStopsOnceItsTaskIsCancelled() async {
        var listing = FolderListing()
        for index in 0..<5_000 { _ = listing.add([], Array("file-\(index).txt".utf8), limits: FileListingLimits()) }
        let made = listing
        let stopped = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try FileFinderIndex(roots: ["/project"], listings: [made], truncated: false); return false }
            catch { return error is CancellationError }
        }.value
        XCTAssertTrue(stopped)
    }

    func testGitIsToldWhereTheUserMovedItsConfiguration() {
        XCTAssertEqual(FinderProcess.gitEnvironment(from: ["XDG_CONFIG_HOME": "/Users/someone/config"])["XDG_CONFIG_HOME"], "/Users/someone/config")
        XCTAssertNil(FinderProcess.gitEnvironment(from: [:])["XDG_CONFIG_HOME"])
        XCTAssertNil(FinderProcess.gitEnvironment(from: ["XDG_CONFIG_HOME": ""])["XDG_CONFIG_HOME"])
    }
}

/// Holds whoever enters until it is opened.
private actor Gate {
    private(set) var entered = false
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}
