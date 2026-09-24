import AppKit
import SwiftUI

/// A rendered reply: one TextKit text holding every block of it, so a
/// selection runs across paragraphs, list items, headings, code and tables,
/// and a copy is the text it covers (`MarkdownTextDocument.swift`).
///
/// The surface reads the message itself (`StreamingMarkdownState`), so a token
/// extends the reply without SwiftUI rebuilding anything: the text changes
/// only from the first character that reads differently, TextKit lays out
/// again only from there, and a selection above it stays as it was.
struct NativeMarkdownSurface: NSViewRepresentable {
    let source: String
    let style: MarkdownStyle
    let capsWidth: Bool
    let streaming: Bool
    let headings: [MarkdownCopyTarget]
    /// Which reply this is, so a token can be handed to the surface that is
    /// carrying it.
    var identity: String = ""
    /// The reader is reading this reply as its source (`ReplySource`). The
    /// surface keeps its text and every height it measured, but draws
    /// nothing and takes no room, so switching back finds the rendered reply
    /// exactly as the reader left it.
    var parked = false

    func makeNSView(context: Context) -> NativeMarkdownContainer {
        let view = NativeMarkdownContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeMarkdownContainer, context: Context) {
        view.read(source: source, style: style, capsWidth: capsWidth, streaming: streaming, headings: headings,
                  environment: TranscriptRowEnvironment(context.environment), identity: identity)
        view.park(parked)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownContainer, context: Context) -> CGSize? {
        parked ? CGSize(width: proposal.width ?? 0, height: 0) : nsView.measure(width: proposal.width)
    }
}

/// The reply's text. Only what the reader selected is its own: a right-click
/// elsewhere is the row's, and a copy is the reply's text as it reads —
/// list items with their markers, table cells split by tabs, blocks by a
/// blank line — without the page's own labels.
@MainActor final class MarkdownTextView: NSTextView {
    // TextKit's back-pointers are weak. Own the storage before constructing
    // the text view, including the interval before super.init adopts it.
    private var ownedStorage: NSTextStorage?
    /// Room above the first line: a reply that opens with a fence, a heading
    /// or a table keeps the padding those have above their text, which
    /// TextKit gives no paragraph at the very top.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { invalidateTextContainerOrigin(); needsDisplay = true } }
    }
    override var textContainerOrigin: NSPoint { NSPoint(x: 0, y: topInset) }
    var didDraw: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        didDraw?()
    }
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), manager = MarkdownTextLayoutManager()
            ownedStorage = storage
            resolved = NSTextContainer(containerSize: NSSize(width: TranscriptMetrics.pageWidth, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isEditable = false; isSelectable = true; isRichText = true; importsGraphics = false
        drawsBackground = false; textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false
        usesFontPanel = false; usesFindBar = false; isAutomaticLinkDetectionEnabled = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        layoutManager?.allowsNonContiguousLayout = false
        linkTextAttributes = [.foregroundColor: NSColor(TranscriptPalette.accent), .cursor: NSCursor.pointingHand]
        setAccessibilityLabel("Reply")
    }
    required init?(coder: NSCoder) { nil }

    /// The copy actions assistive technology offers for the text: each
    /// fence's code, and each heading's section, as their buttons copy them.
    var copyTargets: () -> [MarkdownCopyTarget] = { [] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if let storage = textStorage {
            var fences: [MarkdownCodeMark] = []
            storage.enumerateAttribute(.piCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let mark = value as? MarkdownCodeMark, fences.last !== mark { fences.append(mark) }
            }
            for (index, mark) in fences.enumerated() {
                let name = fences.count == 1 ? "Copy code" : "Copy code \(index + 1)"
                actions.append(NSAccessibilityCustomAction(name: name) { [weak mark] in
                    guard let mark else { return false }
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(mark.code, forType: .string)
                })
            }
        }
        for target in copyTargets() {
            actions.append(NSAccessibilityCustomAction(name: target.label) {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(target.text, forType: .string)
            })
        }
        return (super.accessibilityCustomActions() ?? []) + actions
    }
    /// A right-click on a selection is the text's own: Copy, Look Up. Any
    /// other is the row's, as it is on the rest of the row: a reply's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        selectedRange().length > 0 ? super.menu(for: event) : nil
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(copyText(selectedRanges.map(\.rangeValue)), forType: .string)
    }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(copyText(selectedRanges.map(\.rangeValue)), forType: .string)
    }
    /// The reply's text over `ranges`, as a copy gives it.
    func copyText(_ ranges: [NSRange]) -> String {
        guard let storage = textStorage else { return "" }
        let text = storage.string as NSString
        var result = ""
        for range in ranges {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            guard clipped.length > 0 else { continue }
            if !result.isEmpty { result += "\n" }
            var skippedMarker = NSRange(location: NSNotFound, length: 0)
            storage.enumerateAttributes(in: clipped) { attributes, run, _ in
                if attributes[.piChrome] != nil { return }
                if let marker = attributes[.piListMarker] as? String {
                    // A marker counts once, however the selection cuts it.
                    var whole = NSRange()
                    _ = storage.attribute(.piListMarker, at: run.location, effectiveRange: &whole)
                    guard whole != skippedMarker else { return }
                    skippedMarker = whole
                    result += marker
                    return
                }
                let piece = text.substring(with: run)
                if piece == "\n", let copy = attributes[.piBlockBreak] as? String { result += copy; return }
                result += piece
            }
        }
        return result
    }
}

