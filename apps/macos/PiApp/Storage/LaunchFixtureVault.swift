import Foundation

#if PI_LAUNCH_FIXTURE
// Launch measurements only (`scripts/perf-launch.sh`, docs/perf/launch-0.1.123.md).
// A build made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=PI_LAUNCH_FIXTURE`
// reads its configuration from the fixture file `PI_APP_LAUNCH_FIXTURE_VAULT`
// names, so a launch can be timed with synthetic projects and a loopback
// connection and never the Keychain, which such a build never opens (no
// fixture file: an empty configuration). Writes stay in memory. Release builds
// (`scripts/release.sh`) never set the condition: this file compiles to
// nothing there, and the app's only vault is the Keychain.
final class LaunchFixtureVaultStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private init(data: Data?) { self.data = data }
    static func fromEnvironment() -> LaunchFixtureVaultStorage {
        let path = ProcessInfo.processInfo.environment["PI_APP_LAUNCH_FIXTURE_VAULT"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return LaunchFixtureVaultStorage(data: path.flatMap { FileManager.default.contents(atPath: $0) })
    }
    func read() throws -> Data? { lock.withLock { data } }
    func replace(expected: Data?, with replacement: Data) throws {
        try lock.withLock {
            guard data == expected else { throw VaultError.conflict }
            data = replacement
        }
    }
}
#endif
