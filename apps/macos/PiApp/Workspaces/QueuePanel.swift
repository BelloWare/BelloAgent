import CryptoKit
import SwiftUI
import AppKit

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
    /// The model choices captured when it was queued; nil is the
    /// connection's own setting at delivery.
    let model: String?, thinkingLevel: String?
    let contextWindow: Int?, maxOutputTokens: Int?
    init?(_ item: [String: WireValue]) {
        guard let id = item["turnId"]?.string else { return nil }
        steering = item["kind"]?.string == "steering"
        let raw = item["text"]?.string ?? ""
        text = steering && raw.hasPrefix("[Steering] ") ? String(raw.dropFirst("[Steering] ".count)) : raw
        truncated = item["textTruncated"]?.bool == true
        model = item["model"]?.string; thinkingLevel = item["thinkingLevel"]?.string
        contextWindow = item["contextWindow"]?.number.map(Int.init); maxOutputTokens = item["maxOutputTokens"]?.number.map(Int.init)
        textBytes = Int(item["textBytes"]?.number ?? 0); revision = Int(item["textRevision"]?.number ?? 0)
        self.id = id
    }
    static func from(_ queue: [[String: WireValue]]) -> [QueuedMessage] { queue.compactMap(QueuedMessage.init) }
    /// What the row says of its message: its preview, its whole size and
    /// the helper's revision of the hold, so a rewrite past the preview
    /// (saved while a detail is open) still reads as a change.
    let textBytes: Int, revision: Int
    var contentKey: String { "\(id)|\(text.hashValue)|\(textBytes)|\(revision)|\(truncated)" }
    /// What a row shows for a message with no text of its own.
    var title: String { text.isEmpty ? "Image message" : text }
}

/// When the waiting messages go, in words that hold: a hold or a pause
/// comes before any promise that something is about to be sent.
enum QueueTiming {
    case editing, paused, failed, running, idle
    @MainActor init(_ session: SessionDisplay) {
        if session.queueEditHold != nil { self = .editing }
        else if session.runState == .error { self = .failed }
        // Stopped, or a reopen or lost helper left it waiting: Resume sends it.
        else if session.queuePaused || session.runState.holdsQueue { self = .paused }
        else if session.busy { self = .running }
        else { self = .idle }
    }
    func header(count: Int) -> String {
        switch self {
        case .editing: "Paused while a message is edited · \(count)"
        case .failed: "Paused after the run failed · \(count)"
        case .paused: "Paused · \(count)"
        case .running: "Waiting · \(count)"
        case .idle: "Waiting to send · \(count)"
        }
    }
    var steering: String {
        switch self {
        case .editing, .failed, .paused: "Steering · waits until resumed"
        case .running, .idle: "Steering · after the current tool batch"
        }
    }
    var followUps: String {
        switch self {
        case .editing, .failed, .paused: "Follow-ups · wait until resumed"
        case .running: "Follow-ups · when this run finishes"
        case .idle: "Follow-ups · next"
        }
    }
}

