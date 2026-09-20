import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.piReduceMotion) private var reduceMotion
    /// The sidebar keeps the width the user last dragged it to.
    @AppStorage("sidebarWidth") private var storedSidebarWidth: Double = Double(WindowChrome.sidebarWidth)
    @State private var draggingSidebarWidth: CGFloat?
    private var sidebarWidth: CGFloat { draggingSidebarWidth ?? WindowChrome.clampSidebarWidth(CGFloat(storedSidebarWidth)) }
    /// Where the boundary between a chat and its open side sits, kept across
    /// launches. A fixed half-and-half split gave a side conversation the same
    /// room as the chat it was asked about, and could not be changed.
    @AppStorage("sidePaneFraction") private var storedSideFraction: Double = SplitPane.defaultFraction
    @State private var draggingSideFraction: Double?
    @State private var splitDragStart: Double?
    private var sideFraction: Double { SplitPane.clampFraction(draggingSideFraction ?? storedSideFraction) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WindowChrome(sidebarWidth: sidebarWidth, focusedSessionID: model.focusedSessionID ?? model.selectedID).frame(height: WindowChrome.height)
                WorkspaceSidebar(model: model, width: sidebarWidth)
            }.frame(width: sidebarWidth)
            SidebarResizeHandle(width: sidebarWidth, dragging: $draggingSidebarWidth) { storedSidebarWidth = Double($0) }
            // Errors used to be an overlay on the whole window: they covered
            // the first line of the conversation and floated over the sidebar.
            // Above the content column instead, the strip takes room from the
            // conversation and pushes it down rather than hiding its top row.
            // (A `safeAreaInset` would have been undone by the pane's own
            // `ignoresSafeArea(.container, edges: .top)`, which is there to
            // clear the titlebar; a column is what actually holds.)
            VStack(spacing: 0) {
              errorStrip
              GeometryReader { region in
              ZStack {
                Group {
                    if let session = model.selected, let chat = model.chat {
                        // A shown side takes the share of the column the
                        // reader last dragged the divider to.
                        let shownSide = model.sides[chat.id].flatMap { side in model.displays[side.id].map { (side, $0) } }
                        let mainWidth = shownSide == nil ? region.size.width : SplitPane.mainWidth(total: region.size.width, fraction: sideFraction)
                        HStack(spacing: 0) {
                            ConversationPane(model: model, session: session, chat: chat, paneWidth: mainWidth)
                                .frame(width: mainWidth)
                                // The pane itself is kept across chats: giving it the
                                // chat's identity threw away the transcript's document
                                // and every row host on every click in the sidebar,
                                // which is most of what a chat switch used to cost.
                                // The parts that hold a chat's own typing state carry
                                // the identity instead (see `queuePanel`), and the
                                // draft, focus and live bar follow the session.
                                // A fade of the arriving chat was tried and taken out
                                // again: inside an animated transaction the new chat's
                                // rows took 34 drawn frames and a second to appear
                                // instead of one frame.
                                .transition(.identity)
                            if let shown = shownSide {
                                splitDivider(total: region.size.width)
                                let sideWidth = SplitPane.sideWidth(total: region.size.width, fraction: sideFraction)
                                SidePane(model: model, session: shown.1, info: shown.0, paneWidth: sideWidth).id(shown.0.id)
                                    .frame(width: sideWidth)
                                    .transition(.identity)
                            }
                        }
                        // Width changes reflow native text and restore scroll anchors.
                        // Apply the final geometry once instead of once per spring frame.
                        .piStableLayout()
                    } else if OnboardingState.shouldPresent(configurationLoaded: model.configurationLoaded, hasProfiles: !model.requestProfiles.isEmpty, hasChats: !model.chats.isEmpty) {
                        OnboardingView(model: model)
                    } else {
                        WorkspaceWelcome(model: model)
                    }
                }
                // A hidden split pane must not contribute its combined column
                // minima to the report's available width on a small window.
                .frame(width: region.size.width, height: region.size.height)
                // The chat pane stays mounted (transcript, scroll, drafts and any
                // running generation survive) while the report covers it.
                .opacity(model.page == .chats ? 1 : 0)
                .allowsHitTesting(model.page == .chats)
                .disabled(model.page != .chats)
                .accessibilityHidden(model.page != .chats)
                if model.page == .report {
                    ReportPage(model: model)
                        .transition(.identity)
                        .zIndex(1)
                }
              }
              .frame(width: region.size.width, height: region.size.height)
              .clipped()
              }
            }
            .background(Color.piContent)
        }
        .ignoresSafeArea(.container, edges: .top)
        .buttonStyle(.piSecondary)
        .toggleStyle(.switch)
        .background(Color.piWindow)
        .focusedSceneValue(\.workspaceCommandModel, model)
        .sheet(isPresented: $model.showProfiles) { ProfileSettings(model: model).frame(width: 760, height: 780) }
        .sheet(isPresented: $model.showInspector) { if let id = model.inspectorSessionID ?? model.selectedID { InspectorView(model: model, sessionID: id, messageID: model.inspectorMessageID) } }
        .sheet(isPresented: $model.showMessageViewer) { RetainedMessageViewer(model: model) }
        .sheet(isPresented: $model.showMessageDetail) { if let id = model.messageDetailSessionID, let messageID = model.messageDetailID { MessageDetailView(model: model, sessionID: id, messageID: messageID) } }
        .sheet(isPresented: $model.showConversationContent) { if let id = model.contentSessionID { ConversationContentView(model: model, sessionID: id) } }
        .sheet(isPresented: $model.showResources) { ResourceInspector(model: model) }
        .sheet(isPresented: $model.showWorkspaceManager) { WorkspaceManagerView(model: model) }
        .sheet(item: $model.renameTarget) { target in RenameChatSheet(model: model, chatID: target.id) }
        .sheet(item: $model.topicEditor) { target in TopicSheet(model: model, target: target) }
        .sheet(isPresented: $model.showGit) {
            if let project = model.workspaces.first(where: { $0.id == (model.gitWorkspaceID ?? model.selectedWorkspaceID) }) { GitPanelView(model: model, roots: project.roots) }
        }
        .frame(minWidth: 920, minHeight: 600)
        .background(WindowActivityGuard(model: model))
        .background(ConversationPageVisibility(reportVisible: model.page == .report, focusIdentity: model.focusedSessionID, closeReport: model.closeReport))
        .disabled(model.installPreparing)
        .overlay {
            if model.installPreparing {
                HStack(spacing: PiSpacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Saving drafts and preparing to close…").font(PiFont.body)
                }.padding(20).piElevated()
            }
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// Errors used to be a modal alert: a background save failure interrupted
    /// typing with the same weight as a failed send, and the text vanished on
    /// OK. The strip stays until dismissed and never steals focus.
    @ViewBuilder private var errorStrip: some View {
        ZStack {
            if let error = model.error {
                ErrorBanner(text: error) { model.error = nil }
                    .padding(.horizontal, PiSpacing.xl).padding(.top, PiSpacing.md).padding(.bottom, PiSpacing.sm)
                    .transition(PiMotion.reveal)
            }
        }
        // The strip comes down over the top of the column and takes its room
        // as it comes. It animates the real layout, not an overlay, so the
        // conversation sees a size change on every tick of the slide and
        // keeps the reader's row on its own line through all of them.
        .piAnimation(PiMotion.base, value: model.error != nil)
    }

    /// The boundary between a chat and its open side: the same visible grip as
    /// the sidebar's and the terminal's, and the fraction it lands on is kept.
    private func splitDivider(total: CGFloat) -> some View {
        PiResizeHandle(orientation: .vertical, label: "Resize the side conversation",
                       hint: "Drag left or right; the split stays between 30 and 70 per cent",
                       dragging: draggingSideFraction != nil,
                       changed: { translation in
                           let base = splitDragStart ?? sideFraction
                           if splitDragStart == nil { splitDragStart = sideFraction }
                           draggingSideFraction = SplitPane.clampFraction(base + Double(translation / max(1, total)))
                       },
                       ended: { translation in
                           let base = splitDragStart ?? sideFraction
                           let landed = SplitPane.clampFraction(base + Double(translation / max(1, total)))
                           splitDragStart = nil; draggingSideFraction = nil; storedSideFraction = landed
                       })
    }
}

