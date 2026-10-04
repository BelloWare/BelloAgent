import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Draws a SwiftUI Pi component and its AppKit twin (DesignKit/) in two
/// windows of the same size on the same canvas, and compares what the window
/// server shows of each, pixel by pixel. The captures are the window
/// server's, so they include how layers were composited, not a view drawn
/// into a bitmap.
///
/// Set `PI_COMPONENT_GALLERY` to a folder to keep the captures as
/// `swiftui/<name>.png` and `appkit/<name>.png`, for
/// `scripts/compare-captures.py <folder>/swiftui <folder>/appkit`.
@MainActor enum PiKitParity {
    /// A channel this far apart counts as a different pixel: antialiasing of
    /// the same glyph or edge placed a fraction of a pixel differently stays
    /// under it.
    static let channelTolerance = 16
    /// What one comparison found.
    struct Result: CustomStringConvertible {
        let name: String
        let size: CGSize
        let differing: Int
        let total: Int
        let largest: Int
        let swiftUIFit: CGSize
        let appKitFit: CGSize
        let swiftUIImage: NSBitmapImageRep
        let appKitImage: NSBitmapImageRep
        var description: String {
            "\(name): \(differing)/\(total) px differ (largest channel \(largest)); fitting SwiftUI \(swiftUIFit) AppKit \(appKitFit)"
        }
    }

    /// The canvas both are drawn on, and the margin around them.
    static let margin: CGFloat = 12

    /// Compares `swiftUI` with `appKit` in `appearance`. `hover` puts the
    /// pointer on the centre of both, one after the other.
    static func compare<V: View>(_ name: String, appearance: NSAppearance.Name = .aqua, hover: Bool = false,
                                 swiftUI: V, appKit: NSView, canvas: NSColor = .piContent, width: CGFloat? = nil) async throws -> Result {
        let root = swiftUI.environment(\.piReduceMotion, true)
        // Both drawn from the same top-left corner: centring would leave
        // each to round a half pixel its own way.
        let host = NSHostingView(rootView: root.padding(EdgeInsets(top: margin, leading: margin, bottom: 0, trailing: 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        // SwiftUI's own size, unrounded; a hosting view rounds its fitting size up.
        let swiftUIFit = NSHostingController(rootView: root).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        let intrinsic = appKit.intrinsicContentSize
        var appKitFit = intrinsic.width == NSView.noIntrinsicMetric || intrinsic.height == NSView.noIntrinsicMetric ? appKit.fittingSize : intrinsic
        if let width {
            appKitFit.width = width
            if let sized = appKit as? PiKit.WidthSizing { appKitFit.height = sized.height(forWidth: width) }
            else if intrinsic.height != NSView.noIntrinsicMetric { appKitFit.height = intrinsic.height }
        }
        let size = CGSize(width: ceil(max(swiftUIFit.width, appKitFit.width) + margin * 2),
                          height: ceil(max(swiftUIFit.height, appKitFit.height) + margin * 2))
        let first = try await capture(host, fit: nil, size: size, appearance: appearance, hover: hover, canvas: canvas)
        let second = try await capture(appKit, fit: appKitFit, size: size, appearance: appearance, hover: hover, canvas: canvas)
        if let folder = testEnvironment("PI_COMPONENT_GALLERY"), !folder.isEmpty {
            for (kind, image) in [("swiftui", first), ("appkit", second)] {
                let directory = URL(fileURLWithPath: folder).appendingPathComponent(kind)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        let (differing, total, largest) = difference(first, second)
        return Result(name: name, size: size, differing: differing, total: total, largest: largest, swiftUIFit: swiftUIFit, appKitFit: appKitFit,
                      swiftUIImage: first, appKitImage: second)
    }

    /// `view` at its fitting size, centred as a hosting view centres its
    /// content, in a borderless window of `size`.
    /// `fit` nil fills the window (a hosting view centres its own content).
    private static func capture(_ view: NSView, fit: CGSize?, size: CGSize, appearance: NSAppearance.Name, hover: Bool,
                                canvas: NSColor) async throws -> NSBitmapImageRep {
        let screen = NSScreen.screens.first?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.maxY - 40 - size.height, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = canvas
        window.hasShadow = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        if let fit {
            view.frame = NSRect(x: margin, y: size.height - margin - fit.height, width: fit.width, height: fit.height)
        } else {
            view.frame = NSRect(origin: .zero, size: size)
        }
        content.addSubview(view)
        window.orderFrontRegardless()
        // No field editing: a field that took focus would show its text
        // selected. A view that takes the keys itself (a choice list) keeps them.
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
        defer { view.removeFromSuperview(); window.orderOut(nil); window.contentView = nil }
        if hover {
            // The app the reader points at is the active one: tracking areas
            // report the pointer there, as in use.
            NSApp.activate(ignoringOtherApps: true)
            var settled: Data?
            try await eventually("the window server showing \(type(of: view)) at rest", timeout: .seconds(10), poll: .milliseconds(60)) {
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                guard let now = try? windowImage(window).representation(using: .png, properties: [:]) else { return false }
                defer { settled = now }
                return now == settled
            }
            let centre = window.convertPoint(toScreen: NSPoint(x: view.frame.midX, y: view.frame.midY))
            let top = NSScreen.screens.first?.frame.height ?? 0
            let point = CGPoint(x: centre.x, y: top - centre.y)
            CGWarpMouseCursorPosition(point)
            // A warp moves no tracking area by itself; a moved event does.
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            // Until the hover shows, for as long as it may take to arrive;
            // a control that never shows one is the test's to report.
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                if let now = try? windowImage(window).representation(using: .png, properties: [:]), now != settled { break }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        var previous: Data?, image: NSBitmapImageRep?
        try await eventually("the window server showing \(type(of: view))", timeout: .seconds(10), poll: .milliseconds(60)) {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard let now = try? windowImage(window), let data = now.representation(using: .png, properties: [:]) else { return false }
            defer { previous = data }
            if data == previous { image = now; return true }
            return false
        }
        if hover {
            let away = CGPoint(x: 1, y: 1)
            CGWarpMouseCursorPosition(away)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: away, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return try XCTUnwrap(image)
    }

    static func windowImage(_ window: NSWindow) throws -> NSBitmapImageRep {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        let bounds = CGRect(x: window.frame.minX, y: screen.height - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        guard let image = create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                 CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
        else { throw XCTSkip("Window capture returned no image") }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Pixels whose channels differ by more than the tolerance, of all, and
    /// the largest difference of a channel.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, Int, Int) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return (a.pixelsWide * a.pixelsHigh, a.pixelsWide * a.pixelsHigh, 255) }
        var differing = 0, largest = 0
        var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
                var worst = 0
                for channel in 0..<min(a.samplesPerPixel, 4) { worst = max(worst, abs(p[channel] - q[channel])) }
                largest = max(largest, worst)
                if worst > channelTolerance { differing += 1 }
            }
        }
        return (differing, a.pixelsWide * a.pixelsHigh, largest)
    }
}
