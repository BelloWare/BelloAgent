import SwiftUI

private struct WorkspaceCommandModelKey: FocusedValueKey { typealias Value = WorkspaceModel }
extension FocusedValues {
    var workspaceCommandModel: WorkspaceModel? {
        get { self[WorkspaceCommandModelKey.self] }
        set { self[WorkspaceCommandModelKey.self] = newValue }
    }
}

@main struct BelloAgentApplication: App {
    @StateObject private var updates = UpdateController()
    /// The test host never reads the reader's chats back.
    private static let restoresAtLaunch = ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1"
    /// Launching from its first frame: `restore()` opens the chat the reader
    /// had open, and the window shows nothing in its place until it does.
    @StateObject private var model = WorkspaceModel(launching: Self.restoresAtLaunch)
    @StateObject private var menuBar = MenuBarController()
    @FocusedValue(\.workspaceCommandModel) private var focusedModel
    @Environment(\.openWindow) private var openWindow
    private var commandModel: WorkspaceModel { focusedModel ?? model }
    @NSApplicationDelegateAdaptor(ApplicationLifecycle.self) private var lifecycle
    var body: some Scene {
        // One window: the menu bar item and the Dock reopen this window rather
        // than adding a second view of the same conversations.
        Window("Bello Agent", id: "main") {
            WorkspaceView(model: model)
                .onAppear {
                    lifecycle.model = model; updates.hasActiveWork = { model.hasActiveWork }
                    installMenuBar()
                    updates.acquireBarrier = { model.acquireUpdateBarrier() }
                    updates.prepareForInstall = { try await model.prepareForInstall() }
                    updates.releaseBarrier = { model.releaseUpdateBarrier() }
                    updates.reportFailure = { model.error = $0 }
                }
                .task { if Self.restoresAtLaunch { await model.restore() } }
                .onChange(of: model.configurationLoaded) { _, available in
                    updates.configure(automaticChecks: model.configuration.automaticUpdateChecks, configurationAvailable: available)
                }
                .onChange(of: model.configuration.automaticUpdateChecks) { _, enabled in
                    updates.configure(automaticChecks: enabled, configurationAvailable: model.configurationLoaded)
                }
                // How a finished turn reads is decided where a page is
                // planned, so the planner is told directly rather than through
                // the view tree; until the vault answers, nothing folds.
                .onChange(of: model.configuration.transcriptView) { _, _ in model.applyTranscriptDisplay() }
                .onChange(of: model.configurationLoaded) { _, _ in model.applyTranscriptDisplay() }
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) { Button("Check for Updates…", action: updates.checkForUpdates).disabled(!updates.canCheckForUpdates) }
            CommandGroup(replacing: .newItem) {
                Button("New Chat", action: commandModel.newChat).keyboardShortcut("n")
                    .disabled(commandModel.selectedWorkspaceID == nil)
                Button("Open Project…", action: commandModel.pickWorkspace).keyboardShortcut("o")
                Button("Import Pi Session…", action: commandModel.importChat)
                Button("Rename Chat…", action: commandModel.rename).disabled(!commandModel.conversationCommandsEnabled)
                Button("Delete Chat…", action: commandModel.deleteChat).disabled(!commandModel.conversationCommandsEnabled)
                Divider()
                // The row's own actions, on the chat with keyboard focus.
                // Until now they existed only under a right-click on a row.
                Button(commandModel.commandChat?.isArchived == true ? "Restore Chat" : "Archive Chat", action: commandModel.archiveCommandChat)
                    .disabled(commandModel.commandChat == nil)
                Button(commandModel.commandChat?.isPinned == true ? "Unpin Chat" : "Pin Chat", action: commandModel.pinCommandChat)
                    .disabled(commandModel.commandChat == nil)
                Menu("Move to Topic") {
                    Button("Project root") { commandModel.moveCommandChat(toTopic: nil) }
                    ForEach(commandModel.commandTopicChoices) { topic in
                        Button(topic.title) { commandModel.moveCommandChat(toTopic: topic.id) }
                    }
                }.disabled(commandModel.commandChat == nil || commandModel.commandChat?.workspaceID == WorkspaceRecord.scratchID)
                Button("Mark as Read", action: commandModel.markCommandChatRead).disabled(commandModel.commandChat == nil)
            }
            CommandGroup(after: .sidebar) {
                Button(commandModel.page == .report ? "Back to Chats" : "Usage Report") { commandModel.toggleReport() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Session Inspector…") { if let id = commandModel.focusedSessionID ?? commandModel.selectedID { commandModel.inspect(id) } }.keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled((commandModel.focusedSessionID ?? commandModel.selectedID).flatMap(commandModel.record) == nil)
                Button("Changes and History…") { commandModel.showChanges() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(commandModel.workspaces.isEmpty)
                Button(commandModel.terminalVisible ? "Hide Terminal" : "Show Terminal") { commandModel.toggleTerminal() }.keyboardShortcut("`", modifiers: .control).disabled(commandModel.selectedID == nil)
                Divider()
                Button("Next Chat") { commandModel.selectAdjacentChat(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Chat") { commandModel.selectAdjacentChat(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                // The sidebar boundary can be dragged; now it can also be typed.
                Button("Widen Sidebar") { WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                Button("Narrow Sidebar") { WindowChrome.adjustStoredSidebarWidth(by: -WindowChrome.widthStep) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            }
            CommandMenu("Conversation") {
                // The menu is rebuilt on every publish of the model: each fold
                // availability is read once per build, from the rows.
                let foldsTurns = commandModel.canFoldTurns, foldsResponses = commandModel.canFoldResponses
                // Return in the composer sends or queues; ⌘↩ sends or steers,
                // here and in the composer alike (`submitComposer`).
                Button("Send / Queue Follow-up") { commandModel.send() }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Open Side") { commandModel.openSide() }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Send / Steer Current Run") { commandModel.submitFocusedComposer(intent: .steer) }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!commandModel.conversationCommandsEnabled)
                Button("Stop") { commandModel.stop(sessionID: commandModel.focusedSessionID) }.keyboardShortcut(".")
                Button("Resume Follow-ups") { commandModel.action("queue.resume", sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Compact Now") { commandModel.action("context.compact", sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Latest Messages") { commandModel.latest(sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Divider()
                // Folding a turn was a click on its chevron and nothing else.
                Button("Fold This Turn") { commandModel.setFocusedTurnFolded(true) }
                    .keyboardShortcut("[", modifiers: [.command, .option]).disabled(!foldsTurns)
                Button("Unfold This Turn") { commandModel.setFocusedTurnFolded(false) }
                    .keyboardShortcut("]", modifiers: [.command, .option]).disabled(!foldsTurns)
                Button("Fold Every Turn") { commandModel.setEveryTurnFolded(true) }
                    .keyboardShortcut("[", modifiers: [.command, .option, .shift]).disabled(!foldsTurns)
                Button("Unfold Every Turn") { commandModel.setEveryTurnFolded(false) }
                    .keyboardShortcut("]", modifiers: [.command, .option, .shift]).disabled(!foldsTurns)
                // One more level: the response itself reads as one line.
                Button("Fold This Response to One Line") { commandModel.setFocusedResponseCollapsed(true) }
                    .disabled(!foldsResponses)
                Button("Show This Response") { commandModel.setFocusedResponseCollapsed(false) }
                    .disabled(!foldsResponses)
                Divider()
                Button("Search and Copy Conversation…") { if let id = commandModel.focusedSessionID ?? commandModel.selectedID { commandModel.inspectConversation(id) } }.keyboardShortcut("f").disabled(!commandModel.conversationCommandsEnabled)
            }
        }
        Settings { ProfileSettings(model: model, windowChrome: true).frame(width: 760, height: 780) }
    }
    private func installMenuBar() {
        // The App owns this controller, so closing the last workspace window
        // leaves the same status item and shared model available for recovery.
        // XCTest installs this controller with its isolated fixture model.
        guard ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1" else { return }
        menuBar.install {
                MenuBarMetricsView(load: { period, until, offset in
                    try await model.ensureConfiguration()
                    return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset)
                }, scopedLoad: { period, until, offset, from, workspace in
                    try await model.ensureConfiguration()
                    return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset, from: from, workspaceID: workspace)
                }, projects: { model.workspaces.map { MonitorProject(id: $0.id, title: URL(fileURLWithPath: $0.path).lastPathComponent) } },
                   activity: { model.menuBarActivity() },
                   activityChanges: { model.menuBarActivityChanges },
                   live: model.liveActivity,
                   openApp: revealWorkspace,
                   openReport: { revealWorkspace(); model.openReport() },
                   openSession: { id in
                       revealWorkspace()
                       Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
                   })
        }
    }
    private func revealWorkspace() {
        menuBar.close()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