struct QueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    /// The height the list may take (`QueuePanel.room`).
    var room: CGFloat = .infinity
    private var items: [QueuedMessage] { QueuedMessage.from(session.queue) }
    private var followUps: [QueuedMessage] { items.filter { !$0.steering } }
    private var steering: [QueuedMessage] { items.filter(\.steering) }
    /// One compact row.
    static let rowHeight: CGFloat = 30
    static let sectionHeaderHeight: CGFloat = 22
    /// The panel's list never takes more than three and a half rows (the
    /// half says there is more to scroll to) plus its two headings: at the
    /// 920×600 minimum window that leaves the transcript at least 150 pt of
    /// reading space, and the composer, Stop and Resume stay where they are.
    /// The rest of the queue scrolls.
    static let visibleRows: CGFloat = 3.5
    /// The follow-ups' order after a drag of `source` to `destination`, as
    /// the list showed them when the drag began.
    static func reordered(_ ids: [String], moving source: IndexSet, to destination: Int) -> [String] {
        var order = ids; order.move(fromOffsets: source, toOffset: destination); return order
    }
    static func listHeight(rows: Int, sections: Int = 1, room: CGFloat = .infinity) -> CGFloat {
        let content = CGFloat(rows) * rowHeight + CGFloat(sections) * sectionHeaderHeight
        let cap = visibleRows * rowHeight + CGFloat(sections) * sectionHeaderHeight
        // Never less than one row and its heading: the panel can be collapsed.
        return min(content, max(rowHeight + sectionHeaderHeight, min(cap, room)))
    }
    /// The reading space the transcript keeps before the queue takes more.
    static let transcriptReserve: CGFloat = 150
    /// The panel's own chrome around its list (header, padding and border)
    /// and the space below it.
    static let chrome: CGFloat = 58 + PiSpacing.sm
    /// The height the list may take in a pane of `pane` points with a
    /// composer `composer` tall and a terminal `terminal` tall open below it,
    /// leaving the transcript its reserve and the footer its line.
    static func room(pane: CGFloat, composer: CGFloat, terminal: CGFloat) -> CGFloat {
        guard pane > 0 else { return .infinity }
        return pane - composer - terminal - transcriptReserve - chrome - 36
    }
    var body: some View {
        let timing = QueueTiming(session)
        let listHeight = Self.listHeight(rows: items.count, sections: (steering.isEmpty ? 0 : 1) + (followUps.isEmpty ? 0 : 1), room: room)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: PiSpacing.sm) {
                PiIconButton(symbol: session.queueCollapsed ? "chevron.right" : "chevron.down",
                             label: session.queueCollapsed ? "Show waiting messages" : "Hide waiting messages", size: 20) {
                    session.queueCollapsed.toggle()
                }.accessibilityIdentifier("queue-collapse")
                Label(timing.header(count: items.count), systemImage: timing == .editing ? "pause.circle" : "tray.full")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                    .accessibilityIdentifier("queue-status")
                if !session.queueCollapsed, followUps.count > 1, session.queueEditHold == nil { Text("Drag to reorder").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                Spacer()
                if session.canResumeQueue {
                    let held = session.queueEditHold != nil
                    Button { model.action("queue.resume", sessionID: session.id) } label: { Label(session.queuePaused ? "Resume" : "Send queued", systemImage: "play.fill") }.buttonStyle(.piSecondaryCompact)
                        .disabled(held).help(held ? "Finish or cancel the queued edit first" : "")
                        .accessibilityHint(held ? "Finish or cancel the queued edit first" : "")
                }
            }
            if !session.queueCollapsed {
                List {
                    // Headings are plain rows on the panel's own background,
                    // not sticky list headers with a bar of their own.
                    if !steering.isEmpty {
                        sectionHeader(timing.steering).queueRowInsets().moveDisabled(true)
                        ForEach(steering) { item in row(item, index: nil).queueRowInsets().moveDisabled(true) }
                    }
                    if !followUps.isEmpty {
                        sectionHeader(timing.followUps).queueRowInsets().moveDisabled(true)
                        ForEach(Array(followUps.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index + 1).queueRowInsets()
                        }
                        .onMove(perform: session.queueEditHold != nil ? nil : { source, destination in
                            model.reorderQueued(Self.reordered(followUps.map(\.id), moving: source, to: destination), sessionID: session.id)
                        })
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .scrollDisabled(listHeight >= CGFloat(items.count) * Self.rowHeight + CGFloat((steering.isEmpty ? 0 : 1) + (followUps.isEmpty ? 0 : 1)) * Self.sectionHeaderHeight)
                // Its height, unless the pane can't fit it: then less, down to
                // one row with its heading, so every message stays reachable
                // by scrolling; the panel can be collapsed for the rest.
                .frame(minHeight: min(listHeight, Self.rowHeight + Self.sectionHeaderHeight), idealHeight: listHeight, maxHeight: listHeight)
                .accessibilityIdentifier("queue-follow-ups")
                .transition(.opacity)
            }
        }
        .padding(PiSpacing.md)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        // On the panel, not the row: a message that leaves while its detail
        // is open takes no popover with it; the detail says it left. Closing
        // is written after the update that asked for it.
        .popover(isPresented: Binding(get: { session.queueDetailID != nil },
                                      set: { open in if !open { DispatchQueue.main.async { session.queueDetailID = nil } } }), arrowEdge: .top) {
            QueuedMessageDetail(model: model, session: session, turnID: session.queueDetailID ?? "")
        }
        .piAnimation(PiMotion.quick, value: session.queueCollapsed)
    }
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(PiFont.micro.weight(.semibold)).foregroundStyle(Color.piInkTertiary)
            .frame(maxWidth: .infinity, minHeight: Self.sectionHeaderHeight - 4, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private func row(_ item: QueuedMessage, index: Int?) -> some View {
        let editing = session.queueEditingID == item.id
        // Held by an edit this composer does not own: one a restart left.
        let heldElsewhere = !editing && session.queueEditHold?.turnID == item.id
        HStack(spacing: PiSpacing.sm) {
            if item.steering {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                Text(index.map(String.init) ?? "").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(item.title).lineLimit(1).font(PiFont.body).foregroundStyle(editing ? Color.piInkTertiary : Color.piInk)
            Spacer()
            PiIconButton(symbol: "info.circle", label: "Show the whole message and its model choices", size: 22) { session.queueDetailID = item.id }
                .accessibilityIdentifier("queue-detail-" + item.id)
            if editing {
                Label("Editing in the composer", systemImage: "pencil.line").font(PiFont.caption).foregroundStyle(Color.piAccent)
                    .accessibilityIdentifier("queue-editing-" + item.id)
            } else if heldElsewhere, let hold = session.queueEditHold {
                Label("Edit open", systemImage: "pause.circle").font(PiFont.caption).foregroundStyle(Color.piAccent)
                Button("Resume Edit") { model.editQueued(item.id, sessionID: session.id, resuming: hold.editID) }.buttonStyle(.piGhost)
                    .disabled(session.queueEditCancelling == hold.editID)
                    .accessibilityIdentifier("queue-resume-edit-" + item.id)
                Button("Cancel Edit") { model.cancelHeldQueueEdit(sessionID: session.id) }.buttonStyle(.piGhost)
                    .accessibilityIdentifier("queue-cancel-edit-" + item.id)
            } else {
                if !item.steering && session.busy && session.queueEditHold == nil {
                    PiIconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22) {
                        model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: session.id)
                    }.help("Deliver after the current tool batch instead of after the run")
                }
                if session.queueEditPreparing == item.id {
                    PiSpinner(controlSize: .mini).frame(width: 22).help("Pausing the queue and reading the whole message")
                } else {
                    PiIconButton(symbol: "pencil", label: "Edit queued message", size: 22) { model.editQueued(item.id, sessionID: session.id) }
                        .disabled(session.queueEditHold != nil)
                }
            }
            PiIconButton(symbol: "xmark", label: "Remove", size: 22) {
                // The message being rewritten goes with its hold, in one step.
                if editing { model.removeQueuedEdit(sessionID: session.id) }
                else { model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id) }
            }.disabled((session.queueEditResolving && editing) || heldElsewhere)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((item.steering ? "Steering message: " : "Follow-up \(index ?? 0): ") + item.title)
        .accessibilityIdentifier("queue-item-" + item.id)
    }
}

