import Foundation

// Paused after a restart: which chats wait for Resume, known before any of
// them is opened.
//
// A chat's journal is the truth: its newest run-state record says whether a
// run was cut off or stopped, and what waits behind it, and the helper
// restores exactly that, paused, when the chat is next used. Reading every
// journal at launch to draw the sidebar is too dear, so the app keeps a small
// record per waiting chat (`RunHoldRecord`), written as its runs change. At
// launch the rows show these at once; the journals of the chats they name are
// then read from their ends (`JournalRunHold`) and correct them. A chat
// paused by an older build has no record: the first launch of this one reads
// every journal's end once, off the main thread.
//
// Nothing here resumes anything: the no-replay rule after a restart stays.

/// A chat whose run waits for Resume, or was under way when last seen.
struct RunHoldRecord: Codable, Sendable, Equatable {
    static let kind = "run-hold"
    /// Written once the first launch of this build has read every journal.
    static let bootstrapKind = "run-hold-bootstrap", bootstrapID = "v1"
    var id: String
    /// "paused", "interrupted", or "active": a run was under way when last
    /// seen, so the app quit (which stops runs) or stopped during it.
    var state: String
    /// What the chat's row says until the chat's own state is known: an
    /// interrupted run is called so, anything else waiting is "paused".
    var presented: String { state == RunState.interrupted.rawValue ? state : RunState.paused.rawValue }
}

extension SessionDisplay {
    /// What a chat's run hold is from what its display knows, or nil when
    /// nothing waits.
    var runHold: String? {
        if runState == .interrupted || (uncertain && !busy && runState != .error) { return RunState.interrupted.rawValue }
        if runState == .paused { return RunState.paused.rawValue }
        if busy { return "active" }
        if queuePaused && !queue.isEmpty && runState != .error { return RunState.paused.rawValue }
        return nil
    }
}

extension WorkspaceModel {
    /// The state a chat's row shows when its display does not know its own:
    /// "paused" or "interrupted", else nil.
    func heldRunState(_ sessionID: String) -> String? {
        guard let record = record(sessionID), !record.isArchived, !record.isUtilityChat else { return nil }
        if let view = displays[sessionID], view.runStateKnown { return nil }
        return runHolds[sessionID]?.presented
    }

    /// The display's state is now known (a helper snapshot or the journal was
    /// adopted): the chat's hold follows it, written when it changes.
    func reconcileRunHold(_ sessionID: String) {
        guard let view = displays[sessionID], view.runStateKnown, let item = record(sessionID), !item.isUtilityChat,
              !isEphemeral(sessionID), !pendingChatIDs.contains(sessionID) else { return }
        setRunHold(sessionID, view.runHold)
    }

    func setRunHold(_ sessionID: String, _ state: String?) {
        let next = state.map { RunHoldRecord(id: sessionID, state: $0) }
        guard runHolds[sessionID] != next else { return }
        if let next { runHolds[sessionID] = next } else { runHolds.removeValue(forKey: sessionID) }
        guard store != nil else { return }
        dirtyRunHolds.insert(sessionID)
        scheduleRunHoldWrite(sessionID)
    }

    private func scheduleRunHoldWrite(_ id: String) {
        guard runHoldWrites[id] == nil else { return }
        runHoldWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.runHoldWrites[id] = nil }
            // Always the newest value, in order: a clear is never overtaken by an older hold.
            while self.dirtyRunHolds.remove(id) != nil {
                guard let store = self.store else { return }
                let value = self.runHolds[id]
                do {
                    if self.runHoldWritesFail { throw StoreError.unavailable }
                    if let value { try await store.put(value, kind: RunHoldRecord.kind, id: id) }
                    else { try await store.remove(kind: RunHoldRecord.kind, id: id) }
                } catch {
                    // Still to be written: a later change or the quit's flush tries again.
                    self.dirtyRunHolds.insert(id); return
                }
            }
        }
    }

    /// Waits for the hold writes under way, bounded: quit and update call it
    /// once the helpers have stopped.
    @discardableResult func flushRunHolds(timeout: TimeInterval = 3) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while !runHoldWrites.isEmpty || !dirtyRunHolds.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            for id in dirtyRunHolds where runHoldWrites[id] == nil { scheduleRunHoldWrite(id) }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }

    /// At launch, with the chats loaded: the saved holds show at once, then
    /// the journals of the chats they name (and, on the first launch of this
    /// build, every chat's) are read from their ends off the main thread and
    /// decide. A chat whose state is known by then keeps what it knows.
    func restoreRunHolds() async {
        guard let store else { return }
        let known = Dictionary(chats.filter { !$0.isUtilityChat }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = (try? await store.list(RunHoldRecord.self, kind: RunHoldRecord.kind)) ?? []
        for hold in saved where known[hold.id] != nil && runHolds[hold.id] == nil && displays[hold.id]?.runStateKnown != true { runHolds[hold.id] = hold }
        for hold in saved where known[hold.id] == nil { try? await store.remove(kind: RunHoldRecord.kind, id: hold.id) }
        let bootstrapped = (try? await store.get(Int64.self, kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)) != nil
        let candidates = (bootstrapped ? saved.map(\.id) : Array(known.keys))
            .compactMap { id in known[id]?.path.map { (id, $0) } }
        // The sidebar is on screen with the saved holds; the journals decide after.
        runHoldVerification = Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                candidates.map { candidate -> (String, JournalRunHold) in
                    // A state record far back in a long journal: one wider look.
                    let near = JournalRunHold.read(path: candidate.1)
                    return (candidate.0, near == .unknown ? JournalRunHold.read(path: candidate.1, window: 4_194_304) : near)
                }
            }.value
            guard let self, !self.isShutDown else { return }
            for (id, hold) in read where self.record(id) != nil && self.displays[id]?.runStateKnown != true {
                switch hold {
                case .held(let state): self.setRunHold(id, state)
                case .clear: self.setRunHold(id, nil)
                case .unknown: break  // a saved hold stays; nothing is made up
                }
            }
            // The first launch's reading is done once every journal has said;
            // one that could not be read is tried again next launch.
            // and only once the holds it found are saved: else a chat paused
            // before this build would never be read again.
            if !bootstrapped, !read.contains(where: { $0.1 == .unknown }), await self.flushRunHolds() {
                try? await store.put(Int64(1), kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)
            }
        }
    }

    func forgetRunHold(_ id: String) {
        runHolds.removeValue(forKey: id); dirtyRunHolds.remove(id)
    }
}
