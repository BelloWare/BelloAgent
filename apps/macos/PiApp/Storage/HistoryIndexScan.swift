import Foundation

/// Reads the fields `HistoryReader.IndexRecord` keeps from one journal line without
/// decoding the rest of it. The whole line is validated as strict JSON: the
/// RFC 8259 grammar, UTF-8, escapes and surrogate pairs, at any depth this
/// reader accepts. Only the index's own fields become values; a long reply
/// or tool output is validated and skipped.
///
/// Answers nil for every line it does not read exactly as `JSONDecoder`
/// decodes `HistoryReader.IndexRecord`: a byte-order mark or other encoding, a
/// duplicate, escaped or non-ASCII key where a field is looked up, an escape
/// in a kept string, a number or shape that is not the plain one, edit,
/// run-state and fork-boundary records, compaction checkpoints, and anything
/// `JSONDecoder` would reject. The caller decodes those lines as before, so
/// what is accepted, rejected and indexed is unchanged.
enum HistoryIndexScan {
    static func record(_ line: UnsafeRawBufferPointer) -> HistoryReader.IndexRecord? {
        guard let base = line.baseAddress?.assumingMemoryBound(to: UInt8.self), line.count > 0 else { return nil }
        var reader = Reader(p: base, n: line.count)
        return reader.record()
    }

    /// Deeper values are left to `JSONDecoder`, whose own limit is 512.
    static let maximumDepth = 64

    fileprivate struct Field { var start = 0, end = 0, present = false, null = false }

