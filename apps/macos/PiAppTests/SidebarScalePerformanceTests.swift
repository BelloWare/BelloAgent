import XCTest
import AppKit
@testable import PiApp

/// A workspace the size the owner actually keeps: hundreds of chats spread over
/// several projects and topics, with one session streaming. Every number here
/// is printed rather than asserted against a machine speed, except the ones
/// that describe repeated work — those are structural and deterministic.
final class SidebarScalePerformanceTests: XCTestCase {
    private static let projects = 3
    private static let topicsPerProject = 3
    private static let chatsPerProject = 180

    @MainActor private struct Fixture {
        let model: WorkspaceModel
        let window: NSWindow
        let hosted: NSView
        let root: URL
        let streaming: SessionDisplay
        func teardown() {
            window.contentView = nil; window.close(); model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor private func fixture() throws -> Fixture {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                       vault: ConfigurationVault(storage: MemoryVaultStorage()))
        var workspaces: [WorkspaceRecord] = [], topics: [TopicRecord] = [], chats: [ChatRecord] = []
        for project in 0..<Self.projects {
            let id = "project\(project)"
            workspaces.append(WorkspaceRecord(id: id, path: root.appendingPathComponent(id).path, trusted: true))
            for topic in 0..<Self.topicsPerProject {
                topics.append(TopicRecord(id: "\(id)-topic\(topic)", workspaceID: id, title: "Topic \(topic)"))
            }
            for index in 0..<Self.chatsPerProject {
                var chat = ChatRecord(id: "\(id)-chat\(index)", workspaceID: id, title: "Chat \(index) of \(id)",
                                      path: nil, profileID: "fixture", sidebarOrder: Int64(10_000 - index))
                // Two thirds live in topics, one third at the project root; a
                // slice is archived and a slice carries a side chat.
                if index % 3 != 0 { chat.topicID = "\(id)-topic\(index % Self.topicsPerProject)" }
                if index % 11 == 0 { chat.archivedAt = Date() }
                if index % 17 == 5 { chat.parentSessionID = "\(id)-chat\(index - 1)" }
                chats.append(chat)
            }
        }
        model.workspaces = workspaces
        model.topics = topics
        model.chats = chats
        model.selectedWorkspaceID = "project0"
        model.selectedID = "project0-chat0"
        // One unread chat per project, so the collapsed-group dot has work to do.
        for project in 0..<Self.projects {
            let id = "project\(project)-chat\(40)"
            model.unreadStates[id] = SessionReadState(id: id, observedAssistantCount: 2, latestAssistantID: "m2", unreadOutputs: 1)
        }
        let streaming = SessionDisplay(id: "project0-chat1")
        streaming.state = "running"
        model.displays[streaming.id] = streaming

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 1_000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = makeSidebar(model, width: 280, height: 1_000)
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return Fixture(model: model, window: window, hosted: hosted, root: root, streaming: streaming)
    }

    /// One frame of the hosted sidebar. SwiftUI defers its own invalidation to
    /// the next run-loop pass, which a test never reaches, so the layout is
    /// asked for directly; the control below shows what that costs by itself.
    @MainActor private func redraw(_ fixture: Fixture) {
        fixture.hosted.needsLayout = true
        fixture.hosted.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
    }

    @MainActor private func time(_ label: String, repeats: Int = 12, _ body: (Int) -> Void) -> Double {
        var worst = 0.0, total = 0.0
        body(0)
        for index in 0..<repeats {
            let start = ProcessInfo.processInfo.systemUptime
            body(index)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            worst = max(worst, elapsed); total += elapsed
        }
        let mean = total / Double(repeats)
        print(String(format: "PERF sidebar %@: mean %.2f ms, worst %.2f ms over %d", label, mean * 1_000, worst * 1_000, repeats))
        return mean
    }

