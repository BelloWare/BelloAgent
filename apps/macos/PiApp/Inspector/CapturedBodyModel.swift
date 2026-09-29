import SwiftUI
import AppKit

// A captured body once read: its metadata, its JSON, and the server-sent
// event frames of a streamed response, parsed off the main actor.

struct CapturedBodyMetadata: Equatable, Sendable {
    let body: [String: WireValue]
    let hash: WireValue?
    /// The loaded bytes are the start of a body that was still being written
    /// while they were read; later bytes belong to the next read.
    var growingPrefix = false

    init(body: [String: WireValue], hash: WireValue?) { self.body = body; self.hash = hash }
    /// Describes the first `length` bytes of a capture that grew during the read.
    /// A prefix has no digest of its own.
    init(prefix length: Int, of described: CapturedBodyMetadata) {
        var body = described.body
        body["retainedBytes"] = .number(Double(length))
        body["observedBytes"] = .number(max(Double(length), body["observedBytes"]?.number ?? 0))
        self.body = body; hash = nil; growingPrefix = true
    }

    func count() throws -> Int {
        guard let number = body["retainedBytes"]?.number, number.isFinite,
              number >= 0, number <= Double(PayloadArchive.largestCount), number.rounded() == number else {
            throw HostError.failure("The retained body length is invalid.")
        }
        return Int(number)
    }
    var summary: String {
        let state = body["state"]?.string ?? "unavailable"
        let retained = body["retainedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let observed = body["observedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let reason = body["reason"]?.string ?? ""
        if growingPrefix { return "\(state) · first \(retained) bytes loaded while the capture was still being written" + (reason.isEmpty ? "" : " · \(reason)") }
        return "\(state) · all \(retained) retained bytes loaded / \(observed) observed" + (reason.isEmpty ? "" : " · \(reason)")
    }
}

/// JSONSerialization containers and captured event frames are immutable. They
/// are parsed off the main actor and only read afterward; the outline's mutable
/// child cache is a separate main-actor object.
struct CapturedJSON: @unchecked Sendable {
    let id = UUID()
    let value: Any
    let eagerFormatted: String?
    private let deferred: (@Sendable () throws -> String)?
    var rootLabel: String
    init(value: Any, formatted: String, rootLabel: String = "$") {
        self.value = value; eagerFormatted = formatted; deferred = nil; self.rootLabel = rootLabel
    }
    init(frames: [CapturedEventFrame]) {
        value = frames.map { $0 as Any }; eagerFormatted = nil; rootLabel = "Server-sent events"
        deferred = {
            var result = "Server-sent events · formatted view of retained frames\n\n"
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                if index > 0 { result += "\n\n" }
                result += frame.formatted
            }
            return result
        }
    }
    var formatted: String { (try? render()) ?? "" }
    func render() throws -> String { try eagerFormatted ?? deferred?() ?? "" }
}

