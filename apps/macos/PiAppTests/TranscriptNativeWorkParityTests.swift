import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// The native work rows and their cards read exactly as the SwiftUI rows they
/// replace: each fixture is drawn through `ActionRowView` (as the work list
/// hosted it) and through `TranscriptNativeActionRow`, at several widths and
/// in both appearances, and the two must be as tall and draw the same pixels.
///
/// Set `PI_PARITY_OUT` (and `TEST_RUNNER_PI_PARITY_OUT`) to a folder to keep
/// both captures and a difference image for every pair.
final class TranscriptNativeWorkParityTests: XCTestCase {
    struct Fixture {
        let name: String
        let tool: ToolView
        var open = false
        /// Whether the row's file opens here.
        var opensFiles = true
        var rightToLeft = false
    }

    static func tool(_ id: String, _ name: String, state: String = "completed", input: String, output: String = "",
                     duration: Double? = 940, path: String? = nil, added: Int? = nil, removed: Int? = nil, truncated: Bool = false) -> ToolView {
        ToolView(id: id, name: name, state: state, input: input, output: output, durationMs: duration, truncated: truncated,
                 path: path, added: added, removed: removed)
    }
    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static var closedFixtures: [Fixture] {
        let path = "apps/macos/PiApp/Transcript/TranscriptRows.swift"
        return [
            Fixture(name: "read", tool: tool("r1", "read", input: json(["path": path]), output: "ok", path: path)),
            Fixture(name: "read-nolink", tool: tool("r2", "read", input: json(["path": path]), output: "ok", path: path), opensFiles: false),
            Fixture(name: "bash-running", tool: tool("b1", "bash", state: "running", input: json(["command": "npm test -- --watch=false"]), duration: nil)),
            Fixture(name: "bash-failed", tool: tool("b2", "bash", state: "failed", input: json(["command": "make"]),
                                                    output: "make: *** No rule to make target 'all'.  Stop.\nsecond line")),
            Fixture(name: "bash-stopped", tool: tool("b3", "bash", state: "cancelled", input: json(["command": "sleep 30"]), duration: 20)),
            Fixture(name: "edit-unknown", tool: tool("e1", "edit", state: "unknown", input: json(["path": "notes.md", "oldText": "a", "newText": "b"]),
                                                    path: "notes.md", added: 1, removed: 1)),
            Fixture(name: "edit-suffix", tool: tool("e2", "edit", input: json(["path": "Sources/App/Retry.swift", "oldText": "a\nb", "newText": "c\nd\ne"]),
                                                   duration: 12_400, path: "Sources/App/Retry.swift", added: 130, removed: 12)),
            Fixture(name: "read-long", tool: tool("r3", "read", input: json(["path": String(repeating: "deep/directory/", count: 12) + "file.swift"]),
                                                  output: "ok", path: String(repeating: "deep/directory/", count: 12) + "file.swift")),
            Fixture(name: "grep", tool: tool("g1", "grep", input: json(["pattern": "TranscriptWorkRow"]), output: "3 matches", duration: 30)),
            Fixture(name: "mcp", tool: tool("m1", "mcp", input: json(["action": "invoke", "server": "linear", "tool": "list_issues"]), output: "[]")),
        ]
    }

