import Foundation

/// Immutable read results, paged below the IPC frame limit. This bounds the
/// transport, not reply text. A stale transfer fails rather than returning a
/// successful prefix. No mutation is retried or executed by this reader.
struct DisplayResultTransfers {
    static let chunkBytes = 192 * 1024
    static let maximumBytes = 128 * 1024 * 1024
    private struct Entry { let data: Data; let created: Double }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var bytes = 0

    mutating func insert(_ data: Data, now: Double = ProcessInfo.processInfo.systemUptime) throws -> JSON {
        guard data.count <= Self.maximumBytes else {
            throw AgentError("reply_limit", "This display result exceeds the 128 MiB transport budget. The saved content is unchanged.")
        }
        expire(now)
        while !order.isEmpty && (bytes + data.count > Self.maximumBytes || order.count >= 32) { remove(order[0]) }
        let id = UUID().uuidString
        entries[id] = Entry(data: data, created: now); order.append(id); bytes += data.count
        return ["_displayTransfer":1,"id":JSON(id),"bytes":JSON(data.count)]
    }
    mutating func read(_ id: String, offset: Int, now: Double = ProcessInfo.processInfo.systemUptime) throws -> JSON {
        expire(now)
        guard let entry = entries[id] else { throw AgentError("display_expired", "The display transfer expired. Refresh the conversation to load it again.") }
        guard offset >= 0, offset < entry.data.count else { throw AgentError("invalid_range", "Display transfer offset is invalid") }
        let end = min(entry.data.count, offset + Self.chunkBytes)
        return ["data":JSON(entry.data.subdata(in:offset..<end).base64EncodedString()),"offset":JSON(offset),
                "totalBytes":JSON(entry.data.count),"next":end < entry.data.count ? JSON(end) : .null]
    }
    private mutating func expire(_ now: Double) {
        for id in order where now - (entries[id]?.created ?? 0) > 120 { remove(id) }
    }
    private mutating func remove(_ id: String) {
        if let entry = entries.removeValue(forKey:id) { bytes -= entry.data.count }
        order.removeAll { $0 == id }
    }
}
