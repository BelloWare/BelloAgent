import AppKit

// What a skill pill's hover card and popover show (`SkillPopovers`).

// MARK: - The card

/// The compact preview a resting pointer brings up: the name, what the skill
/// is for, where it comes from and the arguments it was given.
@MainActor final class SkillHoverCardView: NSView, PiKit.WidthSizing {
    private let stack: ShellStack

    init(detail: SkillDetail) {
        var items: [ShellItem] = []
        var header: [ShellItem] = [
            .view(PiKit.SymbolView(PiKit.Symbol("command", size: 10, weight: .bold), color: .piAccent)),
            .view(Self.line("/" + detail.name, font: .systemFont(ofSize: 13, weight: .semibold), color: .piInk, truncation: .middle), .flexible),
            .spacer(6),
        ]
        if let policy = detail.policyTitle {
            header.append(.view(Self.line(policy, font: PiKit.Font.micro, color: .piInkTertiary)))
        }
        items.append(.view(ShellStack(.horizontal, spacing: 5, alignment: .firstBaseline, header), .fill))
        if !detail.description.isEmpty {
            items.append(.view(ShellText(detail.description, font: .systemFont(ofSize: 12), color: .piInkSecondary, maximumLines: 3), .fill))
        }
        items.append(.view(Self.line(detail.place.sentence, font: PiKit.Font.caption, color: .piInkTertiary, truncation: .middle), .fill))
        if !detail.arguments.isEmpty {
            items.append(.view(ShellText(runs: [.init(text: "Arguments  ", color: .piInkTertiary), .init(text: detail.arguments, color: .piInk)],
                                         font: .systemFont(ofSize: 12), maximumLines: 2), .fill))
        }
        if let note = detail.revisionNote, note.warns {
            items.append(.view(ShellStack(.horizontal, spacing: 5, alignment: .top, [
                .view(PiKit.SymbolView(PiKit.Symbol("exclamationmark.circle", size: 10.5, weight: .medium), color: .piWarning),
                      insets: NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)),
                .view(ShellText(note.text, font: PiKit.Font.caption, color: .piWarning), .flexible),
            ]), .fill))
        }
        stack = ShellStack(.vertical, spacing: 5, padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), items)
        super.init(frame: .zero)
        addSubview(stack)
        setAccessibilityIdentifier("skill-hover-card")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    static func line(_ text: String, font: NSFont, color: NSColor, truncation: CTLineTruncationType = .end) -> PiKit.TextLine {
        let view = PiKit.TextLine(PiKit.Line(text, font: font, color: color))
        view.truncation = truncation
        return view
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
}

// MARK: - The popover

/// Everything about one pill's skill: what it is for, the arguments it was
/// given, its source file, where it comes from, its policy and version, and —
/// for a sent message — whether it has changed since. It reads the pill's
/// current values while it is open (a composer token's arguments may be
/// edited, the catalog may arrive) and updates its parts in place, so text
/// the reader is selecting stays where it is.
@MainActor final class SkillPopoverContentView: NSView, PiKit.WidthSizing {
    private let read: @MainActor () -> (detail: SkillDetail, actions: SkillPopoverActions)
    /// The most it may be: the popover's room on this screen.
    private let room: CGFloat
    private var actions = SkillPopoverActions(open: nil, reveal: nil)
    private var observer: ShellObserver?

