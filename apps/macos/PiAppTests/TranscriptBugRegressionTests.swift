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

    @MainActor private func findFixture(saved: Bool, reasoning: Bool = false, source: String = "**alpha** beta") async throws -> (WorkspaceModel, NativeTranscriptPane, NSWindow) {
        let root = scratchRoot("ordinary-markdown-find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let answer: WireValue = saved && reasoning ? .array([
            .object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
            .object(["type": .string("text"), "text": .string("Done.")])]) : .string(saved ? source : "Earlier saved text")
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
        if alreadySearching { pane.find.step(1) }
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
