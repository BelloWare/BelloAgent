import Foundation

/// Helper opening has its own state. The transcript's page/fill ownership is
/// independent, and selecting another chat never cancels this shared work.
enum SessionOpeningState: Equatable {
    case opening(HostCommandProgress?), cancelling(HostCommandProgress?), cancelled, failed(String)
    var active: Bool { switch self { case .opening, .cancelling: true; default: false } }
    var progress: HostCommandProgress? { switch self { case .opening(let p), .cancelling(let p): p; default: nil } }
    var cancelling: Bool { if case .cancelling = self { true } else { false } }
}

extension WorkspaceModel {
    func cancelSessionOpening(_ id: String) {
        guard let opening = sessionOpenings[id], case .opening(let progress) = displays[id]?.helperOpening else { return }
        displays[id]?.helperOpening = .cancelling(progress)
        opening.task.cancel()
    }

    func observeOpening(_ progress: HostCommandProgress, id: String, token: UUID) {
        guard sessionOpenings[id]?.token == token, case .opening = displays[id]?.helperOpening else { return }
        displays[id]?.helperOpening = .opening(progress)
    }

    /// The shared operation owns cancellation; the callers merely await it.
    /// A cancelled send can restore its draft immediately. Cleanup has a
    /// separate fence, so another action cannot adopt a late success before it closes.
    func trackSessionOpening(_ id: String, token: UUID, commandID: String, host: HostSupervisor, connection: UUID?,
                             body: () async throws -> Void) async throws {
        do {
            try await body()
            try Task.checkCancellation()
            if sessionOpenings[id]?.token == token { displays[id]?.helperOpening = nil }
        } catch {
            if Task.isCancelled || error is CancellationError {
                let userCancelled = displays[id]?.helperOpening?.cancelling == true
                settleCancelledOpening(id, commandID: commandID, host: host, connection: connection, userCancelled: userCancelled)
                if userCancelled { throw HostError.rejected("open_cancelled", "Opening cancelled. Your message was not sent.") }
                throw error
            }
            if sessionOpenings[id]?.token == token { displays[id]?.helperOpening = .failed(error.localizedDescription) }
            throw error
        }
    }

    private func settleCancelledOpening(_ id: String, commandID: String, host: HostSupervisor, connection: UUID?, userCancelled: Bool) {
        let token = UUID()
        opened.remove(id)
        let cleanup = Task { [self] in
            // The helper's reply comes after the worker unwinds. A legacy
            // helper may instead succeed: close that unadopted runtime too.
            await host.waitForCommandSettlement(commandID)
            if host.isReady, host.connectionID == connection {
                _ = try? await host.request("session.close", sessionID: id,
                    params: host.supportsOpenCancellation ? ["openingCommandId":.string(commandID)] : [:])
            }
            guard sessionClosings[id]?.token == token else { return }
            sessionClosings.removeValue(forKey: id)
            helperSessionDidUnload(id)
            displays[id]?.helperOpening = userCancelled ? .cancelled : nil
        }
        sessionClosings[id] = (token, cleanup)
    }

}
