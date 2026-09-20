import Foundation
import Combine

/// A retained sidebar row observes only its own accounting. Publishing a cost
/// for one chat must not redraw the window, active composer or other projects.
@MainActor final class CachedSessionAccounting: ObservableObject {
    @Published private(set) var totals: GatewayTotals?
    init(totals: GatewayTotals?) { self.totals = totals }
    func update(_ value: GatewayTotals) {
        if totals != value { totals = value }
    }
}

@MainActor final class SessionAccountingCache {
    /// One observable per chat the sidebar has drawn. A workspace can hold far
    /// more chats than a sidebar ever lists, so the observables are held
    /// weakly: a row lives exactly as long as the view drawing it, and the
    /// figures themselves stay in `values`, which is what a rebuilt row reads.
    private struct Row { weak var observable: CachedSessionAccounting? }
    /// How many entries may accumulate before the dead ones are swept. Only a
    /// bound on bookkeeping; the live rows are whatever is on screen.
    static let sweepThreshold = 256
    private(set) var values: [String: GatewayTotals] = [:]
    private var rows: [String: Row] = [:]
    /// Test seam: how many entries the table is carrying.
    var trackedRows: Int { rows.count }

    func row(for sessionID: String) -> CachedSessionAccounting {
        if let existing = rows[sessionID]?.observable { return existing }
        let row = CachedSessionAccounting(totals: values[sessionID])
        rows[sessionID] = Row(observable: row)
        if rows.count > Self.sweepThreshold { rows = rows.filter { $0.value.observable != nil } }
        return row
    }

    func publish(_ totals: GatewayTotals, sessionID: String) {
        guard values[sessionID] != totals else { return }
        values[sessionID] = totals
        rows[sessionID]?.observable?.update(totals)
    }
}

extension WorkspaceModel {
    /// Metadata updates, not body chunks, invalidate compact accounting. One
    /// task per session coalesces streaming metadata and late final billing.
    func captureDidPersist(_ packet: [String: WireValue], workspaceID: String) async {
        guard !accountingStopped, let type = packet["type"]?.string, ["begin", "metadata", "finish", "links", "interrupted"].contains(type) else { return }
        let metadata = packet["metadata"]?.object ?? packet
        let visibleIDs = Set([selectedID, sides[selectedID ?? ""]?.id].compactMap { $0 })
        let visible = Dictionary(uniqueKeysWithValues: visibleIDs.compactMap { id -> (String, Set<String>)? in
            guard record(id)?.workspaceID == workspaceID, let view = displays[id] else { return nil }
            return (id, Set(TranscriptPage.displayPage(view.messages).map(\.id)))
        })
        var sessions = Set<String>()
        var outputs = Set(metadata["outputMessageIds"]?.array?.compactMap(\.string) ?? [])
        let metadataSession = metadata["sessionId"]?.string
        if let id = metadataSession, record(id)?.workspaceID == workspaceID { sessions.insert(id) }
        let inheritedVisible = visible.filter { $0.key != metadataSession }
        // Metadata already names its owner. Only links need to resolve it;
        // other packets need a read only when another visible pane could show
        // an inherited output. Background bursts keep their cheap coalescing.
        if let attempt = metadata["attemptId"]?.string, type == "links" || !inheritedVisible.isEmpty,
           let target = try? await traces.accountingTarget(attemptID: attempt, workspaceID: workspaceID, visibleMessageIDs: inheritedVisible.values.reduce(into: Set<String>()) { $0.formUnion($1) }) {
            if record(target.sessionID)?.workspaceID == workspaceID { sessions.insert(target.sessionID) }
            outputs.formUnion(target.outputMessageIDs)
        } else if type == "interrupted" {
            for id in displays.keys where record(id)?.workspaceID == workspaceID {
                sessions.insert(id)
            }
        }
        guard !accountingStopped, !Task.isCancelled else { return }
        // A side/fork can show an inherited assistant row from another
        // session. Its inline attribution still follows that output's owner;
        // unrelated background chats need no query. Matching visible outputs
        // also handles a missing owner while its metadata is still arriving.
        if !outputs.isEmpty {
            for (id, messages) in visible where record(id)?.workspaceID == workspaceID {
                if !outputs.isDisjoint(with: messages) { sessions.insert(id) }
            }
        }
        for id in sessions { scheduleAccounting(id, workspaceID: workspaceID) }
    }

    /// SQL attribution depends on row identity/order, role and the streaming
    /// fallback, never on each additional text/thinking/tool-output byte.
    static func accountingTargetsChanged(from previous: [TranscriptMessage], to messages: [TranscriptMessage]) -> Bool {
        !TranscriptPage.displayPage(previous).elementsEqual(TranscriptPage.displayPage(messages)) {
            $0.id == $1.id && $0.role == $1.role && ($0.kind == "compaction") == ($1.kind == "compaction")
                && ($0.state == "streaming") == ($1.state == "streaming")
        }
    }

