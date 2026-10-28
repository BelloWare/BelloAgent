import Foundation

enum MailboxCutPresentation {
    static func marker(_ row: TranscriptMessage) -> String? {
        guard row.mailboxCutin == true, row.nativeMailboxCut?.object?["version"]?.number == 1 else { return nil }
        return "Reply cut for agent message"
    }
    static func cancelled(_ tool: ToolView) -> String? {
        guard tool.mailboxCutin, let metadata = tool.nativeAgentCallCancellation?.object,
              metadata["version"]?.number == 1, metadata["reason"]?.string == "agent_message" else { return nil }
        return "Not run · agent message arrived"
    }
}
