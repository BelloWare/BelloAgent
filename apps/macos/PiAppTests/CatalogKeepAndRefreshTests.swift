import AppKit
import XCTest
@testable import PiApp

/// The two things the owner chose for catalog loading (2026-11-12: "Do both
/// for catalog loading"): the last good catalog is kept on disk and is there
/// at once at launch, and a list in hand is used while a fresh read replaces
/// it behind. Every wait here is on a catalog address held shut by the test,
/// never on a clock.
final class CatalogKeepAndRefreshTests: XCTestCase {
    private func list(_ names: [String], window: Int = 200_000) -> [ModelDescriptor] {
        names.map { ModelDescriptor(id: $0, name: $0.capitalized, description: "Listed as \($0).", contextWindow: window, maxOutputTokens: 64_000, reasoning: ["low", "high"]) }
    }
    private func profile(_ id: String = "kept") -> ProfileRecord {
        var profile = ProfileRecord(); profile.id = id; profile.modelId = "alpha"
        profile.baseUrl = "https://gateway.example/v1"; profile.catalogUrl = "https://gateway.example/catalog.json?token=QUERY-SECRET"
        profile.contextWindow = 128_000; profile.maxOutputTokens = 32_000
        return profile
    }
    private func folder() -> URL {
        let url = URL(fileURLWithPath: scratchBase()).appendingPathComponent("catalog-kept-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func source(_ profile: ProfileRecord) -> String {
        ModelCatalogStore.source(api: profile.api, baseUrl: profile.baseUrl, catalogUrl: profile.catalogUrl)
    }
    @MainActor private func catalog(_ address: CatalogAddress, store: ModelCatalogStore?, clock: CatalogClock = CatalogClock()) -> ModelCatalog {
        ModelCatalog(now: { clock.date }, readBundled: { XCTFail("A custom catalog never reads the bundle"); return [] },
                     fetchCatalog: { _, key in try await address.fetch(key: key) }, store: store)
    }
    /// A read that must not wait for the catalog's address. Failing after five
    /// seconds beats hanging the run when it does wait (the address is held).
    @MainActor private func atOnce(_ catalog: ModelCatalog, _ profile: ProfileRecord, key: String = "key", file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let done = CatalogFlag()
        let reading = Task { @MainActor in let models = await catalog.load(profile: profile) { key }; done.set(); return models }
        try await eventually("The read waited for the catalog's address", timeout: .seconds(5), file: file, line: line) { done.isSet }
        return await reading.value
    }
    @MainActor private func settled(_ catalog: ModelCatalog, _ profile: ProfileRecord) async throws {
        try await eventually("The catalog read never finished") { !catalog.entry(for: profile).loading && catalog.entry(for: profile).fetchedAt != nil }
    }
    @MainActor private func stored(_ store: ModelCatalogStore, _ profile: ProfileRecord, _ names: [String]) async throws {
        let source = source(profile)
        try await eventually("The list was never kept", until: { await store.read(connection: profile.id, source: source)?.descriptors.map(\.id) == names })
    }
    @MainActor private func workspace(_ profiles: [ProfileRecord], root: URL, catalog: ModelCatalog?) async throws -> WorkspaceModel {
        var configuration = VaultConfiguration()
        configuration.profiles = profiles.map { VaultProfile(profile: $0, apiKey: "synthetic-catalog-key") }
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))), modelCatalog: catalog)
        try await model.reloadConfiguration()
        return model
    }
    @MainActor private static func views<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { ($0 as? View).map { [$0] } ?? views(of: type, in: $0) }
    }
    @MainActor private func rows(_ picker: CatalogModelPickerView) -> [String] {
        // No popover hosts it here: give it the size it asks for, as one would.
        if picker.frame.size != picker.intrinsicContentSize { picker.setFrameSize(picker.intrinsicContentSize) }
        picker.layoutSubtreeIfNeeded()
        return Self.views(of: CatalogModelRow.self, in: picker).filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
            .map { ($0.accessibilityIdentifier()).replacingOccurrences(of: "catalog-choice-", with: "") }
    }
    @MainActor private func words(_ picker: CatalogModelPickerView) -> String {
        picker.layoutSubtreeIfNeeded()
        return Self.views(of: ShellText.self, in: picker).filter { !$0.isHidden && $0.superview != nil }.map(\.text).joined(separator: "\n")
            + "\n" + Self.views(of: PiKit.TextLine.self, in: picker).filter { !$0.isHidden }.map(\.line.text).joined(separator: "\n")
    }

    // MARK: The last good catalog, kept

    /// A launch has the list the connection last read before its address answers, and the answer replaces it.
    @MainActor func testALaunchHasTheLastGoodCatalogAtOnceAndAFreshReadReplacesItBehind() async throws {
        let store = ModelCatalogStore(directory: folder()), address = CatalogAddress(list(["alpha", "beta"])), connection = profile()
        let first = catalog(address, store: store)
        let read = await first.load(profile: connection) { "synthetic-catalog-key" }
        XCTAssertEqual(read, ["alpha", "beta"])
        try await stored(store, connection, ["alpha", "beta"])

        // The app is quit and opened again; the address is slow to answer and has a new list.
        await address.answer(list(["alpha", "gamma"], window: 100_000)); await address.hold()
        let relaunched = catalog(address, store: store)
        let atOnce = try await atOnce(relaunched, connection, key: "synthetic-catalog-key")
        XCTAssertEqual(atOnce, ["alpha", "beta"], "The list in hand is returned while the address has not answered")
        var entry = relaunched.entry(for: connection)
        XCTAssertEqual(entry.descriptors, list(["alpha", "beta"]), "with its limits")
        XCTAssertNotNil(entry.fetchedAt); XCTAssertNil(entry.error)
        XCTAssertTrue(entry.loading, "The fresh read is under way behind it")
        try await eventually("The fresh read never started", until: { await address.calls == 2 })
        // More callers meanwhile: the same list, no second read.
        let again = try await self.atOnce(relaunched, connection, key: "synthetic-catalog-key")
        XCTAssertEqual(again, ["alpha", "beta"])
        let calls = await address.calls; XCTAssertEqual(calls, 2)

        await address.release()
        try await settled(relaunched, connection)
        entry = relaunched.entry(for: connection)
        XCTAssertEqual(entry.models, ["alpha", "gamma"]); XCTAssertEqual(entry.descriptor(for: "alpha")?.contextWindow, 100_000)
        try await stored(store, connection, ["alpha", "gamma"])
    }

    /// An address that fails, or does not answer, leaves the kept list in use and says so where a failed refresh is reported.
    @MainActor func testAFailedReadAtLaunchKeepsTheLastGoodCatalogAndReportsTheFailure() async throws {
        let store = ModelCatalogStore(directory: folder()), address = CatalogAddress(list(["alpha", "beta"])), connection = profile()
        _ = await catalog(address, store: store).load(profile: connection) { "key" }
        try await stored(store, connection, ["alpha", "beta"])

        await address.fail(.unavailable)
        let relaunched = catalog(address, store: store)
        let atOnce = try await atOnce(relaunched, connection)
        XCTAssertEqual(atOnce, ["alpha", "beta"])
        try await eventually("The failed read was never reported") { relaunched.entry(for: connection).error != nil }
        let entry = relaunched.entry(for: connection)
        XCTAssertEqual(entry.error, ModelCatalogEndpoint.Failure.unavailable.errorDescription)
        XCTAssertEqual(entry.descriptors, list(["alpha", "beta"]), "A failed read never empties a list that had models")
        XCTAssertFalse(entry.loading)
        try await stored(store, connection, ["alpha", "beta"])
        // Not asked again for thirty seconds; the list keeps answering.
        let after = try await self.atOnce(relaunched, connection)
        XCTAssertEqual(after, ["alpha", "beta"])
        let calls = await address.calls; XCTAssertEqual(calls, 2)
    }

    /// A kept list belongs to one connection and one source. Another catalog address, another gateway, another API or
    /// another connection never shows it, and a connection that goes back to an earlier address starts from nothing.
    @MainActor func testAKeptCatalogIsNeverShownForAnotherSourceGatewayOrConnection() async throws {
        let store = ModelCatalogStore(directory: folder()), address = CatalogAddress(list(["alpha", "beta"])), connection = profile()
        _ = await catalog(address, store: store).load(profile: connection) { "key" }
        try await stored(store, connection, ["alpha", "beta"])

        var otherAddress = connection; otherAddress.catalogUrl = "https://gateway.example/other.json"; otherAddress.revision = "edited-1"
        var otherGateway = connection; otherGateway.baseUrl = "https://elsewhere.example/v1"; otherGateway.revision = "edited-2"
        var otherConnection = connection; otherConnection.id = "another"
        for changed in [otherAddress, otherGateway, otherConnection] {
            await address.answer(list(["alpha", "beta"])); await address.hold()
            let relaunched = catalog(address, store: store)
            let before = await address.calls
            let reading = Task { await relaunched.load(profile: changed) { "key" } }
            try await eventually("The read never started", until: { await address.calls == before + 1 })
            XCTAssertTrue(relaunched.entry(for: changed).descriptors.isEmpty, "Nothing of the other source is shown as this one's")
            XCTAssertFalse(reading.isCancelled)
            await address.answer(list(["delta"])); await address.release()
            let read = await reading.value
            XCTAssertEqual(read, ["delta"])
        }
        // The first connection's file now holds what the other address and then the other gateway listed.
        try await stored(store, otherGateway, ["delta"])
        await address.hold()
        let back = catalog(address, store: store)
        let before = await address.calls
        let reading = Task { await back.load(profile: connection) { "key" } }
        try await eventually("The read never started", until: { await address.calls == before + 1 })
        XCTAssertTrue(back.entry(for: connection).descriptors.isEmpty, "The earlier address's list was replaced, not kept beside")
        await address.release(); _ = await reading.value
    }

    /// The saved revision changes with every save (the key may have changed). The same source keeps its list meanwhile.
    @MainActor func testASavedConnectionKeepsItsListWhileItsNewRevisionIsRead() async throws {
        let store = ModelCatalogStore(directory: folder()), address = CatalogAddress(list(["alpha", "beta"])), connection = profile()
        let catalog = catalog(address, store: store)
        _ = await catalog.load(profile: connection) { "key" }
        try await stored(store, connection, ["alpha", "beta"])
        var saved = connection; saved.revision = "saved-again"; saved.name = "Renamed"
        await address.answer(list(["alpha", "beta", "gamma"])); await address.hold()
        let atOnce = try await atOnce(catalog, saved)
        XCTAssertEqual(atOnce, ["alpha", "beta"])
        XCTAssertTrue(catalog.entry(for: connection).descriptors.isEmpty, "The replaced revision's record reads nothing")
        try await eventually("A new revision reads its catalog again", until: { await address.calls == 2 })
        await address.release()
        try await settled(catalog, saved)
        XCTAssertEqual(catalog.entry(for: saved).models, ["alpha", "beta", "gamma"])
    }

    /// Nothing that could authenticate anywhere is written: no key, no header and not the catalog's address.
    @MainActor func testTheKeptFileHoldsModelsAndNoAddressKeyOrHeader() async throws {
        let directory = folder(), store = ModelCatalogStore(directory: directory), address = CatalogAddress(list(["alpha"])), connection = profile()
        _ = await catalog(address, store: store).load(profile: connection) { "synthetic-catalog-key" }
        try await stored(store, connection, ["alpha"])
        let keys = await address.keys; XCTAssertEqual(keys, ["synthetic-catalog-key"], "The fixture did send its key")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = String(decoding: try Data(contentsOf: files[0]), as: UTF8.self)
        for secret in ["synthetic-catalog-key", "QUERY-SECRET", "gateway.example", "catalog.json", "Authorization", "Bearer", connection.id, connection.revision] {
            XCTAssertFalse(text.contains(secret), "\(secret) was written with the kept catalog")
        }
        XCTAssertTrue(text.contains("\"alpha\""))
        XCTAssertFalse(files[0].lastPathComponent.contains(connection.id))
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    /// A connection still being added or edited is not a saved connection: nothing is kept for it.
    @MainActor func testAConnectionBeingEditedKeepsNothing() async throws {
        let directory = folder(), store = ModelCatalogStore(directory: directory), address = CatalogAddress(list(["alpha"]))
        let catalog = catalog(address, store: store)
        let draft = WorkspaceModel.draftListing(profile(), typedKey: "typed-key")
        let read = await catalog.load(profile: draft) { "typed-key" }
        XCTAssertEqual(read, ["alpha"])
        // A saved connection's list is kept by the same catalog, so the write path is live.
        _ = await catalog.load(profile: profile("saved")) { "key" }
        try await stored(store, profile("saved"), ["alpha"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
        let none = await store.read(connection: draft.id, source: source(draft)); XCTAssertNil(none)
    }

    /// A file this app did not write, or cannot have written, is as if nothing were kept.
    @MainActor func testADamagedOrForeignKeptFileIsIgnored() async throws {
        let directory = folder(), store = ModelCatalogStore(directory: directory), connection = profile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = await store.file(for: connection.id), kept = source(connection)
        let model = #"{"id":"alpha","name":"Alpha","description":"","deprecated":false}"#
        let damaged: [String] = [
            "not json",
            #"{"version":2,"source":"\#(kept)","savedAt":1,"models":[\#(model)]}"#,
            #"{"version":1,"source":"another-source","savedAt":1,"models":[\#(model)]}"#,
            #"{"version":1,"source":"\#(kept)","savedAt":1,"models":[\#(model),\#(model)]}"#,
            #"{"version":1,"source":"\#(kept)","savedAt":1,"models":[{"id":" padded ","name":"","description":"","deprecated":false}]}"#,
            #"{"version":1,"source":"\#(kept)","savedAt":1,"models":[\#((0...2048).map { #"{"id":"m\#($0)","name":"","description":"","deprecated":false}"# }.joined(separator: ","))]}"#,
        ]
        for text in damaged {
            try Data(text.utf8).write(to: file)
            let read = await store.read(connection: connection.id, source: kept)
            XCTAssertNil(read, String(text.prefix(60)))
        }
        try Data(#"{"version":1,"source":"\#(kept)","savedAt":1,"models":[\#(model)]}"#.utf8).write(to: file)
        let read = await store.read(connection: connection.id, source: kept)
        XCTAssertEqual(read?.descriptors.map(\.id), ["alpha"])
        // A damaged file does not stop the catalog: it reads its address as if nothing were kept.
        try Data("not json".utf8).write(to: file)
        let address = CatalogAddress(list(["fresh"]))
        let fresh = await catalog(address, store: store).load(profile: connection) { "key" }
        XCTAssertEqual(fresh, ["fresh"])
    }

    /// The app's own catalog keeps its lists under its state folder; a connection deleted, or no longer saved, loses its list.
    @MainActor func testTheAppKeepsACatalogUnderItsStateFolderAndDropsItWithItsConnection() async throws {
        let root = folder(), kept = root.appendingPathComponent("ModelCatalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let listed = root.appendingPathComponent("fixture.models.json")
        try Data(#"{"models":[{"id":"alpha","contextWindow":200000},{"id":"beta"}]}"#.utf8).write(to: listed)
        var connection = profile("on-disk"); connection.catalogUrl = listed.path
        var other = profile("other"); other.catalogUrl = listed.path
        var model = try await workspace([connection, other], root: root, catalog: nil)
        var read = await model.listModels(for: connection); XCTAssertEqual(read, ["alpha", "beta"])
        _ = await model.listModels(for: other)
        try await eventually("The app never kept its catalogs") { ((try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? []).count == 2 }
        model.shutdown(); await model.store?.close()

        // The catalog file is gone at the next launch: the kept list answers, and the failure is reported.
        try FileManager.default.removeItem(at: listed)
        model = try await workspace([connection, other], root: root, catalog: nil)
        read = await model.listModels(for: connection)
        XCTAssertEqual(read, ["alpha", "beta"], "The last good catalog is there at once")
        try await eventually("The unreadable catalog was never reported") { model.catalogEntry(for: connection).error != nil }
        XCTAssertEqual(model.catalogEntry(for: connection).descriptor(for: "alpha")?.contextWindow, 200_000)

        try await model.deleteProfile(other.id)
        try await eventually("A deleted connection's kept catalog goes with it") { ((try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? []).count == 1 }
        XCTAssertTrue(model.modelCatalog.entry(for: other.id).descriptors.isEmpty)
        model.shutdown(); await model.store?.close()

        // A connection removed while the app was not looking (another save, an import) is dropped at the next load.
        model = try await workspace([], root: root, catalog: nil)
        try await eventually("A list kept for no saved connection stays") { ((try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? []).isEmpty }
    }

    // MARK: The list in hand, refreshed behind

    /// A list older than five minutes is used as it is and read again behind; only Refresh, or having nothing, waits.
    @MainActor func testAListOlderThanItsAgeIsUsedAtOnceAndRefreshedBehind() async throws {
        let address = CatalogAddress(list(["alpha", "beta"])), clock = CatalogClock(), connection = profile()
        let catalog = catalog(address, store: nil, clock: clock)
        // Nothing in hand: the first caller, and one who joins, wait for the read.
        await address.hold()
        let first = Task { await catalog.load(profile: connection) { "key" } }
        let joined = Task { await catalog.load(profile: connection) { "key" } }
        try await eventually("The first read never started", until: { await address.calls == 1 })
        XCTAssertTrue(catalog.entry(for: connection).descriptors.isEmpty)
        await address.release()
        let both = await (first.value, joined.value)
        XCTAssertEqual(both.0, ["alpha", "beta"]); XCTAssertEqual(both.1, ["alpha", "beta"])
        var calls = await address.calls; XCTAssertEqual(calls, 1)

        clock.date = clock.date.addingTimeInterval(301)
        await address.answer(list(["alpha", "gamma"])); await address.hold()
        let atOnce = try await atOnce(catalog, connection)
        XCTAssertEqual(atOnce, ["alpha", "beta"], "The list in hand answers; nobody waits for the address")
        XCTAssertTrue(catalog.entry(for: connection).loading)
        try await eventually("The list was never read again", until: { await address.calls == 2 })
        let more = try await self.atOnce(catalog, connection)
        XCTAssertEqual(more, ["alpha", "beta"])
        calls = await address.calls; XCTAssertEqual(calls, 2, "One read behind, however many ask meanwhile")
        // Refresh is the owner asking for the fresh list: it waits for the read under way.
        let refreshed = Task { await catalog.load(profile: connection, force: true) { "key" } }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(catalog.entry(for: connection).models, ["alpha", "beta"])
        await address.release()
        let fresh = await refreshed.value
        XCTAssertEqual(fresh, ["alpha", "gamma"])
        XCTAssertEqual(catalog.entry(for: connection).models, ["alpha", "gamma"])
        XCTAssertFalse(catalog.entry(for: connection).loading)
    }

    /// A refresh behind that fails keeps the list, reports the failure, waits thirty seconds and then tries again behind.
    @MainActor func testAFailedRefreshBehindKeepsTheListReportsTheFailureAndTriesAgainLater() async throws {
        let address = CatalogAddress(list(["alpha", "beta"])), clock = CatalogClock(), connection = profile()
        let catalog = catalog(address, store: nil, clock: clock)
        _ = await catalog.load(profile: connection) { "key" }
        clock.date = clock.date.addingTimeInterval(301)
        await address.fail(.http(503))
        let atOnce = try await atOnce(catalog, connection)
        XCTAssertEqual(atOnce, ["alpha", "beta"])
        try await eventually("The failed refresh was never reported") { catalog.entry(for: connection).error != nil }
        XCTAssertEqual(catalog.entry(for: connection).error, ModelCatalogEndpoint.Failure.http(503).errorDescription)
        XCTAssertEqual(catalog.entry(for: connection).descriptors, list(["alpha", "beta"]))
        clock.date = clock.date.addingTimeInterval(10)
        _ = await catalog.load(profile: connection) { "key" }
        var calls = await address.calls; XCTAssertEqual(calls, 2, "A failed address is left alone for thirty seconds")
        clock.date = clock.date.addingTimeInterval(31)
        await address.answer(list(["alpha", "gamma"])); await address.hold()
        let later = try await self.atOnce(catalog, connection)
        XCTAssertEqual(later, ["alpha", "beta"], "The retry is behind the list too")
        try await eventually("The address was never tried again", until: { await address.calls == 3 })
        await address.release()
        try await eventually("The retry never landed") { catalog.entry(for: connection).models == ["alpha", "gamma"] }
        XCTAssertNil(catalog.entry(for: connection).error)
        calls = await address.calls; XCTAssertEqual(calls, 3)
    }

    /// An open picker shows the kept list at launch, takes the fresh one in place (same view, same scroll position,
    /// same chosen model), and says what it always said about a chosen model the new list no longer has.
    @MainActor func testAnOpenPickerShowsTheListInHandAndTakesTheFreshOneInPlace() async throws {
        let names = (0..<40).map { "model-\($0)" }
        let store = ModelCatalogStore(directory: folder()), address = CatalogAddress(list(names))
        var connection = profile(); connection.modelId = "model-1"
        _ = await catalog(address, store: store).load(profile: connection) { "key" }
        try await stored(store, connection, names)

        // Relaunch: the address does not answer yet. Its next list renames one model and drops the chosen one.
        var fresh = list(names.filter { $0 != "model-1" }); fresh[0].name = "Renamed"
        await address.answer(fresh); await address.hold()
        let model = try await workspace([connection], root: folder(), catalog: catalog(address, store: store))
        let picker = CatalogModelPickerView(model: model, profile: connection, current: connection.modelId) { _ in }
        picker.frame = NSRect(origin: .zero, size: picker.intrinsicContentSize)
        try await eventually("The picker never showed the kept list") { self.rows(picker).first == "model-0" }
        XCTAssertFalse(words(picker).contains("Loading models"), "The list is there; nothing says it is loading models")
        XCTAssertFalse(words(picker).contains("is not listed by this source"))
        let chosen = Self.views(of: CatalogModelRow.self, in: picker).filter { !$0.isHidden && $0.isChosen }.map { $0.accessibilityIdentifier() }
        XCTAssertEqual(chosen, ["catalog-choice-model-1"])
        let scroll = try XCTUnwrap(Self.views(of: NSScrollView.self, in: picker).first { $0.documentView != nil && !Self.views(of: CatalogModelRow.self, in: $0).isEmpty })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("The picker never drew the rows scrolled to") { !self.rows(picker).contains("model-0") }
        let inSight = rows(picker)

        await address.release()
        try await eventually("The fresh list never reached the open picker") { !model.catalogEntry(for: connection).loading }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 600, "The list stays where the reader had scrolled it")
        XCTAssertFalse(rows(picker).contains("model-0")); XCTAssertEqual(rows(picker).count, inSight.count)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("The fresh rows never showed") { self.rows(picker).first == "model-0" }
        XCTAssertFalse(rows(picker).contains("model-1"), "The model the new list dropped is not offered")
        XCTAssertTrue(words(picker).contains("Renamed"))
        XCTAssertTrue(words(picker).contains("Current selection “model-1” is not listed by this source. It remains selected until you choose another model."),
                      "A chosen model the catalog no longer lists reads as it always has")
    }

    /// A turn takes its limits when it is sent. A refresh that lands afterwards changes neither that turn nor the
    /// limits the chat stored when its model was chosen; the next thing that reads the catalog sees the new list.
    @MainActor func testARefreshNeverChangesATurnAlreadySentOrAChatsChosenLimits() async throws {
        let address = CatalogAddress(list(["alpha", "beta"], window: 200_000)), clock = CatalogClock(), connection = profile()
        let catalog = catalog(address, store: nil, clock: clock)
        let model = try await workspace([connection], root: folder(), catalog: catalog)
        _ = await model.listModels(for: connection)
        var chat = ChatRecord(id: "chat", workspaceID: WorkspaceRecord.scratchID, title: "Chat", path: nil, profileID: connection.id)
        model.applyModelChoice("beta", to: &chat, profile: connection)
        XCTAssertEqual(chat.contextWindow, 200_000)
        let sent = model.turnOverrides(for: chat)
        XCTAssertEqual(sent["contextWindow"], .number(200_000))

        // The catalog now says the window is half the size; the refresh lands while that turn is running.
        clock.date = clock.date.addingTimeInterval(301)
        await address.answer(list(["alpha", "beta"], window: 100_000))
        _ = await model.listModels(for: connection)
        try await eventually("The refresh never landed") { model.catalogEntry(for: connection).descriptor(for: "beta")?.contextWindow == 100_000 }
        XCTAssertEqual(sent["contextWindow"], .number(200_000), "What was sent is what was sent")
        XCTAssertEqual(chat.contextWindow, 200_000, "The chat keeps the limits it chose its model with")
        let next = model.turnOverrides(for: chat)
        XCTAssertEqual(next["contextWindow"], .number(200_000), "until the model is chosen again")
        let grant = next["subagentModels"]?.array?.first { $0.object?["model"]?.string == "beta" }
        XCTAssertEqual(grant?.object?["contextWindow"], .number(100_000), "What is read from the catalog each turn follows the fresh list")
        model.applyModelChoice("beta", to: &chat, profile: connection)
        XCTAssertEqual(chat.contextWindow, 100_000)
    }
}

/// A catalog address the test answers for: what it lists or fails with, whether it is held shut, and what it was sent.
private actor CatalogAddress {
    private var result: Result<[ModelDescriptor], ModelCatalogEndpoint.Failure>
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var keys: [String] = []
    init(_ models: [ModelDescriptor]) { result = .success(models) }
    func answer(_ models: [ModelDescriptor]) { result = .success(models) }
    func fail(_ failure: ModelCatalogEndpoint.Failure) { result = .failure(failure) }
    func hold() { held = true }
    func release() { held = false; waiting.forEach { $0.resume() }; waiting = [] }
    func fetch(key: String) async throws -> [ModelDescriptor] {
        calls += 1; keys.append(key)
        if held { await withCheckedContinuation { waiting.append($0) } }
        return try result.get()
    }
}

/// Read on the main actor only; the catalog's `now` runs there.
private final class CatalogFlag: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Read on the main actor only; the catalog's `now` runs there.
private final class CatalogClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}
