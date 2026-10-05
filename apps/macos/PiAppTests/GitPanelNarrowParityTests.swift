import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp
@testable import GitView

/// The 310pt Changes pane in the released minimum-width main window.
/// Measures both the panel alone and the released ChangesTab hosting topology;
/// a toolbar's overflow must not be assumed to resize its neighboring children.
@MainActor final class GitPanelNarrowParityTests: GitPanelTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func mount(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        window.makeFirstResponder(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil; window.close() }
        return window
    }
    private func settle(_ root: NSView, window: NSWindow, minimumFrames: Int = 12, snapshot: () -> [GitNarrowReferencePart: CGRect]?) async throws -> [GitNarrowReferencePart: CGRect] {
        var previous: [GitNarrowReferencePart: CGRect] = [:], stable = 0
        try await eventually("The narrow Git frames settle", timeout: 5) {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard let current = snapshot(), current.count >= minimumFrames else { return false }
            stable = current == previous ? stable + 1 : 0; previous = current
            return stable >= 3
        }
        return previous
    }
    private func frame(_ view: NSView, in panel: NSView) -> CGRect { view.convert(view.bounds, to: panel) }
    private func nativeFrames(_ panel: GitPanelView) -> [GitNarrowReferencePart: CGRect]? {
        guard let header = views(GitPanelHeader.self, in: panel).first,
              let toolbar = views(GitPanelToolbar.self, in: panel).first,
              let history = views(GitHistoryList.self, in: panel).first,
              let filter = views(PiKit.TextField.self, in: history).first(where: { $0.field.placeholderString == "Filter by message or hash" }),
              let author = views(PiKit.TextField.self, in: history).first(where: { $0.field.placeholderString == "Author" }),
              let branch = views(PiKit.MenuButton.self, in: toolbar).first(where: { $0.accessibilityIdentifier() == "git-branch-menu" }),
              let stash = views(PiKit.MenuButton.self, in: toolbar).first(where: { $0.accessibilityIdentifier() == "git-stash-menu" }),
              let remote = views(GitRemoteControls.self, in: toolbar).first,
              let tabs = views(PiKit.Tabs<GitController.Panel>.self, in: toolbar).first,
              let firstCommit = views(GitCommitRowView.self, in: history).first(where: { $0.row.accessibilityIdentifier() == "git-commit-" + (panel.controller.commits.first?.shortHash ?? "") }),
              let detail = views(GitPanelDetail.self, in: panel).first else { return nil }
        return [.header: frame(header, in: panel), .toolbar: frame(toolbar, in: panel),
                .branch: frame(branch, in: panel), .remote: frame(remote, in: panel), .stash: frame(stash, in: panel), .tabs: frame(tabs, in: panel),
                .history: frame(history, in: panel), .filter: frame(filter, in: panel), .author: frame(author, in: panel),
                .list: frame(history.list, in: panel), .firstCommit: frame(firstCommit, in: panel), .detail: frame(detail, in: panel)]
    }
    private func record(_ kind: String, frames: [GitNarrowReferencePart: CGRect], window: NSWindow, minimum: CGFloat? = nil) throws {
        var values: [String: Any] = ["frames": Dictionary(uniqueKeysWithValues: frames.map { part, rect in
            (part.rawValue, [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)])
        })]
        if let minimum { values["minimumWidth"] = Double(minimum) }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("GIT-NARROW " + kind + " " + String(decoding: data, as: UTF8.self))
        if let path = testEnvironment("PI_COMPONENT_GALLERY"), !path.isEmpty {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("git-narrow-geometry")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(kind + ".json"))
            let image = try PiKitParity.windowImage(window)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(kind + ".png"))
        }
    }

    private func repositoryFixture() throws -> URL {
        let root = try repository("git-narrow-history")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let file = root.appendingPathComponent("PaymentClient.swift")
        // The released 24d gallery's actual two commits, not an inert or
        // smaller diff: default representable sizing is part of the oracle.
        try "func charge(_ order: Order) async throws -> Receipt {\n    for attempt in 1...3 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n    }\n    throw PaymentError.exhausted\n}\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Add the payment client and fixture notes"], in: root)
        try "func charge(_ order: Order) async throws -> Receipt {\n    var delay: Duration = .milliseconds(200)\n    for attempt in 1...5 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n        try await Task.sleep(for: delay); delay *= 2\n    }\n    throw PaymentError.exhausted\n}\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-a", "-m", "Back off between attempts"], in: root)
        return root
    }
    private func ready(_ controller: GitController) async throws {
        try await eventually("The real repository and its two History rows are ready", timeout: 10) {
            controller.statusRead && !controller.loading && controller.status.branch == "main" && controller.commits.count == 2
        }
        controller.selectedCommit = try XCTUnwrap(controller.commits.first)
        try await eventually("The selected commit is ready", timeout: 10) { !controller.commitLoading && controller.detail != nil }
        controller.detailFile = "PaymentClient.swift"
        try await eventually("The actual gallery file's selected diff is ready", timeout: 10) {
            !controller.commitLoading && !controller.detailFileDiff.isEmpty && controller.detailFile == "PaymentClient.swift"
        }
    }
    private func assertFrames(_ actual: [GitNarrowReferencePart: CGRect], _ expected: [GitNarrowReferencePart: CGRect],
                              parts: [GitNarrowReferencePart], file: StaticString = #filePath, line: UInt = #line) throws {
        for part in parts {
            let old = try XCTUnwrap(expected[part]), new = try XCTUnwrap(actual[part])
            XCTAssertEqual(new.minX, old.minX, accuracy: 0.5, "\(part.rawValue) leading position", file: file, line: line)
            XCTAssertEqual(new.minY, old.minY, accuracy: 0.5, "\(part.rawValue) top position", file: file, line: line)
            XCTAssertEqual(new.width, old.width, accuracy: 0.5, "\(part.rawValue) width", file: file, line: line)
            XCTAssertEqual(new.height, old.height, accuracy: 0.5, "\(part.rawValue) height", file: file, line: line)
        }
    }
    private let children: [GitNarrowReferencePart] = [.header, .toolbar, .branch, .remote, .stash, .tabs, .history, .filter, .author, .list, .firstCommit, .detail]

    func testStandaloneNarrowHistoryKeepsItsOriginalToolbarAndChildFrames() async throws {
        let root = try repositoryFixture()
        let controller = GitController(roots: [root.path]); controller.panel = .history
        addTeardownBlock { @MainActor in controller.letGo() }
        let pane = CGSize(width: 310, height: 540)
        let native = GitPanelView(controller: controller)
        let nativeWindow = mount(native, size: pane)
        try await ready(controller)
        let actual = try await settle(native, window: nativeWindow) { self.nativeFrames(native) }

        let geometry = GitNarrowReferenceGeometry()
        let reference = GitPanelNarrowV119Reference(controller: controller, geometry: geometry).environment(\.piReduceMotion, true)
        let minimum = NSHostingController(rootView: reference).sizeThatFits(in: CGSize(width: 0, height: pane.height)).width
        let frozen = NSHostingView(rootView: reference.frame(width: pane.width, height: pane.height)
            .coordinateSpace(name: GitNarrowReferenceGeometry.coordinateSpace))
        let frozenWindow = mount(frozen, size: pane)
        let expected = try await settle(frozen, window: frozenWindow, minimumFrames: 14) { geometry.frames }
        try record("frozen-v119", frames: expected, window: frozenWindow, minimum: minimum)
        try record("native", frames: actual, window: nativeWindow)

        XCTAssertGreaterThan(minimum, pane.width, "The released content reports an intrinsic minimum wider than the actual pane allocation")
        let toolbar = try XCTUnwrap(views(GitPanelToolbar.self, in: native).first)
        XCTAssertEqual(toolbar.minimumWidth, try XCTUnwrap(expected[.toolbar]).width, accuracy: 0.5,
                       "The actual folder and fixed controls determine the toolbar's nonshrinking minimum")
        XCTAssertEqual(native.bounds.width, pane.width, accuracy: 0.5, "Toolbar overflow preserves the panel's pane allocation")
        try assertFrames(actual, expected, parts: children)
    }

    func testChangesOpenedFromBlameKeepsTheReleasedHostingFramesInA310PointPane() async throws {
        let root = try repositoryFixture(), file = root.appendingPathComponent("PaymentClient.swift")
        let host = TabHost(defaults: nil); host.showsWindows = false
        addTeardownBlock { @MainActor in host.tearDown() }
        let fileTab = try XCTUnwrap(host.open(kind: FileTab.kind, key: FileTab.key(for: file)) { FileTab(url: file, projectID: "git-narrow") } as? FileTab)
        let tab = try XCTUnwrap(host.open(kind: ChangesTab.kind, key: "git-narrow") {
            ChangesTab(projectID: "git-narrow", name: root.lastPathComponent, roots: [root.path])
        } as? ChangesTab)
        tab.cameFrom(fileTab); tab.controller.panel = .history
        let pane = CGSize(width: 310, height: 540)
        let content = try XCTUnwrap(tab.contentView.content as? ChangesTabContent)
        let nativeWindow = mount(tab.contentView, size: pane)
        try await ready(tab.controller)
        let actual = try await settle(tab.contentView, window: nativeWindow, minimumFrames: 15) {
            guard var frames = self.nativeFrames(content.panel),
                  let back = self.views(PiKit.Button.self, in: content).first(where: { $0.accessibilityIdentifier() == "changes-back-to-file" }),
                  let backBar = back.superview else { return nil }
            let origin = content.panel.convert(NSPoint.zero, to: content)
            frames = frames.mapValues { $0.offsetBy(dx: origin.x, dy: origin.y) }
            frames[.panel] = self.frame(content.panel, in: content)
            frames[.backBar] = self.frame(backBar, in: content)
            frames[.tabContent] = content.bounds
            return frames
        }
        let geometry = GitNarrowReferenceGeometry(); geometry.globalCoordinates = true
        let reference = ChangesTabNarrowV119Reference(controller: tab.controller, geometry: geometry,
                                                      project: tab.name, returnName: fileTab.title).environment(\.piReduceMotion, true)
        let minimum = NSHostingController(rootView: reference).sizeThatFits(in: CGSize(width: 0, height: pane.height)).width
        let frozen = NSHostingView(rootView: reference)
        // TabContentContainer.show set these AppKit frames and autoresizing
        // masks. There was no SwiftUI fixed frame inside TabContentView.
        let canvas = NSView(frame: NSRect(origin: .zero, size: pane))
        frozen.frame = canvas.bounds; frozen.autoresizingMask = [.width, .height]; canvas.addSubview(frozen)
        let frozenWindow = mount(canvas, size: pane)
        let expected = try await settle(canvas, window: frozenWindow, minimumFrames: GitNarrowReferencePart.allCases.count) { geometry.frames }
        try record("frozen-v119-tab", frames: expected, window: frozenWindow, minimum: minimum)
        try record("native-tab", frames: actual, window: nativeWindow)
        XCTAssertEqual(frozen.frame.width, pane.width, accuracy: 0.5, "The original tab hosting view receives the actual pane allocation")
        XCTAssertEqual(content.bounds.width, pane.width, accuracy: 0.5, "The native tab keeps the same AppKit allocation")
        XCTAssertEqual(content.panel.bounds.width, pane.width, accuracy: 0.5, "The native panel keeps the history and detail's actual width")
        // SwiftUI reports its overflowing VStack's logical minimum frame;
        // AppKit reports the allocated host bounds. Their visible children
        // are the equivalent contract, including the overflowing toolbar.
        try assertFrames(actual, expected, parts: children + [.backBar])
    }

    /// The gallery also has a kept side under its Changes tab. Opacity did
    /// not remove that side's controls from the released ZStack's minimum.
    /// This checks the actual RightPane rather than attributing a neighboring
    /// pane's proposal to GitPanel's toolbar or translating history rows.
    func testAChangesTabOverTheKeptSideRetainsTheReleasedRightPaneProposal() async throws {
        let root = try repositoryFixture(), file = root.appendingPathComponent("PaymentClient.swift")
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["main"])
        addTeardownBlock { @MainActor in bench.model.shutdown() }
        var alternate = bench.profile; alternate.id = "alternate-connection"; alternate.name = "Team fast · Responses"
        bench.model.profiles.append(alternate)
        let parent = bench.chats[0]
        let side = SideRecord(id: "covered-side", parentID: parent.id, workspaceID: bench.workspace.id,
                              profileID: parent.profileID, title: "Fixture reply: Generate a one-line summary.", kept: true)
        let session = SessionDisplay(id: side.id); session.historyState = .empty
        session.messages = [TranscriptMessage(id: "side-reply", role: "assistant", text: "Fixture reply: Is the retry budget shared with queued follow-ups, or per turn?")]
        bench.model.sides[parent.id] = side; bench.model.displays[side.id] = session
        let host = bench.model.tabs; host.showsWindows = false
        addTeardownBlock { @MainActor in host.tearDown() }
        let fileTab = try XCTUnwrap(host.open(kind: FileTab.kind, key: FileTab.key(for: file)) { FileTab(url: file, projectID: bench.workspace.id) } as? FileTab)
        let tab = try XCTUnwrap(host.open(kind: ChangesTab.kind, key: bench.workspace.id) {
            ChangesTab(projectID: bench.workspace.id, name: root.lastPathComponent, roots: [root.path])
        } as? ChangesTab)
        tab.cameFrom(fileTab); tab.controller.panel = .history
        let pane = CGSize(width: 310, height: 576)
        let native = RightPaneView(model: bench.model, host: host, pane: host.pane)
        native.makeSideView = { info, display, width in SidePaneView(model: bench.model, session: display, info: info, paneWidth: width) }
        native.updateSideView = { view, info, _, width in (view as? SidePaneView)?.update(info: info, paneWidth: width) }
        native.update(side: (side, session), width: pane.width)
        let nativeWindow = mount(native, size: pane)
        try await ready(tab.controller)
        let content = try XCTUnwrap(tab.contentView.content as? ChangesTabContent)
        let actual = try await settle(native, window: nativeWindow) {
            guard let frames = self.nativeFrames(content.panel) else { return nil }
            return frames.mapValues { rect in native.convert(rect, from: content.panel) }
        }
        try await eventually("The covered side's model listing has settled", timeout: 10) { !bench.model.catalogEntry(for: bench.profile).loading }

        let geometry = GitNarrowReferenceGeometry(); geometry.globalCoordinates = true
        let sideReference = KeptSideMinimumV119Reference(title: side.title, reading: ModelSwitchPills.reading(model: bench.model, session: session), paneWidth: pane.width)
        let sideMinimum = NSHostingController(rootView: sideReference).sizeThatFits(in: CGSize(width: 0, height: pane.height)).width
        let reference = RightPaneMinimumV119Reference(
            tab: ChangesTabNarrowV119Reference(controller: tab.controller, geometry: geometry, project: tab.name, returnName: fileTab.title),
            side: sideReference)
        let frozen = NSHostingView(rootView: reference.frame(width: pane.width, height: pane.height).environment(\.piReduceMotion, true))
        let frozenWindow = mount(frozen, size: pane)
        let expected = try await settle(frozen, window: frozenWindow, minimumFrames: GitNarrowReferencePart.allCases.count) { geometry.frames }
        try record("frozen-v119-covered-side", frames: expected, window: frozenWindow, minimum: sideMinimum)
        try record("native-covered-side", frames: actual, window: nativeWindow)
        print("GIT-COVERED-SIDE originalControlsMinimum=\(sideMinimum) nativeComposerMinimum=\(self.views(SidePaneView.self, in: native).first?.pane.minimumWidth ?? 0)")
        try assertFrames(actual, expected, parts: children)
        let mountedSide = try XCTUnwrap(views(SidePaneView.self, in: native).first)
        let releasedBodyWidth = try XCTUnwrap(expected[.header]).width
        XCTAssertEqual(native.bounds.width, pane.width, accuracy: 0.5, "The outer pane keeps its allocation")
        XCTAssertEqual(try XCTUnwrap(native.strip).bounds.width, pane.width, accuracy: 0.5, "The strip keeps the same allocation")
        XCTAssertEqual(mountedSide.minimumWidth, releasedBodyWidth, accuracy: 0.5, "The side's real controls supply the released body minimum")
        XCTAssertEqual(mountedSide.pane.composer.paneWidth, pane.width, accuracy: 0.5, "Overflow does not change the composer's trial proposal")

        // A covered side keeps running. Its own state notification, without
        // a RightPane update from its parent, must propagate new controls'
        // minimum to the tab over it, then relinquish that room when idle.
        session.state = "running"
        try await eventually("A covered running side's controls resize the body") {
            native.layoutSubtreeIfNeeded()
            return mountedSide.minimumWidth > releasedBodyWidth && content.panel.bounds.width >= mountedSide.minimumWidth
                && self.views(PiKit.ButtonBase.self, in: mountedSide).contains { $0.accessibilityIdentifier() == "composerStopResponse" && !$0.isHidden }
        }
        session.state = "idle"
        try await eventually("The covered side relinquishes its run controls' room") {
            native.layoutSubtreeIfNeeded()
            return abs(content.panel.bounds.width - releasedBodyWidth) <= 0.5
        }
        let wider = CGSize(width: 600, height: pane.height)
        nativeWindow.setContentSize(wider); native.update(side: (side, session), width: wider.width)
        try await eventually("A wider allocation replaces overflow without rebuilding the tab") {
            native.layoutSubtreeIfNeeded()
            return abs(content.panel.bounds.width - wider.width) <= 0.5 && mountedSide.pane.composer.paneWidth == wider.width
        }
        nativeWindow.setContentSize(pane); native.update(side: nil, width: pane.width)
        try await eventually("Removing the side relinquishes its minimum for the same tab") {
            native.layoutSubtreeIfNeeded()
            return abs(content.panel.bounds.width - pane.width) <= 0.5 && self.views(SidePaneView.self, in: native).isEmpty
        }
    }

    /// The released ZStack permits fixed side controls to widen its flexible
    /// transcript too. Preserve that measured overflow for kept and in-memory
    /// sides rather than assuming the pane allocation always constrains it.
    func testVisibleSideTranscriptRetainsTheReleasedControlMinimum() async throws {
        let root = try repositoryFixture()
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["main"])
        addTeardownBlock { @MainActor in bench.model.shutdown() }
        var alternate = bench.profile; alternate.id = "alternate-connection"; alternate.name = "Team fast · Responses"
        bench.model.profiles.append(alternate)
        let parent = bench.chats[0]
        var side = SideRecord(id: "visible-side", parentID: parent.id, workspaceID: bench.workspace.id,
                              profileID: parent.profileID, title: "Fixture reply: Generate a one-line summary.", kept: true)
        let session = SessionDisplay(id: side.id); session.historyState = .empty
        session.messages = [TranscriptMessage(id: "side-reply", role: "assistant", text: "The visible side keeps its transcript in the allocated column.")]
        bench.model.displays[side.id] = session
        let host = bench.model.tabs; host.showsWindows = false
        addTeardownBlock { @MainActor in host.tearDown() }
        let pane = CGSize(width: 310, height: 540)
        let native = RightPaneView(model: bench.model, host: host, pane: host.pane)
        native.makeSideView = { info, display, width in SidePaneView(model: bench.model, session: display, info: info, paneWidth: width) }
        native.updateSideView = { view, info, _, width in (view as? SidePaneView)?.update(info: info, paneWidth: width) }
        let nativeWindow = mount(native, size: pane)
        for kept in [true, false] {
            side.kept = kept; bench.model.sides[parent.id] = side
            native.update(side: (side, session), width: pane.width)
            try await eventually("The visible side's transcript and model listing are ready", timeout: 10) {
                native.layoutSubtreeIfNeeded(); nativeWindow.displayIfNeeded()
                return (self.views(TranscriptNativeScrollView.self, in: native).first?.bounds.width ?? 0) > 0
                    && !bench.model.catalogEntry(for: bench.profile).loading
            }
            let mountedSide = try XCTUnwrap(views(SidePaneView.self, in: native).first)
            let nativeScroll = try XCTUnwrap(views(TranscriptNativeScrollView.self, in: mountedSide).first)
            var frozenScroll: TranscriptNativeScrollView?
            let sideReference = KeptSideMinimumV119Reference(title: side.title,
                reading: ModelSwitchPills.reading(model: bench.model, session: session), paneWidth: pane.width,
                kept: kept, transcriptProbe: { frozenScroll = $0 })
            let frozen = NSHostingView(rootView: RightPaneMinimumV119Reference(tab: nil, side: sideReference)
                .frame(width: pane.width, height: pane.height).environment(\.piReduceMotion, true))
            let frozenWindow = mount(frozen, size: pane)
            var previous = CGRect.null, stable = 0
            try await eventually("The original visible-side transcript proposal settles") {
                frozen.layoutSubtreeIfNeeded(); frozenWindow.displayIfNeeded()
                guard let frozenScroll, frozenScroll.window != nil, frozenScroll.bounds.width > 0 else { return false }
                let rect = frozenScroll.convert(frozenScroll.bounds, to: frozen)
                stable = rect == previous ? stable + 1 : 0; previous = rect
                return stable >= 3
            }
            native.layoutSubtreeIfNeeded()
            let actual = nativeScroll.convert(nativeScroll.bounds, to: native)
            print("RIGHT-PANE-VISIBLE kept=\(kept) originalTranscript=\(previous) nativeTranscript=\(actual) controlsMinimum=\(mountedSide.minimumWidth)")
            XCTAssertGreaterThan(mountedSide.minimumWidth, pane.width, "The real controls exercise the overflowing minimum")
            let releasedWidth: CGFloat = kept ? 336 : 457
            XCTAssertEqual(previous.minX, (pane.width - releasedWidth) / 2, accuracy: 0.5, "The original controls center their overflowing minimum")
            XCTAssertEqual(previous.width, releasedWidth, accuracy: 0.5, "The independent original kept/in-memory controls retain their measured minimum")
            XCTAssertEqual(actual.minX, previous.minX, accuracy: 0.5, "The visible transcript keeps the released leading boundary")
            XCTAssertEqual(actual.width, previous.width, accuracy: 0.5, "The visible transcript keeps the released allocation")
        }
    }

    /// Pinning the sides panel resizes RightPane without rebuilding the
    /// selected side. Its composer must try its forms at the new allocation,
    /// before those fixed controls determine the transcript's minimum.
    func testVisibleSideRefreshesTheComposerProposalWhenItsColumnResizes() async throws {
        let root = try repositoryFixture()
        let workspace = WorkspaceRecord(id: "sides-panel-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.id = "sides-panel-profile"; profile.name = "Sides"
        profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "sides-model"
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-sides-panel-key")]
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("pin-state"), vault: vault)
        addTeardownBlock { @MainActor in model.shutdown() }
        let parent = ChatRecord(id: "P", workspaceID: workspace.id, title: "P", path: nil, profileID: profile.id)
        var child = ChatRecord(id: "S1", workspaceID: workspace.id, title: "S1", path: nil, profileID: profile.id)
        child.parentSessionID = parent.id
        model.workspaces = [workspace]; model.profiles = [profile]; model.chats = [parent, child]
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        let side = SideRecord(id: child.id, parentID: parent.id, workspaceID: workspace.id,
                              profileID: profile.id, title: child.title, kept: true)
        let session = SessionDisplay(id: child.id); session.historyState = .empty
        session.messages = [TranscriptMessage(id: "side-reply", role: "assistant", text: "The saved side remains in its column when the panel is pinned.")]
        model.displays[session.id] = session; model.sides[parent.id] = side
        let host = model.tabs; host.showsWindows = false
        addTeardownBlock { @MainActor in host.tearDown() }
        let height: CGFloat = 820
        let native = RightPaneView(model: model, host: host, pane: host.pane)
        native.makeSideView = { info, display, width in SidePaneView(model: model, session: display, info: info, paneWidth: width) }
        native.updateSideView = { view, info, _, width in (view as? SidePaneView)?.update(info: info, paneWidth: width) }
        native.update(side: (side, session), width: 489)
        let nativeWindow = mount(native, size: CGSize(width: 489, height: height))
        try await eventually("The single-profile saved side and its model reading are ready", timeout: 10) {
            native.layoutSubtreeIfNeeded(); nativeWindow.displayIfNeeded()
            return (self.views(TranscriptNativeScrollView.self, in: native).first?.bounds.width ?? 0) > 0
                && !model.catalogEntry(for: profile).loading
        }
        let mountedSide = try XCTUnwrap(views(SidePaneView.self, in: native).first)
        let composer = mountedSide.pane.composer
        let nativeScroll = try XCTUnwrap(views(TranscriptNativeScrollView.self, in: mountedSide).first)
        let reading = ModelSwitchPills.reading(model: model, session: session)
        XCTAssertFalse(reading.contents.showsConnection, "The original pinned fixture has just one profile")
        XCTAssertEqual(reading.contents.model, "sides-model")
        XCTAssertEqual(reading.contents.effort, "Effort · connection default")
        var frozenScroll: TranscriptNativeScrollView?
        func reference(width: CGFloat) -> some View {
            RightPaneMinimumV119Reference(tab: nil, side: KeptSideMinimumV119Reference(title: side.title,
                reading: reading, paneWidth: width, transcriptProbe: { frozenScroll = $0 }))
                .frame(width: width, height: height).environment(\.piReduceMotion, true)
        }
        let frozen = NSHostingView(rootView: reference(width: 489))
        let frozenWindow = mount(frozen, size: CGSize(width: 489, height: height))
        for width: CGFloat in [489, 365, 489] {
            // The actual window allocation changes; deliberately do not call
            // RightPane.update, as pinning has no new side/session to publish.
            nativeWindow.setContentSize(CGSize(width: width, height: height))
            frozenWindow.setContentSize(CGSize(width: width, height: height))
            frozen.rootView = reference(width: width)
            var previous = CGRect.null, stable = 0
            try await eventually("The original \(width)pt visible-side allocation settles") {
                frozen.layoutSubtreeIfNeeded(); frozenWindow.displayIfNeeded()
                guard let frozenScroll, frozenScroll.window != nil, frozenScroll.bounds.width > 0 else { return false }
                let rect = frozenScroll.convert(frozenScroll.bounds, to: frozen)
                stable = rect == previous ? stable + 1 : 0; previous = rect
                return stable >= 3
            }
            native.layoutSubtreeIfNeeded(); nativeWindow.displayIfNeeded()
            let actual = nativeScroll.convert(nativeScroll.bounds, to: native)
            print("RIGHT-PANE-RESIZE allocated=\(width) originalTranscript=\(previous) nativeTranscript=\(actual) controlsMinimum=\(mountedSide.minimumWidth) composerProposal=\(composer.paneWidth)")
            XCTAssertTrue(views(SidePaneView.self, in: native).first === mountedSide, "Resizing retains the selected side")
            XCTAssertTrue(mountedSide.pane.composer === composer, "Resizing retains the draft's composer")
            XCTAssertEqual(composer.paneWidth, width, accuracy: 0.5, "Control forms use the actual resized column before measuring its minimum")
            XCTAssertEqual(previous.minX, 0, accuracy: 0.5, "This original single-profile form fits its allocated column")
            XCTAssertEqual(previous.width, width, accuracy: 0.5, "The original pinned form gives the reserved panel its room")
            XCTAssertEqual(actual.minX, previous.minX, accuracy: 0.5, "The resized native transcript keeps the original leading boundary")
            XCTAssertEqual(actual.width, previous.width, accuracy: 0.5, "The resized native transcript keeps the original column width")
            XCTAssertLessThanOrEqual(actual.maxX, width, "The transcript does not enter the reserved panel's column")
        }
    }
}
