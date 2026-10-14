import XCTest
import Darwin
@testable import PiApp

final class TestHostIsolationTests: XCTestCase {
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
