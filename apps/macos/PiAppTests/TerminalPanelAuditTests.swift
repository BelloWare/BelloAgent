import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import PiApp

/// The terminal driven as a reader drives it: a real shell on a real pty in a
/// real window, streaming output, scrolled back, resized, pasted into, and
/// closed. Plus what it costs per megabyte and per frame.
final class TerminalPanelAuditTests: XCTestCase {

    // MARK: Fixtures

    @MainActor private func window(_ view: NSView, width: CGFloat = 800, height: CGFloat = 300) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }
    @MainActor private func eventually(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Never \(what)", file: file, line: line)
    }
    @MainActor private func scroll(_ view: TerminalView, lines: Int32, file: StaticString = #filePath, line: UInt = #line) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            .flatMap({ NSEvent(cgEvent: $0) }) else { return XCTFail("Could not make a scroll event", file: file, line: line) }
        view.scrollWheel(with: event)
    }
    @MainActor private func key(_ view: TerminalView, code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return XCTFail("Could not make a key event", file: file, line: line) }
        view.keyDown(with: event)
    }
    private func milliseconds(_ work: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
    private func workspace(_ id: String) -> WorkspaceRecord {
        WorkspaceRecord(id: id, path: NSTemporaryDirectory(), trusted: true)
    }

    // MARK: Reading while output arrives

    /// Scrolling back and then getting more output used to drag the text out
    /// from under the reader: the offset was measured from the bottom, which
    /// moves. What is on screen must stay on screen.
    @MainActor func testScrollingBackHoldsItsPlaceWhileOutputKeepsArriving() throws {
        let emulator = TerminalEmulator(columns: 40, rows: 8, scrollbackLimit: 10_000)
        let view = TerminalView(emulator: emulator)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        view.layoutSubtreeIfNeeded()
        for index in 0..<200 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        XCTAssertEqual(view.scrolledBackLines, 0)

        scroll(view, lines: 10)                       // ten notches back, three lines each
        let parked = view.scrolledBackLines
        XCTAssertGreaterThan(parked, 0, "the wheel scrolls back")
        let top = emulator.lineCount - emulator.rows - parked
        let textOnScreen = (0..<emulator.rows).map { TerminalEmulator.text(of: emulator.line(at: top + $0)) }
        XCTAssertTrue(textOnScreen.first?.hasPrefix("line ") == true, textOnScreen.joined(separator: "|"))

        for index in 200..<260 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        XCTAssertEqual(view.scrolledBackLines, parked + 60, "sixty new lines push the bottom sixty lines further away")
        let newTop = emulator.lineCount - emulator.rows - view.scrolledBackLines
        XCTAssertEqual((0..<emulator.rows).map { TerminalEmulator.text(of: emulator.line(at: newTop + $0)) }, textOnScreen,
                       "the reader is still looking at the same lines")

        // Typing anything returns to the bottom, as every terminal does.
        view.onInput = { _ in }
        view.pasteText("x")
        XCTAssertEqual(view.scrolledBackLines, 0)
    }

    /// The scrollback never grows past its limit, and scrolling to the very top
    /// while lines are dropped stays inside the history that is left.
    @MainActor func testScrollingBackPastTheTrimmedHistoryStaysInsideIt() throws {
        let emulator = TerminalEmulator(columns: 40, rows: 8, scrollbackLimit: 200)
        let view = TerminalView(emulator: emulator)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        view.layoutSubtreeIfNeeded()
        for index in 0..<300 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        scroll(view, lines: 400)
        XCTAssertEqual(view.scrolledBackLines, emulator.scrollback.count, "the top of the history is as far back as it goes")
        for index in 300..<900 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        XCTAssertLessThanOrEqual(view.scrolledBackLines, emulator.scrollback.count, "and it stays inside it as the oldest lines are dropped")
        view.scrollToBottom()
        XCTAssertEqual(view.scrolledBackLines, 0)
    }

    // MARK: The pty

    /// The reader keeps typing after the shell has exited. Nothing may be
    /// written to the descriptor the terminal used, which by then belongs to
    /// whatever file the app opened next.
    @MainActor func testTypingAfterTheShellExitsReachesNothingAtAll() async throws {
        let process = PseudoTerminal()
        var output = Data(), exited = false
        process.onData = { output.append($0) }
        process.onExit = { _ in exited = true }
        try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "printf READY; exit 0"],
                          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], directory: NSTemporaryDirectory(), columns: 60, rows: 12)
        try await eventually("hear from the child") { String(decoding: output, as: UTF8.self).contains("READY") }
        try await eventually("see the shell exit", timeout: 10) { exited }
        XCTAssertFalse(process.running)

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pty-recycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var descriptors: [Int32] = [], files: [URL] = []
        for index in 0..<12 {
            let url = folder.appendingPathComponent("slot\(index)")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            let descriptor = open(url.path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            descriptors.append(descriptor); files.append(url)
        }
        defer { for descriptor in descriptors { close(descriptor) } }

        process.write(Data("this must never reach a file\n".utf8))
        process.resize(columns: 100, rows: 40)
        process.terminate()
        try await Task.sleep(for: .milliseconds(300))
        for url in files {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            XCTAssertEqual(size, 0, "input after the shell exited was written into \(url.lastPathComponent)")
        }
        XCTAssertFalse(process.running)
    }

    /// A shell killed from outside, and a shell that exits on its own: both
    /// report their exit once, leave nothing unreaped, and stop the panel.
    @MainActor func testAShellKilledFromOutsideAndOneThatExitsBothReportOnce() async throws {
        for (label, arguments) in [("killed", ["sh", "-c", "printf READY; exec /bin/sleep 20"]), ("exited", ["sh", "-c", "printf READY; exit 7"])] {
            let process = PseudoTerminal()
            var output = Data(), exits: [Int32] = []
            process.onData = { output.append($0) }
            process.onExit = { exits.append($0) }
            try process.start(executable: "/bin/sh", arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                              directory: NSTemporaryDirectory(), columns: 60, rows: 12)
            try await eventually("hear from the \(label) shell") { String(decoding: output, as: UTF8.self).contains("READY") }
            if label == "killed" { kill(process.processID, SIGKILL) }
            try await eventually("see the \(label) shell end", timeout: 10) { !exits.isEmpty }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(exits.count, 1, "\(label): the exit is reported exactly once")
            XCTAssertFalse(process.running, "\(label): the terminal knows it is over")
            if label == "exited" { XCTAssertEqual(exits.first, 7) } else { XCTAssertEqual(exits.first, 128 + SIGKILL) }
            process.write(Data("ignored\n".utf8))
            process.terminate()
        }
    }

    /// The shell used to inherit every descriptor the app had open — the
    /// helper's stdin among them, so a helper stopped by closing its input
    /// never saw it end while a terminal was open, and anything left running
    /// from the terminal kept the helper alive past quit.
    @MainActor func testTheShellInheritsNothingButItsTerminal() async throws {
        let pipe = Pipe()
        let readEnd = pipe.fileHandleForReading.fileDescriptor, writeEnd = pipe.fileHandleForWriting.fileDescriptor
        let process = PseudoTerminal()
        var output = Data()
        process.onData = { output.append($0) }
        // The shell's own glob lists its own descriptors, and adds one: the directory it is reading.
        try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "for fd in /dev/fd/*; do echo \"${fd#/dev/fd/}\"; done; printf READY; exec /bin/sleep 5"],
                          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], directory: NSTemporaryDirectory(), columns: 60, rows: 40)
        defer { process.terminate() }
        try await eventually("hear the shell list its descriptors") { String(decoding: output, as: UTF8.self).contains("READY") }
        let listed = Set(String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
        XCTAssertFalse(listed.contains(writeEnd), "the shell holds the app's end of a pipe: \(listed.sorted())")
        XCTAssertEqual(listed, [0, 1, 2, 3], "only the terminal, and the directory being listed, are open in the shell")

        // So the app closing its end is the end of the pipe, while the shell still runs.
        try pipe.fileHandleForWriting.close()
        var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&poller, 1, 2_000), 1, "the reader sees the end at once")
        var byte: UInt8 = 0
        XCTAssertEqual(read(readEnd, &byte, 1), 0, "and it is an end, not data")
        XCTAssertTrue(process.running, "while the shell is still running")
    }

    /// One shell per project, and no shell left running for a project that is
    /// gone or for an app that is quitting.
    @MainActor func testTheRegistryEndsShellsForClosedProjectsAndOnShutdown() async throws {
        let registry = TerminalRegistry.shared
        registry.shutdown()
        let first = workspace("audit-one-" + UUID().uuidString), second = workspace("audit-two-" + UUID().uuidString)
        let one = registry.session(for: first), two = registry.session(for: second)
        XCTAssertTrue(one !== two, "each project gets its own shell")
        XCTAssertTrue(registry.session(for: first) === one, "and keeps it while the panel is hidden")
        XCTAssertEqual(registry.openWorkspaceIDs, [first.id, second.id])
        try await eventually("start both shells") { one.process.running && two.process.running }

        registry.close(workspaceID: first.id)
        try await eventually("end the closed project's shell", timeout: 10) { !one.process.running }
        XCTAssertEqual(registry.openWorkspaceIDs, [second.id])
        XCTAssertTrue(registry.session(for: first) !== one, "a project opened again starts a new shell")

        registry.shutdown()
        XCTAssertTrue(registry.openWorkspaceIDs.isEmpty)
        try await eventually("end every shell on the way out", timeout: 10) { !two.process.running }
    }

    /// `cat` on a binary file: thousands of BEL bytes must not ring thousands
    /// of times, each of them on the main thread.
    @MainActor func testABinaryFileFullOfBellsRingsOnceNotTenThousandTimes() async throws {
        let session = TerminalSession(workspaceID: "bell-" + UUID().uuidString, directory: NSTemporaryDirectory())
        defer { session.process.terminate() }
        var binary = Data()
        for index in 0..<60_000 { binary.append(index % 6 == 0 ? 0x07 : UInt8(0x41 + index % 26)) }
        let cost = milliseconds { session.emulator.feed(binary) }
        print(String(format: "PERF terminal fed %d bell bytes in %.0f ms, rang %d times", 10_000, cost, session.bellsRung))
        XCTAssertLessThanOrEqual(session.bellsRung, 3, "ten thousand bells are not ten thousand sounds")
        XCTAssertGreaterThanOrEqual(session.bellsRung, 1, "but the first one is heard")
        XCTAssertLessThan(cost, 200, "and the main thread is not spent ringing")
    }

    // MARK: A real shell in a real window

    /// The whole panel: a shell in a window, a long-output command, a resize
    /// while it streams, the alternate screen, and copying a selection.
    @MainActor func testARealShellStreamsResizesAndPaintsInAWindow() async throws {
        let emulator = TerminalEmulator(columns: 80, rows: 16, scrollbackLimit: 10_000)
        let view = TerminalView(emulator: emulator)
        let window = window(view, width: 760, height: 320)
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(view)
        XCTAssertTrue(window.firstResponder === view, "the terminal takes the keyboard when the panel opens")

        let process = PseudoTerminal()
        var frames = 0
        process.onData = { emulator.feed($0); view.refresh(); frames += 1 }
        view.onInput = { process.write($0) }
        view.onResize = { process.resize(columns: $0, rows: $1) }
        emulator.onOutput = { process.write($0) }
        try process.start(executable: "/bin/zsh", arguments: ["zsh", "-f"],
                          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "PROMPT": "pi %# ", "LANG": "en_US.UTF-8"],
                          directory: "/private/tmp", columns: emulator.columns, rows: emulator.rows)
        defer { process.terminate() }
        try await eventually("see a prompt") { emulator.screenText.contains("pi #") || emulator.screenText.contains("pi %") }

        // A hundred thousand lines, with a resize in the middle of the stream.
        process.write(Data("yes hello | head -100000; echo LONGDONE\n".utf8))
        try await Task.sleep(for: .milliseconds(120))
        view.setFrameSize(NSSize(width: 520, height: 260))
        view.layoutSubtreeIfNeeded()
        try await eventually("finish a hundred thousand lines", timeout: 60) { emulator.screenText.contains("LONGDONE") }
        XCTAssertGreaterThanOrEqual(emulator.scrollback.count, emulator.scrollbackLimit - emulator.scrollbackLimit / 32, "the history fills to its limit")
        XCTAssertLessThanOrEqual(emulator.scrollback.count, emulator.scrollbackLimit, "and never passes it")
        XCTAssertGreaterThan(emulator.trimmedLines, 50_000, "and the lines it dropped are still counted")
        XCTAssertTrue((0..<emulator.rows).contains { emulator.text(ofRow: $0).contains("LONGDONE") }, emulator.screenText)
        print("PERF terminal streamed 100000 lines in \(frames) main-thread chunks")
        XCTAssertLessThan(frames, 4_000, "a fast writer must not become one hop to the main thread per few dozen bytes")

        // The alternate screen: a full-screen program, then back to the shell.
        let history = emulator.scrollback.count + emulator.trimmedLines
        process.write(Data("printf '\\e[?1049h\\e[H\\e[2JFULL SCREEN\\e[10;1Hbottom'; sleep 1; printf '\\e[?1049l'; echo BACKAGAIN\n".utf8))
        try await eventually("enter the alternate screen", timeout: 20) { emulator.alternateScreen }
        let alternate = emulator.screenText
        XCTAssertTrue(alternate.contains("FULL SCREEN"), alternate)
        XCTAssertTrue(alternate.contains("bottom"), "the cursor moves inside the alternate screen: \(alternate)")
        XCTAssertFalse(alternate.contains("hello"), "the alternate screen is its own, not the shell's: \(alternate)")
        try await eventually("leave the alternate screen", timeout: 20) { !emulator.alternateScreen && emulator.screenText.contains("BACKAGAIN") }
        XCTAssertTrue(emulator.screenText.contains("hello"), "the shell's screen comes back: \(emulator.screenText)")
        XCTAssertLessThanOrEqual(emulator.scrollback.count + emulator.trimmedLines, history + 4, "and the alternate screen left nothing in the history")

        // Wide characters and emoji survive a round trip through the selection.
        process.write(Data("printf '中文 test 🌍 ok\\n'; echo WIDEDONE\n".utf8))
        try await eventually("print wide characters", timeout: 20) { emulator.screenText.contains("WIDEDONE") }
        view.selectAll(nil)
        let copied = try XCTUnwrap(view.selectedText)
        XCTAssertTrue(copied.components(separatedBy: "\n").contains("中文 test 🌍 ok"),
                      "a selection copies wide characters and emoji as one grapheme per cell")
        view.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), copied, "and Copy puts exactly that on the pasteboard")

        view.needsDisplay = true
        let draw = milliseconds { view.displayIfNeeded() }
        print(String(format: "PERF terminal full redraw of %d rows: %.1f ms", emulator.rows, draw))
    }

    /// Keys a full-screen program depends on, through the real view.
    @MainActor func testKeysReachTheProgramInEveryModeTheViewSupports() async throws {
        let emulator = TerminalEmulator(columns: 40, rows: 8)
        let view = TerminalView(emulator: emulator)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        let window = window(view, width: 420, height: 180)
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(view)
        var sent = Data()
        view.onInput = { sent.append($0) }
        func taken() -> String { defer { sent = Data() }; return String(decoding: sent, as: UTF8.self) }

        key(view, code: 126, characters: "")                               // up
        XCTAssertEqual(taken(), "\u{1b}[A")
        emulator.feed("\u{1b}[?1h")                                        // a full-screen program asks for application cursor keys
        key(view, code: 126, characters: "")
        XCTAssertEqual(taken(), "\u{1b}OA", "arrows change shape for a full-screen program")
        key(view, code: 125, characters: ""); XCTAssertEqual(taken(), "\u{1b}OB")
        key(view, code: 53, characters: "\u{1b}"); XCTAssertEqual(taken(), "\u{1b}", "Escape")
        key(view, code: 48, characters: "\t"); XCTAssertEqual(taken(), "\t", "Tab completes")
        key(view, code: 48, characters: "\t", modifiers: .shift); XCTAssertEqual(taken(), "\u{1b}[Z")
        key(view, code: 8, characters: "c", modifiers: .control); XCTAssertEqual(taken(), "\u{03}", "Control-C interrupts")
        key(view, code: 37, characters: "l", modifiers: .control); XCTAssertEqual(taken(), "\u{0c}")
        key(view, code: 27, characters: "-", modifiers: .control); XCTAssertEqual(taken(), "\u{1f}")
        key(view, code: 11, characters: "b", modifiers: .option); XCTAssertEqual(taken(), "\u{1b}b", "Option sends Meta")
        key(view, code: 51, characters: "\u{7f}"); XCTAssertEqual(taken(), "\u{7f}", "Backspace")
        key(view, code: 36, characters: "\r"); XCTAssertEqual(taken(), "\r", "Return")

        // A command key is left to the responder chain, not swallowed as input:
        // ⌘V either pastes or does nothing, and never types a letter v.
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("FROM THE PASTEBOARD", forType: .string)
        key(view, code: 9, characters: "v", modifiers: .command)
        let afterCommandV = taken()
        XCTAssertTrue(afterCommandV.isEmpty || afterCommandV == "FROM THE PASTEBOARD", "⌘V typed \(afterCommandV) into the shell")

        // Input methods: marked text shows at the cursor and commits once.
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(taken(), "", "text still being composed is not sent")
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(taken(), "日本", "the input method commits once")

        // Bracketed paste, and a paste that is not bracketed.
        view.pasteText("one\r\ntwo\n")
        XCTAssertEqual(taken(), "one\rtwo\r")
        emulator.feed("\u{1b}[?2004h")
        view.pasteText("one\ntwo")
        XCTAssertEqual(taken(), "\u{1b}[200~one\rtwo\u{1b}[201~")
    }

    /// The panel in a window, switched from one project to another: the new
    /// project's shell has the keyboard, not nothing at all.
    @MainActor func testSwitchingProjectsMovesTheTerminalAndTheKeyboardWithIt() async throws {
        TerminalRegistry.shared.shutdown()
        let first = workspace("panel-one-" + UUID().uuidString), second = workspace("panel-two-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panel-" + UUID().uuidString),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let holder = WorkspaceHolder(workspace: first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalPanelProbe(model: model, holder: holder))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close(); TerminalRegistry.shared.shutdown() }

        let one = TerminalRegistry.shared.session(for: first)
        try await eventually("give the first project's shell the keyboard") { window.firstResponder === one.view }
        XCTAssertTrue(one.view.window === window, "the terminal is in the window")

        holder.workspace = second
        let two = TerminalRegistry.shared.session(for: second)
        XCTAssertTrue(one !== two)
        try await eventually("move the panel to the other project") { two.view.window === window }
        try await eventually("hand the keyboard to the other project's shell") { window.firstResponder === two.view }
        try await eventually("take the first project's terminal out of the panel") { one.view.superview == nil }
        XCTAssertNil(one.view.window, "and the first project's terminal has left the window")
        XCTAssertEqual(two.view.superview?.subviews.count, 1, "one terminal in the panel, not one per project ever shown")
        XCTAssertEqual(TerminalRegistry.shared.openWorkspaceIDs, [first.id, second.id], "both shells are still there")
    }

    // MARK: Cost

    /// What the emulator costs per megabyte of output and what the scrollback
    /// of several terminals costs in memory. Printed for the release record.
    func testEmulatorThroughputAndScrollbackFootprint() {
        let terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 10_000)
        var stream = ""
        for index in 0..<20_000 { stream += "\u{1b}[32mrow \(index)\u{1b}[0m " + String(repeating: "abcdefgh ", count: 10) + "\r\n" }
        let bytes = Double(stream.utf8.count)
        let data = Data(stream.utf8)
        let cost = milliseconds { terminal.feed(data) }
        print(String(format: "PERF terminal emulator: %.1f ms for %.2f MB (%.1f ms per MB)", cost, bytes / 1_048_576, cost / (bytes / 1_048_576)))
        XCTAssertGreaterThan(terminal.scrollback.count, 9_600)
        XCTAssertLessThanOrEqual(terminal.scrollback.count, 10_000)

        let cell = MemoryLayout<TerminalCell>.stride
        var cells = 0, textBytes = 0, runs = 0, exactLines = 0
        for line in terminal.scrollback {
            cells += line.cellCount; textBytes += line.text.utf8.count; runs += line.styles.count
            if line.exact != nil { exactLines += 1 }
        }
        let asCells = Double(cells * cell) / 1_048_576
        let stored = Double(textBytes + runs * MemoryLayout<TerminalHistoryLine.StyleRun>.stride
                            + terminal.scrollback.count * MemoryLayout<TerminalHistoryLine>.stride) / 1_048_576
        print(String(format: "PERF terminal scrollback: %d cells — %.1f MB as cells, %.1f MB as text plus style runs (%.1f× smaller), %.1f MB for four terminals",
                     cells, asCells, stored, asCells / max(stored, 0.001), stored * 4))
        XCTAssertEqual(exactLines, 0, "ordinary output needs no per-cell text")
        XCTAssertLessThanOrEqual(cells, TerminalEmulator.scrollbackCellLimit, "the history is capped in cells as well as in lines")
        XCTAssertLessThan(stored * 4, asCells, "the history costs a fraction of one cell per column")

        // A very wide window would otherwise hold ten thousand very long lines.
        let wide = TerminalEmulator(columns: 2_000, rows: 10, scrollbackLimit: 10_000)
        let long = String(repeating: "w", count: 1_999) + "\r\n"
        for _ in 0..<4_000 { wide.feed(long) }
        var wideCells = 0
        for line in wide.scrollback { wideCells += line.cellCount }
        print(String(format: "PERF terminal scrollback of a 2000-column window: %d lines, %d cells (%.1f MB as cells)", wide.scrollback.count, wideCells, Double(wideCells * cell) / 1_048_576))
        XCTAssertLessThanOrEqual(wideCells, TerminalEmulator.scrollbackCellLimit, "the widest window still has a memory ceiling")
        XCTAssertGreaterThan(wide.scrollback.count, 500, "and still keeps a usable history")
        XCTAssertEqual(wide.scrollback.count + wide.trimmedLines, 4_000 - 9, "every line that left the screen is kept or counted")
    }

    /// Reading the history back: selection, copy and drawing all go through
    /// cells the emulator builds on demand now.
    @MainActor func testScrolledBackHistoryStillSelectsCopiesAndDraws() throws {
        let emulator = TerminalEmulator(columns: 40, rows: 4, scrollbackLimit: 10_000)
        let view = TerminalView(emulator: emulator)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 140)
        view.layoutSubtreeIfNeeded()
        for index in 0..<300 { emulator.feed("\u{1b}[3\(index % 8)mline \(index) 中文 🌍\u{1b}[0m\r\n") }
        view.refresh()
        scroll(view, lines: 60)
        XCTAssertGreaterThan(view.scrolledBackLines, 0)

        view.selectAll(nil)
        let copied = try XCTUnwrap(view.selectedText).components(separatedBy: "\n")
        XCTAssertEqual(copied.first, "line 0 中文 🌍", "the oldest line reads back whole")
        XCTAssertEqual(copied.count, 300, "every line of history is there")
        XCTAssertTrue(copied.contains("line 299 中文 🌍"))

        let cells = emulator.line(at: 5)
        XCTAssertEqual(cells.first?.style.foreground, .indexed(5), "and keeps the colour it was printed in")
        XCTAssertTrue(cells.contains { $0.width == 2 }, "and its wide characters")

        let draw = milliseconds {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        print(String(format: "PERF terminal frame drawn entirely from history: %.2f ms", draw))
        XCTAssertLessThan(draw, 40, "building the visible history's cells is not a frame's worth of work")
    }

    /// What four projects' terminals, each with ten thousand lines of history,
    /// actually cost the process.
    func testFourTerminalsOfHistoryCostTheProcessLittle() {
        func footprint() -> Double {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
            }
            return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
        }
        var terminals: [TerminalEmulator] = []
        let line = "\u{1b}[36m" + String(repeating: "output ", count: 14) + "\u{1b}[0m\r\n"
        _ = footprint()
        let before = footprint()
        for _ in 0..<4 {
            let terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 10_000)
            for _ in 0..<10_400 { terminal.feed(line) }
            XCTAssertGreaterThan(terminal.scrollback.count, 9_600)
            terminals.append(terminal)
        }
        let after = footprint()
        print(String(format: "PERF four terminals with ten thousand lines of history each: process grew %.1f MB (%.1f MB each)", after - before, (after - before) / 4))
        XCTAssertEqual(terminals.count, 4)
        XCTAssertLessThan(after - before, 60, "four histories must not be a hundred megabytes")
    }

    /// What one frame costs while output streams, in the real view.
    @MainActor func testDrawCostPerFrameWhileStreaming() {
        let emulator = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 10_000)
        let view = TerminalView(emulator: emulator)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 680)
        view.layoutSubtreeIfNeeded()
        let chunk = Data((0..<200).map { "\u{1b}[3\($0 % 8)mrow \($0) " + String(repeating: "content ", count: 12) + "\u{1b}[0m\r\n" }.joined().utf8)
        var total = 0.0
        var frames = 0
        for _ in 0..<20 {
            emulator.feed(chunk)
            view.refresh()
            total += milliseconds {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            frames += 1
        }
        print(String(format: "PERF terminal draw: %.1f ms per frame of %d rows while streaming", total / Double(frames), emulator.rows))
        XCTAssertLessThan(total / Double(frames), 40, "a streaming frame must stay well inside a refresh")
    }
}

/// Swaps the project under a TerminalPanel the way the workspace view does.
@MainActor private final class WorkspaceHolder: ObservableObject {
    @Published var workspace: WorkspaceRecord
    init(workspace: WorkspaceRecord) { self.workspace = workspace }
}
private struct TerminalPanelProbe: View {
    let model: WorkspaceModel
    @ObservedObject var holder: WorkspaceHolder
    var body: some View { TerminalPanel(model: model, workspace: holder.workspace) }
}
