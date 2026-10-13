import AppKit
import QuartzCore
import XCTest
@testable import PiApp

@MainActor final class SidebarDocumentRegressionTests: XCTestCase {
    private func fixture() -> (WorkspaceModel, SidebarListDocument, NSScrollView) {
        let root = scratchRoot("sidebar-document-regression")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let document = SidebarListDocument(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 320))
        scroll.documentView = document
        addTeardownBlock { @MainActor in
            scroll.documentView = nil; model.shutdown(); try? FileManager.default.removeItem(at: root)
        }
        return (model, document, scroll)
    }
    private func contents(_ range: Range<Int>, model: WorkspaceModel, available: CGFloat = 300, metrics: Bool = false) -> SidebarListContents {
        let entries: [SidebarEntry] = range.map { i in
            let id = "chat-\(i)"
            let chat = ChatRecord(id: id, workspaceID: "project", title: "Chat \(i)", path: nil, profileID: "fixture")
            if metrics, model.displays[id] == nil {
                let display = SessionDisplay(id: id)
                display.footer.gateway = GatewayTotals(requests: 3, costSamples: 3, costUSD: 12.34)
                display.footer.timing = SessionTimingHistory(samples: [
                    SessionTimingSample(id: id, wall: Date(), ttftMilliseconds: 320, streamingMilliseconds: 1_400,
                                        outputTokens: 512, costUSD: 0.12, requestMilliseconds: 1_720)
                ])
                model.displays[id] = display
            }
            let state = SidebarChatRowState(liveIdentity: model.displays[id].map(ObjectIdentifier.init), available: available)
            return .chat(chat: chat, state: state, projectID: "project")
        }
        return SidebarListContents(entries: entries, gaps: Array(repeating: 3, count: entries.count),
                                   owners: Array(repeating: (project: "project", topic: nil), count: entries.count))
    }
    private func scroll(_ scroll: NSScrollView, _ document: SidebarListDocument, to id: String, offset: CGFloat = 0) throws {
        let frame = try XCTUnwrap(document.frame(of: id))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: frame.minY + offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        document.materialize()
    }
    private func hostForMotion(_ view: NSView) {
        let reduced = PiKit.Motion.reducedOverride
        PiKit.Motion.reducedOverride = false
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close(); PiKit.Motion.reducedOverride = reduced
        }
    }
    private func glideStart(of view: NSView, in scroll: NSScrollView) -> CGFloat {
        let animation = view.layer?.animation(forKey: "glide") as? CABasicAnimation
        let translation = (animation?.fromValue as? NSNumber)?.doubleValue ?? 0
        return view.frame.minY + CGFloat(translation) - scroll.contentView.bounds.minY
    }

    func testAnimatedChangesAboveTheViewportKeepTheAnchorStillAndLocalMovesGlide() throws {
        let (model, document, scroll) = fixture()
        hostForMotion(scroll)
        document.update(contents(0..<100, model: model), width: 360, animated: false)
        try self.scroll(scroll, document, to: "chat|chat-50", offset: 9)
        let anchor = try XCTUnwrap(document.views["chat|chat-50"])
        let before = anchor.frame.minY - scroll.contentView.bounds.minY
        // Showing and hiding earlier rows changes the clip origin while the
        // reader's row stays put, including the very first animation frame.
        for range in [-20..<100, 0..<100] {
            let origin = scroll.contentView.bounds.minY
            document.update(contents(range, model: model), width: 360, animated: true)
            XCTAssertTrue(document.views["chat|chat-50"] === anchor)
            XCTAssertEqual(anchor.frame.minY - scroll.contentView.bounds.minY, before, accuracy: 0.5)
            let start = glideStart(of: anchor, in: scroll)
            print("ANCHOR-MOTION clip correction: \(scroll.contentView.bounds.minY - origin) pt, starting displacement: \(start - before) pt")
            XCTAssertEqual(start, before, accuracy: 0.5, "The anchor cannot jump away before gliding back")
        }

        // A reorder inside the viewport still gets the existing glide.
        let moved = try XCTUnwrap(document.views["chat|chat-52"])
        let movedBefore = moved.frame.minY - scroll.contentView.bounds.minY
        var reordered = contents(0..<100, model: model)
        reordered.entries.swapAt(52, 54)
        document.update(reordered, width: 360, animated: true)
        XCTAssertNotNil(moved.layer?.animation(forKey: "glide"))
        XCTAssertNotEqual(moved.frame.minY - scroll.contentView.bounds.minY, movedBefore)
        XCTAssertEqual(glideStart(of: moved, in: scroll), movedBefore, accuracy: 0.5)
    }

    func testAnchorScrollAlsoCompensatesNewlyMountedAndDepartingAnimationOrigins() throws {
        let (model, document, scroll) = fixture()
        hostForMotion(scroll)
        document.update(contents(0..<100, model: model), width: 360, animated: false)
        try self.scroll(scroll, document, to: "chat|chat-50", offset: 9)
        XCTAssertNil(document.views["chat|chat-0"])
        let incomingBefore = try XCTUnwrap(document.frame(of: "chat|chat-0")).minY - scroll.contentView.bounds.minY
        let leaving = try XCTUnwrap(document.views["chat|chat-54"])
        let leavingBefore = leaving.frame.minY - scroll.contentView.bounds.minY
        var changed = contents(-20..<100, model: model)
        changed.entries.removeAll { $0.id == "chat|chat-54" }
        let incoming = changed.entries.remove(at: try XCTUnwrap(changed.entries.firstIndex { $0.id == "chat|chat-0" }))
        changed.entries.insert(incoming, at: try XCTUnwrap(changed.entries.firstIndex { $0.id == "chat|chat-52" }))
        changed.gaps.removeLast(); changed.owners.removeLast()
        document.update(changed, width: 360, animated: true)
        let mounted = try XCTUnwrap(document.views["chat|chat-0"])
        XCTAssertNotNil(mounted.layer?.animation(forKey: "glide"))
        XCTAssertEqual(glideStart(of: mounted, in: scroll), incomingBefore, accuracy: 0.5,
                       "A remounted row's old document frame needs the same clip correction")
        XCTAssertNil(document.views["chat|chat-54"])
        XCTAssertNotNil(leaving.layer?.animation(forKey: "reveal"))
        XCTAssertEqual(leaving.frame.minY - scroll.contentView.bounds.minY, leavingBefore, accuracy: 0.5,
                       "A departing row must start its exit at its previous viewport position")
    }

    func testWidthChangesKeepTheVisibleChatAndItsOffset() throws {
        let (model, document, scroll) = fixture()
        document.update(contents(0..<100, model: model, metrics: true), width: 360, animated: false)
        try self.scroll(scroll, document, to: "chat|chat-50", offset: 9)
        let before = try XCTUnwrap(document.frame(of: "chat|chat-50")).minY - scroll.contentView.bounds.minY
        for (width, available) in [(220.0, 90.0), (360.0, 300.0)] {
            scroll.setFrameSize(CGSize(width: width, height: 320))
            document.update(contents(0..<100, model: model, available: available, metrics: true), width: width, animated: false)
            let after = try XCTUnwrap(document.frame(of: "chat|chat-50")).minY - scroll.contentView.bounds.minY
            print("SCROLL-05 resize to \(width): displacement \(after - before) pt")
            XCTAssertEqual(after, before, accuracy: 0.5)
        }
    }

    func testTinyScrollExaminesOnlyTheVisibleInterval() throws {
        let (model, document, scroll) = fixture()
        document.update(contents(0..<2_000, model: model), width: 360, animated: false)
        try self.scroll(scroll, document, to: "chat|chat-1000")
        let before = document.visibilityVisits
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY + 1))
        document.materialize()
        let visits = document.visibilityVisits - before
        print("SCROLL-26 one-pixel visibility visits: \(visits) / 2000 entries")
        XCTAssertLessThan(visits, 100)
        let visible = document.visibleRect.insetBy(dx: 0, dy: -SidebarListDocument.overscan)
        let expected = Set(document.contents.entries.filter { document.frame(of: $0.id)!.intersects(visible) }.map(\.id))
        XCTAssertEqual(Set(document.views.keys), expected)
    }

    func testDistantScrollsReuseRowsAfterWarming() throws {
        let (model, document, scroll) = fixture()
        document.update(contents(0..<200, model: model), width: 360, animated: false)
        try self.scroll(scroll, document, to: "chat|chat-50")
        try self.scroll(scroll, document, to: "chat|chat-150")
        let before = document.rowConstructions
        for _ in 0..<3 {
            try self.scroll(scroll, document, to: "chat|chat-50")
            try self.scroll(scroll, document, to: "chat|chat-150")
        }
        print("SCROLL-27 row constructions after warmup: \(document.rowConstructions - before)")
        XCTAssertEqual(document.rowConstructions, before)
        for (id, view) in document.views {
            let row = try XCTUnwrap(view as? SidebarChatRowView)
            XCTAssertEqual(id, "chat|" + row.chat.id)
            XCTAssertEqual(row.body.content?.title, row.chat.title)
        }
    }

    func testDiscardedEntriesLeaveTheHeightCache() {
        let (model, document, _) = fixture()
        for batch in 0..<10 {
            document.update(contents((batch * 50)..<((batch + 1) * 50), model: model), width: 360, animated: false)
        }
        print("SCROLL-28 retained heights after 10 disjoint lists: \(document.measuredEntryCount)")
        XCTAssertEqual(document.measuredEntryCount, 50)
        document.update(SidebarListContents(), width: 360, animated: false)
        XCTAssertEqual(document.measuredEntryCount, 0)
    }

    func testReusedRowsDropOldObservationsConfirmationsAndActions() throws {
        let (model, document, scroll) = fixture()
        let entries = contents(0..<200, model: model, metrics: true)
        model.chats = entries.entries.compactMap { if case .chat(let chat, _, _) = $0 { chat } else { nil } }
        document.update(entries, width: 360, animated: false)
        let oldRows = document.views.values.compactMap { $0 as? SidebarChatRowView }
        let oldIDs = Set(oldRows.map { $0.chat.id })
        for view in oldRows {
            let archive = InspectorExpandFixture.descendants(PiKit.IconButton.self, in: view).first { $0.accessibilityIdentifier() == "archiveChat" }
            try XCTUnwrap(archive).onPress?()
        }
        try self.scroll(scroll, document, to: "chat|chat-150")
        let reused = try XCTUnwrap(document.views.values.compactMap { $0 as? SidebarChatRowView }.first { row in oldRows.contains { $0 === row } })
        XCTAssertFalse(oldIDs.contains(reused.chat.id))
        let confirmation = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.Button.self, in: reused).first { $0.accessibilityIdentifier() == "confirmArchive" })
        XCTAssertTrue(confirmation.isHidden, "The old chat's Archive question cannot move to a different chat")
        let newID = reused.chat.id
        reused.body.toggle()
        XCTAssertTrue(model.collapsedSidebarSides.contains(newID), "Actions use the new binding")
        XCTAssertTrue(model.collapsedSidebarSides.isDisjoint(with: oldIDs))
        for id in oldIDs { model.displays[id]?.state = "paused" }
        reused.needsLayout = true; reused.layoutSubtreeIfNeeded()
        XCTAssertEqual(reused.body.content?.stats.state, "idle", "Old display notifications cannot feed a reused row")
        model.displays[newID]?.state = "paused"
        reused.needsLayout = true; reused.layoutSubtreeIfNeeded()
        XCTAssertEqual(reused.body.content?.stats.state, "paused", "The new display stays observed")
    }

    func testReusedChatRowsCannotStartASelectionGlide() throws {
        try assertSelectionGlideDropsReusedRows(sideRows: false)
    }

    func testReusedSideRowsCannotStartASelectionGlide() throws {
        try assertSelectionGlideDropsReusedRows(sideRows: true)
    }

    private func assertSelectionGlideDropsReusedRows(sideRows: Bool) throws {
        let (model, document, scroll) = fixture()
        let reduced = PiKit.Motion.reducedOverride
        PiKit.Motion.reducedOverride = false
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close(); PiKit.Motion.reducedOverride = reduced }
        var entries = contents(0..<200, model: model)
        if sideRows {
            entries.entries = (0..<200).map { .side(SidebarSideRowState(id: "side-\($0)", title: "Side \($0)", selected: $0 == 0)) }
        } else if case .chat(let chat, var state, let project) = entries.entries[0] {
            state.selected = true
            entries.entries[0] = .chat(chat: chat, state: state, projectID: project)
        }
        document.update(entries, width: 360, animated: false)
        let selectedID = sideRows ? "side|side-0" : "chat|chat-0"
        let selectedView = try XCTUnwrap(document.views[selectedID])
        func control(_ view: NSView) throws -> PiKit.SelectableRow {
            try XCTUnwrap((view as? SidebarChatRowView)?.row ?? (view as? SidebarSideRowView)?.row)
        }
        let recycledControl = try control(selectedView)
        XCTAssertTrue(recycledControl.selected)
        try self.scroll(scroll, document, to: sideRows ? "side|side-150" : "chat|chat-150")
        XCTAssertNil(document.views[selectedID])
        XCTAssertTrue(document.views.values.contains { $0 === selectedView }, "The selected control must actually acquire another binding")
        XCTAssertFalse(recycledControl.selected)
        let nextView = try XCTUnwrap(document.views.values.first { $0 !== selectedView })
        let next = try control(nextView)
        XCTAssertTrue(next.window === window)
        next.selected = true
        XCTAssertNil(next.fill.animation(forKey: "glide"), "A recycled control cannot supply the previous chat's highlight position")

        next.selected = false
        recycledControl.selected = true
        XCTAssertNotNil(recycledControl.fill.animation(forKey: "glide"), "Ordinary deselection must preserve the glide between live rows")
        nextView.prepareForReuse()
        recycledControl.selected = false
        next.selected = true
        XCTAssertNotNil(next.fill.animation(forKey: "glide"), "Recycling another row must not clear the current selection's glide source")
    }

    func testEmptyEntriesAndGapsUseTheSameVisibilityRulesAtBothEnds() {
        let (model, document, scroll) = fixture()
        var values = contents(0..<60, model: model)
        values.entries.insert(.nothing(groupID: "empty"), at: 30)
        values.gaps.insert(9, at: 30); values.owners.insert(("project", nil), at: 30)
        document.update(values, width: 360, animated: false)
        for y in stride(from: 0.0, through: Double(document.frame.height), by: 400) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); document.materialize()
            let visible = document.visibleRect.insetBy(dx: 0, dy: -SidebarListDocument.overscan)
            let expected = Set(values.entries.filter {
                let frame = document.frame(of: $0.id)!
                return frame.intersects(visible) || frame.height == 0 && visible.contains(frame.origin)
            }.map(\.id))
            XCTAssertEqual(Set(document.views.keys), expected)
        }
    }
}