/// A rendered reply's surface: the text, and the controls that sit on it.
@MainActor final class NativeMarkdownContainer: NSView {
    /// One block of the reply in the text — or one item of a list at the
    /// reply's top level, so a token on a long list sets one item again —
    /// and the characters it fills, the line break before it included.
    private struct Segment {
        var identity: MarkdownBlockIdentity
        var block: MarkdownBlock
        var item: ItemPlace?
        var record: Int
        var sourceRange: Range<Int>?
        var range: NSRange
        var tail: Tail
        var headings: Int
        /// For a paragraph that now reads differently from how it read (a
        /// reference defined later, a mark closed): how its old characters
        /// map to its new ones, through the source, for a selection or a
        /// reading position inside it.
        var reconciliation: MarkdownSelection.Reconciliation? = nil
    }
    /// Where a list item stands in its list: its number, the list's marker
    /// column, and whether it is the list's first.
    private struct ItemPlace: Equatable {
        var ordered: Bool
        var number: Int
        var column: CGFloat
        var first: Bool
    }
    /// What the text is made of: the reading's records, a top-level list
    /// taken item by item.
    private struct Unit {
        var identity: MarkdownBlockIdentity
        var block: MarkdownBlock
        var item: ItemPlace?
        var record: Int
        var sourceRange: Range<Int>?
    }
    /// How a block's last paragraph ended: what the next block is set below.
    private struct Tail {
        var spacing: MarkdownTextTail
        var breakCopy: String
        var attributes: [NSAttributedString.Key: Any]
    }
    /// What an update draws with besides the blocks: when these are what the
    /// last update drew with, the blocks it did not change keep their text.
    private struct Inputs: Equatable {
        var style: MarkdownStyle
        var capsWidth: Bool
        var streaming: Bool
        var headings: [MarkdownCopyTarget]
        var environment: TranscriptRowEnvironment
        func hasSameText(as other: Inputs) -> Bool {
            style == other.style && capsWidth == other.capsWidth && environment.hasSameGeometry(as: other.environment)
        }
    }
    let textView = MarkdownTextView()
    private let builder = MarkdownTextBuilder()
    private var segments: [Segment] = []
    private var recordIdentities: [MarkdownBlockIdentity] = []
    private var identitySet = Set<MarkdownBlockIdentity>()
    private var lastInputs: Inputs?
    /// Heights measured at each width the page asked about, for this text.
    private var sizes: [CGSize] = []
    /// Evidence for regressions: how many full layouts the text has had, and
    /// how many characters the last update replaced.
    private(set) var layoutPasses = 0
    private(set) var lastReplacedLength = 0
    private(set) var lastReplacedLocation = 0
    private(set) var reconciledBlockVisits = 0
    private var invalidationScheduled = false
    private var hoverArea: NSTrackingArea?
    private var toolbar: NSHostingView<MarkdownCodeToolbar>?
    private weak var toolbarMark: MarkdownCodeMark?
    private var headingAction: NSHostingView<MarkdownHeadingAction>?
    private var headingActionIndex: Int?
    private var tableActions: [ObjectIdentifier: NSHostingView<MarkdownTableAction>] = [:]
    /// How many tables are drawn as a preview: they have a control beside them.
    private var largeTables = 0
    private var hasLargeTables: Bool { largeTables > 0 }
    private static func isLargeTable(_ block: MarkdownBlock) -> Bool {
        if case .table(_, let header, let rows) = block { return MarkdownTablePresentation.isLarge(header: header, rows: rows) }
        return false
    }
    /// Where the pointer last was over this reply, to put its control back
    /// after the text under it changed.
    private var hoverPoint: NSPoint?
    private let caret = MarkdownCaretView()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.frame = bounds
        textView.copyTargets = { [weak self] in self?.lastInputs?.headings ?? [] }
        addSubview(textView)
        caret.isHidden = true
        addSubview(caret)
    }
    required init?(coder: NSCoder) { nil }

    /// Whether the text has a height it might still correct: never, now that
    /// the whole reply is laid out as one text.
    var hasProvisionalGeometry: Bool { false }
    /// Whether what is on screen is drawn at its own measure.
    var visibleContentPrepared: Bool {
        isParked || textView.textContainer?.containerSize.width == bounds.width || bounds.width == 0
    }
    var provisionalBlockCount: Int { 0 }
    /// Told each time the text is drawn: the reading position must already
    /// be where it belongs by then.
    var didDrawPreparedContent: (() -> Void)? {
        get { textView.didDraw }
        set { textView.didDraw = newValue }
    }
    var retainedBlockCount: Int { segments.count }
    /// The text: every block of the reply, as one selectable text.
    var textLength: Int { textView.textStorage?.length ?? 0 }

    // MARK: Parking

    /// Parked while the reader reads this reply as its source: the text and
    /// its heights stay, nothing is drawn, and the surface takes no room.
    private(set) var isParked = false
    func park(_ parked: Bool) {
        guard parked != isParked else { return }
        isParked = parked
        textView.isHidden = parked
        if parked { hideControls(); caret.isHidden = true }
        needsLayout = true
    }

    // MARK: Reading

    /// The reading of this message, owned here rather than by a view body, so
    /// that a token can extend it without SwiftUI running at all.
    private let reading = StreamingMarkdownState()
    private var readingContext: (style: MarkdownStyle, capsWidth: Bool, streaming: Bool, headings: [MarkdownCopyTarget],
                                 environment: TranscriptRowEnvironment, identity: String)?
    /// Which reply this surface carries, for the row handing it a token.
    var readingIdentity: String? { readingContext?.identity }
    /// How many tokens this surface has taken without SwiftUI rebuilding the row.
    private(set) var appendCount = 0
    private var appending = false
    private var drewReading = false
    private var priorSourceText: String?

    /// The message as it stands. Called by SwiftUI when anything other than
    /// the arriving text changes: the appearance, the width, the reply
    /// settling, the reader opening something.
    func read(source: String, style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
              headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identity: String) {
        // A token can reach this surface directly, ahead of the view that
        // carries the same text. A view update that is a token behind must
        // not rewind the reading; while a reply arrives its text only grows,
        // so the longer of the two is the one to read.
        var source = source
        if streaming, identity == readingContext?.identity, source != reading.source, reading.source.hasUTF8Prefix(source) {
            source = reading.source
        }
        let sameReply = readingContext?.identity == identity
        readingContext = (style, capsWidth, streaming, headings, environment, identity)
        let readingStarted = TranscriptLayoutClock.recording && appending ? TranscriptLayoutClock.now : 0
        let records = reading.update(source, style: style, streaming: streaming, identity: identity)
        if readingStarted > 0 { TranscriptLayoutClock.markdownReadingSeconds += TranscriptLayoutClock.now - readingStarted }
        reconcile(records, unchangedPrefix: drewReading && sameReply ? reading.unchangedPrefix : 0, sourceText: source,
                  inputs: Inputs(style: style, capsWidth: capsWidth, streaming: streaming, headings: headings, environment: environment))
        drewReading = true
    }

    /// A token arrived: this reply's text grew by a suffix. Only what reads
    /// differently is set again and laid out again. Returns how much taller
    /// the message became, or nil when this surface is not the one carrying
    /// that reply.
    func appendStreaming(_ next: String, identity: String) -> CGFloat? {
        let appendStarted = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownAppendSeconds += TranscriptLayoutClock.now - appendStarted } }
        guard let context = readingContext, context.streaming, context.identity == identity, !identity.isEmpty,
              bounds.width > 0, next.utf8.count > reading.source.utf8.count, !reading.source.isEmpty,
              next.hasUTF8Prefix(reading.source) else { return nil }
        let before = measure(width: bounds.width).height
        appending = true
        read(source: next, style: context.style, capsWidth: context.capsWidth, streaming: true,
             headings: context.headings, environment: context.environment, identity: identity)
        appending = false
        let after = measure(width: bounds.width).height
        if abs(bounds.height - after) > 0.01 { setFrameSize(NSSize(width: bounds.width, height: after)) }
        needsLayout = true
        appendCount += 1
        return after - before
    }

    /// Draws a list of blocks that is not this surface's own reading (tests,
    /// and bodies handed their blocks).
    func update(blocks source: [MarkdownBlock], style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
                headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identities: [MarkdownBlockIdentity]? = nil,
                sourceText: String? = nil, sourceRanges: [Range<Int>]? = nil) {
        let ids = identities?.count == source.count ? identities! : source.indices.map { MarkdownBlockIdentity(generation: 0, sourceOffset: $0) }
        let records = source.indices.map { index in
            StreamingMarkdownRecord(id: ids[index], range: sourceRanges.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? 0..<0,
                                    block: source[index], provisional: false)
        }
        drewReading = false
        reconcile(records, unchangedPrefix: 0, sourceText: sourceText,
                  inputs: Inputs(style: style, capsWidth: capsWidth, streaming: streaming, headings: headings, environment: environment))
    }

    /// Sets the text for `records`. The records before `unchangedPrefix` are
    /// the ones the last update drew, unchanged; the rest are compared with
    /// the blocks drawn, and the text is replaced only from the first
    /// character that reads differently.
    private func reconcile(_ records: [StreamingMarkdownRecord], unchangedPrefix: Int, sourceText: String?, inputs: Inputs) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownUpdateSeconds += TranscriptLayoutClock.now - clock } }
        guard let storage = textView.textStorage else { return }
        enclosingScrollView?.transcriptReading.capture(self)
        applyAppearance(inputs.environment)
        let sameText = lastInputs.map { $0.hasSameText(as: inputs) } ?? false
        // The records the reading says are unchanged keep their text without
        // being looked at; the rest are taken apart into units and compared.
        let keepRecords = sameText ? min(unchangedPrefix, records.count, recordIdentities.count) : 0
        // Identities made unique, as the reading can repeat one; the records
        // kept keep theirs, so a token does not walk the reply for this.
        for id in recordIdentities[keepRecords...] { identitySet.remove(id) }
        recordIdentities.removeSubrange(keepRecords...)
        for record in records[keepRecords...] {
            var id = record.id
            while !identitySet.insert(id).inserted { id.component += 1 }
            recordIdentities.append(id)
        }
        let identities = recordIdentities
        // Found from the end: a token changes the reply's last records, and a
        // search from the start would walk every block of a long reply.
        var keep = segments.count
        while keep > 0, segments[keep - 1].record >= keepRecords { keep -= 1 }
        let context = MarkdownTextContext(style: inputs.style, capsWidth: inputs.capsWidth)
        var units: [Unit] = []
        for index in keepRecords..<records.count {
            let record = records[index]
            let range: Range<Int>? = record.range.isEmpty ? nil : record.range
            if case .list(let ordered, let start, let items) = record.block, !items.isEmpty {
                let column = builder.markerColumn(ordered: ordered, start: start, count: items.count, style: inputs.style)
                for (item, blocks) in items.enumerated() {
                    var id = identities[index]; id.segment = item + 1
                    units.append(Unit(identity: id, block: .list(ordered: ordered, start: start + item, items: [blocks]),
                                      item: ItemPlace(ordered: ordered, number: start + item, column: column, first: item == 0),
                                      record: index, sourceRange: range))
                }
            } else {
                units.append(Unit(identity: identities[index], block: record.block, item: nil, record: index, sourceRange: range))
            }
        }
        var compared = 0
        while sameText, compared < units.count, keep < segments.count, segments[keep].identity == units[compared].identity,
              segments[keep].item == units[compared].item, segments[keep].block == units[compared].block {
            reconciledBlockVisits += 1
            segments[keep].record = units[compared].record
            keep += 1; compared += 1
        }
        let oldCount = segments.count
        guard compared < units.count || keep < oldCount || !sameText else {
            lastInputs = inputs; priorSourceText = sourceText
            updateCaret()
            return
        }
        // A token on the fence at the reply's end sets only the code it adds.
        if sameText, compared == units.count - 1, keep == oldCount - 1, extendOpenFence(units[compared], at: keep, storage: storage, inputs: inputs) {
            finish(inputs: inputs, sourceText: sourceText)
            return
        }
        let editStart = keep < oldCount ? segments[keep].range.location : storage.length
        // The paragraphs about to be set again, as they read now.
        var former: [MarkdownBlockIdentity: (text: String, content: NSRange, source: Range<Int>?)] = [:]
        for index in keep..<oldCount {
            guard case .paragraph = segments[index].block else { continue }
            let content = contentRange(index)
            former[segments[index].identity] = ((storage.string as NSString).substring(with: content), content, segments[index].sourceRange)
        }
        var tail = keep > 0 ? segments[keep - 1].tail : nil
        var headings = keep > 0 ? segments[keep - 1].headings : 0
        var previousItem = keep > 0 ? segments[keep - 1].item.map { _ in segments[keep - 1].record } : nil
        let replacement = NSMutableAttributedString()
        var built: [Segment] = []
        for unit in units[compared...] {
            reconciledBlockVisits += 1
            var headingIndex: Int?
            if unit.item == nil, case .heading = unit.block { headingIndex = headings; headings += 1 }
            let first = keep + built.count == 0
            let paragraphs: [MarkdownTextParagraph]
            if let item = unit.item, case .list(_, _, let items) = unit.block {
                paragraphs = builder.listItem(items[0], number: item.number, ordered: item.ordered, column: item.column, identity: unit.identity,
                                              context: context, gap: item.first ? (first ? 0 : MarkdownTextLayout.blockGap) : MarkdownTextLayout.listItemGap)
            } else {
                paragraphs = builder.paragraphs(unit.block, identity: unit.identity, context: context,
                                                gap: first ? 0 : MarkdownTextLayout.blockGap, headingIndex: headingIndex)
            }
            guard !paragraphs.isEmpty else {
                // A block with nothing to show (an empty table) keeps its place.
                built.append(Segment(identity: unit.identity, block: unit.block, item: unit.item, record: unit.record, sourceRange: nil,
                                     range: NSRange(location: editStart + replacement.length, length: 0),
                                     tail: tail ?? Tail(spacing: MarkdownTextTail(lineSpacing: 0, bottomPad: 0), breakCopy: "", attributes: [:]),
                                     headings: headings))
                continue
            }
            // Between two items of one list a copy puts one line break.
            let sibling = unit.item != nil && !(unit.item?.first ?? true) && previousItem == unit.record
            let (text, end) = MarkdownTextAssembler.text(paragraphs, after: tail?.spacing, leadingBreak: sibling ? "\n" : tail?.breakCopy,
                                                         leadingAttributes: tail?.attributes ?? [:])
            let location = editStart + replacement.length
            replacement.append(text)
            let last = paragraphs[paragraphs.count - 1]
            var attributes = last.marks
            if text.length > 0 {
                for key in [NSAttributedString.Key.font, .paragraphStyle] {
                    if let value = text.attribute(key, at: text.length - 1, effectiveRange: nil) { attributes[key] = value }
                }
            }
            let segmentTail = Tail(spacing: end ?? MarkdownTextTail(lineSpacing: 0, bottomPad: 0), breakCopy: last.breakCopy, attributes: attributes)
            built.append(Segment(identity: unit.identity, block: unit.block, item: unit.item, record: unit.record, sourceRange: unit.sourceRange,
                                 range: NSRange(location: location, length: text.length), tail: segmentTail, headings: headings))
            tail = segmentTail
            previousItem = unit.item != nil ? unit.record : nil
        }
        // A paragraph that reads differently maps its old characters to its
        // new ones through the source.
        for index in built.indices {
            guard case .paragraph = built[index].block, let old = former[built[index].identity] else { continue }
            let skip = built[index].range.length > 0 && keep + index > 0 ? 1 : 0
            let local = NSRange(location: built[index].range.location - editStart + skip, length: max(0, built[index].range.length - skip))
            let text = (replacement.string as NSString).substring(with: local)
            guard text != old.text, !text.hasUTF8Prefix(old.text), let sourceText, let range = built[index].sourceRange,
                  let current = MarkdownSelection.Source(sourceText, bytes: range) else { continue }
            let previous = priorSourceText.flatMap { prior in old.source.flatMap { MarkdownSelection.Source(prior, bytes: $0) } }
            built[index].reconciliation = MarkdownSelection.Reconciliation(previous: old.text, source: current, previousSource: previous,
                                                                          rendered: text, keepsSoftBreaks: inputs.style.keepsSoftBreaks)
        }
        // Only the characters that read differently are replaced: a token
        // that extends the last block adds its own characters, and TextKit
        // lays out again from there, not the reply.
        let oldRange = NSRange(location: editStart, length: storage.length - editStart)
        let common = Self.commonPrefix(storage, oldRange, replacement)
        // And the characters at the end that read the same: a block that
        // changed in the middle (a reference defined late) is replaced alone,
        // and what follows it keeps its characters, and a selection in it.
        let suffix = Self.commonSuffix(storage, NSRange(location: oldRange.location + common, length: oldRange.length - common),
                                       replacement, NSRange(location: common, length: replacement.length - common))
        let replaced = NSRange(location: editStart + common, length: oldRange.length - common - suffix)
        let inserted = replacement.attributedSubstring(from: NSRange(location: common, length: replacement.length - common - suffix))
        let shift = inserted.length - replaced.length
        lastReplacedLocation = replaced.location; lastReplacedLength = inserted.length
        if replaced.length > 0 || inserted.length > 0 {
            let selections = textView.selectedRanges.map(\.rangeValue)
            storage.beginEditing()
            storage.replaceCharacters(in: replaced, with: inserted)
            storage.endEditing()
            // A selection above the change is untouched; one inside a
            // paragraph that reads differently follows its characters; any
            // other keeps what of it still fits the text.
            let length = storage.length
            let kept = selections.map { range -> NSValue in
                if NSMaxRange(range) <= replaced.location { return NSValue(range: range) }
                if range.location >= NSMaxRange(replaced) { return NSValue(range: NSRange(location: range.location + shift, length: range.length)) }
                for (offset, segment) in built.enumerated() {
                    guard let reconciliation = segment.reconciliation, let old = former[segment.identity],
                          range.location >= old.content.location, NSMaxRange(range) <= NSMaxRange(old.content),
                          let mapped = reconciliation.range(NSRange(location: range.location - old.content.location, length: range.length)) else { continue }
                    let skip = segment.range.length > 0 && keep + offset > 0 ? 1 : 0
                    return NSValue(range: NSRange(location: segment.range.location + skip + mapped.location, length: mapped.length))
                }
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            if kept.map(\.rangeValue) != textView.selectedRanges.map(\.rangeValue) { textView.selectedRanges = kept }
            sizes.removeAll(keepingCapacity: true)
        }
        largeTables += built.reduce(0) { $0 + (Self.isLargeTable($1.block) ? 1 : 0) }
            - segments[keep...].reduce(0) { $0 + (Self.isLargeTable($1.block) ? 1 : 0) }
        segments.replaceSubrange(keep..., with: built)
        if !appending { builder.retain(segments.map(\.identity)) }
        finish(inputs: inputs, sourceText: sourceText)
    }

    /// A token on the fence still being written at the reply's end: the code
    /// it adds is appended, and colour is set again only from the scanner's
    /// last neutral point, not over the whole fence.
    private func extendOpenFence(_ unit: Unit, at index: Int, storage: NSTextStorage, inputs: Inputs) -> Bool {
        let segment = segments[index]
        guard segment.identity == unit.identity, segment.item == nil, unit.item == nil, NSMaxRange(segment.range) == storage.length,
              case .code(let oldLanguage, let oldCode) = segment.block, case .code(let language, let code) = unit.block,
              oldLanguage == language, code.utf8.count > oldCode.utf8.count, code.hasUTF8Prefix(oldCode) else { return false }
        let context = MarkdownTextContext(style: inputs.style, capsWidth: inputs.capsWidth)
        let (paragraph, reading) = builder.code(language: language, code: code, identity: unit.identity, context: context,
                                                gap: index == 0 ? 0 : MarkdownTextLayout.blockGap)
        let codeStart = segment.range.location + (index > 0 ? 1 : 0)
        let oldLength = storage.length - codeStart, text = reading.text
        guard codeStart < storage.length, text.length > oldLength, reading.recolorFrom <= oldLength else { return false }
        let first = storage.attribute(.paragraphStyle, at: codeStart, effectiveRange: nil)
        let rest = MarkdownTextAssembler.style(paragraph, after: nil, firstLine: false)
        let firstLineEnd = (text.string as NSString).range(of: "\n").location
        let from = codeStart + reading.recolorFrom
        // TextKit moves a selection to the end of text appended while the
        // view holds it; the reader's selection stays where they made it.
        let selections = textView.selectedRanges.map(\.rangeValue)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: (text.string as NSString).substring(from: oldLength))
        text.enumerateAttributes(in: NSRange(location: reading.recolorFrom, length: text.length - reading.recolorFrom)) { attributes, range, _ in
            var dressed = attributes
            dressed[.piCodeBlock] = reading.mark
            storage.setAttributes(dressed, range: NSRange(location: codeStart + range.location, length: range.length))
        }
        storage.addAttribute(.paragraphStyle, value: rest, range: NSRange(location: from, length: storage.length - from))
        if let first, firstLineEnd == NSNotFound || codeStart + firstLineEnd >= from {
            let end = firstLineEnd == NSNotFound ? storage.length : min(storage.length, codeStart + firstLineEnd + 1)
            if end > from { storage.addAttribute(.paragraphStyle, value: first, range: NSRange(location: from, length: end - from)) }
        }
        storage.endEditing()
        let length = storage.length
        let kept = selections.map { range -> NSValue in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        if kept.map(\.rangeValue) != textView.selectedRanges.map(\.rangeValue) { textView.selectedRanges = kept }
        lastReplacedLocation = from; lastReplacedLength = storage.length - from
        segments[index].block = unit.block; segments[index].record = unit.record
        segments[index].range.length = storage.length - segments[index].range.location
        sizes.removeAll(keepingCapacity: true)
        return true
    }

    /// What every change of the text ends with.
    private func finish(inputs: Inputs, sourceText: String?) {
        if lastInputs?.style.id != inputs.style.id {
            textView.setAccessibilityLabel(inputs.style.id.hasPrefix("reasoning") ? "Reasoning" : inputs.style.id.hasPrefix("summary") ? "Summary" : "Reply")
        }
        lastInputs = inputs; priorSourceText = sourceText
        textView.topInset = firstInset()
        updateCaret()
        refreshHover()
        needsLayout = true
        // A token's own pass has already told the row how much taller the
        // message became. Advertising a new intrinsic size here would put the
        // whole row through SwiftUI a second time for the same text.
        guard !appending, !invalidationScheduled else { return }
        invalidationScheduled = true
        // Input changes can arrive during a parent's sizing pass. Let SwiftUI
        // finish that update before advertising a new intrinsic size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            self.invalidateIntrinsicContentSize()
        }
    }

    /// How many characters at the start of `old` (a range of `storage`) and
    /// `new` are the same characters, dressed the same.
    private static func commonPrefix(_ storage: NSTextStorage, _ old: NSRange, _ new: NSAttributedString) -> Int {
        let limit = min(old.length, new.length)
        guard limit > 0 else { return 0 }
        let oldText = storage.string as NSString, newText = new.string as NSString
        var same = 0
        let chunk = 4_096
        var mine = [unichar](repeating: 0, count: chunk), theirs = [unichar](repeating: 0, count: chunk)
        while same < limit {
            let count = min(chunk, limit - same)
            oldText.getCharacters(&mine, range: NSRange(location: old.location + same, length: count))
            newText.getCharacters(&theirs, range: NSRange(location: same, length: count))
            var index = 0
            while index < count, mine[index] == theirs[index] { index += 1 }
            same += index
            if index < count { break }
        }
        // The same characters can be dressed differently: a word that has
        // just become a keyword, a run that has just become bold.
        var location = 0
        while location < same {
            var mineRun = NSRange(), theirRun = NSRange()
            let a = storage.attributes(at: old.location + location, effectiveRange: &mineRun)
            let b = new.attributes(at: location, effectiveRange: &theirRun)
            guard NSDictionary(dictionary: a).isEqual(to: b) else { return location }
            let next = min(NSMaxRange(mineRun) - old.location, NSMaxRange(theirRun))
            guard next > location else { break }
            location = next
        }
        return min(location, same)
    }

    /// How many characters at the end of `old` (a range of `storage`) and of
    /// `newRange` in `new` are the same characters, dressed the same.
    private static func commonSuffix(_ storage: NSTextStorage, _ old: NSRange, _ new: NSAttributedString, _ newRange: NSRange) -> Int {
        let limit = min(old.length, newRange.length)
        guard limit > 0 else { return 0 }
        let oldText = storage.string as NSString, newText = new.string as NSString
        var same = 0
        let chunk = 4_096
        var mine = [unichar](repeating: 0, count: chunk), theirs = [unichar](repeating: 0, count: chunk)
        while same < limit {
            let count = min(chunk, limit - same)
            oldText.getCharacters(&mine, range: NSRange(location: NSMaxRange(old) - same - count, length: count))
            newText.getCharacters(&theirs, range: NSRange(location: NSMaxRange(newRange) - same - count, length: count))
            var index = count - 1
            while index >= 0, mine[index] == theirs[index] { index -= 1 }
            same += count - 1 - index
            if index >= 0 { break }
        }
        var matched = 0
        while matched < same {
            var mineRun = NSRange(), theirRun = NSRange()
            let a = storage.attributes(at: NSMaxRange(old) - matched - 1, effectiveRange: &mineRun)
            let b = new.attributes(at: NSMaxRange(newRange) - matched - 1, effectiveRange: &theirRun)
            guard NSDictionary(dictionary: a).isEqual(to: b) else { return matched }
            let back = min(NSMaxRange(old) - matched - mineRun.location, NSMaxRange(newRange) - matched - theirRun.location)
            guard back > 0 else { break }
            matched += back
        }
        return min(matched, same)
    }

    /// The room above the first line, which TextKit gives no paragraph at
    /// the very top: a fence's padding, a heading's, a table's.
    private func firstInset() -> CGFloat {
        guard let first = segments.first else { return 0 }
        switch first.block {
        case .code: return MarkdownTextLayout.codeTop
        case .heading: return MarkdownTextLayout.headingTop
        case .table(_, let header, let rows): return MarkdownTablePresentation.isLarge(header: header, rows: rows) ? 0 : MarkdownTextLayout.tablePad
        default: return 0
        }
    }
    /// The room below the last line: a fence's padding, a table's.
    private func lastInset() -> CGFloat { segments.last?.tail.spacing.bottomPad ?? 0 }

    private func applyAppearance(_ environment: TranscriptRowEnvironment) {
        // Colours are dynamic and resolve against the appearance the text is
        // drawn in; the row's colour scheme and contrast decide it.
        let dark = environment.colorScheme == .dark
        let increased = environment.contrast == .increased
        let name: NSAppearance.Name = increased ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
        if appearance?.name != name { appearance = NSAppearance(named: name); textView.needsDisplay = true }
    }

    // MARK: Measuring

    /// Replies longer than this are not laid out again while the window is
    /// being resized: they keep their height until the resize ends.
    static let liveResizeLength = 200_000

    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (bounds.width > 0 ? bounds.width : TranscriptMetrics.pageWidth)
        if let size = sizes.last(where: { $0.width == width }) { return size }
        guard let storage = textView.textStorage, storage.length > 0, let container = textView.textContainer,
              let manager = textView.layoutManager else { return CGSize(width: width, height: 0) }
        if inLiveResize || window?.inLiveResize == true, storage.length > Self.liveResizeLength, let last = sizes.last {
            return CGSize(width: width, height: last.height)
        }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownLayoutSeconds += TranscriptLayoutClock.now - clock } }
        if container.containerSize.width != width { container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        manager.ensureLayout(for: container)
        layoutPasses += 1
        let used = manager.usedRect(for: container)
        let height = ceil(textView.topInset + used.maxY + lastInset())
        let size = CGSize(width: width, height: max(1, height))
        if sizes.count == 4 { sizes.removeFirst() }
        sizes.append(size)
        return size
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: sizes.last(where: { $0.width == bounds.width })?.height ?? NSView.noIntrinsicMetric)
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard textLength > Self.liveResizeLength else { return }
        sizes.removeAll(); needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        if textView.frame != bounds { textView.frame = bounds }
        let deferResize = (inLiveResize || window?.inLiveResize == true) && textLength > Self.liveResizeLength
        if !deferResize, textView.textContainer?.containerSize.width != bounds.width {
            textView.textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        placeTableActions()
        updateCaret()
        enclosingScrollView?.transcriptReading.geometryChanged()
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        enclosingScrollView?.transcriptReading.restore()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCaret()
    }

    // MARK: Reading position

    /// Where the reader's line is, in the reply: a block and a character in
    /// it, independent of the heights around it.
    struct CharacterAnchor: Equatable {
        /// The character, from the start of its block's text.
        var offset: Int
        /// Its block's text when it was taken: a block that reads differently
        /// since maps it through the source.
        var rendered: String
        /// How far its line's top stood below the reader's line.
        var displacement: CGFloat
        /// Where it came from in the message's source, when known.
        var range: NSRange?
    }
    struct LogicalAnchor: Equatable {
        var block: MarkdownBlockIdentity
        var offset: CGFloat
        var character: CharacterAnchor? = nil
        var sourceUTF16Range: NSRange? { character?.range }
    }
    private var observedClip: NSClipView? { enclosingScrollView?.contentView }
    var logicalAnchor: LogicalAnchor? { preparedLogicalAnchor }
    var preparedLogicalAnchor: LogicalAnchor? {
        guard !isParked, let clip = observedClip else { return nil }
        let top = convert(clip.bounds, from: clip).minY
        return anchor(at: top)
    }
    private func anchor(at top: CGFloat) -> LogicalAnchor? {
        guard let manager = textView.layoutManager as? MarkdownTextLayoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0, !segments.isEmpty else { return nil }
        let point = NSPoint(x: 1, y: max(0, top - textView.topInset))
        let glyph = manager.glyphIndex(for: point, in: container)
        let character = min(manager.characterIndexForGlyph(at: glyph), storage.length - 1)
        guard let index = segments.lastIndex(where: { $0.range.location <= character }) ?? segments.indices.first else { return nil }
        let segment = segments[index], content = contentRange(index)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let lineTop = line.minY + textView.topInset
        let blockTop = segmentTop(index) ?? lineTop
        let offset = max(0, character - content.location)
        var source: NSRange?
        if let text = priorSourceText, let bytes = segment.sourceRange, let located = MarkdownSelection.Source(text, bytes: bytes) {
            source = NSRange(location: located.range.location + offset, length: 1)
        }
        return LogicalAnchor(block: segment.identity, offset: blockTop - top,
                             character: CharacterAnchor(offset: offset, rendered: (storage.string as NSString).substring(with: content),
                                                        displacement: lineTop - top, range: source))
    }
    /// A segment's own characters, without the line break before it.
    private func contentRange(_ index: Int) -> NSRange {
        let range = segments[index].range
        let skip = index > 0 && range.length > 0 ? 1 : 0
        return NSRange(location: range.location + skip, length: range.length - skip)
    }
    private func segmentTop(_ index: Int) -> CGFloat? {
        guard let manager = textView.layoutManager, segments.indices.contains(index), let storage = textView.textStorage else { return nil }
        let location = min(segments[index].range.location + (index > 0 ? 1 : 0), max(0, storage.length - 1))
        let glyph = manager.glyphIndexForCharacter(at: location)
        guard glyph < manager.numberOfGlyphs else { return nil }
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.topInset
    }
    func displacement(of anchor: LogicalAnchor) -> CGFloat? {
        guard let clip = observedClip, let top = top(for: anchor) else { return nil }
        return top - convert(clip.bounds, from: clip).minY
    }
    /// Where the reader's line should be for the anchor to stand where it
    /// stood. If its block is gone, the nearest one before it stands in.
    func top(for anchor: LogicalAnchor) -> CGFloat? {
        let index = segments.firstIndex(where: { $0.identity == anchor.block }) ?? segments.lastIndex(where: {
            $0.identity.generation == anchor.block.generation && $0.identity.sourceOffset <= anchor.block.sourceOffset
        }) ?? segments.firstIndex(where: { $0.identity.generation == anchor.block.generation })
        guard let index, let manager = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 else { return nil }
        if let character = anchor.character, segments[index].identity == anchor.block {
            let content = contentRange(index)
            var offset = character.offset
            let current = (storage.string as NSString).substring(with: content)
            if current != character.rendered, !current.hasUTF8Prefix(character.rendered),
               let mapped = segments[index].reconciliation?.range(NSRange(location: character.offset, length: 1), from: character.rendered, to: current) {
                offset = mapped.location
            }
            let location = min(content.location + offset, storage.length - 1)
            let glyph = manager.glyphIndexForCharacter(at: location)
            if glyph < manager.numberOfGlyphs {
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return line.minY + textView.topInset - character.displacement
            }
        }
        guard let top = segmentTop(index) else { return nil }
        return top - anchor.offset
    }

    // MARK: Controls

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        hover(at: point)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverPoint = nil
        hideControls()
    }
    private func refreshHover() {
        guard toolbar?.superview != nil || headingAction?.superview != nil else { return }
        if let hoverPoint { hover(at: hoverPoint) } else { hideControls() }
    }
    /// The control for what the pointer is over: a fence's toolbar, a
    /// heading's copy button. They exist only while the pointer is there.
    private func hover(at point: NSPoint) {
        guard !isParked, let manager = textView.layoutManager as? MarkdownTextLayoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { hideControls(); return }
        let local = NSPoint(x: point.x, y: point.y - textView.topInset)
        let glyph = manager.glyphIndex(for: local, in: container)
        let character = min(manager.characterIndexForGlyph(at: glyph), storage.length - 1)
        // The fence under the pointer, its padding included.
        if let mark = storage.attribute(.piCodeBlock, at: character, effectiveRange: nil) as? MarkdownCodeMark {
            let extent = MarkdownTextLayoutManager.extent(of: mark, key: .piCodeBlock, around: NSRange(location: character, length: 1), in: storage)
            if let panel = manager.panelRect(for: extent, indent: mark.indent, container: container)?.offsetBy(dx: 0, dy: textView.topInset),
               panel.contains(point) {
                showToolbar(mark, panel: panel)
                hideHeadingAction()
                return
            }
        }
        hideToolbar()
        if let index = storage.attribute(.piHeading, at: character, effectiveRange: nil) as? Int,
           let targets = lastInputs?.headings, targets.indices.contains(index) {
            var run = NSRange()
            _ = storage.attribute(.piHeading, at: character, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length))
            if let box = manager.textBox(forCharacters: run)?.offsetBy(dx: 0, dy: textView.topInset),
               point.y >= box.minY - 4, point.y <= box.maxY + 4 {
                showHeadingAction(targets[index], index: index, box: box)
                return
            }
        }
        hideHeadingAction()
    }
    private func hideControls() { hideToolbar(); hideHeadingAction() }
    private func showToolbar(_ mark: MarkdownCodeMark, panel: NSRect) {
        // Made again on each move: the copy is of the code as it now reads.
        let content = MarkdownCodeToolbar(language: mark.language, code: mark.code, environment: lastInputs?.environment ?? TranscriptRowEnvironment())
        let view: NSHostingView<MarkdownCodeToolbar>
        if let toolbar { view = toolbar; if toolbarMark !== mark || !toolbarShows(mark.code) { view.rootView = content } }
        else { view = NSHostingView(rootView: content); view.sizingOptions = [.intrinsicContentSize]; toolbar = view }
        toolbarMark = mark
        let size = view.fittingSize
        view.frame = NSRect(x: panel.maxX - 8 - size.width, y: panel.minY + 5, width: size.width, height: 20)
        if view.superview !== self { addSubview(view, positioned: .above, relativeTo: textView) }
    }
    private func hideToolbar() { toolbar?.removeFromSuperview(); toolbarMark = nil }
    private func showHeadingAction(_ target: MarkdownCopyTarget, index: Int, box: NSRect) {
        let content = MarkdownHeadingAction(target: target, environment: lastInputs?.environment ?? TranscriptRowEnvironment())
        let view: NSHostingView<MarkdownHeadingAction>
        if let headingAction { view = headingAction; if headingActionIndex != index { view.rootView = content } }
        else { view = NSHostingView(rootView: content); view.sizingOptions = [.intrinsicContentSize]; headingAction = view }
        headingActionIndex = index
        let size = view.fittingSize
        let trailing = min(bounds.width, lastInputs?.capsWidth == false ? bounds.width : TranscriptMetrics.proseWidth) + 30
        view.frame = NSRect(x: trailing - size.width, y: box.midY - size.height / 2, width: size.width, height: size.height)
        if view.superview !== self { addSubview(view, positioned: .above, relativeTo: textView) }
    }
    private func hideHeadingAction() { headingAction?.removeFromSuperview(); headingActionIndex = nil }

    /// "Open full table" beside a large table's preview line: a control, so
    /// it is always there, not only under the pointer.
    private func toolbarShows(_ code: String) -> Bool { toolbar?.rootView.code.hasSameUTF8(as: code) ?? false }
    private func placeTableActions() {
        guard hasLargeTables || !tableActions.isEmpty else { return }
        guard hasLargeTables, let manager = textView.layoutManager as? MarkdownTextLayoutManager, let storage = textView.textStorage, !isParked else {
            for view in tableActions.values { view.removeFromSuperview() }
            tableActions = [:]; return
        }
        var wanted: [ObjectIdentifier: (MarkdownTableMark, NSRect)] = [:]
        storage.enumerateAttribute(.piChrome, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, let mark = storage.attribute(.piTable, at: range.location, effectiveRange: nil) as? MarkdownTableMark,
                  mark.large, let box = manager.textBox(forCharacters: range) else { return }
            wanted[ObjectIdentifier(mark)] = (mark, box.offsetBy(dx: 0, dy: textView.topInset))
        }
        for (key, view) in tableActions where wanted[key] == nil { view.removeFromSuperview(); tableActions[key] = nil }
        for (key, entry) in wanted {
            let view = tableActions[key] ?? NSHostingView(rootView: MarkdownTableAction(mark: entry.0, environment: lastInputs?.environment ?? TranscriptRowEnvironment()))
            view.sizingOptions = [.intrinsicContentSize]
            let size = view.fittingSize
            let right = min(bounds.width, lastInputs?.capsWidth == false ? bounds.width : TranscriptMetrics.proseWidth)
            view.frame = NSRect(x: right - size.width, y: entry.1.midY - size.height / 2, width: size.width, height: size.height)
            if view.superview !== self { addSubview(view, positioned: .above, relativeTo: textView) }
            tableActions[key] = view
        }
    }

    /// The caret after the last word while a reply is still being written,
    /// in a paragraph or heading, as the rows drew it.
    private func updateCaret() {
        guard let inputs = lastInputs, inputs.streaming, !isParked, let last = segments.last,
              let manager = textView.layoutManager as? MarkdownTextLayoutManager, let storage = textView.textStorage,
              storage.length > 0, manager.numberOfGlyphs > 0 else { caret.isHidden = true; return }
        switch last.block { case .paragraph, .heading: break; default: caret.isHidden = true; return }
        guard textView.textContainer?.containerSize.width == bounds.width || bounds.width == 0 else { caret.isHidden = true; return }
        let glyph = manager.numberOfGlyphs - 1
        let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let advance = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer!).maxX
        let size = inputs.style.baseSize
        let x = advance + 5
        caret.frame = NSRect(x: x, y: used.maxY + textView.topInset - size, width: 2, height: size)
        caret.isHidden = false
        caret.blink(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// The blinking bar at the end of a reply still being written.
@MainActor final class MarkdownCaretView: NSView {
    private var blinking = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(TranscriptPalette.accent).cgColor
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor(TranscriptPalette.accent).cgColor }
    }
    func blink(_ on: Bool) {
        guard on != blinking else { return }
        blinking = on
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        guard on else { layer.opacity = 1; return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0, 0]; animation.keyTimes = [0, 0.5, 0.5, 1]
        animation.duration = 1; animation.repeatCount = .infinity
        layer.add(animation, forKey: "blink")
    }
}

