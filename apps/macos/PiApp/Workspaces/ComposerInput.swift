import AppKit

// The composer: the native editor, the chips above it, the slash-command
// list over it, and the bar of controls under it whose form is measured
// rather than laid out.

/// One chat's composer card, kept by its pane across chats: `show` hands it
/// another chat, and the editor inside is made for each chat (its undo and
/// its marked text are that chat's). It watches the workspace, the chat, its
/// draft and the model catalog, and changes only what they change.
@MainActor final class ComposerInputView: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    private(set) var session: SessionDisplay?
    /// The pane this bar sits in, for `ComposerBarMetrics`.
    var paneWidth: CGFloat = .infinity { didSet { if oldValue != paneWidth { refresh() } } }
    /// The field's ceiling: lower while a terminal is open below the chat.
    var maximumFieldHeight: CGFloat = ComposerScrollView.maximumHeight { didSet { if oldValue != maximumFieldHeight { refresh() } } }
    /// Called when the card's height changed, for the pane to lay out again.
    var heightChanged: (() -> Void)?
    /// The disabled state handed down from the window (`.disabled` on the
    /// SwiftUI root while the app prepares to close).
    var inheritedEnabled = true {
        didSet { guard oldValue != inheritedEnabled else { return }; pills.inheritedEnabled = inheritedEnabled; shown = nil; refresh() }
    }

    private let card: PiKit.Box
    private let cardContent = Content()
    private let loadingLine = PiKit.TextLine(PiKit.Line("Loading the complete original input…", font: PiKit.Font.caption, color: .labelColor))
    private var editingBanner: ComposerEditBanner?
    private var queueBanner: ComposerEditBanner?
    private let chips = PiKit.FlowView()
    private var chipIDs: [String] = []
    private(set) var field: ComposerScrollView?
    private let placeholder = PiKit.TextLine(PiKit.Line("", font: .systemFont(ofSize: 14), color: .piInkTertiary))
    private let bar: ShellStack
    private let attach: PiKit.IconButton
    private let skills: PiKit.IconButton
    private let steer: PiKit.Button
    private let hintLine = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let runControls: ShellStack
    private let changes: PiKit.IconButton
    private let usage: PiKit.IconButton
    private var actions: ConversationActionsMenuView?
    private let actionsSlot = ShellStack(.horizontal, spacing: 0)
    private let pills: ModelSwitchPillsView
    let send: ComposerRoundButton
    let stop: ComposerRoundButton
    private let completions: SlashCompletionListView
    private var observer: ShellObserver?
    private var shown: State?
    /// The draft last seen, for telling the model about edits (not switches).
    private var lastDraft: (session: String, text: String)?

    final class Content: NSView { override var isFlipped: Bool { true } }

    /// Everything the card shows, read once per change.
    private struct State: Equatable {
        var sessionID: String
        var editing: Bool
        var editPreparing: Bool
        var editBlocker: String?
        var editNotice: String
        var editSubmitting: Bool
        var editReview: Bool
        var queueEditing: Bool
        var queueSteering: Bool
        var queueResolving: Bool
        var attachments: [AttachmentRecord]
        var placeholder: String?
        var canSend: Bool
        var queues: Bool
        var busy: Bool
        var loading: Bool
        var draftReady: Bool
        var form: ComposerBarForm
        var hint: String?
        var showsChanges: Bool
        var showsActions: Bool
        var supportsImages: Bool
        var disabled: Bool
        var completionVisible: Bool
        var accessibilityLabel: String
    }

    init(model: WorkspaceModel) {
        self.model = model
        card = PiKit.elevated(cardContent, radius: 16)
        attach = PiKit.IconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true)
        skills = PiKit.IconButton(symbol: "command", label: "Skills…", size: 28, filled: true)
        steer = PiKit.Button("Steer run", symbol: "arrow.turn.up.right", style: .ghost)
        steer.toolTip = "⌘↩ Steer run · deliver this message to the current run after its tool batch"
        steer.setAccessibilityLabel("Steer run")
        runControls = ShellStack(.horizontal, spacing: ComposerBarMetrics.spacing, [.view(steer), .view(hintLine)])
        changes = PiKit.IconButton(symbol: "arrow.triangle.branch", label: "Changes and history of this project", size: 28, filled: true)
        changes.setAccessibilityIdentifier("sessionChangesButton")
        // The Session Inspector's icon, as the Dashboard's usage button draws it.
        usage = PiKit.IconButton(symbol: "chart.pie", label: "Session Inspector: cost, tokens, time and every request", size: 28)
        usage.toolTip = "Open the Session Inspector: what this chat cost and used, how fast it ran, and every request it made"
        usage.setAccessibilityIdentifier("sessionUsageButton")
        pills = ModelSwitchPillsView(model: model)
        send = ComposerRoundButton(symbol: "arrow.up", symbolSize: 13, fill: .piFillStrong, ink: .piInkTertiary) {}
        stop = ComposerRoundButton(symbol: "stop.fill", symbolSize: 12, fill: .piDanger, ink: .piOnAccent) {}
        stop.toolTip = "Stop response"; stop.setAccessibilityLabel("Stop response"); stop.setAccessibilityIdentifier("composerStopResponse")
        bar = ShellStack(.horizontal, spacing: ComposerBarMetrics.spacing, padding: NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10), [
            .view(attach), .view(skills), .spacer(0), .view(runControls), .view(changes), .view(usage), .view(actionsSlot),
            .view(pills, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: ComposerBarMetrics.pillsTrailing)),
            .view(send), .view(stop),
        ])
        completions = SlashCompletionListView()
        super.init(frame: .zero)
        card.content = cardContent
        addSubview(card)
        for view in [loadingLine, chips, placeholder, bar] as [NSView] { cardContent.addSubview(view) }
        chips.spacing = 6; chips.rowSpacing = 6
        placeholder.setAccessibilityElement(false)
        completions.isHidden = true
        addSubview(completions)
        wire()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private func wire() {
        attach.onPress = { [weak self] in guard let self, let session = self.session else { return }; self.model.attachImages(sessionID: session.id) }
        skills.onPress = { [weak self] in guard let self, let session = self.session else { return }; self.model.inspectResources(session.id) }
        steer.onPress = { [weak self] in self?.submit(.steer) }
        changes.onPress = { [weak self] in
            guard let self, let session = self.session, let chat = self.model.record(session.id) else { return }
            self.model.showChanges(in: chat.workspaceID)
        }
        usage.onPress = { [weak self] in
            guard let self, let session = self.session else { return }
            self.model.openInspector(session: session.id, focus: .overview)
        }
        send.onPress = { [weak self] in self?.submit(.followUp) }
        stop.onPress = { [weak self] in guard let self, let session = self.session else { return }; self.model.stop(sessionID: session.id) }
        completions.onRetry = { [weak self] in
            guard let self, let session = self.session else { return }
            let model = self.model, id = session.id
            Task { await model.loadSkillCatalog(refresh: true, sessionID: id) }
        }
        completions.onAllSkills = { [weak self] in guard let self, let session = self.session else { return }; self.model.inspectResources(session.id) }
        completions.choose = { [weak self] choice in
            guard let self, let session = self.session else { return }
            self.model.chooseCompletion(choice, view: session)
        }
    }

    // MARK: The chat shown

    /// Lets go of the chat and its editor while the pane shows a read-only
    /// footer in the composer's place; the next `show` makes them again.
    func retire() {
        observer = nil
        field?.removeFromSuperview(); field = nil
        session = nil; shown = nil; lastDraft = nil
        pills.retire()
        completions.isHidden = true
    }

    /// Shows `session`'s composer: a new editor for it, its draft and its bar.
    func show(_ session: SessionDisplay) {
        guard session !== self.session else { refresh(); return }
        self.session = session
        pills.show(session)
        let observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model); observer.observe(session); observer.observe(session.composerDraft); observer.observe(model.modelCatalog)
        self.observer = observer
        // The editor is the chat's own: its undo, its marked text.
        field?.removeFromSuperview()
        let field = composer(for: session).makeView()
        field.heightChanged = { [weak self] in self?.contentHeightChanged() }
        cardContent.addSubview(field, positioned: .below, relativeTo: placeholder)
        self.field = field
        // Another chat's draft arriving is not typing.
        lastDraft = (session.id, session.draft)
        shown = nil
        refresh()
    }

    /// The native field's value for `session` as things stand.
    private func composer(for session: SessionDisplay) -> NativeComposer {
        let model = self.model
        return NativeComposer(text: session.composerDraft.text, textChanged: { [weak session] in session?.composerDraft.text = $0 },
                              send: { [weak self] in self?.submit($0) }, sessionID: session.id, completion: { _ in },
                              locationChanged: { [weak session] location, editor in
                                  guard let session else { return }
                                  model.composerMoved(location, editor: editor, view: session)
                              },
                              directSlash: { [weak session] in if session?.directCommand == false { session?.directCommand = true } },
                              pasted: { [weak session] in session?.directCommand = false; session?.completionVisible = false },
                              completionKey: { [weak session] key, modifiers in
                                  guard let session else { return false }
                                  return model.completionKey(key, modifiers: modifiers, view: session)
                              },
                              focused: { [id = session.id] in model.focusPane(id); model.prewarm(id) },
                              accessibilityLabel: model.side(session.id) == nil ? "Main message composer" : "Side message composer",
                              inputRejected: { [weak session] in session?.notice = $0 },
                              attachFiles: { [id = session.id] in model.attachImageFiles($0, sessionID: id) },
                              focusToken: session.composerFocusRequest, settledFocusToken: session.composerFocusSettled,
                              skills: session.skills, skillDisplay: session,
                              skillsChanged: { [weak session] in if let session { model.draftChanged(session) } },
                              skillPressed: { [weak session] chip, token in
                                  guard let session else { return }
                                  SkillPopovers.shared.pressComposer(chip: chip, anchor: token, editor: token.superview as? ComposerTextView,
                                                                     model: model, session: session)
                              },
                              skillHovered: { [weak session] chip, token, inside in
                                  guard let session else { return }
                                  SkillPopovers.shared.hoverComposer(inside, chip: chip, anchor: token, session: session)
                              },
                              describeSkill: { [weak session] chip in .composer(chip, catalog: session?.skillCatalog ?? SkillCatalog()) },
                              maximumFieldHeight: maximumFieldHeight, editable: !session.queueEditResolving)
    }

    private func submit(_ intent: ComposerSubmissionIntent) {
        guard let session, model.page == .chats else { return }
        // A short press-in and spring-back confirms the send under the pointer.
        send.pulse()
        model.submitComposer(intent: intent, sessionID: session.id)
    }

    // MARK: Reading the chat

    private func read(_ session: SessionDisplay) -> State {
        let editing = session.editingMessageID != nil
        let queueEditing = session.queueEditingID != nil
        let draft = session.composerDraft.text
        let hasInput = draft.contains { !$0.isWhitespace } || !session.skills.isEmpty || !session.attachments.isEmpty || (queueEditing && session.queueEditKeepsInput)
        let blocker = editing ? model.editBlocker(session) : nil
        let canSend = session.draftReady && !(!hasInput || session.loading || model.installPreparing || (editing && blocker != nil) || session.queueEditResolving)
        let queues = !editing && !queueEditing && (session.busy || !session.queue.isEmpty || !session.sendingRows.isEmpty)
        let hint: String? = queueEditing ? "↩ Save" : queues ? (session.busy ? "↩ Queue · ⌘↩ Steer" : "↩ Queue")
            : editing ? (session.busy || !session.queue.isEmpty ? "Wait for idle to resend" : "Resend from here") : nil
        let chat = model.record(session.id)
        let isSide = model.side(session.id) != nil
        let showsChanges = chat.map { !isSide && model.workspace(for: $0.workspaceID) != nil && $0.workspaceID != WorkspaceRecord.scratchID } ?? false
        let pillContents = ModelSwitchPills.contents(model: model, session: session)
        let metrics = ComposerBarMetrics(showsSteer: session.busy && !editing && !queueEditing, hint: hint, showsChanges: showsChanges,
                                         showsActions: chat != nil && !isSide, showsStop: session.busy,
                                         showsConnectionPill: pillContents.showsConnection, connection: pillContents.connection,
                                         model: pillContents.model, effort: pillContents.effort, modelLoading: pillContents.loading)
        let form = metrics.form(fitting: ComposerBarMetrics.available(paneWidth: paneWidth))
        let queued = session.queueEditingID.flatMap { id in QueuedMessage.from(session.queue).first { $0.id == id } }
        return State(sessionID: session.id, editing: editing, editPreparing: session.editPreparing, editBlocker: blocker,
                     editNotice: session.editNotice, editSubmitting: session.editSubmitting, editReview: session.editInputReviewRequired,
                     queueEditing: queueEditing, queueSteering: queued?.steering ?? false, queueResolving: session.queueEditResolving,
                     attachments: session.attachments,
                     placeholder: draft.isEmpty && session.skills.isEmpty
                        ? "Message… " + ComposerSubmissionIntent.hint(queues: queues, steers: session.busy, onBar: queues && !editing && form.runControls.showsHint)
                        : nil,
                     canSend: canSend, queues: queues, busy: session.busy, loading: session.loading, draftReady: session.draftReady,
                     form: form, hint: hint, showsChanges: showsChanges, showsActions: chat != nil && !isSide,
                     supportsImages: model.supportsImages(session.id), disabled: editing && session.loading || !inheritedEnabled,
                     completionVisible: session.completionVisible,
                     accessibilityLabel: isSide ? "Side message composer" : "Main message composer")
    }

    /// Reads the chat and changes only what differs.
    func refresh() {
        guard let session else { return }
        // The draft's edits are saved; a switch to another chat's draft is not an edit.
        let text = session.composerDraft.text
        if let last = lastDraft, last.session == session.id, last.text != text { model.draftChanged(session) }
        lastDraft = (session.id, text)
        if let field { composer(for: session).apply(to: field) }
        if session.completionVisible { updateCompletions(session) }
        let now = read(session)
        guard now != shown else { return }
        let before = shown
        shown = now
        apply(now, before: before, session: session)
    }

    private func apply(_ state: State, before: State?, session: SessionDisplay) {
        // Banners above the field.
        loadingLine.isHidden = !(state.editPreparing && !state.editing)
        if state.editing {
            let banner = editingBanner ?? {
                let banner = ComposerEditBanner(title: "Editing an earlier message", accessibilityName: "Editing an earlier message",
                                                cancel: { [weak self] in guard let self, let session = self.session else { return }; self.model.cancelEdit(sessionID: session.id) },
                                                review: { [weak self] in self?.session?.editInputReviewRequired = false })
                cardContent.addSubview(banner); editingBanner = banner
                return banner
            }()
            banner.update(detail: state.editBlocker ?? state.editNotice, detailColor: state.editBlocker == nil ? .piInkSecondary : .piDanger,
                          cancelEnabled: !state.editSubmitting && !state.disabled, offersReview: state.editReview, reviewEnabled: !state.disabled)
        } else { editingBanner?.removeFromSuperview(); editingBanner = nil }
        if state.queueEditing {
            let banner = queueBanner ?? {
                let banner = ComposerEditBanner(title: "", accessibilityName: "Editing a queued message",
                                                cancel: { [weak self] in guard let self, let session = self.session else { return }; self.model.cancelQueuedEdit(sessionID: session.id) })
                cardContent.addSubview(banner); queueBanner = banner
                return banner
            }()
            banner.update(title: state.queueSteering ? "Editing a steering message" : "Editing a queued message",
                          detail: "This message and the others waiting are paused while you edit. Return saves it in its place in the queue.",
                          maximumLines: 3, waiting: state.queueResolving, cancelEnabled: !state.queueResolving && !state.disabled)
        } else { queueBanner?.removeFromSuperview(); queueBanner = nil }
        // Attached images.
        if state.attachments.map(\.id) != chipIDs || before?.disabled != state.disabled {
            chipIDs = state.attachments.map(\.id)
            chips.subviews.forEach { $0.removeFromSuperview() }
            for attachment in state.attachments {
                let chip = PiKit.Chip(text: URL(fileURLWithPath: attachment.path).lastPathComponent, icon: "photo", help: attachment.path,
                                      action: { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) },
                                      remove: { [weak self] in
                                          guard let self, let session = self.session else { return }
                                          session.attachments.removeAll { $0.id == attachment.id }
                                          self.model.draftChanged(session)
                                      })
                chips.addSubview(chip)
            }
        }
        chips.isHidden = state.attachments.isEmpty
        for control in PiKit.controls(in: chips) { control.isEnabled = !state.disabled }
        // The keyboard hints are the empty composer's placeholder; they leave once typing starts.
        placeholder.isHidden = state.placeholder == nil
        if let text = state.placeholder { placeholder.line.text = text }
        // The bar.
        attach.isEnabled = state.draftReady && !state.queueEditing && state.supportsImages && !state.disabled
        skills.isEnabled = !state.queueEditing && !state.disabled
        steer.isHidden = !(state.busy && !state.editing && !state.queueEditing)
        steer.title = state.form.runControls.steerIsCompact ? "" : "Steer run"
        steer.isEnabled = !state.loading && !state.disabled
        hintLine.isHidden = !(state.form.runControls.showsHint && state.hint != nil)
        hintLine.line.text = state.hint ?? ""
        runControls.isHidden = steer.isHidden && hintLine.isHidden
        runControls.relayoutAll()
        changes.isHidden = !state.showsChanges
        changes.isEnabled = !state.disabled
        usage.isEnabled = !state.disabled
        if state.showsActions, actions == nil, model.record(session.id) != nil {
            let menu = ConversationActionsMenuView(model: model, sessionID: session.id)
            menu.session = session
            actions = menu
            actionsSlot.items = [.view(menu)]
        } else if !state.showsActions, actions != nil {
            actions = nil; actionsSlot.items = []
        } else if let actions, actions.sessionID != session.id {
            actions.sessionID = session.id; actions.session = session
        }
        actionsSlot.isHidden = actions == nil
        actions?.isEnabled = !state.disabled
        pills.form = state.form.pills
        let symbol = state.queueEditing ? "checkmark" : state.queues ? "text.badge.plus" : state.editing ? "arrow.uturn.up" : "arrow.up"
        let name = state.queueEditing ? "Save Queued Message" : state.editing ? "Resend Edited Message" : state.queues ? "Queue Follow-up" : "Send"
        if send.symbol != symbol { send.symbol = symbol }
        send.setAccessibilityLabel(name)
        send.toolTip = state.queueEditing ? "Save Queued Message" : state.editing ? (state.editBlocker ?? "Resend Edited Message") : name
        if before?.canSend != state.canSend || before == nil {
            PiKit.Motion.layers(PiKit.Motion.quick, animated: before != nil) {
                send.fillColor = state.canSend ? .piBrandOrange : .piFillStrong
                send.ink = state.canSend ? .piOnAccent : .piInkTertiary
                send.glows = state.canSend
            }
        }
        send.isEnabled = state.canSend && !state.disabled
        let stopping = state.busy
        if stop.isHidden == stopping {
            stop.isHidden = !stopping
            if stopping, before != nil { PiKit.appearScaled(stop) }
        }
        stop.isEnabled = !state.disabled
        bar.relayoutAll()
        // The slash-command list.
        completions.isHidden = !state.completionVisible
        if state.completionVisible { updateCompletions(session) }
        contentHeightChanged()
    }

    private func updateCompletions(_ session: SessionDisplay) {
        let enabled = !(shown?.disabled ?? false)
        if completions.update(choices: model.completions(session), selection: session.completionSelectionID, catalog: session.skillCatalog, enabled: enabled) {
            needsLayout = true
        }
    }

    private func contentHeightChanged() {
        invalidateIntrinsicContentSize(); needsLayout = true
        heightChanged?()
    }

    // MARK: Layout

    private static let outer = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.lg, bottom: 6, right: PiSpacing.lg)
    private func cardParts(width: CGFloat) -> [(NSView, CGFloat, CGFloat)] {
        // (view, height, left/right inset)
        var parts: [(NSView, CGFloat, CGFloat)] = []
        if !loadingLine.isHidden { parts.append((loadingLine, loadingLine.intrinsicContentSize.height + 16, 8)) }
        if let editingBanner { parts.append((editingBanner, editingBanner.height(forWidth: width), 0)) }
        if let queueBanner { parts.append((queueBanner, queueBanner.height(forWidth: width), 0)) }
        if !chips.isHidden { parts.append((chips, chips.height(forWidth: width - PiSpacing.md * 2) + PiSpacing.md, PiSpacing.md)) }
        if let field { parts.append((field, field.fieldHeight, 0)) }
        parts.append((bar, bar.height(forWidth: width), 0))
        return parts
    }
    private func cardHeight(width: CGFloat) -> CGFloat { cardParts(width: width).reduce(0) { $0 + $1.1 } }
    /// The last height worked out, until something in the card changes.
    private var measured: (width: CGFloat, height: CGFloat)?
    override func invalidateIntrinsicContentSize() { measured = nil; super.invalidateIntrinsicContentSize() }
    /// The card's width in a composer `width` wide: never narrower than its
    /// bar's controls. Narrower than that, it stands out past both edges,
    /// centred, as the SwiftUI card did, and the pane cuts it.
    private func cardWidth(_ width: CGFloat) -> CGFloat {
        max(width - Self.outer.left - Self.outer.right, bar.naturalWidth)
    }
    /// The narrowest the composer is: its bar's controls and its padding.
    var minimumWidth: CGFloat { bar.naturalWidth + Self.outer.left + Self.outer.right }
    func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = cardHeight(width: cardWidth(width)) + Self.outer.top + Self.outer.bottom
        measured = (width, height)
        return height
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : paneWidth.isFinite ? paneWidth : 600))
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = cardWidth(bounds.width)
        let height = cardHeight(width: width)
        let x = width > bounds.width - Self.outer.left - Self.outer.right ? PiKit.round((bounds.width - width) / 2, piScale) : Self.outer.left
        card.frame = CGRect(x: x, y: Self.outer.top, width: width, height: height)
        var y: CGFloat = 0
        for (view, partHeight, inset) in cardParts(width: width) {
            if view === loadingLine {
                view.frame = CGRect(x: 8, y: y + 8, width: width - 16, height: partHeight - 16)
            } else if view === chips {
                view.frame = CGRect(x: inset, y: y + PiSpacing.md, width: width - inset * 2, height: partHeight - PiSpacing.md)
            } else {
                view.frame = CGRect(x: inset, y: y, width: width - inset * 2, height: partHeight)
            }
            if view === field {
                let size = placeholder.intrinsicContentSize
                placeholder.frame = CGRect(x: 15, y: y + 9, width: min(size.width, max(0, width - 30)), height: size.height)
            }
            y += partHeight
        }
        // The list rises from the card's top edge, eight points above it.
        if !completions.isHidden {
            let listHeight = completions.height(forWidth: width)
            completions.frame = CGRect(x: card.frame.minX, y: card.frame.minY - PiSpacing.sm - listHeight, width: width, height: listHeight)
        }
    }

    // MARK: Escape

    /// Escape is a banner's Cancel, as `.keyboardShortcut(.cancelAction)` made
    /// it: for the composer the reader is in (or the pane that has the
    /// focus), unless the slash list, text being composed or a sheet takes
    /// it first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let banner = editingBanner ?? queueBanner, banner.cancel.isEnabled, cancelTakesEscape() {
            banner.cancel.performClick(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    private func cancelTakesEscape() -> Bool {
        guard inheritedEnabled, let session, let window, window.attachedSheet == nil, !session.completionVisible, model.page == .chats,
              let editor = field?.documentView as? NSTextView, !editor.isHiddenOrHasHiddenAncestor, !isHiddenOrHasHiddenAncestor else { return false }
        if editor.hasMarkedText() { return false }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return true }
        // Keys elsewhere in the pane the reader is in (its transcript), not another pane's.
        guard model.focusedSessionID == session.id else { return false }
        if let responder = window.firstResponder as? NSView, responder is NSTextView, !responder.isDescendant(of: self),
           (responder as? NSTextView)?.isEditable == true { return false }
        return true
    }

    /// The list floats outside the card's bounds, over the transcript: it
    /// takes its own clicks there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !completions.isHidden, let hit = completions.hitTest(convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }
}

extension PiKit {
    /// A control arriving: it scales up from nine tenths and fades in, as
    /// `.transition(.scale(scale: 0.9).combined(with: .opacity))`.
    @MainActor static func appearScaled(_ view: NSView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.9; scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup(); group.animations = [scale, fade]
        group.duration = Motion.base; group.timingFunction = Motion.timing(.easeOut)
        layer.add(group, forKey: "appear")
    }
}
