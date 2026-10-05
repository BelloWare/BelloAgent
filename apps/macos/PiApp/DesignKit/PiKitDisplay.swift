import AppKit
import QuartzCore

extension PiKit {
    // MARK: - Badges and chips

    /// A rounded icon square: a soft tone tint, or a solid brand-orange
    /// square with a white symbol for a sheet header. Decorative.
    @MainActor final class IconBadge: NSView {
        let symbol: String, tone: PiTone, size: CGFloat, filled: Bool
        init(symbol: String, tone: PiTone = .accent, size: CGFloat = 28, filled: Bool = false) {
            self.symbol = symbol; self.tone = tone; self.size = size; self.filled = filled
            super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
            wantsLayer = true
            // The square is the view's own layer, under what the view draws.
            layer?.cornerCurve = .continuous
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
        override func layout() {
            super.layout()
            layer?.cornerRadius = size * 0.3
            layer?.backgroundColor = piCGColor(filled ? .piBrandOrange : tone.nsColor.withAlphaComponent(0.13))
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            Symbol(symbol, size: size * 0.46, weight: filled ? .bold : .semibold).draw(centredIn: bounds, color: filled ? .piOnAccent : tone.nsColor, scale: piScale)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A small capsule label: a dot or a turning spinner, an optional
    /// symbol and the text, quiet ink on a fill, or the tone's own ink on its tint.
    @MainActor final class Badge: NSView {
        var text: String { didSet { guard oldValue != text else { return }; invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(text); PiKit.sizeChanged(self) } }
        var tone: PiTone { didSet { needsDisplay = true; needsLayout = true } }
        var icon: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
        var dot: Bool { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
        var spinning: Bool { didSet { spinnerChanged() } }
        private var spinner: PiSpinnerView?

        init(text: String, tone: PiTone = .neutral, icon: String? = nil, dot: Bool = false, spinning: Bool = false) {
            self.text = text; self.tone = tone; self.icon = icon; self.dot = dot; self.spinning = spinning
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerCurve = .continuous
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
            spinnerChanged()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var ink: NSColor { tone == .neutral ? .piInkSecondary : tone.nsColor }
        private var line: Line { Line(text, font: PiKit.Font.micro, color: ink) }
        private var glyph: Symbol? { icon.map { Symbol($0, size: 10, weight: .semibold) } }
        private var hPadding: CGFloat { text.isEmpty ? 6 : 8 }
        /// The parts left to right: (width, height).
        private var parts: [CGSize] {
            var parts: [CGSize] = []
            if spinning { parts.append(CGSize(width: 9, height: 9)) } else if dot { parts.append(CGSize(width: 6, height: 6)) }
            if let glyph { parts.append(glyph.layoutSize) }
            if !text.isEmpty { parts.append(line.size(scale: piScale)) }
            return parts
        }
        override var intrinsicContentSize: NSSize {
            let parts = parts
            let width = parts.reduce(0) { $0 + $1.width } + 5 * CGFloat(max(0, parts.count - 1))
            return NSSize(width: width + hPadding * 2, height: (parts.map(\.height).max() ?? 0) + 7)
        }
        private func spinnerChanged() {
            if spinning, spinner == nil {
                let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
                view.configure(lineWidth: 1.4, turning: !Motion.reduced)
                addSubview(view); spinner = view
            } else if !spinning { spinner?.removeFromSuperview(); spinner = nil }
            invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
        }
        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
            layer?.backgroundColor = piCGColor(tone == .neutral ? .piFill : tone.nsColor.withAlphaComponent(0.13))
            spinner?.frame = CGRect(x: hPadding, y: (bounds.height - 9) / 2, width: 9, height: 9)
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            var x = hPadding
            let inner = CGRect(x: 0, y: 3.5, width: bounds.width, height: bounds.height - 7)
            if spinning { x += 9 + 5 } else if dot {
                ink.setFill()
                NSBezierPath(ovalIn: CGRect(x: x, y: inner.midY - 3, width: 6, height: 6)).fill()
                x += 6 + 5
            }
            if let glyph {
                let box = glyph.layoutSize
                glyph.draw(centredIn: CGRect(x: x, y: inner.minY, width: box.width, height: inner.height), color: ink, scale: piScale)
                x += box.width + 5
            }
            if !text.isEmpty {
                let size = line.size(scale: piScale)
                line.draw(at: CGPoint(x: x, y: inner.minY + PiKit.round((inner.height - size.height) / 2, piScale)), scale: piScale)
            }
        }
    }

    /// A chip: an optional accent symbol and caption text on a white capsule
    /// in a strong hairline, with a remove button when it can be removed.
    @MainActor final class Chip: NSView {
        let main: ChipButton
        let removeButton: RemoveButton?
        init(text: String, icon: String? = nil, help: String? = nil, action: (() -> Void)? = nil, remove: (() -> Void)? = nil) {
            main = ChipButton(text: text, icon: icon)
            main.onPress = action
            removeButton = remove.map { remove in
                let button = RemoveButton()
                button.onPress = remove
                button.setAccessibilityLabel("Remove " + text)
                return button
            }
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(main)
            if let removeButton { addSubview(removeButton) }
            toolTip = help ?? text
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private let capsule = CALayer(), outline = CALayer()
        override var intrinsicContentSize: NSSize {
            let label = main.intrinsicContentSize
            return NSSize(width: label.width + (removeButton != nil ? 6 + Symbol("xmark", size: 9, weight: .bold).layoutSize.width : 0) + 20,
                          height: label.height + 10)
        }
        override func layout() {
            super.layout()
            if capsule.superlayer == nil { layer?.insertSublayer(capsule, at: 0); layer?.addSublayer(outline); capsule.cornerCurve = .continuous; outline.cornerCurve = .continuous }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            capsule.frame = bounds; capsule.cornerRadius = bounds.height / 2
            outline.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outline.cornerRadius = bounds.height / 2 + 0.5; outline.borderWidth = 1
            capsule.backgroundColor = piCGColor(.piSurface); outline.borderColor = piCGColor(.piHairlineStrong)
            CATransaction.commit()
            let label = main.intrinsicContentSize
            main.frame = CGRect(x: 10, y: 5, width: label.width, height: label.height)
            if let removeButton {
                let box = Symbol("xmark", size: 9, weight: .bold).layoutSize
                removeButton.frame = CGRect(x: main.frame.maxX + 6, y: (bounds.height - box.height) / 2, width: box.width, height: box.height)
            }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

        /// The chip's remove button: a small bold cross, as a plain button.
        @MainActor final class RemoveButton: ButtonBase {
            let glyph = Symbol("xmark", size: 9, weight: .bold)
            init() {
                super.init(frame: .zero)
                pressScales = false
                disabledOpacity = PiKit.plainDisabledDimming
                toolTip = "Remove"
            }
            required init?(coder: NSCoder) { fatalError("Not used from a nib") }
            override var intrinsicContentSize: NSSize { glyph.layoutSize }
            override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
            override func drawContent(in rect: CGRect) { glyph.draw(centredIn: rect, color: .piInkTertiary, scale: piScale) }
        }

        /// The chip's label as a plain button.
        @MainActor final class ChipButton: ButtonBase {
            let text: String, icon: String?
            init(text: String, icon: String?) {
                self.text = text; self.icon = icon
                super.init(frame: .zero)
                pressScales = false
                setAccessibilityLabel(text)
            }
            required init?(coder: NSCoder) { fatalError("Not used from a nib") }
            private var line: Line { Line(text, font: PiKit.Font.caption, color: .piInk) }
            private var glyph: Symbol? { icon.map { Symbol($0, size: 10, weight: .semibold) } }
            override var intrinsicContentSize: NSSize {
                let text = line.size(scale: piScale)
                guard let glyph else { return text }
                return NSSize(width: glyph.layoutSize.width + 5 + text.width, height: max(text.height, glyph.layoutSize.height))
            }
            override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
            override func drawContent(in rect: CGRect) {
                var x: CGFloat = 0
                if let glyph {
                    glyph.draw(centredIn: CGRect(x: 0, y: 0, width: glyph.layoutSize.width, height: rect.height), color: .piAccent, scale: piScale)
                    x = glyph.layoutSize.width + 5
                }
                let size = line.size(scale: piScale)
                line.draw(at: CGPoint(x: x, y: PiKit.round((rect.height - size.height) / 2, piScale)), scale: piScale)
            }
        }
    }

    // MARK: - Surfaces

    /// A card: content on a white (or sunken) surface with 14-point
    /// continuous corners and a hairline, 16 points in by default.
    @MainActor static func card(_ content: NSView, padding: CGFloat = PiSpacing.lg, sunken: Bool = false) -> Box {
        Box(fill: sunken ? .piSurfaceSunken : .piSurface, stroke: .piHairline, cornerRadius: 14,
            padding: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding), content: content)
    }
    /// A rounded, bordered container for lists and editors, its content clipped.
    @MainActor static func inset(_ content: NSView, sunken: Bool = false) -> Box {
        let box = Box(fill: sunken ? .piSurfaceSunken : .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md, content: content)
        box.clipsContent = true; box.clipsStroke = true
        return box
    }
    /// A raised surface: white on a hairline with a short, soft shadow.
    @MainActor static func elevated(_ content: NSView, radius: CGFloat = 18) -> Box {
        let box = Box(fill: .piSurface, stroke: .piHairline, cornerRadius: radius, content: content)
        box.clipsContent = true
        box.shadowColor = .piShadow; box.shadowRadius = 12; box.shadowOffsetY = 4
        return box
    }

    /// A section's heading, an optional quieter line under it, and an
    /// accessory at the trailing edge on the first line's baseline.
    @MainActor final class SectionHeader: NSView, WidthSizing {
        private let title: TextLine
        private let subtitle: WrappedText?
        let accessory: NSView?
        init(_ title: String, subtitle: String? = nil, accessory: NSView? = nil) {
            self.title = TextLine(Line(title, font: PiKit.Font.heading, color: .piInk))
            self.subtitle = subtitle.map { WrappedText($0, font: PiKit.Font.caption, color: .piInkSecondary) }
            self.accessory = accessory
            super.init(frame: .zero)
            for view in [self.title, self.subtitle, accessory].compactMap({ $0 }) { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        func setSubtitle(_ text: String) {
            guard let subtitle, subtitle.text != text else { return }
            subtitle.text = text
            invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
        }
        private var accessorySize: NSSize { accessory?.intrinsicContentSize ?? .zero }
        private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - (accessory == nil ? 0 : max(0, accessorySize.width) + PiSpacing.md)) }
        private var titleBaseline: CGFloat { title.line.baseline(scale: piScale) }
        private var accessoryBaseline: CGFloat { accessory.map { shellBaseline($0, height: max(0, accessorySize.height)) } ?? 0 }
        private var baseline: CGFloat { max(titleBaseline, accessoryBaseline) }
        func height(forWidth width: CGFloat) -> CGFloat {
            let text = title.intrinsicContentSize.height + (subtitle.map { 2 + $0.height(forWidth: textWidth(width)) } ?? 0)
            return baseline + max(text - titleBaseline, max(0, accessorySize.height) - accessoryBaseline)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 500)) }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
        override func layout() {
            super.layout()
            let size = title.intrinsicContentSize, room = textWidth(bounds.width)
            let titleY = PiKit.round(baseline - titleBaseline, piScale)
            title.frame = CGRect(x: 0, y: titleY, width: min(size.width, room), height: size.height)
            if let subtitle { subtitle.frame = CGRect(x: 0, y: titleY + size.height + 2, width: room, height: subtitle.height(forWidth: room)) }
            if let accessory {
                let fit = accessorySize
                accessory.frame = CGRect(x: bounds.width - max(0, fit.width), y: PiKit.round(baseline - accessoryBaseline, piScale), width: max(0, fit.width), height: max(0, fit.height))
            }
        }
    }

    /// A key and its value on one baseline, the key in a 120-point column.
    @MainActor final class KeyValue: NSView, WidthSizing {
        let key: TextLine, value: NSTextField
        init(key: String, value: String, mono: Bool = false) {
            self.key = TextLine(Line(key, font: PiKit.Font.caption, color: .piInkSecondary))
            self.value = NSTextField(wrappingLabelWithString: value)
            super.init(frame: .zero)
            self.value.font = mono ? PiKit.Font.mono : PiKit.Font.caption
            self.value.textColor = .piInk
            self.value.isSelectable = true
            self.value.maximumNumberOfLines = 2
            self.value.lineBreakMode = .byWordWrapping
            self.value.cell?.wraps = true; self.value.cell?.isScrollable = false
            self.value.cell?.truncatesLastVisibleLine = true
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping; paragraph.lineBreakStrategy = .standard
            paragraph.tighteningFactorForTruncation = 0
            self.value.attributedStringValue = NSAttributedString(string: value, attributes: [.font: self.value.font!, .foregroundColor: NSColor.piInk, .paragraphStyle: paragraph])
            addSubview(self.key); addSubview(self.value)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private func valueWidth(_ width: CGFloat) -> CGFloat { max(0, width - 120 - 2 * PiSpacing.md) }
        private var keyBaseline: CGFloat { key.line.baseline(scale: piScale) }
        private var valueBaseline: CGFloat { value.firstBaselineOffsetFromTop }
        private var baseline: CGFloat { max(keyBaseline, valueBaseline) }
        private func valueHeight(_ width: CGFloat) -> CGFloat {
            let font = value.font ?? PiKit.Font.caption
            let rows = min(2, PiKit.wrappedLines(value.stringValue, font: font, width: valueWidth(width)).count)
            return CGFloat(rows) * PiKit.Line(value.stringValue, font: font, color: .piInk).lineHeight
        }
        func height(forWidth width: CGFloat) -> CGFloat {
            baseline + max(key.intrinsicContentSize.height - keyBaseline, valueHeight(width) - valueBaseline)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 500)) }
        override func layout() {
            super.layout()
            key.frame = CGRect(x: 0, y: PiKit.round(baseline - keyBaseline, piScale), width: 120, height: key.intrinsicContentSize.height)
            let width = valueWidth(bounds.width)
            value.preferredMaxLayoutWidth = width
            value.frame = CGRect(x: 120 + PiSpacing.md - PiKit.fieldInset, y: PiKit.round(baseline - valueBaseline, piScale), width: width + PiKit.fieldInset * 2, height: valueHeight(bounds.width))
        }
    }

    /// A note: a small tone symbol and caption text that wraps; danger reads in its tone.
    @MainActor final class Note: NSView, WidthSizing {
        var text: String { didSet { guard oldValue != text else { return }; label.set(text); shownWidth = nil; invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) } }
        let tone: PiTone
        /// At most this many lines, the last cut with "…" (`.lineLimit(_:)`
        /// on the SwiftUI note); nil, as many as the text needs.
        var lineLimit: Int? {
            didSet {
                guard oldValue != lineLimit else { return }
                applyLineLimit(); invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
            }
        }
        private let icon: SymbolView
        private let label: SelectableText
        init(_ text: String, tone: PiTone = .neutral, lineLimit: Int? = nil) {
            self.text = text; self.tone = tone; self.lineLimit = lineLimit
            let name = tone == .danger ? "exclamationmark.triangle.fill" : tone == .warning ? "exclamationmark.circle" : "info.circle"
            icon = SymbolView(Symbol(name, size: 11), color: tone == .neutral ? .piInkTertiary : tone.nsColor)
            label = SelectableText(text, font: PiKit.Font.caption, color: tone == .danger ? tone.nsColor : .piInkSecondary)
            super.init(frame: .zero)
            addSubview(icon); addSubview(label)
            applyLineLimit()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private func applyLineLimit() {
            shownWidth = nil
            if lineLimit == nil, label.stringValue != text { label.set(text) }
        }
        /// The width `label` shows the text cut for, nil when it shows all of it.
        private var shownWidth: CGFloat?
        /// What the note shows at `width`: the whole text, or, past its line
        /// limit, the lines that fit with the last ending in "…" as SwiftUI
        /// ends it: one line is cut where the room ends; of several, the last
        /// is the line as it wraps, then "…", cut further only when the
        /// ellipsis does not fit.
        func shownText(width: CGFloat) -> String {
            guard let lineLimit, lineLimit > 0 else { return text }
            let lines = PiKit.wrappedLines(text, font: PiKit.Font.caption, width: width)
            guard lines.count > lineLimit else { return text }
            let candidate = Array(lineLimit == 1 ? text.components(separatedBy: "\n")[0] : lines[lineLimit - 1])
            func fits(_ count: Int) -> Bool { Line(String(candidate[0..<count]) + "…", font: PiKit.Font.caption, color: .black).width <= width + 0.01 }
            // The most characters that fit with the ellipsis (widths grow with the count).
            var low = 0, high = candidate.count
            while low < high { let mid = (low + high + 1) / 2; if fits(mid) { low = mid } else { high = mid - 1 } }
            // Joined scripts can make a longer prefix narrower: look a few further.
            for count in stride(from: min(candidate.count, low + 8), to: low, by: -1) where fits(count) { low = count; break }
            var last = Array(candidate[0..<low])
            while last.last?.isWhitespace == true { last.removeLast() }
            return (lines.prefix(lineLimit - 1) + [String(last) + "…"]).joined(separator: "\n")
        }
        /// The text's height in `width`, no more than its line limit allows.
        private func labelHeight(_ width: CGFloat) -> CGFloat {
            // The whole text's lines, whatever the field shows now.
            let height = PiKit.wrappedHeight(text, font: PiKit.Font.caption, width: width)
            guard let lineLimit else { return height }
            return min(height, Line(text, font: PiKit.Font.caption, color: .black).lineHeight * CGFloat(max(1, lineLimit)))
        }
        private var iconWidth: CGFloat { icon.symbol.layoutSize.width }
        /// Its width on one line; it takes no more than that, as `Text` does not.
        var naturalWidth: CGFloat { iconWidth + 6 + Line(text, font: PiKit.Font.caption, color: .black).size(scale: piScale).width }
        func height(forWidth width: CGFloat) -> CGFloat {
            max(labelHeight(width - iconWidth - 6), 1 + icon.symbol.layoutSize.height)
        }
        override var intrinsicContentSize: NSSize {
            let width = bounds.width > 0 ? bounds.width : naturalWidth
            return NSSize(width: naturalWidth, height: height(forWidth: width))
        }
        override func layout() {
            super.layout()
            let box = icon.symbol.layoutSize
            icon.frame = CGRect(x: 0, y: 1, width: box.width, height: box.height)
            let width = max(0, bounds.width - box.width - 6)
            // A field's cell insets its text two points; the field sits that far out.
            // Past its line limit the field shows the text already cut (an
            // `NSTextField` cuts its last line mid-word, SwiftUI after it).
            if lineLimit != nil, shownWidth != width {
                shownWidth = width
                label.set(shownText(width: width))
            } else if lineLimit == nil, label.stringValue != text {
                label.set(text)
            }
            label.frame = CGRect(x: box.width + 6 - PiKit.fieldInset, y: 0, width: width + PiKit.fieldInset * 2, height: labelHeight(width))
        }
    }

    /// A one-figure tile: a tinted glyph and a small-capitals title, the
    /// figure, and a caption that always reserves its two lines.
    @MainActor static func statTile(title: String, value: String, caption: String? = nil, symbol: String? = nil, tone: PiTone = .accent) -> Box {
        card(StatTileContent(title: title, value: value, caption: caption, symbol: symbol, tone: tone), padding: PiSpacing.md)
    }
    @MainActor final class StatTileContent: NSView, WidthSizing {
        let title: String, value: String, caption: String?, symbol: String?, tone: PiTone
        init(title: String, value: String, caption: String?, symbol: String?, tone: PiTone) {
            self.title = title; self.value = value; self.caption = caption; self.symbol = symbol; self.tone = tone
            super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.group)
            setAccessibilityLabel([title, value, caption].compactMap { $0 }.joined(separator: ", "))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        private var titleLine: PiKit.Line { PiKit.Line(title, font: PiKit.Font.micro, color: .piInkSecondary, tracking: 0.5, uppercased: true) }
        private var valueLine: PiKit.Line { PiKit.Line(value, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 20, weight: .semibold)), color: .piInk) }
        /// The caption's room, as `.lineLimit(2, reservesSpace: true)` takes it
        /// (measured against SwiftUI): two wrapped lines take their own height, each
        /// rounded up to the point (28); a one-line caption reserves the text
        /// system's two line heights (26).
        private func captionHeight(_ width: CGFloat) -> CGFloat {
            guard let caption else { return 0 }
            let font = PiKit.Font.caption
            if width > 0, TextWrap.ranges(caption, font: font, width: width).count >= 2 {
                return 2 * Foundation.ceil(font.ascender - font.descender + font.leading)
            }
            return NSLayoutManager().defaultLineHeight(for: font) * 2
        }
        func height(forWidth width: CGFloat) -> CGFloat {
            titleLine.size().height + 6 + PiKit.scaledLine(valueLine, width: width, minimumScale: 0.6).lineHeight + (caption == nil ? 0 : 6 + captionHeight(width))
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
        }
        override func draw(_ dirtyRect: NSRect) {
            let scale = piScale
            var x: CGFloat = 0
            if let symbol {
                let glyph = PiKit.Symbol(symbol, size: 10.5, weight: .semibold)
                glyph.draw(centredIn: CGRect(x: 0, y: 0, width: glyph.layoutSize.width, height: titleLine.size().height), color: tone.nsColor, scale: scale)
                x = glyph.layoutSize.width + 6
            }
            titleLine.draw(in: CGRect(x: x, y: 0, width: bounds.width - x, height: titleLine.lineHeight), scale: scale)
            let y = titleLine.size().height + 6
            let value = PiKit.scaledLine(valueLine, width: bounds.width, minimumScale: 0.6)
            value.draw(in: CGRect(x: 0, y: y, width: bounds.width, height: value.lineHeight), scale: scale)
            guard let caption else { return }
            let font = PiKit.Font.caption
            let shown = TextWrap.cut(caption, font: font, width: bounds.width, lines: 2, scale: scale)
            let lineHeight = PiKit.Line("Ag", font: font, color: .black).lineHeight
            var top = y + value.lineHeight + 6
            for range in TextWrap.ranges(shown, font: font, width: bounds.width).prefix(2) {
                let text = (shown as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                PiKit.Line(text, font: font, color: .piInkTertiary).draw(at: CGPoint(x: 0, y: top), scale: scale)
                top += lineHeight
            }
        }
    }

