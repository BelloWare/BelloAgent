import Foundation

/// Reconcile native UTF-16 positions through Markdown source positions. The
/// block range is UTF-8 (like MarkdownBlockIdentity), converted explicitly at
/// this boundary. Equal words in different blocks never establish identity.
enum MarkdownSelection {
    struct Source {
        let document: String
        let fragment: String
        let range: NSRange

        init?(_ document: String, bytes: Range<Int>) {
            let utf8 = document.utf8
            guard bytes.lowerBound >= 0, bytes.upperBound <= utf8.count else { return nil }
            let start = utf8.index(utf8.startIndex, offsetBy: bytes.lowerBound)
            let end = utf8.index(start, offsetBy: bytes.count)
            guard let lower = String.Index(start, within: document),
                  let upper = String.Index(end, within: document) else { return nil }
            self.document = document
            fragment = String(document[lower..<upper])
            range = NSRange(lower..<upper, in: document)
        }
    }

    /// Kept by the affected native leaf, with parsing deferred until a reader
    /// anchor or selection needs it. Unchanged blocks do no reconciliation work.
    final class Reconciliation {
        private let previous: String
        private let source: Source
        private let previousSource: Source
        private let rendered: String
        private let keepsSoftBreaks: Bool
        private lazy var oldMap: TextMap? = {
            if previousSource.fragment.hasPrefix(previous) {
                return TextMap(text: previous, spans: [Span(
                    output: NSRange(location: 0, length: previous.utf16.count),
                    input: NSRange(location: source.range.location, length: previous.utf16.count))])
            }
            // Settled streaming fragments are parsed independently. A later
            // document-scoped definition can change their inline rendering.
            if let map = Self.parse(previousSource.fragment, scope: NSRange(location: 0, length: previousSource.fragment.utf16.count),
                                    origin: source.range.location, keepsSoftBreaks: keepsSoftBreaks), map.text == previous { return map }
            // Already-canonical content may itself depend on definitions
            // outside this paragraph. Consult the prior document, not the
            // current range, which may now include an appended definition.
            guard let map = Self.parse(previousSource.document, scope: previousSource.range,
                                       origin: source.range.location - previousSource.range.location, keepsSoftBreaks: keepsSoftBreaks),
                  map.text == previous else { return nil }
            return map
        }()
        private lazy var newMap: TextMap? = {
            guard let map = Self.parse(source.document, scope: source.range, origin: 0, keepsSoftBreaks: keepsSoftBreaks),
                  map.text == rendered else { return nil }
            return map
        }()

        init(previous: String, source: Source, previousSource: Source? = nil, rendered: String, keepsSoftBreaks: Bool) {
            self.previous = previous; self.source = source; self.rendered = rendered; self.keepsSoftBreaks = keepsSoftBreaks
            self.previousSource = previousSource ?? source
        }

        func range(_ selection: NSRange, from previous: String, to rendered: String) -> NSRange? {
            guard previous == self.previous, rendered.hasPrefix(self.rendered) else { return nil }
            return range(selection)
        }

        func range(_ selection: NSRange) -> NSRange? {
            guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
                  selection.location <= previous.utf16.count,
                  selection.length <= previous.utf16.count - selection.location,
                  let oldMap, let newMap else { return nil }
            var sourceRanges: [NSRange] = [], covered = 0
            for span in oldMap.spans {
                let common = NSIntersectionRange(span.output, selection)
                guard common.length > 0 else { continue }
                covered += common.length
                sourceRanges.append(NSRange(location: span.input.location + common.location - span.output.location, length: common.length))
            }
            // Don't invent a location inside a parser-transformed run for
            // which Foundation did not expose character-level provenance.
            guard covered == selection.length else { return nil }
            var intersections: [NSRange] = []
            for span in newMap.spans {
                for input in sourceRanges {
                    let common = NSIntersectionRange(span.input, input)
                    if common.length > 0 {
                        intersections.append(NSRange(location: span.output.location + common.location - span.input.location, length: common.length))
                    }
                }
            }
            guard let start = intersections.map(\.location).min(), let end = intersections.map({ NSMaxRange($0) }).max() else { return nil }
            return NSRange(location: start, length: end - start)
        }

        private struct Span { let output: NSRange; let input: NSRange }
        private struct TextMap { let text: String; let spans: [Span] }

        private static func parse(_ source: String, scope: NSRange, origin: Int, keepsSoftBreaks: Bool) -> TextMap? {
            guard let parsed = try? AttributedString(markdown: source, options: .init(
                allowsExtendedAttributes: true, failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: true)) else { return nil }
            var text = "", spans: [Span] = [], outputOffset = 0
            for run in parsed.runs {
                guard let position = run.markdownSourcePosition, let range = Range<String.Index>(position, in: source) else { continue }
                let input = NSRange(range, in: source)
                guard NSIntersectionRange(scope, input).length == input.length, input.length > 0 else { continue }
                let plain = String(parsed.characters[run.range])
                let softBreak = run.inlinePresentationIntent?.contains(.softBreak) == true
                let value = softBreak ? (keepsSoftBreaks ? "\n" : " ") : plain
                let length = value.utf16.count
                // Exact source runs and normalized one-character soft breaks
                // can be mapped without diffing or matching repeated text.
                if String(source[range]) == value || (softBreak && input.length == length) {
                    spans.append(Span(output: NSRange(location: outputOffset, length: length),
                                      input: NSRange(location: origin + input.location, length: input.length)))
                }
                text += value; outputOffset += length
            }
            return TextMap(text: text, spans: spans)
        }
    }

    static func canonicalRange(_ selection: NSRange, literal: String, source: String, rendered: String, keepsSoftBreaks: Bool) -> NSRange? {
        guard let context = Source(source, bytes: 0..<source.utf8.count) else { return nil }
        return Reconciliation(previous: literal, source: context, rendered: rendered, keepsSoftBreaks: keepsSoftBreaks).range(selection)
    }
}
