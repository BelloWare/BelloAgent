import AppKit
import QuartzCore

extension PiKit {
    // MARK: - Selectable rows

    /// Moves a list's selection highlight from row to row, as the SwiftUI
    /// rows' shared namespace does: the newly selected row's highlight
    /// starts where the old one was and glides home.
    @MainActor final class SelectionGlide {
        fileprivate weak var selectedRow: SelectableRow?
        init() {}
    }

    /// A row of a custom list: its content, a soft accent wash when it is
    /// the one open, a quiet fill under the pointer, and an outline when it
    /// is marked for a bulk action. Clicking selects; a double click runs
    /// `doubleClick`. Controls inside it stay their own.
    @MainActor final class SelectableRow: ButtonBase, WidthSizing {
        let contentView: NSView
        private var disabledByRow: [NSControl] = []
        var selected: Bool { didSet { if oldValue != selected { selectionChanged() } } }
        var marked: Bool { didSet { refreshFace() } }
        var doubleClick: (() -> Void)?
        /// Shared by the rows of one list, so the highlight glides between them.
        var glide: SelectionGlide?
        static let padding = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        init(content: NSView, selected: Bool = false, marked: Bool = false, providesCursor: Bool = true, glide: SelectionGlide? = nil,
             action: (() -> Void)? = nil, doubleClick: (() -> Void)? = nil) {
            contentView = content; self.selected = selected; self.marked = marked; self.glide = glide; self.doubleClick = doubleClick
            super.init(frame: .zero)
            pressScales = false
            disabledOpacity = Float(1) * PiKit.plainDisabledDimming
            showsPointer = providesCursor
            onPress = action
            addSubview(content)
            if selected { glide?.selectedRow = self }
            setAccessibilityLabel(PiKit.spokenText(of: content))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override func isAccessibilitySelected() -> Bool { selected }
        override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
        /// Disabled, the row's content dims as a disabled plain button's label
        /// does, and the controls inside it are disabled too.
        override var isEnabled: Bool {
            didSet {
                guard oldValue != isEnabled else { return }
                contentView.alphaValue = isEnabled ? 1 : CGFloat(PiKit.plainDisabledDimming)
                if isEnabled {
                    // Only what the row turned off comes back on.
                    for control in disabledByRow { control.isEnabled = true }
                    disabledByRow = []
                } else {
                    disabledByRow = PiKit.controls(in: contentView).filter(\.isEnabled)
                    for control in disabledByRow { control.isEnabled = false }
                }
            }
        }

        func height(forWidth width: CGFloat) -> CGFloat {
            PiKit.height(of: contentView, width: width - Self.padding.left - Self.padding.right) + Self.padding.top + Self.padding.bottom
        }
        override var intrinsicContentSize: NSSize {
            let size = contentView.fittingSize
            return NSSize(width: NSView.noIntrinsicMetric, height: size.height + Self.padding.top + Self.padding.bottom)
        }
        override func layout() {
            super.layout()
            contentView.frame = CGRect(x: Self.padding.left, y: Self.padding.top, width: max(0, bounds.width - Self.padding.left - Self.padding.right),
                                       height: max(0, bounds.height - Self.padding.top - Self.padding.bottom))
        }
        override func styleFace() {
            fill.backgroundColor = piCGColor(selected ? .piAccentSoft : marked || hovering ? .piFill : .clear)
            stroke.borderColor = marked && !selected ? piCGColor(NSColor.piAccent.withAlphaComponent(0.55)) : CGColor.clear
        }
        private func selectionChanged() {
            defer { refreshFace() }
            guard selected, let glide else { return }
            let previous = glide.selectedRow
            glide.selectedRow = self
            guard let previous, previous !== self, previous.window === window, window != nil, !Motion.reduced, let superview else { return }
            // The highlight leaves where the old one sat and glides here.
            let from = convert(previous.convert(previous.bounds, to: superview), from: superview)
            let to = bounds
            let spring = Motion.glide("position")
            spring.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY)); spring.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
            fill.add(spring, forKey: "glide")
        }
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { doubleClick?() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // A control inside the row keeps its own clicks while enabled.
            if let hit = super.hitTest(point), hit !== self, hit !== contentView, let control = hit as? NSControl, control.isEnabled { return hit }
            return frame.contains(point) && shape(in: bounds).contains(convert(point, from: superview)) ? self : nil
        }
    }

    /// Every control in `view`'s tree, `view` included.
    @MainActor static func controls(in view: NSView) -> [NSControl] {
        (view as? NSControl).map { [$0] } ?? [] + view.subviews.flatMap { controls(in: $0) }
    }

    /// The words a view shows, joined, for an accessibility name.
    @MainActor static func spokenText(of view: NSView) -> String {
        if let line = view as? TextLine { return line.line.text }
        if let text = view as? WrappedText { return text.text }
        if let field = view as? NSTextField { return field.stringValue }
        return view.subviews.map { spokenText(of: $0) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Settings

    /// A settings group: its title in small capitals, rows on a white card
    /// separated by hairlines, and an optional footnote.
    @MainActor final class SettingsGroup: NSView, WidthSizing {
        let title: String
        var footer: String? { didSet { footerView.text = footer ?? ""; footerView.isHidden = footer == nil; needsLayout = true } }
        private let titleView: TextLine
        private let card = Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md)
        private let footerView = WrappedText("", font: PiKit.Font.caption, color: .piInkTertiary)
        private(set) var rows: [Row] = []
        private let stack = Box.ClipView()

        init(title: String, footer: String? = nil, rows: [Row]) {
            self.title = title; self.footer = footer
            titleView = TextLine(Line(title, font: PiKit.Font.micro, color: .piInkSecondary, tracking: 0.5, uppercased: true))
            super.init(frame: .zero)
            card.content = stack
            for view in [titleView, card, footerView] as [NSView] { addSubview(view) }
            footerView.text = footer ?? ""; footerView.isHidden = footer == nil
            setRows(rows)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        func setRows(_ rows: [Row]) {
            self.rows.forEach { $0.removeFromSuperview() }
            self.rows = rows
            for (index, row) in rows.enumerated() { row.lastInGroup = index == rows.count - 1; stack.addSubview(row) }
            needsLayout = true; invalidateIntrinsicContentSize()
        }
        func height(forWidth width: CGFloat) -> CGFloat {
            var height = titleView.intrinsicContentSize.height + PiSpacing.sm
            height += rows.reduce(0) { $0 + $1.height(forWidth: width) }
            if footer != nil { height += PiSpacing.sm + footerView.height(forWidth: width - 8) }
            return height
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
        override func layout() {
            super.layout()
            let width = bounds.width
            let titleSize = titleView.intrinsicContentSize
            titleView.frame = CGRect(x: 4, y: 0, width: min(titleSize.width, width - 4), height: titleSize.height)
            var y: CGFloat = 0
            for row in rows {
                let height = row.height(forWidth: width)
                row.frame = CGRect(x: 0, y: y, width: width, height: height); y += height
            }
            card.frame = CGRect(x: 0, y: titleSize.height + PiSpacing.sm, width: width, height: y)
            if footer != nil {
                let height = footerView.height(forWidth: width - 8)
                footerView.frame = CGRect(x: 4, y: card.frame.maxY + PiSpacing.sm, width: width - 8, height: height)
            }
        }
    }

    /// One settings row: its label (and a quieter detail) on the left, its
    /// control on the right, a hairline under it unless it is the last.
    @MainActor final class Row: NSView, WidthSizing {
        let label: String, detail: String?
        let control: NSView?
        /// No hairline under it, whatever its place (the SwiftUI row's `last`).
        var last: Bool { didSet { needsLayout = true } }
        /// Whether it is the last row of its group; the group sets it.
        var lastInGroup = false { didSet { needsLayout = true } }
        private var hidesSeparator: Bool { last || lastInGroup }
        private let labelView: WrappedText
        private let detailView: WrappedText?
        private let separator = CALayer()

        init(label: String, detail: String? = nil, last: Bool = false, control: NSView?) {
            self.label = label; self.detail = detail; self.control = control; self.last = last
            labelView = WrappedText(label, font: PiKit.Font.body, color: .piInk)
            detailView = detail.map { WrappedText($0, font: PiKit.Font.caption, color: .piInkSecondary) }
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(labelView)
            if let detailView { addSubview(detailView) }
            if let control { addSubview(control) }
            layer?.addSublayer(separator)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        /// The text column: what the control leaves, never under 180 points.
        private func textWidth(_ width: CGFloat) -> CGFloat {
            let natural = max(Line(label, font: PiKit.Font.body, color: .black).size(scale: piScale).width,
                              detail.map { Line($0, font: PiKit.Font.caption, color: .black).size(scale: piScale).width } ?? 0)
            let room = width - 32 - controlSize(width: width).width - (control == nil ? 0 : PiSpacing.lg * 2)
            return min(natural, max(180, room))
        }
        private func textHeight(_ width: CGFloat) -> CGFloat {
            let column = textWidth(width)
            return labelView.height(forWidth: column) + (detailView.map { 2 + $0.height(forWidth: column) } ?? 0)
        }
        private func controlSize(width: CGFloat) -> CGSize {
            guard let control else { return .zero }
            // The label's 180 points, then the stack's spacing on both sides
            // of the spacer between them.
            let room = min(380, max(0, width - 32 - 180 - PiSpacing.lg * 2))
            let intrinsic = control.intrinsicContentSize
            let controlWidth = intrinsic.width == NSView.noIntrinsicMetric ? room : min(room, intrinsic.width)
            return CGSize(width: controlWidth, height: PiKit.height(of: control, width: controlWidth))
        }
        func height(forWidth width: CGFloat) -> CGFloat {
            max(textHeight(width), controlSize(width: width).height) + 20 + (hidesSeparator ? 0 : 1)
        }
        override func layout() {
            super.layout()
            // The text block and the control are each centred in the row
            // inside its 10-point padding, as an HStack centres them.
            let inner = bounds.height - (hidesSeparator ? 0 : 1) - 20
            let column = textWidth(bounds.width)
            var y = 10 + PiKit.round((inner - textHeight(bounds.width)) / 2, piScale)
            labelView.frame = CGRect(x: PiSpacing.lg, y: y, width: column, height: labelView.height(forWidth: column))
            y += labelView.frame.height + 2
            if let detailView { detailView.frame = CGRect(x: PiSpacing.lg, y: y, width: column, height: detailView.height(forWidth: column)) }
            if let control {
                let size = controlSize(width: bounds.width)
                control.frame = CGRect(x: bounds.width - PiSpacing.lg - size.width, y: 10 + PiKit.round((inner - size.height) / 2, piScale), width: size.width, height: size.height)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            separator.isHidden = hidesSeparator
            separator.frame = CGRect(x: PiSpacing.lg, y: bounds.height - 1, width: bounds.width - PiSpacing.lg, height: 1)
            CATransaction.commit()
            updateLayer()
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { separator.backgroundColor = piCGColor(.piHairline) }
    }

    // MARK: - Resize handle

    /// A one-point hairline that is also a drag handle, with its grip always
    /// drawn quietly and strengthened under the pointer or while dragging.
    /// Frame it `hitThickness` across, centred on the boundary: the line is
    /// drawn in its middle.
    @MainActor final class ResizeHandle: NSView {
        enum Orientation { case vertical, horizontal }
        static let gripThickness: CGFloat = 2
        static let gripLength: CGFloat = 18
        static let hitThickness: CGFloat = 9
        static let restingGripOpacity: Float = 0.35
        let orientation: Orientation
        var dragging = false { didSet { refresh() } }
        var changed: ((CGFloat) -> Void)?
        var ended: ((CGFloat) -> Void)?
        private var hovering = false
        private var start: NSPoint?
        /// Whether the pointer has moved a point since the press: a click
        /// alone is not a drag, as SwiftUI's one-point drag threshold has it.
        private var moved = false
        private let line = CALayer(), grip = CALayer()
        private var vertical: Bool { orientation == .vertical }

        init(orientation: Orientation, label: String, hint: String = "Drag to resize", changed: ((CGFloat) -> Void)? = nil, ended: ((CGFloat) -> Void)? = nil) {
            self.orientation = orientation; self.changed = changed; self.ended = ended
            super.init(frame: .zero)
            wantsLayer = true
            grip.cornerCurve = .continuous
            layer?.addSublayer(line); layer?.addSublayer(grip)
            setAccessibilityElement(true); setAccessibilityRole(.splitter)
            setAccessibilityLabel(label); setAccessibilityHelp(hint); setAccessibilityIdentifier("resizeHandle")
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            vertical ? NSSize(width: Self.hitThickness, height: NSView.noIntrinsicMetric) : NSSize(width: NSView.noIntrinsicMetric, height: Self.hitThickness)
        }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if vertical {
                line.frame = CGRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height)
                grip.frame = CGRect(x: (bounds.width - Self.gripThickness) / 2, y: (bounds.height - Self.gripLength) / 2, width: Self.gripThickness, height: Self.gripLength)
            } else {
                line.frame = CGRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1)
                grip.frame = CGRect(x: (bounds.width - Self.gripLength) / 2, y: (bounds.height - Self.gripThickness) / 2, width: Self.gripLength, height: Self.gripThickness)
            }
            grip.cornerRadius = Self.gripThickness / 2
            CATransaction.commit()
            refresh(animated: false)
        }
        private func refresh(animated: Bool = true) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Motion.layers(Motion.quick, animated: animated) {
                    line.backgroundColor = piCGColor(dragging ? .piHairlineStrong : .piHairline)
                    grip.backgroundColor = piCGColor(.piHairlineStrong)
                    grip.opacity = hovering || dragging ? 1 : Self.restingGripOpacity
                }
            }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh(animated: false) }
        override func cursorUpdate(with event: NSEvent) { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
        override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
        override func mouseExited(with event: NSEvent) { hovering = false; refresh(); if !dragging { NSCursor.arrow.set() } }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow; moved = false }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = event.locationInWindow
            if !moved, hypot(now.x - start.x, now.y - start.y) < 1 { return }
            moved = true
            changed?(vertical ? now.x - start.x : start.y - now.y)
        }
        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let now = event.locationInWindow
            self.start = nil
            guard moved else { return }
            ended?(vertical ? now.x - start.x : start.y - now.y)
        }
    }

    // MARK: - Pager

    /// Previous and Next around a caption between them.
    @MainActor final class Pager: NSView {
        let previous: Button, next: Button
        let center: NSView
        var canPrevious: Bool { get { previous.isEnabled } set { previous.isEnabled = newValue } }
        var canNext: Bool { get { next.isEnabled } set { next.isEnabled = newValue } }
        init(previousLabel: String = "Previous", nextLabel: String = "Next", center: NSView, canPrevious: Bool, canNext: Bool,
             previous: @escaping () -> Void, next: @escaping () -> Void) {
            self.previous = Button(previousLabel, symbol: "chevron.left", style: .secondary, compact: true, action: previous)
            self.next = Button(nextLabel, symbol: "chevron.right", style: .secondary, compact: true, action: next)
            self.next.symbolTrailing = true
            self.center = center
            super.init(frame: .zero)
            for view in [self.previous, center, self.next] { addSubview(view) }
            self.canPrevious = canPrevious; self.canNext = canNext
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            let sizes = [previous.intrinsicContentSize, center.fittingSize, next.intrinsicContentSize]
            return NSSize(width: sizes.reduce(0) { $0 + $1.width } + PiSpacing.sm * 2, height: sizes.map(\.height).max() ?? 0)
        }
        override func layout() {
            super.layout()
            var x: CGFloat = 0
            for view in [previous, center, next] {
                let size = view === center ? center.fittingSize : view.intrinsicContentSize
                view.frame = CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
                x += size.width + PiSpacing.sm
            }
        }
    }

    // MARK: - Flow

    /// Wraps its subviews in rows, as `PiFlow`: each at its own width (or the
    /// row's, when wider than a row), starting a new row when the next does
    /// not fit. A subview in `fillsRow` takes what is left of its row, down to
    /// its narrowest form, before starting a row of its own.
    @MainActor final class FlowView: NSView, WidthSizing {
        var spacing: CGFloat = 6 { didSet { needsLayout = true } }
        var rowSpacing: CGFloat = 6 { didSet { needsLayout = true } }
        /// Reports the width its widest row uses instead of the width offered.
        var reportsUsedWidth = false
        /// Subviews that fill what is left of their row.
        var fillsRow: Set<ObjectIdentifier> = []
        /// A subview's narrowest form, for one that fills its row.
        var narrowest: (NSView) -> CGFloat = { _ in 0 }

        override var isFlipped: Bool { true }
        private func ideal(_ view: NSView) -> CGSize {
            let size = view.intrinsicContentSize
            return size.width == NSView.noIntrinsicMetric ? view.fittingSize : size
        }
        private func place(width: CGFloat, apply: Bool) -> CGSize {
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
            for view in subviews where !view.isHidden {
                var size = ideal(view)
                var wraps: Bool
                if fillsRow.contains(ObjectIdentifier(view)) {
                    let least = narrowest(view)
                    // Unbounded, it counts as its narrowest form.
                    guard width.isFinite else { size.width = least; size.height = PiKit.height(of: view, width: least); wraps = false; if apply { view.frame = CGRect(x: x, y: y, width: size.width, height: size.height) }; x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing); continue }
                    wraps = x > 0 && x + least > width
                    let room = max(least, wraps ? width : width - x)
                    if size.width > room { size.width = room; size.height = PiKit.height(of: view, width: room) }
                } else {
                    if width.isFinite, size.width > width { size.width = width; size.height = PiKit.height(of: view, width: width) }
                    wraps = x > 0 && x + size.width > width
                }
                if wraps { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
                if apply { view.frame = CGRect(x: x, y: y, width: size.width, height: size.height) }
                x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
            }
            return CGSize(width: width.isFinite ? (reportsUsedWidth ? min(width, maxX) : width) : maxX, height: y + rowHeight)
        }
        func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false).height }
        func size(forWidth width: CGFloat) -> CGSize { place(width: width, apply: false) }
        override var intrinsicContentSize: NSSize { place(width: bounds.width > 0 ? bounds.width : .infinity, apply: false) }
        override func layout() { super.layout(); _ = place(width: bounds.width, apply: true) }
        override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
}
