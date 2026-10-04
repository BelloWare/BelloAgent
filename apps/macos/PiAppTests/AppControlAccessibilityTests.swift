import AppKit
import SwiftUI
import XCTest
import Combine
import FileView
@testable import GitView
@testable import PiApp

/// The app's own screens as VoiceOver reads them (`PiControlAccessibilityTests`
/// for how the tree is read): Settings' switches, steppers, dropdowns and
/// sections; the terminal tabs and their actions; the commit box's scope; the
/// queue's rows; and the blame bar.
@MainActor final class AppControlAccessibilityTests: XCTestCase {
    private var assistive = false
    override func setUp() async throws { assistive = HostedAccessibility.begin() }
    override func tearDown() async throws { HostedAccessibility.end(restoring: assistive) }

    func testSettingsNamesItsSwitchesSteppersDropdownsAndUnsavedSections() async throws {
        let root = scratchRoot("a11y-settings")
        let (model, _, _, _) = try ConversationPaneTests.workbench(root: root, chats: ["main"])
        registerWorkspaceFixtureTeardown(model, root: root)
        let controller = ConnectionSettingsController(model: model)
        model.settingsSection = .app
        let window = try await hostedWindow(ProfileSettings(model: model, controller: controller, windowChrome: false), width: 880, height: 780)
        let updates = try await AXClient.find(in: window) { $0.label == "Check for app updates automatically" }
        var all = try await AXClient.all(in: window)
        XCTAssertTrue(["AXCheckBox", "AXSwitch"].contains(updates.role), updates.role)
        let grace = controller.preferences.runtime.idleGraceSeconds
        let decrease = try XCTUnwrap(all.first { $0.label == "Decrease Idle helper grace" }, labels(all))
        XCTAssertEqual(decrease.value, "\(grace) seconds")
        XCTAssertEqual(decrease.help, "From 10 to 600 seconds, in steps of 10")
        XCTAssertTrue(all.contains { $0.label == "Increase Idle helper grace" })
        let app = try XCTUnwrap(all.first { $0.role == "AXButton" && $0.label == "App" }, labels(all))
        XCTAssertTrue(app.selected, "the open section is selected")
        XCTAssertEqual(app.value, "")

        controller.preferences.runtime.idleGraceSeconds = grace == 600 ? 590 : grace + 10
        _ = try await AXClient.find(in: window, "the edited section says so") { $0.role == "AXButton" && $0.label == "App" && $0.value == "Unsaved changes" }

        model.settingsSection = .connections
        _ = try await AXClient.find(in: window, "the connection section") { $0.label == "Output budget, tokens" }
        all = try await AXClient.all(in: window)
        for name in ["Configured context capacity, tokens", "Output budget, tokens", "Actual model header", "Deployment ID header",
                     "Route group header", "Cache hit/miss header", "Reasoning continuation policy"] {
            XCTAssertEqual(all.filter { $0.label == name }.count, 1, "\(name) is named once: \(labels(all))")
        }
        XCTAssertEqual(all.first { $0.label == "Output budget, tokens" }?.role, "AXTextField")
        XCTAssertFalse(all.contains { $0.label == "Tokens" || $0.label == "optional" }, "no field is named by its placeholder alone")

        model.settingsSection = .usage
        _ = try await AXClient.find(in: window, "the usage section") { $0.label == "Decrease Body retention" }
        all = try await AXClient.all(in: window)
        let capture = try XCTUnwrap(all.first { $0.label == "Default future body capture" && $0.role == "AXButton" }, labels(all))
        XCTAssertFalse(capture.value.isEmpty, "the dropdown reads its choice as its value")
        XCTAssertEqual(all.first { $0.label == "Decrease Metric retention" }?.value, "\(controller.preferences.dashboard.metricRetentionDays) days")
        XCTAssertEqual(all.filter { $0.label == "Decrease" || $0.label == "Increase" }.count, 0, "no bare stepper names are left")
    }

