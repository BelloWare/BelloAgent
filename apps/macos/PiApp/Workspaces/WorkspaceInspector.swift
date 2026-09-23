import Foundation

// The one way anything in the app opens the Session Inspector: the turn
// report's info button, a reply's Details, the pills, the capture badge, the
// report's rows and the menu command all come here.

extension WorkspaceModel {
    /// Opens a chat's Session Inspector at a page, or brings it forward there.
    func openInspector(session sessionID: String, focus: InspectorFocus = .overview) {
        guard let record = record(sessionID) else {
            error = "That chat is no longer available. It was deleted or was an unkept side conversation; its retained requests remain in the usage report."
            return
        }
        openInspector(session: sessionID, workspaceID: record.workspaceID, title: record.title, focus: focus)
    }

    /// A request from the usage report: its chat may be gone, its project and log are not.
    func openInspector(session sessionID: String, workspaceID: String, title: String?, focus: InspectorFocus) {
        lastInspectorFocus = focus
        SessionInspectorWindows.shared.show(model: self, sessionID: sessionID, workspaceID: workspaceID,
                                            title: title ?? record(sessionID)?.title ?? "Deleted chat", focus: focus)
    }

    /// The focus of a turn the transcript reports: the message that started it.
    static func inspectorFocus(for turn: TurnSummary) -> InspectorFocus {
        if let id = turn.requests.compactMap(\.turn).first ?? turn.taskRootID { return .turn(id) }
        if let reply = turn.requests.last { return .message(reply.id) }
        return .latestRequest
    }
}
