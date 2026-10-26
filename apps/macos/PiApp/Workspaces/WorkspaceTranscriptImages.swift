import Foundation

extension WorkspaceModel {
    /// Reopened rows already carry an offset. A live helper row carries only
    /// its count, so its first visible thumbnail resolves that offset on the
    /// image reader, independently of another chat's history opening.
    func transcriptImage(_ message: TranscriptMessage, sessionID: String, index: Int, pixels: Int) async throws -> TranscriptImageBitmap {
        guard message.role == "user", index >= 0, index < (message.imageCount ?? 0) else { throw StoreError.unreadableRecord }
        let cache = transcriptImages ?? TranscriptImageCache()
        transcriptImages = cache
        if let attachments = message.imageAttachments, attachments.indices.contains(index) {
            return try await cache.image(source: .attachment(attachments[index]), index: 0, pixels: pixels)
        }
        if let reference = message.imageReference {
            do { return try await cache.image(source: .journal(reference), index: index, pixels: pixels) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Journal slimming replaces the file. Resolve the retained
                // message in that replacement rather than reusing its offsets.
                let fresh = try await imageReader().imageReference(path: reference.path, id: message.id)
                return try await cache.image(source: .journal(fresh), index: index, pixels: pixels)
            }
        }
        guard let path = record(sessionID)?.path else { throw HostError.failure("This message's image is not available yet.") }
        let reference = try await imageReader().imageReference(path: path, id: message.id)
        return try await cache.image(source: .journal(reference), index: index, pixels: pixels)
    }

    private func imageReader() -> HistoryReader {
        if let transcriptImageReader { return transcriptImageReader }
        let reader = HistoryReader(); transcriptImageReader = reader
        return reader
    }
}
