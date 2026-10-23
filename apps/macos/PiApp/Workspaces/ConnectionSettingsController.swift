import AppKit
import CryptoKit
import Foundation
import Combine

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
        func rebased(onto saved: ProfileRecord) -> Draft {
            var value = self
            // Saving normalizes the raw JSON; the editable advanced/routing
            // fields above retain the reader's changes independently of it.
            value.profile.revision = saved.revision; value.profile.advancedJSON = saved.advancedJSON
            value.baseline = SettingsConnectionForm.loaded(saved, isSaved: true)
            // The fallback toggle also lives in advanced JSON. Adopt the saved
            // spelling only when save's normalization proves it equivalent.
            if let current = try? value.form.normalizedProfile(), let baseline = try? value.baseline.normalizedProfile(),
               current.advancedJSON == baseline.advancedJSON { value.advanced = value.baseline.advanced }
            return value
        }
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
    /// A write to the vault under way (a save or a delete). Loading is busy
    /// but not saving: there is nothing to wait for before closing.
    @Published var saving = false
    private var requiresReloadBeforeWrite = false
    private var lateRefresh: Task<Void, Never>?
    private var lateSubmittedDraft: Draft?
    private var lateSubmittedPreferences: VaultConfiguration?
    @Published var confirmingDelete = false
    /// The Test Connection button asked once; the footer explains the request until Send or Cancel.
    @Published var confirmingTest = false
    /// The window this editor is shown in, for its questions.
    weak var presentationWindow: NSWindow?

    init(model: WorkspaceModel) {
        self.model = model
        draft = Draft.loaded(ProfileRecord(), isSaved: false)
        model.settingsEditors.add(self)
    }
    deinit { lateRefresh?.cancel() }

    var isSaved: Bool { model.profiles.contains { $0.id == draft.profile.id } }
    var supportedAPI: Bool { draft.profile.api == LiteLLMConfiguration.supportedAPI }
    /// Whether a tab holds unsaved edits: the current draft or a stashed one.
    func isEdited(_ id: String) -> Bool { id == draft.profile.id ? isEdited(draft) : drafts[id].map(isEdited) == true }
    private func isEdited(_ candidate: Draft) -> Bool {
        if candidate.edited { return true }
        guard let submitted = lateSubmittedDraft, submitted.profile.id == candidate.profile.id else { return false }
        return candidate.form != submitted.form || candidate.key != submitted.key || candidate.headers != submitted.headers
    }
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
    /// One preference this sheet edits: the section that shows it, whether
    /// two configurations differ in it, and how to carry it from one to the
    /// other. The unsaved-changes state, the section marks and the conflict
    /// merge all read this one list.
    private struct PreferenceField {
        let section: SettingsSection
        let differs: (VaultConfiguration, VaultConfiguration) -> Bool
        let take: (inout VaultConfiguration, VaultConfiguration) -> Void
    }
    private static let preferenceFields: [PreferenceField] = [
        .init(section: .usage, differs: { $0.capture.defaultMode != $1.capture.defaultMode }, take: { $0.capture.defaultMode = $1.capture.defaultMode }),
        .init(section: .usage, differs: { $0.capture.retentionDays != $1.capture.retentionDays }, take: { $0.capture.retentionDays = $1.capture.retentionDays }),
        .init(section: .usage, differs: { $0.capture.quotaBytes != $1.capture.quotaBytes }, take: { $0.capture.quotaBytes = $1.capture.quotaBytes }),
        .init(section: .usage, differs: { $0.capture.quotaUnlimited != $1.capture.quotaUnlimited }, take: { $0.capture.quotaUnlimited = $1.capture.quotaUnlimited }),
        .init(section: .usage, differs: { $0.dashboard != $1.dashboard }, take: { $0.dashboard = $1.dashboard }),
        .init(section: .usage, differs: { $0.chatCostLimit != $1.chatCostLimit }, take: { $0.chatCostLimit = $1.chatCostLimit }),
        .init(section: .chats, differs: { $0.transcriptView != $1.transcriptView }, take: { $0.transcriptView = $1.transcriptView }),
        .init(section: .chats, differs: { $0.completionSoundEnabled != $1.completionSoundEnabled }, take: { $0.completionSoundEnabled = $1.completionSoundEnabled }),
        .init(section: .chats, differs: { $0.webhook != $1.webhook }, take: { $0.webhook = $1.webhook }),
        .init(section: .chats, differs: { $0.briefSettings != $1.briefSettings }, take: { $0.chatBriefs = $1.chatBriefs }),
        .init(section: .connections, differs: { $0.retrySettings != $1.retrySettings }, take: { $0.retry = $1.retry }),
        .init(section: .app, differs: { $0.runtime != $1.runtime }, take: { $0.runtime = $1.runtime }),
        .init(section: .app, differs: { $0.automaticUpdateChecks != $1.automaticUpdateChecks }, take: { $0.automaticUpdateChecks = $1.automaticUpdateChecks }),
    ]
    static func merging(_ edits: VaultConfiguration, from baseline: VaultConfiguration, onto current: VaultConfiguration) -> VaultConfiguration {
        var merged = current
        for field in preferenceFields where field.differs(edits, baseline) { field.take(&merged, edits) }
        return merged
    }
    /// The sections holding unsaved edits: Connections for any tab's, the
    /// others for the preferences they show.
    var editedSections: Set<SettingsSection> {
        var sections = Set(Self.preferenceFields.filter { field in
            field.differs(preferences, preferencesBaseline) || lateSubmittedPreferences.map { field.differs(preferences, $0) } == true
        }.map(\.section))
        if isEdited(draft) || drafts.values.contains(where: { isEdited($0) }) { sections.insert(.connections) }
        return sections
    }
    /// Anything typed in Settings that the vault doesn't hold yet.
    var isDirty: Bool { !editedSections.isEmpty }
    private var preferencesEdited: Bool { Self.preferenceFields.contains { $0.differs(preferences, preferencesBaseline) } }
    /// Drops every unsaved edit, on every tab and in every section: Settings
    /// shows what the vault holds. Nothing is written.
    func discardAll() {
        drafts = [:]
        if let saved = model.profiles.first(where: { $0.id == draft.profile.id }) { draft = Draft.loaded(saved, isSaved: true) }
        else { draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false) }
        preferences = preferencesBaseline
        // Discard resets the comparison too: the late result should replace
        // discarded values, while anything typed after this must survive it.
        if lateSubmittedPreferences != nil { lateSubmittedPreferences = preferencesBaseline }
        if let id = lateSubmittedDraft?.profile.id { resetLateDraft(id) }
        confirmingDelete = false; confirmingTest = false
        message = ""; messageTone = .neutral
    }
    /// Reads the vault. Stashed edits survive a load caused by a save; the reload button discards them.
    func load(discardingDrafts: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await model.reloadConfiguration()
            adoptLoadedSettings(discardingDrafts: discardingDrafts)
            message = "Settings loaded. Nothing has been sent to a gateway."; messageTone = .neutral
        } catch { message = error.localizedDescription; messageTone = .danger }
    }
    private func adoptLoadedSettings(discardingDrafts: Bool) {
        // Restoring the original value after submission is still an edit. Keep
        // differences from both snapshots: a late completion can be a failed write.
        let refreshed = lateSubmittedPreferences.map { Self.merging(preferences, from: $0, onto: model.configuration) } ?? model.configuration
        preferences = discardingDrafts ? model.configuration : Self.merging(preferences, from: preferencesBaseline, onto: refreshed)
        preferencesBaseline = model.configuration
        revision = model.configuration.revision; loaded = true
        if discardingDrafts {
            drafts = [:]; confirmingDelete = false; confirmingTest = false
            requiresReloadBeforeWrite = false; lateRefresh?.cancel(); lateRefresh = nil
            lateSubmittedDraft = nil; lateSubmittedPreferences = nil
        }
        let current = draft.profile.id
        if let saved = model.profiles.first(where: { $0.id == current }) {
            if discardingDrafts || !isEdited(draft) { draft = Draft.loaded(saved, isSaved: true) }
            else if lateSubmittedDraft?.profile.id == current { draft = draft.rebased(onto: saved) }
        } else if discardingDrafts || (!isEdited(draft) && lateSubmittedDraft == nil) {
            // A new tab opened while the save waited must stay selected; its
            // previous tab may hold a stashed correction to the late save.
            draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false)
        }
        if let id = lateSubmittedDraft?.profile.id, let kept = drafts[id], let saved = model.profiles.first(where: { $0.id == id }) {
            drafts[id] = kept.rebased(onto: saved)
        }
    }
    private static let uncertainWriteNotice = "The earlier change may have been saved. Reload Settings before saving or deleting again."
    private func refreshWhenFinished(_ uncertain: VaultUpdateUncertain, report: String, submitted: VaultConfiguration? = nil, submittedDraft: Draft? = nil) {
        // A route change may have saved under a new connection id. Keep edits
        // visible, but require Reload before retrying and forking a duplicate.
        requiresReloadBeforeWrite = true
        // Stashing a correction back to the original value must not drop it
        // merely because that value still matches the pre-submission baseline.
        lateSubmittedDraft = submittedDraft; lateSubmittedPreferences = submitted
        lateRefresh?.cancel()
        lateRefresh = Task { @MainActor [weak self] in
            for await _ in uncertain.completion {}
            while self?.busy == true, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            guard !Task.isCancelled, let self, self.requiresReloadBeforeWrite, !self.model.installPreparing else { return }
            self.busy = true; defer { self.busy = false }
            do {
                try await self.model.reloadConfiguration()
                guard !Task.isCancelled else { return }
                self.adoptLoadedSettings(discardingDrafts: false)
                self.lateSubmittedDraft = nil; self.lateSubmittedPreferences = nil
                self.message = "Keychain finished the earlier operation. Saved settings were refreshed and your edits were kept. Reload Settings before saving or deleting again."
                self.messageTone = .neutral
                if self.model.error == report { self.model.error = nil }
            } catch {
                self.message = Self.uncertainWriteNotice + " Could not refresh Settings: " + error.localizedDescription
                self.messageTone = .danger
            }
        }
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
        if isEdited(draft) { drafts[draft.profile.id] = draft } else { drafts[draft.profile.id] = nil }
    }
    /// Drops the current unsaved tab, or the current tab's edits, and returns to what the vault holds.
    func discardCurrent() {
        let id = draft.profile.id
        drafts[id] = nil
        if let saved = model.profiles.first(where: { $0.id == id }) { draft = Draft.loaded(saved, isSaved: true) }
        else { draft = model.profiles.first.map { Draft.loaded($0, isSaved: true) } ?? Draft.loaded(ProfileRecord(), isSaved: false) }
        resetLateDraft(id)
        confirmingDelete = false
    }
    private func resetLateDraft(_ id: String) {
        guard lateSubmittedDraft?.profile.id == id else { return }
        lateSubmittedDraft = model.profiles.first(where: { $0.id == id }).map { Draft.loaded($0, isSaved: true) }
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

    /// What a Save All came to.
    enum SaveOutcome: Equatable {
        /// Everything saved; Settings may close.
        case saved
        /// Everything saved, and the message explains something the reader
        /// should see first (a route change made a new connection).
        case savedWithNote
        /// Not everything saved: the message says what did and what didn't.
        case failed
    }
    /// Saves every tab with edits, the current one last, and the preferences.
    /// Returns true when the sheet can close: everything saved and no route
    /// change created a new connection that needs explaining.
    func save(thenTest: Bool = false) async -> Bool { await saveAll(thenTest: thenTest) == .saved }
    func saveAll(thenTest: Bool = false) async -> SaveOutcome {
        guard loaded else { message = "Wait for Settings to finish loading before saving."; messageTone = .danger; return .failed }
        guard !busy else { return .failed }
        guard !requiresReloadBeforeWrite else { message = Self.uncertainWriteNotice; messageTone = .danger; return .failed }
        // Quitting or updating: the last decision about Settings was made.
        guard !model.installPreparing else { message = Self.closingNotice; messageTone = .danger; return .failed }
        busy = true; saving = true; defer { busy = false; saving = false }
        stash()
        let currentID = draft.profile.id
        let queue = drafts.values.filter { $0.edited && $0.profile.id != currentID }.sorted { $0.profile.id < $1.profile.id } + [draft]
        var forkNote: String? = nil
        var savedCurrentID = currentID
        // What has reached the vault so far, for a report that is honest
        // about a save that stopped part of the way.
        var savedNames: [String] = []
        var preferencesSaved = false
        let preferencesWereEdited = preferencesEdited
        for item in queue {
            var submitted = preferences
            do {
                let savedID = try await saveOnce(item, submitted: &submitted)
                drafts[item.profile.id] = nil
                if item.edited { savedNames.append("“\(item.name)”") }
                // Every connection's save writes the preferences too.
                preferences = model.configuration; preferencesBaseline = model.configuration; revision = preferences.revision
                if preferencesWereEdited { preferencesSaved = true }
                if savedID != item.profile.id {
                    forkNote = "Saved “\(item.name)” as a new connection because its API route changed. The previous connection stays for its earlier chats; delete it in its tab if you no longer need it."
                }
                if item.profile.id == currentID { savedCurrentID = savedID }
            } catch {
                // Stay on the tab that failed, with its edits and the reason.
                if item.profile.id != currentID { drafts[currentID] = draft; draft = item }
                drafts[item.profile.id] = nil
                if preferencesSaved { savedNames.append("your preferences") }
                let saved = savedNames.isEmpty ? "" : "Saved " + Self.list(savedNames) + ". "
                let uncertain = error as? VaultUpdateUncertain
                let report = saved + "“\(item.name)” " + (uncertain == nil ? "was not saved: " : "may have been saved: ") + error.localizedDescription
                message = forkNote.map { report + " " + $0 } ?? report; messageTone = .danger
                // In the window's banner as well as the footer, exactly as a
                // failed deletion is: a save that did not happen was silent, and
                // Escape or Cancel closed the sheet over it.
                model.error = report
                if let uncertain { refreshWhenFinished(uncertain, report: report, submitted: submitted, submittedDraft: item) }
                return .failed
            }
        }
        preferences = model.configuration; preferencesBaseline = model.configuration; revision = preferences.revision
        draft = model.profiles.first(where: { $0.id == savedCurrentID }).map { Draft.loaded($0, isSaved: true) } ?? draft
        if thenTest { model.testConnection(profileID: savedCurrentID, confirmed: true) }
        messageTone = .neutral
        if let forkNote { message = forkNote; return .savedWithNote }
        message = "Saved to your Keychain."
        return .saved
    }
    static let closingNotice = "Bello Agent is quitting or updating. Nothing more is saved from Settings."
    private static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // MARK: Closing with unsaved edits

    /// What the reader chose for edits Settings hasn't saved.
    enum UnsavedChoice { case save, discard, keep }
    /// True while a close, reload or quit question of this editor's is up, so
    /// a second Escape or close doesn't ask again.
    private(set) var deciding = false
    /// Asks Save All / Discard Changes / Keep Editing, on this editor's window.
    private func askAboutUnsavedChanges(quitting: Bool) async -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = quitting ? "Save your Settings changes before quitting?" : "Save your Settings changes?"
        alert.informativeText = Self.unsavedSummary(editedSections)
        let save = alert.addButton(withTitle: "Save All")
        let discard = alert.addButton(withTitle: "Discard Changes")
        let keep = alert.addButton(withTitle: "Keep Editing")
        save.keyEquivalent = "\r"
        discard.keyEquivalent = "d"; discard.keyEquivalentModifierMask = .command
        keep.keyEquivalent = "\u{1b}"
        switch await PiQuestion.shared.ask(alert, over: presentationWindow) {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .keep
        }
    }
    /// What the question says is unsaved, by section.
    static func unsavedSummary(_ sections: Set<SettingsSection>) -> String {
        let names = SettingsSection.allCases.filter(sections.contains).map(\.title)
        return "Unsaved changes in " + list(names) + ". Discarding them keeps what is saved in your Keychain."
    }
    /// Whether Settings may close now. Clean closes; unsaved edits ask first;
    /// a save under way keeps it open until it finishes.
    func requestClose() async -> Bool {
        guard !saving else { message = "Wait for the save to finish."; messageTone = .danger; return false }
        guard !deciding else { return false }
        guard isDirty else { return true }
        deciding = true; defer { deciding = false }
        let choice = await askAboutUnsavedChanges(quitting: false)
        // Something else may have started while the question was up.
        guard !saving else { return false }
        switch choice {
        case .save: return await saveAll() == .saved
        case .discard: discardAll(); return true
        case .keep: return false
        }
    }
    /// Whether the app may go on quitting. Unsaved edits ask first; a save
    /// that didn't finish keeps the app open with the reason showing.
    func resolveForQuit() async -> Bool {
        guard !saving, !deciding else { return false }
        guard isDirty else { return true }
        deciding = true; defer { deciding = false }
        let choice = await askAboutUnsavedChanges(quitting: true)
        guard !saving else { return false }
        switch choice {
        case .save: return await saveAll() != .failed
        case .discard: discardAll(); return true
        case .keep: return false
        }
    }
    /// Reloads the vault, after asking when that would drop unsaved edits.
    /// Keep Editing writes and drops nothing.
    func requestReload() async {
        guard !busy, !deciding else { return }
        if isDirty {
            deciding = true
            let reload = await PiQuestion.shared.confirm("Discard unsaved changes and reload?", Self.unsavedSummary(editedSections),
                                                         action: "Discard and Reload", cancel: "Keep Editing", destructive: true,
                                                         cancelIsDefault: true, over: presentationWindow)
            deciding = false
            guard reload, !busy else { return }
        }
        await load(discardingDrafts: true)
    }

    /// One connection's save against the vault's current revision; a conflict from another save reloads and tries once more.
    private func saveOnce(_ item: Draft, submitted: inout VaultConfiguration) async throws -> String {
        // This editor's preference edits go onto what the app holds now, so a
        // save from the other Settings editor since this one loaded stays.
        preferences = Self.merging(preferences, from: preferencesBaseline, onto: model.configuration)
        preferencesBaseline = model.configuration
        do {
            submitted = preferences
            return try await item.form.save(to: model, comparedTo: item.baseline, key: item.key, headers: item.headers,
                                            preferences: preferences, expectedRevision: model.configuration.revision)
        } catch VaultError.conflict {
            try await model.reloadConfiguration()
            preferences = Self.merging(preferences, from: preferencesBaseline, onto: model.configuration)
            preferencesBaseline = model.configuration
            submitted = preferences
            return try await item.form.save(to: model, comparedTo: item.baseline, key: item.key, headers: item.headers,
                                            preferences: preferences, expectedRevision: model.configuration.revision)
        }
    }

    // MARK: Deleting

    /// What the deletion touches: the key, the chats that keep their history, the runs that stop.
    var deletionSummary: String {
        let using = model.chats.filter { $0.profileID == draft.profile.id && !$0.isUtilityChat }
        let working = using.filter { model.displays[$0.id]?.hasWork == true }.count
        var parts = ["Its key leaves the Keychain item."]
        parts.append(using.isEmpty ? "No chat uses it." : using.count == 1 ? "One chat keeps its history and will need another connection."
                     : "\(using.count) chats keep their history and will need another connection.")
        if working > 0 { parts.append(working == 1 ? "One run will be stopped." : "\(working) runs will be stopped.") }
        return parts.joined(separator: " ")
    }
    func delete() async {
        guard !busy else { return }
        guard !requiresReloadBeforeWrite else { message = Self.uncertainWriteNotice; messageTone = .danger; return }
        guard !model.installPreparing else { message = Self.closingNotice; messageTone = .danger; return }
        let id = draft.profile.id, name = draft.name
        confirmingDelete = false
        busy = true; saving = true; defer { busy = false; saving = false }
        do {
            try await model.deleteProfile(id)
            drafts[id] = nil
            preferences = Self.merging(preferences, from: preferencesBaseline, onto: model.configuration)
            preferencesBaseline = model.configuration; revision = model.configuration.revision
            // Do not stash the deleted tab again, or replace another tab's
            // only copy of its edits with its saved form.
            if let first = model.profiles.first { draft = drafts[first.id] ?? Draft.loaded(first, isSaved: true) }
            else { draft = drafts.values.sorted { $0.profile.id < $1.profile.id }.first ?? Draft.loaded(ProfileRecord(), isSaved: false) }
            messageTone = .neutral
            message = model.profiles.isEmpty ? "“\(name)” was deleted. Add a new connection to send messages."
                : "“\(name)” was deleted. \(model.profiles.count) connection\(model.profiles.count == 1 ? " remains" : "s remain")."
        } catch {
            // A timed-out update may still delete the connection after this returns.
            messageTone = .danger
            let uncertain = error as? VaultUpdateUncertain
            message = "“\(name)” " + (uncertain == nil ? "was not deleted: " : "may have been deleted: ") + error.localizedDescription
            let report = "Connection " + message
            model.error = report
            if let uncertain { refreshWhenFinished(uncertain, report: report) }
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
