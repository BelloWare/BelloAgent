import AppKit
import SwiftUI

// Text shown exactly as it was written: a message as the reader typed it, and
// a reply's markdown source when the reader asks for it. Nothing in it is
// interpreted — `**`, `#`, backticks, list markers and links read literally,
// and every line break and space stays — and it is one selectable text, so a
// selection can run across its lines and copies exactly what it covers.

/// How literal text is set: its face, its size and the room between lines.
struct TranscriptPlainTextFace: Equatable, Sendable {
    var size: CGFloat
    var monospaced: Bool
    /// Between one line and the next, never after the last.
    var lineSpacing: CGFloat
    /// One line's box at `size`, for estimates: SF is 17 points tall at
    /// 14.5, SF Mono 15 at 12.5.
    var lineHeight: CGFloat { size * (monospaced ? 1.2 : 1.172) }
    /// Roughly how wide one character is, as a fraction of `size`.
    var characterWidth: CGFloat { monospaced ? 0.6 : 0.52 }
    /// What assistive technology calls the text.
    var label: String

    /// A message the reader sent: the face, size and colour the bubble has
    /// always read in, the prose's own.
    static let user = TranscriptPlainTextFace(size: MarkdownStyle.user.baseSize, monospaced: false,
                                              lineSpacing: MarkdownStyle.user.baseSize * 0.35, label: "Message")
    /// A reply's markdown source: the face and size of the transcript's code.
    static let source = TranscriptPlainTextFace(size: MarkdownStyle.prose.baseSize * 0.86, monospaced: true,
                                                lineSpacing: MarkdownStyle.prose.baseSize * 0.86 * 0.4, label: "Markdown source")

    var font: Font { .system(size: size, design: monospaced ? .monospaced : .default) }
    var nsFont: NSFont { monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size) }
}

/// Literal text as one selectable text. A short text is SwiftUI's own; a
/// long one — a paste can be the composer's whole 256 KiB — is a TextKit leaf
/// that measures its height once per width, as a long code fence is, rather
/// than one enormous SwiftUI text laid out on every pass.
struct TranscriptPlainText: View, Equatable {
    /// From this many bytes on the text is laid out by TextKit.
    static let textKitBytes = 2_048
    let text: String
    let face: TranscriptPlainTextFace

    static func usesTextKit(_ text: String) -> Bool { text.utf8.count >= textKitBytes }