/// Where the boundary between an open chat and its side conversation sits, as
/// the chat's share of the content column. Bounded so neither pane can be
/// squeezed to a sliver, and rounded to whole points so the two panes plus
/// their divider always add up to the column exactly.
enum SplitPane {
    static let defaultFraction = 0.5
    static let minimumFraction = 0.30
    static let maximumFraction = 0.70
    static let dividerWidth: CGFloat = 1
    static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFraction }
        return min(maximumFraction, max(minimumFraction, value))
    }
    static func mainWidth(total: CGFloat, fraction: Double) -> CGFloat {
        guard total.isFinite, total > dividerWidth + 2 else { return max(0, total - dividerWidth) }
        let usable = total - dividerWidth
        return min(usable - 1, max(1, (usable * CGFloat(clampFraction(fraction))).rounded(.down)))
    }
    static func sideWidth(total: CGFloat, fraction: Double) -> CGFloat {
        max(0, total - dividerWidth - mainWidth(total: total, fraction: fraction))
    }
}

/// Non-modal error strip at the top of the window. A gateway can return
/// kilobytes of explanation, so the strip stays three lines tall until it is
/// opened, then scrolls inside a bounded box; Copy takes the whole message
/// whether it is open or not.
struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    /// Where Copy writes; a test passes its own rather than the owner's clipboard.
    var pasteboard: NSPasteboard = .general
    @State private var expanded: Bool
    init(text: String, pasteboard: NSPasteboard = .general, expanded: Bool = false, dismiss: @escaping () -> Void) {
        self.text = text; self.pasteboard = pasteboard; self.dismiss = dismiss
        _expanded = State(initialValue: expanded)
    }
    /// Longer than this and the strip offers to open; the figure is about three
    /// lines at the strip's width.
    static let collapsedCharacters = 220
    static let expandedHeight: CGFloat = 220
    var canExpand: Bool { text.count > Self.collapsedCharacters || text.contains("\n") }
    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piDanger).padding(.top, 2)
            message
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: 2) {
                if canExpand {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.piGhost)
                        .accessibilityIdentifier("errorBannerExpand")
                }
                Button("Copy") { Self.copy(text, to: pasteboard) }.buttonStyle(.piGhost)
                    .accessibilityIdentifier("errorBannerCopy")
                Button("Dismiss", action: dismiss).buttonStyle(.piSecondaryCompact)
                    .accessibilityIdentifier("errorBannerDismiss")
            }.fixedSize()
        }
        .padding(.leading, PiSpacing.md).padding(.trailing, 4).padding(.vertical, PiSpacing.sm)
        .frame(maxWidth: 640)
        // A wash of the danger colour over the surface, so the strip reads as
        // a failure at the same strength in both appearances; a plain surface
        // with a faint outline all but disappeared against a dark canvas.
        .background(Color.piDanger.opacity(0.10), in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piDanger.opacity(0.55), lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: " + text)
        .accessibilityIdentifier("errorBanner")
    }
    @ViewBuilder private var message: some View {
        let body = Text(text).font(PiFont.body).foregroundStyle(Color.piInk).textSelection(.enabled)
        // A strip left open by one error must not open a short one that follows.
        if expanded && canExpand {
            ScrollView { body.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: Self.expandedHeight)
                .accessibilityIdentifier("errorBannerText")
        } else {
            body.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("errorBannerText")
        }
    }
}

