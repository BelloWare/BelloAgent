import AppKit
import XCTest
@testable import PiApp

final class TranscriptBugGalleryTests: XCTestCase {
    @MainActor func testRepeatedCardExpansionGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for tool in ["read", "edit"] {
            for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
                let session = SessionDisplay(id: "repeated-card-gallery")
                session.messages = [TranscriptBugRegressionTests.repeatedCards(tool)]
                let page = TranscriptPage(); page.state = "idle"; page.bind(session)
                for case .block(let block) in page.snapshot?.items ?? [] where block.presentation == .work {
                    session.disclosure.setOpen(true, .work(block.key))
                }
                for call in ["A", "B"] { session.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", call))) }
                let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 720))
                let document = TranscriptNativeDocument(page: page); scroll.documentView = document
                let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll; window.makeKeyAndOrderFront(nil)
                defer { window.contentView = nil; window.close() }
                var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
                document.update(snapshot: page.snapshot, actions: .init(), environment: environment, disclosure: session.disclosure)
                document.layoutRows(width: scroll.contentSize.width); document.finishDisclosureMotion()
                let rows = document.rows(drawing: "reply").filter { if case .block(let block) = $0.item { return block.presentation == .work }; return false }
                XCTAssertEqual(rows.count, 3)
                for row in rows { row.prepareToDraw(); row.layoutForViewport() }
                XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptCardMoreLines.self, in: rows[0]).first).accessibilityPerformPress())
                try await eventually("Both \(tool) cards expand in \(name)") {
                    document.layoutRows(width: scroll.contentSize.width); window.displayIfNeeded()
                    return [rows[0], rows[2]].allSatisfy { row in
                        row.prepareToDraw(); row.layoutForViewport()
                        return tool == "read" ? ConversationPaneTests.views(TranscriptNativeReadCard.self, in: row).first?.expanded == true
                            : ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: row).first?.expanded == true
                    }
                }
                scroll.contentView.scroll(to: CGPoint(x: 0, y: rows[2].frame.minY))
                for _ in 0..<4 { scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
                let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("repeated-\(tool)-\(name).png"))
            }
        }
    }
    @MainActor func testExpandedReadRemountGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
            let tool = TranscriptNativeWorkBehaviourTests.read(output: (1...100).map { "Generated line \($0)" }.joined(separator: "\n"))
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "", tools: [tool])
            let item = try XCTUnwrap(TaskTranscriptPlan.rows([message], lifecycle: nil).first { if case .block(let block) = $0 { return block.presentation == .work }; return false })
            let disclosure = TranscriptDisclosure()
            if case .block(let block) = item { disclosure.setOpen(true, .work(block.key)) }
            disclosure.setOpen(true, .tool(ToolOccurrence.key(message.id, tool.id)))
            var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
            let row = TranscriptRowContainer(item: item, fresh: false, actions: .init(), environment: environment, disclosure: disclosure)
            let following = TranscriptRowContainer(item: TranscriptNativePartView.wordsItem(.init(id: "next", role: "assistant", text: "Following reply, immediately after the expanded card.")), fresh: false, actions: .init(), environment: environment)
            let canvas = TranscriptNativeRowParityTests.ParityCanvas()
            canvas.addSubview(row); canvas.addSubview(following)
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 640)); scroll.documentView = canvas
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll; window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            func draw() {
                row.frame = CGRect(origin: .zero, size: row.measure(width: width))
                following.frame = CGRect(origin: CGPoint(x: 0, y: row.frame.maxY), size: following.measure(width: width))
                canvas.frame.size = CGSize(width: width, height: following.frame.maxY + 24)
                row.layoutForViewport(); following.layoutForViewport(); window.displayIfNeeded()
            }
            draw()
            XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptCardMoreLines.self, in: row).first).accessibilityPerformPress())
            try await eventually("Expanded read validates before eviction") { draw(); return !row.needsMountedValidation }
            window.makeFirstResponder(nil); row.releaseHost(); XCTAssertFalse(row.isHosted)
            row.prepareToDraw(); draw()
            XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeReadCard.self, in: row).first).expanded)
            XCTAssertEqual(row.frame.height, row.hostedFittingHeight, accuracy: 1)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, canvas.frame.height - scroll.contentSize.height)))
            for _ in 0..<4 { draw(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("expanded-read-\(name).png"))
        }
    }
    @MainActor func testReorderedTableDetailsGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(880)), ("dark", .darkAqua, 880), ("narrow", .aqua, 440)] {
            let before = Set(MarkdownTableWindow.open.map(ObjectIdentifier.init))
            MarkdownTableWindow.open(header: [AttributedString("A"), AttributedString("B")], rows: (1...41).map { [AttributedString("A\($0)"), AttributedString("B\($0)")] })
            let window = try XCTUnwrap(MarkdownTableWindow.open.first { !before.contains(ObjectIdentifier($0)) })
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance); window.setContentSize(CGSize(width: width, height: 600))
            let controller = try XCTUnwrap(MarkdownTableWindow.controller(of: window)), content = try XCTUnwrap(window.contentView)
            let table = try XCTUnwrap(controller.gridScroll.documentView as? NSTableView)
            table.moveColumn(1, toColumn: 0); table.reloadData(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.showCell(row: 0, column: 0)
            XCTAssertEqual((controller.detailScroll.documentView as? NSTextView)?.string, "B1")
            for _ in 0..<4 { content.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("reordered-table-\(name).png"))
        }
    }

    @MainActor func testRecoveredLedgerFindGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "recovery", ordinal: 0, itemID: "thought", kind: "reasoningText", update: "replace", text: "Keep **alpha** beta in the recovered reasoning."))
            timeline.consume(.init(attemptID: "recovery", ordinal: 1, itemID: "words", kind: "text", update: "replace", text: "# Recovered reply\n\nVisible **gamma** delta and [a retained link](https://recovery.test)."))
            let session = SessionDisplay(id: "recovery-gallery")
            session.messages = [.init(id: "question", role: "user", text: "Show the retained response after recovery."),
                .init(id: "ledger", role: "system", text: "", kind: "requestLedger", presentationSourceID: "missing", responseTimeline: timeline),
                .init(id: "operation", role: "system", text: "", kind: "execution", detail: "Compaction stage · no terminal receipt", responseTimeline: ResponseTimeline())]
            let page = TranscriptPage(); page.state = "idle"; page.bind(session)
            for case .block(let block) in page.snapshot?.items ?? [] where block.part != nil { session.disclosure.setOpen(true, .work(block.key)) }
            session.disclosure.setOpen(true, .compaction("operation"))
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            let document = TranscriptNativeDocument(page: page); scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll; window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
            document.update(snapshot: page.snapshot, actions: .init(), environment: environment, disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width); document.finishDisclosureMotion()
            for row in document.retainedRows { row.prepareToDraw(); row.layoutForViewport() }
            document.highlights = TranscriptHighlights(query: "gamma delta", focus: .init(messageID: "ledger", needle: "gamma delta", occurrence: 0, serial: 1, fromFind: true, record: "ledger"))
            try await eventually("Recovered phrase is highlighted in \(name)") {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return !document.focusPending && document.focusText != nil
            }
            let text = try XCTUnwrap(document.focusText)
            XCTAssertEqual((text.string as NSString).substring(with: document.focusRange), "gamma delta")
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("recovery-\(name).png"))
        }
    }
    @MainActor func testUserFindAndSummaryRowsGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
            let session = SessionDisplay(id: "find-row-gallery")
            session.messages = [.init(id: "first", role: "user", text: "First user message."),
                .init(id: "second", role: "user", text: "Second user message."),
                .init(id: "summary", role: "system", text: "Conversation summary:\n\nKeep **alpha** beta.\n\n1. first\n2. second", kind: "compaction", detail: "Compacted 120 tokens · 2 messages kept"),
                .init(id: "notice", role: "system", text: "Waiting for sub-agents", kind: "notice"),
                .init(id: "agent", role: "user", text: "**Agent** result with [a link](https://example.test).", kind: "agent_message",
                      nativeAgentDelivery: .object(["author": .string("subagent"), "childId": .string("child"), "turn": .number(1)]))]
            session.disclosure.setOpen(true, .compaction("summary"))
            let page = TranscriptPage(); page.state = "idle"; page.bind(session)
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            let document = TranscriptNativeDocument(page: page); scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
            document.update(snapshot: page.snapshot, actions: .init(), environment: environment, disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width); document.finishDisclosureMotion()
            for row in document.retainedRows { row.prepareToDraw(); row.layoutForViewport() }
            document.highlights = TranscriptHighlights(query: "user", focus: .init(messageID: "second", needle: "user", occurrence: 0, serial: 1, fromFind: true, record: "second"))
            try await eventually("User highlight is visible in \(name)") {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return !document.focusPending && document.focusText?.string == "Second user message."
            }
            XCTAssertEqual(document.focusRange, NSRange(location: 7, length: 4))
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("rows-\(name).png"))
        }
    }
    @MainActor func testHeadingCopyLiteralMarkerDiffAndFormattedFindGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
            let session = SessionDisplay(id: "transcript-bug-gallery")
            let reply = TranscriptMessage(id: "reply", role: "assistant", text: TranscriptBugRegressionTests.nestedHeading + "\n\n**alpha** beta\n\n1. first\n2. second",
                tools: [try TranscriptBugRegressionTests.editTool()], at: 2, turn: "question")
            session.messages = [.init(id: "question", role: "user", text: "Review the heading, edit and formatted phrase.", at: 1), reply]
            let page = TranscriptPage(); page.state = "idle"; page.bind(session)
            for case .block(let block) in page.snapshot?.items ?? [] where block.presentation == .work {
                session.disclosure.setOpen(true, .work(block.key))
            }
            session.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", "edit")))
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            let document = TranscriptNativeDocument(page: page); scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
            document.update(snapshot: page.snapshot, actions: .init(), environment: environment, disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width); document.finishDisclosureMotion()
            for row in document.retainedRows { row.prepareToDraw(); row.layoutForViewport() }
            XCTAssertEqual(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: document).count, 1)
            document.highlights = TranscriptHighlights(query: "2.")
            scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: document).first { $0.textView.string.contains("Real") })
            let text = surface.textView, manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            let range = (text.string as NSString).range(of: "Real")
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
            surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
            XCTAssertTrue(surface.bounds.contains(action.frame), "Heading Copy fits the \(name) surface")
            XCTAssertTrue(scroll.bounds.contains(surface.convert(action.frame, to: scroll)), "Heading Copy fits the \(name) viewport")
            scroll.layoutSubtreeIfNeeded(); scroll.displayIfNeeded()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("transcript-\(name).png"))
        }
    }
}