/// One immutable byte buffer plus byte ranges. Only derived frames that a reader
/// actually asks for enter the bounded cache. Never stores a second full stream.
final class CapturedEventStorage: @unchecked Sendable {
    let bytes: Data
    let cacheLimit: Int
    private let lock = NSLock()
    private var cache: [Int: (CapturedEventContent, Int)] = [:]
    private var order: [Int] = []
    private var cost = 0
    private var parsed = 0
    init(bytes: Data, cacheLimit: Int = 4 * 1_024 * 1_024) { self.bytes = bytes; self.cacheLimit = cacheLimit }
    var cachedBytes: Int { lock.lock(); defer { lock.unlock() }; return cost }
    var parsedFrames: Int { lock.lock(); defer { lock.unlock() }; return parsed }
    func cached(_ index: Int) -> CapturedEventContent? {
        lock.lock(); defer { lock.unlock() }; return cache[index]?.0
    }
    func content(for frame: CapturedEventFrame) -> CapturedEventContent {
        if let value = cached(frame.number) { return value }
        let fields = frame.lines.map { String(decoding: bytes[$0], as: UTF8.self) }
        let data = frame.dataLines.isEmpty ? nil : frame.dataLines.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "\n")
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        let value = CapturedEventContent(fields: fields, data: data, json: json)
        // Account conservatively for strings, Foundation containers and nodes,
        // not just source bytes. Oversized visible frames are never cache entries.
        let charge = frame.lines.reduce(256) { $0 + $1.count * 12 + 64 }
        lock.lock(); defer { lock.unlock() }
        parsed += 1
        if charge <= cacheLimit, cache[frame.number] == nil {
            while cost + charge > cacheLimit, !order.isEmpty {
                if let removed = cache.removeValue(forKey: order.removeFirst()) { cost -= removed.1 }
            }
            cache[frame.number] = (value, charge); order.append(frame.number); cost += charge
        }
        return value
    }
}
struct CapturedEventContent: @unchecked Sendable {
    let fields: [String]
    let data: String?
    let json: Any?
    var formattedData: String? {
        json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

struct CapturedEventFrame: Sendable {
    let number: Int
    let storage: CapturedEventStorage
    let lines: [Range<Int>]
    let dataLines: [Range<Int>]
    let event: String?
    let terminated: Bool
    var content: CapturedEventContent { storage.content(for: self) }
    var fields: [String] { content.fields }
    var data: String? { content.data }
    var json: Any? { content.json }
    var formattedData: String? { content.formattedData }
    var initialLabel: String { "\(number) · " + (event?.isEmpty == false ? event! : (dataLines.isEmpty ? "SSE fields" : "message")) }
    var name: String { name(content) }
    func name(_ content: CapturedEventContent) -> String {
        if let event, !event.isEmpty { return event }
        if let type = (content.json as? [String: Any])?["type"] as? String, !type.isEmpty { return type }
        if content.data == "[DONE]" { return "[DONE]" }
        return content.data == nil ? "SSE fields" : "message"
    }
    var label: String { "\(number) · \(name)" }
    var summary: String { summary(content) }
    func summary(_ value: CapturedEventContent) -> String {
        let type = value.json != nil ? "JSON data" : value.data == "[DONE]" ? "Stream sentinel" : value.data == nil ? "No data" : "Non-JSON data"
        return type + (terminated ? "" : " · unfinished frame")
    }
    var count: Int { dataLines.isEmpty ? 2 : 3 }
    func entry(_ index: Int, prepared: CapturedEventContent? = nil) -> (String, Any) {
        let value = prepared ?? content
        if let data = value.data, index == 0 { return ("data", value.json ?? data) }
        let index = value.data == nil ? index : index - 1
        return index == 0 ? ("SSE fields", value.fields) : ("frame", terminated ? "Terminated by an empty line" : "Retained bytes end before the frame terminator")
    }
    var formatted: String {
        let value = content
        var result = "Event \(number) · \(name(value)) — \(summary(value))\nSSE fields:\n" + value.fields.joined(separator: "\n")
        if let pretty = value.formattedData { result += "\n\nFormatted data:\n" + pretty }
        return result
    }
    /// A cheap candidate check. The demand-driven combiner validates the actual
    /// JSON type before exposing a reconstructed response.
    var mightBeResponseEvent: Bool {
        if let event { return event.hasPrefix("response.") }
        return dataLines.contains { storage.bytes.range(of: Data("response.".utf8), in: $0) != nil }
    }
}

struct CapturedEventStream: Sendable {
    let frames: [CapturedEventFrame]
    let outline: CapturedJSON
    let storage: CapturedEventStorage
    init(frames: [CapturedEventFrame], outline: CapturedJSON, storage: CapturedEventStorage? = nil) {
        self.frames = frames; self.outline = outline
        self.storage = storage ?? frames.first?.storage ?? CapturedEventStorage(bytes: Data())
    }
    static func parse(_ bytes: Data) throws -> Self? {
        guard String(data: bytes, encoding: .utf8) != nil else { return nil }
        let storage = CapturedEventStorage(bytes: bytes)
        var frames: [CapturedEventFrame] = [], lines: [Range<Int>] = [], dataLines: [Range<Int>] = []
        var event: String?, hasSSEField = false
        func appendFrame(_ terminated: Bool) throws {
            guard !lines.isEmpty else { return }
            try Task.checkCancellation()
            frames.append(CapturedEventFrame(number: frames.count + 1, storage: storage, lines: lines, dataLines: dataLines, event: event, terminated: terminated))
            lines.removeAll(keepingCapacity: true); dataLines.removeAll(keepingCapacity: true); event = nil
        }
        try bytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            func appendLine(_ range: Range<Int>) {
                lines.append(range)
                if buffer[range.lowerBound] == 58 { hasSSEField = true; return }
                var separator = range.lowerBound
                while separator < range.upperBound, buffer[separator] != 58 { separator += 1 }
                let name = String(decoding: UnsafeBufferPointer(rebasing: buffer[range.lowerBound..<separator]), as: UTF8.self)
                var start = min(separator + 1, range.upperBound)
                if start < range.upperBound, buffer[start] == 32 { start += 1 }
                switch name {
                case "data": dataLines.append(start..<range.upperBound); hasSSEField = true
                case "event": event = String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<range.upperBound]), as: UTF8.self); hasSSEField = true
                case "id", "retry": hasSSEField = true
                default: break
                }
            }
            var start = buffer.count >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf ? 3 : 0
            var cursor = start, check = start
            while cursor < buffer.count {
                if cursor >= check { try Task.checkCancellation(); check = cursor + 32_768 }
                let byte = buffer[cursor]
                guard byte == 10 || byte == 13 else { cursor += 1; continue }
                if cursor == start { try appendFrame(true) } else { appendLine(start..<cursor) }
                if byte == 13, cursor + 1 < buffer.count, buffer[cursor + 1] == 10 { cursor += 1 }
                cursor += 1; start = cursor
            }
            if start < buffer.count { appendLine(start..<buffer.count) }
            try appendFrame(false)
        }
        guard hasSSEField, !frames.isEmpty else { return nil }
        return Self(frames: frames, outline: CapturedJSON(frames: frames), storage: storage)
    }
}
