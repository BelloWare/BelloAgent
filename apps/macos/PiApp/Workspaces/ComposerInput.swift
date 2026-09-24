import SwiftUI

// The composer: the native editor, the chips above it, the slash-command
// list over it, and the bar of controls under it whose form is measured
// rather than laid out.

/// Which chat's draft changed, and to what: see the `onChange` below.
private struct ComposerDraftEdit: Equatable { let session: String; let text: String }

struct ComposerInput: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var draft: ComposerDraft
    /// The pane this bar sits in, for `ComposerBarMetrics`.
    let paneWidth: CGFloat
    @Environment(\.piReduceMotion) private var reduceMotion
    init(model: WorkspaceModel, session: SessionDisplay, paneWidth: CGFloat) {
        self.model = model; self.session = session; self.draft = session.composerDraft; self.paneWidth = paneWidth
    }
    private var editing: Bool { session.editingMessageID != nil }
    /// A draft of any size is checked for its first non-whitespace character;
    /// trimming a long draft would copy it on every keystroke.
    private var canSend: Bool { session.draftReady && !((!draft.text.contains { !$0.isWhitespace } && session.skills.isEmpty) || session.loading || model.installPreparing || (editing && model.editBlocker(session) != nil)) }
    private var queues: Bool { !editing && (session.busy || !session.queue.isEmpty || !session.sendingRows.isEmpty) }
    @State private var sendPulse = false
    private func submit(intent: ComposerSubmissionIntent = .followUp) {
        guard model.page == .chats else { return }
        // A short press-in and spring-back confirms the send under the pointer.
        // Uncancelled on purpose: 120 ms, writing only this view's own @State.
        sendPulse = true
        Task { try? await Task.sleep(for: .milliseconds(120)); sendPulse = false }
        model.submitComposer(intent: intent, sessionID: session.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            VStack(spacing: 0) {
                if session.editPreparing && !editing { Text("Loading the complete original input…").font(PiFont.caption).padding(8) }
                if editing { EditingBanner(session: session, blocker: model.editBlocker(session)) { model.cancelEdit(sessionID: session.id) }.transition(AnyTransition.move(edge: .top).combined(with: .opacity)) }
                if session.runStatus == "compacting" || session.compactionNotice != nil {
                    CompactionBanner(session: session) { session.compactionNotice = nil }.transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
                if !session.attachments.isEmpty { chips.padding(.horizontal, PiSpacing.md).padding(.top, PiSpacing.md).transition(.opacity) }
                NativeComposer(text: $draft.text, send: { submit(intent: $0) }, sessionID: session.id, completion: { _ in },
                    locationChanged: { model.composerMoved($0, editor: $1, view: session) },
                    directSlash: { if !session.directCommand { session.directCommand = true } }, pasted: { session.directCommand = false; session.completionVisible = false },
                    completionKey: { model.completionKey($0, modifiers: $1, view: session) }, focused: { if model.focusedSessionID != session.id { model.focusedSessionID = session.id }; model.prewarm(session.id) }, accessibilityLabel: model.side(session.id) == nil ? "Main message composer" : "Side message composer", inputRejected: { session.notice = $0 },
                    attachFiles: { model.attachImageFiles($0, sessionID: session.id) },
                    focusToken: session.composerFocusRequest,
                    // The selected skills lead the text as tokens (ComposerSkillTokens.swift).
                    skills: session.skills, skillDisplay: session, skillsChanged: { model.draftChanged(session) },
                    skillPressed: { chip, token in
                        SkillPopovers.shared.pressComposer(chip: chip, anchor: token, editor: token.superview as? ComposerTextView, model: model, session: session,
                                                           reduceMotion: reduceMotion)
                    },
                    skillHovered: { chip, token, inside in
                        SkillPopovers.shared.hoverComposer(inside, chip: chip, anchor: token, session: session, reduceMotion: reduceMotion)
                    },
                    describeSkill: { chip in .composer(chip, catalog: session.skillCatalog) })
                    // Its height is its own (`ComposerScrollView`), in step with the text.
                    .id(session.id).disabled(!session.draftReady).fixedSize(horizontal: false, vertical: true)
                    // The pane is kept across chats, so a switch hands this
                    // bar another chat's draft. That is not typing: saving it
                    // wrote the unchanged draft back on every click.
                    .onChange(of: ComposerDraftEdit(session: session.id, text: draft.text)) { old, new in
                        if old.session == new.session { model.draftChanged(session) }
                    }
                    // The keyboard hints are the empty composer's placeholder; they leave once typing starts.
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty && session.skills.isEmpty {
                            Text("Message… " + ComposerSubmissionIntent.hint(queues: queues, onBar: queues && !editing && barForm.runControls.showsHint))
                                .font(.system(size: 14)).foregroundStyle(Color.piInkTertiary)
                                .padding(.leading, 15).padding(.top, 9).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                let form = barForm
                HStack(spacing: ComposerBarMetrics.spacing) {
                    PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) { model.attachImages(sessionID: session.id) }.disabled(!session.draftReady || !model.supportsImages(session.id))
                    PiIconButton(symbol: "command", label: "Skills…", size: 28, filled: true) { model.inspectResources(session.id) }
                    Spacer()
                    runControlRow(form.runControls)
                    if let chat = model.record(session.id) {
                        if model.side(session.id) == nil, model.workspace(for: chat.workspaceID) != nil, chat.workspaceID != WorkspaceRecord.scratchID {
                            PiIconButton(symbol: "arrow.triangle.branch", label: "Changes and history of this project", size: 28, filled: true) { model.showChanges(in: chat.workspaceID) }
                                .accessibilityIdentifier("sessionChangesButton")
                        }
                        SessionUsageButton(model: model, chat: chat, footer: session.footer)
                        if model.side(session.id) == nil { ConversationActionsMenu(model: model, session: session, chat: chat) }
                    }
                    ModelSwitchPills(model: model, session: session, form: form.pills).padding(.trailing, ComposerBarMetrics.pillsTrailing)
                    Button { submit() } label: {
                        Image(systemName: queues ? "text.badge.plus" : editing ? "arrow.uturn.up" : "arrow.up").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canSend ? Color.piOnAccent : Color.piInkTertiary)
                            .frame(width: 30, height: 30)
                            .background { if canSend { Circle().fill(Color.piBrandOrange) } else { Circle().fill(Color.piFillStrong) } }
                            .shadow(color: canSend ? Color.piBrandOrange.opacity(0.24) : .clear, radius: 5, y: 2)
                            .contentShape(Circle())
                            .scaleEffect(sendPulse && !reduceMotion ? 0.92 : 1)
                            .piAnimation(PiMotion.quick, value: canSend)
                            .piAnimation(PiMotion.quick, value: sendPulse)
                    }.buttonStyle(.plain).piPointer().disabled(!canSend).help(editing ? model.editBlocker(session) ?? "Resend Edited Message" : queues ? "Queue Follow-up" : "Send")
                    if session.busy {
                        Button { model.stop(sessionID: session.id) } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.piOnAccent)
                                .frame(width: 30, height: 30)
                                .background(Color.piDanger, in: Circle()).contentShape(Circle())
                        }
                        .buttonStyle(.plain).piPointer().help("Stop response")
                        .accessibilityLabel("Stop response").accessibilityIdentifier("composerStopResponse")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 0)
            }
            .piElevated(radius: 16)
            // The slash-command list floats above the composer instead of
            // taking part in the pane's layout: in the stack, opening it,
            // filtering it and closing it resized the transcript every time.
            // A zero-height frame on the composer's top edge holds it, and the
            // list, at its own height, rises from that edge.
            .overlay(alignment: .top) {
                if session.completionVisible {
                    completions.padding(.bottom, PiSpacing.sm).frame(height: 0, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm).padding(.bottom, 6)
        // NSTextView supplies its measured height after native layout. An
        // animated height feeds intermediate sizes back into that measurement
        // and makes typing, completion, and the transcript above it bounce.
        .piStableLayout()
        .disabled(editing && session.loading)
    }

    /// What the bar has to show, and what it must therefore give up. Reading
    /// the strings is a handful of dictionary lookups; measuring them is done
    /// once per string in `PiTextWidth`.
    var metrics: ComposerBarMetrics {
        let pills = ModelSwitchPills.contents(model: model, session: session)
        let chat = model.record(session.id)
        let isSide = model.side(session.id) != nil
        return ComposerBarMetrics(showsSteer: session.busy && !editing,
                                  hint: hint,
                                  showsChanges: chat.map { !isSide && model.workspace(for: $0.workspaceID) != nil && $0.workspaceID != WorkspaceRecord.scratchID } ?? false,
                                  showsActions: chat != nil && !isSide,
                                  showsStop: session.busy,
                                  showsConnectionPill: pills.showsConnection,
                                  connection: pills.connection, model: pills.model, effort: pills.effort,
                                  modelLoading: pills.loading)
    }
    private var barForm: ComposerBarForm { metrics.form(fitting: ComposerBarMetrics.available(paneWidth: paneWidth)) }
    /// The line beside the steering button: what pressing Return will do.
    private var hint: String? {
        if queues { return "↩ Queue · ⌘↩ Steer" }
        if editing { return session.busy || !session.queue.isEmpty ? "Wait for idle to resend" : "Resend from here" }
        return nil
    }

    /// Steering and the send hint. A side pane in a small window leaves this
    /// group under a hundred points: the bar gives up its words rather than
    /// wrapping them down the middle, which used to stack "Steer run" one
    /// letter per line and push the composer to three rows.
    @ViewBuilder private func runControlRow(_ form: ComposerRunControlsForm) -> some View {
        HStack(spacing: ComposerBarMetrics.spacing) {
            if session.busy && !editing {
                Button { submit(intent: .steer) } label: {
                    if form.steerIsCompact { Image(systemName: "arrow.turn.up.right") }
                    else { Label("Steer run", systemImage: "arrow.turn.up.right") }
                }
                .buttonStyle(.piGhost).disabled(session.loading).fixedSize()
                .help("⌘↩ Steer run · deliver this message to the current run after its tool batch")
                .accessibilityLabel("Steer run")
            }
            if form.showsHint, let hint {
                Text(hint).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
            }
        }
    }

    /// Attached images. The selected skills are not here: they lead the text
    /// as tokens inside the editor.
    private var chips: some View {
        PiFlow {
            ForEach(session.attachments) { attachment in
                PiChip(text: URL(fileURLWithPath: attachment.path).lastPathComponent, icon: "photo", help: attachment.path,
                       action: { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) },
                       remove: { session.attachments.removeAll { $0.id == attachment.id }; model.draftChanged(session) })
            }
        }
    }

    /// The slash-command list, in the chrome of the other Pi popovers: the
    /// surface, a strong hairline and the hover card's shadow.
    private var completions: some View {
        let choices = model.completions(session)
        let catalog = session.skillCatalog
        let shape = RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: SlashCompletionMetrics.rowSpacing) {
                        ForEach(choices) { choice in
                            SlashCompletionRow(choice: choice, selected: choice.id == session.completionSelectionID) {
                                model.chooseCompletion(choice, view: session)
                            }.id(choice.id)
                        }
                    }.padding(SlashCompletionMetrics.inset)
                }.frame(height: SlashCompletionMetrics.listHeight(count: choices.count))
                    .onChange(of: session.completionSelectionID) { _, id in if let id { reader.scrollTo(id) } }
            }
            Rectangle().fill(Color.piHairline).frame(height: 1)
            HStack(spacing: PiSpacing.sm) {
                Text(catalog.state == .loading ? "Discovering skills…" : catalog.state == .failed ? "Discovery failed" : choices.isEmpty ? "No matches" : "\(choices.count) results · ↑↓ Choose · Tab/Return Select")
                    .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                Spacer(minLength: PiSpacing.sm)
                if catalog.state == .failed || catalog.state == .partial {
                    Button("Retry") { Task { await model.loadSkillCatalog(refresh: true, sessionID: session.id) } }.buttonStyle(.piGhost)
                }
                Button("All Skills…") { model.inspectResources(session.id) }.buttonStyle(.piGhost)
            }.padding(.horizontal, PiSpacing.md).padding(.vertical, PiSpacing.xs)
            if !catalog.notice.isEmpty && catalog.state != .loading {
                Text(catalog.notice).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2).help(catalog.notice)
                    .padding(.horizontal, PiSpacing.md).padding(.bottom, PiSpacing.sm)
            }
        }
        .background(shape.fill(Color.piSurface))
        .overlay(shape.stroke(Color.piHairlineStrong, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: Color.piShadow, radius: 10, y: 3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel("Slash command suggestions")
    }
}

