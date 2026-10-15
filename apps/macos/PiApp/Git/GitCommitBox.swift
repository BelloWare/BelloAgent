import AppKit
import GitView

/// The commit message, what the commit takes (the checked files or the staged
/// index, always said, never inferred), amend, discard all, Reword Last
/// Commit and the commit itself.
@MainActor final class GitCommitBox: NSView, PiKit.WidthSizing {
    struct Inputs: Equatable {
        var message: String, amend: Bool, scope: GitCommitScope, checkedCount: Int, stagedCount: Int, entries: Int, hasHead: Bool, loading: Bool, busy: Bool
        var signOff: Bool, checking: Bool, preflight: GitCommitPreflight?, conflicts: Int
        var context: GitController.RepositoryContext?, rows: [GitStatusEntry]
        @MainActor init(_ controller: GitController) {
            message = controller.commitMessage; amend = controller.amend; scope = controller.commitScope; checkedCount = controller.checkedCount
            stagedCount = controller.staged.count; entries = controller.status.entries.count; hasHead = controller.status.head != nil
            loading = controller.loading; busy = controller.busy
            signOff = controller.signOff; checking = controller.preflightLoading; preflight = controller.preflight
            conflicts = controller.conflictCount
            context = controller.repositoryContext; rows = controller.status.entries
        }
    }

    /// What the box shows and allows for these inputs: the action's name,
    /// whether it and Reword are armed, and the line saying what the active
    /// scope takes. Kept apart from the drawing so it can be checked whole.
    struct Presentation: Equatable {
        var title: String, commitEnabled: Bool, rewordEnabled: Bool, hint: String
    }
    static func presentation(_ inputs: Inputs) -> Presentation {
        let message = inputs.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = inputs.scope == .checkedFiles ? inputs.checkedCount > 0 : inputs.stagedCount > 0
        let idle = !inputs.loading && !inputs.busy && !inputs.checking && inputs.conflicts == 0
        let title = switch (inputs.scope, inputs.amend) {
        case (.checkedFiles, false): "Commit Checked Files"
        case (.checkedFiles, true): "Amend with Checked Files"
        case (.stagedChanges, false): "Commit Staged Changes"
        case (.stagedChanges, true): "Amend with Staged Changes"
        }
        let hint: String
        switch inputs.scope {
        case .checkedFiles where !content:
            hint = "Tick the files to commit. Their whole working-tree state is committed, not only staged hunks."
        case .stagedChanges where !content:
            hint = "Nothing is staged. Stage files or hunks, or choose Checked files for whole working-tree content."
        case _ where inputs.amend && !inputs.hasHead:
            hint = "There is no commit to amend yet."
        default:
            let what = inputs.scope == .checkedFiles
                ? "\(inputs.checkedCount) of \(inputs.entries) \(inputs.entries == 1 ? "file" : "files") · their whole working-tree state"
                : "\(inputs.stagedCount) staged \(inputs.stagedCount == 1 ? "file" : "files") · exactly as staged; unstaged edits stay"
            hint = message.isEmpty ? what + " · write a message to commit" : what
        }
        return Presentation(title: title, commitEnabled: content && !message.isEmpty && idle && (!inputs.amend || inputs.hasHead),
                            rewordEnabled: inputs.hasHead && !message.isEmpty && idle, hint: hint)
    }

    private let controller: GitController
    private let discard: @MainActor ([GitStatusEntry]) -> Void
    private let operation: (@MainActor (GitController.RepositoryContext?, Bool) -> Void)?
    let message = GitMessageEditor()
    private let scopeTabs: PiKit.Tabs<GitCommitScope>
    private let amendTick = gitCheckbox(on: false, label: "Amend the last commit") {}
    private let amendLabel = PiKit.TextLine(PiKit.Line("Amend", font: PiKit.Font.caption, color: .piInkSecondary))
    private let signOffTick = gitCheckbox(on: false, label: "Sign off with the Git committer identity") {}
    private let signOffLabel = PiKit.TextLine(PiKit.Line("Sign off", font: PiKit.Font.caption, color: .piInkSecondary))
    private let check = PlainTextButton("Check", font: PiKit.Font.micro, color: .piAccent)
    private let preflight = TextBlock("Conflicts & whitespace", font: PiKit.Font.micro, color: .piInkSecondary, maximumLines: 2)
    private let reword = PlainTextButton("Reword Last Commit…", font: PiKit.Font.micro, color: .piAccent)
    private let discardAll = PlainTextButton("Discard All…", font: PiKit.Font.micro, color: .piDanger)
    private let hint = TextBlock("", font: PiKit.Font.micro, color: .piInkTertiary, maximumLines: 3)
    private let commit = PiKit.Button("", symbol: "checkmark.circle", style: .primary, compact: true)
    private var inputs: Inputs?

