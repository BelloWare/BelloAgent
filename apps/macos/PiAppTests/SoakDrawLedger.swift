import AppKit
import ObjectiveC
import QuartzCore

/// Where the main thread's CPU drawing goes (opt-in: `PI_SOAK_DRAW_REPORT`).
/// SwiftUI draws most of a hosting view's content with Core Graphics, into
/// layers of its own; this times every such drawing, by the view that owns
/// the layer and by what the soak was doing (`phase`), with the pixels drawn.
/// It replaces `drawInContext:` and `display` on each SwiftUI layer class it
/// finds in a window (`install`), and calls the original.
@MainActor final class SoakDrawLedger {
    struct Entry { var count = 0; var seconds = 0.0; var pixels = 0.0; var longest = 0.0 }
    static var phase = "setup"
    /// Whether draws are being recorded, and of which window: the methods
    /// stay replaced once replaced, and otherwise only call the originals.
    nonisolated(unsafe) static var recording = false
    static weak var window: NSWindow?
    static var entries: [String: Entry] = [:]
    private static var replaced: Set<String> = []
    private static var snapshots = 0

    /// Replaces the drawing methods of the SwiftUI layer classes in `window`.
    static func install(in window: NSWindow) {
        guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return }
        var classes: [AnyClass] = []
        func walk(_ layer: CALayer) {
            classes.append(type(of: layer))
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        for cls in classes {
            let name = NSStringFromClass(cls)
            guard !replaced.contains(name), let image = class_getImageName(cls).map({ String(cString: $0) }),
                  image.contains("SwiftUI") || image.contains("RenderBox") else { continue }
            replaced.insert(name)
            replace(cls, NSSelectorFromString("drawInContext:"))
            replace(cls, NSSelectorFromString("display"))
        }
    }

    private static func replace(_ cls: AnyClass, _ selector: Selector) {
        // Only a method the class itself implements: its superclass's is
        // replaced on the superclass, if that is SwiftUI's.
        guard let method = class_getInstanceMethod(cls, selector),
              class_getInstanceMethod(class_getSuperclass(cls), selector).map({ method_getImplementation($0) != method_getImplementation(method) }) ?? true
        else { return }
        let original = method_getImplementation(method)
        if selector == NSSelectorFromString("display") {
            typealias Display = @convention(c) (CALayer, Selector) -> Void
            let call = unsafeBitCast(original, to: Display.self)
            let block: @convention(block) (CALayer) -> Void = { layer in time(layer, "display") { call(layer, selector) } }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            typealias Draw = @convention(c) (CALayer, Selector, CGContext) -> Void
            let call = unsafeBitCast(original, to: Draw.self)
            let block: @convention(block) (CALayer, CGContext) -> Void = { layer, context in time(layer, "draw") { call(layer, selector, context) } }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    private nonisolated static func time(_ layer: CALayer, _ how: String, _ body: () -> Void) {
        guard recording, Thread.isMainThread else { return body() }
        let start = ProcessInfo.processInfo.systemUptime
        body()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        guard Thread.isMainThread else { return }
        nonisolated(unsafe) let layer = layer
        MainActor.assumeIsolated {
            guard let window, ownerWindow(of: layer) === window else { return }
            let key = "\(phase) | \(how) | \(owner(of: layer))"
            if entries[key] == nil, snapshots < 12, let folder = ProcessInfo.processInfo.environment["PI_SOAK_DRAW_SNAPSHOTS"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_PI_SOAK_DRAW_SNAPSHOTS"],
               let window = (layer.delegate as? NSView)?.window ?? layer.superlayer.flatMap({ $0.delegate as? NSView })?.window, let content = window.contentView {
                // The window around the layer, to see what it is.
                snapshots += 1
                let frame = layer.convert(layer.bounds, to: content.layer)
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let image = NSImage(size: content.bounds.size); image.addRepresentation(rep)
                    image.lockFocus(); NSColor.red.setStroke(); NSBezierPath(rect: frame.insetBy(dx: -2, dy: -2)).stroke(); image.unlockFocus()
                    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("draw-\(snapshots).png"))
                    }
                }
            }
            var entry = entries[key] ?? Entry()
            entry.count += 1; entry.seconds += seconds; entry.longest = max(entry.longest, seconds)
            entry.pixels += Double(layer.bounds.width * layer.bounds.height * layer.contentsScale * layer.contentsScale)
            entries[key] = entry
        }
    }

