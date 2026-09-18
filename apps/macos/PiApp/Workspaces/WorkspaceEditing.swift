import SwiftUI
import AppKit

// Edit-and-resend (contract H4) and the per-message details entry point.
// The composer switches into edit mode for one user message; Send then issues
// `turn.edit` with the same draft/intent/receipt bookkeeping as `send()`.
extension WorkspaceModel {
    nonisolated static let editTurnMethod = "turn.edit"

    /// Parameters for `turn.edit` exactly as the host contract defines them.
    nonisolated static func editTurnParams(messageID: String, text: String, turnID: String, attachments: [AttachmentRecord], skills: [SkillChip], model: String? = nil, thinkingLevel: String? = nil) -> [String: WireValue] {
        var params: [String: WireValue] = ["messageId": .string(messageID), "text": .string(text), "clientTurnId": .string(turnID),
                                           "attachments": .array(attachments.map(\.wire)), "skills": .array(skills.map(\.wire))]
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty, model.count <= 200 { params["model"] = .string(model) }
        if let thinkingLevel, ["default", "off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(thinkingLevel) { params["thinkingLevel"] = .string(thinkingLevel) }
        return params
    }
    /// Per-chat model/thinking overrides (contract H6, `ChatRecord.model` /
    /// `ChatRecord.thinkingLevel`) read through Codable so this compiles both
    /// before and after another change adds those stored properties.
    nonisolated static func turnOverrides<Record: Encodable>(_ item: Record) -> (model: String?, thinkingLevel: String?) {
        guard let data = try? JSONEncoder().encode(item), let object = try? JSONDecoder().decode([String: WireValue].self, from: data) else { return (nil, nil) }
        return (object["model"]?.string, object["thinkingLevel"]?.string)
    }

    func showMessageDetail(_ sessionID: String, messageID: String) {
        messageDetailSessionID = sessionID; messageDetailID = messageID; showMessageDetail = true
    }

    /// Loads a user message into the composer. Nothing is sent until Send.
    func editMessage(_ messageID: String, sessionID: String) {
        guard let view = displays[sessionID], let item = record(sessionID) else { return }
        guard !item.imported else { error = "Imported originals are read-only. Continue as a separate chat before editing a message."; return }
        guard !isEphemeral(sessionID) else { view.notice = "Keep this side chat before editing its messages."; return }
        guard let message = view.messages.first(where: { $0.id == messageID }), message.role == "user", message.kind == nil, !messageID.hasPrefix("stream:") else { return }
        guard !view.loading, side(sessionID)?.keeping != true else { return }
        if message.truncated == true {
            view.loading = true
            Task {
                defer { view.loading = false }
                do { let text = try await fullEditText(messageID, sessionID: sessionID); beginEdit(messageID, text: text, view: view) }
                catch { view.notice = "The complete message could not be loaded for editing: " + error.localizedDescription }
            }
        } else { beginEdit(messageID, text: message.text, view: view) }
    }
    private func fullEditText(_ messageID: String, sessionID: String) async throws -> String {
        var text = "", offset = 0
        repeat {
            let (part, total) = try await messagePage(id: messageID, field: "text", offset: offset, sessionID: sessionID)
            guard total <= 262_144, !part.isEmpty || total == 0 else { throw HostError.failure("The original message exceeds the editor limit or is incomplete.") }
            text += part; offset += (part as NSString).length
            guard text.utf8.count <= 262_144 else { throw HostError.failure("The original message exceeds the 256 KiB submission limit.") }
            if offset >= total { return text }
        } while true
    }
    private func beginEdit(_ messageID: String, text: String, view: SessionDisplay) {
        if view.editingMessageID == nil { view.draftBeforeEdit = view.savedDraft }
        view.editingMessageID = messageID
        view.draft = text; view.attachments = []; view.skills = []; view.directCommand = false; view.completionVisible = false
        focusedSessionID = view.id
        // Editing a message is typing: the cursor lands in the composer with the text.
        view.composerFocusRequest += 1
        if view.busy || !view.queue.isEmpty { view.notice = "Editing waits for the current run and queue to finish before resending." }
        draftChanged(view)
    }
    func cancelEdit(sessionID: String) {
        guard let view = displays[sessionID], view.editingMessageID != nil, !view.loading else { return }
        finishEdit(view)
    }
    private func finishEdit(_ view: SessionDisplay) {
        let original = view.draftBeforeEdit ?? DraftRecord(id: view.id, text: "")
        view.restoreDraft(original)
        draftChanged(view)
    }
    /// Resends the edited message with `turn.edit`. Preconditions mirror the
    /// host: idle session, empty queue, message still in the current context.
    func sendEdit(sessionID: String? = nil) {
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), let view = displays[id], let messageID = view.editingMessageID, let store else { return }
        guard !view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.skills.isEmpty, !view.loading, !installPreparing, side(id)?.keeping != true else { return }
        guard !item.imported, !isEphemeral(id) else { view.notice = "Continue or keep this chat before editing its messages."; return }
        guard !view.busy, view.queue.isEmpty, view.queueCount == 0 else { view.notice = "Wait for the current run and queue to finish before resending an edited message."; return }
        guard view.draft.utf8.count <= 262_144 else { error = "The draft exceeds the 256 KiB submission limit"; return }
        if view.uncertain {
            let alert = NSAlert(); alert.messageText = "Previous command outcome is uncertain"
            alert.informativeText = "Review the transcript and any file or tool effects. Sending again starts a new command and may repeat effects."
            alert.addButton(withTitle: "I Reviewed It — Send New Command"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; view.uncertain = false
        }
        let attachments = view.attachments, skills = view.skills
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString, previousState = view.state
        let savedDraft = view.savedDraft
        let params = TurnOverrides.params(for: item, base: Self.editTurnParams(messageID: messageID, text: text, turnID: turnID, attachments: attachments, skills: skills))
        view.loading = true; view.compactionNotice = nil
        Task {
            defer { view.loading = false }
            var dispatched = false
            do {
                if !isEphemeral(item.id) { try await store.put(savedDraft, kind: "draft", id: item.id) }
                let host = try await open(item)
                let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent", epoch: host.epoch, attachments: attachments, skills: skills)
                if !isEphemeral(item.id) { try await store.put(intent, kind: "pending:\(item.id)", id: commandID) }
                dispatched = true
                if !view.busy { view.state = "queued" }
                _ = try await host.request(Self.editTurnMethod, sessionID: item.id, params: params, commandID: commandID)
                if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID) }
                finishEdit(view)
                latest(sessionID: item.id)
            } catch {
                view.notice = error.localizedDescription
                if case HostError.rejected = error { try? await store.remove(kind: "pending:\(item.id)", id: commandID); view.state = previousState }
                else { view.uncertain = dispatched; view.state = dispatched ? "interrupted" : previousState }
            }
        }
    }
}

