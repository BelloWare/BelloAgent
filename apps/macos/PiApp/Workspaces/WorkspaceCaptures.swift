import Foundation

// What the app keeps of a chat's HTTP traffic, per chat: the mode, the
// preference behind it, and exporting or clearing what was kept.

extension WorkspaceModel {
    func capturePreference(sessionID: String) async throws -> CapturePreference {
        if isEphemeral(sessionID) { return CapturePreference(mode: displays[sessionID]?.captureMode ?? "memory", since: "") }
        try await ensureConfiguration()
        let owner = record(sessionID)?.delegation?.budgetOwnerSessionID ?? sessionID
        guard owner == sessionID || record(owner)?.workspaceID == record(sessionID)?.workspaceID else { throw StoreError.invalidRecord }
        return CapturePreference(mode: configuration.capture.sessionModes[owner] ?? configuration.capture.defaultMode,
                                 since: configuration.capture.sessionSince[owner] ?? "")
    }
    func removeDeletedCapturePreference(sessionID: String) async throws {
        // Do not reset a retained chat's explicit opt-out if another part of
        // deletion fails. Its vault entries are removed only after the chat is.
        guard record(sessionID) == nil else { throw StoreError.invalidRecord }
        try await ensureConfiguration()
        guard configuration.capture.sessionModes[sessionID] != nil || configuration.capture.sessionSince[sessionID] != nil else { return }
        try await updateConfiguration {
            $0.capture.sessionModes.removeValue(forKey: sessionID)
            $0.capture.sessionSince.removeValue(forKey: sessionID)
        }
    }
    func setCaptureMode(_ mode: String, sessionID: String) async throws {
        guard record(sessionID)?.delegation == nil else { throw HostError.failure("Sub-agent capture follows its parent.") }
        if isEphemeral(sessionID) {
            guard mode != "persist" else { throw HostError.failure("Keep the side as a separate chat before enabling persistent capture.") }
            _ = try await debugRequest("debug.mode", sessionID: sessionID, params: ["mode": .string(mode)]); displays[sessionID]?.captureMode = mode; return
        }
        let preference = CapturePreference(mode: mode, since: { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format.string(from: Date()) }())
        try await updateConfiguration { $0.capture.sessionModes[sessionID] = preference.mode; $0.capture.sessionSince[sessionID] = preference.since }
        if let item = chats.first(where: { $0.id == sessionID }), hosts[item.workspaceID]?.isReady == true { _ = try await debugRequest("debug.mode", sessionID: sessionID, params: ["mode": .string(mode)]) }
        displays[sessionID]?.captureMode = mode
    }
    func clearCaptures(sessionID: String) async throws {
        guard displays[sessionID]?.hasWork != true else { throw HostError.failure("Stop active work before clearing capture bodies.") }
        if let item = record(sessionID), let host = hosts[item.workspaceID] {
            if host.isReady { _ = try await debugRequest("debug.clear", sessionID: sessionID) }
            else { try await host.settleCaptureIfStopping() }
        }
        let previous = try await capturePreference(sessionID: sessionID)
        if previous.mode == "persist", record(sessionID)?.delegation == nil { try await setCaptureMode("persist", sessionID: sessionID) }
        try removeRetiredCaptureSpools(sessionID: sessionID)
        try await traces.clear(sessionID: sessionID)
    }
    /// The removed, unreleased capture spool is never a recovery source.
    /// Also retire it when clearing/deleting with this project's helper stopped.
    func removeRetiredCaptureSpools(sessionID: String) throws {
        guard let item = record(sessionID) else { return }
        let retired = root.appendingPathComponent("Workspaces").appendingPathComponent(item.workspaceID)
            .appendingPathComponent("Sessions/.capture-outbox")
        if FileManager.default.fileExists(atPath: retired.path) { try FileManager.default.removeItem(at: retired) }
    }
    func persistAttempt(sessionID: String, attemptID: String, destination: URL) async throws -> URL {
        let metadata = try await debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
        guard metadata["outcome"]?.string != "running" else { throw HostError.failure("Wait for this HTTP attempt to finish, or Stop it before exporting retained bytes") }
        return try await liveExporter.persist(metadata, destination: destination, read: { [weak self] body, offset in
            guard let self else { throw TraceError.invalid }
            return try await self.debugRequest("debug.body", sessionID: sessionID, params: ["attemptId": .string(attemptID), "body": .string(body), "offset": .number(Double(offset))])
        }, verify: { [weak self] in
            guard let self else { throw TraceError.invalid }
            return try await self.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
        })
    }
}
