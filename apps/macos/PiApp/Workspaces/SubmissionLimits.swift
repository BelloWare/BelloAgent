/// The most a message's text can hold: 256 KiB of UTF-8. A send, a side's
/// first message and an edit refuse a longer draft, and reading a message's
/// whole text back for an edit expects no more. The composer holds a draft
/// to the same size (`NativeComposer`).
enum SubmissionLimits {
    static let messageBytes = 262_144
}
