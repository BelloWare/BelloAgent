import AppKit
import QuartzCore

extension PiKit {
    /// A rounded surface: a fill, a hairline centred on its edge (half
    /// outside, as a SwiftUI stroke overlay is), an optional shadow, and
    /// content inset by padding. The cards, insets, raised panels and field
    /// frames are all this.
    @MainActor class Box: NSView, WidthSizing {
        var fillColor: NSColor? { didSet { needsDisplay = true } }
        var strokeColor: NSColor? { didSet { needsDisplay = true } }
        var strokeWidth: CGFloat = 1 { didSet { needsLayout = true } }
        /// A clipped stroke overlay shows only the half inside its edge.
        var clipsStroke = false { didSet { needsLayout = true } }
        /// Nil: a capsule.
        var cornerRadius: CGFloat? { didSet { needsLayout = true } }
        var shadowColor: NSColor? { didSet { needsDisplay = true } }
        var shadowRadius: CGFloat = 0 { didSet { needsDisplay = true } }
        var shadowOffsetY: CGFloat = 0 { didSet { needsDisplay = true } }
        /// Clips the content to the shape, as `.clipShape`.
        var clipsContent = false { didSet { needsLayout = true } }
        var padding = NSEdgeInsets() { didSet { invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) } }
        /// The content, laid out inside the padding at its full width.
        var content: NSView? {
            didSet {
                oldValue?.removeFromSuperview()
                if let content { contentHolder.addSubview(content) }
                invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
            }
        }
        private let fillLayer = CALayer(), strokeLayer = CALayer()
        private let contentHolder = ClipView()

        final class ClipView: NSView {
            override var isFlipped: Bool { true }
        }

        init(fill: NSColor? = nil, stroke: NSColor? = nil, cornerRadius: CGFloat? = nil, padding: NSEdgeInsets = NSEdgeInsets(), content: NSView? = nil) {
            fillColor = fill; strokeColor = stroke; self.cornerRadius = cornerRadius; self.padding = padding
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            for layer in [fillLayer, strokeLayer] as [CALayer] { layer.cornerCurve = .continuous; self.layer?.addSublayer(layer) }
            strokeLayer.zPosition = 1
            contentHolder.wantsLayer = true
            addSubview(contentHolder)
            self.content = content
            if let content { contentHolder.addSubview(content) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        var radius: CGFloat { cornerRadius ?? min(bounds.width, bounds.height) / 2 }

        override var intrinsicContentSize: NSSize {
            guard let content else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
            let size = content.fittingSize
            return NSSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
        }
        /// The height for `width`, its content given the width inside the padding.
        func height(forWidth width: CGFloat) -> CGFloat {
            guard let content else {
                // A box with no content view (a field) is as tall as it says.
                let own = intrinsicContentSize.height
                return own == NSView.noIntrinsicMetric ? padding.top + padding.bottom : own
            }
            return PiKit.height(of: content, width: width - padding.left - padding.right) + padding.top + padding.bottom
        }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fillLayer.frame = bounds; fillLayer.cornerRadius = radius
            layer?.masksToBounds = clipsStroke
            layer?.cornerRadius = clipsStroke ? radius : 0
            layer?.cornerCurve = .continuous
            strokeLayer.frame = bounds.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
            strokeLayer.cornerRadius = radius + strokeWidth / 2; strokeLayer.borderWidth = strokeWidth
            contentHolder.frame = bounds
            contentHolder.layer?.cornerRadius = clipsContent ? radius : 0
            contentHolder.layer?.cornerCurve = .continuous
            contentHolder.layer?.masksToBounds = clipsContent
            CATransaction.commit()
            content?.frame = CGRect(x: padding.left, y: padding.top, width: max(0, bounds.width - padding.left - padding.right),
                                    height: max(0, bounds.height - padding.top - padding.bottom))
            updateLayer()
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            fillLayer.backgroundColor = fillColor.map(piCGColor) ?? CGColor.clear
            strokeLayer.borderColor = strokeColor.map(piCGColor) ?? CGColor.clear
            if let shadowColor {
                fillLayer.shadowColor = piCGColor(shadowColor); fillLayer.shadowOpacity = 1
                fillLayer.shadowRadius = PiKit.shadowRadius(shadowRadius); fillLayer.shadowOffset = CGSize(width: 0, height: shadowOffsetY)
            } else {
                fillLayer.shadowOpacity = 0
            }
        }
    }