    // MARK: - Small gauges

    /// A quiet share bar: a tinted capsule over a faint track.
    @MainActor final class ShareBar: NSView {
        var fraction: Double { didSet { needsLayout = true } }
        var tone: NSColor { didSet { needsLayout = true } }
        private let track = CALayer(), bar = CALayer()
        init(fraction: Double, tone: NSColor = .piAccent) {
            self.fraction = fraction; self.tone = tone
            super.init(frame: .zero)
            wantsLayer = true
            for layer in [track, bar] { layer.cornerCurve = .continuous; self.layer?.addSublayer(layer) }
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.frame = bounds; track.cornerRadius = bounds.height / 2
            bar.frame = CGRect(x: 0, y: 0, width: max(0, min(1, fraction)) * bounds.width, height: bounds.height); bar.cornerRadius = bounds.height / 2
            track.backgroundColor = piCGColor(.piFillStrong); bar.backgroundColor = piCGColor(tone)
            CATransaction.commit()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    }

    /// A tiny ring gauge for a ratio such as cache hit rate; with
    /// `contextTint`, the context ring's accent, warning at 80 per cent and
    /// danger at 95.
    @MainActor final class Ring: NSView {
        var fraction: Double { didSet { needsLayout = true; needsDisplay = true } }
        let size: CGFloat
        let tone: NSColor
        let lineWidth: CGFloat
        let contextTint: Bool
        private let track = CAShapeLayer(), arc = CAShapeLayer()
        init(fraction: Double, size: CGFloat = 10, tone: NSColor = .piSuccess, lineWidth: CGFloat = 2, contextTint: Bool = false) {
            self.fraction = fraction; self.size = size; self.tone = tone; self.lineWidth = lineWidth; self.contextTint = contextTint
            super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
            wantsLayer = true
            layer?.masksToBounds = false
            for shape in [track, arc] { shape.fillColor = nil; shape.lineWidth = lineWidth; layer?.addSublayer(shape) }
            arc.lineCap = .round
            setAccessibilityElement(false)
        }
        /// The context ring: 14 points on a pill, 23 in the inspector.
        static func context(_ fraction: Double?, size: CGFloat = 23) -> Ring {
            Ring(fraction: fraction.map { $0.isFinite ? $0 : 0 } ?? 0, size: size, tone: .piAccent, lineWidth: size < 18 ? 2 : 2.5, contextTint: true)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
        private var bounded: Double { max(0, min(1, fraction)) }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.base); CATransaction.setAnimationTimingFunction(Motion.timing(.easeOut))
            if Motion.reduced { CATransaction.setDisableActions(true) }
            // A SwiftUI circle's stroke is centred on the frame's edge.
            let rect = bounds
            track.frame = bounds; arc.frame = bounds
            track.path = CGPath(ellipseIn: rect, transform: nil)
            // From twelve o'clock, clockwise on screen.
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
            arc.path = path
            arc.strokeEnd = bounded
            let tint: NSColor = contextTint ? (bounded >= 0.95 ? .piDanger : bounded >= 0.8 ? .piWarning : .piAccent) : tone
            track.strokeColor = piCGColor(contextTint ? .piHairlineStrong : .piFillStrong); arc.strokeColor = piCGColor(tint)
            CATransaction.commit()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
        override func draw(_ dirtyRect: NSRect) {
            guard contextTint, size >= 18 else { return }
            let tint: NSColor = bounded >= 0.95 ? .piDanger : bounded >= 0.8 ? .piWarning : .piAccent
            Symbol("square.stack.3d.up", size: 9, weight: .medium).draw(centredIn: bounds, color: tint, scale: piScale)
        }
    }

