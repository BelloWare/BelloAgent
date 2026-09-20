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
    @StateObject private var model = WorkspaceModel()
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
                .task { if ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1" { await model.restore() } }
                .onChange(of: model.configurationLoaded) { _, available in
                    updates.configure(automaticChecks: model.configuration.automaticUpdateChecks, configurationAvailable: available)
                }
                .onChange(of: model.configuration.automaticUpdateChecks) { _, enabled in
                    updates.configure(automaticChecks: enabled, configurationAvailable: model.configurationLoaded)
                }
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
                Button("Current-session Inspector…") { if let id = commandModel.focusedSessionID ?? commandModel.selectedID { commandModel.inspect(id) } }.keyboardShortcut("i", modifiers: [.command, .option])
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
                Button("Send / Queue Follow-up") { commandModel.send() }.keyboardShortcut(.return, modifiers: .command).disabled(!commandModel.conversationCommandsEnabled)
                Button("Open Side") { commandModel.openSide() }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Steer Current Run") { commandModel.send(steer: true) }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Stop") { commandModel.stop(sessionID: commandModel.focusedSessionID) }.keyboardShortcut(".")
                Button("Resume Follow-ups") { commandModel.action("queue.resume", sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Compact Now") { commandModel.action("context.compact", sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Button("Latest Messages") { commandModel.latest(sessionID: commandModel.focusedSessionID) }.disabled(!commandModel.conversationCommandsEnabled)
                Divider()
                // Folding a turn was a click on its chevron and nothing else.
                Button("Fold This Turn") { commandModel.setFocusedTurnFolded(true) }
                    .keyboardShortcut("[", modifiers: [.command, .option]).disabled(!commandModel.canFoldTurns)
                Button("Unfold This Turn") { commandModel.setFocusedTurnFolded(false) }
                    .keyboardShortcut("]", modifiers: [.command, .option]).disabled(!commandModel.canFoldTurns)
                Button("Fold Every Turn") { commandModel.setEveryTurnFolded(true) }
                    .keyboardShortcut("[", modifiers: [.command, .option, .shift]).disabled(!commandModel.canFoldTurns)
                Button("Unfold Every Turn") { commandModel.setEveryTurnFolded(false) }
                    .keyboardShortcut("]", modifiers: [.command, .option, .shift]).disabled(!commandModel.canFoldTurns)
                Divider()
                Button("View Retained Message…") { if let id = commandModel.focusedSessionID ?? commandModel.selectedID { commandModel.viewMessages(id) } }.disabled(!commandModel.conversationCommandsEnabled)
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
            VStack(spacing: 0) {
                MenuBarMetricsView(load: { period, until, offset in
                    try await model.ensureConfiguration()
                    return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset)
                }, activity: { model.menuBarActivity() },
                   activityChanges: { model.menuBarActivityChanges },
                   openApp: revealWorkspace,
                   openReport: { revealWorkspace(); model.openReport() },
                   openSession: { id in
                       revealWorkspace()
                       Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
                   })
                Divider()
                HStack {
                    Spacer()
                    Button("Quit Bello Agent") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.piGhost)
                        .accessibilityIdentifier("menu-bar-quit")
                }.padding(.horizontal, PiSpacing.md).padding(.vertical, PiSpacing.xs)
            }
            .frame(width: 428)
            .background(Color.piContent)
        }
    }
    private func revealWorkspace() {
        menuBar.close()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