    init(controller: GitController, inputs: Inputs, discard: @escaping @MainActor ([GitStatusEntry]) -> Void,
         operation: (@MainActor (GitController.RepositoryContext?, Bool) -> Void)? = nil) {
        self.controller = controller; self.discard = discard; self.operation = operation
        scopeTabs = PiKit.Tabs(selection: inputs.scope, items: [(GitCommitScope.stagedChanges, "Staged changes"), (.checkedFiles, "Checked files")],
                               accessibilityName: "Commit scope") { [controller] in controller.commitScope = $0 }
        super.init(frame: .zero)
        // The SwiftUI tabs here had their animations switched off: the choice moves at once.
        scopeTabs.animatesSelection = false
        scopeTabs.setAccessibilityIdentifier("git-commit-scope")
        message.field.setAccessibilityIdentifier("git-commit-message")
        message.onChange = { [controller] in controller.commitMessage = $0 }
        amendTick.setAccessibilityIdentifier("git-amend")
        amendTick.setAccessibilityRole(.checkBox)
        amendTick.onPress = { [controller] in controller.amend.toggle() }
        signOffTick.setAccessibilityIdentifier("git-sign-off")
        signOffTick.setAccessibilityRole(.checkBox)
        signOffTick.onPress = { [controller] in controller.signOff.toggle() }
        signOffLabel.toolTip = "Add a Signed-off-by trailer using your Git committer identity."
        check.setAccessibilityIdentifier("git-preflight-check")
        preflight.setAccessibilityIdentifier("git-preflight-result")
        amendLabel.toolTip = "Add this commit's content to the last commit and replace its message."
        reword.toolTip = "Change the last commit's message only. Its files, and your staged and unstaged changes, stay as they are."
        reword.setAccessibilityIdentifier("git-reword")
        discardAll.setAccessibilityIdentifier("git-discard-all")
        hint.setAccessibilityIdentifier("git-commit-hint")
        commit.setAccessibilityIdentifier("git-commit")
        for view in [message, scopeTabs, amendTick, amendLabel, signOffTick, signOffLabel, reword, discardAll, hint, check, preflight, commit] as [NSView] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        // A keystroke changes the message and nothing else the box measures.
        let onlyMessage = inputs.map { previous in var same = next; same.message = previous.message; return same == previous } ?? false
        inputs = next
        RedrawCounter.note("GitCommitBox")
        reword.onPress = { [controller, operation] in guard controller.accepts(next.context) else { return }; operation?(next.context, true) }
        discardAll.onPress = { [controller, discard] in guard controller.accepts(next.context) else { return }; discard(next.rows) }
        commit.onPress = { [controller, operation] in guard controller.accepts(next.context) else { return }; operation?(next.context, false) }
        check.onPress = { [controller] in
            guard controller.accepts(next.context), let request = controller.commitRequest(context: next.context, forPreflight: true) else { return }
            Task { _ = await controller.checkCommit(request) }
        }
        check.isEnabled = !next.busy && !next.loading && !next.checking
        preflight.text = next.checking ? "Checking conflicts & whitespace…" : next.preflight?.summary ?? "Conflicts & whitespace"
        preflight.toolTip = next.preflight?.detail
        preflight.setAccessibilityHelp(next.preflight?.detail)
        preflight.color = next.preflight?.canCommit == false ? .piDanger : .piInkSecondary
        signOffTick.setTick(on: next.signOff, label: "Sign off with the Git committer identity")
        signOffTick.setAccessibilityValue(next.signOff ? 1 : 0)
        let shown = Self.presentation(next)
        message.placeholder = next.amend ? "Amended commit message" : "Commit message"
        message.text = next.message
        scopeTabs.selection = next.scope
        amendTick.setTick(on: next.amend, label: "Amend the last commit")
        amendTick.setAccessibilityValue(next.amend ? 1 : 0)
        reword.line.color = shown.rewordEnabled ? .piAccent : .piInkTertiary
        reword.isEnabled = shown.rewordEnabled
        discardAll.isHidden = next.entries == 0
        let sameHint = hint.text == shown.hint, sameTitle = commit.title == shown.title
        hint.text = shown.hint
        commit.title = shown.title
        commit.isEnabled = shown.commitEnabled
        if !(onlyMessage && sameHint && sameTitle) { measures = nil; placed = nil }
        needsLayout = true
        if bounds.width > 0, height(forWidth: bounds.width) != bounds.height { PiKit.sizeChanged(self) }
    }

