import AppKit
import XCTest
@testable import PiApp

/// What a large or slow model catalog costs the reader: the grants every turn
/// carries, the reads a connection being edited makes, and the picker's first
/// layout. The durations are printed and never asserted, because they belong
/// to the machine; the counts and the values are asserted.
final class CatalogLoadCostTests: XCTestCase {
    /// A generated catalog: limits, efforts and inputs vary so every branch of a grant is taken.
    private func descriptors(_ count: Int, family: String = "family") -> [ModelDescriptor] {
        (0..<count).map { index in
            ModelDescriptor(id: "provider-\(index % 37)/model-\(family)-\(index)", name: "Model \(family.capitalized) \(index)",
                            description: index.isMultiple(of: 3) ? "" : String(repeating: "Generated fixture model for catalog timing. ", count: 4),
                            contextWindow: index.isMultiple(of: 5) ? nil : 200_000 + index,
                            maxOutputTokens: index.isMultiple(of: 7) ? nil : 64_000 + index,
                            reasoning: index.isMultiple(of: 4) ? nil : index.isMultiple(of: 9) ? [] : ["low", "medium", "high"],
                            deprecated: index % 50 == 49, mini: index == 3 ? true : nil,
                            input: index.isMultiple(of: 6) ? nil : index.isMultiple(of: 2) ? ["text", "image"] : ["text"])
        }
    }
    private func profile(_ id: String = "fixture") -> ProfileRecord {
        var profile = ProfileRecord(); profile.id = id; profile.modelId = "provider-1/model-family-1"
        profile.baseUrl = "https://gateway.example/v1"; profile.catalogUrl = "https://gateway.example/catalog.json"
        profile.contextWindow = 128_000; profile.maxOutputTokens = 32_000
        profile.advancedJSON = #"{"reasoning":true,"thinkingLevel":"medium","input":["text"],"samplingParams":{"temperature":0.2}}"#
        return profile
    }
    private func chat(_ profile: ProfileRecord) -> ChatRecord {
        ChatRecord(id: "chat", workspaceID: WorkspaceRecord.scratchID, title: "Chat", path: nil, profileID: profile.id)
    }
    @MainActor private func workspace(_ profile: ProfileRecord, catalog: ModelCatalog) async throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("catalog-cost-" + UUID().uuidString)
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-catalog-key")]
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))), modelCatalog: catalog)
        try await model.reloadConfiguration()
        return model
    }
    private func milliseconds(_ work: () -> Void) -> Double {
        let began = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    }
    private func best(of runs: Int = 5, _ work: () -> Void) -> (best: Double, median: Double) {
        let all = (0..<runs).map { _ in milliseconds(work) }.sorted()
        return (all[0], all[all.count / 2])
    }

    /// The grants as they were first written: one profile resolved per model
    /// through `applying(to:)`, then a Codable round trip into the wire value.
    @MainActor private func referenceGrants(_ entry: ModelCatalog.Entry, chat: ChatRecord, profile: ProfileRecord) throws -> WireValue {
        let grants = entry.offered(current: chat.model ?? profile.modelId).map { descriptor in
            let effective = descriptor.applying(to: profile)
            var effort = chat.thinkingLevel ?? profile.configuration["thinkingLevel"]?.string
            if let choices = descriptor.reasoning,
               choices.isEmpty || effort.map({ $0 != "default" && !choices.contains($0) }) == true { effort = "default" }
            return SubagentModelGrant(model: descriptor.id, thinkingLevel: effort, contextWindow: effective.contextWindow,
                                      maxOutputTokens: effective.maxOutputTokens, modelOutputLimit: effective.modelOutputLimit,
                                      input: Array(Set(["text"] + WorkspaceModel.declaredInput(profile) + (descriptor.input ?? []))).sorted(),
                                      reasoning: descriptor.reasoning)
        }
        return try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(grants))
    }

    /// Every turn, session open and context preview carries the grants, worked
    /// out on the main actor: their cost must not grow with a JSON round trip
    /// per model, and their value must not change.
    @MainActor func testTurnGrantsKeepTheirValueForEveryCatalogSize() async throws {
        for count in [6, 30, 200, 2048] {
            let listed = descriptors(count)
            var connection = profile(); connection.id = "fixture-\(count)"
            let model = try await workspace(connection, catalog: ModelCatalog(fetchCatalog: { _, _ in listed }))
            _ = await model.listModels(for: connection)
            let entry = model.catalogEntry(for: connection)
            XCTAssertEqual(entry.descriptors.count, count)
            for (override, effort) in [(String?.none, String?.none), ("provider-12/model-family-49", "high"), ("manual-alias", "max"), (nil, "default")] {
                var item = chat(connection); item.model = override; item.thinkingLevel = effort
                XCTAssertEqual(model.subagentModels(for: item), try referenceGrants(entry, chat: item, profile: connection),
                               "\(count) models, model \(override ?? "default"), effort \(effort ?? "inherited")")
            }
            // A connection that declares nothing of its own.
            var plain = connection; plain.advancedJSON = nil
            XCTAssertEqual(try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(entry.subagentGrants(chat: chat(plain), profile: plain))),
                           try referenceGrants(entry, chat: chat(plain), profile: plain))
            let item = chat(connection)
            let cost = best { _ = model.turnOverrides(for: item) }
            print(String(format: "TIMING turnOverrides with %d catalog models: best %.2f ms, median %.2f ms", count, cost.best, cost.median))
        }
    }

    /// A connection being added or edited lists for the address and key typed
    /// so far. Choosing a model, naming the connection or changing a limit is
    /// not a different catalog: the second picker must not read it again.
    @MainActor func testEditingAnUnsavedConnectionReadsItsCatalogOncePerSource() async throws {
        let fetches = CatalogCostCounter(), listed = descriptors(30)
        let catalog = ModelCatalog(fetchCatalog: { _, _ in await fetches.hit(); return listed })
        let model = try await workspace(profile("saved"), catalog: catalog)
        var draft = profile("draft"); draft.revision = "unsaved"
        _ = await model.listModels(forDraft: draft, typedKey: "typed-key")
        var count = await fetches.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(catalog.entry(for: WorkspaceModel.draftListing(draft, typedKey: "typed-key")).descriptors.count, 30)

        // What choosing a model in the picker does to the draft, and a rename.
        draft = listed[2].applying(to: draft); draft.name = "Renamed"; draft.miniModelId = listed[3].id
        XCTAssertEqual(catalog.entry(for: WorkspaceModel.draftListing(draft, typedKey: "typed-key")).descriptors.count, 30,
                       "The list stays while the connection's other fields are edited")
        _ = await model.listModels(forDraft: draft, typedKey: "typed-key")
        count = await fetches.count; XCTAssertEqual(count, 1, "Choosing a model or renaming the connection is not another catalog")

        _ = await model.listModels(forDraft: draft, typedKey: "another-key")
        count = await fetches.count; XCTAssertEqual(count, 2, "Another key is another listing")
        draft.catalogUrl = "https://gateway.example/other.json"
        XCTAssertTrue(catalog.entry(for: WorkspaceModel.draftListing(draft, typedKey: "another-key")).descriptors.isEmpty,
                      "Another catalog address never shows the previous address's models")
        _ = await model.listModels(forDraft: draft, typedKey: "another-key")
        count = await fetches.count; XCTAssertEqual(count, 3, "Another catalog address is another listing")
        draft.baseUrl = "https://other-gateway.example/v1"
        _ = await model.listModels(forDraft: draft, typedKey: "another-key")
        count = await fetches.count; XCTAssertEqual(count, 4, "Another gateway decides anew whether the key travels")
    }

    /// A saved connection keeps its rule: every save is a new revision, and a
    /// new revision reads the catalog again even at the same address.
    @MainActor func testASavedConnectionsNewRevisionStillReadsItsCatalogAgain() async throws {
        let fetches = CatalogCostCounter(), listed = descriptors(6)
        let catalog = ModelCatalog(fetchCatalog: { _, _ in await fetches.hit(); return listed })
        var saved = profile()
        _ = await catalog.load(profile: saved) { "key" }
        _ = await catalog.load(profile: saved) { "key" }
        var count = await fetches.count; XCTAssertEqual(count, 1)
        saved.revision = "saved-again"
        XCTAssertTrue(catalog.entry(for: saved).descriptors.isEmpty, "A new revision never reads the previous revision's entry")
        _ = await catalog.load(profile: saved) { "key" }
        count = await fetches.count; XCTAssertEqual(count, 2)
        XCTAssertEqual(catalog.entry(for: saved).descriptors.count, 6)
    }

    /// The picker makes views for the rows in sight, however long the list,
    /// and a row measured once is not measured again by the next picker: one
    /// is made every time the list opens.
    @MainActor func testThePickerMeasuresACatalogOnceAndMakesOnlyTheRowsInSight() async throws {
        for count in [30, 200, 2048] {
            let listed = descriptors(count, family: "picker\(count)")
            var connection = profile(); connection.id = "picker-\(count)"; connection.modelId = listed[1].id
            let model = try await workspace(connection, catalog: ModelCatalog(fetchCatalog: { _, _ in listed }))
            _ = await model.listModels(for: connection)
            let offered = model.catalogEntry(for: connection).offered(current: connection.modelId).count
            func open() -> CatalogModelPickerView {
                let view = CatalogModelPickerView(model: model, profile: connection, current: connection.modelId) { _ in }
                view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
                view.layoutSubtreeIfNeeded()
                return view
            }
            var measured = CatalogModelPickerView.rowMeasurements
            var picker: CatalogModelPickerView?
            let first = milliseconds { picker = open() }
            let view = try XCTUnwrap(picker)
            // Once each, or twice where a legacy scroller narrows the rows.
            XCTAssertGreaterThanOrEqual(CatalogModelPickerView.rowMeasurements - measured, offered)
            XCTAssertLessThanOrEqual(CatalogModelPickerView.rowMeasurements - measured, offered * 2)
            let rows = Self.views(of: CatalogModelRow.self, in: view).filter { !$0.isHidden }
            XCTAssertFalse(rows.isEmpty)
            XCTAssertLessThan(rows.count, 40, "Rows are made for what is in sight, not for the whole catalog")
            let heights = rows.map(\.frame.height)
            // Read now: a search hands these row views to other models.
            let name = "catalog-choice-" + listed[0].id
            let before = try XCTUnwrap(rows.first { $0.accessibilityIdentifier() == name }).frame.height

            measured = CatalogModelPickerView.rowMeasurements
            var reopened: CatalogModelPickerView?
            let second = milliseconds { reopened = open() }
            XCTAssertEqual(CatalogModelPickerView.rowMeasurements, measured, "The list opened again measures nothing it has measured")
            let again = Self.views(of: CatalogModelRow.self, in: try XCTUnwrap(reopened)).filter { !$0.isHidden }
            XCTAssertEqual(again.map(\.frame.height), heights, "and lays its rows out as before")

            view.search.text = "\(count)-1"; view.search.onChange?("\(count)-1")
            let search = milliseconds { view.layoutSubtreeIfNeeded() }
            XCTAssertEqual(CatalogModelPickerView.rowMeasurements, measured, "A search measures nothing either")

            // The same alias listed with more words is another, taller row.
            var edited = listed; edited[0].description = String(repeating: "Listed with other words now. ", count: 6)
            let changed = edited
            var other = connection; other.id += "-changed"
            let relisted = try await workspace(other, catalog: ModelCatalog(fetchCatalog: { _, _ in changed }))
            _ = await relisted.listModels(for: other)
            let changedView = CatalogModelPickerView(model: relisted, profile: other, current: other.modelId) { _ in }
            changedView.frame = NSRect(origin: .zero, size: changedView.intrinsicContentSize); changedView.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(CatalogModelPickerView.rowMeasurements, measured)
            let after = try XCTUnwrap(Self.views(of: CatalogModelRow.self, in: changedView).first { !$0.isHidden && $0.accessibilityIdentifier() == name })
            XCTAssertGreaterThan(after.frame.height, before)
            print(String(format: "TIMING model picker with %d models: first opening %.1f ms, opened again %.1f ms, after a search %.1f ms, %d row views", count, first, second, search, rows.count))
        }
    }

    @MainActor private static func views<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { ($0 as? View).map { [$0] } ?? views(of: type, in: $0) }
    }
}

private actor CatalogCostCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}
