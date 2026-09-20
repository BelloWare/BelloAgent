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
        guard !source.utf8.elementsEqual(next.utf8) || self.language != language || pointSize != size || self.environment != environment,
              let storage = textStorage else { return }
        let sameStyle = self.language == language && pointSize == size && self.environment == environment
        let append = sameStyle && next.utf8.starts(with: source.utf8)
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
        // Highlighting is deliberately bounded by the existing scanner limit.
        // Crossing that limit removes old colours, never truncates the code.
        if next.utf8.count <= SyntaxHighlighter.limit || source.utf8.count <= SyntaxHighlighter.limit || !sameStyle {
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
        }
        if let name = language, let grammar = SyntaxHighlighter.language(named: name), next.utf8.count <= SyntaxHighlighter.limit {
            var offsets = [0], offset = 0
            offsets.reserveCapacity(next.unicodeScalars.count + 1)
            for scalar in next.unicodeScalars {
                offset += scalar.value > 0xffff ? 2 : 1
                offsets.append(offset)
            }
            for token in SyntaxHighlighter.tokens(next, language: grammar) {
                let range = NSRange(location: offsets[token.range.lowerBound],
                                    length: offsets[token.range.upperBound] - offsets[token.range.lowerBound])
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
        }
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
