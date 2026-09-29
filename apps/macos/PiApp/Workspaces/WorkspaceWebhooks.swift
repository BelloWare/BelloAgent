import Foundation

/// A webhook made ready for one chat: the request, and how it was made.
struct WebhookPreparation: Sendable {
    var request: WebhookRequest
    var context: WebhookContext
    /// What the mini model was asked and what it wrote; nil when it was not asked.
    var prompt: String?
    var reply: String?
    var model: String?
    /// Every mini-model parameter as sent: its value, or its fallback.
    var parameters: [WebhookHeader] = []
    /// Parameters the mini model left out, sent as their fallback.
    var missing: [String] = []
    /// Why the mini model's parameters are not in the request. The webhook
    /// is still sent: that the chat finished is the news.
    var modelNote: String?
}

// The webhook a chat sends when it finishes and waits for its user (Settings
// → Notifications): whether a chat sends it, the moment it fires, the mini
// model's parameters, and the request. Each chat can turn it off in its ⋯
// menu, where it can also be previewed.
extension WorkspaceModel {
    /// The webhook in Settings, when it is on.
    var activeWebhook: WebhookSettings? { configuration.webhook.flatMap { $0.enabled ? $0 : nil } }

    /// The user's own saved chats: not utility requests, connection tests,
    /// imported history, archived chats or unsaved sides.
    func webhookEligible(_ id: String) -> Bool {
        guard let item = chatRecord(id), !isEphemeral(id) else { return false }
        return !item.isBackgroundTask && item.connectionTest != true && !item.imported && !item.isArchived && item.workspaceID != WorkspaceRecord.scratchID
    }
    /// Whether the chat sends the webhook when it finishes.
    func sendsWebhook(_ id: String) -> Bool { activeWebhook != nil && webhookEligible(id) && chatRecord(id)?.webhookOff != true }

    /// Turns the webhook off or on again for one chat. Saved with the chat.
    func setWebhookOff(_ off: Bool, for id: String) async throws {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { throw HostError.failure("This chat is no longer available.") }
        let value: Bool? = off ? true : nil
        guard chats[index].webhookOff != value else { return }
        chats[index].webhookOff = value
        // A chat not yet sent has no record; its first message writes it, switch included.
        if !pendingChatIDs.contains(id) {
            guard let store else { throw StoreError.unavailable }
            try await store.put(chats[index], kind: "chat", id: id)
        }
    }
    func toggleWebhook(for id: String) {
        let off = chatRecord(id)?.webhookOff != true
        Task {
            do { try await setWebhookOff(off, for: id) }
            catch { self.error = "The chat's webhook switch was not saved: " + error.localizedDescription }
        }
    }
    func previewWebhook(_ id: String) {
        guard !installPreparing, webhookEligible(id) else { return }
        webhookPreviewTarget = RenameTarget(id: id)
    }

