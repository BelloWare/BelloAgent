import AppKit
import Combine

/// The skill pills' two ways of saying more: the card that appears when the
/// pointer rests on a pill, and the popover a press opens. One of each exists
/// app-wide, so a card never lingers under a popover and two popovers never
/// open at once; the popover is the stats pills' `PiPopoverPresenter`, so it
/// looks and closes the same way (Escape, a click elsewhere, a second press).
@MainActor final class SkillPopovers: ObservableObject {
    static let shared = SkillPopovers()
    let popover = PiPopoverPresenter()
    let card = PiHoverCardPresenter()
    /// The pill whose popover is open, for its face to stay lit.
    @Published private(set) var openKey: String?
    /// What the open popover said and offered when it opened, for tests.
    private(set) var presented: (detail: SkillDetail, actions: SkillPopoverActions)?
    static let popoverWidth: CGFloat = 380
    static let popoverMaximumHeight: CGFloat = 560
    static let cardWidth: CGFloat = 288
    /// What Open and Reveal in Finder do; tests record them instead.
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private var observation: AnyCancellable?
    /// The pill a popover is opening for, and what it will say, until it shows.
    private var pendingKey: String?
    private var pendingPresented: (@MainActor () -> (detail: SkillDetail, actions: SkillPopoverActions))?

    private init() {
        observation = popover.$isShown.sink { [weak self] shown in
            MainActor.assumeIsolated {
                guard let self else { return }
                if shown { self.openKey = self.pendingKey; self.presented = self.pendingPresented?() }
                // What a closed popover held — a chat's display among it — is let go.
                else { self.openKey = nil; self.presented = nil; self.pendingKey = nil; self.pendingPresented = nil }
            }
        }
    }

    static func composerKey(sessionID: String, skillID: String) -> String { "composer|" + sessionID + "|" + skillID }
    static func sentKey(messageID: String, skillID: String) -> String { "sent|" + messageID + "|" + skillID }

    // MARK: Card

    /// The pointer entered or left a pill. No card while a popover is open:
    /// the popover already says more.
    func hover(_ inside: Bool, anchor: NSView, reduceMotion: Bool = PiKit.Motion.reduced, detail: @escaping @MainActor () -> SkillDetail) {
        if inside, popover.isShown || popover.isOpening { return }
        card.reducesMotion = reduceMotion
        card.hover(inside, over: anchor, width: Self.cardWidth) { SkillHoverCardView(detail: detail()) }
    }

    // MARK: Popover

    /// Opens the pill's popover, or closes it when it is the one open. When
    /// the skill list is being read for it, the popover waits a moment for
    /// the answer, so it opens whole rather than growing a line after.
    func present(key: String, anchor: NSView, reduceMotion: Bool, waitsForCatalog: Bool, isReady: @escaping @MainActor () -> Bool,
                 presented: @escaping @MainActor () -> (detail: SkillDetail, actions: SkillPopoverActions),
                 content: @escaping @MainActor (CGFloat) -> NSView) {
        card.hide()
        if popover.isShown || popover.isOpening {
            let same = (popover.isShown ? openKey : pendingKey) == key
            popover.close(); pendingKey = nil; pendingPresented = nil
            if same { return }
        }
        pendingKey = key; pendingPresented = presented
        // The room the popover has on this screen as it opens, so the
        // content keeps its header and footer and scrolls only its middle.
        popover.toggle(from: anchor, width: Self.popoverWidth, maximumHeight: Self.popoverMaximumHeight, animates: !reduceMotion,
                       within: waitsForCatalog ? .milliseconds(300) : .zero, isReady: isReady) { [weak anchor] in
            content(anchor.map { Self.room(for: $0) } ?? Self.popoverMaximumHeight)
        }
    }
    func close() { card.hide(); popover.close(); pendingKey = nil; pendingPresented = nil }
    /// How tall a popover from `anchor` may be, as the presenter places it.
    static func room(for anchor: NSView) -> CGFloat {
        guard let window = anchor.window else { return popoverMaximumHeight }
        let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? onScreen.insetBy(dx: -2_000, dy: -2_000)
        return PiPopoverPresenter.placement(anchor: onScreen, visible: visible, maximumHeight: popoverMaximumHeight).height
    }
    /// A pill left its window: its card goes, and its popover if it is the
    /// one the popover points at.
    func anchorLeft(_ anchor: NSView) {
        if card.anchorView === anchor { card.hide() }
        if popover.anchorView === anchor { popover.close() }
    }

    // MARK: The composer's tokens

