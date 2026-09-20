import Foundation

/// Map a literal provisional selection through Foundation's actual source
/// positions when inline markup settles. Offsets are UTF-16, as AppKit expects;
/// this never guesses by matching repeated words in the rendered text.
enum MarkdownSelection {
    static func canonicalRange(_ selection: NSRange, literal: String, source: String, rendered: String, keepsSoftBreaks: Bool) -> NSRange? {
        guard selection.location != NSNotFound, selection.length > 0, source.hasPrefix(literal),
              let parsed=try? AttributedString(markdown: source, options:.init(allowsExtendedAttributes:true, failurePolicy:.returnPartiallyParsedIfPossible, appliesSourcePositionAttributes:true)) else { return nil }
        var text="", intersections:[NSRange]=[]
        for run in parsed.runs {
            var value=String(parsed.characters[run.range])
            if run.inlinePresentationIntent?.contains(.softBreak) == true { value=keepsSoftBreaks ? "\n" : " " }
            let outputStart=text.utf16.count
            text += value
            guard let position=run.markdownSourcePosition, let range=Range<String.Index>(position,in:source) else { continue }
            let input=NSRange(range,in:source), common=NSIntersectionRange(input,selection)
            guard common.length>0 else { continue }
            let start=min(value.utf16.count,common.location-input.location)
            let length=min(common.length,value.utf16.count-start)
            intersections.append(NSRange(location:outputStart+start,length:length))
        }
        guard text == rendered, let first=intersections.first, let last=intersections.last else { return nil }
        return NSRange(location:first.location,length:NSMaxRange(last)-first.location)
    }
}
