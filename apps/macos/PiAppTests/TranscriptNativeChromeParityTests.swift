import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The transcript's chrome outside its rows, drawn by AppKit and by the
/// SwiftUI views it replaced (PiAppTests/SwiftUIReference/), as the window
/// server shows each: a reply's markdown controls, the quote bar, the
/// full-table window. Same size, and no more than 0.4% of the pixels apart
/// (the antialiasing of a symbol drawn by AppKit rather than SwiftUI).
///
/// Serial: the windows are on screen and the hover cases move the pointer.
@MainActor final class TranscriptNativeChromeParityTests: XCTestCase, SerialTestLane {
    static let share = TranscriptNativeRowParityTests.pixelTolerance
    static let channelTolerance = 24
    private var results: [String] = []

    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("PARITY " + result) }
    }

    /// Draws `view` at its fitting size `margin` points in from the top left
    /// of a borderless window `size` big, as the window server shows it;
    /// `hover` puts the pointer on its middle first.
    /// Where `view`'s symbols are drawn, in pixels of its capture from the
    /// top left: AppKit rasterizes a symbol's edges differently from SwiftUI
    /// however it is placed (`testSymbolsDrawAsSwiftUI`), so they are
    /// compared on their own, as the rows mask their spinners.
    static var symbolRects: [ObjectIdentifier: [CGRect]] = [:]
    static func symbols(in view: NSView, windowHeight: CGFloat, scale: CGFloat) -> [CGRect] {
        var rects: [CGRect] = []
        func walk(_ view: NSView) {
            if view is TranscriptSymbol || view is PiKit.SymbolView, !view.isHidden {
                let r = view.convert(view.bounds, to: nil).insetBy(dx: -1, dy: -1)
                rects.append(CGRect(x: floor(r.minX * scale), y: floor((windowHeight - r.maxY) * scale), width: ceil(r.width * scale), height: ceil(r.height * scale)))
            }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return rects
    }
    /// Pixels apart past the tolerance outside `masks`, and inside them.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, masks: [CGRect]) -> (outside: Int, inside: Int, total: Int) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return (a.pixelsWide * a.pixelsHigh, 0, a.pixelsWide * a.pixelsHigh) }
        var outside = 0, inside = 0
        var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
        for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
            a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
            var worst = 0
            for channel in 0..<min(a.samplesPerPixel, 4) { worst = max(worst, abs(p[channel] - q[channel])) }
            guard worst > channelTolerance else { continue }
            if masks.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { inside += 1 } else { outside += 1 }
        } }
        return (outside, inside, a.pixelsWide * a.pixelsHigh)
    }
    /// The image's pixels outside `rects`, to compare one capture with the next.
    static func masked(_ image: NSBitmapImageRep, _ rects: [CGRect]) -> Data {
        var bytes = [UInt8]()
        var p = [Int](repeating: 0, count: 4)
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { continue }
            image.getPixel(&p, atX: x, y: y); bytes.append(UInt8(p[0])); bytes.append(UInt8(p[1])); bytes.append(UInt8(p[2]))
        } }
        return Data(bytes)
    }
    /// The most a symbol's own pixels may differ, each: what AppKit's
    /// rasterizing of the same symbol in the same place leaves, as
    /// `testSymbolsDrawAsSwiftUI` allows it.
    static let symbolPixels = 400
    static func capture(_ view: NSView, size: CGSize, appearance: NSAppearance.Name, hover: Bool, canvas: NSColor,
                        fit given: CGSize? = nil, moving: (@MainActor (NSView, CGFloat) -> [CGRect])? = nil) async throws -> NSBitmapImageRep {
        let margin: CGFloat = 12, fit = given ?? view.fittingSize
        let screen = NSScreen.screens.first?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.maxY - 40 - size.height, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = canvas; window.hasShadow = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        view.frame = NSRect(x: margin, y: size.height - margin - fit.height, width: fit.width, height: fit.height)
        content.addSubview(view)
        window.orderFrontRegardless()
        defer { view.removeFromSuperview(); window.orderOut(nil); window.contentView = nil }
        func settle(_ what: String) async throws -> NSBitmapImageRep {
            var previous: Data?, image: NSBitmapImageRep?
            try await eventually("the window server showing \(what)", timeout: .seconds(10), poll: .milliseconds(60)) {
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                guard let now = try? PiKitParity.windowImage(window), var data = now.representation(using: .png, properties: [:]) else { return false }
                // What moves on its own is left out of "at rest".
                if let moving { data = Self.masked(now, moving(view, size.height)) }
                defer { previous = data }
                if data == previous { image = now; return true }
                return false
            }
            return try XCTUnwrap(image)
        }
        let rest = try await settle("\(type(of: view)) at rest")
        symbolRects[ObjectIdentifier(view)] = symbols(in: view, windowHeight: size.height, scale: window.backingScaleFactor)
        if testEnvironment("PI_PROBE") == "1" {
            func dump(_ v: NSView, _ depth: Int) {
                FileHandle.standardError.write(Data("PROBE \(String(repeating: " ", count: depth))\(type(of: v)) \(v.convert(v.bounds, to: nil))\n".utf8))
                for c in v.subviews { dump(c, depth + 1) }
            }
            dump(view, 0)
        }
        guard hover else { return rest }
        let centre = window.convertPoint(toScreen: NSPoint(x: view.frame.midX, y: view.frame.midY))
        let top = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: centre.x, y: top - centre.y)
        defer {
            let away = CGPoint(x: 1, y: 1)
            CGWarpMouseCursorPosition(away)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: away, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        // The pointer comes onto it, from off it, until the hover shows (a
        // busy run can lose the first move); a control that never shows one
        // is the test's to report.
        let restData = rest.representation(using: .png, properties: [:])
        for _ in 0..<3 {
            NSApp.activate(ignoringOtherApps: true)
            let away = CGPoint(x: 1, y: 1)
            CGWarpMouseCursorPosition(away)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: away, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
            let nudged = CGPoint(x: point.x + 1, y: point.y)
            CGWarpMouseCursorPosition(nudged)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left)?.post(tap: .cghidEventTap)
            var shows = false
            try? await eventually("the hover showing", timeout: .seconds(3), poll: .milliseconds(30)) {
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                shows = (try? PiKitParity.windowImage(window))?.representation(using: .png, properties: [:]) != restData
                return shows
            }
            if shows { break }
        }
        return try await settle("\(type(of: view)) under the pointer")
    }

    /// Compares the SwiftUI view in a hosting view at its fitting size, as
    /// the transcript placed it, with its AppKit replacement at its own.
    /// `idealSize`: the SwiftUI view is drawn at its ideal size rounded up,
    /// rather than at the hosting view's fitting size (see the quote bar).
    private func check<V: View>(_ name: String, hover: ((NSView) -> Void)? = nil, canvas: NSColor = .piContent, idealSize: Bool = false,
                                _ swiftUI: (_ dark: Bool) -> V, _ appKit: (_ dark: Bool) -> NSView,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let dark = appearance == .darkAqua, label = "\(name)-\(suffix)"
            func host() -> NSView {
                let host = NSHostingView(rootView: swiftUI(dark).environment(\.piReduceMotion, true))
                host.sizingOptions = [.intrinsicContentSize]; host.safeAreaRegions = []
                return host
            }
            let hosted = host(), native = appKit(dark)
            var fit = hosted.fittingSize
            if idealSize {
                SizeProbe.size = .zero
                TranscriptTextCalibrationTests.measureInWindow(SizeProbe { swiftUI(dark).environment(\.piReduceMotion, true) })
                let ideal = SizeProbe.size
                fit = CGSize(width: ceil(ideal.width), height: ceil(ideal.height))
            }
            // The surface places each control by its fitting size, as it
            // placed the hosting view it replaces.
            XCTAssertEqual(native.fittingSize, fit, "\(label): fitting size", file: file, line: line)
            let size = CGSize(width: ceil(max(fit.width, native.fittingSize.width)) + 24, height: ceil(max(fit.height, native.fittingSize.height)) + 24)
            // SwiftUI's hover comes from the pointer; the AppKit view's
            // tracking areas report it only while the app is active, which a
            // test runner may not be, so it is told directly (its tracking
            // is checked in TranscriptNativeChromeBehaviourTests).
            let swiftUIImage = try await Self.capture(hosted, size: size, appearance: appearance, hover: hover != nil, canvas: canvas, fit: fit)
            hover?(native)
            let appKitImage = try await Self.capture(native, size: size, appearance: appearance, hover: false, canvas: canvas)
            if let folder = testEnvironment("PI_PARITY_OUT") {
                try TranscriptNativeRowParityTests.png(swiftUIImage)?.write(to: URL(fileURLWithPath: folder + "/\(label)-swiftui.png"))
                try TranscriptNativeRowParityTests.png(appKitImage)?.write(to: URL(fileURLWithPath: folder + "/\(label)-native.png"))
            }
            let masks = Self.symbolRects[ObjectIdentifier(native)] ?? []
            let (differing, inside, total) = Self.difference(swiftUIImage, appKitImage, masks: masks)
            results.append("\(label): \(differing)/\(total) px differ, \(inside) in \(masks.count) symbols; fit \(fit) / \(native.fittingSize)")
            XCTAssertLessThanOrEqual(Double(differing), Double(total) * Self.share, "\(label): \(differing)/\(total) px differ", file: file, line: line)
            XCTAssertLessThanOrEqual(inside, Self.symbolPixels * max(1, masks.count), "\(label): \(inside) px of its symbols differ", file: file, line: line)
            if hover != nil {
                let swiftUIRest = try await Self.capture(host(), size: size, appearance: appearance, hover: false, canvas: canvas, fit: fit)
                let appKitRest = try await Self.capture(appKit(dark), size: size, appearance: appearance, hover: false, canvas: canvas)
                XCTAssertGreaterThan(PiKitParity.difference(swiftUIRest, swiftUIImage, tolerance: 0).0, 0, "\(label): SwiftUI shows no hover", file: file, line: line)
                XCTAssertGreaterThan(PiKitParity.difference(appKitRest, appKitImage, tolerance: 0).0, 0, "\(label): AppKit shows no hover", file: file, line: line)
            }
        }
    }

    // MARK: A reply's markdown controls

    /// A row's values in the appearance drawn: the surface hands its
    /// controls the row's colour scheme.
    static func environment(_ dark: Bool) -> TranscriptRowEnvironment {
        var environment = TranscriptRowEnvironment(); environment.colorScheme = dark ? .dark : .light
        return environment
    }

    func testCodeToolbarsMatchSwiftUI() async throws {
        for language in ["swift", "typescript", nil] as [String?] {
            for rightToLeft in [false, true] {
                func environment(_ dark: Bool) -> TranscriptRowEnvironment {
                    var environment = TranscriptRowEnvironment()
                    environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
                    environment.colorScheme = dark ? .dark : .light
                    return environment
                }
                try await check("toolbar-\(language ?? "none")\(rightToLeft ? "-rtl" : "")", canvas: TranscriptNSPalette.codeBackground, { dark in
                    MarkdownCodeToolbar(language: language, code: "let x = 1", environment: environment(dark))
                        .environment(\.layoutDirection, environment(dark).swiftUILayoutDirection)
                }) { dark in
                    let view = MarkdownCodeToolbarView()
                    view.update(language: language, code: "let x = 1", environment: environment(dark))
                    return view
                }
            }
        }
    }

    func testHeadingCopiesMatchSwiftUI() async throws {
        let target = MarkdownCopyTarget(kind: .section(level: 2), label: "Copy section", text: "## Retry budget\n\nThree tries.")
        for hover in [false, true] {
            try await check("heading-copy\(hover ? "-hover" : "")", hover: hover ? { ($0 as? MarkdownHeadingActionView)?.copy.setHovering(true) } : nil, { dark in
                MarkdownHeadingAction(target: target, environment: Self.environment(dark))
            }) { dark in
                let view = MarkdownHeadingActionView()
                view.update(target: target, environment: Self.environment(dark))
                return view
            }
        }
    }

    /// Opt-in (`PI_TEXT_CALIBRATION=1`): where the chrome's symbols land
    /// closest to SwiftUI's, nudged in eighths of a point (the Copy
    /// button's, the quote bar's).
    func testSweepChromeSymbolOffsets() async throws {
        try XCTSkipUnless(testEnvironment("PI_TEXT_CALIBRATION") == "1", "calibration sweep")
        defer { TranscriptSymbol.offsetOverride = nil }
        let target = MarkdownCopyTarget(kind: .code, label: "Copy code", text: "x")
        func sweep<V: View>(_ name: String, _ swiftUI: V, size: CGSize, fit: CGSize?, _ appKit: () -> NSView) async throws {
            let host = NSHostingView(rootView: swiftUI.environment(\.piReduceMotion, true))
            host.sizingOptions = [.intrinsicContentSize]
            let reference = try await Self.capture(host, size: size, appearance: .aqua, hover: false, canvas: .piContent, fit: fit)
            var results: [(CGPoint, Int)] = []
            for dx in -8...8 { for dy in -12...8 {
                TranscriptSymbol.offsetOverride = CGPoint(x: CGFloat(dx) * 0.125, y: CGFloat(dy) * 0.125)
                let native = try await Self.capture(appKit(), size: size, appearance: .aqua, hover: false, canvas: .piContent)
                results.append((TranscriptSymbol.offsetOverride!, PiKitParity.difference(reference, native, tolerance: Self.channelTolerance).0))
            } }
            let best = results.min { $0.1 < $1.1 }!
            print("CALIBRATE \(name) symbol: best \(best.0) (\(best.1)); at zero \(results.first { $0.0 == .zero }!.1)")
        }
        try await sweep("copy", MarkdownHeadingAction(target: target, environment: TranscriptRowEnvironment()), size: CGSize(width: 88, height: 47), fit: nil) {
            let view = MarkdownHeadingActionView(); view.update(target: target, environment: TranscriptRowEnvironment()); return view
        }
        try await sweep("quote", QuoteActionBar(ask: {}).padding(QuoteActionPanel.margin), size: CGSize(width: 228, height: 86), fit: CGSize(width: 204, height: 62)) {
            QuoteActionBarView(margin: QuoteActionPanel.margin, ask: {})
        }
    }

    func testTableActionsMatchSwiftUI() async throws {
        let mark = MarkdownTableMark(header: [AttributedString("A")], rows: [[AttributedString("1")]], large: true)
        try await check("table-action", { dark in MarkdownTableAction(mark: mark, environment: Self.environment(dark)) }) { dark in
            let view = MarkdownTableActionView()
            view.update(mark: mark, environment: Self.environment(dark))
            return view
        }
    }

    // MARK: The quote bar

    /// The SwiftUI bar's hosting view reported its width rounded down half
    /// a point (203 for 203.5), so its title was cut to "Ask in side ch…";
    /// the AppKit bar takes its whole width, rounded up, and is compared with
    /// the SwiftUI bar given that room.
    func testQuoteBarMatchesSwiftUI() async throws {
        for hover in [false, true] {
            try await check("quote-bar\(hover ? "-hover" : "")", hover: hover ? { ($0 as? QuoteActionBarView)?.trigger.onHover?(true) } : nil, idealSize: true, { _ in
                QuoteActionBar(ask: {}).padding(QuoteActionPanel.margin)
            }) { _ in
                QuoteActionBarView(margin: QuoteActionPanel.margin, ask: {})
            }
        }
    }

    // MARK: The full table

    func testTableWindowMatchesSwiftUI() async throws {
        let header = ["Attempt", "Delay", "Result"].map { AttributedString($0) }
        let rows = (1...60).map { index in ["\(index)", "\(100 * index) ms", index % 4 == 0 ? "failed" : "ok"].map { AttributedString($0) } }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let previous = Set(MarkdownTableWindow.open.map(ObjectIdentifier.init))
            MarkdownTableWindow.open(header: header, rows: rows)
            let window = try XCTUnwrap(MarkdownTableWindow.open.first { !previous.contains(ObjectIdentifier($0)) })
            defer { window.close() }
            let controller = try XCTUnwrap(MarkdownTableWindow.controller(of: window))
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 720, height: 480))
            func capture() async throws -> NSBitmapImageRep {
                var previous: Data?, image: NSBitmapImageRep?
                try await eventually("the table window at rest", timeout: .seconds(10), poll: .milliseconds(60)) {
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                    guard let now = try? PiKitParity.windowImage(window), let data = now.representation(using: .png, properties: [:]) else { return false }
                    defer { previous = data }
                    if data == previous { image = now; return true }
                    return false
                }
                return try XCTUnwrap(image)
            }
            let native = try await capture()
            XCTAssertTrue(window.contentView is MarkdownTableWindowContent, "the window is AppKit")
            // The same grid and cell text, in the SwiftUI layout.
            let content = try XCTUnwrap(window.contentView)
            controller.gridScroll.removeFromSuperview(); controller.detailScroll.removeFromSuperview()
            window.contentView = NSHostingView(rootView: MarkdownTableWindowView(rows: rows.count, grid: controller.gridScroll,
                                                                              detail: controller.detailScroll, copy: {}))
            let swiftUI = try await capture()
            withExtendedLifetime(content) {}
            if let folder = testEnvironment("PI_PARITY_OUT") {
                try TranscriptNativeRowParityTests.png(native)?.write(to: URL(fileURLWithPath: folder + "/table-window-\(suffix)-native.png"))
                try TranscriptNativeRowParityTests.png(swiftUI)?.write(to: URL(fileURLWithPath: folder + "/table-window-\(suffix)-swiftui.png"))
            }
            let (differing, total, largest) = PiKitParity.difference(swiftUI, native, tolerance: Self.channelTolerance)
            results.append("table-window-\(suffix): \(differing)/\(total) px differ (largest channel \(largest))")
            XCTAssertLessThanOrEqual(Double(differing), Double(total) * Self.share, "table-window-\(suffix): \(differing)/\(total) px differ")
            // The bar on its own, so its few words are not lost in the window's pixels.
            let scale = CGFloat(native.pixelsWide) / window.frame.width
            let bar = CGRect(x: 0, y: 0, width: CGFloat(native.pixelsWide), height: MarkdownTableWindowContent.barHeight * scale)
            let (outside, _, _) = Self.difference(swiftUI, native, masks: [CGRect(x: 0, y: bar.maxY, width: bar.width, height: CGFloat(native.pixelsHigh))])
            XCTAssertLessThanOrEqual(Double(outside), Double(bar.width * bar.height) * Self.share, "table-window-\(suffix): \(outside) px of its bar differ")
        }
    }
}
