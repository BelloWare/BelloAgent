import SwiftUI

// Messages waiting their turn: drag to reorder, rewrite one in the chat's
// composer, promote one to steering so it reaches the run after its tool batch.

/// Pending messages: drag follow-ups to reorder, rewrite one in the chat's
/// composer (its place in the queue is kept), promote one to steering so it
/// reaches the current run after its tool batch, or remove it.
struct QueuedMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let steering: Bool
    /// A long submission arrives as a preview; its whole text comes from the
    /// helper's `queue.read` and must be loaded before the row can be saved.
    let truncated: Bool
    init?(_ item: [String: WireValue]) {
        guard let id = item["turnId"]?.string else { return nil }
        steering = item["kind"]?.string == "steering"
        let raw = item["text"]?.string ?? ""
        text = steering && raw.hasPrefix("[Steering] ") ? String(raw.dropFirst("[Steering] ".count)) : raw
        truncated = item["textTruncated"]?.bool == true
        self.id = id
    }
    static func from(_ queue: [[String: WireValue]]) -> [QueuedMessage] { queue.compactMap(QueuedMessage.init) }
}

struct QueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    private var items: [QueuedMessage] { QueuedMessage.from(session.queue) }
    private var followUps: [QueuedMessage] { items.filter { !$0.steering } }
    private var steering: [QueuedMessage] { items.filter(\.steering) }
    /// One follow-up row. A message being rewritten is in the chat's own
    /// composer, so no row grows for it.
    static let rowHeight: CGFloat = 30
    static func listHeight(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(session.busy ? "Waiting for this run to finish · \(items.count)" : session.queuePaused ? "Paused · \(items.count)" : "Waiting to send · \(items.count)", systemImage: "tray.full").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                if followUps.count > 1 { Text("Drag to reorder").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                Spacer()
                if session.canResumeQueue {
                    Button { model.action("queue.resume", sessionID: session.id) } label: { Label(session.queuePaused ? "Resume" : "Send queued", systemImage: "play.fill") }.buttonStyle(.piSecondaryCompact)
                }
            }
            if !steering.isEmpty {
                ForEach(steering) { item in row(item, index: nil) }
            }
            List {
                ForEach(Array(followUps.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index + 1)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    var order = followUps.map(\.id)
                    order.move(fromOffsets: source, toOffset: destination)
                    model.action("queue.reorder", params: ["turnIds": .array(order.map(WireValue.string))], sessionID: session.id)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(height: Self.listHeight(rows: followUps.count))
            .accessibilityIdentifier("queue-follow-ups")
        }
        .padding(PiSpacing.md)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
    }
    @ViewBuilder private func row(_ item: QueuedMessage, index: Int?) -> some View {
        let editing = session.queueEditingID == item.id
        HStack(spacing: PiSpacing.sm) {
            if item.steering {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                    .help("Steering: delivered after the current tool batch")
            } else {
                Text(index.map(String.init) ?? "").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 14)
            }
            Text(item.text).lineLimit(1).font(PiFont.body).foregroundStyle(editing ? Color.piInkTertiary : Color.piInk)
            Spacer()
            if editing {
                Label("Editing in the composer", systemImage: "pencil.line").font(PiFont.caption).foregroundStyle(Color.piAccent)
                    .accessibilityIdentifier("queue-editing-" + item.id)
            } else {
                if !item.steering && session.busy {
                    PiIconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22) {
                        model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: session.id)
                    }.help("Deliver after the current tool batch instead of after the run")
                }
                if session.queueEditPreparing == item.id {
                    PiSpinner(controlSize: .mini).frame(width: 22).help("Reading the whole message")
                } else {
                    PiIconButton(symbol: "pencil", label: "Edit queued message", size: 22) { model.editQueued(item.id, sessionID: session.id) }
                }
            }
            PiIconButton(symbol: "xmark", label: "Remove", size: 22) {
                if editing { model.cancelQueuedEdit(sessionID: session.id) }
                model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id)
            }
        }
        .frame(minHeight: 26)
        .accessibilityIdentifier("queue-item-" + item.id)
    }
}

