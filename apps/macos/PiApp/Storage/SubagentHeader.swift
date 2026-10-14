import Foundation

/// Discovery reads identity without opening a writable helper session. The
/// helper still validates the whole chain before any managed journal opens.
struct SubagentHeader: Codable, Sendable {
    var link: SubagentLink
    var description: String
    var model: SubagentModelGrant
    var readOnly: Bool
}

extension HistoryReader {
    func subagentHeader(path: URL, directory: URL, expected: SubagentTarget) throws -> SubagentHeader {
        guard UUID(uuidString: expected.sessionID) != nil,
              path.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
              path.lastPathComponent == expected.sessionID + ".jsonl" else { throw StoreError.invalidRecord }
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
        var pending = Data(), rows: [[String: WireValue]] = []
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            var start = bytes.startIndex
            while let end = bytes[start...].firstIndex(of: 10) {
                pending.append(bytes[start..<end]); start = end + 1
                guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                rows.append(try JSONDecoder().decode([String: WireValue].self, from: pending))
                pending.removeAll(keepingCapacity: true)
                if rows.count == 3 {
                    guard rows[0]["type"]?.string == "session", rows[0]["version"]?.number == 3, rows[0]["id"]?.string == expected.sessionID,
                          ["pi-app.native.v2", "pi-app.native.v3"].contains(rows[1]["customType"]?.string ?? ""), rows[1]["data"]?.object?["version"]?.number == 2,
                          rows[2]["customType"]?.string == "pi-app.subagent-origin.v1",
                          let markerID = rows[1]["id"]?.string, rows[2]["parentId"]?.string == markerID,
                          let data = rows[2]["data"] else { throw StoreError.invalidRecord }
                    let header = try JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(data))
                    guard header.link.valid, expected.matchesOrigin(header.link) else { throw StoreError.invalidRecord }
                    return header
                }
            }
            pending.append(bytes[start...])
            guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        throw StoreError.unreadableRecord
    }
}

extension HistoryReader {
    /// Navigation reads the child transcript without opening another writer.
    /// Message targets are accepted only if their typed provenance names this
    /// child/turn. The caller already validated the reciprocal origin.
    func subagentTurnMessage(path: URL, childID: String, turn: Int?, messageID: String?) throws -> String? {
        guard turn != nil || messageID != nil else { return nil }
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
        var pending = Data()
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation(); pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let data = Data(pending[..<end]); pending.removeSubrange(...end)
                guard data.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                guard data.range(of: Data("nativeAgentDelivery".utf8)) != nil,
                      let row = try? JSONDecoder().decode([String: WireValue].self, from: data),
                      let id = row["id"]?.string, let author = row["message"]?.object?["nativeAgentDelivery"]?.object,
                      author["childId"]?.string == childID,
                      turn == nil || author["turn"]?.nonnegativeInteger == turn,
                      messageID == nil || id == messageID || author["eventIds"]?.array?.contains(.string(messageID!)) == true else { continue }
                return id
            }
            guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        return nil
    }
}
