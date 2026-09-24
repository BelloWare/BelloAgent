import Foundation

enum ComposerSubmissionIntent: Equatable {
    case followUp
    case steer

    /// The empty composer's keyboard hints. `queues` is the flag the bar's
    /// own hint and the send button follow; while the bar shows "↩ Queue ·
    /// ⌘↩ Steer" beside Steer, the placeholder does not say it again.
    static func hint(queues: Bool, onBar: Bool = false) -> String {
        guard queues else { return "↩ Send · ⇧↩ New line" }
        return onBar ? "⇧↩ New line" : "↩ Queue · ⌘↩ Steer · ⇧↩ New line"
    }
}
