import AppKit
import Network
import XCTest
@testable import PiApp

@MainActor struct AskFixture {
    let model: WorkspaceModel
    let gateway: AskGateway
    let other: AskGateway?
    let root: URL

    static func make(_ test: XCTestCase, second: Bool = false, mini: String? = "mini-fixture", unavailable: Bool = false, catalog: ModelCatalog? = nil) async throws -> AskFixture {
        let root = scratchRoot("sidebar-ask"), project = root.appendingPathComponent("Orchard")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let gateway = try AskGateway(); test.addTeardownBlock { gateway.stop() }
        var profile = ProfileRecord(); profile.id = "profile"; profile.name = "Studio"; profile.baseUrl = try await gateway.start()
        profile.modelId = "conversation-model"; profile.miniModelId = mini
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-ask-key")]
        var other: AskGateway?
        if second {
            let extra = try AskGateway(); test.addTeardownBlock { extra.stop() }
            var next = profile; next.id = "other"; next.name = "Research"; next.baseUrl = try await extra.start()
            next.miniModelId = "other-mini-fixture"
            configuration.profiles.append(VaultProfile(profile: next, apiKey: "synthetic-other-key")); other = extra
        }
        if unavailable {
            var offline = profile; offline.id = "no-mini"; offline.name = "Personal"; offline.miniModelId = nil
            configuration.profiles.append(VaultProfile(profile: offline, apiKey: "synthetic-no-mini-key"))
        }
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))), modelCatalog: catalog)
        test.registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        if unavailable, let profile = model.profiles.first(where: { $0.id == "no-mini" }) { _ = await model.listModels(for: profile) }
        return AskFixture(model: model, gateway: gateway, other: other, root: root)
    }
    @discardableResult func chat(_ id: String, title: String, brief: String? = nil, profile: String = "profile", parent: String? = nil, archived: Bool = false,
                                user: String? = nil, reply: String? = nil) async throws -> ChatRecord {
        let journal = try SearchJournal(root.appendingPathComponent(id + ".jsonl"), id: id)
        let subject = brief ?? "The tokenizer retry checklist for \(title)."
        try journal.message(id + "-u", role: "user", user ?? "Conversation about \(title).")
        try journal.message(id + "-a", role: "assistant", reply ?? "\(title): \(subject)")
        var chat = ChatRecord(id: id, workspaceID: "project", title: title, path: journal.url.path, profileID: profile, parentSessionID: parent)
        chat.sidebarOrder = Int64(model.chats.count + 1)
        if let brief { chat.brief = ChatBrief(text: brief, keywords: ["tokenizer", "retry"], through: id + "-a", at: Date(), activity: chat.activityStamp) }
        if archived { chat.archivedAt = Date() }
        try await model.store?.put(chat, kind: "chat", id: id); model.chats.append(chat)
        return chat
    }
}

/// A loopback Responses fixture: fixed ranking, explicit failures and held
/// replies. Every request is observed independently of the app's parsing.
final class AskGateway: @unchecked Sendable {
    typealias Request = BriefGateway.Request
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.AskGatewayFixture")
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private var held: [NWConnection] = []
    private var holding = false
    private var answerText = #"{"matches":[{"id":"b","reason":"Tracks the parser retry migration."},{"id":"unknown","reason":"Invented chat"},{"id":"a","reason":"Contains the tokenizer checklist."}]}"#
    private var failing = false
    var requests: [Request] { lock.withLock { captured } }
    func reply(_ text: String) { lock.withLock { answerText = text } }
    func fail(_ value: Bool) { lock.withLock { failing = value } }
    func hold(_ value: Bool) {
        let release = lock.withLock { () -> [NWConnection] in
            holding = value
            guard !value else { return [] }
            defer { held = [] }; return held
        }
        release.forEach(answer)
    }
    init() throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue); self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard error == nil, bytes.count <= 1 << 20 else { connection.cancel(); return }
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)), let head = String(data: bytes[..<split.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { self.receive(connection, previous: bytes) }; return
            }
            guard head.hasPrefix("POST /v1/responses") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
            }
            let length = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= split.upperBound + length else {
                if complete { connection.cancel() } else { self.receive(connection, previous: bytes) }; return
            }
            let payload = Data(bytes[split.upperBound..<(split.upperBound + length)])
            let body = (try? JSONDecoder().decode([String: WireValue].self, from: payload)) ?? [:]
            let hold = self.lock.withLock {
                self.captured.append(Request(head: head, raw: String(decoding: payload, as: UTF8.self), body: body))
                if self.holding { self.held.append(connection) }; return self.holding
            }
            if !hold { self.answer(connection) }
        }
    }
    private func answer(_ connection: NWConnection) {
        let (text, failure) = lock.withLock { (answerText, failing) }
        let response: [String: Any] = failure ? ["error": ["message": "Fixture Ask failure", "type": "invalid_request_error"]] : [
            "id": "resp_ask", "object": "response", "status": "completed", "model": "resolved-mini-fixture",
            "output": [["id": "msg_ask", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 120, "output_tokens": 80, "total_tokens": 200]]
        let encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        let reply = Data("HTTP/1.1 \(failure ? "400 Bad Request" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(encoded.count)\r\nx-litellm-response-cost: 0.004\r\nConnection: close\r\n\r\n".utf8) + encoded
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }
}