/// A fence's toolbar: its language and a copy of its whole code.
struct MarkdownCodeToolbar: View {
    let language: String?
    let code: String
    let environment: TranscriptRowEnvironment
    var body: some View {
        HStack(spacing: 6) {
            if let language {
                Text(language.lowercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TranscriptPalette.faint).accessibilityLabel("Language \(language)")
            }
            CopyButton(target: MarkdownCopyTarget(kind: .code, label: "Copy code", text: code), visible: true)
        }
        .frame(height: 20)
        .environment(\.colorScheme, environment.colorScheme)
    }
}

/// A heading's copy button: its section, as markdown.
struct MarkdownHeadingAction: View {
    let target: MarkdownCopyTarget
    let environment: TranscriptRowEnvironment
    var body: some View {
        CopyButton(target: target, visible: true).environment(\.colorScheme, environment.colorScheme)
    }
}

/// "Open full table" for a table shown as a preview.
struct MarkdownTableAction: View {
    let mark: MarkdownTableMark
    let environment: TranscriptRowEnvironment
    var body: some View {
        Button("Open full table") { MarkdownTableWindow.open(header: mark.header, rows: mark.rows) }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(TranscriptPalette.accent)
            .piPointer()
            .environment(\.colorScheme, environment.colorScheme)
    }
}
