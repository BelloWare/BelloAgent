import XCTest
import AppKit
import Combine
import SwiftUI
@testable import PiApp

final class InlineSkillTests: XCTestCase {
    private func token(_ text: String, caret: Int? = nil, selected: Int = 0, marked: Bool = false) -> SlashCompletionToken? {
        SlashCompletionToken.local(in: text as NSString, at: ComposerLocation(sessionID: "a", editorGeneration: UUID(), draftRevision: 1,
            selectedRangeUTF16: NSRange(location: caret ?? (text as NSString).length, length: selected), markedRangeUTF16: marked ? NSRange(location: 0, length: 1) : nil), directInput: true)
    }
    private func skill(_ id: String, name: String, description: String = "review changes", policy: String = "explicitOnly") -> SkillDescriptor {
        SkillDescriptor(id: id, name: name, path: "/skills/\(id)/SKILL.md", description: description, scope: "project", contentHash: "hash", metadataHash: "meta", policy: policy, reasons: [], missingDependencies: [])
    }
    func testCaretLocalUTF16AndLiteralExclusions() {
        for prefix in ["Please use ", "中文 🌍 e\u{301}\n", "(", ""] {
            let text = prefix + "/rev trailing prose", caret = (prefix as NSString).length + 3
            let found = token(text, caret: caret)
            XCTAssertEqual(found?.query, "rev")
            XCTAssertEqual(found.map { (text as NSString).replacingCharacters(in: $0.replacementRangeUTF16, with: "") }, prefix + " trailing prose")
            XCTAssertEqual(found?.wholeMessageCommandEligible, false)
        }
        for text in ["https://host/path", "/Users/me/project", "src/module", "\\/review", "/" + String(repeating: "a", count: 65)] { XCTAssertNil(token(text), text) }
        XCTAssertNil(token("/review", selected: 1)); XCTAssertNil(token("/review", marked: true))
        for text in ["`/review", "```swift\n/review", "~~~swift\n/review", "   ~~~~\n/review", "~~~\n~~~not a closing fence\n/review", "before ``/review"] {
            let slash = (text as NSString).range(of: "/review").location
            XCTAssertFalse(SlashCompletionToken.outsideCode(text, before: slash))
        }
        XCTAssertTrue(SlashCompletionToken.outsideCode("`literal` now /review", before: 14))
        let afterFence = "~~~swift\nliteral\n~~~~\n/review"
        XCTAssertTrue(SlashCompletionToken.outsideCode(afterFence, before: (afterFence as NSString).range(of: "/review").location))
    }
    func testSharedRankingSlashNameTermsPathsAndAllResults() {
        let values = [skill("d", name: "code-review"), skill("b", name: "reviewer"), skill("a", name: "réview"), skill("c", name: "prereview"), skill("x", name: "other", description: "REVIEW changes"), skill("off", name: "review", policy: "disabled")]
        let entries = values.map(SkillSearch.Entry.init)
        XCTAssertEqual(SkillSearch.search(entries, query: " /review ", actionable: true).map(\.id), ["a", "b", "d", "c", "x"])
        XCTAssertEqual(SkillSearch.search(entries, query: "/skills/d", actionable: true).map(\.id), ["d"])
        XCTAssertEqual(SkillSearch.search(entries, query: "other changes", actionable: true).map(\.id), ["x"])
        XCTAssertTrue(SkillSearch.search(entries, query: "review", actionable: false).contains { $0.id == "off" })
        let many = (0..<512).map { SkillSearch.Entry(skill(String($0), name: "review-\($0)")) }
        XCTAssertEqual(SkillSearch.search(many, query: "review", actionable: true).count, 512)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent(); _ = SkillSearch.search(many, query: "review-51", actionable: true)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        print("Inline skill search 512-entry p95 ms: \(samples.sorted()[95])")
        #if PI_RELEASE_TESTS
        XCTAssertLessThan(samples.sorted()[95], 10)
        #endif
    }
    @MainActor func testDifferentComposersLoadIndependentlyAndBadPagesDoNotAuthorize() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        try await model.reloadConfiguration(); model.selectedWorkspaceID = "p"
        let a = SessionDisplay(id: "a"), b = SessionDisplay(id: "b"); model.displays = [a.id: a, b.id: b]
        model.chats = [ChatRecord(id: "a", workspaceID: "p", title: "A", profileID: "p"), ChatRecord(id: "b", workspaceID: "q", title: "B", profileID: "p", toolMode: "read-only")]
        let values = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode([skill("a", name: "review")]))
        var pending: CheckedContinuation<Void, Never>?
        let first = Task { await model.loadSkillCatalog(sessionID: "a", readPage: { _, _ in
            await withCheckedContinuation { pending = $0 }
            return ["revision": .string("A"), "skills": values, "total": .number(1)]
        }) }
        while pending == nil { await Task.yield() }
        await model.loadSkillCatalog(sessionID: "b", readPage: { _, id in
            XCTAssertEqual(id, "b")
            return ["revision": .string("B"), "skills": values, "total": .number(1)]
        })
        XCTAssertEqual(b.skillCatalog.revision, "B"); XCTAssertEqual(a.skillCatalog.state, .loading)
        pending?.resume(); await first.value
        XCTAssertEqual(a.skillCatalog.revision, "A"); XCTAssertEqual(b.skillCatalog.revision, "B")
        await model.loadSkillCatalog(refresh: true, sessionID: "b", readPage: { _, _ in
            ["revision": .string("bad"), "skills": values, "total": .number(2), "next": .number(0)]
        })
        XCTAssertEqual(b.skillCatalog.state, .failed); XCTAssertFalse(b.skillCatalog.authorizes)
        XCTAssertEqual(b.skillCatalog.entries.count, 1, "Keep previous results labelled unavailable")
        await model.loadSkillCatalog(refresh: true, sessionID: "b", readPage: { _, _ in
            ["revision": .string("bad-type"), "skills": values, "total": .number(1), "next": .string("invalid")]
        })
        XCTAssertEqual(b.skillCatalog.state, .failed)
        let nextValues = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode([skill("second", name: "second-review")]))
        await model.loadSkillCatalog(refresh: true, sessionID: "b", readPage: { params, _ in
            if params["offset"]?.number == 0 { return ["revision": .string("paged"), "skills": values, "total": .number(2), "next": .number(1)] }
            return ["revision": .string("paged"), "skills": nextValues, "total": .number(2), "diagnostics": .array([.string("An optional source was unavailable")])]
        })
        XCTAssertEqual(b.skillCatalog.state, .partial); XCTAssertEqual(b.skillCatalog.entries.count, 2)
        XCTAssertTrue(b.skillCatalog.authorizes); XCTAssertFalse(b.skillCatalog.notice.isEmpty)
    }
    @MainActor func testNativeReplacementUndoRedoKeepsExplicitSelectionWithText() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerTextView(frame: window.contentView!.bounds); editor.isRichText = false; editor.allowsUndo = true; editor.sessionID = "a"
        window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        let view = SessionDisplay(id: "a"), text = "中文 🌍 use /review please"
        view.draft = text; editor.string = text
        let range = (text as NSString).range(of: "/review"); editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        editor.replaceCompletion(range: range, with: "", skills: [skill("a", name: "review").chip], display: view, changed: {})
        XCTAssertEqual(view.draft, "中文 🌍 use  please"); XCTAssertEqual(view.skills.count, 1)
        editor.undoManager?.undo(); XCTAssertEqual(editor.string, text); XCTAssertTrue(view.skills.isEmpty)
        editor.undoManager?.redo(); XCTAssertEqual(view.draft, "中文 🌍 use  please"); XCTAssertEqual(view.skills.count, 1)
    }
    func testMaximumDraftLocalParsingIsBoundedAndCodeClassificationIsSeparate() {
        let text = String(repeating: "x ", count: 131_050) + "/review", source = text as NSString
        let location = ComposerLocation(sessionID: "a", editorGeneration: UUID(), draftRevision: 1, selectedRangeUTF16: NSRange(location: source.length, length: 0), markedRangeUTF16: nil)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(SlashCompletionToken.local(in: source, at: location, directInput: false)?.query, "review")
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        XCTAssertTrue(SlashCompletionToken.outsideCode(text, before: source.length - 7))
        print("256 KiB draft local token p95 ms: \(samples.sorted()[95])")
        #if PI_RELEASE_TESTS
        XCTAssertLessThan(samples.sorted()[95], 5)
        #endif
    }
    /// Typing "/sk", then "i", then Backspace must leave the list shown. The
    /// code-span cache was keyed on the draft revision, so every keystroke
    /// missed it: the list was hidden at once and shown again a turn later by
    /// the background classification, and the owner saw it flicker.
    @MainActor func testTypingInsideTheSlashTokenNeverHidesTheList() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let view = SessionDisplay(id: "a"); model.displays[view.id] = view
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "A", profileID: "p")]
        let all = [skill("s1", name: "skill-review"), skill("s2", name: "skim-notes"), skill("s3", name: "sketch")]
        view.skillCatalog = SkillCatalog(state: .ready, scope: model.skillScope(sessionID: view.id, workspaceID: "w"), revision: "v1", entries: all.map(SkillSearch.Entry.init))
        let hosted = NSHostingView(rootView: NativeComposer(text: Binding(get: { view.draft }, set: { view.draft = $0 }), send: { _ in XCTFail("Typing must not submit") }, sessionID: view.id,
            locationChanged: { model.composerMoved($0, editor: $1, view: view) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func find(_ node: NSView) -> ComposerTextView? {
            if let editor = node as? ComposerTextView { return editor }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        hosted.layoutSubtreeIfNeeded(); let editor = try XCTUnwrap(find(hosted)); window.makeFirstResponder(editor)
        /// One keystroke, then everything it schedules: the location hop and
        /// any background classification.
        func key(_ edit: () -> Void) async throws {
            let before = view.composerLocation?.draftRevision
            edit()
            for _ in 0..<400 where view.composerLocation?.draftRevision == before { try await Task.sleep(for: .milliseconds(5)) }
            await view.completionParse?.value
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await key { editor.insertText("/sk", replacementRange: editor.selectedRange()) }
        for _ in 0..<200 where !view.completionVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(view.completionVisible); XCTAssertEqual(model.completions(view).map(\.name), ["sketch", "skill-review", "skim-notes"])
        var shown: [Bool] = []
        let watch = view.$completionVisible.dropFirst().sink { shown.append($0) }; defer { watch.cancel() }
        try await key { editor.insertText("i", replacementRange: editor.selectedRange()) }
        XCTAssertEqual(view.draft, "/ski")
        // "sketch" stays on its path, under skills/, behind the two names "ski" starts.
        XCTAssertEqual(model.completions(view).map(\.name), ["skill-review", "skim-notes", "sketch"])
        try await key { editor.deleteBackward(nil) }
        XCTAssertEqual(view.draft, "/sk"); XCTAssertEqual(model.completions(view).count, 3)
        XCTAssertTrue(view.completionVisible)
        XCTAssertFalse(shown.contains(false), "The list hid and showed again while typing inside its token: \(shown)")
        // An edit before the slash still asks again: the cache holds only for
        // the text its answer was about.
        try await key {
            editor.insertText("`x ", replacementRange: NSRange(location: 0, length: 0))
            editor.setSelectedRange(NSRange(location: 6, length: 0))
        }
        XCTAssertEqual(view.draft, "`x /sk")
        XCTAssertFalse(view.completionVisible); XCTAssertNil(view.completionToken)
    }

    @MainActor func testMountedCaretSelectionBeyondEightAndStaleAcceptance() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let view = SessionDisplay(id: "a"); model.displays[view.id] = view
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "A", profileID: "p")]
        let all = (0..<12).map { skill("skill-\($0)", name: "review-\($0)") }
        view.skillCatalog = SkillCatalog(state: .ready, scope: model.skillScope(sessionID: view.id, workspaceID: "w"), revision: "v1", entries: all.map(SkillSearch.Entry.init))
        let original = "中文 👨‍👩‍👧‍👧 use /rev on this change"
        view.draft = original
        let hosted = NSHostingView(rootView: NativeComposer(text: Binding(get: { view.draft }, set: { view.draft = $0 }), send: { _ in XCTFail("Selection must not submit") }, sessionID: view.id,
            locationChanged: { model.composerMoved($0, editor: $1, view: view) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func find(_ node: NSView) -> ComposerTextView? {
            if let editor = node as? ComposerTextView { return editor }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        hosted.layoutSubtreeIfNeeded(); let editor = try XCTUnwrap(find(hosted)); window.makeFirstResponder(editor)
        let range = (original as NSString).range(of: "/rev")
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        for _ in 0..<200 where !view.completionVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(view.completionVisible); XCTAssertEqual(model.completions(view).count, 12)
        for _ in 0..<10 { XCTAssertTrue(model.completionKey(125, view: view)) }
        let chosen = try XCTUnwrap(model.completions(view).first { $0.id == view.completionSelectionID })
        view.draft = "newer draft"
        model.chooseCompletion(chosen, view: view)
        XCTAssertEqual(view.draft, "newer draft"); XCTAssertTrue(view.skills.isEmpty)
        view.draft = original
        XCTAssertTrue(model.completionKey(48, view: view))
        XCTAssertEqual(view.skills.first?.id, chosen.id)
        XCTAssertEqual(view.skills.first?.intent, "picker"); XCTAssertEqual(view.skills.first?.arguments, "")
        XCTAssertEqual(editor.string, "中文 👨‍👩‍👧‍👧 use  on this change")
        editor.undoManager?.undo(); XCTAssertEqual(view.draft, original); XCTAssertTrue(view.skills.isEmpty)
        editor.undoManager?.redo(); XCTAssertEqual(view.skills.first?.id, chosen.id)
        editor.insertText("plain /rev", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        for _ in 0..<200 where !view.completionVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(view.completionVisible)
        let priorRevision = try XCTUnwrap(view.composerLocation?.draftRevision)
        // Same length and slash offset, different code classification. Real
        // text edits must invalidate the cache even when the caret is stable.
        editor.insertText("`code", replacementRange: NSRange(location: 0, length: 5))
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        for _ in 0..<200 where view.composerLocation?.draftRevision == priorRevision { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(try XCTUnwrap(view.composerLocation?.draftRevision), priorRevision)
        XCTAssertFalse(view.completionVisible); XCTAssertNil(view.completionToken)
    }

}