    /// What the rows below the message take at one width and scale. Typing
    /// changes only the message, so a keystroke measures the message alone;
    /// measuring the tabs, the amend row, the hint and the button again for
    /// each one cost most of a keystroke. Dropped when anything else changes,
    /// or when a part reports a new size (`PiKit.sizeChanged` invalidates
    /// each container on its way up).
    private struct Measures { var width: CGFloat, scale: CGFloat, tabs: CGSize, choicesTogether: Bool, amendRow: CGFloat, actions: CGFloat, hint: CGFloat, preflight: CGFloat, commit: CGSize }
    private var measures: Measures?
    /// The size and row heights the parts were last placed for: a layout pass
    /// that would place them the same way leaves them be.
    private var placed: (size: CGSize, rows: [CGFloat])?
    override func invalidateIntrinsicContentSize() { measures = nil; placed = nil; super.invalidateIntrinsicContentSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); measures = nil; placed = nil }
    private func measured(_ width: CGFloat) -> Measures {
        let scale = piScale
        if let measures, measures.width == width, measures.scale == scale { return measures }
        RedrawCounter.note("GitCommitBox measured")
        let inner = width - PiSpacing.md * 2
        let next = Measures(width: width, scale: scale, tabs: scopeTabs.intrinsicContentSize,
                            choicesTogether: StackLayout.width(choiceRow(), spacing: PiSpacing.sm, proposal: .infinity) <= inner,
                            amendRow: StackLayout.height(amendRow(), spacing: PiSpacing.sm, width: inner),
                            actions: StackLayout.height(actionRow(), spacing: PiSpacing.sm, width: inner),
                            hint: hint.height(forWidth: inner), preflight: preflight.height(forWidth: max(1, inner - check.intrinsicContentSize.width - PiSpacing.sm)),
                            commit: commit.intrinsicContentSize)
        measures = next
        return next
    }

    private func amendRow() -> [StackLayout.Item] {
        [.fixed(amendTick), .line(amendLabel), .spacer(), .fixed(signOffTick), .line(signOffLabel)]
    }
    private func choiceRow() -> [StackLayout.Item] {
        [.fixed(scopeTabs), .spacer(), .fixed(amendTick), .line(amendLabel), .spacer(), .fixed(signOffTick), .line(signOffLabel)]
    }
    private func actionRow() -> [StackLayout.Item] {
        var items: [StackLayout.Item] = [.fixed(reword), .spacer()]
        if !discardAll.isHidden { items.append(.fixed(discardAll)) }
        return items
    }
    private func heights(_ width: CGFloat) -> [CGFloat] {
        let inner = width - PiSpacing.md * 2, rest = measured(width)
        return [message.height(forWidth: inner), rest.choicesTogether ? max(rest.tabs.height, rest.amendRow) : rest.tabs.height,
                rest.choicesTogether ? 0 : rest.amendRow, rest.actions, rest.hint, rest.preflight, rest.commit.height]
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        heights(width).reduce(0, +) + PiSpacing.sm * (measured(width).choicesTogether ? 5 : 6) + PiSpacing.md * 2
    }
    /// Its height with the message at its fewest lines.
    func minimumHeight(forWidth width: CGFloat) -> CGFloat {
        height(forWidth: width) - message.height(forWidth: width - PiSpacing.md * 2) + message.minimumHeight
    }
    override func layout() {
        super.layout()
        let inner = bounds.width - PiSpacing.md * 2, rows = heights(bounds.width), scale = piScale
        if let placed, placed.size == bounds.size, placed.rows == rows { return }
        placed = (bounds.size, rows)
        let rest = measured(bounds.width)
        var y = PiSpacing.md
        message.frame = CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[0]); y += rows[0] + PiSpacing.sm
        // In a full-width stacked panel, put the choices on one row when
        // their intrinsic widths fit. Narrow panes keep two complete rows.
        if rest.choicesTogether {
            StackLayout.place(choiceRow(), spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[1]), scale: scale)
            y += rows[1] + PiSpacing.sm
        } else {
            scopeTabs.frame = CGRect(x: PiSpacing.md, y: y, width: min(rest.tabs.width, inner), height: rows[1]); y += rows[1] + PiSpacing.sm
            StackLayout.place(amendRow(), spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[2]), scale: scale); y += rows[2] + PiSpacing.sm
        }
        StackLayout.place(actionRow(), spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[3]), scale: scale); y += rows[3] + PiSpacing.sm
        hint.frame = CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[4]); y += rows[4] + PiSpacing.sm
        let checkWidth = check.intrinsicContentSize.width
        preflight.frame = CGRect(x: PiSpacing.md, y: y, width: max(0, inner - checkWidth - PiSpacing.sm), height: rows[5])
        check.frame = CGRect(x: PiSpacing.md + inner - checkWidth, y: y, width: checkWidth, height: check.intrinsicContentSize.height)
        y += rows[5] + PiSpacing.sm
        let size = rest.commit, buttonWidth = min(inner, rest.commit.width)
        commit.frame = CGRect(x: PiSpacing.md + inner - buttonWidth, y: y, width: buttonWidth, height: size.height)
    }
}