    /// Every snapshot of a chat, through `observeSessionCompletion`: the
    /// moment it finishes and waits sends the webhook, once.
    func observeWebhookFinish(sessionID: String, snapshot: [String: WireValue], baseline: Bool) {
        guard let display = displays[sessionID], let outcome = display.webhookTracker.observe(snapshot, baseline: baseline),
              let settings = activeWebhook, sendsWebhook(sessionID) else { return }
        let failure = outcome == "failed" ? (snapshot["preflightError"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Run failed." : ""
        let finishedAt = Date(), key = UUID()
        webhookTasks[key] = Task { [weak self] in
            await self?.sendFinishedWebhook(sessionID, settings: settings, outcome: outcome, error: failure, finishedAt: finishedAt)
            self?.webhookTasks[key] = nil
        }
    }

    private func sendFinishedWebhook(_ id: String, settings: WebhookSettings, outcome: String, error failure: String, finishedAt: Date) async {
        let title = chatRecord(id)?.title ?? "chat"
        do {
            let prepared = try await prepareWebhook(for: id, settings: settings, status: outcome, error: failure, finishedAt: finishedAt)
            try Task.checkCancellation()
            _ = try await deliverWebhook(prepared.request, retrying: true)
            // Said in the chat's footer only: the webhook went out.
            if let note = prepared.modelNote { displays[id]?.notice = "Webhook sent without the mini model's parameters. " + note }
        } catch is CancellationError {
        } catch {
            displays[id]?.notice = "Webhook not sent: " + error.localizedDescription
            self.error = "The webhook for “\(title)” was not sent: " + error.localizedDescription
        }
    }

    /// The webhook the chat sends, with the mini model's parameters. With no
    /// status given it describes the chat as it is now: the preview.
    func prepareWebhook(for id: String, settings: WebhookSettings, status: String? = nil, error failure: String? = nil, finishedAt: Date = Date()) async throws -> WebhookPreparation {
        guard let item = chatRecord(id) else { throw HostError.failure("This chat is no longer available.") }
        let profile = profiles.first { $0.id == item.profileID }
        let display = displays[id]
        var context = WebhookContext()
        context.chatID = id; context.chatTitle = item.title
        context.project = workspace(for: item.workspaceID).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
        context.status = status ?? (display?.state == "error" ? "failed" : "completed")
        context.error = failure ?? (context.status == "failed" ? display?.failureMessage ?? "Run failed." : "")
        context.model = item.model ?? profile?.modelId ?? ""
        context.finishedAt = ISO8601DateFormatter().string(from: finishedAt)
        var messages = display?.messages ?? []
        if !messages.contains(where: { $0.role == "user" && $0.kind == nil }), let path = item.path,
           let page = try? await history.read(path: path) { messages = page.messages }
        (context.lastRequest, context.lastReply) = WebhookContext.exchange(in: messages)
        let parameters = try settings.parameterList()
        var values = context.values
        var preparation = WebhookPreparation(request: try WebhookRequest.render(settings, values: values), context: context)
        if !parameters.isEmpty {
            do {
                let asked = try await askWebhookModel(item, profile: profile, context: context, parameters: parameters, instructions: settings.prompt)
                preparation.prompt = asked.prompt; preparation.reply = asked.reply; preparation.model = asked.model
                let parsed = WebhookPrompt.values(from: asked.reply, names: parameters.map(\.name))
                values.merge(parsed.values) { _, written in written }
                preparation.missing = parsed.missing
                if parsed.values.isEmpty { preparation.modelNote = "The mini model's reply held no JSON object with the parameters." }
            } catch {
                try Task.checkCancellation()
                preparation.modelNote = error.localizedDescription
            }
            for parameter in parameters where values[parameter.name] == nil { values[parameter.name] = WebhookPrompt.fallback(parameter.name, context: context) }
            preparation.parameters = parameters.map { WebhookHeader(name: $0.name, value: values[$0.name] ?? "") }
        }
        preparation.request = try WebhookRequest.render(settings, values: values)
        return preparation
    }

    /// The connection's mini model writes the parameters, from the chat's
    /// title, the last request, the assistant's output and the user's own
    /// instructions, in a throwaway chat with no tools or project context.
    private func askWebhookModel(_ item: ChatRecord, profile: ProfileRecord?, context: WebhookContext,
                                 parameters: [(name: String, description: String)], instructions: String) async throws -> (prompt: String, reply: String, model: String) {
        guard !installPreparing, let profile else { throw HostError.failure("This chat's connection is unavailable.") }
        _ = await listModels(for: profile)
        let descriptors = catalogEntry(for: profile).descriptors
        guard TitleGenerationPlan.miniModel(profile: profile, descriptors: descriptors) != nil else {
            throw HostError.failure("“\(profile.name)” has no mini model; choose one in Settings.")
        }
        guard let route = WebhookModelRoute(profile: profile, descriptors: descriptors) else {
            throw HostError.failure("The mini model's context window or output limit is too small for the request.")
        }
        let budget = route.excerptBudget(instructions: instructions)
        guard budget >= 200 else { throw HostError.failure("The mini model's context window is too small for the chat's excerpts and your instructions.") }
        let prompt = WebhookPrompt.text(context: context, parameters: parameters, instructions: instructions, budget: budget)
        let request = MiniModelRequest(model: route.model, contextWindow: route.contextWindow, maxOutputTokens: route.maxOutputTokens,
                                       modelOutputLimit: route.modelOutputLimit, thinkingLevel: route.thinkingLevel, prompt: prompt,
                                       task: "webhook", title: "Webhook notification", timeout: 60, name: "mini model's request")
        func answer(_ messages: [TranscriptMessage]) throws -> String {
            guard let answer = messages.last(where: { $0.role == "assistant" && $0.kind == nil }), !answer.endedUnfinished else {
                throw HostError.failure("The mini model did not answer.")
            }
            return answer.text
        }
        // Kept as the notification it wrote: its parameters, in the webhook's order.
        let messages = try await askMiniModel(request, profile: profile, sourceID: item.id) { messages in
            try BackgroundRequests.webhookResult(reply: answer(messages), names: parameters.map(\.name)) ?? answer(messages)
        }
        return (prompt, try answer(messages), route.model)
    }

    /// Sends a request and returns the HTTP status; anything but 2xx fails.
    /// No cookies, cache or stored credentials. `retrying`: a finished
    /// chat's webhook, which nobody is watching, is sent once more a few
    /// seconds later when the network failed or the address answered 429 or
    /// 5xx; an address that refused it (other 4xx) is not asked again. The
    /// preview's and Settings' sends answer at once.
    func deliverWebhook(_ request: WebhookRequest, retrying: Bool = false) async throws -> Int {
        do { return try await sendWebhookOnce(request) }
        catch let failure as WebhookDeliveryFailure where retrying && failure.transient {
            try await Task.sleep(for: webhookRetryDelay)
            do { return try await sendWebhookOnce(request) }
            catch let again as WebhookDeliveryFailure { throw WebhookError.failed(again.message + " Tried twice, a few seconds apart.") }
        } catch let failure as WebhookDeliveryFailure { throw WebhookError.failed(failure.message) }
    }

    /// The Settings group's Send Test: the webhook as typed, filled from a
    /// sample chat, its parameters with sample words rather than a mini
    /// model's (a test needs no model request).
    func sendTestWebhook(_ settings: WebhookSettings) async throws -> Int {
        var test = settings; test.enabled = true
        try test.validate()
        var context = WebhookContext()
        context.chatID = "sample-chat"; context.chatTitle = "Sample chat"; context.project = "sample-project"
        context.lastRequest = "Add a unit test for the retry loop."
        context.lastReply = "Added the test and ran the suite: 12 passed."
        context.model = requestProfiles.first?.modelId ?? "model"
        context.finishedAt = ISO8601DateFormatter().string(from: Date())
        var values = context.values
        for parameter in try test.parameterList() {
            values[parameter.name] = parameter.name == "title" ? "Webhook test from Bello Agent" : "Sample \(parameter.name) written by the mini model"
        }
        return try await deliverWebhook(try WebhookRequest.render(test, values: values))
    }

    private func sendWebhookOnce(_ request: WebhookRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let status: Int
        do {
            let (_, response) = try await session.data(for: request.urlRequest)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WebhookDeliveryFailure(message: error.localizedDescription, transient: true)
        }
        guard (200..<300).contains(status) else {
            throw WebhookDeliveryFailure(message: "\(request.url.host ?? "The address") answered HTTP \(status).", transient: status == 429 || status >= 500)
        }
        return status
    }
}

/// Why one send failed, and whether trying again a little later may help.
struct WebhookDeliveryFailure: Error {
    let message: String
    let transient: Bool
}
