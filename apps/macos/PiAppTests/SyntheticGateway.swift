import XCTest
@testable import PiApp

// The synthetic loopback gateway (`fixtures/native/ui-gateway.py`) and the
// workspace most tests that drive the app against it start from. Fifteen
// classes each started the gateway with their own copy of the same twenty
// lines, and the copies had drifted: some stopped it without waiting for it
// to exit, and each read its greeting with one read that assumed the whole
// line had arrived.

/// The gateway, started for one test in a folder of the test's own.
final class SyntheticGateway: @unchecked Sendable {
    /// Immutable once started; `stop()` only signals and waits.
    let process: Process
    let port: Int
    /// `http://127.0.0.1:<port>`: a connection's `baseUrl`.
    let base: String

    /// The fixture's own script, found from this file as every test found it.
    static var script: URL {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        return repository.appendingPathComponent("fixtures/native/ui-gateway.py")
    }

    private init(process: Process, port: Int) {
        self.process = process; self.port = port; base = "http://127.0.0.1:\(port)"
    }

    /// Starts the gateway in `folder`, which it also uses as its temporary
    /// directory. `environment` adds the fixture's own knobs
    /// (`PI_APP_UI_FIXTURE_*`). The test is skipped when the fixture is not
    /// there. The caller stops it: `stop()`, or `startSyntheticGateway`,
    /// which stops it at the test's teardown.
    static func start(in folder: URL, environment: [String: String] = [:]) async throws -> SyntheticGateway {
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path]
        process.currentDirectoryURL = folder; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path]
            .merging(environment) { _, knob in knob }
        try process.run()
        // The greeting is one line, `{"port": N}`, and the gateway writes
        // nothing after it. Read to its end, however the pipe delivers it.
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { () -> Data in
            var data = Data()
            while !data.contains(UInt8(ascii: "\n")) {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return data
        }.value
        let line = greeting.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? greeting
        guard let port = try? JSONDecoder().decode([String: Int].self, from: line)["port"] else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw DidNotStart(greeting: String(decoding: greeting, as: UTF8.self))
        }
        return SyntheticGateway(process: process, port: port)
    }

    /// The gateway ran but never said which port it listens on: a failure,
    /// not a skip, as it always was.
    struct DidNotStart: Error, CustomStringConvertible {
        let greeting: String
        var description: String { "The synthetic gateway did not start; it said: " + greeting }
    }

    /// Stops the gateway and waits for it to exit. Harmless once it has.
    func stop() {
        guard process.isRunning else { return }
        process.terminate(); process.waitUntilExit()
    }
}

/// A folder of the test's own, the gateway serving it, and a vault with one
/// trusted project and the gateway's standard connection: the start of every
/// test that relaunches the app over the same state against the helper.
struct GatewayWorkspace {
    let root: URL
    /// The app's state root, which each launch in the test opens.
    let state: URL
    let base: String
    let vault: ConfigurationVault
    let workspace: WorkspaceRecord
    let profile: ProfileRecord
}

extension XCTestCase {
    /// Starts the gateway in `folder` and stops it, waiting for it to exit,
    /// when the test tears down.
    @MainActor func startSyntheticGateway(in folder: URL, environment: [String: String] = [:]) async throws -> SyntheticGateway {
        let gateway = try await SyntheticGateway.start(in: folder, environment: environment)
        addTeardownBlock { gateway.stop() }
        return gateway
    }

    /// A scratch folder named after `name`, removed at teardown; the gateway,
    /// stopped before the folder goes; the project `projectID` in the folder's
    /// `project`, holding the README the fixture's read tool reads when
    /// `readme` is set; and a vault with that project and the connection
    /// "Fixture" (`ui-fixture`, a 2M context and 300k output), whose Codex home
    /// is inside the folder too.
    @MainActor func gatewayWorkspace(_ name: String, projectID: String, readme: Bool = false,
                                     gatewayEnvironment: [String: String] = [:]) async throws -> GatewayWorkspace {
        let root = scratchRoot(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let gateway = try await startSyntheticGateway(in: root, environment: gatewayEnvironment)
        let workspace = WorkspaceRecord(id: projectID, path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        if readme {
            try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8)
                .write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("README.md"))
        }
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = gateway.base; profile.modelId = "ui-fixture"; profile.catalogUrl = gateway.base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        return GatewayWorkspace(root: root, state: root.appendingPathComponent("app-state"), base: gateway.base,
                                vault: vault, workspace: workspace, profile: profile)
    }
}