/// The slash-command list's rows: the height and highlight of a Pi list row.
enum SlashCompletionMetrics {
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    static let inset = PiSpacing.xs
    /// Eight rows show before the list scrolls.
    static let visibleRows = 8
    static func listHeight(count: Int) -> CGFloat {
        let rows = CGFloat(min(visibleRows, max(1, count)))
        return rows * rowHeight + (rows - 1) * rowSpacing + 2 * inset
    }
}

/// One command or skill: its symbol, its name, and where it comes from. The
/// selected row takes the accent wash the keyboard moves; the pointer's row
/// takes the fill every other Pi list uses for hover.
private struct SlashCompletionRow: View {
    let choice: CommandCompletion
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous)
        Button(action: action) {
            HStack(spacing: PiSpacing.sm) {
                Image(systemName: choice.skill == nil ? "terminal" : "command")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.piAccent : Color.piInkSecondary).frame(width: 16)
                Text("/" + choice.name).font(PiFont.body.weight(.semibold)).foregroundStyle(Color.piInk).lineLimit(1).layoutPriority(1)
                Text(choice.detail).lineLimit(1).truncationMode(.middle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PiSpacing.sm).frame(maxWidth: .infinity, minHeight: SlashCompletionMetrics.rowHeight, maxHeight: SlashCompletionMetrics.rowHeight)
            .background(selected ? Color.piAccentSoft : hovering ? Color.piFill : Color.clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain).piPointer().help(choice.detail)
        .onHover { hovering = $0 }
    }
}
