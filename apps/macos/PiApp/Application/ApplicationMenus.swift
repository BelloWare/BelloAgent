import AppKit

/// Native menus read their current titles and availability as they open.
/// Conversation shortcuts belong to the workspace window that owns the chat.
@MainActor final class ApplicationMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let model: WorkspaceModel
    private let updates: UpdateController
    private let workspaceWindow: () -> NSWindow?
    private let revealWorkspace: () -> Void
    private let showSettings: () -> Void
    private var commands: [ObjectIdentifier: Command] = [:]
    private var topicsMenu: NSMenu?
    private var topicCommands: Set<ObjectIdentifier> = []
    private struct Command {
        let title: () -> String
        let enabled: () -> Bool
        let action: () -> Void
    }
    init(model: WorkspaceModel, updates: UpdateController, workspaceWindow: @escaping () -> NSWindow?,
         revealWorkspace: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.model = model; self.updates = updates; self.workspaceWindow = workspaceWindow
        self.revealWorkspace = revealWorkspace; self.showSettings = showSettings
        super.init()
    }
    var conversationCommands: Bool {
        NSApp.keyWindow != nil && NSApp.keyWindow === workspaceWindow() && model.conversationCommandsEnabled
    }
    private func command(_ menu: NSMenu, title: @escaping () -> String, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, enabled: @escaping () -> Bool = { true },
                         action: @escaping () -> Void) {
        let item = NSMenuItem(title: title(), action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = self
        commands[ObjectIdentifier(item)] = Command(title: title, enabled: enabled, action: action)
        menu.addItem(item)
    }
    private func command(_ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                         enabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        command(menu, title: { title }, key: key, modifiers: modifiers, enabled: enabled, action: action)
    }
    private func system(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "",
                        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = target
        menu.addItem(item)
    }
    @objc private func run(_ item: NSMenuItem) {
        guard let command = commands[ObjectIdentifier(item)], command.enabled() else { return }
        command.action()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = commands[ObjectIdentifier(item)] else { return true }
        item.title = command.title()
        return command.enabled()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === topicsMenu { rebuildTopics(menu) }
        for item in menu.items {
            if let command = commands[ObjectIdentifier(item)] { item.title = command.title(); item.isEnabled = command.enabled() }
        }
    }
    private func rebuildTopics(_ menu: NSMenu) {
        for identity in topicCommands { commands.removeValue(forKey: identity) }
        topicCommands.removeAll(); menu.removeAllItems()
        command(menu, "Project root", enabled: { [weak self] in self?.canMoveTopic ?? false }) { [model] in model.moveCommandChat(toTopic: nil) }
        for topic in model.commandTopicChoices {
            command(menu, topic.title, enabled: { [weak self] in self?.canMoveTopic ?? false }) { [model] in model.moveCommandChat(toTopic: topic.id) }
        }
        topicCommands = Set(menu.items.map(ObjectIdentifier.init))
    }
    private var canMoveTopic: Bool { model.commandChat != nil && model.commandChat?.workspaceID != WorkspaceRecord.scratchID }

    func install() {
        let main = NSMenu(title: "Main Menu")
        func menu(_ title: String) -> NSMenu {
            let value = NSMenu(title: title); value.delegate = self
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = value
            main.addItem(item)
            return value
        }
        let app = menu("Bello Agent")
        system(app, "About Bello Agent", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        command(app, "Check for Updates…", enabled: { [updates] in updates.canCheckForUpdates }, action: updates.checkForUpdates)
        app.addItem(.separator())
        command(app, "Settings…", key: ",", action: showSettings)
        app.addItem(.separator())
        let services = NSMenu(title: "Services"), servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        system(app, "Hide Bello Agent", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        system(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp)
        system(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        system(app, "Quit Bello Agent", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        let file = menu("File")
        command(file, "New Chat", key: "n", enabled: { [model] in model.selectedWorkspaceID != nil }, action: model.newChat)
        command(file, "Open Project…", key: "o", action: model.pickWorkspace)
        command(file, "Open File…", key: "p", enabled: { [model] in model.canQuickOpen }) { [model] in model.showQuickOpen(in: NSApp.keyWindow) }
        command(file, "Import Pi Session…", action: model.importChat)
        command(file, "Rename Chat…", enabled: { [model] in model.conversationCommandsEnabled }, action: model.rename)
        command(file, "Delete Chat…", enabled: { [model] in model.conversationCommandsEnabled }, action: model.deleteChat)
        file.addItem(.separator())
        command(file, title: { [model] in model.commandChat?.isArchived == true ? "Restore Chat" : "Archive Chat" },
                enabled: { [model] in model.commandChat != nil }, action: model.archiveCommandChat)
        command(file, title: { [model] in model.commandChat?.isPinned == true ? "Unpin Chat" : "Pin Chat" },
                enabled: { [model] in model.commandChat != nil }, action: model.pinCommandChat)
        let topics = NSMenu(title: "Move to Topic"); topics.delegate = self; topicsMenu = topics
        let topicItem = NSMenuItem(title: "Move to Topic", action: #selector(run(_:)), keyEquivalent: "")
        topicItem.target = self; topicItem.submenu = topics
        commands[ObjectIdentifier(topicItem)] = Command(title: { "Move to Topic" }, enabled: { [weak self] in self?.canMoveTopic ?? false }, action: {})
        file.addItem(topicItem)
        rebuildTopics(topics)
        command(file, "Mark as Read", enabled: { [model] in model.commandChat != nil }, action: model.markCommandChatRead)
        command(file, "Mark as Unread", enabled: { [model] in model.commandChat.map { model.canMarkSessionUnread($0.id) } ?? false },
                action: model.markCommandChatUnread)
        file.addItem(.separator())
        system(file, "Close Window", #selector(NSWindow.performClose(_:)), key: "w")

        let edit = menu("Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                      ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            system(edit, title, selector, key: key)
            if title == "Redo" { edit.items.last?.keyEquivalentModifierMask = [.command, .shift] }
        }
        let view = menu("View")
        command(view, title: { [model] in model.page == .report ? "Back to Chats" : "Usage Report" }, key: "r", modifiers: [.command, .shift], action: model.toggleReport)
        command(view, title: { [model] in model.page == .background ? "Back to Chats" : "Background Requests" }, key: "b", modifiers: [.command, .shift], action: model.toggleBackgroundRequests)
        command(view, title: { [model] in model.sidebarShowsArchived ? "Hide Archived Chats" : "Show Archived Chats" }, action: model.toggleArchivedChats)
        command(view, "Session Inspector…", key: "i", modifiers: [.command, .option],
                enabled: { [model] in !model.presentsSheet && (model.focusedSessionID ?? model.selectedID).flatMap(model.record) != nil }) { [model] in
            if let id = model.focusedSessionID ?? model.selectedID { model.inspect(id) }
        }
        command(view, "Changes and History…", key: "g", modifiers: [.command, .shift], enabled: { [model] in !model.workspaces.isEmpty && !model.presentsSheet }) { [weak self, model] in
            if model.showChanges()?.container?.isPane == true { self?.revealWorkspace() }
        }
        command(view, title: { [model] in model.terminalVisible ? "Hide Terminal" : "Show Terminal" }, key: "`", modifiers: .control,
                enabled: { [model] in model.selectedID != nil }, action: model.toggleTerminal)
        view.addItem(.separator())
        command(view, "Next Chat", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command, .option]) { [model] in model.selectAdjacentChat(1) }
        command(view, "Previous Chat", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .option]) { [model] in model.selectAdjacentChat(-1) }
        view.addItem(.separator())
        command(view, "Widen Sidebar", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .control]) { WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep) }
        command(view, "Narrow Sidebar", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .control]) { WindowChrome.adjustStoredSidebarWidth(by: -WindowChrome.widthStep) }

        let conversation = menu("Conversation")
        let active = { [weak self] in self?.conversationCommands ?? false }
        command(conversation, "Send / Queue Follow-up", enabled: active, action: { [model] in model.send() })
        command(conversation, "Open Side", enabled: active, action: { [model] in model.openSide() })
        command(conversation, "Send / Steer Current Run", key: "\r", enabled: active) { [model] in model.submitFocusedComposer(intent: .steer) }
        command(conversation, "Stop", key: ".", enabled: active, action: { [model] in model.stopFocused() })
        command(conversation, "Resume Follow-ups", enabled: active) { [model] in model.action("queue.resume", sessionID: model.focusedSessionID) }
        command(conversation, "Compact Now", enabled: active) { [model] in model.action("context.compact", sessionID: model.focusedSessionID) }
        command(conversation, "Latest Messages", enabled: active) { [model] in model.latest(sessionID: model.focusedSessionID) }
        conversation.addItem(.separator())
        command(conversation, "Fold This Turn", key: "[", modifiers: [.command, .option], enabled: { [model] in model.canFoldTurns }) { [model] in model.setFocusedTurnFolded(true) }
        command(conversation, "Unfold This Turn", key: "]", modifiers: [.command, .option], enabled: { [model] in model.canFoldTurns }) { [model] in model.setFocusedTurnFolded(false) }
        command(conversation, "Fold Every Turn", key: "[", modifiers: [.command, .option, .shift], enabled: { [model] in model.canFoldTurns }) { [model] in model.setEveryTurnFolded(true) }
        command(conversation, "Unfold Every Turn", key: "]", modifiers: [.command, .option, .shift], enabled: { [model] in model.canFoldTurns }) { [model] in model.setEveryTurnFolded(false) }
        command(conversation, "Fold This Response to One Line", enabled: { [model] in model.canFoldResponses }) { [model] in model.setFocusedResponseCollapsed(true) }
        command(conversation, "Show This Response", enabled: { [model] in model.canFoldResponses }) { [model] in model.setFocusedResponseCollapsed(false) }
        conversation.addItem(.separator())
        command(conversation, "Search and Copy Conversation…", key: "f", enabled: active, action: { [model] in model.searchFocusedConversation() })

        let window = menu("Window")
        system(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        system(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        system(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
