import XCTest
@testable import GitView

/// Opt-in, generated-only benchmark shared verbatim with the baseline package.
final class GitInventoryPerformanceTests: ViewsTestCase {
    @MainActor func testLargeRepositoryStatusAndChangesRefresh() async throws {
        guard let folder = ProcessInfo.processInfo.environment["BELLO_GIT_INVENTORY_BENCHMARK"] else {
            throw XCTSkip("Set BELLO_GIT_INVENTORY_BENCHMARK to a generated fixture folder")
        }
        let base = URL(fileURLWithPath: folder), root = base.appendingPathComponent("repository")
        let environment = ["PATH": "/usr/bin:/bin", "HOME": base.appendingPathComponent("home").path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        func git(_ arguments: [String], in directory: URL) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + arguments
            process.environment = environment; process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        if !FileManager.default.fileExists(atPath: base.appendingPathComponent("prepared").path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: environment["HOME"]!, withIntermediateDirectories: true)
            try git(["init", "-q", "--template=", "-b", "main"], in: root)
            for group in 0..<50 {
                let directory = root.appendingPathComponent("files-\(group)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in 0..<1_000 { try Data("base\n".utf8).write(to: directory.appendingPathComponent("file-\(file).txt")) }
            }
            let source = base.appendingPathComponent("module-source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try git(["init", "-q", "--template="], in: source)
            try Data("module\n".utf8).write(to: source.appendingPathComponent("file"))
            try git(["add", "file"], in: source); try git(["commit", "-qm", "Module"], in: source)
            for index in 0..<20 {
                try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "module-\(index)"], in: root)
            }
            try git(["add", "."], in: root); try git(["commit", "-qm", "50,000 files and 20 modules"], in: root)
            try Data("edit\n".utf8).write(to: root.appendingPathComponent("files-0/file-0.txt"))
            try Data().write(to: base.appendingPathComponent("prepared"))
        }
        #if BELLO_GIT_BENCHMARK_BASELINE
        print("GIT_BENCHMARK_BUILD baseline \(#filePath)")
        let service = GitService(environment: environment)
        #else
        print("GIT_BENCHMARK_BUILD branch \(#filePath)")
        let previousTrust = GitService.resolveTrust, repository = root.resolvingSymlinksInPath().path
        GitService.resolveTrust = { directory, _ in URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == repository }
        defer { GitService.resolveTrust = previousTrust }
        let service = GitService(environment: environment)
        #endif
        let count = Int(ProcessInfo.processInfo.environment["BELLO_GIT_BENCHMARK_SAMPLES"] ?? "25") ?? 25
        _ = try await service.status(in: root.path)
        var statusTimes: [Double] = [], refreshTimes: [Double] = []
        for _ in 0..<count {
            let start = ProcessInfo.processInfo.systemUptime
            let status = try await service.status(in: root.path)
            statusTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            XCTAssertEqual(status.entries.count, 1)
        }
        let controller = GitController(roots: [root.path], service: service)
        defer { controller.stop() }
        controller.setShown(true)
        let readyBy = ProcessInfo.processInfo.systemUptime + 30
        while controller.refreshesFinished == 0 || controller.loading || controller.diffLoading {
            guard ProcessInfo.processInfo.systemUptime < readyBy else { XCTFail("Changes did not finish its initial read: \(controller.notice)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await service.patchReview(in: root.path, path: "files-0/file-0.txt", staged: false)
        for _ in 0..<count {
            let finished = controller.refreshesFinished, start = ProcessInfo.processInfo.systemUptime
            await controller.refresh(automatic: true)
            _ = try await service.patchReview(in: root.path, path: "files-0/file-0.txt", staged: false)
            refreshTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            XCTAssertEqual(controller.refreshesFinished, finished + 1, controller.notice)
        }
        for (name, times) in [("status", statusTimes), ("changes", refreshTimes)] {
            let sorted = times.sorted()
            print("GIT_BENCHMARK \(name) n=\(count) median_ms=\(sorted[count / 2]) p95_ms=\(sorted[min(count - 1, count * 95 / 100)]) samples_ms=\(times)")
        }
    }
}
