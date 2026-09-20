import XCTest
import AppKit
import SwiftUI
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
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
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
        window.contentView = NSHostingView(rootView: SidebarScaleHost(model: model)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
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

    /// Where the part of a sidebar frame that does not scale with rows goes.
    /// Each probe is hosted over the same workspace and asked to redraw after
    /// the same selection change the real sidebar answers in about 15 ms.
    @MainActor func testWhatEachPartOfASidebarFrameCosts() throws {
        let fixture = try fixture()
        defer { fixture.teardown() }
        let model = fixture.model
        model.markedSessionIDs = ["project0-chat3", "project0-chat6"]
        let projects = model.workspaces

        func measure(_ label: String, _ view: some View) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 1_000),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AnyView(view).transaction { $0.animation = nil; $0.disablesAnimations = true })
            window.makeKeyAndOrderFront(nil)
            guard let hosted = window.contentView else { return }
            hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            _ = time(label) { index in
                model.selectedWorkspaceID = index % 2 == 0 ? "project0" : "project1"
                model.selectedID = "project0-chat\(index)"
                hosted.needsLayout = true
                hosted.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            window.contentView = nil; window.close()
        }

        measure("three project headers with their menus", HeaderProbe(model: model, projects: projects, menus: true))
        measure("three project headers without their menus", HeaderProbe(model: model, projects: projects, menus: false))
        measure("twelve project headers with their menus",
                HeaderProbe(model: model, projects: projects + projects + projects + projects, menus: true))
        measure("twelve project headers without their menus",
                HeaderProbe(model: model, projects: projects + projects + projects + projects, menus: false))
        measure("the project list host alone", ProjectListProbe(model: model))
        measure("the marked-rows bar alone", SelectionBarProbe(model: model))

        // The rows themselves, with and without the drag surface every
        // draggable row carries.
        let rows = Array(model.chats.filter { $0.workspaceID == "project0" && !$0.isArchived }.prefix(24))
        measure("twenty-four rows with their drag surface", RowProbe(model: model, chats: rows, dragging: true))
        measure("twenty-four rows without their drag surface", RowProbe(model: model, chats: rows, dragging: false))
        let few = Array(rows.prefix(8))
        measure("eight rows with their drag surface", RowProbe(model: model, chats: few, dragging: true))
        measure("eight rows without their drag surface", RowProbe(model: model, chats: few, dragging: false))

        // The real group, so the difference from the parts above is whatever
        // the group itself adds: its drop zones, its topic groups and the
        // per-group work that does not belong to any row.
        measure("twenty-four rows with their tooltip and right-click menu",
                RowProbe(model: model, chats: rows, dragging: true, chrome: true))
        // The rows the sidebar actually draws: same press surface, menu and
        // drag source, compared on their values instead of rebuilt.
        measure("twenty-four real rows, compared not rebuilt", EquatableRowProbe(model: model, chats: rows))

        // The two things a real group wraps its rows in that a bare list does not.
        measure("twenty-four rows inside one drop zone",
                RowProbe(model: model, chats: rows, dragging: true)
                    .contentShape(Rectangle())
                    .onDrop(of: [TopicSessionDrag.type], isTargeted: .constant(false)) { _ in false })
        measure("twenty-four rows inside four nested drop zones",
                RowProbe(model: model, chats: rows, dragging: true)
                    .contentShape(Rectangle())
                    .onDrop(of: [TopicSessionDrag.type], isTargeted: .constant(false)) { _ in false }
                    .contentShape(Rectangle())
                    .onDrop(of: [TopicSessionDrag.type], isTargeted: .constant(false)) { _ in false }
                    .contentShape(Rectangle())
                    .onDrop(of: [TopicSessionDrag.type], isTargeted: .constant(false)) { _ in false }
                    .contentShape(Rectangle())
                    .onDrop(of: [TopicSessionDrag.type], isTargeted: .constant(false)) { _ in false })

        // What a row is made of.
        measure("24 rows: settled, values only", ChatRowContentProbe(model: model, chats: rows, shape: .plain))
        measure("24 rows: settled, each observing its accounting", ChatRowContentProbe(model: model, chats: rows, shape: .observed))
        measure("24 rows: with a metrics line (ViewThatFits)", ChatRowContentProbe(model: model, chats: rows, shape: .metrics))
        measure("24 rows: the same figures in one layout", ChatRowContentProbe(model: model, chats: rows, shape: .metricsSingle))
        measure("24 rows: metrics line and accounting observable", ChatRowContentProbe(model: model, chats: rows, shape: .observedMetrics))
        measure("24 rows: hand-built with hover and two animations", ChatRowContentProbe(model: model, chats: rows, shape: .handmade))
        measure("24 rows: hand-built with hover only", ChatRowContentProbe(model: model, chats: rows, shape: .handmadeHover))
        measure("24 rows: hand-built with the two animations only", ChatRowContentProbe(model: model, chats: rows, shape: .handmadeAnimated))
        measure("24 rows: hand-built with neither", ChatRowContentProbe(model: model, chats: rows, shape: .handmadeStill))

        let project = try XCTUnwrap(model.workspaces.first)
        measure("one real project group", ProjectSidebarGroup(model: model, project: project, available: true, name: "project0"))
        measure("three real project groups", SidebarScaleHost(model: model))
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

