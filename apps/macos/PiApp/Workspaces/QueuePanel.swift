import SwiftUI

// Messages waiting their turn: drag to reorder, rewrite one in place,
// promote one to steering so it reaches the run after its tool batch.

/// Pending messages: drag follow-ups to reorder, rewrite one in place, promote
/// one to steering so it reaches the current run after its tool batch, or remove it.
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
    @State private var editText = ""
    /// True while the whole text of a previewed submission is being read.
    @State private var prefilling = false
    @State private var prefill = UUID()
    private var editingID: String? { session.queueEditingID }
    private var items: [QueuedMessage] { QueuedMessage.from(session.queue) }
    private var followUps: [QueuedMessage] { items.filter { !$0.steering } }
    private var steering: [QueuedMessage] { items.filter(\.steering) }
    /// One follow-up row, and the room the row being rewritten needs instead:
    /// a field of up to four lines with Save and Cancel beside it. Without the
    /// taller slot the panel clipped what was being typed and the follow-ups
    /// under it, with no way to scroll them back.
    static let rowHeight: CGFloat = 30
    static let editingRowHeight: CGFloat = 88
    static func listHeight(rows: Int, editing: Bool) -> CGFloat {
        CGFloat(rows) * rowHeight + (editing ? editingRowHeight - rowHeight : 0)
    }
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
            .frame(height: Self.listHeight(rows: followUps.count, editing: followUps.contains { $0.id == editingID }))
            .accessibilityIdentifier("queue-follow-ups")
        }
        .padding(PiSpacing.md)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        // The field opens with the message it is rewriting, whether the pencil
        // opened it or the chat was already editing when the panel appeared.
        .onChange(of: session.queueEditingID, initial: true) { _, id in beginEditing(id) }
        .onChange(of: session.queue.count) { _, _ in
            if let editingID, !items.contains(where: { $0.id == editingID }) { session.queueEditingID = nil }
        }
    }
    @ViewBuilder private func row(_ item: QueuedMessage, index: Int?) -> some View {
        HStack(spacing: PiSpacing.sm) {
            if item.steering {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                    .help("Steering: delivered after the current tool batch")
            } else {
                Text(index.map(String.init) ?? "").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 14)
            }
            if editingID == item.id {
                TextField("Message", text: $editText, axis: .vertical).textFieldStyle(.plain).font(PiFont.body).lineLimit(1...4)
                    .onSubmit { commitEdit(item) }
                    .disabled(prefilling)
                    .accessibilityIdentifier("queue-edit-field")
                if prefilling { ProgressView().controlSize(.mini).help("Reading the whole message") }
                Button("Save") { commitEdit(item) }.buttonStyle(.piPrimaryCompact)
                    .disabled(prefilling || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { session.queueEditingID = nil }.buttonStyle(.piGhost)
            } else {
                Text(item.text).lineLimit(1).font(PiFont.body).foregroundStyle(Color.piInk)
                Spacer()
                if !item.steering && session.busy {
                    PiIconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22) {
                        model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: session.id)
                    }.help("Deliver after the current tool batch instead of after the run")
                }
                PiIconButton(symbol: "pencil", label: "Edit queued message", size: 22) { session.queueEditingID = item.id; editText = item.text }
                PiIconButton(symbol: "xmark", label: "Remove", size: 22) {
                    model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id)
                }
            }
        }
        .frame(minHeight: 26)
        .accessibilityIdentifier("queue-item-" + item.id)
    }
    /// Opens the field on a queued row. A previewed submission waits for the
    /// helper's copy: saving the preview would drop everything past it.
    private func beginEditing(_ id: String?) {
        let token = UUID(); prefill = token
        guard let id, let item = items.first(where: { $0.id == id }) else { editText = ""; prefilling = false; return }
        editText = item.text
        guard item.truncated else { prefilling = false; return }
        prefilling = true
        Task {
            do {
                let whole = try await model.queuedMessageText(turnID: id, sessionID: session.id)
                guard prefill == token, session.queueEditingID == id else { return }
                editText = whole; prefilling = false
            } catch {
                guard prefill == token, session.queueEditingID == id else { return }
                prefilling = false; session.queueEditingID = nil
                session.notice = "The whole queued message could not be read, so it was not opened for rewriting. " + error.localizedDescription
            }
        }
    }
    private func commitEdit(_ item: QueuedMessage) {
        // Never save a preview back over the message it previews.
        guard !prefilling else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text != item.text { model.action("queue.update", params: ["turnId": .string(item.id), "text": .string(text)], sessionID: session.id) }
        session.queueEditingID = nil
    }
}
