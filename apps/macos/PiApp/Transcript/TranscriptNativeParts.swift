import AppKit

// Small AppKit pieces the transcript's native rows are built from: a label
// set like SwiftUI's text, a capsule pill, a rounded panel and the hover
// tracking a row needs. They live with the transcript until the app's Pi
// components have AppKit versions of their own.

/// The appearance a row is drawn in, from the values it is given.
@MainActor enum TranscriptAppearance {
    static func named(_ environment: TranscriptRowEnvironment) -> NSAppearance.Name {
        let dark = environment.colorScheme == .dark
        if environment.increasedContrast { return dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua }
        return dark ? .darkAqua : .aqua
    }
    /// Gives `view` the row's appearance, if it does not have it already.
    static func apply(_ environment: TranscriptRowEnvironment, to view: NSView) {
        let name = named(environment)
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

/// The quick ease the rows' decorative changes use (`PiMotion.quick`).
@MainActor enum TranscriptMotion {
    static func fade(_ view: NSView, to alpha: CGFloat) {
        guard view.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(PiMotion.quickMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }
    }
    /// A pill arriving: it fades in and rises the 2 points it used to.
    static func arrive(_ view: NSView) {
        let final = view.frame
        view.alphaValue = 0
        view.setFrameOrigin(CGPoint(x: final.minX, y: final.minY + 2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(PiMotion.quickMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
            view.animator().setFrameOrigin(final.origin)
        }
    }
    /// A pill leaving: it fades out and falls the 2 points it rose, then goes.
    /// Marks a view on its way out, so a row's layout leaves it where it is.
    static let leaving = NSUserInterfaceItemIdentifier("transcript-leaving")
    static func leave(_ view: NSView) {
        view.setAccessibilityElement(false)
        view.identifier = leaving
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Double(PiMotion.quickMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
            view.animator().setFrameOrigin(CGPoint(x: view.frame.minX, y: view.frame.minY + 2))
        }, completionHandler: { MainActor.assumeIsolated { view.removeFromSuperview() } })
    }
    /// `rect` with each edge moved to the nearest pixel, as SwiftUI places a
    /// view (measured: `TranscriptTextCalibrationTests.testProbePixelRounding`
    /// and the failure card's bottom edge).
    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }
    /// `rect` in a row `width` wide laid out right to left.
    static func mirrored(_ rect: CGRect, width: CGFloat, _ rightToLeft: Bool) -> CGRect {
        rightToLeft ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
    }
    /// `rect`, the frame of `view`, mirrored as SwiftUI mirrors it: a label
    /// by its own width.
    static func mirrored(_ rect: CGRect, of view: NSView, width: CGFloat, _ rightToLeft: Bool) -> CGRect {
        guard rightToLeft else { (view as? TranscriptLabel)?.snapsX = true; (view as? TranscriptLabel)?.hangsTrailingSpace = false; return rect }
        if let label = view as? TranscriptLabel, !label.mirrorsByFrame { return label.mirrored(rect, width: width) }
        return mirrored(rect, width: width, true)
    }
}

/// One line of text, drawn as SwiftUI draws a `Text`: the font's own line box
/// (ascender to descender, plus its leading), the first baseline at the
/// ascender, and nothing wrapped. It never takes clicks or focus.
@MainActor final class TranscriptLabel: NSView {
    var text = "" { didSet { if text != oldValue { invalidate() } } }
    var font: NSFont = .systemFont(ofSize: 12) { didSet { if font != oldValue { invalidate() } } }
    var color: NSColor = TranscriptNSPalette.muted { didSet { if color != oldValue { attributed = nil; middleCache = nil; needsDisplay = true } } }
    var monospacedDigits = false { didSet { if monospacedDigits != oldValue { invalidate() } } }
    /// Cut short with an ellipsis when its frame is narrower than its line,
    /// as `lineLimit(1)` does; `head` cuts its beginning instead, `middle`
    /// its middle (`truncationMode(.middle)`, a path's).
    enum Truncation { case tail, head, middle }
    private var ctTruncation: CTLineTruncationType {
        switch truncation { case .head: return .start; case .middle: return .middle; default: return .end }
    }
    var truncation: Truncation? { didSet { if truncation != oldValue { needsDisplay = true } } }
    var underlined = false { didSet { if underlined != oldValue { invalidate() } } }
    private var attributed: NSAttributedString?
    private var measured: CGSize?
    /// Whether the text stands on a whole pixel across; one laid out from
    /// the right by its own width does not.
    var snapsX = true { didSet { if snapsX != oldValue { needsDisplay = true } } }
    /// Whether the line's trailing spaces lie past its end, as a line SwiftUI
    /// sets from the right draws them: the words move over by their width.
    /// A text centred in a box of its own mirrors with its frame, not from its end.
    var mirrorsByFrame = false
    var hangsTrailingSpace = false { didSet { if hangsTrailingSpace != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Makes the label something assistive technology reads, as `label`.
    func speak(_ label: String?, identifier: String? = nil) {
        setAccessibilityElement(label != nil)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }
    private func invalidate() { attributed = nil; measured = nil; middleCache = nil; needsDisplay = true }
    private var resolvedFont: NSFont {
        guard monospacedDigits else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    private var string: NSAttributedString {
        if let attributed { return attributed }
        var attributes: [NSAttributedString.Key: Any] = [.font: resolvedFont, .foregroundColor: color]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let value = NSAttributedString(string: text, attributes: attributes)
        attributed = value
        return value
    }
    /// For the calibration sweep only.
    nonisolated(unsafe) static var baselineOverride: CGFloat?
    /// SwiftUI's line box and baseline for the fonts the rows use, measured
    /// against SwiftUI's own `Text` (TranscriptTextCalibrationTests): its
    /// height, and how far its baseline sits from the font's ascender. No
    /// rule of the font's metrics gave all of them.
    private static let swiftUILines: [String: (height: CGFloat, baseline: CGFloat)] = [
        "12.5/0.3": (15, -0.375), "10.5/0": (13, -0.375), "11.0/0.23": (14, 0.125),
        "11.5/0.23": (14, -0.375), "11.0/0.4": (14, 0.125), "12.0/0.23": (15, 0),
        "13.0/0": (16, 0), "12.5/0": (15, -0.375), "11.5/0": (14, -0.375), "12.0/0": (15, 0),
        "11.0/0.23m": (14, 0.125), "11.5/0m": (14, -0.375), "12.0/0m": (15, 0),
        "12.0/0.3": (15, 0), "13.0/0.3s": (16, -0.5), "11.0/0": (14, 0.125),
        "9.5/0": (12, -0.375), "10.0/0": (13, 0.125), "13.0/0.23": (16, 0), "12.5/0.23": (15, -0.375)]
    static func measured(_ font: NSFont) -> (height: CGFloat, baseline: CGFloat)? {
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        // A monospaced face has its own line box: its key ends in "m"; a
        // serif one (New York) in "s".
        let design = font.isFixedPitch ? "m" : font.fontName.lowercased().contains("newyork") ? "s" : ""
        return swiftUILines[String(format: "%.1f/%.2g", font.pointSize, weight) + design]
    }
    /// The line box SwiftUI gives this font.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        measured(font)?.height ?? ceil(font.ascender - font.descender + font.leading)
    }
    /// The size the text needs on one line.
    var intrinsicSize: CGSize {
        if let measured { return measured }
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let size = CGSize(width: ceil(width * 2) / 2, height: Self.lineHeight(resolvedFont))
        measured = size
        return size
    }
    /// The text's own width on one line, unrounded: where SwiftUI ends its
    /// frame when it lays a text out from the right.
    var exactWidth: CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
    }
    /// `rect` (this label's frame) in a line `width` wide laid out right to
    /// left: a whole text ends where its own width ends, as SwiftUI places it.
    func mirrored(_ rect: CGRect, width: CGFloat) -> CGRect {
        let whole = rect.width + 0.25 >= intrinsicSize.width
        // A text cut short ends where the line it keeps ends, as a whole one
        // does: SwiftUI sets the cut line from the right edge of its frame.
        let cut = !whole && truncation != nil
        // A text wider than its frame and not cut is set where its width puts it, between pixels.
        snapsX = !whole && !cut
        // Set from the right, the line's trailing spaces hang past its end.
        hangsTrailingSpace = whole
        let end = whole ? exactWidth : cut ? CGFloat(CTLineGetTypographicBounds(cutLine(rect.width), nil, nil, nil)) : rect.width
        return CGRect(x: width - rect.minX - end, y: rect.minY, width: rect.width, height: rect.height)
    }
    /// How wide the text is once cut short to fit `width`, as SwiftUI sizes
    /// a truncated text: the line it draws, not the room it was offered.
    func width(truncatedTo width: CGFloat) -> CGFloat {
        let full = intrinsicSize.width
        guard width < full else { return full }
        if truncation == .middle {
            return ceil(CGFloat(CTLineGetTypographicBounds(middleCut(width), nil, nil, nil)) * 2) / 2
        }
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
        // CoreText may hand back a line a fraction wider than asked; SwiftUI
        // keeps the cut that fits whole pixels.
        var room = width
        while room > 0 {
            guard let cut = CTLineCreateTruncatedLine(line, Double(room), ctTruncation, ellipsis) else { return width }
            let used = ceil(CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)) * 2) / 2
            if used <= width { return used }
            room -= 0.5
        }
        return width
    }
    /// The line cut in its middle to fit `width`, as SwiftUI cuts it: by a
    /// frame whose paragraph truncates in the middle, which keeps characters
    /// `CTLineCreateTruncatedLine` drops (measured against SwiftUI's `Text`,
    /// `TranscriptNativeTurnParityTests.testProbeMiddleTruncation`).
    private func middleCut(_ width: CGFloat) -> CTLine {
        // Kept for one width; anything that changes the string (its text, its
        // font, its colour, its underline) drops it.
        if let cut = middleCache, cut.width == width { return cut.line }
        var mode = CTLineBreakMode.byTruncatingMiddle
        let line: CTLine = withUnsafeBytes(of: &mode) { bytes in
            let setting = CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: bytes.baseAddress!)
            let paragraph = CTParagraphStyleCreate([setting], 1)
            let source = NSMutableAttributedString(attributedString: string)
            source.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph, range: NSRange(location: 0, length: source.length))
            let setter = CTFramesetterCreateWithAttributedString(source)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: 10_000), transform: nil), nil)
            return (CTFrameGetLines(frame) as? [CTLine])?.first ?? CTLineCreateWithAttributedString(string)
        }
        middleCache = (width, line)
        return line
    }
    private var middleCache: (width: CGFloat, line: CTLine)?
    /// The line as it is drawn cut short to `width`.
    private func cutLine(_ width: CGFloat) -> CTLine {
        if truncation == .middle { return middleCut(width) }
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
        return CTLineCreateTruncatedLine(line, Double(width), ctTruncation, ellipsis) ?? line
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let font = resolvedFont
        let string = string
        context.saveGState()
        // A flipped view: CoreText draws upward from the baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var line = CTLineCreateWithAttributedString(string)
        // A line cut too short for even its ellipsis is clipped, as SwiftUI clips it.
        if truncation != nil { context.clip(to: bounds) }
        if truncation == .middle, bounds.width + 0.25 < intrinsicSize.width {
            line = middleCut(bounds.width)
        } else if truncation != nil, bounds.width + 0.25 < intrinsicSize.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
            line = CTLineCreateTruncatedLine(line, Double(bounds.width), ctTruncation, ellipsis) ?? line
        }
        // SwiftUI sets a text's origin on the pixel grid.
        var origin = snapsX ? pixelSnappedOrigin : CGPoint(x: bounds.minX, y: pixelSnappedOrigin.y)
        if hangsTrailingSpace { origin.x += CGFloat(CTLineGetTrailingWhitespaceWidth(line)) }
        context.textPosition = CGPoint(x: origin.x, y: origin.y + font.ascender + (Self.baselineOverride ?? Self.measured(font)?.baseline ?? 0))
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// An SF Symbol drawn as SwiftUI's `Image` draws one: as vector, tinted, on
/// the pixel grid nearest where it is placed. It never takes clicks.
extension NSView {
    /// The point nearest this view's origin that lies on the window's pixel
    /// grid, in the view's own coordinates: where SwiftUI would have put it.
    var pixelSnappedOrigin: CGPoint { pixelSnapped(bounds.origin) }
    /// The point nearest `point` (in the view's coordinates) on the window's pixel grid.
    func pixelSnapped(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        let scale = window.backingScaleFactor
        // Rounded from the window's top, as SwiftUI's flipped layout rounds.
        let height = window.contentView?.bounds.height ?? 0
        let inWindow = convert(point, to: nil)
        let top = ((height - inWindow.y) * scale).rounded() / scale
        return convert(CGPoint(x: (inWindow.x * scale).rounded() / scale, y: height - top), from: nil)
    }
}

