import AppKit
import QuartzCore

extension PiKit {
    /// A sheet's chrome: a header (a badge, the title, a quieter subtitle
    /// and the actions) on the window's cream, a hairline, the content on the
    /// content canvas, and an optional footer under another hairline.
    ///
    /// Escape leaves the sheet — `onCancel` when it has unsaved work to ask
    /// about, else `dismiss` — unless `cancelDisabled` holds it back during a
    /// write. In a window of its own (`windowChrome`) the header is the title
    /// bar: it leaves room for the window buttons, and Escape is the window's.
    @MainActor final class Sheet: NSView {
        static let trafficLightInset: CGFloat = 78
        let title: String
        let subtitle: String?
        let symbol: String?
        let windowChrome: Bool
        let content: NSView
        let actions: [NSView]
        let footer: NSView?
        var cancelDisabled = false
        var onCancel: (@MainActor () -> Void)?
        var dismiss: (@MainActor () -> Void)?
        /// Fixed or least sizes, as the SwiftUI sheet's frames.
        var width: CGFloat?, height: CGFloat?, minWidth: CGFloat?, minHeight: CGFloat?

        private let header = Box.ClipView(), body = Box.ClipView(), foot = Box.ClipView()
        private let titleView: TextLine
        private let subtitleView: NSTextField?
        private let badge: IconBadge?
        private let topLine = CALayer(), bottomLine = CALayer()

        init(_ title: String, subtitle: String? = nil, symbol: String? = nil, windowChrome: Bool = false, content: NSView,
             actions: [NSView] = [], footer: NSView? = nil) {
            self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.windowChrome = windowChrome
            self.content = content; self.actions = actions; self.footer = footer
            titleView = TextLine(Line(title, font: PiKit.Font.title(17), color: .piInk))
            subtitleView = subtitle.map { text in
                let field = NSTextField(wrappingLabelWithString: text)
                field.font = PiKit.Font.caption; field.textColor = .piInkSecondary
                field.maximumNumberOfLines = 2; field.isSelectable = true
                return field
            }
            badge = symbol.map { IconBadge(symbol: $0, size: 30) }
            super.init(frame: .zero)
            wantsLayer = true
            for view in [header, body, foot] { view.wantsLayer = true; addSubview(view) }
            for view in [badge, titleView, subtitleView].compactMap({ $0 }) as [NSView] { header.addSubview(view) }
            for action in actions { header.addSubview(action) }
            body.addSubview(content)
            if let footer { foot.addSubview(footer) } else { foot.isHidden = true }
            layer?.addSublayer(topLine); layer?.addSublayer(bottomLine)
            bottomLine.isHidden = footer == nil
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }

        private var leading: CGFloat { windowChrome ? Self.trafficLightInset : PiSpacing.xl }
        private var headerHeight: CGFloat {
            let text = titleView.intrinsicContentSize.height + (subtitleView.map { 3 + $0.intrinsicContentSize.height } ?? 0)
            let tallest = max(text, badge == nil ? 0 : 30, actions.map(\.fittingSize.height).max() ?? 0)
            return tallest + (windowChrome ? PiSpacing.md : PiSpacing.lg) + PiSpacing.lg
        }
        private var footerHeight: CGFloat { footer.map { $0.fittingSize.height + PiSpacing.md * 2 + 1 } ?? 0 }
        override var intrinsicContentSize: NSSize {
            let content = self.content.fittingSize
            return NSSize(width: width ?? max(minWidth ?? 0, content.width),
                          height: height ?? max(minHeight ?? 0, headerHeight + 1 + content.height + footerHeight))
        }

        override func layout() {
            super.layout()
            let headerHeight = self.headerHeight
            header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            let top = windowChrome ? PiSpacing.md : PiSpacing.lg
            let inner = headerHeight - top - PiSpacing.lg
            var x = leading
            if let badge { badge.frame = CGRect(x: x, y: top + (inner - 30) / 2, width: 30, height: 30); x += 30 + PiSpacing.md }
            var right = bounds.width - PiSpacing.xl
            for action in actions.reversed() {
                let size = action.fittingSize
                action.frame = CGRect(x: right - size.width, y: top + PiKit.round((inner - size.height) / 2, piScale), width: size.width, height: size.height)
                right -= size.width + PiSpacing.md
            }
            let textHeight = titleView.intrinsicContentSize.height + (subtitleView.map { 3 + $0.intrinsicContentSize.height } ?? 0)
            var y = top + PiKit.round((inner - textHeight) / 2, piScale)
            titleView.frame = CGRect(x: x, y: y, width: min(titleView.intrinsicContentSize.width, right - x), height: titleView.intrinsicContentSize.height)
            y += titleView.frame.height + 3
            if let subtitleView {
                subtitleView.preferredMaxLayoutWidth = max(0, right - x)
                subtitleView.frame = CGRect(x: x - PiKit.fieldInset, y: y, width: max(0, right - x) + PiKit.fieldInset * 2, height: subtitleView.intrinsicContentSize.height)
            }
            let footerHeight = self.footerHeight
            body.frame = CGRect(x: 0, y: headerHeight + 1, width: bounds.width, height: max(0, bounds.height - headerHeight - 1 - footerHeight))
            content.frame = body.bounds
            if let footer {
                foot.frame = CGRect(x: 0, y: bounds.height - footerHeight + 1, width: bounds.width, height: footerHeight - 1)
                // A footer narrower than the sheet sits in its middle, as a
                // SwiftUI footer does; a flexible one fills it.
                let room = foot.bounds.insetBy(dx: PiSpacing.xl, dy: PiSpacing.md)
                let natural = footer.intrinsicContentSize.width
                if natural != NSView.noIntrinsicMetric, natural < room.width {
                    footer.frame = CGRect(x: PiKit.round(room.midX - natural / 2, piScale), y: room.minY, width: natural, height: room.height)
                } else {
                    footer.frame = room
                }
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            topLine.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: 1)
            bottomLine.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: 1)
            CATransaction.commit()
            updateLayer()
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.backgroundColor = piCGColor(.piWindow)
            header.layer?.backgroundColor = piCGColor(.piWindow)
            foot.layer?.backgroundColor = piCGColor(.piWindow)
            body.layer?.backgroundColor = piCGColor(.piContent)
            topLine.backgroundColor = piCGColor(.piHairline); bottomLine.backgroundColor = piCGColor(.piHairline)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The header badge pops in once.
            if window != nil, let badge, !Motion.reduced, let layer = badge.layer {
                let pop = Motion.pop("transform.scale"); pop.fromValue = 0.6; pop.toValue = 1
                pop.beginTime = CACurrentMediaTime() + 0.08; pop.fillMode = .backwards
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
                fade.duration = Motion.quick; fade.beginTime = pop.beginTime; fade.fillMode = .backwards
                layer.add(pop, forKey: "pop"); layer.add(fade, forKey: "fade")
            }
        }

        // MARK: Escape

        /// Leaves the sheet as Escape does.
        func cancel() {
            guard !windowChrome, !cancelDisabled else { return }
            if let onCancel { onCancel() } else { dismiss?() }
        }
        override func cancelOperation(_ sender: Any?) { cancel() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if !windowChrome, event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                cancel(); return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
