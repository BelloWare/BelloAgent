import Foundation

/// How often the views that keep to their own inputs were drawn, while a test
/// counts. Every change to the workspace used to redraw the whole window;
/// these views now let a change pass that shows them nothing new, and the
/// counts are how a test holds them to that. Nothing is counted unless
/// `recording` is on, and nothing but a view's name is.
@MainActor enum RedrawCounter {
    static var recording = false
    private(set) static var counts: [String: Int] = [:]
    static func note(_ view: String) { if recording { counts[view, default: 0] += 1 } }
    static func reset() { counts = [:] }
}