    func hoverComposer(_ inside: Bool, chip: SkillChip, anchor: NSView, session: SessionDisplay, reduceMotion: Bool = PiKit.Motion.reduced) {
        hover(inside, anchor: anchor, reduceMotion: reduceMotion) { [weak session] in
            let current = session?.skills.first { $0.id == chip.id } ?? chip
            return .composer(current, catalog: session?.skillCatalog ?? SkillCatalog())
        }
    }
    func pressComposer(chip: SkillChip, anchor: NSView, editor: ComposerTextView?, model: WorkspaceModel, session: SessionDisplay,
                       reduceMotion: Bool = PiKit.Motion.reduced) {
        let waits = loadCatalogIfNeeded(model: model, session: session)
        let actions: (SkillChip) -> SkillPopoverActions = { [weak self, weak editor, weak model] current in
            SkillPopoverActions(open: self?.fileAction(current.path, reveal: false), reveal: self?.fileAction(current.path, reveal: true),
                                editArguments: { [weak self] in
                                    self?.close()
                                    model?.editSkillArguments(current, view: session)
                                },
                                remove: { [weak self] in
                                    self?.close()
                                    if let editor, editor.skillStrip.display === session { editor.removeSkillToken(current.id) }
                                    else { session.skills.removeAll { $0.id == current.id }; model?.draftChanged(session) }
                                })
        }
        present(key: Self.composerKey(sessionID: session.id, skillID: chip.id), anchor: anchor, reduceMotion: reduceMotion, waitsForCatalog: waits,
                isReady: { Self.catalogAnswered(session) },
                presented: { [weak session] in
                    let current = session?.skills.first { $0.id == chip.id } ?? chip
                    return (.composer(current, catalog: session?.skillCatalog ?? SkillCatalog()), actions(current))
                }) {
            SkillPopoverContentView(session: session, room: $0) { [weak session] in
                let current = session?.skills.first { $0.id == chip.id } ?? chip
                return (.composer(current, catalog: session?.skillCatalog ?? SkillCatalog()), actions(current))
            }
        }
    }

    // MARK: A sent message's pills

    func hoverSent(_ inside: Bool, use: TranscriptSkillUse, anchor: NSView, session: SessionDisplay) {
        hover(inside, anchor: anchor) { [weak session] in .sent(use, catalog: session?.skillCatalog ?? SkillCatalog()) }
    }
    func pressSent(use: TranscriptSkillUse, messageID: String, anchor: NSView, model: WorkspaceModel, session: SessionDisplay) {
        let waits = loadCatalogIfNeeded(model: model, session: session)
        let actions = SkillPopoverActions(open: fileAction(use.path, reveal: false), reveal: fileAction(use.path, reveal: true))
        present(key: Self.sentKey(messageID: messageID, skillID: use.id), anchor: anchor, reduceMotion: PiKit.Motion.reduced, waitsForCatalog: waits,
                isReady: { Self.catalogAnswered(session) },
                presented: { [weak session] in (.sent(use, catalog: session?.skillCatalog ?? SkillCatalog()), actions) }) {
            SkillPopoverContentView(session: session, room: $0) { [weak session] in
                (.sent(use, catalog: session?.skillCatalog ?? SkillCatalog()), actions)
            }
        }
    }

    /// "Changed since this message" needs the skills as they are now. The
    /// catalog is read once per chat and helper; a load already under way,
    /// or one that already answered for this chat, is not repeated. True when
    /// a read was started.
    private func loadCatalogIfNeeded(model: WorkspaceModel, session: SessionDisplay) -> Bool {
        guard !session.skillCatalog.authorizes, model.record(session.id) != nil else { return false }
        Task { [weak model] in await model?.loadSkillCatalog(sessionID: session.id) }
        return true
    }
    private static func catalogAnswered(_ session: SessionDisplay) -> Bool {
        session.skillCatalog.authorizes || session.skillCatalog.state == .failed
    }
    private func fileAction(_ path: String, reveal: Bool) -> (() -> Void)? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        return { [weak self] in
            self?.close()
            if reveal { self?.revealFile(url) } else { self?.openFile(url) }
        }
    }
}

/// What a skill popover's buttons do. Nil hides or disables the button: a
/// source file that is gone cannot be opened, and only the composer's own
/// tokens can be edited or removed.
struct SkillPopoverActions {
    var open: (() -> Void)?
    var reveal: (() -> Void)?
    var editArguments: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var editable: Bool { editArguments != nil || remove != nil }
}

