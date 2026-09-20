import Foundation

extension WorkspaceModel {
    func preparedContext(_ id: String, automatic: Bool = false) async throws -> [String: WireValue] {
        if !automatic, let pending = automaticContextTask, pending.id == id,
           let item = record(id), let view = displays[id], pending.signature == automaticContextSignature(item, view: view) {
            // Opening the inspector while the selection preview is underway
            // joins that calculation rather than replacing its helper snapshot.
            await pending.task.value
            if let cached = matchingPreparedContext(view), opened.contains(id), hosts[item.workspaceID]?.isReady == true { return cached.summary }
        }
        if automatic { try requireAutomaticContext(id) }
        guard !installPreparing, let item = record(id), let view = displays[id], !view.loading else { throw HostError.failure("Wait for the chat to finish loading before inspecting its context.") }
        guard !item.imported else { throw HostError.failure("Imported history has no native request context. Its original conversation remains available in Search and copy.") }
        guard view.editingMessageID == nil else { throw HostError.failure("Finish or cancel the message edit before previewing the next context. Earlier retained requests remain available below.") }
        if let command = LeadingCommand.leading(view.draft, directInput: view.directCommand) {
            if LeadingCommand.reserved.contains(command.name) { throw HostError.failure("/\(command.name) is an app command, not a model request. Finish or clear the command before previewing context.") }
            throw HostError.failure("Choose /\(command.name) from the skill suggestions first, then preview its structured selection and arguments.")
        }
        try await ensureConfiguration()
        if automatic { try requireAutomaticContext(id) }
        if automatic, let cached = matchingPreparedContext(view), opened.contains(id), hosts[item.workspaceID]?.isReady == true {
            return cached.summary
        }
        let revision = configuration.revision
        let directCommand = view.directCommand
        let params = contextPreviewParams(item, view: view)
        let signature = automaticContextSignature(item, view: view)
        // A footer activation can arrive while an explicit inspector request is
        // awaiting configuration or helper startup. Both must share the same
        // helper snapshot, whose revision would otherwise expire on replacement.
        return try await preparedContextRequests.perform(id, signature: signature, sequence: view.lastSequence) { [self] in
            let host = try await open(item, automaticContext: automatic)
            defer { scheduleIdle(workspaceID:item.workspaceID,host:host) }
            if automatic { try requireAutomaticContext(id) }
            let result = try await host.request("context.preview",sessionID:id,params:params).object ?? [:]
            guard !Task.isCancelled, (!automatic || automaticContextEligible(id)), displays[id] === view, let current = record(id), ContextPreviewBinding(current) == ContextPreviewBinding(item),
                  configuration.revision == revision, view.editingMessageID == nil, view.directCommand == directCommand,
                  contextPreviewParams(current,view:view) == params,
                  (result["seq"]?.number ?? -1) >= view.lastSequence else {
                if let snapshot = result["revision"] { _ = try? await host.request("context.preview.clear",sessionID:id,params:["revision":snapshot]) }
                throw HostError.failure("The conversation, draft, model or settings changed. Refresh the context preview.")
            }
            // Keep the helper's request count in the observable footer,
            // with the exact inputs that make it valid. It is a prepared request,
            // not a provider measurement or a substitute for captured HTTP bytes.
            view.footer.preparedContext = PreparedContextMetrics(summary:result,binding:ContextPreviewBinding(current),
                params:params,configurationRevision:revision,directCommand:directCommand)
            return result
        }
    }
    private func contextPreviewParams(_ item: ChatRecord, view: SessionDisplay) -> [String: WireValue] {
        TurnOverrides.params(for:item,base:["text":.string(view.draft),"skills":.array(view.skills.map(\.wire)),"attachments":.array(view.attachments.map(\.wire))])
    }
    func displayedContext(_ view: SessionDisplay) -> [String: WireValue] {
        if let prepared = matchingPreparedContext(view) { return prepared.context }
        if view.footer.preparingContext {
            return ["state": .string("pending"), "tokens": .null, "source": .string("Preparing the current request inputs")]
        }
        return view.context
    }
    private func matchingPreparedContext(_ view: SessionDisplay) -> PreparedContextMetrics? {
        guard let preview = view.footer.preparedContext, let item = record(view.id),
              preview.binding == ContextPreviewBinding(item), preview.configurationRevision == configuration.revision,
              preview.directCommand == view.directCommand, view.editingMessageID == nil,
              preview.params == contextPreviewParams(item,view:view), preview.sequence >= view.lastSequence,
              Date().timeIntervalSince(preview.createdAt) <= 300 else { return nil }
        return preview
    }

