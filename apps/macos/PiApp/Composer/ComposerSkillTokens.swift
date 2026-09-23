import AppKit

// The composer's selected skills, drawn inline: the tokens lead the text, and
// the typed text begins after the last of them on the same line.
//
// The tokens are views laid over the text view's first lines, not characters
// in its text. The text view holds exactly the draft, as before — so the
// draft that is saved, the text that is sent, the input method's marked
// range, completion's caret arithmetic and Copy of the text are all what they
// were — and the room the tokens take is carved out of the text's first line
// by the text container. Rows of tokens above the one the text begins on
// move the text container down; the text's first line starts after the last
// token.

/// Where each token goes and where the text begins, in the text container's
/// coordinates before it is moved down (x from its left edge, y from the top
/// of the first row).
struct ComposerTokenLayout: Equatable {
    /// One frame per token, in order.
    var frames: [CGRect] = []
    /// How far the text's first line is moved down: the rows of tokens above it.
    var textOffset: CGFloat = 0
    /// The part of the text's first line the last row of tokens takes, or nil
    /// when the text begins on a line of its own.
    var exclusion: CGRect? = nil
    /// Where the last token ends, for the caret after it.
    var textStart: CGFloat = 0
    var rows: Int { frames.isEmpty ? 0 : Int(((frames.last?.minY ?? 0) / Self.rowHeight).rounded(.down)) + 1 }
    var isEmpty: Bool { frames.isEmpty }

    /// Every composer line is this tall, so a row of tokens is exactly a line.
    static let rowHeight: CGFloat = 20
    static let spacing: CGFloat = 4
    /// Between the last token and the first typed character.
    static let textGap: CGFloat = 6
    /// Less room than this after the last token and the text starts a line of its own.
    static let minimumTextWidth: CGFloat = 56

    /// Tokens flow like words: left to right, a token that does not fit
    /// starts the next row, and one wider than the line is cut to the line.
    static func place(widths: [CGFloat], containerWidth: CGFloat, padding: CGFloat,
                      tokenHeight: CGFloat = SkillPillFace.height) -> ComposerTokenLayout {
        guard !widths.isEmpty else { return ComposerTokenLayout() }
        let usable = max(1, containerWidth - padding * 2)
        let right = padding + usable
        var layout = ComposerTokenLayout(), x = padding, row = 0
        // Sat on the row's foot, a token is centred on the text's capitals
        // and its label shares the text's baseline.
        let inset = max(0, rowHeight - tokenHeight)
        for width in widths {
            let width = min(max(1, ceil(width)), usable)
            if x > padding, x + width > right { row += 1; x = padding }
            layout.frames.append(CGRect(x: x, y: CGFloat(row) * rowHeight + inset, width: width, height: tokenHeight))
            x += width + spacing
        }
        let end = x - spacing
        if right - (end + textGap) < minimumTextWidth {
            // No room left on the last row: the text starts below it.
            layout.textOffset = CGFloat(row + 1) * rowHeight
            layout.textStart = padding
        } else {
            layout.textOffset = CGFloat(row) * rowHeight
            layout.exclusion = CGRect(x: 0, y: 0, width: end + textGap - padding, height: rowHeight)
            layout.textStart = end + textGap
        }
        return layout
    }
}

/// The composer's side of its skill tokens: the tokens it shows, how it tells
/// its owner about presses, and the display whose selection they are.
@MainActor final class ComposerSkillStrip {
    var chips: [SkillChip] = []
    var tokens: [ComposerSkillToken] = []
    var layout = ComposerTokenLayout()
    /// The layout's exclusion as last given to the text container.
    var appliedExclusion: CGRect?
    weak var display: SessionDisplay?
    /// The draft changed through its skills (saved like any draft edit).
    var changed: (@MainActor () -> Void)?
    var pressed: ((SkillChip, ComposerSkillToken) -> Void)?
    var hovered: ((SkillChip, ComposerSkillToken, Bool) -> Void)?
    /// What a token's card and popover say, from the catalog the owner has.
    var describe: ((SkillChip) -> SkillDetail?)?
}