/// What one project header is made of, so each part can be priced on its own.
/// A faithful copy rather than the header itself: the question is what a
/// `Menu` and a `contextMenu` cost when the whole sidebar is invalidated, and
/// the real header cannot be asked to leave them out.
private struct HeaderProbe: View {
    @ObservedObject var model: WorkspaceModel
    let projects: [WorkspaceRecord]
    let menus: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(projects) { project in
                header(project)
            }
        }.padding(.horizontal, PiSpacing.sm)
    }
    @ViewBuilder private func header(_ project: WorkspaceRecord) -> some View {
        let strip = HStack(spacing: 4) {
            Button { } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                    Text(project.id).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(model.selectedWorkspaceID == project.id ? Color.piInk : Color.piInkSecondary)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).piPointer()
            PiIconButton(symbol: "arrow.triangle.branch", label: "Changes", size: 22) { }
            PiIconButton(symbol: "plus", label: "New chat", size: 22) { }
            if menus {
                Menu { actions(project) } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer()
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        if menus { strip.contextMenu { actions(project) } } else { strip }
    }
    @ViewBuilder private func actions(_ project: WorkspaceRecord) -> some View {
        Button("New Chat", systemImage: "square.and.pencil") { }
        Button("New Topic…", systemImage: "folder.badge.plus") { }
        Button("Changes and History…", systemImage: "arrow.triangle.branch") { }
        Button("Collapse Project") { }
        Button("Show Archived Chats", systemImage: "archivebox") { }
        Divider()
        Button("Manage Project…", systemImage: "folder.badge.gearshape") { }
    }
}

/// Chat rows as the sidebar builds them, with and without the AppKit drag
/// surface each draggable row carries. The surface is an overlay over a
/// preference the row publishes, which makes SwiftUI resolve preferences and
/// lay the row out again; this prices that.
private struct RowProbe: View {
    @ObservedObject var model: WorkspaceModel
    let chats: [ChatRecord]
    let dragging: Bool
    /// The tooltip and the right-click menu every real row also carries.
    var chrome = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(chats) { chat in
                row(chat)
            }
        }.padding(.horizontal, PiSpacing.sm)
    }
    @ViewBuilder private func row(_ chat: ChatRecord) -> some View {
        let built = PiSelectableRow(selected: model.selectedID == chat.id, providesCursor: !dragging, action: { }) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left").font(.system(size: 12, weight: .medium))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(chat.title).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    PiIconButton(symbol: "archivebox", label: "Archive chat", size: 18) { }
                                }
                                .anchorPreference(key: SidebarRowControlBounds.self, value: .bounds) { [$0] }
                            }
                            Text("Ready").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                        }
                    }
                }
        if chrome {
            built
                .help("Ready · 4 requests · cache 2 hit / 1 miss")
                .contextMenu {
                    Button("Rename…") { }
                    Button("Pin Chat", systemImage: "pin") { }
                    Button("Archive Chat", systemImage: "archivebox") { }
                    Menu { Button("Project root", systemImage: "tray") { } } label: { Label("Move to Topic", systemImage: "folder") }
                    Divider()
                    Button("Copy Session ID", systemImage: "number") { }
                }
                .modifier(TopicSessionDragSource(model: model, sessionID: chat.id, projectID: chat.workspaceID,
                                                 enabled: dragging, click: { _ in }, doubleClick: { }))
                .padding(.leading, 14)
        } else {
            built
                .modifier(TopicSessionDragSource(model: model, sessionID: chat.id, projectID: chat.workspaceID,
                                                 enabled: dragging, click: { _ in }, doubleClick: { }))
                .padding(.leading, 14)
        }
    }
}

