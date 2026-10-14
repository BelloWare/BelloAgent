import XCTest
import AppKit
@testable import PiApp
@testable import GitView

final class GitOperationSafetyTests: GitPanelTestCase {
    @MainActor func testTheDefaultStagedScopeCanCheckConflictsWithoutStagedContent() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.conflict()
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        try await eventually("read conflicts") { controller.isShown && controller.statusRead && !controller.loading }
        XCTAssertEqual(controller.commitScope, .stagedChanges)
        XCTAssertTrue(controller.staged.isEmpty)
        panel.refresh()
        let before = try fixture.snapshot()
        let check = try XCTUnwrap(Self.views(PlainTextButton.self, in: panel).first { $0.accessibilityIdentifier() == "git-preflight-check" })
        check.onPress?()
        try await eventually("check the conflicted index") { controller.preflight != nil || !controller.notice.isEmpty }
        XCTAssertEqual(controller.preflight?.conflicts, 1)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertEqual(controller.commitScope, .stagedChanges)
    }

    @MainActor func testAmendAsksAboutTheReviewedTargetAndCancelKeepsEverything() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "working\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read status") { controller.statusRead && !controller.loading }
        controller.amend = true; controller.commitMessage = "Amended message"
        let questions = PiQuestion()
        var asked: NSView?, answer: ((Bool) -> Void)?
        questions.presentSheet = { sheet, _, complete in asked = sheet; answer = complete }
        let panel = GitPanelView(controller: controller, questions: questions), window = host(panel)
        defer { window.close() }
        try await eventually("show panel") { controller.isShown && !controller.loading }
        panel.refresh()
        let before = try fixture.snapshot()
        try XCTUnwrap(Self.views(PiKit.Button.self, in: panel).first { $0.accessibilityIdentifier() == "git-commit" }).onPress?()
        try await eventually("ask before amending") { asked != nil || controller.lastCommit != nil }
        XCTAssertNotNil(asked, "Amend must ask before rewriting history")
        XCTAssertEqual(try fixture.snapshot(), before)
        if let asked {
            let target = Self.views(PiKit.TextLine.self, in: asked).first { $0.accessibilityIdentifier() == "git-question-target" }
            XCTAssertTrue(target?.toolTip?.contains(controller.status.head ?? "missing head") == true)
            XCTAssertTrue(target?.line.text.contains("main") == true)
            XCTAssertTrue(Self.views(ShellText.self, in: asked).contains { $0.text.contains("working-tree") })
            let buttons = Self.views(PiKit.Button.self, in: asked)
            XCTAssertEqual(buttons.first { $0.title == "Amend" }?.keyEquivalent, "")
            XCTAssertEqual(buttons.first { $0.title == "Cancel" }?.keyEquivalent, "\r")
        }
        answer?(false)
        XCTAssertEqual(controller.commitMessage, "Amended message")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor func testDiscardNeverHasADestructiveReturnDefault() {
        let entry = GitStatusEntry(path: "file.txt", originalPath: nil, indexState: ".", worktreeState: "M", untracked: false)
        let alert = GitDiscard.alert(for: [entry])
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\r")
        XCTAssertTrue(Self.views(NSButton.self, in: alert.window.contentView!).contains { $0.keyEquivalent == "\u{1b}" })
    }

    @MainActor func testStaleRepositoryAnswersNeverMutateEitherRepository() async throws {
        for reword in [false, true] {
            let first = try GitSafetyRepository(), second = try GitSafetyRepository()
            defer { first.remove(); second.remove() }
            try first.seed(); try second.seed(); try first.write("file.txt", "first work\n"); try second.write("file.txt", "second work\n")
            let firstTop = try first.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
            let secondTop = try second.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
            let controller = GitController(roots: [first.root.path, second.root.path]); defer { controller.letGo() }
            controller.commitScope = .checkedFiles
            try await eventually("read first") { controller.statusRead && !controller.loading }
            controller.amend = true; controller.commitMessage = "First repository message"
            let questions = PiQuestion(), place = GitPanelPlace()
            var answer: ((Bool) -> Void)?
            questions.presentSheet = { _, _, complete in answer = complete }
            let panel = GitPanelView(controller: controller, place: place, questions: questions), window = host(panel)
            defer { window.close() }
            try await eventually("show first") { controller.isShown && !controller.loading }
            place.requestCommit(controller, context: controller.repositoryContext, reword: reword, questions: questions)
            try await eventually("ask") { answer != nil }
            let beforeFirst = try first.snapshot(), beforeSecond = try second.snapshot()
            controller.root = second.root.path
            try await eventually("read second") { controller.repositoryRoot == secondTop && !controller.loading }
            answer?(true)
            try await eventually("retire stale answer") { place.operation?.pending != true && !controller.busy }
            XCTAssertEqual(try first.snapshot(), beforeFirst); XCTAssertEqual(try second.snapshot(), beforeSecond)
            // Also exercise the controller's repository guard independently
            // of the panel cancelling its question on a repository switch.
            controller.root = first.root.path
            try await eventually("return to first") { controller.repositoryRoot == firstTop && !controller.loading }
            controller.amend = true; controller.commitMessage = "Same choices"
            let request = try XCTUnwrap(controller.commitRequest(context: controller.repositoryContext, reword: reword))
            controller.root = second.root.path
            try await eventually("return to second") { controller.repositoryRoot == secondTop && !controller.loading }
            controller.amend = true; controller.commitMessage = "Same choices"
            await controller.submitCommit(request)
            XCTAssertTrue(controller.notice.contains("changed"), controller.notice)
            XCTAssertEqual(try first.snapshot(), beforeFirst); XCTAssertEqual(try second.snapshot(), beforeSecond)
        }
    }

    @MainActor func testChangedTargetAndChangedScopeInvalidatePreparedRequests() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "work\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read status") { controller.statusRead && !controller.loading }
        controller.amend = true; controller.commitMessage = "Keep this draft"
        let request = try XCTUnwrap(controller.commitRequest(context: controller.repositoryContext))
        try fixture.git(["commit", "--allow-empty", "-qm", "External commit"])
        let before = try fixture.snapshot()
        await controller.submitCommit(request)
        XCTAssertEqual(try fixture.snapshot(), before); XCTAssertEqual(controller.commitMessage, "Keep this draft")
        let refreshed = try XCTUnwrap(controller.commitRequest(context: controller.repositoryContext))
        controller.commitScope = .stagedChanges
        await controller.submitCommit(refreshed)
        XCTAssertEqual(try fixture.snapshot(), before); XCTAssertEqual(controller.commitMessage, "Keep this draft")
    }

    @MainActor func testWhitespaceRequiresReviewAndSignOffFailureKeepsTheDraft() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "work with spaces  \n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read status") { controller.statusRead && !controller.loading }
        controller.commitMessage = "Keep me"; controller.signOff = true
        let request = try XCTUnwrap(controller.commitRequest(context: controller.repositoryContext))
        let before = try fixture.snapshot()
        await controller.submitCommit(request)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(controller.preflight?.hasWarnings == true)
        XCTAssertEqual(controller.commitMessage, "Keep me"); XCTAssertTrue(controller.signOff)
        let hook = fixture.root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho fixture-hook-refused >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        await controller.submitCommit(request, allowingWhitespace: true)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(controller.notice.contains("fixture-hook-refused"), controller.notice)
        XCTAssertEqual(controller.commitMessage, "Keep me"); XCTAssertTrue(controller.signOff)
    }

    @MainActor func testSignOffSurvivesHidingButResetsWhenThePanelCloses() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed()
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        controller.setShown(true)
        try await eventually("read sign-off repository") { controller.statusRead && !controller.loading }
        controller.signOff = true
        controller.commitScope = .checkedFiles
        controller.setShown(false)
        XCTAssertTrue(controller.signOff, "Changing tabs retains the active commit choices")
        controller.setShown(true)
        try await eventually("show the same commit draft") { !controller.loading }
        XCTAssertTrue(controller.signOff)

        controller.setShown(false)
        controller.letGo()
        XCTAssertFalse(controller.signOff, "Closing the panel drops its commit choices")
        XCTAssertEqual(controller.commitScope, GitController.defaultCommitScope)
        controller.opened(); controller.setShown(true)
        try await eventually("reopen the commit panel") { controller.statusRead && !controller.loading }
        XCTAssertFalse(controller.signOff, "A fresh panel starts without opting into a trailer")
    }

    @MainActor func testAConfirmedRewordRunsOnceAndPreservesTreeIndexAndWorkingBytes() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "staged\n"); try fixture.git(["add", "file.txt"]); try fixture.write("file.txt", "working\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read status") { controller.statusRead && !controller.loading }
        controller.commitMessage = "Reworded explicitly"
        let questions = PiQuestion(), place = GitPanelPlace()
        var answer: ((Bool) -> Void)?, sheet: NSView?
        questions.presentSheet = { shown, _, complete in sheet = shown; answer = complete }
        let panel = GitPanelView(controller: controller, place: place, questions: questions), window = host(panel)
        defer { window.close() }
        try await eventually("show") { controller.isShown && !controller.loading }
        let before = try fixture.snapshot(), tree = try fixture.git(["rev-parse", "HEAD^{tree}"])
        place.requestCommit(controller, context: controller.repositoryContext, reword: true, questions: questions)
        try await eventually("ask reword") { answer != nil }
        XCTAssertTrue(Self.views(ShellText.self, in: try XCTUnwrap(sheet)).contains { $0.text.contains("Message only") })
        answer?(true); answer?(true)
        try await eventually("finish reword") { controller.lastCommit != nil && !controller.busy }
        let after = try fixture.snapshot()
        XCTAssertNotEqual(after[0], before[0]); XCTAssertEqual(Array(after.dropFirst()), Array(before.dropFirst()))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD^{tree}"]), tree)
        XCTAssertEqual(try fixture.git(["reflog", "--format=%gs"]).components(separatedBy: "Reworded explicitly").count, 2)
    }

    @MainActor func testHidingThePanelCancelsItsOutstandingAnswer() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "work\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read") { controller.statusRead && !controller.loading }
        controller.amend = true; controller.commitMessage = "Keep me"
        let questions = PiQuestion(), place = GitPanelPlace()
        var answer: ((Bool) -> Void)?
        questions.presentSheet = { _, _, complete in answer = complete }
        let panel = GitPanelView(controller: controller, place: place, questions: questions), window = host(panel)
        defer { window.close() }
        try await eventually("show") { controller.isShown && !controller.loading }
        let before = try fixture.snapshot()
        place.requestCommit(controller, context: controller.repositoryContext, reword: false, questions: questions)
        try await eventually("ask") { answer != nil }
        let operation = try XCTUnwrap(place.operation)
        panel.isHidden = true
        try await eventually("hide") { !controller.isShown }
        answer?(true)
        // Join any task a late answer queued before checking the repository.
        // An immediate assertion could miss an erroneously dispatched write.
        await operation.task?.value
        XCTAssertEqual(try fixture.snapshot(), before); XCTAssertEqual(controller.commitMessage, "Keep me")
        XCTAssertFalse(controller.busy)
    }

    @MainActor func testEscapeAndReturnCancelTheActualRewriteSheet() async throws {
        for (characters, code) in [("\u{1b}", UInt16(53)), ("\r", UInt16(36))] {
            let fixture = try GitSafetyRepository(); defer { fixture.remove() }
            try fixture.seed(); try fixture.write("file.txt", "working\n")
            let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
            controller.commitScope = .checkedFiles
            try await eventually("read") { controller.statusRead && !controller.loading }
            controller.amend = true; controller.commitMessage = "Keep me"
            let place = GitPanelPlace(), questions = PiQuestion()
            let panel = GitPanelView(controller: controller, place: place, questions: questions), window = host(panel)
            defer { window.close() }
            try await eventually("show") { controller.isShown && !controller.loading }
            let before = try fixture.snapshot()
            place.requestCommit(controller, context: controller.repositoryContext, reword: false, questions: questions)
            try await eventually("attach sheet") { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertEqual(sheet.defaultButtonCell?.title, "Cancel")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            if code == 53 { XCTAssertTrue(sheet.performKeyEquivalent(with: event), "Escape must reach Cancel") }
            else {
                let action = try XCTUnwrap(Self.views(PiKit.Button.self, in: sheet.contentView!).first { $0.title == "Amend" })
                XCTAssertTrue(sheet.makeFirstResponder(action))
                XCTAssertTrue(sheet.performKeyEquivalent(with: event), "Return cancels even with the rewrite action focused")
            }
            try await eventually("cancel sheet") { !questions.asking && place.operation?.pending != true && !controller.busy }
            XCTAssertEqual(try fixture.snapshot(), before); XCTAssertEqual(controller.commitMessage, "Keep me")
        }
    }

    @MainActor func testHistoricalOpenWorkingFileDoesNotReuseTheHistoricalLine() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "today\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read") { controller.statusRead && !controller.loading && !controller.commits.isEmpty }
        var opened: [(String, Int)] = []
        let panel = GitPanelView(controller: controller, openFile: { opened.append(($0, $1)) }), window = host(panel)
        defer { window.close() }
        controller.panel = .history; controller.selectedCommit = controller.commits.first
        try await eventually("read historical diff") { controller.detail != nil && !controller.commitLoading }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(Self.views(PlainTextButton.self, in: panel).first { $0.accessibilityIdentifier() == "git-open-working-file" })
        XCTAssertFalse(button.isHidden); XCTAssertEqual(button.line.text, "Open Working File")
        button.onPress?()
        XCTAssertEqual(opened.map(\.0), ["file.txt"]); XCTAssertEqual(opened.map(\.1), [1])
        let table = try XCTUnwrap(Self.views(GitDiffTable.self, in: panel).first)
        table.layoutSubtreeIfNeeded()
        let menu = table.coordinator.menu?(GitDiffMenuRequest(hasSelection: false, filePath: "file.txt",
            fileLine: GitDiffFileLine(path: "file.txt", line: 37), copy: {}, selectAll: {}))
        XCTAssertFalse(menu?.items.contains { $0.identifier?.rawValue == "git-diff-open-file" } == true,
                       "Historical lines must not offer a jump into today's file")
    }

    @MainActor func testEditingTheDraftCancelsAnInFlightPreflightRead() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "work\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.commitScope = .checkedFiles
        try await eventually("read") { controller.statusRead && !controller.loading }
        controller.commitMessage = "Before"; controller.checked = ["file.txt"]
        try fixture.write(".gitattributes", "file.txt filter=hold\n")
        let entered = fixture.root.appendingPathComponent(".git/entered"), release = fixture.root.appendingPathComponent(".git/release")
        let script = "#!/bin/sh\ntouch .git/entered\nn=0\nwhile [ ! -f .git/release ] && [ $n -lt 100 ]; do sleep 0.05; n=$((n+1)); done\ncat\n"
        try Data(script.utf8).write(to: fixture.root.appendingPathComponent(".git/hooks/hold"))
        try fixture.git(["config", "filter.hold.clean", "sh .git/hooks/hold"])
        let request = try XCTUnwrap(controller.commitRequest(context: controller.repositoryContext))
        let reading = Task { await controller.checkCommit(request) }
        try await eventually("enter the fixture filter") { FileManager.default.fileExists(atPath: entered.path) }
        controller.commitMessage = "After"
        try Data().write(to: release)
        let result = await reading.value
        XCTAssertNil(result); XCTAssertNil(controller.preflight); XCTAssertFalse(controller.preflightLoading)
        XCTAssertEqual(controller.commitMessage, "After")
        XCTAssertEqual(try fixture.git(["show", "HEAD:file.txt"]), "base\n")
        XCTAssertEqual(try fixture.git(["show", ":file.txt"]), "base\n")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8), "work\n")
    }

    @MainActor static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
}

/// Shared with this stream's standalone gallery. No app model, gateway or vault.
final class GitSafetyRepository {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("git-operation-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"])
        for (key, value) in [("user.name", "Safety Fixture"), ("user.email", "safety@example.invalid"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("credential.helper", ""),
                             ("core.hooksPath", root.appendingPathComponent(".git/hooks").path),
                             ("core.fsmonitor", "false"), ("protocol.allow", "never")] { try git(["config", key, value]) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: [String], status: Int32 = 0) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args; process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, status, "git \(args)")
        return String(decoding: bytes, as: UTF8.self)
    }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    func seed() throws { try write("file.txt", "base\n"); try git(["add", "."]); try git(["commit", "-qm", "Base"]) }
    func conflict() throws {
        try seed(); try git(["checkout", "-qb", "side"]); try write("file.txt", "side\n"); try git(["commit", "-qam", "Side"])
        try git(["checkout", "-q", "main"]); try write("file.txt", "main\n"); try git(["commit", "-qam", "Main"])
        try git(["merge", "side"], status: 1)
    }
    func snapshot() throws -> [String] {
        [try git(["rev-parse", "HEAD"]), try git(["ls-files", "-s"]), try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8)]
    }
}
