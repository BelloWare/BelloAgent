import Foundation

struct MenuBarActivityRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let workspace: String
    let phase: String
    let model: String
    let resolvedModel: String?
    let tools: [String]
    let followUps: Int
    let steering: Int
    let unread: Int
    var modelActive = false
    var startedAt: Double?
    var elapsedMs: Double?
    var latestRate: Double?
    var tokens: Double?
    var costUSD: Double?
    var retryAttempt: Int?
    var retryLimit: Int?
    var running: Bool { ["starting", "model", "tool", "compacting", "stopping"].contains(phase) }
    var needsAttention: Bool { ["queued", "paused", "error"].contains(phase) }
    var phaseLabel: String {
        if let retryAttempt, let retryLimit { return "Retrying · attempt \(retryAttempt) of \(retryLimit)" }
        switch phase {
        case "starting": return "Starting"
        case "model": return "Generating"
        case "tool": return "Working"
        case "compacting": return "Compacting context"
        case "stopping": return "Stopping"
        case "queued": return "Waiting for project"
        case "paused": return "Paused · needs attention"
        case "error": return "Error · needs attention"
        default: return unread > 0 ? "\(unread) unread \(unread == 1 ? "reply" : "replies")" : "Idle"
        }
    }
    func elapsed(at date: Date) -> Double? {
        guard running else { return nil }
        guard let startedAt else { return elapsedMs }
        return max(elapsedMs ?? 0, max(0, date.timeIntervalSince1970 * 1_000 - startedAt))
    }
}

struct MenuBarActivitySnapshot: Equatable, Sendable {
    var rows: [MenuBarActivityRow] = []
    var unreadChats = 0
    /// The menu focuses on work happening now. Keep the complete local snapshot
    /// separate so hiding rows never alters a chat's queue or unread state.
    var runningRows: [MenuBarActivityRow] { rows.filter(\.running) }
    /// Chats waiting on the user: queued behind a project, paused or failed.
    var attentionRows: [MenuBarActivityRow] { rows.filter(\.needsAttention) }
    /// Idle chats with replies the user has not viewed yet.
    var unreadRows: [MenuBarActivityRow] { rows.filter { !$0.running && !$0.needsAttention && $0.unread > 0 } }
    var running: Int { runningRows.count }
    var generating: Int { runningRows.filter { $0.modelActive && $0.retryAttempt == nil }.count }
    var runningPending: Int { runningRows.reduce(0) { $0 + $1.followUps + $1.steering } }
    var queuedChats: Int { rows.filter { $0.phase == "queued" }.count }
    var paused: Int { rows.filter { $0.phase == "paused" }.count }
    var pending: Int { rows.reduce(0) { $0 + $1.followUps + $1.steering } }
}

extension WorkspaceModel {
    /// Reads the existing bounded display snapshots. Opening the menu does not
    /// load a session, poll a provider, or sum completed-request average speeds.
    func menuBarActivity(now: Double = ProcessInfo.processInfo.systemUptime) -> MenuBarActivitySnapshot {
        var rows: [MenuBarActivityRow] = []
        for view in displays.values {
            guard let record = record(view.id), !record.isArchived, record.connectionTest != true else { continue }
            let raw = view.activity, unread = unreadOutputCount(sessionID: view.id)
            let phase: String
            if view.state == "error" { phase = "error" }
            else if ["paused", "interrupted"].contains(view.state) || view.uncertain { phase = "paused" }
            else if view.state == "stopping" { phase = "stopping" }
            else if view.loading { phase = "starting" }
            else if view.busy {
                let candidate = raw["phase"]?.string ?? ""
                phase = ["starting", "model", "tool", "compacting", "queued"].contains(candidate) ? candidate : (view.state == "queued" ? "queued" : "starting")
            } else { phase = "idle" }
            let followUps = activityCount(raw["pendingFollowUps"]) ?? max(0, view.queueCount)
            let steering = activityCount(raw["pendingSteering"]) ?? 0
            guard phase != "idle" || followUps + steering > 0 || unread > 0 else { continue }
            let workspace = workspaces.first { $0.id == record.workspaceID }.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Project"
            let model = raw["model"]?.string ?? record.model ?? profiles.first { $0.id == record.profileID }?.modelId ?? ""
            // This is explicitly the last reported route, never an assumption
            // that a router will use the same model for its next HTTP request.
            let identity = view.metrics["identity"]?.object
            let resolved = view.metrics["requestedModel"]?.string == model && identity?["status"]?.string == "reported" ? identity?["effectiveModel"]?.string : nil
            let tools = (raw["toolNames"]?.array ?? []).compactMap(\.string)
            let totals = chatStats[view.id]
            var row = MenuBarActivityRow(id: view.id, title: record.title, workspace: workspace, phase: phase, model: model, resolvedModel: resolved != model ? resolved : nil, tools: tools, followUps: followUps, steering: steering, unread: unread)
            row.modelActive = raw["modelActive"]?.bool == true
            row.startedAt = activityNumber(view.turnTiming["startedAt"])
            row.elapsedMs = activityNumber(view.turnTiming["elapsedMs"])
            row.latestRate = view.footer.timing.latest?.outputTokensPerSecond
            row.tokens = totals?.tokens?.total
            row.costUSD = totals?.costUSD
            if view.runStatus == "retrying" {
                row.retryAttempt = view.retryAttempt
                row.retryLimit = view.retryLimit
            }
            rows.append(row)
        }
        // Persistent unread badges do not require loading old transcript pages
        // or starting their helper. Keep those chats actionable after restart.
        let projectedIDs = Set(rows.map(\.id))
        for record in chats where !projectedIDs.contains(record.id) {
            let unread = unreadOutputCount(sessionID: record.id)
            guard unread > 0 else { continue }
            let workspace = workspaces.first { $0.id == record.workspaceID }.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Project"
            let model = record.model ?? profiles.first { $0.id == record.profileID }?.modelId ?? ""
            rows.append(MenuBarActivityRow(id: record.id, title: record.title, workspace: workspace, phase: "idle", model: model, resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: unread))
        }
        rows.sort {
            let a = $0.running ? 0 : $0.phase == "queued" ? 1 : ["paused", "error"].contains($0.phase) ? 2 : 3
            let b = $1.running ? 0 : $1.phase == "queued" ? 1 : ["paused", "error"].contains($1.phase) ? 2 : 3
            if a != b { return a < b }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
        return MenuBarActivitySnapshot(rows: rows, unreadChats: unreadCount)
    }
}

private func activityCount(_ value: WireValue?) -> Int? {
    guard let value = value?.number, value.isFinite, value >= 0, value <= 100_000, value.rounded() == value else { return nil }
    return Int(value)
}

private func activityNumber(_ value: WireValue?) -> Double? {
    guard let number = value?.number, number.isFinite, number >= 0 else { return nil }
    return number
}
