import SwiftUI

// The chat itself: the transcript, what sits above it (a side's header, a
// recovery banner, a starter card) and what sits below it (the queue, the
// terminal, the composer and the metrics footer).

struct SideActions {
    var bringBack: () -> Void
    var keep: () -> Void
    var close: () -> Void
}

struct ConversationPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let chat: ChatRecord
    /// How wide this pane is. The composer bar measures its own controls
    /// against it instead of laying nine trial rows out to find the one that
    /// fits; the workspace already knows the figure, so nothing has to be
    /// measured in a `body` to learn it.
    let paneWidth: CGFloat
    var side: SideRecord? = nil
    var sideActions: SideActions? = nil
    private var profile: ProfileRecord? { model.profiles.first { $0.id == chat.profileID } }
    private var projectAvailable: Bool { model.workspace(for: chat.workspaceID) != nil }
    /// A chat with nothing in it yet shows what it is connected to and where to start.
    private var showsStarter: Bool {
        session.historyState == .empty && session.messages.isEmpty && session.sendingRows.isEmpty && !session.busy && !session.loading && session.failureMessage == nil && session.sendFailure == nil
            && !chat.imported && !chat.isBackgroundTask && projectAvailable && (side == nil || side?.pending == true)
    }
    var body: some View {
        VStack(spacing: 0) {
            // No header: the sidebar names the chat, the composer bar holds its
            // actions, and the live turn bar at the bottom shows what is going on.
            if side != nil { sideHeader; Rectangle().fill(Color.piHairline).frame(height: 1) }
            if session.uncertain && !session.busy && !session.recovered.isEmpty { recoveredBanner }
            NativeTranscriptView(session: session, state: session.state,
                                 actions: TranscriptActions(inspect: { model.showMessageDetail(session.id, messageID: $0) },
                                                            edit: { model.editMessage($0, sessionID: session.id) },
                                                            copyMessage: { id in
                                                                guard let message = session.presentedMessages.first(where: { $0.id == id }) else { return }
                                                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                                                            },
                                                            stop: { model.stop(sessionID: session.id) },
                                                            // The retry carries this chat's current model, effort and budgets, as a send would.
                                                            retry: { model.action("turn.retry", params: model.record(session.id).map { TurnOverrides.params(for: $0) } ?? [:], sessionID: session.id) },
                                                            quoteReply: quoteReplyAction,
                                                            inspectTurn: { [weak model] turn in
                                                                model?.openInspector(session: session.id, focus: WorkspaceModel.inspectorFocus(for: turn))
                                                            },
                                                            skillPressed: { [weak model, weak session] messageID, use, anchor in
                                                                guard let model, let session else { return }
                                                                SkillPopovers.shared.pressSent(use: use, messageID: messageID, anchor: anchor, model: model, session: session)
                                                            },
                                                            skillHovered: { [weak session] _, use, anchor, inside in
                                                                guard let session else { return }
                                                                SkillPopovers.shared.hoverSent(inside, use: use, anchor: anchor, session: session)
                                                            },
                                                            costLimit: { [weak model] action, anchor in model?.costLimitNotice(action, sessionID: session.id, anchor: anchor) }),
                                 onAnchorChanged: { anchor in session.scrollAnchor = anchor; model.anchorChanged(session) },
                                 onReadReply: { sessionID, messageID in model.acknowledgeVisibleReply(sessionID: sessionID, messageID: messageID) },
                                 onLoadEarlier: { sessionID in model.loadEarlier(sessionID: sessionID) },
                                 onLoadNewer: { model.loadNewer(sessionID: $0) },
                                 onLatest: { model.latest(sessionID: $0) },
                                 onViewportReady: { model.historyViewportReady($0, generation: $1) })
                // A card whose arguments the host had to cut asks it for the
                // rest when the reader opens it.
                .task(id: session.id) {
                    session.toolInputs.load = { [weak model, weak session] messageID, callID in
                        guard let model, let session else { throw HostError.failure("This conversation is gone") }
                        return try await model.toolInput(sessionID: session.id, messageID: messageID, callID: callID)
                    }
                }
                .piStableLayout()
                .background(Color.piContent)
                .overlay(alignment: .top) {
                    ZStack {
                        if showsStarter { StarterPanel(model: model, chat: chat, sessionID: session.id).padding(.top, PiSpacing.xl).transition(.opacity) }
                    }.piAnimation(PiMotion.quick, value: showsStarter)
                }
                .overlay {
                    ZStack {
                        // A first message being sent is already on the page: it is not covered while the helper starts.
                        if session.historyState.loading || session.loading && session.messages.isEmpty && session.sendingRows.isEmpty {
                            Color.piContent
                            VStack(spacing: PiSpacing.md) {
                                LoadingMark()
                                if let progress = session.historyProgress { Text(progress).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                            }.transition(.opacity)
                        } else if case .failed(let error) = session.historyState {
                            Color.piContent
                            VStack(spacing: PiSpacing.md) {
                                Text("Couldn’t load this conversation").font(PiFont.heading)
                                Text(error).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).textSelection(.enabled)
                                Button("Retry") { model.reloadHistory(session.id) }.buttonStyle(.piSecondaryCompact)
                            }.padding(PiSpacing.lg)
                        }
                    }.piAnimation(PiMotion.quick, value: session.historyState.loading)
                }
            if !session.queue.isEmpty { queuePanel.transition(PiMotion.arrival(from: .bottom)) }
            if model.terminalVisible, side == nil, let workspace = model.workspace(for: chat.workspaceID), !workspace.isScratch {
                TerminalPanel(model: model, workspace: workspace).transition(PiMotion.arrival(from: .bottom))
            }
            if let missing = model.missingProjectFolders[chat.workspaceID] {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(Color.piWarning)
                    Text("Project folder not found · \(missing)").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle).help(missing)
                    Spacer()
                    Button("Locate Folder…") { Task { await model.locateMissingFolder(chat.workspaceID) } }.buttonStyle(.piSecondaryCompact)
                        .accessibilityIdentifier("locateProjectFolder")
                }.padding(.horizontal, PiSpacing.md).padding(.top, PiSpacing.sm)
            }
            if !projectAvailable {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(Color.piInkSecondary)
                    Text("Project unavailable · Retained history is read-only").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Spacer()
                    // Settings that could not be read (a locked Keychain) are
                    // read again; a project that was really removed is set up.
                    if !model.configurationLoaded { Button("Retry") { model.retryConfiguration() }.buttonStyle(.piSecondaryCompact) }
                    else { Button("Configure Projects…") { model.showWorkspaceManager = true }.buttonStyle(.piSecondaryCompact) }
                }.padding(PiSpacing.md)
            } else if chat.isBackgroundTask {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "sparkle").foregroundStyle(Color.piAccent)
                    Text("Background task · Tools disabled").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Spacer()
                    if session.busy {
                        Button { model.stop(sessionID: session.id) } label: { Label("Stop task", systemImage: "stop.fill") }.buttonStyle(.piDanger)
                    }
                    if let source = chat.sourceSessionID, model.record(source) != nil {
                        Button("Open source chat") { Task { await model.select(source) } }.buttonStyle(.piSecondaryCompact)
                    }
                }.padding(PiSpacing.md)
            } else if chat.isArchived { archivedFooter } else if session.damagedTail { damagedFooter } else if chat.imported { importedFooter } else { ComposerInput(model: model, session: session, paneWidth: paneWidth) }
            // A side conversation repeats the whole status bar of the chat it
            // was opened from. In half a window that is two of everything; it
            // keeps the two figures that are its own.
            MetricsFooter(model: model, session: session, contextWindow: chat.contextWindow ?? profile?.contextWindow,
                          outputReserve: chat.maxOutputTokens ?? profile?.maxOutputTokens, compact: side != nil) { [model, id = session.id] in model.openInspector(session: id, focus: .overview) }
        }
        // The follow-up panel and the terminal slide in and out from the
        // bottom of the pane. Both take their room from below the
        // conversation, so the reader's row keeps its line on the screen at
        // every tick of the slide — it is the composer's own edge that moves.
        .piAnimation(PiMotion.base, value: session.queue.isEmpty)
        .piAnimation(PiMotion.base, value: model.terminalVisible)
        // Everything else about the pane — a chat switch, a disclosure, a
        // selection elsewhere in the window — reaches native layout as a
        // finished geometry, never as a spring frame.
        .piStableLayout()
        .background(Color.piContent)
        // HSplitView gives each pane its own native hosting surface. Remove
        // that surface's titlebar inset too, not only the outer window inset.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var quoteReplyAction: ((TranscriptQuote) -> Void)? {
        guard model.canQuoteReply(session.id) else { return nil }
        return { quote in model.openQuotedSide(parentID: session.id, quote: quote) }
    }

    /// Plain words for what the side shares; the identifiers stay in the tooltip.
    private var boundary: String {
        guard let side else { return "" }
        if side.pending { return "Draft side · takes the parent's context when you send your first message" }
        guard let cutoff = side.boundary["cutoffEntryId"]?.string else { return "Shares the parent's context as of when it opened" }
        let parent = model.displays[side.parentID]?.messages.first { $0.id == cutoff }
        let preview = parent.map { String($0.text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let upTo = preview.map { "up to “\($0.count > 60 ? String($0.prefix(59)) + "…" : $0)”" } ?? "as of when it opened"
        return "Shares the parent's context \(upTo)" + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : "")
    }
    private var boundaryDetail: String {
        guard let side else { return "" }
        return "Snapshot through \(side.boundary["cutoffEntryId"]?.string ?? "empty context") · \(Int(side.boundary["omittedIncompleteEntries"]?.number ?? 0)) incomplete entries omitted"
            + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : " · initial instruction snapshot")
    }
    /// The side pane keeps a slim header: its name, whether it is saved, what it shares, and its own controls.
    private var sideHeader: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                if let side {
                    HStack(spacing: 6) {
                        if side.kept { titleButton.font(PiFont.title(15)) }
                        else { Text("Side conversation").font(PiFont.title(15)).foregroundStyle(Color.piInk).fixedSize() }
                        if side.pending { PiBadge(text: "Created when you send", icon: "square.and.pencil").fixedSize() }
                        else { PiBadge(text: side.kept ? "Saved · Read-only" : "In memory", tone: side.kept ? .success : .warning, icon: "arrow.triangle.branch").fixedSize() }
                    }
                    Text(boundary).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail).help(boundaryDetail)
                }
            }
            Spacer(minLength: PiSpacing.sm)
            if let side, let sideActions {
                PiIconButton(symbol: "arrow.uturn.backward", label: "Bring Back to Parent Draft…") { sideActions.bringBack() }
                if !side.pending && !side.kept {
                    Button { sideActions.keep() } label: { Label(side.keeping ? "Keeping…" : side.keepRequested ? "Keep Requested" : "Keep", systemImage: "pin") }
                        .buttonStyle(.piSecondaryCompact).disabled(side.keeping || side.keepRequested || session.loading)
                }
                ConversationActionsMenu(model: model, session: session, chat: chat)
                PiIconButton(symbol: "xmark", label: "Close side", size: 26) { sideActions.close() }.disabled(side.keeping || session.loading)
            }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 8)
        .background(Color.piContent)
    }
    @ViewBuilder private var titleButton: some View {
        if chat.isBackgroundTask {
            Text(chat.title).foregroundStyle(Color.piInk).lineLimit(1)
        } else {
          Button { model.renameSession(chat.id) } label: {
            Text(chat.title).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
          }
        .buttonStyle(.plain).piPointer().help("Rename chat")
        .accessibilityLabel("Rename chat: " + chat.title).accessibilityIdentifier("renameSessionTitle")
        }
    }

    private var recoveredBanner: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.piWarning)
                Text("Interrupted submissions").font(PiFont.heading)
                Text("· Nothing was resent").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            ForEach(session.recovered, id: \.id) { intent in
                HStack {
                    Text(intent.text).lineLimit(1).font(PiFont.body)
                    Spacer()
                    Button("Insert in Draft") { model.recoverDraft(intent, insert: true) }.buttonStyle(.piSecondaryCompact)
                    Button("Dismiss") { model.recoverDraft(intent, insert: false) }.buttonStyle(.piGhost)
                }
            }
        }
        .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piWarning.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm)
    }

    private var queuePanel: some View {
        // The row being rewritten, and the text typed into it, belong to this
        // chat: the panel starts over when the reader goes to another one.
        QueuePanel(model: model, session: session)
            .id(session.id)
            .padding(.horizontal, PiSpacing.lg).padding(.bottom, PiSpacing.sm)
    }

    /// The chat's last record was cut off mid-write (a power loss, a full
    /// disk). Its file cannot be continued; a recovered copy can.
    private var damagedFooter: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.piWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last record incomplete · Read-only").font(PiFont.heading)
                Text("Recover Copy makes a new chat from every complete record. This chat's file stays as it is.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            Spacer()
            Button("Recover Copy") { model.recoverCopy(chat.id) }.buttonStyle(.piSecondaryCompact)
                .accessibilityIdentifier("recoverDamagedChat")
        }
        .padding(PiSpacing.md)
        .accessibilityElement(children: .contain).accessibilityLabel("Chat with an incomplete last record")
    }
    /// An archived chat is read-only until it is restored; nothing can run in it.
    private var archivedFooter: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "archivebox").foregroundStyle(Color.piInkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archived · Read-only").font(PiFont.heading)
                Text("Restore the chat to send messages, steer or resume its queue.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            Spacer()
            Button("Restore Chat") { model.toggleSessionArchive(chat.id) }.buttonStyle(.piSecondaryCompact)
                .accessibilityIdentifier("restoreArchivedChat")
        }
        .padding(PiSpacing.md)
        .accessibilityElement(children: .contain).accessibilityLabel("Archived chat")
    }
    private var importedFooter: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(Color.piInkSecondary)
                Text("Imported original · Read-only").font(PiFont.heading)
            }
            Text("A portable context draft starts a separate chat from its text; the imported file stays untouched.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            HStack(spacing: PiSpacing.sm) {
                PiDropdown(selection: $model.profileChoice, items: [("", "Choose Responses connection")] + model.requestProfiles.map { ($0.id, $0.name) }, placeholder: "Choose Responses connection", icon: "antenna.radiowaves.left.and.right")
                Button("Portable Context Draft…", action: model.portableHandoff).buttonStyle(.piPrimary)
                Spacer()
            }
        }
        .padding(PiSpacing.lg).piElevated()
        .padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }
}

