import SwiftUI
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
    /// What the open popover said and offered when it opened. A test reads
    /// it rather than a SwiftUI button it cannot reach.
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
    func hover(_ inside: Bool, anchor: NSView, reduceMotion: Bool = PiMotion.reducesMotion, detail: @escaping @MainActor () -> SkillDetail) {
        if inside, popover.isShown || popover.isOpening { return }
        card.reducesMotion = reduceMotion
        card.hover(inside, over: anchor, width: Self.cardWidth) { AnyView(SkillHoverCard(detail: detail())) }
    }

    // MARK: Popover

    /// Opens the pill's popover, or closes it when it is the one open. When
    /// the skill list is being read for it, the popover waits a moment for
    /// the answer, so it opens whole rather than growing a line after.
    func present(key: String, anchor: NSView, reduceMotion: Bool, waitsForCatalog: Bool, isReady: @escaping @MainActor () -> Bool,
                 presented: @escaping @MainActor () -> (detail: SkillDetail, actions: SkillPopoverActions),
                 content: @escaping @MainActor () -> AnyView) {
        card.hide()
        if popover.isShown || popover.isOpening {
            let same = (popover.isShown ? openKey : pendingKey) == key
            popover.close(); pendingKey = nil; pendingPresented = nil
            if same { return }
        }
        pendingKey = key; pendingPresented = presented
        popover.toggle(from: anchor, width: Self.popoverWidth, maximumHeight: Self.popoverMaximumHeight, animates: !reduceMotion,
                       within: waitsForCatalog ? .milliseconds(300) : .zero, isReady: isReady) {
            AnyView(content().environment(\.piReduceMotion, reduceMotion).tint(Color.piAccent))
        }
    }
    func close() { card.hide(); popover.close(); pendingKey = nil; pendingPresented = nil }
    /// A pill left its window: its card goes, and its popover if it is the
    /// one the popover points at.
    func anchorLeft(_ anchor: NSView) {
        if card.anchorView === anchor { card.hide() }
        if popover.anchorView === anchor { popover.close() }
    }

    // MARK: The composer's tokens

    func hoverComposer(_ inside: Bool, chip: SkillChip, anchor: NSView, session: SessionDisplay, reduceMotion: Bool = PiMotion.reducesMotion) {
        hover(inside, anchor: anchor, reduceMotion: reduceMotion) { [weak session] in
            let current = session?.skills.first { $0.id == chip.id } ?? chip
            return .composer(current, catalog: session?.skillCatalog ?? SkillCatalog())
        }
    }
    func pressComposer(chip: SkillChip, anchor: NSView, editor: ComposerTextView?, model: WorkspaceModel, session: SessionDisplay,
                       reduceMotion: Bool = PiMotion.reducesMotion) {
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
            AnyView(ComposerSkillPopover(session: session, chipID: chip.id, fallback: chip, actions: actions))
        }
    }

    // MARK: A sent message's pills

    func hoverSent(_ inside: Bool, use: TranscriptSkillUse, anchor: NSView, session: SessionDisplay) {
        hover(inside, anchor: anchor) { [weak session] in .sent(use, catalog: session?.skillCatalog ?? SkillCatalog()) }
    }
    func pressSent(use: TranscriptSkillUse, messageID: String, anchor: NSView, model: WorkspaceModel, session: SessionDisplay) {
        let waits = loadCatalogIfNeeded(model: model, session: session)
        let actions = SkillPopoverActions(open: fileAction(use.path, reveal: false), reveal: fileAction(use.path, reveal: true))
        present(key: Self.sentKey(messageID: messageID, skillID: use.id), anchor: anchor, reduceMotion: PiMotion.reducesMotion, waitsForCatalog: waits,
                isReady: { Self.catalogAnswered(session) },
                presented: { [weak session] in (.sent(use, catalog: session?.skillCatalog ?? SkillCatalog()), actions) }) {
            AnyView(SentSkillPopover(session: session, use: use, actions: actions))
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

/// A composer token's popover, reading the token's current values: its
/// arguments may be edited, and the catalog may arrive, while it is open.
private struct ComposerSkillPopover: View {
    @ObservedObject var session: SessionDisplay
    let chipID: String
    let fallback: SkillChip
    let actions: (SkillChip) -> SkillPopoverActions
    var body: some View {
        let chip = session.skills.first { $0.id == chipID } ?? fallback
        SkillPopoverView(detail: .composer(chip, catalog: session.skillCatalog), actions: actions(chip))
    }
}

/// A sent message's pill: what was sent, against the catalog as it is now.
private struct SentSkillPopover: View {
    @ObservedObject var session: SessionDisplay
    let use: TranscriptSkillUse
    let actions: SkillPopoverActions
    var body: some View {
        SkillPopoverView(detail: .sent(use, catalog: session.skillCatalog), actions: actions)
    }
}

// MARK: - The card

/// The compact preview a resting pointer brings up: the name, what the skill
/// is for, where it comes from and the arguments it was given.
struct SkillHoverCard: View {
    let detail: SkillDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "command").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.piAccent)
                Text("/" + detail.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let policy = detail.policyTitle {
                    Text(policy).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).fixedSize()
                }
            }
            if !detail.description.isEmpty {
                Text(detail.description).font(.system(size: 12)).foregroundStyle(Color.piInkSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Text(detail.place.sentence).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                .lineLimit(1).truncationMode(.middle)
            if !detail.arguments.isEmpty {
                (Text("Arguments  ").foregroundStyle(Color.piInkTertiary) + Text(detail.arguments).foregroundStyle(Color.piInk))
                    .font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let note = detail.revisionNote, note.warns {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5, weight: .medium)).padding(.top, 1)
                    Text(note.text).font(PiFont.caption).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.piWarning)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("skill-hover-card")
    }
}