/// The commit message: a plain field on an inset surface that wraps, two to
/// five lines tall, scrolling past five (`TextField(axis: .vertical)` with
/// `lineLimit(2...5)`, 8 points of padding).
@MainActor final class GitMessageEditor: NSView, PiKit.WidthSizing, NSTextFieldDelegate {
    let field = NSTextField()
    private let box = PiKit.inset(NSView())
    var onChange: ((String) -> Void)?
    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { if field.placeholderString != newValue { field.placeholderString = newValue } }
    }
    static let minimumLines = 2, maximumLines = 5
    override init(frame: NSRect) {
        super.init(frame: frame)
        PiKit.configurePlain(field, font: PiKit.Font.body, placeholder: "Commit message")
        field.usesSingleLineMode = false
        field.cell?.wraps = true; field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.delegate = self
        addSubview(box)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func controlTextDidChange(_ notification: Notification) {
        // The box measures its height again when the controller has the text.
        onChange?(field.stringValue)
    }
    private var lineHeight: CGFloat { PiKit.Line("", font: PiKit.Font.body, color: .black).lineHeight }
    /// The lines the text takes at this width, from two to five.
    func lines(forWidth width: CGFloat) -> Int {
        let inner = max(1, width - PiSpacing.sm * 2)
        let paragraphs = field.stringValue.components(separatedBy: "\n")
        let count = paragraphs.reduce(0) { $0 + PiKit.wrappedLines($1, font: PiKit.Font.body, width: inner).count }
        return min(Self.maximumLines, max(Self.minimumLines, count))
    }
    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(lines(forWidth: width)) * lineHeight + PiSpacing.sm * 2 }
    var minimumHeight: CGFloat { CGFloat(Self.minimumLines) * lineHeight + PiSpacing.sm * 2 }
    override func layout() {
        super.layout()
        box.frame = bounds
        field.frame = CGRect(x: PiSpacing.sm - PiKit.fieldInset, y: PiSpacing.sm, width: max(0, bounds.width - PiSpacing.sm * 2) + PiKit.fieldInset * 2,
                             height: max(0, bounds.height - PiSpacing.sm * 2))
    }
}