private extension View {
    func queueRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// A waiting message, whole, with the model choices it was queued with.
/// Reading it takes no hold and leaves the composer alone.
struct QueuedMessageDetail: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let turnID: String
    @State private var whole: String?
    @State private var readFailed = false
    static let goneText = "This message is no longer waiting."
    var body: some View {
        let item = QueuedMessage.from(session.queue).first { $0.id == turnID }
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            if let item {
                Text(item.steering ? "Steering message" : "Follow-up").font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInkSecondary)
                ScrollView {
                    Text(whole ?? item.text).font(PiFont.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("queue-detail-text")
                }.frame(maxHeight: 220)
                if item.truncated && whole == nil {
                    Text(readFailed ? "Only the start of the message could be read." : "Reading the whole message…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
                Divider()
                detailRow("Model", item.model ?? "Connection default")
                detailRow("Reasoning", item.thinkingLevel.map { $0 == "default" ? "Model default" : $0.capitalized } ?? "Connection default")
                if let window = item.contextWindow { detailRow("Context", "\(window.formatted()) tokens") }
                if let output = item.maxOutputTokens { detailRow("Output budget", "\(output.formatted()) tokens") }
            } else {
                Text(Self.goneText).font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                    .accessibilityIdentifier("queue-detail-gone")
            }
        }
        .padding(PiSpacing.md).frame(width: 340)
        // What the detail shows, for the chat to read back (tests, and the
        // row's own label): the message, or that it is no longer waiting.
        .onChange(of: item.map { whole ?? $0.text } ?? Self.goneText, initial: true) { _, shown in
            if session.queueDetailShowing != shown { session.queueDetailShowing = shown }
        }
        .onDisappear { session.queueDetailShowing = nil }
        // Keyed by what the row now says: a rewrite saved while the detail
        // is open reads the message again, and an older read is dropped.
        .task(id: item.map(\.contentKey)) {
            whole = nil; readFailed = false
            guard let item, item.truncated else { return }
            let key = item.contentKey
            do {
                let text = try await model.queuedMessageText(turnID: turnID, sessionID: session.id)
                guard !Task.isCancelled, QueuedMessage.from(session.queue).first(where: { $0.id == turnID })?.contentKey == key else { return }
                whole = text
            } catch { if !Task.isCancelled { readFailed = true } }
        }
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Color.piInkSecondary); Spacer(); Text(value).foregroundStyle(Color.piInk) }
            .font(PiFont.caption).accessibilityElement(children: .combine)
    }
}

/// Over the composer while it holds a queued message, in the look of the
/// earlier-message edit: Return saves the text in the message's place in the
/// queue, Cancel leaves it as it was, and the draft set aside comes back.
struct QueueEditBanner: View {
    let steering: Bool
    var resolving = false
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").foregroundStyle(Color.piAccent)
                Text(steering ? "Editing a steering message" : "Editing a queued message").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                if resolving { PiSpinner(controlSize: .mini).accessibilityLabel("Waiting for the helper") }
                Button("Cancel", action: cancel).buttonStyle(.piGhost).keyboardShortcut(.cancelAction).disabled(resolving)
            }
            Text("This message and the others waiting are paused while you edit. Return saves it in its place in the queue.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 8).padding(.top, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Editing a queued message")
    }
}

/// Where the reader was when they asked to edit: focus moves to the
/// composer only if they are still there, in the same window and control.
@MainActor struct QueueEditFocus {
    private let window: NSWindow?, responder: ObjectIdentifier?, session: String?
    init(_ model: WorkspaceModel, _ view: SessionDisplay) {
        window = NSApp.keyWindow; responder = NSApp.keyWindow?.firstResponder.map(ObjectIdentifier.init); session = model.focusedSessionID
    }
    func holds(_ model: WorkspaceModel) -> Bool {
        NSApp.keyWindow === window && NSApp.keyWindow?.firstResponder.map(ObjectIdentifier.init) == responder && model.focusedSessionID == session
    }
}

/// The helper's hold on a chat's pending input while one queued message is
/// being edited: which edit, and which message.
struct QueueEditHold: Equatable {
    let editID: String, turnID: String
    init?(_ value: [String: WireValue]?) {
        guard let value, let editID = value["editId"]?.string, let turnID = value["turnId"]?.string else { return nil }
        self.editID = editID; self.turnID = turnID
    }
}

