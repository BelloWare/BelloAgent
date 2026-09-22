import CryptoKit
import Foundation
import SwiftUI

/// The Settings sheet's connection editor, kept apart from the view so the
/// whole flow can be driven by tests: one draft per connection tab, so
/// switching tabs never loses an edit; a model list that works for a draft
/// before it is saved, with the key typed into the sheet; saves that use the
/// vault's current revision; and a deletion that reports what happened.
@MainActor final class ConnectionSettingsController: ObservableObject {
    /// Everything the form edits for one connection.
    struct Draft: Equatable {
        var profile: ProfileRecord
        var key = ""
        var headers = ""
        var advanced = "{}"
        var replayPolicy = "portable"
        var expectedModel = ""
        var replayContract = ""
        var metadataReference = ""
        var modelHeader = ""
        var deploymentHeader = ""
        var groupHeader = ""
        var cacheHeader = ""
        var allowFallbacks = false
        /// The form as it was loaded, for change detection and for the save's comparison.
        var baseline: SettingsConnectionForm

        static func loaded(_ profile: ProfileRecord, isSaved: Bool) -> Draft {
            let form = SettingsConnectionForm.loaded(profile, isSaved: isSaved), routing = form.routing
            var draft = Draft(profile: profile, baseline: form)
            draft.advanced = form.advanced; draft.replayPolicy = routing["replayPolicy"]?.string ?? "ask"
            draft.expectedModel = routing["expectedModel"]?.string ?? ""; draft.replayContract = routing["replayContract"]?.string ?? ""
            draft.metadataReference = routing["reference"]?.string ?? ""; draft.modelHeader = routing["modelHeader"]?.string ?? ""
            draft.deploymentHeader = routing["deploymentHeader"]?.string ?? ""; draft.groupHeader = routing["groupHeader"]?.string ?? ""
            draft.cacheHeader = routing["cacheHeader"]?.string ?? ""
            draft.allowFallbacks = form.allowFallbacks
            return draft
        }
        var form: SettingsConnectionForm {
            var routing: [String: WireValue] = ["replayPolicy": .string(replayPolicy)]
            for (name, value) in [("expectedModel", expectedModel), ("replayContract", replayContract), ("reference", metadataReference), ("modelHeader", modelHeader),
                                  ("deploymentHeader", deploymentHeader), ("groupHeader", groupHeader), ("cacheHeader", cacheHeader)] where !value.isEmpty { routing[name] = .string(value) }
            return SettingsConnectionForm(profile: profile, advanced: advanced, routing: routing, allowFallbacks: allowFallbacks)
        }
        /// Anything typed since the load, including a key or headers, which the vault never shows back.
        var edited: Bool { form != baseline || !key.isEmpty || !headers.isEmpty }
        var name: String { profile.name.isEmpty ? "Unnamed" : profile.name }
    }

    let model: WorkspaceModel
    @Published var draft: Draft
    /// Edits made on other tabs, by connection id, waiting to be saved or discarded.
    @Published private(set) var drafts: [String: Draft] = [:]
    @Published var preferences = VaultConfiguration()
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var loaded = false
    @Published var message = ""
    @Published var messageTone: PiTone = .neutral
    @Published var busy = false
    @Published var confirmingDelete = false

    init(model: WorkspaceModel) {
        self.model = model
        draft = Draft.loaded(ProfileRecord(), isSaved: false)
    }

