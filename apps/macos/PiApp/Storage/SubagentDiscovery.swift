import Foundation

struct DiscoveredSubagent: Sendable {
    var header: SubagentHeader
    var path: String
    var task: String
    var status: SubagentStatus
    var issue: String?
    var hasTerminalRecord = false
    var turn: Int? = nil
    var executionID: String? = nil
    /// Rebuildable UI ordinal in the owner's persisted acceptance order.
    var number: Int? = nil
    var effort: String? = nil
    /// Unsealed and held at its family's cost limit (the owner's or the
    /// child's saved `costPaused`): queued for Resume, not interrupted.
    var costPaused = false
}

extension HistoryReader {
    /// Match helper recovery's SubagentOrigin.matchesAccepted rule without
    /// dropping fields absent from the desktop's smaller SubagentHeader type.
    /// Older helpers omit optional model capabilities; no other origin field
    /// or explicit capability difference is compatible.
    static func subagentOriginMatchesAccepted(_ mirror: WireValue, accepted: WireValue?) -> Bool {
        guard let accepted, let owner = accepted.object, var child = mirror.object,
              let ownerModel = owner["model"]?.object, var childModel = child["model"]?.object else { return false }
        if childModel["reasoning"] == nil || childModel["reasoning"] == .null { childModel["reasoning"] = ownerModel["reasoning"] }
        child["model"] = .object(childModel)
        return .object(child) == accepted
    }

    static func subagentPlan(_ row: [String: WireValue]) -> [String: WireValue]? {
        switch row["customType"]?.string {
        case "pi-app.subagent-call.v1": row["data"]?.object
        case "pi-app.agent-operation.v1": row["data"]?.object?["plan"]?.object
        default: nil
        }
    }

