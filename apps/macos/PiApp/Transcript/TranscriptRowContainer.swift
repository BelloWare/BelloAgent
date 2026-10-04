import SwiftUI
import AppKit

/// Values affecting the row's own rendering must cross the hosting boundary.
/// Reduce Motion remains a system accessibility environment in both hosts.
struct TranscriptRowEnvironment: Equatable {
    var colorScheme: ColorScheme
    var contrast: ColorSchemeContrast
    var dynamicTypeSize: DynamicTypeSize
    var layoutDirection: LayoutDirection
    var locale: Locale
    var isEnabled: Bool
    /// Whether the chat's replies offer "Fork from here" (`transcriptForks`).
    var forks: Bool
    /// Whether file tools' paths open their files (`transcriptOpensFiles`).
    var opensFiles: Bool
    init(_ values: EnvironmentValues = EnvironmentValues()) {
        colorScheme = values.colorScheme; contrast = values.colorSchemeContrast
        dynamicTypeSize = values.dynamicTypeSize; layoutDirection = values.layoutDirection; locale = values.locale
        isEnabled = values.isEnabled; forks = values.transcriptForks; opensFiles = values.transcriptOpensFiles
    }
    /// Whether a row measured under these values is as tall under those.
    /// The type size, the writing direction and the locale decide how text
    /// wraps; the colour scheme, the contrast and whether the pane takes input
    /// only decide how it is painted. The pane is disabled while Reports is
    /// in front, and that must not cost every row its measurement.
    func hasSameGeometry(as other: TranscriptRowEnvironment) -> Bool {
        return dynamicTypeSize == other.dynamicTypeSize && layoutDirection == other.layoutDirection && locale == other.locale
    }
}

struct TranscriptHostedRow: View {
    init(_ inputs: TranscriptRowInputs) {
        item = inputs.item; fresh = inputs.fresh; actions = inputs.actions; width = inputs.width
        environment = inputs.environment; disclosure = inputs.disclosure; toggle = inputs.toggle
        workListHeight = inputs.workListHeight; workListMeasured = inputs.workListMeasured; foldInMotion = inputs.foldInMotion
    }
    let item: TranscriptItem
    let fresh: Bool
    let actions: TranscriptActions
    let width: CGFloat
    let environment: TranscriptRowEnvironment
    /// Plain values, not observed state: the row host knows what the reader
    /// opened, so it can re-measure this row in the same pass as the click.
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// What this turn's work list measured last time it was open, kept by the
    /// row container so a fold costs a frame change rather than sixty rows of
    /// native layout.
    var workListHeight: CGFloat? = nil
    var workListMeasured: (CGFloat) -> Void = { _ in }
    /// True while the document is moving this row between two measured
    /// heights, so a folding work list stays on screen and slides away.
    var foldInMotion = false
    /// Whether this message draws nothing at all: its turn has folded behind
    /// one line, or its response has folded and this is the header line's own
    /// figures, which that line already carries.
    private func drawsNothing(_ message: TranscriptMessage) -> Bool {
        disclosure.foldedAway || (message.kind == "requestInfo" && disclosure.responseFolded)
    }
    var body: some View {
        Group {
            switch item {
            case .message(let message):
                // A row a fold has emptied must take up nothing: the paragraph
                // spacing reserved around every message would otherwise leave
                // fourteen points of blank where the fold swallowed the row.
                let blank = drawsNothing(message)
                MessageRowView(message: message, actions: actions, disclosure: disclosure, toggle: toggle, switchesSource: true).equatable()
                    .padding(.top, blank ? 0 : (message.role == "user" ? 14 : 4))
                    .padding(.bottom, blank ? 0 : (message.role == "user" ? 4 : 10))
            case .block(let block):
                BlockRowView(block: block, actions: actions, fresh: fresh, disclosure: disclosure, toggle: toggle,
                             workListHeight: workListHeight, workListMeasured: workListMeasured,
                             foldInMotion: foldInMotion).equatable()
            }
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, environment.colorScheme)
        .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
        .environment(\.layoutDirection, environment.layoutDirection)
        .environment(\.locale, environment.locale)
        .environment(\.transcriptForks, environment.forks)
        .environment(\.transcriptOpensFiles, environment.opensFiles)
        .disabled(!environment.isEnabled)
        // No control in a row draws the system's focus ring; the ones that
        // take focus on purpose draw their own (`TranscriptFocusRing`).
        .focusEffectDisabled()
        .piStableLayout()
    }
}

/// The SwiftUI row, for items whose content has not been ported yet.
final class TranscriptHostedRowContent: NSHostingView<TranscriptHostedRow>, TranscriptRowContent {
    weak var owner: TranscriptRowContainer?
    convenience init(inputs: TranscriptRowInputs) {
        self.init(rootView: TranscriptHostedRow(inputs))
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
    }
    func accepts(_ item: TranscriptItem) -> Bool { true }
    func apply(_ inputs: TranscriptRowInputs) { rootView = TranscriptHostedRow(inputs) }
    func settle() -> (height: CGFloat, passes: Int) {
        // One native pass. The host is laid out at the width the text wraps
        // at; the height it settles on is read from that same pass through
        // the intrinsic size SwiftUI has just computed, so nothing asks it to
        // size the tree a second time for the same answer.
        layoutSubtreeIfNeeded()
        let intrinsic = intrinsicContentSize.height
        // A host that has not published one yet is asked directly; that is a
        // second pass, and the count is what says how often it happens.
        return intrinsic > 0 ? (max(1, ceil(intrinsic)), 1) : (max(1, ceil(fittingSize.height)), 2)
    }
    func confirmHeight() -> CGFloat { max(1, ceil(fittingSize.height)) }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }
}