    /// The height `view` takes at `width`: its own answer when it has one,
    /// else Auto Layout's.
    @MainActor static func height(of view: NSView, width: CGFloat) -> CGFloat {
        if let sized = view as? WidthSizing { return sized.height(forWidth: width) }
        let intrinsic = view.intrinsicContentSize
        if intrinsic.height != NSView.noIntrinsicMetric { return intrinsic.height }
        return view.fittingSize.height
    }

    /// A container that wants to know when something inside it changed its
    /// size (a popover's document, which grows the panel).
    @MainActor protocol SizeObserver: AnyObject { func contentSizeChanged() }
    /// Tells the nearest container watching for it that `view` changed size.
    /// Every container on the way lays out again (a flow moves its other
    /// items even when its own height stays the same).
    @MainActor static func sizeChanged(_ view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            current.invalidateIntrinsicContentSize(); current.needsLayout = true
            if let observer = current as? SizeObserver { observer.contentSizeChanged(); return }
            ancestor = current.superview
        }
    }

    /// A view whose height depends on the width it is given.
    @MainActor protocol WidthSizing: AnyObject { func height(forWidth width: CGFloat) -> CGFloat }

    // MARK: - Text fields

    /// The rounded text field, with an optional leading symbol: plain text
    /// (or secure, or monospaced) on a white surface in a hairline frame.
    @MainActor final class TextField: Box, NSTextFieldDelegate {
        let field: NSTextField
        private let icon: Symbol?
        /// The text, set from outside without calling `onChange`.
        var text: String {
            get { field.stringValue }
            set { if field.stringValue != newValue { field.stringValue = newValue } }
        }
        var onChange: ((String) -> Void)?
        var onSubmit: (() -> Void)?

        init(placeholder: String, text: String = "", icon: String? = nil, secure: Bool = false, mono: Bool = false,
             onChange: ((String) -> Void)? = nil, onSubmit: (() -> Void)? = nil) {
            field = secure ? SecureFieldText(string: text) : FieldText(string: text)
            self.icon = icon.map { Symbol($0, size: 11, weight: .medium) }
            self.onChange = onChange; self.onSubmit = onSubmit
            super.init(fill: .piSurface, stroke: .piHairline, cornerRadius: 10,
                       padding: NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11))
            PiKit.configurePlain(field, font: mono ? PiKit.Font.mono : PiKit.Font.body, placeholder: placeholder)
            field.delegate = self
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
            field.target = self; field.action = #selector(submitted)
            addSubview(field)
            if let icon = self.icon {
                iconView = SymbolView(icon, color: .piInkTertiary)
                addSubview(iconView!)
            }
        }
        private var iconView: SymbolView?
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        @objc private func submitted() { onSubmit?() }
        func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }

        private var iconWidth: CGFloat { icon.map { $0.layoutSize.width + 7 } ?? 0 }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: field.intrinsicContentSize.height + padding.top + padding.bottom)
        }
        override func layout() {
            super.layout()
            let height = field.intrinsicContentSize.height
            if let iconView, let icon { iconView.frame = CGRect(x: padding.left, y: padding.top, width: icon.layoutSize.width, height: height) }
            field.frame = CGRect(x: padding.left + iconWidth - PiKit.fieldInset, y: padding.top, width: max(0, bounds.width - padding.left - padding.right - iconWidth) + PiKit.fieldInset * 2, height: height)
        }
    }

    /// A field's text, which reads disabled to VoiceOver and leaves the
    /// key-view loop inside a disabled selectable row, as SwiftUI's did.
    @MainActor final class FieldText: NSTextField {
        override func isAccessibilityEnabled() -> Bool { isEnabled && !piInDisabledRow }
        override var acceptsFirstResponder: Bool { super.acceptsFirstResponder && !piInDisabledRow }
        override var canBecomeKeyView: Bool { super.canBecomeKeyView && !piInDisabledRow }
    }
    /// `FieldText` for a secure field.
    @MainActor final class SecureFieldText: NSSecureTextField {
        override func isAccessibilityEnabled() -> Bool { isEnabled && !piInDisabledRow }
        override var acceptsFirstResponder: Bool { super.acceptsFirstResponder && !piInDisabledRow }
        override var canBecomeKeyView: Bool { super.canBecomeKeyView && !piInDisabledRow }
    }

    /// A symbol as a view, centred in its frame as `Image(systemName:)` is;
    /// decorative to accessibility unless given a label.
    @MainActor final class SymbolView: NSView {
        var symbol: Symbol { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
        var color: NSColor { didSet { needsDisplay = true } }
        init(_ symbol: Symbol, color: NSColor) {
            self.symbol = symbol; self.color = color
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { symbol.layoutSize }
        override func draw(_ dirtyRect: NSRect) { symbol.draw(centredIn: bounds, color: color, scale: piScale) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A plain field: no bezel, no background, no focus ring, the app's ink.
    @MainActor static func configurePlain(_ field: NSTextField, font: NSFont, placeholder: String) {
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = font; field.textColor = .piInk
        field.placeholderString = placeholder
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
    }
    /// What an AppKit text field's cell insets its text by, which SwiftUI's
    /// plain field draws without: the field sits that far left of its slot.
    static let fieldInset: CGFloat = 2

    /// The rounded numeric field: whole numbers in monospaced digits.
    @MainActor final class NumberField: Box, NSTextFieldDelegate {
        let field: NSTextField = FieldText()
        var value: Int {
            didSet { if oldValue != value || field.integerValue != value { field.integerValue = value } }
        }
        var onChange: ((Int) -> Void)?
        var onSubmit: (() -> Void)?
        let width: CGFloat

        init(placeholder: String, value: Int, width: CGFloat = 120, onChange: ((Int) -> Void)? = nil, onSubmit: (() -> Void)? = nil) {
            self.value = value; self.width = width; self.onChange = onChange; self.onSubmit = onSubmit
            super.init(fill: .piSurface, stroke: .piHairlineStrong, cornerRadius: PiRadius.sm,
                       padding: NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11))
            PiKit.configurePlain(field, font: PiKit.Font.monospacedDigits(PiKit.Font.body), placeholder: placeholder)
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            field.formatter = formatter
            field.integerValue = value
            field.delegate = self
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
            field.target = self; field.action = #selector(submitted)
            addSubview(field)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        @objc private func submitted() { commit(); onSubmit?() }
        func controlTextDidEndEditing(_ notification: Notification) { commit() }
        private func commit() {
            let next = field.integerValue
            guard next != value else { return }
            value = next
            onChange?(next)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: width, height: field.intrinsicContentSize.height + padding.top + padding.bottom)
        }
        override func layout() {
            super.layout()
            field.frame = CGRect(x: padding.left - PiKit.fieldInset, y: padding.top, width: max(0, bounds.width - padding.left - padding.right) + PiKit.fieldInset * 2, height: field.intrinsicContentSize.height)
        }
    }

    /// A date and time the reader types, as AppKit's date field edits it,
    /// without its bezel: the Pi pill around it is its frame.
    @MainActor static func dateField(_ date: Date, elements: NSDatePicker.ElementFlags = [.yearMonthDay, .hourMinute]) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.isBezeled = false; picker.isBordered = false; picker.drawsBackground = false
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: PiKit.Font.captionSize); picker.textColor = .piInk
        picker.datePickerElements = elements
        picker.dateValue = date
        return picker
    }
}