/// Over the composer while it holds a queued message, in the look of the
/// earlier-message edit: Return saves the text in the message's place in the
/// queue, Cancel leaves it as it was, and the draft set aside comes back.
struct QueueEditBanner: View {
    let steering: Bool
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").foregroundStyle(Color.piAccent)
                Text(steering ? "Editing a steering message" : "Editing a queued message").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                Button("Cancel", action: cancel).buttonStyle(.piGhost).keyboardShortcut(.cancelAction)
            }
            Text("Return saves it in its place in the queue.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(8).background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 8).padding(.top, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Editing a queued message")
    }
}

extension WorkspaceModel {
    /// Opens a queued message in the chat's composer, setting its draft
    /// aside. A previewed submission is read whole first: saving the preview
    /// would drop everything past it.
    func editQueued(_ turnID: String, sessionID: String) {
        guard let view = displays[sessionID], let item = QueuedMessage.from(view.queue).first(where: { $0.id == turnID }) else { return }
        guard view.editingMessageID == nil, !view.editPreparing else {
            view.notice = "Finish or cancel the message edit before rewriting a queued message."; return
        }
        if view.queueEditingID == turnID { view.composerFocusRequest += 1; return }
        if view.queueEditingID != nil { cancelQueuedEdit(sessionID: sessionID) }
        let read = UUID(); view.queueEditRead = read
        guard item.truncated else { view.queueEditPreparing = nil; beginQueuedEdit(view, turnID: turnID, text: item.text); return }
        view.queueEditPreparing = turnID
        Task {
            do {
                let whole = try await queuedMessageText(turnID: turnID, sessionID: sessionID)
                guard view.queueEditRead == read else { return }
                view.queueEditPreparing = nil
                guard view.queue.contains(where: { $0["turnId"]?.string == turnID }) else { return }
                beginQueuedEdit(view, turnID: turnID, text: whole)
            } catch {
                guard view.queueEditRead == read else { return }
                view.queueEditPreparing = nil
                view.notice = "The whole queued message could not be read, so it was not opened for rewriting. " + error.localizedDescription
            }
        }
    }
    private func beginQueuedEdit(_ view: SessionDisplay, turnID: String, text: String) {
        guard view.editingMessageID == nil, view.queueEditingID == nil else { return }
        // Set aside first: the draft saved for the chat stays the one typed.
        view.draftBeforeQueueEdit = view.savedDraft
        view.queueEditOriginal = text
        view.queueEditingID = turnID
        view.draft = text; view.attachments = []; view.skills = []
        view.directCommand = false; view.completionVisible = false
        focusedSessionID = view.id; view.composerFocusRequest += 1
    }
    /// Return in a composer holding a queued message: its text goes back in
    /// the queue, in its place, and the draft set aside comes back.
    func saveQueuedEdit(sessionID: String) {
        guard let view = displays[sessionID], let turnID = view.queueEditingID else { return }
        guard view.attachments.isEmpty, view.skills.isEmpty else {
            view.notice = "A queued message keeps only its text. Remove the image or skill to save it."; return
        }
        let text = view.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { view.notice = "Type the message, or Cancel to keep it as it was."; return }
        let original = view.queueEditOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        finishQueuedEdit(view)
        if text != original { action("queue.update", params: ["turnId": .string(turnID), "text": .string(text)], sessionID: sessionID) }
    }
    func cancelQueuedEdit(sessionID: String) {
        guard let view = displays[sessionID] else { return }
        view.queueEditRead = UUID(); view.queueEditPreparing = nil
        guard view.queueEditingID != nil else { return }
        finishQueuedEdit(view)
    }
    private func finishQueuedEdit(_ view: SessionDisplay) {
        let before = view.draftBeforeQueueEdit ?? DraftRecord(id: view.id, text: "")
        view.queueEditingID = nil; view.queueEditOriginal = ""; view.draftBeforeQueueEdit = nil
        view.restoreDraft(before)
        draftChanged(view)
    }
}
