import Foundation

// Chats written before 0.1.111 hold a copy of their 128 command receipts in
// every run-state record, several a turn: in a long chat most of the file.
// Once after launch, while nothing else is going on, each such chat's helper
// writes its journal again without the copies nothing reads
// (`JournalSlimming` in the helper), checks that the chat replays exactly as
// before, and moves the original to the Trash. Nothing on screen changes.

/// What slimming a chat's journal came to, kept so it is asked once.
struct JournalSlimMark: Codable, Sendable, Equatable {
    static let kind = "journal-slim"
    var chatID: String
    var slimmed: Bool
    /// Why it was left as it was, from the helper; nil when it was slimmed.
    var reason: String?
    var bytesBefore: Double = 0, bytesAfter: Double = 0
}

extension WorkspaceModel {
    /// A journal smaller than this is not asked about: there is little to gain.
    static let slimmingThreshold: UInt64 = 2 << 20
    /// How long after launch the pass starts.
    static let slimmingDelay: Duration = .seconds(20)

    /// Starts the pass, once per launch.
    func scheduleJournalSlimming(after delay: Duration = WorkspaceModel.slimmingDelay) {
        guard journalSlimming == nil, store != nil else { return }
        journalSlimming = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.slimJournals()
        }
    }

    /// The chats worth asking about, largest first: saved native chats, not
    /// imported and not background tasks, big enough, and not asked before.
    func slimmingCandidates(marked: Set<String>) -> [(chat: ChatRecord, bytes: UInt64)] {
        chats.compactMap { chat -> (chat: ChatRecord, bytes: UInt64)? in
            guard !chat.imported, !chat.isBackgroundTask, !marked.contains(chat.id), let path = chat.path,
                  let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value,
                  size >= Self.slimmingThreshold else { return nil }
            return (chat, size)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Each candidate in turn, while the reader is doing nothing and the chat
    /// is not open. A chat that is open, or locked by another writer, is left
    /// for the next launch; any other outcome is recorded.
    func slimJournals(waitForQuiet: Bool = true) async {
        guard let store else { return }
        let marked = Set(((try? await store.list(JournalSlimMark.self, kind: JournalSlimMark.kind)) ?? []).map(\.chatID))
        var touched: [String: HostSupervisor] = [:]
        defer { for (workspaceID, host) in touched { scheduleIdle(workspaceID: workspaceID, host: host) } }
        for (candidate, _) in slimmingCandidates(marked: marked) {
            if waitForQuiet {
                while !Task.isCancelled, !accountingStopped, !installPreparing,
                      launching || hasActiveWork || TranscriptIdleScheduler.shared.remainingInputQuietTime > 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            guard !Task.isCancelled, !accountingStopped, !installPreparing else { return }
            // Whatever the reader has open, or may open any moment, waits.
            guard let chat = record(candidate.id), let path = chat.path, !opened.contains(chat.id), !isSessionOpening(chat.id),
                  chat.id != selectedID, sides[selectedID ?? ""]?.id != chat.id, displays[chat.id]?.hasWork != true,
                  let workspace = workspace(for: chat.workspaceID) else { continue }
            let result: [String: WireValue]
            do {
                let host = try await host(for: workspace)
                touched[workspace.id] = host
                result = try await host.request("journal.slim", params: ["sessionId": .string(chat.id), "path": .string(path)]).object ?? [:]
            } catch is CancellationError { return }
            catch HostError.rejected(let code, _) where !["quiesced", "workspace_required", "host_busy"].contains(code) {
                // The helper refused this journal (a damaged one, say): it is
                // not asked again.
                try? await store.put(JournalSlimMark(chatID: chat.id, slimmed: false, reason: "refused:" + code), kind: JournalSlimMark.kind, id: chat.id)
                continue
            } catch {
                // A helper that could not start or answer: next launch.
                continue
            }
            let reason = result["reason"]?.string
            if ["session-open", "locked"].contains(reason ?? "") { continue }
            let mark = JournalSlimMark(chatID: chat.id, slimmed: result["slimmed"]?.bool == true, reason: reason,
                                       bytesBefore: result["bytesBefore"]?.number ?? 0, bytesAfter: result["bytesAfter"]?.number ?? 0)
            try? await store.put(mark, kind: JournalSlimMark.kind, id: chat.id)
        }
    }
}