    func automaticContextActivation(_ view: SessionDisplay) -> AutomaticContextActivation {
        AutomaticContextActivation(eligible: automaticContextEligible(view.id),
            binding: record(view.id).map(ContextPreviewBinding.init), configurationRevision: configuration.revision)
    }
    private func automaticContextSignature(_ item: ChatRecord, view: SessionDisplay) -> AutomaticContextSignature {
        AutomaticContextSignature(binding: ContextPreviewBinding(item), params: contextPreviewParams(item, view: view),
                                  configurationRevision: configuration.revision, directCommand: view.directCommand)
    }
    private func automaticContextEligible(_ id: String) -> Bool {
        guard !accountingStopped, !installPreparing, page == .chats, (focusedSessionID ?? selectedID) == id, !pendingChatIDs.contains(id),
              let item = record(id), let view = displays[id], !view.loading,
              view.contextSelectionReady || (side(id) != nil && opened.contains(id)),
              !item.imported, !item.isArchived, !item.isBackgroundTask,
              !view.hasWork, view.state == "idle", !view.uncertain, view.recovered.isEmpty, view.editingMessageID == nil,
              !workspaceChangesInFlight.contains(item.workspaceID), let workspace = workspace(for: item.workspaceID), workspace.trusted,
              let profile = profiles.first(where: { $0.id == item.profileID }), profile.api == LiteLLMConfiguration.supportedAPI,
              !LeadingCommand.begins(view.draft, directInput: view.directCommand) else { return false }
        return true
    }
    func requireAutomaticContext(_ id: String) throws {
        try Task.checkCancellation()
        guard automaticContextEligible(id) else { throw CancellationError() }
    }
    /// Selecting a chat previews after a short pause; typing waits longer so
    /// the helper is not asked to recount the draft on every keystroke.
    static let selectionPreviewDelay: Duration = .milliseconds(180)
    static let typingPreviewDelay: Duration = .milliseconds(1_500)
    /// Only the focused idle chat counts. Tab changes and draft edits share a
    /// debounce; output deltas do not start fresh preview calculations.
    func scheduleAutomaticContext(_ id: String, delay: Duration = WorkspaceModel.selectionPreviewDelay) {
        guard automaticContextEligible(id), let view = displays[id], let item = record(id) else { cancelAutomaticContext(id); return }
        guard matchingPreparedContext(view) == nil else { cancelAutomaticContext(id); return }
        let signature = automaticContextSignature(item, view: view)
        if let pending = automaticContextTask, pending.id == id, pending.signature == signature { return }
        cancelAutomaticContext()
        let token = UUID(), operation = automaticContextOperation
        view.footer.preparingContext = true
        let task = Task { [weak self, weak view] in
            // Coalesce rapid edits and tab traversal before opening the helper.
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let view else { return }
            defer {
                if automaticContextTask?.token == token { automaticContextTask = nil; view.footer.preparingContext = false }
            }
            do {
                try requireAutomaticContext(id)
                guard automaticContextTask?.token == token, automaticContextSignature(record(id) ?? item, view: view) == signature else { return }
                if !opened.contains(id) {
                    // Creating/resuming a runtime is allowed only when no
                    // interrupted work would be repaired or adopted on open.
                    if isEphemeral(id) { return }
                    if let path = item.path, !(try await history.allowsAutomaticContext(path: path, id: id)) { return }
                    if try await store?.get(WireValue.self, kind: "handoff", id: id) != nil { return }
                }
                try requireAutomaticContext(id)
                guard automaticContextTask?.token == token, let current = record(id), automaticContextSignature(current, view: view) == signature else { return }
                if let operation {
                    let result = try await operation(current, signature.params)
                    try requireAutomaticContext(id)
                    guard automaticContextTask?.token == token, displays[id] === view,
                          let latest = record(id), automaticContextSignature(latest, view: view) == signature,
                          (result["seq"]?.number ?? -1) >= view.lastSequence else { return }
                    view.footer.preparedContext = PreparedContextMetrics(summary: result, binding: signature.binding,
                        params: signature.params, configurationRevision: signature.configurationRevision, directCommand: signature.directCommand)
                } else { _ = try await preparedContext(id, automatic: true) }
            } catch {
                // Selection is read-only UI work. A locked key, removed project
                // or unavailable helper must not interrupt chat navigation.
                // Clicking the meter still provides explicit inspection/retry.
            }
        }
        automaticContextTask = AutomaticContextTask(id: id, signature: signature, token: token, task: task)
    }
    func cancelAutomaticContext(_ id: String? = nil) {
        guard let pending = automaticContextTask, id == nil || pending.id == id else { return }
        automaticContextTask = nil; pending.task.cancel()
        displays[pending.id]?.footer.preparingContext = false
    }
    func readPreparedContext(_ id: String, revision: String, section: String? = nil, offset: Int = 0, itemOffset: Int = 0) async throws -> [String: WireValue] {
        var params: [String: WireValue] = ["revision":.string(revision),"offset":.number(Double(offset)),"itemOffset":.number(Double(itemOffset))]
        if let section { params["section"] = .string(section) }
        return try await debugRequest("context.preview.read",sessionID:id,params:params)
    }
    func clearPreparedContext(_ id: String, revision: String) async {
        _ = try? await debugRequest("context.preview.clear",sessionID:id,params:["revision":.string(revision)])
    }
}