    fileprivate struct Reader {
        let p: UnsafePointer<UInt8>
        let n: Int
        var i = 0

        // MARK: Grammar

        @inline(__always) mutating func ws() {
            while i < n {
                let b = p[i]
                guard b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 else { return }
                i += 1
            }
        }
        /// Any byte that needs a look: a quote, a backslash, a control
        /// character or a byte of a multi-byte character.
        @inline(__always) static func special(_ w: UInt64) -> Bool {
            let ones: UInt64 = 0x0101_0101_0101_0101, high: UInt64 = 0x8080_8080_8080_8080
            let quote = w ^ (ones &* 0x22), slash = w ^ (ones &* 0x5C)
            let control = (w &- ones &* 0x20) & ~w
            let quoted = (quote &- ones) & ~quote, escaped = (slash &- ones) & ~slash
            return (w | control | quoted | escaped) & high != 0
        }
        /// A string at `i`; the bytes between its quotes, and whether it
        /// held an escape. Nil for anything but a valid JSON string.
        mutating func string() -> (start: Int, end: Int, plain: Bool)? {
            guard i < n, p[i] == 0x22 else { return nil }
            i += 1
            let start = i
            var plain = true
            while true {
                while i + 8 <= n, !Self.special(UnsafeRawPointer(p + i).loadUnaligned(as: UInt64.self)) { i += 8 }
                guard i < n else { return nil }
                let b = p[i]
                if b == 0x22 { i += 1; return (start, i - 1, plain) }
                if b == 0x5C { plain = false; guard escape() else { return nil }; continue }
                if b < 0x20 { return nil }
                if b < 0x80 { i += 1; continue }
                guard character() else { return nil }
            }
        }
        @inline(__always) func hex(_ at: Int) -> UInt32? {
            guard at + 4 <= n else { return nil }
            var value: UInt32 = 0
            for k in 0..<4 {
                let b = p[at + k]
                let digit: UInt8
                switch b {
                case 0x30...0x39: digit = b - 0x30
                case 0x41...0x46: digit = b - 0x37
                case 0x61...0x66: digit = b - 0x57
                default: return nil
                }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        /// An escape at `i`, including both halves of a surrogate pair. A
        /// lone or reversed surrogate is rejected: `JSONDecoder` cannot
        /// decode such a string.
        mutating func escape() -> Bool {
            guard i + 1 < n else { return false }
            switch p[i + 1] {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: i += 2; return true
            case 0x75:
                guard let unit = hex(i + 2) else { return false }
                i += 6
                if unit >= 0xDC00 && unit <= 0xDFFF { return false }
                guard unit >= 0xD800 && unit <= 0xDBFF else { return true }
                guard i + 1 < n, p[i] == 0x5C, p[i + 1] == 0x75, let low = hex(i + 2), low >= 0xDC00 && low <= 0xDFFF else { return false }
                i += 6
                return true
            default: return false
            }
        }
        /// One multi-byte UTF-8 character at `i` (Unicode table 3-7).
        mutating func character() -> Bool {
            let b = p[i]
            @inline(__always) func tail(_ at: Int) -> Bool { at < n && p[at] & 0xC0 == 0x80 }
            @inline(__always) func within(_ at: Int, _ low: UInt8, _ high: UInt8) -> Bool { at < n && p[at] >= low && p[at] <= high }
            switch b {
            case 0xC2...0xDF: guard tail(i + 1) else { return false }; i += 2
            case 0xE0: guard within(i + 1, 0xA0, 0xBF), tail(i + 2) else { return false }; i += 3
            case 0xE1...0xEC, 0xEE, 0xEF: guard tail(i + 1), tail(i + 2) else { return false }; i += 3
            case 0xED: guard within(i + 1, 0x80, 0x9F), tail(i + 2) else { return false }; i += 3
            case 0xF0: guard within(i + 1, 0x90, 0xBF), tail(i + 2), tail(i + 3) else { return false }; i += 4
            case 0xF1...0xF3: guard tail(i + 1), tail(i + 2), tail(i + 3) else { return false }; i += 4
            case 0xF4: guard within(i + 1, 0x80, 0x8F), tail(i + 2), tail(i + 3) else { return false }; i += 4
            default: return false
            }
            return true
        }
        @inline(__always) func digit(_ at: Int) -> Bool { at < n && p[at] >= 0x30 && p[at] <= 0x39 }
        /// A number in the RFC 8259 grammar.
        mutating func number() -> Bool {
            if i < n, p[i] == 0x2D { i += 1 }
            guard i < n else { return false }
            if p[i] == 0x30 { i += 1 }
            else if p[i] >= 0x31 && p[i] <= 0x39 { i += 1; while digit(i) { i += 1 } }
            else { return false }
            if i < n, p[i] == 0x2E {
                i += 1; guard digit(i) else { return false }
                while digit(i) { i += 1 }
            }
            if i < n, p[i] == 0x65 || p[i] == 0x45 {
                i += 1
                if i < n, p[i] == 0x2B || p[i] == 0x2D { i += 1 }
                guard digit(i) else { return false }
                while digit(i) { i += 1 }
            }
            return true
        }
        @inline(__always) mutating func literal(_ text: StaticString) -> Bool {
            let count = text.utf8CodeUnitCount
            guard i + count <= n, memcmp(p + i, text.utf8Start, count) == 0 else { return false }
            i += count
            return true
        }
        @inline(__always) mutating func null() -> Bool { i < n && p[i] == 0x6E && literal("null") }
        /// Any valid JSON value at `i`, skipped.
        mutating func value(_ depth: Int) -> Bool {
            guard i < n else { return false }
            switch p[i] {
            case 0x22: return string() != nil
            case 0x7B:
                guard depth < HistoryIndexScan.maximumDepth else { return false }
                i += 1; ws()
                if i < n, p[i] == 0x7D { i += 1; return true }
                while true {
                    guard string() != nil else { return false }
                    ws(); guard i < n, p[i] == 0x3A else { return false }
                    i += 1; ws()
                    guard value(depth + 1) else { return false }
                    ws(); guard i < n else { return false }
                    if p[i] == 0x2C { i += 1; ws(); continue }
                    guard p[i] == 0x7D else { return false }
                    i += 1; return true
                }
            case 0x5B:
                guard depth < HistoryIndexScan.maximumDepth else { return false }
                i += 1; ws()
                if i < n, p[i] == 0x5D { i += 1; return true }
                while true {
                    guard value(depth + 1) else { return false }
                    ws(); guard i < n else { return false }
                    if p[i] == 0x2C { i += 1; ws(); continue }
                    guard p[i] == 0x5D else { return false }
                    i += 1; return true
                }
            case 0x74: return literal("true")
            case 0x66: return literal("false")
            case 0x6E: return literal("null")
            case 0x2D, 0x30...0x39: return number()
            default: return false
            }
        }

        // MARK: Fields

        /// The members of the object at `i`, each key handed to `member`
        /// with `i` at its value; `member` reads or skips the value. A key
        /// that needs decoding (an escape, a byte outside printable ASCII)
        /// answers false: `JSONDecoder` compares keys as decoded strings.
        @inline(__always) mutating func members(_ depth: Int, _ member: (inout Reader, Int, Int) -> Bool) -> Bool {
            guard depth < HistoryIndexScan.maximumDepth, i < n, p[i] == 0x7B else { return false }
            i += 1; ws()
            if i < n, p[i] == 0x7D { i += 1; return true }
            while true {
                guard let key = string(), key.plain else { return false }
                for k in key.start..<key.end where p[k] < 0x20 || p[k] > 0x7E { return false }
                ws(); guard i < n, p[i] == 0x3A else { return false }
                i += 1; ws()
                guard member(&self, key.start, key.end) else { return false }
                ws(); guard i < n else { return false }
                if p[i] == 0x2C { i += 1; ws(); continue }
                guard p[i] == 0x7D else { return false }
                i += 1; return true
            }
        }
        @inline(__always) func key(_ start: Int, _ end: Int, _ name: StaticString) -> Bool {
            end - start == name.utf8CodeUnitCount && memcmp(p + start, name.utf8Start, end - start) == 0
        }
        /// An optional string field (`decodeIfPresent(String.self)`): a
        /// string without escapes, or null. Anything else is left to
        /// `JSONDecoder`, which rejects a wrong type.
        mutating func optionalString(_ field: inout Field) -> Bool {
            guard !field.present else { return false }
            field.present = true
            if null() { field.null = true; return true }
            guard let text = string(), text.plain else { return false }
            field.start = text.start; field.end = text.end
            return true
        }
        func text(_ field: Field) -> String? {
            guard field.present, !field.null else { return nil }
            return String(decoding: UnsafeBufferPointer(start: p + field.start, count: field.end - field.start), as: UTF8.self)
        }
        /// `decodeIfPresent([String].self)`: plain strings, or null.
        mutating func optionalStrings(_ present: inout Bool, _ result: inout [String]?, _ depth: Int) -> Bool {
            guard !present else { return false }
            present = true
            if null() { return true }
            guard depth < HistoryIndexScan.maximumDepth, i < n, p[i] == 0x5B else { return false }
            i += 1; ws()
            var values: [String] = []
            if i < n, p[i] == 0x5D { i += 1; result = values; return true }
            while true {
                guard let text = string(), text.plain else { return false }
                values.append(String(decoding: UnsafeBufferPointer(start: p + text.start, count: text.end - text.start), as: UTF8.self))
                ws(); guard i < n else { return false }
                if p[i] == 0x2C { i += 1; ws(); continue }
                guard p[i] == 0x5D else { return false }
                i += 1; result = values; return true
            }
        }
        /// `decodeIfPresent(Int.self)`: a plain integer of at most 18
        /// digits, or null. Other forms `JSONDecoder` converts or rejects.
        mutating func optionalInt(_ present: inout Bool, _ result: inout Int?) -> Bool {
            guard !present else { return false }
            present = true
            if null() { return true }
            let start = i
            var negative = false
            if i < n, p[i] == 0x2D { negative = true; i += 1 }
            let digits = i
            guard i < n, p[i] >= 0x31 && p[i] <= 0x39 || p[i] == 0x30 && !negative && !digit(i + 1) else { return false }
            var value = 0
            while digit(i) {
                // Longer numbers are left to `JSONDecoder` before they overflow.
                guard i - digits < 18 else { return false }
                value = value * 10 + Int(p[i] - 0x30); i += 1
            }
            guard i < n, p[i] != 0x2E && p[i] != 0x65 && p[i] != 0x45, i > start else { return false }
            result = negative ? -value : value
            return true
        }
        /// `decodeIfPresent(Bool.self)`.
        mutating func optionalBool(_ present: inout Bool, _ result: inout Bool?) -> Bool {
            guard !present else { return false }
            present = true
            if null() { return true }
            if literal("true") { result = true; return true }
            if literal("false") { result = false; return true }
            return false
        }

        // MARK: Records

        mutating func record() -> HistoryReader.IndexRecord? {
            var type = Field(), id = Field(), parent = Field(), from = Field(), custom = Field(), data = Field()
            var keptIdsPresent = false, keptIds: [String]? = nil, nativeKeptPresent = false, nativeKeptIDs: [String]? = nil
            var versionPresent = false, version: Int? = nil, compactionVersionPresent = false, compactionVersion: Int? = nil
            var messagePresent = false, message: HistoryReader.IndexRecord.MessageRole? = nil, compactionPresent = false
            ws()
            guard i < n, p[i] == 0x7B else { return nil }
            let read = members(0) { reader, start, end in
                switch end - start {
                case 2 where reader.key(start, end, "id"): return reader.optionalString(&id)
                case 4 where reader.key(start, end, "type"): return reader.optionalString(&type)
                case 4 where reader.key(start, end, "data"):
                    guard !data.present else { return false }
                    data.present = true; data.start = reader.i
                    guard reader.value(1) else { return false }
                    data.end = reader.i; return true
                case 7 where reader.key(start, end, "keptIds"): return reader.optionalStrings(&keptIdsPresent, &keptIds, 1)
                case 7 where reader.key(start, end, "version"): return reader.optionalInt(&versionPresent, &version)
                case 7 where reader.key(start, end, "message"):
                    guard !messagePresent else { return false }
                    messagePresent = true
                    if reader.null() { return true }
                    guard let role = reader.message(1) else { return false }
                    message = role; return true
                case 8 where reader.key(start, end, "parentId"): return reader.optionalString(&parent)
                case 10 where reader.key(start, end, "customType"): return reader.optionalString(&custom)
                case 13 where reader.key(start, end, "fromMessageId"): return reader.optionalString(&from)
                case 13 where reader.key(start, end, "nativeKeptIDs"): return reader.optionalStrings(&nativeKeptPresent, &nativeKeptIDs, 1)
                case 16 where reader.key(start, end, "nativeCompaction"):
                    // A compaction checkpoint is decoded by `JSONDecoder`.
                    guard !compactionPresent else { return false }
                    compactionPresent = true
                    return reader.null()
                case 23 where reader.key(start, end, "nativeCompactionVersion"): return reader.optionalInt(&compactionVersionPresent, &compactionVersion)
                default: return reader.value(1)
                }
            }
            guard read else { return nil }
            ws()
            guard i == n else { return nil }
            let typeText = text(type), customText = text(custom)
            // Edits, run state and fork boundaries are decoded in full.
            if typeText == "branch" || customText == "pi-app.native.state.v1" || customText == "pi-app.native.context.v1" { return nil }
            var target: String?, task: TaskPresentationRecord?
            if customText == "pi-app.presentation.update.v1" {
                guard data.present, !data.null else { return nil }
                var fields = Reader(p: p, n: data.end, i: data.start)
                var targetID = Field()
                let read = fields.members(1) { reader, start, end in
                    if reader.key(start, end, "id") { return reader.optionalString(&targetID) }
                    return reader.value(2)
                }
                guard read, let value = fields.text(targetID) else { return nil }
                target = value
            } else if customText == "pi-app.task-terminal.v1" {
                guard data.present, p[data.start] == 0x7B else { return nil }
                let bytes = Data(bytes: p + data.start, count: data.end - data.start)
                guard let value = try? JSONDecoder().decode(TaskPresentationRecord.self, from: bytes), value.valid, value.terminal else { return nil }
                task = value
            }
            return HistoryReader.IndexRecord(type: typeText, id: text(id), parentId: text(parent), fromMessageId: text(from), keptIds: keptIds, nativeKeptIDs: nativeKeptIDs,
                                      version: version, customType: customText, nativeCompactionVersion: compactionVersion, message: message,
                                      presentationTarget: target, taskTerminal: task)
        }

        /// A record's `message` object, as `HistoryReader.IndexRecord.MessageRole`
        /// decodes it.
        mutating func message(_ depth: Int) -> HistoryReader.IndexRecord.MessageRole? {
            var role = Field(), toolCallId = Field(), kind = Field(), operation = Field(), execution = Field(), root = Field()
            var rootOther = false, eligiblePresent = false, eligible: Bool? = nil, compactionPresent = false
            var deliveryPresent = false, delivery = false, contentPresent = false, contentIndexed = false
            var calls: [String] = []
            let read = members(depth) { reader, start, end in
                switch end - start {
                case 4 where reader.key(start, end, "role"): return reader.optionalString(&role)
                case 7 where reader.key(start, end, "content"):
                    guard !contentPresent else { return false }
                    contentPresent = true
                    guard reader.i < reader.n else { return false }
                    switch reader.p[reader.i] {
                    case 0x22: guard reader.string() != nil else { return false }; contentIndexed = true; return true
                    case 0x6E: return reader.null()
                    case 0x5B:
                        guard let found = reader.blocks(depth + 1) else { return false }
                        calls = found; contentIndexed = true; return true
                    default: return false
                    }
                case 10 where reader.key(start, end, "toolCallId"): return reader.optionalString(&toolCallId)
                case 10 where reader.key(start, end, "nativeKind"): return reader.optionalString(&kind)
                case 14 where reader.key(start, end, "nativeTaskRoot"):
                    // Read only when the execution is present: keep its shape.
                    guard !root.present, !rootOther else { return false }
                    if reader.i < reader.n, reader.p[reader.i] == 0x22 || reader.p[reader.i] == 0x6E { return reader.optionalString(&root) }
                    rootOther = true
                    return reader.value(depth + 1)
                case 16 where reader.key(start, end, "nativeCompaction"):
                    guard !compactionPresent else { return false }
                    compactionPresent = true
                    return reader.null()
                case 17 where reader.key(start, end, "nativeOperationID"): return reader.optionalString(&operation)
                case 19 where reader.key(start, end, "nativeAgentDelivery"):
                    guard !deliveryPresent else { return false }
                    deliveryPresent = true
                    if reader.null() { return true }
                    delivery = true
                    return reader.value(depth + 1)
                case 19 where reader.key(start, end, "nativeTaskExecution"): return reader.optionalString(&execution)
                case 20 where reader.key(start, end, "nativeReplayEligible"): return reader.optionalBool(&eligiblePresent, &eligible)
                default: return reader.value(depth + 1)
                }
            }
            guard read else { return nil }
            var taskKey: String?
            if let execution = text(execution) {
                guard !rootOther else { return nil }
                taskKey = TaskPresentationRecord.identity(text(root) ?? "", execution)
            }
            return .init(role: text(role), toolCallId: text(toolCallId), calls: calls, contentIndexed: contentIndexed, nativeReplayEligible: eligible,
                         nativeKind: text(kind), nativeOperationID: text(operation), taskKey: taskKey, agentDelivery: delivery)
        }

        /// A message's content blocks (`[Block]`): the ids of its tool calls.
        mutating func blocks(_ depth: Int) -> [String]? {
            guard depth < HistoryIndexScan.maximumDepth, i < n, p[i] == 0x5B else { return nil }
            i += 1; ws()
            var calls: [String] = []
            if i < n, p[i] == 0x5D { i += 1; return calls }
            while true {
                var type = Field(), id = Field()
                let read = members(depth + 1) { reader, start, end in
                    switch end - start {
                    case 2 where reader.key(start, end, "id"): return reader.optionalString(&id)
                    case 4 where reader.key(start, end, "type"): return reader.optionalString(&type)
                    default: return reader.value(depth + 2)
                    }
                }
                guard read else { return nil }
                if type.present, !type.null, key(type.start, type.end, "toolCall") { calls.append(text(id) ?? "") }
                ws(); guard i < n else { return nil }
                if p[i] == 0x2C { i += 1; ws(); continue }
                guard p[i] == 0x5D else { return nil }
                i += 1; return calls
            }
        }
    }
}
