import Foundation

/// Pi 0.85.1's provider rules, ported from packages/ai/src: which failures are
/// context overflows (utils/overflow.ts), which are worth retrying
/// (utils/retry.ts), how tool-call JSON is parsed (utils/json-parse.ts), the
/// session's retry settings (coding-agent settings-manager.ts) and how a
/// thinking level is clamped to a model (models.ts). Every text rule reads the
/// message pi's OpenAI Responses provider would have reported for the same
/// failure; `AgentError.piMessage` holds it.
enum PiProviderRules {
    private static func pattern(_ source: String) -> NSRegularExpression {
        // Every source below is a literal that compiles; a failure is a programming error.
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }
    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// OVERFLOW_PATTERNS.
    static let overflowPatterns: [NSRegularExpression] = [
        #"prompt is too long"#,
        #"request_too_large"#,
        #"input is too long for requested model"#,
        #"exceeds the context window"#,
        #"exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))"#,
        #"input token count.*exceeds the maximum"#,
        #"maximum prompt length is \d+"#,
        #"reduce the length of the messages"#,
        #"maximum context length is \d+ tokens"#,
        #"exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?"#,
        #"input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)"#,
        #"exceeds the limit of \d+"#,
        #"exceeds the available context size"#,
        #"greater than the context length"#,
        #"context window exceeds limit"#,
        #"exceeded model token limit"#,
        #"too large for model with \d+ maximum context length"#,
        #"prompt has [\d,]+ tokens?, but the configured context size is [\d,]+ tokens?"#,
        #"model_context_window_exceeded"#,
        #"prompt too long; exceeded (?:max )?context length"#,
        #"range of input length should be"#,
        #"context[_ ]length[_ ]exceeded"#,
        #"too many tokens"#,
        #"token limit exceeded"#,
        #"^4(?:00|13)\s*(?:status code)?\s*\(no body\)"#,
    ].map(pattern)
    /// NON_OVERFLOW_PATTERNS.
    static let nonOverflowPatterns: [NSRegularExpression] = [
        #"^(Throttling error|Service unavailable):"#,
        #"rate limit"#,
        #"too many requests"#,
    ].map(pattern)
    /// NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN.
    static let nonRetryableLimit = pattern(["GoUsageLimitError", "FreeUsageLimitError", "Monthly usage limit reached", "available balance",
        "insufficient_quota", "out of budget", "quota exceeded", "billing"].joined(separator: "|"))
    /// RETRYABLE_PROVIDER_ERROR_PATTERN.
    static let retryable = pattern([
        "overloaded", "rate.?limit", "too many requests", "429", "500", "502", "503", "504", "524",
        "service.?unavailable", "server.?error", "internal.?error",
        "provider.?returned.?error", "exceeded request buffer limit while retrying upstream",
        "network.?error", "connection.?error", "connection.?refused", "connection.?lost", "other side closed", "fetch failed",
        "getaddrinfo", "ENOTFOUND", "EAI_AGAIN", "upstream.?connect", "reset before headers", "socket hang up",
        "socket connection was closed", "timed? out", "timeout", "terminated",
        "websocket.?closed", "websocket.?error",
        "ended without", "stream ended before message_stop", "stream ended before a terminal response event",
        "http2 request did not get a response",
        "retry delay",
        "you can retry your request", "try your request again", "please retry your request",
        "ResourceExhausted",
    ].joined(separator: "|"))