/// The chat's actions, reachable from the composer bar (and the side header): the
/// conversation itself has no header bar.
///
/// The menu is built when it opens, from the chat as it is then. As a SwiftUI
/// `Menu` it observed the whole workspace and the session, and every snapshot
/// of a running turn rebuilt its twenty-odd items and re-sized its pop-up
/// button (see PiMenu.swift).
struct ConversationActionsMenu: View {
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    var body: some View {
        PiMenuControl(label: "Chat actions", identifier: "conversationActions", help: "Chat actions") { [model, session, chat] in
            ConversationActionsMenu.entries(model: model, session: session, chat: model.record(chat.id) ?? chat)
        } face: { hovering in
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(hovering ? Color.piInk : Color.piInkSecondary)
                .frame(width: 28, height: 28).background(hovering ? Color.piFillStrong : Color.piFill, in: Circle()).contentShape(Circle())
        }
        .frame(width: 28, height: 28)
    }

    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, session: SessionDisplay, chat: ChatRecord) -> [PiMenuEntry] {
        if !chat.isBackgroundTask {
            PiMenuEntry.button("Rename Chat…") { model.renameSession(chat.id) }
            if !chat.imported, !chat.isArchived {
                PiMenuEntry.button("Generate Title", enabled: model.titleSuggestionsAvailable(for: model.profiles.first { $0.id == chat.profileID } ?? ProfileRecord())) {
                    model.regenerateTitle(chat.id)
                }
            }
        }
        if !model.isEphemeral(session.id) {
            SessionOrganizationActions.entries(model: model, chat: chat)
            PiMenuEntry.divider
        }
        if model.side(session.id) == nil && !chat.isBackgroundTask {
            PiMenuEntry.button("Open Side", enabled: model.canOpenSide(session.id)) { model.openSide(parentID: session.id) }
            PiMenuEntry.button("Portable Context Handoff…") { model.portableHandoff() }
            if chat.toolMode == "read-only" && chat.connectionTest != true && chat.workspaceID != WorkspaceRecord.scratchID {
                PiMenuEntry.button("Enable Editing Tools…", enabled: !session.hasWork) { model.enableEditing(session.id) }
            }
            PiMenuEntry.divider
        }
        if !chat.isBackgroundTask { PiMenuEntry.button("Compact Now", identifier: "compactNow") { model.action("context.compact", sessionID: session.id) } }
        if session.before != nil || session.hostBefore != nil { PiMenuEntry.button("Earlier Messages") { model.loadEarlier(sessionID: session.id) } }
        PiMenuEntry.button("Latest Messages") { model.latest(sessionID: session.id) }
        PiMenuEntry.divider
        SessionReferenceActions.entries(model: model, sessionID: session.id)
        PiMenuEntry.divider
        PiMenuEntry.button("Search and Copy Conversation…") { model.inspectConversation(session.id) }
        PiMenuEntry.button("Session Inspector…", identifier: "sessionInspector") { model.inspect(session.id) }
        if model.side(session.id) == nil {
            PiMenuEntry.divider
            PiMenuEntry.button("Delete Chat…") { model.deleteChat(chat.id) }
        }
    }
}