    // MARK: - Chart parts

    /// A figure at the top of a panel: the reading, what it is, and a
    /// quieter line under it (warning ink when coverage is partial).
    @MainActor final class Figure: NSView, WidthSizing {
        let value: String, title: String, caption: String?
        let partial: Bool, large: Bool, warning: Bool
        init(value: String, title: String, caption: String? = nil, partial: Bool = false, large: Bool = false, warning: Bool = false) {
            self.value = value; self.title = title; self.caption = caption; self.partial = partial; self.large = large; self.warning = warning
            super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.group)
            setAccessibilityLabel([value, title, caption].compactMap { $0 }.joined(separator: ", "))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var valueLine: Line { Line(value, font: .systemFont(ofSize: large ? 21 : 15, weight: .semibold), color: warning ? .piWarning : .piInk) }
        private var titleLine: Line { Line(title, font: PiKit.Font.caption, color: .piInkSecondary) }
        func height(forWidth width: CGFloat) -> CGFloat {
            valueLine.size().height + 2 + titleLine.size().height + (caption.map { 2 + PiKit.wrappedHeight($0, font: PiKit.Font.micro, width: width) } ?? 0)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 200)) }
        override func draw(_ dirtyRect: NSRect) {
            PiKit.drawScaled(valueLine, in: CGRect(x: 0, y: 0, width: bounds.width, height: valueLine.size().height), minimumScale: 0.7, scale: piScale)
            var y = valueLine.size().height + 2
            titleLine.draw(in: CGRect(x: 0, y: y, width: bounds.width, height: titleLine.lineHeight), scale: piScale)
            y += titleLine.size().height + 2
            if let caption { PiKit.drawWrapped(caption, font: PiKit.Font.micro, color: partial ? .piWarning : .piInkTertiary, in: CGRect(x: 0, y: y, width: bounds.width, height: 1_000)) }
        }
    }

