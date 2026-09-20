import XCTest
@testable import PiApp

/// Moving through many chats must not accumulate their in-memory pages.
final class WorkspaceDisplayMemoryTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("display-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor func testVisitingFiftyChatsKeepsOnlyTheRecentPagesAndReleasesTheRest() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        model.chats = (0..<50).map { ChatRecord(id: "chat-\($0)", workspaceID: "w", title: "Chat \($0)", path: nil, profileID: "p") }

        var released: [String: () -> Bool] = [:]
        for index in 0..<50 {
            let id = "chat-\(index)"
            await model.select(id)
            let page = try XCTUnwrap(model.displays[id])
            // Give each page a body, as a visited chat has.
            page.messages = (0..<40).map { .init(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: String(repeating: "x", count: 4_000)) }
            weak var weakPage = page
            released[id] = { weakPage == nil }
            XCTAssertLessThanOrEqual(model.displays.count, 8, "hidden idle pages must be dropped as the reader moves on")
        }
        // Drop the last strong reference the model itself keeps to the newest page.
        model.selected = nil
        await model.select("chat-49")
        for _ in 0..<50 { await Task.yield() }

        let live = released.filter { !$0.value() }.keys.sorted()
        XCTAssertLessThanOrEqual(live.count, 8, "visiting 50 chats must not retain 50 transcript pages: \(live)")
        XCTAssertTrue(released["chat-0"]?() == true, "the first chat's page must be gone after 49 more")
        XCTAssertEqual(model.displays.count, min(8, model.displays.count))
        try await model.traces.close(); await model.store?.close()
    }

    /// A chat that is still working keeps its page even when it scrolls out of
    /// the retained window, and gets collected once the work ends.
    @MainActor func testAWorkingChatKeepsItsPageUntilTheWorkEnds() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        model.chats = (0..<20).map { ChatRecord(id: "chat-\($0)", workspaceID: "w", title: "Chat \($0)", path: nil, profileID: "p") }
        await model.select("chat-0")
        let busy = try XCTUnwrap(model.displays["chat-0"])
        busy.state = "running"
        for index in 1..<20 { await model.select("chat-\(index)") }
        XCTAssertNotNil(model.displays["chat-0"], "a running chat's page must survive being scrolled past")
        busy.state = "idle"
        for index in 1..<20 { await model.select("chat-\(index)") }
        XCTAssertNil(model.displays["chat-0"], "once the work ends the page is droppable again")
        try await model.traces.close(); await model.store?.close()
    }
}
