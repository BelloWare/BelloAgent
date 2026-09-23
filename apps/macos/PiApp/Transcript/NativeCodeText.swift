import AppKit
import SwiftUI

/// A persistent selectable leaf. The fence's chrome and complete-source copy
/// action stay in CodeBlockView; TextKit owns only literal code and wrapping.
struct NativeCodeText: NSViewRepresentable {
    // Internal comparison seam. Small fences keep the cheaper SwiftUI leaf;
    // a large fence uses TextKit's bounded drawing and incremental text storage.
    static var enabled = true
    static let minimumBytes = 16_384
    let source: String
    let language: String?
    let size: CGFloat
    func makeNSView(context: Context) -> TranscriptCodeTextView { TranscriptCodeTextView() }
    func updateNSView(_ view: TranscriptCodeTextView, context: Context) {
        view.update(source: source, language: language, size: size, environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptCodeTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

@MainActor final class TranscriptCodeTextView: NSTextView {
    // TextKit's back-pointers are weak. Own the storage before constructing
    // the text view, including the interval before super.init adopts it.
    private var ownedStorage: NSTextStorage?
    private var source = ""
    private var language: String?
    private var pointSize: CGFloat = 0
    private var environment: TranscriptRowEnvironment?
    private var sizes: [CGSize] = []
    private(set) var appendCount = 0
    /// Where the highlighter last stood in a neutral lexical state, as a byte
    /// offset into the code and a UTF-16 offset into the text storage.
    private var checkpoint = (utf8: 0, utf16: 0)
    private(set) var highlightedScalarVisits = 0
    private(set) var lastAttributeRange = NSRange(location: 0, length: 0)
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // Unlike NSTextView(frame:), the designated initializer does not
        // create a text system when passed a nil container.
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), manager = NSLayoutManager()
            ownedStorage = storage
            resolved = NSTextContainer(containerSize: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isEditable = false; isSelectable = true; isRichText = false
        drawsBackground = false; textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        setAccessibilityLabel("Code")
    }
    required init?(coder: NSCoder) { nil }

    func update(source next: String, language: String?, size: CGFloat, environment: TranscriptRowEnvironment) {
        // Bytes, compared as memory: a token must not walk the whole fence.
        guard !source.hasSameUTF8(as: next) || self.language != language || pointSize != size || self.environment != environment,
              let storage = textStorage else { return }
        let sameStyle = self.language == language && pointSize == size && self.environment == environment
        let append = sameStyle && next.hasUTF8Prefix(source)
        let previousLength = storage.length, ranges = selectedRanges
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.4
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(TranscriptPalette.text), .paragraphStyle: paragraph]
        storage.beginEditing()
        if append {
            let suffix = String(decoding: next.utf8.dropFirst(source.utf8.count), as: UTF8.self)
            storage.append(NSAttributedString(string: suffix, attributes: base))
            appendCount += 1
        } else { storage.setAttributedString(NSAttributedString(string: next, attributes: base)) }
        // Resume only at a scanner-certified neutral lexical state. Preserve
        // attributes before that checkpoint. Oversized tails remain plain;
        // crossing the cap never strips already validated prefix colours.
        // Only the code from the checkpoint on is scanned, and only its
        // characters are located in the storage: a checkpoint follows a line
        // break in a neutral state, so scanning from there alone finds exactly
        // the tokens a scan of the whole code finds after it.
        var dirtyStart = append ? previousLength : 0
        if let name = language, let grammar = SyntaxHighlighter.language(named: name),
           !append || source.utf8.count < SyntaxHighlighter.limit {
            let resume = append ? checkpoint : (utf8: 0, utf16: 0)
            let tail: String = next.withUTF8Bytes { bytes in
                // The colourable part ends at the limit, on a scalar boundary.
                var bound = min(bytes.count, SyntaxHighlighter.limit)
                while bound > 0, bound < bytes.count, bytes[bound] & 0xC0 == 0x80 { bound -= 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[min(resume.utf8, bound)..<bound]), as: UTF8.self)
            }
            let scan = SyntaxHighlighter.scan(tail, language: grammar)
            // Where each of the tail's scalars begins, in the storage and in the code.
            var utf16 = [resume.utf16], utf8 = [resume.utf8]
            utf16.reserveCapacity(tail.utf8.count + 1); utf8.reserveCapacity(tail.utf8.count + 1)
            for scalar in tail.unicodeScalars {
                utf16.append(utf16[utf16.count - 1] + (scalar.value > 0xffff ? 2 : 1))
                utf8.append(utf8[utf8.count - 1] + UTF8.width(scalar))
            }
            highlightedScalarVisits += utf16.count - 1
            dirtyStart = resume.utf16
            storage.setAttributes(base, range: NSRange(location: dirtyStart, length: storage.length - dirtyStart))
            for token in scan.tokens {
                let range = NSRange(location: utf16[token.range.lowerBound], length: utf16[token.range.upperBound] - utf16[token.range.lowerBound])
                let color: Color
                switch token.kind {
                case .keyword: color = TranscriptPalette.keyword
                case .string: color = TranscriptPalette.string
                case .number, .title: color = TranscriptPalette.number
                case .comment:
                    color = TranscriptPalette.comment
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: range)
                }
                storage.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            }
            if let last = scan.checkpoints.last(where: { $0 < utf16.count - 1 }) { checkpoint = (utf8[last], utf16[last]) }
            else { checkpoint = resume }
        } else if !append { checkpoint = (0, 0) }
        lastAttributeRange = NSRange(location: dirtyStart, length: storage.length - dirtyStart)
        storage.endEditing()
        source = next; self.language = language; pointSize = size; self.environment = environment
        sizes.removeAll(keepingCapacity: true)
        // Appending must not move the native selection to the new end.
        if previousLength > 0 {
            selectedRanges = ranges.map { value in
                let range = value.rangeValue, location = min(range.location, storage.length)
                return NSValue(range: NSRange(location: location, length: min(range.length, storage.length - location)))
            }
        }
        needsDisplay = true
    }

    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? TranscriptMetrics.pageWidth
        // SwiftUI probes several widths, including cached ones. A probe must
        // not leave the selectable view wrapping at a different width from
        // its current frame when that frame itself did not change.
        defer { alignTextToBounds() }
        if let size = sizes.last(where: { $0.width == width }) { return size }
        guard let container = textContainer, let manager = layoutManager else { return CGSize(width: width, height: 1) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let result = CGSize(width: width, height: max(1, ceil(height)))
        if sizes.count == 4 { sizes.removeFirst() }; sizes.append(result)
        return result
    }
    override func layout() {
        super.layout()
        alignTextToBounds()
    }
    private func alignTextToBounds() {
        if bounds.width > 0, textContainer?.containerSize.width != bounds.width {
            textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
    }
}
