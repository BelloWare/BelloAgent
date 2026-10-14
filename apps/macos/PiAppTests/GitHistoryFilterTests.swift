import AppKit
import Combine
import XCTest
@testable import GitView
@testable import PiApp

final class GitHistoryFilterTests: XCTestCase {
    @MainActor func testOldRefreshCannotReplaceTheNewFilterOrItsLoadingState() async throws {
        let fixture = try GitHistoryFixture(count: 3); defer { fixture.close() }
        try await fixture.start()
        let before = try fixture.repositoryBytes()
        var entered = false, release: CheckedContinuation<Void, Never>?
        fixture.state.didRead = { query in
            guard query.message == "Change 1" else { return }
            entered = true; await withCheckedContinuation { release = $0 }
        }
        let old = Task { await fixture.state.reload(in: fixture.historyRoot, query: GitHistoryQuery(message: "Change 1")) }
        try await fixture.wait { entered }
        let new = await fixture.state.reload(in: fixture.historyRoot, query: GitHistoryQuery(message: "Change 2"))
        XCTAssertTrue(new); XCTAssertEqual(fixture.state.reading.commits.map(\.subject), ["Change 2"])
        release?.resume(); let accepted = await old.value
        XCTAssertFalse(accepted); XCTAssertFalse(fixture.state.reading.loading)
        XCTAssertEqual(fixture.state.reading.commits.map(\.subject), ["Change 2"])
        XCTAssertEqual(try fixture.repositoryBytes(), before)
    }

