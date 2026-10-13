import XCTest
@testable import PiApp

final class CostLimitOpeningTests: XCTestCase {
    @MainActor func testOpeningReconcilesADefaultChangedWhileTheSeedWasRead() async throws {
        let root = scratchRoot("cost-opening")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")]; $0.chatCostLimit = .unlimited
        }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p")
        let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host
        model.boundHostConnections[workspace.id] = host.connectionID
        var seedRead: CheckedContinuation<WireValue?, Never>?
        model.costSeedRead = { _ in await withCheckedContinuation { seedRead = $0 } }
        var finished = false
        let opening = Task { defer { finished = true }; return try await model.open(chat) }
        try await eventually("seed read held") { seedRead != nil }
        try await model.setDefaultCostLimit(.usd(1))
        XCTAssertFalse(model.opened.contains(chat.id))
        seedRead?.resume(returning: .object(["usd": .number(1), "reported": .number(1), "unreported": .number(0)])); seedRead = nil
        try await eventually("session open sent") { frames.contains { $0["method"]?.string == "session.open" } }
        let open = try XCTUnwrap(frames.first { $0["method"]?.string == "session.open" })
        XCTAssertEqual(view.costLimitSent?.wire, open["params"]?.object?["costLimit"], "Track the limit actually sent, even if Settings changed during the await")
        func reply(_ frame: [String: WireValue]) throws {
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object([:])]), connectionID: try XCTUnwrap(host.connectionID))
        }
        try reply(open)
        try await eventually("debug mode sent") { frames.contains { $0["method"]?.string == "debug.mode" } }
        try reply(try XCTUnwrap(frames.first { $0["method"]?.string == "debug.mode" }))
        try await eventually("opening reconciles or completes") { finished || frames.contains { $0["method"]?.string == "session.configure" } }
        let configure = frames.first { $0["method"]?.string == "session.configure" }
        XCTAssertEqual(configure?["params"]?.object?["costLimit"], .object(["usd": .number(1)]))
        if let configure { try reply(configure) }
        _ = try await opening.value
        XCTAssertEqual(view.costLimitSent, .usd(1))
        try await host.shutdownAndWait()
    }
}