/// The helper retains one prepared snapshot per session. Matching callers share
/// its revision; changed inputs wait for the previous request so an older reply
/// cannot replace a newer snapshot. Cancelling a waiter does not cancel work
/// another caller is reading; the operation still checks its input/selection guards.
@MainActor final class PreparedContextRequests {
    private struct Pending {
        let token: UUID
        let signature: AutomaticContextSignature
        let sequence: Double
        let task: Task<[String: WireValue], Error>
    }
    private var pending: [String: Pending] = [:]

    func perform(_ id: String, signature: AutomaticContextSignature, sequence: Double,
                 operation: @escaping @MainActor () async throws -> [String: WireValue]) async throws -> [String: WireValue] {
        try Task.checkCancellation()
        while let current = pending[id] {
            if current.signature == signature, current.sequence == sequence {
                let result = try await current.task.value
                try Task.checkCancellation()
                return result
            }
            let result = try? await current.task.value
            try Task.checkCancellation()
            // Startup/snapshot events can advance the desktop sequence while
            // the shared request is being built. Reuse it when its actual
            // helper sequence already covers the newer caller's observation.
            if current.signature == signature, let result, (result["seq"]?.number ?? -1) >= sequence { return result }
        }
        let token = UUID()
        let task = Task { [self] in
            defer { if pending[id]?.token == token { pending.removeValue(forKey: id) } }
            return try await operation()
        }
        pending[id] = Pending(token: token, signature: signature, sequence: sequence, task: task)
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }
}

struct PreparedContextMetrics {
    let summary: [String: WireValue]
    let binding: ContextPreviewBinding
    let params: [String: WireValue]
    let configurationRevision: Int64
    let directCommand: Bool
    let sequence: Double
    let createdAt = Date()
    let context: [String: WireValue]
    init?(summary: [String: WireValue], binding: ContextPreviewBinding, params: [String: WireValue], configurationRevision: Int64, directCommand: Bool) {
        guard let context = Self.context(from: summary),
              let sequence = summary["seq"]?.number, sequence.isFinite, sequence >= 0 else { return nil }
        self.binding = binding; self.params = params; self.configurationRevision = configurationRevision
        self.summary = summary
        self.directCommand = directCommand; self.sequence = sequence
        self.context = context
    }

    /// Inspector and footer normalize one helper result. A malformed new count
    /// must not silently fall back to the unrelated legacy estimate field.
    static func context(from summary: [String: WireValue]) -> [String: WireValue]? {
        let count: [String: WireValue]
        if let value = summary["count"] {
            guard let supplied = value.object else { return nil }
            count = supplied
        } else {
            count = ["tokens": summary["estimatedTokens"] ?? .null, "estimated": .bool(true), "method": .string("heuristic")]
        }
        guard let tokens = count["tokens"]?.number, tokens.isFinite, tokens >= 0,
              let capacity = summary["contextWindow"]?.number, capacity.isFinite, capacity > 0 else { return nil }
        var context = count
        context["tokens"] = .number(tokens)
        context["contextWindow"] = .number(capacity)
        context["outputReserve"] = count["outputBudget"] ?? summary["outputReserve"] ?? .null
        context["estimated"] = .bool(count["estimated"]?.bool ?? true)
        context["state"] = .string("prepared")
        context["preparation"] = .string(summary["mode"]?.string == "active-context" ? "Prepared running context; unsent draft and queued turns excluded" :
            (summary["draftIncluded"]?.bool == true ? "Prepared next request, including unsent draft and selected skills/images" : "Prepared next request; no draft included"))
        context["source"] = count["source"] ?? .string("Estimated request context")
        return context
    }
}

typealias AutomaticContextOperation = @MainActor (ChatRecord, [String: WireValue]) async throws -> [String: WireValue]
struct AutomaticContextSignature: Equatable {
    let binding: ContextPreviewBinding
    let params: [String: WireValue]
    let configurationRevision: Int64
    let directCommand: Bool
}
struct AutomaticContextActivation: Equatable {
    let eligible: Bool
    let binding: ContextPreviewBinding?
    let configurationRevision: Int64
}
struct AutomaticContextTask {
    let id: String
    let signature: AutomaticContextSignature
    let token: UUID
    let task: Task<Void, Never>
}

/// Journal allocation, title edits and sidebar organization do not change a
/// request's inputs. Route/tool changes do and invalidate an in-flight preview.
struct ContextPreviewBinding: Equatable {
    let id: String, workspaceID: String, profileID: String, toolMode: String
    let imported: Bool, connectionTest: Bool
    let model: String?, thinkingLevel: String?
    let contextWindow: Int?, maxOutputTokens: Int?, modelOutputLimit: Int?
    init(_ record: ChatRecord) {
        id = record.id; workspaceID = record.workspaceID; profileID = record.profileID; toolMode = record.toolMode
        imported = record.imported; connectionTest = record.connectionTest == true
        model = record.model; thinkingLevel = record.thinkingLevel; contextWindow = record.contextWindow; maxOutputTokens = record.maxOutputTokens; modelOutputLimit = record.modelOutputLimit
    }
}