    /// The heading of one chart: what it shows and, quieter, how much of the
    /// session it covers; an accessory at the trailing edge.
    @MainActor final class ChartHeader: NSView, WidthSizing {
        let title: String, subtitle: String?
        let accessory: NSView?
        init(_ title: String, subtitle: String? = nil, accessory: NSView? = nil) {
            self.title = title; self.subtitle = subtitle; self.accessory = accessory
            super.init(frame: .zero)
            if let accessory { addSubview(accessory) }
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
            setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
            setAccessibilityRoleDescription("heading")
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var titleLine: Line { Line(title, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInk) }
        private var textWidth: CGFloat { bounds.width - (accessory.map { $0.fittingSize.width + PiSpacing.sm } ?? 0) }
        func height(forWidth width: CGFloat) -> CGFloat {
            let room = width - (accessory.map { $0.fittingSize.width + PiSpacing.sm } ?? 0)
            return titleLine.size().height + (subtitle.map { 1 + PiKit.wrappedHeight($0, font: PiKit.Font.micro, width: room) } ?? 0)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 300)) }
        override func layout() {
            super.layout()
            if let accessory {
                let fit = accessory.fittingSize
                accessory.frame = CGRect(x: bounds.width - fit.width, y: PiKit.round(titleLine.baseline() - accessory.firstBaselineOffsetFromTop, piScale), width: fit.width, height: fit.height)
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            titleLine.draw(in: CGRect(x: 0, y: 0, width: textWidth, height: titleLine.lineHeight), scale: piScale)
            if let subtitle { PiKit.drawWrapped(subtitle, font: PiKit.Font.micro, color: .piInkTertiary, in: CGRect(x: 0, y: titleLine.size().height + 1, width: textWidth, height: 1_000)) }
        }
    }