    func testTerminalTabsAreANamedGroupAndTheirActionsNameTheTerminal() async throws {
        let registry = TerminalRegistry.shared
        registry.shutdown()
        let folder = scratchRoot("a11y-terminals")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "a11y-" + UUID().uuidString, path: folder.path, trusted: true)
        // Registered first, so it runs last: after the model's stores close.
        addTeardownBlock { @MainActor in registry.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let model = makeWorkspaceModel(stateRoot: folder.appendingPathComponent("state"))
        let window = try await hostedWindow(TerminalPanel(model: model, workspace: project), width: 920, height: 420)
        try await eventually("Terminal 1 opened") { registry.selected(for: project.id) != nil }
        let two = registry.create(for: project)
        registry.select(two.id, in: project.id)
        let name = "Terminals in " + folder.lastPathComponent
        let tabs = try await AXClient.find(in: window, "the tabs as one named group") { $0.label == name && $0.children.count == 2 }
        let all = try await AXClient.all(in: window)
        XCTAssertEqual(tabs.children.map(\.label), ["Terminal 1", "Terminal 2"])
        XCTAssertEqual(tabs.children.map(\.selected), [false, true])
        for action in ["Rename", "Restart", "Close"] {
            let button = try XCTUnwrap(all.first { $0.label == action + " Terminal 2" }, labels(all))
            XCTAssertEqual(button.role, "AXButton")
        }
        XCTAssertTrue(all.contains { $0.label == "New terminal" })
        // The shell's own text area says which terminal it is.
        let shell = try await AXClient.find(in: window, "the shell's text area") { $0.role == "AXTextArea" }
        XCTAssertEqual(shell.label, "Terminal 2")
    }

