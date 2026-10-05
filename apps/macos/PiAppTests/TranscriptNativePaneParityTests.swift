import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The conversation pane drawn by AppKit (`NativeTranscriptPane`, through
/// its SwiftUI wrapper) and by the SwiftUI pane it replaced
/// (`NativeTranscriptReferenceView`), as the window server shows each: its
/// edges in every state, Back to bottom, the live bar and the note. Same
/// size, and no more than 0.4% of the pixels apart outside the symbols
/// (compared on their own) and the spinners and shimmer (which move).
///
/// Serial: the windows are on screen.
@MainActor final class TranscriptNativePaneParityTests: XCTestCase, SerialTestLane {
    private var results: [String] = []
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("PARITY " + result) }
    }

    /// What moves in `view` (a window `height` tall), in pixels.
    static func moving(_ view: NSView, _ height: CGFloat) -> [CGRect] { animatedRects(in: view, windowHeight: height, scale: view.window?.backingScaleFactor ?? 2) }
    /// What moves on its own: masked in both captures.
    static func animatedRects(in view: NSView, windowHeight: CGFloat, scale: CGFloat) -> [CGRect] {
        var rects: [CGRect] = []
        func walk(_ view: NSView) {
            if view is TranscriptSpinner || view is TranscriptShimmerLabel, !view.isHiddenOrHasHiddenAncestor {
                let r = view.convert(view.bounds, to: nil).insetBy(dx: -2, dy: -2)
                rects.append(CGRect(x: floor(r.minX * scale), y: floor((windowHeight - r.maxY) * scale), width: ceil(r.width * scale), height: ceil(r.height * scale)))
            }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return rects
    }

    /// Pixels apart outside the masks, and inside the symbols.
    private func compare(_ label: String, swiftUI: NSBitmapImageRep, native: NSBitmapImageRep, symbols: [CGRect], animated: [CGRect],
                         file: StaticString = #filePath, line: UInt = #line) throws {
        if let folder = testEnvironment("PI_PARITY_OUT") {
            try TranscriptNativeRowParityTests.png(swiftUI)?.write(to: URL(fileURLWithPath: folder + "/\(label)-swiftui.png"))
            try TranscriptNativeRowParityTests.png(native)?.write(to: URL(fileURLWithPath: folder + "/\(label)-native.png"))
        }
        let both = TranscriptNativeChromeParityTests.difference(swiftUI, native, masks: symbols + animated)
        let moving = TranscriptNativeChromeParityTests.difference(swiftUI, native, masks: animated)
        let inSymbols = moving.outside - both.outside
        results.append("\(label): \(both.outside)/\(both.total) px differ, \(inSymbols) in \(symbols.count) symbols, \(animated.count) masked")
        XCTAssertLessThanOrEqual(Double(both.outside), Double(both.total) * TranscriptNativeChromeParityTests.share,
                                 "\(label): \(both.outside)/\(both.total) px differ", file: file, line: line)
        XCTAssertLessThanOrEqual(inSymbols, TranscriptNativeChromeParityTests.symbolPixels * max(1, symbols.count),
                                 "\(label): \(inSymbols) px of its symbols differ", file: file, line: line)
    }

    // MARK: The edges' controls

    /// One edge control, the SwiftUI view in a frame `width` wide and the
    /// AppKit one in the slot the pane gives it, centred the same way.
    private func checkEdge<V: View>(_ name: String, width: CGFloat = 520, rightToLeft: Bool = false, _ swiftUI: V, _ shown: (NativeTranscriptPane) -> TranscriptEdgeSlot.Shown?,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let label = "edge-\(name)-\(suffix)"
            let host = NSHostingView(rootView: swiftUI.frame(width: width).environment(\.piReduceMotion, true)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight))
            host.sizingOptions = [.intrinsicContentSize]; host.safeAreaRegions = []
            let pane = NativeTranscriptPane()
            var environment = TranscriptRowEnvironment(); environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            pane.update(session: SessionDisplay(id: "edge"), state: "idle", actions: TranscriptActions(), environment: environment, reduceMotion: true)
            let slot = TranscriptEdgeSlot()
            slot.show(shown(pane), animated: false)
            let size = slot.size(offered: width)
            let hosted = host.fittingSize
            XCTAssertEqual(ceil(size.height * 2) / 2, hosted.height, accuracy: 0.5, "\(label): height", file: file, line: line)
            let fit = CGSize(width: width, height: hosted.height)
            let window = CGSize(width: width + 24, height: ceil(fit.height) + 24)
            let swiftUIImage = try await TranscriptNativeChromeParityTests.capture(host, size: window, appearance: appearance, hover: false,
                                                                                    canvas: .piContent, fit: fit)
            let container = EdgeHolder(slot: slot, width: width)
            let nativeImage = try await TranscriptNativeChromeParityTests.capture(container, size: window, appearance: appearance, hover: false,
                                                                                   canvas: .piContent, fit: fit, moving: { Self.moving($0, $1) })
            let symbols = TranscriptNativeChromeParityTests.symbolRects[ObjectIdentifier(container)] ?? []
            try compare(label, swiftUI: swiftUIImage, native: nativeImage, symbols: symbols, animated: container.animated, file: file, line: line)
        }
    }
    /// Holds a slot at the top of a frame `width` wide, centred as the
    /// SwiftUI view is in its frame, and notes what moves in it.
    final class EdgeHolder: NSView {
        let slot: TranscriptEdgeSlot
        let width: CGFloat
        var animated: [CGRect] = []
        init(slot: TranscriptEdgeSlot, width: CGFloat) {
            self.slot = slot; self.width = width
            super.init(frame: .zero)
            addSubview(slot)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            let size = slot.size(offered: width)
            slot.frame = TranscriptMotion.pixelAligned(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                              width: size.width, height: size.height), scale: window?.backingScaleFactor ?? 2)
            slot.place(offered: width)
            if let window {
                animated = TranscriptNativePaneParityTests.animatedRects(in: self, windowHeight: window.contentView?.bounds.height ?? 0,
                                                                         scale: window.backingScaleFactor)
            }
        }
    }

    static let longError = "The helper could not read the earlier page of this conversation: the connection was reset while the page was being read, after 3 tries. Check the connection and try again."

    func testEarlierEdgesMatchSwiftUI() async throws {
        let states: [(String, TranscriptEdge, String?)] = [
            ("loading", .loading, nil), ("waiting", .waiting, nil), ("waiting-partial", .waiting, "What changed?"),
            ("failed", .failed("Connection reset"), nil), ("failed-long", .failed(Self.longError), nil),
            ("failed-partial", .failed("Connection reset"), "What changed?")]
        for (name, state, partial) in states {
            try await checkEdge("earlier-\(name)", TranscriptEarlierEdge(state: state, partialTurnInput: partial, load: {}, inspect: { _ in })) {
                $0.earlierControl(state, partialTurnInput: partial)
            }
        }
        // Narrow: the line's words wrap as SwiftUI's did.
        for (name, state) in [("waiting-partial", TranscriptEdge.waiting), ("failed-partial", .failed("Connection reset"))] {
            for width in [268, 220] as [CGFloat] {
                try await checkEdge("earlier-\(name)-\(Int(width))", width: width,
                                    TranscriptEarlierEdge(state: state, partialTurnInput: "u1", load: {}, inspect: { _ in })) {
                    $0.earlierControl(state, partialTurnInput: "u1")
                }
            }
        }
        // Right to left: the stacks mirror.
        for (name, state) in [("waiting-partial", TranscriptEdge.waiting), ("failed-partial", .failed("Connection reset"))] {
            try await checkEdge("earlier-\(name)-rtl", rightToLeft: true,
                                TranscriptEarlierEdge(state: state, partialTurnInput: "u1", load: {}, inspect: { _ in })) {
                $0.earlierControl(state, partialTurnInput: "u1")
            }
        }
        try await checkEdge("earlier-failed-narrow", width: 300, TranscriptEarlierEdge(state: .failed(Self.longError), partialTurnInput: nil, load: {}, inspect: { _ in })) {
            $0.earlierControl(.failed(Self.longError), partialTurnInput: nil)
        }
    }

    func testPartialTurnChipsMatchSwiftUI() async throws {
        try await checkEdge("partial", TranscriptPartialTurnChip(input: "What changed?", inspect: { _ in })) { $0.partialChip("What changed?") }
        try await checkEdge("partial-rtl", rightToLeft: true, TranscriptPartialTurnChip(input: "What changed?", inspect: { _ in })) { $0.partialChip("What changed?") }
        try await checkEdge("partial-narrow", width: 120, TranscriptPartialTurnChip(input: "What changed?", inspect: { _ in })) { $0.partialChip("What changed?") }
    }

    func testNewerEdgesMatchSwiftUI() async throws {
        let states: [(String, TranscriptEdge)] = [("loading", .loading), ("failed", .failed("Connection reset")),
                                                  ("changed", .changed("This chat changed in another window.")), ("failed-long", .failed(Self.longError))]
        for (name, state) in states {
            try await checkEdge("newer-\(name)", width: 440, TranscriptNewerEdge(state: state, load: {}, reload: {})) {
                $0.newerControl(state)
            }
        }
        try await checkEdge("newer-changed-rtl", width: 440, rightToLeft: true, TranscriptNewerEdge(state: .changed("This chat changed in another window."), load: {}, reload: {})) {
            $0.newerControl(.changed("This chat changed in another window."))
        }
    }

    // MARK: The whole pane

    /// A chat of a few turns, its newest reply still running so the live
    /// bar shows, drawn by both panes in windows of the same size.
    private func pane(native: Bool, session: SessionDisplay, width: CGFloat, height: CGFloat, dark: Bool,
                      prepare: (NSView) async throws -> Void) async throws -> (NSBitmapImageRep, symbols: [CGRect], animated: [CGRect]) {
        let screen = NSScreen.screens.first?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.maxY - 40 - height, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .piContent; window.hasShadow = false
        let host: NSView
        if native {
            let view = NSHostingView(rootView: NativeTranscriptView(session: session, state: session.state, actions: TranscriptActions())
                .environment(\.piReduceMotion, true))
            // The window keeps its size: the pane fills it, as it fills its place in the app.
            view.safeAreaRegions = []; view.sizingOptions = []; host = view
        } else {
            let view = NSHostingView(rootView: NativeTranscriptReferenceView(session: session, state: session.state, actions: TranscriptActions())
                .environment(\.piReduceMotion, true))
            // The window keeps its size: the pane fills it, as it fills its place in the app.
            view.safeAreaRegions = []; view.sizingOptions = []; host = view
        }
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await prepare(host)
        var previous: Data?, image: NSBitmapImageRep?
        try await eventually("the pane at rest", timeout: .seconds(20), poll: .milliseconds(80)) {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard let now = try? PiKitParity.windowImage(window) else { return false }
            // What moves is left out of "at rest".
            let animated = Self.animatedRects(in: host, windowHeight: height, scale: window.backingScaleFactor)
            let data = TranscriptNativeChromeParityTests.masked(now, animated)
            defer { previous = data }
            if data == previous { image = now; return true }
            return false
        }
        let scale = window.backingScaleFactor
        return (try XCTUnwrap(image), TranscriptNativeChromeParityTests.symbols(in: host, windowHeight: height, scale: scale),
                Self.animatedRects(in: host, windowHeight: height, scale: scale))
    }
    private func chat(running: Bool) -> SessionDisplay {
        let session = SessionDisplay(id: "pane-parity")
        session.messages = TranscriptStreamingStressTests.history(turns: 6)
        if running { session.state = "running" }
        return session
    }

    /// Scrolled up: Back to bottom floats over the foot; running: the live bar.
    func testThePaneMatchesSwiftUI() async throws {
        for width in [792, 520] as [CGFloat] {
            for dark in [false, true] {
                for (name, running, scrolled) in [("rest", false, false), ("scrolled", false, true), ("running", true, true)] {
                    let label = "pane-\(name)-\(Int(width))-\(dark ? "dark" : "light")"
                    func prepare(_ host: NSView) async throws {
                        var found: TranscriptNativeScrollView?
                        try await eventually("the pane's scroll view", timeout: .seconds(10)) { host.layoutSubtreeIfNeeded(); found = Self.scrollView(in: host); return found != nil }
                        let scroll = try XCTUnwrap(found)
                        try await eventually("rows", timeout: .seconds(10)) { host.layoutSubtreeIfNeeded(); return (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height }
                        if scrolled {
                            // The reader scrolls to the top: Back to bottom floats over the foot.
                            scroll.readerWillNavigate(upward: true)
                            scroll.contentView.setBoundsOrigin(.zero)
                            scroll.reflectScrolledClipView(scroll.contentView)
                            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                            try await eventually("Back to bottom", timeout: .seconds(10)) {
                                host.layoutSubtreeIfNeeded()
                                return Self.latestMarkers(in: host).contains { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
                            }
                            try await Task.sleep(for: .milliseconds(600))
                        }
                    }
                    let swiftUI = try await pane(native: false, session: chat(running: running), width: width, height: 600, dark: dark, prepare: prepare)
                    let native = try await pane(native: true, session: chat(running: running), width: width, height: 600, dark: dark, prepare: prepare)
                    try compare(label, swiftUI: swiftUI.0, native: native.0, symbols: native.symbols, animated: native.animated + swiftUI.animated)
                }
            }
        }
    }

    /// The edges in the pane: an earlier read that failed at the top and a
    /// slow newer one beside Back to bottom; then a newer read that failed
    /// above the circle, and the page's note that it could not be projected.
    func testThePanesEdgesMatchSwiftUI() async throws {
        let cursor = ConversationCursor(incarnation: "runtime", lineage: "root", entry: "m4")
        for dark in [false, true] {
            for name in ["earlier-failed-newer-loading", "newer-failed"] {
                let label = "pane-edges-\(name)-\(dark ? "dark" : "light")"
                func chat() -> SessionDisplay {
                    let session = SessionDisplay(id: "pane-edges")
                    session.messages = TranscriptStreamingStressTests.history(turns: 6)
                    if name == "newer-failed" {
                        session.newerPage = ConversationPageBoundary(cursor: cursor, loading: false, error: "Connection reset")
                    } else {
                        session.olderPage = ConversationPageBoundary(cursor: cursor, loading: false, error: Self.longError)
                        session.newerPage = ConversationPageBoundary(cursor: cursor, loading: true, error: nil)
                    }
                    return session
                }
                func prepare(_ host: NSView) async throws {
                    try await eventually("the edges", timeout: .seconds(10)) {
                        host.layoutSubtreeIfNeeded()
                        let kinds = Set(HistoryEdgeTests.edges(host).filter { $0.window != nil }.map { "\($0.edge):\($0.kind)" })
                        return name == "newer-failed" ? kinds.contains("newer:failed") : kinds.contains("earlier:failed") && kinds.contains("newer:loading")
                    }
                    if name == "newer-failed" {
                        func marker(_ view: NSView) -> TranscriptSurfaceMarker? {
                            (view as? TranscriptSurfaceMarker) ?? view.subviews.lazy.compactMap(marker).first
                        }
                        let page = try XCTUnwrap(marker(host)?.page)
                        page.projectionError = "This page could not be projected: an entry is missing."
                        try await eventually("the note", timeout: .seconds(5)) { host.layoutSubtreeIfNeeded(); return Self.scrollView(in: host).map { $0.frame.height < host.bounds.height - 8 } ?? false }
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
                let swiftUI = try await pane(native: false, session: chat(), width: 792, height: 600, dark: dark, prepare: prepare)
                let native = try await pane(native: true, session: chat(), width: 792, height: 600, dark: dark, prepare: prepare)
                try compare(label, swiftUI: swiftUI.0, native: native.0, symbols: native.symbols, animated: native.animated + swiftUI.animated)
            }
        }
    }

    static func latestMarkers(in view: NSView) -> [TranscriptEdgeMarkerView] {
        ((view as? TranscriptEdgeMarkerView).map { $0.kind == "latest" ? [$0] : [] } ?? []) + view.subviews.flatMap { latestMarkers(in: $0) }
    }
    static func scrollView(in view: NSView) -> TranscriptNativeScrollView? {
        if let scroll = view as? TranscriptNativeScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}
