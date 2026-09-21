import Foundation

/// Display evidence only. Neither this schema nor its ordinals authorize
/// execution or participate in provider replay/context construction.
public struct ResponsePartEvent: Codable, Equatable, Sendable {
    public var attemptID: String
    public var ordinal: Int
    public var itemID: String
    public var outputIndex: Int?
    public var partIndex: Int?
    public var providerSequence: Int?
    public var kind: String
    public var update: String
    public var text: String
    public var callID: String?
    public var name: String?
    public var observedAt: Double?
    public var evidence: String = "observed"
    public var sessionOrdinal: Int? = nil
    public var reconcilesPartKey: String? = nil
    public var partKey: String { "\(attemptID):\(outputIndex.map(String.init) ?? itemID):\(kind):\(partIndex ?? -1)" }
}

public struct ResponseTimeline: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var part: ResponsePartEvent
        public var text: String
        public var state: String = "streaming"
        public var truncated: Bool = false
        public var revision: Int = 0
    }
    public var version = 1
    public var segments: [Segment] = []
    public var coverage: String = "observed"
    public var omittedEvents = 0
    public var terminal: String?
    private var lastOmittedPart: String?
    public init() {}
    public static let maximumSegments = 64, segmentBytes = 16384
    public var supported: Bool {
        version == 1 && segments.count <= Self.maximumSegments && omittedEvents >= 0 &&
            Set(segments.map(\.id)).count == segments.count &&
            segments.allSatisfy { !$0.id.isEmpty && $0.part.ordinal >= 0 && $0.revision >= 0 }
    }
    public static func prefix(_ text: String, bytes: Int) -> String {
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: min(max(0, bytes), text.utf8.count))
        while end != text.utf8.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }
    /// Coalesce only adjacent contributions. A/B/A becomes three stable
    /// segments. End/usage events never move an already displayed segment.
    @discardableResult public mutating func consume(_ event: ResponsePartEvent) -> Bool {
        if event.update == "end" {
            for index in segments.indices where segments[index].part.partKey == event.partKey && segments[index].state == "streaming" {
                segments[index].state = "completed"; segments[index].revision += 1
            }
            return true
        }
        if event.update == "replace" {
            if let corrected=segments.last(where: { $0.part.kind == "correction" && $0.part.attemptID == event.attemptID && $0.part.reconcilesPartKey == event.partKey }), corrected.text == event.text { return false }
            let existing = segments.filter { $0.part.partKey == event.partKey }
            if !existing.isEmpty, existing.contains(where: \.truncated) || existing.map(\.text).joined() == event.text { return false }
            if let index = segments.firstIndex(where: { $0.part.partKey == event.partKey }), existing.allSatisfy({ $0.text.isEmpty }) {
                segments[index].text=Self.prefix(event.text,bytes:Self.segmentBytes)
                segments[index].truncated=event.text.utf8.count > Self.segmentBytes
                segments[index].state="completed"; segments[index].revision += 1
                return true
            }
            if !existing.isEmpty {
                var correction = event; correction.kind = "correction"; correction.update = "begin"
                correction.evidence = "terminal-correction"; correction.reconcilesPartKey = event.partKey
                return consume(correction)
            }
        }
        if event.update == "begin", segments.contains(where: { $0.part.partKey == event.partKey }), event.text.isEmpty { return false }
        if event.update == "append", event.text.isEmpty { return false }
        if let index = segments.indices.last, segments[index].part.partKey == event.partKey,
           segments[index].state == "streaming", event.update == "append" {
            let room = max(0, Self.segmentBytes - segments[index].text.utf8.count)
            if room == 0 && segments[index].truncated { return false }
            segments[index].text += Self.prefix(event.text, bytes: room)
            segments[index].truncated = segments[index].truncated || event.text.utf8.count > room
            segments[index].revision += 1
            return true
        }
        guard segments.count < Self.maximumSegments else {
            guard lastOmittedPart != event.partKey else { return false }
            lastOmittedPart = event.partKey; omittedEvents += 1; coverage = "partial"; return true
        }
        // A continuation is a new segment. The earlier native text owner no
        // longer has a streaming caret, even while its provider part is open.
        if let last = segments.indices.last, segments[last].state == "streaming" { segments[last].state = "continued"; segments[last].revision += 1 }
        var metadata = event; metadata.text = ""
        segments.append(Segment(id: "\(event.attemptID):\(event.ordinal)", part: metadata,
                                text: Self.prefix(event.text, bytes: Self.segmentBytes),
                                state: event.update == "replace" ? "completed" : "streaming",
                                truncated: event.text.utf8.count > Self.segmentBytes))
        if event.evidence != "observed", coverage == "observed" { coverage = event.evidence }
        return true
    }
    public mutating func finish(_ outcome: String) {
        terminal = outcome
        for index in segments.indices where segments[index].state == "streaming" { segments[index].state = outcome; segments[index].revision += 1 }
    }
    /// Fixed per-ordinal allowances: a new part cannot shrink an already
    /// displayed prefix. Reserve room for later parts and bound JSON escaping.
    public func projected(bytes: Int = 32768) -> Self {
        var result = self
        if result.segments.count > Self.maximumSegments {
            result.omittedEvents += result.segments.count - Self.maximumSegments
            result.segments = Array(result.segments.prefix(Self.maximumSegments)); result.coverage = "partial"
        }
        for index in result.segments.indices {
            let text = result.segments[index].text
            let cap = index == 0 ? min(16384,bytes / 2) : index < 8 ? 2048 : 128
            var size = 2, kept = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                let cost = scalar.value < 32 ? 6 : [34,47,92].contains(scalar.value) ? 2 : String(scalar).utf8.count
                if size + cost > cap { break }; size += cost; kept.append(scalar)
            }
            result.segments[index].text = String(kept)
            result.segments[index].truncated = result.segments[index].truncated || result.segments[index].text.utf8.count < text.utf8.count
        }
        return result
    }
    /// Retained evidence for copy/export. Truncation remains explicit even
    /// when request capture is disabled or expired; this never invents a tail.
    public var retainedText: String {
        var lines = ["Timeline evidence: \(coverage)"]
        for part in segments {
            let identity = "\(part.part.attemptID) / \(part.part.itemID) / \(part.part.partIndex ?? 0)"
            lines.append("[\(part.part.kind) · \(identity) · \(part.part.evidence)]\n" + part.text + (part.truncated ? "\n[Retained preview truncated]" : ""))
        }
        if omittedEvents > 0 { lines.append("[Partial coverage: \(omittedEvents) additional events omitted]") }
        lines.append("[\(terminal ?? "No terminal receipt")]")
        return lines.joined(separator: "\n\n")
    }
    public static func canonical(_ parts: [(kind:String,text:String,callID:String?,name:String?)], sourceID:String) -> Self {
        var result = ResponseTimeline(); result.coverage="canonical"
        for (index,part) in parts.enumerated() {
            result.consume(ResponsePartEvent(attemptID:"canonical:"+sourceID,ordinal:index,itemID:"part-\(index)",outputIndex:index,partIndex:0,kind:part.kind,update:"replace",text:part.text,callID:part.callID,name:part.name,evidence:"canonical"))
        }
        result.finish("completed"); return result
    }
}