    func testTheCommitScopeIsANamedGroupWithTheChosenScopeSelected() async throws {
        let root = scratchRoot("a11y-commit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-q", "-b", "main"], ["config", "commit.gpgsign", "false"]] { try git(arguments, in: root) }
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try "a2\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        let window = try await hostedWindow(CommitBoxHost(controller: controller), width: 420, height: 300)
        let scope = try await AXClient.find(in: window) { $0.label == "Commit scope" }
        XCTAssertEqual(scope.role, "AXGroup")
        XCTAssertEqual(scope.children.map(\.label), ["Checked files", "Staged changes"])
        XCTAssertEqual(scope.children.map(\.selected), [true, false])
        controller.commitScope = .stagedChanges
        _ = try await AXClient.find(in: window, "the staged scope selected") { $0.label == "Commit scope" && $0.children.map(\.selected) == [false, true] }
    }

    func testEachQueueRowsButtonsSayWhichMessageTheyActOn() async throws {
        let pane = try ConversationPaneTests.Pane(width: 920, height: 600)
        // The stores close before the root goes, as every model must be taken down.
        registerWorkspaceFixtureTeardown(pane.model, root: pane.root)
        addTeardownBlock { @MainActor in pane.window.contentView = nil; pane.window.close() }
        pane.session.state = "running"
        pane.session.queue = [
            ["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Summarise what changed")],
            ["turnId": .string("q1"), "kind": .string("steering"), "text": .string("Check the failing test first")],
            ["turnId": .string("q2"), "kind": .string("follow-up"), "text": .string("Then open a pull request")],
        ]
        await pane.settle(16)
        pane.window.title = "ax-" + UUID().uuidString
        _ = try await AXClient.find(in: pane.window, "the rows") { $0.label == "Remove follow-up 2" }
        let all = try await AXClient.all(in: pane.window)
        for label in ["Remove follow-up 1", "Remove follow-up 2", "Remove steering message", "Edit follow-up 1",
                      "Steer the current run with follow-up 2", "Show the whole follow-up 1 and its model choices",
                      "Show the whole steering message and its model choices"] {
            XCTAssertTrue(all.contains { $0.label == label && $0.role == "AXButton" }, "\(label) missing: \(labels(all))")
        }
        XCTAssertFalse(all.contains { $0.label == "Remove" }, "no row's Remove is anonymous")
        let rows = all.filter { $0.role == "AXGroup" && ["Follow-up 1", "Follow-up 2", "Steering message"].contains($0.label) }
        XCTAssertEqual(Set(rows.map(\.label)), ["Follow-up 1", "Follow-up 2", "Steering message"], labels(all))
        XCTAssertEqual(all.filter { $0.label == "Summarise what changed" || $0.value == "Summarise what changed" }.count, 1,
                       "a message's text is read once, not again in its row's name")
        XCTAssertTrue(all.contains { $0.label == "Hide waiting messages" })
    }

    func testTheBlameBarReadsAsWordsAndOffersTheWholeCommit() async throws {
        let root = scratchRoot("a11y-blame")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key")]
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        addTeardownBlock { @MainActor in for window in model.tabs.windows { model.tabs.window(of: window)?.close() } }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "main", workspaceID: "w", title: "Main", path: nil, profileID: profile.id)
        let main = SessionDisplay(id: chat.id)
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main]
        try git(["init", "-q", "-b", "main"], in: root, author: "Ada")
        try "alpha\nbeta\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: root, author: "Ada"); try git(["commit", "-q", "-m", "Greek letters"], in: root, author: "Ada")
        let hash = try git(["rev-parse", "HEAD"], in: root, author: "Ada").trimmingCharacters(in: .whitespacesAndNewlines)
        let window = try await hostedWindow(WorkspaceView(model: model), width: 1400, height: 900)
        let tab = model.openFile(root.appendingPathComponent("file.txt"))
        try await eventually("the text shown and read") { tab.status == .ready && tab.focusView != nil }
        tab.blame.toggle()
        try await eventually("blamed") { tab.blame.blame != nil }
        let line = try await AXClient.find(in: window, "the bar") { $0.spoken.hasPrefix("Line 1, commit ") }
        let all = try await AXClient.all(in: window)
        XCTAssertTrue(line.spoken.contains(", by Ada, "), line.spoken)
        XCTAssertTrue(line.spoken.hasSuffix(": Greek letters"), line.spoken)
        XCTAssertFalse(line.spoken.contains("·"), "no separators read aloud")
        XCTAssertTrue(line.help.contains("Full commit ID " + hash), "the whole commit ID on request: \(line.help)")
        XCTAssertFalse(line.help.contains("Greek letters") || line.help.contains("Ada,"), "the hint adds to the line, it does not repeat it: \(line.help)")
        XCTAssertTrue(all.contains { $0.label.hasPrefix("Copy commit ID ") && $0.role == "AXButton" })
        XCTAssertTrue(all.contains { $0.label == "Show Change" && $0.role == "AXButton" })
        // The gutter's attribution is drawn; the bar is how the keyboard and
        // VoiceOver reach it: it follows the line the caret is on.
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        text.select(from: FileTextPosition(line: 1, column: 0), to: FileTextPosition(line: 1, column: 0))
        _ = try await AXClient.find(in: window, "the bar following the caret") { $0.spoken.hasPrefix("Line 2, commit ") }
        let ruler = try XCTUnwrap((tab.focusView as? FileTextView)?.enclosingScrollView?.verticalRulerView)
        XCTAssertEqual(ruler.accessibilityLabel(), "Line numbers and annotations")
        tab.blame.hide()
        try await eventually("hidden") { !tab.blame.isOn }
        XCTAssertEqual(ruler.accessibilityLabel(), "Line numbers")
    }

    /// Every button in a chat window, with a run going and a message
    /// queued, has a name, and none is a symbol's name read aloud ("Up",
    /// "Add List"); nothing else is exposed where the composer's AppKit press
    /// targets (the usage pill, Chat actions, the capture badge) sit over
    /// their drawn faces.
    func testAChatWindowsControlsAllHaveNamesAndNoFaceIsReadAsAnImage() async throws {
        let root = scratchRoot("a11y-window")
        let (model, _, _, chats) = try ConversationPaneTests.workbench(root: root, chats: ["main"])
        registerWorkspaceFixtureTeardown(model, root: root)
        let main = SessionDisplay(id: chats[0].id)
        model.selectedID = chats[0].id; model.selected = main; model.displays = [main.id: main]; model.focusedSessionID = main.id
        let window = try await hostedWindow(WorkspaceView(model: model), width: 1400, height: 900)
        let idle = try await AXClient.find(in: window, "the idle send button") { $0.label == "Send" && $0.role == "AXButton" }
        XCTAssertEqual(idle.help, "Send")
        main.state = "running"
        main.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Summarise")]]
        main.draft = "One more thing"
        _ = try await AXClient.find(in: window, "the queue button") { $0.label == "Queue Follow-up" && $0.role == "AXButton" }
        let content = try await AXClient.content(of: window)
        // Scroll bars' own arrow buttons are AppKit's and unnamed by design.
        func controls(_ nodes: [AXNode]) -> [AXNode] {
            nodes.flatMap { $0.role == "AXScrollBar" ? [] : [$0] + controls($0.children) }
        }
        let all = controls(content)
        let unnamed = all.filter { ["AXButton", "AXMenuButton", "AXCheckBox", "AXPopUpButton"].contains($0.role) && $0.label.isEmpty }
        XCTAssertEqual(unnamed.map { "\($0.role) help='\($0.help)'" }, [], "every control has a name")
        let symbols = ["Up", "Add List", "Chart Pie", "More", "Ellipsis"]
        XCTAssertEqual(all.filter { symbols.contains($0.label) }.map { "\($0.role):\($0.label)" }, [], "no symbol name is read as a name")
        XCTAssertEqual(all.filter { $0.role == "AXImage" && $0.label == "Filter chats and topics by title" }.count, 0, "the filter's icon does not repeat its name")
        let targets = all.filter { $0.label == "Chat actions" || $0.label.hasPrefix("Session Inspector: cost") || $0.label.hasPrefix("Capture: ") }
        XCTAssertEqual(targets.count, 3, targets.map(\.label).joined(separator: " | "))
        for target in targets {
            XCTAssertGreaterThan(target.frame.width * target.frame.height, 0, "\(target.label) has a frame to check")
            // SwiftUI's own wrapper around the AppKit button holds it; that
            // is the button's container, not a second thing to read.
            let containers = all.filter { node in AXNode.flat(node.children).contains { $0.element == target.element } }
            let under = all.filter { node in
                // A hidden SwiftUI view leaves an empty, role-less placeholder,
                // as hidden views do throughout the window; VoiceOver skips it.
                node.element != target.element && !(node.role == "AXGroup" && node.label.isEmpty && node.value.isEmpty) && node.frame.width > 0
                    && !(node.role == "AXUnknown" && node.label.isEmpty && node.value.isEmpty)
                    && !containers.contains { $0.element == node.element }
                    && target.frame.insetBy(dx: 1, dy: 1).intersects(node.frame) && target.frame.contains(node.frame.insetBy(dx: 1, dy: 1))
            }
            XCTAssertEqual(under.map { "\($0.role):\($0.label)" }, [], "\(target.label): its face is drawing, not a second element")
        }
    }

    // MARK: Fixtures

    private func labels(_ nodes: [AXNode]) -> String { nodes.map { "\($0.role):\($0.label)" }.joined(separator: " | ") }
    @discardableResult
    private func git(_ arguments: [String], in root: URL, author: String = "Fixture") throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
}

/// The commit box alone, 380 points wide with 16 around it, following its controller.
@MainActor private final class CommitBoxHost: NSView {
    let box: GitCommitBox
    private var observation: AnyCancellable?
    init(controller: GitController) {
        box = GitCommitBox(controller: controller, inputs: GitCommitBox.Inputs(controller), discard: { _ in })
        super.init(frame: .zero)
        addSubview(box)
        // The hosting group the accessibility client reads from.
        setAccessibilityElement(true); setAccessibilityRole(.group)
        observation = controller.objectWillChange.sink { [weak self, controller] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.box.apply(GitCommitBox.Inputs(controller)); self?.needsLayout = true } }
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        box.frame = CGRect(x: (bounds.width - 380) / 2 + 16, y: 16, width: 380 - 32, height: box.height(forWidth: 380 - 32))
    }
}

extension XCTestCase {
    /// An AppKit view in a window of its own, read once by the accessibility client.
    @MainActor func hostedWindow(_ view: NSView, width: CGFloat, height: CGFloat) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ax-" + UUID().uuidString
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil }
        _ = try await AXClient.content(of: window)
        return window
    }
}
