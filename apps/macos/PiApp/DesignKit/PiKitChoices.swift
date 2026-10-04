import AppKit
import QuartzCore

extension PiKit {
    // MARK: - Pill faces

    /// A pill that opens something: optionally a symbol, a label cut in the
    /// middle past `maxLabelWidth`, and a trailing chevron, on a white
    /// capsule in a strong hairline. The dropdown and the menu button.
    @MainActor class PillFaceButton: ButtonBase {
        var label: String { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        var icon: String? { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        var maxLabelWidth: CGFloat? { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        let chevron: String
        let compact: Bool
        let fontSize: CGFloat
        let padding: (h: CGFloat, v: CGFloat)
        /// Whether the pointer shades the face (the menu button) or not (the dropdown).
        let hoverFill: Bool

        init(label: String, icon: String?, chevron: String, compact: Bool, fontSize: CGFloat, padding: (h: CGFloat, v: CGFloat), hoverFill: Bool) {
            self.label = label; self.icon = icon; self.chevron = chevron; self.compact = compact
            self.fontSize = fontSize; self.padding = padding; self.hoverFill = hoverFill
            super.init(frame: .zero)
            pressScales = false
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        var line: Line { Line(label, font: .systemFont(ofSize: fontSize, weight: .medium), color: .piInk) }
        var iconSymbol: Symbol? { icon.map { Symbol($0, size: 11, weight: .semibold) } }
        var iconInk: NSColor { .piInkSecondary }
        var chevronSymbol: Symbol { Symbol(chevron, size: 9, weight: .semibold) }
        static let spacing: CGFloat = 6
        private var textWidth: CGFloat {
            let width = line.size(scale: piScale).width
            return maxLabelWidth.map { min($0, width) } ?? width
        }
        override var intrinsicContentSize: NSSize {
            var width = textWidth + Self.spacing + chevronSymbol.layoutSize.width
            var height = max(line.size(scale: piScale).height, chevronSymbol.layoutSize.height)
            if let iconSymbol { width += iconSymbol.layoutSize.width + Self.spacing; height = max(height, iconSymbol.layoutSize.height) }
            return NSSize(width: width + padding.h * 2, height: height + padding.v * 2)
        }
        override func drawContent(in rect: CGRect) {
            var x = padding.h
            let inner = CGRect(x: 0, y: padding.v, width: rect.width, height: rect.height - padding.v * 2)
            if let iconSymbol {
                let box = iconSymbol.layoutSize
                iconSymbol.draw(centredIn: CGRect(x: x, y: inner.minY, width: box.width, height: inner.height), color: iconInk, scale: piScale)
                x += box.width + Self.spacing
            }
            let text = line.size(scale: piScale)
            line.draw(in: CGRect(x: x, y: inner.minY + PiKit.round((inner.height - text.height) / 2, piScale), width: textWidth, height: text.height),
                      truncation: .middle, scale: piScale)
            x += textWidth + Self.spacing
            let box = chevronSymbol.layoutSize
            chevronSymbol.draw(centredIn: CGRect(x: x, y: inner.minY, width: box.width, height: inner.height), color: .piInkTertiary, scale: piScale)
        }
        override func styleFace() {
            fill.backgroundColor = piCGColor(hoverFill && hovering && isEnabled ? .piFill : .piSurface)
            stroke.borderColor = piCGColor(.piHairlineStrong)
        }
    }

    // MARK: - Dropdown

    /// The pill dropdown: the chosen item, opening the choices in a popover.
    /// VoiceOver names it for what it chooses and reads the choice as its value.
    @MainActor final class Dropdown<Tag: Hashable>: PillFaceButton {
        /// An open list closes when its items or selection change under it.
        /// An open list follows its items and selection where it stands.
        var items: [(Tag, String)] {
            didSet {
                guard oldValue.map(\.0) != items.map(\.0) || oldValue.map(\.1) != items.map(\.1) else { return }
                label = current; setAccessibilityValue(current); refreshOpenList()
            }
        }
        /// Set from outside without calling `onSelect`.
        var selection: Tag { didSet { label = current; setAccessibilityValue(current); if oldValue != selection { refreshOpenList() } } }
        private func refreshOpenList() {
            guard let list, popover?.isShown == true else { return }
            list.update(selection: selection, choices: items.map { Choice(id: $0.0, title: $0.1) })
            (popover?.contentViewController)?.preferredContentSize = list.frame.size
        }
        let placeholder: String
        var onSelect: ((Tag) -> Void)?
        private var popover: NSPopover?
        private var current: String { items.first { $0.0 == selection }?.1 ?? placeholder }

        init(selection: Tag, items: [(Tag, String)], placeholder: String = "Choose", icon: String? = nil, compact: Bool = false,
             maxLabelWidth: CGFloat? = nil, accessibilityName: String? = nil, onSelect: ((Tag) -> Void)? = nil) {
            self.items = items; self.selection = selection; self.placeholder = placeholder; self.onSelect = onSelect
            super.init(label: items.first { $0.0 == selection }?.1 ?? placeholder, icon: icon, chevron: "chevron.up.chevron.down", compact: compact,
                       fontSize: compact ? 12 : 13, padding: compact ? (10, 5) : (12, 7), hoverFill: false)
            self.maxLabelWidth = maxLabelWidth
            // The SwiftUI dropdown is a plain button: disabled, its face dims.
            disabledOpacity = PiKit.plainDisabledDimming
            setAccessibilityLabel(accessibilityName ?? placeholder)
            setAccessibilityValue(current)
            onPress = { [weak self] in self?.toggleChoices() }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        /// The list that opens, for tests.
        private(set) var list: ChoiceList<Tag>?
        func toggleChoices() {
            if let popover, popover.isShown { popover.close(); return }
            // A dropdown not on screen has nowhere to open its list.
            guard window != nil else { return }
            let list = ChoiceList(title: placeholder, selection: selection, choices: items.map { Choice(id: $0.0, title: $0.1) },
                                  choose: { [weak self] value in
                                      guard let self else { return }
                                      self.popover?.close()
                                      // Only a choice that is still offered.
                                      guard self.items.contains(where: { $0.0 == value }) else { return }
                                      if value != self.selection { self.selection = value; self.onSelect?(value) }
                                  }, cancel: { [weak self] in self?.popover?.close() })
            self.list = list
            let popover = PiKit.popover(list)
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            // The list is in the popover's window, which takes the keys.
            list.window?.makeFirstResponder(list)
        }
    }

    /// One choice in a `ChoiceList`.
    struct Choice<Tag: Hashable>: Equatable {
        let id: Tag
        let title: String
        var subtitle: String? = nil
        var enabled = true
    }

    /// A popover around an AppKit view, on the app's own surface.
    @MainActor static func popover(_ content: NSView) -> NSPopover {
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = content.fittingSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.reduced
        popover.contentViewController = controller
        return popover
    }

    /// The app's own selection list: a title, rows with a check by the
    /// chosen one, an optional note and action. Moving through it with the
    /// arrows never applies a choice before Return or a click; Escape closes.
    @MainActor final class ChoiceList<Tag: Hashable>: NSView {
        let title: String
        private(set) var selection: Tag?
        private(set) var choices: [Choice<Tag>]
        let note: String?
        let actionTitle: String?
        let action: (() -> Void)?
        let choose: (Tag) -> Void
        let cancel: () -> Void
        /// The row the keyboard is on.
        private(set) var highlighted: Tag?
        private var rows: [Row] = []
        private var empty: TextLine?
        private let divider = DividerView()

        /// SwiftUI's `Divider().overlay(Color.piHairline)`: the system
        /// separator with the hairline over it.
        @MainActor final class DividerView: NSView {
            override func draw(_ dirtyRect: NSRect) {
                NSColor.separatorColor.setFill(); bounds.fill()
                NSColor.piHairline.setFill(); bounds.fill(using: .sourceOver)
            }
        }

        /// The management action under the list: a full-width accent line of body text.
        @MainActor final class ActionRow: ButtonBase {
            init(_ title: String) { super.init(frame: .zero); self.title = title; pressScales = false; setAccessibilityLabel(title) }
            required init?(coder: NSCoder) { fatalError("Not used from a nib") }
            private var line: Line { Line(title, font: PiKit.Font.body, color: .piAccent) }
            override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: line.size(scale: piScale).height + 16) }
            override func shape(in rect: CGRect) -> CGPath { CGPath(rect: rect, transform: nil) }
            override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
            override func drawContent(in rect: CGRect) { line.draw(at: CGPoint(x: 8, y: 8), scale: piScale) }
        }
        private let scroll = NSScrollView()
        private let stack = FlippedView()
        /// Its whole width, padding included, as the SwiftUI list's frame.
        static var width: CGFloat { 310 }
        static var inner: CGFloat { width - 16 }

        final class FlippedView: NSView { override var isFlipped: Bool { true } }

        init(title: String, selection: Tag?, choices: [Choice<Tag>], note: String? = nil, actionTitle: String? = nil,
             action: (() -> Void)? = nil, choose: @escaping (Tag) -> Void, cancel: @escaping () -> Void) {
            self.title = title; self.selection = selection; self.choices = choices; self.note = note
            self.actionTitle = actionTitle; self.action = action; self.choose = choose; self.cancel = cancel
            super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
            wantsLayer = true
            setAccessibilityIdentifier("pi-choice-list")
            highlighted = Self.initialChoice(choices, selection: selection)
            build()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        /// Its size, set when its rows are laid out.
        override var intrinsicContentSize: NSSize { frame.size }

        /// A choice row.
        @MainActor final class Row: ButtonBase {
            let choice: Choice<Tag>
            let chosen: Bool
            var focused = false { didSet { refreshFace() } }
            init(_ choice: Choice<Tag>, chosen: Bool) {
                self.choice = choice; self.chosen = chosen
                super.init(frame: .zero)
                pressScales = false
                disabledOpacity = 1
                isEnabled = choice.enabled
                setAccessibilityLabel([choice.title, choice.subtitle].compactMap { $0 }.joined(separator: ", "))
            }
            required init?(coder: NSCoder) { fatalError("Not used from a nib") }
            override func isAccessibilitySelected() -> Bool { chosen }
            override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
            var ink: NSColor { choice.enabled ? .piInk : .piInkTertiary }
            func height(width: CGFloat) -> CGFloat {
                let textWidth = width - 16 - 24
                var height = PiKit.wrappedHeight(choice.title, font: PiKit.Font.body, width: textWidth)
                if let subtitle = choice.subtitle { height += 3 + PiKit.wrappedHeight(subtitle, font: PiKit.Font.caption, width: textWidth) }
                return height + 16
            }
            override func drawContent(in rect: CGRect) {
                if chosen {
                    // Centred on the whole text block, as the row's HStack centres it.
                    Symbol("checkmark", size: 11, weight: .semibold).draw(centredIn: CGRect(x: 8, y: 8, width: 14, height: rect.height - 16), color: .piAccent, scale: piScale)
                }
                let textWidth = rect.width - 16 - 24
                var y: CGFloat = 8
                y += PiKit.drawWrapped(choice.title, font: PiKit.Font.body, color: ink, in: CGRect(x: 32, y: y, width: textWidth, height: 10_000))
                if let subtitle = choice.subtitle {
                    _ = PiKit.drawWrapped(subtitle, font: PiKit.Font.caption, color: .piInkSecondary, in: CGRect(x: 32, y: y + 3, width: textWidth, height: 10_000))
                }
            }
            override func styleFace() {
                fill.backgroundColor = piCGColor(chosen ? .piAccentSoft : (focused || hovering || isPressedDown) ? .piSurfaceSunken : .clear)
                stroke.borderColor = focused ? piCGColor(NSColor.piAccent.withAlphaComponent(0.45)) : CGColor.clear
            }
            override var acceptsFirstResponder: Bool { false }
        }

        private func build() {
            let titleView = TextLine(Line(title, font: PiKit.Font.caption, color: .piInkSecondary))
            addSubview(titleView)
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.documentView = stack
            addSubview(scroll)
            rows = choices.map { choice in
                let row = Row(choice, chosen: choice.id == selection)
                row.onPress = { [weak self] in self?.commit(choice.id) }
                stack.addSubview(row)
                return row
            }
            if choices.isEmpty {
                empty = TextLine(Line("No available choices", font: PiKit.Font.body, color: .piInkTertiary))
                stack.addSubview(empty!)
            }
            if let note { addSubview(WrappedText(note, font: PiKit.Font.caption, color: .piInkSecondary)) }
            if let actionTitle, let action {
                addSubview(divider)
                let button = ActionRow(actionTitle)
                button.onPress = action
                addSubview(button)
            }
            layoutList()
            refreshHighlight()
        }
        /// Its height: the rows up to 360 points, as the SwiftUI list allows.
        private var listHeight: CGFloat {
            min(360, max(40, CGFloat(choices.count) * 40 + CGFloat(choices.filter { $0.subtitle != nil }.count) * 18))
        }
        private func layoutList() {
            let width = Self.inner
            var y: CGFloat = 8
            if let titleView = subviews.first as? TextLine {
                titleView.frame = CGRect(x: 16, y: y + 4, width: width - 16, height: titleView.intrinsicContentSize.height)
                y = titleView.frame.maxY + 8
            }
            var rowY: CGFloat = 0
            for row in rows {
                let height = row.height(width: width)
                row.frame = CGRect(x: 0, y: rowY, width: width, height: height)
                rowY += height + 2
            }
            if let empty { empty.frame = CGRect(x: 8, y: 8, width: width - 16, height: empty.intrinsicContentSize.height); rowY = empty.frame.maxY + 8 + 2 }
            stack.frame = CGRect(x: 0, y: 0, width: width, height: max(rowY - 2, 0))
            scroll.frame = CGRect(x: 8, y: y, width: width, height: listHeight)
            y = scroll.frame.maxY + 8
            for view in subviews where view is WrappedText {
                let height = (view as! WrappedText).height(forWidth: width - 16)
                view.frame = CGRect(x: 16, y: y, width: width - 16, height: height); y += height + 8
            }
            if divider.superview != nil {
                divider.frame = CGRect(x: 8, y: y, width: width, height: 1); y += 1 + 8
            }
            for view in subviews where view is ActionRow {
                view.frame = CGRect(x: 8, y: y, width: width, height: view.intrinsicContentSize.height); y += view.frame.height + 8
            }
            setFrameSize(NSSize(width: Self.width, height: y))
        }

        /// New choices or selection while it is open: its rows are rebuilt,
        /// and the keyboard's row stays where it was while that is offered.
        func update(selection: Tag?, choices: [Choice<Tag>]) {
            self.selection = selection; self.choices = choices
            // Rows are matched by choice: one that is unchanged keeps its
            // view (and its accessibility element); others are made anew.
            var old: [Tag: Row] = [:]
            for row in rows { old[row.choice.id] = row }
            rows = choices.map { choice in
                if let row = old.removeValue(forKey: choice.id) {
                    if row.choice == choice, row.chosen == (choice.id == selection) { return row }
                    row.removeFromSuperview()
                }
                let row = Row(choice, chosen: choice.id == selection)
                row.onPress = { [weak self] in self?.commit(choice.id) }
                stack.addSubview(row)
                return row
            }
            for row in old.values { row.removeFromSuperview() }
            // The empty message follows whether there is anything to choose.
            if choices.isEmpty, empty == nil {
                empty = TextLine(Line("No available choices", font: PiKit.Font.body, color: .piInkTertiary))
                stack.addSubview(empty!)
            } else if !choices.isEmpty, let shown = empty { shown.removeFromSuperview(); empty = nil }
            let before = highlighted
            if !choices.contains(where: { $0.id == highlighted && $0.enabled }) { highlighted = Self.initialChoice(choices, selection: selection) }
            layoutList(); refreshHighlight(scroll: highlighted != before); invalidateIntrinsicContentSize()
        }

        static func initialChoice(_ choices: [Choice<Tag>], selection: Tag?) -> Tag? {
            choices.first { $0.id == selection && $0.enabled }?.id ?? choices.first { $0.enabled }?.id
        }
        static func nextChoice(_ choices: [Choice<Tag>], after current: Tag?, delta: Int) -> Tag? {
            let enabled = choices.filter(\.enabled).map(\.id)
            guard !enabled.isEmpty else { return nil }
            guard let index = enabled.firstIndex(where: { $0 == current }) else { return delta < 0 ? enabled.last : enabled.first }
            return enabled[min(enabled.count - 1, max(0, index + delta))]
        }
        /// Outlines the keyboard's row; scrolls to it only when the keyboard
        /// moved, so an update does not undo the reader's own scrolling.
        private func refreshHighlight(scroll: Bool = true) {
            for row in rows { row.focused = row.choice.id == highlighted && hasKeys }
            if scroll, let row = rows.first(where: { $0.choice.id == highlighted }) { row.scrollToVisible(row.bounds) }
        }
        func commit(_ id: Tag) {
            guard choices.contains(where: { $0.id == id && $0.enabled }) else { return }
            choose(id)
        }
        /// It takes the keys as soon as it is shown, as the SwiftUI list
        /// focuses itself when it appears.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        }
        /// Whether it has the keys: the keyboard's row is outlined only then.
        private var hasKeys = false
        override func becomeFirstResponder() -> Bool { hasKeys = true; refreshHighlight(); return true }
        override func resignFirstResponder() -> Bool { hasKeys = false; refreshHighlight(); return true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: highlighted = Self.nextChoice(choices, after: highlighted, delta: -1); refreshHighlight()
            case 125: highlighted = Self.nextChoice(choices, after: highlighted, delta: 1); refreshHighlight()
            case 36, 76: if let highlighted { commit(highlighted) }
            case 53: cancel()
            default: super.keyDown(with: event)
            }
        }
        override func cancelOperation(_ sender: Any?) { cancel() }
        /// Moves the keyboard highlight, as an arrow key does. For tests.
        func move(_ delta: Int) { highlighted = Self.nextChoice(choices, after: highlighted, delta: delta); refreshHighlight() }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = piCGColor(.piSurface) }
    }

    /// Where `text` breaks into lines in `font` at `width`, as `Text` wraps it.
    static func wrappedRanges(_ text: String, font: NSFont, width: CGFloat) -> [NSRange] {
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var ranges: [NSRange] = [], start = 0
        while start < string.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            guard count > 0 else { break }
            ranges.append(NSRange(location: start, length: count))
            start += count
        }
        return ranges
    }
    /// The lines `text` breaks into in `font` at `width`, without their trailing spaces.
    static func wrappedLines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        let ns = text as NSString
        let lines = wrappedRanges(text, font: font, width: width).map { range -> String in
            var line = ns.substring(with: range)
            while line.hasSuffix(" ") || line.hasSuffix("\n") { line.removeLast() }
            return line
        }
        return lines.isEmpty ? [""] : lines
    }
    /// The height `text` wraps to in `font` at `width`: one text-system line
    /// height per line, as `Text` stacks its lines.
    static func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        CGFloat(wrappedLines(text, font: font, width: width).count) * Line(text, font: font, color: .black).lineHeight
    }
    /// Draws one line shrunk to fit `rect`'s width, down to `minimumScale`
    /// of its size and cut with "…" past that, as `.minimumScaleFactor`.
    static func drawScaled(_ line: Line, in rect: CGRect, minimumScale: CGFloat, scale: CGFloat = 2) {
        let width = line.width
        guard width > rect.width, width > 0 else { line.draw(at: rect.origin, scale: scale); return }
        let factor = max(minimumScale, rect.width / width)
        var smaller = line
        smaller.font = NSFont(descriptor: line.font.fontDescriptor, size: line.font.pointSize * factor) ?? line.font
        // Centred on the full-size line's middle, as a scaled `Text` sits.
        let y = rect.minY + (line.lineHeight - smaller.lineHeight) / 2
        smaller.draw(in: CGRect(x: rect.minX, y: PiKit.round(y, scale), width: rect.width, height: smaller.lineHeight), scale: scale)
    }
    /// Draws `text` wrapped in `rect` (flipped), up to `maximumLines` (the
    /// last cut with "…"); returns the height it took.
    @discardableResult static func drawWrapped(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, scale: CGFloat = 2, maximumLines: Int = .max) -> CGFloat {
        let lines = wrappedLines(text, font: font, width: rect.width)
        if lines.count > maximumLines {
            // The kept lines as they wrap; the last line is the rest of the
            // original text from there, its first paragraph cut with "…".
            var y = rect.minY
            for line in lines.prefix(maximumLines - 1) {
                let drawn = Line(line, font: font, color: color)
                drawn.draw(in: CGRect(x: rect.minX, y: y, width: rect.width, height: drawn.lineHeight), scale: scale); y += drawn.lineHeight
            }
            let start = wrappedRanges(text, font: font, width: rect.width)[maximumLines - 1].location
            let rest = (text as NSString).substring(from: start)
            let paragraph = rest.components(separatedBy: "\n").first ?? rest
            // Core Text cuts it, shaping and all; a paragraph that fits but has
            // more after it ends with the ellipsis itself.
            let last = Line(paragraph.count < rest.count ? paragraph + "…" : paragraph, font: font, color: color)
            last.draw(in: CGRect(x: rect.minX, y: y, width: rect.width, height: last.lineHeight), scale: scale)
            return y + last.lineHeight - rect.minY
        }
        var y = rect.minY
        for line in lines {
            let drawn = Line(line, font: font, color: color)
            drawn.draw(in: CGRect(x: rect.minX, y: y, width: rect.width, height: drawn.lineHeight), scale: scale)
            y += drawn.lineHeight
        }
        return y - rect.minY
    }

    /// Wrapping text the reader can select and copy (`.textSelection(.enabled)`),
    /// its lines spaced and its baseline placed as `Text` places them.
    @MainActor final class SelectableText: NSTextField, WidthSizing {
        let textFont: NSFont
        init(_ text: String, font: NSFont, color: NSColor) {
            textFont = font
            super.init(frame: .zero)
            isEditable = false; isSelectable = true; isBordered = false; isBezeled = false; drawsBackground = false
            lineBreakMode = .byWordWrapping; cell?.wraps = true; cell?.isScrollable = false
            maximumNumberOfLines = 0
            textColor = color; self.font = font
            set(text)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        /// Sets the text with SwiftUI's line height on every line.
        func set(_ text: String) {
            let lineHeight = Line(text, font: textFont, color: .black).lineHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
            paragraph.lineBreakMode = .byWordWrapping
            // The text system puts a line's baseline at its whole-point offset
            // from the line's top, as `Text` does.
            attributedStringValue = NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: textColor ?? .piInk, .paragraphStyle: paragraph])
            invalidateIntrinsicContentSize()
        }
        func height(forWidth width: CGFloat) -> CGFloat { PiKit.wrappedHeight(stringValue, font: textFont, width: width) }
    }

    /// Wrapping, selectable-free text as a view: `Text` that takes the lines it needs.
    @MainActor final class WrappedText: NSView, WidthSizing {
        var text: String { didSet { guard oldValue != text else { return }; needsDisplay = true; invalidateIntrinsicContentSize(); setAccessibilityLabel(text); PiKit.sizeChanged(self) } }
        var font: NSFont, color: NSColor
        init(_ text: String, font: NSFont, color: NSColor) {
            self.text = text; self.font = font; self.color = color
            super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        func height(forWidth width: CGFloat) -> CGFloat { PiKit.wrappedHeight(text, font: font, width: width) }
        override func draw(_ dirtyRect: NSRect) { PiKit.drawWrapped(text, font: font, color: color, in: bounds) }
    }

    // MARK: - Menus

    /// The pill menu button: a title (cut in the middle past
    /// `maxLabelWidth`) and a chevron; its menu is built when it opens
    /// (`PiMenus`), so a long list costs nothing until someone asks for it.
    @MainActor final class MenuButton: PillFaceButton {
        let entries: @MainActor () -> [PiMenuEntry]
        /// The title, kept as the accessibility name and tooltip when it changes.
        override var label: String {
            didSet { setAccessibilityLabel(label); if help.isEmpty { toolTip = label } }
        }
        private let help: String
        init(title: String, icon: String? = nil, identifier: String? = nil, help: String = "", maxLabelWidth: CGFloat? = nil,
             @PiMenuBuilder entries: @escaping @MainActor () -> [PiMenuEntry]) {
            self.entries = entries; self.help = help
            super.init(label: title, icon: icon, chevron: "chevron.down", compact: false, fontSize: 13, padding: (12, 7), hoverFill: true)
            self.maxLabelWidth = maxLabelWidth
            disabledOpacity = 0.35
            setAccessibilityRole(.menuButton)
            setAccessibilityLabel(title)
            if let identifier { setAccessibilityIdentifier(identifier) }
            toolTip = help.isEmpty ? title : help
            onPress = { [weak self] in guard let self else { return }; PiMenus.popUp(self.entries(), below: self) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var iconInk: NSColor { .piInk }
    }

    /// A control with a face of its own that opens a menu built on the
    /// press. The face is any view; the control tells it when the pointer is
    /// over it, and is the accessibility menu button.
    @MainActor final class MenuControl: ButtonBase {
        let faceView: NSView
        let entries: @MainActor () -> [PiMenuEntry]
        init(label: String, identifier: String? = nil, help: String = "", face: NSView,
             onHover: ((Bool) -> Void)? = nil, @PiMenuBuilder entries: @escaping @MainActor () -> [PiMenuEntry]) {
            faceView = face; self.entries = entries
            super.init(frame: .zero)
            pressScales = false
            disabledOpacity = 0.35
            addSubview(face)
            face.setAccessibilityElement(false)
            self.onHover = onHover
            setAccessibilityRole(.menuButton)
            setAccessibilityLabel(label)
            if let identifier { setAccessibilityIdentifier(identifier) }
            toolTip = help.isEmpty ? label : help
            onPress = { [weak self] in guard let self else { return }; PiMenus.popUp(self.entries(), below: self) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { faceView.fittingSize }
        override func layout() { super.layout(); faceView.frame = bounds }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear; faceView.alphaValue = CGFloat(isEnabled ? 1 : disabledOpacity) }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    }
}