    /// Case 1 of isContextOverflow: an error whose message names an overflow
    /// and is not a rate limit.
    static func isOverflowText(_ text: String) -> Bool {
        !nonOverflowPatterns.contains { matches($0, text) } && overflowPatterns.contains { matches($0, text) }
    }
    /// isRetryableAssistantError: transient provider or transport text, never
    /// quota or billing exhaustion.
    static func isRetryableText(_ text: String) -> Bool {
        !text.isEmpty && !matches(nonRetryableLimit, text) && matches(retryable, text)
    }
    /// Cases 2 and 3 of isContextOverflow, read from a reply's usage in pi's
    /// shape: a completed reply whose input passed the window, or a length stop
    /// with no output whose input filled it.
    static func isUsageOverflow(stopReason: String, usage: JSON?, contextWindow: Int) -> Bool {
        guard contextWindow > 0, let usage else { return false }
        func count(_ key: String) -> Int { UsageObservation.count(usage[key]) ?? 0 }
        let input = PiContext.sum([count("input"), count("cacheRead")])
        if stopReason == "stop" { return input > contextWindow }
        if stopReason == "length", count("output") == 0 { return Double(input) >= Double(contextWindow) * 0.99 }
        return false
    }
    /// isRecoverableLength: a length stop below the model's own output limit.
    static func isRecoverableLength(stopReason: String, usage: JSON?, desiredMaxOutput: Int) -> Bool {
        stopReason == "length" && desiredMaxOutput > 0 && (UsageObservation.count(usage?["output"] ?? .null) ?? 0) < desiredMaxOutput
    }

    /// settings.retry: three retries, 2 s doubling (2, 4, 8 s).
    struct RetrySettings: Sendable, Equatable {
        var enabled = true
        var maxRetries = 3
        var baseDelayMs = 2_000.0
        /// baseDelayMs × 2^(attempt − 1), for the 1-based retry attempt.
        func delayMs(attempt: Int) -> Double { baseDelayMs * pow(2, Double(max(0, attempt - 1))) }
    }