// MARK: - The popover

/// Everything about one pill's skill: what it is for, the arguments it was
/// given, its source file, where it comes from, its policy and version, and —
/// for a sent message — whether it has changed since.
struct SkillPopoverView: View {
    let detail: SkillDetail
    let actions: SkillPopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if detail.description.isEmpty {
                        Text("No description").font(PiFont.body).foregroundStyle(Color.piInkTertiary)
                    } else {
                        Text(detail.description).font(PiFont.body).foregroundStyle(Color.piInk)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let note = detail.revisionNote {
                        PiNote(note.text, tone: note.warns ? .warning : .neutral)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("skill-popover-revision")
                    }
                    section("Arguments") {
                        if detail.arguments.isEmpty {
                            Text("None").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        } else {
                            Text(detail.arguments).font(.system(size: 12.5)).foregroundStyle(Color.piInk)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
                        }
                    }
                    section("Source") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.place.file(detail.path)).font(PiFont.mono).foregroundStyle(Color.piInk)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(detail.path)
                            if !detail.place.root.isEmpty {
                                Text("in " + (detail.place.root as NSString).abbreviatingWithTildeInPath).font(PiFont.caption)
                                    .foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle).help(detail.place.root)
                            }
                            HStack(spacing: 6) {
                                Button("Open") { actions.open?() }.buttonStyle(.piSecondaryCompact).disabled(actions.open == nil)
                                    .accessibilityIdentifier("skill-popover-open")
                                Button("Reveal in Finder") { actions.reveal?() }.buttonStyle(.piSecondaryCompact).disabled(actions.reveal == nil)
                                    .accessibilityIdentifier("skill-popover-reveal")
                                if actions.open == nil {
                                    Text("File not found").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fact("Scope", detail.place.title)
                        if let policy = detail.policyTitle {
                            fact("Policy", policy + (detail.policyDetail.map { " · " + $0 } ?? ""))
                        }
                        fact("Version", versionText, mono: true)
                    }
                }
                .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, PiSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if actions.editable {
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(spacing: PiSpacing.sm) {
                    if let edit = actions.editArguments {
                        Button("Edit Arguments…", action: edit).buttonStyle(.piSecondaryCompact)
                            .accessibilityIdentifier("skill-popover-edit")
                    }
                    Spacer(minLength: 0)
                    if let remove = actions.remove {
                        Button("Remove", action: remove).buttonStyle(.piGhostDanger)
                            .accessibilityIdentifier("skill-popover-remove")
                    }
                }
                .padding(.horizontal, PiSpacing.md).padding(.vertical, 10)
            }
        }
        .foregroundStyle(Color.piInk)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-popover")
    }

    private var header: some View {
        HStack(spacing: 9) {
            PiIconBadge(symbol: "command", size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("/" + detail.name).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                Text(detail.context == .composer ? "Selected for the message you are writing" : "Sent with this message")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            Spacer(minLength: PiSpacing.sm)
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, 12)
    }
    private var versionText: String {
        if case .changed(let now) = detail.revision {
            return detail.context == .sent ? "\(detail.version) · now \(now)" : "\(detail.version) · installed \(now)"
        }
        return detail.version.isEmpty ? "Unknown" : detail.version
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
            content()
        }
    }
    private func fact(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.md) {
            Text(key).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(width: 58, alignment: .leading)
            Text(value).font(mono ? PiFont.mono : PiFont.caption).foregroundStyle(Color.piInk)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