extension ComposerTextView {
    /// Room around the text. With 20-point lines the first line's baseline
    /// sits exactly where it did with the system's 17-point line and a
    /// 9-point inset.
    static let textInset = NSSize(width: 10, height: 7)
    /// Every line of the composer is one token row tall, its glyphs centred in
    /// it, so a line of text and a row of tokens are the same thing and the
    /// text after the last token sits on the tokens' line.
    static func applyLineMetrics(to editor: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ComposerTokenLayout.rowHeight
        style.maximumLineHeight = ComposerTokenLayout.rowHeight
        editor.defaultParagraphStyle = style
        var attributes = editor.typingAttributes
        attributes[.paragraphStyle] = style
        attributes[.baselineOffset] = 1
        editor.typingAttributes = attributes
    }

    /// The skills shown as tokens, in order. Setting the same list is free.
    var skillTokens: [SkillChip] {
        get { skillStrip.chips }
        set {
            guard newValue != skillStrip.chips else { return }
            skillStrip.chips = newValue
            rebuildSkillTokens()
        }
    }
    var skillTokenViews: [ComposerSkillToken] { skillStrip.tokens }
    var skillTokenLayout: ComposerTokenLayout { skillStrip.layout }

    private func rebuildSkillTokens() {
        var kept: [String: ComposerSkillToken] = [:]
        for token in skillStrip.tokens { kept[token.chip.id] = token }
        var next: [ComposerSkillToken] = []
        for chip in skillStrip.chips {
            let token = kept.removeValue(forKey: chip.id) ?? makeSkillToken(chip)
            token.apply(chip)
            next.append(token)
        }
        for stale in kept.values {
            if window?.firstResponder === stale { window?.makeFirstResponder(self) }
            stale.removeFromSuperview()
        }
        skillStrip.tokens = next
        for token in next where token.superview !== self { addSubview(token) }
        layoutSkillTokens()
    }
    private func makeSkillToken(_ chip: SkillChip) -> ComposerSkillToken {
        let token = ComposerSkillToken(chip: chip, sessionID: sessionID)
        token.onPress = { [weak self] button in
            guard let self, let token = button as? ComposerSkillToken else { return }
            self.skillStrip.pressed?(token.chip, token)
        }
        token.onHover = { [weak self] button, inside in
            guard let self, let token = button as? ComposerSkillToken else { return }
            self.skillStrip.hovered?(token.chip, token, inside)
        }
        token.onKey = { [weak self] button, key in
            guard let self, let token = button as? ComposerSkillToken else { return false }
            return self.tokenKey(key, on: token)
        }
        token.describe = { [weak self] chip in self?.skillStrip.describe?(chip) }
        token.menuItems = { [weak self, weak token] in
            guard let self, let token else { return [] }
            let remove = NSMenuItem(title: "Remove", action: #selector(ComposerTextView.removeSkillTokenFromMenu(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = token.chip.id
            return [remove]
        }
        return token
    }
    /// Places the tokens for the current width and carves their room out of
    /// the text's first line. Cheap and idempotent: a pass that changes
    /// nothing touches neither the tokens nor the text container.
    func layoutSkillTokens() {
        // The room is carved out of TextKit 1's line fragments, which the
        // composer uses anyway (it measures through its layout manager); asking
        // for the layout manager settles that before the container is shaped.
        guard layoutManager != nil, let container = textContainer else { return }
        // Before the editor has its width there is nothing to flow into: laid
        // out now, every token would take a row of its own for one pass and
        // the field would grow and shrink before it is first drawn.
        guard container.size.width >= ComposerTokenLayout.minimumTextWidth || skillStrip.tokens.isEmpty else { return }
        let layout = ComposerTokenLayout.place(widths: skillStrip.tokens.map(\.idealWidth), containerWidth: container.size.width,
                                               padding: container.lineFragmentPadding)
        let offsetChanged = layout.textOffset != skillStrip.layout.textOffset
        skillStrip.layout = layout
        // Where the first row begins: the container's origin before the text is moved down.
        let origin = NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y - layout.textOffset)
        for (token, frame) in zip(skillStrip.tokens, layout.frames) {
            let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
            if token.frame != placed { token.frame = placed }
        }
        let exclusionChanged = layout.exclusion != skillStrip.appliedExclusion
        if exclusionChanged {
            skillStrip.appliedExclusion = layout.exclusion
            container.exclusionPaths = layout.exclusion.map { [NSBezierPath(rect: $0)] } ?? []
        }
        if offsetChanged {
            invalidateTextContainerOrigin()
            // The frame must make room for the moved text now, not at the
            // next edit: nothing else asks the text view to resize.
            sizeToFit(); setFrameSize(frame.size)
            needsDisplay = true
        }
        // A token row that came or went changes how tall the field must be,
        // whether or not the text changed with it.
        if offsetChanged || exclusionChanged { reportContentHeight() }
    }
    /// How far the text container is moved down for the rows of tokens above
    /// the text's first line.
    var skillTextOffset: CGFloat { skillStrip.layout.textOffset }

