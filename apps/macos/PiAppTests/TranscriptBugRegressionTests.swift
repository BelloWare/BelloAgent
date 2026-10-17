import AppKit
import XCTest
@testable import PiApp

final class TranscriptBugRegressionTests: XCTestCase {
    static let nestedHeading = "- item\n\n  ## Nested\n\n  nested text\n\n# Real\n\nreal text."
    static let before = "header\n…[truncated, 12 more bytes]\nold tail"
    static let after = "header\n…[truncated, 12 more bytes]\nnew tail"

    @MainActor func testHeadingCopyUsesTheRenderedTopLevelHeading() throws {
        let message = TranscriptMessage(id: "reply", role: "assistant", text: Self.nestedHeading)
        let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
            actions: .init(), width: 620, environment: .init(), disclosure: .init(), toggle: { _ in }))
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = row
        defer { window.contentView = nil; window.close() }
        row.layoutSubtreeIfNeeded()
        let text = surface.textView
        let range = (text.string as NSString).range(of: "Real")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
        surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
        XCTAssertEqual(action.copy.accessibilityLabel(), "Copy Real as Markdown")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(action.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "# Real\n\nreal text.")
        XCTAssertEqual(text.copyTargets().map(\.label), ["Copy Real as Markdown"], "Nested headings consume no top-level index")
    }

    func testSectionCopyMatchesParsedContainersAndMultilineSetextSource() {
        for prefix in ["- item\n\n  ## Nested\n\n  nested text\n\n", "1. item\n\n   Nested\n   ------\n\n   nested text\n\n",
                       "> ## Nested\n> text\n\n", "<!--\n# Hidden\n-->\n\n"] {
            let source = prefix + "# Real\n\nreal text."
            let sections = TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }
            XCTAssertEqual(sections.map(\.text), ["# Real\n\nreal text."], source)
        }
        let source = "Intro 🌍\r\n\r\nFirst **line**\r\nsecond line\r\n===========\r\n\r\nbody\r\n\r\n# Peer\r\nlast"
        let sections = TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }
        XCTAssertEqual(sections.map(\.text), ["First **line**\r\nsecond line\r\n===========\r\n\r\nbody\r\n\r\n", "# Peer\r\nlast"])
    }

    func testSectionCopyPreservesCRLFAndMixedLineEndings() {
        for ending in ["\r", "\r\n", "\n"] {
            let intro = "Intro 🌍" + ending + ending
            let one = "# One" + ending + "body" + ending + ending
            let two = "# Two" + ending + "more"
            let targets = TranscriptCopy.targets(in: intro + one + two)
            XCTAssertEqual(targets.map(\.text), [intro, one, two], ending.debugDescription)
        }
        let intro = "Intro 🌍\r\n\r", one = "First **line**\nsecond line\r=======\r\nbody\r\r", two = "# Two\nmore"
        XCTAssertEqual(TranscriptCopy.targets(in: intro + one + two).map(\.text), [intro, one, two])
    }

    func testLiveMarkdownOffsetsRespectCRLFAndMixedLineEndings() {
        for ending in ["\r", "\r\n", "\n"] {
            let intro = "Intro 🌍\r\n\r", first = "- first" + ending, second = "- second" + ending + ending, tail = "# Last" + ending + "body"
            let parsed = TranscriptMarkdown.liveBlocksWithItems(intro + first + second + tail, style: .prose)
            XCTAssertEqual(parsed.blocks.map(\.offset), [0, intro.utf8.count, (intro + first + second).utf8.count,
                (intro + first + second + "# Last" + ending).utf8.count], ending.debugDescription)
            XCTAssertEqual(parsed.items, [[], [intro.utf8.count, (intro + first).utf8.count], [], []], ending.debugDescription)
        }
    }

    @MainActor func testHeadingCopyControlStaysInsideNarrowReplyRows() throws {
        for width: CGFloat in [320, 360, 620, 760] {
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "# Real\n\nreal text.")
            let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
                actions: .init(), width: width, environment: .init(), disclosure: .init(), toggle: { _ in }))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = row
            defer { window.contentView = nil; window.close() }
            row.layoutSubtreeIfNeeded()
            let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
            let text = surface.textView, manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            let range = (text.string as NSString).range(of: "Real")
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
            surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
            XCTAssertTrue(surface.bounds.contains(action.frame), "\(width)-point surface: \(action.frame) outside \(surface.bounds)")
            XCTAssertTrue(row.bounds.contains(surface.convert(action.frame, to: row)), "\(width)-point row clips heading Copy")
        }
    }

    static func editTool(name: String = "edit", truncated: Bool? = false) throws -> ToolView {
        let values = name == "write" ? ["path": "fixture.txt", "content": after] : ["path": "fixture.txt", "oldText": before, "newText": after]
        return ToolView(id: "edit", name: name, state: "completed", input: String(decoding: try JSONEncoder().encode(values), as: UTF8.self),
                        output: "ok", truncated: false, path: "fixture.txt", inputTruncated: truncated)
    }
    func testCompleteEditKeepsLiteralTruncationMarkerAndChangedTails() throws {
        for flag: Bool? in [false, nil] {
            let tool = try Self.editTool(truncated: flag)
            guard case .diff(let request, _, _, _, _) = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) else { return XCTFail("Expected edit card") }
            XCTAssertTrue(request.complete)
            XCTAssertEqual(request.before, Self.before); XCTAssertEqual(request.after, Self.after)
            XCTAssertTrue(request.rows.contains { $0.kind == .removed && $0.text == "old tail" })
            XCTAssertTrue(request.rows.contains { $0.kind == .added && $0.text == "new tail" })
            XCTAssertTrue(request.rows.contains { $0.kind == .context && $0.text == "…[truncated, 12 more bytes]" })
        }
    }
    func testCompleteWriteKeepsLiteralTruncationMarker() throws {
        let tool = try Self.editTool(name: "write")
        guard case .diff(let request, _, _, _, _) = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) else { return XCTFail("Expected write card") }
        XCTAssertTrue(request.complete); XCTAssertEqual(request.after, Self.after)
        XCTAssertEqual(request.rows.map(\.text), Self.after.components(separatedBy: "\n"))
    }
    func testExplicitlyTruncatedEditStillSeparatesTheLegacyMarker() throws {
        let tool = try Self.editTool(truncated: true)
        let request = try XCTUnwrap(TranscriptActivity.editRequest(tool))
        XCTAssertFalse(request.complete)
        XCTAssertEqual(request.before, "header\n"); XCTAssertEqual(request.after, "header\n")
        XCTAssertEqual(request.rows.last?.text, "…[truncated, 12 more bytes]\nnew tail")
    }

    @MainActor private func findFixture(saved: Bool, reasoning: Bool = false, source: String = "**alpha** beta", content: WireValue? = nil, entries: [WireValue]? = nil) async throws -> (WorkspaceModel, NativeTranscriptPane, NSWindow) {
        let root = scratchRoot("ordinary-markdown-find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let answer: WireValue = content ?? (saved && reasoning ? .array([
            .object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
            .object(["type": .string("text"), "text": .string("Done.")])]) : .string(saved ? source : "Earlier saved text"))
        let records: [WireValue] = [.object(["type": .string("session"), "version": .number(3), "id": .string("ordinary-find")])] + (entries ?? [
            .object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                     "message": .object(["role": .string("user"), "content": .string("Reply")])]),
            .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"),
                     "message": .object(["role": .string("assistant"), "content": answer])])])
        var bytes = Data()
        for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        let path = root.appendingPathComponent("find.jsonl"); try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "ordinary-find", workspaceID: "project", title: "Find", path: path.path, profileID: "profile")]
        await model.select("ordinary-find")
        let session = try XCTUnwrap(model.selected)
        if !saved {
            session.messages[1].text = reasoning ? "Done." : source; session.messages[1].state = "streaming"
            if reasoning { session.messages[1].thinking = "**alpha** beta" }
        }
        let pane = NativeTranscriptPane()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in pane.closeFind(focusing: false); window.contentView = nil; window.close() }
        pane.showTranscript(model: model, session: session, state: saved ? "idle" : "running", canFork: false, canQuote: false, enabled: true)
        return (model, pane, window)
    }
    @MainActor private func checkFind(saved: Bool, reasoning: Bool = false, raw: Bool = false) async throws {
        let (model, pane, window) = try await findFixture(saved: saved, reasoning: reasoning)
        if raw { model.selected?.disclosure.setOpen(true, .source("reply")); pane.refresh() }
        pane.showFind(); pane.find.setQuery("alpha beta")
        try await eventually("Ordinary reply search finished") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply"])
        guard !pane.find.matches.isEmpty else { return }
        try await eventually("The phrase across emphasis is visibly highlighted") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), "alpha beta")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        XCTAssertNotNil(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
        XCTAssertTrue(pane.scrollView.contentView.bounds.intersects(text.convert(rect, to: pane.scrollView.contentView)))
        XCTAssertEqual(reasoning ? model.selected?.messages.last?.thinking : model.selected?.messages.last?.text,
                       "**alpha** beta", "Find leaves source Markdown intact")
    }
    @MainActor func testFindMatchesFormattedOrdinaryLiveReply() async throws { try await checkFind(saved: false) }
    @MainActor func testFindMatchesFormattedOrdinaryReopenedReply() async throws { try await checkFind(saved: true) }
    @MainActor func testFindMatchesFormattedLiveReasoning() async throws { try await checkFind(saved: false, reasoning: true) }
    @MainActor func testFindMatchesFormattedReopenedReasoning() async throws { try await checkFind(saved: true, reasoning: true) }
    @MainActor func testRememberedViewRawKeepsStreamingFindRendered() async throws { try await checkFind(saved: false, raw: true) }
    @MainActor func testViewRawKeepsReasoningFindRendered() async throws { try await checkFind(saved: true, reasoning: true, raw: true) }

    @MainActor private func checkRawFind(unsaved: Bool = false, noJournal: Bool = false, alreadySearching: Bool = false) async throws {
        let source = "[site](https://example.test)"
        let (model, pane, window) = try await findFixture(saved: true, source: source)
        let session = try XCTUnwrap(model.selected)
        let replyID = unsaved ? "unsaved-reply" : "reply"
        if unsaved { session.messages[1] = TranscriptMessage(id: replyID, role: "assistant", text: source) }
        if noJournal { model.chats[0].path = nil }
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if alreadySearching {
            pane.showFind(); pane.find.setQuery("example.test")
            try await eventually("Rendered link search finishes") { !pane.find.searching }
            XCTAssertTrue(pane.find.matches.isEmpty, "The rendered link hides its destination")
        }
        let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == replyID })
        row.toggleDisclosure(.source(replyID))
        pane.refresh(); pane.document.finishDisclosureMotion(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self, in: row).contains { $0.string == source && !$0.isHiddenOrHasHiddenAncestor })
        if !alreadySearching { pane.showFind(); pane.find.setQuery("example.test") }
        try await eventually("Raw reply search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), [replyID])
        guard !pane.find.matches.isEmpty else { return }
        if alreadySearching {
            XCTAssertNil(pane.document.highlights.focus, "A refresh that gains its first match creates no navigation focus")
            XCTAssertFalse(pane.document.focusPending)
            pane.find.step(1)
        }
        try await eventually("The visible raw destination is highlighted") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), "example.test")
        XCTAssertNotNil(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        row.toggleDisclosure(.source(replyID)); pane.refresh()
        try await eventually("Switching back refreshes the active search") { !pane.find.searching }
        XCTAssertTrue(pane.find.matches.isEmpty)
        XCTAssertEqual(session.messages.last?.text, source)
    }
    @MainActor func testFindMatchesViewRawInSavedReply() async throws { try await checkRawFind() }
    @MainActor func testFindMatchesViewRawInUnsavedReply() async throws { try await checkRawFind(unsaved: true) }
    @MainActor func testFindMatchesViewRawWithoutJournal() async throws { try await checkRawFind(noJournal: true) }
    @MainActor func testViewRawRefreshesAnActiveFind() async throws { try await checkRawFind(alreadySearching: true) }

    @MainActor private func assertFind(_ query: String, in pane: NativeTranscriptPane, window: NSWindow, record: String = "reply") async throws {
        pane.showFind(); pane.find.setQuery(query)
        try await eventually("Search finishes for \(query)") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), [record])
        guard !pane.find.matches.isEmpty else { return }
        try await eventually("Visible match for \(query)") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), query)
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        XCTAssertNotNil(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
        let point = NSPoint(x: rect.midX, y: rect.midY), clip = pane.scrollView.contentView
        XCTAssertTrue(clip.bounds.contains(text.convert(point, to: clip)), "The match is visible in the transcript")
        if let inner = text.enclosingScrollView, inner !== pane.scrollView {
            XCTAssertTrue(inner.contentView.bounds.contains(text.convert(point, to: inner.contentView)), "The match is visible inside its card")
        }
    }
    @MainActor func testFindIncludesVisibleOrderedMarkersInSavedReply() async throws {
        let (_, pane, window) = try await findFixture(saved: true, source: "1. alpha\n2. beta")
        try await assertFind("2.", in: pane, window: window)
    }
    @MainActor func testFindIncludesVisibleOrderedMarkersInLiveReply() async throws {
        let (_, pane, window) = try await findFixture(saved: false, source: "1. alpha\n2. beta")
        try await assertFind("2.", in: pane, window: window)
    }

    @MainActor func testFindUsesRawCompletedSegmentWhileAnotherSegmentStreams() async throws {
        let source = "[site](https://example.test)", later = "**later** text"
        let (model, pane, window) = try await findFixture(saved: false, source: source + later)
        let session = try XCTUnwrap(model.selected)
        var timeline = ResponseTimeline()
        timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "first", kind: "text", update: "replace", text: source))
        timeline.consume(.init(attemptID: "fixture", ordinal: 1, itemID: "later", kind: "text", update: "append", text: later))
        session.messages[1].responseTimeline = timeline
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let row = try XCTUnwrap(pane.document.retainedRows.first {
            if case .block(let block) = $0.contentItem { return block.part?.id == timeline.segments[0].id }; return false
        })
        row.toggleDisclosure(.source("reply")); pane.refresh(); pane.document.finishDisclosureMotion()
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(TranscriptNativeDocument.textViews(in: row).contains { $0.string == source })
        XCTAssertTrue(ConversationPaneTests.views(NativeMarkdownContainer.self, in: pane.document).contains { !$0.isParked && $0.textView.string == "later text" })
        try await assertFind("example.test", in: pane, window: window)
    }

    @MainActor func testSourceRefreshKeepsTheReaderAwayFromTheCurrentFindHit() async throws {
        let (model, pane, window) = try await findFixture(saved: true, source: "needle here and needle again")
        let session = try XCTUnwrap(model.selected)
        session.messages += [.init(id: "other-question", role: "user", text: "Read something else"),
                             .init(id: "other-reply", role: "assistant", text: String(repeating: "Other plain paragraph.\n\n", count: 100))]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        pane.showFind(); pane.find.setQuery("needle")
        try await eventually("The initial search lands") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        XCTAssertEqual(pane.find.matches.count, 2)
        pane.find.step(1)
        try await eventually("The reader chooses the second hit") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending
        }
        XCTAssertEqual(pane.find.current, 1)
        let focus = try XCTUnwrap(pane.document.highlights.focus), current = pane.find.current
        let clip = pane.scrollView.contentView
        pane.page.readerWillNavigate(upward: false)
        clip.setBoundsOrigin(NSPoint(x: 0, y: 750)); pane.scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: pane.scrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: pane.scrollView)
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == "other-reply" })
        row.toggleDisclosure(.source("other-reply")); pane.refresh(); pane.document.finishDisclosureMotion()
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 500, "The reader has left the hit behind")
        XCTAssertEqual(pane.document.highlights.focus, focus, "Refreshing never clears and reinstalls navigation focus")
        XCTAssertEqual(pane.find.current, current, "Keep the selected match while refreshing")
        try await eventually("Refreshed results finish without a reveal") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending
        }
        for _ in 0..<5 { await Task.yield(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1, "Refreshing cannot scroll back to the old hit")
        XCTAssertEqual(pane.document.highlights.focus, focus)
        XCTAssertEqual(pane.find.current, current)
    }

    @MainActor func testFindRefreshKeepsNewerNextAndPreviousSelections() async throws {
        let (_, pane, window) = try await findFixture(saved: true, source: "needle one, needle two, needle three")
        pane.showFind(); pane.find.setQuery("needle")
        try await eventually("Initial Find lands") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        let search = try XCTUnwrap(pane.find.search)
        var waiting: CheckedContinuation<Void, Never>?
        defer { waiting?.resume(); pane.find.search = search }
        pane.find.search = { id, query, start in
            let result = try await search(id, query, start)
            await withCheckedContinuation { waiting = $0 }
            return result
        }
        for direction in [1, -1] {
            let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == "reply" })
            row.toggleDisclosure(.source("reply")); pane.refresh(); pane.document.finishDisclosureMotion()
            try await eventually("Refresh reaches its held search result") { waiting != nil }
            pane.find.step(direction)
            try await eventually("Newer Find step lands") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending
            }
            let selection = pane.find.current, focus = try XCTUnwrap(pane.document.highlights.focus)
            let text = pane.document.focusText, range = pane.document.focusRange
            waiting?.resume(); waiting = nil
            try await eventually("Refresh finishes") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching
            }
            XCTAssertEqual(pane.find.current, selection, "The newer \(direction) step wins")
            XCTAssertEqual(pane.document.highlights.focus, focus, "Refresh retains the newer focused highlight")
            XCTAssertTrue(pane.document.focusText === text)
            XCTAssertEqual(pane.document.focusRange, range)
            XCTAssertFalse(pane.document.focusPending)
        }
    }

    @MainActor func testFindRefreshKeepsPendingNavigationWhenMatchIndexesChange() async throws {
        let (model, pane, window) = try await findFixture(saved: true, source: "needle here")
        var refreshing = false
        var searchWait: CheckedContinuation<Void, Never>?, revealWait: CheckedContinuation<Void, Never>?
        defer { searchWait?.resume(); revealWait?.resume() }
        pane.showFind()
        pane.find.search = { _, _, _ in
            if refreshing { await withCheckedContinuation { searchWait = $0 } }
            let ids = refreshing ? ["earlier", "reply", "target"] : ["reply", "target"]
            return ContentSearch(hits: ids.enumerated().map { ContentHit(id: $0.element, position: $0.offset, preview: "needle", count: 1) }, total: ids.count, next: nil, revision: "fixture")
        }
        pane.find.reveal = { _, id in
            XCTAssertEqual(id, "target")
            await withCheckedContinuation { revealWait = $0 }
            return true
        }
        pane.find.setQuery("needle")
        try await eventually("Initial results arrive") { !pane.find.searching }
        refreshing = true; pane.find.setQuery("needle", restarting: true)
        try await eventually("Refresh waits") { searchWait != nil }
        pane.find.step(1)
        try await eventually("The newer step waits for its missing page") { revealWait != nil }
        searchWait?.resume(); searchWait = nil
        try await eventually("Refresh inserts an earlier match") { !pane.find.searching }
        XCTAssertEqual(pane.find.current, 2)
        model.selected?.messages += [.init(id: "target-question", role: "user", text: "Later question"),
            .init(id: "target", role: "assistant", text: "Done.", thinking: "needle target", state: "complete")]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        revealWait?.resume(); revealWait = nil
        try await eventually("The original Next action opens and highlights the loaded thought") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText?.string == "needle target"
        }
        XCTAssertEqual(pane.document.highlights.focus?.record, "target")
    }

    private var twoUsers: [WireValue] {
        ["question", "reply"].enumerated().map { index, id in
            .object(["type": .string("message"), "id": .string(id), "parentId": index == 0 ? .null : .string("question"),
                     "message": .object(["role": .string("user"), "content": .string("user \(index + 1)")])])
        }
    }
    @MainActor func testSavedUserFindCountsOnlyDisplayedTextAndKeepsPreviousHighlight() async throws {
        let (_, pane, window) = try await findFixture(saved: true, entries: twoUsers)
        pane.showFind(); pane.find.setQuery("user")
        try await eventually("User search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.count, 2)
        pane.find.step(-1)
        try await eventually("Previous reaches the other user's text") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText?.string == "user 2"
        }
        XCTAssertEqual(pane.document.highlights.focus?.record, "reply")
        XCTAssertEqual(pane.document.highlights.focus?.occurrence, 0)
    }
    @MainActor func testReconciliationAdoptsClampedFocusWithoutNewNavigation() async throws {
        let (_, pane, window) = try await findFixture(saved: true, entries: twoUsers)
        pane.showFind()
        // Keep overcounts independent of the projection fix: a newly drawn
        // row may still reconcile a count obtained before its text changed.
        pane.find.search = { _, _, _ in
            ContentSearch(hits: [ContentHit(id: "question", position: 1, preview: "user", count: 2),
                                ContentHit(id: "reply", position: 2, preview: "user", count: 2)], total: 2, next: nil, revision: "fixture")
        }
        pane.document.onFocusResolved = nil
        pane.find.setQuery("user")
        try await eventually("Controlled counts arrive") { !pane.find.searching }
        pane.find.step(-1)
        let previous = try XCTUnwrap(pane.document.highlights.focus)
        XCTAssertEqual(previous.occurrence, 1)
        pane.document.focusPending = false
        let origin = pane.scrollView.contentView.bounds.origin
        pane.find.reconcile("reply", needle: "user", rendered: 1)
        let adopted = pane.document.highlights.focus
        XCTAssertEqual(adopted?.record, "reply")
        XCTAssertEqual(adopted?.occurrence, 0)
        XCTAssertEqual(adopted?.serial, previous.serial, "Count adoption creates no navigation request")
        XCTAssertFalse(pane.document.focusPending)
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertEqual(pane.scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(pane.document.focusText?.string, "user 2")
        XCTAssertEqual(pane.document.focusRange, NSRange(location: 0, length: 4))
        pane.document.highlights.focus = nil
        pane.find.reconcile("reply", needle: "user", rendered: 2)
        XCTAssertNil(pane.document.highlights.focus, "Reconciliation cannot invent focus after the reader cleared it")
    }

    @MainActor private func rowPayload(_ message: TranscriptMessage) -> String {
        let item = TranscriptItem.message(message)
        let row = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: .init(), width: 620,
            environment: .init(), disclosure: .init(compaction: true)))
        row.frame = CGRect(x: 0, y: 0, width: 620, height: 500)
        row.frame.size.height = row.settle().height
        row.layoutSubtreeIfNeeded()
        if message.kind == "notice" {
            return ConversationPaneTests.views(TranscriptLabel.self, in: row).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if message.kind == "versionBanner" {
            return row.subviews.compactMap { ($0 as? TranscriptLabel)?.text }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let execution = row as? TranscriptNativeExecutionRow {
            let body = TranscriptNativeDocument.textViews(in: row).filter { $0.accessibilityLabel() != "Button" }.map(\.string).filter { !$0.isEmpty }.joined(separator: "\n")
            return [execution.line.accessibilityLabel() ?? "", body].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if row is TranscriptNativeAgentRow {
            var parts: [String] = []
            func visit(_ view: NSView) {
                if let prose = view as? TranscriptAgentMarkdown { parts.append(prose.markdown.textView.string); return }
                if let title = view as? PiKit.WrappedText { parts.append(title.text); return }
                if let badge = view as? PiKit.Badge { parts.append(badge.text); return }
                if let note = view as? PiKit.Note { parts.append(note.text); return }
                for child in view.subviews where !child.isHidden { visit(child) }
            }
            visit(row)
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return TranscriptNativeDocument.textViews(in: row).filter { message.kind != "failure" || $0.accessibilityLabel() != "Title" }
            .map(\.string).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @MainActor func testUserStatusAndSummaryProjectionEqualsNativeRowsSavedAndLive() throws {
        let sources = ["user", "**literal** [site](https://example.test)", "1. first\n2. second", "# Heading\n\nBody 🌍", "", "left\r\nright"]
        for source in sources {
            for (role, kind) in [("user", ""), ("system", ""), ("system", "notice"), ("system", "compaction"), ("system", "unrecognized")] {
                var fields: [String: WireValue] = ["role": .string(role), "content": .string(source)]
                if !kind.isEmpty { fields["nativeKind"] = .string(kind) }
                let message = TranscriptMessage.project(id: "row", message: fields), shown = rowPayload(message)
                XCTAssertEqual(ConversationContent.transcriptText(["id": .string("row"), "message": .object(fields)]), shown, "Saved \(role)/\(kind): \(source)")
                XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(role)/\(kind): \(source)")
            }
        }
        for content: WireValue in [.array([.object(["type": .string("image")])]),
                                   .array([.object(["type": .string("image")]), .object(["type": .string("image")])]),
                                   .array([.object(["type": .string("text"), "text": .string("first ")]), .object(["type": .string("text"), "text": .string("second")])])] {
            let fields: [String: WireValue] = ["role": .string("user"), "content": content]
            let message = TranscriptMessage.project(id: "row", message: fields)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), rowPayload(message))
            XCTAssertEqual(ConversationContent.transcriptText(message), rowPayload(message))
        }
        let fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden envelope"), "nativeDisplayText": .string("Visible **literal** request")]
        XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), rowPayload(.project(id: "row", message: fields)))
    }
    @MainActor func testSavedCompactionFindUsesTheNativeSummaryAndOpensIt() async throws {
        let entry: WireValue = .object(["type": .string("compaction"), "id": .string("reply"), "parentId": .null,
                                      "summary": .string("Keep **alpha** beta."), "tokensBefore": .number(120)])
        let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
        let message = try XCTUnwrap(model.selected?.messages.first)
        XCTAssertEqual(ConversationContent.transcriptText(try XCTUnwrap(entry.object)), rowPayload(message))
        try await assertFind("alpha beta", in: pane, window: window)
    }
    @MainActor func testAgentDeliveryProjectionEqualsNativeCardsSavedAndLive() throws {
        let source = "1. **alpha** beta\n2. [site](https://example.test)"
        for (author, kind) in [("parent", "task"), ("parent", "follow_up"), ("parent", "steer"), ("subagent", "result"),
                               ("subagent", "note"), ("subagent", "question"), ("subagent", "blocker")] {
            let delivery: WireValue = .object(["author": .string(author), "childId": .string("child"), "turn": .number(1),
                "events": .array([.object(["kind": .string(kind), "text": .string(source), "task": .string("Fixture task")])])])
            let fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden transport envelope"), "nativeAgentDelivery": delivery]
            let message = TranscriptMessage.project(id: "delivery", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved \(author)/\(kind)")
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(author)/\(kind)")
        }
        let child = SessionDisplay(id: "child"); child.isManagedSubagent = true; child.delegatedTask = source
        let task = try XCTUnwrap(child.presentedMessages.first)
        XCTAssertEqual(ConversationContent.transcriptText(task), rowPayload(task), "Unsaved delegated task")
    }
    @MainActor func testSidePaneProjectionEqualsItsSavedAndLiveUserRows() async throws {
        let (model, _, window) = try await findFixture(saved: true, entries: twoUsers)
        let session = try XCTUnwrap(model.selected)
        let info = SideRecord(id: session.id, parentID: "fixture-parent", workspaceID: "project", profileID: "profile", title: "Side", kept: true)
        let side = SidePaneView(model: model, session: session, info: info, paneWidth: 620)
        window.contentView = side
        defer { side.pane.transcript.closeFind(focusing: false) }
        for saved in [true, false] {
            if !saved { session.messages = [.init(id: "live-user", role: "user", text: "**literal** [site](https://example.test)")] }
            side.pane.transcript.refresh(); side.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            for message in session.presentedMessages {
                let row = try XCTUnwrap(side.pane.transcript.document.row(drawing: message.id))
                row.prepareToDraw(); row.layoutForViewport()
                let shown = TranscriptNativeDocument.textViews(in: row).filter(\.isSelectable).map(\.string).joined(separator: "\n")
                XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Side \(message.id)")
                if saved {
                    let entry = try XCTUnwrap(twoUsers.first { $0.object?["id"]?.string == message.id }?.object)
                    XCTAssertEqual(ConversationContent.transcriptText(entry), shown, "Saved side \(message.id)")
                }
            }
        }
    }
    @MainActor func testSavedManagedRowsKeepTheirDisplayedAgentAndUserText() async throws {
        let entries: [WireValue] = [
            .object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                "message": .object(["role": .string("user"), "content": .string("**alpha** beta")])]),
            .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"),
                "message": .object(["role": .string("user"), "content": .string("**literal** user")])])]
        let (model, pane, window) = try await findFixture(saved: true, entries: entries)
        let session = try XCTUnwrap(model.selected), path = try XCTUnwrap(model.chats.first?.path)
        session.isManagedSubagent = true; session.subagentNumbers = [session.id: 3]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let task = try XCTUnwrap(session.presentedMessages.first)
        XCTAssertEqual(ConversationContent.transcriptText(task), rowPayload(task))
        for (query, id) in [("Parent → Sub-agent 3", "question"), ("alpha beta", "question"), ("**literal** user", "reply")] {
            let found = try await model.history.searchContent(path: path, query: query, start: 0, renderedAgentProse: true,
                                                            managedChild: true, presented: session.presentedMessages)
            XCTAssertEqual(found.hits.map(\.id), [id], "Presented managed row: \(query)")
        }
        for (query, id) in [("alpha beta", "question"), ("**literal** user", "reply")] {
            let cold = try await model.history.searchContent(path: path, query: query, start: 0, renderedAgentProse: true, managedChild: true)
            XCTAssertEqual(cold.hits.map(\.id), [id], "Unloaded managed row: \(query)")
        }
    }
    @MainActor func testAgentDeliveryNotesAndUnavailableAttributionMatchTheCard() {
        for metadata: WireValue? in [nil, .object([:]), .object(["author": .string("subagent"), "childId": .string("child"), "turn": .number(2),
            "events": .array([.object(["kind": .string("result"), "text": .string("**visible** result"),
                "result": .object(["text_truncated": .bool(true), "error": .object(["message": .string("Fixture error")])])])])])] {
            var fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden delivery transport"), "nativeKind": .string("agent_message")]
            fields["nativeAgentDelivery"] = metadata
            let message = TranscriptMessage.project(id: "agent", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown)
            XCTAssertEqual(ConversationContent.transcriptText(message), shown)
        }
    }
    @MainActor func testRemainingRowKindsProjectTheirNativeContent() throws {
        for kind in ["failure", "branch", "versionBanner", "requestInfo", "execution", "toolResult"] {
            var fields: [String: WireValue] = ["role": .string(kind == "toolResult" ? "toolResult" : "system"),
                "nativeKind": .string(kind), "content": .string("Literal body"), "nativeDetail": .string("Visible detail")]
            if kind == "requestInfo" { fields["nativeStopReason"] = .string("length") }
            if kind == "execution" {
                var timeline = ResponseTimeline()
                timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "**alpha** beta"))
                timeline.finish("completed")
                fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            }
            let message = TranscriptMessage.project(id: "row", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved \(kind)")
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(kind)")
        }
    }
    @MainActor func testBranchSearchUsesItsDisplayedDetailWithoutAnExportHeading() async throws {
        let entries: [WireValue] = [twoUsers[0], .object(["type": .string("branch"), "id": .string("reply"),
            "parentId": .string("question"), "fromMessageId": .string("question"), "keptIds": .array([.string("question")])])]
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let message = try XCTUnwrap(model.selected?.messages.first { $0.kind == "branch" }), path = try XCTUnwrap(model.chats.first?.path)
        let shown = rowPayload(message)
        let rendered = try await model.history.searchContent(path: path, query: "", start: 0, renderedAgentProse: true)
        XCTAssertEqual(rendered.hits.first { $0.id == message.id }?.preview, shown)
        let source = try await model.history.searchContent(path: path, query: "## Edit", start: 0)
        XCTAssertEqual(source.hits.map(\.id), [message.id], "Source export retains its heading")
    }
    @MainActor func testExecutionFindUsesAndOpensItsRenderedTimeline() async throws {
        var timeline = ResponseTimeline()
        timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "**alpha** beta"))
        timeline.finish("completed")
        let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null,
            "message": .object(["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Hidden canonical text"),
                "nativeDetail": .string("Recorded execution"), "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])])
        let (_, pane, window) = try await findFixture(saved: true, entries: [entry])
        try await assertFind("alpha beta", in: pane, window: window)
    }
    @MainActor func testExecutionCaptionsStaySearchableWithAndWithoutTimelineBodies() throws {
        for hasBody in [false, true] { for caption: String? in [nil, "Recorded execution"] {
            var fields: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Fallback caption")]
            fields["nativeDetail"] = caption.map(WireValue.string)
            if hasBody {
                var timeline = ResponseTimeline()
                timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "Body **alpha** beta"))
                timeline.finish("completed")
                fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            }
            let message = TranscriptMessage.project(id: "execution", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live body=\(hasBody), caption=\(caption ?? "fallback")")
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved body=\(hasBody), caption=\(caption ?? "fallback")")
        } }
    }
    @MainActor func testStandaloneToolResultsMatchTheirNativeRowsSavedAndLive() async throws {
        for name in ["custom_fixture", "subagent_start"] { for saved in [true, false] {
            let source = name == "custom_fixture" ? "**alpha** beta" : #"{"text":"**alpha** beta"}"#
            let fields: [String: WireValue] = ["role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(source)]
            let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])
            let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
            let session = try XCTUnwrap(model.selected), shown = rowPayload(try XCTUnwrap(session.messages.first))
            if saved {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats.first?.path), query: "", start: 0,
                    renderedAgentProse: true, presented: session.presentedMessages)
                XCTAssertEqual(found.hits.first?.preview, shown, "Saved standalone \(name)")
            } else {
                model.chats[0].path = nil
                let found = try await model.history.searchPresented(session.presentedMessages, query: "", start: 0)
                XCTAssertEqual(found.hits.first?.preview, shown, "Live standalone \(name)")
            }
            try await assertFind("alpha beta", in: pane, window: window)
        } }
    }
    @MainActor func testPairedToolResultsKeepTheirLiteralCardText() async throws {
        let call = toolEntry("custom_fixture", arguments: .object([:]))
        let entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
            .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                "role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta")])])]
        let (model, pane, window) = try await findFixture(saved: true, entries: entries)
        pane.showFind(); pane.find.setQuery("**alpha** beta")
        try await eventually("Paired result is highlighted literally") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
        XCTAssertEqual(pane.document.focusText?.string, "**alpha** beta")
        let session = try XCTUnwrap(model.selected), path = try XCTUnwrap(model.chats.first?.path)
        let hidden = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: session.presentedMessages)
        XCTAssertTrue(hidden.hits.isEmpty, "The paired I/O card shows literal Markdown marks")
    }

    private func recoveryLedger(terminal: String? = nil, legacy: Bool = false) throws -> [String: WireValue] {
        var fields: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("requestLedger"),
            "nativePresentationSourceID": .string("missing-reply"), "content": .array([])]
        if legacy {
            fields["content"] = .array([.object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
                .object(["type": .string("text"), "text": .string("Visible **gamma** delta")])])
        } else {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "recovery", ordinal: 0, itemID: "thought", kind: "reasoningText", update: "replace", text: "**alpha** beta"))
            timeline.consume(.init(attemptID: "recovery", ordinal: 1, itemID: "words", kind: "text", update: "replace", text: "Visible **gamma** delta and [site](https://recovery.test)"))
            if let terminal { timeline.finish(terminal) }
            fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
        }
        return fields
    }
    @MainActor private func plannedPayload(_ messages: [TranscriptMessage], raw: Bool = false) -> [String: String] {
        var payload: [String: [String]] = [:]
        for item in TaskTranscriptPlan.rows(messages, lifecycle: nil) {
            if case .message(let message) = item {
                let text = rowPayload(message)
                if !text.isEmpty { payload[message.id, default: []].append(text) }
                continue
            }
            guard case .block(let block) = item, block.presentation != .response, block.presentation != .summary else { continue }
            if block.part != nil, let message = block.message, let tool = message.tools?.first {
                payload[message.id, default: []].append(cardPayload(tool)); continue
            }
            let disclosure = TranscriptRowDisclosure(work: true,
                openTools: Set(block.replies.flatMap { message in (message.tools ?? []).map { ToolOccurrence.key(message.id, $0.id) } }),
                openReasoning: Set(block.replies.map(\.id)), compaction: true, raw: raw)
            let row = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: .init(), width: 620,
                environment: .init(), disclosure: disclosure))
            row.frame = CGRect(x: 0, y: 0, width: 620, height: 500); row.frame.size.height = row.settle().height; row.layoutSubtreeIfNeeded()
            let shown = TranscriptNativeDocument.textViews(in: row).filter { $0.isSelectable && !$0.isHiddenOrHasHiddenAncestor }
                .map(\.string).filter { !$0.isEmpty }.joined(separator: "\n")
            if !shown.isEmpty { payload[block.message?.id ?? block.activity.first?.id ?? block.id, default: []].append(shown) }
        }
        return payload.mapValues { $0.joined(separator: "\n") }
    }
    @MainActor func testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive() throws {
        for terminal: String? in [nil, "completed", "interrupted"] { for legacy in [false, true] { for raw in [false, true] {
            let fields = try recoveryLedger(terminal: terminal, legacy: legacy), message = TranscriptMessage.project(id: "reply", message: fields)
            let shown = plannedPayload([message], raw: raw)["reply"] ?? ""
            XCTAssertTrue(shown.contains("alpha beta"))
            XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "Live terminal=\(terminal ?? "missing"), legacy=\(legacy), raw=\(raw)")
            XCTAssertEqual(ConversationContent.transcriptText(["id": .string("reply"), "message": .object(fields)], rawReply: raw), shown,
                "Saved terminal=\(terminal ?? "missing"), legacy=\(legacy), raw=\(raw)")
        } } }
    }
    @MainActor func testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery() async throws {
        for saved in [true, false] {
            let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null,
                "message": .object(try recoveryLedger())])
            let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
            if !saved { model.chats[0].path = nil }
            try await assertFind("alpha beta", in: pane, window: window)
            try await assertFind("gamma delta", in: pane, window: window)
            model.selected?.disclosure.setOpen(true, .source("reply")); pane.refresh()
            try await assertFind("recovery.test", in: pane, window: window)
        }
    }
    @MainActor func testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions() async throws {
        var fields = try recoveryLedger(terminal: "completed")
        fields["nativePresentationSourceID"] = .string("accepted")
        let accepted: WireValue = .object(["type": .string("message"), "id": .string("accepted"), "parentId": .string("reply"),
            "message": .object(["role": .string("assistant"), "content": .string("Accepted answer")])])
        for superseded in [true, false] {
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            if superseded { entries.append(accepted) }
            else {
                var cleared = ResponseTimeline(); cleared.finish("failed")
                var discarded = fields
                discarded["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(cleared))
                entries.append(.object(["type": .string("custom"), "customType": .string("pi-app.presentation.update.v1"),
                    "id": .string("discard"), "parentId": .string("reply"), "data": .object(["id": .string("reply")]), "message": .object(discarded)]))
            }
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
            XCTAssertFalse(shown.values.contains { $0.contains("alpha beta") })
            let live = try await model.history.searchPresented(rows, query: "alpha beta", start: 0)
            XCTAssertTrue(live.hits.isEmpty)
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "alpha beta", start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertTrue(saved.hits.isEmpty, "superseded=\(superseded), presented=\(!presented.isEmpty)")
            }
        }
    }

    @MainActor func testRecoveryPlannerCorpusMatchesSavedAndLiveSearch() async throws {
        let encoded = try XCTUnwrap(recoveryLedger(terminal: "completed")["nativeResponseTimeline"])
        let execution: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Hidden canonical"),
            "nativeReplayEligible": .bool(false), "nativeDetail": .string("Compaction stage"), "nativeOperationID": .string("operation"), "nativeResponseTimeline": encoded]
        var unfinished = execution
        unfinished["nativeResponseTimeline"] = try recoveryLedger()["nativeResponseTimeline"]
        var unsupported = try recoveryLedger(legacy: true), future = try XCTUnwrap(encoded.object)
        future["version"] = .number(999); unsupported["nativeResponseTimeline"] = .object(future)
        let summary: WireValue = .object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string("reply"),
            "summary": .string("Hidden checkpoint **alpha** beta"), "nativeCompactionVersion": .number(2),
            "nativeCompaction": .object(["operationId": .string("operation"), "version": .number(2), "sourceIDs": .array([]), "protectedIDs": .array([]), "keptIDs": .array([])])])
        for (name, fields, checkpoint) in [("unfinished operation", unfinished, false), ("adopted operation", unfinished, true),
                                           ("duplicate checkpoint", execution, true), ("unsupported ledger", unsupported, false)] {
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            if checkpoint { entries.append(summary) }
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
            let live = try await model.history.searchPresented(rows, query: "", start: 0)
            for row in rows { XCTAssertEqual(live.hits.first { $0.id == row.id }?.preview, shown[row.id] ?? "", "Live \(name), \(row.id)") }
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0,
                    renderedAgentProse: true, presented: presented)
                for row in rows { XCTAssertEqual(saved.hits.first { $0.id == row.id }?.preview, shown[row.id] ?? "", "Saved \(name), \(row.id), presented=\(!presented.isEmpty)") }
            }
        }
    }

    @MainActor func testPlannedPairedToolPayloadsMatchSavedAndLiveSearch() async throws {
        let cases: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["key": .string("value")]), "**alpha** beta"),
            ("bash", .object(["command": .string("printf fixture")]), "**alpha** beta"),
            ("read", .object(["path": .string("fixture.txt")]), "**alpha** beta"),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old tail"), "newText": .string("new tail")]), "Transport receipt"),
            ("subagent_start", .object(["task": .string("**Task** prose")]), #"{"text":"**alpha** beta"}"#)]
        for (name, arguments, output) in cases { for separated in [false, true] {
            let call = toolEntry(name, arguments: arguments)
            let entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
                .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                    "role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(output),
                    "nativeToolStats": .object(["outcome": .string("succeeded")])])])]
            var records = entries
            if separated {
                var parent = "reply"
                for i in 0..<40 {
                    let id = "spacer-\(i)"
                    records.insert(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                        "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]), at: records.count - 1)
                    parent = id
                }
                records[records.count - 1].object.map { original in
                    var value = original; value["parentId"] = .string(parent); records[records.count - 1] = .object(value)
                }
            }
            let (model, _, _) = try await findFixture(saved: true, entries: records)
            let rows = try XCTUnwrap(model.selected).presentedMessages, payload = plannedPayload(rows)
            let shown = ["reply", "result"].compactMap { payload[$0] }.filter { !$0.isEmpty }.joined(separator: "\n")
            let live = try await model.history.searchPresented(rows, query: "", start: 0)
            XCTAssertEqual(live.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Live paired \(name), separated=\(separated)")
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertEqual(saved.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Saved paired \(name), presented=\(!presented.isEmpty), separated=\(separated)")
            }
        } }
    }

    private func pageBoundaryEntries(_ name: String = "custom_fixture", arguments: WireValue = .object(["message": .string("inputneedle sharedneedle")]),
                                     output: String = "**outputneedle** sharedneedle [site](https://receipt.test)") -> [WireValue] {
        let call = toolEntry(name, arguments: arguments)
        return [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
            .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                "role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(output),
                "nativeToolStats": .object(["outcome": .string("succeeded")])])]),
            .object(["type": .string("message"), "id": .string("answer"), "parentId": .string("result"), "message": .object([
                "role": .string("assistant"), "content": .string("**replyneedle** sharedneedle [reply](https://reply.test)")])])]
    }
    @MainActor private func nativePageSearchText(_ full: [TranscriptMessage], page: [TranscriptMessage], pairs: [(String, String)], raw: Bool = false) -> String {
        var rows = full
        for message in page { if let index = rows.firstIndex(where: { $0.id == message.id }) { rows[index] = message } }
        let complete = plannedPayload(rows, raw: raw), captured = plannedPayload(page, raw: raw)
        // A visible standalone receipt keeps its own native Markdown. Its
        // payload replaces the off-page card output, not the card's input.
        // Pair identities are explicit fixture data, independent of search.
        for (call, receipt) in pairs where captured[receipt] != nil && complete[receipt] == nil {
            if let index = rows.firstIndex(where: { $0.id == call }) { rows[index].tools?[0].output = "" }
        }
        let standalone = page.filter { $0.role == "tool" && complete[$0.id] == nil }.compactMap { captured[$0.id] }
        return (Array(plannedPayload(rows, raw: raw).values) + standalone).joined(separator: "\n")
    }
    @MainActor func testCapturedCallDoesNotDuplicateItsUnloadedReceipt() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let rows = try XCTUnwrap(model.selected).presentedMessages, call = try XCTUnwrap(rows.first)
        XCTAssertEqual(call.tools?.first?.state, "completed")
        XCTAssertEqual(ConversationContent.occurrences(of: "outputneedle", in: plannedPayload([call])[call.id] ?? ""), 1)
        let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "outputneedle", start: 0,
            renderedAgentProse: true, presented: [call])
        XCTAssertEqual(found.hits.map(\.id), ["result"], "The retained receipt owns the card output even outside the captured page")
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 1)
        model.selected?.messages = [call]; pane.refresh()
        try await assertFind("outputneedle", in: pane, window: window, record: "result")
        pane.find.step(1); pane.find.step(-1)
        XCTAssertEqual(pane.find.current, 0); XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
    }
    @MainActor func testFindCountsEveryCallReceiptReplyPageSplitSavedAndLive() async throws {
        let output = "**outputneedle** sharedneedle [site](https://receipt.test)"
        let cases: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["message": .string("inputneedle sharedneedle")]), output),
            ("bash", .object(["command": .string("printf 'inputneedle sharedneedle'")]), output),
            ("read", .object(["path": .string("inputneedle-sharedneedle.txt")]), output),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old inputneedle sharedneedle"), "newText": .string("new editneedle")]), "transportneedle"),
            ("subagent_start", .object(["task": .string("inputneedle sharedneedle")]), #"{"text":"**outputneedle** sharedneedle [site](https://receipt.test)"}"#)]
        let queries = ["inputneedle", "outputneedle", "replyneedle", "sharedneedle", "**outputneedle**", "receipt.test", "transportneedle", "reply.test", "outputneedle sharedneedle"]
        for (name, arguments, output) in cases {
            let (model, _, _) = try await findFixture(saved: true, entries: pageBoundaryEntries(name, arguments: arguments, output: output))
            let saved = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
            XCTAssertEqual(saved.map(\.id), ["reply", "result", "answer"])
            for live in [false, true] { for raw in [false, true] {
                var rows = saved
                if live {
                    rows[2].state = "streaming"
                    rows = try TranscriptMessage.page(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(rows)))
                }
                // Every contiguous page: both edges can fall before, between
                // or after the call, receipt and following reply, including an
                // empty overlay, the receipt alone and the complete group.
                for lower in 0...rows.count { for upper in lower...rows.count {
                    let page = Array(rows[lower..<upper])
                    let shown = nativePageSearchText(saved, page: page, pairs: [("reply", "result")], raw: raw)
                    for query in queries {
                        let found = try await model.history.searchContent(path: path, query: query, start: 0,
                            renderedAgentProse: true, presented: page, rawReplies: raw ? ["reply", "answer"] : [])
                        let expected = ConversationContent.occurrences(of: query, in: shown)
                        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, expected,
                            "\(name), live=\(live), raw=\(raw), page=\(lower)..<\(upper), query=\(query)")
                    }
                } }
            } }
        }
    }

    @MainActor func testFindRevealsCapturedOutputWithoutLoadingItsReceipt() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let call = try XCTUnwrap(model.selected?.presentedMessages.first)
        model.selected?.messages = [call]; pane.refresh()
        var reads: [String] = []
        pane.find.reveal = { _, id in reads.append(id); return false }
        pane.showFind(); pane.find.setQuery("receipt.test")
        try await eventually("Captured output search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
        XCTAssertEqual(pane.document.highlights.focus?.messageID, "reply", "The loaded card draws the receipt's output")
        XCTAssertEqual(pane.document.highlights.focus?.scopeCall, "call")
        XCTAssertTrue(reads.isEmpty, "The output is already loaded; revealing its receipt can replace literal card text with standalone Markdown")
        guard pane.document.highlights.focus?.messageID == "reply" else { return }
        try await assertFind("receipt.test", in: pane, window: window, record: "result")
    }

    @MainActor func testFindKeepsCallInputAndReceiptOutputSeparateWhenReconciling() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let rows = try XCTUnwrap(model.selected).presentedMessages
        for page in [[rows[0]], rows] {
            pane.closeFind(focusing: false); model.selected?.messages = page; pane.refresh()
            pane.showFind(); pane.find.setQuery("sharedneedle")
            try await eventually("Shared input/output search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
            if pane.find.current != 0 { pane.find.step(-(pane.find.current ?? 0)) }
            try await eventually("Shared input/output focus resolves") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending && pane.document.focusText != nil }
            XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply", "result", "answer"], "Reconciling the call must not count its receipt-owned output again")
            XCTAssertTrue(pane.document.focusText?.string.contains("inputneedle") == true)
            pane.find.step(1)
            try await eventually("The receipt occurrence resolves") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending && pane.document.focusText != nil }
            XCTAssertEqual(pane.document.highlights.focus?.record, "result")
            XCTAssertTrue(pane.document.focusText?.string.contains("outputneedle") == true)
        }
    }

    @MainActor func testCompletedWireCardOwnsOneOutputAcrossThePageByteLimit() async throws {
        let output = String(repeating: "padding ", count: 24_000) + "outputneedle"
        let entries = pageBoundaryEntries(output: output)
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        var call = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entries[0].object?["message"]?.object))
        call.tools?[0].state = "completed"; call.tools?[0].output = output
        let result = TranscriptMessage.project(id: "result", message: try XCTUnwrap(entries[1].object?["message"]?.object))
        let bytes = try JSONEncoder().encode([call])
        XCTAssertLessThan(bytes.count + HistoryWindowPolicy.metadataAllowance, HistoryWindowPolicy.envelopeBytes)
        XCTAssertGreaterThan(try JSONEncoder().encode([call, result]).count, HistoryWindowPolicy.envelopeBytes)
        let captured = try TranscriptMessage.page(JSONDecoder().decode(WireValue.self, from: bytes))
        let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "outputneedle", start: 0,
            renderedAgentProse: true, presented: captured)
        XCTAssertEqual(found.hits.map(\.id), ["result"])
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 1)
    }
    @MainActor func testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate() async throws {
        var entries: [WireValue] = [], parent: String?
        for prefix in ["first", "second"] {
            for (index, item) in pageBoundaryEntries(output: "**\(prefix)output** sharedneedle").enumerated() {
                if prefix == "first", index == 1 {
                    var stale = try XCTUnwrap(item.object), fields = try XCTUnwrap(stale["message"]?.object)
                    stale["id"] = .string("stale-result"); stale["parentId"] = parent.map(WireValue.string) ?? .null
                    fields["content"] = .string("staleoutput"); stale["message"] = .object(fields)
                    entries.append(.object(stale)); parent = "stale-result"
                }
                var value = try XCTUnwrap(item.object)
                let id = prefix + "-" + (try XCTUnwrap(value["id"]?.string))
                value["id"] = .string(id); value["parentId"] = parent.map(WireValue.string) ?? .null
                entries.append(.object(value)); parent = id
            }
        }
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        XCTAssertEqual(rows.count, 7); XCTAssertFalse(plannedPayload(rows).values.contains { $0.contains("staleoutput") })
        for lower in 0...rows.count { for upper in lower...rows.count {
            let shown = nativePageSearchText(rows, page: Array(rows[lower..<upper]), pairs: [("first-reply", "first-result"), ("second-reply", "second-result")])
            for query in ["firstoutput", "secondoutput", "staleoutput", "sharedneedle", "**firstoutput**"] {
                let found = try await model.history.searchContent(path: path, query: query, start: 0,
                    renderedAgentProse: true, presented: Array(rows[lower..<upper]))
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(lower)..<\(upper), query=\(query)")
                if query == "firstoutput" || query == "secondoutput" {
                    XCTAssertEqual(found.hits.map(\.id), [query == "firstoutput" ? "first-result" : "second-result"])
                }
            }
        } }
    }
    @MainActor func testEveryLegacyPageSplitKeepsBothDisplayedOutputRows() async throws {
        var entries = pageBoundaryEntries()
        var value = try XCTUnwrap(entries[0].object), fields = try XCTUnwrap(value["message"]?.object)
        var future = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(ResponseTimeline())).object)
        future["version"] = .number(999); fields["nativeResponseTimeline"] = .object(future)
        value["message"] = .object(fields); entries[0] = .object(value)
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        let shown = plannedPayload(rows).values.joined(separator: "\n")
        XCTAssertEqual(ConversationContent.occurrences(of: "outputneedle", in: shown), 2)
        for lower in 0...rows.count { for upper in lower...rows.count {
            for query in ["outputneedle", "**outputneedle**", "receipt.test", "sharedneedle"] {
                let found = try await model.history.searchContent(path: path, query: query, start: 0,
                    renderedAgentProse: true, presented: Array(rows[lower..<upper]))
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(lower)..<\(upper), query=\(query)")
            }
        } }
    }
    @MainActor func testCapturedStandaloneReceiptKeepsItsRenderedText() async throws {
        let entries = pageBoundaryEntries(output: "**alpha** beta and [site](https://receipt.test)")
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, receipt = rows[1]
        let recorded = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entries[0].object?["message"]?.object))
        var carrying = recorded; carrying.tools?[0].output = "capturedliteral"
        for page in [[receipt], [recorded, receipt], [carrying, receipt]] {
            let shown = plannedPayload(page).values.joined(separator: "\n")
            XCTAssertTrue(shown.contains("alpha beta and site"))
            for query in ["alpha beta", "receipt.test", "**alpha** beta", "capturedliteral"] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                    renderedAgentProse: true, presented: page)
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(page.map(\.id)), query=\(query)")
            }
        }
    }
    @MainActor func testCapturedCardKeepsItsDisplayedOutputWhenReceiptIsUnloaded() async throws {
        let (model, _, _) = try await findFixture(saved: true, entries: pageBoundaryEntries(output: "retainedoutput"))
        var call = try XCTUnwrap(model.selected?.presentedMessages.first)
        call.tools?[0].output = "displayedoutput"
        XCTAssertTrue(plannedPayload([call])[call.id]?.contains("displayedoutput") == true)
        for query in ["retainedoutput", "displayedoutput"] {
            let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                renderedAgentProse: true, presented: [call])
            XCTAssertEqual(found.hits.map(\.id), query == "displayedoutput" ? ["result"] : [])
            XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, query == "displayedoutput" ? 1 : 0)
        }
    }
    @MainActor func testCapturedOutputWithoutARetainedReceiptStaysOnItsCall() async throws {
        let entries = pageBoundaryEntries()
        let (model, _, _) = try await findFixture(saved: true, entries: [entries[0]])
        var call = try XCTUnwrap(model.selected?.presentedMessages.first)
        call.tools?[0].state = "completed"; call.tools?[0].output = "outputneedle"
        let path = try XCTUnwrap(model.chats[0].path)
        let saved = try await model.history.searchContent(path: path, query: "outputneedle", start: 0, renderedAgentProse: true, presented: [call])
        let live = try await model.history.searchPresented([call], query: "outputneedle", start: 0)
        XCTAssertEqual(saved.hits.map(\.id), ["reply"]); XCTAssertEqual(live.hits.map(\.id), ["reply"])
        XCTAssertEqual(saved.hits.first?.count, 1); XCTAssertEqual(live.hits.first?.count, 1)
    }

    @MainActor func testColdPlannerContextCrossesDecodeRuns() async throws {
        for tool in [false, true] {
            var fields = tool ? try XCTUnwrap(toolEntry("custom_fixture", arguments: .object(["key": .string("value")]))["message"]?.object) : try recoveryLedger(terminal: "completed")
            if !tool { fields["nativePresentationSourceID"] = .string("result") }
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            var parent = "reply"
            for i in 0..<40 {
                let id = "spacer-\(i)"
                entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                    "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]))
                parent = id
            }
            let result: [String: WireValue] = tool
                ? ["role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta"), "nativeToolStats": .object(["outcome": .string("succeeded")])]
                : ["role": .string("assistant"), "content": .string("Accepted answer")]
            entries.append(.object(["type": .string("message"), "id": .string("result"), "parentId": .string(parent), "message": .object(result)]))
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages
            XCTAssertEqual(rows.count, 42)
            let query = tool ? "**alpha** beta" : "alpha beta"
            for presented in [rows, []] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertEqual(found.hits.map(\.id), tool ? ["result"] : [], "tool=\(tool), presented=\(!presented.isEmpty)")
            }
        }
    }

    func testPlannerDependencyIndexKeepsReusedCallsAndActiveBranchesSeparate() throws {
        let index = try HistoryOffsetIndex()
        let records: [HistoryOffset] = [
            .init(id: "first", parent: nil, offset: 0, length: 1, type: "message", role: "assistant", calls: ["call"]),
            .init(id: "old-result", parent: "first", offset: 1, length: 1, type: "message", role: "toolResult", resultCall: "call"),
            .init(id: "second", parent: "old-result", offset: 2, length: 1, type: "message", role: "assistant", calls: ["call"]),
            .init(id: "new-result", parent: "second", offset: 3, length: 1, type: "message", role: "toolResult", resultCall: "call"),
            .init(id: "operation", parent: "new-result", offset: 4, length: 1, type: "message", role: "system", operationID: "compact"),
            .init(id: "summary", parent: "operation", offset: 5, length: 1, type: "compaction")]
        for record in records { try index.insert(record); try index.append(record) }
        func peers(_ id: String, calls: [String] = [], result: String? = nil, operation: String? = nil) throws -> Set<String> {
            Set(try index.related(to: id, calls: calls, result: result, operation: operation).map(\.id))
        }
        XCTAssertEqual(try peers("first", calls: ["call"]), ["old-result"])
        XCTAssertEqual(try peers("second", calls: ["call"]), ["new-result"])
        XCTAssertEqual(try peers("old-result", result: "call"), ["first"])
        XCTAssertEqual(try peers("new-result", result: "call"), ["second"])
        XCTAssertEqual(try peers("summary", operation: "compact"), ["operation"])
        try index.branch(from: "second", kept: ["first", "old-result"])
        XCTAssertEqual(try peers("first", calls: ["call"]), ["old-result"], "Abandoned call/result links stay outside the active plan")
        XCTAssertTrue(try peers("old-result", operation: "compact").isEmpty)
    }
    @MainActor func testSearchKeepsCapturedOrphanPresentationWhenFinalReplyIsAppended() async throws {
        var fields = try recoveryLedger(terminal: "completed"); fields["nativePresentationSourceID"] = .string("accepted")
        let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])
        let (model, _, _) = try await findFixture(saved: true, entries: [entry])
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        let accepted: WireValue = .object(["type": .string("message"), "id": .string("accepted"), "parentId": .string("reply"),
            "message": .object(["role": .string("assistant"), "content": .string("Accepted answer")])])
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: JSONEncoder().encode(accepted)); try file.write(contentsOf: Data([10]))
        let captured = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: rows)
        XCTAssertEqual(captured.hits.map(\.id), ["reply"], "The current pane still draws the orphan; a later journal append does not override that snapshot")
        let reopened = try await model.history.read(path: path, whole: true)
        let refreshed = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: reopened.messages)
        XCTAssertTrue(refreshed.hits.isEmpty, "The refreshed planner hides the superseded ledger")
    }

    func testPlannerDependencyIndexKeepsLiteralCallIDs() throws {
        let index = try HistoryOffsetIndex()
        let first = "call\u{0}first", second = "call\u{0}second"
        let records: [HistoryOffset] = [
            .init(id: "first", parent: nil, offset: 0, length: 1, type: "message", role: "assistant", calls: [first]),
            .init(id: "second", parent: "first", offset: 1, length: 1, type: "message", role: "assistant", calls: [second]),
            .init(id: "first-result", parent: "second", offset: 2, length: 1, type: "message", role: "toolResult", resultCall: first),
            .init(id: "second-result", parent: "first-result", offset: 3, length: 1, type: "message", role: "toolResult", resultCall: second)]
        for record in records { try index.insert(record); try index.append(record) }
        let peers = try index.related(to: "first-result", calls: [], result: first, operation: nil)
        XCTAssertEqual(Set(peers.map(\.id)), ["first"], "The complete provider call ID selects its own issuer")
    }

    @MainActor func testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns() async throws {
        var fields = try XCTUnwrap(toolEntry("custom_fixture", arguments: .object(["key": .string("value")]))["message"]?.object)
        fields["nativeResponseTimeline"] = .object(["version": .number(999), "segments": .array([]), "omittedEvents": .number(0), "coverage": .string("observed")])
        var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
        var parent = "reply"
        for i in 0..<40 {
            let id = "spacer-\(i)"
            entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "content": .string("Spacer \(i)")])]))
            parent = id
        }
        entries.append(.object(["type": .string("message"), "id": .string("result"), "parentId": .string(parent), "message": .object([
            "role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta"),
            "nativeToolStats": .object(["outcome": .string("succeeded")])])]))
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
        XCTAssertTrue(shown["reply"]?.contains("**alpha** beta") == true)
        XCTAssertEqual(shown["result"], "alpha beta")
        let live = try await model.history.searchPresented(rows, query: "", start: 0)
        for id in ["reply", "result"] { XCTAssertEqual(live.hits.first { $0.id == id }?.preview, shown[id], "Live legacy \(id)") }
        for presented in [rows, []] {
            let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0, renderedAgentProse: true, presented: presented)
            for id in ["reply", "result"] { XCTAssertEqual(saved.hits.first { $0.id == id }?.preview, shown[id], "Saved legacy \(id), presented=\(!presented.isEmpty)") }
        }
    }

    @MainActor func testColdCompactionContextUsesBothRetainedOperationIdentityForms() async throws {
        for nested in [false, true] {
            let identity: WireValue = .object(["operationId": .string("operation"), "version": .number(2), "sourceIDs": .array([]), "protectedIDs": .array([]), "keptIDs": .array([])])
            var timeline = ResponseTimeline(); timeline.finish("completed")
            var operation: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "nativeReplayEligible": .bool(false),
                "nativeDetail": .string("Recorded operation"), "content": .string(""), "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))]
            if nested { operation["nativeCompaction"] = identity } else { operation["nativeOperationID"] = .string("operation") }
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(operation)])]
            var parent = "reply"
            for i in 0..<40 {
                let id = "spacer-\(i)"
                entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": .object([
                    "role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]))
                parent = id
            }
            entries.append(.object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string(parent),
                "summary": .string("Hidden **checkpoint** token"), "nativeCompactionVersion": .number(2), "nativeCompaction": identity]))
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages
            XCTAssertNil(plannedPayload(rows)["summary"])
            for presented in [rows, []] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "checkpoint token", start: 0, renderedAgentProse: true, presented: presented)
                XCTAssertTrue(found.hits.isEmpty, "nested=\(nested), presented=\(!presented.isEmpty)")
            }
        }
    }

    @MainActor private func cardPayload(_ tool: ToolView) -> String {
        let value = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false)
        let card = TranscriptNativeCard.make(value)
        card.update(value, link: nil, environment: .init())
        card.frame = CGRect(x: 0, y: 0, width: 620, height: card.height(width: 620))
        card.layoutSubtreeIfNeeded()
        let payload = TranscriptNativeDocument.textUnits(in: card).compactMap { view -> String? in
            if let lines = view as? TranscriptCardLines { return lines.lines.map(\.text).joined(separator: "\n") }
            guard let text = view as? NSTextView, text.isSelectable else { return nil }
            return text.string
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        // File paths and the agent's row identity are searchable labels outside
        // the selectable payload; retain them while comparing the actual body.
        switch value {
        case .subagent(let agent): return [agent.title, payload].filter { !$0.isEmpty }.joined(separator: "\n")
        case .diff(_, let path?, _, _, _), .read(_, _, let path?, _):
            let label = ConversationPaneTests.views(TranscriptLabel.self, in: card).first { !$0.isHiddenOrHasHiddenAncestor && $0.text == path }
            XCTAssertNotNil(label)
            return [label?.text ?? "", payload].filter { !$0.isEmpty }.joined(separator: "\n")
        default: return payload
        }
    }
    private func toolEntry(_ name: String, arguments: WireValue) -> [String: WireValue] {
        ["id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("toolCall"), "id": .string("call"), "name": .string(name), "arguments": arguments])])])]
    }
    @MainActor func testFindMatchesDisplayedToolJSONInSavedAndLiveReplies() async throws {
        for saved in [true, false] {
            let entry = toolEntry("custom_fixture", arguments: .object(["message": .string("visible card value")]))
            let projected = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entry["message"]?.object))
            let query = try XCTUnwrap(cardPayload(try XCTUnwrap(projected.tools?.first)).split(separator: "\n").first { $0.contains("visible card value") })
                .trimmingCharacters(in: .whitespaces)
            let (model, pane, window) = try await findFixture(saved: saved, content: saved ? entry["message"]?.object?["content"] : nil)
            if !saved { model.selected?.messages[1] = projected; model.selected?.messages[1].state = "streaming"; pane.refresh() }
            try await assertFind(query, in: pane, window: window)
        }
    }
    @MainActor func testFindOpensDecodedEditTextBeyondItsPreview() async throws {
        let query = "middle \"quoted\" change"
        let source = (0..<180).map { $0 == 90 ? query : "fixture line \($0)" }.joined(separator: "\n")
        let entry = toolEntry("edit", arguments: .object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string(source)]))
        let (_, pane, window) = try await findFixture(saved: true, content: entry["message"]?.object?["content"])
        try await assertFind(query, in: pane, window: window)
        if !pane.find.matches.isEmpty {
            XCTAssertTrue(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: pane.document).contains(where: \.expanded))
        }
    }
    @MainActor func testToolSearchProjectionEqualsNativeCardPayloadsSavedAndLive() throws {
        let corpus: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["message": .string("two words 🌍 \"quoted\"\nnext line"), "nested": .object(["flag": .bool(true), "items": .array([.number(2), .null])])]), "output **stays literal**"),
            ("mcp", .object(["server": .string("fixture"), "tool": .string("lookup"), "arguments": .object(["key": .string("some value")])]), "result"),
            ("find", .object(["pattern": .string("*.swift"), "path": .string("fixture")]), "fixture/a.swift"),
            ("grep", .object(["pattern": .string("two words"), "path": .string("fixture")]), "fixture/a.swift:2: two words"),
            ("ls", .object(["path": .string("fixture")]), "first\nsecond"),
            ("bash", .object(["command": .string("printf 'one two'\nprintf 'three'"), "timeout": .number(12)]), "one two\nthree"),
            ("read", .object(["path": .string("fixture.txt"), "offset": .number(4)]), "first line\nlast line\n[Truncated. 9 total lines; read another range.]"),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("shared\nold \"tail\""), "newText": .string("shared\nnew \"tail\"")]), "applied"),
            ("write", .object(["path": .string("fixture.txt"), "content": .string("first line\nlast \"line\"")]), "written"),
            ("subagent_start", .object(["description": .string("Separate label"), "task": .string("1. **first**\n2. [second](https://example.test)")]), "{\"text\":\"**done** now\"}"),
            ("subagent_send", .object(["child_id": .string("fixture-child"), "message": .string("Check **these** words.")]), "{\"accepted\":true}"),
            ("subagent_report", .object(["kind": .string("note"), "message": .string("A **reported** observation.")]), "{\"accepted\":true}")
        ]
        for (name, arguments, output) in corpus {
            let entry = toolEntry(name, arguments: arguments)
            let saved = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entry["message"]?.object))
            let tool = try XCTUnwrap(saved.tools?.first)
            XCTAssertEqual(ConversationContent.transcriptText(entry), cardPayload(tool), "Saved \(name)")
            for state in ["running", "completed", "held", "failed", "unknown"] {
                var live = saved; live.responseTimeline = nil; live.state = "streaming"
                live.tools?[0].state = state; live.tools?[0].output = output
                XCTAssertEqual(ConversationContent.transcriptText(live), cardPayload(try XCTUnwrap(live.tools?.first)), "Live \(name), \(state)")
            }
        }
        for input in [#"{"message":"complete field","tail":"unfinished"#,
                      #"{"message":"a \"quoted\" value","tail":"unfinished"#,
                      #"{"message":"unterminated"#] {
            let tool = ToolView(id: "partial", name: "custom_fixture", state: "running", input: input, output: "", truncated: false, inputTruncated: true)
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "", tools: [tool], state: "streaming")
            XCTAssertEqual(ConversationContent.transcriptText(message), cardPayload(tool), "Partial input \(input)")
        }
    }

    @MainActor func testFindProjectionEqualsNativeReplyTextAcrossMarkdownCorpus() throws {
        let corpus = ["**alpha** beta and _italic_ ~~gone~~ `code`", "# Heading\n\nBody\n\nSetext\n------",
                      "1. alpha\n2. beta", "7. seven\n29. eight\n   - nested\n\n     > quote",
                      "- ```swift\n  let x = 1\n  ```\n- next", "> # Quote\n>\n> body\n>\n> 1. one\n> 2. two",
                      "```text\nfirst\n\nlast\n```\n\n~~~\n~~~", "[site](https://example.test) and [reference][id]\n\n[id]: https://reference.test",
                      "![alt](https://image.test/a.png)\n\n<!-- hidden -->\n\nvisible", "| A | B |\n|---|---|\n| one | |\n| two | three |",
                      "| A | B |\n|---|---|\n" + (0..<45).map { "| row \($0) | value |" }.joined(separator: "\n"),
                      "Before **unfinished", "[unfinished](https://example.test", "1. first\n2."]
        for (index, source) in corpus.enumerated() {
            for streaming in [false, true] { for raw in [false, true] {
                let message = TranscriptMessage(id: "corpus", role: "assistant", text: source, state: streaming ? "streaming" : "complete")
                let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
                    actions: .init(), width: 620, environment: .init(), disclosure: .init(raw: raw), toggle: { _ in }))
                let shown = TranscriptNativeDocument.textViews(in: row).filter(\.isSelectable).map(\.string).joined(separator: "\n")
                XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "Corpus \(index), streaming=\(streaming), raw=\(raw)")
                if !streaming {
                    let entry: [String: WireValue] = ["id": .string("corpus"), "message": .object(["role": .string("assistant"), "content": .string(source)])]
                    XCTAssertEqual(ConversationContent.transcriptText(entry, rawReply: raw), shown, "Saved corpus \(index), raw=\(raw)")
                }
            } }
        }
    }

    @MainActor func testTimelineProjectionEqualsEachNativeSegmentInBothModes() throws {
        var timeline = ResponseTimeline()
        for (index, kind) in ["text", "refusal", "reasoningText", "reasoningSummary", "opaque", "text"].enumerated() {
            timeline.consume(.init(attemptID: "fixture", ordinal: index, itemID: "part-\(index)", kind: kind,
                update: index == 5 ? "append" : "replace", text: "\(index + 1). [site](https://part\(index).test)\n\n**alpha** beta"))
        }
        for streaming in [false, true] { for raw in [false, true] {
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "Canonical text is not the arrival-ordered rows",
                                           state: streaming ? "streaming" : "complete", responseTimeline: timeline)
            let shown = timeline.segments.map { part -> String in
                let view = TranscriptNativePartView(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
                view.update(.init(part: part, message: message, actions: .init(), open: true, toggle: {}, raw: raw, toggleRow: { _ in }, environment: .init()))
                return TranscriptNativeDocument.textViews(in: view).filter(\.isSelectable).map(\.string).joined(separator: "\n")
            }.joined(separator: "\n")
            XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "streaming=\(streaming), raw=\(raw)")
            if !streaming {
                let entry: [String: WireValue] = ["id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .string(message.text),
                    "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])]
                XCTAssertEqual(ConversationContent.transcriptText(entry, rawReply: raw), shown, "saved raw=\(raw)")
            }
        } }
    }

    @MainActor func testFindOpensTimelineProseForItsRenderedListMarker() async throws {
        for kind in ["reasoningText", "reasoningSummary", "opaque", "correction"] {
            let (model, pane, window) = try await findFixture(saved: false)
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: kind, update: "replace", text: "7. first\n29. second"))
            model.selected?.messages[1].responseTimeline = timeline
            pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await assertFind("8.", in: pane, window: window)
        }
    }

    @MainActor func testAgentMarkdownSearchIncludesItsNativeListMarkers() {
        let view = TranscriptAgentMarkdown(label: "Task", identity: "list-marker")
        view.update("7. first\n29. second", environment: .init())
        XCTAssertTrue(view.markdown.textView.string.contains("8."))
        XCTAssertTrue(view.contains("8.", flexible: false), "The agent preview uses the same searchable text as its native surface")
    }

    func testSavedFindProjectsAssistantTextAlongsideToolCalls() throws {
        let prose: WireValue = .object(["type": .string("text"), "text": .string("**alpha** beta")])
        for name in ["read", "subagent_start"] {
            let tool: WireValue = .object(["type": .string("toolCall"), "id": .string("call"), "name": .string(name), "arguments": .object(["path": .string("fixture.txt"), "task": .string("Check **task** boundaries and \\*literal\\*.")])])
            let entry: [String: WireValue] = ["type": .string("message"), "id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .array([prose, tool])])]
            XCTAssertEqual(ConversationContent.occurrences(of: "alpha beta", in: ConversationContent.transcriptText(entry)), 1, name)
            XCTAssertTrue(ConversationContent.text(entry).contains("**alpha** beta"))
            if SubagentToolView.isControl(name) {
                XCTAssertTrue(ConversationContent.transcriptText(entry).contains("Check task boundaries and *literal*."), "Already-rendered agent text is never parsed twice")
            }
        }
    }

    func testSavedFindProjectsTimelineProseAndKeepsSourceEvidence() throws {
        for kind in ["text", "reasoningText", "reasoningSummary"] {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "text", kind: kind, update: "replace", text: "**alpha** beta"))
            timeline.consume(.init(attemptID: "fixture", ordinal: 1, itemID: "tool", kind: "toolArguments", update: "replace", text: "**literal** argument"))
            timeline.finish("completed")
            let entry: [String: WireValue] = ["message": .object(["role": .string("assistant"), "content": .string("**alpha** beta"),
                "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])]
            let projected = ConversationContent.transcriptText(entry)
            XCTAssertEqual(ConversationContent.occurrences(of: "alpha beta", in: projected), 1, kind)
            XCTAssertTrue(projected.contains("**literal** argument"))
            XCTAssertTrue(ConversationContent.text(entry).contains("**alpha** beta"))
        }
        let user: [String: WireValue] = ["message": .object(["role": .string("user"), "content": .string("**alpha** beta")])]
        XCTAssertEqual(ConversationContent.transcriptText(user), "**alpha** beta")
        XCTAssertEqual(ConversationContent.text(user), "## user\n\n**alpha** beta\n\n", "Export keeps its source heading")
    }
}