    func validateSubagentDeletion(path: URL, directory: URL, expected: SubagentTarget) throws {
        guard path.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
              path.lastPathComponent == expected.sessionID + ".jsonl" else { throw StoreError.invalidRecord }
        var rows: [[String: WireValue]] = []
        try subagentRecords(path) { row, line in rows.append(row); return line < 3 }
        guard rows.count >= 2, rows[0]["type"]?.string == "session", rows[0]["version"]?.number == 3, rows[0]["id"]?.string == expected.sessionID,
              ["pi-app.native.v2", "pi-app.native.v3"].contains(rows[1]["customType"]?.string ?? ""), rows[1]["data"]?.object?["version"]?.number == 2 else { throw StoreError.invalidRecord }
        if rows.count > 2 { _ = try subagentHeader(path: path, directory: directory, expected: expected) }
    }
    /// The owning journal is the authority even before a child file exists.
    func subagentPlans(path: URL, ownerID: String, childID: String? = nil, includeInherited: Bool = false) throws -> [DiscoveredSubagent] {
        try Task.checkCancellation()
        let revision = Self.currentRevision(path: path.path)
        func matches(_ plan: DiscoveredSubagent) -> Bool {
            (includeInherited || plan.header.link.budgetOwnerSessionID == ownerID) &&
                (childID == nil || plan.header.link.childSessionID == childID)
        }
        if let revision, let cached = subagentPlanCache[path.path], cached.owner == ownerID, cached.revision == revision {
            subagentPlanRecency.removeAll { $0 == path.path }; subagentPlanRecency.append(path.path)
            return cached.plans.filter(matches)
        }
        var found: [DiscoveredSubagent] = [], starts: [String: SubagentLink] = [:]
        try subagentRecords(path) { row, line in
            if line == 1 { guard row["type"]?.string == "session", row["id"]?.string == ownerID, row["version"]?.number == 3 else { throw StoreError.invalidRecord } }
            if let data = Self.subagentPlan(row),
               let raw = data["origin"], let origin = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)),
               origin.link.valid, UUID(uuidString: origin.link.childSessionID) != nil {
                let id = origin.link.childSessionID
                if let previous = starts[id] {
                    guard previous == origin.link else { throw StoreError.invalidRecord }
                    return true
                }
                starts[id] = origin.link
                // Count every unique start, even when filtering or when its
                // child file is missing. Follow-ups never contain a new plan.
                // Full scans retain every start, so inheritance/filter choices
                // share one revision cache. Targeted cold lookups still stop
                // at their child and never cache a partial set of plans.
                if let childID {
                    guard (includeInherited || origin.link.budgetOwnerSessionID == ownerID), childID == id else { return true }
                }
                let child = path.deletingLastPathComponent().appendingPathComponent(origin.link.childSessionID + ".jsonl")
                guard child.resolvingSymlinksInPath().deletingLastPathComponent() == path.resolvingSymlinksInPath().deletingLastPathComponent() else { throw StoreError.invalidRecord }
                found.append(DiscoveredSubagent(header: origin, path: child.path, task: data["task"]?.string ?? "", status: .interrupted, number: starts.count))
                if childID != nil { return false }
            }
            return true
        }
        try Task.checkCancellation()
        if childID == nil, let revision, Self.currentRevision(path: path.path) == revision {
            subagentPlanCache[path.path] = (ownerID, revision, found)
            subagentPlanRecency.removeAll { $0 == path.path }; subagentPlanRecency.append(path.path)
            while subagentPlanRecency.count > 8 {
                subagentPlanCache.removeValue(forKey: subagentPlanRecency.removeFirst())
            }
        }
        return found.filter(matches)
    }
    /// Streaming scan: retain only origins/plans/status, never transcript or
    /// capture bodies. A torn final line is left for the helper's recovery.
    func subagentRecords(_ path: URL, visit: ([String: WireValue], Int) throws -> Bool) throws {
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
        var pending = Data(), line = 0
        // Run-state records carry a cost-limit pause (`costPaused`).
        let needles = ["pi-app.subagent-", "pi-app.agent-", "pi-app.family-run", "pi-app.native.state.v1"].map { Data($0.utf8) }
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            subagentScannedBytes += bytes.count
            try Task.checkCancellation()
            var start = bytes.startIndex
            while let end = bytes[start...].firstIndex(of: 10) {
                pending.append(bytes[start..<end]); start = end + 1
                guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                line += 1
                if line <= 3 || needles.contains(where: { pending.range(of: $0) != nil }) {
                    let row = try JSONDecoder().decode([String: WireValue].self, from: pending)
                    if try !visit(row, line) { return }
                }
                pending.removeAll(keepingCapacity: true)
            }
            pending.append(bytes[start...])
            guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
    }

    /// Existing journals are readable even with rollout off. A missing or
    /// inconsistent reciprocal plan becomes an input-free recovery view.
    func discoverSubagents(directory: URL, parents: [ChatRecord]) throws -> [DiscoveredSubagent] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let byID = Dictionary(parents.filter { !$0.isSubagent && !$0.imported }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var plans: [String: [String: WireValue]] = [:], checked: Set<String> = []
        var numbers: [String: [String: Int]] = [:], ownerPaused: [String: Bool] = [:]
        func plan(_ owner: String) throws -> [String: WireValue] {
            if checked.insert(owner).inserted {
                guard let parent = byID[owner], let saved = parent.path else { return [:] }
                let path = URL(fileURLWithPath: saved)
                guard path.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw StoreError.invalidRecord }
                try subagentRecords(path) { row, line in
                    if line == 1 { guard row["type"]?.string == "session", row["id"]?.string == owner, row["version"]?.number == 3 else { throw StoreError.invalidRecord } }
                    if row["customType"]?.string == StateRecordTail.customType { ownerPaused[owner] = row["data"]?.object?["costPaused"]?.bool == true }
                    if let data = Self.subagentPlan(row),
                       let raw = data["origin"], let origin = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)),
                       origin.link.valid {
                        let id = origin.link.childSessionID
                        if numbers[owner]?[id] == nil { numbers[owner, default: [:]][id] = (numbers[owner]?.count ?? 0) + 1 }
                        guard origin.link.budgetOwnerSessionID == owner else { return true }
                        if let previous = plans[owner]?[id], previous != .object(data) { throw StoreError.invalidRecord }
                        plans[owner, default: [:]][id] = .object(data)
                    }
                    return true
                }
            }
            return plans[owner] ?? [:]
        }
        var found: [DiscoveredSubagent] = []
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where path.pathExtension == "jsonl" {
            guard UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil,
                  path.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { continue }
            var prefix: [[String: WireValue]] = [], status: SubagentStatus = .interrupted, terminal = false
            var latestTurn: Int?, executionID: String?, effort: String?, childPaused = false
            do {
                try subagentRecords(path) { row, line in
                    if line <= 3 { prefix.append(row) }
                    if line == 2, !["pi-app.native.v2", "pi-app.native.v3"].contains(row["customType"]?.string ?? "") { return false }
                    if row["customType"]?.string == "pi-app.subagent-terminal.v1", prefix.count == 3,
                       let data = row["data"]?.object,
                       data["delegationID"] == prefix[2]["data"]?.object?["link"]?.object?["delegationID"],
                       let value = data["status"]?.string.flatMap(SubagentStatus.init(rawValue:)), value.terminal { status = value; terminal = true }
                    let kind = row["customType"]?.string ?? ""
                    if kind == StateRecordTail.customType { childPaused = row["data"]?.object?["costPaused"]?.bool == true }
                    let turnData = kind == "pi-app.agent-operation.v1" ? row["data"]?.object?["turn"]?.object : row["data"]?.object
                    if ["pi-app.agent-operation.v1", "pi-app.subagent-turn.v1", "pi-app.subagent-turn-state.v1", "pi-app.subagent-turn-terminal.v1"].contains(kind),
                       let data = turnData, data["childID"]?.string == path.deletingPathExtension().lastPathComponent,
                       let number = data["turn"]?.nonnegativeInteger, number > 0, number >= (latestTurn ?? 0) {
                        if number != latestTurn { terminal = false; status = .interrupted; effort = nil }
                        latestTurn = number; executionID = data["executionID"]?.string
                        // State/terminal mirrors need not repeat the accepted
                        // turn's effort. Never replace it with an absent field.
                        if let accepted = data["effort"]?.string { effort = accepted }
                        if kind == "pi-app.subagent-turn-terminal.v1", let value = data["status"]?.string.flatMap(SubagentStatus.init(rawValue:)), value.terminal {
                            status = value; terminal = true
                        }
                    }
                    return true
                }
                guard prefix.count == 3, let raw = prefix[2]["data"], let header = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)) else { continue }
                _ = try subagentHeader(path: path, directory: directory, expected: SubagentTarget(header.link))
                let accepted = (try? plan(header.link.budgetOwnerSessionID))?[header.link.childSessionID]?.object
                let issue = Self.subagentOriginMatchesAccepted(raw,accepted:accepted?["origin"]) ? nil : "The parent’s matching delegation is unavailable. This saved sub-agent is view-only."
                var effective = header
                if issue == nil, effective.model.reasoning == nil {
                    effective.model.reasoning = accepted?["origin"]?.object?["model"]?.object?["reasoning"]?.array?.compactMap(\.string)
                }
                let paused = !terminal && (childPaused || ownerPaused[header.link.budgetOwnerSessionID] == true)
                found.append(DiscoveredSubagent(header: effective, path: path.path, task: accepted?["task"]?.string ?? "", status: paused ? .queued : status, issue: issue, hasTerminalRecord: terminal, turn: latestTurn, executionID: executionID, number: numbers[header.link.budgetOwnerSessionID]?[header.link.childSessionID], effort: effort, costPaused: paused))
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // Invalid headers remain untouched; helper recovery reports their exact error.
        }
        return found
    }
}