    func scheduleAccounting(_ id: String, workspaceID: String) {
        guard !accountingStopped else { return }
        dirtyAccounting.insert(id)
        guard accountingTasks[id] == nil else { return }
        accountingTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            defer { accountingTasks.removeValue(forKey: id) }
            while !Task.isCancelled, dirtyAccounting.remove(id) != nil {
                guard record(id)?.workspaceID == workspaceID else { break }
                if let view = displays[id] {
                    let visible = selectedID == id || sides[selectedID ?? ""]?.id == id
                    await refreshAccounting(view, workspaceID: workspaceID, includeMessages: visible)
                }
                else {
                    let revision = beginChatStatsQuery(id)
                    if let value = try? await traces.gatewayAccounting(sessionID: id, workspaceID: workspaceID, messages: []),
                       !Task.isCancelled, record(id)?.workspaceID == workspaceID {
                        publishChatStats(value.session, sessionID: id, revision: revision)
                    }
                }
                if dirtyAccounting.contains(id) { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    func refreshRetainedAccounting() async {
        for view in displays.values {
            if let workspaceID = record(view.id)?.workspaceID { await refreshAccounting(view, workspaceID: workspaceID) }
        }
        await refreshChatStats()
    }

    /// All project groups remain visible, so restore retained totals without
    /// loading their hosts. Publish each result promptly and reject an older
    /// query if a late capture or loaded display has already superseded it.
    func refreshChatStats(query: (@MainActor (ChatRecord) async throws -> GatewayTotals)? = nil) async {
        chatStatsRevision += 1
        let batch = chatStatsRevision
        let records = chats.filter { displays[$0.id] == nil }
        guard !records.isEmpty else { return }
        if query == nil {
            // One grouped read for every chat; chats with no retained attempts
            // publish empty totals so stale figures never linger.
            let revisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, beginChatStatsQuery($0.id)) })
            guard let totals = try? await traces.allSessionTotals(), !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
            for chat in records where record(chat.id)?.workspaceID == chat.workspaceID && displays[chat.id] == nil {
                publishChatStats(totals[chat.workspaceID + "\u{0}" + chat.id] ?? GatewayTotals(), sessionID: chat.id, revision: revisions[chat.id])
            }
            return
        }
        // The `query == nil` branch above has already returned.
        guard let query else { return }
        for chat in records {
            guard !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
            if displays[chat.id] != nil { continue }
            let revision = beginChatStatsQuery(chat.id)
            do {
                let totals = try await query(chat)
                guard !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
                if record(chat.id)?.workspaceID == chat.workspaceID, displays[chat.id] == nil {
                    publishChatStats(totals, sessionID: chat.id, revision: revision)
                }
            } catch { /* Keep the last observed totals while storage is unavailable. */ }
        }
    }

    private func beginChatStatsQuery(_ id: String) -> Int {
        let revision = (chatStatsVersions[id] ?? 0) + 1
        chatStatsVersions[id] = revision
        return revision
    }

    func publishChatStats(_ totals: GatewayTotals, sessionID id: String, revision: Int? = nil) {
        if let revision {
            guard chatStatsVersions[id] == revision else { return }
        } else { _ = beginChatStatsQuery(id) }
        chatAccounting.publish(totals, sessionID: id)
    }

    func refreshAccounting(_ view: SessionDisplay, workspaceID: String, includeMessages: Bool = true, query: (@MainActor () async throws -> SessionGatewayAccounting)? = nil) async {
        view.accountingRevision += 1
        let revision = view.accountingRevision
        let totalsRevision = beginChatStatsQuery(view.id)
        // Match the native transcript's bounded visible page. Older prefetched
        // rows must neither fail this query's limit nor enlarge it indefinitely.
        let page = includeMessages ? TranscriptPage.displayPage(view.messages) : []
        let requestedIDs = page.map(\.id)
        do {
            let value: SessionGatewayAccounting
            if let query { value = try await query() }
            else { value = try await traces.gatewayAccounting(sessionID: view.id, workspaceID: workspaceID, messages: page, includeTiming: true) }
            guard !Task.isCancelled, view.accountingRevision == revision else { return }
            if view.footer.gateway != value.session { view.footer.gateway = value.session }
            if let timing = value.timing, view.footer.timing != timing { view.footer.timing = timing }
            publishChatStats(value.session, sessionID: view.id, revision: totalsRevision)
            if !view.footer.gatewayNotice.isEmpty { view.footer.gatewayNotice = "" }
            // Background sessions need current sidebar/session metrics, not a
            // fresh SQL attribution and transcript publication on every pulse.
            guard includeMessages else { return }
            // A streamed message/page change must not discard session billing.
            // Only per-message attribution depends on the requested projection.
            guard TranscriptPage.displayPage(view.messages).map(\.id) == requestedIDs else { return }
            view.messageAccounting = value.messages
            var messages = view.messages
            for index in messages.indices { messages[index].accounting = value.messages[messages[index].id] }
            // Accounting doesn't invalidate the helper's content revision.
            let revision = view.projectionRevision
            if view.messages != messages { view.messages = messages; view.projectionRevision = revision }
        } catch {
            guard !Task.isCancelled, view.accountingRevision == revision else { return }
            view.footer.gatewayNotice = "Retained cost/cache metrics unavailable"
        }
    }
}
