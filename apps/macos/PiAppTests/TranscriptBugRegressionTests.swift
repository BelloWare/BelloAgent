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

    @MainActor private func findFixture(saved: Bool, reasoning: Bool = false, source: String = "**alpha** beta", content: WireValue? = nil) async throws -> (WorkspaceModel, NativeTranscriptPane, NSWindow) {
        let root = scratchRoot("ordinary-markdown-find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let answer: WireValue = content ?? (saved && reasoning ? .array([
            .object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
            .object(["type": .string("text"), "text": .string("Done.")])]) : .string(saved ? source : "Earlier saved text"))
        let records: [WireValue] = [
            .object(["type": .string("session"), "version": .number(3), "id": .string("ordinary-find")]),
            .object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                     "message": .object(["role": .string("user"), "content": .string("Reply")])]),
            .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"),
                     "message": .object(["role": .string("assistant"), "content": answer])])]
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

    @MainActor private func assertFind(_ query: String, in pane: NativeTranscriptPane, window: NSWindow) async throws {
        pane.showFind(); pane.find.setQuery(query)
        try await eventually("Search finishes for \(query)") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply"])
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
        XCTAssertEqual(ConversationContent.transcriptText(user), ConversationContent.text(user))
    }
}
