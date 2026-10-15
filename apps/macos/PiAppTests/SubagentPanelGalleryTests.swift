import AppKit
import Darwin
import XCTest
@testable import PiApp

final class SubagentPanelGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testOriginalReaderForkGallery() async throws {
        guard let path = testEnvironment("PI_APP_ORIGINAL_GALLERY") else { throw XCTSkip("Set PI_APP_ORIGINAL_GALLERY") }
        let folder = URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fixture = try SubagentGalleryFixture(root:folder.appendingPathComponent("fixture-" + UUID().uuidString))
        let model = fixture.model, window = fixture.window
        model.chats.removeAll { $0.isSubagent }
        model.chats[0].title = "Parser review"
        let saved = try SubagentDiscoveryTests.family(model)
        try await model.store?.putChats(model.chats); await model.reconcileSubagents()
        let parent = model.chats[0], child = try XCTUnwrap(model.record(saved.child)), target = SubagentTarget(child.delegation!)
        let source = URL(fileURLWithPath:parent.path!), forkPath = source.deletingLastPathComponent().appendingPathComponent("fork.jsonl")
        var rows = try String(contentsOf:source,encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode([String:WireValue].self,from:Data($0.utf8)) }
        rows[0]["id"] = .string("fork")
        var bytes = Data(); for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }; try bytes.write(to:forkPath)
        var fork = parent; fork.id = "fork"; fork.title = "Parser review · fork"; fork.path = forkPath.path; fork.parentSessionID = parent.id
        model.chats.append(fork)
        var tool = SubagentTranscriptTests.tool
        tool.name = "subagent_start"; tool.input = "{\"description\":\"Parser review\",\"task\":\"Check **token boundaries** and report any ambiguities.\"}"
        tool.output = "{\"text\":\"The parser checks passed. Escaped scalars retain their source spans.\"}"
        var meta = SubagentTranscriptTests.metadata.object!; meta["sessionId"] = .string(child.id); tool.nativeSubagent = .object(meta)
        let savedTool = tool
        model.historyWindowLoader = { id,_,_,_ in
            var page = try ConversationHistoryPage(.object(["version":.number(2),"incarnation":.string(id),"lineage":.string("root"),"messages":.array([]),"older":.null,"newer":.null]))
            page.messages = id == "fork" ? [.init(id:"question",role:"user",text:"Continue the review from this saved result."),
                .init(id:"reply",role:"assistant",text:"The original review is available below.",tools:[savedTool])] :
                [.init(id:"task",role:"user",text:"Check token boundaries."),.init(id:"answer",role:"assistant",text:"## Parser checks\n\nAll **token boundary** cases passed.\n\n- Preserve source spans for escaped scalars.\n- Keep recovery checks beside each parser fixture.\n\n```swift\nlet span = token.sourceRange\n```\n\nThe original task and its captured requests remain in the original chat.")]
            return page
        }
        await model.select(fork.id)
        let display = try XCTUnwrap(model.selected)
        display.disclosure.setOpen(true,.work("reply")); display.disclosure.setOpen(true,.tool(ToolOccurrence.key("reply",tool.id)))
        var own = child; own.id = "fork-agent"; own.title = "Review follow-up tests"; own.path = nil; own.parentSessionID = fork.id; own.subagentNumber = 2
        own.delegation?.childSessionID = own.id; own.delegation?.budgetOwnerSessionID = fork.id; own.delegation?.call.parentSessionID = fork.id
        model.chats.append(own); model.subagentSummaries[own.id] = .init(link:own.delegation!,description:own.title,model:"fixture-model",status:.completed,revision:1)
        let root = WorkspaceRootView(model:model); window.contentView = root
        let opened = await model.openOriginalSubagent(target,from:fork.id); XCTAssertTrue(opened)
        defer { fixture.close() }
        addTeardownBlock { @MainActor in model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        var files: [String] = []
        for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:appearance)
            for size in [NSSize(width:1240,height:800),NSSize(width:920,height:600)] {
                window.setContentSize(size); root.refresh(); await settle(window)
                _ = await model.revealInTranscript(sessionID:fork.id,messageID:"reply",toolCallID:tool.id); await settle(window)
                let base = "original-\(theme)-\(Int(size.width))x\(Int(size.height))"
                try capture([window],to:folder.appendingPathComponent(base + ".png")); files.append(base + ".png")
                let header = try XCTUnwrap(root.conversation?.agentFamilyHeader)
                header.open(); await settle(window)
                let popup = try XCTUnwrap(header.popover.popover?.contentViewController?.view.window)
                try capture([popup,window],to:folder.appendingPathComponent(base + "-picker.png")); files.append(base + "-picker.png")
                header.popover.close()
                XCTAssertTrue(model.subagentTab(child.id)?.pane?.composer.isHidden == true)
            }
        }
        try (files.joined(separator:"\n") + "\n").write(to:folder.appendingPathComponent("manifest.txt"),atomically:true,encoding:.utf8)
    }
    @MainActor func testNestedFamilyPickerGallery() async throws {
        guard let path = testEnvironment("PI_APP_SUB_NESTED_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_NESTED_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        let model = fixture.model, window = fixture.window
        fixture.show("completed"); fixture.parent.runState = .idle
        fixture.parent.messages = [.init(id: "question", role: "user", text: "Review the parser and keep follow-up branches for recovery and Unicode checks."),
            .init(id: "answer", role: "assistant", text: "The review notes and their follow-up branches are ready. Open Sides and Agents to browse the saved review tree and the checks delegated within each branch.")]
        model.chats.removeAll { $0.isSubagent && $0.id != "child-0" }
        model.subagentSummaries = model.subagentSummaries.filter { $0.key == "child-0" }
        let profile = fixture.records[0].profileID
        for (id, parent, title) in [("review", fixture.parent.id, "Review notes"), ("fork", "review", "Parser recovery follow-up"), ("deep", "fork", "Verify malformed Unicode cases")] {
            let chat = ChatRecord(id: id, workspaceID: "pane-project", title: title, profileID: profile, parentSessionID: parent)
            model.chats.append(chat)
            let display = SessionDisplay(id: id); display.historyState = .ready; display.draftReady = true
            var totals = GatewayTotals(); totals.costSamples = 1; totals.costUSD = 0.04
            display.footer.gateway = totals; model.displays[id] = display
        }
        let original = try XCTUnwrap(model.record("child-0"))
        for (owner, title, status) in [("fork", "Review recovery paths", SubagentStatus.completed), ("deep", "Check escaped scalars", .running)] {
            var child = original; child.id = owner + "-agent"; child.title = title; child.parentSessionID = owner; child.subagentNumber = 1
            child.delegation?.childSessionID = child.id; child.delegation?.budgetOwnerSessionID = owner; child.delegation?.call.parentSessionID = owner
            model.chats.append(child)
            model.subagentSummaries[child.id] = .init(link: child.delegation!, description: title, model: "fixture-model", status: status, revision: 1)
        }
        let root = WorkspaceRootView(model: model); window.contentView = root
        let previousMotion = PiKit.Motion.reducedOverride; PiKit.Motion.reducedOverride = true
        defer { PiKit.Motion.reducedOverride = previousMotion; fixture.close() }
        addTeardownBlock { @MainActor in model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        var files: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600)] {
                window.setContentSize(size); root.refresh(); await settle(window)
                let header = try XCTUnwrap(root.conversation?.agentFamilyHeader)
                XCTAssertEqual(header.button.title, "3 sides · 3 agents")
                header.open(); await settle(window)
                let content = try XCTUnwrap(header.popover.popover?.contentViewController?.view), popup = try XCTUnwrap(content.window)
                let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: content).filter { $0.accessibilityIdentifier().hasPrefix("open-") }
                XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, 2, 0])
                XCTAssertGreaterThanOrEqual(popup.frame.minX, window.frame.minX); XCTAssertLessThanOrEqual(popup.frame.maxX, window.frame.maxX)
                XCTAssertGreaterThanOrEqual(popup.frame.minY, window.frame.minY)
                for row in rows { XCTAssertTrue(content.visibleRect.contains(row.convert(row.bounds, to: content)), row.primary) }
                let file = "nested-\(theme)-\(Int(size.width))x\(Int(size.height)).png"
                try capture([popup, window], to: folder.appendingPathComponent(file)); files.append(file)
                header.popover.close()
            }
        }
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor func testMainColumnFamilyAndChildTabGallery() async throws {
        guard let path = testEnvironment("PI_APP_SUB_PANEL_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_PANEL_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        let model = fixture.model, window = fixture.window
        model.historyWindowLoader = { id, _, _, _ in
            let reply = id.hasPrefix("child") ? "The tokenizer handles UTF-8 boundaries correctly. Preserve the diagnostic span before advancing the recovery cursor." : "The saved side keeps these review notes and its own draft beside the main chat."
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture-" + id), "lineage": .string("root"),
                "messages": .array([.object(["id": .string(id + "-reply"), "role": .string("assistant"), "text": .string(reply)])]), "older": .null, "newer": .null]))
        }
        let root = WorkspaceRootView(model: model); window.contentView = root
        let previousMotion = PiKit.Motion.reducedOverride; PiKit.Motion.reducedOverride = true
        defer { PiKit.Motion.reducedOverride = previousMotion; fixture.close() }
        addTeardownBlock { @MainActor in model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        var files: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                window.setContentSize(size)
                for done in [false, true] {
                    for tab in model.tabs.allTabs { model.tabs.close(tab) }
                    model.sides = [:]
                    fixture.show(done ? "completed" : "parallel-queued")
                    for index in 0..<2 {
                        let id = "saved-side-\(index)"
                        let chat = ChatRecord(id: id, workspaceID: "pane-project", title: index == 0 ? "Review notes" : "Release checklist", profileID: fixture.records[0].profileID, sidebarOrder: Int64(2 - index), parentSessionID: fixture.parent.id)
                        model.chats.append(chat)
                        let display = SessionDisplay(id: id); display.historyState = .ready; display.draftReady = true
                        display.runState = !done && index == 0 ? .running : .idle
                        var totals = GatewayTotals(); totals.costSamples = 1; totals.costUSD = index == 0 ? 0.025 : 0.012
                        display.footer.gateway = totals; model.displays[id] = display
                    }
                    model.readStatesRestored = true
                    model.unreadStates["saved-side-1"] = .init(id: "saved-side-1", observedAssistantCount: 1, latestAssistantID: "side-reply", unreadOutputs: 1, unreadFailure: done)
                    if done { fixture.parent.runState = .idle; fixture.parent.runStatus = "idle" }
                    fixture.child.subagentStatus = done ? .completed : .running
                    fixture.child.runState = done ? .idle : .running
                    fixture.child.runStatus = done ? "idle" : "streaming"
                    root.refresh(); await settle(window)
                    let main = try XCTUnwrap(root.conversation)
                    XCTAssertFalse(main.agentFamilyHeader.isHidden)
                    XCTAssertEqual(main.agentFamilyHeader.button.title, "2 sides · 4 agents")
                    XCTAssertEqual(ConversationPaneTests.views(PiSpinnerView.self, in: main.agentFamilyHeader).count, done ? 0 : 1)
                    if let parentRow = root.sidebar.list.views["chat|chat-parent"] as? SidebarChatRowView {
                        XCTAssertEqual(ConversationPaneTests.views(PiSpinnerView.self, in: parentRow).count, done ? 0 : 1)
                    }
                    let base = "\(done ? "done" : "running")-\(theme)-\(Int(size.width))x\(Int(size.height))"
                    try capture([window], to: folder.appendingPathComponent(base + "-closed.png")); files.append(base + "-closed.png")
                    main.agentFamilyHeader.open(); await settle(window)
                    let popup = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                    XCTAssertGreaterThanOrEqual(popup.frame.minX, window.frame.minX)
                    XCTAssertLessThanOrEqual(popup.frame.maxX, window.frame.maxX, "The picker stays inside its owning window")
                    XCTAssertGreaterThanOrEqual(popup.frame.minY, window.frame.minY)
                    XCTAssertLessThanOrEqual(popup.frame.maxY, window.frame.maxY)
                    try capture([popup, window], to: folder.appendingPathComponent(base + "-open.png")); files.append(base + "-open.png")
                    let content = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view)
                    let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.ButtonBase.self, in: content).first { $0.accessibilityIdentifier() == "open-agent-child-0" })
                    XCTAssertTrue(open.accessibilityLabel()?.contains("Sub-agent 1") == true)
                    let list = try XCTUnwrap(ConversationPaneTests.views(AgentFamilyPopoverView.self, in: content).first)
                    if size.width == 1240 {
                        let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: list).filter { $0.accessibilityIdentifier().hasPrefix("open-") }
                        XCTAssertEqual(rows.count, 6)
                        for row in rows { XCTAssertTrue(list.visibleRect.contains(row.convert(row.bounds, to: list)), row.primary + " must fit without scrolling") }
                    }
                    let tabKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: popup.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                    list.keyDown(with: tabKey)
                    XCTAssertEqual((popup.firstResponder as? PiKit.ButtonBase)?.accessibilityIdentifier(), "open-side-saved-side-0")
                    let footer = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: content).first { $0.title == "Inspect Family" })
                    footer.scrollToVisible(footer.bounds); await settle(window)
                    try capture([popup, window], to: folder.appendingPathComponent(base + "-open-footer.png")); files.append(base + "-open-footer.png")
                    if !done {
                        let stop = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: content).first { $0.title == "Stop All…" })
                        var reviewed = false
                        model.questions.presentSheet = { sheet, owner, answer in
                            XCTAssertTrue(owner === window)
                            XCTAssertTrue(sheet is AgentStopAllSheet)
                            reviewed = true; answer(false)
                        }
                        stop.onPress?(); XCTAssertTrue(reviewed)
                        model.questions.presentSheet = nil
                    }
                    main.agentFamilyHeader.popover.close()
                    await model.openSubagentTab("child-0")
                    root.refresh(); await settle(window)
                    let tab = try XCTUnwrap(model.subagentTab("child-0")), pane = try XCTUnwrap(model.subagentTab("child-0")?.pane)
                    XCTAssertTrue(pane.composer.isHidden); XCTAssertTrue(pane.agentFamilyHeader.isHidden)
                    XCTAssertEqual(model.selectedID, fixture.parent.id)
                    let mainBounds = main.convert(main.bounds, to: root)
                    let pill = main.agentFamilyHeader.button.convert(main.agentFamilyHeader.button.bounds, to: root)
                    let childBounds = pane.convert(pane.bounds, to: root)
                    XCTAssertLessThanOrEqual(pill.maxX, mainBounds.maxX)
                    XCTAssertLessThanOrEqual(mainBounds.maxX, childBounds.minX)
                    XCTAssertGreaterThanOrEqual(main.transcript.frame.minY, main.agentFamilyHeader.frame.maxY)
                    try capture([window], to: folder.appendingPathComponent(base + "-side.png")); files.append(base + "-side.png")
                    XCTAssertEqual(tab.stripTitle, "#1 · Check token boundaries")
                    let tabLabels = ConversationPaneTests.views(TabItemLabelView.self, in: root).filter { $0.accessibilityLabel()?.contains("Sub-agent 1") == true }
                    XCTAssertFalse(tabLabels.isEmpty); XCTAssertTrue(tabLabels.allSatisfy(\.truncatesAtEnd))
                    main.agentFamilyHeader.open(); await settle(window)
                    let sidePopup = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                    XCTAssertGreaterThanOrEqual(sidePopup.frame.minX, window.frame.minX)
                    XCTAssertLessThanOrEqual(sidePopup.frame.maxX, window.frame.maxX)
                    XCTAssertGreaterThanOrEqual(sidePopup.frame.minY, window.frame.minY)
                    XCTAssertLessThanOrEqual(sidePopup.frame.maxY, window.frame.maxY)
                    try capture([sidePopup, window], to: folder.appendingPathComponent(base + "-side-open.png")); files.append(base + "-side-open.png")
                    main.agentFamilyHeader.popover.close()
                    await model.openFamilySide("saved-side-0"); root.refresh(); await settle(window)
                    XCTAssertTrue(model.tabs.pane.sideShown)
                    XCTAssertEqual(model.selectedID, fixture.parent.id)
                    try capture([window], to: folder.appendingPathComponent(base + "-ordinary-side.png")); files.append(base + "-ordinary-side.png")
                    await model.openSubagentTab("child-0"); XCTAssertTrue(model.subagentTab("child-0") === tab)
                    XCTAssertTrue(window.firstResponder === pane)
                    await model.backToSubagentParent("child-0")
                    XCTAssertEqual(model.focusedSessionID, fixture.parent.id)
                    if done {
                        let index = try XCTUnwrap(model.chats.firstIndex { $0.id == "child-1" }), original = model.chats[index]
                        model.chats[index].parentSessionID = "saved-side-0"
                        model.chats[index].delegation?.budgetOwnerSessionID = "saved-side-0"
                        model.chats[index].subagentNumber = 1
                        root.refresh(); await settle(window)
                        main.agentFamilyHeader.open(); await settle(window)
                        let grouped = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                        try capture([grouped, window], to: folder.appendingPathComponent(base + "-side-family.png")); files.append(base + "-side-family.png")
                        main.agentFamilyHeader.popover.close()
                        await model.openSubagentTab("child-1"); root.refresh(); await settle(window)
                        XCTAssertEqual(model.selectedID, fixture.parent.id)
                        try capture([window], to: folder.appendingPathComponent(base + "-side-agent.png")); files.append(base + "-side-agent.png")
                        await model.backToSubagentParent("child-1")
                        XCTAssertEqual(model.focusedSessionID, "saved-side-0")
                        model.chats[index] = original
                        await model.openSubagentTab("child-0"); await settle(window)
                        model.tabs.popOut(tab); await settle(window)
                        let popped = try XCTUnwrap(tab.container.flatMap { model.tabs.window(of: $0) })
                        popped.appearance = window.appearance; await settle(popped)
                        XCTAssertFalse(pane.agentFamilyHeader.isHidden)
                        XCTAssertTrue(popped.title.contains("Sub-agent 1"))
                        pane.agentFamilyHeader.open(); await settle(popped)
                        let siblingPopup = try XCTUnwrap(pane.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                        try capture([siblingPopup, popped], to: folder.appendingPathComponent(base + "-window.png")); files.append(base + "-window.png")
                        pane.agentFamilyHeader.popover.close()
                        model.tabs.moveToPane(tab); await settle(window)
                    }
                }
            }
        }
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.setContentSize(NSSize(width: 920, height: 600))
            for tab in model.tabs.allTabs { model.tabs.close(tab) }
            model.sides = [:]; fixture.show("completed")
            fixture.parent.runState = .idle; fixture.child.runState = .idle
            model.chats[1].title = "Check token boundaries across malformed escape sequences and Unicode recovery spans"
            await model.openSubagentTab("child-0"); root.refresh(); await settle(window)
            try capture([window], to: folder.appendingPathComponent("long-tab-" + theme + ".png")); files.append("long-tab-" + theme + ".png")
            for tab in model.tabs.allTabs { model.tabs.close(tab) }
            root.refresh(); await settle(window)
            try capture([window], to: folder.appendingPathComponent("agents-only-" + theme + ".png")); files.append("agents-only-" + theme + ".png")
            model.chats.removeAll { $0.isSubagent }; model.subagentSummaries = [:]
            fixture.parent.messages = [.init(id: "side-question", role: "user", text: "Collect the review notes."), .init(id: "side-answer", role: "assistant", text: "The review notes are ready. Open a side to collect follow-up questions.")]
            model.openNewFamilySide(fixture.parent.id)
            root.refresh(); await settle(window)
            let main = try XCTUnwrap(root.conversation)
            XCTAssertEqual(main.agentFamilyHeader.button.title, "1 side")
            let right = try XCTUnwrap(root.rightPane)
            let draft = try XCTUnwrap(ConversationPaneTests.views(SidePaneView.self, in: right).first)
            let draftFrame = draft.convert(draft.bounds, to: root)
            let rightFrame = right.convert(right.bounds, to: root)
            XCTAssertGreaterThanOrEqual(draftFrame.minX, rightFrame.minX)
            XCTAssertLessThanOrEqual(draftFrame.maxX, rightFrame.maxX)
            XCTAssertLessThanOrEqual(main.agentFamilyHeader.convert(main.agentFamilyHeader.bounds, to: root).maxX, draftFrame.minX)
            try capture([window], to: folder.appendingPathComponent("side-draft-" + theme + ".png")); files.append("side-draft-" + theme + ".png")
            main.agentFamilyHeader.open(); await settle(window)
            let popup = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
            try capture([popup, window], to: folder.appendingPathComponent("sides-only-" + theme + ".png")); files.append("sides-only-" + theme + ".png")
            main.agentFamilyHeader.popover.close()
        }
        XCTAssertEqual(files.count, 68)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor private func settle(_ window: NSWindow) async {
        for _ in 0..<4 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(75)) }
    }
    /// Only this fixture's windows, including its own popup. Never the desktop.
    @MainActor private func capture(_ windows: [NSWindow], to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let union = windows.reduce(CGRect.null) { $0.union($1.frame) }
        let screen = NSScreen.screens.first?.frame ?? .zero
        let scale = windows.first?.backingScaleFactor ?? 1
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        for window in windows.reversed() {
            let frame = window.frame
            let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
            let image = try XCTUnwrap(create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
            context.draw(image, in: CGRect(x: frame.minX - union.minX, y: frame.minY - union.minY, width: frame.width, height: frame.height))
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
