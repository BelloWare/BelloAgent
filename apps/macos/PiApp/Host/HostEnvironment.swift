import Foundation

enum HostEnvironment {
    static func values(toolsPATH: String, appVersion: String, benchmark: Bool) -> [String: String] {
        let environment = [
            "HOME": NSHomeDirectory(), "PATH": toolsPATH,
            "LANG": "en_US.UTF-8", "TMPDIR": ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory(),
            "PI_APP_VERSION": appVersion, "PI_APP_BENCHMARK": benchmark ? "1" : "0"
        ]
        #if PI_LAUNCH_FIXTURE || PI_TEST_HOST
        // Foundation resolves HOME independently in a child process.
        return environment.merging([
            "CFFIXED_USER_HOME": NSHomeDirectory(),
            "CODEX_HOME": URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        ]) { _, fixed in fixed }
        #else
        return environment
        #endif
    }
}
