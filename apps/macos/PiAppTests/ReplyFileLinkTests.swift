import XCTest
import AppKit
@testable import PiApp

final class ReplyFileLinkTests: XCTestCase {
    @MainActor private final class Trust { var allowed = true }
    @MainActor func testMarkdownEqualityIncludesWhetherFileLinksCanOpen() {
        let withoutAction = MarkdownBodyView(source: "`Sources/App.swift`")
        var withAction = withoutAction
        withAction.openFile = { _, _ in }
        XCTAssertNotEqual(withAction, withoutAction)
        withAction.openFile = nil
        XCTAssertEqual(withAction, withoutAction)
        withAction.resolveFile = { _ in nil }
        XCTAssertNotEqual(withAction, withoutAction)
    }

    private func files() throws -> URL {
        let root = scratchRoot("reply-file-links")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("a.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testExistingFilesAndLineSuffixesAreCachedAndFoldersAndMissingFilesAreNotLinked() async throws {
        let root = try files(), resolver = ReplyFileResolver()
        let context = ReplyFileResolver.Context(roots: [root.path], projects: [.init(path: root.path, trusted: true)])
        let expected = ReplyFileLocation(path: root.resolvingSymlinksInPath().appendingPathComponent("a.swift").path, line: 2)
        let first = await resolver.resolve("a.swift:2", in: context)
        let second = await resolver.resolve("a.swift:2", in: context)
        let checks = await resolver.fileChecks
        XCTAssertEqual(first, expected); XCTAssertEqual(second, expected)
        XCTAssertEqual(checks, 1, "a cache hit does no filesystem work")
        let missing = await resolver.resolve("missing.swift", in: context)
        let folder = await resolver.resolve(root.path, in: context)
        XCTAssertNil(missing); XCTAssertNil(folder)
    }

    func testResolvedPathsRespectNestedTrustAndAChangedTrustConfiguration() async throws {
        let root = try files(), resolver = ReplyFileResolver()
        let nested = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let secret = nested.appendingPathComponent("secret.swift")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.swift"), withDestinationURL: secret)
        let trusted = ReplyFileResolver.Context(roots: [root.path], projects: [.init(path: root.path, trusted: true)])
        let original = await resolver.resolve("alias.swift", in: trusted)
        XCTAssertNotNil(original)
        let protected = ReplyFileResolver.Context(roots: [root.path], projects: trusted.projects + [.init(path: nested.path, trusted: false)])
        let alias = await resolver.resolve("alias.swift", in: protected)
        let absolute = await resolver.resolve(secret.path, in: protected)
        let traversal = await resolver.resolve("private/../private/secret.swift", in: protected)
        XCTAssertNil(alias); XCTAssertNil(absolute); XCTAssertNil(traversal)
        let untrusted = ReplyFileResolver.Context(roots: [root.path], projects: [.init(path: root.path, trusted: false)])
        let revoked = await resolver.resolve("a.swift", in: untrusted)
        XCTAssertNil(revoked)
    }

    @MainActor func testOnlyCodeSpansBecomeFileLinksAndClickRevalidatesThem() async throws {
        let (surface, window) = MarkdownTextSurfaceTests.surface("Use `a.swift:2`; a.swift:2 in prose. `missing.swift`.")
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var requests: [String] = [], opened: ReplyFileLocation?
        let trust = Trust()
        surface.textView.resolveFile = { text in
            requests.append(text)
            return trust.allowed && text == "a.swift:2" ? ReplyFileLocation(path: "/project/a.swift", line: 2) : nil
        }
        surface.textView.openFile = { opened = ReplyFileLocation(path: $0, line: $1?.lowerBound) }
        let storage = try XCTUnwrap(surface.textView.textStorage)
        surface.textView.resolveFileLinks(in: NSRange(location: 0, length: storage.length))
        try await eventually("visible code paths resolved") { surface.textView.pendingFileLinks == 0 }
        XCTAssertEqual(Set(requests), ["a.swift:2", "missing.swift"])
        let first = (storage.string as NSString).range(of: "a.swift:2")
        let prose = (storage.string as NSString).range(of: "a.swift:2", options: .backwards)
        let link = try XCTUnwrap(storage.attribute(.link, at: first.location, effectiveRange: nil) as? URL)
        XCTAssertNil(storage.attribute(.link, at: prose.location, effectiveRange: nil))
        XCTAssertTrue(surface.textView.textView(surface.textView, clickedOnLink: link, at: first.location))
        try await eventually("the linked file opens at its line") { opened != nil }
        XCTAssertEqual(opened, ReplyFileLocation(path: "/project/a.swift", line: 2))
        opened = nil; trust.allowed = false
        let before = requests.count
        XCTAssertTrue(surface.textView.textView(surface.textView, clickedOnLink: link, at: first.location))
        try await eventually("click checked the revoked trust") { requests.count > before }
        XCTAssertNil(opened)
    }
}