    var body: some View {
        Group {
            if text.isEmpty {
                // A message with nothing typed (its images or skills are the
                // message) still gives its bubble the full width.
                Color.clear.frame(height: 0)
            } else if Self.usesTextKit(text) {
                NativePlainText(text: text, face: face)
            } else {
                Text(verbatim: text)
                    .font(face.font).foregroundStyle(TranscriptPalette.text)
                    .lineSpacing(face.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.face == b.face && a.text.hasSameUTF8(as: b.text) }
}

/// The TextKit leaf, as SwiftUI sizes it: its height is the one the text
/// view measured at the width it was offered.
struct NativePlainText: NSViewRepresentable {
    let text: String
    let face: TranscriptPlainTextFace
    func makeNSView(context: Context) -> TranscriptPlainTextView { TranscriptPlainTextView() }
    func updateNSView(_ view: TranscriptPlainTextView, context: Context) {
        view.update(text: text, face: face, environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptPlainTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

/// A persistent selectable leaf for literal text. TextKit owns the text, its
/// wrapping and its selection; nothing in it is interpreted, detected or
/// edited, and a copy is the plain characters the selection covers.
@MainActor final class TranscriptPlainTextView: NSTextView {
    // TextKit's back-pointers are weak. Own the storage before constructing
    // the text view, including the interval before super.init adopts it.
    private var ownedStorage: NSTextStorage?
    private(set) var text = ""
    private var face: TranscriptPlainTextFace?
    private var environment: TranscriptRowEnvironment?
    private var sizes: [CGSize] = []
    /// How often the text has been laid out in full: once per width it is
    /// asked about, never again for a width it already knows.
    private(set) var layoutPasses = 0
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // Unlike NSTextView(frame:), the designated initializer does not
        // create a text system when passed a nil container.
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), manager = NSLayoutManager()
            ownedStorage = storage
            resolved = NSTextContainer(containerSize: NSSize(width: TranscriptMetrics.proseWidth, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isEditable = false; isSelectable = true; isRichText = false; importsGraphics = false
        drawsBackground = false; textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
    }
    required init?(coder: NSCoder) { nil }

    func update(text next: String, face: TranscriptPlainTextFace, environment: TranscriptRowEnvironment) {
        // Bytes, compared as memory: a long paste is not walked a character
        // at a time on every update of its row.
        let sameText = self.face == face && text.hasSameUTF8(as: next)
        guard !sameText || self.environment != environment, let storage = textStorage else { return }
        if sameText, let current = self.environment, current.hasSameGeometry(as: environment) {
            // Painted again, measured the same: the colours are dynamic and
            // resolve against the appearance they are drawn in.
            self.environment = environment
            needsDisplay = true
            return
        }
        let ranges = selectedRanges, previousLength = storage.length
        if !sameText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = face.lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            storage.setAttributedString(NSAttributedString(string: next, attributes: [
                .font: face.nsFont, .foregroundColor: NSColor(TranscriptPalette.text), .paragraphStyle: paragraph
            ]))
            text = next; self.face = face
            setAccessibilityLabel(face.label)
        }
        self.environment = environment
        sizes.removeAll(keepingCapacity: true)
        // New text keeps whatever of the reader's selection still fits it.
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
        guard !text.isEmpty, let container = textContainer, let manager = layoutManager else { return CGSize(width: width, height: 0) }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        layoutPasses += 1
        // The used rect ends at the last line's own box: TextKit puts line
        // spacing between lines, and a trailing line break is a line.
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
            textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }
    /// A right-click on a selection is the text's own: Copy, Look Up. Any
    /// other is the row's, as it is on the rest of the row and on a short
    /// text: a reply's menu, with View rendered in it.
    override func menu(for event: NSEvent) -> NSMenu? {
        selectedRange().length > 0 ? super.menu(for: event) : nil
    }
}

// MARK: - A reply's source

/// A reply read as its markdown source: which rows can switch, what the
/// switch is called, and the per-reply state it keeps in the conversation's
/// disclosure (`TranscriptDisclosure.Part.source`).
enum ReplySource {
    /// The id of the reply whose view this row draws, if the row draws a
    /// reply's text: a reply's body, or one text part of a reply read in
    /// order. A response's header line, its cards, its reasoning and its
    /// figures draw none, so switching a reply never re-measures them.
    static func replyID(of item: TranscriptItem) -> String? {
        switch item {
        case .message(let message):
            return drawsReply(message) ? message.id : nil
        case .block(let block):
            guard let message = block.message, drawsReply(message) else { return nil }
            switch block.presentation {
            case .body, .reply: return message.id
            case .timeline: return block.part.map { ["text", "refusal"].contains($0.part.kind) } == true ? message.id : nil
            case .work, .summary, .response, .turnFold: return nil
            }
        }
    }
    private static func drawsReply(_ message: TranscriptMessage) -> Bool {
        message.role == "assistant" && message.kind == nil
    }
    /// Whether a row offers the switch: on a reply's finished text only.
    /// Text still arriving is always drawn rendered, by the surface that
    /// takes its tokens.
    static func offered(_ message: TranscriptMessage) -> Bool {
        drawsReply(message) && !message.isStreaming && TaskTranscriptPlan.visible(message.text)
    }
    /// Whether a row draws this reply as its source.
    static func shows(_ message: TranscriptMessage, raw: Bool) -> Bool {
        raw && drawsReply(message) && !message.isStreaming
    }
    /// The pill's and the accessibility action's name.
    static func title(raw: Bool) -> String { raw ? "View rendered" : "View raw" }
    /// The reply menu's command.
    static func menuTitle(raw: Bool) -> String { raw ? "View Rendered" : "View Raw" }
    static let menuIdentifier = "reply-raw"
}

/// A row's switch between its reply rendered and its source, as the pill,
/// the reply menu and the accessibility action offer it.
struct ReplySourceToggle {
    /// Whether the reply reads as its source now.
    let raw: Bool
    let toggle: () -> Void
}

/// A reply's markdown source exactly as it arrived: one selectable
/// monospaced text in the panel the transcript's code sits in.
struct ReplySourceView: View, Equatable {
    let source: String
    var body: some View {
        TranscriptPlainText(text: source, face: .source).equatable()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
            .accessibilityIdentifier("reply-source")
    }
    nonisolated static func == (a: Self, b: Self) -> Bool { a.source.hasSameUTF8(as: b.source) }
}