/// The app mark with a soft pulse while a chat is being prepared and has nothing to show yet.
struct LoadingMark: View {
    @Environment(\.piReduceMotion) private var reduceMotion
    @State private var breathing = false
    var body: some View {
        VStack(spacing: PiSpacing.md) {
            Image("BelloAgentIcon").resizable().interpolation(.high).scaledToFit().frame(width: 56, height: 56)
                .scaleEffect(breathing && !reduceMotion ? 1.06 : 1).opacity(breathing && !reduceMotion ? 1 : 0.82)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
                .accessibilityLabel("Bello Agent")
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
        }
        .onAppear { breathing = true }
        .accessibilityIdentifier("loadingMark")
    }
}

/// What an empty chat is connected to, and where to start. Gone with the
/// first message — and it takes nothing of the chat with it: the card holds
/// the chat's id and reaches the model, never the page. A subtree SwiftUI has
/// taken off screen but that still has a button in it stays alive for as long
/// as the window's views do, so a card that held the page would keep that
/// chat's whole conversation, for the first chat of every window — the one
/// that is shown before it has any messages.
struct StarterPanel: View {
    @ObservedObject var model: WorkspaceModel
    let chat: ChatRecord
    let sessionID: String
    private var workspace: WorkspaceRecord? { model.workspace(for: chat.workspaceID) }
    private var profile: ProfileRecord? { model.profiles.first { $0.id == chat.profileID } }
    private var modelName: String { chat.model ?? profile?.modelId ?? "catalog default" }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack { Spacer(); Image("BelloAgentIcon").resizable().interpolation(.high).scaledToFit().frame(width: 48, height: 48).accessibilityLabel("Bello Agent"); Spacer() }
                .piStaggered(0)
            HStack(spacing: PiSpacing.sm) {
                PiIconBadge(symbol: "folder", tone: .accent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? chat.workspaceID).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1)
                    ForEach((workspace?.roots ?? []).prefix(4), id: \.self) { root in
                        Text(root).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .piStaggered(1)
            HStack(spacing: PiSpacing.sm) {
                PiBadge(text: profile?.name ?? "No connection", tone: profile == nil ? .danger : .neutral, icon: "antenna.radiowaves.left.and.right")
                PiBadge(text: modelName, icon: "cpu")
                PiBadge(text: chat.toolMode == "read-only" ? "Read-only tools" : "Editing tools", icon: chat.toolMode == "read-only" ? "eye" : "pencil")
            }
            .piStaggered(2)
            Text("Type below to start. Your first message creates the chat.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .piStaggered(3)
            PiFlow(spacing: PiSpacing.sm, rowSpacing: PiSpacing.sm) {
                if model.side(sessionID) == nil, chat.workspaceID != WorkspaceRecord.scratchID {
                    Button { model.showChanges(in: chat.workspaceID) } label: { Label("Changes", systemImage: "arrow.triangle.branch") }.buttonStyle(.piSecondaryCompact)
                    Button { model.toggleTerminal() } label: { Label("Terminal", systemImage: "terminal") }.buttonStyle(.piSecondaryCompact)
                }
                Button { model.inspectResources(sessionID) } label: { Label("Skills", systemImage: "command") }.buttonStyle(.piSecondaryCompact)
                if model.side(sessionID) == nil { Button { model.openSide(parentID: sessionID) } label: { Label("Open a side", systemImage: "arrow.triangle.branch") }.buttonStyle(.piSecondaryCompact).disabled(!model.canOpenSide(sessionID)) }
            }
            .piStaggered(4)
        }
        .padding(PiSpacing.lg).frame(maxWidth: 560, alignment: .leading)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .accessibilityIdentifier("starterPanel")
    }
}