    var isSaved: Bool { model.profiles.contains { $0.id == draft.profile.id } }
    var supportedAPI: Bool { draft.profile.api == LiteLLMConfiguration.supportedAPI }
    /// Whether a tab holds unsaved edits: the current draft or a stashed one.
    func isEdited(_ id: String) -> Bool { id == draft.profile.id ? draft.edited : drafts[id]?.edited == true }
    /// Every saved connection, then every unsaved draft. A tab shows the name as
    /// typed on it and carries a dot while its edits are unsaved.
    var tabs: [(String, String)] {
        let saved = model.profiles.map { profile -> (String, String) in
            let typed = profile.id == draft.profile.id ? draft.profile.name : drafts[profile.id]?.profile.name
            let name = typed ?? profile.name
            return (profile.id, (name.isEmpty ? "Unnamed" : name) + (isEdited(profile.id) ? " •" : ""))
        }
        let savedIDs = Set(model.profiles.map(\.id))
        var unsaved = drafts.values.filter { !savedIDs.contains($0.profile.id) }.sorted { $0.profile.id < $1.profile.id }
        if !savedIDs.contains(draft.profile.id), !unsaved.contains(where: { $0.profile.id == draft.profile.id }) { unsaved.append(draft) }
        let untitled = ProfileRecord().name
        return saved + unsaved.map { ($0.profile.id, $0.profile.name.isEmpty || $0.profile.name == untitled ? "New connection" : $0.profile.name + " · new") }
    }

    // MARK: Loading and choosing a tab

