import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A connection's mini model, switched in Settings while the chat window's
/// model pickers are on screen, against the synthetic loopback gateway and
/// the packaged helper.
final class MiniModelSettingsTests: XCTestCase {
    /// Each save in Settings gives the connection a new revision, so the model
    /// pickers and Settings list its catalog again. Title suggestions asked
    /// right after joined that listing, and could read the catalog entry
    /// before the listing had written it: after the mini model was switched
    /// away and back, the request went out without the catalog's output
    /// limit, and the gateway refused fixture-fast's.
    @MainActor func testSuggestionsAfterSettingsSwitchesTheMiniModelAwayAndBackCarryItsCatalogOutputLimit() async throws {
        let folder = scratchRoot("mini-settings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Title suggestions are a utility request (0.1.115): the helper asks
        // for a short reply, well under either model's catalog ceiling, so the
        // gateway checks the limit as a ceiling, as it does a mini model's. A
        // request with no limit at all, the failure this test is for, is still
        // refused.
        let gateway = try await SyntheticGateway.start(in: folder, environment: ["PI_APP_UI_FIXTURE_LENIENT_LIMIT": "1"]); defer { gateway.stop() }
        let base = gateway.base
        // The gallery's two connections: both list the gateway's catalog and
        // use its mini model, fixture-fast, whose catalog output limit is
        // 16,000 tokens; each carries routing metadata.
        let workspace = WorkspaceRecord(id: "project", path: folder.path, trusted: true)
        let connections = ["ui-fixture", "fixture-fast"].map { alias -> VaultProfile in
            var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = alias; profile.catalogUrl = base + "/catalog"
            profile.contextWindow = alias == "fixture-fast" ? 128_000 : 2_000_000; profile.maxOutputTokens = alias == "fixture-fast" ? 16_000 : 300_000
            profile.modelOutputLimit = alias == "fixture-fast" ? 16_000 : 300_000
            profile.name = alias == "fixture-fast" ? "Team fast" : "Team router"
            profile.miniModelId = "fixture-fast"
            profile.advancedJSON = #"{"routing":{"replayPolicy":"portable","reference":"Synthetic UI gateway accounting contract v1","cacheHeader":"x-fixture-cache"}}"#
            return VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = connections; $0.automaticUpdateChecks = false
            $0.resources[workspace.id] = .object(["codexHome": .string(folder.appendingPathComponent("codex").path)])
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        defer { model.shutdown() }
        await model.restore()
        let profileID = connections[0].profile.id
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Harden the payment retry loop", path: nil, profileID: profileID)
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        // The chat window, whose model pickers list the connection's catalog
        // again after every save, and Settings beside it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let controller = ConnectionSettingsController(model: model)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: ProfileSettings(model: model, controller: controller, windowChrome: false)); settings.makeKeyAndOrderFront(nil)
        defer { settings.contentView = nil; settings.close() }
        await controller.load(discardingDrafts: true)
        controller.select(id: profileID)
        await controller.listModels()
        // Read as soon as the listing returns, as the suggestions below read it:
        // Settings' own list came back empty when its listing joined the pickers'.
        let offered = controller.listingEntry.descriptors
        let router = try XCTUnwrap(offered.first { $0.id == "ui-fixture" }, "Settings lists the catalog")
        let fast = try XCTUnwrap(offered.first { $0.id == "fixture-fast" }, "Settings lists the catalog")
        for round in 1...2 {
            for mini in [router, fast] {
                controller.chooseMini(mini)
                let saved = await controller.save()
                XCTAssertTrue(saved, controller.message)
                do {
                    let titles = try await model.suggestTitles(for: chat.id)
                    XCTAssertEqual(titles.count, 3)
                } catch { XCTFail("Round \(round), \(mini.id): \(error.localizedDescription)") }
                let request = try XCTUnwrap(model.chats.last { $0.backgroundTask == "title-suggestions" })
                XCTAssertEqual(request.model, mini.id)
                XCTAssertEqual(request.modelOutputLimit, mini.maxOutputTokens, "Round \(round), \(mini.id): the request carries the catalog's output limit")
            }
        }
        for host in model.hosts.values { try? await host.shutdownAndWait() }
        try? await model.traces.close(); await model.store?.close()
    }
}
