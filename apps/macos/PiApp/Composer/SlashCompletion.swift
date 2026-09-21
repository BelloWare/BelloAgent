import Foundation

struct ComposerLocation: Equatable, Sendable {
    let sessionID: String
    let editorGeneration: UUID
    let draftRevision: UInt64
    let selectedRangeUTF16: NSRange
    let markedRangeUTF16: NSRange?
}

struct SlashCompletionToken: Equatable, Sendable {
    let location: ComposerLocation
    let replacementRangeUTF16: NSRange
    let query: String
    let literal: String
    let wholeMessageCommandEligible: Bool

    /// Only inspect the bounded token here. Code classification is a separate,
    /// cancellable background operation, never a whole-draft keystroke scan.
    static func local(in text: NSString, at location: ComposerLocation, directInput: Bool) -> Self? {
        let caret = location.selectedRangeUTF16
        guard location.markedRangeUTF16 == nil, caret.length == 0,
              caret.location != NSNotFound, caret.location <= text.length else { return nil }
        func name(_ c: unichar) -> Bool { (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95 }
        func whitespace(_ c: unichar) -> Bool { UnicodeScalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
        var start = caret.location
        while start > 0 && name(text.character(at: start - 1)) && caret.location - start <= 64 { start -= 1 }
        guard start > 0, text.character(at: start - 1) == 47 else { return nil }
        start -= 1
        guard start == 0 || whitespace(text.character(at: start - 1)) || [40, 91, 123].contains(text.character(at: start - 1)) else { return nil }
        var end = caret.location
        while end < text.length && name(text.character(at: end)) && end - start <= 65 { end += 1 }
        guard end - start <= 65,
              end == text.length || whitespace(text.character(at: end)) || [41, 93, 125, 44, 46, 59, 58, 33, 63].contains(text.character(at: end)) else { return nil }
        if end + 1 < text.length, text.character(at: end) == 46, name(text.character(at: end + 1)) { return nil }
        let range = NSRange(location: start, length: end - start)
        let literal = text.substring(with: range)
        let query = String(literal.dropFirst())
        guard query.isEmpty || query.first!.isLetter || query.first!.isNumber else { return nil }
        return Self(location: location, replacementRangeUTF16: range, query: query, literal: literal,
                    wholeMessageCommandEligible: directInput && start == 0 && end == text.length)
    }

    /// Runs off the UI actor and only for a locally valid token. Treat an
    /// unfinished Markdown code span/fence conservatively as literal input.
    static func outsideCode(_ text: String, before offset: Int) -> Bool {
        var codeDelimiter = 0, fence: UInt16 = 0, fenceLength = 0
        var run = 0, runKind: UInt16 = 0, runAtLineStart = false, leadingSpaces = 0
        var escaped = false, index = 0, closingFence = false
        func finishRun() {
            guard run > 0 else { return }
            if fence != 0 {
                if runAtLineStart, runKind == fence, run >= fenceLength { closingFence = true }
            } else if codeDelimiter > 0 {
                if runKind == 96, run == codeDelimiter { codeDelimiter = 0 }
            } else if runAtLineStart, run >= 3 { fence = runKind; fenceLength = run }
            else if runKind == 96 { codeDelimiter = run }
            run = 0
        }
        for unit in text.utf16 {
            if Task.isCancelled { return false }
            if index >= offset { break }; index += 1
            if (unit == 96 || unit == 126), !escaped {
                if closingFence { closingFence = false }
                if run > 0, runKind != unit { finishRun() }
                if run == 0 { runKind = unit; runAtLineStart = leadingSpaces <= 3 }
                run += 1; leadingSpaces = 4; continue
            }
            finishRun()
            if closingFence {
                if unit == 10 { fence = 0; fenceLength = 0; closingFence = false }
                else if unit != 32 && unit != 9 && unit != 13 { closingFence = false }
            }
            if unit == 10 { leadingSpaces = 0 }
            else if unit == 32, leadingSpaces <= 3 { leadingSpaces += 1 }
            else { leadingSpaces = 4 }
            if unit == 92 && !escaped { escaped = true } else { escaped = false }
        }
        finishRun()
        return codeDelimiter == 0 && fence == 0
    }
}

enum SkillSearch {
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func query(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), !trimmed.dropFirst().contains("/"), !trimmed.contains(where: \.isWhitespace) { return fold(String(trimmed.dropFirst())) }
        return fold(trimmed)
    }
    struct Entry: Sendable {
        let skill: SkillDescriptor
        let name: String, path: String, description: String
        init(_ skill: SkillDescriptor) { self.skill = skill; name = fold(skill.name); path = fold(skill.path); description = fold(skill.description) }
    }
    static func search(_ entries: [Entry], query raw: String, actionable: Bool) -> [SkillDescriptor] {
        let needle = query(raw), terms = query(raw).split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.compactMap { entry -> (Entry, Int)? in
            guard !actionable || entry.skill.canSelect else { return nil }
            let rank: Int
            if needle.isEmpty || entry.name == needle { rank = 0 }
            else if entry.name.hasPrefix(needle) { rank = 1 }
            else if entry.name.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains(where: { $0.hasPrefix(needle) }) { rank = 2 }
            else if entry.name.contains(needle) { rank = 3 }
            else if terms.allSatisfy({ entry.name.contains($0) || entry.description.contains($0) || entry.path.contains($0) }) { rank = 4 + terms.filter { !entry.name.contains($0) }.count }
            else { return nil }
            return (entry, rank)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.name != b.0.name { return a.0.name < b.0.name }
            return a.0.path == b.0.path ? a.0.skill.id < b.0.skill.id : a.0.path < b.0.path
        }.map { $0.0.skill }
    }
}