    /// One part of a whole, as a stacked bar draws it.
    struct BarSegment: Equatable, Sendable { let id: String; let fraction: Double }

    /// A stacked bar of shares: flat fills two points apart, rounded only at
    /// the bar's ends; a part too small to see keeps a three-point sliver.
    @MainActor final class SegmentedBar: NSView {
        var segments: [BarSegment] { didSet { needsDisplay = true } }
        let color: (String) -> NSColor
        let height: CGFloat
        init(segments: [BarSegment], height: CGFloat = 10, color: @escaping (String) -> NSColor) {
            self.segments = segments; self.height = height; self.color = color
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
        override func draw(_ dirtyRect: NSRect) {
            let visible = segments.filter { $0.fraction > 0 }
            guard !visible.isEmpty, bounds.width > 0 else { return }
            let gap: CGFloat = 2, sliver: CGFloat = 3
            let room = max(0, bounds.width - gap * CGFloat(visible.count - 1))
            let small = visible.filter { $0.fraction * room < sliver }
            let rest = max(0, room - sliver * CGFloat(small.count))
            let restFraction = visible.filter { $0.fraction * room >= sliver }.reduce(0) { $0 + $1.fraction }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2).addClip()
            var x: CGFloat = 0
            for segment in visible {
                let width = segment.fraction * room < sliver ? sliver : (restFraction > 0 ? rest * segment.fraction / restFraction : 0)
                color(segment.id).setFill()
                CGRect(x: x, y: 0, width: width, height: bounds.height).fill()
                x += width + gap
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Spinner

    /// A small turning ring (`PiSpinnerView`) at a control size's dimensions:
    /// mini 10, small 16, regular 32 points.
    @MainActor static func spinner(controlSize: NSControl.ControlSize) -> PiSpinnerView {
        let (size, line): (CGFloat, CGFloat) = controlSize == .mini ? (10, 1.4) : controlSize == .small ? (16, 1.8) : (32, 2.6)
        let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.fixedSize = CGSize(width: size, height: size)
        view.configure(lineWidth: line, turning: !Motion.reduced)
        return view
    }
}