    @MainActor func testArrowSelectionCrossesVirtualRowsAndReturnOpensDetails() async throws {
        let fixture = try GitHistoryFixture(count: 65); defer { fixture.close() }
        try await fixture.start(); _ = await fixture.state.loadMore()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 320, height: 250))
        defer { window.close() }
        browser.focusList()
        for _ in 0..<60 { browser.moveDown(nil) }
        browser.layoutSubtreeIfNeeded()
        let target = fixture.state.reading.commits[60]
        let row = try XCTUnwrap(browser.list.madeView(for: target.hash) as? GitHistoryRow)
        XCTAssertTrue(row.button.isAccessibilitySelected())
        XCTAssertTrue(window.firstResponder === row, "The selected accessible row owns keyboard focus")
        XCTAssertTrue(row.button.accessibilityLabel()?.contains("committed") == true)
        XCTAssertNil(fixture.controller.selectedCommit, "Arrow navigation previews the row; Return opens its detail")
        XCTAssertGreaterThan(browser.list.contentView.bounds.minY, 0)
        browser.insertNewline(nil)
        try await fixture.wait { fixture.controller.detail?.commit.hash == target.hash }
        XCTAssertEqual(fixture.controller.selectedCommit?.hash, target.hash)
        XCTAssertEqual(fixture.controller.detail?.files.map(\.path), ["notes.txt"])
        XCTAssertLessThan(GitHistoryFixture.views(GitHistoryRow.self, in: browser).count, 20, "Offscreen rows remain virtual")
    }

    @MainActor func testDownAtPageBoundaryLoadsAndSelectsTheNextCommit() async throws {
        let fixture = try GitHistoryFixture(count: 52); defer { fixture.close() }
        try await fixture.start()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 320, height: 300)); defer { window.close() }
        browser.focusList()
        for _ in 0..<49 { browser.moveDown(nil) }
        browser.moveDown(nil); browser.moveDown(nil)
        try await fixture.wait { fixture.state.reading.commits.count == 52 && !fixture.state.reading.paging }
        browser.layoutSubtreeIfNeeded()
        let next = fixture.state.reading.commits[50]
        try await fixture.wait { (browser.list.madeView(for: next.hash) as? GitHistoryRow)?.button.isAccessibilitySelected() == true }
        XCTAssertEqual(Set(fixture.state.reading.commits.map(\.hash)).count, 52)
        XCTAssertNil(fixture.state.reading.next)
    }

    @MainActor func testFinishingAPageDoesNotOverrideANewerKeyboardChoice() async throws {
        let fixture = try GitHistoryFixture(count: 52); defer { fixture.close() }
        try await fixture.start()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 320, height: 300)); defer { window.close() }
        browser.focusList(); for _ in 0..<49 { browser.moveDown(nil) }
        var release: CheckedContinuation<Void, Never>?
        fixture.state.didRead = { _ in await withCheckedContinuation { release = $0 } }
        browser.moveDown(nil)
        try await fixture.wait { release != nil }
        browser.moveUp(nil)
        let wanted = fixture.state.reading.commits[48], scroll = browser.list.contentView.bounds.origin
        release?.resume()
        try await fixture.wait { fixture.state.reading.commits.count == 52 && !fixture.state.reading.paging }
        browser.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(browser.list.madeView(for: wanted.hash) as? GitHistoryRow)
        XCTAssertTrue(row.button.isAccessibilitySelected())
        XCTAssertEqual(browser.list.contentView.bounds.origin, scroll)
    }

    @MainActor func testAnOldRepositoryRowCannotOpenInTheNewRepository() async throws {
        let fixture = try GitHistoryFixture(), other = try GitHistoryFixture(); defer { fixture.close(); other.close() }
        try await fixture.start()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 320, height: 300)); defer { window.close() }
        let hash = fixture.state.reading.commits[0].hash
        let old = try XCTUnwrap(browser.list.madeView(for: hash) as? GitHistoryRow), press = try XCTUnwrap(old.button.onPress)
        let resolvedRoot = await fixture.service.repositoryRoot(of: other.root.path)
        let otherRoot = try XCTUnwrap(resolvedRoot)
        fixture.controller.roots.append(other.root.path); fixture.controller.root = other.root.path
        try await fixture.wait { fixture.controller.repositoryRoot == otherRoot && !fixture.controller.loading }
        fixture.update(); browser.layoutSubtreeIfNeeded()
        XCTAssertTrue(GitHistoryFixture.views(GitHistoryRow.self, in: browser).isEmpty, "Rows must belong to the displayed repository")
        press()
        XCTAssertNil(fixture.controller.selectedCommit)
    }

    @MainActor func testFinishingAPageDoesNotTakeFocusFromAFilterField() async throws {
        let fixture = try GitHistoryFixture(count: 52); defer { fixture.close() }
        try await fixture.start()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 320, height: 300)); defer { window.close() }
        browser.focusList(); for _ in 0..<49 { browser.moveDown(nil) }
        var release: CheckedContinuation<Void, Never>?
        fixture.state.didRead = { _ in await withCheckedContinuation { release = $0 } }
        browser.moveDown(nil)
        try await fixture.wait { release != nil }
        window.makeFirstResponder(browser.message.field)
        let editor = try XCTUnwrap(browser.message.field.currentEditor())
        release?.resume()
        try await fixture.wait { fixture.state.reading.commits.count == 52 && !fixture.state.reading.paging }
        // Allow the navigation task awaiting that page to complete too.
        await Task.yield()
        XCTAssertTrue(window.firstResponder === editor)
    }

    @MainActor func testFilterChipsStayRemovableInANarrowPane() async throws {
        let fixture = try GitHistoryFixture(); defer { fixture.close() }
        try await fixture.start()
        fixture.controller.logFilter = GitLogFilter(text: "Change", author: "History Fixture", path: "notes.txt")
        fixture.options = GitHistoryOptions(reference: "refs/heads/" + String(repeating: "long-branch-", count: 14),
                                            dates: .init(from: "2026-10-01", through: "2026-10-31"))
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 260, height: 600)); defer { window.close() }
        fixture.update(); browser.layoutSubtreeIfNeeded()
        let chips = GitHistoryFixture.views(GitHistoryFilterChip.self, in: browser)
        XCTAssertEqual(chips.count, 6)
        for chip in chips {
            XCTAssertLessThanOrEqual(chip.frame.maxX, browser.bounds.width)
            XCTAssertLessThanOrEqual(chip.remove.frame.maxX, chip.bounds.width)
            XCTAssertTrue(chip.remove.accessibilityLabel()?.hasPrefix("Remove ") == true)
        }
        let ref = try XCTUnwrap(chips.first { $0.toolTip?.hasPrefix("refs/") == true })
        ref.remove.performClick(nil)
        XCTAssertNil(fixture.options.reference)
        XCTAssertEqual(fixture.controller.logFilter.path, "notes.txt")
        XCTAssertEqual(fixture.options.dates.from, "2026-10-01")
    }

    @MainActor func testDateEditorRejectsInvalidDaysAndEscapeCancels() throws {
        let editor = GitHistoryDateEditor(.init())
        var applied: GitHistoryDates?, closed = false
        editor.apply = { applied = $0 }; editor.close = { closed = true }
        editor.from.text = "2026-02-30"; editor.submit(); XCTAssertNil(applied)
        editor.from.text = "2026-10-14"; editor.through.text = "2026-10-13"; editor.submit(); XCTAssertNil(applied)
        editor.through.text = "2026-10-14"; editor.submit()
        XCTAssertEqual(applied, GitHistoryDates(from: "2026-10-14", through: "2026-10-14"))
        editor.cancelOperation(nil); XCTAssertTrue(closed)
        XCTAssertTrue(editor.from.field.accessibilityLabel()?.contains("UTC") == true)
    }

    @MainActor func testHashPopoverOpensOnlyTheRequestedCommitWithoutChangingFilters() async throws {
        let fixture = try GitHistoryFixture(count: 3); defer { fixture.close() }
        try await fixture.start()
        let target = fixture.state.reading.commits.last!
        fixture.controller.logFilter = GitLogFilter(text: "Change 2", author: "History Fixture", path: "notes.txt")
        _ = await fixture.state.reload(in: fixture.historyRoot, query: GitHistoryQuery(filter: fixture.controller.logFilter))
        let before = fixture.state.reading
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 500, height: 450)); defer { browser.popover.close(); window.close() }
        browser.showHash()
        let content = try XCTUnwrap(browser.popover.popover?.contentViewController?.view)
        let editor = try XCTUnwrap(GitHistoryFixture.views(GitHistoryHashEditor.self, in: content).first)
        editor.field.text = target.hash; editor.button.performClick(nil)
        try await fixture.wait { fixture.openedHash?.hash == target.hash }
        XCTAssertEqual(fixture.state.reading, before)
        XCTAssertEqual(fixture.controller.logFilter.text, "Change 2")
        XCTAssertEqual(fixture.openedHash?.hash, target.hash)
    }

    @MainActor func testEscapeDismissesTheRefAndDatePopovers() async throws {
        let fixture = try GitHistoryFixture(); defer { fixture.close() }
        try await fixture.start()
        let browser = fixture.browser, window = fixture.window(size: NSSize(width: 500, height: 450)); defer { window.close() }
        browser.showReferences(); XCTAssertTrue(browser.popover.isShown)
        browser.cancelOperation(nil); XCTAssertFalse(browser.popover.isShown)
        browser.showDates(); XCTAssertTrue(browser.popover.isShown)
        browser.cancelOperation(nil); XCTAssertFalse(browser.popover.isShown)
    }

    @MainActor func testRefSearchArrowAndReturnUseTheNativeFieldEditor() throws {
        let picker = GitHistoryRefPicker()
        picker.show([GitHistoryRef(name: "refs/heads/feature/target", object: String(repeating: "a", count: 40)),
                     GitHistoryRef(name: "refs/heads/main", object: String(repeating: "b", count: 40))])
        var chosen: GitHistoryQuery.Scope?
        picker.choose = { chosen = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = picker; defer { window.close() }
        picker.layoutSubtreeIfNeeded(); window.makeFirstResponder(picker.search.field)
        let editor = try XCTUnwrap(picker.search.field.currentEditor() as? NSTextView)
        editor.insertText("target", replacementRange: NSRange(location: NSNotFound, length: 0))
        for (code, chars) in [(UInt16(125), "\u{f701}"), (UInt16(36), "\r")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            editor.keyDown(with: event)
        }
        XCTAssertEqual(chosen, .reference("refs/heads/feature/target"))
    }

    @MainActor func testArrivingRefsPreserveTheScopeChosenWithTheKeyboard() {
        let picker = GitHistoryRefPicker()
        var chosen: GitHistoryQuery.Scope?
        picker.choose = { chosen = $0 }
        _ = picker.control(picker.search.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        picker.show([GitHistoryRef(name: "refs/heads/main", object: String(repeating: "a", count: 40))])
        _ = picker.control(picker.search.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(chosen, .all)
    }

    @MainActor func testPagingErrorAndRetryDoNotOverlapInANarrowPane() throws {
        for width: CGFloat in [260, 300] {
            let row = GitHistoryStatusRow()
            row.show(String(repeating: "This page could not be read. ", count: 8), more: true, action: {})
            row.frame = CGRect(x: 0, y: 0, width: width, height: 112); row.layoutSubtreeIfNeeded()
            let text = try XCTUnwrap(GitHistoryFixture.views(TextBlock.self, in: row).first)
            let button = try XCTUnwrap(GitHistoryFixture.views(PiKit.Button.self, in: row).first)
            XCTAssertLessThanOrEqual(text.frame.maxY + 6, button.frame.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, row.bounds.height)
        }
    }
}

/// The new view is callback-driven so stream 1 can wire its controller
/// without either stream moving or refactoring the other's owned files.
@MainActor final class GitHistoryFixture {
    let root: URL
    let service = GitService()
    let controller: GitController
    let state: GitHistoryState
    var historyRoot: String { controller.repositoryRoot ?? root.path }
    var options = GitHistoryOptions()
    var openedHash: GitCommit?
    private var observer: AnyCancellable?
    lazy var browser = GitHistoryBrowser(controller: controller, state: state, options: { [weak self] in self?.options ?? .init() },
        setOptions: { [weak self] in self?.options = $0; self?.update() },
        openExact: { [weak self] in self?.openedHash = $0; self?.controller.selectedCommit = $0 },
        loadMore: { [weak self] in _ = await self?.state.loadMore() })
    init(count: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("history-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        controller = GitController(roots: [root.path], service: service); state = GitHistoryState(service: service)
        try git(["init", "-qb", "main"])
        for (key, value) in [("user.name", "History Fixture"), ("user.email", "history@example.invalid"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
                             ("credential.helper", ""), ("core.fsmonitor", "false")] { try git(["config", key, value]) }
        for i in 0..<count {
            try ("Change \(i)\n").write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-qm", "Change \(i)"])
        }
        observer = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
    }
    @discardableResult func git(_ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args; process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_DATE": "2026-10-13T12:00:00Z", "GIT_COMMITTER_DATE": "2026-10-14T12:00:00Z"]) { _, new in new }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "HistoryFixtureGit", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func start() async throws {
        await controller.refresh()
        try await wait { controller.repositoryRoot != nil && !controller.loading }
        _ = try XCTUnwrap(controller.repositoryRoot, "Resolved identity=\(controller.repositoryIdentity?.root ?? "nil"), notice=\(controller.notice), loading=\(controller.loading)")
        _ = await state.reload(in: historyRoot, query: .init())
        guard !state.reading.commits.isEmpty else { throw NSError(domain: "HistoryFixtureRead", code: 1, userInfo: [NSLocalizedDescriptionKey: state.reading.notice]) }
        XCTAssertEqual(state.reading.snapshot?.root, controller.repositoryIdentity?.root, "History fixture and controller must name the same repository")
        update()
    }
    func update() { browser.apply(.init(controller, options: options)) }
    func window(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = browser
        browser.frame = CGRect(origin: .zero, size: size); browser.layoutSubtreeIfNeeded()
        return window
    }
    func repositoryBytes() throws -> [Data] {
        [try Data(contentsOf: root.appendingPathComponent(".git/index")), try Data(contentsOf: root.appendingPathComponent("notes.txt")),
         Data(try git(["rev-parse", "HEAD^{tree}"]).utf8), Data(try git(["show", ":notes.txt"]).utf8)]
    }
    func close() { observer?.cancel(); observer = nil; browser.popover.close(); controller.letGo(); state.cancel(); try? FileManager.default.removeItem(at: root) }
    func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < end else { throw NSError(domain: "HistoryFixtureWait", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "fixture=\(root.path), repository=\(controller.repositoryRoot ?? "nil"), snapshot=\(state.reading.snapshot?.root ?? "nil"), loading=\(controller.loading), notice=\(controller.notice), history=\(state.reading.notice)"]) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) } }
}
