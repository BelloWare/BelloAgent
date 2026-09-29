import XCTest
@testable import PiApp

/// A model catalog can say which models take images. A chat on such a model
/// takes images even when its connection does not say so, and its turns tell
/// the helper; the connection's own declaration still counts.
final class CatalogImageInputTests: XCTestCase {
    private func profile(input: [String]? = nil) -> ProfileRecord {
        var value = ProfileRecord(); value.id = "connection"; value.modelId = "text-model"
        value.baseUrl = "https://gateway.example/v1"
        if let input { value.advancedJSON = WireValue.object(["input": .array(input.map(WireValue.string))]).pretty }
        return value
    }

    func testTheCatalogsInputIsReadAsItsEffortsAre() throws {
        let body = Data(#"{"models":[{"id":"a","input":["text","image"]},{"id":"b","input":["image","text","image","video"]},{"id":"c","input":[]},{"id":"d"}]}"#.utf8)
        let parsed = try ModelCatalogEndpoint().parse(body)
        XCTAssertEqual(parsed.map(\.input), [["text", "image"], ["text", "image"], [], nil])
        XCTAssertEqual(parsed.map(\.takesImages), [true, true, false, false])
        for invalid in [#"{"models":[{"id":"a","input":"image"}]}"#, #"{"models":[{"id":"a","input":[1]}]}"#] {
            XCTAssertThrowsError(try ModelCatalogEndpoint().parse(Data(invalid.utf8)), invalid)
        }
    }

    @MainActor func testAChatOnAModelTheCatalogListsWithImagesTakesThem() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("catalog-input-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = [ModelDescriptor(id: "text-model", name: "Text", input: ["text"]),
                      ModelDescriptor(id: "vision-model", name: "Vision", input: ["text", "image"]),
                      ModelDescriptor(id: "unreported", name: "Unreported")]
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()),
                                       modelCatalog: ModelCatalog(readBundled: { listed }))
        defer { model.shutdown() }
        let connection = profile(); model.profiles = [connection]
        var chat = ChatRecord(id: "chat", workspaceID: "project", title: "New", path: nil, profileID: connection.id)
        model.chats = [chat]
        XCTAssertFalse(model.supportsImages(chat.id), "Nothing says so before the catalog loads")
        _ = await model.listModels(for: connection)
        XCTAssertFalse(model.supportsImages(chat.id), "The connection's model is listed as text only")
        XCTAssertNil(model.turnOverrides(for: chat)["input"])

        chat.model = "vision-model"; model.chats = [chat]
        XCTAssertTrue(model.supportsImages(chat.id))
        let params = model.turnOverrides(for: chat, base: ["text": .string("What is this?")])
        XCTAssertEqual(params["input"], .array([.string("text"), .string("image")]), "The helper hears it with the turn")
        XCTAssertEqual(params["model"], .string("vision-model")); XCTAssertEqual(params["text"], .string("What is this?"))

        chat.model = "unreported"; model.chats = [chat]
        XCTAssertFalse(model.supportsImages(chat.id), "A model the catalog says nothing about follows its connection")

        // The connection's own declaration lets images in, and the helper already has it.
        model.profiles = [profile(input: ["text", "image"])]
        XCTAssertTrue(model.supportsImages(chat.id))
        XCTAssertNil(model.turnOverrides(for: chat)["input"])
        await model.store?.close()
    }
}
