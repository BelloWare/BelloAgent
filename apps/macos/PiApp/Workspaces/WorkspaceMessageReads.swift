import Foundation

// Reads of one message's content from the helper, each bounded so a reply
// nobody can display cannot be pulled into memory whole.

extension WorkspaceModel {
    /// The complete text of a queued submission. Status snapshots carry only a
    /// preview of a long one, so rewriting it in place has to ask the helper
    /// for the rest; saving the preview back would throw away everything past
    /// the first kilobyte.
    func queuedMessageText(turnID: String, sessionID: String) async throws -> String {
        if let queueReadOperation { return try Self.queuedText(in: await queueReadOperation(sessionID, turnID)) }
        guard let item = record(sessionID), let host = hosts[item.workspaceID], opened.contains(sessionID) else {
            throw HostError.failure("The complete message is only available while this chat's helper is running.")
        }
        let result = try await host.request("queue.read", sessionID: sessionID, params: ["turnId": .string(turnID)]).object ?? [:]
        return try Self.queuedText(in: result)
    }
    private static func queuedText(in result: [String: WireValue]) throws -> String {
        guard let text = result["text"]?.string, text.utf8.count <= 262_144 else {
            throw HostError.failure("The queued message could not be read in full.")
        }
        return text
    }
    func messagePage(id: String, field: String, offset: Int, sessionID: String? = nil) async throws -> (String, Int) {
        guard let target = sessionID ?? selectedID, let item = record(target) else { throw HostError.failure("Only retained completed messages can be opened") }
        if let host = hosts[item.workspaceID], opened.contains(item.id) {
            let value = try await host.request("session.message.read", sessionID: item.id, params: ["messageId": .string(id), "field": .string(field), "offset": .number(Double(offset))]).object ?? [:]
            return (value["text"]?.string ?? "", Int(value["totalCharacters"]?.number ?? 0))
        }
        guard let path = item.path else { throw HostError.failure("This session has no retained file") }
        return try await history.message(path: path, id: id, field: field, offset: offset)
    }
    /// One tool call's arguments, bounded for that tool rather than for a
    /// display snapshot. Read-only, and only for a session the host has open;
    /// history read from disk keeps the document its journal carried.
    func toolInput(sessionID: String, messageID: String, callID: String) async throws -> ToolInputDocument {
        guard let item = record(sessionID), let host = hosts[item.workspaceID], opened.contains(item.id) else {
            throw HostError.failure("This conversation has no live host to read the call's arguments from")
        }
        let value = try await host.request("session.tool.input", sessionID: sessionID,
                                           params: ["messageId": .string(messageID), "callId": .string(callID)]).object ?? [:]
        guard let input = value["input"]?.string else { throw HostError.failure("The call's arguments are unavailable") }
        return ToolInputDocument(input: input, truncated: value["inputTruncated"]?.bool ?? false,
                                 bytes: Int(value["inputBytes"]?.number ?? Double(input.utf8.count)),
                                 streaming: value["streaming"]?.bool ?? false)
    }
    func debugRequest(_ method: String, sessionID: String, params: [String: WireValue] = [:]) async throws -> [String: WireValue] {
        guard let item = record(sessionID), let host = hosts[item.workspaceID], host.isReady else { throw HostError.failure("No live capture for this session. Imported and unloaded history has no retroactive HTTP trace.") }
        return try await host.request(method, sessionID: sessionID, params: params).object ?? [:]
    }
}
