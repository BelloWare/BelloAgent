import XCTest
import AppKit
@testable import PiApp

/// Recently opened chats are washed (0.1.122): the open chat's row has the
/// accent wash, the chats opened before it a fainter one, fading out over
/// four steps. The rank is the order of opening, not time, and it is kept
/// across a relaunch with the selection.
final class SidebarRecencyTests: XCTestCase {
    @MainActor private func model(_ ids: [String]) async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("recency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.chats = ids.enumerated().map { ChatRecord(id: $0.element, workspaceID: "project", title: $0.element, path: nil, profileID: "p", sidebarOrder: Int64(100 - $0.offset)) }
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        return (model, root)
    }

    /// The ladder: the open row's whole wash, then four fainter steps, then none.
    @MainActor func testTheWashFadesOverFourStepsAndNeverOutshinesTheOpenRow() throws {
        XCTAssertEqual((0..<7).map { PiKit.SelectableRow.recencyTint(rank: $0) }, [1, 0.75, 0.5, 0.3, 0.15, 0, 0])
        XCTAssertEqual(PiKit.SelectableRow.recencyTint(rank: nil), 0)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let row = PiKit.SelectableRow(content: NSView())
            row.appearance = NSAppearance(named: appearance)
            let wash = row.piCGColor(.piAccentSoft)
            for rank in 1...4 {
                row.recencyTint = PiKit.SelectableRow.recencyTint(rank: rank); row.styleFace()
                let fill = try XCTUnwrap(row.fill.backgroundColor)
                XCTAssertEqual(fill.alpha, wash.alpha * PiKit.SelectableRow.recencyLadder[rank], accuracy: 0.001, "\(appearance.rawValue) rank \(rank)")
                XCTAssertEqual(fill.components?.prefix(3).map { ($0 * 255).rounded() }, wash.components?.prefix(3).map { ($0 * 255).rounded() },
                               "the same accent as the open row's wash")
            }
            row.recencyTint = 0; row.styleFace()
            XCTAssertEqual(row.fill.backgroundColor?.alpha ?? 0, 0, "older chats are plain")
            // The open row keeps its own wash; a marked row its own fill.
            row.recencyTint = 0.75; row.selected = true; row.styleFace()
            XCTAssertEqual(row.fill.backgroundColor?.alpha ?? 0, wash.alpha, accuracy: 0.001)
            row.selected = false; row.marked = true; row.styleFace()
            XCTAssertEqual(row.fill.backgroundColor, row.piCGColor(.piFill))
        }
    }

    /// The order of opening: the open chat first, a chat opened again moves
    /// to the front, a parent opened only on the way to its side does not.
    @MainActor func testTheRankIsTheOrderOfOpening() async throws {
        let (model, _) = try await model(["a", "b", "c", "d", "e", "f"])
        for id in ["a", "b", "c", "d", "e", "f", "b"] { model.focusedSessionID = id }
        XCTAssertEqual(model.recentlyOpened, ["b", "f", "e", "d", "c", "a"])
        XCTAssertEqual(["b", "f", "e", "d", "c", "a"].map { model.recencyRank($0) }, [0, 1, 2, 3, 4, nil], "five steps, then plain")
        await model.passingThrough("a") { model.focusedSessionID = "a" }
        model.focusedSessionID = "c"
        XCTAssertEqual(model.recentlyOpened.prefix(3), ["c", "b", "f"], "a parent passed through on the way to its side is not opened")
        // The rows carry it, and only the rank changes them: nothing else.
        let contents = model.sidebarGroupContents(in: try XCTUnwrap(model.workspaces.first), topicID: nil, archived: false, filter: "",
                                                  showEmpty: true, sidebarWidth: 300, namesConnection: false)
        func rank(_ id: String) throws -> Int? { try XCTUnwrap(contents.rows.first { $0.id == id }).state.recency }
        XCTAssertEqual(try rank("c"), 0); XCTAssertEqual(try rank("b"), 1)
        XCTAssertNil(try rank("a"), "opened six chats ago: plain")
        // Never more than the limit; a deleted chat leaves no gap.
        for index in 0..<40 { model.noteOpened("x\(index)") }
        XCTAssertEqual(model.recentlyOpened.count, WorkspaceModel.recentlyOpenedLimit)
    }

    /// Kept with the selection: a relaunch reads the same order back, for
    /// the chats that still exist; a New chat never sent is not kept.
    @MainActor func testTheOrderOfOpeningSurvivesARelaunch() async throws {
        let (model, root) = try await model(["a", "b", "c"])
        model.selectionMemory.enabled = true
        model.pendingChatIDs = ["new"]
        model.chats.append(ChatRecord(id: "new", workspaceID: "project", title: ChatRecord.defaultTitle, path: nil, profileID: "p"))
        for id in ["a", "c", "b", "new"] { model.focusedSessionID = id }
        XCTAssertEqual(model.recentlyOpened, ["new", "b", "c", "a"])
        XCTAssertEqual(model.selectionToRemember.recentChats, ["b", "c", "a"], "an unsent New chat is not kept")
        await model.flushSelection()
        let saved = try await model.store?.get(RememberedSelection.self, kind: RememberedSelection.recordKind, id: RememberedSelection.recordID)
        XCTAssertEqual(saved?.recentChats, ["b", "c", "a"])

        let relaunched = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(relaunched, root: root)
        relaunched.chats = model.chats.filter { $0.id != "c" }   // "c" was deleted meanwhile
        relaunched.adoptRememberedSelection(saved?.sanitized)
        XCTAssertEqual(relaunched.recentlyOpened, ["b", "a"])
        // A record written before 0.1.122 has none.
        let legacy = try JSONDecoder().decode(RememberedSelection.self, from: Data(#"{"chatID":"a","revision":1}"#.utf8))
        XCTAssertNil(legacy.recentChats)
        relaunched.adoptRememberedSelection(legacy)
        XCTAssertEqual(relaunched.recentlyOpened, [])
    }

    /// A row takes its wash from its rank, and a rank change redraws only
    /// the rows whose rank changed.
    @MainActor func testARowTakesItsWashFromItsRank() async throws {
        let (model, _) = try await model(["a", "b"])
        let chat = try XCTUnwrap(model.record("a"))
        let row = SidebarChatRowView(model: model, chat: chat, state: SidebarChatRowState(recency: 2), projectID: "project", glide: PiKit.SelectionGlide())
        XCTAssertEqual(row.row.recencyTint, 0.5)
        SidebarRowRenderCount.reset()
        row.apply(chat: chat, state: SidebarChatRowState(recency: 2), projectID: "project")
        XCTAssertEqual(SidebarRowRenderCount.builds, 0, "the same rank draws nothing again")
        row.apply(chat: chat, state: SidebarChatRowState(recency: nil), projectID: "project")
        XCTAssertEqual(row.row.recencyTint, 0)
    }
}