@MainActor final class TranscriptSymbol: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    /// The symbol `name` at `size` points and `weight`, as `Image(systemName:)`
    /// with `.font(.system(size:weight:))` draws it.
    func show(_ name: String, size: CGFloat, weight: NSFont.Weight) {
        let next = "\(name)/\(size)/\(weight.rawValue)"
        // A row updated on every streamed delta keeps the image it has.
        guard next != key || image == nil else { return }
        key = next
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    private var key = ""
    /// The frame SwiftUI lays the symbol out in, measured
    /// (`TranscriptTextCalibrationTests.testSymbolFramesMatchSwiftUI`): it is
    /// not the image's size, nor its alignment rectangle, for every symbol.
    nonisolated static let swiftUIFrames: [String: CGSize] = [
        "dollarsign.circle.fill/15.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 18.5, height: 18.5),
        "checkmark.circle.fill/15.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 18.5, height: 18.5),
        "play.fill/11.5/\(NSFont.Weight.medium.rawValue)": CGSize(width: 10.5, height: 12),
        "arrow.up.circle/11.5/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14, height: 14),
        "arrow.clockwise/11.5/\(NSFont.Weight.medium.rawValue)": CGSize(width: 12.5, height: 14.5),
        "clock.arrow.circlepath/11.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14.5, height: 13.5),
        "exclamationmark.triangle/11.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 13.5, height: 12.5),
        // A work row's icons, and the chevron they turn into.
        "terminal/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 17, height: 13),
        "pencil/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 13, height: 12),
        "doc.text/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 13.5, height: 15),
        "folder/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 16.5, height: 13),
        "magnifyingglass/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 15, height: 14),
        "point.3.connected.trianglepath.dotted/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 16, height: 12.5),
        "circle/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14.5, height: 14.5),
        "chevron.down/11.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 13, height: 8),
        // A skill pill's glyph, the version switcher's chevrons, a fold
        // header's chevron and a tool result's.
        "command/9.0/\(NSFont.Weight.bold.rawValue)": CGSize(width: 10.5, height: 10.5),
        "chevron.left/9.5/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 7.5, height: 10.5),
        "chevron.right/9.5/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 7.5, height: 10.5),
        "chevron.down/10.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 11, height: 7.5),
        "chevron.right/12.5/\(NSFont.Weight.regular.rawValue)": CGSize(width: 9.5, height: 13),
        "chevron.down/12.5/\(NSFont.Weight.regular.rawValue)": CGSize(width: 14, height: 8),
        // A turn report's outcome and its Copy.
        "checkmark.circle/11.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 13.5, height: 13.5),
        "exclamationmark.circle/11.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 13.5, height: 13.5),
        "doc.on.doc/11.0/\(NSFont.Weight.regular.rawValue)": CGSize(width: 14, height: 16),
        // A response part's and a legacy reply's work icons, a reply's model mark,
        // an execution record's chevrons.
        "brain/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 18, height: 15.5),
        "hammer/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 17.5, height: 17),
        "info.circle/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14.5, height: 14.5),
        "arrow.uturn.backward/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14.5, height: 13.5),
        "list.bullet/12.0/\(NSFont.Weight.medium.rawValue)": CGSize(width: 15.5, height: 11),
        "info.circle/11.0/\(NSFont.Weight.regular.rawValue)": CGSize(width: 13, height: 13),
        "chevron.right/12.5/\(NSFont.Weight.medium.rawValue)": CGSize(width: 10, height: 13),
        "chevron.down/12.5/\(NSFont.Weight.medium.rawValue)": CGSize(width: 14, height: 8.5),
        // A response's fold button.
        "arrow.down.left.and.arrow.up.right/10.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 11.5, height: 11.5),
        "arrow.up.right.and.arrow.down.left/10.0/\(NSFont.Weight.semibold.rawValue)": CGSize(width: 12, height: 12),
    ]
    /// How far from the middle of SwiftUI's frame SwiftUI draws the symbol,
    /// measured (`TranscriptTextCalibrationTests.testSymbolsDrawAsSwiftUI`).
    nonisolated static let swiftUIOffsets: [String: CGPoint] = [
        // Swept in the work row itself (TranscriptNativeWorkParityTests.testSweepWorkSymbolOffsets).
        "pencil/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.125, y: -0.25),
        "doc.text/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.125, y: -0.375),
        "folder/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.5, y: -0.125),
        "magnifyingglass/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.125, y: -0.25),
        "point.3.connected.trianglepath.dotted/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0, y: -0.875),
        "circle/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.125, y: -1),
        "chevron.down/11.0/\(NSFont.Weight.semibold.rawValue)": CGPoint(x: 0, y: -0.375),
        // Swept in the response's rows (TranscriptNativeRowParityTests.testSweepTimelineSymbolOffsets).
        "brain/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0, y: -1),
        "hammer/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.5, y: -0.375),
        "info.circle/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.125, y: -1),
        "arrow.uturn.backward/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0.375, y: -0.875),
        "list.bullet/12.0/\(NSFont.Weight.medium.rawValue)": CGPoint(x: 0, y: -0.125),
        // Swept in testSymbolsDrawAsSwiftUI.
        "chevron.down/10.0/\(NSFont.Weight.semibold.rawValue)": CGPoint(x: 0, y: -1),
        "chevron.left/9.5/\(NSFont.Weight.semibold.rawValue)": CGPoint(x: 0, y: -0.875),
        "chevron.right/9.5/\(NSFont.Weight.semibold.rawValue)": CGPoint(x: 0.375, y: -1),
        "chevron.right/12.5/\(NSFont.Weight.regular.rawValue)": CGPoint(x: 0.375, y: -0.5),
        // Swept in the bubble (TranscriptNativeRowParityTests.testSweepSkillGlyphOffset).
        "command/9.0/\(NSFont.Weight.bold.rawValue)": CGPoint(x: 0.125, y: -0.625),
    ]
    /// For the calibration sweep only.
    nonisolated(unsafe) static var offsetOverride: CGPoint?
    /// The view's frame for SwiftUI's frame `rect` for the symbol: the image,
    /// whole, in its middle.
    func place(in rect: CGRect) {
        guard let image else { frame = rect; return }
        let side = square ? max(image.size.width, image.size.height) : 0
        let size = square ? CGSize(width: side, height: side) : image.size
        frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    /// Drawn in the middle of square bounds, so it can turn inside them.
    var square = false { didSet { if square != oldValue { needsDisplay = true } } }
    /// How far the symbol is turned about its middle, in degrees, clockwise
    /// on screen; animatable.
    /// Drawn mirrored left to right, turn and all.
    var mirroredAcross = false { didSet { if mirroredAcross != oldValue { needsDisplay = true } } }
    @objc dynamic var rotation: CGFloat = 0 { didSet { if rotation != oldValue { needsDisplay = true } } }
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "rotation" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    /// Where SwiftUI's frame for the symbol is; nil for a symbol not measured.
    var swiftUIFrame: CGSize? { Self.swiftUIFrames[key] }
    var contentTintColor: NSColor? { didSet { if contentTintColor != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let tint = contentTintColor ?? TranscriptNSPalette.text
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // SwiftUI sets a symbol on the pixel grid, so its straight edges are crisp.
        let size = square ? image.size : bounds.size
        let place = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let snapped = pixelSnapped(place), nudge = Self.offsetOverride ?? Self.swiftUIOffsets[key] ?? .zero
        let origin = CGPoint(x: snapped.x + nudge.x, y: snapped.y + nudge.y)
        if rotation != 0 || mirroredAcross {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            // A right-to-left row mirrors a turned symbol, as SwiftUI flips its row.
            if mirroredAcross { context.scaleBy(x: -1, y: 1) }
            context.rotate(by: rotation * .pi / 180)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn)
        context.setFillColor(tint.cgColor)
        context.fill(bounds)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// A capsule of colour or a rounded panel behind a row's content: the bubble
/// a message sits in, a pill's face. Drawn by its layer, so moving or resizing
/// it is a frame change and nothing redraws.
@MainActor final class TranscriptPanel: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Nil is a capsule.
    var cornerRadius: CGFloat? = 14 { didSet { needsDisplay = true } }
    /// SwiftUI's `Circle` and `Capsule` round with a circle's arc; its
    /// rounded rectangles here are continuous.
    var circular = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The stroke's outer half lies outside the shape, as SwiftUI's does.
        clipsToBounds = false
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// The stroke, centred on the shape's edge as SwiftUI strokes a shape:
    /// a layer half the line wider all round, its border the whole line.
    private let edge = CALayer()
    /// The fill, in a layer of its own: a view's own rounded layer clips
    /// what lies outside it when it is drawn into an image, and the stroke's
    /// outer half does.
    private let body = CALayer()
    override func updateLayer() {
        guard let layer else { return }
        let radius = cornerRadius ?? bounds.height / 2
        let curve: CALayerCornerCurve = circular ? .circular : .continuous
        var background: CGColor?, border: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = fill?.cgColor
            border = stroke?.cgColor
        }
        if body.superlayer == nil { layer.addSublayer(body) }
        if edge.superlayer == nil { layer.addSublayer(edge) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = layer.bounds
        body.cornerRadius = radius
        body.cornerCurve = curve
        body.backgroundColor = background
        edge.frame = layer.bounds.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        edge.cornerRadius = radius + strokeWidth / 2
        edge.cornerCurve = curve
        edge.borderColor = border
        edge.borderWidth = border == nil ? 0 : strokeWidth
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// One of a row's pill buttons (Edit, Copy, Details…): its title in a
/// capsule that lights under the pointer, as `TranscriptPillStyle` drew it.
@MainActor final class TranscriptPillButton: NSView {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let face = TranscriptPanel()
    private let label = TranscriptLabel()
    private let icon = TranscriptSymbol()
    /// The title over several lines, when the pill is offered less than its
    /// one line: SwiftUI's `Label` wraps rather than truncates.
    private var wrapped: TranscriptPlainTextView?
    private let font: NSFont
    let title: String
    let accent: Bool
    var perform: () -> Void
    /// A row in a pane that takes no input draws its pills and acts on none.
    var enabled = true
    /// How the pill is painted: a row's quiet pill, or Raise limit…, which
    /// stands on the surface colour and reads in the text colour at rest.
    enum Style { case plain, raise }
    var style = Style.plain { didSet { refresh() } }
    /// Whether the title wraps when the pill is offered less than its one
    /// line (SwiftUI's `Label`); a pill fixed at its size does not.
    var wraps = true
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    /// For a press target laid over the pill that takes its pointer.
    func setHovering(_ value: Bool) { hovering = value }
    private var pressed = false { didSet { alphaValue = pressed ? 0.7 : 1 } }
    override var isFlipped: Bool { true }
    init(title: String, accent: Bool, symbol: String? = nil, font: NSFont = TranscriptPillButton.font, perform: @escaping () -> Void) {
        self.title = title; self.accent = accent; self.perform = perform; self.font = font; self.symbolName = symbol
        super.init(frame: .zero)
        face.cornerRadius = nil
        addSubview(face); addSubview(label)
        label.text = title; label.font = font
        if let symbol {
            icon.show(symbol, size: font.pointSize, weight: .medium)
            icon.setAccessibilityElement(false)
            addSubview(icon)
        }
        setAccessibilityElement(false)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    /// A label's icon and title, as SwiftUI's `Label` spaces them: the
    /// symbol's outline, then 8 points (measured against SwiftUI's frames).
    private var glyph: CGRect? { icon.image.map { $0.alignmentRect } }
    /// Measured per symbol against SwiftUI's pills (TranscriptNativeRowParityTests):
    /// how much lower the title and the symbol sit than the pill's middle on
    /// one line, and, when the title wraps, how much lower it sits than the
    /// middle and its symbol than its first line's middle.
    nonisolated static let drops: [String: (title: CGFloat, symbol: CGFloat, wrappedTitle: CGFloat, wrappedSymbol: CGFloat)] = [
        "arrow.clockwise": (0.375, -0.25, 0.75, -1.25), "arrow.up.circle": (0, -0.625, 0, 0), "play.fill": (0.125, -0.25, 0, -0.75)]
    private var drop: (title: CGFloat, symbol: CGFloat, wrappedTitle: CGFloat, wrappedSymbol: CGFloat) {
        symbolName.flatMap { Self.drops[$0] } ?? (0, 0, 0, 0)
    }
    private var iconWidth: CGFloat { glyph.map { $0.width + 8 } ?? 0 }
    /// How tall SwiftUI's `Label` of a symbol and an 11.5-point medium title
    /// is, unrounded (measured, `TranscriptTextCalibrationTests.testPillLabelsMatchSwiftUI`):
    /// a symbol taller than the title's line makes it taller by a fraction.
    nonisolated static let swiftUILabelHeights: [String: CGFloat] = [
        "arrow.clockwise": 15.0513916015625, "arrow.up.circle": 14.0513916015625, "play.fill": 14]
    private let symbolName: String?
    private var labelHeight: CGFloat {
        let line = label.intrinsicSize.height
        guard let image = icon.image else { return line }
        return symbolName.flatMap { Self.swiftUILabelHeights[$0] } ?? max(line, (icon.swiftUIFrame?.height ?? image.size.height) + 1)
    }
    /// Whether the symbol stands taller than the title's line.
    var symbolOverhangs: Bool { labelHeight > label.intrinsicSize.height }
    var pillSize: CGSize {
        CGSize(width: iconWidth + label.intrinsicSize.width + 20, height: labelHeight + 8)
    }
    /// The face a wrapped title is set in.
    static func wrappedFace(_ font: NSFont) -> TranscriptPlainTextFace {
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        return TranscriptPlainTextFace(size: font.pointSize, monospaced: false, lineSpacing: 0, label: "Button", weight: weight)
    }
    private var wrappedText: TranscriptPlainTextView {
        if let wrapped { return wrapped }
        let text = TranscriptPlainTextView(); text.isSelectable = false; text.setAccessibilityElement(false)
        text.update(text: title, face: Self.wrappedFace(font), environment: textEnvironment, swiftUILines: true, color: label.color)
        addSubview(text); wrapped = text
        return text
    }
    /// The pill's size when offered `width`: its one line when that fits,
    /// else its title wrapped in what is left beside the symbol.
    func size(offered width: CGFloat) -> CGSize {
        let ideal = pillSize
        guard width < ideal.width else { return ideal }
        let room = max(1, width - 20 - iconWidth), text = wrappedText
        let overhang = labelHeight - label.intrinsicSize.height
        return CGSize(width: 20 + iconWidth + text.usedWidth(width: room), height: ceil(text.exactHeight(width: room)) + overhang + 8)
    }
    override func layout() {
        super.layout()
        face.frame = bounds
        let wraps = self.wraps && bounds.width + 0.25 < pillSize.width
        label.isHidden = wraps
        if wraps {
            let text = wrappedText, room = max(1, bounds.width - 20 - iconWidth)
            text.isHidden = false
            let textHeight = ceil(text.exactHeight(width: room))
            text.frame = CGRect(x: 10 + iconWidth, y: (bounds.height - textHeight) / 2 + drop.wrappedTitle, width: room, height: textHeight)
            if let image = icon.image, let glyph {
                // Beside the first line.
                let line = TranscriptLabel.lineHeight(font)
                icon.frame = CGRect(x: 10 - glyph.minX, y: text.frame.minY + (line - glyph.height) / 2 - (image.size.height - glyph.maxY) + drop.wrappedSymbol,
                                    width: image.size.width, height: image.size.height)
            }
            mirrorContents()
            return
        }
        wrapped?.isHidden = true
        let text = label.intrinsicSize
        if let image = icon.image, let glyph {
            // The image view draws the whole image; place it so its outline
            // lands where SwiftUI draws the symbol.
            let x = 10 - glyph.minX, y = (bounds.height - glyph.height) / 2 - (image.size.height - glyph.maxY) + drop.symbol
            icon.frame = CGRect(x: x, y: y, width: image.size.width, height: image.size.height)
        }
        label.frame = CGRect(x: 10 + iconWidth, y: (bounds.height - text.height) / 2 + drop.title,
                             width: text.width, height: text.height)
        mirrorContents()
    }
    /// Laid out right to left: the title before the symbol.
    var rightToLeft = false { didSet { if rightToLeft != oldValue { refresh(); needsLayout = true } } }
    private var textEnvironment: TranscriptRowEnvironment {
        var environment = TranscriptRowEnvironment()
        environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        return environment
    }
    private func mirrorContents() {
        guard rightToLeft else { return }
        for view in [icon, label, wrapped] as [NSView?] {
            if let view { view.frame = TranscriptMotion.mirrored(view.frame, width: bounds.width, true) }
        }
    }
    private func refresh() {
        switch style {
        case .plain: label.color = hovering ? (accent ? TranscriptNSPalette.accent : TranscriptNSPalette.text) : TranscriptNSPalette.muted
        case .raise: label.color = hovering ? TranscriptNSPalette.accent : TranscriptNSPalette.text
        }
        if let wrapped { wrapped.update(text: title, face: Self.wrappedFace(font), environment: textEnvironment, swiftUILines: true, color: label.color) }
        icon.contentTintColor = label.color
        face.fill = hovering ? TranscriptNSPalette.panelStrong : style == .raise ? TranscriptNSPalette.surface : nil
        face.stroke = hovering && accent ? TranscriptNSPalette.accent : TranscriptNSPalette.hairStrong
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, enabled { perform() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// VoiceOver's press does what a click does.
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }

    // MARK: The keyboard

    /// A pill that is always on screen (Retry, Continue) is a button the
    /// keyboard reaches, as SwiftUI's was; a hover pill is not.
    var focusable = false
    override var acceptsFirstResponder: Bool { focusable && enabled }
    override var canBecomeKeyView: Bool { focusable && enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        // Space and Return press it, as they press a button.
        guard focusable, enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return super.resignFirstResponder() }
}

/// Watches the pointer over a view without taking anything from it.
@MainActor final class TranscriptHoverTracker {
    private weak var view: NSView?
    private var area: NSTrackingArea?
    var changed: (Bool) -> Void
    private(set) var inside = false
    init(view: NSView, changed: @escaping (Bool) -> Void) { self.view = view; self.changed = changed }
    /// Called from the view's `updateTrackingAreas`, with the part of it that counts.
    func update(rect: CGRect) {
        guard let view else { return }
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: view)
        view.addTrackingArea(next); area = next
        // A view that moved under a resting pointer learns where it is now.
        if let window = view.window {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            set(rect.contains(point))
        }
    }
    func set(_ value: Bool) { guard value != inside else { return }; inside = value; changed(value) }
}

/// Copies a markdown target and says so for two seconds, as `CopyButton`
/// does: a 64-point face so "Copy" turning into "Copied" moves nothing.
@MainActor final class TranscriptCopyButton: NSView {
    static let size = CGSize(width: 64, height: 21)
    private let face = TranscriptPanel()
    private let icon = TranscriptSymbol()
    private let label = TranscriptLabel()
    var target: MarkdownCopyTarget? { didSet { setAccessibilityLabel(target?.label); toolTip = target?.label } }
    var enabled = true
    /// Laid out right to left: the label before the icon.
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    private var hovering = false { didSet { refresh() } }
    private var copied = false { didSet { refresh() } }
    private var reset: Timer?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        face.cornerRadius = 5
        addSubview(face); addSubview(icon); addSubview(label)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    deinit { MainActor.assumeIsolated { reset?.invalidate() } }
    private func refresh() {
        let tint = copied ? TranscriptNSPalette.accent : hovering ? TranscriptNSPalette.text : TranscriptNSPalette.muted
        label.text = copied ? "Copied" : "Copy"; label.color = tint
        let symbol = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        icon.image = symbol; icon.contentTintColor = tint
        face.fill = hovering ? TranscriptNSPalette.panelStrong : TranscriptNSPalette.codeBackground
        face.stroke = copied ? TranscriptNSPalette.accent.withAlphaComponent(0.4) : hovering ? TranscriptNSPalette.hairStrong : nil
        needsLayout = true
    }
    override func layout() {
        super.layout()
        face.frame = bounds
        let iconSize = icon.image?.size ?? CGSize(width: 10, height: 10)
        let text = label.intrinsicSize
        let width = iconSize.width + 4 + text.width
        let x = (bounds.width - width) / 2
        icon.frame = TranscriptMotion.mirrored(CGRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height),
                                               width: bounds.width, rightToLeft)
        label.frame = TranscriptMotion.mirrored(CGRect(x: x + iconSize.width + 4, y: (bounds.height - text.height) / 2, width: text.width, height: text.height),
                                                width: bounds.width, rightToLeft)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = accessibilityPerformPress()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let target, enabled else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.text, forType: .string)
        copied = true
        reset?.invalidate()
        reset = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.copied = false }
        }
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A row's hover pills (Edit, Copy, Details…): built only while the pointer
/// is over the row, arriving and leaving as `RowActionsView`'s did, and laid
/// out from the band's trailing edge four points apart.
@MainActor final class TranscriptPillBand {
    private weak var host: NSView?
    private(set) var pills: [TranscriptPillButton] = []
    init(host: NSView) { self.host = host }
    /// Shows `wanted`, keeping the pills already there when they are the same.
    func show(_ wanted: [RowActionsView.Pill], enabled: Bool) {
        guard let host else { return }
        if pills.map(\.title) != wanted.map(\.title) {
            // Leaving pills fade out as they used to, then go.
            for old in pills { TranscriptMotion.leave(old) }
            pills = wanted.map { pill in
                let button = TranscriptPillButton(title: pill.title, accent: pill.accent, perform: pill.perform)
                button.enabled = enabled
                host.addSubview(button)
                return button
            }
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            pills.forEach(TranscriptMotion.arrive)
        } else {
            for (button, pill) in zip(pills, wanted) { button.perform = pill.perform; button.enabled = enabled }
        }
    }
    /// Lays the pills out leftwards from `maxX`, centred on `midY`, mirrored
    /// in a right-to-left row `width` wide. Returns where the leftmost starts
    /// (or `maxX` when there are none).
    @discardableResult
    func place(maxX: CGFloat, midY: CGFloat, width: CGFloat, rightToLeft: Bool) -> CGFloat {
        var x = maxX
        for button in pills.reversed() {
            let size = button.pillSize
            x -= size.width
            button.frame = TranscriptMotion.mirrored(CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height),
                                                     width: width, rightToLeft)
            x -= 4
        }
        return pills.isEmpty ? maxX : x + 4
    }
}

/// Words that act when clicked, as a plain SwiftUI `Button` around a `Text`
/// does: underlined under the pointer, reachable from the keyboard.
@MainActor final class TranscriptLinkButton: NSView {
    let label = TranscriptLabel()
    var perform: () -> Void = {}
    var enabled = true
    var underlinesOnHover = true
    private var hovering = false { didSet { label.underlined = hovering && underlinesOnHover } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    var size: CGSize { label.intrinsicSize }
    override func layout() { super.layout(); label.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// A plain button without `piPointer` keeps the arrow.
    var pointsOnHover = true
    override func cursorUpdate(with event: NSEvent) { (pointsOnHover ? NSCursor.pointingHand : NSCursor.arrow).set() }
    /// Who had the keyboard when the pointer came down: a click acts and
    /// leaves focus where it was, as a SwiftUI button's click does.
    private weak var responderBeforeClick: NSResponder?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point) == nil ? nil : self as NSView?
        if hit === self, let current = window?.firstResponder, current !== self {
            if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                responderBeforeClick = field
            } else {
                responderBeforeClick = current
            }
        }
        return hit
    }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self, let before = responderBeforeClick, before !== self { window?.makeFirstResponder(before) }
        responderBeforeClick = nil
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)), enabled { perform() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? label.text }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
}
