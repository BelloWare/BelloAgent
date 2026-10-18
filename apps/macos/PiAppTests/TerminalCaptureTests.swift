import XCTest
import AppKit
@testable import PiApp

/// Opt-in visual evidence for the terminal: a real shell in the app's own
/// terminal view, captured in both appearances next to the gallery captures.
final class TerminalCaptureTests: XCTestCase {
    @MainActor func testRestoredShellAfterAlternateResizeGallery() async throws {
        guard let root = testEnvironment("PI_ROUND2_GITFILES_GALLERY") else { throw XCTSkip("Set PI_ROUND2_GITFILES_GALLERY to capture") }
        let folder = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [760, 360] {
                let terminal = TerminalEmulator()
                // Only generated VT bytes; no shell or user files.
                let terminalView = TerminalView(emulator: terminal)
                let height = terminal.cellPixelSize.height
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Double(width), height: 16 + 4 * height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
                window.contentView = terminalView; window.makeKeyAndOrderFront(nil)
                defer { window.contentView = nil; window.close() }
                terminalView.layoutSubtreeIfNeeded()
                XCTAssertEqual(terminal.rows, 4)
                terminal.feed("one\r\ntwo\r\nthree\r\n\u{1b}[32mfour")
                terminal.feed("\u{1b}[?1049h\u{1b}[H\u{1b}[31mALT\u{1b}7")
                window.setContentSize(NSSize(width: Double(width), height: 16 + 2 * height))
                terminalView.layoutSubtreeIfNeeded()
                terminal.feed("\u{1b}[?1049l!")
                terminalView.refresh()
                XCTAssertEqual(terminal.screenText, "three\nfour!")
                XCTAssertEqual(terminal.scrollback.map(\.text), ["one", "two"])
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try XCTUnwrap(terminalView.bitmapImageRepForCachingDisplay(in: terminalView.bounds))
                terminalView.cacheDisplay(in: terminalView.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("terminal-restored-\(name)-\(width).png"))
                window.setContentSize(NSSize(width: Double(width), height: 16 + 4 * height))
                terminalView.layoutSubtreeIfNeeded()
                terminal.feed("\u{1b}[?1049h\u{1b}[H\u{1b}[0m\u{1b}[?25lALT\r\nNEXT")
                terminalView.refresh(); terminalView.selectAll(nil)
                window.setContentSize(NSSize(width: Double(width), height: 16 + 2 * height))
                terminalView.layoutSubtreeIfNeeded(); terminalView.refresh()
                XCTAssertEqual(terminalView.selectedText, "ALT\nNEXT")
                let selected = try XCTUnwrap(terminalView.bitmapImageRepForCachingDisplay(in: terminalView.bounds))
                terminalView.cacheDisplay(in: terminalView.bounds, to: selected)
                try XCTUnwrap(selected.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("terminal-selected-\(name)-\(width).png"))
            }
        }
    }

    @MainActor func testCaptureTerminalInBothAppearances() async throws {
        guard let root = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else { throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT to capture the terminal") }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let terminal = TerminalEmulator(columns: 80, rows: 16)
        let view = TerminalView(emulator: terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { window.contentView = nil; window.close() }
        let process = PseudoTerminal()
        process.onData = { terminal.feed($0); view.refresh() }
        view.onInput = { process.write($0) }
        view.onResize = { process.resize(columns: $0, rows: $1) }
        terminal.onOutput = { process.write($0) }
        try process.start(executable: "/bin/zsh", arguments: ["zsh", "-f"], environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "PROMPT": "bello %~ %# ", "LANG": "en_US.UTF-8"],
                          directory: "/private/tmp", columns: terminal.columns, rows: terminal.rows)
        process.write(Data("printf '\\e[1;31mbold red\\e[0m \\e[38;5;208morange\\e[0m \\e[4munderlined\\e[0m \\e[7minverse\\e[0m \\e[3mitalic\\e[0m 中文 🌍\\n'; printf '\\e[32m✓ tests passed\\e[0m  \\e[33m⚠ 2 warnings\\e[0m  \\e[34mhttps://belloware.com\\e[0m\\n'; ls -la /usr | head -4; echo done\n".utf8))
        for _ in 0..<200 where !terminal.screenText.contains("done") { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(terminal.screenText.contains("done"), terminal.screenText)
        XCTAssertTrue(terminal.screenText.contains("bold red"), terminal.screenText)
        for (name, appearance) in [("12-terminal-light", NSAppearance.Name.aqua), ("12-terminal-dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            view.needsDisplay = true; view.displayIfNeeded()
            let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        }
        process.write(Data("exit\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
    }
}
