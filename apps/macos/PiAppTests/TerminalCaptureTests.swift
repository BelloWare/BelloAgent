import XCTest
import AppKit
@testable import PiApp

/// Opt-in visual evidence for the terminal: a real shell in the app's own
/// terminal view, captured in both appearances next to the gallery captures.
final class TerminalCaptureTests: XCTestCase {
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