    // MARK: Editing the selection

    /// Replaces the selected skills as one undoable step; the text is left
    /// exactly as it is.
    func applySkillChange(_ skills: [SkillChip], actionName: String) {
        guard let display = skillStrip.display, display.id == sessionID, display.skills != skills else { return }
        let previous = display.skills
        breakUndoCoalescing()
        display.skills = skills
        skillTokens = skills
        skillStrip.changed?()
        undoManager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.applySkillChange(previous, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }
    /// Backspace with the caret at the very start of the text.
    @discardableResult func removeLastSkillToken() -> Bool {
        guard !hasMarkedText(), selectedRange() == NSRange(location: 0, length: 0), let display = skillStrip.display,
              display.id == sessionID, !display.skills.isEmpty else { return false }
        applySkillChange(Array(display.skills.dropLast()), actionName: "Remove Skill")
        return true
    }
    func removeSkillToken(_ id: String) {
        guard let display = skillStrip.display, display.skills.contains(where: { $0.id == id }) else { return }
        let refocus = skillStrip.tokens.contains { $0.chip.id == id && window?.firstResponder === $0 }
        applySkillChange(display.skills.filter { $0.id != id }, actionName: "Remove Skill")
        if refocus { window?.makeFirstResponder(self) }
    }
    @objc func removeSkillTokenFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        removeSkillToken(id)
    }

    // MARK: Keyboard

    /// Left with the caret at the very start of the text moves focus onto the last token.
    @discardableResult func focusLastSkillToken() -> Bool {
        guard !hasMarkedText(), selectedRange() == NSRange(location: 0, length: 0), let last = skillStrip.tokens.last else { return false }
        return last.focusFromKeyboard()
    }
    private func tokenKey(_ key: SkillPillKey, on token: ComposerSkillToken) -> Bool {
        guard let index = skillStrip.tokens.firstIndex(where: { $0 === token }) else { return false }
        func returnToText() { window?.makeFirstResponder(self); setSelectedRange(NSRange(location: 0, length: 0)) }
        switch key {
        case .left:
            if index > 0 { skillStrip.tokens[index - 1].focusFromKeyboard() }
            return true
        case .right:
            if index + 1 < skillStrip.tokens.count { skillStrip.tokens[index + 1].focusFromKeyboard() } else { returnToText() }
            return true
        case .delete:
            let neighbour = index > 0 ? skillStrip.tokens[index - 1].chip.id : nil
            removeSkillToken(token.chip.id)
            if let neighbour, let previous = skillStrip.tokens.first(where: { $0.chip.id == neighbour }) { previous.focusFromKeyboard() }
            else { returnToText() }
            return true
        case .escape, .type:
            returnToText()
            return true
        }
    }
}