    /// The preferences as the vault held them when this sheet last read it, so
    /// a conflict retry can tell what this sheet changed from what another
    /// writer changed.
    private var preferencesBaseline = VaultConfiguration()
    /// Everything this sheet edited, reapplied onto whatever the vault holds
    /// now. Carrying the sheet's whole stale copy forward silently reverted a
    /// capture mode, retention or update toggle set from somewhere else.
    static func merging(_ edits: VaultConfiguration, from baseline: VaultConfiguration, onto current: VaultConfiguration) -> VaultConfiguration {
        var merged = current
        if edits.runtime != baseline.runtime { merged.runtime = edits.runtime }
        if edits.capture != baseline.capture { merged.capture = edits.capture }
        if edits.dashboard != baseline.dashboard { merged.dashboard = edits.dashboard }
        if edits.automaticUpdateChecks != baseline.automaticUpdateChecks { merged.automaticUpdateChecks = edits.automaticUpdateChecks }
        if edits.completionSoundEnabled != baseline.completionSoundEnabled { merged.completionSoundEnabled = edits.completionSoundEnabled }
        if edits.transcriptView != baseline.transcriptView { merged.transcriptView = edits.transcriptView }
        return merged
    }
    /// Reads the vault. Stashed edits survive a load caused by a save; the reload button discards them.
    func load(discardingDrafts: Bool) async {
        busy = true; defer { busy = false }
        do {
            try await model.reloadConfiguration()
            preferences = model.configuration; preferencesBaseline = model.configuration
            revision = preferences.revision; loaded = true
            if discardingDrafts { drafts = [:] }
            let current = draft.profile.id
            if let saved = model.profiles.first(where: { $0.id == current }) {
                if discardingDrafts || !draft.edited { draft = Draft.loaded(saved, isSaved: true) }
            } else if drafts[current] == nil || discardingDrafts {
                draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false)
            }
            message = "Settings loaded. Nothing has been sent to a gateway."; messageTone = .neutral
        } catch { message = error.localizedDescription; messageTone = .danger }
    }
    /// Shows another tab. The current tab's edits are kept and come back with it.
    func select(id: String) {
        guard id != draft.profile.id else { return }
        stash()
        if let stashed = drafts[id] { draft = stashed }
        else if let saved = model.profiles.first(where: { $0.id == id }) { draft = Draft.loaded(saved, isSaved: true) }
        else { return }
        confirmingDelete = false
    }
    /// Opens the unsaved connection tab, reusing one that is already being filled in.
    func startNew() {
        stash()
        let savedIDs = Set(model.profiles.map(\.id))
        // Dictionary order is unspecified, so with two unsaved connections "+"
        // used to jump to either one. Take them in the order the tabs show.
        if let pending = drafts.values.filter({ !savedIDs.contains($0.profile.id) }).min(by: { $0.profile.id < $1.profile.id }) { draft = pending }
        else { draft = Draft.loaded(ProfileRecord(), isSaved: false) }
        confirmingDelete = false
        message = "Fill in the new connection and save it."; messageTone = .neutral
    }
    private func stash() {
        if draft.edited { drafts[draft.profile.id] = draft } else { drafts[draft.profile.id] = nil }
    }
    /// Drops the current unsaved tab, or the current tab's edits, and returns to what the vault holds.
    func discardCurrent() {
        let id = draft.profile.id
        drafts[id] = nil
        if let saved = model.profiles.first(where: { $0.id == id }) { draft = Draft.loaded(saved, isSaved: true) }
        else { draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false) }
        confirmingDelete = false
    }

    // MARK: Models

    /// The profile whose catalog entry the pickers show: a saved connection
    /// whose route and catalog are unchanged lists through its source, as every
    /// other picker does; anything else lists for the draft itself.
    var listingProfile: ProfileRecord {
        if draft.key.isEmpty, let saved = model.profiles.first(where: { $0.id == draft.profile.id }),
           saved.baseUrl == draft.profile.baseUrl, saved.catalogUrl == draft.profile.catalogUrl, saved.api == draft.profile.api {
            return model.catalogProfile(for: saved)
        }
        return WorkspaceModel.draftListing(draft.profile, typedKey: draft.key)
    }
    var listingEntry: ModelCatalog.Entry { model.modelCatalog.entry(for: listingProfile) }
    @discardableResult
    func listModels(force: Bool = false) async -> [String] {
        await model.listModels(forDraft: draft.profile, typedKey: draft.key, force: force)
    }
    func choose(_ item: ModelDescriptor) {
        var candidate = draft.profile; candidate.advancedJSON = draft.advanced
        draft.profile = item.applying(to: candidate)
        draft.advanced = draft.profile.advancedJSON ?? "{}"
    }
    /// Choosing a utility model must not replace the chat model, context limits or its reasoning preferences.
    func chooseMini(_ item: ModelDescriptor) { draft.profile.miniModelId = item.id }
    func useCatalogMiniDefault() { draft.profile.miniModelId = nil }

    // MARK: Saving

    /// Saves every tab with edits, the current one last, and the preferences.
    /// Returns true when the sheet can close: everything saved and no route
    /// change created a new connection that needs explaining.
    func save(thenTest: Bool = false) async -> Bool {
        guard loaded else { message = "Wait for Settings to finish loading before saving."; messageTone = .danger; return false }
        busy = true; defer { busy = false }
        stash()
        let currentID = draft.profile.id
        let queue = drafts.values.filter { $0.edited && $0.profile.id != currentID }.sorted { $0.profile.id < $1.profile.id } + [draft]
        var forkNote: String? = nil
        var savedCurrentID = currentID
        for item in queue {
            do {
                let savedID = try await saveOnce(item)
                drafts[item.profile.id] = nil
                if savedID != item.profile.id {
                    forkNote = "Saved “\(item.name)” as a new connection because its API route changed. The previous connection stays for its earlier chats; delete it in its tab if you no longer need it."
                }
                if item.profile.id == currentID { savedCurrentID = savedID }
            } catch {
                // Stay on the tab that failed, with its edits and the reason.
                if item.profile.id != currentID { drafts[currentID] = draft; draft = item }
                drafts[item.profile.id] = nil
                message = error.localizedDescription; messageTone = .danger
                // In the window's banner as well as the footer, exactly as a
                // failed deletion is: a save that did not happen was silent, and
                // Escape or Cancel closed the sheet over it.
                model.error = "“\(item.name)” was not saved: " + error.localizedDescription
                return false
            }
        }
        preferences = model.configuration; preferencesBaseline = model.configuration; revision = preferences.revision
        draft = model.profiles.first(where: { $0.id == savedCurrentID }).map { Draft.loaded($0, isSaved: true) } ?? draft
        if thenTest { model.testConnection(profileID: savedCurrentID, confirmed: true) }
        messageTone = .neutral
        if let forkNote { message = forkNote; return false }
        message = "Saved to your Keychain."
        return true
    }
    /// One connection's save against the vault's current revision; a conflict from another save reloads and tries once more.
    private func saveOnce(_ item: Draft) async throws -> String {
        do {
            return try await item.form.save(to: model, comparedTo: item.baseline, key: item.key, headers: item.headers,
                                            preferences: preferences, expectedRevision: model.configuration.revision)
        } catch VaultError.conflict {
            try await model.reloadConfiguration()
            preferences = Self.merging(preferences, from: preferencesBaseline, onto: model.configuration)
            preferencesBaseline = model.configuration
            return try await item.form.save(to: model, comparedTo: item.baseline, key: item.key, headers: item.headers,
                                            preferences: preferences, expectedRevision: model.configuration.revision)
        }
    }

    // MARK: Deleting

    /// What the deletion touches: the key, the chats that keep their history, the runs that stop.
    var deletionSummary: String {
        let using = model.chats.filter { $0.profileID == draft.profile.id && $0.connectionTest != true && !$0.isBackgroundTask }
        let working = using.filter { model.displays[$0.id]?.hasWork == true }.count
        var parts = ["Its key leaves the Keychain item."]
        parts.append(using.isEmpty ? "No chat uses it." : using.count == 1 ? "One chat keeps its history and will need another connection."
                     : "\(using.count) chats keep their history and will need another connection.")
        if working > 0 { parts.append(working == 1 ? "One run will be stopped." : "\(working) runs will be stopped.") }
        return parts.joined(separator: " ")
    }
    func delete() async {
        let id = draft.profile.id, name = draft.name
        confirmingDelete = false
        busy = true; defer { busy = false }
        do {
            try await model.deleteProfile(id)
            drafts[id] = nil
            preferences = model.configuration; revision = preferences.revision
            draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false)
            messageTone = .neutral
            message = model.profiles.isEmpty ? "“\(name)” was deleted. Add a new connection to send messages."
                : "“\(name)” was deleted. \(model.profiles.count) connection\(model.profiles.count == 1 ? " remains" : "s remain")."
        } catch {
            // In the footer and in the window's banner: a deletion that did not happen is never quiet.
            messageTone = .danger
            message = "“\(name)” was not deleted: " + error.localizedDescription
            model.error = "Connection “\(name)” was not deleted: " + error.localizedDescription
        }
    }
}

