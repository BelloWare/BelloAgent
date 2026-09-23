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
    public init() {}
    public var supported: Bool {
        version == 1 && omittedEvents >= 0 &&
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
            var ended = false
            for index in segments.indices where segments[index].part.partKey == event.partKey && segments[index].state == "streaming" {
                segments[index].state = "completed"; segments[index].revision += 1; ended = true
            }
            // A second `.done` for a part already closed changes nothing.
            return ended
        }
        if event.update == "replace" {
            if let corrected=segments.last(where: { $0.part.kind == "correction" && $0.part.attemptID == event.attemptID && $0.part.reconcilesPartKey == event.partKey }), corrected.text == event.text { return false }
            let existing = segments.filter { $0.part.partKey == event.partKey }
            if !existing.isEmpty, existing.map(\.text).joined() == event.text { return false }
            if let index = segments.firstIndex(where: { $0.part.partKey == event.partKey }), existing.allSatisfy({ $0.text.isEmpty }) {
                segments[index].text=event.text
                segments[index].truncated=false
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
            segments[index].text += event.text
            segments[index].revision += 1
            return true
        }
        // A continuation is a new segment. The earlier native text owner no
        // longer has a streaming caret, even while its provider part is open.
        if let last = segments.indices.last, segments[last].state == "streaming" { segments[last].state = "continued"; segments[last].revision += 1 }
        var metadata = event; metadata.text = ""
        segments.append(Segment(id: "\(event.attemptID):\(event.ordinal)", part: metadata,
                                text: event.text,
                                state: event.update == "replace" ? "completed" : "streaming"))
        if event.evidence != "observed", coverage == "observed" { coverage = event.evidence }
        return true
    }
    public mutating func finish(_ outcome: String) {
        terminal = outcome
        for index in segments.indices where segments[index].state == "streaming" { segments[index].state = outcome; segments[index].revision += 1 }
    }
    /// Display pagination limits how many rows travel together, never the
    /// content of an individual response. Large results use chunked IPC.
    public func projected() -> Self { self }

    /// Older builds saved shortened timeline parts but kept the full message.
    /// Recover canonical order without inventing the lost arrival chronology.
    public func restoringContent(_ parts: [(kind:String,text:String,callID:String?,name:String?)], sourceID:String) -> Self {
        guard omittedEvents > 0 || segments.contains(where: \.truncated), !parts.isEmpty else { return self }
        var restored = Self.canonical(parts, sourceID: sourceID)
        restored.terminal = terminal
        return restored
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
