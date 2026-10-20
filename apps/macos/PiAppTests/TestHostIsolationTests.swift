import XCTest
import Darwin
@testable import PiApp

final class TestHostIsolationTests: XCTestCase {
    func testChildProcessesCannotRestoreInheritedHomeRoots() throws {
        guard hasIsolatedHost() else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let expected = [home, home, home + "/.codex"]
        for environment in [["HOME": "/synthetic/inherited", "CFFIXED_USER_HOME": "/synthetic/inherited",
                             "CODEX_HOME": "/synthetic/inherited-codex", "PI_FIXTURE_FLAG": "retained"], [:]] {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.environment = environment; child.standardOutput = output
            try child.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            let entries = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1) }
            let values = Dictionary(uniqueKeysWithValues: entries.filter { $0.count == 2 }.map { (String($0[0]), String($0[1])) })
            XCTAssertEqual(["HOME", "CFFIXED_USER_HOME", "CODEX_HOME"].map { values[$0] ?? "" }, expected)
            XCTAssertEqual(values["PI_FIXTURE_FLAG"], environment["PI_FIXTURE_FLAG"])
        }
        for (name, path) in zip(["HOME", "CFFIXED_USER_HOME", "CODEX_HOME"], expected) {
            XCTAssertEqual(ProcessInfo.processInfo.environment[name], path)
        }
    }

    // Verification must stop before any defaults/storage/Keychain access if
    // the boundary is broken; a non-fatal XCTAssert alone would keep running.
    private func hasIsolatedHost() -> Bool {
        guard Bundle.main.bundleIdentifier == "com.belloware.PiAppTests.Host",
              let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              let account = getpwuid(getuid()), let real = account.pointee.pw_dir else {
            XCTFail("Refusing verification outside the isolated test host")
            return false
        }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        guard home == URL(fileURLWithPath: fixed).resolvingSymlinksInPath(),
              home != URL(fileURLWithPath: String(cString: real)).resolvingSymlinksInPath() else {
            XCTFail("Refusing verification in the account's data home")
            return false
        }
        return true
    }

    func testDefaultsSupportAndCachesResolveInsideTheTestHome() throws {
        guard hasIsolatedHost() else { return }
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
        XCTAssertEqual(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath(), URL(fileURLWithPath: home).resolvingSymlinksInPath())
        for kind: FileManager.SearchPathDirectory in [.applicationSupportDirectory, .cachesDirectory] {
            let path = try XCTUnwrap(FileManager.default.urls(for: kind, in: .userDomainMask).first)
            XCTAssertTrue(path.path.hasPrefix(home + "/Library/"), path.path)
        }
        // This writes only the already-guarded test host domain.
        let key = "isolation-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("fixture", forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "fixture")
    }

    /// Terminal tests start real login shells. They read zsh's files from the
    /// test home, never the developer's: those (nvm, brew, rbenv) made each
    /// shell take seconds and five at once in the parallel lane outlast the
    /// tests' twenty-second waits.
    func testShellsStartedInTestsReadTheTestHomesFilesNotTheDevelopers() throws {
        guard hasIsolatedHost() else { return }
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["ZDOTDIR"], "The scheme names the shells' file folder")
        let account = String(cString: try XCTUnwrap(getpwuid(getuid())?.pointee.pw_dir))
        XCTAssertEqual(URL(fileURLWithPath: folder).resolvingSymlinksInPath(), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath())
        XCTAssertNotEqual(URL(fileURLWithPath: folder).resolvingSymlinksInPath(), URL(fileURLWithPath: account).resolvingSymlinksInPath())
    }

    @MainActor func testDefaultWorkspaceAndKeychainLockAreInTheTestHome() throws {
        guard hasIsolatedHost() else { return }
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
        let model = WorkspaceModel()
        XCTAssertTrue(model.root.path.hasPrefix(home + "/Library/Application Support/"), model.root.path)
        XCTAssertTrue(KeychainVaultStorage().lockURL.path.hasPrefix(home + "/Library/Application Support/"))
    }

    func testKeychainIsRejectedBeforeReadingOrWritingEvenWithTheProductionService() {
        guard hasIsolatedHost() else { return }
        let storage = KeychainVaultStorage()
        for operation in [{ _ = try storage.read() }, { try storage.replace(expected: nil, with: Data()) }] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertTrue(error.localizedDescription.contains("Keychain access is disabled in PiAppTestHost"))
            }
        }
    }
}
