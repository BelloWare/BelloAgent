import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// The sidebar at its narrowest, in both appearances, with everything that can
/// crowd a row at once: a marked selection, unread dots, live metrics, a long
/// title, a topic, an archived group and an indented child. Captures go to
/// `PI_APP_SIDEBAR_SHOT_ROOT` when it is set, so the pictures can be looked at;
/// the assertions are about what would be cut off.
final class SidebarAppearanceTests: XCTestCase {
    @MainActor private func crowdedModel(_ root: URL) throws -> (WorkspaceModel, WorkspaceRecord) {
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]
        model.selectedWorkspaceID = project.id
        model.topics = [TopicRecord(id: "topic", workspaceID: project.id, title: "Billing and invoicing")]
        var chats: [ChatRecord] = []
        func chat(_ id: String, _ title: String, order: Int64, topic: String? = nil,
                  parent: String? = nil, archived: Bool = false, pinned: Bool = false) -> ChatRecord {
            var record = ChatRecord(id: id, workspaceID: project.id, title: title, path: nil,
                                    profileID: "fixture", sidebarOrder: 1_000 - order)
            record.topicID = topic; record.parentSessionID = parent
            if archived { record.archivedAt = Date() }
            if pinned { record.pinnedAt = Date() }
            return record
        }
        chats.append(chat("long", "A chat with a title far longer than any narrow sidebar could ever show", order: 1, pinned: true))
        chats.append(chat("running", "Running with metrics", order: 2))
        chats.append(chat("child", "Side branch of the running chat", order: 3, parent: "running"))
        chats.append(chat("unread", "Unread replies waiting", order: 4))
        chats.append(chat("grouped", "Invoice reconciliation", order: 5, topic: "topic"))
        chats.append(chat("filed", "Archived last week", order: 6, archived: true))
        model.chats = chats
        model.selectedID = "running"
        model.unreadStates["unread"] = SessionReadState(id: "unread", observedAssistantCount: 3,
                                                        latestAssistantID: "m3", unreadOutputs: 2)
        // A live row with real numbers on its metrics line.
        let display = SessionDisplay(id: "running")
        display.state = "running"
        var totals = GatewayTotals(requests: 42, costSamples: 42, costUSD: 12.3456)
        totals.tokens = GatewayTokenTotals(total: 1_234_567, samples: 42)
        display.footer.gateway = totals
        model.displays["running"] = display
        // Two marked rows, so the selection bar is up.
        model.markedSessionIDs = ["long", "unread"]
        return (model, project)
    }

    @MainActor private func capture(_ name: String, width: CGFloat, dark: Bool) throws -> NSBitmapImageRep {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, project) = try crowdedModel(root)
        defer { model.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let sidebar = VStack(alignment: .leading, spacing: 0) {
            SidebarSelectionBar(model: model).padding(.horizontal, PiSpacing.md).padding(.vertical, 6)
            ProjectSidebarGroup(model: model, project: project, available: true, name: "bello-agent", sidebarWidth: width)
                .padding(.horizontal, PiSpacing.sm)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .background(Color.piWindow)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        window.contentView = NSHostingView(rootView: sidebar)
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.needsLayout = true
        hosted.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = hosted.bounds
        let image = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: bounds))
        hosted.cacheDisplay(in: bounds, to: image)
        if let destination = testEnvironment("PI_APP_SIDEBAR_SHOT_ROOT") {
            let directory = URL(fileURLWithPath: destination)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(name).png")
            if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: file) }
            print("SHOT \(file.path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
        window.contentView = nil
        window.close()
        return image
    }

    /// Nothing a row draws may leave the sidebar, in either appearance, at the
    /// narrowest width the resize handle allows.
    @MainActor func testTheNarrowSidebarFitsEveryRowInBothAppearances() throws {
        for dark in [false, true] {
            let name = dark ? "sidebar-narrow-dark" : "sidebar-narrow-light"
            let image = try capture(name, width: WindowChrome.minimumSidebarWidth, dark: dark)
            // The trailing two points of every row band must be the sidebar's
            // own background: a control that overflowed would paint there.
            let inks = self.inkColumns(image)
            XCTAssertTrue(inks.trailing.isEmpty,
                          "\(name): something is drawn into the last two points of the sidebar at rows \(inks.trailing)")
            XCTAssertFalse(inks.any.isEmpty, "\(name): the sidebar drew nothing at all")
        }
    }

    @MainActor func testTheDefaultSidebarFitsEveryRowInBothAppearances() throws {
        for dark in [false, true] {
            let name = dark ? "sidebar-wide-dark" : "sidebar-wide-light"
            let image = try capture(name, width: WindowChrome.sidebarWidth, dark: dark)
            XCTAssertTrue(self.inkColumns(image).trailing.isEmpty, "\(name): a row overflows the sidebar")
        }
    }

    /// Every width the resize handle allows, with rows whose figures differ
    /// in every way they can: short and long costs, thousands and millions of
    /// tokens, "just now" through "yesterday", with and without a rate. The
    /// metrics line picks its form by measurement now, so this is where a
    /// measurement that drifted from layout would show up as ink past the
    /// sidebar's edge.
    @MainActor func testMetricsFitAtEveryWidthTheHandleAllows() throws {
        for width in [200, 240, 260, 300, 340, 420] as [CGFloat] {
            let base = scratchBase()
            let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-metrics-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                       vault: ConfigurationVault(storage: MemoryVaultStorage()))
            defer { model.shutdown() }
            let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
            model.workspaces = [project]; model.selectedWorkspaceID = project.id
            let figures: [(String, Double?, Double?, TimeInterval?)] = [
                ("Cents and thousands", 0.0042, 12_300, 5),
                ("Dollars and millions", 12.34, 9_876_543, 900),
                ("Large cost yesterday", 98_765.43, 4_500_000, 129_600),
                ("No cost, no tokens", nil, nil, 60),
                ("A very long chat title that leaves the figures no room at all", 1.23, 456_000, 3),
            ]
            var chats: [ChatRecord] = []
            for (index, figure) in figures.enumerated() {
                chats.append(ChatRecord(id: "chat\(index)", workspaceID: project.id, title: figure.0, path: nil,
                                        profileID: "fixture", sidebarOrder: Int64(100 - index)))
            }
            model.chats = chats
            for (index, figure) in figures.enumerated() {
                var totals = GatewayTotals(requests: 6, costSamples: 6, costUSD: figure.1)
                totals.tokens = GatewayTokenTotals(total: figure.2, samples: 6)
                totals.lastActivity = figure.3.map { Date().timeIntervalSince1970 - $0 }
                model.chatAccounting.publish(totals, sessionID: "chat\(index)")
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                ProjectSidebarGroup(model: model, project: project, available: true, name: "bello-agent", sidebarWidth: width)
                    .frame(width: width, alignment: .leading).background(Color.piWindow)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true })
            window.makeKeyAndOrderFront(nil)
            let hosted = try XCTUnwrap(window.contentView)
            hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: image)
            let inks = inkColumns(image)
            XCTAssertTrue(inks.trailing.isEmpty,
                          "At \(Int(width))pt something is drawn into the last two points of the sidebar at rows \(inks.trailing)")
            XCTAssertFalse(inks.any.isEmpty, "At \(Int(width))pt the sidebar drew nothing")
            if let destination = testEnvironment("PI_APP_SIDEBAR_SHOT_ROOT") {
                let directory = URL(fileURLWithPath: destination)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let data = image.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent("sidebar-metrics-\(Int(width)).png"))
                }
            }
            window.contentView = nil; window.close()
        }
    }

    /// A row that is skipped because nothing about it changed is the whole
    /// point of comparing rows — and the way that goes wrong is a row that
    /// keeps showing what it showed before. Each of these changes one thing a
    /// row draws and insists the picture is different afterwards.
    @MainActor func testEveryRowRedrawsWhenSomethingItShowsChanges() throws {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, project) = try crowdedModel(root)
        defer { model.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 620), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            ProjectSidebarGroup(model: model, project: project, available: true, name: "bello-agent")
                .frame(width: 300, alignment: .leading).background(Color.piWindow)
                .transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        defer { window.contentView = nil; window.close() }

        func frame() throws -> Data {
            hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: image)
            return try XCTUnwrap(image.representation(using: .png, properties: [:]))
        }
        var previous = try frame()
        func changes(_ what: String, _ mutate: () -> Void) throws {
            mutate()
            let next = try frame()
            XCTAssertNotEqual(previous, next, "The sidebar still shows what it showed before \(what)")
            previous = next
        }

        try changes("a chat was renamed") { model.chats[1].title = "Renamed while the sidebar is up" }
        try changes("a chat became unread") {
            model.unreadStates["grouped"] = SessionReadState(id: "grouped", observedAssistantCount: 1,
                                                             latestAssistantID: "m1", unreadOutputs: 1)
        }
        try changes("the unread chat was read") { model.unreadStates["unread"] = SessionReadState(id: "unread", observedAssistantCount: 3, latestAssistantID: "m3", unreadOutputs: 0) }
        try changes("the selection moved") { model.selectedID = "unread" }
        try changes("a row was marked") { model.markedSessionIDs = ["long", "unread", "running"] }
        try changes("a chat was pinned") { model.chats[1].pinnedAt = Date() }
        try changes("a chat was archived") { model.chats[3].archivedAt = Date() }
        try changes("a branch was folded") { model.collapsedSidebarSides.insert("running") }
        try changes("a session went live") {
            let display = SessionDisplay(id: "grouped"); display.state = "running"
            model.displays["grouped"] = display
        }
        // A live row keeps its own figures moving: nothing above this row
        // changed, and the row still has to redraw.
        try changes("a live row's figures moved") {
            guard let live = model.displays["running"] else { return }
            var totals = GatewayTotals(requests: 99, costSamples: 99, costUSD: 98.76)
            totals.tokens = GatewayTokenTotals(total: 9_876_543, samples: 99)
            live.footer.gateway = totals
        }
        // A chat with no live session of its own draws the figures the
        // accounting cache retained for it.
        try changes("a settled row's retained billing arrived") {
            var totals = GatewayTotals(requests: 4, costSamples: 4, costUSD: 0.4321)
            totals.tokens = GatewayTokenTotals(total: 54_321, samples: 4)
            model.chatAccounting.publish(totals, sessionID: "long")
        }
        // The group headers are compared on their own values too, so every
        // one of these has to reach them.
        try changes("a topic was renamed") { model.topics[0].title = "Renamed while the sidebar is up" }
        try changes("a chat left its topic") { model.chats[4].topicID = nil }
        try changes("the marks were cleared") { model.markedSessionIDs = [] }
        try changes("another project became the chosen one") { model.selectedWorkspaceID = "somewhere-else" }
        try changes("the project was collapsed") { model.setProjectExpanded(project.id, expanded: false) }
        try changes("the project was expanded again") { model.setProjectExpanded(project.id, expanded: true) }
        try changes("the archive filter was turned on") { model.setProjectArchiveFilter(project.id, archived: true) }
        try changes("the archive filter went back to the chats") { model.setProjectArchiveFilter(project.id, archived: false) }
        // A group is compared on a signature of everything it draws. Each of
        // these changes something inside one group and nothing above it, so a
        // signature that leaves any of them out shows the sidebar it drew last.
        func arrival(_ id: String, _ title: String, order: Int64) -> ChatRecord {
            ChatRecord(id: id, workspaceID: project.id, title: title, path: nil, profileID: "fixture", sidebarOrder: order)
        }
        try changes("a chat arrived in the project") { model.chats.append(arrival("arrived", "Arrived while the sidebar is up", order: 940)) }
        try changes("that chat moved into the topic") {
            guard let index = model.chats.firstIndex(where: { $0.id == "arrived" }) else { return }
            model.chats[index].topicID = "topic"
        }
        try changes("a side conversation opened under a chat") {
            model.sides["long"] = SideRecord(id: "side-of-long", parentID: "long", workspaceID: project.id,
                                             profileID: "fixture", title: "Side conversation")
        }
        try changes("a chat inside the topic was marked") { model.markedSessionIDs = ["grouped", "arrived"] }
        try changes("more chats than a page arrived") {
            model.chats.append(contentsOf: (0..<8).map { arrival("page\($0)", "Paged chat \($0)", order: Int64(900 - $0)) })
        }
        try changes("the page was opened") { model.setSidebarShownRoots(project.id, to: 20, in: project.id) }
        try changes("a chat left the project") { model.chats.removeAll { $0.id == "arrived" } }
    }

    /// Only the collapsed header of a project, so the trailing controls are the
    /// only thing in the picture.
    /// Marking rows for a bulk action must not take the highlight away from the
    /// chat that is open. Both used to be filled with the same accent wash, so
    /// with five rows marked the reader could no longer see which one they were
    /// reading; only a one-pixel outline told them apart.
    @MainActor func testAMarkedRowDoesNotWearTheOpenChatsHighlight() throws {
        func fill(selected: Bool, marked: Bool) throws -> NSColor {
            let row = PiSelectableRow(selected: selected, marked: marked, action: {}) {
                Text("Chat").font(PiFont.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            let view = NSHostingView(rootView: row.frame(width: 240, height: 34).background(Color.piWindow))
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 34)
            view.appearance = NSAppearance(named: .aqua)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let sample = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            return sample
        }
        func distance(_ a: NSColor, _ b: NSColor) -> Double {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        let plain = try fill(selected: false, marked: false)
        let marked = try fill(selected: false, marked: true)
        let selected = try fill(selected: true, marked: false)
        XCTAssertGreaterThan(distance(marked, selected), 0.03, "A marked row must not be filled like the open chat")
        XCTAssertGreaterThan(distance(plain, selected), 0.03, "The open chat must still stand out from an ordinary row")
    }

    @MainActor private func captureHeader(_ name: String, width: CGFloat) throws -> NSBitmapImageRep {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, project) = try crowdedModel(root)
        defer { model.shutdown() }
        model.setProjectExpanded(project.id, expanded: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            ProjectSidebarGroup(model: model, project: project, available: true, name: "bello-agent", sidebarWidth: width)
                .frame(width: width, alignment: .leading)
                .background(Color.piWindow)
                .transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let image = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
        hosted.cacheDisplay(in: hosted.bounds, to: image)
        if let destination = testEnvironment("PI_APP_SIDEBAR_SHOT_ROOT") {
            let directory = URL(fileURLWithPath: destination)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("\(name).png"))
            }
            print("SHOT \(destination)/\(name).png \(Int(hosted.bounds.width))x\(Int(hosted.bounds.height))")
        }
        window.contentView = nil; window.close()
        return image
    }

    /// A sidebar pulled in below the threshold gives the project's own buttons'
    /// room back to its name; both stay in the actions menu.
    @MainActor func testANarrowProjectHeaderDropsItsButtonsAndKeepsItsName() throws {
        let wide = try captureHeader("sidebar-header-wide", width: WindowChrome.sidebarWidth)
        let narrow = try captureHeader("sidebar-header-narrow", width: WindowChrome.minimumSidebarWidth)
        let wideControls = trailingInk(wide, points: 70), narrowControls = trailingInk(narrow, points: 70)
        print("PERF sidebar header trailing ink: wide \(wideControls), narrow \(narrowControls)")
        XCTAssertGreaterThan(wideControls, 0, "The wide header draws its changes, new-chat and actions controls")
        XCTAssertGreaterThan(narrowControls, 0, "The narrow header still has its actions menu")
        XCTAssertLessThan(narrowControls * 2, wideControls,
                          "A narrow header must give the changes and new-chat buttons' room back to the project's name")
    }

    /// Ink in the trailing strip of a header, in pixels.
    @MainActor private func trailingInk(_ image: NSBitmapImageRep, points: Int) -> Int {
        let scale = max(1, image.pixelsWide / max(1, Int(image.size.width)))
        let background = image.colorAt(x: 1, y: image.pixelsHigh / 2)
        var ink = 0
        for row in stride(from: 1, to: image.pixelsHigh - 1, by: scale) {
            for column in max(0, image.pixelsWide - points * scale)..<image.pixelsWide {
                guard let colour = image.colorAt(x: column, y: row), let background else { continue }
                let difference = abs(colour.redComponent - background.redComponent)
                    + abs(colour.greenComponent - background.greenComponent)
                    + abs(colour.blueComponent - background.blueComponent)
                if difference > 0.12 { ink += 1 }
            }
        }
        return ink
    }

    /// Rows that carry ink in the two trailing points of the sidebar, in points
    /// from the top. Anything there has been pushed past the edge.
    @MainActor private func inkColumns(_ image: NSBitmapImageRep) -> (trailing: [Int], any: [Int]) {
        let scale = max(1, image.pixelsWide / max(1, Int(image.size.width)))
        var trailing: [Int] = [], any: [Int] = []
        let background = image.colorAt(x: image.pixelsWide - 1, y: 2)
        for row in stride(from: 2, to: image.pixelsHigh - 2, by: scale * 2) {
            var sawInk = false, sawTrailingInk = false
            for column in 0..<image.pixelsWide {
                guard let colour = image.colorAt(x: column, y: row), let background else { continue }
                let difference = abs(colour.redComponent - background.redComponent)
                    + abs(colour.greenComponent - background.greenComponent)
                    + abs(colour.blueComponent - background.blueComponent)
                guard difference > 0.12 else { continue }
                sawInk = true
                if column >= image.pixelsWide - scale * 2 { sawTrailingInk = true }
            }
            if sawInk { any.append(row / scale) }
            if sawTrailingInk { trailing.append(row / scale) }
        }
        return (trailing, any)
    }
}
