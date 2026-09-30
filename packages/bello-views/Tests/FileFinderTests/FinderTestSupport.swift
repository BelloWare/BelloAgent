import Foundation
import XCTest
@testable import FileFinder

/// git as the tests run it: a home of the test's own, so the user's global
/// configuration and ignore file play no part, and a known author.
struct TestGit {
    let home: URL
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
         "GIT_CONFIG_NOSYSTEM": "1", "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0",
         "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
         "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
    }

    init(_ root: URL) throws {
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Runs git in `folder`: its output, failing the test when git fails.
    @discardableResult
    func run(_ arguments: [String], in folder: URL, input: Data? = nil, allowFailure: Bool = false,
             file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(String(decoding: diagnostics, as: UTF8.self))", file: file, line: line)
        }
        return data
    }

    /// A new repository at `folder`, matching case as the finder does.
    func initialize(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: folder)
        try run(["config", "core.ignorecase", "false"], in: folder)
    }
}

/// Writes `text` to `path` below `root`, making the folders on the way.
func write(_ text: String, _ path: String, in root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// An index of `paths` below one root, as a listing would give them.
func index(_ paths: [String], root: String = "/project") -> FileFinderIndex {
    var listing = FolderListing()
    for path in paths { _ = listing.add([], Array(path.utf8), limits: FileListingLimits()) }
    return try! FileFinderIndex(roots: [root], listings: [listing], truncated: false)
}

/// A listing's paths, as strings.
func paths(_ listing: FolderListing) -> [String] {
    (0..<listing.count).map { String(decoding: listing.path($0), as: UTF8.self) }
}
