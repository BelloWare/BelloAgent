/// What one message can hold, as the bundled helper accepts it.
enum SubmissionLimits {
    /// The most a message's text can hold: 256 KiB of UTF-8. A send, a side's
    /// first message and an edit refuse a longer draft, and reading a message's
    /// whole text back for an edit expects no more. The composer holds a draft
    /// to the same size (`NativeComposer.Coordinator.byteLimit`).
    static let messageBytes = 262_144
    /// Its images, as the helper loads them (`loadImages`): four, each within
    /// 8 MiB, so 32 MiB in all.
    static let images = 4
    static let imageBytes = 8 * 1024 * 1024
    static let imageTotalBytes = images * imageBytes
}
