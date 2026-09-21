import Foundation

struct TranscriptPresentationInput: Equatable, Sendable {
    var messages: [TranscriptMessage]
    var lifecycle: TaskPresentationProjection?
}