/// What a chat row is made of, priced piece by piece: the per-row observable
/// that carries retained billing, the metrics line that picks its layout by
/// trying several, and the animations and hover the row hangs off itself.
private struct ChatRowContentProbe: View {
    enum Shape {
        case plain, observed, metrics, metricsSingle, observedMetrics, handmade, handmadeStill, handmadeHover, handmadeAnimated
        var activity: Bool { self == .metrics || self == .observedMetrics }
    }
    @ObservedObject var model: WorkspaceModel
    let chats: [ChatRecord]
    let shape: Shape
    /// Retained figures for a settled row: what the accounting cache holds.
    private func totals() -> GatewayTotals {
        var value = GatewayTotals(requests: 7, costSamples: 7, costUSD: 1.2345)
        value.tokens = GatewayTokenTotals(total: 98_765, samples: 7)
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(chats) { chat in row(chat) }
        }.padding(.horizontal, PiSpacing.sm)
    }
    @ViewBuilder private func row(_ chat: ChatRecord) -> some View {
        switch shape {
        case .plain, .metrics:
            rowBody(chat, stats: ChatRowStats(totals: shape.activity ? totals() : nil))
        case .metricsSingle:
            // The same figures the metrics line shows, in the one layout
            // `ViewThatFits` would have chosen at this width.
            PiSelectableRow(selected: model.selectedID == chat.id, action: { }) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "bubble.left").font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(chat.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        HStack(spacing: 6) {
                            Text("$1.23")
                            Text("· 98.8k tok")
                            Text("· 3m ago")
                        }
                        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        case .observed, .observedMetrics:
            RetainedAccountingRow(accounting: model.chatAccounting.row(for: chat.id)) { retained in
                rowBody(chat, stats: ChatRowStats(totals: shape.activity ? (retained ?? totals()) : nil))
            }
        case .handmade, .handmadeStill, .handmadeHover, .handmadeAnimated:
            handmade(chat)
        }
    }
    private func rowBody(_ chat: ChatRecord, stats: ChatRowStats) -> some View {
        PiSelectableRow(selected: model.selectedID == chat.id, action: { }) {
            ChatRowBody(stats: stats, title: chat.title, subtitle: "Ready", symbol: "bubble.left",
                        selected: model.selectedID == chat.id).equatable()
        }
    }
    /// The same row drawn by hand, so the animations and the hover it carries
    /// can be left out one at a time.
    @ViewBuilder private func handmade(_ chat: ChatRecord) -> some View {
        let content = HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(chat.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text("Ready").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
            }
        }
        PiSelectableRow(selected: model.selectedID == chat.id, action: { }) {
            switch shape {
            case .handmadeStill:
                content.help("Ready")
            case .handmadeHover:
                content.help("Ready").onHover { _ in }
            case .handmadeAnimated:
                content.help("Ready")
                    .piAnimation(PiMotion.spring, value: model.selectedID == chat.id)
                    .piAnimation(PiMotion.quick, value: model.selectedID == chat.id)
            default:
                content.help("Ready").onHover { _ in }
                    .piAnimation(PiMotion.spring, value: model.selectedID == chat.id)
                    .piAnimation(PiMotion.quick, value: model.selectedID == chat.id)
            }
        }
    }
}

/// The bare host: the project groups' own `ForEach` with nothing in it.
private struct ProjectListProbe: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(model.sidebarProjects) { project in
                    Text(project.name).font(PiFont.caption)
                        .foregroundStyle(model.selectedWorkspaceID == project.id ? Color.piInk : Color.piInkSecondary)
                }
            }.padding(.horizontal, PiSpacing.sm)
        }
    }
}

/// The marked-rows bar on its own.
private struct SelectionBarProbe: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        SidebarSelectionBar(model: model).padding(.horizontal, PiSpacing.md)
    }
}

/// The sidebar's own list, hosted without the window chrome and the content
/// pane so a redraw measures the sidebar and nothing else.
private struct SidebarScaleHost: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(model.sidebarProjects) { project in
                    ProjectSidebarGroup(model: model, project: project.record, available: project.available, name: project.name)
                }
            }.padding(.horizontal, PiSpacing.sm)
        }
    }
}

/// The real sidebar row, which is `Equatable` on the chat record and the small
/// state its group looks up for it. A workspace change that this row does not
/// show must leave its whole subtree — press surface, menu, drag source —
/// standing rather than rebuilt.
private struct EquatableRowProbe: View {
    @ObservedObject var model: WorkspaceModel
    let chats: [ChatRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(chats) { chat in
                SidebarChatRow(model: model, chat: chat, projectID: chat.workspaceID,
                               state: SidebarChatRowState(selected: model.selectedID == chat.id,
                                                          marked: model.isSessionMarked(chat.id),
                                                          anyMarked: model.hasMarkedSessions,
                                                          unreadCount: model.unreadOutputCount(sessionID: chat.id),
                                                          draggable: true, subtitle: "Ready",
                                                          available: 240, indent: 14))
                    .equatable()
            }
        }.padding(.horizontal, PiSpacing.sm)
    }
}