    /// Records the CPU drawings of `window` from now on: from nothing, or,
    /// `adding`, after what was recorded of other windows.
    static func begin(_ window: NSWindow, adding: Bool = false) {
        install(in: window)
        self.window = window; recording = true
        if !adding { entries = [:] }
    }
    static func end() { recording = false; window = nil }
    private static func ownerWindow(of layer: CALayer) -> NSWindow? {
        var current: CALayer? = layer
        while let candidate = current { if let view = candidate.delegate as? NSView { return view.window }; current = candidate.superlayer }
        return nil
    }

    /// The layer's size and the views it is drawn for, innermost first.
    private static func owner(of layer: CALayer) -> String {
        var current: CALayer? = layer, view: NSView?
        while let candidate = current, view == nil { view = candidate.delegate as? NSView; current = candidate.superlayer }
        var chain: [String] = []
        if let shown = view, let window = shown.window {
            let frame = shown.convert(shown.bounds, to: nil)
            chain.append("at \(Int(frame.minX / 10) * 10),\(Int(frame.minY / 10) * 10)")
            // What accessibility finds there: which SwiftUI view it is.
            let center = window.convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.midY))
            if let element = window.contentView?.accessibilityHitTest(center) as? NSAccessibilityProtocol {
                chain.append("[\(element.accessibilityRole()?.rawValue ?? "?") \((element.accessibilityLabel() ?? "").prefix(40)) \((element.accessibilityIdentifier() ?? "").prefix(30))]")
            }
        }
        while let shown = view, chain.count < 4 {
            chain.append(String(String(describing: type(of: shown)).prefix(48)) + " \(Int(shown.frame.width))x\(Int(shown.frame.height))")
            view = shown.superview
        }
        return "\(type(of: layer)) \(Int(layer.bounds.width))x\(Int(layer.bounds.height)) in " + chain.joined(separator: " < ")
    }

    /// The most expensive owners, per phase kind, after each phase's total.
    static func report() -> [String] {
        var phases: [String: Entry] = [:]
        for (key, entry) in entries {
            let phase = String(key.prefix { $0 != "|" })
            var total = phases[phase] ?? Entry()
            total.count += entry.count; total.seconds += entry.seconds; total.pixels += entry.pixels; total.longest = max(total.longest, entry.longest)
            phases[phase] = total
        }
        let totals = phases.sorted { $0.value.seconds > $1.value.seconds }.map { phase, entry in
            String(format: "SOAK draw phase %@: %.1f ms in %d draws, %.1f Mpx", phase, entry.seconds * 1_000, entry.count, entry.pixels / 1e6)
        }
        // By where on screen, whatever the size: one place drawn at many sizes
        // is one owner.
        var places: [String: Entry] = [:]
        for (key, entry) in entries {
            let place = key.range(of: " in ").map { String(key[$0.upperBound...]).components(separatedBy: " < ").prefix(2).joined(separator: " < ") } ?? key
            var total = places[place] ?? Entry()
            total.count += entry.count; total.seconds += entry.seconds; total.pixels += entry.pixels
            places[place] = total
        }
        let byPlace = places.sorted { $0.value.seconds > $1.value.seconds }.prefix(20).map { place, entry in
            String(format: "SOAK draw place %7.1f ms, %5d draws, %6.1f Mpx: %@", entry.seconds * 1_000, entry.count, entry.pixels / 1e6, place)
        }
        return totals + byPlace + owners()
    }
    private static func owners() -> [String] {
        entries.sorted { $0.value.seconds > $1.value.seconds }.prefix(40).map { key, entry in
            String(format: "SOAK draw %7.1f ms total, %5d draws, longest %5.1f ms, %6.1f Mpx: %@",
                   entry.seconds * 1_000, entry.count, entry.longest * 1_000, entry.pixels / 1e6, key)
        }
    }
}
