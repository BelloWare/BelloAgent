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
    private var storedSegments: [Segment] = []
    public var segments: [Segment] {
        get { storedSegments }
        set { storedSegments = newValue; reconciliation = nil }
        _modify { reconciliation = nil; yield &storedSegments }
    }
    public var coverage: String = "observed"
    public var omittedEvents = 0
    public var terminal: String?
    private enum CodingKeys: String, CodingKey {
        case version, storedSegments = "segments", coverage, omittedEvents, terminal
    }
    private struct CorrectionKey: Hashable, Sendable {
        let attempt: String, part: String
    }
    /// Derived lookups never travel in saved/display timelines. External edits
    /// invalidate them; decoding and canonical construction build them lazily.
    private struct ReconciliationIndex: Sendable {
        struct Part: Sendable {
            let first: Int
            var text = ""
        }
        var parts: [String: Part] = [:]
        var corrections: [CorrectionKey: Int] = [:]
        var streaming: [String: Set<Int>] = [:]
        mutating func insert(_ segment: Segment, at index: Int, key: String) {
            parts[key, default: Part(first:index)].text += segment.text
            if segment.state == "streaming" { streaming[key, default: []].insert(index) }
            if segment.part.kind == "correction", let reconciles = segment.part.reconcilesPartKey {
                corrections[CorrectionKey(attempt:segment.part.attemptID,part:reconciles)] = index
            }
        }
    }
    private var reconciliation: ReconciliationIndex?
    public init() {}
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.storedSegments == rhs.storedSegments &&
            lhs.coverage == rhs.coverage && lhs.omittedEvents == rhs.omittedEvents && lhs.terminal == rhs.terminal
    }
    private mutating func indexSegments() {
        guard reconciliation == nil else { return }
        var index = ReconciliationIndex()
        for (offset, segment) in storedSegments.enumerated() {
            index.insert(segment,at:offset,key:segment.part.partKey)
        }
        reconciliation = index
    }
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
        indexSegments()
        let key = event.partKey
        if event.update == "end" {
            let opened = reconciliation!.streaming.removeValue(forKey:key) ?? []
            for index in opened {
                storedSegments[index].state = "completed"; storedSegments[index].revision += 1
            }
            // A second `.done` for a part already closed changes nothing.
            return !opened.isEmpty
        }
        if event.update == "replace" {
            if let corrected = reconciliation!.corrections[CorrectionKey(attempt:event.attemptID,part:key)],
               storedSegments[corrected].text == event.text { return false }
            if let existing = reconciliation!.parts[key] {
                if existing.text == event.text { return false }
                if existing.text.isEmpty {
                    let index = existing.first
                    storedSegments[index].text=event.text
                    storedSegments[index].truncated=false
                    storedSegments[index].state="completed"; storedSegments[index].revision += 1
                    reconciliation!.parts[key]?.text = event.text
                    reconciliation!.streaming[key]?.remove(index)
                    return true
                }
                var correction = event; correction.kind = "correction"; correction.update = "begin"
                correction.evidence = "terminal-correction"; correction.reconcilesPartKey = key
                return consume(correction)
            }
        }
        if event.update == "begin", reconciliation!.parts[key] != nil, event.text.isEmpty { return false }
        if event.update == "append", event.text.isEmpty { return false }
        if let index = storedSegments.indices.last, storedSegments[index].part.partKey == key,
           storedSegments[index].state == "streaming", event.update == "append" {
            storedSegments[index].text += event.text
            storedSegments[index].revision += 1
            reconciliation!.parts[key]?.text += event.text
            return true
        }
        // A continuation is a new segment. The earlier native text owner no
        // longer has a streaming caret, even while its provider part is open.
        if let last = storedSegments.indices.last, storedSegments[last].state == "streaming" {
            storedSegments[last].state = "continued"; storedSegments[last].revision += 1
            reconciliation!.streaming[storedSegments[last].part.partKey]?.remove(last)
        }
        var metadata = event; metadata.text = ""
        let segment = Segment(id: "\(event.attemptID):\(event.ordinal)", part: metadata, text: event.text,
                              state: event.update == "replace" ? "completed" : "streaming")
        reconciliation!.insert(segment,at:storedSegments.count,key:key)
        storedSegments.append(segment)
        if event.evidence != "observed", coverage == "observed" { coverage = event.evidence }
        return true
    }
    public mutating func finish(_ outcome: String) {
        terminal = outcome
        for index in storedSegments.indices where storedSegments[index].state == "streaming" { storedSegments[index].state = outcome; storedSegments[index].revision += 1 }
        reconciliation = nil
    }
    /// Display pagination limits how many rows travel together, never the
    /// content of an individual response. Large results use chunked IPC.
    public func projected() -> Self {
        var result = self
        result.reconciliation = nil
        return result
    }

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
        let attemptID="canonical:"+sourceID
        // Each canonical part has a distinct output index and is complete;
        // no streaming reconciliation or search through earlier parts is needed.
        result.segments=parts.enumerated().map { index, part in
            let metadata=ResponsePartEvent(attemptID:attemptID,ordinal:index,itemID:"part-\(index)",outputIndex:index,partIndex:0,kind:part.kind,update:"replace",text:"",callID:part.callID,name:part.name,evidence:"canonical")
            return Segment(id:"\(attemptID):\(index)",part:metadata,text:part.text,state:"completed")
        }
        result.terminal="completed"; return result
    }
}
