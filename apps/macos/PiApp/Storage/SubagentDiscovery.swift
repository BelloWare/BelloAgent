import Foundation

struct DiscoveredSubagent: Sendable {
    var header: SubagentHeader
    var path: String
    var task: String
    var status: SubagentStatus
    var issue: String?
}

extension HistoryReader {
    func validateSubagentDeletion(path: URL, directory: URL, expected: SubagentTarget) throws {
        guard path.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
              path.lastPathComponent == expected.sessionID + ".jsonl" else { throw StoreError.invalidRecord }
        var rows: [[String: WireValue]] = []
        try subagentRecords(path) { row, line in rows.append(row); return line < 3 }
        guard rows.count >= 2, rows[0]["type"]?.string == "session", rows[0]["version"]?.number == 3, rows[0]["id"]?.string == expected.sessionID,
              rows[1]["customType"]?.string == "pi-app.native.v2", rows[1]["data"]?.object?["version"]?.number == 2 else { throw StoreError.invalidRecord }
        if rows.count > 2 { _ = try subagentHeader(path: path, directory: directory, expected: expected) }
    }
    /// The owning journal is the authority even before a child file exists.
    func subagentPlans(path: URL, ownerID: String, childID: String? = nil) throws -> [DiscoveredSubagent] {
        var found: [DiscoveredSubagent] = []
        try subagentRecords(path) { row, line in
            if line == 1 { guard row["type"]?.string == "session", row["id"]?.string == ownerID, row["version"]?.number == 3 else { throw StoreError.invalidRecord } }
            if row["customType"]?.string == "pi-app.subagent-call.v1", let data = row["data"]?.object,
               let raw = data["origin"], let origin = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)),
               origin.link.valid, origin.link.budgetOwnerSessionID == ownerID, UUID(uuidString: origin.link.childSessionID) != nil,
               childID == nil || childID == origin.link.childSessionID {
                let child = path.deletingLastPathComponent().appendingPathComponent(origin.link.childSessionID + ".jsonl")
                guard child.resolvingSymlinksInPath().deletingLastPathComponent() == path.resolvingSymlinksInPath().deletingLastPathComponent() else { throw StoreError.invalidRecord }
                found.append(DiscoveredSubagent(header: origin, path: child.path, task: data["task"]?.string ?? "", status: .interrupted))
                if childID != nil { return false }
            }
            return true
        }
        return found
    }
    /// Streaming scan: retain only origins/plans/status, never transcript or
    /// capture bodies. A torn final line is left for the helper's recovery.
    private func subagentRecords(_ path: URL, visit: ([String: WireValue], Int) throws -> Bool) throws {
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
        var pending = Data(), line = 0
        let needle = Data("pi-app.subagent-".utf8)
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            var start = bytes.startIndex
            while let end = bytes[start...].firstIndex(of: 10) {
                pending.append(bytes[start..<end]); start = end + 1
                guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                line += 1
                if line <= 3 || pending.range(of: needle) != nil {
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
        func plan(_ owner: String) throws -> [String: WireValue] {
            if checked.insert(owner).inserted {
                guard let parent = byID[owner], let saved = parent.path else { return [:] }
                let path = URL(fileURLWithPath: saved)
                guard path.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw StoreError.invalidRecord }
                try subagentRecords(path) { row, line in
                    if line == 1 { guard row["type"]?.string == "session", row["id"]?.string == owner, row["version"]?.number == 3 else { throw StoreError.invalidRecord } }
                    if row["customType"]?.string == "pi-app.subagent-call.v1", let data = row["data"]?.object,
                       let raw = data["origin"], let origin = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)),
                       origin.link.valid, origin.link.budgetOwnerSessionID == owner {
                        let id = origin.link.childSessionID
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
            var prefix: [[String: WireValue]] = [], status: SubagentStatus = .interrupted
            do {
                try subagentRecords(path) { row, line in
                    if line <= 3 { prefix.append(row) }
                    if line == 2, row["customType"]?.string != "pi-app.native.v2" { return false }
                    if row["customType"]?.string == "pi-app.subagent-terminal.v1", prefix.count == 3,
                       let data = row["data"]?.object,
                       data["delegationID"] == prefix[2]["data"]?.object?["link"]?.object?["delegationID"],
                       let value = data["status"]?.string.flatMap(SubagentStatus.init(rawValue:)), value.terminal { status = value }
                    return true
                }
                guard prefix.count == 3, let raw = prefix[2]["data"], let header = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)) else { continue }
                _ = try subagentHeader(path: path, directory: directory, expected: SubagentTarget(header.link))
                let accepted = (try? plan(header.link.budgetOwnerSessionID))?[header.link.childSessionID]?.object
                let issue = accepted?["origin"] == raw ? nil : "The parent’s matching delegation is unavailable. This saved sub-agent is view-only."
                found.append(DiscoveredSubagent(header: header, path: path.path, task: accepted?["task"]?.string ?? "", status: status, issue: issue))
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // Invalid headers remain untouched; helper recovery reports their exact error.
        }
        return found
    }
}