    /// What one streamed delta, one unread change and one selection change cost
    /// the sidebar with a real workspace in it.
    @MainActor func testSidebarRedrawCostPerWorkspaceEvent() throws {
        let fixture = try fixture()
        defer { fixture.teardown() }
        let chats = Self.projects * Self.chatsPerProject
        print("PERF sidebar fixture: \(chats) chats, \(Self.projects) projects, \(fixture.model.topics.count) topics")

        _ = time("a frame with nothing changed (control)") { _ in redraw(fixture) }
        _ = time("one streamed delta on a running chat") { index in
            fixture.streaming.messages = [TranscriptMessage(id: "m\(index)", role: "assistant",
                                                            text: String(repeating: "token ", count: 40), state: "streaming")]
            fixture.streaming.objectWillChange.send()
            redraw(fixture)
        }
        _ = time("one unread change") { index in
            let id = "project1-chat\(index)"
            fixture.model.unreadStates[id] = SessionReadState(id: id, observedAssistantCount: 1, latestAssistantID: "m",
                                                             unreadOutputs: index % 2)
            redraw(fixture)
        }
        _ = time("one selection change") { index in
            fixture.model.selectedID = "project0-chat\(index)"
            redraw(fixture)
        }
        _ = time("one collapsed project") { index in
            fixture.model.setProjectExpanded("project2", expanded: index % 2 == 0)
            redraw(fixture)
        }

        // Where the frame goes: with two of the three projects collapsed the
        // sidebar draws a third of the rows over the same 540 chats.
        fixture.model.setProjectExpanded("project1", expanded: false)
        fixture.model.setProjectExpanded("project2", expanded: false)
        redraw(fixture)
        _ = time("one selection change with two of three projects collapsed") { index in
            fixture.model.selectedID = "project0-chat\(index)"
            redraw(fixture)
        }
        fixture.model.setProjectExpanded("project1", expanded: true)
        fixture.model.setProjectExpanded("project2", expanded: true)
        redraw(fixture)

        // A used workspace: every chat has billed requests, so every row draws
        // its metrics line rather than its subtitle. The measurements above
        // are of a workspace where nothing has run yet.
        for chat in fixture.model.chats {
            var totals = GatewayTotals(requests: 9, costSamples: 9, costUSD: 3.21)
            totals.tokens = GatewayTokenTotals(total: 123_456, samples: 9)
            fixture.model.chatAccounting.publish(totals, sessionID: chat.id)
        }
        redraw(fixture)
        _ = time("one selection change with every row showing its metrics") { index in
            fixture.model.selectedID = "project0-chat\(index)"
            redraw(fixture)
        }

        // Structural, not a stopwatch. A renamed chat invalidates everything the
        // sidebar knows; drawing the next frame must answer each query once, not
        // once per group reference and once per row.
        let before = fixture.model.sidebarIndex.computations
        fixture.model.chats[7].title = "Renamed while the sidebar is up"
        redraw(fixture)
        let computed = fixture.model.sidebarIndex.computations - before
        let groups = Self.projects * (Self.topicsPerProject + 1)
        print("PERF sidebar model queries computed for one frame: \(computed) (\(groups) groups, \(Self.projects * Self.chatsPerProject) chats)")
        XCTAssertLessThanOrEqual(computed, groups + 8,
                                 "One frame recomputed \(computed) sidebar queries for \(groups) groups: a group or a row is asking again per reference")
        XCTAssertGreaterThan(computed, 0, "The rename has to invalidate what the sidebar cached")
    }

    /// Where a sidebar frame goes, part by part. Each part is hosted over the
    /// same workspace and asked to redraw after the same selection change.
    @MainActor func testWhatEachPartOfASidebarFrameCosts() throws {
        let fixture = try fixture()
        defer { fixture.teardown() }
        let model = fixture.model
        model.markedSessionIDs = ["project0-chat3", "project0-chat6"]

        func measure(_ label: String, _ view: NSView, refresh: @escaping () -> Void = {}) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 1_000),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 280, height: 1_000)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.needsLayout = true; view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            _ = time(label) { index in
                model.selectedWorkspaceID = index % 2 == 0 ? "project0" : "project1"
                model.selectedID = "project0-chat\(index)"
                refresh()
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            window.contentView = nil; window.close()
        }

        let bar = SidebarSelectionBarView(model: model)
        measure("the marked-rows bar alone", bar) { bar.refresh() }
        // The list without the column around it: the work of building its
        // entries and changing only the rows that changed.
        let list = SidebarListDocument(model: model)
        measure("the list alone, rebuilt from the model", list) {
            list.update(SidebarListContents.build(model: model, filter: "", sidebarWidth: 280, confirmingRemove: [], removing: [], dropTarget: nil),
                        width: 280, animated: false)
        }
        _ = time("building the list's entries, nothing drawn", repeats: 20) { _ in
            _ = SidebarListContents.build(model: model, filter: "", sidebarWidth: 280, confirmingRemove: [], removing: [], dropTarget: nil)
        }
        measure("the whole sidebar column", makeSidebar(model, width: 280, height: 1_000))
    }

    /// The model work behind one sidebar pass, measured without SwiftUI in the
    /// way. A group recomputes `sidebarEntries` several times per body, every
    /// group of every project does it again, and every row asks the model for
    /// its record by scanning the whole chat list.
    @MainActor func testSidebarModelQueriesAreNotRepeatedScansOfEveryChat() throws {
        let fixture = try fixture()
        defer { fixture.teardown() }
        let model = fixture.model

        _ = time("sidebarEntries for one topic", repeats: 200) { _ in
            _ = model.sidebarEntries(in: "project0", topicID: "project0-topic1", archived: false, collapsed: [])
        }
        _ = time("sidebarChatOrder", repeats: 50) { _ in _ = model.sidebarChatOrder }
        _ = time("record() for every chat", repeats: 5) { _ in
            for chat in model.chats { _ = model.record(chat.id) }
        }
        _ = time("unread dot for a collapsed project", repeats: 20) { _ in
            _ = model.chats.contains { $0.workspaceID == "project1" && model.unreadOutputCount(sessionID: $0.id) > 0 }
        }
        // Two unarchived chats at the project's root, sixty rows apart.
        model.selectedID = "project0-chat3"
        model.extendSessionMarks(to: "project0-chat63")
        XCTAssertGreaterThan(model.markedChats.count, 10)
        _ = time("markedChats with a marked range", repeats: 20) { _ in _ = model.markedChats.count }
        model.clearSessionMarks()
    }
}