    // Header
    private let name = SkillHoverCardView.line("", font: PiKit.Font.heading, color: .piInk, truncation: .middle)
    private let subtitle = SkillHoverCardView.line("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let header: ShellStack
    // Body
    private let noDescription = SkillHoverCardView.line("No description", font: PiKit.Font.body, color: .piInkTertiary)
    private let descriptionText = ShellSelectableText("", font: PiKit.Font.body, color: .piInk)
    private var note: ShellNote?
    private let noteSlot = ShellStack(.vertical, spacing: 0)
    private let noArguments = SkillHoverCardView.line("None", font: PiKit.Font.caption, color: .piInkTertiary)
    private let argumentsText = ShellSelectableText("", font: .systemFont(ofSize: 12.5), color: .piInk)
    private let argumentsBox: PiKit.Box
    private let file = ShellSelectableText("", font: PiKit.Font.mono, color: .piInk, singleLine: true, truncation: .byTruncatingMiddle)
    private let root = SkillHoverCardView.line("", font: PiKit.Font.caption, color: .piInkSecondary, truncation: .middle)
    private var openButton: PiKit.Button!
    private var revealButton: PiKit.Button!
    private let notFound = SkillHoverCardView.line("File not found", font: PiKit.Font.caption, color: .piInkTertiary)
    private let scope = ShellSelectableText("", font: PiKit.Font.caption, color: .piInk)
    private let policy = ShellSelectableText("", font: PiKit.Font.caption, color: .piInk)
    private var policyRow: ShellStack!
    private let version = ShellSelectableText("", font: PiKit.Font.mono, color: .piInk)
    private var body: ShellStack!
    // Footer
    private var editButton: PiKit.Button!
    private var removeButton: PiKit.Button!
    private var footer: ShellStack!

    private let scroll = NSScrollView()
    private let document = Document()
    private let topLine = CALayer(), bottomLine = CALayer()

    final class Document: NSView { override var isFlipped: Bool { true } }

    init(session: SessionDisplay?, room: CGFloat = SkillPopovers.popoverMaximumHeight,
         read: @escaping @MainActor () -> (detail: SkillDetail, actions: SkillPopoverActions)) {
        self.read = read; self.room = room
        header = ShellStack(.horizontal, spacing: 9, padding: NSEdgeInsets(top: 14, left: PiSpacing.lg, bottom: 12, right: PiSpacing.lg), [
            .view(PiKit.IconBadge(symbol: "command", size: 26)),
            .view(ShellStack(.vertical, spacing: 1, [.view(name, .flexible), .view(subtitle, .flexible)]), .flexible),
            .spacer(PiSpacing.sm),
        ])
        argumentsBox = PiKit.Box(fill: .piSurfaceSunken, stroke: .piHairline, cornerRadius: PiRadius.sm,
                                 padding: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10), content: argumentsText)
        super.init(frame: .zero)
        openButton = PiKit.Button("Open", style: .secondary, compact: true) { [weak self] in self?.actions.open?() }
        openButton.setAccessibilityIdentifier("skill-popover-open")
        revealButton = PiKit.Button("Reveal in Finder", style: .secondary, compact: true) { [weak self] in self?.actions.reveal?() }
        revealButton.setAccessibilityIdentifier("skill-popover-reveal")
        editButton = PiKit.Button("Edit Arguments…", style: .secondary, compact: true) { [weak self] in self?.actions.editArguments?() }
        editButton.setAccessibilityIdentifier("skill-popover-edit")
        removeButton = PiKit.Button("Remove", style: .ghostDanger) { [weak self] in self?.actions.remove?() }
        removeButton.setAccessibilityIdentifier("skill-popover-remove")

        func section(_ title: String, _ content: [ShellItem]) -> ShellStack {
            ShellStack(.vertical, spacing: 6, [.view(SkillHoverCardView.line(title, font: .systemFont(ofSize: 12, weight: .semibold), color: .piInkSecondary))] + content)
        }
        func fact(_ key: String, _ value: ShellSelectableText) -> ShellStack {
            ShellStack(.horizontal, spacing: PiSpacing.md, alignment: .firstBaseline, [
                .view(SkillHoverCardView.line(key, font: PiKit.Font.caption, color: .piInkSecondary), .fixed(58)),
                .view(value, .flexible),
                .spacer(0),
            ])
        }
        policyRow = fact("Policy", policy)
        let buttons = ShellStack(.horizontal, spacing: 6, [.view(openButton), .view(revealButton), .view(notFound)])
        body = ShellStack(.vertical, spacing: 14, padding: NSEdgeInsets(top: 14, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg), [
            .view(noDescription), .view(descriptionText, .fill),
            .view(noteSlot, .fill),
            .view(section("Arguments", [.view(noArguments), .view(argumentsBox, .fill)]), .fill),
            .view(section("Source", [.view(ShellStack(.vertical, spacing: 4, [
                .view(file, .fill), .view(root, .fill), .view(buttons, insets: NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)),
            ]), .fill)]), .fill),
            .view(ShellStack(.vertical, spacing: 6, [.view(fact("Scope", scope), .fill), .view(policyRow, .fill), .view(fact("Version", version), .fill)]), .fill),
        ])
        footer = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 10, left: PiSpacing.md, bottom: 10, right: PiSpacing.md),
                            [.view(editButton), .spacer(0), .view(removeButton)])

        wantsLayer = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        document.addSubview(body)
        for view in [header, scroll, footer] as [NSView] { addSubview(view) }
        layer?.addSublayer(topLine); layer?.addSublayer(bottomLine)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("skill-popover")
        update()
        if let session {
            let observer = ShellObserver { [weak self] in self?.update() }
            observer.observe(session)
            self.observer = observer
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private static func versionText(_ detail: SkillDetail) -> String {
        if case .changed(let now) = detail.revision {
            return detail.context == .sent ? "\(detail.version) · now \(now)" : "\(detail.version) · installed \(now)"
        }
        return detail.version.isEmpty ? "Unknown" : detail.version
    }

    /// What the popover shows: it changes views only when this does.
    private struct Shown: Equatable {
        var detail: SkillDetail
        var open: Bool, reveal: Bool, edit: Bool, remove: Bool
    }
    private var shown: Shown?

    /// Shows the pill's current values, changing only what differs. The
    /// actions are taken every time; the views only when something they
    /// show is different.
    private func update() {
        let (detail, actions) = read()
        self.actions = actions
        let now = Shown(detail: detail, open: actions.open != nil, reveal: actions.reveal != nil,
                        edit: actions.editArguments != nil, remove: actions.remove != nil)
        guard now != shown else { return }
        shown = now
        name.line.text = "/" + detail.name
        subtitle.line.text = detail.context == .composer ? "Selected for the message you are writing" : "Sent with this message"
        noDescription.isHidden = !detail.description.isEmpty
        descriptionText.isHidden = detail.description.isEmpty
        descriptionText.text = detail.description
        if let revision = detail.revisionNote {
            let tone: PiTone = revision.warns ? .warning : .neutral
            if note?.tone != tone {
                note?.removeFromSuperview()
                let view = ShellNote(revision.text, tone: tone)
                view.setAccessibilityElement(true); view.setAccessibilityRole(.staticText)
                view.setAccessibilityIdentifier("skill-popover-revision")
                note = view
                noteSlot.items = [.view(view, .fill)]
            }
            note?.text = revision.text
            note?.setAccessibilityLabel(revision.text)
            noteSlot.isHidden = false
        } else {
            noteSlot.isHidden = true
        }
        noArguments.isHidden = !detail.arguments.isEmpty
        argumentsBox.isHidden = detail.arguments.isEmpty
        argumentsText.text = detail.arguments
        file.text = detail.place.file(detail.path); file.toolTip = detail.path
        root.isHidden = detail.place.root.isEmpty
        root.line.text = "in " + (detail.place.root as NSString).abbreviatingWithTildeInPath; root.toolTip = detail.place.root
        openButton.isEnabled = actions.open != nil
        revealButton.isEnabled = actions.reveal != nil
        notFound.isHidden = actions.open != nil
        scope.text = detail.place.title
        policyRow.isHidden = detail.policyTitle == nil
        policy.text = (detail.policyTitle ?? "") + (detail.policyDetail.map { " · " + $0 } ?? "")
        version.text = Self.versionText(detail)
        editButton.isHidden = actions.editArguments == nil
        removeButton.isHidden = actions.remove == nil
        footer.isHidden = !actions.editable
        bottomLine.isHidden = !actions.editable
        // Whatever was shown or hidden, every stack measures again.
        for stack in [header, body, footer] as [ShellStack] { stack.relayoutAll() }
        needsLayout = true; invalidateIntrinsicContentSize()
        PiKit.sizeChanged(self)
    }

    // MARK: Size

    private func parts(width: CGFloat) -> (header: CGFloat, body: CGFloat, footer: CGFloat) {
        (PiKit.height(of: header, width: width), PiKit.height(of: body, width: width),
         footer.isHidden ? 0 : PiKit.height(of: footer, width: width) + 1)
    }
    /// As tall as it all is, up to the popover's room; the middle scrolls past that.
    func height(forWidth width: CGFloat) -> CGFloat {
        let parts = parts(width: width)
        return min(room, parts.header + 1 + parts.body + parts.footer)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = bounds.width
        let parts = parts(width: width)
        header.frame = CGRect(x: 0, y: 0, width: width, height: parts.header)
        let scrollHeight = max(0, bounds.height - parts.header - 1 - parts.footer)
        scroll.frame = CGRect(x: 0, y: parts.header + 1, width: width, height: scrollHeight)
        document.frame = CGRect(x: 0, y: 0, width: width, height: parts.body)
        body.frame = document.bounds
        if !footer.isHidden { footer.frame = CGRect(x: 0, y: bounds.height - parts.footer + 1, width: width, height: parts.footer - 1) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        topLine.frame = CGRect(x: 0, y: parts.header, width: width, height: 1)
        bottomLine.frame = CGRect(x: 0, y: bounds.height - parts.footer, width: width, height: 1)
        topLine.backgroundColor = piCGColor(.piHairline); bottomLine.backgroundColor = piCGColor(.piHairline)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    // MARK: Keys

    /// It takes the keys when it opens, so Escape closes the popover, as
    /// the SwiftUI content's own focus did.
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }
    override func cancelOperation(_ sender: Any?) { SkillPopovers.shared.close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { cancelOperation(nil); return }
        super.keyDown(with: event)
    }
}