    /// repairJson: escape raw control characters inside strings and double a
    /// backslash that starts no valid escape.
    static func repairJSON(_ json: String) -> String {
        let units = Array(json.utf16)
        var repaired: [UInt16] = [], inString = false, index = 0
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C
        let escapes: Set<UInt16> = Set("\"\\/bfnrtu".utf16)
        func isHex(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit) }
        while index < units.count {
            let unit = units[index]
            if !inString { repaired.append(unit); if unit == quote { inString = true }; index += 1; continue }
            if unit == quote { repaired.append(unit); inString = false; index += 1; continue }
            if unit == backslash {
                guard index + 1 < units.count else { repaired += [backslash, backslash]; index += 1; continue }
                let next = units[index + 1]
                if next == 0x75, index + 5 < units.count, units[(index + 2)...(index + 5)].allSatisfy(isHex) {
                    repaired += units[index...(index + 5)]; index += 6; continue
                }
                // Pi keeps any escape letter, `u` included, as it is.
                if escapes.contains(next) { repaired += [backslash, next]; index += 2; continue }
                repaired += [backslash, backslash]; index += 1; continue
            }
            if unit <= 0x1F {
                switch unit {
                case 0x08: repaired += Array("\\b".utf16)
                case 0x0C: repaired += Array("\\f".utf16)
                case 0x0A: repaired += Array("\\n".utf16)
                case 0x0D: repaired += Array("\\r".utf16)
                case 0x09: repaired += Array("\\t".utf16)
                default:
                    let hex = String(unit, radix: 16)
                    repaired += Array(("\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex).utf16)
                }
            } else { repaired.append(unit) }
            index += 1
        }
        return String(decoding: repaired, as: UTF16.self)
    }
    /// parseStreamingJson for complete arguments: the JSON as sent, else
    /// repaired, else the longest prefix that closes into JSON, else {}. It
    /// never fails; a tool whose arguments are wrong reports that to the model.
    static func parseArguments(_ text: String?) -> JSON {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        if let value = try? JSON.parse(Data(text.utf8)) { return value }
        let repaired = repairJSON(text)
        if repaired != text, let value = try? JSON.parse(Data(repaired.utf8)) { return value }
        return partial(text) ?? partial(repaired) ?? [:]
    }
    /// partial-json's reading of an unfinished document: open strings, arrays
    /// and objects are closed, and a trailing incomplete member is dropped.
    static func partial(_ text: String) -> JSON? {
        var stack: [Character] = [], inString = false, escaped = false
        var lastSafe: String.Index? = nil
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]": if !stack.isEmpty { stack.removeLast() }
                case ",": lastSafe = index
                default: break
                }
            }
            index = text.index(after: index)
        }
        var candidates: [String] = []
        var closing = inString ? "\"" : ""
        closing += String(stack.reversed())
        candidates.append(text + closing)
        if let lastSafe {
            let head = String(text[..<lastSafe])
            var nested: [Character] = [], quoted = false, escape = false
            for character in head {
                if quoted { if escape { escape = false } else if character == "\\" { escape = true } else if character == "\"" { quoted = false }; continue }
                switch character {
                case "\"": quoted = true
                case "{": nested.append("}")
                case "[": nested.append("]")
                case "}", "]": if !nested.isEmpty { nested.removeLast() }
                default: break
                }
            }
            if !quoted { candidates.append(head + String(nested.reversed())) }
        }
        for candidate in candidates { if let value = try? JSON.parse(Data(candidate.utf8)) { return value } }
        return nil
    }

    /// validateToolArguments' preparation (utils/validation.ts): an optional
    /// property sent as null is dropped when its schema does not take null
    /// (normalizeOptionalNulls), then each value is converted to its schema's
    /// type where pi converts it (coerceWithJsonSchema). The tool validates
    /// what it receives. Pi's TypeBox Value.Convert pass changes nothing for
    /// a plain JSON schema, which every tool here has.
    static func coerceArguments(_ value: JSON, schema: JSON) -> JSON {
        coerce(dropOptionalNulls(value, schema: schema), schema: schema)
    }
    /// getSchemaTypes.
    private static func types(_ schema: JSON) -> [String] {
        if let type = schema["type"].text { return [type] }
        return schema["type"].list.compactMap(\.text)
    }
    /// matchesJsonType.
    private static func matches(_ value: JSON, _ type: String) -> Bool {
        switch (type, value) {
        case ("number", .number): return true
        case ("integer", .number(let number)): return number.isFinite && number.rounded() == number
        case ("boolean", .bool), ("string", .string), ("null", .null), ("array", .array), ("object", .object): return true
        default: return false
        }
    }
    /// The schema validator's Check for the JSON Schema keywords tool schemas
    /// use; nil where pi's validator cannot be built (a $ref it cannot resolve).
    static func validates(_ value: JSON, _ schema: JSON) -> Bool? {
        func hasReference(_ node: JSON) -> Bool {
            switch node {
            case .object(let fields): return fields["$ref"] != nil || fields.values.contains(where: hasReference)
            case .array(let items): return items.contains(where: hasReference)
            default: return false
            }
        }
        return hasReference(schema) ? nil : check(value, schema)
    }
    private static func check(_ value: JSON, _ schema: JSON) -> Bool {
        if case .bool(let flag) = schema { return flag }
        guard case .object(let s) = schema else { return true }
        let declared = types(schema)
        if !declared.isEmpty, !declared.contains(where: { matches(value, $0) }) { return false }
        if case .array(let options)? = s["enum"], !options.contains(value) { return false }
        if let constant = s["const"], constant != value { return false }
        if case .number(let number) = value {
            if let limit = s["minimum"]?.double, number < limit { return false }
            if let limit = s["maximum"]?.double, number > limit { return false }
            if let limit = s["exclusiveMinimum"]?.double, number <= limit { return false }
            if let limit = s["exclusiveMaximum"]?.double, number >= limit { return false }
            if let step = s["multipleOf"]?.double, step > 0, (number / step).rounded() != number / step { return false }
        }
        if case .string(let text) = value {
            let length = text.unicodeScalars.count
            if let limit = s["minLength"]?.int, length < limit { return false }
            if let limit = s["maxLength"]?.int, length > limit { return false }
            if let pattern = s["pattern"]?.text, let expression = try? NSRegularExpression(pattern: pattern),
               expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return false }
        }
        if case .array(let items) = value {
            if let limit = s["minItems"]?.int, items.count < limit { return false }
            if let limit = s["maxItems"]?.int, items.count > limit { return false }
            if s["uniqueItems"]?.flag == true, items.indices.contains(where: { index in items[..<index].contains(items[index]) }) { return false }
            let prefix = s["prefixItems"]?.list ?? (s["items"]?.list.isEmpty == false ? s["items"]!.list : [])
            for (index, item) in items.enumerated() where index < prefix.count { if !check(item, prefix[index]) { return false } }
            if let rest = s["items"], !(rest.list.isEmpty == false) {
                for item in items.dropFirst(prefix.count) where !check(item, rest) { return false }
            }
        }
        if case .object(let fields) = value {
            let properties = s["properties"]?.map ?? [:]
            if s["required"]?.list.contains(where: { fields[$0.text ?? ""] == nil }) == true { return false }
            for (key, field) in fields {
                if let property = properties[key] { if !check(field, property) { return false }; continue }
                let patterned = (s["patternProperties"]?.map ?? [:]).filter { entry in
                    (try? NSRegularExpression(pattern: entry.key)).map { $0.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil } ?? false
                }
                if !patterned.isEmpty { if patterned.values.contains(where: { !check(field, $0) }) { return false }; continue }
                if let additional = s["additionalProperties"], !check(field, additional) { return false }
            }
            if let limit = s["minProperties"]?.int, fields.count < limit { return false }
            if let limit = s["maxProperties"]?.int, fields.count > limit { return false }
        }
        if s["allOf"]?.list.contains(where: { !check(value, $0) }) == true { return false }
        if let members = s["anyOf"]?.list, !members.isEmpty, !members.contains(where: { check(value, $0) }) { return false }
        if let members = s["oneOf"]?.list, !members.isEmpty, members.filter({ check(value, $0) }).count != 1 { return false }
        if let negated = s["not"], check(value, negated) { return false }
        return true
    }
    /// normalizeOptionalNulls.
    private static func dropOptionalNulls(_ value: JSON, schema: JSON) -> JSON {
        switch value {
        case .array(let items):
            if case .array(let schemas) = schema["items"] { return .array(items.enumerated().map { $0.offset < schemas.count ? dropOptionalNulls($0.element, schema: schemas[$0.offset]) : $0.element }) }
            if schema["items"].isObject { return .array(items.map { dropOptionalNulls($0, schema: schema["items"]) }) }
            return value
        case .object(var fields):
            let properties = schema["properties"].map
            guard schema["properties"].isObject else { return value }
            let required = Set(schema["required"].list.compactMap(\.text))
            for (key, property) in properties {
                guard let field = fields[key] else { continue }
                if field.isNull, !required.contains(key), property["$ref"].text == nil, validates(.null, property) == false { fields.removeValue(forKey: key) }
                else { fields[key] = dropOptionalNulls(field, schema: property) }
            }
            return .object(fields)
        default: return value
        }
    }
    /// JavaScript's WhiteSpace and LineTerminator, which String.prototype.trim
    /// and Number() strip.
    private static let jsSpace = CharacterSet(charactersIn: "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        .union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))
    /// Number(text): NaN when the text is not a JavaScript numeric literal.
    static func jsNumber(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: jsSpace)
        if trimmed.isEmpty { return 0 }
        switch trimmed {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        if trimmed.count > 2, let radix = ["0x": 16, "0o": 8, "0b": 2][trimmed.prefix(2).lowercased()] {
            var number = 0.0
            for character in trimmed.dropFirst(2) {
                guard character.isASCII, let digit = character.hexDigitValue, digit < radix else { return .nan }
                number = number * Double(radix) + Double(digit)
            }
            return number
        }
        guard trimmed.range(of: #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return .nan }
        return Double(trimmed) ?? .nan
    }
    /// String(number), JavaScript's Number::toString.
    static func jsString(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number == 0 { return "0" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        if number < 0 { return "-" + jsString(-number) }
        // Swift's description holds the same shortest round-trip digits.
        let parts = "\(number)".lowercased().split(separator: "e", maxSplits: 1).map(String.init)
        let pieces = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var digits = Array(pieces[0] + (pieces.count > 1 ? pieces[1] : ""))
        var point = pieces[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let count = digits.count, text = String(digits)
        if count <= point && point <= 21 { return text + String(repeating: "0", count: point - count) }
        if 0 < point && point <= 21 { return String(digits[..<point]) + "." + String(digits[point...]) }
        if -6 < point && point <= 0 { return "0." + String(repeating: "0", count: -point) + text }
        let exponent = point - 1
        return String(digits[0]) + (count > 1 ? "." + String(digits[1...]) : "") + "e" + (exponent >= 0 ? "+" : "-") + String(abs(exponent))
    }
    /// coercePrimitiveByType.
    private static func primitive(_ value: JSON, _ type: String) -> JSON {
        switch (type, value) {
        case ("number", .null), ("integer", .null): return 0
        case ("number", .string(let text)):
            guard !text.trimmingCharacters(in: jsSpace).isEmpty else { return value }
            let number = jsNumber(text)
            return number.isFinite ? .number(number) : value
        case ("integer", .string(let text)):
            guard !text.trimmingCharacters(in: jsSpace).isEmpty else { return value }
            let number = jsNumber(text)
            return number.isFinite && number.rounded() == number ? .number(number) : value
        case ("number", .bool(let flag)), ("integer", .bool(let flag)): return .number(flag ? 1 : 0)
        case ("boolean", .null): return false
        case ("boolean", .string("true")): return true
        case ("boolean", .string("false")): return false
        case ("boolean", .number(1)): return true
        case ("boolean", .number(0)): return false
        case ("string", .null): return ""
        case ("string", .number(let number)): return .string(jsString(number))
        case ("string", .bool(let flag)): return .string(flag ? "true" : "false")
        case ("null", .string("")), ("null", .number(0)), ("null", .bool(false)): return .null
        default: return value
        }
    }
    /// coerceWithUnionSchema.
    private static func union(_ value: JSON, _ members: [JSON]) -> JSON {
        if members.contains(where: { validates(value, $0) == true }) { return value }
        for member in members {
            let coerced = coerce(value, schema: member)
            if validates(coerced, member) == true { return coerced }
        }
        return value
    }
    /// coerceWithJsonSchema.
    private static func coerce(_ value: JSON, schema: JSON) -> JSON {
        var next = value
        for nested in schema["allOf"].list { next = coerce(next, schema: nested) }
        if case .array(let members) = schema["anyOf"] { next = union(next, members) }
        if case .array(let members) = schema["oneOf"] { next = union(next, members) }
        let declared = types(schema)
        if !declared.isEmpty, !(declared.count > 1 && declared.contains { matches(next, $0) }) {
            for type in declared {
                let candidate = primitive(next, type)
                if candidate != next { next = candidate; break }
            }
        }
        if declared.contains("object"), case .object(var fields) = next {
            let properties = schema["properties"].map
            for (key, property) in properties { if let field = fields[key] { fields[key] = coerce(field, schema: property) } }
            if schema["additionalProperties"].isObject {
                for (key, field) in fields where properties[key] == nil { fields[key] = coerce(field, schema: schema["additionalProperties"]) }
            }
            next = .object(fields)
        }
        if declared.contains("array"), case .array(var items) = next {
            if case .array(let schemas) = schema["items"] {
                for index in items.indices where index < schemas.count { items[index] = coerce(items[index], schema: schemas[index]) }
            } else if schema["items"].isObject {
                items = items.map { coerce($0, schema: schema["items"]) }
            }
            next = .array(items)
        }
        return next
    }

    /// EXTENDED_THINKING_LEVELS.
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// clampThinkingLevel: a level the model's map marks unavailable (null)
    /// moves to the next available level up, else down. Ours: the app offers
    /// only the efforts its model catalog lists, so xhigh and max stay
    /// available without a map entry, where pi requires one.
    static func clampThinkingLevel(_ level: String, map: JSON) -> String {
        func available(_ candidate: String) -> Bool { !(map.map[candidate].map { $0.isNull } ?? false) }
        guard let requested = thinkingLevels.firstIndex(of: level) else { return level }
        if available(level) { return level }
        for candidate in thinkingLevels[requested...] where available(candidate) { return candidate }
        for candidate in thinkingLevels[..<requested].reversed() where available(candidate) { return candidate }
        return "off"
    }
}

/// The error text pi's OpenAI Responses provider reports (the OpenAI SDK's
/// APIError message, formatProviderError's "OpenAI API error" composition,
/// and processResponsesStream's own messages).
enum PiErrorText {
    /// A non-2xx response: APIError.makeMessage over the body's `error`, then
    /// formatProviderError, which shows the error object when the message does
    /// not already carry it.
    /// JavaScript truthiness of a parsed JSON value.
    static func truthy(_ value: JSON) -> Bool {
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .number(let number): return number != 0 && !number.isNaN
        case .string(let text): return !text.isEmpty
        case .object, .array: return true
        }
    }
    static func http(status: Int, body: Data) -> String {
        let raw = String(decoding: body, as: UTF8.self)
        let parsed = try? JSON.parse(body)
        let error = parsed.map { $0["error"] } ?? .null
        let detail: String?
        if truthy(error["message"]) { detail = error["message"].text ?? error["message"].encoded() }
        else if truthy(error) { detail = error.encoded() }
        else { detail = parsed.map(truthy) == true ? nil : raw }
        let message = detail.map { $0.isEmpty ? "\(status) status code (no body)" : "\(status) \($0)" } ?? "\(status) status code (no body)"
        // normalizeProviderError: the body is a non-empty error object, cut to 4,000 characters.
        var bodyText: String?
        if case .object(let fields) = error, !fields.isEmpty {
            let encoded = error.encoded().trimmingCharacters(in: .whitespacesAndNewlines)
            let units = encoded.utf16.count
            bodyText = units <= 4000 ? encoded : String(decoding: Array(encoded.utf16.prefix(4000)), as: UTF16.self) + "... [truncated \(units - 4000) chars]"
        }
        if let bodyText, !message.contains(bodyText) { return "OpenAI API error (\(status)): \(bodyText)" }
        return "OpenAI API error (\(status)): \(message)"
    }
    /// A failure frame in the stream: the SDK's APIError for a frame carrying
    /// `error`, pi's text for an `error` event or a failed response.
    static func stream(_ value: JSON) -> String {
        let error = value["error"]
        if truthy(error) {
            if truthy(error["message"]) { return error["message"].text ?? error["message"].encoded() }
            return error.encoded()
        }
        // A template literal: an absent field reads "undefined", a null one "null".
        func js(_ key: String) -> String { value.map[key].map { $0.text ?? $0.encoded() } ?? "undefined" }
        if value["type"].text == "error" { return "Error Code \(js("code")): \(js("message"))" }
        let failure = value["response"]["error"], details = value["response"]["incomplete_details"]
        func text(_ field: JSON) -> String? { truthy(field) ? field.text ?? field.encoded() : nil }
        if truthy(failure) { return "\(text(failure["code"]) ?? "unknown"): \(text(failure["message"]) ?? "no message")" }
        if let reason = text(details["reason"]) { return "incomplete: \(reason)" }
        return "Unknown error (no error details in response)"
    }
    /// A transport failure as the SDK names it: a timeout, a connection that
    /// failed, or a stream cut after its response began.
    static func transport(_ error: Error, afterResponse: Bool) -> String {
        if (error as? URLError)?.code == .timedOut { return "Request timed out." }
        return afterResponse ? "terminated" : "Connection error."
    }
    /// mapStopReason for an incomplete response other than max_output_tokens.
    static func incomplete(_ reason: String?) -> String {
        reason.map { "Response incomplete: \($0)" } ?? "Response incomplete without a provider reason"
    }
}

extension AgentError {
    /// The text pi's provider would have reported for this failure, which pi's
    /// overflow and retry rules read. An error made without one (a test double,
    /// a local failure) reads as the nearest pi text for its code.
    var piMessage: String {
        if let providerMessage { return providerMessage }
        switch code {
        case "provider_transport", "stream_backpressure": return "Connection error."
        case "incomplete_stream": return ProviderClient.piIncompleteStream
        case "provider_http":
            let status = AgentSession.httpStatus(in: message).map(String.init) ?? "unknown"
            return "OpenAI API error (\(status)): " + message
        default: return message
        }
    }
    /// The same error carrying pi's text for it.
    func carrying(_ piText: String?) -> AgentError {
        AgentError(code, message, failure: failure, attemptID: attemptID, providerMessage: piText ?? providerMessage)
    }
}
