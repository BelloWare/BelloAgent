import AppKit
import SwiftUI

/// AppKit owns mouse tracking inside the plot only. Wheel events continue up
/// to the popup's scroll view; leaving the plot during a drag clamps its end.
/// Keeping the input surface separate also exercises real native mouse events
/// in tests without requiring an unlocked global desktop.
@MainActor struct MonitorChartInteraction: NSViewRepresentable {
    let plot: CGRect
    let domain: ClosedRange<Date>
    let hover: (Date?) -> Void
    let drag: (Double, Double, Double, ClosedRange<Date>) -> Void
    let finish: (Double, Double) -> Void
    let reset: () -> Void
    let step: (Int) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.plot = plot; view.domain = domain
        view.hover = hover; view.drag = drag; view.finish = finish; view.reset = reset; view.step = step
    }
    final class Surface: NSView {
        var plot = CGRect.zero
        var domain = Date.distantPast...Date.distantFuture
        var hover: ((Date?) -> Void)?
        var drag: ((Double, Double, Double, ClosedRange<Date>) -> Void)?
        var finish: ((Double, Double) -> Void)?
        var reset: (() -> Void)?
        var step: ((Int) -> Void)?
        private var origin: CGPoint?
        private var capturedDomain: ClosedRange<Date>?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return plot.contains(local) ? super.hitTest(point) : nil
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard plot.contains(point) else { return }
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { origin = nil; capturedDomain = nil; reset?(); return }
            origin = point; capturedDomain = domain
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let capturedDomain else { return }
            let point = convert(event.locationInWindow, from: nil)
            let x = point.x - origin.x, y = point.y - origin.y
            guard abs(x) >= 8, abs(x) > abs(y) else { return }
            hover?(nil)
            drag?(origin.x - plot.minX, point.x - plot.minX, plot.width, capturedDomain)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let capturedDomain, abs(point.x - origin.x) >= 8, abs(point.x - origin.x) > abs(point.y - origin.y) {
                drag?(origin.x - plot.minX, point.x - plot.minX, plot.width, capturedDomain)
            }
            finish?(point.x - origin.x, point.y - origin.y)
            self.origin = nil; capturedDomain = nil
        }
        override func mouseMoved(with event: NSEvent) {
            guard origin == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            hover?(plot.contains(point) ? MonitorChartZoom.date(x: point.x - plot.minX, width: plot.width, domain: domain) : nil)
        }
        override func mouseExited(with event: NSEvent) { if origin == nil { hover?(nil) } }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: origin = nil; capturedDomain = nil; reset?()
            case 123: step?(-1)
            case 124: step?(1)
            case 24, 69: // + zooms the middle half for keyboard users.
                drag?(plot.width / 4, plot.width * 0.75, plot.width, domain); finish?(plot.width / 2, 0)
            case 27, 78: reset?()
            default: super.keyDown(with: event)
            }
        }
    }
}
