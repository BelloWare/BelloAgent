import SwiftUI

// The composer: the native editor, the chips above it, the slash-command
// list over it, and the bar of controls under it whose form is measured
// rather than laid out.

struct ComposerInput: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var draft: ComposerDraft
    /// The pane this bar sits in, for `ComposerBarMetrics`.
    let paneWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    private let minimumHeight: CGFloat = 44
    private let maximumHeight: CGFloat = 240
    init(model: WorkspaceModel, session: SessionDisplay, paneWidth: CGFloat) {
        self.model = model; self.session = session; self.draft = session.composerDraft; self.paneWidth = paneWidth
    }
    private var editing: Bool { session.editingMessageID != nil }
    /// A draft of any size is checked for its first non-whitespace character;
    /// trimming a long draft would copy it on every keystroke.
    private var canSend: Bool { !((!draft.text.contains { !$0.isWhitespace } && session.skills.isEmpty) || session.loading || model.installPreparing || (editing && (session.busy || !session.queue.isEmpty))) }
    private var queues: Bool { !editing && (session.busy || !session.queue.isEmpty) }
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
            if session.completionVisible { completions.transition(AnyTransition.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity)) }
            VStack(spacing: 0) {
                if editing { EditingBanner(session: session) { model.cancelEdit(sessionID: session.id) }.transition(AnyTransition.move(edge: .top).combined(with: .opacity)) }
                if session.runStatus == "compacting" || session.compactionNotice != nil {
                    CompactionBanner(session: session) { session.compactionNotice = nil }.transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
                if !session.attachments.isEmpty || !session.skills.isEmpty { chips.padding(.horizontal, PiSpacing.md).padding(.top, PiSpacing.md).transition(.opacity) }
                NativeComposer(text: $draft.text, send: { submit(intent: $0) }, sessionID: session.id, completion: { _ in model.commandChanged(session) },
                    directSlash: { session.directCommand = true }, pasted: { session.directCommand = false; session.completionVisible = false },
                    completionKey: { model.completionKey($0, modifiers: $1, view: session) }, focused: { if model.focusedSessionID != session.id { model.focusedSessionID = session.id } }, accessibilityLabel: model.side(session.id) == nil ? "Main message composer" : "Side message composer", inputRejected: { session.notice = $0 },
                    attachFiles: { model.attachImageFiles($0, sessionID: session.id) },
                    heightChanged: { height in if abs(contentHeight - height) >= 1 { contentHeight = height } }, focusToken: session.composerFocusRequest)
                    .id(session.id).frame(height: min(maximumHeight, max(minimumHeight, contentHeight)))
                    .onChange(of: draft.text) { _, _ in model.draftChanged(session) }
                    // The keyboard hints are the empty composer's placeholder; they leave once typing starts.
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty && session.skills.isEmpty {
                            Text("Message… " + ComposerSubmissionIntent.hint(running: session.busy)).font(.system(size: 14)).foregroundStyle(Color.piInkTertiary)
                                .padding(.leading, 15).padding(.top, 9).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                let form = barForm
                HStack(spacing: ComposerBarMetrics.spacing) {
                    PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) { model.attachImages(sessionID: session.id) }.disabled(!model.supportsImages(session.id))
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
                    }.buttonStyle(.plain).piPointer().disabled(!canSend).help(queues ? "Queue Follow-up" : editing ? "Resend Edited Message" : "Send")
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

    private var chips: some View {
        PiFlow {
            ForEach(session.attachments) { attachment in
                PiChip(text: URL(fileURLWithPath: attachment.path).lastPathComponent, icon: "photo", help: attachment.path,
                       action: { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) },
                       remove: { session.attachments.removeAll { $0.id == attachment.id }; model.draftChanged(session) })
            }
            ForEach(session.skills) { chip in
                PiChip(text: "/\(chip.name)" + (chip.arguments.isEmpty ? "" : " · \(String(chip.arguments.prefix(50)))"), icon: "command",
                       help: "Explicit for this submission · \(chip.path) · \(chip.contentHash)",
                       action: { model.editSkillArguments(chip, view: session) },
                       remove: { session.skills.removeAll { $0.id == chip.id }; model.draftChanged(session) })
            }
        }
    }

    private var completions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.completions(session).enumerated()), id: \.element.id) { index, choice in
                Button { model.chooseCompletion(choice, view: session) } label: {
                    HStack(spacing: PiSpacing.sm) {
                        Image(systemName: choice.skill == nil ? "terminal" : "command").font(.system(size: 11, weight: .semibold)).foregroundStyle(index == session.completionIndex ? Color.piAccent : Color.piInkSecondary).frame(width: 16)
                        Text("/" + choice.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk)
                        Text(choice.detail).lineLimit(1).truncationMode(.middle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        Spacer()
                    }.padding(.horizontal, PiSpacing.sm).padding(.vertical, 6).frame(maxWidth: .infinity)
                        .background(index == session.completionIndex ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).piPointer()
            }
            HStack {
                Text(model.resourceLoading ? "Discovering skills…" : "↑↓ Choose · Tab or Return Select · Select skills before ⌘↩ · Esc Dismiss").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                Spacer()
                Button("All Skills…") { model.inspectResources(session.id) }.buttonStyle(.piGhost)
            }.padding(.horizontal, PiSpacing.sm).padding(.top, 4)
        }
        .padding(PiSpacing.sm)
        .piElevated(radius: PiRadius.md)
        .accessibilityElement(children: .contain).accessibilityLabel("Slash command suggestions")
    }
}