extension WorkspaceModel {
    /// The catalog cache key for a connection as it is being edited, apart from
    /// the saved connection's own entry so other pickers keep their list.
    nonisolated static func draftListing(_ draft: ProfileRecord, typedKey: String = "") -> ProfileRecord {
        var probe = draft; probe.id = "draft:" + draft.id
        // A different key is a different listing: a failure cached for the empty key must not outlive typing one.
        probe.revision = typedKey.isEmpty ? "draft" : "draft:" + SHA256.hash(data: Data(typedKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return probe
    }
    /// Lists models for a connection as the Settings sheet edits it. A saved
    /// connection whose route and catalog are unchanged lists through its
    /// source; anything else lists for the draft itself, with the key typed
    /// into the sheet, or the saved key by id when nothing was typed. The
    /// bundled catalog needs no key at all.
    @discardableResult
    func listModels(forDraft draft: ProfileRecord, typedKey: String, force: Bool = false) async -> [String] {
        guard draft.api == LiteLLMConfiguration.supportedAPI else { return [] }
        // The same four fields `listingProfile` uses to choose the picker's
        // cache slot. Dropping `api` here sent the Messages -> Responses
        // conversion into the saved connection's listing, which refuses an
        // unsupported API and wrote nothing into the slot the picker reads.
        if typedKey.isEmpty, let saved = profiles.first(where: { $0.id == draft.id }),
           saved.api == draft.api, saved.baseUrl == draft.baseUrl, saved.catalogUrl == draft.catalogUrl {
            return await listModels(for: saved, force: force)
        }
        let id = draft.id
        return await modelCatalog.load(profile: Self.draftListing(draft, typedKey: typedKey), force: force) { [weak self] in
            guard let self else { throw HostError.failure("The project is closing.") }
            if GatewayModelDiscovery.validKey(typedKey) { return typedKey }
            let stored = try await self.vault.load().profiles.first { $0.profile.id == id }?.apiKey ?? ""
            guard GatewayModelDiscovery.validKey(stored) else { throw GatewayModelDiscovery.Failure.credential }
            return stored
        }
    }
}