/// Slim banner above the composer field while an earlier message is being edited.
/// Strip above the composer while context is being compacted and after it
/// finished, so the change is noticed even when the transcript marker has
/// scrolled away. Dismissed by the next send or the button.
struct CompactionBanner: View {
    @ObservedObject var session: SessionDisplay
    let dismiss: () -> Void
    private var compacting: Bool { session.runStatus == "compacting" }
    var body: some View {
        HStack(spacing: 6) {
            if compacting { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInfo) }
            Text(compacting ? "Compacting context…" : "Context compacted").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.piInk)
            Text("· " + (compacting ? "older messages are being summarized to fit the model's window" : session.compactionNotice ?? ""))
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if !compacting { Button("Dismiss", action: dismiss).buttonStyle(.piGhost) }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
        .background(Color.piInfo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8).padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compacting ? "Compacting context" : "Context compacted. " + (session.compactionNotice ?? ""))
        .accessibilityIdentifier("compactionBanner")
    }
}

struct EditingBanner: View {
    @ObservedObject var session: SessionDisplay
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.line").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piAccent)
            Text("Editing an earlier message").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.piInk)
            Text("· replies after it will be replaced in context").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel).buttonStyle(.piGhost).keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
        .background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8).padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editing an earlier message. Replies after it will be replaced in context.")
    }
}