extension WorkspaceModel {
    /// Puts the follow-ups in `order`. A queue that changed during the drag
    /// (a message removed or delivered) is refused by the helper; nothing
    /// moves, and the chat says so.
    func reorderQueued(_ order: [String], sessionID: String) {
        guard let view = displays[sessionID] else { return }
        Task {
            do { _ = try await queueEditRequest("queue.reorder", sessionID: sessionID, params: ["turnIds": .array(order.map(WireValue.string))]) }
            catch HostError.rejected("queue_order", _) { view.notice = "The queue changed while you were dragging, so nothing was moved. Drag again." }
            catch { view.notice = "The queue was not reordered. " + error.localizedDescription }
        }
    }
    /// One `queue.edit.*` command to the chat's helper.
    func queueEditRequest(_ method: String, sessionID: String, params: [String: WireValue]) async throws -> [String: WireValue] {
        if let queueEditOperation { return try await queueEditOperation(method, sessionID, params) }
        guard let item = record(sessionID) else { throw HostError.failure("This chat is no longer open.") }
        let host = try await open(item)
        return try await host.request(method, sessionID: sessionID, params: params).object ?? [:]
    }
    /// Opens a queued message in the chat's composer. The helper first takes
    /// the hold on the chat's pending input and reads the whole message, as
    /// one step; until it answers the composer and its draft are left alone.
    /// `editID` resumes an edit the helper already holds (after a restart).
    func editQueued(_ turnID: String, sessionID: String, resuming editID: String? = nil) {
        guard let view = displays[sessionID] else { return }
        guard view.editingMessageID == nil, !view.editPreparing else {
            view.notice = "Finish or cancel the message edit before rewriting a queued message."; return
        }
        if view.queueEditingID == turnID { view.composerFocusRequest += 1; return }
        guard view.queueEditingID == nil, view.queueEditBeginning == nil else {
            view.notice = "Save or cancel the queued message you are rewriting first."; return
        }
        if let hold = view.queueEditHold, hold.editID != editID {
            view.notice = "Another queued message in this chat is being edited. Resume or cancel that edit first."; return
        }
        if let cancelling = view.queueEditCancelling, cancelling == editID {
            view.notice = "That edit is being cancelled; it can't be resumed."; return
        }
        // An earlier edit whose outcome is not known yet is settled first,
        // by its own identity: never a second edit beside it.
        if let earlier = view.unreconciledQueuedEdit, earlier.editID != editID {
            view.notice = "Checking an earlier queued edit first; choose Edit again in a moment."
            Task { await reconcileQueuedEdit(view, earlier) }
            return
        }
        let edit = editID ?? UUID().uuidString
        // A Cancel of this edit sent and not confirmed: it is settled first,
        // never crossed by a Resume.
        if let record = view.unreconciledQueuedEdit, record.editID == edit, record.pending == "cancel" {
            view.notice = "That edit is being cancelled; it can't be resumed."
            Task { await reconcileQueuedEdit(view, record) }
            return
        }
        // A rewrite recovered for this edit comes back as it was, empty or not.
        let record = view.unreconciledQueuedEdit?.editID == edit ? view.unreconciledQueuedEdit : nil
        // A record with no rewrite of its own (a Begin with no answer) opens the held message.
        let recovered = record?.beginOnly == true ? nil : record
        view.queueEditBeginning = edit; view.queueEditPreparing = turnID
        var params: [String: WireValue] = ["turnId": .string(turnID), "editId": .string(edit)]
        if view.queueEditHoldRevision >= 0 { params["basis"] = .number(Double(view.queueEditHoldRevision)) }
        let focus = QueueEditFocus(self, view)
        Task {
            var reply: [String: WireValue]?, failure: Error?
            do { reply = try await queueEditRequest("queue.edit.begin", sessionID: sessionID, params: params) }
            catch { failure = error }
            let unanswered = failure.map { !Self.definitive($0) } ?? false
            // Abandoned while it was asked (Cancel, or another took its
            // place): the edit is let go of by its identity, which also keeps
            // a Begin still on its way from taking the hold later. Until the
            // helper confirms that, the identity is kept to ask after.
            // Cancelled while it was asked (Cancel Edit on the row, say): abandoned.
            let cancelledMeanwhile = view.queueEditCancelling == edit || (view.unreconciledQueuedEdit?.editID == edit && view.unreconciledQueuedEdit?.pending == "cancel")
            if cancelledMeanwhile { view.queueEditBeginning = nil; view.queueEditPreparing = nil }
            guard view.queueEditBeginning == edit else {
                guard reply != nil || unanswered else { return }
                // The recovery record of a resumed edit stays as it was, its
                // rewrite included; a Save or Remove it says is unanswered is
                // settled first, never crossed by a Cancel.
                // Only the record still standing for this edit: one already
                // settled (a second Cancel, say) is not brought back.
                let kept = view.unreconciledQueuedEdit?.editID == edit ? view.unreconciledQueuedEdit : nil
                if let kept, kept.pending == "save" || kept.pending == "remove" { await reconcileQueuedEdit(view, kept); return }
                await cancelByIdentity(view, kept ?? QueuedEditDraft(editID: edit, turnID: turnID, rewrite: "", original: "", beginOnly: true))
                return
            }
            view.queueEditBeginning = nil; view.queueEditPreparing = nil
            if let reply, let text = reply["text"]?.string {
                // A newer report than this answer: ask after the edit again
                // rather than open an editor for a hold that may be gone.
                if let revision = reply["revision"]?.number, !view.adoptQueueEditHold(QueueEditHold(reply["held"]?.object ?? reply), revision: Int(revision)) {
                    await reconcileQueuedEdit(view, recovered ?? QueuedEditDraft(editID: edit, turnID: turnID, rewrite: "", original: text, beginOnly: true), focus: focus); return
                }
                let keeps = (reply["attachmentCount"]?.number ?? 0) > 0 || (reply["skillCount"]?.number ?? 0) > 0
                beginQueuedEdit(view, turnID: turnID, editID: edit, original: text, rewrite: recovered?.rewrite, keepsInput: keeps, focus: focus.holds(self), pending: recovered)
                return
            }
            switch failure {
            case HostError.rejected("queue_delivering", _)?: view.notice = "That message is already being sent, so it can no longer be edited."
            case HostError.rejected("queue_edit_busy", _)?: view.notice = "Another queued message in this chat is being edited. Finish or cancel that edit first."
            case HostError.rejected("queue_missing", _)?: view.notice = "That message is no longer waiting."
            case HostError.rejected(_, let message)? where !unanswered: view.notice = "The queued message was not opened for rewriting. " + message
            default:
                // No answer: the helper may have taken the hold. Ask after the
                // same edit; nothing is released on a timeout.
                await reconcileQueuedEdit(view, recovered ?? QueuedEditDraft(editID: edit, turnID: turnID, rewrite: "", original: "", beginOnly: true), focus: focus)
            }
        }
    }
    /// An answer that settles what happened (the helper said yes or no), as
    /// opposed to none at all or a journal that can't say.
    static func definitive(_ error: Error) -> Bool {
        if case HostError.rejected(let code, _) = error { return code != "journal_uncertain" }
        return false
    }
    private func beginQueuedEdit(_ view: SessionDisplay, turnID: String, editID: String, original: String, rewrite: String?, keepsInput: Bool, focus: Bool, pending: QueuedEditDraft? = nil) {
        guard view.editingMessageID == nil, view.queueEditingID == nil else { return }
        // Set aside first: the draft saved for the chat stays the one typed.
        view.draftBeforeQueueEdit = view.savedDraft
        view.draftBeforeQueueEdit?.queuedEdit = nil; view.unreconciledQueuedEdit = nil
        view.queueEditOriginal = original
        view.queueEditingID = turnID; view.queueEditID = editID; view.queueEditKeepsInput = keepsInput; view.queueEditResolving = false
        // A Save, Cancel or Remove a reopen found unanswered: only it may be repeated.
        view.queueEditPendingOperation = pending?.pending; view.queueEditSentDigest = pending?.pending == nil ? nil : pending?.sentDigest
        view.draft = rewrite ?? original; view.attachments = []; view.skills = []
        view.directCommand = false; view.completionVisible = false
        // Focus follows only while the reader is still where they asked.
        if focus { focusedSessionID = view.id; view.composerFocusRequest += 1 }
        draftChanged(view)
    }
    /// Return in a composer holding a queued message: the rewrite is saved
    /// in its place, and only when the helper says so does the editor close
    /// and the draft set aside come back. A Save that fails keeps the
    /// rewrite and the hold; one that is not answered is asked after.
    func saveQueuedEdit(sessionID: String) {
        guard let view = displays[sessionID], let turnID = view.queueEditingID, let editID = view.queueEditID, !view.queueEditResolving else { return }
        guard view.attachments.isEmpty, view.skills.isEmpty else {
            view.notice = "A queued message keeps its own images and skills. Remove the ones added here to save it."; return
        }
        // Sent whole: an unchanged Save keeps the message exactly as it was.
        let text = view.draft
        guard text.contains(where: { !$0.isWhitespace }) || view.queueEditKeepsInput else { view.notice = "Type the message, or Cancel to keep it as it was."; return }
        resolveQueuedEdit(view, editID: editID, operation: "save", sent: text) { [weak self] reply in
            guard let self else { return }
            // Typed after Save was pressed: kept, ahead of the draft set aside.
            let newer = view.draft == text ? nil : view.draft
            self.finishQueuedEdit(view)
            if let newer, newer.contains(where: { !$0.isWhitespace }) {
                view.draft = view.draft.isEmpty ? newer : newer + "\n\n" + view.draft
                view.notice = "The queued message was saved as it was when you pressed Return; what you typed after is in the composer."
                self.draftChanged(view)
            }
            Task { await self.recordQueuedRewrite(sessionID: sessionID, turnID: turnID, text: text) }
        }
    }
    /// Cancel keeps the queued message as it was. The editor closes when the
    /// helper confirms; a Begin still being asked is let go of when it answers.
    func cancelQueuedEdit(sessionID: String) {
        guard let view = displays[sessionID] else { return }
        if view.queueEditBeginning != nil { view.queueEditBeginning = nil; view.queueEditPreparing = nil }
        guard view.queueEditingID != nil, let editID = view.queueEditID, !view.queueEditResolving else { return }
        resolveQueuedEdit(view, editID: editID, operation: "cancel", sent: nil) { [weak self] _ in self?.finishQueuedEdit(view) }
    }
    /// Removes the message being rewritten and lets go of the hold, as one step.
    func removeQueuedEdit(sessionID: String) {
        guard let view = displays[sessionID], let editID = view.queueEditID, !view.queueEditResolving else { return }
        resolveQueuedEdit(view, editID: editID, operation: "remove", sent: nil) { [weak self] reply in
            guard let self else { return }
            if let turnID = reply["turnId"]?.string { Task { await self.forgetPendingIntent(sessionID: view.id, turnID: turnID) } }
            self.finishQueuedEdit(view)
        }
    }
    /// One Save, Cancel or Remove: the editor stays, unchangeable, until the
    /// helper answers. A refusal keeps everything; no answer (or a journal
    /// that can't say) is asked after by the same edit. Until that is known,
    /// only the same request may be sent again: never a different one.
    private func resolveQueuedEdit(_ view: SessionDisplay, editID: String, operation: String, sent: String?, done: @escaping ([String: WireValue]) -> Void) {
        let sentDigest = sent.map(QueuedEditDraft.digest)
        if let pending = view.queueEditPendingOperation, pending != operation || view.queueEditSentDigest != sentDigest {
            view.notice = "The earlier " + (pending == "save" ? "save" : pending == "cancel" ? "cancel" : "remove") + " of this edit is not confirmed yet. Repeat it, or wait for the helper to answer."
            view.queueEditResolving = true
            let pendingDigest = view.queueEditSentDigest
            Task { await settleUnansweredQueuedEdit(view, editID: editID, operation: pending, sentDigest: pendingDigest, done: { [weak self] _ in
                guard let self else { return }
                // What is in the composer now is not what that Save sent, or
                // the earlier Cancel or Remove closed an edit with text typed
                // since: kept.
                let original = view.queueEditOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                let newer = pending == "save" ? (QueuedEditDraft.digest(view.draft) != pendingDigest ? view.draft : nil)
                    : (view.draft.trimmingCharacters(in: .whitespacesAndNewlines) != original ? view.draft : nil)
                self.finishQueuedEdit(view)
                if let newer, newer.contains(where: { !$0.isWhitespace }) {
                    view.draft = view.draft.isEmpty ? newer : newer + "\n\n" + view.draft
                    view.notice = "An earlier save of this message took effect; what you typed after it is in the composer."
                    self.draftChanged(view)
                }
            }) }
            return
        }
        view.queueEditResolving = true; view.queueEditPendingOperation = operation; view.queueEditSentDigest = sentDigest
        draftChanged(view)
        var params: [String: WireValue] = ["editId": .string(editID)]
        if let sent { params["text"] = .string(sent) }
        let method = "queue.edit." + operation
        Task {
            do {
                let reply = try await queueEditRequest(method, sessionID: view.id, params: params)
                guard view.queueEditID == editID else { return }
                if let revision = reply["revision"]?.number { view.adoptQueueEditHold(QueueEditHold(reply["held"]?.object), revision: Int(revision)) }
                view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil
                done(reply)
            } catch HostError.rejected(let code, _) where ["queue_edit_cancelled", "queue_edit_removed", "queue_edit_saved", "queue_edit_missing", "command_conflict"].contains(code) {
                guard view.queueEditID == editID else { return }
                // Ended otherwise. A Save refused because another text was
                // saved keeps this rewrite, even one back to the original.
                queuedEditEndedElsewhere(view, keepAlways: code == "command_conflict" || code == "queue_edit_saved" && operation == "save")
            } catch let error where Self.definitive(error) {
                guard view.queueEditID == editID else { return }
                view.queueEditResolving = false; view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil
                view.notice = (operation == "save" ? "The rewrite was not saved" : operation == "cancel" ? "The edit was not cancelled" : "The message was not removed")
                    + "; the queue is still paused. " + error.localizedDescription
                draftChanged(view)
            } catch {
                guard view.queueEditID == editID else { return }
                await settleUnansweredQueuedEdit(view, editID: editID, operation: operation, sentDigest: sentDigest, done: done)
            }
        }
    }
    /// What became of a Save, Cancel or Remove that got no answer, asked
    /// after by its edit a few times. Until the helper says, the editor stays.
    private func settleUnansweredQueuedEdit(_ view: SessionDisplay, editID: String, operation: String, sentDigest: String?, done: @escaping ([String: WireValue]) -> Void) async {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let status = try? await queueEditRequest("queue.edit.status", sessionID: view.id, params: ["editId": .string(editID)]), view.queueEditID == editID else { continue }
            // An answer older than one already taken settles nothing.
            if let revision = status["revision"]?.number, !view.adoptQueueEditHold(QueueEditHold(status["held"]?.object), revision: Int(revision)) { continue }
            switch status["state"]?.string {
            case "active":
                view.queueEditResolving = false; view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil
                view.notice = "That did not reach the helper; the edit is still open and the queue still paused. Try again."
                draftChanged(view)
            case "saved" where operation == "save" && status["textDigest"]?.string == sentDigest:
                view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil; done(status)
            case "cancelled" where operation == "cancel", "removed" where operation == "remove":
                view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil; done(status)
            default:
                queuedEditEndedElsewhere(view, keepAlways: status["state"]?.string == "saved")
            }
            return
        }
        // Still no answer: the editor can be read again, and the saved draft
        // keeps what was asked, so a reopen settles it. Only the same request
        // may be repeated; the helper answers a repeat as it did the first.
        view.queueEditResolving = false
        view.notice = "The helper has not answered, so whether that took effect is not known yet. The rewrite is still here; asking again is safe."
        draftChanged(view)
    }
    /// Lets go of a hold this composer does not hold (one a restart left).
    func cancelHeldQueueEdit(sessionID: String) {
        guard let view = displays[sessionID], let hold = view.queueEditHold, view.queueEditID != hold.editID else { return }
        let record = view.unreconciledQueuedEdit?.editID == hold.editID ? view.unreconciledQueuedEdit! : QueuedEditDraft(editID: hold.editID, turnID: hold.turnID, rewrite: "", original: "", beginOnly: true)
        // A Save or Remove sent and never answered is settled first: no Cancel crosses it.
        if record.pending == "save" || record.pending == "remove" {
            view.notice = "An earlier change to that edit is not confirmed yet; asking the helper first."
            Task { await reconcileQueuedEdit(view, record) }
            return
        }
        // A Resume of this edit still being asked is abandoned: when it
        // answers, it cancels the edit by its identity instead of opening it.
        // The Cancel is recorded first, rewrite kept: an earlier status answer
        // still on its way then opens nothing either.
        if view.queueEditBeginning == hold.editID {
            var cancelling = record; cancelling.pending = "cancel"; cancelling.sentDigest = nil
            view.unreconciledQueuedEdit = cancelling; draftChanged(view)
            view.queueEditBeginning = nil; view.queueEditPreparing = nil; return
        }
        Task { await cancelByIdentity(view, record) }
    }
    /// Cancels an edit by its identity, keeping the record (and so the saved
    /// draft's note of it) until the helper confirms; a rewrite that differs
    /// from the message stays in the composer.
    private func cancelByIdentity(_ view: SessionDisplay, _ record: QueuedEditDraft) async {
        var cancelling = record; cancelling.pending = "cancel"; cancelling.sentDigest = nil
        view.unreconciledQueuedEdit = cancelling; view.queueEditCancelling = record.editID; draftChanged(view)
        // The transient flag goes when this attempt ends; an unanswered Cancel
        // stays in the record (pending "cancel"), which Resume also checks.
        defer { if view.queueEditCancelling == record.editID { view.queueEditCancelling = nil } }
        do {
            let reply = try await queueEditRequest("queue.edit.cancel", sessionID: view.id, params: ["editId": .string(record.editID)])
            if let revision = reply["revision"]?.number { view.adoptQueueEditHold(QueueEditHold(reply["held"]?.object), revision: Int(revision)) }
            finishRecord(view, cancelling, saved: nil)
        } catch HostError.rejected(let code, _) where ["queue_edit_saved", "queue_edit_removed", "queue_edit_missing"].contains(code) {
            // Settled otherwise: what it settled as decides what is kept.
            view.queueEditCancelling = nil
            await reconcileQueuedEdit(view, cancelling)
        } catch {
            view.notice = "A queued edit could not be let go of yet; the queue may stay paused. It is asked after again when the chat is next opened."
        }
    }
    /// Done with a recovery record: it leaves the saved draft, and its
    /// rewrite stays in the composer unless nothing would be lost.
    private func finishRecord(_ view: SessionDisplay, _ record: QueuedEditDraft, saved digest: String?) {
        guard view.unreconciledQueuedEdit == record else { return }
        view.unreconciledQueuedEdit = nil
        if record.beginOnly == true { draftChanged(view); return }
        if let digest {
            // Saved: kept unless what was saved is this very rewrite (a Save
            // answered too late while the reader typed on, even back to the original).
            if digest != QueuedEditDraft.digest(record.rewrite) { keepRewrite(view, record.rewrite, unless: nil) } else { draftChanged(view) }
        } else {
            keepRewrite(view, record.rewrite, unlessOriginalOf: record)
        }
    }
    /// The edit was resolved elsewhere (another Save, Cancel or Remove, or a
    /// restart): the editor closes, and a rewrite that differs from the
    /// message (any rewrite, when other text was saved) stays in the composer
    /// ahead of the draft set aside.
    private func queuedEditEndedElsewhere(_ view: SessionDisplay, keepAlways: Bool = false) {
        let rewrite = view.draft, original = view.queueEditOriginal
        finishQueuedEdit(view)
        keepRewrite(view, rewrite, unless: keepAlways ? nil : original)
    }
    private func keepRewrite(_ view: SessionDisplay, _ rewrite: String, unlessOriginalOf record: QueuedEditDraft) {
        keepRewrite(view, rewrite, unless: record.isOriginal(rewrite) ? rewrite : nil)
    }
    /// Puts a rewrite back in the composer, ahead of its draft, unless it is
    /// blank or the same as `unless`.
    private func keepRewrite(_ view: SessionDisplay, _ rewrite: String, unless original: String?) {
        guard rewrite.contains(where: { !$0.isWhitespace }) else { draftChanged(view); return }
        if let original, rewrite.trimmingCharacters(in: .whitespacesAndNewlines) == original.trimmingCharacters(in: .whitespacesAndNewlines) { draftChanged(view); return }
        // Another queued message is in the composer now: the rewrite joins
        // the draft set aside for that edit, never that edit's text.
        if view.queueEditingID != nil, var before = view.draftBeforeQueueEdit {
            before.text = before.text.isEmpty ? rewrite : rewrite + "\n\n" + before.text
            view.draftBeforeQueueEdit = before
            view.notice = "An earlier queued edit had ended, so its rewrite was not saved. It will be in the composer when this edit ends."
            draftChanged(view); return
        }
        view.draft = view.draft.isEmpty ? rewrite : rewrite + "\n\n" + view.draft
        view.notice = "That queued edit had already ended, so your rewrite was not saved. It is in the composer."
        draftChanged(view)
    }
    private func finishQueuedEdit(_ view: SessionDisplay) {
        var before = view.draftBeforeQueueEdit ?? DraftRecord(id: view.id, text: "")
        before.queuedEdit = nil
        view.queueEditingID = nil; view.queueEditID = nil; view.queueEditOriginal = ""; view.draftBeforeQueueEdit = nil
        view.queueEditResolving = false; view.queueEditKeepsInput = false; view.queueEditPendingOperation = nil; view.queueEditSentDigest = nil
        view.restoreDraft(before)
        draftChanged(view)
    }
    /// A saved draft that held a rewrite, or a Begin with no answer: the
    /// helper says what became of that edit. Still open, it is the
    /// composer's again, with the rewrite as last saved; ended, a rewrite that
    /// differs from what the message became stays in the composer. Until an
    /// answer comes the record stays in the saved draft, so nothing is lost.
    /// Focus moves only if `focus` says the reader is still where they asked.
    func reconcileQueuedEdit(_ view: SessionDisplay, _ record: QueuedEditDraft, focus: QueueEditFocus? = nil) async {
        view.unreconciledQueuedEdit = record
        let status: [String: WireValue]
        do { status = try await queueEditRequest("queue.edit.status", sessionID: view.id, params: ["editId": .string(record.editID)]) }
        catch {
            if record.beginOnly == true { view.notice = "The helper has not said whether the queue is paused for that edit. When it does, the message offers Resume Edit or Cancel Edit." }
            draftChanged(view); return
        }
        guard view.unreconciledQueuedEdit == record, view.queueEditingID == nil else { return }
        let state = status["state"]?.string
        if state == "active", record.pending == "cancel" {
            // A Cancel sent and never answered: it is sent again, never an editor installed.
            if view.queueEditCancelling != record.editID { await cancelByIdentity(view, record) }
            return
        }
        if state == "active" {
            // A newer report says otherwise: the record stays for Resume Edit.
            if let revision = status["revision"]?.number, !view.adoptQueueEditHold(QueueEditHold(status["held"]?.object ?? status), revision: Int(revision)) { draftChanged(view); return }
            let keeps = (status["attachmentCount"]?.number ?? 0) > 0 || (status["skillCount"]?.number ?? 0) > 0
            beginQueuedEdit(view, turnID: record.turnID, editID: record.editID, original: status["text"]?.string ?? "",
                            rewrite: record.beginOnly == true ? nil : record.rewrite, keepsInput: keeps, focus: focus?.holds(self) ?? false, pending: record)
            return
        }
        // An answer older than a report already taken settles nothing: the
        // record stays, to be asked after again.
        if let revision = status["revision"]?.number, !view.adoptQueueEditHold(QueueEditHold(status["held"]?.object), revision: Int(revision)) { draftChanged(view); return }
        if record.beginOnly == true, state == "unknown" {
            // Never granted: a Cancel by its identity keeps a late Begin out,
            // and the record stays until the helper confirms it.
            await cancelByIdentity(view, record)
            if view.unreconciledQueuedEdit == nil { view.notice = "The queued message was not opened for rewriting." }
            return
        }
        if record.beginOnly == true { view.notice = "The queued message was not opened for rewriting." }
        finishRecord(view, record, saved: state == "saved" ? (status["textDigest"]?.string ?? "") : nil)
    }
    /// The digest the helper keeps of a saved rewrite.
    nonisolated static func textDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// A recovered intent shows the text the helper will actually deliver.
    private func recordQueuedRewrite(sessionID: String, turnID: String, text: String) async {
        guard !isEphemeral(sessionID), let store else { return }
        for var intent in (try? await store.list(CommandIntent.self, kind: "pending:\(sessionID)")) ?? [] where intent.turnID == turnID {
            intent.text = text; try? await store.put(intent, kind: "pending:\(sessionID)", id: intent.id)
        }
        pendingIntentsChanged(sessionID)
    }
    private func forgetPendingIntent(sessionID: String, turnID: String) async {
        guard let store else { return }
        for intent in (try? await store.list(CommandIntent.self, kind: "pending:\(sessionID)")) ?? [] where intent.turnID == turnID {
            try? await store.remove(kind: "pending:\(sessionID)", id: intent.id)
        }
        pendingIntentsChanged(sessionID)
    }
}
