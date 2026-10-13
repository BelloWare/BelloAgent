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
                          rows[1]["customType"]?.string == "pi-app.native.v2", rows[1]["data"]?.object?["version"]?.number == 2,
                          rows[2]["customType"]?.string == "pi-app.subagent-origin.v1",
                          let markerID = rows[1]["id"]?.string, rows[2]["parentId"]?.string == markerID,
                          let data = rows[2]["data"] else { throw StoreError.invalidRecord }
                    let header = try JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(data))
                    guard header.link.valid, SubagentTarget(header.link) == expected else { throw StoreError.invalidRecord }
                    return header
                }
            }
            pending.append(bytes[start...])
            guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        throw StoreError.unreadableRecord
    }
}
