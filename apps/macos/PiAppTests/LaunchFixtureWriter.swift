import XCTest
@testable import PiApp

/// Opt-in, not part of any gate: writes the synthetic state that
/// `scripts/perf-launch.sh` launches a `PI_LAUNCH_FIXTURE` build over, with the
/// app's own record types. `PI_APP_LAUNCH_FIXTURE=<folder>` gets:
///
///   home/Library/Application Support/com.belloware.PiApp/   the app's state
///   projects/alpha, projects/beta                          two projects
///   vault.json                                             the configuration
///
/// 60 chats in two projects; the one reopened at launch has 200 turns of
/// Markdown; five are unread, one marked unread, two paused, three hold a
/// draft. The only connection is a loopback port nothing listens on.
final class LaunchFixtureWriter: XCTestCase {
    @MainActor func testWriteLaunchFixture() async throws {
        guard let path = testEnvironment("PI_APP_LAUNCH_FIXTURE") else { throw XCTSkip("Set PI_APP_LAUNCH_FIXTURE to write the launch fixture") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { return XCTFail("\(root.path) exists; the fixture is written to a new folder") }
        let state = root.appendingPathComponent("home/Library/Application Support/com.belloware.PiApp", isDirectory: true)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)

        var profile = ProfileRecord()
        profile.id = "launch-profile"; profile.name = "Launch fixture"; profile.baseUrl = "http://127.0.0.1:9"; profile.modelId = "fixture-model"
        let projects = ["alpha", "beta"].map { name -> WorkspaceRecord in
            let folder = root.appendingPathComponent("projects/" + name, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("Synthetic project \(name).\n".utf8).write(to: folder.appendingPathComponent("README.md"))
            return WorkspaceRecord(id: "project-" + name, path: folder.path, trusted: true)
        }
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only")]
        configuration.workspaces = projects
        configuration.automaticUpdateChecks = false
        configuration.completionSoundEnabled = false
        try configuration.validate()
        try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("vault.json"))

        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        try await store.open()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        var chats: [ChatRecord] = []
        for (p, project) in projects.enumerated() {
            let sessions = state.appendingPathComponent("Workspaces/\(project.id)/Sessions", isDirectory: true)
            try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
            for n in 0..<30 {
                let id = "chat-\(p)-\(String(format: "%02d", n))"
                let journal = sessions.appendingPathComponent(id + ".jsonl")
                let turns = (p == 0 && n == 0) ? 200 : 3 + n % 5
                try Self.journal(id: id, cwd: project.path, turns: turns).write(to: journal)
                var chat = ChatRecord(id: id, workspaceID: project.id, title: "Fixture chat \(p + 1)·\(n + 1) about topic \(n % 7)", path: journal.path, profileID: profile.id)
                chat.lastActivityAt = now - Int64(p * 30 + n) * 60_000_000
                chat.sidebarOrder = chat.lastActivityAt
                if n == 3 { chat.pinnedAt = Date(timeIntervalSince1970: 1_790_000_000) }
                chats.append(chat)
            }
        }
        try await store.putChats(chats)
        for (index, chat) in chats.enumerated() where [2, 5, 9, 31, 40].contains(index) {
            try await store.put(SessionReadState(id: chat.id, observedAssistantCount: 2, unreadOutputs: 1), kind: "session-read", id: chat.id)
        }
        try await store.put(SessionReadState(id: chats[12].id, observedAssistantCount: 4, markedUnread: true), kind: "session-read", id: chats[12].id)
        for chat in [chats[6], chats[35]] {
            try await store.put(RunHoldRecord(id: chat.id, state: RunState.paused.rawValue), kind: RunHoldRecord.kind, id: chat.id)
        }
        try await store.put(Int64(1), kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)
        for chat in [chats[1], chats[8], chats[44]] {
            try await store.put(DraftRecord(id: chat.id, text: "An unsent thought about \(chat.title)", attachments: nil, skills: nil), kind: "draft", id: chat.id)
        }
        try await store.put(RememberedSelection(chatID: chats[0].id, projectID: projects[0].id), kind: RememberedSelection.recordKind, id: RememberedSelection.recordID)
    }

    /// A pi session journal: a header, then user and assistant messages.
    private static func journal(id: String, cwd: String, turns: Int) throws -> Data {
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": id, "timestamp": "2026-10-01T00:00:00.000Z", "cwd": cwd]]
        var parent: String?
        for turn in 0..<turns {
            for role in ["user", "assistant"] {
                let entry = "e\(lines.count)"
                let text = role == "user" ? "Question \(turn): how does part \(turn) of the fixture work?"
                    : "## Part \(turn)\n\nA synthetic answer with **bold**, `code` and a list:\n\n- first point about \(turn)\n- second point\n- third point\n\n```swift\nlet value = \(turn)\nprint(value * 2)\n```\n\n" + String(repeating: "A retained paragraph of fixture prose that wraps across the transcript's width. ", count: 6)
                var message: [String: Any] = ["role": role, "timestamp": 1_790_000_000_000 + turn, "content": [["type": "text", "text": text]]]
                if role == "assistant" {
                    message["api"] = "openai-responses"; message["provider"] = "litellm"; message["model"] = "fixture-model"; message["stopReason"] = "stop"
                    message["usage"] = ["input": 100, "output": 40, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 140,
                                        "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
                }
                var line: [String: Any] = ["type": "message", "id": entry, "timestamp": "2026-10-01T00:00:00.000Z", "message": message]
                line["parentId"] = parent ?? NSNull()
                parent = entry
                lines.append(line)
            }
        }
        var data = Data()
        for line in lines { data += try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]); data += Data("\n".utf8) }
        return data
    }
}
