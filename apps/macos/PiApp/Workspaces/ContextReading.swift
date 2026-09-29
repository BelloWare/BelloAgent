import Foundation

// What a chat's context pill showed when the chat was last idle with an empty
// composer, kept so that the chat shows it again at once instead of opening
// the helper to count it again.
//
// Showing a chat used to start its project's helper and open the chat in it a
// fifth of a second later, only so the pill could say how full the next
// request would be; until then the pill read "Calculating context…". The
// helper's reading is now saved with what it depends on: the chat's model and
// limits (its binding), the configuration revision, and the journal it was
// counted from. A chat whose saved reading still matches all three, with
// nothing in its composer and no helper open for it, shows that reading and
// opens nothing. Anything else counts as before: typing, a chat never counted,
// a changed model, settings or journal. The helper's own figures, once it
// publishes them, always come first.

/// A context pill's reading and what makes it still the right one.
struct ContextReading: Codable, Sendable, Equatable {
    static let recordKind = "context-reading"
    var chatID: String
    /// What the pill showed: `WorkspaceModel.displayedContext`.
    var context: [String: WireValue]
    var binding: ContextPreviewBinding
    var configurationRevision: Int64
    /// The journal it was counted from; nil for a chat with none yet.
    var journal: HistoryRevision?
}

extension WorkspaceModel {
    /// Every chat's saved reading, read with the chat list so the first frame
    /// of a chat already has it.
    func restoreContextReadings() async {
        guard let store else { return }
        let readings = (try? await store.list(ContextReading.self, kind: ContextReading.recordKind)) ?? []
        var byChat: [String: ContextReading] = [:]
        for reading in readings where byChat[reading.chatID] == nil { byChat[reading.chatID] = reading }
        contextReadings = byChat
    }

    /// Whether a reading was counted for this chat as it is now: its binding,
    /// the configuration, and its journal, which is looked at, not read.
    func contextReadingStands(_ reading: ContextReading, for item: ChatRecord) -> Bool {
        guard reading.chatID == item.id, !item.imported, reading.binding == ContextPreviewBinding(item),
              reading.configurationRevision == configuration.revision else { return false }
        guard let path = item.path else { return reading.journal == nil }
        return reading.journal == HistoryReader.currentRevision(path: path)
    }

    /// Gives a chat about to be shown its saved reading, when the reading still
    /// stands and no helper is open for it; else takes away one it held.
    func adoptContextReading(_ view: SessionDisplay, item: ChatRecord) {
        var standing: ContextReading?
        if !opened.contains(item.id), let reading = contextReadings[item.id], contextReadingStands(reading, for: item) { standing = reading }
        if view.footer.retainedContext != standing { view.footer.retainedContext = standing }
    }

    /// The saved reading the pill shows: only while the helper has published
    /// nothing for the chat and the next request is the one it counted, with
    /// an empty composer. `forScheduling` leaves out the estimate the
    /// scheduler itself turns on.
    func servingContextReading(_ view: SessionDisplay, forScheduling: Bool = false) -> ContextReading? {
        guard let reading = view.footer.retainedContext, view.footer.contextState.isEmpty, view.footer.preparedContext == nil,
              forScheduling || !view.footer.preparingContext, view.footer.pendingContextSubmission == nil,
              !view.busy, view.state == "idle", view.draft.isEmpty, view.skills.isEmpty, view.attachments.isEmpty, !view.directCommand,
              view.editingMessageID == nil, view.queueEditingID == nil,
              let item = record(view.id), reading.binding == ContextPreviewBinding(item),
              reading.configurationRevision == configuration.revision else { return nil }
        return reading
    }

    /// Saves what the pill shows now, when the chat is idle with an empty
    /// composer and the helper counted it: the reading the chat shows next
    /// time without opening anything.
    func retainContextReading(_ view: SessionDisplay) {
        guard let item = record(view.id), !item.imported, !item.isBackgroundTask, !isEphemeral(item.id),
              !view.busy, view.state == "idle", view.footer.pendingContextSubmission == nil, !view.footer.preparingContext,
              view.draft.isEmpty, view.skills.isEmpty, view.attachments.isEmpty, !view.directCommand,
              view.editingMessageID == nil, view.queueEditingID == nil,
              !view.footer.contextState.isEmpty || view.footer.preparedContext != nil else { return }
        let context = contextPresentation(view).context
        // A count, not a placeholder: pending readings are never saved.
        guard context["state"]?.string != "pending", context["tokens"]?.number != nil || context["state"]?.string == "post-compaction" else { return }
        var journal: HistoryRevision?
        if let path = item.path {
            guard let current = HistoryReader.currentRevision(path: path) else { return }
            journal = current
        }
        let reading = ContextReading(chatID: item.id, context: context, binding: ContextPreviewBinding(item),
                                     configurationRevision: configuration.revision, journal: journal)
        if view.footer.retainedContext != reading { view.footer.retainedContext = reading }
        guard contextReadings[item.id] != reading else { return }
        contextReadings[item.id] = reading
        let store = store
        Task { try? await store?.put(reading, kind: ContextReading.recordKind, id: reading.chatID) }
    }
}