private struct WorkspaceWelcome: View {
    @ObservedObject var model: WorkspaceModel
    /// The project a new chat would start in: the chosen one, else the first trusted one.
    private var readyWorkspace: WorkspaceRecord? {
        model.workspaces.first { $0.id == model.selectedWorkspaceID && $0.trusted } ?? model.workspaces.first(where: \.trusted)
    }
    private var ready: Bool { readyWorkspace != nil && !model.requestProfiles.isEmpty }
    var body: some View {
        VStack(spacing: PiSpacing.lg) {
            Image("BelloAgentIcon")
                .resizable().interpolation(.high).frame(width: 84, height: 84)
                .accessibilityLabel("Bello Agent")
            VStack(spacing: 8) {
                Text("What are we working on?").font(PiFont.display(30)).foregroundStyle(Color.piInk)
                Text(ready ? "Start a new chat in \(readyWorkspace.map(WorkspaceLabel.name) ?? "your project"), or pick a chat in the sidebar.\nSide conversations, exact HTTP inspection and cost accounting are built in."
                     : "Create a project from one or more trusted folders and connect a LiteLLM route to start a chat.\nSide conversations, exact HTTP inspection and cost accounting are built in.")
                    .font(PiFont.body).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 460)
            }
            HStack(spacing: PiSpacing.md) {
                if ready, let workspace = readyWorkspace {
                    // Both halves exist: the next step is a chat, not another setup sheet.
                    Button { model.newChat(in: workspace.id) } label: { Label("New Chat", systemImage: "square.and.pencil") }.buttonStyle(.piPrimary)
                        .accessibilityIdentifier("welcome-new-chat")
                    Button { model.showWorkspaceManager = true } label: { Label("Projects…", systemImage: "folder") }.buttonStyle(.piSecondary)
                    Button { model.showProfiles = true } label: { Label("Connections…", systemImage: "slider.horizontal.3") }.buttonStyle(.piSecondary)
                } else {
                    Button { model.showWorkspaceManager = true } label: { Label(model.workspaces.isEmpty ? "Create a project" : "Projects…", systemImage: "folder") }.buttonStyle(.piPrimary)
                    Button { model.showProfiles = true } label: { Label(model.requestProfiles.isEmpty ? "Add a Connection…" : "Connections…", systemImage: "slider.horizontal.3") }.buttonStyle(.piSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.piContent)
    }
}
