import Foundation

enum ComposerSubmissionIntent: Equatable {
    case followUp
    case steer

    static func hint(running: Bool) -> String {
        running ? "↩ Queue · ⌘↩ Steer · ⇧↩ New line" : "↩ Send · ⌘↩ Send · ⇧↩ New line"
    }
}