    @MainActor func testClosedWorkRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.closedFixtures, widths: [792, 520, 380])
    }

    static var cardFixtures: [Fixture] {
        let lines = (1...40).map { "line \($0) of the file, with some words after it" }.joined(separator: "\n")
        let long = (1...30).map { "output line \($0) of a command that printed a lot" }.joined(separator: "\n")
        let diffRows = (1...30).map { "let value\($0) = compute(\($0))" }
        return [
            Fixture(name: "card-read", tool: tool("r1", "read", input: json(["path": "Sources/App.swift", "offset": 40, "limit": 3]),
                                                  output: "alpha\nbeta\n\ngamma is a longer line\n[Truncated. 400 total lines; read another range.]", path: "Sources/App.swift"), open: true),
            Fixture(name: "card-read-capped", tool: tool("r2", "read", input: json(["path": "Sources/Long.swift"]), output: lines, path: "Sources/Long.swift"), open: true),
            Fixture(name: "card-terminal", tool: tool("b1", "bash", input: json(["command": "swift build --configuration release"]),
                                                      output: "Compiling App\nBuild complete!"), open: true),
            Fixture(name: "card-terminal-long", tool: tool("b2", "bash", state: "failed", input: json(["command": String(repeating: "echo words; ", count: 20)]),
                                                           output: long), open: true),
            Fixture(name: "card-terminal-empty", tool: tool("b3", "bash", state: "running", input: json(["command": "sleep 5"]), duration: nil), open: true),
            Fixture(name: "card-diff", tool: tool("e1", "edit", input: json(["path": "notes.md", "oldText": "first\nsecond", "newText": "first\nchanged second\nthird"]),
                                                  path: "notes.md", added: 2, removed: 1), open: true),
            Fixture(name: "card-diff-capped", tool: tool("e2", "edit", state: "failed",
                                                         input: json(["path": "Sources/Values.swift", "oldText": diffRows.joined(separator: "\n"),
                                                                      "newText": diffRows.map { $0 + " // checked" }.joined(separator: "\n")]),
                                                         output: "Could not apply", path: "Sources/Values.swift"), open: true),
            Fixture(name: "card-write", tool: tool("w1", "write", input: json(["path": "README.md", "content": "# Title\n\nSome words."]),
                                                   path: "README.md", added: 3), open: true),
            Fixture(name: "card-io", tool: tool("g1", "grep", input: json(["pattern": "TranscriptWorkRow", "path": "apps"]),
                                                output: "apps/macos/PiApp/Transcript/TranscriptRowChrome.swift:136: struct TranscriptWorkRow", duration: 30), open: true),
            Fixture(name: "card-io-long", tool: tool("g2", "find", state: "failed", input: json(["pattern": "*.swift"]), output: long, truncated: true), open: true),
            Fixture(name: "card-io-path", tool: tool("w2", "write", input: json(["path": "Empty.md"]), path: "Empty.md"), open: true),
            Fixture(name: "card-io-input", tool: tool("m1", "mcp", state: "running", input: json(["action": "invoke", "server": "linear", "tool": "list_issues", "arguments": ["team": "APP"]]), duration: nil), open: true),
        ]
    }

    @MainActor func testOpenWorkRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.cardFixtures, widths: [792, 520, 380])
    }

    /// A right-to-left reader's rows: everything on the other side.
    @MainActor func testRightToLeftWorkRowsMatchTheirSwiftUIRows() throws {
        var fixtures = [Self.closedFixtures[0], Self.closedFixtures[3], Self.closedFixtures[6]]
            + Self.cardFixtures.filter { ["card-read", "card-terminal", "card-diff", "card-io", "card-io-path"].contains($0.name) }
        for index in fixtures.indices { fixtures[index].rightToLeft = true; fixtures[index] = Fixture(name: fixtures[index].name + "-rtl", tool: fixtures[index].tool, open: fixtures[index].open, rightToLeft: true) }
        try compare(fixtures, widths: [520, 380])
    }

    /// Cards in the states only the reader reaches: a diff or a read
    /// expanded, a diff too large to draw, a request the host cut short.
    @MainActor func testCardStatesMatchTheirSwiftUICards() throws {
        let rows = (1...30).map { DiffRow(kind: $0 % 3 == 0 ? .removed : $0 % 3 == 1 ? .added : .context, text: "let value\($0) = compute(\($0))") }
        func request(_ rows: [DiffRow], mode: String = "edit", hidden: Int = 0, complete: Bool = true, tooLarge: Bool = false) -> TranscriptActivity.EditRequest {
            TranscriptActivity.EditRequest(before: "old line one\nold line two", after: "new line one\nnew line two\nnew line three", mode: mode, rows: rows,
                                           hiddenRows: hidden, complete: complete, tooLarge: tooLarge, lines: tooLarge ? 9_000 : rows.count)
        }
        let lines = (1...40).map { "line \($0) of the file" }.joined(separator: "\n")
        let cards: [(String, ActionRowView.Card, Bool)] = [
            ("diff-expanded", .diff(request(rows), path: "Sources/Values.swift", outcome: .done, added: 20, removed: 10), true),
            ("diff-expanded-short", .diff(request(Array(rows.prefix(14))), path: nil, outcome: .running, added: nil, removed: nil), true),
            ("diff-partial", .diff(request(Array(rows.prefix(5)), mode: "write", hidden: 120, complete: false), path: "Notes.md", outcome: .cancelled, added: nil, removed: nil), false),
            ("diff-too-large", .diff(request([], tooLarge: true), path: "Big.json", outcome: .done, added: 9_000, removed: 0), false),
            ("read-expanded", .read(text: lines, firstLine: 100, path: "Sources/File.swift", failed: false), true),
            ("read-failed", .read(text: "only line", firstLine: 1, path: nil, failed: true), false),
        ]
        var failures: [String] = []
        let out = testEnvironment("PI_PARITY_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        for (name, card, expanded) in cards {
            for width in [792, 520, 380] as [CGFloat] {
                for dark in [false, true] {
                    var environment = TranscriptRowEnvironment(); environment.colorScheme = dark ? .dark : .light
                    let label = "\(name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let hosted = render(width: width, dark: dark) {
                        let view: AnyView
                        switch card {
                        case let .diff(request, path, outcome, added, removed):
                            view = AnyView(TranscriptDiffCard(request: request, path: path, outcome: outcome, added: added, removed: removed, open: {}, expanded: expanded))
                        case let .read(text, firstLine, path, failed):
                            view = AnyView(TranscriptReadCard(text: text, firstLine: firstLine, path: path, failed: failed, open: {}, expanded: expanded))
                        default: view = AnyView(EmptyView())
                        }
                        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .environment(\.colorScheme, environment.colorScheme).focusEffectDisabled().piStableLayout())
                        host.safeAreaRegions = []; host.sizingOptions = [.intrinsicContentSize]
                        return (host, { max(1, ceil(host.fittingSize.height)) })
                    }
                    let native = render(width: width, dark: dark) {
                        let view = TranscriptNativeCard.make(card)
                        view.update(card, link: {}, environment: environment)
                        if expanded { (view as? TranscriptNativeDiffCard)?.setExpanded(true); (view as? TranscriptNativeReadCard)?.setExpanded(true) }
                        return (view, { max(1, ceil(view.height(width: width))) })
                    }
                    if hosted.height != native.height { failures.append("\(label): height \(native.height) native, \(hosted.height) SwiftUI") }
                    let (differing, total, diff) = TranscriptNativeRowParityTests.difference(hosted.image, native.image)
                    let share = total == 0 ? 0 : Double(differing) / Double(total)
                    if share > TranscriptNativeRowParityTests.pixelTolerance { failures.append(String(format: "%@: %.2f%% of pixels differ (%d)", label, share * 100, differing)) }
                    if let out {
                        try TranscriptNativeRowParityTests.png(hosted.image)?.write(to: out.appendingPathComponent(label + "-swiftui.png"))
                        try TranscriptNativeRowParityTests.png(native.image)?.write(to: out.appendingPathComponent(label + "-native.png"))
                        if let diff { try TranscriptNativeRowParityTests.png(diff)?.write(to: out.appendingPathComponent(label + "-diff.png")) }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Opt-in: what SwiftUI's disclosure in a too-large diff exposes.
    @MainActor func testProbeDisclosure() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        let request = TranscriptActivity.EditRequest(before: "old", after: "new", mode: "edit", rows: [], hiddenRows: 0, complete: true, tooLarge: true, lines: 9_000)
        let host = NSHostingView(rootView: TranscriptDiffCard(request: request, path: "Big.json", added: 1, removed: 0).frame(width: 520))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func walk(_ element: Any, _ depth: Int) {
            guard depth < 14, let object = element as? NSAccessibilityProtocol else { return }
            FileHandle.standardError.write(Data("PROBE AX \(String(repeating: " ", count: depth))\(object.accessibilityRole()?.rawValue ?? "?") [\(object.accessibilityLabel() ?? "")] \(type(of: element))\n".utf8))
            for child in object.accessibilityChildren() ?? [] { walk(child, depth + 1) }
        }
        walk(host, 0)
        func views(_ view: NSView, _ depth: Int) {
            FileHandle.standardError.write(Data("PROBE VIEW \(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame)\n".utf8))
            for child in view.subviews { views(child, depth + 1) }
        }
        views(host, 0)
        window.contentView = nil
    }

    /// Prints SwiftUI's frame for every symbol a work row draws.
    @MainActor func testProbeWorkSymbols() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        for name in ["terminal", "pencil", "doc.text", "folder", "magnifyingglass", "point.3.connected.trianglepath.dotted", "circle"] {
            SizeProbe.size = .zero
            TranscriptTextCalibrationTests.measureInWindow(SizeProbe { Image(systemName: name).font(.system(size: 12, weight: .medium)) })
            FileHandle.standardError.write(Data("PROBE symbol \(name)/12 medium: \(SizeProbe.size)\n".utf8))
        }
        SizeProbe.size = .zero
        TranscriptTextCalibrationTests.measureInWindow(SizeProbe { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) })
        FileHandle.standardError.write(Data("PROBE symbol chevron.down/11 semibold: \(SizeProbe.size)\n".utf8))
    }

    /// Opt-in (`PI_TEXT_CALIBRATION=1`): where each work symbol lands on
    /// SwiftUI's pixels, swept in the row itself, for `TranscriptSymbol.swiftUIOffsets`.
    @MainActor func testSweepWorkSymbolOffsets() throws {
        try XCTSkipUnless(testEnvironment("PI_TEXT_CALIBRATION") == "1", "calibration sweep")
        defer { TranscriptSymbol.offsetOverride = nil }
        let medium = NSFont.Weight.medium.rawValue
        let cases: [(String, Fixture)] = [
            ("terminal/12.0/\(medium)", Fixture(name: "", tool: Self.tool("1", "bash", input: Self.json(["command": "ls"])))),
            ("pencil/12.0/\(medium)", Fixture(name: "", tool: Self.tool("2", "edit", input: Self.json(["path": "a.md"]), path: "a.md"))),
            ("doc.text/12.0/\(medium)", Fixture(name: "", tool: Self.tool("3", "read", input: Self.json(["path": "a.md"]), output: "ok", path: "a.md"))),
            ("folder/12.0/\(medium)", Fixture(name: "", tool: Self.tool("4", "ls", input: Self.json(["path": "apps"]), path: "apps"))),
            ("magnifyingglass/12.0/\(medium)", Fixture(name: "", tool: Self.tool("5", "grep", input: Self.json(["pattern": "x"])))),
            ("point.3.connected.trianglepath.dotted/12.0/\(medium)", Fixture(name: "", tool: Self.tool("6", "mcp", input: Self.json(["action": "list"])))),
            ("circle/12.0/\(medium)", Fixture(name: "", tool: Self.tool("7", "custom", input: "{}"))),
            ("chevron.down/11.0/\(NSFont.Weight.semibold.rawValue)", Fixture(name: "", tool: Self.tool("8", "grep", input: Self.json(["pattern": "x"]), output: "y"), open: true)),
        ]
        for (key, fixture) in cases {
            var line: [String] = []
            var sums: [String: (CGPoint, Int)] = [:]
            for dark in [false, true] {
                TranscriptSymbol.offsetOverride = nil
                let swift = render(fixture, width: 240, dark: dark, native: false).image
                var results: [(CGPoint, Int)] = []
                for dx in -6...6 { for dy in -8...4 {
                    let offset = CGPoint(x: CGFloat(dx) * 0.125, y: CGFloat(dy) * 0.125)
                    TranscriptSymbol.offsetOverride = offset
                    results.append((offset, TranscriptNativeRowParityTests.difference(swift, render(fixture, width: 240, dark: dark, native: true).image).0))
                } }
                for (offset, count) in results { sums["\(offset)", default: (offset, 0)].1 += count }
                let best = results.min { $0.1 < $1.1 }!
                let zero = results.first { $0.0 == .zero }!.1
                line.append("\(dark ? "dark" : "light") best \(best.0) (\(best.1)) zero \(zero) table \(results.first { $0.0 == (TranscriptSymbol.swiftUIOffsets[key] ?? .zero) }!.1)")
            }
            let both = sums.values.min { $0.1 < $1.1 }!
            line.append("both best \(both.0) (\(both.1))")
            FileHandle.standardError.write(Data("CALIBRATE work symbol \(key): \(line.joined(separator: "; "))\n".utf8))
        }
    }

    // MARK: Drawing a row both ways

    @MainActor func compare(_ fixtures: [Fixture], widths: [CGFloat]) throws {
        let out = testEnvironment("PI_PARITY_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var failures: [String] = []
        for fixture in fixtures {
            for width in widths {
                for dark in [false, true] {
                    let label = "\(fixture.name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let hosted = render(fixture, width: width, dark: dark, native: false)
                    let native = render(fixture, width: width, dark: dark, native: true)
                    if hosted.height != native.height {
                        failures.append("\(label): height \(native.height) native, \(hosted.height) SwiftUI")
                    }
                    let (differing, total, diff) = TranscriptNativeRowParityTests.difference(hosted.image, native.image)
                    let share = total == 0 ? 0 : Double(differing) / Double(total)
                    if share > TranscriptNativeRowParityTests.pixelTolerance { failures.append(String(format: "%@: %.2f%% of pixels differ (%d)", label, share * 100, differing)) }
                    if let out {
                        try TranscriptNativeRowParityTests.png(hosted.image)?.write(to: out.appendingPathComponent(label + "-swiftui.png"))
                        try TranscriptNativeRowParityTests.png(native.image)?.write(to: out.appendingPathComponent(label + "-native.png"))
                        if let diff { try TranscriptNativeRowParityTests.png(diff)?.write(to: out.appendingPathComponent(label + "-diff.png")) }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    struct Rendered { let height: CGFloat; let image: NSBitmapImageRep }

    @MainActor func render(_ fixture: Fixture, width: CGFloat, dark: Bool, native: Bool) -> Rendered {
        var environment = TranscriptRowEnvironment()
        environment.colorScheme = dark ? .dark : .light
        environment.opensFiles = fixture.opensFiles
        environment.layoutDirection = fixture.rightToLeft ? .rightToLeft : .leftToRight
        let openFile: (String, ClosedRange<Int>?) -> Void = { _, _ in }
        return render(width: width, dark: dark) {
            if native {
                let row = TranscriptNativeActionRow()
                row.update(tool: fixture.tool, open: fixture.open, fetched: nil, environment: environment, toggle: {}, openFile: openFile)
                return (row, { max(1, ceil(row.height(width: width))) })
            }
            let host = NSHostingView(rootView: ActionRowView(tool: fixture.tool, open: fixture.open, fetched: nil, toggle: {}, openFile: openFile)
                .equatable()
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.transcriptOpensFiles, environment.opensFiles)
                .environment(\.layoutDirection, environment.layoutDirection)
                .focusEffectDisabled()
                .piStableLayout())
            host.safeAreaRegions = []
            host.sizingOptions = [.intrinsicContentSize]
            return (host, { max(1, ceil(host.fittingSize.height)) })
        }
    }

    /// Puts the view `make` builds in a window `width` wide, measures it there
    /// with the closure it returns, and captures it at that height.
    @MainActor func render(width: CGFloat, dark: Bool, _ make: () -> (NSView, () -> CGFloat)) -> Rendered {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = canvas
        let (view, measure) = make()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        canvas.addSubview(view)
        let height = measure()
        window.setContentSize(CGSize(width: width, height: height))
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.layoutSubtreeIfNeeded()
        canvas.display()
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        view.removeFromSuperview()
        window.contentView = nil
        return Rendered(height: height, image: rep)
    }
}