@MainActor final class TranscriptRowContainer: NSView {
    var onHeightInvalidated: (() -> Void)?
    var onHeightValidated: (() -> Void)?
    /// The SwiftUI tree this row draws through, built the first time the row
    /// is measured or mounted and let go of once the reader has scrolled well
    /// past it. A page of three hundred rows would otherwise hold three
    /// hundred hosting views, which is most of what opening or leaving a long
    /// chat used to cost. The row keeps what it is, what it measured and what
    /// the reader opened in it either way.
    private var hosted: (NSView & TranscriptRowContent)?
    private(set) var item: TranscriptItem
    private var fresh: Bool
    private var actions: TranscriptActions
    private var environment: TranscriptRowEnvironment
    private var measurements: [CGSize] = []
    private var measuring = false
    private var invalidationPending = false
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private let geometryCache: TranscriptGeometryCache?
    private let geometrySessionID: String?
    private let disclosureStore: TranscriptDisclosure?
    private let toolInputs: TranscriptToolInputs?
    /// Asks the conversation for a call's full arguments, with the id of the
    /// reply that made the call.
    var onToolInputNeeded: ((String, String) -> Void)?
    private var disclosure: TranscriptRowDisclosure
    /// The store and tool-document revisions `disclosure` was read at.
    private var disclosureRevisions = (-1, -1)
    /// Called when the reader opens or closes part of this row, so the document
    /// lays the rows out again in the same pass rather than a run loop later.
    var onDisclosureChanged: (() -> Void)?
    private var measurementScale: CGFloat?
    private var restoredMeasurementNeedsValidation = false
    /// Geometry inside FoldedWork, independently of the reply prose and turn
    /// footer. Usage that is actually inside the work list remains in this key:
    /// a longer model name can wrap and must invalidate the measured height.
    private struct ReplyWorkKey: Equatable {
        var id: String
        var thinking: String
        var streaming: Bool
        var tools: [ToolView]
        var accounting: GatewayTotals?
    }
    private struct WorkListKey: Equatable {
        var width: CGFloat
        var replies: [ReplyWorkKey]
        var openTools: Set<String>
        var openReasoning: Set<String>
        var inputs: [String: ToolInputDocument]
        var environment: TranscriptRowEnvironment
    }
    private var workList: (key: WorkListKey, height: CGFloat)?
    private var workListKey: WorkListKey {
        let replies: [ReplyWorkKey]
        if case .block(let block) = item {
            replies = block.replies.map { reply in
                let showsUsage = !(reply.tools ?? []).isEmpty || !(reply.thinking ?? "").isEmpty || reply.id != block.message?.id
                return ReplyWorkKey(id: reply.id, thinking: reply.thinking ?? "", streaming: reply.isStreaming,
                                    tools: reply.tools ?? [], accounting: showsUsage ? reply.accounting : nil)
            }
        } else { replies = [] }
        return WorkListKey(width: width, replies: replies, openTools: disclosure.openTools,
                           openReasoning: disclosure.openReasoning, inputs: disclosure.toolInputs, environment: environment)
    }
    /// How often this row has been able to reuse its work list's measured
    /// height instead of measuring sixty tool rows again.
    private(set) var workListReuses = 0
    /// Explicit exact-width cache misses, separately from AppKit's redundant
    /// intrinsic-size validation requests when a host reenters a window.
    private(set) var measurementCount = 0
    /// How many times SwiftUI has sized or laid this row's tree out.
    private(set) var nativeSizingPasses = 0
    private(set) var intrinsicValidationCount = 0
    private(set) var sharedMeasurementHits = 0
    var itemID: String { item.id }
    var contentItem: TranscriptItem { item }
    /// The values this row is drawn with, for checks that a change reached it.
    var renderingEnvironment: TranscriptRowEnvironment { environment }
    /// What the hosted content actually needs at this width, for checks that a
    /// row never draws more than its own frame holds.
    var hostedFittingHeight: CGFloat { host().confirmHeight() }
    /// Whether this row is holding a SwiftUI tree right now.
    var isHosted: Bool { hosted != nil }
    /// Set while this row's tree has not been laid out since it was built or
    /// its content changed. A row mounted only because it is near the
    /// viewport waits for the reader to actually reach it.
    private(set) var awaitingViewportLayout = false
    /// Builds the row's tree so it is ready to draw. A row near the viewport
    /// is prepared; only one the reader can actually see is laid out.
    func prepareToDraw() { host() }
    /// What a row about to arrive can usefully do before it arrives. Laying
    /// it out and drawing it into its backing store here as well was tried
    /// and measured: a first read through a four-hundred-row page went from
    /// 4.2 % of its steps over a 120 Hz frame to 8.3 %, because the work
    /// lands on the step that prepares the row instead of the step that
    /// shows it, and an unmounted row's drawing is thrown away. Building the
    /// tree is the part that pays.
    func prepareForTheReader() {
        host()
        // Laying it out here is what leaves the frame that shows it with
        // nothing to do. The shared scheduler admits one of these per frame,
        // so it is bounded; a row still standing at an estimate is left until
        // it has a height of its own.
        if hasMeasurement(width: width) { layoutForViewport() }
    }
    /// While the document is moving this row between two measured heights,
    /// the tree inside it stays at the height it was measured at and the row
    /// clips to the frame the motion is interpolating. Resizing the tree on
    /// every tick is the SwiftUI re-layout the motion exists to avoid.
    private var pinnedContentHeight: CGFloat?
    /// The part of the row the motion is revealing or hiding fades while the
    /// frame moves. It is one mask over the region the two states do not
    /// share, so every disclosure fades the same way — a turn's work, a tool
    /// card, exposed reasoning, a compaction summary — without any of them
    /// having to know about it, and without a hosting boundary per region.
    private var revealFade: CALayer?
    private var addedLayerForReveal = false
    var isInDisclosureMotion: Bool { pinnedContentHeight != nil }
    /// True while a folding work list must stay placed although the row is
    /// closing, so it slides out of sight instead of vanishing first.
    private var keepingFoldedContent = false
    func beginDisclosureMotion(contentHeight: CGFloat, keepingContentPlaced: Bool) {
        pinnedContentHeight = max(1, contentHeight)
        // Opening, the content is placed anyway; only a closing row has to be
        // told to keep it, and only then is the tree worth rebuilding.
        if keepingContentPlaced {
            keepingFoldedContent = true
            updateRoot()
        }
        if layer == nil { wantsLayer = true; addedLayerForReveal = true }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        let fade = CALayer()
        fade.backgroundColor = NSColor.black.cgColor
        mask.addSublayer(fade)
        revealFade = fade
        layer?.mask = mask
        needsLayout = true
        layout()
    }
    func endDisclosureMotion() {
        guard pinnedContentHeight != nil else { return }
        pinnedContentHeight = nil
        layer?.mask = nil
        revealFade = nil
        if addedLayerForReveal { wantsLayer = false; addedLayerForReveal = false }
        if keepingFoldedContent {
            keepingFoldedContent = false
            updateRoot()
        }
        needsLayout = true
    }
    /// The region the two states do not share, and how visible it is. The
    /// part both states have stays solid; the rest fades out as it goes and
    /// in as it arrives.
    func setDisclosureReveal(keeping: CGFloat, fade: CGFloat) {
        guard let revealFade, let mask = layer?.mask else { return }
        let height = max(1, pinnedContentHeight ?? bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width), height: max(1, keeping))
        revealFade.frame = CGRect(x: 0, y: max(0, keeping), width: max(1, bounds.width), height: max(0, height - keeping))
        revealFade.opacity = Float(min(1, max(0, fade)))
        CATransaction.commit()
    }
    /// Ends any selection in this row's text, for a row kept out of sight
    /// while the reader is in another chat (`TranscriptKeptRows`). A chat
    /// they come back to has nothing selected, as it always had; a selection
    /// left standing there would draw without the bar that acts on it.
    func forgetTextSelection() {
        func visit(_ view: NSView) {
            if let text = view as? NSTextView, text.selectedRange().length > 0 {
                text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0))
            }
            for child in view.subviews { visit(child) }
        }
        if let hosted { visit(hosted) }
    }
    /// Lets go of the SwiftUI tree for a row the reader has scrolled well
    /// past. Everything that decides what the row is and how tall it is
    /// stays, so coming back to it is one native layout and no measuring.
    func releaseHost() {
        guard let hosted, !measurements.isEmpty, !invalidationPending, !restoredMeasurementNeedsValidation,
              !ownsFirstResponder else { return }
        hosted.owner = nil
        hosted.removeFromSuperview()
        self.hosted = nil
    }
    /// Lays the row's tree out as it joins the view tree, so the frame that
    /// draws it has nothing left to do. A tree that is already laid out costs
    /// nothing here; a borrowed height is confirmed once, the first time the
    /// row is actually drawn.
    func layoutForViewport() {
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.viewportLayoutSeconds += TranscriptLayoutClock.now - started } }
        let hosted = host()
        if hosted.needsLayout || needsLayout {
            nativeSizingPasses += 1
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.rowSizingPasses += 1 }
        }
        layoutSubtreeIfNeeded()
        guard awaitingViewportLayout else { return }
        awaitingViewportLayout = false
        validateSharedMeasurementAfterMount()
    }
    func hasMeasurement(width: CGFloat) -> Bool { measurements.contains { $0.width == width } }
    /// The exact height this row already has at a width, or nil.
    func measuredHeight(width: CGFloat) -> CGFloat? { measurements.last { $0.width == width }?.height }
    /// A row nothing has ever measured, at any width: a chat the reader has
    /// just opened, or a page of earlier rows just prepended. Such a row may
    /// stand at an estimate until the page is about to draw it; a row whose
    /// content or width changed has a height to fall back on and never does.
    var neverMeasured: Bool { measurementCount == 0 && measurements.isEmpty }
    /// What this row is worth before anything has measured it. The page asks
    /// for this once per pass for every row it has not measured yet, so the
    /// answer is kept rather than counting the row's characters again.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        if let estimate, estimate.width == width { return estimate.height }
        let height = TranscriptRowEstimate.height(of: item, width: width, raw: disclosure.raw)
        estimate = (width, height)
        return height
    }
    private var estimate: (width: CGFloat, height: CGFloat)?
    var needsMountedValidation: Bool { invalidationPending || restoredMeasurementNeedsValidation || !hasMeasurement(width: width) }
    var ownsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder.isDescendant(of: self) { return true }
        // AppKit's shared field editor is attached to the window, not always
        // beneath its selectable NSTextField. Its delegate owns the selection.
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView {
            return field.isDescendant(of: self)
        }
        return false
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measurements.last { $0.width == width }?.height ?? NSView.noIntrinsicMetric)
    }
    init(item: TranscriptItem, fresh: Bool, actions: TranscriptActions, environment: TranscriptRowEnvironment = TranscriptRowEnvironment(),
         geometryCache: TranscriptGeometryCache? = nil, geometrySessionID: String? = nil, disclosure: TranscriptDisclosure? = nil,
         toolInputs: TranscriptToolInputs? = nil) {
        self.item = item; self.fresh = fresh; self.actions = actions; self.environment = environment
        self.geometryCache = geometryCache; self.geometrySessionID = geometrySessionID
        self.disclosureStore = disclosure
        self.toolInputs = toolInputs
        self.disclosure = disclosure.map { TranscriptRowDisclosure.of(item, in: $0, inputs: toolInputs) } ?? .default
        super.init(frame: .zero)
        // A row never paints outside itself, so a transient mismatch between a
        // resizing host and its frame can never draw over the next row.
        clipsToBounds = true
    }
    /// The row's SwiftUI tree, built if this is the first time it is needed.
    @discardableResult private func host() -> NSView & TranscriptRowContent {
        if let hosted { return hosted }
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.hostBuildSeconds += TranscriptLayoutClock.now - started
            TranscriptLayoutClock.hostBuilds += 1
        } }
        let view = TranscriptRowRenderer.content(for: item, inputs: inputs())
        view.owner = self
        hosted = view
        awaitingViewportLayout = true
        view.frame = bounds.width > 0 ? bounds : CGRect(x: 0, y: 0, width: width, height: 1)
        addSubview(view)
        return view
    }
    required init?(coder: NSCoder) { return nil }
    /// Where this row sits in the page, so the document can say from which
    /// row down a pass has to place anything.
    var layoutIndex = 0
    /// How many tokens this row has taken by extending the reply's own native
    /// surface, without SwiftUI rebuilding or re-sizing its tree.
    private(set) var streamingAppendCount = 0
    /// Tokens taken since this row was last measured for real. Every so often
    /// one is measured properly, so a long reply cannot drift away from what
    /// its tree actually needs.
    private var tokensSinceMeasured = 0
    static let tokensPerMeasurement = 64
    /// True while this row's reply has grown with no tree to grow: the reader
    /// is reading elsewhere. The page may stand it at an estimate until they
    /// come back, exactly as it stands unseen history.
    private(set) var grewWithoutATree = false
    /// True while the height this row holds came from the message's own
    /// surface measuring the block a token extended. The hosting view
    /// invalidates its intrinsic size for that same change; validating it
    /// would put the whole row through SwiftUI again for a height the row
    /// already has, and that second pass is most of what a token used to cost.
    private var streamingHeightKnown = false
    /// The surface carrying a reply, found once and kept while it streams.
    private weak var streamingSurface: NativeMarkdownContainer?
    private var streamingSurfaceID = ""
    private func surface(for messageID: String) -> NativeMarkdownContainer? {
        if let streamingSurface, streamingSurfaceID == messageID, streamingSurface.superview != nil,
           streamingSurface.readingIdentity == messageID { return streamingSurface }
        guard let hosted else { return nil }
        func visit(_ view: NSView) -> NativeMarkdownContainer? {
            if let surface = view as? NativeMarkdownContainer { return surface.readingIdentity == messageID ? surface : nil }
            for child in view.subviews { if let found = visit(child) { return found } }
            return nil
        }
        let found = visit(hosted)
        streamingSurface = found; streamingSurfaceID = messageID
        return found
    }
    /// What a row is drawn with besides its item. Any of it can decide the
    /// row's height: what the reader opened in it, the values it is drawn
    /// with, and the accent a row wears as it arrives.
    struct Look: Equatable {
        var disclosure: TranscriptRowDisclosure
        var environment: TranscriptRowEnvironment
        var fresh: Bool
    }
    /// A closed timeline part or call card is one line, whatever its text
    /// says, so it keeps its height while its text or arguments arrive: the
    /// same part — for a card, the same call in the same state — with
    /// nothing open in the row and nothing else about it changing.
    nonisolated static func closedPartKeepsHeight(from old: TranscriptItem, _ was: Look, to new: TranscriptItem, _ now: Look) -> Bool {
        guard case .block(let old) = old, case .block(let new) = new,
              old.presentation == new.presentation, old.presentation == .timeline || old.presentation == .work,
              let a = old.part, let b = new.part,
              !was.disclosure.work, !now.disclosure.work,
              was.disclosure.openTools.isEmpty, now.disclosure.openTools.isEmpty,
              !["text", "refusal", "status"].contains(a.part.kind) else { return false }
        // A call's card is one line while it is closed, whatever its
        // arguments say, so it keeps its height while they arrive — as
        // long as it is still the same call in the same state.
        if old.presentation == .work {
            guard let before = old.message?.tools?.first, let after = new.message?.tools?.first,
                  before.id == after.id, before.name == after.name, before.state == after.state else { return false }
        }
        // Everything the reader has opened or closed must agree, not only
        // this row's own work fold: a card whose whole response has just
        // been folded changes height although its own text has not.
        return was == now && a.part.kind == b.part.kind && a.part.name == b.part.name && a.state == b.state
    }
    /// A closed work list keeps its height while its calls change. Timeline
    /// tool cards have their own disclosure and live summary; only an
    /// unchanged, closed aggregate work list has fixed geometry.
    nonisolated static func closedWorkKeepsHeight(from old: TranscriptItem, _ was: Look, to new: TranscriptItem, _ now: Look) -> Bool {
        guard case .block(let old) = old, case .block(let new) = new else { return false }
        return old.presentation == .work && new.presentation == .work && old.part == nil && new.part == nil &&
            !was.disclosure.work && was == now
    }
    /// Returns whether anything that decides this row's height changed.
    @discardableResult
    func update(item: TranscriptItem, fresh: Bool, actions: TranscriptActions, environment: TranscriptRowEnvironment = TranscriptRowEnvironment()) -> Bool {
        self.actions = actions
        let sameItem = self.item == item
        // New content can bring parts the reader already opened or closed.
        // Otherwise what the row shows open changes only when the reader
        // opens or closes something, or a card's document lands: not with
        // every token of a reply somewhere else on the page.
        let disclosure: TranscriptRowDisclosure
        let revisions = (disclosureStore?.revision ?? -1, toolInputs?.revision ?? -1)
        if sameItem, revisions == disclosureRevisions { disclosure = self.disclosure }
        else {
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.disclosureReads += 1 }
            disclosure = disclosureStore.map { TranscriptRowDisclosure.of(item, in: $0, inputs: toolInputs) } ?? .default
        }
        disclosureRevisions = revisions
        let was = Look(disclosure: self.disclosure, environment: self.environment, fresh: self.fresh)
        let now = Look(disclosure: disclosure, environment: environment, fresh: fresh)
        switch Self.change(from: self.item, was, to: item, now, sameItem: sameItem, hasTree: hosted != nil, inMotion: pinnedContentHeight != nil) {
        case .none:
            return false
        case .repaint:
            self.environment = environment
            measuring = true
            updateRoot()
            measuring = false
            return false
        case .unseenGrowth:
            self.item = item
            measurements.removeAll(keepingCapacity: true)
            estimate = nil
            grewWithoutATree = true
            restoredMeasurementNeedsValidation = false
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.streamingEstimates += 1 }
            return true
        case .streamed(let append):
            if let grew = takeStreamed(append, item: item) { return grew != 0 }
            return settle(Self.settledChange(from: self.item, was, to: item, now), to: item, now)
        case .settled(let change):
            return settle(change, to: item, now)
        }
    }
    /// What an update does to a row.
    enum Change: Equatable {
        /// Nothing the row draws changed.
        case none
        /// Only how the row is painted changed: it is drawn with the new
        /// values and keeps every height it has.
        case repaint
        /// A token of a reply whose row holds no tree: the reader scrolled
        /// well past it. Building and laying one out for every token of a
        /// reply nobody can see is what made scrolling during a reply
        /// expensive. The row stands at an estimate of its own growth, is
        /// never drawn at it, and is measured when the reader comes back.
        case unseenGrowth
        /// A token the reply's own surface can take: it says how much taller
        /// the message became, and the row's one measurement grows by that
        /// much, with no SwiftUI rebuild and no sizing. Where the surface
        /// cannot take it, the row does what `settledChange` says.
        case streamed(TranscriptStreamingTail.Append)
        /// A change no token explains.
        case settled(Settled)
    }
    enum Settled: Equatable {
        /// A closed part or card keeps its one-line height (`closedPartKeepsHeight`).
        case closedPart
        /// A closed work list keeps its height (`closedWorkKeepsHeight`).
        case closedWork
        /// The row is measured again.
        case remeasure
    }
    /// What an update from `old`, drawn as `was`, to `new`, drawn as `now`,
    /// does to a row. `sameItem` is `old == new`, which the caller has
    /// already asked; `hasTree` says whether the row holds its SwiftUI tree,
    /// and `inMotion` whether a disclosure is moving it.
    nonisolated static func change(from old: TranscriptItem, _ was: Look, to new: TranscriptItem, _ now: Look,
                                   sameItem: Bool, hasTree: Bool, inMotion: Bool) -> Change {
        guard !sameItem || was != now else { return .none }
        if sameItem, was.fresh == now.fresh, was.disclosure == now.disclosure, was.environment.hasSameGeometry(as: now.environment) {
            return .repaint
        }
        if was == now, !inMotion, let tail = TranscriptStreamingTail.append(from: old, to: new) {
            return hasTree ? .streamed(tail) : .unseenGrowth
        }
        return .settled(settledChange(from: old, was, to: new, now))
    }
    nonisolated static func settledChange(from old: TranscriptItem, _ was: Look, to new: TranscriptItem, _ now: Look) -> Settled {
        if closedPartKeepsHeight(from: old, was, to: new, now) { return .closedPart }
        if closedWorkKeepsHeight(from: old, was, to: new, now) { return .closedWork }
        return .remeasure
    }
    /// Takes a token through the reply's own surface, and returns how much
    /// taller it made the row. Nil where the surface cannot take it, or where
    /// the row is due a real measurement: every so often one is measured
    /// properly, so a long reply cannot drift away from what its tree needs.
    private func takeStreamed(_ append: TranscriptStreamingTail.Append, item: TranscriptItem) -> CGFloat? {
        guard tokensSinceMeasured < Self.tokensPerMeasurement, let surface = surface(for: append.messageID),
              let cached = measurements.last(where: { $0.width == width }) else { return nil }
        measuring = true
        let grew = surface.appendStreaming(append.text, identity: append.messageID)
        measuring = false
        guard let grew else { return nil }
        grewWithoutATree = false
        self.item = item
        streamingAppendCount += 1; tokensSinceMeasured += 1
        estimate = nil
        measurements = [CGSize(width: cached.width, height: max(1, cached.height + grew))]
        if let hosted, hosted.frame.height != measurements[0].height {
            hosted.frame = CGRect(x: 0, y: 0, width: cached.width, height: measurements[0].height)
        }
        streamingHeightKnown = true
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.streamingAppends += 1 }
        return grew
    }
    /// Takes the new item and look after a change no token explains.
    private func settle(_ change: Settled, to item: TranscriptItem, _ look: Look) -> Bool {
        let oldItem = self.item
        self.item = item; self.fresh = look.fresh; self.environment = look.environment; self.disclosure = look.disclosure
        switch change {
        case .closedPart:
            // The collapsed line keeps its height, but its latest reasoning
            // text still needs to reach the view while the reply streams.
            updateRoot()
            return false
        case .closedWork:
            workList = nil
            if case .block(let old) = oldItem, case .block(let new) = item,
               old.live != new.live || old.task?.outcome != new.task?.outcome ||
               old.taskSummary?.tools != new.taskSummary?.tools || old.taskSummary?.partial != new.taskSummary?.partial ||
               old.taskSummary?.toolCountPartial != new.taskSummary?.toolCountPartial {
                updateRoot()
            }
            return false
        case .remeasure:
            if TranscriptLayoutClock.recording, TranscriptStreamingTail.textGrew(from: oldItem, to: item) {
                TranscriptLayoutClock.streamingRebuilds += 1
            }
            streamingHeightKnown = false
            measurements.removeAll(keepingCapacity: true)
            estimate = nil
            if hosted != nil { awaitingViewportLayout = true }
            // Prose, freshness and the turn footer still remeasure the outer row,
            // but do not throw away unchanged tool/reasoning geometry.
            if workList?.key != workListKey { workList = nil }
            restoredMeasurementNeedsValidation = false
            updateRoot()
            invalidateIntrinsicContentSize()
            return true
        }
    }
    /// Only a new, unmeasured native host can borrow default-state geometry.
    /// No retained local disclosure state is ever replaced by a shared size.
    func restoreSharedMeasurement(width: CGFloat, backingScale: CGFloat) {
        guard measurementCount == 0, measurements.isEmpty, let geometryCache, let geometrySessionID,
              TranscriptGeometryCache.permits(item),
              let size = geometryCache.measurement(sessionID: geometrySessionID, item: item, fresh: fresh,
                                                   environment: environment, disclosure: disclosure,
                                                   width: width, backingScale: backingScale) else { return }
        measurements = [size]; measurementScale = backingScale
        restoredMeasurementNeedsValidation = true
        sharedMeasurementHits += 1
        if self.width != width {
            measuring = true
            self.width = width; updateRoot()
            measuring = false
        }
    }
    /// Once a borrowed baseline enters the viewport, resolve actual native
    /// text at its drawn width before accepting that mounted measurement.
    func validateSharedMeasurementAfterMount() {
        if restoredMeasurementNeedsValidation, window != nil, hosted != nil { contentSizeChanged() }
    }
    private func inputs() -> TranscriptRowInputs {
        // The relay reads the latest callbacks without replacing unchanged
        // SwiftUI text fields merely because their parent's closures changed.
        let relay = TranscriptActions.forwarding { [weak self] in self?.actions }
        let key = workListKey
        let known = workList?.key == key ? workList?.height : nil
        if known != nil { workListReuses += 1 }
        return TranscriptRowInputs(item: item, fresh: fresh, actions: relay, width: width, environment: environment,
                                   disclosure: disclosure, toggle: { [weak self] part in self?.toggleDisclosure(part) },
                                   workListHeight: known,
                                   workListMeasured: { [weak self] height in
                                       guard let self, self.workListKey == key else { return }
                                       self.workList = (key, height)
                                   },
                                   foldInMotion: keepingFoldedContent)
    }
    /// Rebuilds the tree, if this row is holding one. A row with no host has
    /// nothing to rebuild: it builds the current content when it is next
    /// measured or mounted.
    private func updateRoot() {
        guard let hosted else { return }
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.rootUpdateSeconds += TranscriptLayoutClock.now - started
            TranscriptLayoutClock.rootUpdates += 1
        } }
        if !hosted.accepts(item) {
            // The item became something this content cannot draw: build the
            // content that can, in the same place.
            let replacement = TranscriptRowRenderer.content(for: item, inputs: inputs())
            replacement.owner = self
            replacement.frame = hosted.frame
            hosted.owner = nil
            replaceSubview(hosted, with: replacement)
            self.hosted = replacement
            awaitingViewportLayout = true
            return
        }
        hosted.apply(inputs())
    }
    /// A click on a disclosure: record it, rebuild this row's content and drop
    /// its measurements, then let the document lay out now. Nothing waits for a
    /// hosting view to notice its own intrinsic size changed.
    func toggleDisclosure(_ part: TranscriptDisclosure.Part) {
        guard let disclosureStore else { return }
        // Switching a reply between rendered and its source takes away the
        // text a selection in it lives in. The selection ends here, in the
        // click, rather than when its view goes: that is inside the update
        // that removes it, and moving the first responder there lays the
        // window out in the middle of SwiftUI's update.
        if part.kind == .source { releaseSelection(inReply: part.id) }
        disclosureStore.toggle(part)
        // A card the reader just opened whose arguments the host had to cut
        // asks for the rest, once. The card draws the inline document until it
        // lands, and this row is measured again when it does.
        if disclosureStore.isOpen(part), let card = TranscriptToolInputs.cutCard(part, in: item) {
            onToolInputNeeded?(card.messageID, card.callID)
        }
        let updated = TranscriptRowDisclosure.of(item, in: disclosureStore, inputs: toolInputs)
        disclosureRevisions = (disclosureStore.revision, toolInputs?.revision ?? -1)
        guard updated != disclosure else { return }
        disclosure = updated
        measurements.removeAll(keepingCapacity: true)
        restoredMeasurementNeedsValidation = false
        // The document measures and lays this row out immediately below, so the
        // hosting view must not also schedule its own deferred re-validation:
        // that would lay the same tree out a second and third time per click.
        measuring = true
        updateRoot()
        measuring = false
        invalidateIntrinsicContentSize()
        onDisclosureChanged?()
    }
    /// Ends a selection held in any row that draws this reply's text.
    private func releaseSelection(inReply id: String) {
        guard let window, let document = superview else { return }
        let rows = document.subviews.compactMap { $0 as? TranscriptRowContainer }
        if rows.contains(where: { ReplySource.replyID(of: $0.item) == id && $0.ownsFirstResponder }) {
            window.makeFirstResponder(nil)
        }
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        // SwiftUI probes zero while discovering minimum sizes. It is not the
        // row's actual wrapping width and must not pin the parent's minimum.
        if proposed == 0 { return .zero }
        let target = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? width
        // A VStack probes the ideal page width as well as the actual viewport
        // width on every update. Keep both exact results; changing the root for
        // an already known speculative width would redo native text layout.
        if let cached = measurements.last(where: { $0.width == target }) { return cached }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer {
            if TranscriptLayoutClock.recording {
                TranscriptLayoutClock.measureSeconds += TranscriptLayoutClock.now - clock
                TranscriptLayoutClock.measuredRows += 1
            }
        }
        measuring = true
        defer {
            measuring = false
            // Keep first-mount rows attached until a later fitting pass agrees
            // with their exact size. Only then is a value shared across tabs.
            if geometryCache != nil, TranscriptGeometryCache.permits(item) { contentSizeChanged() }
        }
        if width != target { width = target; updateRoot() }
        let hosted = host()
        // One native pass. The host is given the width the text wraps at and
        // laid out; the height it settles on is read from that same pass
        // through the intrinsic size SwiftUI has just computed, so nothing
        // asks it to size the tree a second time for the same answer. The
        // root is vertically fixed, so the frame's own height never moves it.
        if hosted.frame.width != target { hosted.frame = CGRect(x: 0, y: 0, width: target, height: max(1, hosted.frame.height)) }
        let sizingStart = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        let (height, passes) = hosted.settle()
        nativeSizingPasses += passes
        if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.rowSizingPasses += passes
            TranscriptLayoutClock.rowSizingSeconds += TranscriptLayoutClock.now - sizingStart
        }
        // Leave the tree at the size the row is about to be given, so the
        // frame the document sets a moment later is the height it was just
        // laid out at and nothing is laid out again before it is drawn.
        if hosted.frame.height != height {
            let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
            hosted.frame = CGRect(x: 0, y: 0, width: target, height: height)
            hosted.layoutSubtreeIfNeeded()
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.placementSeconds += TranscriptLayoutClock.now - started }
        }
        let result = CGSize(width: target, height: height)
        if measurements.count == 4 { measurements.removeFirst() }
        measurements.append(result); measurementCount += 1
        grewWithoutATree = false; streamingHeightKnown = false; tokensSinceMeasured = 0
        measurementScale = window?.backingScaleFactor
        needsLayout = true
        return result
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, let previous = measurementScale, scale != previous else { return }
        measurements.removeAll(keepingCapacity: true)
        workList = nil
        restoredMeasurementNeedsValidation = false; streamingHeightKnown = false
        measurementScale = scale
        invalidateIntrinsicContentSize()
        onHeightInvalidated?()
    }
    override func layout() {
        super.layout()
        // While a disclosure is moving, the tree keeps the height it was
        // measured at and the row's own frame does the moving.
        if let pinnedContentHeight {
            let target = CGRect(x: 0, y: 0, width: bounds.width, height: pinnedContentHeight)
            if let hosted, hosted.frame != target { hosted.frame = target }
            return
        }
        // A sizing probe need not be the width eventually drawn. Bind the
        // hosted content to its real bounds here, without invalidating exact
        // measurements merely because a different proposal was probed last.
        if bounds.width > 0, width != bounds.width {
            measuring = true
            width = bounds.width; updateRoot()
            measuring = false
        }
        if let hosted, hosted.frame != bounds { hosted.frame = bounds }
    }
    var visibleContentPrepared: Bool {
        func prepared(_ view: NSView) -> Bool {
            if let markdown = view as? NativeMarkdownContainer { return markdown.visibleContentPrepared }
            for child in view.subviews { if !prepared(child) { return false } }
            return true
        }
        guard let hosted else { return false }; return prepared(hosted)
    }
    func contentSizeChanged() {
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.intrinsicInvalidations += 1 }
        // The host also invalidates while answering fittingSize. That call
        // supplies the new exact measurement; it need not schedule itself.
        guard !measuring else { return }
        // While the document is moving this row between two measured
        // heights, it owns the geometry: the tree is deliberately taller
        // than the frame and has nothing to report.
        guard pinnedContentHeight == nil else { return }
        // A token the message's own surface has already measured: the row has
        // the new height, and the page has already been placed around it.
        guard !streamingHeightKnown else { return }
        guard !invalidationPending else { return }
        invalidationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.invalidationPending = false
                self.onHeightValidated?()
            }
            // Reports retains this tree but hides its native scroll surface.
            // Reflow its latest revision when shown, not behind the report.
            if self.isHiddenOrHasHiddenAncestor { self.onHeightInvalidated?(); return }
            // Removing/reinserting the same host also invalidates its AppKit
            // intrinsic-size observation. Keep exact geometry unless its
            // actual height changed; otherwise scrolling causes a reflow loop.
            if let cached = self.measurements.last(where: { $0.width == self.width }) {
                guard self.window != nil, let hosted = self.hosted else {
                    // Measured in a window and detached since — a row the page
                    // measured in a slice, or one the reader scrolled past.
                    // The measurement stands, so share it rather than drop it;
                    // a baseline this row only borrowed is not shared again
                    // until a mounted pass has confirmed it.
                    if self.measurementCount > 0, !self.restoredMeasurementNeedsValidation,
                       let cache = self.geometryCache, let sessionID = self.geometrySessionID, let scale = self.measurementScale {
                        cache.store(cached, sessionID: sessionID, item: self.item, fresh: self.fresh,
                                    environment: self.environment, disclosure: self.disclosure, backingScale: scale)
                    }
                    return
                }
                self.measuring = true
                // One native pass, as in `measure`: laying the host out and
                // then asking its fitting size runs SwiftUI's sizing twice.
                let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
                let height = hosted.confirmHeight()
                if TranscriptLayoutClock.recording { TranscriptLayoutClock.validationSeconds += TranscriptLayoutClock.now - started }
                self.intrinsicValidationCount += 1
                self.measuring = false
                self.restoredMeasurementNeedsValidation = false
                if height == cached.height {
                    if let cache = self.geometryCache, let sessionID = self.geometrySessionID,
                       let scale = self.window?.backingScaleFactor, self.measurementScale == scale {
                        cache.store(cached, sessionID: sessionID, item: self.item, fresh: self.fresh, environment: self.environment,
                                    disclosure: self.disclosure, backingScale: scale)
                    }
                    return
                }
                if let cache = self.geometryCache, let sessionID = self.geometrySessionID, let scale = self.measurementScale {
                    cache.invalidate(sessionID: sessionID, item: self.item, width: cached.width, backingScale: scale)
                }
            }
            self.measurements.removeAll(keepingCapacity: true)
            self.invalidateIntrinsicContentSize()
            self.onHeightInvalidated?()
        }
    }
}
