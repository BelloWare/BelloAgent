import Foundation

enum ConnectionProbeError: LocalizedError {
    case changed, cancelled, timedOut, failed(String)
    var errorDescription: String? {
        switch self {
        case .changed: "The connection or project changed during the test. Save your settings and test again."
        case .cancelled: "Connection test cancelled. Nothing was retried."
        case .timedOut: "The gateway did not complete the connection test within 30 seconds. Check its URL, model and availability, then retry."
        case .failed(let message): message
        }
    }
}

extension WorkspaceModel {
    /// Uses the packaged helper's normal provider/capture transport, but never
    /// opens a chat, loads repository resources, or launches configured tools.
    /// Requests remain attributable to the real workspace in the request report.
    func verifyOnboardingConnection(_ profile: ProfileRecord) async throws {
        try await ensureConfiguration()
        guard store != nil, profileChoice == profile.id,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID && $0.trusted }),
              !workspaceChangesInFlight.contains(workspace.id) else {
            throw ConnectionProbeError.failed("Choose a trusted project and a saved connection before testing.")
        }
        let credential = try await credentials(for: profile)
        let headers = credential["headers"]?.object?.compactMapValues(\.string) ?? [:]
        try LiteLLMConfiguration.validateForRequests(profile, headers: headers)
        guard let key = credential["apiKey"]?.string, GatewayModelDiscovery.validKey(key) else {
            throw ConnectionProbeError.failed("Save a valid API key for this gateway before testing.")
        }
        let sessionID = "connection-test-" + UUID().uuidString
        let directory = root.appendingPathComponent("ConnectionTests/" + sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let host = HostSupervisor(), archive = traces, runtime = configuration.runtime
        let mode = configuration.capture.defaultMode
        let deadline = Date().addingTimeInterval(30)
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            host.shutdown()
        }
        defer { timeout.cancel() }
        func unchanged() async throws {
            let latest: [String: WireValue]
            do { latest = try await credentials(for: profile) } catch { throw ConnectionProbeError.changed }
            guard profileChoice == profile.id, selectedWorkspaceID == workspace.id,
                  workspaces.contains(workspace), !workspaceChangesInFlight.contains(workspace.id),
                  latest == credential else { throw ConnectionProbeError.changed }
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await host.connect(cwd: directory, state: directory.appendingPathComponent("Host"), runtime: runtime,
                                       capture: { try await archive.accept($0, workspace: workspace.id) })
                try Task.checkCancellation()
                _ = try await host.request("workspace.open", params: [
                    "cwd": .string(directory.path), "directory": .string(directory.appendingPathComponent("Sessions").path),
                    "captureProtocol": .number(1), "mcp": .object(["servers": .object([:])])])
                _ = try await host.request("debug.mode", sessionID: sessionID, params: ["mode": .string(mode)])
                try await unchanged()
                try Task.checkCancellation()
                var wire = profile.wire.object ?? [:]
                wire["headers"] = credential["headers"]
                let result = try await host.request("connection.test", sessionID: sessionID,
                    params: ["profile": .object(wire), "apiKey": .string(key)])
                try Task.checkCancellation()
                guard result.object?["verified"] == .bool(true), result.object?["model"] == .string(profile.modelId) else {
                    throw ConnectionProbeError.failed("The gateway did not confirm the selected model. Review the connection and test again.")
                }
                try await unchanged()
                guard Date() < deadline else { throw ConnectionProbeError.timedOut }
            } onCancel: { Task { @MainActor in host.shutdown() } }
            // A separate task also waits when the caller is cancelled, so cleanup
            // cannot remove the helper's working directory while it is alive.
            try await Task { @MainActor in try await host.shutdownAndWait() }.value
            try? FileManager.default.removeItem(at: directory)
            await refreshRetainedAccounting()
            // Cleanup and archive refresh suspend. Recheck after them so a
            // connection/workspace edit cannot reuse this successful probe.
            try await unchanged()
        } catch {
            if (try? await Task { @MainActor in try await host.shutdownAndWait() }.value) != nil {
                try? FileManager.default.removeItem(at: directory)
            }
            await refreshRetainedAccounting()
            if Task.isCancelled || error is CancellationError { throw ConnectionProbeError.cancelled }
            if Date() >= deadline { throw ConnectionProbeError.timedOut }
            if let known = error as? ConnectionProbeError { throw known }
            if case HostError.rejected(let code, let message) = error, code.hasPrefix("connection_test_") {
                throw ConnectionProbeError.failed(message)
            }
            throw ConnectionProbeError.failed("Couldn't test this connection. Check the saved gateway URL, API key and model, then retry. Details are available in Requests.")
        }
    }
}

extension WorkspaceModel {
    /// Sends one small request in a saved test chat. Settings confirms in its own
    /// footer and passes `confirmed`; other callers get the system prompt.
    func testConnection(profileID: String, confirmed: Bool = false) {
        guard requestProfiles.contains(where: { $0.id == profileID }) else { error = LiteLLMConfiguration.unsupportedAPIMessage; return }
        if confirmed {
            Task { do {
                let item = try await createConnectionTestChat(profileID: profileID)
                submitConnectionTestChat(item.id)
            } catch { self.error = error.localizedDescription } }
            return
        }
        let question = ChatQuestion(title: "Test this profile's connection?",
                                    detail: "Send a real API request to the configured LiteLLM gateway. Its upstream provider may charge for it. The test runs in a saved chat with tools disabled, outside any project, so you can inspect it later.",
                                    action: "Send Test Request")
        if !questions.ask(question, answered: { [weak self] send in
            guard let self, send else { return }
            Task { do {
                let item = try await self.createConnectionTestChat(profileID: profileID)
                self.submitConnectionTestChat(item.id)
            } catch { self.error = error.localizedDescription } }
        }) { error = PiQuestion.busyNotice }
    }
    /// Selection can change while the saved test chat loads. Its submission
    /// always belongs to that chat, never to the newly selected conversation.
    func submitConnectionTestChat(_ id: String) {
        guard let view = displays[id], record(id)?.connectionTest == true else { return }
        view.draft = "Reply with OK to confirm this API connection."
        send(sessionID: id)
    }
    /// Connection tests need no project: the chat is saved under the scratch
    /// workspace so its request and reply stay inspectable in the sidebar and report.
    @discardableResult
    func createConnectionTestChat(profileID: String) async throws -> ChatRecord {
        guard requestProfiles.contains(where: { $0.id == profileID }) else { throw HostError.failure(LiteLLMConfiguration.unsupportedAPIMessage) }
        guard let store else { throw HostError.failure("Desktop storage is unavailable. Resolve the storage error before testing a connection.") }
        let item = ChatRecord(id: UUID().uuidString, workspaceID: WorkspaceRecord.scratchID, title: "Connection test", path: nil, profileID: profileID, toolMode: "read-only", connectionTest: true)
        try await store.put(item, kind: "chat", id: item.id); chats.insert(item, at: 0)
        page = .chats
        await select(item.id)
        return item
    }
}
