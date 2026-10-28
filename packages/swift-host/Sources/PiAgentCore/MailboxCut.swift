import Foundation

/// A committed prefix, never a terminal response or a recoverable transport
/// failure. Its attempt remains live until the HTTP reader settles it.
public struct MailboxCut: Codable, Sendable, Equatable {
    public var version = 1
    public let cutId: String, attemptId: String, responseId: String, itemId: String
}

/// Completion evidence is separate from the accumulator's display deltas and
/// partially assembled calls. A gap or conflicting duplicate closes this path.
struct MailboxCutPrefix {
    var completed: [Int:JSON] = [:]
    var opened: Set<Int> = []
    var responseID: String?
    var invalid = false
    var terminal = false

    mutating func consume(_ event: JSON) -> [JSON]? {
        let type = event["type"].text ?? ""
        if ["response.created", "response.in_progress"].contains(type), let id = event["response"]["id"].text {
            if let responseID, responseID != id { invalid = true }
            responseID = id
        }
        if ["response.completed", "response.incomplete", "response.failed", "error"].contains(type) { terminal = true }
        guard !terminal, !invalid, let index = event["output_index"].int, index >= 0, index < 65536 else { return nil }
        if type == "response.output_item.added" {
            if completed[index] != nil || !opened.insert(index).inserted { invalid = true }
            return nil
        }
        guard type == "response.output_item.done" else { return nil }
        let item = event["item"]
        if let prior = completed[index] { if prior != item { invalid = true }; return nil }
        completed[index] = item; opened.remove(index)
        let end = completed.keys.max() ?? index
        guard Self.eligible(item), !invalid, responseID?.isEmpty == false,
              (0...end).allSatisfy({ completed[$0] != nil && !opened.contains($0) }) else { return nil }
        let items = (0...end).compactMap { completed[$0] }
        guard items.allSatisfy(Self.replayable), Set(items.compactMap { $0["id"].text }).count == items.count else { return nil }
        let calls = items.filter { $0["type"].text == "function_call" }.compactMap { $0["call_id"].text }
        guard Set(calls).count == calls.count else { return nil }
        return items
    }
    static func eligible(_ item: JSON) -> Bool {
        item["type"].text == "reasoning" || item["type"].text == "message" && item["role"].text == "assistant" && ["commentary", "partial_answer"].contains(item["phase"].text ?? "")
    }
    static func replayable(_ item: JSON) -> Bool {
        guard item["id"].text?.isEmpty == false, item["status"].isNull || item["status"].text == "completed" else { return false }
        switch item["type"].text {
        case "reasoning": return item["encrypted_content"].text?.isEmpty == false
        case "message":
            guard case .array = item["content"] else { return false }
            return item["role"].text == "assistant" && ["commentary", "partial_answer"].contains(item["phase"].text ?? "") && item["content"].list.allSatisfy { $0["type"].text == "output_text" && $0["text"].text != nil }
        case "function_call": return item["call_id"].text?.isEmpty == false && item["name"].text?.isEmpty == false && item["arguments"].text.flatMap { try? JSON.parse(Data($0.utf8)) }?.isObject == true
        default: return false
        }
    }
}

extension ProviderClient {
    /// RoutingContract records no upstream provider. This deliberately small
    /// name rule is documented in §11.1, not inferred from a route alias.
    static func mailboxCutRoute(profile: Profile, identity: JSON, body: JSON) -> Bool {
        func model(_ name: String) -> String { name.hasPrefix("openai/") ? String(name.dropFirst(7)) : name }
        guard profile.api == "openai-responses", profile.routing.policy == "pinned",
              let expected = profile.routing.raw["expectedModel"].text,
              identity["status"].text == "reported", identity["effectiveModel"].text.map(model) == model(expected),
              profile.raw["revision"].text?.isEmpty == false,
              body["model"].text == profile.model, body["stream"].flag == true, body["store"].flag == false else { return false }
        var probe = ChatMessage(role:"assistant",content:[])
        probe.providerItems = [["type":"reasoning"]]
        probe.providerIdentity = identity; probe.providerBinding = try? replayBinding(profile)
        guard (try? replayItems(probe,profile:profile)) != nil else { return false }
        let name = model(expected)
        guard ["gpt-4o", "gpt-4.1", "o1", "o3", "o4"].contains(where: { name == $0 || name.hasPrefix($0 + "-") }) || name.range(of:"^gpt-[56](\\.[0-9]+)?(-[a-zA-Z0-9.-]+)?$",options:.regularExpression) != nil else { return false }
        // Generic options must not replace the history or its execution mode.
        return Set(profile.raw["samplingParams"].map.keys).isDisjoint(with:["input", "model", "stream", "store", "previous_response_id", "conversation", "context_management", "truncation", "background"])
    }
}

/// The caller gets either the terminal reply or a committed cut, once. The
/// unstructured reader survives an early return; cancelling the waiting caller
/// still cancels it. A family RequestPermit controls it after that return.
final class MailboxReplyDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ModelReply,Error>?
    private var result: Result<ModelReply,Error>?
    private var task: Task<Void,Never>?
    private var cancelled = false
    func install(_ task: Task<Void,Never>) {
        lock.lock(); self.task = task; let cancelled = cancelled; lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func resolve(_ value: Result<ModelReply,Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiting = continuation; continuation = nil; lock.unlock()
        waiting?.resume(with:value)
    }
    func wait() async throws -> ModelReply {
        try await withCheckedThrowingContinuation { waiting in
            lock.lock()
            if let result { lock.unlock(); waiting.resume(with:result) }
            else { continuation = waiting; lock.unlock() }
        }
    }
    func finished() { lock.lock(); task = nil; lock.unlock() }
}
